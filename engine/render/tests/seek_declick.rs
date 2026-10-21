//! SEEKING WHILE PLAYING MUST NOT CLICK, AND THE PLAY HEAD MUST LAND.
//!
//! A seek mid-playback is a content discontinuity by definition: the sample
//! after the jump has nothing to do with the sample before it. `RenderCommand::
//! Seek` used to handle that by setting `transport_gain = 0.0` and calling it
//! "the jump lands in silence" -- but assigning zero is itself a hard step from
//! whatever the gain was, so the click was not avoided, it was relocated by one
//! frame. Measured on a four-stem tone bed it was a first difference of 2.8e-1
//! against a 1.1e-2 content slope: a full-scale tick, once per seek.
//!
//! That matters more than "once per seek" sounds, because seeks come in
//! streams. Anything that drives the play head from a pointer or a key repeat
//! sends one per event, and a full-scale step repeated at pointer rate is not a
//! click, it is a buzz. (The arrangement's scrub drag used to do exactly this,
//! one `transport.seek` per mouse-move; it now commits one command on release,
//! and this file is the other half of that fix.)
//!
//! The fix defers the jump behind the ramp that already existed: target zero,
//! glide down, move `position` on the frame the gain is exactly zero, glide
//! back up. So the tests here are:
//!
//!   1. the first difference across a mid-playback seek stays inside the
//!      content's own slope (the same oracle `mute_solo_declick.rs` uses);
//!   2. the play head actually ARRIVES -- asserted on `position_frame`, the
//!      engine's own published position, not on a flag;
//!   3. a seek STREAM (a scrub) does not become a per-block buzz;
//!   4. Stop still stops, and Play still plays, when either lands on top of a
//!      seek that is still fading. Both are absorbed deliberately, and both
//!      have a way to be silently wrong: a Stop that lets the pending seek
//!      re-arm the transport RESUMES playback (the app's Stop is literally
//!      seek-then-stop, so this is the shipped path, not a corner);
//!   5. a project that never seeks renders bit-identically, because the
//!      legacy-null pin depends on it.

use std::collections::HashMap;
use std::sync::Arc;

use render::compile::compile_session;
use render::engine::EngineConfig;
use render::media::AudioBuf;
use render::offline::{residual, ManualRenderer};
use render::rt::{RenderCommand, MICRO_FADE_FRAMES};
use timeline_core::{Bpm, Command, FadeShape, Project, Source, TempoMap};

const LEN: u64 = 48_000 * 8;
const RATE: f32 = 48_000.0;
const TRACKS: usize = 4;
const WARMUP: usize = 12_288;
const STEMS: [(f32, f32); TRACKS] = [(220.0, 0.20), (330.0, 0.15), (440.0, 0.12), (550.0, 0.10)];

fn sine(id: &str, hz: f32, amp: f32) -> Arc<AudioBuf> {
    let samples: Vec<[f32; 2]> = (0..LEN as usize)
        .map(|n| {
            let v = amp * (std::f32::consts::TAU * hz * n as f32 / RATE).sin();
            [v, v]
        })
        .collect();
    AudioBuf::from_samples(samples, id)
}

fn stems_project() -> (Project, HashMap<String, Arc<AudioBuf>>) {
    let mut project = Project::new(48_000, TempoMap::single(Bpm::from_int(130).unwrap()));
    let mut sources = HashMap::new();
    for (i, (hz, amp)) in STEMS.into_iter().enumerate() {
        let sid = format!("s{i}");
        let audio = sine(&sid, hz, amp);
        project
            .add_source(Source {
                id: sid.clone(),
                path: format!("synthetic:{sid}"),
                len_frames: audio.len_frames(),
            })
            .unwrap();
        sources.insert(sid.clone(), audio);
        project
            .apply(&Command::TrackAdd {
                track_id: format!("t{i}"),
                name: format!("t{i}"),
                index: None,
            })
            .unwrap();
        project
            .apply(&Command::ClipPlace {
                track_id: format!("t{i}"),
                clip_id: format!("c{i}"),
                source_id: sid,
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

fn warmed(block: usize) -> ManualRenderer {
    let (project, sources) = stems_project();
    let cfg = EngineConfig::default();
    let mut renderer = ManualRenderer::new(&cfg);
    let session = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    renderer.send(RenderCommand::SetSession(session));
    renderer.send(RenderCommand::Play);
    let mut warm = vec![[0.0_f32; 2]; WARMUP];
    for c in warm.chunks_mut(block) {
        renderer.render(c);
    }
    renderer
}

fn render_blocks(r: &mut ManualRenderer, blocks: usize, block: usize) -> Vec<[f32; 2]> {
    let mut out = vec![[0.0_f32; 2]; blocks * block];
    for c in out.chunks_mut(block) {
        r.render(c);
    }
    out
}

/// Render `blocks` blocks into ONE buffer, sending `command` at the block
/// boundary in the middle of it.
///
/// ⚠️ THE EVENT MUST LAND INSIDE THE MEASURED BUFFER, and that is not a detail.
/// The obvious shape -- send the command, then render and measure -- puts the
/// discontinuity between the last sample of the warm-up and the FIRST sample of
/// the buffer, and `max_first_diff` only looks at differences WITHIN the slice
/// it is given. Observed: a mutation that jumped the transport at full gain
/// passed the click assertion at five different seek targets, because the step
/// was always at index -1. Rendering across the event is what makes the
/// measurement able to see it at all.
fn render_across(
    r: &mut ManualRenderer,
    blocks: usize,
    block: usize,
    command: RenderCommand,
) -> Vec<[f32; 2]> {
    let mut out = vec![[0.0_f32; 2]; blocks * block];
    let at = blocks / 2;
    let mut pending = Some(command);
    for (i, c) in out.chunks_mut(block).enumerate() {
        if i == at {
            let cmd = pending.take().expect("sent once");
            assert!(r.send(cmd), "command channel full");
        }
        r.render(c);
    }
    out
}

fn max_first_diff(buf: &[[f32; 2]]) -> (f32, usize) {
    let mut worst = 0.0_f32;
    let mut at = 0;
    for (i, w) in buf.windows(2).enumerate() {
        let d = (w[1][0] - w[0][0]).abs().max((w[1][1] - w[0][1]).abs());
        if d > worst {
            worst = d;
            at = i;
        }
    }
    (worst, at)
}

/// Peak above ~4 kHz -- the broadband signature of a step. See the same helper
/// in `mute_solo_declick.rs` for why this band and why no FFT.
fn hf_peak(buf: &[[f32; 2]]) -> f32 {
    let dt = 1.0 / RATE;
    let rc = 1.0 / (std::f32::consts::TAU * 4_000.0);
    let a = rc / (rc + dt);
    let mut st = [(0.0_f32, 0.0_f32); 4];
    let mut peak = 0.0_f32;
    // ⚠️ THE FILTER'S OWN START-UP IS NOT SIGNAL. Zeroed state against a
    // non-zero first sample IS a step, and a four-pole high pass reports it as
    // a large transient — which, before this skip, was the largest thing in
    // every buffer measured here and made every comparison below a comparison
    // of two identical numbers. Discard the first PRIME samples from the PEAK
    // (the filter still runs over them, so its state is settled by the time
    // measurement starts).
    const PRIME: usize = 2_048;
    for (i, f) in buf.iter().enumerate() {
        let mut x = f[0];
        for s in st.iter_mut() {
            let y = a * (s.1 + x - s.0);
            s.0 = x;
            s.1 = y;
            x = y;
        }
        if i >= PRIME {
            peak = peak.max(x.abs());
        }
    }
    peak
}

const TOLERANCE: f32 = 1.6;

/// The same buffer with ONE un-declicked gate in the middle: what the bug
/// under test sounds like, on this material, through this filter. The
/// high-frequency bound is stated against it rather than against the untouched
/// render, for the reason spelled out on `CLICK_MARGIN` in
/// `mute_solo_declick.rs`: a correct declick is a LINEAR ramp, a linear ramp
/// has corners, and corners put a small, real, inaudible amount of energy up
/// here. A bound of "a bit more than the clean render" therefore fails on
/// correct behaviour; a bound of "far below a real click" does not, and is the
/// claim that actually matters.
fn hard_gated(buf: &[[f32; 2]]) -> Vec<[f32; 2]> {
    let mut out = buf.to_vec();
    for f in out.iter_mut().skip(buf.len() / 2) {
        *f = [0.0, 0.0];
    }
    out
}

/// How far below a single un-declicked gate a clean seek has to sit.
const CLICK_MARGIN: f32 = 20.0;

// ---------------------------------------------------------------------------
// 1 + 2. One seek: no step, and the play head lands.
// ---------------------------------------------------------------------------

#[test]
fn a_seek_mid_playback_does_not_click_and_the_playhead_lands() {
    let block = 512;
    let blocks = 64;

    let mut r = warmed(block);
    let reference = render_blocks(&mut r, blocks, block);
    let (rd, _) = max_first_diff(&reference);
    let rh = hf_peak(&hard_gated(&reference));

    // ⚠️ SEVERAL TARGETS, NOT ONE. The size of an un-declicked seek's step is
    // the difference between two arbitrary points on the waveform, so it
    // depends entirely on where you land: a single hard-coded destination can
    // fall on a phase where the two samples happen to agree, and then the
    // assertion passes with the declick removed. That is not a hypothetical --
    // it was observed. Frame 137_777 alone let a mutation that jumps at full
    // gain through this test untouched; the sweep below catches it at the
    // first target and every one after it.
    for target in [137_777_u64, 96_000, 211_111, 150_007, 44_101] {
        let mut s = warmed(block);
        let out = render_across(&mut s, blocks, block, RenderCommand::Seek { frame: target });

        let (md, at) = max_first_diff(&out);
        assert!(
            md <= rd * TOLERANCE,
            "seek to {target} stepped the output: max first difference \
             {md:.6e} at frame {at} exceeds {TOLERANCE}x the untouched \
             render's own slope {rd:.6e}"
        );
        assert!(
            hf_peak(&out) * CLICK_MARGIN <= rh,
            "seek to {target} put broadband energy above 4 kHz: {:.6e} is \
             within {CLICK_MARGIN}x of the {rh:.6e} a single un-declicked gate \
             puts there",
            hf_peak(&out)
        );

        // THE SEEK ACTUALLY HAPPENED, asserted on the engine's published
        // position. Everything above passes on a seek that was dropped.
        let landed = s.stats().snapshot().position_frame;
        let expected_hi = target + (blocks * block) as u64 + MICRO_FADE_FRAMES;
        assert!(
            (target..=expected_hi).contains(&landed),
            "the play head must be at the seek target plus the frames rendered \
             since ({landed} not in {target}..={expected_hi})"
        );
        // And the transport is still rolling -- a seek is a jump, not a stop.
        assert!(
            s.stats().snapshot().playing,
            "a seek must not halt the transport"
        );
    }
}

/// The declick costs at most one 5 ms fade of latency, and the jump must not
/// take longer than that: a seek that took 100 ms to land would feel broken
/// even though every discontinuity assertion above stayed green.
#[test]
fn the_seek_lands_within_the_declick_window() {
    let block = 128;
    let mut s = warmed(block);
    const TARGET: u64 = 200_000;
    assert!(s.send(RenderCommand::Seek { frame: TARGET }));

    // One fade-out, rounded up to whole blocks, plus one block of slack.
    let blocks = (MICRO_FADE_FRAMES as usize).div_ceil(block) + 1;
    render_blocks(&mut s, blocks, block);
    let landed = s.stats().snapshot().position_frame;
    assert!(
        landed >= TARGET,
        "the play head has not reached the target yet ({landed} < {TARGET}) -- \
         the deferred jump never fired"
    );
    assert!(
        landed <= TARGET + (blocks * block) as u64,
        "the play head overshot ({landed} > {TARGET} + {})",
        blocks * block
    );
}

// ---------------------------------------------------------------------------
// 3. A SEEK STREAM. This is the shape that turns a click into a screech.
// ---------------------------------------------------------------------------

#[test]
fn a_seek_stream_never_becomes_a_per_block_buzz() {
    let block = 512;
    let blocks = 64;

    let mut r = warmed(block);
    let reference = render_blocks(&mut r, blocks, block);
    let (rd, _) = max_first_diff(&reference);
    let rh = hf_peak(&hard_gated(&reference));

    let mut s = warmed(block);
    let mut out = vec![[0.0_f32; 2]; blocks * block];
    for (i, c) in out.chunks_mut(block).enumerate() {
        assert!(s.send(RenderCommand::Seek {
            frame: 137_777 + (i as u64) * 977
        }));
        s.render(c);
    }
    let (md, at) = max_first_diff(&out);
    assert!(
        md <= rd * TOLERANCE,
        "a seek per block stepped the output at frame {at}: {md:.6e} vs \
         {TOLERANCE}x {rd:.6e}. A step that repeats at block rate is a buzz at \
         {} Hz, not a click.",
        48_000 / block
    );
    assert!(
        hf_peak(&out) * CLICK_MARGIN <= rh,
        "a seek per block put broadband energy above 4 kHz: {:.6e} is within \
         {CLICK_MARGIN}x of the {rh:.6e} a single un-declicked gate puts there. \
         A step that repeats is a screech.",
        hf_peak(&out)
    );
}

// ---------------------------------------------------------------------------
// 4. Stop and Play on top of a fading seek.
// ---------------------------------------------------------------------------

/// The app's Stop is `seek(0)` then `stop`, in that order and deliberately.
/// If the pending seek were allowed to fire after the Stop it would set the
/// transport target back to 1.0 and playback would RESUME from the start --
/// "Stop does nothing", which this codebase has already shipped once.
#[test]
fn stop_on_top_of_a_pending_seek_still_stops_and_lands_at_the_target() {
    let block = 128;
    let mut s = warmed(block);
    assert!(s.send(RenderCommand::Seek { frame: 0 }));
    assert!(s.send(RenderCommand::Stop));

    // Well past both the seek fade and the stop ramp.
    render_blocks(&mut s, 16, block);
    assert!(
        !s.stats().snapshot().playing,
        "Stop must halt the transport even when a seek was still fading"
    );
    // The position stopped at (or just after) the seek target, not wherever
    // playback had got to. A few frames of the stop tail are expected.
    let landed = s.stats().snapshot().position_frame;
    // The position keeps advancing through the stop RAMP (documented on
    // `RenderCommand::Stop`), so "near 0" is one declick window, not exactly 0.
    // What this rules out is the failure that matters: playback continuing from
    // where it was (~12k frames in) because the seek was dropped, or resuming
    // from 0 because the pending seek re-armed the transport.
    assert!(
        landed <= MICRO_FADE_FRAMES + 64,
        "Stop must land the pending seek: play head at {landed}, expected near 0"
    );
}

/// Play on top of a fading seek must roll FROM THE SEEK TARGET. Dropping the
/// pending seek here would resume from the old position, i.e. the play head
/// would visibly jump back the moment you pressed Play.
#[test]
fn play_on_top_of_a_pending_seek_rolls_from_the_target() {
    let block = 128;
    let mut s = warmed(block);
    const TARGET: u64 = 300_000;
    assert!(s.send(RenderCommand::Seek { frame: TARGET }));
    assert!(s.send(RenderCommand::Play));

    render_blocks(&mut s, 8, block);
    assert!(s.stats().snapshot().playing, "Play must roll");
    let landed = s.stats().snapshot().position_frame;
    assert!(
        (TARGET..=TARGET + (8 * block) as u64).contains(&landed),
        "Play must resume from the seek target ({landed} not near {TARGET})"
    );
}

/// A seek while STOPPED is immediate: nothing is sounding, so there is nothing
/// to declick, and the position must be there before anyone asks.
#[test]
fn a_seek_while_stopped_is_immediate() {
    let block = 128;
    let (project, sources) = stems_project();
    let cfg = EngineConfig::default();
    let mut r = ManualRenderer::new(&cfg);
    let session = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    r.send(RenderCommand::SetSession(session));
    const TARGET: u64 = 123_456;
    r.send(RenderCommand::Seek { frame: TARGET });
    render_blocks(&mut r, 1, block);
    assert_eq!(
        r.stats().snapshot().position_frame,
        TARGET,
        "a stopped seek must not advance, ramp, or defer"
    );
    assert!(!r.stats().snapshot().playing);
}

// ---------------------------------------------------------------------------
// 5. The legacy pin: a project that never seeks is untouched.
// ---------------------------------------------------------------------------

#[test]
fn a_render_with_no_seek_is_bit_identical_across_block_sizes() {
    let run = |block: usize| -> Vec<[f32; 2]> {
        let (project, sources) = stems_project();
        let cfg = EngineConfig::default();
        let mut r = ManualRenderer::new(&cfg);
        let session = compile_session(&project, &sources, cfg.max_tracks).unwrap();
        r.send(RenderCommand::SetSession(session));
        r.send(RenderCommand::Play);
        let mut out = vec![[0.0_f32; 2]; 96_000];
        for c in out.chunks_mut(block) {
            r.render(c);
        }
        out
    };
    let base = run(512);
    for block in [128_usize, 417, 480] {
        assert!(
            residual(&base, &run(block)).bit_identical,
            "the deferred-seek path must be inert when nothing seeks \
             (block {block} diverged)"
        );
    }
}
