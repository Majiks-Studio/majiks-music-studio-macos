# L6 - Agent surface (FFI + MCP + headless CLI)

Lane L6 makes the integrated Majik's Music Studio engine drivable from the Swift
app, from an in-process copilot, from remote MCP agents, and from a headless CLI
- all through ONE engine instance and the SAME timeline-core command bus, so
undo, provenance, and agent parity are identical whoever drives.

Owned surface: the new crate `engine/agent-surface/`, the build script
`src/swift/scripts/build-engine.sh`, and the Swift files under
`src/swift/Sources/Engine/`.

## 1. Shape: one instance, three transports

```
                     ┌───────────────── StudioHost (one instance, Send) ─────────────────┐
  Swift app  ─FFI──▶ │  Session (command bus + hash-chained journal + undo)              │
  copilot   ─tool─▶  │  sources: assetHash -> decoded AudioBuf   package dir (.mstudio)   │
  MCP agents ─HTTP─▶ │  submit(actor, name, params) -> the ONLY mutation path            │
  CLI/tests ─direct▶ │  bounce = render crate's OFFLINE graph (same RenderCore::render)   │
                     └───────────────────────────────────────────────────────────────────┘
```

`StudioHost` holds NO live cpal stream (that type is `!Send` and is exactly why
the DJ engine went global). Live playback + real meters are the app's audio
thread at integration checkpoint I1; here transport is a tracked view and meters
report an honest silence floor. The "real engine" for acceptance is the render
crate's offline graph, which is the same `RenderCore::render` the device
callback runs, so a bounce is truthful and deterministic.

## 2. FFI (UniFFI 0.29, proc-macro)

`MajiksEngine` is a UniFFI **object** the Swift app constructs and holds
(`MajiksEngine.initialize(dataDir:)`), never a process global - the DJ singleton
hazard, fixed by rule. Scalars in, JSON snapshots out (DJ `ffi.rs` idiom), one
typed `FfiError`. Exports: `command` (`ffi_studio_command`), `tool`, `snapshot`
(`ffi_studio_snapshot`, diff-cursor aware), `transport` play/stop/seek fast
paths, `meters`, `tiles` (via the media peak path), `engineStats`,
`bounceMaster`, `undo/redo/save/seq`, `toolsManifest`, and (mcp feature)
`mcpStart/mcpStop/mcpRunning`. The bindgen bin is behind `ffi-bindgen`, so
default builds keep exactly ONE bin (the CLI) - the DJ packaging rule.

`build-engine.sh` builds a universal (arm64 + x86_64) staticlib, runs
uniffi-bindgen, and assembles `src/swift/MajiksEngine.xcframework` +
`src/swift/Sources/Engine/Generated/majiks_engine.swift`. The generated Swift +
build script are committed; the xcframework (large `.a` slices) is gitignored
and rebuilt on demand.

The object was named `MajiksEngine`, not `StudioEngine`, because UniFFI emits a
`<Object>Protocol` and `StudioEngineProtocol` already exists (L5's engine seam).

## 3. MCP server

- rmcp **streamable-HTTP** on `127.0.0.1:` **`8478`** (the chosen fixed free
  port, distinct from Majik's DJ's 8471; `agent_surface::mcp::DEFAULT_MCP_PORT`).
- Bearer PAT (from the app's Keychain / `MAJIKS_STUDIO_MCP_PAT` env), **OFF by
  default**; `start` fails closed unless enabled + a non-empty PAT.
- Connection snippet (PAT redacted unless the UI reveals it):
  `claude mcp add majiks-studio --transport http --url http://127.0.0.1:8478/mcp --header "Authorization: Bearer ••••"`
- Dispatch order (DJ discipline): validate args against the tool schema ->
  Manage confirm gate -> write rate limit (10 ms, reads free) -> route to the
  host under the lock (no `.await` while locked, so the server future stays Send).
- Live handshake proven over real HTTP in `tests/mcp_handshake.rs`: health,
  401 on missing bearer, `initialize` (+ session id), `notifications/initialized`,
  `tools/list` (count == registry, every tool carries an object `inputSchema`,
  all names present), a read tool, a write tool that mutated the shared bus, and
  a Manage tool rejected without `confirm`.

## 4. Tool registry - generated, drift-proof, parity-gated

Tools are GENERATED from `engine/contracts/command-catalog.v1.json`: one tool
per command (`studio_<snake_name>`), inputSchema taken **verbatim** from the
catalog `paramsSchema`, so the tool set can never drift from the bus. Tiers:
reads = Read (dedicated read tools), mutations = Perform, delete-class + export/
publish = Manage (`confirm: true` required, stripped before the bus).

- **82 tools** total = 70 command tools + 6 read (`studio_snapshot`,
  `studio_journal`, `studio_engine_stats`, `studio_waveform` capped,
  `studio_takes`, `studio_lineage`) + 4 gen proxy (`gen_submit/status/cancel/
  capabilities`, forwarded to L4; honest "not configured" when no endpoint) + 2
  session (`studio_undo`, `studio_redo`).
- **Parity gate GREEN**: every one of the 71 catalog commands has a tool or a
  documented exclusion. The ONE exclusion is `gen.landed` (system-authored: the
  engine writes it on async completion; agents never author it). Test:
  `tests/parity.rs`.
- Committed codegen output: `engine/docs/generated/mcp-tools.v1.json`, with a
  **regen check** in `tests/parity.rs` (rewrite with
  `majiks-studio-cli tools --write engine/docs/generated/mcp-tools.v1.json`).

## 5. Headless CLI - the agents-render-anywhere surface

`majiks-studio-cli`:
- `run --project DIR --script FILE.jsonl [--bounce OUT]` - apply an
  envelope-per-line script through the bus, save, bounce.
- `bounce --project DIR --out OUT [--start-ticks N --end-ticks N]`.
- `interop [--dir DIR]` - the self-contained acceptance (see
  `l6-agent-interop.md`): create -> tempo -> 2 tracks -> 2 imported fixture clips
  -> move/trim -> save -> bounce, plus an envelope-route vs tool-route
  **bit-identical** null match.
- `tools [--write PATH]` - emit/regen the tool manifest.

## 6. Bounce fidelity (null tests)

Deterministic, silent at any device. Two routes that build the same journal
bounce bit-identically:
- envelope route (`host.submit` / `ffi_studio_command`) vs tool route
  (`dispatch_tool` / MCP): `bit_identical=true` (CLI interop).
- FFI route (`MajiksEngine`) vs direct route (`StudioHost`): byte-identical WAV
  (`tests/interop.rs::cli_bounce_null_matches_ffi_bounce_bit_identical`).

## 7. Swift EngineClient + RealStudioEngine adapter

`Sources/Engine/EngineClient.swift` is a thin facade over the generated FFI
object. `Sources/Engine/RealStudioEngine.swift` is an `actor` that conforms to
L5's existing `StudioEngineProtocol` (snapshot / send / waveformTile), so the
Studio tab can switch from `StudioMockEngine` to the real engine at I1 by
changing one initializer. It typechecks against the generated bindings + the L5
protocol (`swiftc -typecheck`, exit 0). It is EXCLUDED from the default app build
(Package.swift + project.yml) - the default build does not link the xcframework
and keeps `StudioMockEngine` - so no default build is broken; flipping the tab is
the I1 step.

## 8. Test tallies

- `agent-surface` (`--features ffi,mcp`): **20 passed** (lib 13 + interop 2 +
  mcp_handshake 2 + parity 3), 0 failed.
- `cargo test --workspace` (default features): all green, incl. timeline-core 32.
- `timeline-core` still compiles for `wasm32-unknown-unknown` after the additive
  `+ Send` tightening (see §9).
- Swift adapter: `swiftc -typecheck` clean.

## 9. Decisions, additive exports, and proposals (for the coordinating session)

1. **timeline-core additive tightening (needed):** `Session`'s sink field became
   `Box<dyn JournalSink + Send>` (and `with_sink`'s param). Every concrete sink
   (MemoryJournal, FileJournal) is already Send; the bound lets a `Session` sit
   inside the FFI/MCP `Arc<Mutex<..>>` without a global. No wasm impact (the
   trait is unchanged; verified). No other timeline-core/render internals changed.

2. **`import.audio` host decomposition (proposal):** the agent-facing
   `import.audio` resolves to host io (decode + blake3 + copy into `audio/`) plus
   a single journaled `clip.place` carrying the real assetHash + length, rather
   than a literal `import.audio` envelope. The content hash is the provenance
   link and a `clip.place` journal replays deterministically without re-reading
   the source. The `studio_import_audio` tool schema therefore extends the
   catalog params with optional placement hints (`clipId`, `startTicks`);
   `additionalProperties` stays false. If the coordinator prefers the literal
   `import.audio` + `clip.place` txn (the `submit_with_hint` path), that is a
   small host change.

3. **Tier mapping choice:** Manage (confirm) = `track.remove`, `clip.remove`,
   `export.*` (4), `publish.track`. Section/marker/autopoint removals stay
   Perform (undoable metadata, not "delete-class"). All transport/view commands
   are Perform (actions, not reads). Open to re-mapping.

4. **`publish.track`** is journaled-as-intent but reported
   `executed:false` - the majiks.online publish pipeline is out of the engine
   surface's scope (02-ARCH: shipped pre-Studio).

5. **Existing Python stdio MCP:** untouched; a deprecation-after-parity note
   belongs in its README (P2 scope, per the brief's out-of-scope line).

## 10. Known gaps (honest, for I1)

- Live cpal playback + real meters/`engine.stats` are not wired here (the host
  is Send-clean by design); transport is a tracked view and meters read a
  silence floor. I1 attaches a live engine on the app's audio thread feeding the
  same bus.
- The Swift adapter infers stem kind from the track name and does not yet surface
  take lanes / per-clip generative flags (the read model has no stem-kind field);
  `clipTrim` maps a single dragged edge to one catalog `clip.trim`.
- Region/stem export and the bounce currently emit WAV only; FLAC/AAC land with
  the AudioToolbox path (02-ARCH §3).
- Warped-clip bounce plays the clip unwarped in the headless path (no off-thread
  warp worker offline); the live host runs the warp worker.
