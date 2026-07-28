// Microphone calibration files.
//
// Format follows what REW documents and what miniDSP ships with the UMIK-1
// and UMIK-2, which is also what Cross-Spectrum, Dayton and most others emit:
// a plain-text list of frequency/gain rows, optionally with phase, optionally
// preceded by a sensitivity header.  Being permissive here is correct - the
// files are hand-edited, vendor-generated, and inconsistent - but being
// permissive about *structure* must not become permissive about *meaning*.
// A file that parses into two junk rows is worse than a file that fails.
#pragma once

#include <string>
#include <vector>

namespace dspi_rc {

struct CalibrationPoint {
    double freqHz = 0.0;
    double gainDb = 0.0;
    double phaseDegrees = 0.0;
    bool hasPhase = false;
};

struct MicCalibration {
    std::vector<CalibrationPoint> points;

    // From a "Sens Factor =-1.6690dB" header if present.  Absolute SPL is only
    // meaningful when this is known *and* the input chain's gain is known, so
    // its presence is necessary but not sufficient; the UI decides whether to
    // show dB SPL or stay in dBFS.
    bool hasSensitivity = false;
    double sensitivityDb = 0.0;

    // Free-text serial or identifying comment, when the file carries one.
    std::string serial;

    bool empty() const { return points.empty(); }
    double minFreqHz() const { return points.empty() ? 0.0 : points.front().freqHz; }
    double maxFreqHz() const { return points.empty() ? 0.0 : points.back().freqHz; }

    // Interpolated gain at a frequency, linear in dB against log frequency.
    //
    // Outside the file's range the endpoint value is held rather than
    // extrapolated.  Extrapolating a calibration curve invents correction
    // where the vendor measured none, and the error grows without bound
    // exactly where the microphone is least trustworthy.  Callers should warn
    // when the analysis range exceeds the file range; `covers()` answers that.
    double gainDbAt(double freqHz) const;

    bool covers(double lowHz, double highHz) const;

    // Apply the calibration to a measured magnitude curve.  The file describes
    // the microphone's own deviation, so the correction is a subtraction.
    void applyTo(const std::vector<double>& freqsHz, std::vector<double>& magnitudesDb) const;
};

struct CalibrationParseResult {
    MicCalibration calibration;
    // Empty on success.  Human-readable and safe to show in the UI.
    std::string error;
    // Non-fatal observations worth surfacing: dropped rows, reordering,
    // duplicate frequencies.  A file that needed repairs still parsed, but the
    // user should know what was done to it.
    std::vector<std::string> warnings;

    bool ok() const { return error.empty(); }
};

// Parse from file contents.  Never throws; failures come back in `error`.
CalibrationParseResult parseCalibration(const std::string& contents);

}  // namespace dspi_rc
