// Command-line harness for libdspi_rc.
//
// Two purposes:
//
//   1. `corpus` runs the synthetic acceptance corpus and prints neutral
//      metrics.  This is the cross-platform determinism check: the same build
//      on macOS arm64, macOS x86_64 and Windows x64 must produce identical
//      numbers, and CI compares them.
//   2. `fit` reads measured responses from plain text and fits a correction,
//      so a real measurement can be reprocessed without the app.
//
// It deliberately goes through the C ABI rather than the C++ headers, so every
// invocation also exercises the boundary the application layer will use.  A
// break in the ABI shows up here rather than in Swift.
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "dspi_rc/capi.h"

namespace {

constexpr double kMinHz = 20.0;
constexpr double kMaxHz = 20000.0;
constexpr int kPointsPerOctave = 24;

struct Corpus {
    std::string name;
    std::vector<std::vector<double>> positions;
};

std::vector<double> gridFrequencies() {
    size_t points = 0;
    if (dspi_rc_grid_points(kMinHz, kMaxHz, kPointsPerOctave, &points) != DSPI_RC_OK) return {};
    std::vector<double> hz(points, 0.0);
    size_t written = 0;
    dspi_rc_grid_frequencies(kMinHz, kMaxHz, kPointsPerOctave, hz.data(), hz.size(), &written);
    return hz;
}

void addBump(const std::vector<double>& hz, std::vector<double>& curve,
             double centreHz, double widthOctaves, double gainDb) {
    for (size_t i = 0; i < curve.size(); ++i) {
        const double octaves = std::log2(hz[i] / centreHz);
        curve[i] += gainDb * std::exp(-0.5 * (octaves / widthOctaves) * (octaves / widthOctaves));
    }
}

void addRolloff(const std::vector<double>& hz, std::vector<double>& curve,
                double cornerHz, double order, bool low) {
    for (size_t i = 0; i < curve.size(); ++i) {
        const double ratio = low ? (cornerHz / hz[i]) : (hz[i] / cornerHz);
        if (ratio > 1.0) curve[i] -= 6.0 * order * std::log2(ratio);
    }
}

void addReflection(const std::vector<double>& hz, std::vector<double>& curve,
                   double delayMs, double amplitude) {
    for (size_t i = 0; i < curve.size(); ++i) {
        const double phase = -2.0 * M_PI * hz[i] * delayMs / 1000.0;
        const double real = 1.0 + amplitude * std::cos(phase);
        const double imag = amplitude * std::sin(phase);
        const double magnitude = std::sqrt(real * real + imag * imag);
        curve[i] += 20.0 * std::log10(std::max(1e-6, magnitude / (1.0 + amplitude)));
    }
}

std::vector<Corpus> buildCorpus(const std::vector<double>& hz) {
    const size_t n = hz.size();
    std::vector<Corpus> corpus;

    {
        Corpus scenario{"shared_room_modes", {}};
        for (int i = 0; i < 5; ++i) {
            std::vector<double> curve(n, 75.0);
            addBump(hz, curve, 48.0, 0.22, 8.0);
            addBump(hz, curve, 118.0, 0.28, 5.0);
            addBump(hz, curve, 620.0, 0.5, 2.5);
            scenario.positions.push_back(curve);
        }
        corpus.push_back(scenario);
    }
    {
        Corpus scenario{"single_seat_local_null", {}};
        for (int i = 0; i < 5; ++i) {
            std::vector<double> curve(n, 75.0);
            addBump(hz, curve, 46.0, 0.25, 5.0);
            addBump(hz, curve, 155.0, 0.3, 3.0);
            if (i == 4) addBump(hz, curve, 73.0, 0.05, -30.0);
            scenario.positions.push_back(curve);
        }
        corpus.push_back(scenario);
    }
    {
        Corpus scenario{"moving_spatial_nulls", {}};
        const double centres[] = {76.0, 88.0, 101.0, 118.0, 136.0};
        for (double centre : centres) {
            std::vector<double> curve(n, 75.0);
            addBump(hz, curve, 58.0, 0.22, 6.0);
            addBump(hz, curve, centre, 0.05, -18.0);
            scenario.positions.push_back(curve);
        }
        corpus.push_back(scenario);
    }
    {
        Corpus scenario{"single_position_rolloff", {}};
        std::vector<double> curve(n, 75.0);
        addRolloff(hz, curve, 62.0, 4.0, true);
        addRolloff(hz, curve, 17000.0, 3.0, false);
        addBump(hz, curve, 140.0, 0.3, 4.0);
        scenario.positions.push_back(curve);
        corpus.push_back(scenario);
    }
    {
        Corpus scenario{"nine_position_cancellation", {}};
        for (int p = 0; p < 9; ++p) {
            std::vector<double> curve(n, 75.0);
            addBump(hz, curve, 55.0, 0.25, 6.0);
            addReflection(hz, curve, 4.0 + 0.9 * p, 0.75);
            scenario.positions.push_back(curve);
        }
        corpus.push_back(scenario);
    }
    {
        Corpus scenario{"twentyone_position_diffuse", {}};
        for (int p = 0; p < 21; ++p) {
            std::vector<double> curve(n, 75.0);
            for (size_t i = 0; i < n; ++i) curve[i] -= 1.2 * std::log2(hz[i] / 1000.0);
            addRolloff(hz, curve, 45.0, 4.0, true);
            addBump(hz, curve, 52.0, 0.2, 7.0);
            addReflection(hz, curve, 3.0 + 0.55 * p, 0.6);
            scenario.positions.push_back(curve);
        }
        corpus.push_back(scenario);
    }
    return corpus;
}

// Read "frequency  level" rows, interpolate onto the session grid.
bool readResponse(const std::string& path, const std::vector<double>& hz,
                  std::vector<double>& out) {
    std::ifstream file(path);
    if (!file) { std::fprintf(stderr, "cannot open %s\n", path.c_str()); return false; }

    std::vector<double> fileHz;
    std::vector<double> fileDb;
    std::string line;
    while (std::getline(file, line)) {
        std::istringstream stream(line);
        double f = 0.0;
        double db = 0.0;
        if (!(stream >> f >> db)) continue;   // skip headers and comments
        if (f <= 0.0) continue;
        fileHz.push_back(f);
        fileDb.push_back(db);
    }
    if (fileHz.size() < 2) {
        std::fprintf(stderr, "%s: need at least two data rows\n", path.c_str());
        return false;
    }

    out.assign(hz.size(), 0.0);
    for (size_t i = 0; i < hz.size(); ++i) {
        const double f = hz[i];
        if (f <= fileHz.front()) { out[i] = fileDb.front(); continue; }
        if (f >= fileHz.back()) { out[i] = fileDb.back(); continue; }
        size_t k = 1;
        while (k < fileHz.size() && fileHz[k] < f) ++k;
        const double span = std::log(fileHz[k] / fileHz[k - 1]);
        const double t = span > 0.0 ? std::log(f / fileHz[k - 1]) / span : 0.0;
        out[i] = fileDb[k - 1] + t * (fileDb[k] - fileDb[k - 1]);
    }
    return true;
}

void printMetrics(const char* label, const dspi_rc_metrics& m) {
    std::printf("  %-14s rawRMSE=%7.3f relRMSE=%7.3f relMed=%6.3f p95over=%6.3f "
                "maxCorr=%7.3f minCorr=%8.3f dispBoost=%6.3f outBoost=%6.3f "
                "boostQ=%5.2f bands=%2d shelves=%d\n",
                label, m.raw_worst_position_rmse_db, m.reliable_worst_position_rmse_db,
                m.reliable_median_abs_error_db, m.p95_positive_overshoot_db,
                m.max_combined_correction_db, m.min_combined_correction_db,
                m.max_disputed_boost_db, m.max_outside_native_boost_db,
                m.max_boost_filter_q, m.active_filter_count, m.shelf_filter_count);
}

int runOne(const Corpus& scenario, bool advancedBoost, bool verbose, bool& gatesPassed) {
    dspi_rc_session* session = dspi_rc_session_create(
        kMinHz, kMaxHz, kPointsPerOctave, 48000.0, DSPI_RC_PLATFORM_RP2350);
    if (!session) {
        std::fprintf(stderr, "session create failed: %s\n", dspi_rc_last_error());
        return 1;
    }

    for (size_t i = 0; i < scenario.positions.size(); ++i) {
        const double weight = (i == 0) ? 2.0 : 1.0;
        if (dspi_rc_session_add_position(session, scenario.positions[i].data(),
                                         scenario.positions[i].size(), weight, 1) != DSPI_RC_OK) {
            std::fprintf(stderr, "add position failed: %s\n", dspi_rc_last_error());
            dspi_rc_session_free(session);
            return 1;
        }
    }

    dspi_rc_target_spec target;
    dspi_rc_target_preset(1, &target);   // natural
    if (dspi_rc_session_set_target(session, &target, 1) != DSPI_RC_OK) {
        std::fprintf(stderr, "set target failed: %s\n", dspi_rc_last_error());
        dspi_rc_session_free(session);
        return 1;
    }

    dspi_rc_fit_config config;
    dspi_rc_default_fit_config(&config);
    if (advancedBoost) {
        config.boost_limit_db = 3.0;
        config.combined_ceiling_db = 3.0;
    }

    if (dspi_rc_session_fit(session, &config) != DSPI_RC_OK) {
        std::fprintf(stderr, "fit failed: %s\n", dspi_rc_last_error());
        dspi_rc_session_free(session);
        return 1;
    }

    dspi_rc_metrics fitted;
    dspi_rc_metrics uncorrected;
    dspi_rc_session_metrics(session, &fitted);
    dspi_rc_session_uncorrected_metrics(session, &uncorrected);

    double trim = 0.0;
    double transition = 0.0;
    int estimated = 0;
    dspi_rc_session_trim_db(session, &trim);
    dspi_rc_session_transition_hz(session, &transition, &estimated);

    const double improvement =
        uncorrected.reliable_worst_position_rmse_db > 0.0
            ? 100.0 * (uncorrected.reliable_worst_position_rmse_db -
                       fitted.reliable_worst_position_rmse_db) /
                  uncorrected.reliable_worst_position_rmse_db
            : 0.0;

    std::printf("%s  (%zu positions, transition %.0f Hz%s, trim %.2f dB, improvement %.1f%%)\n",
                scenario.name.c_str(), scenario.positions.size(), transition,
                estimated ? "" : " fallback", trim, improvement);
    printMetrics("uncorrected", uncorrected);
    printMetrics("corrected", fitted);

    // Safety gates.  These are the ones Milestone 0 established as hard
    // requirements; error improvement is reported but is not a gate on the
    // cancellation-dominated fixtures, where magnitude EQ genuinely cannot do
    // much.
    struct Gate { const char* name; bool ok; };
    const double ceiling = advancedBoost ? 3.0 : -0.5;
    const Gate gates[] = {
        {"combined ceiling", fitted.max_combined_correction_db <= ceiling + 1e-6},
        {"no disputed boost", fitted.max_disputed_boost_db <= 0.5 + 1e-6},
        {"no out-of-band boost", fitted.max_outside_native_boost_db <= 0.5 + 1e-6},
        {"boost Q limited", fitted.max_boost_filter_q <= config.max_boost_q + 0.01},
        {"bands within budget", fitted.active_filter_count <= config.max_filters},
        {"error not worsened",
         fitted.reliable_worst_position_rmse_db <=
             uncorrected.reliable_worst_position_rmse_db + 1e-6},
    };
    for (const Gate& gate : gates) {
        if (!gate.ok) {
            std::printf("  GATE FAILED: %s\n", gate.name);
            gatesPassed = false;
        }
    }

    if (verbose) {
        size_t count = 0;
        dspi_rc_session_filter_count(session, &count);
        std::vector<dspi_rc_filter> filters(count);
        size_t written = 0;
        if (count > 0) {
            dspi_rc_session_filters(session, filters.data(), filters.size(), &written);
        }
        for (size_t i = 0; i < count; ++i) {
            std::printf("    band %2zu  type=%2u  %8.1f Hz  Q %6.3f  %+7.3f dB\n",
                        i + 1, filters[i].type, filters[i].freq_hz, filters[i].q,
                        filters[i].gain_db);
        }
    }

    dspi_rc_session_free(session);
    return 0;
}

int commandCorpus(bool verbose) {
    const std::vector<double> hz = gridFrequencies();
    if (hz.empty()) { std::fprintf(stderr, "grid failed\n"); return 1; }

    std::printf("libdspi_rc %s\n", dspi_rc_algorithm_version());
    std::printf("grid: %.0f-%.0f Hz, %d points/octave, %zu points\n\n",
                kMinHz, kMaxHz, kPointsPerOctave, hz.size());

    bool gatesPassed = true;
    const std::vector<Corpus> corpus = buildCorpus(hz);

    std::printf("=== default (cut-only) ===\n");
    for (const Corpus& scenario : corpus) {
        if (runOne(scenario, false, verbose, gatesPassed) != 0) return 1;
    }

    std::printf("\n=== advanced boost (+3 dB permitted) ===\n");
    for (const Corpus& scenario : corpus) {
        if (runOne(scenario, true, verbose, gatesPassed) != 0) return 1;
    }

    std::printf("\n%s\n", gatesPassed ? "ALL GATES PASSED" : "GATES FAILED");
    return gatesPassed ? 0 : 1;
}

int commandFit(int argc, char** argv) {
    if (argc < 1) {
        std::fprintf(stderr, "usage: dspi_rc_cli fit <response.txt> [more.txt ...]\n");
        return 2;
    }
    const std::vector<double> hz = gridFrequencies();
    if (hz.empty()) return 1;

    dspi_rc_session* session = dspi_rc_session_create(
        kMinHz, kMaxHz, kPointsPerOctave, 48000.0, DSPI_RC_PLATFORM_RP2350);
    if (!session) { std::fprintf(stderr, "%s\n", dspi_rc_last_error()); return 1; }

    for (int i = 0; i < argc; ++i) {
        std::vector<double> response;
        if (!readResponse(argv[i], hz, response)) { dspi_rc_session_free(session); return 1; }
        const double weight = (i == 0) ? 2.0 : 1.0;
        if (dspi_rc_session_add_position(session, response.data(), response.size(),
                                         weight, 1) != DSPI_RC_OK) {
            std::fprintf(stderr, "%s\n", dspi_rc_last_error());
            dspi_rc_session_free(session);
            return 1;
        }
        std::printf("loaded %s\n", argv[i]);
    }

    dspi_rc_target_spec target;
    dspi_rc_target_preset(1, &target);
    if (dspi_rc_session_set_target(session, &target, 1) != DSPI_RC_OK ||
        dspi_rc_session_fit(session, nullptr) != DSPI_RC_OK) {
        std::fprintf(stderr, "%s\n", dspi_rc_last_error());
        dspi_rc_session_free(session);
        return 1;
    }

    size_t count = 0;
    dspi_rc_session_filter_count(session, &count);
    std::vector<dspi_rc_filter> filters(count);
    size_t written = 0;
    if (count > 0) dspi_rc_session_filters(session, filters.data(), filters.size(), &written);

    double trim = 0.0;
    dspi_rc_session_trim_db(session, &trim);

    std::printf("\nPreamp %+.1f dB\n", trim);
    for (size_t i = 0; i < count; ++i) {
        const char* label = filters[i].type == 2 ? "LS" : (filters[i].type == 3 ? "HS" : "PK");
        std::printf("Filter %2zu: ON  %s  Fc %8.1f Hz  Gain %+6.2f dB  Q %5.3f\n",
                    i + 1, label, filters[i].freq_hz, filters[i].gain_db, filters[i].q);
    }

    dspi_rc_metrics fitted;
    dspi_rc_metrics uncorrected;
    dspi_rc_session_metrics(session, &fitted);
    dspi_rc_session_uncorrected_metrics(session, &uncorrected);
    std::printf("\n");
    printMetrics("uncorrected", uncorrected);
    printMetrics("corrected", fitted);

    dspi_rc_session_free(session);
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    bool verbose = false;
    std::vector<char*> arguments;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "-v") == 0 || std::strcmp(argv[i], "--verbose") == 0) {
            verbose = true;
        } else {
            arguments.push_back(argv[i]);
        }
    }

    if (arguments.empty() || std::strcmp(arguments[0], "corpus") == 0) {
        return commandCorpus(verbose);
    }
    if (std::strcmp(arguments[0], "fit") == 0) {
        return commandFit(static_cast<int>(arguments.size()) - 1, arguments.data() + 1);
    }

    std::fprintf(stderr,
                 "usage:\n"
                 "  dspi_rc_cli [corpus] [-v]        run the acceptance corpus\n"
                 "  dspi_rc_cli fit <file> [file...] fit measured responses\n");
    return 2;
}
