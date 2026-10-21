//! MIDI INPUT only. The OS connections are confined to `pump`'s one thread.
//!
//! Everything a control does becomes a catalog command on the same journaled,
//! validated bus the UI and the agents use. `apply` runs the host-side config
//! effects (persist maps + overrides, drive the learn session); `pump` turns
//! live hardware events into `host.submit` calls stamped `Actor::user("midi")`.
pub mod event;
pub mod learn;
pub mod map;
pub mod pump;
pub mod registry;
pub mod resolve;

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};

use serde_json::{json, Value};
use timeline_core::Actor;

use crate::{error::StudioError, host::StudioHost};
use event::MidiEvent;
use learn::LearnSession;
use map::{validate_map, Binding, ControlMatch, DeviceMatch, MidiMap, Target, ValueMap};
use registry::{LoadedMap, MapRegistry, PortRole};
use resolve::{resolve, Prepared};

/// The Sterling trigger ring is bounded; the oldest item is dropped (spec 8.1).
const STERLING_RING_MAX: usize = 16;

/// A present MIDI input port. The resolved map, source, and override are all
/// computed fresh from the registry at snapshot time, so a `device.select` or a
/// map edit re-resolves every port live without touching this row.
#[derive(Debug, Clone, Default)]
pub struct PortState {
    pub name: String,
    pub connected: bool,
}

#[derive(Debug, Default)]
pub struct MidiShared {
    pub registry: RwLock<MapRegistry>,
    pub learn: Mutex<LearnSession>,
    pub ports: Mutex<Vec<PortState>>,
    pub enabled: AtomicBool,
    pub last_event: Mutex<Option<Value>>,
    pub sterling: Mutex<Vec<Value>>,
    pub sterling_seq: AtomicU64,
    pub event_seq: AtomicU64,
    /// Bumped once per COMPLETED `dispatch_event`. This is the far end of the
    /// input path — the observable that says "the note has reached the host",
    /// which is what an input-latency measurement has to time against. A seq
    /// (not a bool) so a waiter can tell "the one I sent" from "one that was
    /// already there".
    pub dispatched_seq: AtomicU64,
    /// The running pump's own event inlet: the exact point a device callback
    /// hands an event over. Published by `pump::spawn`, taken by
    /// `pump::inject`. `None` when no pump is running.
    pub(crate) inlet: pump::PumpInlet,
    /// The base data dir maps + settings persist under (spec 4). `None` in memory.
    pub data_dir: Option<PathBuf>,
}

#[derive(Default)]
pub struct MidiState {
    pub shared: Arc<MidiShared>,
    pub pump: Option<pump::MidiPump>,
}

impl MidiState {
    pub fn new(data_dir: Option<&Path>) -> Self {
        let registry = MapRegistry::load(data_dir.map(|p| p.to_path_buf()));
        let shared = Arc::new(MidiShared {
            registry: RwLock::new(registry),
            enabled: AtomicBool::new(true),
            data_dir: data_dir.map(|p| p.to_path_buf()),
            ..Default::default()
        });
        Self { shared, pump: None }
    }

    pub fn snapshot_json(&self) -> Value {
        let s = &self.shared;
        let enabled = s.enabled.load(Ordering::Relaxed);
        let ports_raw = s.ports.lock().map(|x| x.clone()).unwrap_or_default();
        let reg = s.registry.read().ok();
        let ports: Vec<Value> = ports_raw.iter().map(|p| port_json(p, reg.as_deref())).collect();
        let active: Vec<Value> = ports_raw
            .iter()
            .flat_map(|p| active_bindings_for(p, reg.as_deref()))
            .collect();
        let maps = reg.as_ref().map(|r| r.json()).unwrap_or_else(|| json!([]));
        json!({
            "enabled": enabled,
            "ports": ports,
            "maps": maps,
            "activeBindings": active,
            "learn": s.learn.lock().map(|l| l.json()).unwrap_or_else(|_| json!({})),
            "lastEvent": s.last_event.lock().ok().and_then(|x| x.clone()),
            "sterling": {
                "nextSeq": s.sterling_seq.load(Ordering::Relaxed),
                "pending": s.sterling.lock().map(|x| x.clone()).unwrap_or_default(),
            },
        })
    }

    /// Route a `midi.*` submit to its host-side config effect (GAP 1). The bus
    /// has already validated the envelope (host `submit`); this persists to disk
    /// and mutates shared state.
    pub fn apply(&mut self, name: &str, params: &Value) -> Result<Value, StudioError> {
        match name {
            "midi.device.select" => self.device_select(params),
            "midi.port.role.set" => self.port_role_set(params),
            "midi.learn.start" => self.learn_start(params),
            "midi.learn.stop" => self.learn_stop(),
            "midi.binding.set" => self.binding_set(params),
            "midi.binding.clear" => self.binding_clear(params),
            "midi.map.import" => self.map_import(params),
            "midi.map.export" => self.map_export(params),
            "midi.reload" => self.reload(),
            other => Err(StudioError::Unsupported(format!("unknown midi command {other}"))),
        }
    }

    // -- handlers --------------------------------------------------------------

    fn device_select(&mut self, params: &Value) -> Result<Value, StudioError> {
        let device = str_param(params, "device")?;
        let map = params.get("map").and_then(Value::as_str).unwrap_or("auto").to_string();
        {
            let mut reg = self.shared.registry.write().map_err(lock_err)?;
            let stored = if map == "auto" || map == "none" {
                map.clone()
            } else {
                // Accept a file-stem key or a display name; persist the KEY.
                reg.find(&map)
                    .map(|m| m.key.clone())
                    .ok_or_else(|| StudioError::invalid(format!("unknown map '{map}'")))?
            };
            reg.set_override(&device, &stored);
            reg.save_overrides().map_err(StudioError::io)?;
        }
        self.rescan();
        Ok(json!({ "ok": true, "device": device, "map": map }))
    }

    /// `midi.port.role.set`: choose what a port's KEYS do. Nothing is deleted
    /// either way — flipping a port to `control` restores every note binding it
    /// had, and flipping back to `instrument` makes the keys play again.
    fn port_role_set(&mut self, params: &Value) -> Result<Value, StudioError> {
        let port = str_param(params, "port")?;
        let role_str = str_param(params, "role")?;
        let role = PortRole::parse(&role_str)
            .ok_or_else(|| StudioError::invalid(format!("role must be instrument|control, got {role_str}")))?;
        {
            let mut reg = self.shared.registry.write().map_err(lock_err)?;
            reg.set_role(&port, role);
            reg.save_overrides().map_err(StudioError::io)?;
        }
        Ok(json!({ "ok": true, "port": port, "role": role.as_str() }))
    }

    fn learn_start(&mut self, params: &Value) -> Result<Value, StudioError> {
        let device = params.get("device").and_then(Value::as_str).map(String::from);
        self.shared.learn.lock().map_err(lock_err)?.start(device.clone());
        // Connect every present input so brand-new hardware is learnable (spec 1.1).
        self.rescan();
        Ok(json!({ "ok": true, "learning": true, "device": device }))
    }

    fn learn_stop(&mut self) -> Result<Value, StudioError> {
        self.shared.learn.lock().map_err(lock_err)?.stop();
        self.rescan();
        Ok(json!({ "ok": true, "learning": false }))
    }

    fn binding_set(&mut self, params: &Value) -> Result<Value, StudioError> {
        let target_val = params
            .get("target")
            .cloned()
            .ok_or_else(|| StudioError::invalid("midi.binding.set requires target"))?;
        let target: Target = serde_json::from_value(target_val)
            .map_err(|e| StudioError::invalid(format!("invalid target: {e}")))?;

        let captured = self.shared.learn.lock().ok().and_then(|l| l.captured.clone());
        let (ctype, channel, number) = resolve_control(params.get("control"), captured.as_ref())?;
        let device = params
            .get("device")
            .and_then(Value::as_str)
            .map(String::from)
            .or_else(|| captured.as_ref().and_then(|c| c.get("device")).and_then(Value::as_str).map(String::from))
            .ok_or_else(|| StudioError::invalid("no device given and no captured control"))?;
        let control = build_control_match(&ctype, channel, number)?;

        let value_map: Option<ValueMap> = match params.get("valueMap") {
            Some(v) if !v.is_null() => Some(
                serde_json::from_value(v.clone())
                    .map_err(|e| StudioError::invalid(format!("invalid valueMap: {e}")))?,
            ),
            _ => None,
        };
        let label = params
            .get("label")
            .and_then(Value::as_str)
            .map(String::from)
            .unwrap_or_else(|| default_label(&ctype, channel, number));
        let enabled = params.get("enabled").and_then(Value::as_bool).unwrap_or(true);
        let id = slug(&label);
        let binding = Binding { id: id.clone(), label, control, target, value_map, enabled, comment: None };

        // Pick the user overlay map: the resolved user file, else a user copy of
        // the active bundled map, else a fresh map for unknown hardware (spec 4).
        let (stem, mut candidate) = {
            let reg = self.shared.registry.read().map_err(lock_err)?;
            match reg.resolve(&device) {
                Some(lm) if lm.source == "user" => (lm.key.clone(), lm.map.clone()),
                Some(lm) => (format!("{}-user", lm.key), lm.map.clone()),
                None => (sanitize(&device), new_map_for(&device)),
            }
        };
        upsert_binding(&mut candidate, binding);
        // Validate the whole map (target compile) BEFORE writing: a typo fails
        // the command, not the first keypress.
        validate_map(&candidate).map_err(StudioError::invalid)?;

        self.persist_map(&stem, candidate)?;
        self.rescan();
        Ok(json!({ "ok": true, "device": device, "map": stem, "binding": id }))
    }

    fn binding_clear(&mut self, params: &Value) -> Result<Value, StudioError> {
        let device = str_param(params, "device")?;
        let (ctype, channel, number) = resolve_control(params.get("control"), None)?;
        let control = build_control_match(&ctype, channel, number)?;

        let (stem, candidate) = {
            let reg = self.shared.registry.read().map_err(lock_err)?;
            match reg.resolve(&device) {
                Some(lm) if lm.source == "user" => {
                    let mut m = lm.map.clone();
                    let before = m.bindings.len();
                    m.bindings.retain(|b| b.control != control);
                    if m.bindings.len() == before {
                        return Err(StudioError::invalid("no matching binding to clear"));
                    }
                    (lm.key.clone(), m)
                }
                _ => return Err(StudioError::invalid(format!("no user overlay map to clear for '{device}'"))),
            }
        };
        self.persist_map(&stem, candidate)?;
        self.rescan();
        Ok(json!({ "ok": true, "device": device, "cleared": true }))
    }

    fn map_import(&mut self, params: &Value) -> Result<Value, StudioError> {
        let source = str_param(params, "sourcePath")?;
        let overwrite = params.get("overwrite").and_then(Value::as_bool).unwrap_or(false);
        let maps_dir = self
            .shared
            .registry
            .read()
            .map_err(lock_err)?
            .maps_dir()
            .ok_or_else(|| StudioError::invalid("midi.map.import needs a data dir; unavailable on an in-memory host"))?;

        let text = std::fs::read_to_string(&source).map_err(StudioError::io)?;
        let candidate: MidiMap = serde_json::from_str(&text)
            .map_err(|e| StudioError::invalid(format!("source is not a valid midi map: {e}")))?;
        validate_map(&candidate).map_err(StudioError::invalid)?;

        let stem = sanitize(Path::new(&source).file_stem().and_then(|s| s.to_str()).unwrap_or("imported"));
        let dest = maps_dir.join(format!("{stem}.json"));
        let replaced = dest.exists();
        if replaced && !overwrite {
            return Err(StudioError::invalid(format!(
                "a map named {stem}.json already exists; pass overwrite:true to replace it"
            )));
        }
        std::fs::create_dir_all(&maps_dir).map_err(StudioError::io)?;
        std::fs::write(&dest, &text).map_err(StudioError::io)?;

        let name = candidate.name.clone();
        let bindings = candidate.bindings.len();
        let shadows = MapRegistry::is_bundled_key(&stem);
        self.reload_registry()?;
        self.rescan();
        Ok(json!({
            "ok": true,
            "file": format!("{stem}.json"),
            "name": name,
            "bindings": bindings,
            "replacedFile": replaced,
            "shadowsBundled": shadows,
        }))
    }

    fn map_export(&mut self, params: &Value) -> Result<Value, StudioError> {
        let key_or_name = str_param(params, "map")?;
        let out = str_param(params, "outputPath")?;
        let (body, name, bindings) = {
            let reg = self.shared.registry.read().map_err(lock_err)?;
            let lm = reg
                .find(&key_or_name)
                .ok_or_else(|| StudioError::invalid(format!("unknown map '{key_or_name}'")))?;
            // Verbatim file body: the on-disk file if present, else the embedded
            // bundled copy, else a re-serialization (in-memory user edits).
            let body = reg
                .maps_dir()
                .and_then(|d| std::fs::read_to_string(d.join(format!("{}.json", lm.key))).ok())
                .or_else(|| MapRegistry::bundled_body(&lm.key).map(String::from))
                .unwrap_or_else(|| serde_json::to_string_pretty(&lm.map).unwrap_or_default());
            (body, lm.map.name.clone(), lm.map.bindings.len())
        };
        std::fs::write(&out, body).map_err(StudioError::io)?;
        Ok(json!({ "ok": true, "map": key_or_name, "outputPath": out, "name": name, "bindings": bindings }))
    }

    fn reload(&mut self) -> Result<Value, StudioError> {
        self.reload_registry()?;
        self.rescan();
        let maps = self.shared.registry.read().map_err(lock_err)?.maps.len();
        Ok(json!({ "ok": true, "maps": maps }))
    }

    // -- shared plumbing -------------------------------------------------------

    /// Persist a map to its user file and reload, or (in memory) mutate the
    /// registry directly with no file write (spec 4).
    fn persist_map(&self, stem: &str, map: MidiMap) -> Result<(), StudioError> {
        if self.shared.data_dir.is_some() {
            self.shared
                .registry
                .read()
                .map_err(lock_err)?
                .write_map_file(stem, &map)
                .map_err(StudioError::io)?;
            self.reload_registry()
        } else {
            let mut reg = self.shared.registry.write().map_err(lock_err)?;
            reg.maps.insert(
                stem.to_string(),
                LoadedMap { key: stem.to_string(), map, source: "user".into(), error: None },
            );
            Ok(())
        }
    }

    fn reload_registry(&self) -> Result<(), StudioError> {
        self.shared.registry.write().map_err(lock_err)?.reload();
        Ok(())
    }

    fn rescan(&self) {
        if let Some(pump) = &self.pump {
            pump.rescan();
        }
    }
}

// -- dispatch (GAP 2 shares this with the pump; tests drive `feed_event`) ------

/// Resolve `event` on `port`'s active map and run each prepared dispatch through
/// the host, which is already locked (the pump thread, or a test). Hardware
/// commands are stamped `Actor::user("midi")` (spec 8.2). Never panics; a failed
/// command is logged and skipped so it cannot wedge the pump.
pub(crate) fn dispatch_event(host: &mut StudioHost, shared: &MidiShared, port: &str, event: &MidiEvent) {
    // Clone the bindings + role out from under the registry lock so nothing is
    // held across `host.submit`.
    let (bindings, role) = match shared.registry.read() {
        Ok(reg) => (
            reg.resolve(port).map(|lm| lm.map.bindings.clone()).unwrap_or_default(),
            reg.role(port),
        ),
        Err(_) => return,
    };

    // THE KEYS PLAY, BY DEFAULT. A note message on an `instrument` port goes to
    // the instrument and never to a binding — otherwise every note a map binds
    // is stolen from the musician. On the bundled SX-KC211 map that is C2..D4,
    // middle C included, wired to transport/undo/Sterling: the instant an
    // instrument became audible, playing middle C would have fired "add a
    // layer". Flipping the port to `control` (midi.port.role.set) restores
    // every one of those bindings; nothing is deleted either way.
    //
    // Non-note messages (CC, pitch bend) fall through to the binding path in
    // BOTH roles, so a controller's knobs and wheel keep working while its keys
    // play.
    if role == PortRole::Instrument && !event.is_continuous() {
        dispatch_note_to_instrument(host, event);
        shared.dispatched_seq.fetch_add(1, Ordering::Relaxed);
        return;
    }

    if bindings.is_empty() {
        shared.dispatched_seq.fetch_add(1, Ordering::Relaxed);
        return;
    }
    let ctx = host.midi_dispatch_ctx();
    for prepared in resolve(event, &ctx, &bindings) {
        match prepared {
            // undo/redo are host session verbs, not bus commands (spec 5.3).
            Prepared::Command { name, .. } if name == "undo" => {
                let _ = host.undo(Actor::user("midi"));
            }
            Prepared::Command { name, .. } if name == "redo" => {
                let _ = host.redo(Actor::user("midi"));
            }
            Prepared::Command { name, params } => {
                if let Err(e) = host.submit(Actor::user("midi"), &name, params) {
                    eprintln!("midi: command {name} failed: {e}");
                }
            }
            Prepared::Sterling { instruction, binding_id } => {
                push_sterling(shared, port, &instruction, &binding_id);
            }
        }
    }
    shared.dispatched_seq.fetch_add(1, Ordering::Relaxed);
}

/// Play one keyboard note on the project's instrument track.
///
/// Note-on holds (`gate: "on"`) and note-off releases, so a held key sustains
/// exactly as long as the finger does. `preview_note` is the SAME path the
/// piano-roll gutter key and the on-screen keyboard use — one note path, so a
/// change to how a note sounds, is buffered, or is kept cannot apply to some
/// surfaces and not others.
///
/// An EMPTY project is playable: a note-on with no instrument track in the
/// project creates one (`instrument_target_for_note`, one undoable step) rather
/// than going silent. The condition is asked of the PROJECT on every note, so
/// removing the instrument and playing again gets you another one — it is not a
/// "we already did this once" latch. A note-OFF never creates anything, and a
/// note-on whose auto-create the user has just undone with keys still held is
/// reported rather than acted on.
///
/// While a MIDI take is open (`record.start` on an instrument track), note-on
/// and note-off are also buffered into the capture with project-tick stamps so
/// `record.stop` can land one batched `note.add`.
fn dispatch_note_to_instrument(host: &mut StudioHost, event: &MidiEvent) {
    // Record the key gate BEFORE resolving a target. Both branches below can
    // return without ever reaching `preview_note`, and a key-up that is dropped
    // on the way out leaves that pitch held down in the host's view — which is
    // what a hold-off is keyed on.
    match event {
        MidiEvent::NoteOn { note, .. } => host.observe_note_gate(*note, "on"),
        MidiEvent::NoteOff { note, .. } => host.observe_note_gate(*note, "off"),
        _ => {}
    }
    let track_id = match host.midi_instrument_target() {
        Some(id) => id,
        None => {
            if matches!(event, MidiEvent::NoteOff { .. }) {
                return; // a stray key-up must not conjure a track.
            }
            match host.instrument_target_for_note() {
                Ok(Some(id)) => id,
                // Held off: the user undid the auto-created track and their
                // fingers are still down. Rebuilding it under them is the one
                // way this rule can fight its user.
                Ok(None) => return,
                Err(e) => {
                    eprintln!("midi: could not create an instrument track to play: {e}");
                    return;
                }
            }
        }
    };
    let (pitch, velocity, gate, is_on) = match event {
        MidiEvent::NoteOn { note, velocity, .. } => (*note, *velocity, "on", true),
        MidiEvent::NoteOff { note, .. } => (*note, 0u8, "off", false),
        // Unreachable: the caller already filtered continuous events, and those
        // are the only other variants. Kept total rather than `unreachable!()`
        // so a future MidiEvent variant degrades to "ignored", not "panic on
        // the MIDI pump thread".
        _ => return,
    };
    // Buffer the take first so a stamp is not delayed by audition work.
    host.midi_record_event(pitch, velocity, is_on);
    let params = json!({
        "trackId": track_id,
        "pitch": pitch,
        "velocity": if velocity == 0 { 100 } else { velocity },
        "gate": gate,
    });
    if let Err(e) = host.preview_note(&params) {
        eprintln!("midi: note {pitch} -> instrument failed: {e}");
    }
}

/// Push a Sterling trigger onto the bounded ring with a monotonic seq (spec 8.1).
pub(crate) fn push_sterling(shared: &MidiShared, port: &str, instruction: &str, binding_id: &str) {
    let seq = shared.sterling_seq.fetch_add(1, Ordering::Relaxed);
    if let Ok(mut ring) = shared.sterling.lock() {
        ring.push(json!({ "seq": seq, "instruction": instruction, "bindingId": binding_id, "port": port }));
        while ring.len() > STERLING_RING_MAX {
            ring.remove(0);
        }
    }
}

/// Record the latest event for the snapshot's MIDI monitor line, with a
/// monotonic seq (spec 6 `lastEvent`).
pub(crate) fn record_last_event(shared: &MidiShared, port: &str, event: &MidiEvent) {
    let seq = shared.event_seq.fetch_add(1, Ordering::Relaxed);
    if let Ok(mut last) = shared.last_event.lock() {
        *last = Some(json!({
            "seq": seq,
            "port": port,
            "type": event.kind(),
            "channel": event.channel(),
            "number": event.number(),
            "value": event.value(),
        }));
    }
}

/// The no-hardware injection seam (spec 11): feed one `(port, event)` as if it
/// arrived from a device, without opening one. An in-scope learn session
/// captures and swallows it; otherwise it dispatches immediately (coalescing is
/// a pump-thread timing concern, not a correctness one). Returns whether learn
/// swallowed the event.
pub fn feed_event(host: &mut StudioHost, port: &str, event: &MidiEvent) -> bool {
    let shared = Arc::clone(&host.midi.shared);
    let swallowed = {
        match shared.learn.lock() {
            Ok(mut learn) => learn.offer(port, event),
            Err(_) => false,
        }
    };
    record_last_event(&shared, port, event);
    if swallowed {
        return true;
    }
    dispatch_event(host, &shared, port, event);
    false
}

pub fn start_pump(host: &Arc<Mutex<StudioHost>>) -> Result<(), StudioError> {
    let mut h = host.lock().map_err(|_| StudioError::invalid("host lock poisoned"))?;
    if h.midi.pump.is_some() {
        return Ok(());
    }
    let shared = Arc::clone(&h.midi.shared);
    let weak = Arc::downgrade(host);
    h.midi.pump = Some(pump::spawn(shared, weak).map_err(StudioError::io)?);
    Ok(())
}

// -- snapshot helpers ----------------------------------------------------------

fn port_json(p: &PortState, reg: Option<&MapRegistry>) -> Value {
    let mut map_name = Value::Null;
    let mut map_key = Value::Null;
    let mut source = Value::Null;
    let mut tested = Value::Null;
    let mut unsupported = Value::Null;
    let mut override_val = Value::Null;
    // Unset = instrument. Reported on every port so the Settings row can show
    // what the keys will actually do without the UI having to guess a default.
    let mut role = PortRole::default();
    if let Some(reg) = reg {
        role = reg.role(&p.name);
        if let Some(o) = reg.overrides.get(&p.name) {
            override_val = json!(o);
        }
        if let Some(lm) = reg.resolve(&p.name) {
            map_name = json!(lm.map.name);
            map_key = json!(lm.key);
            source = json!(lm.source);
            tested = json!(lm.map.tested);
            unsupported = lm.map.unsupported_reason.clone().map(Value::from).unwrap_or(Value::Null);
        } else if let Some(reason) = reg.unsupported_reason_for(&p.name) {
            // A matching map that never loads still reports why (spec 6).
            unsupported = json!(reason);
        }
    }
    json!({
        "name": p.name,
        "connected": p.connected,
        "map": map_name,
        "mapKey": map_key,
        "source": source,
        "tested": tested,
        "unsupportedReason": unsupported,
        "override": override_val,
        "role": role.as_str(),
    })
}

fn active_bindings_for(p: &PortState, reg: Option<&MapRegistry>) -> Vec<Value> {
    if !p.connected {
        return vec![];
    }
    let Some(reg) = reg else { return vec![] };
    let Some(lm) = reg.resolve(&p.name) else { return vec![] };
    let role = reg.role(&p.name);
    lm.map
        .bindings
        .iter()
        .map(|b| {
            // A note-matched binding on an `instrument` port does NOT fire — the
            // keys play. Say so on the row rather than listing it as active:
            // "16 active bindings" while 16 of them are being swallowed is
            // exactly the kind of green-on-the-wrong-axis readout that sends
            // someone hunting a hardware fault.
            let suppressed = role == PortRole::Instrument
                && matches!(b.control, ControlMatch::NoteOn { .. } | ControlMatch::NoteOff { .. });
            json!({
                "port": p.name,
                "id": b.id,
                "label": b.label,
                "match": serde_json::to_value(&b.control).unwrap_or(Value::Null),
                "target": serde_json::to_value(&b.target).unwrap_or(Value::Null),
                "targetSummary": target_summary(&b.target),
                "enabled": b.enabled,
                "suppressedByRole": suppressed,
            })
        })
        .collect()
}

fn target_summary(t: &Target) -> String {
    match t {
        Target::Command { name, .. } => format!("command {name}"),
        Target::Builtin { name, .. } => format!("builtin {name}"),
        Target::Sterling { .. } => "Sterling instruction".into(),
    }
}

// -- small helpers -------------------------------------------------------------

fn lock_err<T>(_: T) -> StudioError {
    StudioError::invalid("midi state lock poisoned")
}

fn str_param(params: &Value, key: &str) -> Result<String, StudioError> {
    params
        .get(key)
        .and_then(Value::as_str)
        .map(String::from)
        .ok_or_else(|| StudioError::invalid(format!("missing string param '{key}'")))
}

/// Read a control `{type, channel, number?}` from explicit params, else from the
/// learn session's captured descriptor.
fn resolve_control(explicit: Option<&Value>, captured: Option<&Value>) -> Result<(String, u8, Option<u8>), StudioError> {
    let src = explicit
        .filter(|v| !v.is_null())
        .or(captured)
        .ok_or_else(|| StudioError::invalid("no control given and no captured control"))?;
    let ctype = src
        .get("type")
        .and_then(Value::as_str)
        .ok_or_else(|| StudioError::invalid("control.type is required"))?
        .to_string();
    let channel = src
        .get("channel")
        .and_then(Value::as_u64)
        .ok_or_else(|| StudioError::invalid("control.channel is required"))? as u8;
    let number = src.get("number").and_then(Value::as_u64).map(|n| n as u8);
    Ok((ctype, channel, number))
}

fn build_control_match(ctype: &str, channel: u8, number: Option<u8>) -> Result<ControlMatch, StudioError> {
    let need_number = || number.ok_or_else(|| StudioError::invalid(format!("control.number required for {ctype}")));
    Ok(match ctype {
        "noteOn" => ControlMatch::NoteOn { channel, number: need_number()? },
        "noteOff" => ControlMatch::NoteOff { channel, number: need_number()? },
        "controlChange" => ControlMatch::ControlChange { channel, number: need_number()? },
        "pitchBend" => ControlMatch::PitchBend { channel },
        other => return Err(StudioError::invalid(format!("unknown control type '{other}'"))),
    })
}

fn default_label(ctype: &str, channel: u8, number: Option<u8>) -> String {
    match number {
        Some(n) => format!("{ctype} ch{channel} #{n}"),
        None => format!("{ctype} ch{channel}"),
    }
}

fn control_slug(c: &ControlMatch) -> String {
    match c {
        ControlMatch::NoteOn { channel, number } => format!("noteon-{channel}-{number}"),
        ControlMatch::NoteOff { channel, number } => format!("noteoff-{channel}-{number}"),
        ControlMatch::ControlChange { channel, number } => format!("cc-{channel}-{number}"),
        ControlMatch::PitchBend { channel } => format!("pb-{channel}"),
    }
}

/// Same control replaces, not duplicates (spec 1.1). Disambiguate a colliding id.
fn upsert_binding(map: &mut MidiMap, mut binding: Binding) {
    map.bindings.retain(|b| b.control != binding.control);
    if map.bindings.iter().any(|b| b.id == binding.id) {
        binding.id = format!("{}-{}", binding.id, control_slug(&binding.control));
    }
    map.bindings.push(binding);
}

fn new_map_for(device: &str) -> MidiMap {
    MidiMap {
        version: 1,
        name: device.to_string(),
        device: DeviceMatch { name_patterns: vec![device.to_string()] },
        author: Some("User".into()),
        tested: false,
        source_url: None,
        unsupported_reason: None,
        bindings: vec![],
    }
}

fn slug(s: &str) -> String {
    let mut out = String::new();
    let mut dash = false;
    for c in s.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
            dash = false;
        } else if !dash && !out.is_empty() {
            out.push('-');
            dash = true;
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    if out.is_empty() { "binding".into() } else { out }
}

fn sanitize(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' })
        .collect();
    if cleaned.is_empty() { "untitled".into() } else { cleaned }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn midi_pump_handle_is_send() {
        fn assert_send<T: Send>() {}
        assert_send::<pump::MidiPump>();
    }
}
