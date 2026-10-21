# MIDI control surface: build wave (M1-M5, refined by M0)

This breakdown SUPERSEDES the scaffold task bodies in the dispatch pack
(`~/Documents/majiks-studio-daw/delegation-prompts/05..09`). The design spec is
`docs/design/midi-control-surface.md` in this repo; where a scaffold prompt and
the spec disagree, the spec wins (section 12 lists the known deltas). House
rules still apply: `00-CONSTRAINTS.md` (fresh clones, never Studio Storage,
MIDI input only, no new FFI without a loud flag, branch + push, no self-merge).

## Order of play

```
M1 contract (Frontier, ~2h)          M4a map assets (Medium-Local, ~1h)
      |                                    |            (only needs the spec)
      v                                    |
M2 engine (Bleeding-Edge, ~8h)  <---- consumes M4a's two JSON maps
      |
      +----------------+----------------+
      v                v                v
M3 Swift tab      M4b map tests     M5 Sterling triggers
(Frontier, ~5h)   (Medium-Local,    (Frontier, ~3h)
      |            ~2h)                  |
      +---------------------------------+
                      |
                      v
        M5 UI cell rides on M3's binding table
        (M5 engine half only needs M2)
```

- Dispatch NOW, in parallel: **M1** and **M4a**.
- **M2** starts when M1 merges (it implements the handlers M1 declared) and
  embeds M4a's map files (or M0's appendix versions if M4a lags; they are in
  the spec verbatim).
- **M3**, **M4b**, **M5-engine** run in parallel once M2 merges.
- **M5-UI** (the Sterling instruction cell) lands after M3; if the same agent
  takes M5 it can ship the engine half first and rebase the cell onto M3.
- Serial critical path: M1 -> M2 -> (M3 | M5). Everything else parallelizes.

Branch names: `feat/midi-contract`, `feat/midi-engine`, `feat/midi-maps`,
`feat/midi-settings-ui`, `feat/midi-sterling-triggers`.

---

## M1 - contract: 8 midi.* commands + parity (Frontier, Medium context)

Spec sections: 1.1 (commands, schemas, tiering), 1.2 (exhaustive file list and
counts), 12 (corrections).

Do: declare the eight commands in `command-catalog.v1.1.json` exactly as
specced; typed `Cmd` variants + `name()` arms; the joined
`unjournaled_noop()` apply arm; coverage-table reps; count updates
(86 / 85 / 108) across catalog.rs, conformance.rs, support.rs, parity.rs,
registry.rs; `midi.map.export` into `MANAGE_COMMANDS`; regenerate
`engine/docs/generated/mcp-tools.v1.json` (exact command in spec 1.2); doc
count edits (lib.rs, cmd.rs, README, AGENT_API, MCP_API).

Accept: `cargo test -p agent-surface -p timeline-core` green; manifest
regenerated and committed; no behavior beyond validate+noop; zero new
`#[uniffi::export]` fns (grep check, spec section 10).

## M2 - engine: midi subsystem + pump + dispatch (Bleeding-Edge, Large context)

Spec sections: 2 (architecture, ownership, coalescing), 3 (module layout,
DispatchCtx, resolver purity), 4 (persistence), 5.2-5.3 (placeholders,
builtins), 6 (snapshot block), 9 (safety), 11 (test tiers 1-3).

Do: the `engine/agent-surface/src/midi/` module tree as laid out in spec
section 3 (`event/map/registry/resolve/learn/pump` + mod glue); `MidiState` on
`StudioHost` + the `midi.*` submit routing arm + `midi` snapshot key;
`start_pump` wired into `initialize`, `mcp_start`, and CLI serve bodies;
`midir = "0.9"` dep; bundled maps embedded + installed copy-if-absent;
overrides in `midi-settings.json`; the six builtins; 33 ms coalescing with
settle flush; the Sterling ring (the ring itself is M2; consuming it is M5);
`Actor::user("midi")` on the sink (actor parameterized, spec 8.2).

Tests: tier 1 pure resolver/map/registry/learn suites; tier 2 in-memory host
round-trips; tier 3 `#[ignore]` virtual end-to-end with the
`MAJIKS_MIDI_PORT_FILTER` hardware guard (spec 11). Run the tier 3 suite once
locally and paste its output in the PR (evidence discipline).

Accept: all M1 tests still green plus the new suites; `MidiPump` has the
compile-time `assert_send` test; no `midir::MidiOutput` import outside test
code; no audio-path contact (`render::` streams untouched); zero new FFI;
snapshot carries the full section 6 block.

## M3 - Swift: MIDI settings tab + model + mock (Frontier, Medium context)

Spec section 7 (placement, engine hub, model additions, tab UX, parse gotcha,
mock behavior), 12.5/12.7.

Do: `StudioEngineHub` ownership hoist (one engine instance shared by the
Studio tab and Settings); `MidiSettingsView` as SettingsView tag 6 with the
five sections (Ports / Maps / Bindings / Learn / Monitor); snapshot structs +
the ONE generic `.catalog(name:params:)` command case; `RealStudioEngine`
midi-block parse (compactMap pattern); `StudioMockEngine` midi state + fake
learn capture so the tab fully demos with no hardware.

Accept: on the MOCK engine: tab renders ports/maps, learn arms and captures,
assign creates a visible binding, table edits/clears/toggles, import/export
round-trip (mock ok), monitor line updates; Swift build + tests green
(`swift build && swift test` in `src/swift`); snapshot round-trip + learn-flow
tests added; zero FFI change; copy has no em-dashes.

## M4 - maps + table-driven tests (Medium-Local, Medium context; two halves)

Spec sections 5.4 (translation table), 5.5 (SX-KC211 zones + generic map),
11 tier 1.

M4a (dispatch with M1, needs only the spec): author
`engine/agent-surface/assets/midi-maps/sx-kc211.json` and
`generic-controller.json` exactly per spec 5.5 (SX-KC211 is note-zone based;
the keyboard's keys are its only MIDI surface). Validate shape against spec
5/5.1 by hand; keep `tested: false` on both.

M4b (after M2): table-driven tier 1 tests, one row per binding in each map:
synthetic event + fabricated `DispatchCtx` -> exact envelope / builtin
expansion / sterling ring item. Port DJ's ValueMapping curve tests. Provide
the mock fixture shapes M3 seeds (coordinate: the mock's seeded bindings must
equal sx-kc211.json).

Accept: both maps load with `loadError: null`; every mapped control proven by
a test row; `cargo test -p agent-surface` green; no hardcoded machine paths.

## M5 - Sterling triggers end-to-end (Frontier, Medium context)

Spec section 8 (ring + cursor + Swift consumption + provenance), 12.6.

Do (engine half, after M2): confirm ring semantics (bounded 16, monotonic seq,
oldest dropped) and the pump's sterling resolve path; tier 1 tests: bound
control fires -> ring item with exact instruction/bindingId; ring bounds; seq
monotonicity.

Do (app half, after M3): `StudioCopilotModel` cursor consumption (init cursor
= nextSeq, never replay old items), submit via existing `backend.send`,
transcript prefix "MIDI trigger: <label>", unconfigured/mock-backend notice;
the binding-table Sterling instruction cell (editable text -> re-send
`midi.binding.set`).

Accept: virtual/mock test proves press -> ring -> (Swift test) turn submitted
with the exact instruction; resulting tool calls journal as
`Actor{Agent,"sterling"}` (assert on the journal in the engine test that a
copilot-driven command after a trigger is agent-actored; the classification to
`ClipOrigin::Generated` is already covered by export tests); no new FFI; no
auto-play of anything audible.

---

## Explicitly out of this wave (tracked, not dropped)

- MIDI OUT (LED feedback, displays): out of scope by design; format has no
  fields for it.
- txn-grouped continuous sweeps (one undo unit per fader gesture): blocked on
  journal txn tagging; spec 2.4.
- `track.mute`/`track.solo` toggle builtins: cheap follow-ups if Aaron wants
  them on keys; spec 5.5 note.
- Bundled-map SHA-256 superseded-refresh (DJ has it; we ship copy-if-absent):
  add when a bundled map first changes post-ship.
- Shift layers, jog/scratch, soft-takeover: DJ-domain; revisit with a real
  fader/encoder controller map.
- Dedicated `midi.state` read tool (narrower than snapshot) if agents ask.
- Attended (Aaron, hardware): SX-KC211 live verification, flip its
  `tested: true`, tune the velocity feel; stays in
  `10-ATTENDED-audio-boundary.md` territory.
