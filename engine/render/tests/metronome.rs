//! THE METRONOME GATE.
//!
//! Every assertion in this file is on RENDERED SAMPLES. A test that checked
//! `params.metronome_enabled() == true` is precisely the kind of test that let
//! a metronome ship as a flag that produced no sound: the model updated, the
//! command journalled, and nothing was audible. So: transients at computed
//! frames, bit-identity of buffers, and peak levels — never a flag.
//!
//! The four bars:
//!
//! 1. **It makes a sound, on the beat.** A transient appears at every beat
//!    frame, and the frames are COMPUTED from the tempo and PPQ here, not
//!    copied from the implementation.
//! 2. **It never reaches a bounce.** Not "we don't send the command" — the
//!    offline constructor cannot enable it at all.
//! 3. **Off is bit-identical.** A render with the metronome off is byte-for-
//!    byte the offline render, so nothing about the click path perturbs an
//!    existing project.
//! 4. **It is per-FRAME.** Bit-identical at 128 / 417 / 480 / 512, and
//!    allocation-free.

use render::dsp::click::{DEFAULT_LEVEL, PPQ};
use render::engine::EngineConfig;
use render::guard;
use render::offline::{render_offline_with, residual, ManualRenderer, ScheduledCommand};
use render::rt::{CaptureBuf, RenderCommand};

#[global_allocator]
static ALLOC: guard::CountingAlloc = guard::CountingAlloc;

const RATE: u32 = 48_000;

/// Beat frame from the MODEL's arithmetic, recomputed here independently of
/// the render side: `frames = ticks * rate * 60 * den / (PPQ * num)`,
/// round-half-up. If the two ever disagree this test fails, which is the
/// point — hardcoding `24_000` would prove nothing about 92 BPM.
fn beat_frame(beat: u64, bpm_num: u64, bpm_den: u64, anchor_ticks: u64) -> u64 {
    let tick = anchor_ticks + beat * PPQ;
    let n = u128::from(tick) * u128::from(RATE) * 60 * u128::from(bpm_den);
    let d = u128::from(PPQ) * u128::from(bpm_num);
    ((n + d / 2) / d) as u64
}

fn cfg() -> EngineConfig {
    EngineConfig {
        sample_rate: RATE,
        max_tracks: 2,
        ..EngineConfig::default()
    }
}

fn play() -> Vec<ScheduledCommand> {
    vec![ScheduledCommand {
        at_frame: 0,
        command: RenderCommand::Play,
    }]
}

/// Render on a MONITORING core (the live device path) with the metronome set
/// to `bpm` and `enabled`.
fn render_monitor(
    bpm_num: u32,
    bpm_den: u32,
    anchor: u64,
    beats_per_bar: u32,
    enabled: bool,
    total: u64,
    chunk: usize,
) -> Vec<[f32; 2]> {
    let c = cfg();
    let mut r = ManualRenderer::new_monitoring(&c);
    r.params().set_metronome_grid(bpm_num, bpm_den, anchor, beats_per_bar);
    r.params().set_metronome_enabled(enabled);
    r.params().set_metronome_level(DEFAULT_LEVEL);
    render_offline_with(&mut r, play(), total, chunk)
}

/// Peak absolute sample in `[from, to)`.
fn peak_in(audio: &[[f32; 2]], from: usize, to: usize) -> f32 {
    audio[from.min(audio.len())..to.min(audio.len())]
        .iter()
        .map(|f| f[0].abs().max(f[1].abs()))
        .fold(0.0_f32, f32::max)
}

/// THE FRAME-EXACT ONSET ASSERTION.
///
/// Not "there is a transient somewhere near frame f" — a window wide enough to
/// be comfortable is also wide enough to hide a drifting grid, which is
/// exactly how a float phase accumulator survives a sloppy test. This pins the
/// onset to a single frame:
///
///   * frame `f - 1` is bit-exactly 0 (the previous click has fully decayed
///     and this one has not started),
///   * frame `f` is bit-exactly 0 — the click starts at phase 0, where sin is
///     0, which is what makes the onset a transient rather than a step edge,
///   * frame `f + 1` is NONZERO — the click has begun.
///
/// A one-frame drift in either direction fails this.
fn assert_click_onset_exactly_at(audio: &[[f32; 2]], f: usize, what: &str) {
    assert!(f + 2 < audio.len(), "{what}: frame {f} is past the render");
    if f > 0 {
        assert_eq!(
            audio[f - 1][0], 0.0,
            "{what}: signal at frame {} — the click is EARLY", f - 1
        );
    }
    assert_eq!(
        audio[f][0], 0.0,
        "{what}: frame {f} must be the zero-crossing onset"
    );
    assert_ne!(
        audio[f + 1][0], 0.0,
        "{what}: no click at frame {f} — the click is LATE or absent"
    );
}

/// The longest run of bit-exact zeros that can occur INSIDE one click, used to
/// separate one click from the next.
///
/// A click is a decaying sine, so it crosses zero every half period (30 frames
/// at 800 Hz / 48 kHz) — but it crosses, it does not SIT there, and the float
/// samples either side are nonzero. Between clicks the voice is bit-exactly 0.0
/// for the rest of the beat (that is what the `Slew` envelope buys, see
/// `ClickVoice`). 1000 frames is comfortably longer than any within-click zero
/// run and comfortably shorter than the ~22 000-frame gap between clicks at
/// 120 BPM, so it separates clicks without ever splitting one.
const SILENCE_GAP_FRAMES: usize = 1_000;

/// Every click ONSET in `audio`: the first nonzero frame after at least
/// [`SILENCE_GAP_FRAMES`] of bit-exact silence.
///
/// COUNTING is the point. `assert_click_onset_exactly_at` proves a click is at
/// a frame you already computed; it cannot notice that the SECOND one never
/// came, because it is only ever asked about frames the test already believes
/// in. This walks the whole buffer and reports what is actually there — which
/// is the only shape of assertion that can tell "a steady click" apart from
/// "one chirp and then silence", the symptom this file failed to catch.
fn click_onsets(audio: &[[f32; 2]]) -> Vec<usize> {
    let mut onsets = Vec::new();
    // Start "already silent" so a click at frame 0 counts.
    let mut zeros = SILENCE_GAP_FRAMES;
    for (i, f) in audio.iter().enumerate() {
        if f[0] == 0.0 && f[1] == 0.0 {
            zeros += 1;
        } else {
            if zeros >= SILENCE_GAP_FRAMES {
                onsets.push(i);
            }
            zeros = 0;
        }
    }
    onsets
}

// ---------------------------------------------------------------------------
// 1. IT MAKES A SOUND, ON THE BEAT
// ---------------------------------------------------------------------------

/// THE STEADY-BEAT GATE: the right NUMBER of clicks, evenly spaced.
///
/// This is the assertion the rest of section 1 was missing. Everything else
/// here asks "is there a click at frame F?" for frames the test computed in
/// advance, so a metronome that fires ONCE and then goes quiet fails only if
/// the very first frame it is asked about happens to be one of the missing
/// ones — and a "the buffer is not silent" check passes on a single chirp
/// outright. A user does not hear frame-exactness; they hear two clicks a
/// second. So: count every onset in four seconds and assert there are EIGHT,
/// 24 000 frames apart, with the bar accented.
#[test]
fn four_seconds_at_120_bpm_is_eight_evenly_spaced_clicks() {
    let total = 4 * u64::from(RATE); // 4 s
    let audio = render_monitor(120, 1, 0, 4, true, total, 512);

    let onsets = click_onsets(&audio);
    assert_eq!(
        onsets.len(),
        8,
        "120 BPM for 4 s must be EIGHT clicks (two a second); got {} at {onsets:?} \
         — one or two onsets here is the 'I hear at most one click' bug",
        onsets.len()
    );

    // Evenly spaced, at the grid the tempo map defines. The onset is the first
    // NONZERO frame, which is one frame after the beat frame (the click starts
    // at phase 0, where sin is 0 — see `assert_click_onset_exactly_at`), so the
    // spacing is what is pinned here, not the absolute offset.
    for (beat, onset) in onsets.iter().enumerate() {
        let want = beat_frame(beat as u64, 120, 1, 0) as usize + 1;
        assert_eq!(
            *onset, want,
            "click {beat} landed at {onset}, the grid says {want}"
        );
    }
    for pair in onsets.windows(2) {
        assert_eq!(
            pair[1] - pair[0],
            24_000,
            "clicks must be one beat apart; {pair:?} are not"
        );
    }

    // The bar has a shape: beat 1 of each bar is louder than the off-beats.
    // Read each click's peak over its own beat, so this cannot be satisfied by
    // one loud transient bleeding across the measurement window.
    let peak_of = |beat: usize| peak_in(&audio, onsets[beat] - 1, onsets[beat] + 4_000);
    for bar_start in [0_usize, 4] {
        let accent = peak_of(bar_start);
        for off in 1..4 {
            assert!(
                peak_of(bar_start + off) < accent * 0.9,
                "beat {} of the bar starting at click {bar_start} is not below the \
                 downbeat ({} vs {accent})",
                off + 1,
                peak_of(bar_start + off)
            );
        }
    }
}

/// The same steady beat when the click is switched on WHILE THE TRANSPORT IS
/// ALREADY ROLLING — which is what a person actually does.
///
/// Every other test in this file arms the metronome before frame 0 and then
/// starts the transport. The real gesture is the opposite order: play, decide
/// you want the click, reach for the button. That path resyncs a clock which
/// has been ticking (unarmed) for seconds and re-pushes the whole grid
/// mid-flight (`StudioHost::sync_metronome_params` writes grid, enable AND
/// level on every toggle), so it exercises `BeatClock::resync` from an
/// arbitrary position and `Metronome::set_config` from a live one. Neither was
/// covered.
#[test]
fn enabling_the_click_mid_flight_gives_a_steady_beat() {
    let c = cfg();
    let mut r = ManualRenderer::new_monitoring(&c);
    r.params().set_metronome_grid(120, 1, 0, 4);
    r.params().set_metronome_level(DEFAULT_LEVEL);
    r.params().set_metronome_enabled(false);
    r.send(RenderCommand::Play);

    // Roll for a second with the click OFF, in odd blocks so the enable does
    // not land on a beat or a block boundary by luck.
    let mut block = vec![[0.0_f32; 2]; 417];
    let mut audio: Vec<[f32; 2]> = Vec::new();
    while audio.len() < RATE as usize {
        r.render(&mut block);
        audio.extend_from_slice(&block);
    }
    assert!(
        click_onsets(&audio).is_empty(),
        "precondition: nothing clicked while the metronome was off"
    );

    // The toggle, exactly as the host performs it.
    r.params().set_metronome_grid(120, 1, 0, 4);
    r.params().set_metronome_enabled(true);
    r.params().set_metronome_level(DEFAULT_LEVEL);

    let armed_at = audio.len();
    while audio.len() < armed_at + 4 * RATE as usize {
        r.render(&mut block);
        audio.extend_from_slice(&block);
    }

    // Four seconds of armed transport = eight clicks, still on the project's
    // grid (not restarted from wherever the button was pressed).
    let onsets: Vec<usize> = click_onsets(&audio[armed_at..])
        .iter()
        .map(|i| i + armed_at)
        .collect();
    assert_eq!(
        onsets.len(),
        8,
        "arming mid-flight must give a steady beat, got {} at {onsets:?}",
        onsets.len()
    );
    for pair in onsets.windows(2) {
        assert_eq!(
            pair[1] - pair[0],
            24_000,
            "mid-flight clicks are not one beat apart: {pair:?}"
        );
    }
    // Still phase-locked to the PROJECT grid: every onset is a beat frame + 1,
    // which is what stops the click from re-anchoring on the button press.
    for onset in &onsets {
        assert_eq!(
            (onset - 1) % 24_000,
            0,
            "click at {onset} is off the project grid — the toggle re-anchored it"
        );
    }
}

/// The headline evidence: a transient at every beat boundary, at the frame the
/// TEMPO MAP puts it on, and silence in between.
#[test]
fn a_transient_appears_at_every_computed_beat_frame() {
    let total = 96_000; // 2 s at 48 k
    let audio = render_monitor(120, 1, 0, 4, true, total, 128);

    // 120 BPM: beats at 0, 24000, 48000, 72000 — but COMPUTED, not typed.
    for beat in 0..4_u64 {
        let f = beat_frame(beat, 120, 1, 0) as usize;
        assert_eq!(
            f,
            (beat as usize) * 24_000,
            "sanity: the arithmetic agrees with the obvious answer at 120 BPM"
        );
        // FRAME-EXACT: not "near" f, AT f.
        assert_click_onset_exactly_at(&audio, f, &format!("120 BPM beat {beat}"));
    }

    // ...and it is a TRANSIENT, not a drone: the last third of each beat is
    // bit-exactly silent (the envelope is a Slew, so it ARRIVES at zero).
    for beat in 0..3_u64 {
        let f = beat_frame(beat, 120, 1, 0) as usize;
        let quiet_from = f + 16_000;
        let quiet_to = f + 24_000;
        let tail = peak_in(&audio, quiet_from, quiet_to);
        assert_eq!(
            tail, 0.0,
            "beat {beat} must decay to EXACT silence before the next beat, got {tail}"
        );
    }
}

/// The same, at a tempo whose beat is not a whole number of frames. This is
/// the test a float phase accumulator fails.
#[test]
fn beat_frames_are_exact_at_92_bpm_over_a_long_run() {
    // 92 BPM: 31304.347... frames per beat. Run 60 beats (~39 s) so any
    // per-beat rounding error would accumulate into whole frames.
    let beats = 60_u64;
    let total = beat_frame(beats, 92, 1, 0) + 48_000;
    let audio = render_monitor(92, 1, 0, 4, true, total, 512);

    for beat in 0..beats {
        let f = beat_frame(beat, 92, 1, 0) as usize;
        // FRAME-EXACT at every one of 60 beats. An f32 phase accumulator
        // drifts sub-frame per beat and whole frames over this run; a window
        // of even a few frames would let it pass, so there is no window.
        assert_click_onset_exactly_at(&audio, f, &format!("92 BPM beat {beat}"));
    }
}

/// The downbeat is louder than the off-beats, so a bar has a shape.
#[test]
fn the_downbeat_is_accented() {
    let audio = render_monitor(120, 1, 0, 4, true, 240_000, 480);
    let peak_at = |beat: u64| {
        let f = beat_frame(beat, 120, 1, 0) as usize;
        peak_in(&audio, f, f + 2_000)
    };
    let bar1 = peak_at(0);
    let bar2 = peak_at(4);
    for off in [1_u64, 2, 3, 5, 6, 7] {
        assert!(
            peak_at(off) < bar1 * 0.9,
            "beat {off} must be quieter than the downbeat ({} vs {bar1})",
            peak_at(off)
        );
    }
    assert!(bar2 > 0.01, "bar 2's downbeat is also accented ({bar2})");
}

/// `phaseAnchorTicks` moves bar 1 to where the music thinks bar 1 is.
#[test]
fn the_project_phase_anchor_moves_the_click_grid() {
    let anchor = 480; // an eighth note at 960 PPQ
    let audio = render_monitor(120, 1, anchor, 4, true, 96_000, 417);

    // Nothing at frame 0 any more...
    assert_eq!(
        peak_in(&audio, 0, 2_000),
        0.0,
        "with a phase anchor the grid does not start at frame 0"
    );
    // ...and a click at the anchored beats instead.
    for beat in 0..3_u64 {
        let f = beat_frame(beat, 120, 1, anchor) as usize;
        assert_click_onset_exactly_at(&audio, f, &format!("anchored beat {beat}"));
    }
    assert_eq!(
        beat_frame(0, 120, 1, anchor),
        12_000,
        "sanity: an eighth at 120 BPM is 12000 frames"
    );
}

/// Level is controllable, and it is the click that moves.
#[test]
fn the_click_level_is_controllable() {
    let render_at = |level: f32| {
        let c = cfg();
        let mut r = ManualRenderer::new_monitoring(&c);
        r.params().set_metronome_grid(120, 1, 0, 4);
        r.params().set_metronome_enabled(true);
        r.params().set_metronome_level(level);
        let out = render_offline_with(&mut r, play(), 48_000, 512);
        peak_in(&out, 0, 4_000)
    };
    let quiet = render_at(DEFAULT_LEVEL * 0.25);
    let loud = render_at(DEFAULT_LEVEL);
    assert!(loud > quiet * 3.0, "level moved the click: {quiet} -> {loud}");
    assert_eq!(render_at(0.0), 0.0, "level 0 is exact silence");
}

// ---------------------------------------------------------------------------
// 2. IT NEVER REACHES A BOUNCE
// ---------------------------------------------------------------------------

/// THE BOUNCE-EXCLUSION PROOF.
///
/// `ManualRenderer::new` is the constructor behind `render_offline`,
/// `bounce_master`, `bounce_region` and the stem export. This test enables the
/// metronome as hard as the API allows on exactly that constructor and shows
/// the output is digital black — not quiet, ZERO. The exclusion is structural
/// (`CoreConfig::monitor`), so there is no command sequence that could defeat
/// it.
#[test]
fn the_offline_bounce_cannot_produce_a_click_however_hard_you_try() {
    let c = cfg();
    let mut r = ManualRenderer::new(&c); // <- the BOUNCE constructor
    r.params().set_metronome_grid(120, 1, 0, 4);
    r.params().set_metronome_enabled(true);
    r.params().set_metronome_level(2.0); // maximum the clamp allows
    let out = render_offline_with(&mut r, play(), 240_000, 512);

    let peak = peak_in(&out, 0, out.len());
    assert_eq!(
        peak, 0.0,
        "an offline bounce produced a metronome click (peak {peak}) — the export firewall is broken"
    );
}

/// The same claim stated as bit-identity: a bounce with the metronome on is
/// byte-for-byte a bounce with it off. This is the assertion that would catch
/// a click summed at the wrong point in the chain (e.g. into the master
/// accumulator) even if it happened to be inaudible in the test above.
#[test]
fn a_bounce_is_bit_identical_with_the_metronome_on_and_off() {
    let bounce = |enabled: bool| {
        let c = cfg();
        let mut r = ManualRenderer::new(&c);
        r.params().set_metronome_grid(120, 1, 0, 4);
        r.params().set_metronome_enabled(enabled);
        r.params().set_metronome_level(DEFAULT_LEVEL);
        render_offline_with(&mut r, play(), 240_000, 512)
    };
    let on = bounce(true);
    let off = bounce(false);
    assert!(
        residual(&on, &off).bit_identical,
        "the metronome flag changed an offline bounce"
    );
}

/// A TAKE recorded while playing to the click has no click in it.
///
/// The capture tap reads the master frame BEFORE the monitor sum, so this is
/// structural too — but a future edit could move the sum above the tap, and
/// that edit would be inaudible in a bounce test while quietly printing the
/// metronome onto every recording. This is the test that catches it.
#[test]
fn a_recorded_take_contains_no_click() {
    let c = cfg();
    let mut r = ManualRenderer::new_monitoring(&c);
    r.params().set_metronome_grid(120, 1, 0, 4);
    r.params().set_metronome_enabled(true);
    r.params().set_metronome_level(DEFAULT_LEVEL);

    let frames = 96_000_usize;
    let out = render_offline_with(
        &mut r,
        vec![ScheduledCommand {
            at_frame: 0,
            command: RenderCommand::CaptureStart {
                capture: CaptureBuf::new(frames),
                start_transport: true,
            },
        }],
        frames as u64,
        512,
    );

    // The monitored OUTPUT has the click...
    assert!(
        peak_in(&out, 0, 2_000) > 0.01,
        "precondition: the monitor path is clicking"
    );
    // ...and the captured TAKE is silent.
    let capture = r
        .wait_capture(std::time::Duration::from_secs(5))
        .expect("capture completed");
    let peak = capture
        .data
        .iter()
        .map(|f| f[0].abs().max(f[1].abs()))
        .fold(0.0_f32, f32::max);
    assert_eq!(
        peak, 0.0,
        "the metronome bled into a recorded take (peak {peak})"
    );
}

// ---------------------------------------------------------------------------
// 3. OFF IS BIT-IDENTICAL
// ---------------------------------------------------------------------------

/// With the metronome OFF, the monitoring path and the offline path produce
/// the SAME BYTES. Nothing about adding a click generator perturbs an existing
/// project by so much as a low bit.
#[test]
fn metronome_off_is_bit_identical_to_the_offline_render() {
    let monitored = render_monitor(120, 1, 0, 4, false, 240_000, 512);

    let c = cfg();
    let mut r = ManualRenderer::new(&c);
    r.params().set_metronome_grid(120, 1, 0, 4);
    r.params().set_metronome_enabled(false);
    let offline = render_offline_with(&mut r, play(), 240_000, 512);

    assert!(
        residual(&monitored, &offline).bit_identical,
        "metronome OFF must render bit-identically on both paths"
    );
}

// ---------------------------------------------------------------------------
// 4. IT IS PER-FRAME
// ---------------------------------------------------------------------------

/// THE PARITY GATE, for the click itself.
///
/// A per-block shortcut — deciding once per buffer whether a beat fell in it,
/// or holding the envelope's value for the block — passes every test above and
/// fails this one. The click must be a pure function of the absolute frame
/// position, which is what makes the live callback (128) and a bounce (512)
/// produce identical bytes.
#[test]
fn the_click_is_bit_identical_at_128_417_480_512() {
    let total = 240_000;
    let reference = render_monitor(92, 1, 240, 4, true, total, 128);
    assert!(
        peak_in(&reference, 0, reference.len()) > 0.01,
        "guard: the reference actually contains clicks, so this is not a null-vs-null pass"
    );
    for chunk in [417_usize, 480, 512] {
        let got = render_monitor(92, 1, 240, 4, true, total, chunk);
        assert!(
            residual(&reference, &got).bit_identical,
            "click is not block-size independent at chunk {chunk}"
        );
    }
}

/// A fractional-BPM grid at odd block sizes: the rational tempo path, under
/// the parity gate.
#[test]
fn a_fractional_bpm_click_is_also_block_size_independent() {
    // 185/2 = 92.5 BPM.
    let total = 192_000;
    let reference = render_monitor(185, 2, 0, 3, true, total, 128);
    assert!(peak_in(&reference, 0, reference.len()) > 0.01, "guard: has signal");
    for chunk in [417_usize, 480, 512] {
        let got = render_monitor(185, 2, 0, 3, true, total, chunk);
        assert!(
            residual(&reference, &got).bit_identical,
            "92.5 BPM click not block-size independent at {chunk}"
        );
    }
}

/// The click follows a LOOP FOLD instead of running off the end of it. This is
/// the "play along to a looping section" path.
#[test]
fn the_click_follows_a_loop_fold() {
    let c = cfg();
    let mut r = ManualRenderer::new_monitoring(&c);
    r.params().set_metronome_grid(120, 1, 0, 4);
    r.params().set_metronome_enabled(true);
    r.params().set_metronome_level(DEFAULT_LEVEL);

    // Loop one bar: frames 0..96000 at 120 BPM 4/4.
    let out = render_offline_with(
        &mut r,
        vec![
            ScheduledCommand {
                at_frame: 0,
                command: RenderCommand::LoopSet {
                    start_frame: 0,
                    end_frame: 96_000,
                },
            },
            ScheduledCommand {
                at_frame: 0,
                command: RenderCommand::Play,
            },
        ],
        // Three passes of the bar.
        288_000,
        512,
    );

    // Every beat of every pass must click: positions fold, so the click must
    // fold with them.
    for pass in 0..3_usize {
        for beat in 0..4_usize {
            let f = pass * 96_000 + beat * 24_000;
            assert_click_onset_exactly_at(
                &out,
                f,
                &format!("loop pass {pass} beat {beat}"),
            );
        }
    }
    // And the loop is genuinely folding — the three passes are identical.
    assert!(
        residual(&out[0..96_000], &out[96_000..192_000]).bit_identical,
        "loop passes must render identically"
    );
}

/// A count-in sounds BEFORE the transport rolls, accented on "1".
#[test]
fn the_count_in_is_audible_with_the_transport_stopped() {
    let c = cfg();
    let mut r = ManualRenderer::new_monitoring(&c);
    r.params().set_metronome_grid(120, 1, 0, 4);
    // Deliberately DISABLED: a count-in is not the running metronome, and it
    // must sound even when the click is off.
    r.params().set_metronome_enabled(false);
    r.params().set_metronome_level(DEFAULT_LEVEL);

    let period = 24_000_u64; // one beat at 120 BPM
    let out = render_offline_with(
        &mut r,
        vec![ScheduledCommand {
            at_frame: 0,
            command: RenderCommand::CountIn {
                beats: 4,
                period_frames: period,
            },
        }],
        // NOTE: no Play. The transport never rolls.
        144_000,
        512,
    );

    for beat in 0..4_usize {
        let f = beat * period as usize;
        assert_click_onset_exactly_at(
            &out,
            f,
            &format!("count-in beat {} (silent count-in is THE bug)", beat + 1),
        );
    }
    // "1" is accented so you know which beat you are on.
    let one = peak_in(&out, 0, 2_000);
    let two = peak_in(&out, period as usize, period as usize + 2_000);
    assert!(one > two * 1.2, "count-in beat 1 is accented ({one} vs {two})");
    // And it STOPS after four, rather than becoming a free-running click.
    let after = peak_in(&out, 4 * period as usize + 4_000, 144_000);
    assert_eq!(after, 0.0, "the count-in did not stop (peak {after})");
}

/// ALLOCATION-FREE, with the click running and toggling.
#[test]
fn clicking_does_not_allocate_on_the_render_path() {
    // Positive control FIRST: without it a zero below could mean "the counting
    // allocator is not installed" rather than "clean".
    let control_before = guard::violations();
    guard::enter_render_scope();
    let v: Vec<u8> = Vec::with_capacity(64);
    drop(v);
    guard::leave_render_scope();
    assert!(
        guard::violations() > control_before,
        "the counting allocator is not installed; this test would be vacuous"
    );

    let c = cfg();
    let mut r = ManualRenderer::new_monitoring(&c);
    r.params().set_metronome_grid(120, 1, 0, 4);
    r.params().set_metronome_level(DEFAULT_LEVEL);
    r.send(RenderCommand::Play);
    let mut out = vec![[0.0_f32; 2]; 512];

    let before = guard::violations();
    for block in 0..600 {
        // Hammer every control the metronome has, between blocks: the enable
        // flag, the level, and the whole grid (which forces a resync).
        r.params().set_metronome_enabled(block % 3 != 0);
        r.params().set_metronome_level(DEFAULT_LEVEL * (0.5 + (block % 4) as f32 * 0.25));
        r.params()
            .set_metronome_grid(90 + (block % 60) as u32, 1, (block % 480) as u64, 4);
        if block % 97 == 0 {
            r.send(RenderCommand::CountIn {
                beats: 4,
                period_frames: 24_000,
            });
        }
        r.render(&mut out);
    }
    assert_eq!(
        guard::violations() - before,
        0,
        "the metronome allocated on the audio thread"
    );
}

// ---------------------------------------------------------------------------
// 5. THE PLAY-ALONG WORKFLOW
//
// "Maybe we'll be able to have a metronome and or I can put on a beat in the
// background." Those are the two standard ways to play in time, and the second
// one is: loop a section, and play over it. The loop half is proved here at the
// render layer; the missing GUI to SET a loop is reported, not built.
// ---------------------------------------------------------------------------

/// You can play over a looping section, with the click running, and hear all
/// three at once.
///
/// This is the combination, not three separate facts: a preview note (the
/// on-screen keyboard and a hardware MIDI key take the identical path) sounding
/// while the transport loops and the metronome clicks.
#[test]
fn you_can_play_over_a_looping_section_with_the_click_running() {
    use render::automation::AutomationStore;
    use render::compile::{compile_session_full, DeclickPolicy};
    use render::media::AudioBuf;
    use render::rt::PREVIEW_HINT_BASE;
    use render::warp::WarpOverlay;
    use std::collections::HashMap;
    use timeline_core::cmd::Cmd;
    use timeline_core::model::DeviceKind;
    use timeline_core::tempo::PPQ as MODEL_PPQ;
    use timeline_core::{Bpm, Project, TempoMap, Track};

    let mut p = Project::new(RATE, TempoMap::single(Bpm::from_int(120).unwrap()));
    p.tracks.push(Track::new("t1", "Keys"));
    p.apply_cmd(&Cmd::DeviceAdd {
        track_id: "t1".into(),
        device_id: "inst1".into(),
        kind: DeviceKind::Synth,
    })
    .expect("device.add");
    p.apply_cmd(&Cmd::ClipPlaceMidi {
        clip_id: "cm1".into(),
        track_id: "t1".into(),
        start_ticks: 0,
        length_ticks: MODEL_PPQ * 8,
    })
    .expect("clip.placeMidi");

    let sources: HashMap<String, std::sync::Arc<AudioBuf>> = HashMap::new();
    let session = compile_session_full(
        &p,
        &sources,
        &WarpOverlay::new(),
        &AutomationStore::new(),
        cfg().max_tracks,
        DeclickPolicy::None,
    )
    .expect("compile");

    // Render the SAME session twice, click on and click off. Subtracting the
    // two isolates the click exactly, which is what lets the frame-exact onset
    // assertion still apply while an instrument is sounding over the top — and
    // it simultaneously proves the click perturbs nothing else.
    let run = |enabled: bool| {
        let sources: HashMap<String, std::sync::Arc<AudioBuf>> = HashMap::new();
        let session = compile_session_full(
            &p,
            &sources,
            &WarpOverlay::new(),
            &AutomationStore::new(),
            cfg().max_tracks,
            DeclickPolicy::None,
        )
        .expect("compile");
        let c = cfg();
        let mut r = ManualRenderer::new_monitoring(&c);
        r.params().set_metronome_grid(120, 1, 0, 4);
        r.params().set_metronome_enabled(enabled);
        r.params().set_metronome_level(DEFAULT_LEVEL);
        render_offline_with(
        &mut r,
        vec![
            ScheduledCommand {
                at_frame: 0,
                command: RenderCommand::SetSession(session),
            },
            ScheduledCommand {
                at_frame: 0,
                command: RenderCommand::LoopSet {
                    start_frame: 0,
                    end_frame: 96_000, // one bar at 120 BPM
                },
            },
            ScheduledCommand {
                at_frame: 0,
                command: RenderCommand::Play,
            },
            // Hold a key down ACROSS the loop fold — the thing a person does
            // when they are playing along to a looping section.
            ScheduledCommand {
                at_frame: 90_000,
                command: RenderCommand::PreviewNoteOn {
                    track: 0,
                    pitch: 60,
                    velocity: 100.0 / 127.0,
                    hint: PREVIEW_HINT_BASE + 60,
                    hold_frames: 24_000,
                },
            },
        ],
        192_000,
        128,
        )
    };

    let with_click = run(true);
    let without_click = run(false);
    let click_only: Vec<[f32; 2]> = with_click
        .iter()
        .zip(without_click.iter())
        .map(|(a, b)| [a[0] - b[0], a[1] - b[1]])
        .collect();

    // The click is running on the grid, frame-exactly, even with an instrument
    // playing over it and a loop folding underneath it.
    assert_click_onset_exactly_at(&click_only, 0, "play-along downbeat");
    assert_click_onset_exactly_at(&click_only, 48_000, "play-along beat 3");
    assert_click_onset_exactly_at(&click_only, 96_000, "play-along loop pass 2 downbeat");

    // The note the person played is sounding ACROSS the fold. Read it off the
    // click-free render so this cannot be the click in disguise.
    let before_fold = peak_in(&without_click, 92_000, 95_000);
    assert!(
        before_fold > 0.001,
        "the key played over the loop was inaudible (peak {before_fold})"
    );
    let after_fold = peak_in(&without_click, 98_000, 100_000);
    assert!(
        after_fold > 0.001,
        "the held key went silent across the loop fold (peak {after_fold})"
    );

    // And the click did not disturb what was being played: outside the click's
    // own envelope the two renders are bit-identical.
    for i in 20_000..23_000 {
        assert_eq!(
            with_click[i], without_click[i],
            "the click perturbed the instrument at frame {i}"
        );
    }
}

// ---------------------------------------------------------------------------
// 6. THE CLICK IS OBSERVABLE
//
// Everything above measures rendered samples, which is the right standard for
// a test and useless to the person in the room. The click is deliberately
// excluded from `master`, the meters, the true-peak detector and the capture
// tap, so in the RUNNING app there was no signal for it at all: the only
// oracle was a human ear, and "one chirp and then silence" could not be told
// apart from "the enable never arrived". `EngineStats::metronome_clicks` is
// that missing signal. This section proves it says what it claims — that it
// counts CLICKS YOU CAN HEAR, one for one, and that it is as inert on a bounce
// as the click itself.
// ---------------------------------------------------------------------------

/// The counter equals the clicks in the buffer. Not "greater than zero": the
/// same number, from the same render, compared against onsets measured off the
/// samples. A counter that over-counts (incremented on every beat frame rather
/// than every fired voice) or under-counts (incremented once per block) would
/// be worse than no counter at all — it would send the next person hunting in
/// the wrong half.
#[test]
fn the_click_counter_counts_the_clicks_you_can_hear() {
    use std::sync::atomic::Ordering;

    let c = cfg();
    let mut r = ManualRenderer::new_monitoring(&c);
    r.params().set_metronome_grid(120, 1, 0, 4);
    r.params().set_metronome_enabled(true);
    r.params().set_metronome_level(DEFAULT_LEVEL);
    assert_eq!(
        r.stats().metronome_clicks.load(Ordering::Relaxed),
        0,
        "a fresh core has clicked zero times"
    );

    let audio = render_offline_with(&mut r, play(), 4 * u64::from(RATE), 512);
    let onsets = click_onsets(&audio);
    let counted = r.stats().metronome_clicks.load(Ordering::Relaxed);

    assert_eq!(onsets.len(), 8, "precondition: four seconds is eight clicks");
    assert_eq!(
        counted,
        onsets.len() as u64,
        "the counter says {counted} clicks, the buffer contains {} — a counter that \
         disagrees with the audio is a worse instrument than none",
        onsets.len()
    );
}

/// Disabled means zero. The counter tracks the SOUND, not the transport: a
/// rolling transport with the click off ticks the beat clock every beat and
/// must still count nothing, or "the number is climbing" would stop meaning
/// "clicks are being made".
#[test]
fn a_disabled_metronome_counts_nothing_while_the_transport_rolls() {
    use std::sync::atomic::Ordering;

    let c = cfg();
    let mut r = ManualRenderer::new_monitoring(&c);
    r.params().set_metronome_grid(120, 1, 0, 4);
    r.params().set_metronome_enabled(false);
    r.params().set_metronome_level(DEFAULT_LEVEL);

    let audio = render_offline_with(&mut r, play(), 4 * u64::from(RATE), 512);
    assert!(
        click_onsets(&audio).is_empty(),
        "precondition: a disabled metronome is silent"
    );
    assert_eq!(
        r.stats().metronome_clicks.load(Ordering::Relaxed),
        0,
        "the counter moved with the metronome switched off — it is counting beats, \
         not clicks"
    );
}

/// Enabling mid-flight moves the counter from a standing start, which is the
/// exact reading the owner takes: press the button, watch the number.
#[test]
fn arming_the_click_mid_flight_starts_the_counter() {
    use std::sync::atomic::Ordering;

    let c = cfg();
    let mut r = ManualRenderer::new_monitoring(&c);
    r.params().set_metronome_grid(120, 1, 0, 4);
    r.params().set_metronome_level(DEFAULT_LEVEL);
    r.params().set_metronome_enabled(false);
    r.send(RenderCommand::Play);

    let mut block = vec![[0.0_f32; 2]; 417];
    let mut rendered = 0_usize;
    while rendered < RATE as usize {
        r.render(&mut block);
        rendered += block.len();
    }
    assert_eq!(
        r.stats().metronome_clicks.load(Ordering::Relaxed),
        0,
        "a second of unarmed transport counted clicks"
    );

    // The toggle, exactly as the host performs it.
    r.params().set_metronome_grid(120, 1, 0, 4);
    r.params().set_metronome_enabled(true);
    r.params().set_metronome_level(DEFAULT_LEVEL);

    let armed_at = rendered;
    while rendered < armed_at + 4 * RATE as usize {
        r.render(&mut block);
        rendered += block.len();
    }
    assert_eq!(
        r.stats().metronome_clicks.load(Ordering::Relaxed),
        8,
        "four seconds of armed transport is eight counted clicks"
    );
}

/// A count-in counts too. It is a click the user is meant to hear, it fires
/// with the transport STOPPED and with the metronome disabled, and it goes
/// through the second trigger site in the render core — so a counter wired
/// only to the grid would read zero through an audible count-in.
#[test]
fn the_count_in_moves_the_click_counter() {
    use std::sync::atomic::Ordering;

    let c = cfg();
    let mut r = ManualRenderer::new_monitoring(&c);
    r.params().set_metronome_grid(120, 1, 0, 4);
    r.params().set_metronome_enabled(false);
    r.params().set_metronome_level(DEFAULT_LEVEL);

    let out = render_offline_with(
        &mut r,
        vec![ScheduledCommand {
            at_frame: 0,
            command: RenderCommand::CountIn {
                beats: 4,
                period_frames: 24_000,
            },
        }],
        // No Play: the transport never rolls, so every counted click here came
        // from the count-in path.
        144_000,
        512,
    );

    assert_eq!(
        click_onsets(&out).len(),
        4,
        "precondition: a four-beat count-in is four clicks"
    );
    assert_eq!(
        r.stats().metronome_clicks.load(Ordering::Relaxed),
        4,
        "the count-in sounded but the counter did not move"
    );
}

/// THE FIREWALL, RESTATED FOR THE COUNTER.
///
/// The click cannot reach a bounce because `CoreConfig::monitor` is false on
/// every offline path, and the counter lives INSIDE that gate — so a bounce
/// that ticks it would mean the increment had been placed somewhere that runs
/// offline, which is the same mistake as summing the click into the export.
/// The counter is a second, cheaper detector for exactly that error: a
/// nonzero here fails long before anyone has to listen to an exported file.
///
/// `device_frames_audible` is asserted zero for the matching reason: it counts
/// what an OUTPUT DEVICE CALLBACK copied, and an offline render never has one.
#[test]
fn an_offline_bounce_leaves_the_click_counter_at_zero() {
    use std::sync::atomic::Ordering;

    let c = cfg();
    let mut r = ManualRenderer::new(&c); // <- the BOUNCE constructor
    r.params().set_metronome_grid(120, 1, 0, 4);
    r.params().set_metronome_enabled(true);
    r.params().set_metronome_level(2.0); // maximum the clamp allows
    let out = render_offline_with(&mut r, play(), 240_000, 512);

    assert_eq!(
        peak_in(&out, 0, out.len()),
        0.0,
        "precondition: the bounce is digital black"
    );
    assert_eq!(
        r.stats().metronome_clicks.load(Ordering::Relaxed),
        0,
        "an offline bounce moved the click counter — the increment is outside \
         `if self.cfg.monitor`, which is the same defect as a click in an export"
    );
    assert_eq!(
        r.stats().device_frames_audible.load(Ordering::Relaxed),
        0,
        "an offline render has no device callback, so no frame can have reached one"
    );
}

/// A count-in ARMED ON A BOUNCE CORE is silent and uncounted. The other half
/// of the firewall: the count-in is the one click path a command can fire
/// directly, so it is the one an over-eager counter would leak through.
#[test]
fn a_count_in_on_a_bounce_core_is_silent_and_uncounted() {
    use std::sync::atomic::Ordering;

    let c = cfg();
    let mut r = ManualRenderer::new(&c); // <- the BOUNCE constructor
    r.params().set_metronome_grid(120, 1, 0, 4);
    r.params().set_metronome_level(2.0);
    let out = render_offline_with(
        &mut r,
        vec![ScheduledCommand {
            at_frame: 0,
            command: RenderCommand::CountIn {
                beats: 4,
                period_frames: 24_000,
            },
        }],
        144_000,
        512,
    );

    assert_eq!(
        peak_in(&out, 0, out.len()),
        0.0,
        "a count-in reached an offline render"
    );
    assert_eq!(
        r.stats().metronome_clicks.load(Ordering::Relaxed),
        0,
        "a count-in on a bounce core moved the click counter"
    );
}

/// The counter changes no sample, and reports the same number twice.
///
/// A diagnostic that perturbs what it measures is worse than none, and an
/// atomic on the hot path is the classic way to do it. Two identical renders
/// must be bit-identical AND agree on the count.
///
/// ALLOCATION-FREEDOM IS NOT ASSERTED HERE ON PURPOSE. The increments sit on
/// the metronome path that `clicking_does_not_allocate_on_the_render_path`
/// already hammers (600 blocks, the enable toggling, the grid resyncing and a
/// count-in firing), so that test measures them. Re-measuring here would mean
/// a second `guard::enter_render_scope` window open in parallel with that
/// one — and `guard::violations()` is a PROCESS-WIDE counter, so the two
/// windows see each other's deliberate positive-control allocations and one of
/// them fails at random. That was observed, not theorised.
#[test]
fn counting_the_clicks_changes_no_sample() {
    use std::sync::atomic::Ordering;

    let render_one = || {
        let c = cfg();
        let mut r = ManualRenderer::new_monitoring(&c);
        r.params().set_metronome_grid(120, 1, 0, 4);
        r.params().set_metronome_enabled(true);
        r.params().set_metronome_level(DEFAULT_LEVEL);
        let audio = render_offline_with(&mut r, play(), 4 * u64::from(RATE), 512);
        let counted = r.stats().metronome_clicks.load(Ordering::Relaxed);
        (audio, counted)
    };

    let (a, counted_a) = render_one();
    let (b, counted_b) = render_one();
    assert_eq!(counted_a, 8, "precondition: four seconds is eight clicks");
    assert_eq!(counted_a, counted_b, "the count is not reproducible");
    assert!(
        residual(&a, &b).bit_identical,
        "two identical renders differ — the counter is in the signal path"
    );
}
