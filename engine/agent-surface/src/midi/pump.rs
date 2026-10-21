//! The MIDI pump thread. It OWNS the midir input connections for their whole
//! life (one thread ever touches them, so no Send/Sync juggling of connections),
//! turns live events into bus commands, and hot-plugs devices.
//!
//! MIDI INPUT ONLY: this module imports `midir::MidiInput` and never
//! `midir::MidiOutput`. The realtime callback stays alloc/lock-light (parse +
//! try_send); ALL host locking happens here on the pump thread.
use std::{collections::HashMap, sync::{mpsc, Arc, Mutex, Weak}, thread::{self, JoinHandle}, time::{Duration, Instant}};
use midir::{Ignore, MidiInput, MidiInputConnection};
use super::{event::MidiEvent, resolve, MidiShared, PortState};
use crate::host::StudioHost;

/// Continuous controls coalesce to their latest value within this window; the
/// drain also settles on the next tick after events stop (spec 2.4).
const COALESCE_MS: u64 = 33;
/// The hotplug enumeration cadence (spec 2.3).
const HOTPLUG_MS: u64 = 1500;
/// The pump's IDLE heartbeat: how long it waits for an event before waking to
/// run housekeeping (hotplug rescan, coalesce flush). This is NOT an input-
/// latency term — an arriving event wakes the thread immediately (see `run`).
/// Raising it delays device hotplug, never a note.
const IDLE_TICK_MS: u64 = 15;

enum PumpMsg { Stop, Rescan }
pub struct MidiPump { tx: mpsc::Sender<PumpMsg>, join: Option<JoinHandle<()>> }
impl MidiPump { pub fn rescan(&self) { let _ = self.tx.send(PumpMsg::Rescan); } }

/// The running pump's event inlet, published into `MidiShared` so a caller can
/// hand the pump an event at EXACTLY the point a device callback does.
///
/// This exists because `feed_event` — the old no-hardware seam — calls
/// `dispatch_event` directly on the caller's thread and so cannot observe the
/// pump at all. Every millisecond between the cable and the instrument lives in
/// the pump's wake path, which means the one seam we had was structurally blind
/// to input latency. A note-on took 0..15 ms to be noticed and no test could
/// have caught it. `inject` closes that hole.
#[derive(Default)]
pub struct PumpInlet(Mutex<Option<mpsc::SyncSender<(String, MidiEvent)>>>);

impl std::fmt::Debug for PumpInlet {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let live = self.0.lock().map(|g| g.is_some()).unwrap_or(false);
        f.debug_tuple("PumpInlet").field(&live).finish()
    }
}

/// Hand one `(port, event)` to the RUNNING pump exactly where a device callback
/// hands it over — same channel, same drain, same dispatch, same thread hops.
/// Returns false when no pump is running or the queue is full (both of which a
/// real device callback would also drop).
///
/// Unlike `super::feed_event`, this measures the real thing: it goes THROUGH the
/// pump rather than around it.
pub fn inject(shared: &MidiShared, port: &str, event: MidiEvent) -> bool {
    let Ok(guard) = shared.inlet.0.lock() else { return false };
    match guard.as_ref() {
        Some(tx) => tx.try_send((port.to_string(), event)).is_ok(),
        None => false,
    }
}
impl Drop for MidiPump {
    fn drop(&mut self) {
        // Detach, never join. Joining here would deadlock when a caller drops the
        // pump while holding the host lock (project switch / teardown), and would
        // self-join if the pump thread itself drops the last host Arc. The thread
        // sees Stop, drops its connections, and exits on its own.
        let _ = self.tx.send(PumpMsg::Stop);
        let _ = self.join.take();
    }
}

pub fn spawn(shared: Arc<MidiShared>, host: Weak<Mutex<StudioHost>>) -> Result<MidiPump, String> {
    let (tx,rx)=mpsc::channel();
    // The event channel is built HERE, not inside `run`, so its sender can be
    // published on `MidiShared` before the thread starts: `inject` is usable the
    // instant `start_pump` returns.
    let (event_tx, event_rx) = mpsc::sync_channel::<(String, MidiEvent)>(1024);
    if let Ok(mut slot) = shared.inlet.0.lock() { *slot = Some(event_tx.clone()); }
    let thread=thread::Builder::new().name("majiks-studio-midi".into()).spawn(move || run(shared,host,rx,event_tx,event_rx)).map_err(|e|e.to_string())?;
    Ok(MidiPump{tx,join:Some(thread)})
}

fn run(
    shared: Arc<MidiShared>,
    host: Weak<Mutex<StudioHost>>,
    rx: mpsc::Receiver<PumpMsg>,
    event_tx: mpsc::SyncSender<(String, MidiEvent)>,
    event_rx: mpsc::Receiver<(String, MidiEvent)>,
) {
    let mut connections: Vec<MidiInputConnection<()>> = Vec::new();
    let mut connected_names: Vec<String> = Vec::new();
    let mut last_scan = Instant::now() - Duration::from_secs(2);
    let mut last_flush = Instant::now();
    let mut learn_was = false;
    // Continuous (fader) events, keyed by "{port}:{event_id}", latest-wins.
    let mut pending: HashMap<String, (String, MidiEvent)> = HashMap::new();

    loop {
        // BLOCK ON THE EVENT CHANNEL, never on the control channel.
        //
        // This thread used to sleep on `rx.recv_timeout(15ms)` — the CONTROL
        // channel — and only drained events after that timeout expired. A
        // note-on arriving one microsecond into the sleep therefore woke
        // nothing and sat for the rest of the tick: measured at mean 10.0 ms,
        // p95 17.4 ms, worst 18.5 ms from callback to dispatch, which is what a
        // player feels as "a little delay". Nothing downstream was at fault;
        // the audio buffer is 128 frames and the render thread was idling at
        // 0.1 ms p95.
        //
        // Now the wake is the event itself. `IDLE_TICK_MS` survives ONLY as the
        // idle heartbeat that drives hotplug rescans and the coalesce flush when
        // no events are arriving; it no longer gates input latency. Stop and
        // Rescan are latency-tolerant by nature (a device rescan is a 1.5 s
        // cadence, teardown is not felt), so they move to a non-blocking poll.
        //
        // `event_tx` is held for the life of this thread, so this recv can never
        // return Disconnected — the pump stays alive with zero devices attached.
        let first = match event_rx.recv_timeout(Duration::from_millis(IDLE_TICK_MS)) {
            Ok(event) => Some(event),
            Err(_) => None,
        };

        // Control channel: drained without blocking, so it cannot delay a note.
        let mut stop = false;
        loop {
            match rx.try_recv() {
                Ok(PumpMsg::Stop) | Err(mpsc::TryRecvError::Disconnected) => {
                    stop = true;
                    break;
                }
                Ok(PumpMsg::Rescan) => last_scan = Instant::now() - Duration::from_secs(2),
                Err(mpsc::TryRecvError::Empty) => break,
            }
        }
        if stop {
            break;
        }

        // A learn session opening/closing changes which ports we connect.
        let learn_active = shared.learn.lock().map(|l| l.active).unwrap_or(false);
        if learn_active != learn_was {
            learn_was = learn_active;
            last_scan = Instant::now() - Duration::from_secs(2);
        }

        if last_scan.elapsed() >= Duration::from_millis(HOTPLUG_MS) {
            last_scan = Instant::now();
            if let Some((conns, names)) = scan(&shared, &event_tx, learn_active, &connected_names) {
                connections = conns;
                connected_names = names;
            }
        }

        // Drain the callback channel: learn captures/swallows in-scope events;
        // continuous events coalesce; discrete events dispatch this tick. The
        // event that WOKE us leads the batch; everything queued behind it
        // follows, so a chord still dispatches in one pass.
        let mut immediate: Vec<(String, MidiEvent)> = Vec::new();
        let batch = first.into_iter().chain(std::iter::from_fn(|| event_rx.try_recv().ok()));
        for (port, event) in batch {
            if learn_active {
                if let Ok(mut learn) = shared.learn.lock() {
                    if learn.offer(&port, &event) {
                        drop(learn);
                        super::record_last_event(&shared, &port, &event);
                        continue;
                    }
                }
            }
            super::record_last_event(&shared, &port, &event);
            if event.is_continuous() && continuous_binding(&shared, &port, &event) {
                pending.insert(format!("{port}:{}", event.event_id()), (port, event));
            } else {
                immediate.push((port, event));
            }
        }

        let flush_due = last_flush.elapsed() >= Duration::from_millis(COALESCE_MS);
        if !immediate.is_empty() || (flush_due && !pending.is_empty()) {
            // ALL host locking is here on the pump thread, never in the callback.
            match host.upgrade() {
                Some(strong) => {
                    if let Ok(mut h) = strong.lock() {
                        for (port, event) in &immediate {
                            super::dispatch_event(&mut h, &shared, port, event);
                        }
                        if flush_due {
                            for (_, (port, event)) in pending.drain() {
                                super::dispatch_event(&mut h, &shared, &port, &event);
                            }
                        }
                    }
                }
                None => break, // the host is gone; end the pump.
            }
        }
        if flush_due {
            last_flush = Instant::now();
        }
    }

    // Shutdown: drop the connections and exit WITHOUT touching the host lock.
    // Locking the host here would deadlock a caller tearing the pump down while
    // holding that lock (project switch / teardown). Any un-flushed coalesced
    // values are discarded; the in-loop flush already dispatched everything up to
    // the last COALESCE_MS tick.
    if let Ok(mut slot) = shared.inlet.0.lock() { *slot = None; }
    drop(connections);
}

/// Whether `scan` should open a connection to `port`.
///
/// Split out of `scan` and made pure ON PURPOSE. The only headless seam for MIDI
/// input is `pump::inject`, which hands an event to a pump that is ALREADY
/// running — so it enters downstream of this decision and can never observe it.
/// A test that injects on an unmapped port proves the dispatch half and says
/// nothing at all about whether that port would ever have been opened, which is
/// exactly where the "an ordinary USB keyboard is completely inert" bug lived.
/// This function is what `scan` calls and what the tests below assert on.
pub(crate) fn should_connect(
    reg: Option<&super::registry::MapRegistry>,
    port: &str,
    learn_active: bool,
) -> bool {
    // A learn session listens to everything present, mapped or not (spec 1.1).
    if learn_active {
        return true;
    }
    match reg {
        // An INSTRUMENT port is one whose keys are supposed to play, which is
        // the default role. It is connected whether or not a map resolves for
        // it: a map binds knobs to commands, it does not grant permission to
        // play notes. A CONTROL port with no map has nothing to fire, so it
        // stays closed exactly as before.
        Some(r) => {
            r.role(port) == super::registry::PortRole::Instrument || r.resolve(port).is_some()
        }
        // No registry to consult: treat the port as an instrument (the default).
        None => true,
    }
}

/// Whether `event`'s matched binding on `port` is a continuous fader (spec 2.4).
fn continuous_binding(shared: &MidiShared, port: &str, event: &MidiEvent) -> bool {
    let Ok(reg) = shared.registry.read() else { return false };
    let Some(lm) = reg.resolve(port) else { return false };
    resolve::matched_binding(event, &lm.map.bindings)
        .map(resolve::binding_is_continuous)
        .unwrap_or(false)
}

/// Enumerate present inputs, refresh the port table, and (re)connect the desired
/// set only when it changed. Honors `MAJIKS_MIDI_PORT_FILTER`. Returns `None`
/// when the connected set is unchanged.
///
/// # Which ports get connected, and why that changed
///
/// It used to be "a map resolves for it, or a learn session is open". That made
/// an ordinary USB keyboard nobody had written a map for **completely inert**:
/// no map resolves, so the port is never opened, so no event ever reaches the
/// pump, so the keys do nothing and the MIDI monitor stays empty. There is
/// nothing to learn and nothing to diagnose — the app simply does not see the
/// instrument. Requiring a device-specific map before a keyboard's KEYS work
/// inverts the relationship: a map exists to bind knobs to commands, not to
/// grant permission to play notes.
///
/// So a port is now connected when it is an INSTRUMENT port (the default role —
/// see `registry::PortRole`), which is to say: whenever its keys are supposed to
/// play. A map still decides what its knobs and wheels do; it no longer decides
/// whether it exists. A port explicitly flipped to `control` with no map has
/// nothing to fire and stays unconnected, as before.
///
/// This opens MIDI **input** connections only (`MidiInput`, never
/// `MidiOutput`) — it makes no sound by itself and touches no audio device.
fn scan(
    shared: &MidiShared,
    tx: &mpsc::SyncSender<(String, MidiEvent)>,
    learn_active: bool,
    prev_names: &[String],
) -> Option<(Vec<MidiInputConnection<()>>, Vec<String>)> {
    let filter = std::env::var("MAJIKS_MIDI_PORT_FILTER").ok();
    let scanner = match MidiInput::new("Majiks Studio MIDI Scanner") {
        Ok(mut i) => { i.ignore(Ignore::None); i }
        Err(e) => { eprintln!("MIDI unavailable: {e}"); return None; }
    };
    let present: Vec<(usize, String)> = scanner.ports().iter().enumerate().filter_map(|(index, port)| {
        let name = scanner.port_name(port).ok()?;
        if filter.as_deref().is_some_and(|f| !name.contains(f)) { return None; }
        Some((index, name))
    }).collect();
    drop(scanner);

    // Decide connect per present port and build the snapshot's port table.
    let mut ports = Vec::with_capacity(present.len());
    let mut to_connect: Vec<(usize, String)> = Vec::new();
    {
        let reg = shared.registry.read().ok();
        for (index, name) in &present {
            let connect = should_connect(reg.as_deref(), name, learn_active);
            ports.push(PortState { name: name.clone(), connected: connect });
            if connect { to_connect.push((*index, name.clone())); }
        }
    }
    if let Ok(mut p) = shared.ports.lock() { *p = ports; }

    let mut names: Vec<String> = to_connect.iter().map(|(_, n)| n.clone()).collect();
    names.sort();
    if names == prev_names {
        return None; // connected set unchanged; keep the live connections.
    }

    let debounce = Arc::new(Mutex::new(HashMap::<String, Instant>::new()));
    let conns = to_connect.into_iter().filter_map(|(index, name)| {
        let input = MidiInput::new("Majiks Studio MIDI Input").ok()?;
        let port = input.ports().into_iter().nth(index)?;
        let sender = tx.clone();
        let port_name = name.clone();
        let debounce = Arc::clone(&debounce);
        input.connect(&port, &name, move |_stamp, bytes, _| {
            let Some(event) = MidiEvent::from_bytes(bytes) else { return };
            let now = Instant::now();
            let key = format!("{port_name}:{}", event.event_id());
            if let Ok(mut seen) = debounce.lock() {
                if seen.get(&key).is_some_and(|t| now.duration_since(*t) < Duration::from_millis(3)) { return; }
                seen.insert(key, now);
            }
            let _ = sender.try_send((port_name.clone(), event));
        }, ()).ok()
    }).collect();
    Some((conns, names))
}

#[cfg(test)]
mod tests {
    use super::should_connect;
    use super::super::registry::{MapRegistry, PortRole};

    /// A name matching no bundled map's `namePatterns` — an ordinary keyboard
    /// nobody has written a map for.
    const UNMAPPED: &str = "Some Unremarkable USB Keyboard";
    /// The cable name the bundled SX-KC211 map auto-matches.
    const MAPPED: &str = "usb midi interface";

    #[test]
    fn an_unmapped_keyboard_is_connected_so_its_keys_can_play() {
        // THE first-run bug. `connect = learn_active || mapped` left this false,
        // so the port was never opened, no event ever reached the pump, the MIDI
        // monitor stayed empty, and the keyboard looked broken with nothing to
        // diagnose.
        let reg = MapRegistry::bundled();
        assert!(reg.resolve(UNMAPPED).is_none(), "precondition: no map resolves");
        assert!(
            should_connect(Some(&reg), UNMAPPED, false),
            "an instrument port must be opened whether or not a map exists for it"
        );
    }

    #[test]
    fn a_mapped_controller_is_still_connected() {
        let reg = MapRegistry::bundled();
        assert!(reg.resolve(MAPPED).is_some(), "precondition: a map resolves");
        assert!(should_connect(Some(&reg), MAPPED, false));
    }

    #[test]
    fn a_control_port_with_no_map_stays_closed() {
        // Flipping a port to `control` says "its keys do not play". With no map
        // it has no bindings to fire either, so there is nothing to listen for.
        let mut reg = MapRegistry::bundled();
        reg.set_role(UNMAPPED, PortRole::Control);
        assert!(
            !should_connect(Some(&reg), UNMAPPED, false),
            "a control port with nothing bound has nothing to listen for"
        );
    }

    #[test]
    fn a_control_port_that_has_a_map_is_still_connected() {
        let mut reg = MapRegistry::bundled();
        reg.set_role(MAPPED, PortRole::Control);
        assert!(
            should_connect(Some(&reg), MAPPED, false),
            "a control surface's bindings must keep working"
        );
    }

    #[test]
    fn a_learn_session_listens_to_everything_present() {
        let mut reg = MapRegistry::bundled();
        reg.set_role(UNMAPPED, PortRole::Control);
        assert!(
            should_connect(Some(&reg), UNMAPPED, true),
            "learn must be able to capture from a port nothing else would open"
        );
    }
}
