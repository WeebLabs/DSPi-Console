// Calibration parser tests.
//
// Real calibration files are hand-edited, vendor-generated and inconsistent,
// so these fixtures are modelled on the variants actually encountered rather
// than on an idealized grammar: UMIK sensitivity headers, tab and comma
// separators, comment markers nobody agreed on, optional phase columns, and
// files that are simply broken.
#include <string>

#include <cmath>

#include "dspi_rc/calibration.hpp"
#include "testing.hpp"

using namespace dspi_rc;

namespace {

// A UMIK-1 file as miniDSP actually ships it.
const char* kUmikFile =
    "\"Sens Factor =-1.6690dB, SERNO: 7012345\"\n"
    "20.000  -0.7071\n"
    "25.000  -0.5423\n"
    "31.500  -0.3912\n"
    "1000.000 0.0000\n"
    "10000.000 1.2345\n"
    "20000.000 -2.5000\n";

}  // namespace

TEST_CASE(parses_a_umik_file) {
    const CalibrationParseResult result = parseCalibration(kUmikFile);
    CHECK(result.ok());
    CHECK(result.calibration.points.size() == 6u);
    CHECK(result.calibration.hasSensitivity);
    CHECK_NEAR(result.calibration.sensitivityDb, -1.6690, 1e-6);
    CHECK(result.calibration.serial == "7012345");
    CHECK_NEAR(result.calibration.minFreqHz(), 20.0, 1e-9);
    CHECK_NEAR(result.calibration.maxFreqHz(), 20000.0, 1e-9);
}

TEST_CASE(accepts_tab_comma_and_semicolon_separators) {
    const CalibrationParseResult tabs = parseCalibration("20\t1.0\n100\t2.0\n");
    CHECK(tabs.ok());
    CHECK(tabs.calibration.points.size() == 2u);

    const CalibrationParseResult commas = parseCalibration("20,1.0\n100,2.0\n");
    CHECK(commas.ok());
    CHECK(commas.calibration.points.size() == 2u);

    const CalibrationParseResult semis = parseCalibration("20;1.0\n100;2.0\n");
    CHECK(semis.ok());
    CHECK(semis.calibration.points.size() == 2u);
}

TEST_CASE(ignores_comment_and_header_lines_whatever_the_marker) {
    const CalibrationParseResult result = parseCalibration(
        "* miniDSP style comment\n"
        "# hash style comment\n"
        "// slash style comment\n"
        "Some free text nobody planned for\n"
        "\n"
        "20 1.0\n"
        "100 2.0\n");
    CHECK(result.ok());
    CHECK(result.calibration.points.size() == 2u);
}

TEST_CASE(reads_an_optional_phase_column) {
    const CalibrationParseResult result = parseCalibration(
        "20 1.0 -12.5\n"
        "100 2.0 7.25\n");
    CHECK(result.ok());
    CHECK(result.calibration.points[0].hasPhase);
    CHECK_NEAR(result.calibration.points[0].phaseDegrees, -12.5, 1e-9);
    CHECK(result.calibration.points[1].hasPhase);
    CHECK_NEAR(result.calibration.points[1].phaseDegrees, 7.25, 1e-9);
}

TEST_CASE(rejects_a_file_with_too_few_points) {
    CHECK(!parseCalibration("").ok());
    CHECK(!parseCalibration("only text, no numbers\n").ok());
    CHECK(!parseCalibration("1000 0.0\n").ok());
}

TEST_CASE(rejects_a_file_whose_rows_are_all_malformed) {
    // The failure mode this guards: a permissive parser turning a corrupt file
    // into two junk points and reporting success.
    const CalibrationParseResult result = parseCalibration(
        "20\n"
        "100\n"
        "200\n");
    CHECK(!result.ok());
}

TEST_CASE(sorts_out_of_order_rows_and_says_so) {
    const CalibrationParseResult result = parseCalibration(
        "1000 3.0\n"
        "20 1.0\n"
        "100 2.0\n");
    CHECK(result.ok());
    CHECK(result.calibration.points.size() == 3u);
    CHECK_NEAR(result.calibration.points[0].freqHz, 20.0, 1e-9);
    CHECK_NEAR(result.calibration.points[2].freqHz, 1000.0, 1e-9);
    CHECK(!result.warnings.empty());
}

TEST_CASE(removes_duplicate_frequencies_and_says_so) {
    const CalibrationParseResult result = parseCalibration(
        "20 1.0\n"
        "20 1.5\n"
        "100 2.0\n");
    CHECK(result.ok());
    CHECK(result.calibration.points.size() == 2u);
    CHECK(!result.warnings.empty());
}

TEST_CASE(reports_but_survives_partially_malformed_rows) {
    const CalibrationParseResult result = parseCalibration(
        "20 1.0\n"
        "50 notanumber\n"
        "100 2.0\n");
    CHECK(result.ok());
    CHECK(result.calibration.points.size() == 2u);
    CHECK(!result.warnings.empty());
}

TEST_CASE(rejects_nonpositive_frequencies) {
    const CalibrationParseResult result = parseCalibration(
        "0 1.0\n"
        "-20 1.0\n"
        "100 2.0\n"
        "200 3.0\n");
    CHECK(result.ok());
    CHECK(result.calibration.points.size() == 2u);
}

// ---------------------------------------------------------------------------
// Interpolation and application
// ---------------------------------------------------------------------------

TEST_CASE(interpolates_on_log_frequency) {
    // Two points an octave apart: the midpoint in log frequency is the
    // geometric mean, not the arithmetic mean.  Linear-in-Hz interpolation
    // would put the halfway value at 150 Hz instead of ~141.4 Hz.
    const CalibrationParseResult result = parseCalibration("100 0.0\n200 4.0\n");
    CHECK(result.ok());
    const MicCalibration& cal = result.calibration;
    CHECK_NEAR(cal.gainDbAt(100.0), 0.0, 1e-9);
    CHECK_NEAR(cal.gainDbAt(200.0), 4.0, 1e-9);
    CHECK_NEAR(cal.gainDbAt(std::sqrt(100.0 * 200.0)), 2.0, 1e-9);
    CHECK(cal.gainDbAt(150.0) > 2.0);  // above the geometric midpoint
}

TEST_CASE(holds_endpoints_instead_of_extrapolating) {
    // Extrapolation invents correction where the vendor measured none, and the
    // error grows without bound exactly where the mic is least trustworthy.
    const CalibrationParseResult result = parseCalibration("100 -3.0\n1000 5.0\n");
    const MicCalibration& cal = result.calibration;
    CHECK_NEAR(cal.gainDbAt(10.0), -3.0, 1e-9);
    CHECK_NEAR(cal.gainDbAt(1.0), -3.0, 1e-9);
    CHECK_NEAR(cal.gainDbAt(20000.0), 5.0, 1e-9);
}

TEST_CASE(coverage_reports_whether_the_file_spans_the_analysis_range) {
    const CalibrationParseResult result = parseCalibration("20 0.0\n20000 0.0\n");
    const MicCalibration& cal = result.calibration;
    CHECK(cal.covers(20.0, 20000.0));
    CHECK(cal.covers(50.0, 10000.0));
    CHECK(!cal.covers(10.0, 20000.0));
    CHECK(!cal.covers(20.0, 24000.0));
}

TEST_CASE(application_subtracts_the_microphone_response) {
    // The file describes the microphone's own deviation, so a mic that reads
    // 3 dB hot at 1 kHz must pull the measurement 3 dB down.
    const CalibrationParseResult result = parseCalibration("100 0.0\n1000 3.0\n10000 0.0\n");
    const MicCalibration& cal = result.calibration;

    const std::vector<double> freqs{100.0, 1000.0, 10000.0};
    std::vector<double> magnitudes{80.0, 80.0, 80.0};
    cal.applyTo(freqs, magnitudes);

    CHECK_NEAR(magnitudes[0], 80.0, 1e-9);
    CHECK_NEAR(magnitudes[1], 77.0, 1e-9);
    CHECK_NEAR(magnitudes[2], 80.0, 1e-9);
}

TEST_CASE(application_is_a_no_op_for_an_empty_calibration) {
    const MicCalibration cal;
    const std::vector<double> freqs{100.0, 1000.0};
    std::vector<double> magnitudes{80.0, 81.0};
    cal.applyTo(freqs, magnitudes);
    CHECK_NEAR(magnitudes[0], 80.0, 1e-12);
    CHECK_NEAR(magnitudes[1], 81.0, 1e-12);
    CHECK_NEAR(cal.gainDbAt(1000.0), 0.0, 1e-12);
}

TEST_CASE(application_tolerates_mismatched_vector_lengths) {
    const CalibrationParseResult result = parseCalibration("100 1.0\n1000 1.0\n");
    const std::vector<double> freqs{100.0, 1000.0, 5000.0};
    std::vector<double> magnitudes{80.0, 80.0};
    result.calibration.applyTo(freqs, magnitudes);
    CHECK(magnitudes.size() == 2u);
    CHECK_NEAR(magnitudes[0], 79.0, 1e-9);
}

TEST_CASE(serial_is_stripped_of_wrapping_punctuation) {
    // UMIK files quote the entire header line, so a naive parse stores the
    // closing quote as part of the serial and then it appears in the UI.
    const CalibrationParseResult quoted =
        parseCalibration("\"Sens Factor =-1.0dB, SERNO: 1234\"\n20 0\n100 0\n");
    CHECK(quoted.calibration.serial == "1234");

    const CalibrationParseResult bare =
        parseCalibration("Sens Factor =-1.0dB, SERNO: 5678\n20 0\n100 0\n");
    CHECK(bare.calibration.serial == "5678");
}

TEST_CASE(sensitivity_is_optional) {
    const CalibrationParseResult result = parseCalibration("100 1.0\n1000 1.0\n");
    CHECK(result.ok());
    CHECK(!result.calibration.hasSensitivity);
}
