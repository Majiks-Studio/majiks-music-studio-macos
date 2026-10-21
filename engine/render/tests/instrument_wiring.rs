//! The E1/E2 WIRING gate: notes on the timeline reach an instrument, the
//! instrument reaches the master output, and nothing ever sticks.
//!
//! Everything here asserts on RENDERED BUFFERS coming out of the real
//! `RenderCore::render` — the same function the cpal callback and the offline
//! bounce run. No model state, no voice counters, no "the node exists". Solo
//! shipped broken for months because a UI-state test passed while nothing was
//! audible; `held_voices()` would be exactly that mistake again, one layer down.
//!
//! The bars:
//!
//! 1. **A note makes sound, at the right frame.** Signal from the note-on
//!    frame, EXACT silence strictly before it, and a release that decays to
//!    zero. A parity test on silence is vacuous, so every parity assertion
//!    below is preceded by a non-silence gate.
//! 2. **Bit-identical bounce at 128 / 417 / 480 / 512 with an instrument
//!    actually playing** — including under a loop set AT RUNTIME and a seek.
//! 3. **No stuck notes**, ever: loop fold, seek during sustain, stop during
//!    sustain. Asserted as "the output returns to exact zero and stays there",
//!    which is the only definition an audience can hear.
//! 4. **Zero allocations** on the render path with an instrument playing,
//!    behind a positive control that proves the guard can see one.
//!
//! Nothing here opens an output device. Every render is offline.

use std::collections::HashMap;
use std::sync::Arc;

use render::automation::{AutomationStore, CurveKind, RawPoint};
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
use timeline_core::{Bpm, Num, Project, TempoMap, Track};

#[global_allocator]
static ALLOC: guard::CountingAlloc = guard::CountingAlloc;

/// The four witnesses the engine's own null tests use.
const BLOCK_SIZES: [usize; 4] = [128, 417, 480, 512];
/// Frames per quarter note at 120 BPM, 48 kHz.
const QUARTER: u64 = 24_000;
const DEVICE_ID: &str = "inst1";

// ---------------------------------------------------------------------------
// fixtures
// ---------------------------------------------------------------------------

fn spec(id: &str, start_ticks: u64, len_ticks: u64, pitch: u8, vel: i64) -> NoteSpec {
    NoteSpec {
        note_id: id.into(),
        start_ticks,
        length_ticks: len_ticks,
        pitch,
        velocity: Num::int(vel),
    }
}

/// One track, one synth device, one MIDI clip carrying `notes`. No audio clips
/// at all, so anything non-zero in the master output came from the instrument
/// and nowhere else — that is what makes the silence assertions below mean
/// something.
fn keys_project(clip_len_ticks: u64, notes: Vec<NoteSpec>) -> Project {
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
        length_ticks: clip_len_ticks,
    })
    .expect("clip.placeMidi");
    if !notes.is_empty() {
        p.apply_cmd(&Cmd::NoteAdd {
            clip_id: "cm1".into(),
            notes,
        })
        .expect("note.add");
    }
    p
}

/// A short, snappy patch: a fast attack and a SHORT release, so "the tail
/// reaches zero" is testable inside a couple of seconds of render.
fn set_patch(p: &mut Project) {
    let d = &mut p.tracks[0].devices[0];
    d.params.insert("attack".into(), fnum(0.001));
    d.params.insert("decay".into(), fnum(0.05));
    d.params.insert("sustain".into(), fnum(0.8));
    d.params.insert("release".into(), fnum(0.02));
    d.params.insert("gain".into(), fnum(0.0));
    d.params.insert("cutoff".into(), fnum(8_000.0));
}

/// `Num` from a float. `Num::int` is the only constructor the model exposes
/// (integer shape is load-bearing for the hash chain), so a float parameter
/// goes through `serde_json::Number` directly.
fn fnum(v: f64) -> Num {
    Num(serde_json::Number::from_f64(v).expect("finite"))
}

fn compile(p: &Project, automation: &AutomationStore) -> Box<RtSession> {
    let sources: HashMap<String, Arc<AudioBuf>> = HashMap::new();
    compile_session_full(
        p,
        &sources,
        &WarpOverlay::new(),
        automation,
        EngineConfig::default().max_tracks,
        DeclickPolicy::None,
    )
    .expect("compile")
}

/// Render `total` frames at `block`, driving the real render core.
fn render_at(
    p: &Project,
    automation: &AutomationStore,
    extra: &dyn Fn() -> Vec<ScheduledCommand>,
    total: u64,
    block: usize,
) -> Vec<[f32; 2]> {
    let cfg = EngineConfig::default();
    let mut r = ManualRenderer::new(&cfg);
    let mut schedule = vec![
        ScheduledCommand {
            at_frame: 0,
            command: RenderCommand::SetSession(compile(p, automation)),
        },
        ScheduledCommand {
            at_frame: 0,
            command: RenderCommand::Play,
        },
    ];
    schedule.extend(extra());
    render_offline_with(&mut r, schedule, total, block)
}

fn peak(buf: &[[f32; 2]]) -> f32 {
    buf.iter()
        .map(|f| f[0].abs().max(f[1].abs()))
        .fold(0.0_f32, f32::max)
}

fn no_extra() -> Vec<ScheduledCommand> {
    Vec::new()
}

// ---------------------------------------------------------------------------
// 1. A note makes sound, at the right frame
// ---------------------------------------------------------------------------

#[test]
fn a_note_on_the_timeline_is_audible_at_its_frame_and_silent_strictly_before_it() {
    // Note at beat 2 (frame 24_000), one beat long (off at 48_000).
    let mut p = keys_project(PPQ * 4, vec![spec("n1", PPQ, PPQ, 60, 100)]);
    set_patch(&mut p);
    let out = render_at(&p, &AutomationStore::new(), &no_extra, 72_000, 512);

    // EXACT silence before the attack. Not "quiet" — zero. There is no audio
    // clip in this project, so a single non-zero sample before frame 24_000
    // means the instrument leaked, or a note landed early.
    let before = peak(&out[..QUARTER as usize]);
    assert_eq!(
        before, 0.0,
        "instrument must be silent strictly before the note-on frame"
    );

    // Audible from the note-on frame. The attack is 1 ms (48 frames), so give
    // it a hair; the point is that the note lands on ITS frame, not a block
    // boundary — 512 frames would be the tell.
    let attack_window = peak(&out[QUARTER as usize..(QUARTER + 128) as usize]);
    assert!(
        attack_window > 0.0,
        "the note must be audible within 128 frames of its own frame, \
         not at the next block boundary (peak {attack_window})"
    );
    // And it is real signal, not a denormal.
    let sustain = peak(&out[(QUARTER + 2_000) as usize..(QUARTER * 2) as usize]);
    assert!(sustain > 0.05, "the note sustains at a real level ({sustain})");
}

#[test]
fn the_release_decays_all_the_way_to_zero_after_the_note_off() {
    let mut p = keys_project(PPQ * 4, vec![spec("n1", PPQ, PPQ, 60, 100)]);
    set_patch(&mut p); // 20 ms release
    let out = render_at(&p, &AutomationStore::new(), &no_extra, 96_000, 512);

    let off = (QUARTER * 2) as usize; // frame 48_000
    // Sounding right up to the off.
    assert!(peak(&out[off - 2_000..off]) > 0.05, "note sustains until its off");
    // 20 ms release = 960 frames. Well past it the output must be EXACTLY
    // zero: a truncated release is a click, and a release that asymptotes but
    // never lands leaves a voice alive forever.
    let tail = &out[off + 4_800..];
    assert_eq!(
        peak(tail),
        0.0,
        "release must reach exact zero (peak {})",
        peak(tail)
    );
}

// ---------------------------------------------------------------------------
// 2. Bit-identical bounce with an instrument playing
// ---------------------------------------------------------------------------

#[test]
fn bounce_is_bit_identical_at_128_417_480_512_with_an_instrument_playing() {
    // A chord plus a melody, so several voices are live at once, spanning a
    // loop fold and a seek — the two paths that are transport state and
    // therefore cannot be baked.
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
    let mut p = keys_project(PPQ * 16, notes);
    set_patch(&mut p);

    let extra = || {
        vec![
            ScheduledCommand {
                at_frame: 12_000,
                command: RenderCommand::LoopSet {
                    start_frame: 20_000,
                    end_frame: 44_000,
                },
            },
            ScheduledCommand {
                at_frame: 120_000,
                command: RenderCommand::LoopClear,
            },
            ScheduledCommand {
                at_frame: 130_000,
                command: RenderCommand::Seek { frame: 26_000 },
            },
        ]
    };
    let total = 192_000;
    let auto = AutomationStore::new();

    let reference = render_at(&p, &auto, &extra, total, BLOCK_SIZES[0]);

    // NON-SILENCE GATE FIRST. A parity test on silence is vacuous, and that
    // exact false green has been caught twice in this program.
    let pk = peak(&reference);
    assert!(
        pk > 0.05,
        "the reference render must actually contain the instrument (peak {pk})"
    );
    let nonzero = reference.iter().filter(|f| f[0] != 0.0).count();
    assert!(
        nonzero > total as usize / 4,
        "the instrument must be sounding for most of the render, not a blip \
         ({nonzero} non-zero frames of {total})"
    );

    for block in &BLOCK_SIZES[1..] {
        let other = render_at(&p, &auto, &extra, total, *block);
        let r = residual(&reference, &other);
        assert!(
            r.bit_identical,
            "instrument bounce must be bit-identical at block {block} \
             (peak residual {} dBFS, max_abs {})",
            r.peak_dbfs, r.max_abs
        );
    }
}

// ---------------------------------------------------------------------------
// 3. No stuck notes
// ---------------------------------------------------------------------------

/// The subtle one. A note SUSTAINS ACROSS the loop end, so its authored
/// note-off lies past the fold and is never reached. The loop is set at
/// RUNTIME (`RenderCommand::LoopSet`), not baked, which is the whole point:
/// the loop region is transport state that compile cannot see.
#[test]
fn a_runtime_loop_over_a_sustaining_note_never_strands_a_voice() {
    // Note 10_000 .. 200_000. Loop [0, 48_000): the off at 200_000 can never
    // be reached while the loop is engaged.
    let mut p = keys_project(
        PPQ * 32,
        vec![spec("long", PPQ / 2, PPQ * 8, 60, 110)],
    );
    set_patch(&mut p);

    let extra = || {
        vec![
            ScheduledCommand {
                at_frame: 0,
                command: RenderCommand::LoopSet {
                    start_frame: 0,
                    end_frame: 48_000,
                },
            },
            // Eight folds later: drop the loop and jump somewhere with no
            // notes at all. If ANY voice survived a fold, the output after
            // this seek can never return to zero.
            ScheduledCommand {
                at_frame: 384_000,
                command: RenderCommand::LoopClear,
            },
            ScheduledCommand {
                at_frame: 384_000,
                command: RenderCommand::Seek { frame: 600_000 },
            },
        ]
    };
    let out = render_at(&p, &AutomationStore::new(), &extra, 480_000, 512);

    // Non-silence gate: the loop really was playing the note.
    assert!(
        peak(&out[..384_000]) > 0.05,
        "the looped note must actually have been sounding"
    );

    // THE FOLD ASSERTION, and it has to be this one.
    //
    // An earlier version of this test only checked the tail after the trailing
    // seek — and a mutation run proved that green even with EVERY anti-stuck
    // mechanism removed, because the seek's own release was quietly rescuing
    // it. A test whose subject is silently substituted by another mechanism is
    // exactly the false green this program keeps finding.
    //
    // So: look INSIDE the loop. The note attacks at frame 12_000 of each pass
    // and its authored off is at 204_000, far past the loop end. On every pass
    // AFTER the first, the window between the fold and the next attack must be
    // EXACTLY silent — that silence exists only because the fold released the
    // note. If the note survives a fold it simply keeps sounding through here.
    for pass in 1..8u64 {
        let fold = pass * 48_000;
        // Skip the 20 ms release tail, stop before the next attack at +12_000.
        let gap = &out[(fold + 4_800) as usize..(fold + 12_000) as usize];
        assert_eq!(
            peak(gap),
            0.0,
            "loop pass {pass}: a voice survived the fold — STUCK NOTE (peak {})",
            peak(gap)
        );
        // ...and the note really does re-attack on that pass, so the silence
        // above is a release and not a dead instrument.
        let after_attack = &out[(fold + 12_000) as usize..(fold + 20_000) as usize];
        assert!(
            peak(after_attack) > 0.05,
            "loop pass {pass}: the note did not re-attack after the fold"
        );
    }

    // Separately: the seek path. After LoopClear + a seek past everything the
    // engine is EXACTLY silent and stays that way for the rest of the render.
    let after = &out[384_000 + 9_600..];
    assert_eq!(
        peak(after),
        0.0,
        "a voice survived the seek out of the loop (peak {})",
        peak(after)
    );
}

#[test]
fn a_seek_during_sustain_leaves_nothing_sounding() {
    let mut p = keys_project(PPQ * 32, vec![spec("long", PPQ / 2, PPQ * 8, 60, 110)]);
    set_patch(&mut p);
    let extra = || {
        // Seek mid-note to a region the clip does not cover.
        vec![ScheduledCommand {
            at_frame: 60_000,
            command: RenderCommand::Seek { frame: 600_000 },
        }]
    };
    let out = render_at(&p, &AutomationStore::new(), &extra, 200_000, 512);

    assert!(peak(&out[20_000..60_000]) > 0.05, "the note was sounding");
    let after = &out[60_000 + 9_600..];
    assert_eq!(
        peak(after),
        0.0,
        "seek during sustain left a voice sounding (peak {})",
        peak(after)
    );
}

#[test]
fn a_stop_during_sustain_leaves_nothing_sounding_and_a_restart_is_clean() {
    let mut p = keys_project(PPQ * 32, vec![spec("long", PPQ / 2, PPQ * 8, 60, 110)]);
    set_patch(&mut p);
    let extra = || {
        vec![
            ScheduledCommand {
                at_frame: 60_000,
                command: RenderCommand::Stop,
            },
            // Restart with a BARE Play — deliberately NO seek. An earlier
            // version seeked here, and a mutation run showed the seek's own
            // release was standing in for everything this test claims to
            // check. The transport resumes exactly where it stopped, in the
            // middle of the note, which is the case that actually exercises
            // stop/play note handling.
            ScheduledCommand {
                at_frame: 120_000,
                command: RenderCommand::Play,
            },
        ]
    };
    let out = render_at(&p, &AutomationStore::new(), &extra, 200_000, 512);

    assert!(peak(&out[20_000..60_000]) > 0.05, "the note was sounding");
    let after_stop = &out[60_000 + 9_600..120_000];
    assert_eq!(
        peak(after_stop),
        0.0,
        "stop during sustain left a voice sounding (peak {})",
        peak(after_stop)
    );
    // After the restart the transport is back inside the note's span. The
    // released voice may finish the remainder of its 20 ms release, but the
    // note must NOT resume at sustain level and must NOT re-attack: an attack
    // the cursor never delivered does not sound, exactly as when you start
    // playback in the middle of a note.
    let after_restart = &out[120_000 + 9_600..];
    assert_eq!(
        peak(after_restart),
        0.0,
        "restarting the transport mid-note resurrected the note (peak {})",
        peak(after_restart)
    );
}

/// The instrument sums at the CLIP LAYER, before strip gain/pan/EQ. That is a
/// product requirement, not an implementation detail: summed after the strip
/// it would ignore mute, solo, fader, pan and EQ, and every one of those would
/// be "the control does nothing" — the shape of the solo bug that shipped for
/// months.
///
/// Mute and pan are the two cheapest audible witnesses for the position of the
/// sum. Both are asserted on rendered buffers.
#[test]
fn an_instrument_obeys_track_mute_and_pan_because_it_sums_at_the_clip_layer() {
    let mut p = keys_project(PPQ * 8, vec![spec("n1", 0, PPQ * 4, 57, 110)]);
    set_patch(&mut p);
    let auto = AutomationStore::new();
    let cfg = EngineConfig::default();

    let run = |setup: &dyn Fn(&render::params::EngineParams)| -> Vec<[f32; 2]> {
        let mut r = ManualRenderer::new(&cfg);
        setup(r.params());
        let schedule = vec![
            ScheduledCommand {
                at_frame: 0,
                command: RenderCommand::SetSession(compile(&p, &auto)),
            },
            ScheduledCommand {
                at_frame: 0,
                command: RenderCommand::Play,
            },
        ];
        render_offline_with(&mut r, schedule, 96_000, 512)
    };

    let plain = run(&|_| {});
    assert!(peak(&plain) > 0.05, "baseline instrument is audible");

    let muted = run(&|p: &render::params::EngineParams| p.set_track_mute(0, true));
    assert_eq!(
        peak(&muted),
        0.0,
        "muting the track must silence its instrument (peak {})",
        peak(&muted)
    );

    let hard_left = run(&|p: &render::params::EngineParams| p.set_track_pan(0, -1.0));
    let right = hard_left
        .iter()
        .map(|f| f[1].abs())
        .fold(0.0_f32, f32::max);
    let left = hard_left.iter().map(|f| f[0].abs()).fold(0.0_f32, f32::max);
    assert!(left > 0.05, "hard-left instrument still plays on the left");
    // The balance law's f32 residual at the extreme is ~3.5e-8, the same
    // floor `graph.rs::pan_hard_left_silences_right` allows for audio clips.
    assert!(
        right < 1.0e-6,
        "hard-left pan must silence the right channel of an instrument \
         (peak {right}, left {left})"
    );
}

// ---------------------------------------------------------------------------
// 4. Instrument parameters automate through the dense lane table
// ---------------------------------------------------------------------------

#[test]
fn a_device_param_lane_changes_the_rendered_audio() {
    // `track.device.<id>.cutoff` is an ordinary ParamRef. If the wiring did not
    // read the lane, sweeping the filter from nearly closed to wide open would
    // produce the SAME buffer as the authored static value — silent
    // degradation, the #1 bug class here.
    let mut p = keys_project(PPQ * 8, vec![spec("n1", 0, PPQ * 4, 45, 110)]);
    set_patch(&mut p);

    let flat = compile_and_render(&p, &AutomationStore::new(), 120_000);

    let mut auto = AutomationStore::new();
    let path = format!("track.device.{DEVICE_ID}.cutoff");
    auto.add_point_path(
        "t1",
        &path,
        RawPoint {
            tick: 0,
            value: 200.0,
            curve: CurveKind::Linear,
        },
    );
    auto.add_point_path(
        "t1",
        &path,
        RawPoint {
            tick: PPQ * 4,
            value: 16_000.0,
            curve: CurveKind::Linear,
        },
    );
    let swept = compile_and_render(&p, &auto, 120_000);

    assert!(peak(&flat) > 0.05, "the un-automated render is real audio");
    assert!(peak(&swept) > 0.05, "the automated render is real audio");
    assert!(
        !residual(&flat, &swept).bit_identical,
        "a cutoff automation lane must change the rendered audio"
    );
}

fn compile_and_render(p: &Project, automation: &AutomationStore, total: u64) -> Vec<[f32; 2]> {
    render_at(p, automation, &no_extra, total, 512)
}

/// Automation of an instrument param must ALSO be block-size independent —
/// it is per-frame state, and a lane read that happened once per block would
/// be invisible to every other test in this file.
#[test]
fn an_automated_instrument_is_still_bit_identical_across_block_sizes() {
    let mut p = keys_project(PPQ * 8, vec![spec("n1", 0, PPQ * 4, 45, 110)]);
    set_patch(&mut p);
    let mut auto = AutomationStore::new();
    let path = format!("track.device.{DEVICE_ID}.cutoff");
    for (tick, value) in [(0u64, 300.0_f32), (PPQ, 9_000.0), (PPQ * 4, 400.0)] {
        auto.add_point_path(
            "t1",
            &path,
            RawPoint {
                tick,
                value,
                curve: CurveKind::Linear,
            },
        );
    }
    let reference = render_at(&p, &auto, &no_extra, 120_000, BLOCK_SIZES[0]);
    assert!(peak(&reference) > 0.05, "automated instrument is audible");
    for block in &BLOCK_SIZES[1..] {
        let other = render_at(&p, &auto, &no_extra, 120_000, *block);
        assert!(
            residual(&reference, &other).bit_identical,
            "automated instrument must be bit-identical at block {block}"
        );
    }
}

// ---------------------------------------------------------------------------
// 5. Allocation-free with an instrument playing
// ---------------------------------------------------------------------------

#[test]
fn render_with_an_instrument_playing_allocates_nothing() {
    // POSITIVE CONTROL first: without an installed `#[global_allocator]` this
    // whole test is vacuously green, and a prior lane shipped exactly that.
    let before = guard::violations();
    guard::enter_render_scope();
    let v: Vec<u8> = Vec::with_capacity(64);
    drop(v);
    guard::leave_render_scope();
    assert!(
        guard::violations() > before,
        "the alloc guard cannot see an allocation — is #[global_allocator] installed?"
    );

    // A busy instrument: 64 overlapping notes into a 32-voice pool, so voice
    // STEALING runs hot too (steals are the path most likely to want a heap).
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
    let mut p = keys_project(PPQ * 64, notes);
    set_patch(&mut p);

    let cfg = EngineConfig::default();
    let auto = AutomationStore::new();
    let mut renderer = ManualRenderer::new(&cfg);
    renderer.send(RenderCommand::SetSession(compile(&p, &auto)));
    renderer.send(RenderCommand::Play);

    let mut out = vec![[0.0_f32; 2]; 128];
    for _ in 0..4 {
        renderer.render(&mut out);
    }

    let clean_before = guard::violations();
    let mut heard = 0.0_f32;
    for block in 0..2_000_u64 {
        // Control-side pressure BETWEEN blocks, including session swaps that
        // replace a sounding instrument (the deferred-drop path) and loop /
        // seek storms that hammer the anti-stuck-note lever.
        match block % 16 {
            0 => {
                renderer.send(RenderCommand::SetSession(compile(&p, &auto)));
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
            9 => {
                renderer.params().set_track_gain_db(0, -6.0);
                renderer.params().set_master_gain_db(-1.0);
            }
            _ => {}
        }
        renderer.render(&mut out);
        heard = heard.max(peak(&out));
    }
    let violations = guard::violations() - clean_before;
    assert_eq!(
        violations, 0,
        "render() allocated or freed on the render path with an instrument playing"
    );
    // NON-SILENCE GATE: an allocation test over a silent engine proves nothing.
    assert!(
        heard > 0.01,
        "the instrument must actually have been rendering during the alloc run (peak {heard})"
    );
    let stats = renderer.stats().snapshot();
    assert_eq!(stats.underruns, 0);
    assert_eq!(stats.leaked_buffers, 0);
}

// ---------------------------------------------------------------------------
// 6. A session swap must not cut a sounding instrument dead
// ---------------------------------------------------------------------------

/// The install-time `snap_to`, made falsifiable.
///
/// A freshly compiled node's parameter ramps start at the CONSTRUCTOR default
/// (cutoff 12 kHz), not at the authored value. `install_session` snaps them,
/// mirroring `strip.gain.snap`. At session start that snap is invisible — the
/// 5 ms transport declick covers exactly the same window — so the only place
/// it can be observed is a session swap MID-PLAYBACK, immediately before a
/// note attacks.
///
/// The property asserted is the one a musician would state: swapping in an
/// IDENTICAL session (i.e. making any edit) must not change how the next note
/// sounds. Without the snap the incoming node's filter glides down from 12 kHz
/// across that note's attack and the render differs.
#[test]
fn an_identical_session_swap_just_before_an_attack_is_inaudible() {
    // Authored cutoff is 8 kHz (see `set_patch`), far from the 12 kHz default,
    // so an un-snapped glide is plainly audible on the attack.
    let mut p = keys_project(PPQ * 8, vec![spec("n1", PPQ, PPQ * 2, 45, 110)]);
    set_patch(&mut p);
    let auto = AutomationStore::new();
    let cfg = EngineConfig::default();

    let run = |swap_at: Option<u64>| -> Vec<[f32; 2]> {
        let mut r = ManualRenderer::new(&cfg);
        let mut schedule = vec![
            ScheduledCommand {
                at_frame: 0,
                command: RenderCommand::SetSession(compile(&p, &auto)),
            },
            ScheduledCommand {
                at_frame: 0,
                command: RenderCommand::Play,
            },
        ];
        if let Some(at) = swap_at {
            schedule.push(ScheduledCommand {
                at_frame: at,
                command: RenderCommand::SetSession(compile(&p, &auto)),
            });
        }
        render_offline_with(&mut r, schedule, 96_000, 128)
    };

    let baseline = run(None);
    // Swap 100 frames before the attack at 24_000: inside the 240-frame
    // crossfade AND inside the window an un-snapped ramp would still be moving.
    let swapped = run(Some(23_900));

    assert!(peak(&baseline) > 0.05, "the note is audible at all");
    let r = residual(&baseline, &swapped);
    // Same bar as `graph.rs::identical_session_swap_is_transparent`: a float
    // crossfade of identical content to itself (new*t + old*(1-t)) is
    // transparent to ~-140 dBFS but not bit-exact, so the bar is inaudibility.
    // Measured here: -150 dBFS. An un-snapped incoming node is ~90 dB louder
    // than that.
    assert!(
        r.peak_dbfs < -120.0,
        "an identical session swap changed the next note's sound — the \
         incoming instrument's ramps were not snapped on install \
         (peak residual {} dBFS, max_abs {})",
        r.peak_dbfs, r.max_abs
    );
}

fn rms(buf: &[[f32; 2]]) -> f32 {
    if buf.is_empty() {
        return 0.0;
    }
    (buf.iter().map(|f| f[0] * f[0]).sum::<f32>() / buf.len() as f32).sqrt()
}

/// A session swap (i.e. ANY edit) while a note sustains.
///
/// Documented behaviour, and it is deliberate:
/// * the OUTGOING session's instrument keeps rendering for the whole 5 ms
///   crossfade, so the note fades out instead of being cut dead. That is the
///   reason the wiring renders `old_session`'s instrument at all.
/// * the INCOMING session does NOT re-attack a note that straddles the swap.
///   Its cursor re-anchors at the current position, and an attack the cursor
///   never delivered does not sound — exactly what seeking into the middle of
///   a note already does. Re-attacking would flam against the outgoing tail.
/// * nothing is left sounding afterwards: the old node is deferred-dropped with
///   its voices, and the new one never started any.
///
/// So an edit under a sustaining note ends that note over 5 ms, click-free.
#[test]
fn a_session_swap_mid_note_fades_the_old_voice_out_and_strands_nothing() {
    let mut p = keys_project(PPQ * 32, vec![spec("long", PPQ / 2, PPQ * 8, 60, 110)]);
    set_patch(&mut p);
    let auto = AutomationStore::new();
    let cfg = EngineConfig::default();
    let mut r = ManualRenderer::new(&cfg);
    r.send(RenderCommand::SetSession(compile(&p, &auto)));
    r.send(RenderCommand::Play);

    let mut out = vec![[0.0_f32; 2]; 512];
    let mut all: Vec<[f32; 2]> = Vec::new();
    for block in 0..200 {
        if block == 100 {
            // Identical content: the crossfade of a sounding instrument with
            // itself must not produce a hole.
            r.send(RenderCommand::SetSession(compile(&p, &auto)));
        }
        r.render(&mut out);
        all.extend_from_slice(&out);
    }
    // The swap is drained at the block boundary that starts at `swap`.
    let swap = 100 * 512;
    let before = rms(&all[swap - 2_400..swap]);
    assert!(before > 0.05, "the note was sounding before the swap ({before})");

    // THE ASSERTION THAT MATTERS: the outgoing instrument is still rendered
    // through the 240-frame crossfade. A linear fade to zero over the window
    // leaves rms ≈ before/sqrt(3) ≈ 0.577*before. If the old session's
    // instrument were NOT rendered, this window would be exactly 0.0 and the
    // edit would be a hard click.
    let fade = rms(&all[swap..swap + 240]);
    assert!(
        fade > 0.3 * before,
        "the outgoing instrument was cut dead at the swap instead of fading \
         (crossfade rms {fade} vs {before} before)"
    );

    // And nothing survives it: the incoming session does not re-attack the
    // straddling note, the old node leaves with its voices.
    let after = &all[swap + 480..];
    assert_eq!(
        peak(after),
        0.0,
        "a voice survived the session swap (peak {})",
        peak(after)
    );
}
