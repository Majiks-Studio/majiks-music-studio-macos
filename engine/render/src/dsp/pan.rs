//! Equal-power BALANCE pan law for stereo material: center is exact unity
//! (bit-exact pass-through, which the P0-B playback tests rely on), and
//! panning attenuates the opposite side along a cosine curve. Full left
//! keeps L at unity and takes R to zero.

/// Left/right gains for pan position `p` in [-1, 1] (negative = left).
#[inline]
pub fn balance_gains(p: f32) -> (f32, f32) {
    let p = p.clamp(-1.0, 1.0);
    if p == 0.0 {
        return (1.0, 1.0);
    }
    let half_pi = std::f32::consts::FRAC_PI_2;
    let l = if p > 0.0 { (p * half_pi).cos() } else { 1.0 };
    let r = if p < 0.0 { ((-p) * half_pi).cos() } else { 1.0 };
    (l, r)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn center_is_exact_unity() {
        assert_eq!(balance_gains(0.0), (1.0, 1.0));
    }

    #[test]
    fn extremes_isolate_one_side() {
        let (l, r) = balance_gains(-1.0);
        assert_eq!(l, 1.0);
        assert!(r.abs() < 1e-6);
        let (l, r) = balance_gains(1.0);
        assert!(l.abs() < 1e-6);
        assert_eq!(r, 1.0);
    }

    #[test]
    fn halfway_follows_the_cosine() {
        let (l, r) = balance_gains(0.5);
        assert_eq!(l, (0.5 * std::f32::consts::FRAC_PI_2).cos());
        assert_eq!(r, 1.0);
    }
}
