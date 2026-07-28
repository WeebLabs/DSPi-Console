#include "dspi_rc/calibration.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <sstream>

namespace dspi_rc {
namespace {

std::string trim(const std::string& s) {
    const auto first = s.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return {};
    const auto last = s.find_last_not_of(" \t\r\n");
    return s.substr(first, last - first + 1);
}

// A data row must *start* with a number.  This is the rule REW documents and
// it is what makes the format tolerant of arbitrary header and comment text
// without needing to enumerate every comment marker vendors have invented.
bool startsWithNumber(const std::string& line) {
    for (char c : line) {
        if (c == ' ' || c == '\t') continue;
        return (std::isdigit(static_cast<unsigned char>(c)) != 0) || c == '+' || c == '-' || c == '.';
    }
    return false;
}

// Split on whitespace, tabs, commas and semicolons.  Vendors use all of them,
// sometimes within one file.
std::vector<std::string> splitFields(const std::string& line) {
    std::vector<std::string> fields;
    std::string current;
    for (char c : line) {
        if (c == ' ' || c == '\t' || c == ',' || c == ';') {
            if (!current.empty()) { fields.push_back(current); current.clear(); }
        } else {
            current.push_back(c);
        }
    }
    if (!current.empty()) fields.push_back(current);
    return fields;
}

bool parseDouble(const std::string& text, double& out) {
    if (text.empty()) return false;
    char* end = nullptr;
    const double value = std::strtod(text.c_str(), &end);
    if (end == text.c_str()) return false;
    // Tolerate a glued unit ("100Hz", "-3.5dB") but not arbitrary trailing
    // garbage that suggests the field was not a number at all.
    if (!std::isfinite(value)) return false;
    out = value;
    return true;
}

// "Sens Factor =-1.6690dB, SERNO: 7012345"
void parseSensitivityHeader(const std::string& line, MicCalibration& cal) {
    std::string lowered = line;
    std::transform(lowered.begin(), lowered.end(), lowered.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });

    const bool looksLikeSensitivity =
        lowered.find("sens factor") != std::string::npos ||
        lowered.find("sensitivity") != std::string::npos;
    if (looksLikeSensitivity) {
        const auto equals = line.find('=');
        if (equals != std::string::npos) {
            double value = 0.0;
            if (parseDouble(trim(line.substr(equals + 1)), value)) {
                cal.hasSensitivity = true;
                cal.sensitivityDb = value;
            }
        }
    }

    const auto serno = lowered.find("serno");
    if (serno != std::string::npos) {
        const auto colon = line.find(':', serno);
        if (colon != std::string::npos) {
            std::string serial = trim(line.substr(colon + 1));
            // UMIK files wrap the whole header in quotes, so the serial
            // arrives with a trailing one attached.  Strip quotes and any
            // trailing separator rather than storing punctuation as identity.
            while (!serial.empty() &&
                   (serial.back() == '"' || serial.back() == '\'' || serial.back() == ',')) {
                serial.pop_back();
            }
            while (!serial.empty() && (serial.front() == '"' || serial.front() == '\'')) {
                serial.erase(serial.begin());
            }
            cal.serial = trim(serial);
        }
    }
}

}  // namespace

// ---------------------------------------------------------------------------

double MicCalibration::gainDbAt(double freqHz) const {
    if (points.empty()) return 0.0;
    if (points.size() == 1) return points.front().gainDb;

    // Hold rather than extrapolate.  See the header for why.
    if (freqHz <= points.front().freqHz) return points.front().gainDb;
    if (freqHz >= points.back().freqHz) return points.back().gainDb;

    const auto upper = std::lower_bound(
        points.begin(), points.end(), freqHz,
        [](const CalibrationPoint& p, double f) { return p.freqHz < f; });
    if (upper == points.begin()) return points.front().gainDb;
    const auto lower = upper - 1;

    // Interpolate against log frequency: calibration curves are specified on
    // log-spaced points and linear-in-Hz interpolation visibly kinks them.
    const double logLow = std::log(lower->freqHz);
    const double logHigh = std::log(upper->freqHz);
    const double span = logHigh - logLow;
    if (span <= 0.0) return lower->gainDb;
    const double t = (std::log(freqHz) - logLow) / span;
    return lower->gainDb + t * (upper->gainDb - lower->gainDb);
}

bool MicCalibration::covers(double lowHz, double highHz) const {
    if (points.empty()) return false;
    return minFreqHz() <= lowHz && maxFreqHz() >= highHz;
}

void MicCalibration::applyTo(const std::vector<double>& freqsHz,
                             std::vector<double>& magnitudesDb) const {
    if (points.empty()) return;
    const std::size_t count = std::min(freqsHz.size(), magnitudesDb.size());
    for (std::size_t i = 0; i < count; ++i) {
        magnitudesDb[i] -= gainDbAt(freqsHz[i]);
    }
}

// ---------------------------------------------------------------------------

CalibrationParseResult parseCalibration(const std::string& contents) {
    CalibrationParseResult result;
    MicCalibration& cal = result.calibration;

    std::istringstream stream(contents);
    std::string line;
    std::size_t malformedRows = 0;

    while (std::getline(stream, line)) {
        const std::string trimmed = trim(line);
        if (trimmed.empty()) continue;

        if (!startsWithNumber(trimmed)) {
            parseSensitivityHeader(trimmed, cal);
            continue;
        }

        const std::vector<std::string> fields = splitFields(trimmed);
        if (fields.size() < 2) { ++malformedRows; continue; }

        CalibrationPoint point;
        if (!parseDouble(fields[0], point.freqHz) || !parseDouble(fields[1], point.gainDb)) {
            ++malformedRows;
            continue;
        }
        if (!(point.freqHz > 0.0)) { ++malformedRows; continue; }

        if (fields.size() >= 3) {
            double phase = 0.0;
            if (parseDouble(fields[2], phase)) {
                point.phaseDegrees = phase;
                point.hasPhase = true;
            }
        }
        cal.points.push_back(point);
    }

    if (malformedRows > 0) {
        result.warnings.push_back("ignored " + std::to_string(malformedRows) +
                                  " malformed row(s)");
    }

    if (cal.points.size() < 2) {
        result.error = "calibration needs at least two frequency points";
        cal.points.clear();
        return result;
    }

    // Sort and de-duplicate.  Out-of-order rows are common in hand-edited
    // files; duplicates are usually a copy-paste artifact.  Both are
    // recoverable, but silently recovering would hide a corrupt file, so each
    // repair is reported.
    const bool wasSorted = std::is_sorted(
        cal.points.begin(), cal.points.end(),
        [](const CalibrationPoint& a, const CalibrationPoint& b) { return a.freqHz < b.freqHz; });
    if (!wasSorted) {
        std::stable_sort(
            cal.points.begin(), cal.points.end(),
            [](const CalibrationPoint& a, const CalibrationPoint& b) { return a.freqHz < b.freqHz; });
        result.warnings.push_back("rows were not in ascending frequency order and were sorted");
    }

    const auto duplicate = std::unique(
        cal.points.begin(), cal.points.end(),
        [](const CalibrationPoint& a, const CalibrationPoint& b) {
            return a.freqHz == b.freqHz;
        });
    if (duplicate != cal.points.end()) {
        const auto removed = static_cast<std::size_t>(std::distance(duplicate, cal.points.end()));
        cal.points.erase(duplicate, cal.points.end());
        result.warnings.push_back("removed " + std::to_string(removed) +
                                  " duplicate frequency row(s)");
    }

    if (cal.points.size() < 2) {
        result.error = "calibration needs at least two distinct frequency points";
        cal.points.clear();
        return result;
    }

    return result;
}

}  // namespace dspi_rc
