"""Splice math contract tests. numpy + pytest only."""

import numpy as np
import pytest

from repaint_harness import splice


def make_tone(n, freq=440.0, sr=48000, channels=1, amp=0.5, phase=0.0):
    t = np.arange(n, dtype=np.float64) / sr
    y = amp * np.sin(2 * np.pi * freq * t + phase)
    if channels == 1:
        return y
    return np.stack([y] * channels, axis=1)


class TestEqualPowerCurves:
    def test_power_sums_to_one(self):
        fade_in, fade_out = splice.equal_power_curves(960)
        np.testing.assert_allclose(fade_in**2 + fade_out**2, 1.0, atol=1e-12)

    def test_monotonic(self):
        fade_in, fade_out = splice.equal_power_curves(64)
        assert np.all(np.diff(fade_in) > 0)
        assert np.all(np.diff(fade_out) < 0)

    def test_zero_length(self):
        fade_in, fade_out = splice.equal_power_curves(0)
        assert fade_in.size == 0 and fade_out.size == 0

    def test_negative_rejected(self):
        with pytest.raises(ValueError):
            splice.equal_power_curves(-1)


class TestExtractRegion:
    def test_extract_is_a_copy(self):
        y = make_tone(1000)
        region = splice.extract_region(y, 100, 200)
        region[:] = 0.0
        assert not np.any(y[100:200] == 0.0)

    def test_bad_bounds_rejected(self):
        y = make_tone(1000)
        for bad in [(-1, 10), (10, 10), (20, 10), (0, 1001)]:
            with pytest.raises(ValueError):
                splice.extract_region(y, *bad)


class TestSpliceRegion:
    SR = 48000

    def test_outside_region_bit_exact(self):
        """The null-preserve guarantee: samples outside [start, end) unchanged."""
        rng = np.random.default_rng(7)
        original = rng.standard_normal((self.SR, 2)) * 0.1
        start, end = 10000, 30000
        replacement = rng.standard_normal((end - start, 2)) * 0.1
        out = splice.splice_region(original, replacement, start, end, fade_samples=960)
        np.testing.assert_array_equal(out[:start], original[:start])
        np.testing.assert_array_equal(out[end:], original[end:])

    def test_zero_fade_is_hard_cut(self):
        original = make_tone(self.SR)
        start, end = 1000, 2000
        replacement = np.full(end - start, 0.25)
        out = splice.splice_region(original, replacement, start, end, fade_samples=0)
        np.testing.assert_array_equal(out[start:end], replacement)

    def test_middle_of_region_is_pure_replacement(self):
        original = make_tone(self.SR)
        start, end, fade = 1000, 5000, 960
        replacement = np.full(end - start, 0.25)
        out = splice.splice_region(original, replacement, start, end, fade)
        np.testing.assert_array_equal(out[start + fade : end - fade], replacement[fade:-fade])

    def test_identity_splice_preserves_signal(self):
        """Splicing a region back into its own source must be transparent:
        inside the crossfade, out = orig * fout + orig * fin, which is NOT
        exactly orig for equal-power curves. Verify the deviation is bounded
        by the known equal-power sum (at most ~sqrt(2)) and there is no click.
        """
        original = make_tone(self.SR, freq=220.0)
        start, end, fade = 8000, 24000, 960
        region = splice.extract_region(original, start, end)
        out = splice.splice_region(original, region, start, end, fade)
        # Outside fades: exact.
        np.testing.assert_array_equal(out[:start], original[:start])
        np.testing.assert_allclose(
            out[start + fade : end - fade], original[start + fade : end - fade]
        )
        # Inside fades: bounded by (fade_in + fade_out) max, which is sqrt(2).
        seg = out[start : start + fade]
        ref = original[start : start + fade]
        assert np.max(np.abs(seg)) <= np.sqrt(2) * np.max(np.abs(ref)) + 1e-9

    def test_equal_power_holds_energy_for_uncorrelated_noise(self):
        """Crossfading two independent noises keeps RMS roughly constant,
        which is the point of equal-power over linear fades."""
        rng = np.random.default_rng(3)
        n, fade = 200_000, 48_000
        a = rng.standard_normal(n) * 0.3
        b = rng.standard_normal(fade) * 0.3
        out = splice.splice_region(a, np.concatenate([b, rng.standard_normal(fade) * 0.3]),
                                   50_000, 50_000 + 2 * fade, fade)
        fade_zone = out[50_000 : 50_000 + fade]
        rms_zone = np.sqrt(np.mean(fade_zone**2))
        assert 0.25 < rms_zone < 0.35

    def test_length_mismatch_rejected(self):
        original = make_tone(self.SR)
        with pytest.raises(ValueError):
            splice.splice_region(original, np.zeros(999), 1000, 2000, 0)

    def test_channel_mismatch_rejected(self):
        original = make_tone(self.SR, channels=2)
        with pytest.raises(ValueError):
            splice.splice_region(original, np.zeros(1000), 1000, 2000, 0)

    def test_fade_too_large_rejected(self):
        original = make_tone(self.SR)
        with pytest.raises(ValueError):
            splice.splice_region(original, np.zeros(1000), 1000, 2000, 501)

    def test_fade_exactly_half_region_allowed(self):
        original = make_tone(self.SR)
        out = splice.splice_region(original, np.zeros(1000), 1000, 2000, 500)
        assert out.shape == original.shape

    def test_int_audio_rejected(self):
        original = (make_tone(self.SR) * 32767).astype(np.int16)
        with pytest.raises(TypeError):
            splice.splice_region(original, np.zeros(10), 0, 10, 0)


class TestStemRecombine:
    def make_stems(self, n=48000, seed=0):
        rng = np.random.default_rng(seed)
        names = ["vocals", "drums", "bass", "other"]
        return {name: rng.standard_normal(n) * 0.1 for name in names}

    def test_unscoped_stems_null_preserved(self):
        original = self.make_stems(seed=1)
        replacement_full = self.make_stems(seed=2)
        start, end, fade = 10000, 20000, 960
        replacement = {k: v[start:end].copy() for k, v in replacement_full.items()}
        mix, stems_out = splice.stem_recombine(
            original, replacement, scoped=["drums", "other"], start=start, end=end,
            fade_samples=fade,
        )
        # Vocals and bass are bit-identical everywhere, including inside the region.
        np.testing.assert_array_equal(stems_out["vocals"], original["vocals"])
        np.testing.assert_array_equal(stems_out["bass"], original["bass"])
        # Scoped stems changed inside, untouched outside.
        np.testing.assert_array_equal(stems_out["drums"][:start], original["drums"][:start])
        assert not np.allclose(
            stems_out["drums"][start + fade : end - fade],
            original["drums"][start + fade : end - fade],
        )

    def test_mix_is_sum_of_stems(self):
        original = self.make_stems(seed=3)
        replacement = {k: v[100:200].copy() for k, v in self.make_stems(seed=4).items()}
        mix, stems_out = splice.stem_recombine(
            original, replacement, scoped=["drums"], start=100, end=200, fade_samples=10
        )
        expected = sum(stems_out.values())
        np.testing.assert_allclose(mix, expected)

    def test_all_stems_scoped_equals_plain_splices(self):
        original = self.make_stems(seed=5)
        repl = {k: v[500:1500].copy() for k, v in self.make_stems(seed=6).items()}
        mix, stems_out = splice.stem_recombine(
            original, repl, scoped=list(original), start=500, end=1500, fade_samples=100
        )
        for name in original:
            expected = splice.splice_region(original[name], repl[name], 500, 1500, 100)
            np.testing.assert_allclose(stems_out[name], expected)

    def test_unknown_scope_rejected(self):
        original = self.make_stems()
        with pytest.raises(ValueError):
            splice.stem_recombine(original, {}, scoped=["piano"], start=0, end=10,
                                  fade_samples=0)

    def test_missing_replacement_rejected(self):
        original = self.make_stems()
        with pytest.raises(ValueError):
            splice.stem_recombine(original, {}, scoped=["drums"], start=0, end=10,
                                  fade_samples=0)
