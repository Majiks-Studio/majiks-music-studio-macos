# I1 - playable: the Studio tab on the real engine

Milestone lane I1 makes the "it's real" moment: the Studio tab runs on the REAL
FFI-backed engine with live audio, and an agent moves a clip over MCP with the
UI reflecting it. Phase 1 shipped the Rust engine, the offline bounce, the L6
agent surface (FFI + MCP), and a `RealStudioEngine` adapter that was compiled
but not yet the default. I1 wires live playback, flips the tab to the real
engine, and proves it end to end.

## What shipped

1. **Live audio in the engine.** `render::Engine` already owned the cpal output
   stream and the silence gate; I1 makes it drivable from the host without
   breaking the `Send` rule the MCP server needs. A new `LiveAudio`
   (`engine/agent-surface/src/live.rs`) owns the `!Send` engine on a dedicated
   audio-host thread and hands the control side only a `Send` handle (a command
   `Sender` plus the shared param / meter / stat `Arc`s). Transport and freshly
   compiled sessions cross a bounded channel as `RenderCommand`s; meters, stats,
   and the play position read from the shared atomics. The render callback stays
   allocation, lock, and IO free (proven below: `allocViolations=0`).

2. **The flip.** The Studio tab now builds the view model on `RealStudioEngine`
   when the app links `MajiksEngine.xcframework` (`StudioEngineFactory`), and on
   `StudioMockEngine` otherwise, so the no-framework build still works. See
   "Builds" below.

3. **Live is explicit and silent.** A live session opens only on an explicit act
   (the FFI `start_live`, or a user pressing play, which lazily opens it). The
   device is SILENCE-GATED: the graph renders for real, but the device hears
   zeros unless `MAJIKS_TEST_AUDIBLE=1`. Nothing in this lane sets it; every run
   below has `audible=false`.

## Acceptance, proven three ways

### A. In the running app (the GUI proof)

The real `.app` (Debug, links the xcframework, `REAL_ENGINE` defined) was
launched on the Studio tab against a seeded project, with the in-process MCP
server on `127.0.0.1:8478`. Screenshots are the app window only.

- **`docs/evidence/i1/01-clip-loaded-bar1.png`** - the Studio tab on the real
  engine (top bar reads `engine (offline)`, never "Mock engine"; project "Live
  Proof", 120 BPM, provenance "1 clip, 1 imported"). Clip `c1` (a real imported
  WAV) sits at bar 1; project length 4 bars.
- **`docs/evidence/i1/02-agent-moved-clip-bar3.png`** - after an EXTERNAL MCP
  client issued `studio_clip_move` (`c1` -> `startTicks 7680`), the tab reflects
  the move within its 30 Hz poll: `c1` is now at bar 3, project length 6 bars.
  Nothing else changed; the agent moved the clip and the UI followed.
- **`docs/evidence/i1/03-live-transport.png`** - after play, the top bar reads
  `engine (live), 0.1 ms p95, 0 underruns`, the transport shows Pause with the
  position advanced to `2.3.4`, and the play head has moved into the timeline.
  This is the real engine's clock, silence-gated.

Agent-moves-a-clip transcript (external MCP client vs the running app's
in-process server, `scratchpad/mcp_app_proof.py`):

```
connected to app MCP server: {'name': 'rmcp', 'version': '2.2.0'}
BEFORE: clip c1 startTicks = 0 (engine live=False, seq=3)
studio_clip_move -> {"command": "clip.move","duplicate": false,"journaled": true,"mutated": true,"ok": true,"seq": 4}
AFTER:  clip c1 startTicks = 7680 (seq=4)
PASS: the running app's real engine moved c1 0 -> 7680 on the agent's command
```

Live engine health read back from the same running app after play:

```
engine_stats: live=True playing=True positionFrame=173568 underruns=0 deviceName=HISENSE audible=False callbacks=1356
```

### B. Headless, deterministic (the CLI proof)

`majiks-studio-cli live-proof` does the whole path with no UI, so it is the
reproducible backbone. It imports a real fixture WAV, opens the live engine,
plays (the transport advances against the real engine), and an agent moves the
clip (the tool route, which is exactly what the MCP server dispatches):

```
== go live (SILENT unless MAJIKS_TEST_AUDIBLE=1) ==
  start_live -> {"audible":false,"channels":2,"configuredRate":48000,"deviceName":"HISENSE","deviceSampleRate":48000,"generation":1,"live":true,"ok":true}
== transport runs against the real engine ==
  poll: positionFrame=2432 callbacks=19 underruns=0
  position advanced: 2432 frames (0.051s) -> live transport confirmed
== an agent moves the clip (tool route = MCP dispatch) ==
  studio_clip_move -> {"command":"clip.move","duplicate":false,"journaled":true,"mutated":true,"ok":true,"seq":4}
  clip c1 startTicks: Some(0) -> Some(3840) (reflected in snapshot)
live-proof: PASS
  engine health: underruns=0 allocViolations=0 deadlineMisses=0
```

### C. Tests

`engine/agent-surface/tests/live.rs` is the same end to end (import a real WAV,
go live, assert the transport advances, an agent `clip.move` is reflected). It
opens a device, so it is OFF by default and only runs under `MAJIKS_TEST_LIVE=1`
(and stays silent unless `MAJIKS_TEST_AUDIBLE=1`), keeping `cargo test
--workspace` device-free. A compile-time guard asserts `StudioHost` and
`LiveAudio` are `Send`.

## Reproduce

```bash
# 1. Build the engine framework (universal; add MAJIKS_ENGINE_ARM64_ONLY=1 for a
#    fast local arm64-only build). Regenerates the committed Swift bindings.
bash src/swift/scripts/build-engine.sh

# 2a. Headless CLI proof (opens the default device, SILENT):
cargo run -p agent-surface --bin majiks-studio-cli -- live-proof --dir /tmp/i1

# 2b. Seed a project for the app (no device):
cargo run -p agent-surface --bin majiks-studio-cli -- live-proof --dir /tmp/i1 --seed-only

# 3. Build + launch the real app on the Studio tab with the seeded project and
#    the in-process MCP server:
( cd src/swift && xcodegen generate \
  && xcodebuild -project MajiksMusicStudio.xcodeproj -scheme MajiksMusicStudio \
       -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build )
open -n "src/swift/build/Build/Products/Debug/MajiksMusicStudio.app" --args \
  --open-studio-tab --studio-project /tmp/i1/LiveProof.mstudio \
  --studio-mcp-pat "<PAT>" --studio-mcp-port 8478

# 4. From another agent, move the clip over MCP; the tab reflects it:
python3 scratchpad/mcp_app_proof.py --pat "<PAT>" --port 8478 --clip c1 --track t1 --to 7680

# Gated device test:
MAJIKS_TEST_LIVE=1 cargo test -p agent-surface --features ffi --test live -- --nocapture
```

## Builds (the flip keeps CI on mock)

- Mock / CI path: `MAJIKS_ENGINE=mock swift build` (no xcframework) -> `Build
  complete!`. `Package.swift` selects mock when the framework is absent (or
  `MAJIKS_ENGINE=mock`), excludes `Sources/Engine`, and runs `StudioMockEngine`.
  This is the path CI takes: it never builds the framework.
- Real / app path: `xcodegen generate && xcodebuild ... build` -> `BUILD
  SUCCEEDED`. `project.yml` links the xcframework, defines `REAL_ENGINE`, and
  adds the linker flags the Rust staticlib needs (`-lc++` for the C++
  signalsmith-stretch stretcher, plus CoreAudio / AudioToolbox / AudioUnit for
  cpal). `Package.swift` mirrors these under its real branch for `swift build`
  when the framework is present.

## Additive engine exports

- `render::Engine::params_arc()` - clone the shared `EngineParams` so the
  off-thread control side can drive the live engine's atomics. The only render
  change; everything else lives in `agent-surface`.
- FFI: `MajiksEngine.start_live` / `stop_live` / `live_running`.

## Test tallies

- `agent-surface` (`--features ffi,mcp`): 22 passed (was 20; +1 `Send` guard, +1
  gated `live` test that no-ops without `MAJIKS_TEST_LIVE`). 0 failed.
- `render`: 32 passed. `cargo test --workspace` (default features): green.

## Notes and caveats (questions, not invented behavior)

- **Attended audible check for Aaron.** Every run here was silence-gated
  (`audible=false`). Confirming real sound needs an attended run with
  `MAJIKS_TEST_AUDIBLE=1` set in the app or CLI environment. That was
  deliberately not done here (Aaron's studio monitors are live).
- **App window under a headless launch.** Launched from this automation context,
  the SwiftUI `WindowGroup` main window materializes on a secondary Space that
  `CGWindowListCopyWindowInfo` does not enumerate, so the screenshots were taken
  by raising the window through the accessibility API and capturing its exact
  rectangle (`scratchpad/capture_app.sh`). This is a capture-harness detail, not
  an app behavior; a normal user launch shows the window directly.
- **Live device-switch survival is a follow-up.** `render::Engine` already
  supports `restart_output` on a stream fault; re-pushing the session across the
  audio-thread boundary after a device change is not wired in I1 (the device
  stays put). The live session is torn down cleanly on `stop_live`.
- **xcodegen rewrites `Info.plist`.** `xcodegen generate` regenerates
  `src/swift/Info.plist` from the `info:` block in `project.yml`, dropping the
  hand-maintained version string and the `majiksstudio` OAuth URL scheme. This
  predates I1 (the `info:` block was already there); the working-tree change was
  reverted and not committed. Worth a separate fix (move the extra keys into
  `project.yml`), but it is outside this lane.
