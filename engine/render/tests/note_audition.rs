//! AUDITION: the piano roll's primary feedback loop, at the render layer.
//!
//! The piano roll shipped with `onPreview` unwired — pressing a gutter key or
//! drawing a note made no sound at all. Wiring it needed a path the engine did
//! not have: sound a note RIGHT NOW, with the transport STOPPED. Every clip and
//! instrument render in `RenderCore` was gated on `playing && transport_gain > 0`,
//! so an audition against a stopped transport was structurally silent.
//!
//! These tests assert on RENDERED BUFFERS out of the real `RenderCore::render`,
//! for the same reason `instrument_wiring.rs` does: "the command was accepted"
//! is not "the user heard something", and this whole epic has already been
//! bitten once by a green signal on the wrong axis.
//!
//! Nothing here opens an output device. Every render is offline.

use std::collections::HashMap;
use std::sync::Arc;

use render::automation::AutomationStore;
use render::compile::{compile_session_full, DeclickPolicy};
use render::engine::EngineConfig;
use render::media::AudioBuf;
use render::offline::{render_offline_with, ManualRenderer, ScheduledCommand};
use render::rt::{RenderCommand, RtSession, ENGINE_SAMPLE_RATE, PREVIEW_HINT_BASE};
use render::warp::WarpOverlay;
use timeline_core::cmd::Cmd;
use timeline_core::model::DeviceKind;
use timeline_core::tempo::PPQ;
use timeline_core::{Bpm, Num, Project, TempoMap, Track};

const DEVICE_ID: &str = "inst1";
const HINT: u32 = PREVIEW_HINT_BASE + 60;

fn fnum(v: f64) -> Num {
    Num(serde_json::Number::from_f64(v).expect("finite"))
}

/// One track, one synth, one EMPTY MIDI clip. No audio clips and no authored
/// notes, so every non-zero sample below came from the audition and nowhere
/// else — which is what makes the silence assertions mean something.
fn keys_project() -> Project {
    let mut p = Project::new(
        ENGINE_SAMPLE_RATE,
        TempoMap::single(Bpm::from_int(120).unwrap()),
    );
    p.tracks.push(Track::new("t1", "Keys"));
    p.apply_cmd(&Cmd::DeviceAdd {
        track_id: "t1".into(),
        device_id: DEVICE_ID.into(),
        kind: DeviceKind::Synth,
    })
    .expect("device.add");
    p.apply_cmd(&Cmd::ClipPlaceMidi {
        clip_id: "cm1".into(),
        track_id: "t1".into(),
        start_ticks: 0,
        length_ticks: PPQ * 8,
    })
    .expect("clip.placeMidi");
    let d = &mut p.tracks[0].devices[0];
    d.params.insert("attack".into(), fnum(0.001));
    d.params.insert("decay".into(), fnum(0.05));
    d.params.insert("sustain".into(), fnum(0.8));
    d.params.insert("release".into(), fnum(0.02));
    d.params.insert("gain".into(), fnum(0.0));
    d.params.insert("cutoff".into(), fnum(8_000.0));
    p
}

/// A project with a track but NO instrument device, to prove an audition on a
/// plain audio track is silent rather than a panic or a leak.
fn audio_only_project() -> Project {
    let mut p = Project::new(
        ENGINE_SAMPLE_RATE,
        TempoMap::single(Bpm::from_int(120).unwrap()),
    );
    p.tracks.push(Track::new("t1", "Gtr"));
    p
}

fn compile(p: &Project) -> Box<RtSession> {
    let sources: HashMap<String, Arc<AudioBuf>> = HashMap::new();
    compile_session_full(
        p,
        &sources,
        &WarpOverlay::new(),
        &AutomationStore::new(),
        EngineConfig::default().max_tracks,
        DeclickPolicy::None,
    )
    .expect("compile")
}

/// Render `total` frames with the transport left STOPPED. The schedule installs
/// the session and then whatever audition commands the test wants — deliberately
/// no `RenderCommand::Play`.
fn render_stopped(p: &Project, extra: Vec<ScheduledCommand>, total: u64, block: usize) -> Vec<[f32; 2]> {
    let cfg = EngineConfig::default();
    let mut r = ManualRenderer::new(&cfg);
    let mut schedule = vec![ScheduledCommand {
        at_frame: 0,
        command: RenderCommand::SetSession(compile(p)),
    }];
    schedule.extend(extra);
    render_offline_with(&mut r, schedule, total, block)
}

fn peak(buf: &[[f32; 2]]) -> f32 {
    buf.iter()
        .map(|f| f[0].abs().max(f[1].abs()))
        .fold(0.0_f32, f32::max)
}

fn note_on(at_frame: u64, hold_frames: u64) -> ScheduledCommand {
    ScheduledCommand {
        at_frame,
        command: RenderCommand::PreviewNoteOn {
            track: 0,
            pitch: 60,
            velocity: 100.0 / 127.0,
            hint: HINT,
            hold_frames,
        },
    }
}

fn note_off(at_frame: u64) -> ScheduledCommand {
    ScheduledCommand {
        at_frame,
        command: RenderCommand::PreviewNoteOff {
            track: 0,
            hint: HINT,
        },
    }
}

// ---------------------------------------------------------------------------
// 1. The gate this lane exists to open
// ---------------------------------------------------------------------------

#[test]
fn an_audition_is_audible_with_the_transport_stopped() {
    // THE test. A piano-roll key press happens against a stopped transport
    // essentially always — that is the whole point of auditioning. Before this,
    // `playing && transport_gain > 0` made that case structurally silent.
    let p = keys_project();
    let out = render_stopped(&p, vec![note_on(0, 24_000)], 12_000, 512);
    assert!(
        peak(&out) > 0.0,
        "a note auditioned while STOPPED must be audible; got exact silence"
    );
}

#[test]
fn nothing_sounds_until_the_audition_arrives() {
    // The negative control for the test above: the same stopped session with no
    // audition command renders EXACT silence, so "peak > 0" up there is the
    // audition and not some idle instrument hum.
    let p = keys_project();
    let out = render_stopped(&p, vec![], 12_000, 512);
    assert_eq!(
        peak(&out),
        0.0,
        "a stopped session with no audition must be exactly silent"
    );
}

#[test]
fn a_one_shot_audition_releases_itself_and_returns_to_exact_zero() {
    // A UI click has no key-up, so a one-shot MUST release itself. A hanging
    // synth voice after a click is the worst possible outcome of wiring this.
    let p = keys_project();
    // Hold for 2000 frames (~42 ms); release is 20 ms, so it is long gone by
    // the end of a 48 000-frame (1 s) render.
    let out = render_stopped(&p, vec![note_on(0, 2_000)], 48_000, 512);
    assert!(peak(&out[..3_000]) > 0.0, "the one-shot must actually sound");
    let tail = peak(&out[24_000..]);
    assert_eq!(
        tail, 0.0,
        "a one-shot audition must decay to EXACT zero; a non-zero tail is a stuck note"
    );
}

#[test]
fn a_held_audition_sustains_until_its_note_off() {
    // The MIDI keyboard case: `hold_frames == 0` means "held until an explicit
    // off", so the note must still be sounding well past any one-shot length,
    // and must stop after the off.
    let p = keys_project();
    let out = render_stopped(&p, vec![note_on(0, 0), note_off(48_000)], 96_000, 512);
    assert!(
        peak(&out[40_000..48_000]) > 0.0,
        "a HELD audition must still be sounding 1 s in — it has no self-release"
    );
    assert_eq!(
        peak(&out[72_000..]),
        0.0,
        "after the note-off the held audition must decay to exact zero"
    );
}

#[test]
fn a_transport_start_releases_every_auditioning_voice() {
    // Pressing Play while a key is held must not leave the audition ringing
    // under the song. `panic_all_notes` sweeps the pool; the bookkeeping has to
    // be swept with it or the render gate stays open forever.
    let p = keys_project();
    let out = render_stopped(
        &p,
        vec![
            note_on(0, 0), // held, no self-release
            ScheduledCommand {
                at_frame: 4_000,
                command: RenderCommand::Stop, // a discontinuity, transport still stopped
            },
        ],
        48_000,
        512,
    );
    assert!(peak(&out[..2_000]) > 0.0, "the audition sounded first");
    assert_eq!(
        peak(&out[24_000..]),
        0.0,
        "a transport discontinuity must release a HELD audition, not leave it ringing"
    );
}

#[test]
fn auditioning_a_track_with_no_instrument_is_silent_and_harmless() {
    let p = audio_only_project();
    let out = render_stopped(&p, vec![note_on(0, 24_000)], 12_000, 512);
    assert_eq!(
        peak(&out),
        0.0,
        "a track with no instrument device has nothing to sound"
    );
}

#[test]
fn an_out_of_range_track_index_is_ignored() {
    // The control side resolves the index, but the audio thread must never
    // index out of bounds on a stale command that outlived a session swap.
    let p = keys_project();
    let out = render_stopped(
        &p,
        vec![ScheduledCommand {
            at_frame: 0,
            command: RenderCommand::PreviewNoteOn {
                track: 99,
                pitch: 60,
                velocity: 1.0,
                hint: HINT,
                hold_frames: 24_000,
            },
        }],
        12_000,
        512,
    );
    assert_eq!(peak(&out), 0.0, "an unknown track index sounds nothing");
}

// ---------------------------------------------------------------------------
// 2. Block-size independence — the rule the whole render core rests on
// ---------------------------------------------------------------------------

#[test]
fn a_one_shot_audition_is_identical_at_every_block_size() {
    // Audition voices age per FRAME, not per block. If the countdown were
    // per-block, a one-shot would be a different LENGTH at 128 than at 512 and
    // the "state advances per frame" rule would be broken by this lane.
    let p = keys_project();
    let reference = render_stopped(&p, vec![note_on(0, 2_000)], 48_000, 512);
    assert!(peak(&reference) > 0.0, "non-silence gate: parity on silence is vacuous");

    for block in [128usize, 417, 480] {
        let out = render_stopped(&p, vec![note_on(0, 2_000)], 48_000, block);
        // The release has to have HAPPENED inside the window at every block
        // size, or "identical" would only mean "both still sustaining" — which
        // a per-BLOCK countdown would satisfy while making the note 128x or
        // 512x too long.
        assert!(peak(&out[..3_000]) > 0.0, "block {block}: the one-shot sounded");
        assert_eq!(
            peak(&out[24_000..]),
            0.0,
            "block {block}: a 2000-FRAME one-shot must have released well before frame 24000"
        );
        assert_eq!(out.len(), reference.len());
        let mut worst = 0.0_f32;
        for (a, b) in out.iter().zip(reference.iter()) {
            worst = worst.max((a[0] - b[0]).abs()).max((a[1] - b[1]).abs());
        }
        assert_eq!(
            worst, 0.0,
            "an audition at block {block} must be BIT-IDENTICAL to block 512"
        );
    }
}

// ---------------------------------------------------------------------------
// 3. The transport must not cut a performance short at the project end
// ---------------------------------------------------------------------------

/// Render with the transport RUNNING, and report both the audio and whether the
/// core was still playing at the end. Deliberately mirrors `render_stopped` so
/// the only difference under test is the `Play`.
fn render_playing(
    p: &Project,
    extra: Vec<ScheduledCommand>,
    total: u64,
    block: usize,
) -> (Vec<[f32; 2]>, bool, u64) {
    let cfg = EngineConfig::default();
    let mut r = ManualRenderer::new(&cfg);
    let mut schedule = vec![
        ScheduledCommand {
            at_frame: 0,
            command: RenderCommand::SetSession(compile(p)),
        },
        ScheduledCommand {
            at_frame: 0,
            command: RenderCommand::Play,
        },
    ];
    schedule.extend(extra);
    let out = render_offline_with(&mut r, schedule, total, block);
    let stats = r.stats();
    let playing = stats
        .playing
        .load(std::sync::atomic::Ordering::Relaxed)
        != 0;
    let position = stats.position_frame.load(std::sync::atomic::Ordering::Relaxed);
    (out, playing, position)
}

#[test]
fn the_transport_runs_past_the_project_end_instead_of_cutting_a_performance_short() {
    // THE finding: "I hit play, played the keyboard, then stop. The track
    // stopped before I hit stop, maybe it was too short."
    //
    // `keys_project` is 8 beats long — 4 bars at 120 BPM, ~4 s. Render 12 s and
    // hold a key across the project end. The transport must still be running and
    // the note must still be sounding: a person's performance is not over
    // because the clips they were playing along to ran out.
    //
    // This pins a rule rather than a fix. The render core does not stop at the
    // project end today (`playing` flips false only when a Stop ramp lands), and
    // adding an end-of-project stop is otherwise a perfectly reasonable thing for
    // a later lane to want. If one is added, it has to exempt a live performance,
    // and this is what will say so.
    let p = keys_project();
    let project_end_frames = 4 * ENGINE_SAMPLE_RATE as u64; // 8 beats @ 120 BPM
    let total = 12 * ENGINE_SAMPLE_RATE as u64;

    let (out, playing, position) = render_playing(
        &p,
        vec![note_on(project_end_frames / 2, 0)], // held, no self-release
        total,
        512,
    );

    assert!(
        playing,
        "the transport must still be running past the project end while a note is held"
    );
    assert!(
        position >= total,
        "the play head must have kept advancing past the project end: {position} < {total}"
    );
    let tail = &out[(project_end_frames as usize + ENGINE_SAMPLE_RATE as usize)..];
    assert!(
        peak(tail) > 0.0,
        "the held note must still be sounding a second past the project end"
    );
}

#[test]
fn an_instrument_is_audible_past_the_project_end_with_the_transport_stopped_too() {
    // The other half of the same rule, and the one that makes the transport
    // irrelevant to playing: a key sounds with the transport parked past the end
    // of the arrangement, so "the project ran out" cannot silence a player.
    let p = keys_project();
    let past_end = 6 * ENGINE_SAMPLE_RATE as u64;
    let cfg = EngineConfig::default();
    let mut r = ManualRenderer::new(&cfg);
    let out = render_offline_with(
        &mut r,
        vec![
            ScheduledCommand {
                at_frame: 0,
                command: RenderCommand::SetSession(compile(&p)),
            },
            ScheduledCommand {
                at_frame: 0,
                command: RenderCommand::Seek { frame: past_end },
            },
            note_on(1_000, 24_000),
        ],
        48_000,
        512,
    );
    assert!(
        peak(&out) > 0.0,
        "a key must sound with the play head parked past the end of the arrangement"
    );
}
