//! MIDI INPUT LATENCY: the hop from a device callback to the host, measured.
//!
//! NO hardware, NO CoreMIDI connections, NO audio. `MAJIKS_MIDI_PORT_FILTER` is
//! set to a sentinel no port name can contain, so the pump's scan enumerates and
//! connects NOTHING; every event under test is injected at exactly the point a
//! device callback would hand one over (`midi::pump::inject`).
//!
//! Why this file exists at all: the pre-existing seam (`midi::feed_event`) calls
//! `dispatch_event` directly on the CALLER's thread. It goes AROUND the pump, so
//! it could not see the pump's wake path — where all of the input latency lived.
//! A note-on waited 0..15 ms to be noticed and the whole suite was green.
//!
//! ONE `#[test]` on purpose. Two would race on `set_var` and, worse, would time
//! each other's thread load: a latency gate that is only honest when it happens
//! to run alone is not a gate.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use agent_surface::midi::event::MidiEvent;
use agent_surface::midi::{pump, start_pump};
use agent_surface::StudioHost;

/// A name no real MIDI port contains, so `scan` connects zero devices.
const NO_HARDWARE: &str = "__majiks_no_such_midi_port__";
/// The port we inject on. Unmapped, default role `instrument`, so dispatch runs
/// the same instrument branch a keyboard's keys take.
const PORT: &str = "latency-probe";
const SAMPLES: u32 = 240;

/// Injection phase must be spread across the WHOLE of any plausible poll period,
/// or the measurement samples one corner of the distribution and lies about the
/// mean. This walks phase over a ~20 ms span with a step coprime to it, so
/// samples land all over a 15 ms tick instead of clustering just after one.
fn phase_delay(i: u32) -> Duration {
    Duration::from_micros(300 + ((i as u64 * 7_919) % 20_000))
}

fn probe_host() -> Arc<Mutex<StudioHost>> {
    std::env::set_var("MAJIKS_MIDI_PORT_FILTER", NO_HARDWARE);
    let host = Arc::new(Mutex::new(StudioHost::in_memory()));
    start_pump(&host).expect("start pump");
    // Let the pump reach its steady-state loop (first scan done).
    std::thread::sleep(Duration::from_millis(150));
    host
}

/// Inject one note-on and return how long the PUMP took to complete dispatch.
fn one_hop(host: &Arc<Mutex<StudioHost>>, note: u8) -> Duration {
    let shared = host.lock().unwrap().midi_shared();
    let before = shared.dispatched_seq.load(Ordering::Relaxed);
    let t0 = Instant::now();
    assert!(
        pump::inject(&shared, PORT, MidiEvent::NoteOn { note, velocity: 100, channel: 0 }),
        "the pump inlet refused the event; no pump is running"
    );
    // ⚠️ THIS DEADLINE IS A HANG GUARD, NOT THE MEASUREMENT.
    //
    // What this test asserts about latency is `s.p50 < 1.0` — a MEDIAN over
    // many samples, which is the right shape precisely because it survives a
    // busy machine: one descheduled sample cannot move it.
    //
    // This bound only exists so a genuinely dead pump fails instead of hanging
    // the suite forever. It was 500 ms, which is well inside the range a thread
    // can simply not be scheduled for on a saturated box — four independent
    // lanes hit it red at load 29–42 while the pump was perfectly healthy, and
    // each one had to work out from scratch that the machine, not the code, was
    // the variable. A hang guard that fires on load is a false alarm that costs
    // more than the hang it prevents.
    //
    // Ten seconds still catches "no pump is running" in a suite that takes
    // minutes, and cannot plausibly fire on a live pump. The latency claim is
    // unchanged and unweakened: it is still sub-millisecond at the median.
    let deadline = t0 + Duration::from_secs(10);
    loop {
        if shared.dispatched_seq.load(Ordering::Relaxed) != before {
            return t0.elapsed();
        }
        assert!(
            Instant::now() < deadline,
            "note never dispatched within 10 s — the pump is not running at all \
             (this is a liveness guard; the latency assertion is the p50 below)"
        );
        std::hint::spin_loop();
    }
}

struct Stats {
    p50: f64,
    mean: f64,
    p95: f64,
    p99: f64,
    max: f64,
}

impl Stats {
    fn line(&self) -> String {
        format!(
            "p50 {:.3} ms  mean {:.3} ms  p95 {:.3} ms  p99 {:.3} ms  max {:.3} ms",
            self.p50, self.mean, self.p95, self.p99, self.max
        )
    }
}

fn stats(mut samples: Vec<Duration>) -> Stats {
    samples.sort();
    let n = samples.len();
    let ms = |d: Duration| d.as_secs_f64() * 1000.0;
    Stats {
        p50: ms(samples[n / 2]),
        mean: samples.iter().map(|d| ms(*d)).sum::<f64>() / n as f64,
        p95: ms(samples[n * 95 / 100]),
        p99: ms(samples[n * 99 / 100]),
        max: ms(samples[n - 1]),
    }
}

/// What this gate does and does NOT assert on, deliberately.
///
/// GATED: the MEDIAN, and nothing else. This is a deliberate choice, made after
/// watching mean- and p95-based gates flake.
///
/// The failure being guarded against shifts the WHOLE distribution: coupling the
/// wake to a 15 ms tick makes every sample wait a uniform 0..15 ms, so the median
/// moves from ~0.03 ms to ~10 ms — a factor of ~300. Nothing else in this system
/// can move the median like that.
///
/// The competing signal is OS scheduler noise. This suite runs on a shared build
/// box; while developing this gate the load average hit 46 with another lane
/// burning 392% CPU, and healthy runs then showed mean up to 1.2 ms, p95 up to
/// 5.7 ms and max up to 17.7 ms — indistinguishable, at the tail, from the very
/// regression we are hunting. Mean and p95 therefore cannot separate "our code
/// regressed" from "the box is busy", and a gate that cannot separate those is a
/// coin flip that will be deleted the first time it goes red for no reason.
///
/// The median is immune to that: a handful of stalled samples cannot move it, so
/// it stays ~0.03 ms under any load while still reading ~10 ms the instant the
/// poll comes back. Gate at 1.0 ms — 30x above healthy, 10x below the
/// regression, with no overlap in either direction.
///
/// mean/p95/p99/max are PRINTED, never asserted. They are what a human should
/// read to judge tail behaviour and machine health; they are not evidence of a
/// code regression on their own.
fn assert_is_a_thread_wake(label: &str, s: &Stats) {
    assert!(
        s.p50 < 1.0,
        "{label}: MEDIAN hop {:.3} ms — a note-on is waiting on a tick again, not a thread wake. \
         A healthy median is ~0.03 ms; a 15 ms poll-gated wake reads ~10 ms. \
         (full distribution: {})",
        s.p50,
        s.line()
    );
}

fn sweep(host: &Arc<Mutex<StudioHost>>) -> Stats {
    let mut samples = Vec::with_capacity(SAMPLES as usize);
    for i in 0..SAMPLES {
        std::thread::sleep(phase_delay(i));
        samples.push(one_hop(host, 60 + (i % 12) as u8));
    }
    stats(samples)
}

/// THE REGRESSION GATE. A note-on must reach the host in about the time it takes
/// to wake a thread — NOT in a poll interval.
///
/// The number this replaced: the pump slept on `recv_timeout(15ms)` against its
/// CONTROL channel and only then drained the event channel, so an event's
/// arrival did not wake anything. Measured over 240 phase-spread injections:
///
///   before   mean 10.043 ms   p95 17.366 ms   max 18.530 ms
///   after    mean  0.034 ms   p95  0.059 ms   max  0.322 ms
///
/// — on top of everything downstream, none of which was at fault (the device
/// buffer is 128 frames and the render thread idles at 0.1 ms p95).
///
/// KNOWN BLIND SPOT, stated so the next person does not trust this further than
/// it goes: the 1.5 s hotplug `scan()` still runs BEFORE the drain, so a note
/// arriving just as a device enumeration starts waits it out. This probe CANNOT
/// see that — `MAJIKS_MIDI_PORT_FILTER` leaves zero ports present and `scan`
/// early-returns on an unchanged connected set, so enumeration is free here.
/// Reordering it was tried, measured, and reverted: it changed nothing on this
/// probe, and gating hotplug on "no events this iteration" would starve device
/// detection during sustained playing. Quantifying it needs real hardware.
#[test]
fn a_note_on_reaches_the_host_on_a_thread_wake_not_a_poll_tick() {
    let host = probe_host();

    let idle = sweep(&host);
    println!("PUMP HOP inject->dispatched (idle):  {}", idle.line());

    // The same hop while both 30 Hz Swift pollers hammer the host lock.
    // `snapshot` takes the SAME `Arc<Mutex<StudioHost>>` the pump must take in
    // order to dispatch, so this is where contention could put the delay back.
    // StudioViewModel.startPolling and StudioPianoRollController.startPolling
    // both run at 33 ms in the shipping app; two pollers is the real load.
    let stop = Arc::new(AtomicBool::new(false));
    let pollers: Vec<_> = (0..2)
        .map(|_| {
            let host = Arc::clone(&host);
            let stop = Arc::clone(&stop);
            std::thread::spawn(move || {
                let mut n = 0u64;
                while !stop.load(Ordering::Relaxed) {
                    {
                        let h = host.lock().unwrap();
                        let _ = h.snapshot(None);
                        n += 1;
                    }
                    std::thread::sleep(Duration::from_millis(33));
                }
                n
            })
        })
        .collect();

    let loaded = sweep(&host);
    stop.store(true, Ordering::Relaxed);
    let polls: u64 = pollers.into_iter().map(|j| j.join().unwrap()).sum();
    println!(
        "PUMP HOP inject->dispatched (30Hz x2 snapshot load, {polls} snapshots): {}",
        loaded.line()
    );

    assert!(polls > 0, "the pollers never ran; the loaded sweep measured nothing");
    assert_is_a_thread_wake("idle", &idle);
    // Under the real UI load the host lock is the only thing left that could
    // delay dispatch. Measured cost of that contention: none — the loaded and
    // idle distributions are the same. If someone starts doing real work under
    // the host lock, this is where it shows up.
    assert_is_a_thread_wake("under 30Hz x2 snapshot load", &loaded);
}
