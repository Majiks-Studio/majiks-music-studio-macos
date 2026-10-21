//! Linear slew (the DJ `step_toward` idiom): move toward a target by a fixed
//! per-frame step and arrive EXACTLY on target, so settled values multiply
//! bit-exactly (1.0 stays 1.0).

#[derive(Debug, Clone, Copy)]
pub struct Slew {
    now: f32,
    step: f32,
}

impl Slew {
    pub fn new(initial: f32, step: f32) -> Self {
        Self { now: initial, step }
    }

    /// Jump immediately (used when a track first appears, never mid-signal).
    pub fn snap(&mut self, value: f32) {
        self.now = value;
    }

    #[inline(always)]
    pub fn get(&self) -> f32 {
        self.now
    }

    #[inline(always)]
    pub fn settled_at(&self, target: f32) -> bool {
        self.now == target
    }

    /// One frame of glide toward `target`; returns the new value.
    #[inline(always)]
    pub fn advance(&mut self, target: f32) -> f32 {
        let delta = target - self.now;
        if delta.abs() <= self.step {
            self.now = target;
        } else if delta > 0.0 {
            self.now += self.step;
        } else {
            self.now -= self.step;
        }
        self.now
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arrives_exactly_and_bounds_steps() {
        let mut s = Slew::new(0.0, 1.0 / 240.0);
        let mut last = s.get();
        let mut frames = 0;
        loop {
            let v = s.advance(1.0);
            // f32 accumulation wobbles deltas by ~1 ulp of the running value.
            assert!((v - last).abs() <= 1.0 / 240.0 + 1e-6);
            last = v;
            frames += 1;
            if s.settled_at(1.0) {
                break;
            }
            assert!(frames < 300, "must settle within 240 frames + slack");
        }
        assert_eq!(s.get(), 1.0, "bit-exact arrival");
        assert!((238..=242).contains(&frames), "settled in {frames} frames");
    }
}
