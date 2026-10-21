//! MUTE AND SOLO MUST NOT MAKE A NOISE OF THEIR OWN.
//!
//! `solo.rs` already proves solo changes the mix and that the strip gain
//! glides. What it does NOT do is measure the OUTPUT for the artefact a user
//! actually reports, and it does not drive the path the app drives.
//!
//! Two gaps, both of which this file exists to close.
//!
//! **1. The oracle.** "The gain reached zero" and "no step larger than the
//! declick slope" both pass on a DC clip, which is what `solo.rs` uses — and a
//! DC clip has no slope of its own, so the bound is trivially generous. These
//! tests render TONES (four sines, like four stems), toggle the switch
//! mid-render, and compare two numbers against a REFERENCE RENDER of the same
//! span with nothing touched:
//!
//!   * the maximum absolute FIRST DIFFERENCE — a step of any size shows up
//!     here and nowhere else, because a step is by definition one sample of
//!     slope that the content cannot account for;
//!   * PEAK ENERGY ABOVE 4 kHz, well above every partial in the source. A
//!     step is broadband, so it lands in that band; the clean mix does not.
//!     This is the "screech" measurement: a discontinuity that REPEATS (per
//!     block, per command) is a buzz whose harmonics live up here, and a
//!     first-difference test alone would report the same single number for
//!     one click as for a thousand of them.
//!
//! **2. The path.** The app does NOT reach the render core the way `solo.rs`
//! does. `StudioHost::sync_after_mutation` runs on EVERY bus command, and it
//! does two things: `sync_params` (the whole mixer block — mute, solo, gain,
//! pan, four EQ bands, both sends, master, limiter) and a RECOMPILED
//! `SetSession`, which starts a swap crossfade on the audio thread. So every
//! mute press is a param write AND a session swap. Both are exercised here,
//! separately and together, plus the storm case (a push every block), because
//! a per-block artefact is exactly the thing that sounds like a screech and
//! exactly the thing a single-toggle test cannot see.
//!
//! The project is deliberately NOT the minimum: non-flat EQ on every strip (so
//! the bank is not bypassed), both sends open (so the reverb and delay buses
//! are live and their feedback paths are running), master trim and the limiter
//! engaged. A declick bug that only shows through a live filter or a live
//! feedback bus would pass on a bare project.

use std::collections::HashMap;
use std::sync::Arc;

use render::compile::compile_session;
use render::engine::EngineConfig;
use render::media::AudioBuf;
use render::offline::ManualRenderer;
use render::rt::RenderCommand;
use timeline_core::{Bpm, Command, FadeShape, Project, Source, TempoMap};

const LEN: u64 = 48_000 * 8;
const RATE: f32 = 48_000.0;
const TRACKS: usize = 4;
/// Long enough that every glide in the graph (strip gain, pan, sends, EQ
/// coefficient ramps, the limiter's own smoothing) has settled before a
/// measurement starts. A reference contaminated by the engine warming up
/// reports a bigger first difference than any real click, which would make
/// every assertion below vacuous.
const WARMUP: usize = 12_288;

/// Four "stems" at four pitches, at four levels, so each one's contribution to
/// the sum is identifiable and none of them is DC.
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

/// A playing renderer plus the model state the host mirrors into it.
struct Rig {
    project: Project,
    sources: HashMap<String, Arc<AudioBuf>>,
    renderer: ManualRenderer,
    cfg: EngineConfig,
    mute: [bool; TRACKS],
    solo: [bool; TRACKS],
}

impl Rig {
    /// Warmed and settled: params pushed, session installed, transport rolling.
    fn new(block: usize) -> Self {
        let (project, sources) = stems_project();
        let cfg = EngineConfig::default();
        let renderer = ManualRenderer::new(&cfg);
        let session = compile_session(&project, &sources, cfg.max_tracks).unwrap();
        renderer.send(RenderCommand::SetSession(session));
        renderer.send(RenderCommand::Play);
        let mut rig = Self {
            project,
            sources,
            renderer,
            cfg,
            mute: [false; TRACKS],
            solo: [false; TRACKS],
        };
        rig.sync();
        rig.render_blocks(WARMUP / block, block);
        rig
    }

    /// Everything `StudioHost::sync_params` pushes, on EVERY mixer command.
    fn sync(&self) {
        let p = self.renderer.params();
        for i in 0..TRACKS {
            p.set_track_mute(i, self.mute[i]);
            p.set_track_solo(i, self.solo[i]);
            p.set_track_gain_db(i, -3.0);
            p.set_track_pan(i, 0.1 * i as f32);
            // Non-flat, so `EqBank` is NOT in its bit-exact bypass.
            p.set_track_eq(i, 0, 80.0, 3.0, 0.7);
            p.set_track_eq(i, 1, 500.0, -2.0, 1.0);
            p.set_track_eq(i, 2, 2_000.0, 2.0, 1.0);
            p.set_track_eq(i, 3, 8_000.0, -1.0, 0.7);
            // Both FX buses live, so the reverb and delay feedback paths are
            // running while the gate moves.
            p.set_track_send(i, false, 0.25);
            p.set_track_send(i, true, 0.15);
        }
        p.clear_track_solos_from(TRACKS);
        p.set_master_gain_db(-1.0);
        p.set_limiter(true, -0.3, 50.0);
    }

    /// The second half of a bus mutation: a recompiled snapshot, which starts a
    /// swap crossfade on the audio thread.
    fn push_session(&mut self) {
        let session = compile_session(&self.project, &self.sources, self.cfg.max_tracks).unwrap();
        assert!(
            self.renderer.send(RenderCommand::SetSession(session)),
            "command channel full -- the rig, not the engine, is broken"
        );
    }

    fn render_blocks(&mut self, blocks: usize, block: usize) -> Vec<[f32; 2]> {
        let mut out = vec![[0.0_f32; 2]; blocks * block];
        for c in out.chunks_mut(block) {
            self.renderer.render(c);
        }
        out
    }

    /// Render `blocks` blocks into ONE buffer, running `toggle` (a mixer edit,
    /// pushed exactly as the host pushes one) at the block boundary in the
    /// middle of it.
    ///
    /// ⚠️ THE EVENT MUST LAND INSIDE THE MEASURED BUFFER. The obvious shape --
    /// toggle, then render and measure -- puts the transition between the last
    /// sample of the warm-up and the FIRST sample of the buffer, and
    /// `max_first_diff` only looks at differences WITHIN the slice it is given.
    /// A mutation that replaces the strip's 5 ms glide with a hard snap then
    /// passes, because the step is at index -1. This was observed on the
    /// companion `seek_declick.rs` before it was found here.
    fn render_across(
        &mut self,
        blocks: usize,
        block: usize,
        swap: bool,
        toggle: impl FnOnce(&mut Self),
    ) -> Vec<[f32; 2]> {
        let mut out = vec![[0.0_f32; 2]; blocks * block];
        let at = blocks / 2;
        let mut toggle = Some(toggle);
        for (i, c) in out.chunks_mut(block).enumerate() {
            if i == at {
                (toggle.take().expect("run once"))(self);
                self.sync();
                if swap {
                    self.push_session();
                }
            }
            self.renderer.render(c);
        }
        out
    }
}

/// The maximum absolute sample-to-sample step in a buffer. A step edge shows up
/// here as a value the content's own slope cannot produce.
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

/// Peak level above ~4 kHz, well clear of every partial in the source (the
/// highest sine is 550 Hz). Four cascaded one-pole high passes: enough
/// stop-band rejection that the clean mix sits far below any step edge, and
/// simple enough that this file needs no FFT.
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

/// The half of the buffer AFTER the toggle. `render_across` puts the event at
/// the midpoint, so a level assertion has to look here: comparing whole buffers
/// halves the effect and makes an "it got quieter" bound a coin flip.
fn tail(buf: &[[f32; 2]]) -> &[[f32; 2]] {
    &buf[buf.len() / 2..]
}

fn rms(buf: &[[f32; 2]]) -> f32 {
    if buf.is_empty() {
        return 0.0;
    }
    let s: f64 = buf
        .iter()
        .map(|f| f64::from(f[0]) * f64::from(f[0]) + f64::from(f[1]) * f64::from(f[1]))
        .sum();
    (s / (buf.len() as f64 * 2.0)).sqrt() as f32
}

/// How much worse than the untouched render a toggle is allowed to be.
///
/// Not 1.0: muting removes a partial, which genuinely changes the waveform's
/// slope and its high-frequency content in both directions, and the strip's
/// 5 ms glide is itself a (bounded) change. 1.6 is loose enough for that and
/// nowhere near a step: a hard gate on this material steps by ~0.1-0.5, which
/// is 10-40x the content's worst slope, and the mutation table in the report
/// shows the assertion firing when the slew is replaced by a snap.
const TOLERANCE: f32 = 1.6;

/// Reference: the same span, same rig, nothing touched.
fn reference(block: usize, blocks: usize) -> Vec<[f32; 2]> {
    let mut r = Rig::new(block);
    r.render_blocks(blocks, block)
}

/// The same buffer with ONE un-declicked gate in the middle of it: what the
/// bug under test sounds like, on this exact material, measured by this exact
/// filter. It is the calibration the high-frequency bound is stated against.
fn hard_gated(buf: &[[f32; 2]]) -> Vec<[f32; 2]> {
    let mut out = buf.to_vec();
    for f in out.iter_mut().skip(buf.len() / 2) {
        *f = [0.0, 0.0];
    }
    out
}

/// How far BELOW a single un-declicked gate a clean toggle has to sit.
///
/// The high-frequency bound is deliberately NOT stated as a multiple of the
/// reference. A correct 5 ms declick is a LINEAR ramp, and a linear ramp has a
/// corner at each end — a discontinuity in the first derivative — which puts a
/// small, real, entirely inaudible amount of energy above 4 kHz. Toggle forty
/// gates in a second (the storm case) and that legitimately reaches a few times
/// the untouched render's floor, so a bound like "1.6x the reference" fails on
/// correct behaviour and teaches the next reader to loosen it until it stops.
///
/// Stating it against a real click instead makes the claim the one that
/// matters: whatever the ramps leave behind is at least 20x quieter than the
/// artefact this file exists to catch. Measured, the margin is several hundred
/// times, so 20 is not a squeeze — and a genuine step cannot pass it, by
/// construction, because a genuine step IS the number on the right.
const CLICK_MARGIN: f32 = 20.0;

fn assert_no_artefact(label: &str, measured: &[[f32; 2]], reference: &[[f32; 2]]) {
    let (rd, _) = max_first_diff(reference);
    let (md, at) = max_first_diff(measured);
    let mh = hf_peak(measured);
    let click_h = hf_peak(&hard_gated(reference));
    assert!(
        md <= rd * TOLERANCE,
        "{label}: max first difference {md:.6e} at frame {at} exceeds \
         {TOLERANCE}x the untouched render's own worst slope {rd:.6e} -- \
         that is a step edge, i.e. an audible discontinuity"
    );
    assert!(
        mh * CLICK_MARGIN <= click_h,
        "{label}: peak energy above 4 kHz is {mh:.6e}, within {CLICK_MARGIN}x of \
         the {click_h:.6e} a single un-declicked gate puts there on this same \
         material -- that is broadband junk of the order a click makes, and a \
         click that repeats is a screech"
    );
}

// ---------------------------------------------------------------------------
// 1. Mute, through the app's own path: params AND a recompiled session.
// ---------------------------------------------------------------------------

#[test]
fn muting_a_track_mid_playback_adds_no_discontinuity() {
    for block in [128_usize, 512] {
        let blocks = 48_000 / block;
        let reference = reference(block, blocks);

        let mut rig = Rig::new(block);
        let out = rig.render_across(blocks, block, true, |r| r.mute[1] = true);

        // The mute really happened: a track left the mix. Without this the
        // assertions below would pass on a render where nothing changed.
        assert!(
            rms(tail(&out)) < rms(tail(&reference)) * 0.97,
            "block {block}: muting a track must REMOVE audio (rms {} vs {})",
            rms(tail(&out)),
            rms(tail(&reference))
        );
        assert_no_artefact(&format!("mute (block {block})"), &out, &reference);
    }
}

/// The same toggle with the session swap left out. Both halves of the app's
/// mutation path have to be clean on their own, or a green pair could be two
/// artefacts cancelling.
#[test]
fn muting_through_params_alone_adds_no_discontinuity() {
    let block = 512;
    let blocks = 48_000 / block;
    let reference = reference(block, blocks);

    let mut rig = Rig::new(block);
    let out = rig.render_across(blocks, block, false, |r| r.mute[1] = true);
    assert!(rms(tail(&out)) < rms(tail(&reference)) * 0.97, "the mute must be audible");
    assert_no_artefact("mute (params only)", &out, &reference);
}

// ---------------------------------------------------------------------------
// 2. Solo. It moves EVERY track's gate at once, so an artefact that is quiet
//    with one mute is three times louder here.
// ---------------------------------------------------------------------------

#[test]
fn soloing_moves_every_gate_without_a_discontinuity() {
    for block in [128_usize, 512] {
        let blocks = 48_000 / block;
        let reference = reference(block, blocks);

        let mut rig = Rig::new(block);
        let out = rig.render_across(blocks, block, true, |r| r.solo[0] = true);

        // Three of the four stems left: the gate moved on every one of them.
        // The bound is 0.85 rather than the 0.68 the bare stem levels predict
        // because the reverb and delay returns still carry the tail of what was
        // just gated. A solo that did nothing reads 1.0, so this still fails on
        // a no-op — which is the thing it is here to catch.
        assert!(
            rms(tail(&out)) < rms(tail(&reference)) * 0.85,
            "block {block}: solo must gate the other three tracks (rms {} vs {})",
            rms(tail(&out)),
            rms(tail(&reference))
        );
        assert_no_artefact(&format!("solo on (block {block})"), &out, &reference);
    }
}

/// Releasing solo brings three gates back UP at once. Un-gating is the
/// direction that is easy to get wrong, because the strip glide has to open
/// from exactly zero rather than close to it.
#[test]
fn releasing_solo_restores_every_gate_without_a_discontinuity() {
    let block = 512;
    let blocks = 48_000 / block;
    let reference = reference(block, blocks);

    let mut rig = Rig::new(block);
    rig.solo[0] = true;
    rig.sync();
    rig.push_session();
    rig.render_blocks(blocks, block);

    let out = rig.render_across(blocks, block, true, |r| r.solo[0] = false);

    assert!(
        rms(tail(&out)) > rms(tail(&reference)) * 0.97,
        "releasing solo must bring the mix back (rms {} vs {})",
        rms(tail(&out)),
        rms(tail(&reference))
    );
    assert_no_artefact("solo off", &out, &reference);
}

// ---------------------------------------------------------------------------
// 3. THE SCREECH CASE. One click is a tick; a discontinuity that repeats at
//    block rate is a buzz at (sample_rate / block) Hz with a huge harmonic
//    series, which is what "high pitched screech" describes. So: the whole
//    mutation push, every block, for a second.
// ---------------------------------------------------------------------------

#[test]
fn a_mute_storm_never_becomes_a_per_block_buzz() {
    for block in [128_usize, 512] {
        let blocks = 48_000 / block;
        let reference = reference(block, blocks);

        let mut rig = Rig::new(block);
        let mut out = vec![[0.0_f32; 2]; blocks * block];
        let mut toggles = 0;
        for (i, chunk) in out.chunks_mut(block).enumerate() {
            let want = i % 7 == 0;
            let slot = i % TRACKS;
            if rig.mute[slot] != want {
                toggles += 1;
            }
            rig.mute[slot] = want;
            rig.sync();
            rig.push_session();
            rig.renderer.render(chunk);
        }
        assert!(
            toggles > 20,
            "block {block}: the storm must actually toggle mutes ({toggles})"
        );
        assert_no_artefact(&format!("mute storm (block {block})"), &out, &reference);
    }
}

// ---------------------------------------------------------------------------
// 4. The oracle can see a step at all.
//
//    Every assertion above is an upper bound, and an upper bound that nothing
//    can exceed is not a test. This drives a full-scale discontinuity into the
//    SAME measurement functions and requires them to report it, so a green run
//    above means "no step", not "the detector is blind".
// ---------------------------------------------------------------------------

#[test]
fn the_measurement_reports_a_step_when_there_is_one() {
    let block = 512;
    let blocks = 48_000 / block;
    let reference = reference(block, blocks);

    // Take the untouched render and gate it hard, once, mid-buffer -- exactly
    // what an un-slewed mute would produce.
    let mut stepped = reference.clone();
    for f in stepped.iter_mut().skip(blocks * block / 2) {
        *f = [0.0, 0.0];
    }
    let (rd, _) = max_first_diff(&reference);
    let (sd, _) = max_first_diff(&stepped);
    assert!(
        sd > rd * TOLERANCE,
        "a hard gate must exceed the tolerance the tests above rely on \
         ({sd:.6e} vs {rd:.6e} * {TOLERANCE})"
    );
    // And it must fail the high-frequency bound too, which is stated against
    // this very buffer: a hard gate compared with itself is 1x, and the bound
    // demands CLICK_MARGIN x quieter.
    assert!(
        hf_peak(&stepped) * CLICK_MARGIN > hf_peak(&hard_gated(&reference)),
        "the high-frequency bound must reject a hard gate"
    );
    assert!(
        hf_peak(&stepped) > hf_peak(&reference) * 10.0,
        "a hard gate must put broadband energy above 4 kHz, well clear of the \
         clean render ({:.6e} vs {:.6e})",
        hf_peak(&stepped),
        hf_peak(&reference)
    );
}
