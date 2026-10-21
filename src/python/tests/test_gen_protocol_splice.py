"""Pure math tests for gen_protocol.py's splice functions (no generator, no
threading, no I/O beyond numpy arrays). These encode the P0-A verdict this
lane was told to implement (docs/evidence/p0a-repaint.md sections 1/6/9):
outside a spliced region must be bit-exact, fades sit INSIDE the region,
equal-power (constant loudness) crossfade, and the stem-scope null-preserve
guarantee for unscoped stems.
"""
from __future__ import annotations

import numpy as np
import pytest

import majik_backend.gen_protocol as gp


class TestEqualPowerCurves:
    def test_zero_length(self):
        fi, fo = gp.equal_power_curves(0)
        assert fi.shape == (0,)
        assert fo.shape == (0,)

    def test_constant_power(self):
        fi, fo = gp.equal_power_curves(100)
        assert np.allclose(fi ** 2 + fo ** 2, 1.0)

    def test_monotonic(self):
        fi, fo = gp.equal_power_curves(50)
        assert np.all(np.diff(fi) > 0)  # fade_in rises
        assert np.all(np.diff(fo) < 0)  # fade_out falls

    def test_never_exactly_zero_or_one(self):
        # Bin-centered sampling: neither endpoint hits a hard 0/1, which
        # avoids a true instantaneous silence/full-volume sample at the
        # fade boundary.
        fi, fo = gp.equal_power_curves(10)
        assert np.all(fi > 0) and np.all(fi < 1)
        assert np.all(fo > 0) and np.all(fo < 1)


class TestSpliceRegion:
    def _ramp(self, n, channels=1):
        return np.tile(np.linspace(0, 1, n).reshape(-1, 1), (1, channels)).astype(np.float64)

    def test_outside_region_bit_exact(self):
        orig = self._ramp(1000)
        replacement = -self._ramp(1000)[300:600]
        out = gp.splice_region(orig, replacement, 300, 600, fade_samples=15)
        assert np.array_equal(out[:300], orig[:300])
        assert np.array_equal(out[600:], orig[600:])

    def test_mid_region_equals_replacement_away_from_fades(self):
        orig = self._ramp(1000)
        replacement = -self._ramp(1000)[300:600]
        out = gp.splice_region(orig, replacement, 300, 600, fade_samples=15)
        assert np.allclose(out[320:580], replacement[20:-20])

    def test_hard_cut_when_fade_samples_zero(self):
        orig = self._ramp(1000)
        replacement = -self._ramp(1000)[300:600]
        out = gp.splice_region(orig, replacement, 300, 600, fade_samples=0)
        assert np.array_equal(out[300:600], replacement)

    def test_two_dimensional_stereo_shape_preserved(self):
        orig = self._ramp(1000, channels=2)
        replacement = -self._ramp(1000, channels=2)[300:600]
        out = gp.splice_region(orig, replacement, 300, 600, fade_samples=10)
        assert out.shape == (1000, 2)

    def test_fade_longer_than_half_region_is_clamped_not_rejected(self):
        orig = self._ramp(1000)
        replacement = -self._ramp(1000)[300:320]  # 20-sample region
        # fade_samples=100 requested on a 20-sample region: must clamp to
        # region_len // 2, not raise or read out of bounds.
        out = gp.splice_region(orig, replacement, 300, 320, fade_samples=100)
        assert out.shape == orig.shape

    def test_invalid_region_raises(self):
        orig = self._ramp(100)
        replacement = self._ramp(100)[10:20]
        with pytest.raises(ValueError):
            gp.splice_region(orig, replacement, 20, 10, fade_samples=2)  # end before start
        with pytest.raises(ValueError):
            gp.splice_region(orig, replacement, 90, 200, fade_samples=2)  # past the end

    def test_wrong_length_replacement_raises(self):
        orig = self._ramp(100)
        with pytest.raises(ValueError):
            gp.splice_region(orig, self._ramp(5), 10, 20, fade_samples=2)  # needs 10 frames, got 5

    def test_null_test_matches_p0a_never_silence_finding(self):
        # P0-A section 5: raw repaint residual outside the region is never
        # silence (median ~-21 dBFS, range -12.5..-29.9). The splice's job
        # is to make it EXACTLY silent (bit-identical), which is a stronger
        # guarantee than "close": assert the residual is truly zero, not
        # just small.
        orig = self._ramp(1000)
        replacement = -self._ramp(1000)[300:600]
        out = gp.splice_region(orig, replacement, 300, 600, fade_samples=15)
        residual_outside = np.concatenate([out[:300] - orig[:300], out[600:] - orig[600:]])
        assert np.max(np.abs(residual_outside)) == 0.0


class TestSpliceOpenTail:
    def test_tail_is_bit_exact(self):
        orig = np.linspace(0, 1, 500).reshape(-1, 1)
        tail = np.linspace(0, 1, 200).reshape(-1, 1) + 5.0
        extended = np.concatenate([orig * 3, tail], axis=0)  # head rewritten, real tail
        out = gp.splice_open_tail(orig, extended, join_at=500, fade_samples=10)
        assert out.shape[0] == 700
        assert np.array_equal(out[500:], extended[500:])

    def test_head_bit_exact_before_the_fade_zone(self):
        orig = np.linspace(0, 1, 500).reshape(-1, 1)
        extended = np.concatenate([orig * 3, np.zeros((200, 1))], axis=0)
        out = gp.splice_open_tail(orig, extended, join_at=500, fade_samples=10)
        assert np.array_equal(out[:490], orig[:490])

    def test_invalid_join_raises(self):
        orig = np.zeros((100, 1))
        extended = np.zeros((150, 1))
        with pytest.raises(ValueError):
            gp.splice_open_tail(orig, extended, join_at=0, fade_samples=1)
        with pytest.raises(ValueError):
            gp.splice_open_tail(orig, extended, join_at=200, fade_samples=1)

    def test_extended_shorter_than_join_raises(self):
        orig = np.zeros((100, 1))
        extended = np.zeros((50, 1))
        with pytest.raises(ValueError):
            gp.splice_open_tail(orig, extended, join_at=100, fade_samples=1)


class TestStemRecombine:
    def _stems(self, n=200, values=(1, 2, 3, 4)):
        names = ["vocals", "drums", "bass", "other"]
        return {name: np.full((n, 1), v, dtype=np.float64) for name, v in zip(names, values)}

    def test_unscoped_stems_pass_through_untouched_everywhere(self):
        orig = self._stems(values=(1, 2, 3, 4))
        new_region = {name: np.full((40, 1), 99.0) for name in orig}
        mix, out = gp.stem_recombine(orig, new_region, ["drums"], 80, 120, fade_samples=5)
        for name in ("vocals", "bass", "other"):
            assert np.array_equal(out[name], orig[name])

    def test_scoped_stem_region_is_null_preserved_outside(self):
        orig = self._stems()
        new_region = {name: np.full((40, 1), 99.0) for name in orig}
        mix, out = gp.stem_recombine(orig, new_region, ["drums"], 80, 120, fade_samples=5)
        assert np.array_equal(out["drums"][:75], orig["drums"][:75])
        assert np.array_equal(out["drums"][125:], orig["drums"][125:])
        assert np.allclose(out["drums"][90:110], 99.0)

    def test_mix_is_sum_of_output_stems(self):
        orig = self._stems()
        new_region = {name: np.full((40, 1), 99.0) for name in orig}
        mix, out = gp.stem_recombine(orig, new_region, ["drums", "bass"], 80, 120, fade_samples=5)
        expected = sum(out.values())
        assert np.allclose(mix, expected)

    def test_unknown_scoped_stem_raises(self):
        orig = self._stems()
        new_region = {name: np.full((40, 1), 1.0) for name in orig}
        with pytest.raises(ValueError):
            gp.stem_recombine(orig, new_region, ["synth"], 80, 120, fade_samples=5)

    def test_missing_replacement_stem_raises(self):
        orig = self._stems()
        new_region = {"vocals": np.full((40, 1), 1.0)}  # missing drums
        with pytest.raises(ValueError):
            gp.stem_recombine(orig, new_region, ["drums"], 80, 120, fade_samples=5)


class TestBlake3:
    def test_pure_matches_compiled_when_available(self):
        try:
            import blake3 as compiled  # noqa: PLC0415
        except ImportError:
            pytest.skip("compiled blake3 package not installed in this environment")
        for data in (b"", b"x", b"a" * 1023, b"b" * 1024, b"c" * 1025, b"d" * 65537):
            assert gp._blake3_hex_pure(data) == compiled.blake3(data).hexdigest()

    def test_hex_shape_matches_asset_hash_pattern(self):
        import re  # noqa: PLC0415
        digest = gp.blake3_hex(b"hello gen protocol")
        assert re.match(r"^[0-9a-f]{64}$", digest)

    def test_of_file(self, tmp_path):
        p = tmp_path / "x.bin"
        p.write_bytes(b"hello file hashing")
        assert gp.blake3_hex_of_file(str(p)) == gp.blake3_hex(b"hello file hashing")

    def test_deterministic(self):
        assert gp.blake3_hex(b"same input") == gp.blake3_hex(b"same input")

    def test_different_input_different_hash(self):
        assert gp.blake3_hex(b"a") != gp.blake3_hex(b"b")
