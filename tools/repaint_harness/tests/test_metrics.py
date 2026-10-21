"""Metric sanity tests. numpy + pytest only."""

import numpy as np
import pytest

from repaint_harness import metrics, splice

SR = 48000


def tone(n, freq=440.0, amp=0.5, phase=0.0):
    t = np.arange(n, dtype=np.float64) / SR
    return amp * np.sin(2 * np.pi * freq * t + phase)


class TestLevels:
    def test_rms_db_of_known_sine(self):
        y = tone(SR, amp=1.0)
        # Full-scale sine RMS is -3.01 dBFS.
        assert metrics.rms_db(y) == pytest.approx(-3.01, abs=0.05)

    def test_peak_db_of_known_sine(self):
        y = tone(SR, amp=0.5)
        assert metrics.peak_db(y) == pytest.approx(-6.02, abs=0.05)

    def test_silence_reports_floor(self):
        assert metrics.rms_db(np.zeros(1000)) == -200.0

    def test_stereo_mixdown(self):
        y = np.stack([tone(1000), tone(1000)], axis=1)
        assert metrics.rms_db(y) == pytest.approx(metrics.rms_db(tone(1000)), abs=1e-9)


class TestRmsStep:
    def test_no_step_in_steady_tone(self):
        y = tone(4 * SR)
        assert metrics.rms_step_db(y, 2 * SR, SR) < 0.1

    def test_6db_step_detected(self):
        y = np.concatenate([tone(2 * SR, amp=0.5), tone(2 * SR, amp=0.25)])
        step = metrics.rms_step_db(y, 2 * SR, SR)
        assert step == pytest.approx(6.02, abs=0.3)

    def test_window_leaving_signal_rejected(self):
        with pytest.raises(ValueError):
            metrics.rms_step_db(tone(1000), 10, SR)


class TestClickRatio:
    def test_continuous_tone_has_low_ratio(self):
        y = tone(4 * SR)
        assert metrics.click_ratio(y, 2 * SR, SR) < 3.0

    def test_hard_phase_cut_spikes_ratio(self):
        # Splice a phase-inverted tone with no fade at a peak: a real click.
        a = tone(4 * SR, phase=np.pi / 2)
        b = tone(2 * SR, phase=-np.pi / 2)
        y = splice.splice_region(a, b, 2 * SR, 4 * SR, fade_samples=0)
        assert metrics.click_ratio(y, 2 * SR, SR) > 20.0

    def test_crossfade_removes_the_click(self):
        a = tone(4 * SR, phase=np.pi / 2)
        b = tone(2 * SR, phase=-np.pi / 2)
        fade = int(0.020 * SR)
        y = splice.splice_region(a, b, 2 * SR, 4 * SR, fade_samples=fade)
        hard = splice.splice_region(a, b, 2 * SR, 4 * SR, fade_samples=0)
        assert (
            metrics.click_ratio(y, 2 * SR, SR)
            < metrics.click_ratio(hard, 2 * SR, SR) / 3
        )

    def test_boundary_bounds_checked(self):
        with pytest.raises(ValueError):
            metrics.click_ratio(tone(100), 0, SR)


class TestSpectralFlux:
    def test_splice_of_different_content_scores_high(self):
        rng = np.random.default_rng(0)
        a = tone(8 * SR, freq=220.0)
        b = (rng.standard_normal(2 * SR) * 0.2)
        y = splice.splice_region(a, b, 3 * SR, 5 * SR, fade_samples=0)
        out = metrics.spectral_flux_zscore(
            y, 3 * SR, SR, exclude=[(3 * SR, 5 * SR)], seed=1
        )
        assert out["zscore"] > 5.0
        assert out["percentile"] == 1.0

    def test_steady_signal_scores_low(self):
        y = tone(8 * SR, freq=220.0)
        out = metrics.spectral_flux_zscore(y, 3 * SR, SR, seed=1)
        assert abs(out["zscore"]) < 3.0

    def test_boundary_too_close_to_edge_rejected(self):
        with pytest.raises(ValueError):
            metrics.spectral_flux_zscore(tone(SR), 10, SR)


class TestNullResidual:
    def test_identical_signals_report_floor(self):
        y = tone(4 * SR)
        out = metrics.null_residual(y, y.copy(), exclude=[(SR, 2 * SR)])
        assert out["residual_rms_db"] == -200.0
        assert out["gain"] == pytest.approx(1.0)

    def test_known_noise_level_outside_region(self):
        rng = np.random.default_rng(5)
        a = tone(4 * SR, amp=0.5)
        noise = rng.standard_normal(4 * SR) * 1e-3  # about -60 dBFS RMS
        b = a + noise
        out = metrics.null_residual(a, b, exclude=[(SR, 2 * SR)])
        assert out["residual_rms_db"] == pytest.approx(-60.0, abs=0.5)

    def test_pure_gain_change_is_compensated(self):
        a = tone(4 * SR, amp=0.5)
        b = a * 0.7
        out = metrics.null_residual(a, b, exclude=[(SR, 2 * SR)])
        # Raw residual is loud (0.3 * a is about -19.5 dBFS here),
        # compensated residual collapses to the floor.
        assert out["residual_rms_db"] == pytest.approx(-19.5, abs=0.5)
        assert out["residual_rms_db_gain_compensated"] < -150.0
        assert out["gain"] == pytest.approx(1 / 0.7, rel=1e-6)

    def test_exclusion_hides_region_edit(self):
        a = tone(4 * SR)
        b = a.copy()
        b[SR : 2 * SR] = 0.0  # edit only inside the region
        out = metrics.null_residual(a, b, exclude=[(SR, 2 * SR)])
        assert out["residual_rms_db"] == -200.0

    def test_guard_widens_exclusion(self):
        a = tone(4 * SR)
        b = a.copy()
        b[SR - 100 : SR] = 0.0  # damage just before the region
        strict = metrics.null_residual(a, b, exclude=[(SR, 2 * SR)])
        guarded = metrics.null_residual(a, b, exclude=[(SR, 2 * SR)], guard_samples=200)
        assert strict["residual_rms_db"] > -200.0
        assert guarded["residual_rms_db"] == -200.0

    def test_length_delta_reported(self):
        a = tone(4 * SR)
        b = np.concatenate([a, np.zeros(100)])
        out = metrics.null_residual(a, b, exclude=[(SR, 2 * SR)])
        assert out["length_delta"] == 100

    def test_full_exclusion_rejected(self):
        y = tone(1000)
        with pytest.raises(ValueError):
            metrics.null_residual(y, y, exclude=[(0, 1000)])
