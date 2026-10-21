//! THE SAMPLER BINDING GATE: a `device.zone.add` source binding survives
//! compile and comes out of `RenderCore::render` as audible, correctly-pitched
//! sound.
//!
//! Everything here asserts on RENDERED BUFFERS from the real render core — the
//! same function the cpal callback and the offline bounce run. Not
//! `map.len()`, not `active_voices()`. A sampler that renders silence would
//! pass every model-level test in `timeline-core/tests/device_zones.rs`, and
//! silent degradation is the failure class this whole feature exists to close.
//!
//! The bars:
//!
//! 1. **Signal at the note-on frame, EXACT silence strictly before it.**
//! 2. **Pitch really tracks the key** — a measured frequency relationship
//!    between two different pitches, not "the output is non-zero". A sampler
//!    that ignored `root_pitch` and read every zone at rate 1.0 would still be
//!    audible; only a period measurement catches that.
//! 3. **The release decays to true zero.**
//! 4. **The zone map selects by key range**, measured by which sample you hear.
//! 5. **An unloaded source fails LOUDLY at compile**, through the same
//!    `sources` map and the same error shape a clip uses.
//! 6. **A drum pad is a one-shot at its own key.**
//! 7. **Bit-identical bounce at 128/417/480/512 with a sampler playing.**
//!
//! Nothing here opens an output device. Every render is offline.

use std::collections::HashMap;
use std::f32::consts::TAU;
use std::sync::Arc;

use render::automation::AutomationStore;
use render::compile::{compile_session_full, DeclickPolicy};
use render::engine::EngineConfig;
use render::guard;
use render::media::AudioBuf;
use render::offline::{render_offline_with, residual, ManualRenderer, ScheduledCommand};
use render::rt::{RenderCommand, RtSession, ENGINE_SAMPLE_RATE};
use render::warp::WarpOverlay;
use timeline_core::cmd::{Cmd, NoteSpec};
use timeline_core::model::DeviceKind;
use timeline_core::tempo::PPQ;
use timeline_core::{Bpm, Num, Project, Source, TempoMap, Track};

#[global_allocator]
static ALLOC: guard::CountingAlloc = guard::CountingAlloc;

const BLOCK_SIZES: [usize; 4] = [128, 417, 480, 512];
/// Frames per quarter note at 120 BPM, 48 kHz.
const QUARTER: u64 = 24_000;
const DEVICE_ID: &str = "inst1";
/// A 440 Hz sine, 4 seconds long — long enough that a zone transposed two
/// octaves DOWN still has material for the whole measurement window.
const SAMPLE_HZ: f32 = 440.0;
const SAMPLE_FRAMES: usize = 48_000 * 4;

// ---------------------------------------------------------------------------
// fixtures
// ---------------------------------------------------------------------------

fn sine(hz: f32, frames: usize, amp: f32) -> Vec<[f32; 2]> {
    (0..frames)
        .map(|i| {
            let v = amp * (TAU * hz * i as f32 / ENGINE_SAMPLE_RATE as f32).sin();
            [v, v]
        })
        .collect()
}

fn fnum(v: f64) -> Num {
    Num(serde_json::Number::from_f64(v).expect("finite"))
}

fn spec(id: &str, start_ticks: u64, len_ticks: u64, pitch: u8, vel: i64) -> NoteSpec {
    NoteSpec {
        note_id: id.into(),
        start_ticks,
        length_ticks: len_ticks,
        pitch,
        velocity: Num::int(vel),
    }
}

struct Rig {
    project: Project,
    sources: HashMap<String, Arc<AudioBuf>>,
}

impl Rig {
    /// One track, one sampler-or-drum device, one MIDI clip. NO audio clips at
    /// all, so anything non-zero in the master output came from the instrument
    /// and nowhere else — which is what makes the silence assertions mean
    /// something.
    fn new(kind: DeviceKind) -> Self {
        let mut project = Project::new(
            ENGINE_SAMPLE_RATE,
            TempoMap::single(Bpm::from_int(120).unwrap()),
        );
        project.tracks.push(Track::new("t1", "Sampler"));
        project
            .apply_cmd(&Cmd::DeviceAdd {
                track_id: "t1".into(),
                device_id: DEVICE_ID.into(),
                kind,
            })
            .expect("device.add");
        Self {
            project,
            sources: HashMap::new(),
        }
    }

    /// Register an asset in BOTH places a clip's asset lives: the project's
    /// `Source` registry (model) and the loaded-audio map (render). This is the
    /// same pair `add_synth` in `graph.rs` uses for a clip — deliberately, so
    /// a zone cannot drift onto its own lookup path.
    fn asset(&mut self, id: &str, samples: Vec<[f32; 2]>) -> &mut Self {
        let audio = AudioBuf::from_samples(samples, id);
        self.project
            .add_source(Source {
                id: id.into(),
                path: format!("synthetic:{id}"),
                len_frames: audio.len_frames(),
            })
            .expect("add_source");
        self.sources.insert(id.to_string(), audio);
        self
    }

    fn zone_full(
        &mut self,
        zone_id: &str,
        source_id: &str,
        lo: i64,
        hi: i64,
        root: i64,
        gain_db: Option<Num>,
        pan: Option<Num>,
    ) -> &mut Self {
        self.project
            .apply_cmd(&Cmd::DeviceZoneAdd {
                track_id: "t1".into(),
                device_id: DEVICE_ID.into(),
                zone_id: zone_id.into(),
                source_id: source_id.into(),
                root_pitch: Num::int(root),
                lo_pitch: Num::int(lo),
                hi_pitch: Num::int(hi),
                gain_db,
                pan,
            })
            .expect("device.zone.add");
        self
    }

    fn zone(&mut self, zone_id: &str, source_id: &str, lo: i64, hi: i64, root: i64) -> &mut Self {
        self.project
            .apply_cmd(&Cmd::DeviceZoneAdd {
                track_id: "t1".into(),
                device_id: DEVICE_ID.into(),
                zone_id: zone_id.into(),
                source_id: source_id.into(),
                root_pitch: Num::int(root),
                lo_pitch: Num::int(lo),
                hi_pitch: Num::int(hi),
                gain_db: None,
                pan: None,
            })
            .expect("device.zone.add");
        self
    }

    fn notes(&mut self, clip_len_ticks: u64, notes: Vec<NoteSpec>) -> &mut Self {
        self.project
            .apply_cmd(&Cmd::ClipPlaceMidi {
                clip_id: "cm1".into(),
                track_id: "t1".into(),
                start_ticks: 0,
                length_ticks: clip_len_ticks,
            })
            .expect("clip.placeMidi");
        if !notes.is_empty() {
            self.project
                .apply_cmd(&Cmd::NoteAdd {
                    clip_id: "cm1".into(),
                    notes,
                })
                .expect("note.add");
        }
        self
    }

    /// A snappy amp envelope so "silence before" and "reaches zero after" are
    /// testable inside a couple of seconds of render.
    fn patch(&mut self) -> &mut Self {
        let d = &mut self.project.tracks[0].devices[0];
        d.params.insert("attack".into(), fnum(0.001));
        d.params.insert("decay".into(), fnum(0.05));
        d.params.insert("sustain".into(), fnum(1.0));
        d.params.insert("release".into(), fnum(0.02));
        d.params.insert("gain".into(), fnum(0.0));
        self
    }

    fn compile(&self) -> Result<Box<RtSession>, String> {
        compile_session_full(
            &self.project,
            &self.sources,
            &WarpOverlay::new(),
            &AutomationStore::new(),
            EngineConfig::default().max_tracks,
            DeclickPolicy::None,
        )
    }

    fn render(&self, total: u64, block: usize) -> Vec<[f32; 2]> {
        let cfg = EngineConfig::default();
        let mut r = ManualRenderer::new(&cfg);
        let schedule = vec![
            ScheduledCommand {
                at_frame: 0,
                command: RenderCommand::SetSession(self.compile().expect("compile")),
            },
            ScheduledCommand {
                at_frame: 0,
                command: RenderCommand::Play,
            },
        ];
        render_offline_with(&mut r, schedule, total, block)
    }
}

fn peak(buf: &[[f32; 2]]) -> f32 {
    buf.iter()
        .map(|f| f[0].abs().max(f[1].abs()))
        .fold(0.0_f32, f32::max)
}

/// Fundamental frequency of a window, by counting sign changes on channel 0.
///
/// Amplitude-independent: the ADSR, the zone gain, the track fader and the
/// master are all POSITIVE scalars, so none of them can move a zero crossing.
/// That is exactly why this measures the thing a peak test cannot — playback
/// RATE.
fn measured_hz(buf: &[[f32; 2]]) -> f32 {
    let crossings = buf
        .windows(2)
        .filter(|w| (w[0][0] < 0.0) != (w[1][0] < 0.0))
        .count();
    let seconds = buf.len() as f32 / ENGINE_SAMPLE_RATE as f32;
    crossings as f32 / 2.0 / seconds
}

// ---------------------------------------------------------------------------
// 1 + 2 + 3. It makes sound, at the right frame, at the right PITCH
// ---------------------------------------------------------------------------

#[test]
fn a_bound_sampler_zone_is_audible_at_its_note_frame_and_silent_strictly_before() {
    let mut rig = Rig::new(DeviceKind::Sampler);
    rig.asset("srcA", sine(SAMPLE_HZ, SAMPLE_FRAMES, 0.5))
        .zone("z1", "srcA", 0, 127, 69)
        .notes(PPQ * 4, vec![spec("n1", PPQ, PPQ, 69, 127)])
        .patch();
    let out = rig.render(72_000, 512);

    // EXACT silence before the attack. Not "quiet" — zero.
    assert_eq!(
        peak(&out[..QUARTER as usize]),
        0.0,
        "the sampler leaked signal before its note-on frame"
    );
    // Audible within its own frame's block, not at the next block boundary.
    let attack = peak(&out[QUARTER as usize..(QUARTER + 128) as usize]);
    assert!(
        attack > 0.0,
        "the note must be audible within 128 frames of its own frame (peak {attack})"
    );
    let sustain = peak(&out[(QUARTER + 2_400) as usize..(QUARTER * 2) as usize]);
    assert!(
        sustain > 0.05,
        "the sample must sustain at a real level, not a denormal ({sustain})"
    );
}

#[test]
fn the_root_note_plays_the_sample_at_its_recorded_pitch() {
    let mut rig = Rig::new(DeviceKind::Sampler);
    rig.asset("srcA", sine(SAMPLE_HZ, SAMPLE_FRAMES, 0.5))
        .zone("z1", "srcA", 0, 127, 69)
        .notes(PPQ * 8, vec![spec("n1", PPQ, PPQ * 4, 69, 127)])
        .patch();
    let out = rig.render(144_000, 512);
    // Measure a clean second inside the sustain.
    let hz = measured_hz(&out[(QUARTER + 4_800) as usize..(QUARTER + 52_800) as usize]);
    assert!(
        (hz - SAMPLE_HZ).abs() < 4.0,
        "playing the root key must read the sample at rate 1.0: expected ~{SAMPLE_HZ} Hz, \
         measured {hz} Hz"
    );
}

#[test]
fn pitch_tracks_the_key_an_octave_up_doubles_and_an_octave_down_halves() {
    // THE test that a peak/non-zero assertion cannot make. A sampler that
    // ignored `root_pitch` — or read every zone at rate 1.0 — is fully audible
    // and passes every "signal exists" gate; only the measured frequency
    // RATIO catches it.
    let hz_for = |pitch: u8| {
        let mut rig = Rig::new(DeviceKind::Sampler);
        rig.asset("srcA", sine(SAMPLE_HZ, SAMPLE_FRAMES, 0.5))
            .zone("z1", "srcA", 0, 127, 69)
            .notes(PPQ * 8, vec![spec("n1", PPQ, PPQ * 4, pitch, 127)])
            .patch();
        let out = rig.render(144_000, 512);
        measured_hz(&out[(QUARTER + 4_800) as usize..(QUARTER + 40_800) as usize])
    };

    let root = hz_for(69);
    let up = hz_for(81);
    let down = hz_for(57);

    assert!(
        (up / root - 2.0).abs() < 0.02,
        "+12 semitones must double the frequency: {root} Hz -> {up} Hz"
    );
    assert!(
        (down / root - 0.5).abs() < 0.02,
        "-12 semitones must halve the frequency: {root} Hz -> {down} Hz"
    );
    // And absolutely, not just relatively: equal temperament, not some other
    // ratio that happens to be 2:1 across those two keys.
    let expected_up = SAMPLE_HZ * 2.0;
    assert!(
        (up - expected_up).abs() < 8.0,
        "expected ~{expected_up} Hz at +12, measured {up} Hz"
    );
}

#[test]
fn a_seventh_above_the_root_lands_on_equal_temperament() {
    // A non-octave interval, so the test cannot be satisfied by a
    // power-of-two-only implementation (a doubling read pointer, say).
    let mut rig = Rig::new(DeviceKind::Sampler);
    rig.asset("srcA", sine(SAMPLE_HZ, SAMPLE_FRAMES, 0.5))
        .zone("z1", "srcA", 0, 127, 69)
        .notes(PPQ * 8, vec![spec("n1", PPQ, PPQ * 4, 76, 127)])
        .patch();
    let out = rig.render(144_000, 512);
    let hz = measured_hz(&out[(QUARTER + 4_800) as usize..(QUARTER + 40_800) as usize]);
    let expected = SAMPLE_HZ * 2.0_f32.powf(7.0 / 12.0); // ~659.26 Hz
    assert!(
        (hz / expected - 1.0).abs() < 0.01,
        "+7 semitones must be 2^(7/12): expected ~{expected} Hz, measured {hz} Hz"
    );
}

#[test]
fn the_release_decays_all_the_way_to_zero() {
    let mut rig = Rig::new(DeviceKind::Sampler);
    rig.asset("srcA", sine(SAMPLE_HZ, SAMPLE_FRAMES, 0.5))
        .zone("z1", "srcA", 0, 127, 69)
        .notes(PPQ * 4, vec![spec("n1", PPQ, PPQ, 69, 127)])
        .patch(); // 20 ms release
    let out = rig.render(96_000, 512);

    let off = (QUARTER * 2) as usize;
    assert!(
        peak(&out[off - 2_400..off]) > 0.05,
        "the sample must still be sounding right up to its note-off"
    );
    // 20 ms release = 960 frames. Well past it the output must be EXACTLY
    // zero: a truncated release is a click, and a release that asymptotes
    // without landing leaves a voice alive forever.
    let tail = &out[off + 4_800..];
    assert_eq!(
        peak(tail),
        0.0,
        "release must reach exact zero (peak {})",
        peak(tail)
    );
}

// ---------------------------------------------------------------------------
// 4. The zone map selects by key range — measured by WHICH SAMPLE you hear
// ---------------------------------------------------------------------------

#[test]
fn the_key_range_selects_the_zone_and_you_can_hear_which_one() {
    // Two zones, two DIFFERENT assets, split at middle C. Each zone's root is
    // its own recorded pitch, so playing each zone's root reproduces that
    // zone's recorded frequency exactly — which means the measured frequency
    // identifies the zone unambiguously.
    let hz_for = |pitch: u8| {
        let mut rig = Rig::new(DeviceKind::Sampler);
        rig.asset("low", sine(220.0, SAMPLE_FRAMES, 0.5))
            .asset("high", sine(880.0, SAMPLE_FRAMES, 0.5))
            .zone("zlow", "low", 0, 59, 45)
            .zone("zhigh", "high", 60, 127, 81)
            .notes(PPQ * 8, vec![spec("n1", PPQ, PPQ * 4, pitch, 127)])
            .patch();
        let out = rig.render(144_000, 512);
        measured_hz(&out[(QUARTER + 4_800) as usize..(QUARTER + 40_800) as usize])
    };

    let low = hz_for(45);
    let high = hz_for(81);
    assert!(
        (low - 220.0).abs() < 4.0,
        "key 45 must select the low zone (220 Hz), measured {low} Hz"
    );
    assert!(
        (high - 880.0).abs() < 8.0,
        "key 81 must select the high zone (880 Hz), measured {high} Hz"
    );
}

#[test]
fn a_key_no_zone_covers_is_silent_rather_than_wrong() {
    let mut rig = Rig::new(DeviceKind::Sampler);
    rig.asset("srcA", sine(SAMPLE_HZ, SAMPLE_FRAMES, 0.5))
        .zone("z1", "srcA", 60, 72, 69)
        .notes(PPQ * 4, vec![spec("n1", PPQ, PPQ, 20, 127)])
        .patch();
    let out = rig.render(96_000, 512);
    assert_eq!(
        peak(&out),
        0.0,
        "an unmapped key must be silent, never mapped to the nearest zone"
    );
}

// ---------------------------------------------------------------------------
// 5. An unloaded source fails LOUDLY, control-side
// ---------------------------------------------------------------------------

#[test]
fn an_unloaded_zone_source_fails_compile_the_same_way_a_clip_does() {
    // The whole point of routing zones through the EXISTING content-addressed
    // asset path: one lookup, one failure. A sampler that quietly compiled
    // with a missing asset would render silence and count dropped notes —
    // which is what the pre-binding build refused to do, and this keeps that
    // refusal.
    let mut rig = Rig::new(DeviceKind::Sampler);
    rig.asset("srcA", sine(SAMPLE_HZ, 48_000, 0.5))
        .zone("z1", "srcA", 0, 127, 69)
        .notes(PPQ * 4, vec![spec("n1", PPQ, PPQ, 69, 127)]);
    // Unload it, exactly as an offline asset would be.
    rig.sources.remove("srcA");

    let err = match rig.compile() {
        Ok(_) => panic!("compile must refuse"),
        Err(e) => e,
    };
    assert!(
        err.contains("references unloaded source") && err.contains("srcA"),
        "expected the clip-shaped unloaded-source error, got: {err}"
    );
}

#[test]
fn a_sampler_with_no_zones_at_all_fails_compile() {
    let mut rig = Rig::new(DeviceKind::Sampler);
    rig.notes(PPQ * 4, vec![spec("n1", PPQ, PPQ, 69, 127)]);
    let err = match rig.compile() {
        Ok(_) => panic!("compile must refuse"),
        Err(e) => e,
    };
    assert!(
        err.contains("no zones") && err.contains("render silence"),
        "an unbound sampler must fail loudly, not compile to silence: {err}"
    );
}

#[test]
fn a_drum_rack_wider_than_the_pad_grid_fails_compile() {
    let mut rig = Rig::new(DeviceKind::Drum);
    rig.asset("kick", sine(80.0, 4_800, 0.8))
        .zone("p1", "kick", 36, 36, 36)
        .zone("p2", "kick", 60, 60, 60);
    let err = match rig.compile() {
        Ok(_) => panic!("compile must refuse"),
        Err(e) => e,
    };
    assert!(
        err.contains("wider than") && err.contains("refusing"),
        "a kit that does not fit the rack must be refused, not truncated: {err}"
    );
}

// ---------------------------------------------------------------------------
// 6. The drum rack
// ---------------------------------------------------------------------------

#[test]
fn a_drum_pad_sounds_on_its_own_key_and_is_a_one_shot() {
    // Pad at 36 plays a 0.1 s burst. The note is a full beat long, so a
    // pad that (wrongly) honoured note-off would be cut short; a one-shot
    // plays its own length and stops. Both directions are measured on the
    // rendered buffer.
    let burst: Vec<[f32; 2]> = sine(200.0, 4_800, 0.8);
    let mut rig = Rig::new(DeviceKind::Drum);
    rig.asset("kick", burst)
        .zone("p1", "kick", 36, 36, 36)
        .notes(PPQ * 4, vec![spec("n1", PPQ, PPQ, 36, 127)])
        .patch();
    let out = rig.render(96_000, 512);

    assert_eq!(
        peak(&out[..QUARTER as usize]),
        0.0,
        "silent before the hit"
    );
    let hit = peak(&out[QUARTER as usize..(QUARTER + 4_800) as usize]);
    assert!(hit > 0.05, "the pad must be audible (peak {hit})");
    // The note is a beat (24 000 frames) long but the sample is 4 800: a
    // one-shot ends with the SAMPLE, well before the note-off at 48 000.
    let after_sample = peak(&out[(QUARTER + 5_200) as usize..(QUARTER * 2) as usize]);
    assert_eq!(
        after_sample, 0.0,
        "a one-shot must end with its sample, not with the note (peak {after_sample})"
    );
}

#[test]
fn a_drum_rack_does_not_pitch_track() {
    // Two pads, SAME asset, adjacent keys. A rack reads at rate 1.0 whatever
    // key fires it, so both must reproduce the recorded frequency. This is the
    // exact inverse of the sampler test above, and it fails if the drum path
    // ever gets wired through the sampler's rate math.
    let hz_for = |pitch: u8| {
        let mut rig = Rig::new(DeviceKind::Drum);
        rig.asset("tone", sine(300.0, 48_000, 0.8))
            .zone("p1", "tone", 36, 36, 36)
            .zone("p2", "tone", 48, 48, 48)
            .notes(PPQ * 8, vec![spec("n1", PPQ, PPQ, pitch, 127)])
            .patch();
        let out = rig.render(96_000, 512);
        measured_hz(&out[(QUARTER + 2_400) as usize..(QUARTER + 26_400) as usize])
    };
    let a = hz_for(36);
    let b = hz_for(48);
    assert!((a - 300.0).abs() < 4.0, "pad 36 reads at rate 1.0, got {a} Hz");
    assert!(
        (b - 300.0).abs() < 4.0,
        "pad 48 must read at rate 1.0 too — a rack does not pitch-track, got {b} Hz"
    );
}

// ---------------------------------------------------------------------------
// 7. Bit-identical bounce with a sampler playing
// ---------------------------------------------------------------------------

#[test]
fn bounce_is_bit_identical_at_128_417_480_512_with_a_sampler_playing() {
    let mut notes = vec![
        spec("c1", PPQ, PPQ * 6, 48, 100),
        spec("c2", PPQ, PPQ * 6, 55, 90),
        spec("c3", PPQ, PPQ * 6, 64, 80),
    ];
    for i in 0..12u64 {
        notes.push(spec(
            &format!("m{i}"),
            PPQ / 2 + i * (PPQ / 2),
            PPQ / 3,
            60 + (i % 12) as u8,
            70 + (i % 40) as i64,
        ));
    }
    let mut rig = Rig::new(DeviceKind::Sampler);
    rig.asset("low", sine(220.0, SAMPLE_FRAMES, 0.4))
        .asset("high", sine(660.0, SAMPLE_FRAMES, 0.4))
        .zone("zlow", "low", 0, 59, 45)
        .zone("zhigh", "high", 60, 127, 81)
        .notes(PPQ * 16, notes)
        .patch();

    let total = 144_000;
    let reference = rig.render(total, BLOCK_SIZES[0]);
    // NON-SILENCE GATE: a parity test on silence is vacuous, and that false
    // green has already been caught twice in this program.
    let p = peak(&reference);
    assert!(p > 0.05, "the sampler produced no audible signal (peak {p})");

    for block in &BLOCK_SIZES[1..] {
        let out = rig.render(total, *block);
        let r = residual(&reference, &out);
        assert!(
            r.bit_identical,
            "bounce with a sampler playing must be bit-identical at block {block} \
             (peak residual {} dBFS, max_abs {})",
            r.peak_dbfs, r.max_abs
        );
    }
}

// ---------------------------------------------------------------------------
// 8. Allocation-free with a SAMPLER playing
// ---------------------------------------------------------------------------

#[test]
fn render_with_a_sampler_playing_allocates_nothing() {
    // POSITIVE CONTROL first: without the `#[global_allocator]` above, this
    // whole test is vacuously green — a prior lane in this program shipped
    // exactly that.
    let before = guard::violations();
    guard::enter_render_scope();
    let v: Vec<u8> = Vec::with_capacity(64);
    drop(v);
    guard::leave_render_scope();
    assert!(
        guard::violations() > before,
        "the alloc guard cannot see an allocation — is #[global_allocator] installed?"
    );

    // A sampler is the interesting case for this guard: every note-on clones
    // an `Arc<AudioBuf>` out of the zone map. That must stay ONE relaxed
    // atomic increment — never a heap touch — and the map holding a strong ref
    // for the node's life is what makes a voice's drop safe on the audio
    // thread. 64 overlapping notes into a 32-voice pool so stealing (the path
    // most likely to want a heap) runs hot.
    let mut notes = Vec::new();
    for i in 0..64u64 {
        notes.push(spec(
            &format!("n{i}"),
            i * (PPQ / 8),
            PPQ * 3,
            36 + (i % 60) as u8,
            60 + (i % 60) as i64,
        ));
    }
    let mut rig = Rig::new(DeviceKind::Sampler);
    rig.asset("low", sine(220.0, SAMPLE_FRAMES, 0.4))
        .asset("high", sine(660.0, SAMPLE_FRAMES, 0.4))
        .zone("zlow", "low", 0, 59, 45)
        .zone("zhigh", "high", 60, 127, 81)
        .notes(PPQ * 64, notes)
        .patch();

    let cfg = EngineConfig::default();
    let mut renderer = ManualRenderer::new(&cfg);
    renderer.send(RenderCommand::SetSession(rig.compile().expect("compile")));
    renderer.send(RenderCommand::Play);

    let mut out = vec![[0.0_f32; 2]; 128];
    for _ in 0..4 {
        renderer.render(&mut out);
    }

    let clean_before = guard::violations();
    let mut heard = 0.0_f32;
    for block in 0..1_000_u64 {
        // Control-side pressure BETWEEN blocks, including session swaps that
        // replace a SOUNDING sampler — the deferred-drop path, which is where
        // a new sample map arrives and the old one is handed off.
        match block % 16 {
            0 => {
                renderer.send(RenderCommand::SetSession(rig.compile().expect("compile")));
            }
            3 => {
                renderer.send(RenderCommand::Seek {
                    frame: (block * 977) % 200_000,
                });
            }
            5 => {
                renderer.send(RenderCommand::LoopSet {
                    start_frame: 10_000,
                    end_frame: 20_000,
                });
            }
            7 => {
                renderer.send(RenderCommand::LoopClear);
            }
            _ => {}
        }
        renderer.render(&mut out);
        heard = heard.max(peak(&out));
    }
    let violations = guard::violations() - clean_before;
    assert_eq!(
        violations, 0,
        "render() allocated or freed on the audio thread with a sampler playing"
    );
    // NON-SILENCE GATE: an allocation test over a silent engine proves nothing.
    assert!(
        heard > 0.01,
        "the sampler must actually have been rendering during the alloc run (peak {heard})"
    );
}

// ---------------------------------------------------------------------------
// 9. The per-zone gain and per-pad pan are not decoration
// ---------------------------------------------------------------------------

#[test]
fn the_per_zone_gain_reaches_the_output() {
    // -12 dB is a factor of 0.2512. Measured on the rendered buffer, not on
    // `zone.gain_lin`: a gain the model stores and the DSP never reads is
    // exactly the kind of field that ships broken.
    let peak_for = |gain_db: Option<Num>| {
        let mut rig = Rig::new(DeviceKind::Sampler);
        rig.asset("srcA", sine(SAMPLE_HZ, SAMPLE_FRAMES, 0.5))
            .zone_full("z1", "srcA", 0, 127, 69, gain_db, None)
            .notes(PPQ * 4, vec![spec("n1", PPQ, PPQ, 69, 127)])
            .patch();
        let out = rig.render(96_000, 512);
        peak(&out[(QUARTER + 2_400) as usize..(QUARTER * 2) as usize])
    };
    let unity = peak_for(None);
    let cut = peak_for(Some(Num::int(-12)));
    assert!(unity > 0.05, "the reference render must be audible ({unity})");
    let ratio = cut / unity;
    assert!(
        (ratio - 0.2512).abs() < 0.01,
        "-12 dB of zone gain must be a factor of 0.2512 at the output, measured {ratio} \
         ({cut} vs {unity})"
    );
}

#[test]
fn the_per_pad_pan_reaches_the_output() {
    // A drum pad panned hard right must be silent on the left. The sampler
    // deliberately ignores `pan` (documented on `DeviceZone`), so this is the
    // one instrument where the field is load-bearing.
    let mut rig = Rig::new(DeviceKind::Drum);
    rig.asset("kick", sine(200.0, 4_800, 0.8))
        .zone_full("p1", "kick", 36, 36, 36, None, Some(Num::int(1)))
        .notes(PPQ * 4, vec![spec("n1", PPQ, PPQ, 36, 127)])
        .patch();
    // The track pan is centred, so any L/R difference came from the PAD.
    let out = rig.render(96_000, 512);
    let window = &out[QUARTER as usize..(QUARTER + 4_800) as usize];
    let left = window.iter().map(|f| f[0].abs()).fold(0.0_f32, f32::max);
    let right = window.iter().map(|f| f[1].abs()).fold(0.0_f32, f32::max);
    assert!(right > 0.05, "the pad must be audible on the right ({right})");
    assert!(
        left < right * 0.05,
        "a pad panned hard right must be effectively silent on the left \
         (left {left}, right {right})"
    );
}

// ---------------------------------------------------------------------------
// 10. Gaps found by mutation testing (both were real; both are closed here)
// ---------------------------------------------------------------------------

#[test]
fn a_drum_kit_can_sit_anywhere_on_the_keyboard_not_only_at_c1() {
    // FOUND BY MUTATION: hard-coding the rack's base pitch to
    // `DEFAULT_BASE_PITCH` (36) left every existing drum test green, because
    // every fixture happened to start at 36. A kit bound higher up the
    // keyboard would then have been silent — the exact silent-degradation
    // shape this feature exists to close.
    let mut rig = Rig::new(DeviceKind::Drum);
    rig.asset("tone", sine(300.0, 4_800, 0.8))
        .zone("p1", "tone", 60, 60, 60)
        .zone("p2", "tone", 63, 63, 63)
        .notes(
            PPQ * 8,
            vec![spec("n1", PPQ, PPQ, 60, 127), spec("n2", PPQ * 3, PPQ, 63, 127)],
        )
        .patch();
    let out = rig.render(144_000, 512);

    let first = peak(&out[QUARTER as usize..(QUARTER + 4_800) as usize]);
    let second = peak(&out[(QUARTER * 3) as usize..(QUARTER * 3 + 4_800) as usize]);
    assert!(first > 0.05, "pad at key 60 must sound (peak {first})");
    assert!(second > 0.05, "pad at key 63 must sound (peak {second})");
}

#[test]
fn a_foreign_checkpoints_out_of_range_zone_pitch_fails_compile() {
    // FOUND BY MUTATION: the compile-side pitch range check was unreachable
    // from anything `apply.rs` validates, so nothing exercised it — yet
    // `package.rs::parse_device_zone` will happily read whatever number a
    // foreign writer put in the checkpoint. Written directly onto the model
    // here, which is exactly the shape a loaded project arrives in.
    let mut rig = Rig::new(DeviceKind::Sampler);
    rig.asset("srcA", sine(SAMPLE_HZ, 48_000, 0.5))
        .zone("z1", "srcA", 0, 127, 69)
        .notes(PPQ * 4, vec![spec("n1", PPQ, PPQ, 69, 127)]);
    rig.project.tracks[0].devices[0].zones[0].root_pitch = fnum(999.5);

    let err = match rig.compile() {
        Ok(_) => panic!("compile must refuse an out-of-range zone pitch"),
        Err(e) => e,
    };
    assert!(
        err.contains("rootPitch") && err.contains("[0, 127]"),
        "expected a loud out-of-range zone pitch error, got: {err}"
    );
}
