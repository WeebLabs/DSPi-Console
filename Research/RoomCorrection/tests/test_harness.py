from __future__ import annotations

from dataclasses import replace
from pathlib import Path
import sys
import tempfile
import unittest

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from room_correction.fixtures import load_corpus
from room_correction.model import (
    ParametricEQ,
    filter_response_db,
    firmware_filter_response_db,
    log_frequency_grid,
    quantize_filter_recipe,
)
from room_correction.optimizer import (
    FitConfig,
    evaluate_fixed_filters,
    fit_variant,
    spatial_statistics,
)
from room_correction.rew import read_rew_magnitude, write_rew_magnitude
from room_correction.sweep import generate_firmware_log_sweep


class FirmwareSweepTests(unittest.TestCase):
    def test_phase_law_and_edges_are_deterministic(self) -> None:
        sweep = generate_firmware_log_sweep(
            48_000,
            20.0,
            20_000.0,
            duration_milliseconds=100,
            block_samples=192,
        )
        self.assertEqual(sweep.duration_samples, 4_800)
        self.assertEqual(sweep.fade_samples, 240)
        self.assertEqual(sweep.increment_start_q48, 117_281_240_296)
        self.assertEqual(sweep.epsilon_q31, 3_090_477)
        self.assertEqual(int(sweep.phase_q48[0]), sweep.increment_start_q48)
        self.assertAlmostEqual(float(sweep.envelope[0]), 0.0)
        self.assertGreater(float(sweep.envelope[239]), 0.98)
        self.assertAlmostEqual(float(sweep.envelope[-1]), 1.0 / 240.0, places=7)

    def test_room_correction_rejects_unknown_sample_rate(self) -> None:
        with self.assertRaises(ValueError):
            generate_firmware_log_sweep(88_200)

    def test_generator_capability_limit_precedes_nyquist_limit(self) -> None:
        sweep = generate_firmware_log_sweep(
            96_000,
            end_hz=50_000.0,
            duration_milliseconds=10,
        )
        self.assertEqual(sweep.effective_end_hz, 40_000.0)

    def test_five_second_reference_trace_is_frozen_at_supported_rates(self) -> None:
        expected = {
            44_100: (220_500, 220, 127_653_050_662, 126_634_014_322_331, 67_199),
            48_000: (240_000, 240, 117_281_240_296, 117_258_976_199_747, 61_809),
            96_000: (480_000, 480, 58_640_620_148, 58_626_651_300_312, 30_904),
        }
        for sample_rate, values in expected.items():
            with self.subTest(sample_rate=sample_rate):
                sweep = generate_firmware_log_sweep(
                    sample_rate,
                    duration_milliseconds=5_000,
                )
                self.assertEqual(
                    (
                        sweep.duration_samples,
                        sweep.fade_samples,
                        sweep.increment_start_q48,
                        sweep.increment_end_q48,
                        sweep.epsilon_q31,
                    ),
                    values,
                )


class FirmwareFilterModelTests(unittest.TestCase):
    def test_grid_is_96_points_per_octave(self) -> None:
        frequencies = log_frequency_grid(points_per_octave=96)
        spacing = np.diff(np.log2(frequencies[:-1]))
        np.testing.assert_allclose(spacing, 1.0 / 96.0, atol=1.0e-12)

    def test_low_and_high_shelves_have_expected_asymptotes(self) -> None:
        frequencies = np.asarray([20.0, 20_000.0])
        low = filter_response_db(
            frequencies,
            48_000,
            ParametricEQ(1_000.0, 0.707, 4.0, "low_shelf"),
        )
        high = filter_response_db(
            frequencies,
            48_000,
            ParametricEQ(1_000.0, 0.707, -3.0, "high_shelf"),
        )
        self.assertAlmostEqual(float(low[0]), 4.0, delta=0.02)
        self.assertAlmostEqual(float(low[-1]), 0.0, delta=0.02)
        self.assertAlmostEqual(float(high[0]), 0.0, delta=0.02)
        self.assertAlmostEqual(float(high[-1]), -3.0, delta=0.02)

    def test_console_and_firmware_recipe_quantization_is_pinned(self) -> None:
        quantized = quantize_filter_recipe(
            ParametricEQ(4.0, 25.0, 1.25), 48_000
        )
        self.assertEqual(quantized.frequency_hz, 10.0)
        self.assertEqual(quantized.q, 20.0)
        self.assertAlmostEqual(quantized.gain_db, 1.3, places=6)
        negative = quantize_filter_recipe(
            ParametricEQ(1_000.123, 1.234, -1.25), 48_000
        )
        self.assertAlmostEqual(negative.gain_db, -1.3, places=6)
        self.assertEqual(negative.frequency_hz, float(np.float32(1_000.123)))

    def test_ordinary_rp2040_and_rp2350_coefficient_magnitudes_are_close(self) -> None:
        frequencies = log_frequency_grid()
        item = quantize_filter_recipe(
            ParametricEQ(47.3, 1.91, -7.4), 48_000
        )
        rp2350 = firmware_filter_response_db(
            frequencies, 48_000, item, "rp2350"
        )
        rp2040 = firmware_filter_response_db(
            frequencies, 48_000, item, "rp2040"
        )
        self.assertLess(float(np.max(np.abs(rp2350 - rp2040))), 0.02)

    def test_rp2040_model_exposes_sensitive_low_frequency_q28_case(self) -> None:
        frequencies = log_frequency_grid()
        item = quantize_filter_recipe(
            ParametricEQ(25.0, 10.0, -12.0), 48_000
        )
        rp2350 = firmware_filter_response_db(
            frequencies, 48_000, item, "rp2350"
        )
        rp2040 = firmware_filter_response_db(
            frequencies, 48_000, item, "rp2040"
        )
        self.assertGreater(float(np.max(np.abs(rp2350 - rp2040))), 0.1)


class CorpusTests(unittest.TestCase):
    def test_corpus_is_deterministic_diverse_and_weighted(self) -> None:
        path = ROOT / "fixtures" / "corpus.json"
        first = load_corpus(path)
        second = load_corpus(path)
        self.assertEqual(len(first.scenarios), 8)
        self.assertEqual(
            {item.measurements_db.shape[0] for item in first.scenarios},
            {1, 3, 5, 9, 21},
        )
        self.assertEqual(
            {item.sample_rate_hz for item in first.scenarios},
            {44_100, 48_000, 96_000},
        )
        self.assertTrue(any(np.ptp(item.target_db) > 1.0 for item in first.scenarios))
        self.assertTrue(any(item.native_band_hz is not None for item in first.scenarios))
        self.assertTrue(all("rbj" not in item.source_model for item in first.scenarios))
        for left, right in zip(first.scenarios, second.scenarios):
            np.testing.assert_array_equal(left.measurements_db, right.measurements_db)
            self.assertAlmostEqual(float(np.sum(left.position_weights)), 1.0)
            self.assertGreaterEqual(left.frequencies_hz.size, 958)

    def test_rew_compatible_text_fixture(self) -> None:
        frequencies, magnitude = read_rew_magnitude(
            ROOT / "fixtures" / "rew_example.txt"
        )
        self.assertEqual(frequencies.size, 10)
        self.assertEqual(float(frequencies[0]), 20.0)
        self.assertEqual(float(magnitude[2]), 4.0)

    def test_rew_round_trip_preserves_corpus_curve(self) -> None:
        scenario = load_corpus(ROOT / "fixtures" / "corpus.json").scenarios[0]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "measurement.txt"
            write_rew_magnitude(
                path,
                scenario.frequencies_hz,
                scenario.measurements_db[0],
                "round trip",
            )
            frequencies, magnitude = read_rew_magnitude(path)
        np.testing.assert_allclose(frequencies, scenario.frequencies_hz, atol=5.0e-7)
        np.testing.assert_allclose(magnitude, scenario.measurements_db[0], atol=5.0e-7)


class OptimizerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.corpus = load_corpus(ROOT / "fixtures" / "corpus.json")
        cls.local_null = cls.corpus.named("single_seat_local_null")

    def test_spatial_statistics_mark_local_null_unreliable(self) -> None:
        stats = spatial_statistics(self.local_null)
        index = int(np.argmin(np.abs(self.local_null.frequencies_hz - 73.0)))
        self.assertLess(float(stats.sign_agreement[index]), 0.35)
        self.assertLess(float(stats.reliability[index]), 0.35)

    def test_default_gate_uses_the_hardware_band_count(self) -> None:
        config = FitConfig()
        self.assertEqual(config.filter_count, 10)
        self.assertEqual(config.max_iterations, 400)

    def test_single_position_uses_transition_fallback(self) -> None:
        single_position = replace(
            self.local_null,
            measurements_db=self.local_null.measurements_db[:1],
            position_weights=np.asarray([1.0]),
        )
        self.assertEqual(
            spatial_statistics(single_position).transition_frequency_hz,
            200.0,
        )

    def test_equal_start_ablation_separates_spatial_and_hygiene_effects(self) -> None:
        config = FitConfig(
            filter_count=4,
            max_iterations=80,
            deterministic_starts=2,
            combined_correction_ceiling_db=3.0,
            positive_correction_weight=0.15,
        )
        fits = {
            variant: fit_variant(self.local_null, variant, config, "SLSQP")
            for variant in (
                "arithmetic_plain",
                "arithmetic_hygiene",
                "spatial_plain",
                "spatial_hygiene",
            )
        }
        self.assertTrue(all(item.starts == 2 for item in fits.values()))
        probe = {
            key: item.neutral_metrics["probe_0_max_correction_db"]
            for key, item in fits.items()
        }
        self.assertGreater(probe["arithmetic_plain"], 2.0)
        self.assertLess(probe["arithmetic_hygiene"], probe["arithmetic_plain"] - 1.0)
        self.assertLess(probe["spatial_plain"], probe["arithmetic_plain"] - 1.0)
        self.assertLessEqual(probe["spatial_hygiene"], 0.5)

    def test_house_curve_uses_shelf_and_obeys_hard_safety_contracts(self) -> None:
        scenario = self.corpus.named("three_position_house_curve")
        config = FitConfig(
            filter_count=4,
            max_iterations=120,
            deterministic_starts=1,
            combined_correction_ceiling_db=3.0,
            positive_correction_weight=0.15,
        )
        result = fit_variant(scenario, "spatial_hygiene", config, "SLSQP")
        metrics = result.neutral_metrics
        self.assertGreaterEqual(metrics["shelf_filter_count"], 1.0)
        self.assertLessEqual(metrics["max_outside_native_boost_db"], 1.0e-6)
        self.assertLessEqual(metrics["max_disputed_boost_db"], 0.5 + 1.0e-6)
        self.assertLessEqual(metrics["maximum_boost_filter_q"], 2.01)
        for item in result.quantized_filters:
            self.assertAlmostEqual(item.gain_db * 10.0, round(item.gain_db * 10.0), places=5)

    def test_filter_budgets_from_one_through_ten_are_supported(self) -> None:
        scenario = self.corpus.named("shared_room_modes")
        for filter_count in range(1, 11):
            with self.subTest(filter_count=filter_count):
                result = fit_variant(
                    scenario,
                    "spatial_hygiene",
                    FitConfig(
                        filter_count=filter_count,
                        max_iterations=1,
                        deterministic_starts=1,
                    ),
                    "SLSQP",
                )
                self.assertEqual(len(result.quantized_filters), filter_count)
                self.assertTrue(np.isfinite(result.optimization_objective))

    def test_fixed_solution_is_scored_for_the_selected_platform(self) -> None:
        config = FitConfig(
            filter_count=4,
            max_iterations=100,
            deterministic_starts=1,
            combined_correction_ceiling_db=3.0,
            firmware_platform="rp2350",
        )
        primary = fit_variant(
            self.local_null, "spatial_hygiene", config, "SLSQP"
        )
        alternate = evaluate_fixed_filters(
            self.local_null,
            "spatial_hygiene",
            primary.filters,
            replace(config, firmware_platform="rp2040"),
        )
        self.assertEqual(primary.firmware_platform, "rp2350")
        self.assertEqual(alternate.firmware_platform, "rp2040")
        self.assertNotEqual(
            primary.neutral_metrics["reliability_weighted_huber_loss"],
            alternate.neutral_metrics["reliability_weighted_huber_loss"],
        )

    def test_default_mode_enforces_headroom_margin(self) -> None:
        result = fit_variant(
            self.corpus.named("shared_room_modes"),
            "spatial_hygiene",
            FitConfig(filter_count=2, max_iterations=55),
            "SLSQP",
        )
        self.assertLessEqual(
            result.neutral_metrics["max_combined_correction_db"],
            -0.5 + 1.0e-9,
        )
        self.assertLess(result.trim_db, 0.0)


if __name__ == "__main__":
    unittest.main()
