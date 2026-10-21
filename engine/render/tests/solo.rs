//! PRE-DAG SOLO: the AUDIO must change, not just the model.
//!
//! The shipped bug was that `Track::solo` existed in the model and lit up the
//! S button, but never crossed the control->RT boundary, so `RenderCore::render`
//! could not read it and the mix was unchanged. A UI-state test would have
//! passed the whole time. Every assertion here therefore compares RENDERED
//! BUFFERS, never model flags.
//!
//! Two tracks carry constant-DC clips at distinguishable levels (0.25 and
//! 0.50) so a track's contribution to the master sum is identifiable by
//! inspection: mix = 0.75, t1 alone = 0.25, t2 alone = 0.50, neither = 0.0.
//!
//! Solo lives on the same per-strip gain `Slew` as mute, so it also has to be
//! declicked over MICRO_FADE_FRAMES (5 ms / 240 frames at 48k). A hard step is
//! an audible click, so the ramp is asserted too.

use std::collections::HashMap;
use std::sync::Arc;

use render::compile::compile_session;
use render::engine::EngineConfig;
use render::guard;
use render::media::AudioBuf;
use render::offline::{render_offline_with, residual, ManualRenderer, ScheduledCommand};
use render::rt::{RenderCommand, MICRO_FADE_FRAMES};
use timeline_core::{Bpm, Command, FadeShape, Project, Source, TempoMap};

// The counting allocator only observes anything when it IS the binary's global
// allocator; without this the alloc assertion below would be vacuously green.
#[global_allocator]
static ALLOC: guard::CountingAlloc = guard::CountingAlloc;

const T1_LEVEL: f32 = 0.25;
const T2_LEVEL: f32 = 0.50;
const MIX_LEVEL: f32 = T1_LEVEL + T2_LEVEL;
const LEN: u64 = 48_000;

fn project_120() -> Project {
    Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()))
}

fn add_dc(
    project: &mut Project,
    sources: &mut HashMap<String, Arc<AudioBuf>>,
    id: &str,
    level: f32,
) {
    let audio = AudioBuf::from_samples(vec![[level, level]; LEN as usize], id);
    project
        .add_source(Source {
            id: id.into(),
            path: format!("synthetic:{id}"),
            len_frames: audio.len_frames(),
        })
        .unwrap();
    sources.insert(id.to_string(), audio);
}

/// Two tracks, two DC clips at distinguishable levels, no fades.
fn two_track_project() -> (Project, HashMap<String, Arc<AudioBuf>>) {
    let mut project = project_120();
    let mut sources = HashMap::new();
    add_dc(&mut project, &mut sources, "dc1", T1_LEVEL);
    add_dc(&mut project, &mut sources, "dc2", T2_LEVEL);
    for (track, clip, source) in [("t1", "c1", "dc1"), ("t2", "c2", "dc2")] {
        project
            .apply(&Command::TrackAdd {
                track_id: track.into(),
                name: track.into(),
                index: None,
            })
            .unwrap();
        project
            .apply(&Command::ClipPlace {
                track_id: track.into(),
                clip_id: clip.into(),
                source_id: source.into(),
                start_tick: None,
                start_frame: Some(0),
                offset_frames: 0,
                len_frames: LEN,
                gain_db: 0.0,
                fade_in_frames: 0,
                fade_out_frames: 0,
                fade_shape: FadeShape::EqualPower,
            })
            .unwrap();
    }
    (project, sources)
}

/// A playing renderer with the two-track session installed, warmed past any
/// transport ramp. Params are untouched (no mute, no solo).
fn started_renderer(
    project: &Project,
    sources: &HashMap<String, Arc<AudioBuf>>,
    cfg: &EngineConfig,
) -> ManualRenderer {
    let session = compile_session(project, sources, cfg.max_tracks).unwrap();
    let mut renderer = ManualRenderer::new(cfg);
    renderer.send(RenderCommand::SetSession(session));
    renderer.send(RenderCommand::Play);
    let mut warmup = vec![[0.0_f32; 2]; 2_048];
    renderer.render(&mut warmup);
    assert!(
        (warmup[2_000][0] - MIX_LEVEL).abs() < 1e-6,
        "warmup should be the full mix, got {}",
        warmup[2_000][0]
    );
    renderer
}

fn settled(out: &[[f32; 2]]) -> f32 {
    // Well past the 240-frame declick ramp.
    out[out.len() - 1][0]
}

// ---------------------------------------------------------------------------
// 1. The point of the ticket: soloing removes the OTHER track's audio from the
//    rendered output. Buffers, not flags.
// ---------------------------------------------------------------------------

#[test]
fn solo_removes_the_other_tracks_audio_from_the_output() {
    let (project, sources) = two_track_project();
    let cfg = EngineConfig::default();
    let mut renderer = started_renderer(&project, &sources, &cfg);

    renderer.params().set_track_solo(0, true);
    let mut out = vec![[0.0_f32; 2]; 1_024];
    renderer.render(&mut out);

    let v = settled(&out);
    assert!(
        (v - T1_LEVEL).abs() < 1e-6,
        "soloing t1 must leave ONLY t1's {T1_LEVEL} in the output, got {v}"
    );
    assert!(
        (v - MIX_LEVEL).abs() > 0.1,
        "the audio did not change at all (still the full mix {MIX_LEVEL}) -- this is the shipped bug"
    );
    // t2's contribution is gone, not merely attenuated.
    assert!(
        (v - T1_LEVEL).abs() < 1e-6 && (v - (T1_LEVEL + T2_LEVEL * 0.001)).abs() > 1e-5,
        "t2 must be fully absent, residual {v}"
    );

    // And the mirror image: soloing t2 leaves only t2.
    let mut r2 = started_renderer(&project, &sources, &cfg);
    r2.params().set_track_solo(1, true);
    let mut out2 = vec![[0.0_f32; 2]; 1_024];
    r2.render(&mut out2);
    assert!(
        (settled(&out2) - T2_LEVEL).abs() < 1e-6,
        "soloing t2 must leave only {T2_LEVEL}, got {}",
        settled(&out2)
    );
}

// ---------------------------------------------------------------------------
// 2. Any-solo-active gating: with NO track soloed the mix is untouched; the
//    gate only engages once at least one track is soloed.
// ---------------------------------------------------------------------------

#[test]
fn gate_engages_only_while_some_track_is_soloed() {
    let (project, sources) = two_track_project();
    let cfg = EngineConfig::default();
    let mut renderer = started_renderer(&project, &sources, &cfg);

    // No solo anywhere: full mix.
    let mut out = vec![[0.0_f32; 2]; 512];
    renderer.render(&mut out);
    assert!((settled(&out) - MIX_LEVEL).abs() < 1e-6, "no solo -> full mix");

    // Both tracks soloed: nothing is gated, full mix again.
    renderer.params().set_track_solo(0, true);
    renderer.params().set_track_solo(1, true);
    renderer.render(&mut out);
    assert!(
        (settled(&out) - MIX_LEVEL).abs() < 1e-6,
        "all tracks soloed -> nothing gated, got {}",
        settled(&out)
    );

    // Drop one solo: the gate engages for the un-soloed track only.
    renderer.params().set_track_solo(1, false);
    renderer.render(&mut out);
    assert!(
        (settled(&out) - T1_LEVEL).abs() < 1e-6,
        "one solo -> the other track is gated, got {}",
        settled(&out)
    );
}

// ---------------------------------------------------------------------------
// 3. Solo + mute compose. Ableton Live convention: mute is the track
//    activator, solo only implicitly mutes the others -> MUTE WINS.
// ---------------------------------------------------------------------------

#[test]
fn mute_wins_over_solo_on_the_same_track() {
    let (project, sources) = two_track_project();
    let cfg = EngineConfig::default();

    // t1 soloed AND muted, t2 not soloed: t1 silent by its own mute, t2 silent
    // by the solo gate -> total silence.
    let mut a = started_renderer(&project, &sources, &cfg);
    a.params().set_track_solo(0, true);
    a.params().set_track_mute(0, true);
    let mut out = vec![[0.0_f32; 2]; 1_024];
    a.render(&mut out);
    assert_eq!(
        settled(&out),
        0.0,
        "a muted track stays silent even when soloed (mute wins)"
    );

    // t1 soloed+muted, t2 ALSO soloed: t2 survives (it is soloed and not
    // muted), t1 does not.
    let mut b = started_renderer(&project, &sources, &cfg);
    b.params().set_track_solo(0, true);
    b.params().set_track_mute(0, true);
    b.params().set_track_solo(1, true);
    b.render(&mut out);
    assert!(
        (settled(&out) - T2_LEVEL).abs() < 1e-6,
        "only the soloed, unmuted track is audible, got {}",
        settled(&out)
    );

    // Explicit mute on a NON-soloed track is redundant but harmless.
    let mut c = started_renderer(&project, &sources, &cfg);
    c.params().set_track_solo(0, true);
    c.params().set_track_mute(1, true);
    c.render(&mut out);
    assert!(
        (settled(&out) - T1_LEVEL).abs() < 1e-6,
        "solo t1 + mute t2 -> t1 only, got {}",
        settled(&out)
    );
}

// ---------------------------------------------------------------------------
// 4. The declick ramp. Solo must ride the same 5 ms strip-gain Slew as mute:
//    no full-scale sample-to-sample step at the transition.
// ---------------------------------------------------------------------------

#[test]
fn solo_transition_ramps_without_a_step() {
    let (project, sources) = two_track_project();
    let cfg = EngineConfig::default();
    let mut renderer = started_renderer(&project, &sources, &cfg);

    // Engage.
    renderer.params().set_track_solo(0, true);
    let mut down = vec![[0.0_f32; 2]; 1_024];
    renderer.render(&mut down);

    // Per-frame slope bound: each strip's gain moves at most 1/MICRO_FADE_FRAMES
    // per frame, and the falling strip's clip level scales that.
    let bound = T2_LEVEL / MICRO_FADE_FRAMES as f32 + 1e-6;
    for (i, w) in down.windows(2).enumerate() {
        let step = (w[1][0] - w[0][0]).abs();
        assert!(
            step <= bound,
            "solo-on step {step} at frame {i} exceeds the {bound} declick slope (audible click)"
        );
    }
    // It really ramped: a hard gate would land on the target within one frame.
    assert!(
        down[8][0] > T1_LEVEL + 0.1,
        "solo-on must glide, not jump (frame 8 = {})",
        down[8][0]
    );
    assert!(
        (down[MICRO_FADE_FRAMES as usize + 4][0] - T1_LEVEL).abs() < 1e-6,
        "the ramp must complete within MICRO_FADE_FRAMES"
    );

    // Release.
    renderer.params().set_track_solo(0, false);
    let mut up = vec![[0.0_f32; 2]; 1_024];
    renderer.render(&mut up);
    for (i, w) in up.windows(2).enumerate() {
        let step = (w[1][0] - w[0][0]).abs();
        assert!(
            step <= bound,
            "solo-off step {step} at frame {i} exceeds the {bound} declick slope"
        );
    }
    assert!(
        up[8][0] < MIX_LEVEL - 0.1,
        "solo-off must glide back, not jump (frame 8 = {})",
        up[8][0]
    );
}

// ---------------------------------------------------------------------------
// 5. Un-soloing restores the original mix bit-exactly (the Slew arrives
//    exactly on target, so settled values must match the untouched render
//    sample for sample).
// ---------------------------------------------------------------------------

#[test]
fn unsolo_restores_the_original_mix_bit_exactly() {
    let (project, sources) = two_track_project();
    let cfg = EngineConfig::default();

    // Untouched reference, rendered over the same frame span.
    let mut reference = started_renderer(&project, &sources, &cfg);
    let mut ref_out = vec![[0.0_f32; 2]; 3_072];
    reference.render(&mut ref_out);

    // Solo on, hold past the ramp, solo off, hold past the ramp.
    let mut renderer = started_renderer(&project, &sources, &cfg);
    let mut out = vec![[0.0_f32; 2]; 3_072];
    renderer.params().set_track_solo(0, true);
    renderer.render(&mut out[..1_024]);
    renderer.params().set_track_solo(0, false);
    renderer.render(&mut out[1_024..]);

    // Mid-solo the audio genuinely differed...
    assert!(
        (out[1_000][0] - ref_out[1_000][0]).abs() > 0.1,
        "solo must have changed the audio"
    );
    // ...and after release the settled tail is bit-identical to the reference.
    let tail = 2_048;
    let r = residual(&out[tail..], &ref_out[tail..]);
    assert!(
        r.bit_identical,
        "un-soloing must restore the original mix bit-exactly (max_abs {})",
        r.max_abs
    );
}

// ---------------------------------------------------------------------------
// 6. Bounce/live parity survives. A static solo (the bounce case: params are
//    synced before the render starts) must be block-size independent, because
//    the gate is read into per-block targets and every signal state still
//    advances per frame.
// ---------------------------------------------------------------------------

#[test]
fn solo_bounce_is_bit_identical_across_block_sizes() {
    let (project, sources) = two_track_project();
    let cfg = EngineConfig::default();
    let total = 24_000_u64;

    let run = |chunk: usize| -> Vec<[f32; 2]> {
        let session = compile_session(&project, &sources, cfg.max_tracks).unwrap();
        let mut renderer = ManualRenderer::new(&cfg);
        // Solo is part of the synced param state before the first block, the
        // same way `sync_params` mirrors the model into an offline bounce.
        renderer.params().set_track_solo(0, true);
        render_offline_with(
            &mut renderer,
            vec![
                ScheduledCommand {
                    at_frame: 0,
                    command: RenderCommand::SetSession(session),
                },
                ScheduledCommand {
                    at_frame: 0,
                    command: RenderCommand::Play,
                },
            ],
            total,
            chunk,
        )
    };

    let base = run(128);
    for chunk in [417_usize, 480, 512] {
        assert!(
            residual(&base, &run(chunk)).bit_identical,
            "solo bounce must be bit-identical at block size {chunk}"
        );
    }
    // And it is the soloed mix, not the full one.
    assert!(
        (base[base.len() - 1][0] - T1_LEVEL).abs() < 1e-6,
        "bounce with solo must contain only t1"
    );
}

// ---------------------------------------------------------------------------
// 7. RT rules: hammering solo from the control side allocates nothing inside
//    render(). Solo adds only Relaxed atomic loads to the existing per-block
//    target read.
// ---------------------------------------------------------------------------

#[test]
fn hammering_solo_does_not_allocate_on_the_render_path() {
    // Positive control first: the guard can see an allocation at all, so a
    // zero delta below means "clean", not "not looking".
    let control_before = guard::violations();
    guard::enter_render_scope();
    let v: Vec<u8> = Vec::with_capacity(64);
    drop(v);
    guard::leave_render_scope();
    assert!(
        guard::violations() > control_before,
        "the counting allocator is not installed; this assertion would be vacuous"
    );

    let (project, sources) = two_track_project();
    let cfg = EngineConfig::default();
    let mut renderer = started_renderer(&project, &sources, &cfg);
    let mut out = vec![[0.0_f32; 2]; 128];

    let before = guard::violations();
    for block in 0..2_000_u64 {
        // Control-side pressure BETWEEN blocks; allocations here are legal.
        renderer.params().set_track_solo(0, block % 3 == 0);
        renderer.params().set_track_solo(1, block % 7 == 0);
        renderer.params().set_track_mute(0, block % 11 == 0);
        renderer.render(&mut out);
    }
    assert_eq!(
        guard::violations() - before,
        0,
        "render() allocated or freed while the solo gate was moving"
    );
}

// ---------------------------------------------------------------------------
// 8. A solo flag left on a slot the current session no longer uses must not
//    silence the mix (solo is a GLOBAL gate; a stale mute would only affect
//    its own strip).
// ---------------------------------------------------------------------------

#[test]
fn stale_solo_on_an_unused_slot_does_not_gate_the_mix() {
    let (project, sources) = two_track_project();
    let cfg = EngineConfig::default();
    let mut renderer = started_renderer(&project, &sources, &cfg);

    // Slot 7 belongs to no track in this 2-track session.
    renderer.params().set_track_solo(7, true);
    let mut out = vec![[0.0_f32; 2]; 1_024];
    renderer.render(&mut out);
    assert!(
        (settled(&out) - MIX_LEVEL).abs() < 1e-6,
        "a solo on an unused slot must not gate the live tracks, got {}",
        settled(&out)
    );
}

// ===========================================================================
// E5-graph §7.1 — SOLO IS SOLO-IN-PLACE, and bus/group nodes are implicitly
// SOLO-SAFE. Rendered buffers only.
// ===========================================================================

/// Soloing a track whose output goes through a GROUP must not silence it.
///
/// This is the famous footgun §7.1 exists to prevent: if solo gated buses as
/// well as source strips, soloing a track inside a group would produce
/// silence, and the user would file "solo is broken" for the second time in
/// this product's life. Solo gates SOURCES; the group passes through whatever
/// reaches it.
#[test]
fn solo_does_not_silence_a_group_carrying_the_soloed_track() {
    use timeline_core::cmd::Cmd;
    use timeline_core::routing::{NodeKind, NodeRef, Tap};
    use timeline_core::Num;

    let (mut project, sources) = two_track_project();
    project
        .apply_cmd(&Cmd::RouteNodeAdd {
            node_id: "grp".into(),
            kind: NodeKind::Group,
            name: "grp".into(),
        })
        .unwrap();
    // BOTH tracks go through the group, so the group is the only path to
    // master and a gated bus would take the whole mix with it.
    for (edge, track) in [("e1", "t1"), ("e2", "t2")] {
        project
            .apply_cmd(&Cmd::RouteConnect {
                edge_id: edge.into(),
                from: NodeRef::parse(&format!("track.{track}")).unwrap(),
                to: NodeRef::parse("bus.grp").unwrap(),
                level: Num::int(1),
                tap: Tap::Post,
            })
            .unwrap();
    }

    let render = |setup: &dyn Fn(&render::params::EngineParams)| {
        let session = compile_session(&project, &sources, EngineConfig::default().max_tracks)
            .expect("compile");
        let cfg = EngineConfig::default();
        let mut renderer = ManualRenderer::new(&cfg);
        render::compile::sync_graph_params(&project, renderer.params());
        setup(renderer.params());
        render_offline_with(
            &mut renderer,
            vec![
                ScheduledCommand {
                    at_frame: 0,
                    command: RenderCommand::SetSession(session),
                },
                ScheduledCommand {
                    at_frame: 0,
                    command: RenderCommand::Play,
                },
            ],
            4_000,
            512,
        )
    };
    let settled = |v: &[[f32; 2]]| {
        v[(MICRO_FADE_FRAMES as usize) * 4..]
            .iter()
            .fold(0.0_f32, |m, f| m.max(f[0].abs()))
    };

    let open = render(&|_| {});
    assert!(
        (settled(&open) - MIX_LEVEL).abs() < 1e-4,
        "fixture broken: the grouped mix is {}",
        settled(&open)
    );
    let soloed = render(&|p| p.set_track_solo(1, true));
    assert!(
        (settled(&soloed) - T2_LEVEL).abs() < 2e-3,
        "solo through a group produced {} — expected t2 alone ({T2_LEVEL}). \
         0.0 would mean the group itself was gated (§7.1's footgun)",
        settled(&soloed)
    );
}

/// Solo-in-place preserves the SOLOED track's own send: the reverb keeps
/// ringing with the soloed material and nothing else. That is what makes solo
/// useful, and it is what the engine already did — pinned here so the graph
/// walk cannot quietly change it.
#[test]
fn solo_keeps_the_soloed_tracks_own_send() {
    use timeline_core::cmd::{Cmd, SendBus};
    use timeline_core::Num;

    let (mut project, sources) = two_track_project();
    // t2 (the loud one) sends to the legacy reverb; t1 does not.
    project
        .apply_cmd(&Cmd::MixSend {
            track_id: "t2".into(),
            bus: SendBus::A,
            amount: Num::int(1),
        })
        .unwrap();

    let render = |setup: &dyn Fn(&render::params::EngineParams)| {
        let session = compile_session(&project, &sources, EngineConfig::default().max_tracks)
            .expect("compile");
        let cfg = EngineConfig::default();
        let mut renderer = ManualRenderer::new(&cfg);
        render::compile::sync_graph_params(&project, renderer.params());
        renderer.params().set_track_send(1, false, 1.0);
        renderer.params().set_return_db(false, 0.0);
        setup(renderer.params());
        render_offline_with(
            &mut renderer,
            vec![
                ScheduledCommand {
                    at_frame: 0,
                    command: RenderCommand::SetSession(session),
                },
                ScheduledCommand {
                    at_frame: 0,
                    command: RenderCommand::Play,
                },
            ],
            8_000,
            512,
        )
    };
    // With t2 soloed, the reverb must still be fed: the master level has to
    // exceed t2's dry level on its own.
    let soloed = render(&|p| p.set_track_solo(1, true));
    let dry_only = {
        let mut project2 = project.clone();
        project2.tracks[1].sends.a = Num::int(0);
        let session = compile_session(&project2, &sources, EngineConfig::default().max_tracks)
            .expect("compile");
        let cfg = EngineConfig::default();
        let mut renderer = ManualRenderer::new(&cfg);
        render::compile::sync_graph_params(&project2, renderer.params());
        renderer.params().set_track_solo(1, true);
        render_offline_with(
            &mut renderer,
            vec![
                ScheduledCommand {
                    at_frame: 0,
                    command: RenderCommand::SetSession(session),
                },
                ScheduledCommand {
                    at_frame: 0,
                    command: RenderCommand::Play,
                },
            ],
            8_000,
            512,
        )
    };
    let peak = |v: &[[f32; 2]]| {
        v[4_000..].iter().fold(0.0_f32, |m, f| m.max(f[0].abs()))
    };
    assert!(
        peak(&soloed) > peak(&dry_only) + 0.02,
        "the soloed track's own send vanished: with send {} vs without {}",
        peak(&soloed),
        peak(&dry_only)
    );
}
