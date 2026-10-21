//! `generator`: the region generator seam.
//!
//! Revise/extend/layer all need "give me N frames of new audio for this stem,
//! at this seed and quality rung". The engine surface PROXIES generation (it
//! implements none): the live path forwards to L4's Gen Protocol RPC (the
//! Python backend / Majiks Gen Node), and the deterministic path is a mock
//! fixture generator so the orchestration + splice + commit + undo are provable
//! without a Gen Node, exactly as the L9 brief requires.
//!
//! P0-A's rungs (docs/evidence/p0a-repaint.md section 7): the DRAFT rung is
//! turbo-8 (about 3.9 s/song on a 3090, seam metrics at or better than base-50),
//! the COMMIT rung is base-50 (the app default, about 15.7 s). Seed variance
//! dominates instruction variance, which is why 3 variants is the right default:
//! the user picks the take, takes are cheap.

use crate::error::StudioError;

/// The three generation ops L9 surfaces. Carried into lineage and used by the
/// mock to give each op a distinguishable flavor.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GenOp {
    Revise,
    Extend,
    Layer,
}

impl GenOp {
    pub fn source_command(self) -> &'static str {
        match self {
            GenOp::Revise => "gen.revise",
            GenOp::Extend => "gen.extend",
            GenOp::Layer => "gen.layer",
        }
    }
}

/// The two-phase render rungs (01-DESIGN 3.2 step 6, calibrated by P0-A).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QualityRung {
    /// turbo-8: the fast audition rung.
    Draft,
    /// A middle rung (advanced override; P0-A did not pin a step count).
    Standard,
    /// base-50: the app-default commit rung.
    Full,
}

impl QualityRung {
    pub fn from_wire(s: &str) -> QualityRung {
        match s {
            "draft" => QualityRung::Draft,
            "full" => QualityRung::Full,
            _ => QualityRung::Standard,
        }
    }

    pub fn wire(self) -> &'static str {
        match self {
            QualityRung::Draft => "draft",
            QualityRung::Standard => "standard",
            QualityRung::Full => "full",
        }
    }

    /// The ACE-Step model name this rung maps to (gen-protocol.v1.yaml
    /// gen.finalize: draft=turbo/8, full=base/50).
    pub fn model_name(self) -> &'static str {
        match self {
            QualityRung::Draft => "acestep-v15-turbo",
            QualityRung::Standard => "acestep-v15-quality",
            QualityRung::Full => "acestep-v15-base",
        }
    }

    pub fn steps(self) -> u32 {
        match self {
            QualityRung::Draft => 8,
            QualityRung::Standard => 25,
            QualityRung::Full => 50,
        }
    }
}

/// One region-generation request. `context` is the ORIGINAL region audio (the
/// repaint conditioning; the mock uses only its length, a real repaint uses the
/// samples). `region_frames` is how many frames to return (repaint preserves
/// length; extend/layer return the requested span).
#[derive(Debug, Clone)]
pub struct GenSpec {
    pub op: GenOp,
    /// "mix" for an all-stems revise / extend, or a stem name for a scoped
    /// stem or an added layer ("vocals"/"drums"/"bass"/"other").
    pub stem: String,
    pub region_frames: usize,
    pub seed: u64,
    pub rung: QualityRung,
    pub instruction: String,
    pub context: Vec<[f32; 2]>,
}

/// The generator seam. One method returns the region's replacement PCM.
pub trait RegionGenerator {
    /// Produce `spec.region_frames` frames of new stereo audio for the request.
    fn generate(&self, spec: &GenSpec) -> Result<Vec<[f32; 2]>, StudioError>;

    /// The `gen.landed.engineIdentity.device` value. MUST be one of the catalog
    /// enum (`mlx`/`mps`/`cuda`/`cpu`/`remote`); the mock reports `cpu` (it runs
    /// deterministically on the CPU) and carries its "this is a stand-in"
    /// honesty in the model name instead.
    fn device(&self) -> &'static str;

    /// The `gen.landed.engineIdentity.model` value for a rung. The mock appends
    /// `-mock` to the ACE-Step model name so lineage never claims a real render.
    fn model_name(&self, rung: QualityRung) -> String;

    /// A short label for the evidence/report ("mock-fixture" / "gen-node").
    fn label(&self) -> &'static str;
}

/// A deterministic, silence-gated fixture generator: a pure function of
/// (op, stem, seed, rung, region length), so the whole revise/commit/undo flow
/// is reproducible with no Gen Node. It is a STAND-IN, not a model; lineage says
/// so (`engineIdentity.device = "mock"`, model name carries "-mock").
///
/// The audio is a low-amplitude (<= about 0.06 peak) seeded tone so evidence
/// stays SILENCE-GATED: different seeds give audibly different takes (seed
/// dominates, per P0-A), different stems give different timbres, and the FULL
/// rung is a coherent higher-fidelity version of the DRAFT take at the same seed
/// (a second harmonic and slightly more level), so the draft->commit finalize
/// swap is observable AND clearly "the same take, better".
pub struct MockGenerator;

impl MockGenerator {
    /// Peak amplitude ceiling; keeps every fixture take silence-gated.
    const AMP: f32 = 0.05;

    fn scramble(mut x: u64) -> u64 {
        x = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = x;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    fn stem_partial(stem: &str) -> f64 {
        // A per-stem base frequency so stems read as different timbres.
        match stem {
            "vocals" => 330.0,
            "drums" => 110.0,
            "bass" => 82.0,
            "other" => 220.0,
            _ => 261.63, // "mix" and layers: middle C
        }
    }
}

impl RegionGenerator for MockGenerator {
    fn generate(&self, spec: &GenSpec) -> Result<Vec<[f32; 2]>, StudioError> {
        if spec.region_frames == 0 {
            return Err(StudioError::audio("region has zero frames"));
        }
        let rate = super::splice::RATE as f64;
        let base = Self::stem_partial(&spec.stem);
        // Seed shifts the pitch a little (up to +/- ~6%) so variants differ.
        let seed_scaled = (Self::scramble(spec.seed) % 1000) as f64 / 1000.0; // 0..1
        let detune = 1.0 + (seed_scaled - 0.5) * 0.12;
        let op_mul = match spec.op {
            GenOp::Revise => 1.0,
            GenOp::Extend => 1.5, // an octave-ish up, so an extension reads distinct
            GenOp::Layer => 2.0,
        };
        let freq = base * detune * op_mul;
        // Full rung adds a second harmonic + a hair more level than draft, so
        // the finalize swap is "the same take, higher fidelity".
        let (level, harmonic) = match spec.rung {
            QualityRung::Draft => (0.80, 0.0),
            QualityRung::Standard => (0.90, 0.15),
            QualityRung::Full => (1.00, 0.30),
        };
        let phase = (Self::scramble(spec.seed ^ 0xA5A5) % 6283) as f64 / 1000.0;
        let mut out = vec![[0.0f32; 2]; spec.region_frames];
        for (i, frame) in out.iter_mut().enumerate() {
            let t = i as f64 / rate;
            // A gentle raised-cosine window over the whole region so the
            // fixture itself has no edge clicks before the splice ramp even
            // applies (belt and suspenders for the declick evidence).
            let w = {
                let n = spec.region_frames as f64;
                0.5 - 0.5 * (2.0 * std::f64::consts::PI * i as f64 / n).cos()
            };
            let fundamental = (2.0 * std::f64::consts::PI * freq * t + phase).sin();
            let second = (2.0 * std::f64::consts::PI * freq * 2.0 * t + phase).sin();
            let v = Self::AMP as f64 * level * w * (fundamental + harmonic * second);
            frame[0] = v as f32;
            frame[1] = v as f32;
        }
        Ok(out)
    }

    fn device(&self) -> &'static str {
        "cpu"
    }

    fn model_name(&self, rung: QualityRung) -> String {
        format!("{}-mock", rung.model_name())
    }

    fn label(&self) -> &'static str {
        "mock-fixture"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(stem: &str, seed: u64, rung: QualityRung, op: GenOp, frames: usize) -> GenSpec {
        GenSpec {
            op,
            stem: stem.to_string(),
            region_frames: frames,
            seed,
            rung,
            instruction: "test".into(),
            context: vec![[0.0; 2]; frames],
        }
    }

    #[test]
    fn mock_is_deterministic_for_the_same_spec() {
        let a = MockGenerator.generate(&spec("drums", 22, QualityRung::Draft, GenOp::Revise, 4000)).unwrap();
        let b = MockGenerator.generate(&spec("drums", 22, QualityRung::Draft, GenOp::Revise, 4000)).unwrap();
        assert_eq!(a, b, "same spec must reproduce the same audio exactly");
    }

    #[test]
    fn different_seeds_give_different_takes() {
        let s11 = MockGenerator.generate(&spec("drums", 11, QualityRung::Draft, GenOp::Revise, 4000)).unwrap();
        let s22 = MockGenerator.generate(&spec("drums", 22, QualityRung::Draft, GenOp::Revise, 4000)).unwrap();
        assert_ne!(s11, s22, "seed variance must produce distinct takes (P0-A: seed dominates)");
    }

    #[test]
    fn full_rung_differs_from_draft_at_the_same_seed() {
        let draft = MockGenerator.generate(&spec("mix", 7, QualityRung::Draft, GenOp::Revise, 4000)).unwrap();
        let full = MockGenerator.generate(&spec("mix", 7, QualityRung::Full, GenOp::Revise, 4000)).unwrap();
        assert_ne!(draft, full, "finalize must re-render to a different (higher-fidelity) asset");
    }

    #[test]
    fn fixtures_are_silence_gated() {
        let a = MockGenerator.generate(&spec("other", 33, QualityRung::Full, GenOp::Layer, 8000)).unwrap();
        let peak = a.iter().flat_map(|f| [f[0].abs(), f[1].abs()]).fold(0.0f32, f32::max);
        assert!(peak <= 0.06, "fixture not silence-gated, peak {peak}");
    }

    #[test]
    fn fixture_has_no_edge_click_of_its_own() {
        let a = MockGenerator.generate(&spec("vocals", 5, QualityRung::Draft, GenOp::Revise, 4000)).unwrap();
        // The raised-cosine window means the fixture starts and ends near zero.
        assert!(a.first().unwrap()[0].abs() < 1e-3);
        assert!(a.last().unwrap()[0].abs() < 1e-3);
    }
}
