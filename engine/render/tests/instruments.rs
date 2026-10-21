//! E2 instrument bars, as automated tests.
//!
//! 1. **Block-size parity** — the same instrument playing the same notes
//!    renders BIT-IDENTICALLY at 128 / 417 / 480 / 512, including under
//!    per-frame automation and under voice-stealing overload. This is the
//!    property the design calls the parity gate; it is what makes an offline
//!    bounce equal the realtime callback, and it holds only because every
//!    piece of instrument state advances per FRAME.
//! 2. **Allocation-free** — the counting global allocator observes zero
//!    allocator hits inside render scopes while three instruments are hammered
//!    with note-ons, note-offs and steals. Preceded by a POSITIVE CONTROL that
//!    proves the guard can see an allocation at all (a `#[global_allocator]`
//!    that is not installed makes this whole file vacuously green).
//! 3. **The audio is real** — every assertion below is on a RENDERED BUFFER,
//!    not on model state. Solo shipped broken for months because a UI-state
//!    test passed while nothing was audible.
//!
//! Nothing here opens an output device. Every render is offline.

use std::sync::Arc;

use render::dsp::drum::{DrumKit, DrumPad, DrumRack, DEFAULT_BASE_PITCH};
use render::dsp::instrument::{
    Instrument, InstrumentNode, InstrumentParams, INSTRUMENT_PARAM_KEYS, PARAM_CUTOFF,
};
use render::dsp::note::{NoteEvent, NoteSchedule};
use render::dsp::osc::Waveform;
use render::dsp::sampler::{SampleMap, SampleZone, Sampler};
use render::dsp::synth::Synth;
use render::dsp::voice::DEFAULT_MAX_VOICES;
use render::guard;
use render::media::AudioBuf;
use render::offline::residual;
use render::rt::{ENGINE_SAMPLE_RATE, MICRO_FADE_FRAMES};

#[global_allocator]
static ALLOC: guard::CountingAlloc = guard::CountingAlloc;

const RAMP: u32 = MICRO_FADE_FRAMES as u32;
/// The four witnesses the engine's own null test uses (`graph.rs:593-660`,
/// `null_and_alloc.rs:113-149`): a live block size, a prime-ish odd one, and
/// two common bounce sizes.
const BLOCK_SIZES: [usize; 4] = [128, 417, 480, 512];

// ---------------------------------------------------------------------------
// fixtures
// ---------------------------------------------------------------------------

fn sine_buf(hz: f32, frames: usize) -> Arc<AudioBuf> {
    let samples: Vec<[f32; 2]> = (0..frames)
        .map(|i| {
            let v =
                (std::f32::consts::TAU * hz * i as f32 / ENGINE_SAMPLE_RATE as f32).sin();
            [v, v * 0.8]
        })
        .collect();
    AudioBuf::from_samples(samples, "sine")
}

/// A decaying noise-ish burst: deterministic (an LCG), so it is a fine drum
/// one-shot and a fine sampler source without touching the filesystem.
fn burst(frames: usize, decay: f32) -> Arc<AudioBuf> {
    let mut state = 0x2545_F491_4F6C_DD1D_u64;
    let samples: Vec<[f32; 2]> = (0..frames)
        .map(|i| {
            state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let r = ((state >> 33) as f32 / (1u64 << 31) as f32) - 1.0;
            let env = (-decay * i as f32 / frames as f32).exp();
            [r * env, r * env]
        })
        .collect();
    AudioBuf::from_samples(samples, "burst")
}

fn synth_params() -> InstrumentParams {
    InstrumentParams {
        waveform: Waveform::Saw.as_param(),
        cutoff_hz: 3_000.0,
        resonance: 0.4,
        attack_s: 0.004,
        decay_s: 0.08,
        sustain: 0.7,
        release_s: 0.15,
        gain_db: -6.0,
        transpose: 0.0,
        fine_cents: 0.0,
    }
}

fn synth_node(events: Vec<NoteEvent>, voices: usize) -> InstrumentNode {
    let synth = Synth::new(ENGINE_SAMPLE_RATE, voices, RAMP);
    let mut n = InstrumentNode::new("synth1", Instrument::Synth(synth), events);
    n.snap_to(&synth_params());
    n
}

fn sampler_node(events: Vec<NoteEvent>, voices: usize) -> InstrumentNode {
    let map = Arc::new(SampleMap::new(vec![
        SampleZone {
            audio: sine_buf(220.0, 24_000),
            root_pitch: 45,
            lo_pitch: 0,
            hi_pitch: 59,
            gain_lin: 1.0,
        },
        SampleZone {
            audio: burst(24_000, 3.0),
            root_pitch: 69,
            lo_pitch: 60,
            hi_pitch: 127,
            gain_lin: 0.9,
        },
    ]));
    let s = Sampler::new(map, ENGINE_SAMPLE_RATE, voices, RAMP);
    let mut n = InstrumentNode::new("sampler1", Instrument::Sampler(s), events);
    n.snap_to(&synth_params());
    n
}

fn drum_node(events: Vec<NoteEvent>, voices: usize) -> InstrumentNode {
    let kit = Arc::new(DrumKit::new(
        vec![
            Some(DrumPad::new(burst(4_800, 6.0))),
            Some(DrumPad::new(burst(2_400, 3.0))),
            Some(DrumPad {
                audio: burst(9_600, 1.5),
                gain_lin: 0.7,
                pan: -0.5,
            }),
            None,
            Some(DrumPad::new(burst(1_200, 8.0))),
        ],
        DEFAULT_BASE_PITCH,
    ));
    let d = DrumRack::new(kit, ENGINE_SAMPLE_RATE, voices, RAMP);
    let mut n = InstrumentNode::new("drum1", Instrument::Drum(d), events);
    n.snap_to(&synth_params());
    n
}

/// A musically dense schedule: chords, overlaps, repeats of the same pitch,
/// and a couple of very short notes.
fn dense_events(count: u32, span: u64) -> Vec<NoteEvent> {
    let mut ev = Vec::new();
    for i in 0..count {
        let on = (i as u64 * span / count as u64) + 37;
        let len = 400 + (i as u64 % 7) * 900;
        let pitch = 36 + ((i * 7) % 40) as u8;
        ev.push(NoteEvent::on(on, pitch, 0.3 + 0.7 * ((i % 5) as f32 / 4.0), i));
        ev.push(NoteEvent::off(on + len, pitch, i));
    }
    ev
}

// ---------------------------------------------------------------------------
// render harness (offline only — never opens a device)
// ---------------------------------------------------------------------------

/// How the parameter targets are produced for a frame.
#[derive(Clone, Copy, PartialEq, Eq)]
enum ParamMode {
    /// Constant for the whole render — the plain null-test case.
    Static,
    /// A pure function of the absolute frame, which is exactly how a baked
    /// automation lane behaves (`AutoLane::value_at(frame, cursor)`). Because
    /// it depends only on the frame, block size cannot perturb it — and if any
    /// instrument state secretly advanced per BLOCK, this test would catch it.
    AutomatedCutoff,
}

fn targets_at(mode: ParamMode, frame: u64) -> InstrumentParams {
    let mut p = synth_params();
    if mode == ParamMode::AutomatedCutoff {
        // A STEP, not a gentle sweep, and on a prime period that aligns with
        // no block size. This is deliberate: the cutoff `Slew` moves at
        // (20 kHz - 20 Hz) / 240 frames, so a slow sweep would land exactly on
        // target every single frame and the ramp would carry no state at all —
        // a parity test over it would be vacuous (verified: a mutation that
        // snapped every ramp at each block boundary still passed). A 14.7 kHz
        // jump takes ~177 frames to traverse, so the ramp is genuinely
        // mid-flight across block boundaries and any block-rate work shows up
        // (the same mutation now fails with a -2.4 dBFS residual).
        p.cutoff_hz = if (frame / 997) % 2 == 0 { 300.0 } else { 15_000.0 };
    }
    p
}

/// Render `total` frames in chunks of `block`, exactly as the engine does:
/// the loop over frames inside a block does all the work, and nothing at a
/// block boundary touches signal state.
fn render_chunked(
    node: &mut InstrumentNode,
    total: u64,
    block: usize,
    mode: ParamMode,
) -> Vec<[f32; 2]> {
    let mut out = Vec::with_capacity(total as usize);
    let mut frame = 0u64;
    while frame < total {
        let n = block.min((total - frame) as usize);
        guard::enter_render_scope();
        for i in 0..n {
            let f = frame + i as u64;
            let p = targets_at(mode, f);
            out.push(node.render_frame(f, &p));
        }
        guard::leave_render_scope();
        frame += n as u64;
    }
    out
}

fn peak(buf: &[[f32; 2]]) -> f32 {
    buf.iter().fold(0.0f32, |m, f| m.max(f[0].abs()).max(f[1].abs()))
}

fn assert_block_size_parity(
    label: &str,
    make: impl Fn() -> InstrumentNode,
    total: u64,
    mode: ParamMode,
) {
    let reference = {
        let mut n = make();
        render_chunked(&mut n, total, BLOCK_SIZES[0], mode)
    };
    assert!(
        peak(&reference) > 0.05,
        "{label}: the reference render is silent (peak {}) — a parity test on \
         silence proves nothing",
        peak(&reference)
    );
    for &block in &BLOCK_SIZES[1..] {
        let mut n = make();
        let other = render_chunked(&mut n, total, block, mode);
        let r = residual(&reference, &other);
        assert_eq!(
            reference.len(),
            other.len(),
            "{label}: frame count differs at block {block}"
        );
        assert!(
            r.bit_identical,
            "{label}: block {block} is not bit-identical to 128 \
             (peak residual {} dBFS, max_abs {})",
            r.peak_dbfs, r.max_abs
        );
    }
}

// ---------------------------------------------------------------------------
// 1. the parity gate
// ---------------------------------------------------------------------------

#[test]
fn synth_bounce_is_bit_identical_at_every_block_size() {
    assert_block_size_parity(
        "synth/static",
        || synth_node(dense_events(24, 96_000), DEFAULT_MAX_VOICES),
        96_000,
        ParamMode::Static,
    );
}

#[test]
fn synth_under_per_frame_automation_is_bit_identical_at_every_block_size() {
    assert_block_size_parity(
        "synth/automated-cutoff",
        || synth_node(dense_events(24, 96_000), DEFAULT_MAX_VOICES),
        96_000,
        ParamMode::AutomatedCutoff,
    );
}

#[test]
fn sampler_bounce_is_bit_identical_at_every_block_size() {
    assert_block_size_parity(
        "sampler",
        || sampler_node(dense_events(24, 96_000), DEFAULT_MAX_VOICES),
        96_000,
        ParamMode::Static,
    );
}

#[test]
fn drum_rack_bounce_is_bit_identical_at_every_block_size() {
    let mut ev = Vec::new();
    for i in 0..64u32 {
        let on = 200 + i as u64 * 1_400;
        let pitch = DEFAULT_BASE_PITCH + (i % 5) as u8;
        ev.push(NoteEvent::on(on, pitch, 0.4 + 0.6 * ((i % 4) as f32 / 3.0), i));
        ev.push(NoteEvent::off(on + 100, pitch, i));
    }
    assert_block_size_parity("drum", || drum_node(ev.clone(), 16), 96_000, ParamMode::Static);
}

#[test]
fn voice_stealing_overload_is_bit_identical_at_every_block_size() {
    // 8 voices, 64 overlapping long notes: the pool is saturated for almost
    // the whole render, so every block size must agree on WHICH voice dies and
    // exactly when its 5 ms steal fade lands.
    let mut ev = Vec::new();
    for i in 0..64u32 {
        let on = 100 + i as u64 * 600;
        let pitch = 40 + (i % 30) as u8;
        ev.push(NoteEvent::on(on, pitch, 0.2 + 0.8 * ((i % 9) as f32 / 8.0), i));
        ev.push(NoteEvent::off(on + 30_000, pitch, i));
    }
    assert_block_size_parity(
        "synth/overload",
        || synth_node(ev.clone(), 8),
        96_000,
        ParamMode::Static,
    );
}

// ---------------------------------------------------------------------------
// 2. allocation guard (positive control first)
// ---------------------------------------------------------------------------

#[test]
fn allocation_guard_positive_control_then_instrument_render_is_clean() {
    // POSITIVE CONTROL. Without this, a missing `#[global_allocator]` would
    // make the "zero violations" half of this test vacuously true — which is
    // exactly how a prior lane shipped a green alloc test that proved nothing.
    let before = guard::violations();
    guard::enter_render_scope();
    let v: Vec<u8> = Vec::with_capacity(64);
    std::hint::black_box(&v);
    drop(v);
    guard::leave_render_scope();
    let after = guard::violations();
    assert!(
        after > before,
        "guard is blind: it must see the control allocation \
         (before {before}, after {after}) — is CountingAlloc installed?"
    );

    // A second control, for the shape the instruments actually risk: growing a
    // container from inside a scope. If the voice pool ever pushed a Vec, the
    // guard would flag it just like this.
    let before2 = guard::violations();
    guard::enter_render_scope();
    let mut grow: Vec<f32> = Vec::new();
    for i in 0..64 {
        grow.push(i as f32);
    }
    std::hint::black_box(&grow);
    guard::leave_render_scope();
    assert!(guard::violations() > before2, "guard must see a Vec growth");

    // Now the real thing: all three instruments, hammered.
    let mut nodes = vec![
        synth_node(dense_events(200, 480_000), 8),
        sampler_node(dense_events(200, 480_000), 8),
        drum_node(dense_events(200, 480_000), 8),
    ];

    // Warm up outside the measurement.
    for n in nodes.iter_mut() {
        render_chunked(n, 4_800, 128, ParamMode::Static);
    }

    let clean_before = guard::violations();
    for (idx, n) in nodes.iter_mut().enumerate() {
        // AutomatedCutoff exercises the SVF coefficient solve on every frame,
        // and the dense schedule keeps the 8-voice pool stealing constantly:
        // note_on, note_off, steal, retrigger and Arc traffic are all inside
        // the measured scope.
        let out = render_chunked(n, 240_000, 417, ParamMode::AutomatedCutoff);
        assert!(peak(&out) > 0.01, "node {idx} rendered silence — nothing was measured");
    }
    let clean_after = guard::violations();
    assert_eq!(
        clean_after - clean_before,
        0,
        "instrument render allocated or freed on the audio thread"
    );
}

// ---------------------------------------------------------------------------
// 3. prove the AUDIO
// ---------------------------------------------------------------------------

#[test]
fn a_note_is_silent_before_its_frame_and_audible_after() {
    const ON: u64 = 12_000;
    let mut n = synth_node(vec![NoteEvent::on(ON, 60, 1.0, 1)], 8);
    let out = render_chunked(&mut n, 36_000, 417, ParamMode::Static);

    for (i, f) in out.iter().enumerate().take(ON as usize) {
        assert_eq!(*f, [0.0, 0.0], "signal leaked before the note-on at frame {i}");
    }
    let after_peak = peak(&out[ON as usize..]);
    assert!(after_peak > 0.05, "the note is inaudible, peak {after_peak}");

    // The first non-silent frame lands ON the note-on frame, not on a block
    // boundary (12 000 is not a multiple of 417 — the block containing it
    // starts at 11 676). A tolerance of a couple of frames is not slop: an
    // oscillator reset to phase 0 into a zeroed filter genuinely renders
    // exactly 0.0 for its first sample or two, so demanding a non-zero value
    // at exactly `ON` would be asserting a DSP accident rather than the
    // timing. Anything block-quantized would be off by hundreds of frames and
    // this still catches it.
    let first = out.iter().position(|f| *f != [0.0, 0.0]).unwrap() as u64;
    assert!(
        (ON..=ON + 3).contains(&first),
        "the note started at frame {first}, expected {ON} (block-quantized?)"
    );
}

#[test]
fn the_envelope_release_actually_reaches_zero() {
    let p = InstrumentParams {
        release_s: 0.25, // 12 000 frames
        ..synth_params()
    };
    let synth = Synth::new(ENGINE_SAMPLE_RATE, 8, RAMP);
    let mut n = InstrumentNode::new(
        "s",
        Instrument::Synth(synth),
        vec![NoteEvent::on(0, 60, 1.0, 1), NoteEvent::off(24_000, 60, 1)],
    );
    n.snap_to(&p);

    let mut out = Vec::new();
    for f in 0..48_000u64 {
        out.push(n.render_frame(f, &p));
    }

    // Still ringing well into the release...
    let mid = peak(&out[24_000..30_000]);
    assert!(mid > 0.005, "release was truncated, mid-release peak {mid}");
    // ...and EXACTLY silent once it has run its course.
    let tail = &out[38_000..];
    assert_eq!(
        peak(tail),
        0.0,
        "release never reached zero — that is an audible click and a voice leak"
    );
    assert_eq!(n.active_voices(), 0, "the voice was not reclaimed");

    // And the decay into silence is monotone enough to be click-free: no
    // single frame jumps by more than a small fraction of full scale.
    let max_step = out[24_000..38_000]
        .windows(2)
        .map(|w| (w[1][0] - w[0][0]).abs())
        .fold(0.0f32, f32::max);
    assert!(max_step < 0.2, "release has a discontinuity, max step {max_step}");
}

#[test]
fn polyphony_sums_and_a_chord_is_louder_than_one_note() {
    let p = synth_params();
    let render_one = |pitches: &[u8]| {
        let events: Vec<NoteEvent> = pitches
            .iter()
            .enumerate()
            .map(|(i, pitch)| NoteEvent::on(10, *pitch, 1.0, i as u32))
            .collect();
        let mut n = synth_node(events, 8);
        (0..24_000u64).map(|f| n.render_frame(f, &p)[0]).collect::<Vec<f32>>()
    };
    let c = render_one(&[60]);
    let e = render_one(&[64]);
    let g = render_one(&[67]);
    let chord = render_one(&[60, 64, 67]);

    for i in 0..24_000 {
        let sum = c[i] + e[i] + g[i];
        assert!(
            (chord[i] - sum).abs() < 1e-5,
            "frame {i}: chord {} != {} + {} + {}",
            chord[i],
            c[i],
            e[i],
            g[i]
        );
    }
    let solo_peak = c.iter().fold(0.0f32, |m, v| m.max(v.abs()));
    let chord_peak = chord.iter().fold(0.0f32, |m, v| m.max(v.abs()));
    assert!(chord_peak > solo_peak * 1.5, "a triad must be louder than one note");
}

#[test]
fn voice_stealing_is_deterministic_and_bounded() {
    let p = synth_params();
    let run = || {
        let mut ev = Vec::new();
        for i in 0..40u32 {
            ev.push(NoteEvent::on(100 + i as u64 * 300, 40 + (i % 24) as u8, 0.2 + 0.02 * i as f32, i));
        }
        let mut n = synth_node(ev, 6);
        let out: Vec<[f32; 2]> = (0..48_000u64).map(|f| n.render_frame(f, &p)).collect();
        (out, n.active_voices(), n.steal_count())
    };
    let (a, a_active, a_steals) = run();
    let (b, b_active, b_steals) = run();
    assert_eq!(a, b, "identical input renders identical audio");
    assert_eq!(a_active, b_active);
    assert_eq!(a_steals, b_steals);
    assert!(a_steals > 0, "the test did not actually overload the pool");
    assert!(a_active <= 6, "the pool never exceeded its fixed capacity");
    assert!(peak(&a) > 0.05, "the overloaded pool still made sound");
}

#[test]
fn a_stolen_voice_does_not_click() {
    // One voice, two overlapping notes: the steal fade is the only thing
    // standing between this and a hard cut.
    let p = InstrumentParams {
        attack_s: 0.0001,
        sustain: 1.0,
        ..synth_params()
    };
    let synth = Synth::new(ENGINE_SAMPLE_RATE, 1, RAMP);
    let mut n = InstrumentNode::new(
        "s",
        Instrument::Synth(synth),
        vec![NoteEvent::on(0, 60, 1.0, 1), NoteEvent::on(4_800, 72, 1.0, 2)],
    );
    n.snap_to(&p);
    let out: Vec<[f32; 2]> = (0..24_000u64).map(|f| n.render_frame(f, &p)).collect();

    // Across the steal window, no single-frame jump anywhere near a hard cut
    // of the sounding note (which was at roughly full envelope).
    let window = &out[4_700..5_400];
    let max_step = window
        .windows(2)
        .map(|w| (w[1][0] - w[0][0]).abs())
        .fold(0.0f32, f32::max);
    let before = peak(&out[4_000..4_700]);
    assert!(
        max_step < before * 0.5,
        "voice steal clicked: max step {max_step} against a level of {before}"
    );
    assert!(peak(&out[6_000..12_000]) > 0.02, "the stealing note is audible");
}

#[test]
fn sampler_pitch_tracks_the_keyboard_in_rendered_audio() {
    // A 220 Hz sine mapped at root A2 (45). Playing A2 must render 220 Hz;
    // playing A3 (57) must render 440 Hz. Measured on the OUTPUT BUFFER.
    let map = Arc::new(SampleMap::new(vec![SampleZone::full_range(
        sine_buf(220.0, 48_000),
        45,
    )]));
    let p = InstrumentParams {
        attack_s: 0.001,
        decay_s: 0.001,
        sustain: 1.0,
        release_s: 0.01,
        gain_db: 0.0,
        ..synth_params()
    };
    let crossings_for = |pitch: u8| {
        let s = Sampler::new(Arc::clone(&map), ENGINE_SAMPLE_RATE, 4, RAMP);
        let mut n = InstrumentNode::new("s", Instrument::Sampler(s), vec![NoteEvent::on(0, pitch, 1.0, 1)]);
        n.snap_to(&p);
        let out: Vec<f32> = (0..24_000u64).map(|f| n.render_frame(f, &p)[0]).collect();
        out.windows(2).filter(|w| (w[0] < 0.0) != (w[1] < 0.0)).count()
    };
    let root = crossings_for(45);
    let up = crossings_for(57);
    let down = crossings_for(33);
    assert!(root.abs_diff(220) <= 4, "root note read at 220 Hz, got {root} crossings/0.5 s");
    assert!(up.abs_diff(440) <= 8, "+1 octave read at 440 Hz, got {up}");
    assert!(down.abs_diff(110) <= 4, "-1 octave read at 110 Hz, got {down}");
}

#[test]
fn drum_rack_hits_are_one_shots_that_ignore_note_off() {
    let mut n = drum_node(
        vec![
            NoteEvent::on(1_000, DEFAULT_BASE_PITCH, 1.0, 1),
            // Key-up almost immediately: a kick must NOT stop here.
            NoteEvent::off(1_100, DEFAULT_BASE_PITCH, 1),
        ],
        8,
    );
    let out = render_chunked(&mut n, 12_000, 480, ParamMode::Static);
    assert_eq!(peak(&out[..1_000]), 0.0, "silent before the hit");
    let after_keyup = peak(&out[1_200..4_000]);
    assert!(
        after_keyup > 0.02,
        "the one-shot stopped at key-up, peak after {after_keyup}"
    );
    // The pad is 4 800 frames; it must be over well before the end.
    assert_eq!(peak(&out[7_000..]), 0.0, "one-shot ran past its own length");
}

#[test]
fn drum_rack_does_not_pitch_shift() {
    // Two different keys on the SAME pad index would be pitch-shifted by a
    // sampler; a rack maps them to different pads instead. Pad 0 (4 800
    // frames) and pad 1 (2 400 frames) must keep their own lengths.
    let p = synth_params();
    let length_of = |pitch: u8| {
        let mut n = drum_node(vec![NoteEvent::on(0, pitch, 1.0, 1)], 8);
        let out: Vec<[f32; 2]> = (0..12_000u64).map(|f| n.render_frame(f, &p)).collect();
        out.iter().rposition(|f| *f != [0.0, 0.0]).unwrap() + 1
    };
    assert_eq!(length_of(DEFAULT_BASE_PITCH), 4_800);
    assert_eq!(length_of(DEFAULT_BASE_PITCH + 1), 2_400);
}

#[test]
fn no_stuck_notes_across_repeated_loop_wraps() {
    // The single worst failure mode in the design doc. E1 emits explicit offs
    // at the wrap; this asserts the instrument honours them and that a
    // backward jump does not strand or duplicate a voice.
    let p = synth_params();
    let loop_len = 24_000u64;
    let events = vec![
        NoteEvent::on(1_000, 60, 1.0, 1),
        NoteEvent::on(4_000, 64, 1.0, 2),
        NoteEvent::on(7_000, 67, 1.0, 3),
        // Every on is closed before the wrap.
        NoteEvent::off(loop_len - 1, 60, 1),
        NoteEvent::off(loop_len - 1, 64, 2),
        NoteEvent::off(loop_len - 1, 67, 3),
    ];
    let mut n = synth_node(events, DEFAULT_MAX_VOICES);
    for pass in 0..12 {
        let mut out = Vec::with_capacity(loop_len as usize);
        let mut held_mid = 0usize;
        for f in 0..loop_len {
            out.push(n.render_frame(f, &p));
            if f == 12_000 {
                held_mid = n.held_voices();
            }
        }
        // A "no stuck notes" assertion is worthless on silence: if the note
        // cursor failed to re-anchor at the wrap, NOTHING would sound on
        // passes 1..n and every held-voice count would be trivially zero.
        // Pin the audio first, then the voice state.
        assert!(
            peak(&out) > 0.05,
            "loop pass {pass} rendered silence (peak {}) — the schedule did not              replay, so the stuck-note check would be vacuous",
            peak(&out)
        );
        assert_eq!(held_mid, 3, "all three notes must be sounding mid-pass {pass}");
        assert_eq!(n.held_voices(), 0, "a note stuck on loop pass {pass}");
        assert!(
            n.active_voices() <= 3,
            "voices accumulating across loops: {} on pass {pass}",
            n.active_voices()
        );
    }
}

#[test]
fn a_seek_past_a_note_on_does_not_strand_a_voice() {
    let p = synth_params();
    let mut n = synth_node(
        vec![NoteEvent::on(1_000, 60, 1.0, 1), NoteEvent::off(2_000, 60, 1)],
        8,
    );
    // Jump straight past both boundaries.
    for f in 5_000..8_000u64 {
        let out = n.render_frame(f, &p);
        assert_eq!(out, [0.0, 0.0]);
    }
    assert_eq!(n.active_voices(), 0, "a skipped note-on must not sound");
}

#[test]
fn the_schedule_dispatches_identically_however_the_timeline_is_chunked() {
    // The note cursor is the one piece of per-block-looking state in the
    // instrument path. Prove it is a pure function of the frame.
    let events = dense_events(40, 96_000);
    let mut a = NoteSchedule::new(events.clone());
    let mut by_frame = Vec::new();
    for f in 0..96_000u64 {
        a.drain_frame(f, |e| by_frame.push((e.frame, e.pitch, e.on, e.voice_hint)));
    }
    for block in BLOCK_SIZES {
        let mut b = NoteSchedule::new(events.clone());
        let mut chunked = Vec::new();
        let mut frame = 0u64;
        while frame < 96_000 {
            let n = (block as u64).min(96_000 - frame);
            for i in 0..n {
                b.drain_frame(frame + i, |e| {
                    chunked.push((e.frame, e.pitch, e.on, e.voice_hint))
                });
            }
            frame += n;
        }
        assert_eq!(by_frame, chunked, "dispatch differs at block {block}");
    }
    // Every event INSIDE the rendered window fired exactly once. (The dense
    // fixture deliberately runs a few note-offs past the window; those are
    // E1's to close at the clip edge, not this test's to observe.)
    let inside = events.iter().filter(|e| e.frame < 96_000).count();
    assert_eq!(by_frame.len(), inside, "every in-window event fired exactly once");
    assert!(inside > 0);
}

// ---------------------------------------------------------------------------
// 4. the parameter seam E1 will bake against
// ---------------------------------------------------------------------------

#[test]
fn instrument_params_are_addressable_by_the_existing_paramref_form() {
    use timeline_core::{ParamRef, ParamRefKind};

    for (slot, key) in INSTRUMENT_PARAM_KEYS.iter().enumerate() {
        let r = ParamRef::parse(&format!("track.device.synth1.{key}")).unwrap();
        match r.kind() {
            ParamRefKind::TrackDeviceParam { device_id, param } => {
                assert_eq!(device_id, "synth1");
                assert_eq!(param, *key, "ParamRef round-trip for slot {slot}");
                assert_eq!(InstrumentParams::index_of(param), Some(slot));
            }
            other => panic!("{key} did not parse as a device param: {other:?}"),
        }
    }
}

#[test]
fn an_automated_cutoff_lane_actually_changes_the_rendered_timbre() {
    // The E0 lane table hands a per-frame f32 to `InstrumentParams.set(slot)`.
    // Prove the value reaches the DSP and is audible, rather than being
    // accepted and ignored.
    let base = synth_params();
    let energy_with = |cutoff: f32| {
        let mut n = synth_node(vec![NoteEvent::on(0, 45, 1.0, 1)], 8);
        let mut p = base;
        p.set(PARAM_CUTOFF, cutoff);
        n.snap_to(&p);
        (0..48_000u64).fold(0.0f64, |acc, f| {
            let s = n.render_frame(f, &p)[0];
            acc + (s * s) as f64
        })
    };
    let open = energy_with(16_000.0);
    let closed = energy_with(120.0);
    assert!(open > 0.0 && closed > 0.0);
    assert!(
        closed < open * 0.5,
        "the cutoff lane did not reach the filter: open {open}, closed {closed}"
    );
}
