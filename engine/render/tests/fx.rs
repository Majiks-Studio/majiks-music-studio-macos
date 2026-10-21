//! E5-fx: the effect suite proven on RENDERED BUFFERS, with measurements.
//!
//! ## Test-seam honesty (§12.5) — which production hops these traverse
//!
//! | Hop | Status |
//! |---|---|
//! | `FxNode::process_frame` / `load_block_targets` — the exact code `rt.rs` will call per frame / per block | **traversed** |
//! | The parameter read path (`FxParams::fx_param_target`, slot layout, clamping) | **traversed**, against `FxParamBank` |
//! | `EngineParams`'s §16.6 atomics | **SKIPPED** — E5-params owns them and they do not exist yet. `FxParamBank` is the declared fixture (see `dsp/fx.rs`). **A green run here does NOT prove the host pushes an fx param.** That proof belongs to E5-graph/E5-params. |
//! | `rt.rs`'s per-frame walk, `compile.rs`'s chain build, PDC | **SKIPPED** — E5-graph owns them. This lane is file-disjoint from `rt.rs` by §21.1. |
//!
//! Stating that plainly because a 15 ms MIDI input delay once shipped with the
//! whole suite green on a seam that skipped the pump.
//!
//! ## What is asserted, and why it is not "the output got quieter"
//!
//! - The compressor is checked against a **measured gain-reduction curve**
//!   over a grid of (threshold, ratio, input level). An implementation that
//!   ignored `ratio` would still attenuate and would still fail every row.
//! - The keyed detector is checked by **inverting the measured gain back into
//!   the key level the detector must have seen** and comparing it to the key
//!   signal's actual amplitude (§20.2 proof 6 — assert the key VALUE, not just
//!   that the output changed).
//! - The chorus is checked against **`2π·rate·depth`**, the closed form for
//!   peak fractional pitch deviation, at two settings — a joint constraint on
//!   both parameters that a fixed-tap or depth-ignoring implementation cannot
//!   satisfy.
//! - Per-frame advance is checked by **bit-identity across block sizes
//!   1 / 128 / 417 / 480 / 512**, per kind.
//!
//! No assertion here is on wall-clock time; every number is deterministic
//! buffer arithmetic, so a loaded machine cannot move any of them.

use render::dsp::chorus::ChorusFx;
use render::dsp::compressor::CompressorFx;
use render::dsp::fx::{
    all_fx_param_keys, base_slot_of, seed_fx_defaults, set_fx_param_by_key, FxKindId, FxNode,
    FxUnit, ALL_FX_KINDS, BYPASS_KEY,
};
use render::dsp::{db_to_lin, lin_to_db};
use render::guard;
use render::params::{EngineParams, MAX_FX_PARAMS_PER_FX};
use render::rt::{ENGINE_SAMPLE_RATE, MICRO_FADE_FRAMES};

// The counting allocator only observes anything when it IS the binary's global
// allocator; without this the alloc assertion below would be vacuously green
// (`render/tests/solo.rs:29-31` documents the trap).
#[global_allocator]
static ALLOC: guard::CountingAlloc = guard::CountingAlloc;

const SR: u32 = ENGINE_SAMPLE_RATE;
const SRF: f32 = SR as f32;
const RAMP: u32 = MICRO_FADE_FRAMES as u32;

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// One `EngineParams` carrying one seeded fx instance at fx slot 0.
fn bank_for(kind: FxKindId) -> EngineParams {
    let p = EngineParams::new(4);
    seed_fx_defaults(&p, kind, 0);
    p
}

fn set(b: &EngineParams, kind: FxKindId, key: &str, v: f32) {
    assert!(
        set_fx_param_by_key(b, kind, 0, key, v),
        "{kind:?} has no param {key:?}"
    );
}

/// Every sample of a rendered buffer must be finite. A NaN or an infinity at a
/// summing point destroys the whole mix with no cause visible in the model
/// (§23.4), and the pathological input that produces one is exactly the bug
/// that ships.
fn assert_all_finite(label: &str, buf: &[[f32; 2]]) {
    for (i, f) in buf.iter().enumerate() {
        assert!(
            f[0].is_finite() && f[1].is_finite(),
            "{label}: non-finite sample {f:?} at frame {i}"
        );
    }
}

/// Run a unit over `input`, keyed by `key`, in blocks of `block` frames.
/// `load_block_targets` is called at every block boundary, exactly as `rt.rs`
/// will; `process_frame` is called once per frame, exactly as `rt.rs` will.
fn render_blocks(
    unit: &mut FxUnit,
    p: &EngineParams,
    input: &[[f32; 2]],
    key: &[[f32; 2]],
    block: usize,
) -> Vec<[f32; 2]> {
    let mut out = Vec::with_capacity(input.len());
    let mut i = 0;
    while i < input.len() {
        unit.load_block_targets(p, 0);
        let end = (i + block).min(input.len());
        for f in i..end {
            out.push(unit.process_frame(input[f], key[f]));
        }
        i = end;
    }
    out
}

fn dc(level: f32, n: usize) -> Vec<[f32; 2]> {
    vec![[level, level]; n]
}

fn sine(freq: f32, amp: f32, n: usize) -> Vec<[f32; 2]> {
    (0..n)
        .map(|i| {
            let v = amp * (2.0 * std::f32::consts::PI * freq * i as f32 / SRF).sin();
            [v, v]
        })
        .collect()
}

/// A kick-like pulse train: `on_frames` of DC at `amp` every `period` frames.
fn pulses(amp: f32, period: usize, on_frames: usize, n: usize) -> Vec<[f32; 2]> {
    (0..n)
        .map(|i| {
            let v = if i % period < on_frames { amp } else { 0.0 };
            [v, v]
        })
        .collect()
}

/// Magnitude of one frequency component, computed over an integer number of
/// cycles so there is no spectral leakage to argue about.
fn bin_magnitude(buf: &[f32], freq: f32) -> f64 {
    let n = buf.len() as f64;
    let w = 2.0 * std::f64::consts::PI * f64::from(freq) / f64::from(SRF);
    let (mut re, mut im) = (0.0_f64, 0.0_f64);
    for (i, &x) in buf.iter().enumerate() {
        let t = w * i as f64;
        re += f64::from(x) * t.cos();
        im -= f64::from(x) * t.sin();
    }
    (re * re + im * im).sqrt() * 2.0 / n
}

/// Interpolated upward zero crossings, in fractional frames.
fn upward_crossings(buf: &[f32]) -> Vec<f64> {
    let mut out = Vec::new();
    for i in 1..buf.len() {
        let (a, b) = (buf[i - 1], buf[i]);
        if a <= 0.0 && b > 0.0 {
            let t = f64::from(-a) / f64::from(b - a);
            out.push(i as f64 - 1.0 + t);
        }
    }
    out
}

fn left(buf: &[[f32; 2]]) -> Vec<f32> {
    buf.iter().map(|f| f[0]).collect()
}

// ---------------------------------------------------------------------------
// 1. RT safety: allocation guard WITH a positive control
// ---------------------------------------------------------------------------

/// §12.7. The negative assertion is worthless without the positive control:
/// a guard that cannot see an allocation proves nothing.
#[test]
fn every_kind_is_allocation_free_on_the_audio_thread() {
    // --- positive control: the guard CAN see an allocation in a render scope.
    let before = guard::violations();
    guard::enter_render_scope();
    let deliberate: Vec<f32> = vec![0.0; 128];
    guard::leave_render_scope();
    let after_control = guard::violations();
    assert!(
        after_control > before,
        "positive control: the CountingAlloc guard did not observe a deliberate \
         allocation inside a render scope ({before} -> {after_control}); every \
         alloc assertion below would be vacuously green"
    );
    drop(deliberate);

    // --- construction happens OUTSIDE the scope (control-side allocation is
    // legal and expected: rings, tables, the boxed limiter).
    let mut units: Vec<(FxKindId, FxUnit, EngineParams)> = ALL_FX_KINDS
        .iter()
        .map(|&k| {
            let b = bank_for(k);
            // Non-default values so no kind sits on a short-circuit path.
            if k.param_index("mix").is_some() {
                set(&b, k, "mix", 0.7);
            }
            (k, FxUnit::new(k, SR, RAMP), b)
        })
        .collect();

    let input = sine(220.0, 0.6, 4096);
    let key = pulses(0.9, 512, 64, 4096);

    let before = guard::violations();
    guard::enter_render_scope();
    for (_, unit, bank) in units.iter_mut() {
        let mut i = 0;
        while i < input.len() {
            unit.load_block_targets(bank, 0);
            let end = (i + 128).min(input.len());
            for f in i..end {
                std::hint::black_box(unit.process_frame(input[f], key[f]));
            }
            i = end;
        }
        std::hint::black_box(unit.take_block_meter());
    }
    guard::leave_render_scope();
    let after = guard::violations();

    assert_eq!(
        after, before,
        "allocation inside a render scope: {} hits across {} kinds",
        after - before,
        ALL_FX_KINDS.len()
    );
}

// ---------------------------------------------------------------------------
// 2. Per-FRAME advance: bit-identity across block sizes (§6.1, §16.7)
// ---------------------------------------------------------------------------

/// The single rule §6.1 calls the hardest in the document. A per-BLOCK
/// shortcut passes every casual test and silently makes a bounce sound
/// different from what the user heard.
///
/// The signal is continuous (no silent tail) on purpose: `EqBank` flushes
/// denormal filter state at block boundaries, which is legitimately
/// block-aligned hygiene, and feeding it a decaying-to-silence signal would
/// test that inherited behaviour rather than this lane's per-frame rule.
#[test]
fn every_kind_is_bit_identical_at_128_417_480_512() {
    let n = 24_000;
    let input: Vec<[f32; 2]> = (0..n)
        .map(|i| {
            let t = i as f32 / SRF;
            let l = 0.6 * (2.0 * std::f32::consts::PI * 220.0 * t).sin()
                + 0.3 * (2.0 * std::f32::consts::PI * 1_337.0 * t).sin();
            [l, l * 0.8]
        })
        .collect();
    let key = pulses(0.9, 4_800, 480, n);

    for &kind in ALL_FX_KINDS.iter() {
        let bank = bank_for(kind);
        // Drive every kind off its neutral default so the test has teeth.
        if kind.param_index("mix").is_some() {
            set(&bank, kind, "mix", 0.6);
        }
        if kind == FxKindId::Compressor {
            set(&bank, kind, "threshold", -24.0);
            set(&bank, kind, "ratio", 6.0);
            set(&bank, kind, "attack", 5.0);
            set(&bank, kind, "release", 80.0);
        }
        if kind == FxKindId::Gate {
            set(&bank, kind, "threshold", -18.0);
            set(&bank, kind, "hold", 5.0);
        }
        if kind == FxKindId::Eq {
            set(&bank, kind, "band1Gain", -12.0);
            set(&bank, kind, "band3Gain", 6.0);
        }
        if kind == FxKindId::Saturator {
            set(&bank, kind, "drive", 12.0);
        }
        if kind == FxKindId::Utility {
            set(&bank, kind, "width", 1.4);
            set(&bank, kind, "pan", -0.3);
        }

        let mut reference_unit = FxUnit::new(kind, SR, RAMP);
        let reference = render_blocks(&mut reference_unit, &bank, &input, &key, 128);
        assert_all_finite(&format!("{kind:?} block-identity reference"), &reference);

        for block in [1_usize, 417, 480, 512] {
            let mut unit = FxUnit::new(kind, SR, RAMP);
            let got = render_blocks(&mut unit, &bank, &input, &key, block);
            assert_eq!(got.len(), reference.len());
            for (i, (a, b)) in got.iter().zip(reference.iter()).enumerate() {
                assert_eq!(
                    a, b,
                    "{kind:?}: block {block} diverges from block 128 at frame {i}"
                );
            }
        }
    }
}

// ---------------------------------------------------------------------------
// 3. The compressor's measured gain-reduction curve (§20.2 proof 4)
// ---------------------------------------------------------------------------

/// Measure the settled gain reduction of a DC input and compare it to the
/// curve the CONFIGURED ratio and threshold demand:
/// `GR_dB = (level_dB - threshold_dB) * (1/ratio - 1)`.
///
/// DC rather than a tone on purpose: a peak detector settles on DC *exactly*,
/// so there is no envelope ripple to hide behind and the tolerance can be
/// 0.02 dB instead of "about right".
///
/// **A compressor that ignored `ratio` and simply attenuated would pass a
/// "did it get quieter" test and fail every row of this one** — the rows for a
/// single `over` differ by more than 6 dB between ratios, which the test
/// asserts explicitly so the grid cannot silently collapse.
#[test]
fn compressor_gain_reduction_follows_the_configured_ratio_and_threshold() {
    let n = 48_000;
    let mut rows: Vec<(f32, f32, f32, f32, f32)> = Vec::new();

    for &threshold in &[-24.0_f32, -12.0] {
        for &ratio in &[2.0_f32, 4.0, 8.0] {
            for &over in &[6.0_f32, 12.0] {
                let level_db = threshold + over;
                let amp = db_to_lin(level_db);

                let bank = bank_for(FxKindId::Compressor);
                set(&bank, FxKindId::Compressor, "threshold", threshold);
                set(&bank, FxKindId::Compressor, "ratio", ratio);
                set(&bank, FxKindId::Compressor, "knee", 0.0);
                set(&bank, FxKindId::Compressor, "attack", 1.0);
                set(&bank, FxKindId::Compressor, "release", 100.0);
                set(&bank, FxKindId::Compressor, "makeup", 0.0);
                set(&bank, FxKindId::Compressor, "mix", 1.0);

                let mut unit = FxUnit::new(FxKindId::Compressor, SR, RAMP);
                let input = dc(amp, n);
                let out = render_blocks(&mut unit, &bank, &input, &input, 128);

                let settled = out[n - 1][0];
                let measured_gr = lin_to_db(settled / amp);
                let expected_gr = over * (1.0 / ratio - 1.0);
                rows.push((threshold, ratio, over, measured_gr, expected_gr));
                eprintln!(
                    "GR thr={threshold:>6.1} ratio={ratio:>4.1} over={over:>5.1}                      measured={measured_gr:>8.4} dB expected={expected_gr:>8.4} dB"
                );

                assert!(
                    (measured_gr - expected_gr).abs() < 0.02,
                    "thr={threshold} ratio={ratio} over={over}: measured {measured_gr:.4} dB, \
                     expected {expected_gr:.4} dB"
                );
            }
        }
    }

    // The grid must actually discriminate: for a fixed `over`, 2:1 and 8:1
    // differ by > 6 dB. If this ever collapses, the rows above stop meaning
    // anything even while they pass.
    let gr = |ratio: f32, over: f32| {
        rows.iter()
            .find(|r| r.1 == ratio && r.2 == over && r.0 == -24.0)
            .map(|r| r.3)
            .unwrap()
    };
    // 12 dB over: 2:1 gives -6.0 dB, 8:1 gives -10.5 dB.
    assert!(
        (gr(2.0, 12.0) - gr(8.0, 12.0)).abs() > 4.0,
        "the ratio grid does not discriminate: {} vs {}",
        gr(2.0, 12.0),
        gr(8.0, 12.0)
    );

    // And the threshold must matter independently of the ratio: the same
    // absolute input level under two thresholds gives different reduction.
    let amp = db_to_lin(-6.0);
    let mut measured = Vec::new();
    for &threshold in &[-24.0_f32, -12.0] {
        let bank = bank_for(FxKindId::Compressor);
        set(&bank, FxKindId::Compressor, "threshold", threshold);
        set(&bank, FxKindId::Compressor, "ratio", 4.0);
        set(&bank, FxKindId::Compressor, "knee", 0.0);
        set(&bank, FxKindId::Compressor, "attack", 1.0);
        let mut unit = FxUnit::new(FxKindId::Compressor, SR, RAMP);
        let input = dc(amp, n);
        let out = render_blocks(&mut unit, &bank, &input, &input, 128);
        let measured_gr = lin_to_db(out[n - 1][0] / amp);
        let expected_gr = (-6.0 - threshold) * (1.0 / 4.0 - 1.0);
        assert!(
            (measured_gr - expected_gr).abs() < 0.02,
            "thr={threshold}: {measured_gr:.4} vs {expected_gr:.4}"
        );
        measured.push(measured_gr);
    }
    assert!(
        (measured[0] - measured[1]).abs() > 8.0,
        "threshold does not move the curve: {measured:?}"
    );
}

/// Below threshold the compressor must be a bit-exact pass-through: gain
/// reduction is EXACTLY 1.0, not 0.9998 (§17.2).
#[test]
fn compressor_below_threshold_is_bit_exact_unity() {
    let n = 24_000;
    let amp = db_to_lin(-30.0);
    let bank = bank_for(FxKindId::Compressor);
    set(&bank, FxKindId::Compressor, "threshold", -12.0);
    set(&bank, FxKindId::Compressor, "ratio", 8.0);
    set(&bank, FxKindId::Compressor, "knee", 0.0);
    set(&bank, FxKindId::Compressor, "makeup", 0.0);
    set(&bank, FxKindId::Compressor, "mix", 1.0);

    let mut unit = FxUnit::new(FxKindId::Compressor, SR, RAMP);
    let input = dc(amp, n);
    let out = render_blocks(&mut unit, &bank, &input, &input, 128);
    for (i, f) in out.iter().enumerate().skip(2_000) {
        assert_eq!(*f, input[i], "frame {i}: not a bit-exact pass-through");
    }

    // And the block meter reports exactly "no reduction".
    assert_eq!(unit.take_block_meter(), 1.0);
}

/// The attack coefficient is honoured, **measured on the rendered buffer**.
///
/// The measurement inverts the (independently proven) static curve to recover
/// the detector envelope the compressor must have had at each frame, then
/// times its charge to 63.2 % — one time constant, by definition of a
/// one-pole. Measuring 63.2 % of the *gain reduction in dB* instead would be
/// wrong by construction: dB is logarithmic, so the envelope reaching 63 % of
/// its amplitude is already ~78 % of the way in dB, and the measurement would
/// land near 0.63 tau. (That is exactly what it did on the first run — 1.90 ms
/// for a 5 ms attack — which is the arithmetic error being recorded here, not
/// a DSP one.)
#[test]
fn compressor_attack_time_is_measurable_on_the_buffer() {
    let n = 48_000;
    let level_db = -6.0_f32;
    let amp = db_to_lin(level_db);
    let threshold = -24.0_f32;
    let ratio = 4.0_f32;
    let slope = 1.0 / ratio - 1.0;

    for &attack_ms in &[5.0_f32, 40.0] {
        let bank = bank_for(FxKindId::Compressor);
        set(&bank, FxKindId::Compressor, "threshold", threshold);
        set(&bank, FxKindId::Compressor, "ratio", ratio);
        set(&bank, FxKindId::Compressor, "knee", 0.0);
        set(&bank, FxKindId::Compressor, "attack", attack_ms);
        set(&bank, FxKindId::Compressor, "release", 500.0);
        set(&bank, FxKindId::Compressor, "makeup", 0.0);
        set(&bank, FxKindId::Compressor, "mix", 1.0);

        let mut unit = FxUnit::new(FxKindId::Compressor, SR, RAMP);
        // Silence, then a step to DC: the envelope charge is visible directly.
        let mut input = dc(0.0, 4_800);
        input.extend(dc(amp, n));
        let key = input.clone();
        let out = render_blocks(&mut unit, &bank, &input, &key, 128);

        // Invert the curve: gain -> gain reduction (dB) -> detector envelope.
        let env_at = |i: usize| -> f32 {
            let gr_db = lin_to_db(out[i][0] / amp);
            db_to_lin(threshold + gr_db / slope)
        };
        let step = 4_800;
        let settled = env_at(out.len() - 1);
        assert!(
            (settled - amp).abs() < amp * 0.01,
            "attack {attack_ms} ms: envelope settled at {settled}, input is {amp}"
        );
        let target = 0.632 * settled;
        let reached = (step..out.len())
            .find(|&i| env_at(i) >= target)
            .expect("the detector envelope reaches 63.2% of the input level");
        let measured_ms = (reached - step) as f32 * 1_000.0 / SRF;
        eprintln!("ATTACK configured={attack_ms:.1} ms measured={measured_ms:.3} ms");
        assert!(
            (measured_ms - attack_ms).abs() < attack_ms * 0.2,
            "attack {attack_ms} ms measured as {measured_ms:.2} ms"
        );
    }
}

// ---------------------------------------------------------------------------
// 4. The keyed detector (§17.3, §20.2 proofs 5 and 6)
// ---------------------------------------------------------------------------

/// **The same input, compressed by two different sidechain sources, must
/// produce measurably different output.**
///
/// A sustained DC "bus" is keyed by (a) a kick-like pulse train, (b) silence,
/// (c) its own input. All three are rendered from identical audio and differ
/// only in `key`.
#[test]
fn keyed_detector_actually_keys() {
    let n = 48_000;
    let bus_amp = db_to_lin(-20.0);
    let audio = dc(bus_amp, n);
    let kick = pulses(db_to_lin(-3.0), 12_000, 2_400, n);
    let silence = dc(0.0, n);

    let bank = bank_for(FxKindId::Compressor);
    set(&bank, FxKindId::Compressor, "threshold", -30.0);
    set(&bank, FxKindId::Compressor, "ratio", 8.0);
    set(&bank, FxKindId::Compressor, "knee", 0.0);
    set(&bank, FxKindId::Compressor, "attack", 0.0);
    // 30 ms: the detector must fall from the -3 dB kick to below the -30 dB
    // threshold within the 200 ms gap between kicks, or "recovers between
    // kicks" is testing the release time rather than the keying.
    set(&bank, FxKindId::Compressor, "release", 30.0);
    set(&bank, FxKindId::Compressor, "mix", 1.0);

    let run = |key: &[[f32; 2]]| {
        let mut unit = FxUnit::new(FxKindId::Compressor, SR, RAMP);
        render_blocks(&mut unit, &bank, &audio, key, 128)
    };

    let keyed = run(&kick);
    let unkeyed_silent = run(&silence);
    let self_keyed = run(&audio);

    // (a) Keyed by silence: nothing above threshold, bit-exact pass-through.
    for (i, f) in unkeyed_silent.iter().enumerate().skip(1_000) {
        assert_eq!(*f, audio[i], "silent key must not compress (frame {i})");
    }

    // (b) Keyed by the kick: the bus ducks IN TIME with the transients and
    //     recovers between them.
    let during = keyed[13_000][0];
    let between = keyed[23_000][0];
    assert!(
        during < bus_amp * 0.5,
        "bus did not duck under the kick: {during} vs {bus_amp}"
    );
    assert!(
        between > bus_amp * 0.98,
        "bus did not recover between kicks: {between} vs {bus_amp}"
    );

    // (c) Two different key sources produce measurably different output on
    //     the SAME audio — the discrimination the brief asks for.
    let rms = |b: &[[f32; 2]]| -> f64 {
        (b.iter().map(|f| f64::from(f[0]) * f64::from(f[0])).sum::<f64>() / b.len() as f64).sqrt()
    };
    let (r_keyed, r_silent, r_self) = (rms(&keyed), rms(&unkeyed_silent), rms(&self_keyed));
    eprintln!(
        "SIDECHAIN rms kick-keyed={r_keyed:.6} silence-keyed={r_silent:.6}          self-keyed={r_self:.6} | duck={:.6} recover={:.6}",
        keyed[13_000][0], keyed[23_000][0]
    );
    assert!(
        (r_keyed - r_silent).abs() / r_silent > 0.1,
        "kick-keyed vs silence-keyed differ by only {:.4}%",
        100.0 * (r_keyed - r_silent).abs() / r_silent
    );
    assert!(
        (r_keyed - r_self).abs() / r_self > 0.1,
        "kick-keyed vs self-keyed differ by only {:.4}%",
        100.0 * (r_keyed - r_self).abs() / r_self
    );
    // Self-keyed also compresses (the bus is above threshold on its own), so
    // it is distinguishable from BOTH of the others, not just from silence.
    assert!(
        (r_self - r_silent).abs() / r_silent > 0.1,
        "self-keyed vs silence-keyed differ by only {:.4}%",
        100.0 * (r_self - r_silent).abs() / r_silent
    );
}

/// §20.2 proof 6 — the ordering failure mode. *"A test that only checks
/// 'output changed' would pass while the detector read `0.0` from a
/// not-yet-written accumulator."*
///
/// So assert the **key value**, not the effect: invert the measured gain back
/// through the (known, verified) static curve into the key level the detector
/// must have seen, and compare it to the key signal's actual amplitude.
/// With `attack = 0` the detector is instantaneous, so this is a
/// frame-accurate readout of what it saw on the first frame of the kick.
#[test]
fn the_detector_reads_the_key_value_on_the_first_frame_of_the_transient() {
    let n = 24_000;
    let bus_amp = db_to_lin(-20.0);
    let key_db = -6.0_f32;
    let key_amp = db_to_lin(key_db);
    let audio = dc(bus_amp, n);
    // Key is silent until frame 8000, then steps to `key_amp`.
    let key: Vec<[f32; 2]> = (0..n)
        .map(|i| if i < 8_000 { [0.0, 0.0] } else { [key_amp, key_amp] })
        .collect();

    let (threshold, ratio) = (-30.0_f32, 4.0_f32);
    let bank = bank_for(FxKindId::Compressor);
    set(&bank, FxKindId::Compressor, "threshold", threshold);
    set(&bank, FxKindId::Compressor, "ratio", ratio);
    set(&bank, FxKindId::Compressor, "knee", 0.0);
    set(&bank, FxKindId::Compressor, "attack", 0.0);
    set(&bank, FxKindId::Compressor, "release", 500.0);
    set(&bank, FxKindId::Compressor, "mix", 1.0);

    let mut unit = FxUnit::new(FxKindId::Compressor, SR, RAMP);
    let out = render_blocks(&mut unit, &bank, &audio, &key, 128);

    // Frame 7999: key still silent -> exactly no reduction.
    assert_eq!(out[7_999], audio[7_999], "compressing before the key arrives");

    // Frame 8000: the FIRST frame of the transient. Invert the curve.
    let gain = out[8_000][0] / bus_amp;
    let gr_db = lin_to_db(gain);
    let slope = 1.0 / ratio - 1.0;
    let implied_key_db = threshold + gr_db / slope;
    eprintln!(
        "KEY-VALUE readout: detector saw {implied_key_db:.5} dB on the first frame; \
         key is {key_db:.5} dB (gain {gain:.6})"
    );
    assert!(
        (implied_key_db - key_db).abs() < 0.05,
        "the detector saw {implied_key_db:.4} dB on the first frame of the key, \
         but the key is {key_db:.4} dB (gain {gain}). A detector reading a \
         not-yet-written accumulator would land at -inf here, not off by a little."
    );

    // The failure mode this guards against, spelled out: reading 0.0 would
    // give exactly no reduction, which is a value this assertion rejects.
    assert!(gain < 0.999, "the detector read silence, i.e. 0.0");
}

/// The gate keys too, and shares the compressor's detector (§17.2).
#[test]
fn gate_is_keyable_and_closes_to_exact_silence() {
    let n = 96_000;
    let tone = sine(220.0, 0.5, n);
    // One key pulse per 48 000 frames, 4 000 frames long.
    let opener = pulses(0.9, 48_000, 4_000, n);

    let bank = bank_for(FxKindId::Gate);
    set(&bank, FxKindId::Gate, "threshold", -12.0);
    set(&bank, FxKindId::Gate, "attack", 1.0);
    set(&bank, FxKindId::Gate, "hold", 5.0);
    set(&bank, FxKindId::Gate, "release", 10.0);
    set(&bank, FxKindId::Gate, "range", -96.0);

    let mut unit = FxUnit::new(FxKindId::Gate, SR, RAMP);
    let keyed = render_blocks(&mut unit, &bank, &tone, &opener, 128);

    // Inside a key pulse: the tone passes.
    let open_rms: f64 = {
        let s = &keyed[1_000..3_000];
        (s.iter().map(|f| f64::from(f[0]).powi(2)).sum::<f64>() / s.len() as f64).sqrt()
    };
    assert!(open_rms > 0.3, "gate did not open on the key: {open_rms}");

    // Shortly after the key stops, the gate is deep into its release.
    assert!(
        keyed[12_000][0].abs() < 1e-5,
        "gate did not attenuate: {}",
        keyed[12_000][0]
    );

    // And it reaches EXACTLY zero, not "small". A 10 ms release needs ~22 000
    // frames to cross the 1e-20 flush floor from unity; the assertion starts
    // well past that and stops before the next key pulse at 48 000.
    for (i, f) in keyed.iter().enumerate().take(47_000).skip(30_000) {
        assert_eq!(*f, [0.0, 0.0], "gate did not reach exact silence at frame {i}");
    }

    // Self-keyed on the same audio: the tone is above threshold throughout,
    // so the gate stays open — a measurably different output from the same
    // input, driven only by the key.
    let mut unit = FxUnit::new(FxKindId::Gate, SR, RAMP);
    let self_keyed = render_blocks(&mut unit, &bank, &tone, &tone, 128);
    let self_rms: f64 = {
        let s = &self_keyed[10_000..15_000];
        (s.iter().map(|f| f64::from(f[0]).powi(2)).sum::<f64>() / s.len() as f64).sqrt()
    };
    assert!(
        self_rms > 0.3,
        "self-keyed gate should stay open: {self_rms}"
    );
}

// ---------------------------------------------------------------------------
// 5. Bypass (§20.2 proof 3)
// ---------------------------------------------------------------------------

/// A bypassed fx is **bit-identical** to no fx, for every kind — including the
/// limiter, whose 96-frame lookahead makes "close enough" tempting.
#[test]
fn bypass_is_bit_exact_for_every_kind() {
    let n = 8_000;
    let input: Vec<[f32; 2]> = (0..n)
        .map(|i| {
            let t = i as f32 / SRF;
            [
                0.7 * (2.0 * std::f32::consts::PI * 330.0 * t).sin(),
                0.5 * (2.0 * std::f32::consts::PI * 550.0 * t).sin(),
            ]
        })
        .collect();

    for &kind in ALL_FX_KINDS.iter() {
        let bank = bank_for(kind);
        set(&bank, kind, "bypass", 1.0);
        let mut unit = FxUnit::new(kind, SR, RAMP);
        let out = render_blocks(&mut unit, &bank, &input, &input, 128);
        // Skip the declick ramp, then demand exactness.
        for (i, f) in out.iter().enumerate().skip(RAMP as usize + 8) {
            assert_eq!(*f, input[i], "{kind:?} bypass is not bit-exact at frame {i}");
        }
    }
}

/// The bypass transition ramps over `MICRO_FADE_FRAMES` instead of stepping.
/// Asserted as a bounded per-frame delta across the whole transition, not just
/// on the endpoints.
#[test]
fn bypass_transition_ramps_over_micro_fade_frames() {
    let n = 4_000;
    let input = dc(1.0, n);
    let bank = bank_for(FxKindId::Utility);
    set(&bank, FxKindId::Utility, "gain", -12.0);
    let processed = db_to_lin(-12.0);

    let mut unit = FxUnit::new(FxKindId::Utility, SR, RAMP);
    // Settle un-bypassed.
    let first = render_blocks(&mut unit, &bank, &input, &input, 128);
    assert!((first[n - 1][0] - processed).abs() < 1e-6);

    // Flip to bypassed and watch the transition. The two renders are
    // CONCATENATED before the per-frame delta is measured: a `snap` in
    // `load_block_targets` puts the whole step at the boundary between them,
    // where a window over the second buffer alone cannot see it. (That is
    // exactly how this test first passed against a snapping mutant.)
    set(&bank, FxKindId::Utility, "bypass", 1.0);
    let tail = render_blocks(&mut unit, &bank, &input, &input, 128);
    let mut out = first.clone();
    out.extend(tail.iter().copied());

    // Measure across the flip only: the head of `first` contains the Utility's
    // own gain ramp settling from unity to -12 dB, which is a different (and
    // legitimate) ramp.
    let max_step = out[n - 4..]
        .windows(2)
        .map(|w| (w[1][0] - w[0][0]).abs())
        .fold(0.0_f32, f32::max);
    let ideal = (1.0 - processed) / RAMP as f32;
    assert!(
        max_step <= ideal * 1.05,
        "bypass stepped: max per-frame delta {max_step} vs ideal ramp step {ideal}"
    );

    // And it completes within the declick window (plus the block boundary at
    // which the new target is first read), measured from the flip.
    let done = tail
        .iter()
        .position(|f| f[0] == 1.0)
        .expect("bypass reaches exactly unity");
    assert!(
        done <= RAMP as usize + 128,
        "bypass took {done} frames, window is {RAMP}"
    );
    // ...and it does NOT complete instantly, which is what a snap would do.
    assert!(
        done >= RAMP as usize - 8,
        "bypass completed in {done} frames: that is a snap, not a {RAMP}-frame ramp"
    );
}

// ---------------------------------------------------------------------------
// 6. Saturator: measured harmonic generation
// ---------------------------------------------------------------------------

/// Drive is proven by **measuring the harmonic content it creates**, not by
/// observing that the buffer changed. Odd symmetry is asserted too: the 2nd
/// harmonic must stay negligible while the 3rd grows with drive.
#[test]
fn saturator_generates_odd_harmonics_in_proportion_to_drive() {
    // 100 cycles of 1 kHz at 48 k = 4800 frames, an integer number of cycles
    // for both the fundamental and its harmonics: no spectral leakage.
    let n = 4_800;
    let f0 = 1_000.0_f32;
    let input = sine(f0, 0.7, n);

    let measure = |drive_db: f32| -> (f64, f64) {
        let bank = bank_for(FxKindId::Saturator);
        set(&bank, FxKindId::Saturator, "drive", drive_db);
        set(&bank, FxKindId::Saturator, "mix", 1.0);
        set(&bank, FxKindId::Saturator, "gain", 0.0);
        let mut unit = FxUnit::new(FxKindId::Saturator, SR, RAMP);
        // Two passes so the drive Slew is fully settled before measuring.
        let _ = render_blocks(&mut unit, &bank, &input, &input, 128);
        let out = render_blocks(&mut unit, &bank, &input, &input, 128);
        let l = left(&out);
        let h1 = bin_magnitude(&l, f0);
        let h2 = bin_magnitude(&l, f0 * 2.0);
        let h3 = bin_magnitude(&l, f0 * 3.0);
        (h2 / h1, h3 / h1)
    };

    let (h2_low, h3_low) = measure(-24.0);
    let (h2_high, h3_high) = measure(24.0);
    eprintln!(
        "SATURATOR drive=-24dB h2/h1={h2_low:.3e} h3/h1={h3_low:.3e} |          drive=+24dB h2/h1={h2_high:.3e} h3/h1={h3_high:.3e}"
    );

    // Odd-symmetric curve: essentially no even harmonics at either drive.
    assert!(h2_low < 1e-4, "2nd harmonic at low drive: {h2_low}");
    assert!(h2_high < 1e-4, "2nd harmonic at high drive: {h2_high}");

    // At -24 dB drive the curve is nearly linear over the signal range.
    assert!(h3_low < 5e-3, "low drive should be nearly clean: {h3_low}");
    // At +24 dB it is deep into saturation.
    assert!(h3_high > 0.15, "high drive should saturate hard: {h3_high}");
    assert!(
        h3_high / h3_low > 50.0,
        "drive did not change the harmonic content: {h3_low} -> {h3_high}"
    );

    // And it is monotone in between, which a "did it change" test misses.
    let mut last = 0.0_f64;
    for drive in [-12.0_f32, 0.0, 12.0, 24.0] {
        let (_, h3) = measure(drive);
        assert!(h3 > last, "3rd harmonic not monotone at drive {drive}: {h3}");
        last = h3;
    }
}

// ---------------------------------------------------------------------------
// 7. Chorus: measured pitch deviation against 2*pi*rate*depth
// ---------------------------------------------------------------------------

/// The closed form for a sinusoidally modulated delay is
/// `peak |Δf/f| = 2π · rate · depth_seconds`.
///
/// This constrains **rate and depth jointly**. A chorus that ignored `depth`,
/// or that quantised its tap to whole frames (killing the modulation), cannot
/// satisfy it, and neither can one that modulates at the wrong rate — the
/// second row is the same depth at double the rate and must double the
/// deviation.
#[test]
fn chorus_pitch_deviation_matches_two_pi_rate_depth() {
    let f0 = 500.0_f32;
    let n = 96_000; // 2 s
    let input = sine(f0, 0.8, n);
    let silence = dc(0.0, n);

    // Out-of-band noise: linear interpolation of the fractional tap keeps a
    // pure tone pure. Quantising the tap to whole frames injects a phase
    // discontinuity on every tap change, which is broadband. Measured well
    // away from the carrier and its modulation sidebands.
    {
        let bank = bank_for(FxKindId::Chorus);
        set(&bank, FxKindId::Chorus, "rate", 2.0);
        set(&bank, FxKindId::Chorus, "depth", 4.0);
        set(&bank, FxKindId::Chorus, "mix", 1.0);
        set(&bank, FxKindId::Chorus, "spread", 0.0);
        let mut unit = FxUnit::new(FxKindId::Chorus, SR, RAMP);
        let out = render_blocks(&mut unit, &bank, &input, &silence, 128);
        let tail = left(&out[48_000..]);
        let fund = bin_magnitude(&tail, f0);
        for probe in [3_700.0_f32, 7_100.0, 11_300.0] {
            let noise = bin_magnitude(&tail, probe) / fund;
            eprintln!("CHORUS out-of-band {probe} Hz / fundamental = {noise:.3e}");
            assert!(
                noise < 1.0e-3,
                "fractional tap interpolation lost: {probe} Hz noise is {noise:.3e} of \
                 the fundamental. A whole-frame tap makes this broadband."
            );
        }
    }

    let measure = |rate: f32, depth_ms: f32| -> f32 {
        let bank = bank_for(FxKindId::Chorus);
        set(&bank, FxKindId::Chorus, "rate", rate);
        set(&bank, FxKindId::Chorus, "depth", depth_ms);
        set(&bank, FxKindId::Chorus, "mix", 1.0); // 100 % wet
        set(&bank, FxKindId::Chorus, "spread", 0.0);

        let mut unit = FxUnit::new(FxKindId::Chorus, SR, RAMP);
        let out = render_blocks(&mut unit, &bank, &input, &silence, 128);
        let l = left(&out);
        // Skip the ring fill + parameter slews.
        let crossings = upward_crossings(&l[24_000..]);
        assert!(
            crossings.len() > 100,
            "not enough zero crossings to measure: {}",
            crossings.len()
        );
        let periods: Vec<f64> = crossings.windows(2).map(|w| w[1] - w[0]).collect();
        let fmax = f64::from(SRF) / periods.iter().cloned().fold(f64::INFINITY, f64::min);
        let fmin = f64::from(SRF) / periods.iter().cloned().fold(0.0_f64, f64::max);
        // Peak deviation either side of the carrier, as a fraction.
        (((fmax - fmin) / 2.0) / f64::from(f0)) as f32
    };

    for &(rate, depth_ms) in &[(2.0_f32, 4.0_f32), (4.0, 4.0), (2.0, 8.0)] {
        let expected = ChorusFx::expected_pitch_deviation(rate, depth_ms);
        let measured = measure(rate, depth_ms);
        eprintln!(
            "CHORUS rate={rate:.1} Hz depth={depth_ms:.1} ms measured_dev={measured:.5}              2pi*rate*depth={expected:.5} ratio={:.3}",
            measured / expected
        );
        assert!(
            (measured - expected).abs() < expected * 0.15,
            "rate={rate} Hz depth={depth_ms} ms: measured deviation {measured:.5}, \
             2*pi*rate*depth = {expected:.5}"
        );
    }

    // The joint constraint, stated as a ratio so a constant-deviation
    // implementation cannot pass: doubling rate doubles deviation, and so
    // does doubling depth.
    let base = measure(2.0, 4.0);
    let double_rate = measure(4.0, 4.0);
    let double_depth = measure(2.0, 8.0);
    assert!(
        (double_rate / base - 2.0).abs() < 0.2,
        "doubling rate gave {:.3}x, not 2x",
        double_rate / base
    );
    assert!(
        (double_depth / base - 2.0).abs() < 0.2,
        "doubling depth gave {:.3}x, not 2x",
        double_depth / base
    );
}

// ---------------------------------------------------------------------------
// 8. Reuse wrappers behave, and latency is honest
// ---------------------------------------------------------------------------

/// §20.2 proof 1, on the kind §17.1 calls trivial: a `Utility` at −6 dB halves
/// what passes through it, and changes nothing else.
#[test]
fn utility_at_minus_six_db_halves_the_signal() {
    let n = 4_000;
    let input = dc(0.5, n);
    let bank = bank_for(FxKindId::Utility);
    set(&bank, FxKindId::Utility, "gain", -6.020_6);
    let mut unit = FxUnit::new(FxKindId::Utility, SR, RAMP);
    let out = render_blocks(&mut unit, &bank, &input, &input, 128);
    assert!((out[n - 1][0] - 0.25).abs() < 1e-4, "{:?}", out[n - 1]);
    assert!((out[n - 1][1] - 0.25).abs() < 1e-4, "{:?}", out[n - 1]);
}

/// §17.1 / §19.1: **only the limiter carries latency**, it reports exactly the
/// 96 frames its lookahead costs, and that report does not change when the
/// unit is bypassed. PDC compensates topology, not switch position; a
/// bypass-dependent `latency_frames` would make the compensated delay wrong
/// every time a user clicked the bypass button.
#[test]
fn only_the_limiter_reports_latency_and_bypass_does_not_change_it() {
    for &kind in ALL_FX_KINDS.iter() {
        let expected = if kind == FxKindId::Limiter { 96 } else { 0 };
        let mut unit = FxUnit::new(kind, SR, RAMP);
        assert_eq!(unit.latency_frames(), expected, "{kind:?}");

        let bank = bank_for(kind);
        set(&bank, kind, "bypass", 1.0);
        let input = dc(0.3, 1_000);
        let _ = render_blocks(&mut unit, &bank, &input, &input, 128);
        assert_eq!(
            unit.latency_frames(),
            expected,
            "{kind:?}: latency changed under bypass"
        );
    }
}

/// The limiter wrapper genuinely limits: a signal well over the ceiling comes
/// out at or under it. (The primitive is `dsp/limiter.rs` — this asserts the
/// wrapper wires the ceiling through, not that Freeverb-era code works.)
#[test]
fn limiter_wrapper_holds_its_ceiling() {
    let n = 24_000;
    let input = sine(220.0, 0.95, n);
    let bank = bank_for(FxKindId::Limiter);
    set(&bank, FxKindId::Limiter, "ceiling", -6.0);
    let mut unit = FxUnit::new(FxKindId::Limiter, SR, RAMP);
    let out = render_blocks(&mut unit, &bank, &input, &input, 128);
    let ceiling = db_to_lin(-6.0);
    let peak = out[4_000..]
        .iter()
        .map(|f| f[0].abs().max(f[1].abs()))
        .fold(0.0_f32, f32::max);
    assert!(
        peak <= ceiling * 1.02,
        "peak {peak} exceeds the -6 dB ceiling {ceiling}"
    );
    assert!(peak > ceiling * 0.5, "limiter over-attenuated: {peak}");
    assert!(
        unit.take_block_meter() < 1.0,
        "limiter reported no gain reduction while limiting"
    );
}

/// The Delay and Reverb wrappers add the dry/wet an insert needs to the
/// 100 %-wet send-bus primitives they reuse, and `mix = 0` is exact.
#[test]
fn delay_and_reverb_wrappers_respect_their_mix() {
    let n = 24_000;
    let input = sine(330.0, 0.5, n);
    for kind in [FxKindId::Delay, FxKindId::Reverb] {
        let bank = bank_for(kind);
        set(&bank, kind, "mix", 0.0);
        let mut unit = FxUnit::new(kind, SR, RAMP);
        let out = render_blocks(&mut unit, &bank, &input, &input, 128);
        for (i, f) in out.iter().enumerate().skip(RAMP as usize + 8) {
            assert_eq!(*f, input[i], "{kind:?} mix=0 is not exact at frame {i}");
        }

        set(&bank, kind, "mix", 1.0);
        let mut unit = FxUnit::new(kind, SR, RAMP);
        let wet = render_blocks(&mut unit, &bank, &input, &input, 128);
        let differs = wet
            .iter()
            .zip(input.iter())
            .skip(12_000)
            .any(|(a, b)| a != b);
        assert!(differs, "{kind:?} mix=1 produced the dry signal");
    }
}

/// The `Eq` wrapper is the existing `EqBank`: a −24 dB bell must actually cut
/// its band, measured, and flat bands must pass bit-exactly.
#[test]
fn eq_wrapper_cuts_its_band_and_is_exact_when_flat() {
    let n = 4_800;
    let f0 = 400.0_f32; // BAND_DEFAULT_HZ[1]
    let input = sine(f0, 0.5, n);

    let bank = bank_for(FxKindId::Eq);
    let mut unit = FxUnit::new(FxKindId::Eq, SR, RAMP);
    let flat = render_blocks(&mut unit, &bank, &input, &input, 128);
    for (i, f) in flat.iter().enumerate() {
        assert_eq!(*f, input[i], "flat EQ is not a bit-exact bypass at frame {i}");
    }

    set(&bank, FxKindId::Eq, "band1Gain", -24.0);
    set(&bank, FxKindId::Eq, "band1Q", 1.0);
    let mut unit = FxUnit::new(FxKindId::Eq, SR, RAMP);
    let _ = render_blocks(&mut unit, &bank, &input, &input, 128);
    let cut = render_blocks(&mut unit, &bank, &input, &input, 128);
    let before = bin_magnitude(&left(&input), f0);
    let after = bin_magnitude(&left(&cut), f0);
    let db = 20.0 * (after / before).log10();
    assert!(
        (db + 24.0).abs() < 1.5,
        "-24 dB bell measured {db:.2} dB at {f0} Hz"
    );
}

// ---------------------------------------------------------------------------
// 9. Registry sanity that E5-model and E5-graph consume
// ---------------------------------------------------------------------------

/// The param-key union E5-model needs for `FX_PARAM_KEYS` (§16.3), and the
/// slot arithmetic E5-graph needs to lay out the flat fx-param slab.
#[test]
fn registry_exposes_a_consistent_slot_layout() {
    let keys = all_fx_param_keys();
    assert!(
        keys.len() >= 30,
        "expected the full fx param vocabulary, got {}: {keys:?}",
        keys.len()
    );

    assert!(keys.contains(&BYPASS_KEY), "bypass must appear in FX_PARAM_KEYS");

    // §23.4 slot arithmetic: nine fx in one chain, each at its fixed stride,
    // must not overlap.
    let bank = EngineParams::new(4);
    for (fx_slot, &kind) in ALL_FX_KINDS.iter().enumerate() {
        seed_fx_defaults(&bank, kind, fx_slot);
    }
    for (fx_slot, &kind) in ALL_FX_KINDS.iter().enumerate() {
        let base = base_slot_of(fx_slot);
        assert_eq!(base, fx_slot * MAX_FX_PARAMS_PER_FX);
        for (i, spec) in kind.params().iter().enumerate() {
            assert_eq!(
                bank.fx_param_target(base + i),
                spec.default,
                "{kind:?} at fx slot {fx_slot}, param {i} ({}) was overwritten by a neighbour",
                spec.key
            );
        }
    }

    // `CompressorFx`'s curve is public so E5-ui can draw the same one the DSP
    // applies, rather than a second implementation that disagrees.
    assert_eq!(
        CompressorFx::gain_reduction_db(-10.0, -20.0, 4.0, 0.0),
        10.0 * (0.25 - 1.0)
    );
}

// ---------------------------------------------------------------------------
// 10. Parameters that a first pass leaves uncovered
// ---------------------------------------------------------------------------
//
// Written after auditing the mutation table: `mix`, `makeup`, `knee`,
// `detector` and `spread` were all pinned at one value by every test above, so
// deleting the code that reads them would have left the suite GREEN. That is
// the row-7 bug class in miniature — a parameter that compiles into a slot and
// nothing reads — so each one gets a rendered, quantitative proof.

/// Parallel (NY) compression: `mix` blends the compressed and dry paths, and
/// its endpoints are exact.
#[test]
fn compressor_mix_blends_dry_and_compressed_paths() {
    let n = 48_000;
    let amp = db_to_lin(-6.0);
    let input = dc(amp, n);

    let run = |mix: f32| -> f32 {
        let bank = bank_for(FxKindId::Compressor);
        set(&bank, FxKindId::Compressor, "threshold", -30.0);
        set(&bank, FxKindId::Compressor, "ratio", 8.0);
        set(&bank, FxKindId::Compressor, "knee", 0.0);
        set(&bank, FxKindId::Compressor, "attack", 1.0);
        set(&bank, FxKindId::Compressor, "makeup", 0.0);
        set(&bank, FxKindId::Compressor, "mix", mix);
        let mut unit = FxUnit::new(FxKindId::Compressor, SR, RAMP);
        render_blocks(&mut unit, &bank, &input, &input, 128)[n - 1][0]
    };

    let dry = run(0.0);
    assert_eq!(dry, amp, "mix=0 must be a bit-exact dry pass-through");

    let wet = run(1.0);
    assert!(wet < amp * 0.2, "mix=1 should be heavily compressed: {wet}");

    let half = run(0.5);
    let expected = dry + (wet - dry) * 0.5;
    assert!(
        (half - expected).abs() < 1e-6,
        "mix=0.5 gave {half}, linear blend of {dry} and {wet} is {expected}"
    );
}

/// Makeup gain is applied to the compressed path. Ratio 1:1 isolates it from
/// the gain computer entirely, so this measures makeup and nothing else.
#[test]
fn compressor_makeup_gain_is_applied() {
    let n = 24_000;
    let amp = 0.25_f32;
    let input = dc(amp, n);
    for &makeup_db in &[0.0_f32, 6.020_6, -6.020_6] {
        let bank = bank_for(FxKindId::Compressor);
        set(&bank, FxKindId::Compressor, "ratio", 1.0);
        set(&bank, FxKindId::Compressor, "threshold", -60.0);
        set(&bank, FxKindId::Compressor, "makeup", makeup_db);
        set(&bank, FxKindId::Compressor, "mix", 1.0);
        let mut unit = FxUnit::new(FxKindId::Compressor, SR, RAMP);
        let out = render_blocks(&mut unit, &bank, &input, &input, 128)[n - 1][0];
        let expected = amp * db_to_lin(makeup_db);
        assert!(
            (out - expected).abs() < 1e-5,
            "makeup {makeup_db} dB: got {out}, expected {expected}"
        );
    }
}

/// A soft knee reduces gain *below* the threshold, where a hard knee does
/// exactly nothing. Measured at the knee's lower hinge and at the threshold.
#[test]
fn compressor_knee_softens_the_transition() {
    let n = 24_000;
    let threshold = -20.0_f32;
    let knee = 12.0_f32;

    let run = |level_db: f32, knee_db: f32| -> f32 {
        let amp = db_to_lin(level_db);
        let input = dc(amp, n);
        let bank = bank_for(FxKindId::Compressor);
        set(&bank, FxKindId::Compressor, "threshold", threshold);
        set(&bank, FxKindId::Compressor, "ratio", 4.0);
        set(&bank, FxKindId::Compressor, "knee", knee_db);
        set(&bank, FxKindId::Compressor, "attack", 1.0);
        set(&bank, FxKindId::Compressor, "mix", 1.0);
        let mut unit = FxUnit::new(FxKindId::Compressor, SR, RAMP);
        let out = render_blocks(&mut unit, &bank, &input, &input, 128)[n - 1][0];
        lin_to_db(out / amp)
    };

    // Exactly at the threshold: hard knee = 0 dB, soft knee already reducing.
    let hard_at_thr = run(threshold, 0.0);
    let soft_at_thr = run(threshold, knee);
    assert_eq!(hard_at_thr, 0.0, "hard knee at threshold must be exactly 0 dB");
    assert!(
        soft_at_thr < -0.5,
        "soft knee should already reduce at the threshold: {soft_at_thr:.4} dB"
    );
    // The closed form: slope * (knee/2)^2 / (2*knee) at `over == 0`.
    let expected = (0.25 - 1.0) * (knee * 0.5) * (knee * 0.5) / (2.0 * knee);
    assert!(
        (soft_at_thr - expected).abs() < 0.02,
        "soft knee at threshold: {soft_at_thr:.4} dB vs closed form {expected:.4} dB"
    );

    // Below the knee's lower hinge, both are exactly 0 dB.
    let below = threshold - knee;
    assert_eq!(run(below, knee), 0.0);
}

/// Peak vs RMS detection, measured as the 3.01 dB level difference between
/// the peak and the RMS of a sine, mapped through the known ratio slope.
#[test]
fn compressor_detector_mode_changes_the_measured_level() {
    let n = 96_000;
    let amp = 0.5_f32;
    let input = sine(400.0, amp, n);
    let ratio = 4.0_f32;
    let slope = 1.0 / ratio - 1.0;

    let run = |detector: f32| -> f64 {
        let bank = bank_for(FxKindId::Compressor);
        set(&bank, FxKindId::Compressor, "threshold", -40.0);
        set(&bank, FxKindId::Compressor, "ratio", ratio);
        set(&bank, FxKindId::Compressor, "knee", 0.0);
        // Fast attack + long release so the PEAK detector genuinely settles on
        // the peak. With a 50 ms attack it cannot track a 400 Hz waveform's
        // crests at all and parks between the peak and the mean, which
        // collapses the measured difference to ~1 dB and makes the test
        // measure the attack coefficient instead of the detector mode.
        set(&bank, FxKindId::Compressor, "attack", 0.1);
        set(&bank, FxKindId::Compressor, "release", 500.0);
        set(&bank, FxKindId::Compressor, "mix", 1.0);
        set(&bank, FxKindId::Compressor, "detector", detector);
        let mut unit = FxUnit::new(FxKindId::Compressor, SR, RAMP);
        let out = render_blocks(&mut unit, &bank, &input, &input, 128);
        // Compare the settled tail's magnitude at the fundamental.
        let tail: Vec<f32> = out[48_000..].iter().map(|f| f[0]).collect();
        bin_magnitude(&tail, 400.0)
    };

    let peak = run(0.0);
    let rms = run(1.0);
    let delta_db = 20.0 * (rms / peak).log10();
    // RMS reads the sine 3.01 dB lower, so it reduces LESS: the output is
    // louder by 3.01 * |slope| dB.
    let expected = -3.0103 * f64::from(slope);
    assert!(
        (delta_db - expected).abs() < 0.3,
        "peak vs RMS detection differed by {delta_db:.4} dB, expected {expected:.4} dB \
         (peak={peak:.6} rms={rms:.6})"
    );
    assert!(
        delta_db.abs() > 1.0,
        "the detector mode did not change the result at all: {delta_db:.4} dB"
    );
}

/// `spread` offsets the right channel's LFO. At 0 the two channels are
/// identical for identical input; at 0.25 they are measurably decorrelated.
#[test]
fn chorus_spread_decorrelates_the_channels() {
    let n = 48_000;
    let input = sine(500.0, 0.7, n);
    let silence = dc(0.0, n);

    let run = |spread: f32| -> Vec<[f32; 2]> {
        let bank = bank_for(FxKindId::Chorus);
        set(&bank, FxKindId::Chorus, "rate", 2.0);
        set(&bank, FxKindId::Chorus, "depth", 4.0);
        set(&bank, FxKindId::Chorus, "mix", 1.0);
        set(&bank, FxKindId::Chorus, "spread", spread);
        let mut unit = FxUnit::new(FxKindId::Chorus, SR, RAMP);
        render_blocks(&mut unit, &bank, &input, &silence, 128)
    };

    let mono = run(0.0);
    for (i, f) in mono.iter().enumerate().skip(24_000) {
        assert_eq!(f[0], f[1], "spread=0 must be channel-identical at frame {i}");
    }

    let wide = run(0.25);
    let max_diff = wide[24_000..]
        .iter()
        .map(|f| (f[0] - f[1]).abs())
        .fold(0.0_f32, f32::max);
    assert!(
        max_diff > 0.1,
        "spread=0.25 did not decorrelate the channels: max |L-R| = {max_diff}"
    );
}

/// **No inert parameter slots.** For every kind, for every parameter it
/// declares, perturbing that parameter must change the rendered buffer.
///
/// This is §0 row 7's bug class turned into a standing check: a parameter that
/// compiles into a slot and that nothing reads is *the default outcome, not
/// the unlikely one* (§20.2 proof 9). The targeted tests above prove specific
/// parameters behave **correctly**; this one proves that none of the other
/// 55 slots is silently dead.
///
/// The stimulus is deliberately busy — tone bursts near full scale, with
/// silence between them and a stereo difference — because different params
/// need different signal features to show up: `release` needs decays, `hold`
/// needs gaps, `width`/`spread` need L != R, `ceiling` needs peaks above it.
#[test]
fn no_parameter_slot_is_inert() {
    let n = 48_000;
    let stimulus: Vec<[f32; 2]> = (0..n)
        .map(|i| {
            let t = i as f32 / SRF;
            let on = (i / 4_000) % 2 == 0;
            let env = if on { 0.98 } else { 0.0 };
            let l = env * (2.0 * std::f32::consts::PI * 300.0 * t).sin();
            let r = env
                * (0.5 * (2.0 * std::f32::consts::PI * 300.0 * t).sin()
                    + 0.5 * (2.0 * std::f32::consts::PI * 900.0 * t).sin());
            [l, r]
        })
        .collect();

    // The single documented exception, with its reason.
    // `Eq` band Q and frequency do nothing while a band sits at 0 dB — a flat
    // biquad is the identity regardless of its shape, by construction
    // (`dsp/biquad.rs`: "a band at 0 dB gain produces coefficients where
    // b0 == 1 ... a true bypass"). So the EQ baseline puts every band off flat.
    let base_for = |kind: FxKindId| -> EngineParams {
        let b = bank_for(kind);
        if kind == FxKindId::Eq {
            for band in 0..4 {
                assert!(set_fx_param_by_key(
                    &b,
                    kind,
                    0,
                    &format!("band{band}Gain"),
                    -6.0
                ));
            }
        }
        b
    };

    let run = |kind: FxKindId, bank: &EngineParams| -> Vec<[f32; 2]> {
        let mut unit = FxUnit::new(kind, SR, RAMP);
        let out = render_blocks(&mut unit, bank, &stimulus, &stimulus, 128);
        // Every param is driven to an extreme of its declared range here, so
        // this doubles as a finiteness sweep over the whole parameter space.
        assert_all_finite(&format!("{kind:?} extreme params"), &out);
        out
    };

    let mut checked = 0_usize;
    for &kind in ALL_FX_KINDS.iter() {
        let base_bank = base_for(kind);
        let reference = run(kind, &base_bank);

        for (i, spec) in kind.params().iter().enumerate() {
            let current = base_bank.fx_param_target(i);
            // Perturb as far from the current value as the range allows.
            let perturbed = if (current - spec.min).abs() >= (spec.max - current).abs() {
                spec.min
            } else {
                spec.max
            };
            assert_ne!(
                perturbed, current,
                "{kind:?} {}: degenerate range, cannot perturb",
                spec.key
            );

            let bank = base_for(kind);
            bank.set_fx_param(i, perturbed);
            let got = run(kind, &bank);
            let differs = got.iter().zip(reference.iter()).any(|(a, b)| a != b);
            assert!(
                differs,
                "INERT SLOT: {kind:?} param {:?} (slot {i}) moved {current} -> {perturbed} \
                 and the rendered buffer did not change by a single sample",
                spec.key
            );
            checked += 1;
        }
    }

    // `bypass` has no slot (§23.4) but is still a parameter the render side
    // must read, so it is swept through its own setter.
    for &kind in ALL_FX_KINDS.iter() {
        let base_bank = base_for(kind);
        let reference = run(kind, &base_bank);
        let bypassed = base_for(kind);
        bypassed.set_fx_bypass(0, true);
        let got = run(kind, &bypassed);
        assert!(
            got.iter().zip(reference.iter()).any(|(a, b)| a != b),
            "INERT: {kind:?} ignores fx_bypassed()"
        );
        checked += 1;
    }

    // Guard against the sweep silently shrinking to nothing.
    let expected: usize =
        ALL_FX_KINDS.iter().map(|k| k.param_count()).sum::<usize>() + ALL_FX_KINDS.len();
    assert_eq!(checked, expected, "the sweep did not cover every slot");
    assert!(checked >= 50, "only {checked} slots swept");
}


/// **No kind produces a non-finite sample**, under hostile parameters or
/// hostile audio (§23.4).
///
/// `EngineParams::set_fx_param` drops non-finite writes, so the hostile-param
/// half also proves that dropping them is enough: the slot keeps whatever it
/// held, and `read_param`'s clamp covers the finite-but-absurd values that DO
/// get through (1e30 is a legal write). The classic sources are a `log` of a
/// zero envelope and a division by a zero ratio; both are exercised here by
/// leaving a slab unseeded (every slot reads `FX_PARAM_CLEARED` = 0.0) while
/// feeding exact digital silence.
#[test]
fn no_kind_produces_a_non_finite_sample() {
    // Hostile audio: exact silence, denormals, full scale, a hot bus well over
    // full scale, an alternating-sign square, and isolated spikes.
    let n = 12_000;
    let hostile: Vec<[f32; 2]> = (0..n)
        .map(|i| match i / 2_000 {
            0 => [0.0, 0.0],
            1 => [1.0e-40, -1.0e-40],
            2 => [1.0, -1.0],
            3 => [4.0, -4.0],
            4 => {
                let v = if i % 2 == 0 { 1.0 } else { -1.0 };
                [v, -v]
            }
            _ => {
                if i % 500 == 0 {
                    [8.0, -8.0]
                } else {
                    [0.0, 0.0]
                }
            }
        })
        .collect();

    for &kind in ALL_FX_KINDS.iter() {
        // (a) UNSEEDED slab: every parameter reads FX_PARAM_CLEARED (0.0).
        //     For the compressor that is `ratio = 0` before `read_param`'s
        //     clamp, i.e. the division-by-zero case.
        let raw = EngineParams::new(4);
        let mut unit = FxUnit::new(kind, SR, RAMP);
        let out = render_blocks(&mut unit, &raw, &hostile, &hostile, 128);
        assert_all_finite(&format!("{kind:?} unseeded params"), &out);

        // (b) Non-finite and absurd writes into every slot.
        let hostile_params = bank_for(kind);
        for bad in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY, 1.0e30, -1.0e30] {
            for i in 0..kind.param_count() {
                hostile_params.set_fx_param(base_slot_of(0) + i, bad);
            }
            let mut unit = FxUnit::new(kind, SR, RAMP);
            let out = render_blocks(&mut unit, &hostile_params, &hostile, &hostile, 128);
            assert_all_finite(&format!("{kind:?} params all = {bad}"), &out);
        }

        // (c) Silence in, silence out — and exactly zero, so an idle chain
        //     carries no denormal residue into the next node.
        let quiet = bank_for(kind);
        let mut unit = FxUnit::new(kind, SR, RAMP);
        let silence = dc(0.0, 4_000);
        let out = render_blocks(&mut unit, &quiet, &silence, &silence, 128);
        assert_all_finite(&format!("{kind:?} silence"), &out);
        for (i, f) in out.iter().enumerate().skip(RAMP as usize + 8) {
            assert_eq!(*f, [0.0, 0.0], "{kind:?} is not silent on silence at frame {i}");
        }
    }
}

/// Everything above sits an fx at slot 0, where `base_slot == 0` and a broken
/// `fx_slot_of` / stride would be invisible. E5-graph will use slots 0..255,
/// so the mapping gets its own proof at a NON-ZERO slot: the effect must read
/// its own block, and a differently-configured neighbour at slot 0 must not
/// reach it.
#[test]
fn an_fx_at_a_nonzero_slot_reads_its_own_block() {
    let n = 24_000;
    let input = dc(0.5, n);
    let fx_slot = 5_usize;
    let base = base_slot_of(fx_slot);
    assert_eq!(base, fx_slot * MAX_FX_PARAMS_PER_FX);

    let p = EngineParams::new(4);
    // A decoy at slot 0 with the opposite setting, and a decoy immediately
    // before ours, so an off-by-one stride lands on a wrong but plausible value.
    seed_fx_defaults(&p, FxKindId::Utility, 0);
    assert!(set_fx_param_by_key(&p, FxKindId::Utility, 0, "gain", 24.0));
    seed_fx_defaults(&p, FxKindId::Utility, fx_slot - 1);
    assert!(set_fx_param_by_key(&p, FxKindId::Utility, fx_slot - 1, "gain", 12.0));

    seed_fx_defaults(&p, FxKindId::Utility, fx_slot);
    assert!(set_fx_param_by_key(
        &p,
        FxKindId::Utility,
        fx_slot,
        "gain",
        -6.020_6
    ));

    let mut unit = FxUnit::new(FxKindId::Utility, SR, RAMP);
    let mut i = 0;
    let mut out = Vec::with_capacity(n);
    while i < n {
        unit.load_block_targets(&p, base);
        let end = (i + 128).min(n);
        for f in i..end {
            out.push(unit.process_frame(input[f], input[f]));
        }
        i = end;
    }
    assert!(
        (out[n - 1][0] - 0.25).abs() < 1e-4,
        "read the wrong parameter block: got {} for a -6 dB Utility at fx slot {fx_slot}",
        out[n - 1][0]
    );

    // And bypass is resolved per INSTANCE, not globally: bypassing slot 0 must
    // not bypass slot 5.
    p.set_fx_bypass(0, true);
    let mut unit = FxUnit::new(FxKindId::Utility, SR, RAMP);
    let mut i = 0;
    let mut out = Vec::with_capacity(n);
    while i < n {
        unit.load_block_targets(&p, base);
        let end = (i + 128).min(n);
        for f in i..end {
            out.push(unit.process_frame(input[f], input[f]));
        }
        i = end;
    }
    assert!(
        (out[n - 1][0] - 0.25).abs() < 1e-4,
        "bypassing fx slot 0 bypassed fx slot {fx_slot}: {}",
        out[n - 1][0]
    );

    // Bypassing OUR slot does take effect.
    p.set_fx_bypass(fx_slot, true);
    let mut unit = FxUnit::new(FxKindId::Utility, SR, RAMP);
    let mut i = 0;
    let mut out = Vec::with_capacity(n);
    while i < n {
        unit.load_block_targets(&p, base);
        let end = (i + 128).min(n);
        for f in i..end {
            out.push(unit.process_frame(input[f], input[f]));
        }
        i = end;
    }
    assert_eq!(out[n - 1], [0.5, 0.5], "bypass at the right slot is exact");
}

/// **Cross-lane conformance: every key this lane declares is in E5-model's
/// `FX_PARAM_KEYS`.**
///
/// The vocabulary is E5-model's to own (`timeline-core/src/model.rs`) and
/// `apply.rs` validates the wire `key` against it. A DSP key outside that list
/// could never be set by any command — it would be an effect parameter with no
/// way to reach it, which §16.0 row 24 calls "not an effect". Improvising a
/// name here and having it renamed later is exactly the semantic merge
/// conflict the design document exists to prevent, so it is pinned in code
/// rather than checked by eye.
///
/// The EQ keys are FLAT (`band0Gain`, not `band.0.gain`) because the ParamRef
/// grammar gives an fx exactly one parameter segment.
#[test]
fn fx_keys_are_all_in_the_model_vocabulary() {
    use timeline_core::model::FX_PARAM_KEYS;

    for &kind in ALL_FX_KINDS.iter() {
        for spec in kind.params() {
            assert!(
                FX_PARAM_KEYS.contains(&spec.key),
                "{kind:?} declares {:?}, which is not in FX_PARAM_KEYS. Either use an \
                 existing key or ask E5-model to widen the list — do not improvise a name.",
                spec.key
            );
        }
    }
    assert!(FX_PARAM_KEYS.contains(&BYPASS_KEY));

    // Report the keys the vocabulary carries that no kind uses, so a drift in
    // either direction is visible rather than silent. `division` is E5-model's
    // provision for a tempo-synced delay time; this suite's `Delay` takes an
    // absolute `time` in ms (the tempo resolution is control-side, per
    // `dsp/delay.rs`), so it is deliberately unused HERE, not dead.
    let mine = all_fx_param_keys();
    let unused: Vec<&str> = FX_PARAM_KEYS
        .iter()
        .copied()
        .filter(|k| !mine.contains(k))
        .collect();
    assert_eq!(
        unused,
        vec!["division"],
        "the set of FX_PARAM_KEYS no effect implements has changed"
    );
}
