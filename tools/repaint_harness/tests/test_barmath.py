"""Bar math contract tests. Standard library + pytest only."""

import math

import pytest

from repaint_harness import barmath as bm


class TestBeatAndBarDurations:
    def test_seconds_per_beat_120(self):
        assert bm.seconds_per_beat(120) == 0.5

    def test_seconds_per_bar_default_four_four(self):
        assert bm.seconds_per_bar(120) == 2.0

    def test_seconds_per_bar_three_four(self):
        assert bm.seconds_per_bar(120, beats_per_bar=3) == 1.5

    def test_seconds_per_bar_six_eight_pulse(self):
        assert bm.seconds_per_bar(96, beats_per_bar=6) == pytest.approx(3.75)

    @pytest.mark.parametrize("bad", [0, -1, float("nan"), float("inf")])
    def test_bad_bpm_rejected(self, bad):
        with pytest.raises(ValueError):
            bm.seconds_per_beat(bad)

    @pytest.mark.parametrize("bad", [0, -2, 2.5])
    def test_bad_beats_per_bar_rejected(self, bad):
        with pytest.raises(ValueError):
            bm.seconds_per_bar(120, beats_per_bar=bad)


class TestBarStartsAndRegions:
    def test_bar_one_starts_at_zero(self):
        assert bm.bar_start_seconds(1, 120) == 0.0

    def test_bar_17_at_120(self):
        # 16 full bars of 2 s precede bar 17.
        assert bm.bar_start_seconds(17, 120) == 32.0

    def test_grid_offset_shifts_start(self):
        assert bm.bar_start_seconds(17, 120, grid_offset_seconds=0.25) == 32.25

    def test_region_brief_example_bars_33_48(self):
        # The brief's example: bars 33-48 at 120 bpm 4/4 -> 64 s to 96 s.
        start, end = bm.region_seconds(33, 48, 120)
        assert start == 64.0
        assert end == 96.0

    def test_region_is_inclusive_of_end_bar(self):
        start, end = bm.region_seconds(17, 24, 120)
        assert (start, end) == (32.0, 48.0)
        assert bm.bars_in_region(17, 24) == 8
        assert end - start == bm.region_duration_seconds(17, 24, 120)

    def test_single_bar_region(self):
        start, end = bm.region_seconds(5, 5, 100)
        assert start == pytest.approx(4 * 2.4)
        assert end - start == pytest.approx(2.4)

    def test_non_integer_bar_rejected(self):
        with pytest.raises(ValueError):
            bm.bar_start_seconds(1.5, 120)

    def test_zero_bar_rejected(self):
        with pytest.raises(ValueError):
            bm.bar_start_seconds(0, 120)

    def test_reversed_region_rejected(self):
        with pytest.raises(ValueError):
            bm.region_seconds(24, 17, 120)


class TestSampleConversion:
    def test_exact_sample(self):
        assert bm.seconds_to_sample(1.0, 48000) == 48000

    def test_rounds_half_up(self):
        # 0.5 sample exactly: 1.5 / 48000 s * 48000 = 1.5 -> 2
        t = 1.5 / 48000
        assert bm.seconds_to_sample(t, 48000) == 2

    def test_rounds_nearest_down(self):
        t = 1.4 / 48000
        assert bm.seconds_to_sample(t, 48000) == 1

    def test_negative_time_rejected(self):
        with pytest.raises(ValueError):
            bm.seconds_to_sample(-0.1, 48000)

    def test_bad_sample_rate_rejected(self):
        with pytest.raises(ValueError):
            bm.seconds_to_sample(1.0, 0)

    def test_region_samples_matches_seconds(self):
        s, e = bm.region_samples(17, 24, 120, 48000)
        assert (s, e) == (32 * 48000, 48 * 48000)

    def test_region_samples_at_odd_bpm_are_consistent(self):
        # 97 bpm produces non-integer bar lengths; sample bounds must still
        # be deterministic and ordered.
        s, e = bm.region_samples(13, 20, 97, 44100)
        start_s, end_s = bm.region_seconds(13, 20, 97)
        assert s == bm.seconds_to_sample(start_s, 44100)
        assert e == bm.seconds_to_sample(end_s, 44100)
        assert s < e


class TestBarLookupAndSnap:
    def test_bar_at_seconds_half_open(self):
        # 32.0 s at 120 bpm is the first instant of bar 17.
        assert bm.bar_at_seconds(31.999, 120) == 16
        assert bm.bar_at_seconds(32.0, 120) == 17

    def test_bar_at_seconds_before_grid_is_bar_one(self):
        assert bm.bar_at_seconds(0.1, 120, grid_offset_seconds=0.5) == 1

    def test_snap_nearest(self):
        assert bm.snap_seconds_to_bar(32.9, 120) == 32.0
        assert bm.snap_seconds_to_bar(33.1, 120) == 34.0

    def test_snap_floor_and_ceil(self):
        assert bm.snap_seconds_to_bar(33.9, 120, mode="floor") == 32.0
        assert bm.snap_seconds_to_bar(32.1, 120, mode="ceil") == 34.0

    def test_snap_never_before_grid_origin(self):
        assert bm.snap_seconds_to_bar(0.0, 120, grid_offset_seconds=1.0) == 1.0

    def test_snap_bad_mode_rejected(self):
        with pytest.raises(ValueError):
            bm.snap_seconds_to_bar(1.0, 120, mode="round")

    def test_snap_respects_offset(self):
        snapped = bm.snap_seconds_to_bar(4.4, 120, grid_offset_seconds=0.25)
        assert math.isclose(snapped, 4.25)
