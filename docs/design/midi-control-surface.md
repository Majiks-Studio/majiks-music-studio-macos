# MIDI control surface: design spec (M0)

Status: DESIGN, authoritative for the M1-M5 build wave. Written 2026-07-13 against
`main` = `cdce313` (recording lane merged). Companion task breakdown:
`docs/design/midi-tasks.md`.

The port source is Majik's DJ's controller-maps lane
(`~/majiks-dj-lanes/integration`, merged into DJ `main`; read-only reference).
The port target is this repo's command-bus architecture: every capability is a
catalog command first, dispatched through the generic bus, read back through the
snapshot. MIDI INPUT ONLY. Nothing in this design opens an audio output stream,
and nothing sends MIDI out.

What the feature does when built: a class-compliant MIDI controller (Aaron's
SX-KC211 keyboard first) drives transport, mixer moves, arbitrary catalog
commands, and Sterling instructions. Devices auto-connect when a map matches.
MIDI-Learn binds new controls from the Settings tab or from an agent over MCP.
Maps live-reload. Everything a control does goes through the same journaled,
validated bus as the UI and the agents.

---

## 0. Findings that shaped the design (read before implementing)

1. DJ has TWO MIDI surfaces. The legacy Tauri-command surface
   (`midi_commands.rs` + `MidiActionDispatcher::execute_action`) is placeholder
   scaffolding (`println!("Would execute...")`) with stale JSON presets (their
   `"cc"` event type does not even parse against the current enum). The REAL
   surface is the controller-maps lane: `midi.rs` (input manager) +
   `midi_config.rs` (TOML maps, bundled installs, resolve precedence) +
   `midi_runtime.rs` (apply/hot-plug threads, per-port overrides, event ring) +
   `midi_learn.rs` (session learn) + `midi_apply.rs` (engine applier). We port
   the controller-maps lane and ignore the legacy surface and the JSON presets.

2. DJ never sends MIDI OUT. The `led_feedback` and `display` map fields are
   parsed but never transmitted. The port drops them (see the translation
   table, section 5.4).

3. The SX-KC211 reality (live-tested 2026-07-09, `docs/midi/sx-kc211-midi.md`
   in the DJ repo): only the 61 KEYS transmit. Note On/Off, wire channel 0,
   notes 36..96, velocity-sensitive (observed 13..95). Panel buttons, knobs,
   and Party Pads transmit nothing; MAIN VOLUME is analog. The unit reaches
   CoreMIDI under its USB-DIN cable's generic name, "USB MIDI Interface", so
   maps must match that too. Consequence: the DAW's SX-KC211 map is note-zone
   based (keys as buttons), and continuous mixer control on this hardware means
   nudge actions, not fader follows. The format still fully supports CC faders
   for controllers that have them.

4. In the DAW, transport commands on a NON-live host mutate only the tracked
   transport view (`host.rs` `apply_transport`); no device opens and nothing is
   audible. Tests can therefore drive `transport.play` end-to-end silently,
   which DJ's virtual suites could not (they had to pin master volume to 0).

5. Sterling's engine entry (`copilot.rs:248` `Copilot::send(config, text)`)
   needs a `CopilotConfig { endpoint, model, api_key }` that lives in SWIFT
   (UserDefaults + Keychain), passed per call over FFI. The engine cannot mint
   one. This forces the Sterling-trigger dispatch design in section 8.

---

## 1. Contract additions

### 1.1 The command set (8 new commands, catalog 78 -> 86)

All eight are transport-class session verbs: `journaled: false`,
`undoable: false`, `inverseRule: {"mode": "none"}`, category `"midi"`. This
follows the `record.start/stop/cancel` and `project.save` precedent, and it is
a deliberate correction to the M1 scaffold's guess that map mutations would be
journaled: the project journal is project-scoped (replay must reproduce
`project.json` from `.mstudio` contents alone), while MIDI maps and bindings
are app-level config on disk beside the packages. Journaling app config into
the project would break replay determinism and make Cmd+Z in the timeline
unbind hardware keys. Nothing here needs an inverse; the map file is the state.

Two scaffold commands are dropped, with their meaning absorbed:

- `midi.map.load` is `midi.device.select` (pinning a map to a port IS loading
  it; auto-detect does the rest).
- `midi.map.save` is unnecessary because `midi.binding.set` persists to the
  user overlay map file immediately, exactly like DJ's learn-assign.

The commands (paramsSchema given in full; `additionalProperties: false` on all):

**`midi.device.select`** - pin or unpin the map for a MIDI input port.

```json
{
  "type": "object",
  "required": ["device"],
  "properties": {
    "device": { "type": "string", "minLength": 1,
      "description": "Reported port name, e.g. 'USB MIDI Interface'." },
    "map": { "type": "string", "minLength": 1,
      "description": "A map key (file stem or map name), 'none' to leave the port unmapped, or 'auto' (default) to return to pattern auto-detect." }
  }
}
```

Effect: persists the per-port override to `midi-settings.json`, re-resolves the
port live. Precedence (ported from DJ verbatim): override beats auto-detect;
within auto-detect user maps beat bundled and the longest matched pattern wins;
maps carrying `unsupportedReason` never load.

**`midi.learn.start`** - open the learn session.

```json
{
  "type": "object",
  "properties": {
    "device": { "type": "string", "minLength": 1,
      "description": "Scope capture to one port name. Omitted: first control from any device." }
  }
}
```

While the session is open the pump connects EVERY present input (so brand-new
hardware can be learned) and offers every event to the session first; in-scope
events are captured and swallowed, never dispatched. The captured control
descriptor appears in the snapshot (`midi.learn.captured`); the UI polls the
snapshot instead of a dedicated `next` call.

**`midi.learn.stop`** - close the session. No params (`{"type": "object", "properties": {}}`).

**`midi.binding.set`** - create or replace one binding and persist it.

```json
{
  "type": "object",
  "required": ["target"],
  "properties": {
    "device": { "type": "string", "minLength": 1,
      "description": "Port name whose resolved map takes the binding. Default: the learn session's captured device." },
    "control": {
      "type": "object",
      "required": ["type", "channel"],
      "properties": {
        "type": { "type": "string", "enum": ["noteOn", "noteOff", "controlChange", "pitchBend"] },
        "channel": { "type": "integer", "minimum": 0, "maximum": 15 },
        "number": { "type": "integer", "minimum": 0, "maximum": 127,
          "description": "Note or CC number. Omitted for pitchBend (channel-wide)." }
      },
      "additionalProperties": false,
      "description": "Explicit control coordinates. Default: the learn session's captured control."
    },
    "target": {
      "type": "object",
      "required": ["kind"],
      "properties": {
        "kind": { "type": "string", "enum": ["command", "builtin", "sterling"] },
        "name": { "type": "string", "minLength": 1,
          "description": "kind=command: a catalog command name. kind=builtin: one of the built-in action names (section 5.3)." },
        "params": { "type": "object",
          "description": "kind=command: the params template, may contain '$value' and '$track:N' placeholders (section 5.2)." },
        "instruction": { "type": "string", "minLength": 1,
          "description": "kind=sterling: the instruction text queued for Sterling." }
      },
      "additionalProperties": false
    },
    "valueMap": {
      "type": "object",
      "properties": {
        "inputMin": { "type": "integer", "minimum": 0, "maximum": 127, "default": 0 },
        "inputMax": { "type": "integer", "minimum": 0, "maximum": 127, "default": 127 },
        "outputMin": { "type": "number", "default": 0 },
        "outputMax": { "type": "number", "default": 1 },
        "curve": { "type": "string", "enum": ["linear", "exponential", "logarithmic"], "default": "linear" }
      },
      "additionalProperties": false
    },
    "label": { "type": "string" },
    "enabled": { "type": "boolean", "default": true }
  }
}
```

Effect (DJ assign semantics): the binding is written into the USER overlay map
for the device (the resolved user file when one exists, a user copy of the
active bundled map otherwise, a brand-new map for unknown hardware), the file
is saved, the registry reloads, and the binding is live. Same control in the
same map = replace, not duplicate. Validation happens before write: the target
must compile (section 5.2), so a typo fails the command, not the first
keypress.

**`midi.binding.clear`** - remove one binding from the device's user overlay map.

```json
{
  "type": "object",
  "required": ["device", "control"],
  "properties": {
    "device": { "type": "string", "minLength": 1 },
    "control": { "$comment": "same shape as midi.binding.set control", "type": "object",
      "required": ["type", "channel"],
      "properties": {
        "type": { "type": "string", "enum": ["noteOn", "noteOff", "controlChange", "pitchBend"] },
        "channel": { "type": "integer", "minimum": 0, "maximum": 15 },
        "number": { "type": "integer", "minimum": 0, "maximum": 127 }
      },
      "additionalProperties": false }
  }
}
```

**`midi.map.import`** - copy an external map file into the user maps dir.

```json
{
  "type": "object",
  "required": ["sourcePath"],
  "properties": {
    "sourcePath": { "type": "string", "minLength": 1 },
    "overwrite": { "type": "boolean", "default": false,
      "description": "Replace an existing user map with the same file name. Refused without it, mirroring DJ's confirm-overwrite flow." }
  }
}
```

Validates before install (schema + target compile), sanitizes the file stem,
reloads on success. Result JSON carries `{file, name, bindings, replacedFile, shadowsBundled}`.

**`midi.map.export`** - write a map's file body verbatim to a path outside the app dir.

```json
{
  "type": "object",
  "required": ["map", "outputPath"],
  "properties": {
    "map": { "type": "string", "minLength": 1, "description": "Map key (file stem or map name)." },
    "outputPath": { "type": "string", "minLength": 1 }
  }
}
```

This command writes outside the project, so it joins `MANAGE_COMMANDS` in
`registry.rs` (Manage tier, `confirm: true` required on the tool), exactly like
`export.master`. It is the only new Manage command; `midi.map.import` stays
Perform (it reads external and writes only app config, like `import.audio`;
its own `overwrite` flag is the destructive-path guard).

**`midi.reload`** - re-read bundled + user maps from disk and re-resolve every
connected port. No params. This is the "I hand-edited the JSON" affordance;
`binding.set`, `map.import`, and `device.select` already reload implicitly.

### 1.2 Count changes and every file that must change

New counts: catalog **78 -> 86** commands; command tools **77 -> 85** (nothing
new is excluded; `EXCLUDED_COMMANDS` stays `["gen.landed"]`); total MCP tools
**100 -> 108**. Command tools are generated 1:1 from the catalog by
`registry::tool_defs()`, so the eight tools (`studio_midi_device_select`,
`studio_midi_learn_start`, `studio_midi_learn_stop`, `studio_midi_binding_set`,
`studio_midi_binding_clear`, `studio_midi_map_import`, `studio_midi_map_export`,
`studio_midi_reload`) appear with no per-tool registry code; only the Manage
list and the count assertions change.

Exhaustive change list for the contract step (M1). Build-gated:

| File | Change |
|---|---|
| `engine/contracts/command-catalog.v1.1.json` | 8 command declarations (section 1.1) |
| `engine/timeline-core/src/cmd.rs` | 8 typed `Cmd` variants + `name()` arms (payload fields: `device: String`, `map/label: Option<String>`, `control/target/value_map: serde_json::Map` or `Value`, mirroring how `GenSong.request` carries open JSON) + doc-comment count |
| `engine/timeline-core/src/apply.rs` | one arm: all 8 variants -> `Ok(CmdEffect::unjournaled_noop())`, joined to the existing transport/record arm |
| `engine/timeline-core/src/catalog.rs:133` | `assert_eq!(cat.len(), 86)` |
| `engine/timeline-core/tests/conformance.rs:32,35` | 86 / 86 |
| `engine/timeline-core/tests/support.rs` | 8 representative envelopes in `representative_commands()` (valid params per section 1.1; also fix the stale "71-command" comment at line 2 while there) |
| `engine/agent-surface/tests/parity.rs:54,64-66` | 86 / 85 |
| `engine/agent-surface/src/registry.rs` | add `midi.map.export` to `MANAGE_COMMANDS`; count test at `:685-690` -> 85 + comment |
| `engine/docs/generated/mcp-tools.v1.json` | REGENERATE: `cargo run -p agent-surface --bin majiks-studio-cli -- tools --write engine/docs/generated/mcp-tools.v1.json` (note: `engine/docs/generated/`, not `docs/generated/`; the M1 scaffold had the wrong path) |

Doc text (not build-gated, same commit):

| File | Change |
|---|---|
| `engine/timeline-core/src/lib.rs:6` | "86 commands" |
| `engine/README.md:13,22,66,178,198` | 86 / 86 / 108 / 86 / 108 |
| `docs/AGENT_API.md:63,70` | "Total: 86 commands." / "all 108 tools" + a short midi.* family paragraph |
| `docs/MCP_API.md:17,21` | "Tool count: **108**" / "The 85 command tools..." |

The conformance suite's `catalog_undoable_and_inverse_flags_are_self_consistent`
passes untouched (false/false/none is self-consistent). M1 lands validation +
noop apply only; behavior is M2's.

---

## 2. Architecture: where MIDI lives and how an event becomes a command

```
CoreMIDI callback thread          midi pump thread (owns midir connections)      host lock
  (midir, per port)                "majiks-studio-midi", one per StudioHost
       |                                   |
  parse MidiEvent                          |
  try_send (bounded 1024) ---------------> drain
       |                                   |-- learn session open? offer + swallow
  (never blocks, never                     |-- resolver: match bindings
   allocates, no engine                    |     buttons: dispatch now
   work; DJ discipline)                    |     continuous: coalesce 33 ms latest-wins
                                           |-- substitute $value / $track:N
                                           |-- builtin? expand against DispatchCtx
                                           |-- sterling? push to trigger ring (snapshot)
                                           |-- command? sink.dispatch(envelope) ------> lock StudioHost
                                           |                                            host.submit(Actor::user("midi"),
                                           |                                                        name, params)
                                           |-- hotplug tick every ~1.5 s                 (validate -> journal -> apply ->
                                                (enumerate, connect mapped or             live mirror, the same path the
                                                 learn-open ports, prune gone,            UI and MCP take)
                                                 stale-index guard)
```

### 2.1 Ownership and the Send story (mirrors `record_input::LiveInput`)

- **`MidiState`** (new field on `StudioHost`, like `RecordState`): the host-side
  half. Holds `Arc<MidiShared>` and `Option<MidiPump>`. `#[derive(Default)]`
  so constructors add one line. The `midi.*` submit handlers mutate
  `MidiShared` (registry, overrides, learn, bindings) and never touch midir.
- **`MidiShared`**: `RwLock<MapRegistry>` (loaded maps + compiled resolvers),
  `Mutex<LearnSession>`, `Mutex<PortTable>` (port name, connected, resolved map,
  override, unsupportedReason), `Mutex<SterlingRing>` (section 8), last-event
  cell, `AtomicBool` enabled, the maps data dir. Shared by host and pump.
- **`MidiPump`**: the `Send` control-side handle. `Sender<PumpMsg>` (`Stop`,
  `Rescan`) + `JoinHandle`. `Drop` sends Stop and joins, so the midir
  connections die on the thread that made them. Compile-time regression test:
  `fn assert_send<T: Send>(); assert_send::<MidiPump>();` exactly like
  `record_input.rs:255`.
- The pump thread OWNS the `midir::MidiInput` connections for their whole life
  (DJ note ported: only one thread ever touches the manager, no Send/Sync
  juggling of connections). DJ used two threads (apply + hotplug); the DAW uses
  ONE: the drain loop `recv_timeout(15ms)` doubles as the coalesce tick, and a
  counter fires the hotplug enumeration every ~100 ticks (~1.5 s). MIDI resolve
  is microseconds of work; nothing here is realtime-critical the way the audio
  callback is.
- **Dispatch sink**: the pump is spawned with `Weak<Mutex<StudioHost>>`. Per
  prepared dispatch: upgrade, lock, `host.submit(Actor::user("midi"), name,
  params)`, log-and-drop on failure (a failed MIDI command must never wedge the
  pump). If the upgrade fails the host is gone and the loop exits.

### 2.2 Boot wiring (zero new FFI)

`agent_surface::midi::start_pump(host: &Arc<Mutex<StudioHost>>)`: installs the
bundled maps if absent, loads the registry, spawns the thread, stores the
`MidiPump` into `host.midi`. Idempotent (a second call is a no-op). Failure is
non-fatal and logged; the app runs without controllers (DJ `ensure_started`
discipline).

Call sites, all body-only changes to existing functions:
- `ffi.rs` `initialize(data_dir)`: after the host Arc exists.
- `mcp.rs` server boot: same, for headless MCP sessions.
- `bin/majiks-studio-cli` long-running modes (`serve`): same. One-shot CLI
  invocations skip the pump; `midi.*` config commands still work host-side.

Auto-connecting MIDI INPUTS at boot is deliberate and matches DJ ("controllers
just work"). It is input-only and silent; the record/live "nothing auto-opens a
device" rule is about audio devices, and stays intact. The kill switches are
per-port (`midi.device.select` map=none) and per-binding (`enabled: false`).

In-memory hosts (`StudioHost::in_memory()`) get `MidiState` with no pump and a
bundled-only registry; every `midi.*` command still validates and mutates
state, so pure unit tests need no threads and no CoreMIDI.

### 2.3 Event flow details ported from DJ

- Parse (`0x90/0x80/0xB0/0xE0`, NoteOn vel 0 -> NoteOff) ports verbatim from DJ
  `midi.rs` into `midi/event.rs`, including the `event_id` debounce key. The
  callback debounce stays 3 ms (DJ runtime's constructed value, not the 10 ms
  default).
- Port identity: connect by index, persist and match by NAME (override key =
  port name). The stale-index guard ports verbatim: a tracked index reporting a
  different name is disconnected and reconnected same tick (CoreMIDI reuses
  enumeration slots).
- The hotplug tick connects ports that resolve to a map, plus EVERY port while
  a learn session is open. Unsupported maps report once per appearance.
- `MAJIKS_MIDI_PORT_FILTER` env var ports verbatim: when set, only port names
  containing the value are considered. This is the hardware guard for the
  virtual test suites and MUST be honored by the pump's enumeration.

### 2.4 Journal pressure and coalescing

The DJ applier writes lock-free atomics and journals nothing, so it applies
every CC. Here every dispatch is a journaled bus command (`mix.gain` is
journaled + undoable). Policy:

- Buttons (noteOn/noteOff bindings, and CC bindings whose target has no
  `$value`): dispatch immediately, one command per press. Matches the UI.
- Continuous bindings: per-binding latest-value slot, flushed every 33 ms while
  changing, plus a final settle flush. A 2 s fader sweep journals ~60 `mix.gain`
  entries; undo steps through them like 60 drags. This is accepted for v1 and
  matches the honesty rule (every applied value is a real command). The UI
  fader journals once per drag gesture because a gesture has an end; a MIDI
  stream does not.
- Future refinement (NOT v1): wrap a continuous burst in `txn.begin`/`txn.commit`
  to make a sweep one undo unit. Blocked on a design answer for interleaving:
  a UI command submitted while the pump's txn is open would land inside the
  MIDI transaction. Do not build this until the journal grows txn tagging.

---

## 3. The Rust `midi_input` subsystem: module layout

New module tree in `engine/agent-surface/src/midi/` (agent-surface, not
timeline-core: it needs the host, the registry, and OS I/O, exactly like
`record_input.rs` and `live.rs`; timeline-core stays pure):

| Module | Contents | Ported from |
|---|---|---|
| `midi/mod.rs` | `MidiState`, `MidiShared`, `start_pump`, submit-handler entry (`apply_midi(name, params)` routed from `host.submit`), snapshot builder `midi_json()` | glue (new) |
| `midi/event.rs` | `MidiEvent` enum + `from_bytes` + `event_id` | DJ `midi.rs:10-116` |
| `midi/map.rs` | serde model: `MidiMap`, `Binding`, `ControlMatch`, `Target`, `ValueMap`; JSON schema validation; `match_specificity` port | DJ `midi_mapping.rs` (schema parts) |
| `midi/registry.rs` | `MapRegistry`: bundled `include_str!` install, `load_all`, resolve precedence, import/export, override store (`midi-settings.json`) | DJ `midi_config.rs`, `midi_runtime.rs` resolve |
| `midi/resolve.rs` | `CompiledResolver`: event match -> `Prepared` dispatches; `ValueMap::map_value` (linear/exponential/logarithmic); placeholder substitution; builtin expansion against `DispatchCtx` | DJ `midi_mapping.rs` (match/extract), new (placeholders, builtins) |
| `midi/learn.rs` | `LearnSession` (host-owned, NOT a process-global like DJ's): start/offer/captured/stop, descriptor JSON with `valueShape` (button / continuous / bipolar14) | DJ `midi_learn.rs`, de-globalized |
| `midi/pump.rs` | the thread: midir ownership, hotplug tick, drain, coalesce, sink dispatch | DJ `midi.rs` manager + `midi_runtime.rs` loops, merged to one thread |

Crate additions: `midir = "0.9"` to `engine/agent-surface/Cargo.toml`
(dependency of the DJ lane already; input-only usage). No new crate in
timeline-core.

`host.rs` changes: `midi: MidiState` field (one line per constructor);
`submit()` gains one match arm:

```rust
// MIDI: validate on the bus (unjournaled no-op at the model layer), then run
// the host-side config effect. Mirrors the record.* routing exactly.
name if name.starts_with("midi.") => {
    self.bus_submit(actor, name, params.clone())?;
    self.midi.apply(name, &params)
}
```

plus `root.insert("midi", self.midi.snapshot_json())` in `snapshot()`
(section 6).

Resolver purity rule (the DJ lesson that makes everything testable): resolve
touches NO engine state. Everything stateful it needs arrives in a
`DispatchCtx` snapshot the pump captures under one short host lock per flush
tick (or that a test fabricates):

```rust
pub struct DispatchCtx {
    pub playing: bool,
    pub recording: bool,
    pub metronome: bool,
    pub armed_track_id: Option<String>,   // first armed track
    pub track_ids: Vec<String>,           // ordered, for $track:N
    pub track_gains_db: Vec<f64>,         // for mix.gain.nudge
}
```

`resolve(event, &ctx) -> Vec<Prepared>` where
`Prepared = Command { name, params } | Sterling { instruction, binding_id }`.
Table-driven tests feed events + a fabricated ctx and assert exact envelopes.

---

## 4. Persistence

- Maps dir: `<data_dir>/midi-maps/*.json`, where `data_dir` is
  `StudioHost::data_dir()` (the directory `.mstudio` packages live under, i.e.
  Application Support/MajiksMusicStudio). App-level, shared across projects,
  exactly like DJ's `<app_data>/midi-mappings/`. NOT inside the `.mstudio`
  package: bindings are hardware+user config, not project content, and must not
  ride project export/import.
- Overrides + subsystem settings: `<data_dir>/midi-settings.json`:
  `{ "overrides": { "<port name>": "<mapKey>|none" } }` (absent port = auto).
  A tiny JSON file instead of DJ's SQLite settings table; the DAW engine has no
  settings DB and does not want one for this.
- Bundled defaults: `engine/agent-surface/assets/midi-maps/sx-kc211.json` and
  `generic-controller.json`, embedded with `include_str!` (the
  `sterling-system.md` / catalog precedent), installed copy-if-absent on first
  pump start. User files are never overwritten. (DJ's SHA-256
  superseded-refresh for updated bundled maps is a follow-up, noted in
  midi-tasks.md; with two maps and no shipped installs yet, copy-if-absent is
  correct today.)
- `midi.binding.set` persistence semantics are DJ's learn-assign: write the
  resolved USER file (create `<stem>-user.json` copying the bundled map when
  needed; brand-new `<sanitized-port>.json` for unknown hardware), managed
  header comment field noting the file is tool-rewritten, then reload.
- In-memory hosts (no data_dir): registry = bundled + in-session edits, no file
  writes; `midi.map.import/export` return a clean error naming the reason.

---

## 5. The map format (`midi-map.v1`)

JSON, one file per device family. Full example (this is also the shape the
snapshot echoes under `midi.maps[].bindings`):

```json
{
  "version": 1,
  "name": "SX-KC211 (Studio)",
  "device": { "namePatterns": ["kc211", "usb midi interface"] },
  "author": "Magic Unicorn",
  "tested": true,
  "sourceUrl": "https://... (vendor manual or DJ doc)",
  "unsupportedReason": null,
  "bindings": [
    {
      "id": "play-toggle",
      "label": "Play / Stop",
      "match": { "type": "noteOn", "channel": 0, "number": 36 },
      "target": { "kind": "builtin", "name": "transport.toggle" },
      "enabled": true,
      "comment": "C2, bottom key"
    },
    {
      "id": "t1-gain",
      "label": "Track 1 gain (CC fader)",
      "match": { "type": "controlChange", "channel": 0, "number": 21 },
      "target": { "kind": "command", "name": "mix.gain",
                  "params": { "trackId": "$track:0", "gainDb": "$value" } },
      "valueMap": { "inputMin": 0, "inputMax": 127,
                    "outputMin": -60, "outputMax": 12, "curve": "linear" }
    },
    {
      "id": "sterling-tighten",
      "label": "Sterling: tighten the selection",
      "match": { "type": "noteOn", "channel": 0, "number": 60 },
      "target": { "kind": "sterling",
                  "instruction": "Revise the selected region: keep the parts, make the timing tighter." }
    }
  ]
}
```

### 5.1 Fields

- `version`: literal 1. Loaders accept only 1 for now.
- `name`: display name (DJ `device_name`). Also a map key for
  `midi.device.select` / `midi.map.export`, alongside the file stem.
- `device.namePatterns`: case-insensitive plain substrings matched against the
  reported port name; any hit selects the map; the longest hit is the
  specificity. Ported from DJ v3 `[device] name_patterns` including the rule
  that this list is the ONLY matcher when non-empty. No regex. DJ's legacy
  scalar `match_pattern` and the >3-char device-name token fallback are ported
  as translation-time conversion only (section 5.4); the DAW format has one
  matcher field.
- `tested`, `author`, `sourceUrl`, `unsupportedReason`: verbatim DJ semantics.
  A map with `unsupportedReason` never auto-loads; the port row reports it.
- `bindings[]`: `id` (stable slug, unique per map; minted from the label when
  absent), `label`, `match`, `target`, `valueMap?`, `enabled` (default true),
  `comment?`.
- `match.type`: `noteOn | noteOff | controlChange | pitchBend` (camelCase; DJ's
  snake_case translates). `channel` 0-15 wire. `number` required except
  pitchBend.

### 5.2 Targets, values, placeholders

`target.kind = "command"`: `name` must be a catalog command; `params` is the
wire params template. Two placeholders, both string literals in the template:

- `"$value"`: replaced with the mapped continuous value as a JSON number.
  Sources: CC value, note velocity, or normalized pitch bend, passed through
  `valueMap` (defaults 0..127 -> 0..1 linear). Integer-typed schema slots get
  the value rounded.
- `"$track:N"`: replaced with the id of the Nth track (0-based, current
  project order) at dispatch time. A binding that references a missing index
  no-ops with a logged note (band on a 2-track project).

Load-time compile: every command target is validated by substituting probe
values and running `catalog::validate_params`. A map with an invalid target
fails to load (file kept, error surfaced in the snapshot's map row and the
`midi.reload` result), so typos surface at load, not at the first keypress.
`gen.*`, `txn.*`, `project.new/open`, and `studio.importStemSession` are
rejected as binding targets at compile time (async request protocols and
lifecycle verbs need arguments a key press cannot mint; Sterling triggers are
the right way to reach generation from hardware).

`target.kind = "builtin"`: section 5.3. `params` allowed where documented.

`target.kind = "sterling"`: `instruction` is the exact text queued (section 8).

### 5.3 Builtins (closed set)

Builtins exist because a stateless envelope cannot express a toggle and a
key press cannot carry a fader's current position. Each builtin reads
`DispatchCtx` and emits ordinary catalog envelopes (or host undo/redo), so the
journal only ever shows real commands. The set is CLOSED; adding one is a
design change, not a map edit:

| name | ctx read | effect |
|---|---|---|
| `transport.toggle` | `playing` | emit `transport.stop` when playing, else `transport.play` |
| `record.toggle` | `recording`, `armed_track_id` | recording: emit `record.stop`. Not recording: `record.start {trackId: armed}`; no armed track -> no-op with note |
| `metronome.toggle` | `metronome` | emit `transport.metronome {enabled: !current}` |
| `undo` | none | `host.undo(Actor::user("midi"))` |
| `redo` | none | `host.redo(Actor::user("midi"))` |
| `mix.gain.nudge` | `track_gains_db` | params `{trackId | "$track:N", deltaDb}`; emit `mix.gain {trackId, gainDb: clamp(current + deltaDb, -60, 12)}` |

### 5.4 Translating DJ TOML maps

Mechanical translation table (M4 applies it to the SX-KC211 map; other DJ maps
translate only if their actions have DAW analogs):

| DJ TOML | DAW JSON |
|---|---|
| `device_name` | `name` |
| `[device] name_patterns` | `device.namePatterns` |
| `match_pattern` `"a|b"` | `device.namePatterns: ["a", "b"]` |
| neither present | `namePatterns` from >3-char tokens of `device_name` (translation bakes the fallback in; the DAW loader has no fallback) |
| `version`, `author`, `tested`, `source_url`, `unsupported_reason` | `version: 1`, `author`, `tested`, `sourceUrl`, `unsupportedReason` |
| `[[mappings]] event_type` snake_case | `match.type` camelCase |
| `channel`, `note_or_cc` | `match.channel`, `match.number` |
| `action = {type = "..."}` | `target` per the action translation below |
| `value_mapping` | `valueMap` (field names camelCase) |
| `enabled`, `label`, `comment` | same |
| `deck` | DROPPED (no decks; track-scoped targets name `$track:N` or a trackId) |
| `shift_layer`, `jog_mode` | DROPPED v1 (no shift layers; no jogs). Translation warns and skips the binding |
| `[[led_feedback]]`, `[[display]]` | DROPPED (MIDI OUT; out of scope, section 9) |

DJ action -> DAW target for the actions the DAW has analogs for:
`PlayPause -> builtin transport.toggle`; `Play -> transport.play`;
`Pause/Stop -> transport.stop`; `SetMasterVolume -> mix.master.gain` with
`valueMap` outputs in dB; `SetVolume (deck) -> mix.gain {trackId: $track:N,
gainDb: $value}`; `SeekAbsolute -> transport.seek` (valueMap output 0..project
length is not expressible statically, so translation maps it to seek-to-zero
with a warning); DJ-only actions (cues, sync, keylock, stems, FX, jog, browse,
clip pads) have no DAW analog and translate to a commented-out binding the user
can rebind via Learn. The SX-KC211 DJ map (16 keys -> sampler pads) is NOT
meaningful in the DAW; M0 ships a purpose-designed Studio map instead
(section 5.5), and the translation table exists for future controller maps
with real transport/fader surfaces.

### 5.5 The SX-KC211 first map (bundled)

Keys only (finding 3). Wire channel 0. Zones, bottom octave up:

| Key | Note | Binding |
|---|---|---|
| C2 | 36 | builtin `transport.toggle` |
| C#2 | 37 | builtin `record.toggle` |
| D2 | 38 | `transport.seek {positionTicks: 0}` (return to start) |
| D#2 | 39 | builtin `metronome.toggle` |
| E2 | 40 | builtin `undo` |
| F2 | 41 | builtin `redo` |
| F#2 | 42 | `transport.loop.clear` |
| G2 | 43 | `transport.stop` (hard stop) |
| C3/D3 | 48/50 | track 1 gain nudge -1 dB / +1 dB (builtin `mix.gain.nudge`, `$track:0`) |
| E3/F3 | 52/53 | track 2 gain nudge -/+ 1 dB (`$track:1`) |
| G3/A3 | 55/57 | track 3 gain nudge -/+ 1 dB (`$track:2`) |
| B3 | 59 | unmapped (reserved) |
| C4 | 60 | Sterling: "Revise the selected region. Keep the arrangement, tighten the timing." |
| D4 | 62 | Sterling: "Add a complementary layer that fits the current section." |
| E4 and up | 64+ | unmapped, reserved (future MIDI note recording and user Learn bindings) |

`namePatterns: ["kc211", "usb midi interface"]` (the cable-name trade-off is
inherited from DJ and documented in the map's comment field). `tested: false`
until Aaron confirms on hardware (flip to true in the attended pass).

Design note: `track.mute` and `track.solo` take absolute booleans, so a single
key cannot toggle them without a builtin. v1 keeps the builtin set minimal;
mute/solo toggles are listed in midi-tasks.md as candidate builtin follow-ups
if Aaron wants them on keys (cheap to add: same shape as `metronome.toggle`).

A second bundled map, `generic-controller.json` (`tested: false`,
`namePatterns: []` so it never auto-loads and exists as a Learn/pin starting
point): transport builtins on noteOn 60/62/64 ch 0, master gain on CC 7,
track 1 gain on CC 21, all with comments saying "pin this map to your port,
then relearn the controls that differ".

---

## 6. Snapshot additions

`snapshot()` gains one top-level key beside `audioInputs`:

```json
"midi": {
  "enabled": true,
  "ports": [
    { "name": "USB MIDI Interface", "connected": true,
      "map": "SX-KC211 (Studio)", "mapKey": "sx-kc211", "source": "bundled",
      "tested": false, "unsupportedReason": null, "override": null }
  ],
  "maps": [
    { "key": "sx-kc211", "name": "SX-KC211 (Studio)", "source": "bundled",
      "tested": false, "bindingCount": 16, "loadError": null }
  ],
  "activeBindings": [
    { "port": "USB MIDI Interface", "id": "play-toggle", "label": "Play / Stop",
      "match": { "type": "noteOn", "channel": 0, "number": 36 },
      "target": { "kind": "builtin", "name": "transport.toggle" },
      "targetSummary": "Play / Stop toggle", "enabled": true }
  ],
  "learn": {
    "active": false, "device": null, "ageSeconds": null,
    "captured": null,
    "current": null
  },
  "lastEvent": { "seq": 412, "port": "USB MIDI Interface",
                 "type": "noteOn", "channel": 0, "number": 36, "value": 96 },
  "sterling": { "nextSeq": 3, "pending": [
    { "seq": 2, "instruction": "Add a complementary layer...",
      "bindingId": "sterling-layer", "port": "USB MIDI Interface" }
  ] }
}
```

- Learn `captured`/`current` carry the DJ descriptor shape: `{device, type,
  channel, number, value, valueShape}` with `valueShape` in `button |
  continuous | bipolar14`. `captured` is the not-yet-consumed capture;
  `current` is what `midi.binding.set` binds by default. The Swift tab and MCP
  agents poll the snapshot for this (DJ's separate `next` poll call is not
  ported; the snapshot IS the poll).
- `lastEvent` (bounded to the single latest, with a monotonic `seq`) powers a
  MIDI-monitor line in the tab and makes "is the cable alive" debuggable
  without a learn session.
- `sterling.pending` is the trigger ring (section 8). Bounded (16); consumers
  keep a client-side cursor against `seq` and never ack.
- Everything is cheap clones of small state under the existing host lock;
  build shape mirrors `transport_json()`.

The read surface (`readSurface` in the catalog contract) is NOT extended in
v1: `project.snapshot` already carries the block, and adding a dedicated
`midi.state` read tool would change the tool count for no consumer. Noted as
follow-up if agents want a narrower read.

---

## 7. Swift: Settings MIDI tab and model

### 7.1 Placement and engine access

- The tab joins the app Settings window: `SettingsView.swift`, new
  `MidiSettingsView().tabItem { Label("MIDI", systemImage: "pianokeys") }.tag(6)`.
  The window's sibling tabs are stock SwiftUI `Form`/`Section`; the MIDI tab
  uses the same idiom for chrome consistency (StudioTokens accents only for
  state color: learn pulse, connection dots). This resolves the M3 scaffold's
  "match StudioTokens" against the reality that the Settings window is the
  legacy shell: form idiom from the window, accent colors from the tokens.
- Engine seam (the one structural Swift change): today the engine instance is
  created inside the Studio tab (`StudioEngineFactory.makeDefault()` ->
  `StudioViewModel`). The MIDI tab must drive the SAME instance. M3 introduces
  `StudioEngineHub` (a lazy app-level holder returning the one
  `any StudioEngineProtocol`; `StudioViewModel` and `MidiSettingsView` both
  take it). No FFI change; pure Swift ownership hoist. Keep
  `--studio-project` and mock/real selection behavior identical.
- Polling: the tab runs its own light poll while visible, 2 Hz,
  `engine.snapshot(ifNewerThan: nil)` (learn needs sub-second echo; 2 Hz
  matches DJ's 1 Hz settings poll plus the 4 Hz learn sheet compromise).
  The Studio tab's 30 Hz poll is untouched.

### 7.2 Model additions (`StudioEngineModel.swift`)

Snapshot structs, mirroring the section 6 shapes:
`StudioMidiPort`, `StudioMidiMap`, `StudioMidiBinding` (with nested
`StudioMidiControl`, `StudioMidiTarget` enum: command/builtin/sterling),
`StudioMidiLearnState`, `StudioMidiLastEvent`, `StudioMidiSterlingItem`, all
under `StudioMidiSnapshot`, added as `var midi: StudioMidiSnapshot?` on
`StudioProjectSnapshot` (optional so existing constructors compile, the
`inputDevices` precedent).

Commands: MIDI verbs go through a generic envelope case instead of eight
bespoke enum cases. `StudioEngineCommand` gains ONE case:

```swift
/// Generic catalog envelope for config-plane verbs (midi.*). The typed cases
/// stay for timeline/mixer verbs the UI builds from geometry; config verbs
/// carry ready wire params.
case catalog(name: String, params: [String: AnyHashable])
```

with `catalogName` returning `name`. `RealStudioEngine.route` maps it to
`try submit(name, params)`. This keeps the enum from growing eight
parameter-free wrappers and gives the tab (and future config UIs) a clean
generic path; the bus validates params server-side either way. The mock
handles the same case by string-switching on the midi names.

### 7.3 Tab UX (DJ `MidiSettings.swift` is the pattern)

Sections in order:

1. **Ports**: one row per `midi.ports[]`: connection dot, port name, subtitle
   (resolved map + source badge + tested badge, or unsupportedReason in warn
   color, or "No mapping"). Trailing `Picker` (Auto / None / divider / every
   map name) driving `midi.device.select`. Footnote explains precedence.
   Empty state: "No MIDI inputs present. Hot-plug scans every 1.5 s."
2. **Maps**: one row per `midi.maps[]`: name, source badge (BUNDLED none /
   USER / CUSTOMIZED), tested badge, bindingCount, loadError in warn color,
   Export button (NSSavePanel -> `midi.map.export`). Row actions bar: Import
   (NSOpenPanel .json -> `midi.map.import`, on "confirm overwrite" error show
   the replace alert and retry with `overwrite: true`, DJ flow), Reveal Maps
   Folder, Reload (`midi.reload`).
3. **Bindings** (selected port's active map): table of `activeBindings`:
   control (monospaced "noteOn ch0 #36"), label, target summary, enabled
   toggle (`midi.binding.set` with same control re-sent), Clear
   (`midi.binding.clear`). Sterling rows show the instruction in an editable
   text field; commit re-sends `midi.binding.set` with the new instruction
   (M5 wires the cell; M3 lands the table).
4. **Learn**: inline flow, not a separate window. Arm button ->
   `midi.learn.start {device: selectedPort?}`; live status from
   `midi.learn` (pulsing dot + "Move ONE control..."); captured descriptor
   renders monospaced (`noteOn - ch 0 - #36 - button`); assign picker: builtin
   list / command picker (curated common commands + free-form name + params
   editor for advanced) / Sterling instruction field; Assign sends
   `midi.binding.set` (no `control` field: binds the captured one); the flow
   re-arms after assign (DJ behavior). Close/stop sends `midi.learn.stop`.
   The curated command list for v1: transport.play/stop/seek-to-0,
   loop.clear, metronome (via builtin), record toggle (builtin), undo/redo
   (builtin), mix.gain nudges, mix.master.gain, track.arm.
5. **Monitor**: one line rendering `lastEvent` ("noteOn ch0 #36 vel 96 on USB
   MIDI Interface") so a dead cable is diagnosable at a glance.

Copy: plain and factual. No em-dashes, no marketing-speak (house rule).

### 7.4 Real parse (`RealStudioEngine.swift`)

`buildSnapshot` parses the `midi` block. Array-of-objects casting uses the
established gotcha-safe pattern: `(root["midi"] as? [String: Any])` then
`(midi["ports"] as? [Any])?.compactMap { $0 as? [String: Any] }`, never
`.array(...)`. Missing block -> `midi: nil` (older engine builds stay
compatible).

### 7.5 Mock (`StudioMockEngine.swift`)

Recording-precedent state: `mockMidiPorts = ["SX-KC211 Keyboard (USB MIDI Interface)"]`,
a bundled-shaped map list, an in-memory bindings array seeded with the
SX-KC211 zone map, learn state. Behavior: `.catalog(name:params:)` cases for
the eight midi verbs mutate state and bump `revision`; `midi.learn.start` sets
learn active and schedules a fake capture (noteOn ch0 #36 vel 96) after ~1.2 s;
`binding.set/clear` edit the array; import/export return ok. While learn is
active the freshness gate stays live (same clause as `recording`) so the tab
animates. The whole tab is demoable with no hardware and no xcframework: M3's
acceptance runs on the mock.

---

## 8. Sterling triggers (the novel part) and provenance

### 8.1 Dispatch design

A `sterling` binding cannot call `Copilot::send` from the pump: the engine has
no `CopilotConfig` (endpoint/model/key live in Swift's UserDefaults + Keychain
and cross the FFI per call; finding 5). Caching credentials engine-side just to
fire from the pump would invent a second config store and a staleness bug.
Instead the trigger rides the snapshot, and Sterling's EXISTING entry points
stay the only entry points:

1. Pump resolves a sterling binding -> pushes `{seq, instruction, bindingId,
   port, firedAtMonotonic}` into `MidiShared.SterlingRing` (bounded 16,
   monotonic seq, oldest dropped).
2. Snapshot exposes it as `midi.sterling.pending` (section 6).
3. The Swift copilot model (`StudioCopilotModel`) keeps a cursor: on first
   sight it sets `cursor = nextSeq` (never replays triggers from before this
   app session), then for each newer item submits the instruction through its
   normal `backend.send(text)` path, i.e. `copilot_send` with the user's
   configured endpoint/model/key, and shows the turn in the dock like a typed
   instruction, prefixed in the transcript ("MIDI trigger: <label>").
4. If Sterling is unconfigured or the backend is `DisabledCopilotBackend`
   (mock build), the dock surfaces "MIDI trigger ignored: Sterling is not
   configured" once per item. Items age out of the ring regardless.

Consequences, stated plainly: triggers need the app (some Sterling face)
running and polling; a headless engine with only the MCP server does not fire
Sterling turns from MIDI (an MCP agent session IS the engineer in that
context). Latency is bounded by the Studio poll (30 Hz) or the dock's poll,
well under a second. No ack command is needed: the ring is bounded, the cursor
is client-side, and replay on relaunch is prevented by the cursor
initialization rule. This is one new bounded buffer instead of a parallel
Sterling entry path, which is exactly what the M5 scaffold asked ("reuse the
existing Sterling entry point; do not invent a parallel one").

### 8.2 Provenance

Origin is carried by the existing two-layer machinery; nothing new is
invented:

- Every command a human's MIDI control dispatches is journaled with
  `Actor { kind: User, name: "midi" }` (the pump's sink stamps it; one call
  site). Undo/redo builtins pass the same actor. Journal readers can tell
  hardware-driven edits from pointer-driven ones (`user/majiks-studio` vs
  `user/midi`) without any schema change.
- A recorded take stays human: the `record.*` landing path already writes
  `gen.landed` with `sourceCommand: "record.commit"` under `Actor::user("record")`,
  which `export.rs` classifies `ClipOrigin::Recorded`. MIDI pressing
  `record.toggle` changes nothing about that classification. So: MIDI a person
  plays = human origin, stamped where it always was (the record landing and
  the envelope actor).
- A Sterling trigger's resulting work is agent origin: the turn runs through
  `Copilot` which stamps every tool call `Actor { kind: Agent, name: "sterling" }`
  (`copilot.rs:66-71`), and landed generations classify
  `ClipOrigin::Generated` in the export manifest. The human pressed the
  button; the agent authored the edit; the journal shows exactly that (no
  journaled command carries the press itself, because the press produced no
  bus command; the dock transcript carries the "MIDI trigger" prefix for the
  human-readable trail).
- Future agent-PLAYED MIDI (an agent synthesizing performance input) is out of
  scope v1; the seam is the actor: such a path must not use
  `Actor::user("midi")`. Called out in midi-tasks.md so M5 leaves the actor
  parameterized in the sink, defaulting to user/midi.

---

## 9. Audio and MIDI-out safety

- MIDI INPUT ONLY. `midi/` imports `midir::MidiInput` and never
  `midir::MidiOutput`. Guard: a compile-boundary test in `midi/pump.rs` module
  docs plus a repo grep in review; virtual-input TESTS may use `MidiOutput`
  solely to create virtual SOURCES (a CoreMIDI port, not sound).
- No audio path: the subsystem never touches `render::` stream code. Dispatched
  transport commands on a non-live host move the tracked view only (finding 4).
  The pump never calls `start_live`. Tests never set `MAJIKS_TEST_AUDIBLE`.
- LED feedback / on-device displays (MIDI OUT) are explicitly out of scope for
  this wave; the map format deliberately has no fields for them (dropped in
  translation), so scope cannot creep in through map files.

---

## 10. FFI safety statement (checkable)

Claim: the whole port adds ZERO UniFFI symbols and leaves the generated
bindings byte-identical.

Why it holds by construction:
- All eight commands enter through the existing generic envelope path:
  Swift `EngineClient.submit(name:params:)` -> `MajiksEngine.command(envelopeJson:)`
  -> `host.submit`. MCP agents reach the same eight as auto-generated command
  tools through the existing `tool()`/HTTP dispatch. No new exported fn.
- All reads ride the existing `snapshot(sinceSeq:)` (one new JSON key).
- The pump boots inside the BODIES of existing exported fns
  (`initialize`, `mcp_start`) and a CLI main; signatures untouched.
- Swift model/tab changes are pure Swift.

How M1/M2/M3 verify (each lands the relevant check):
1. `cargo test -p agent-surface -p timeline-core` green (parity, conformance,
   coverage, regen check).
2. `grep -rn "#\[uniffi::export\]" engine/agent-surface/src/` produces the same
   two blocks (`ffi.rs`) with the same fn list as `main` (no additions).
3. Real build only: regenerate bindings and `git diff --stat
   src/swift/Sources/Engine/Generated/` is empty, and
   `nm <MajiksEngine binary> | grep -c agent_surface` still reports **660**
   (the count from 00-CONSTRAINTS; it lives in the built artifact, not in the
   repo, so mock-only lanes cite checks 1-2 and the coordinator runs check 3).

---

## 11. Testing strategy (M2/M4 implement; listed here so the wave shares one map)

Tier 1, pure (no threads, no CoreMIDI, always on):
- `midi/resolve.rs` tables: every SX-KC211 binding feeds a synthetic event +
  fabricated `DispatchCtx` and asserts the exact envelope (name + params JSON)
  or sterling instruction. Curve math ports DJ's ValueMapping tests. Builtin
  branch coverage (playing/stopped, armed/unarmed, gain clamp edges).
  Placeholder substitution incl. missing-track no-op.
- `midi/map.rs`: serde round-trips, validation failures (bad channel, unknown
  target command, bad placeholder), DJ-translation fixtures.
- `midi/registry.rs`: bundled install copy-if-absent, user-beats-bundled,
  longest-pattern, override precedence incl. dangling override fallback,
  unsupported maps never load (all ported DJ test intents).
- `midi/learn.rs`: start/offer/capture/consume/stop state walk.

Tier 2, host integration (in-memory host, no pump):
- `midi.*` submit round-trips: binding.set -> snapshot shows it; device.select
  persists + re-resolves; import/export round-trip on a temp data_dir; reload
  picks up an on-disk edit; every command rejects bad params via the bus
  schema (proving M1's contract wiring).

Tier 3, virtual end-to-end (`#[ignore]`, evidence runs; DJ pattern):
- `engine/agent-surface/tests/midi_virtual.rs`: set
  `MAJIKS_MIDI_PORT_FILTER=majiks-test` BEFORE the pump starts (hardware
  guard), create a CoreMIDI virtual source `majiks-test kc211` via
  `midir::os::unix::VirtualOutput` (test-side only), spawn the pump on an
  `Arc<Mutex<StudioHost>>`, wait for auto-resolve, send note 36 on/off, assert
  the tracked transport flipped and the journal grew a `transport.play` from
  `user/midi`; send a sterling-bound note and assert the ring item. No audio
  device, no `Silence` guard needed (finding 4), which makes this STRONGER
  than DJ's equivalent: it can run on a headless mac with no output device.

Swift (M3): mock learn flow (arm -> fake capture -> assign -> binding appears),
snapshot round-trip for the midi block, generic `.catalog` routing test.

---

## 12. Corrections to the scaffold prompts (M1-M5 authors read this)

1. Command set is EIGHT, not ten: `midi.map.load` and `midi.map.save` are
   dropped (absorbed by `midi.device.select` and `midi.binding.set`
   persistence). All midi.* are transport-class (unjournaled, non-undoable),
   overriding M1's "map mutations are likely journaled/undoable" guess.
2. The generated-manifest path is `engine/docs/generated/mcp-tools.v1.json`
   (M1 scaffold said `docs/generated/...`; the regen command in section 1.2 is
   copy-paste correct).
3. `docs/MCP_API.md` lines 17 and 21 are count sites the scaffold missed.
4. MIDI-Learn has no `next` command: the snapshot carries the captured
   descriptor; UIs poll the snapshot.
5. The Settings tab lives in the app `SettingsView` TabView (tag 6) using the
   window's stock form idiom with StudioTokens accent colors only; it is not a
   StudioTokens panel inside the Studio lane.
6. Sterling triggers dispatch via the snapshot ring + the Swift copilot model's
   existing `backend.send` path, NOT via an engine-side `Copilot::send` call
   (the engine has no CopilotConfig; section 8.1).
7. The `StudioEngineCommand` enum gains ONE generic `.catalog(name:params:)`
   case for the midi verbs, not eight bespoke cases.
8. Coalescing policy for continuous bindings (33 ms latest-wins + settle
   flush) is part of M2's acceptance, not optional.
