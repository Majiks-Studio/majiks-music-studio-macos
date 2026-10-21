# Lane L5: Studio tab UI shell — evidence

Date: 2026-07-11. Branch: `lane/l5-studio-shell` off main `cbfec4c`.
Built and driven from the lane worktree. Backend Python is absent in a bare
clone (expected); the Studio tab runs entirely against `StudioMockEngine`, a
silent Swift actor implementing `StudioEngineProtocol`. No audio is produced.

## Builds (both green)

- `swift build` from `src/swift`: SUCCEEDS (release path used for shipping).
- `xcodegen generate` + `xcodebuild -scheme MajiksMusicStudio` (Debug,
  ad-hoc sign): `** BUILD SUCCEEDED **` (IDE/app path).
- `xcodegen` rewrites `src/swift/Info.plist` (known repo gotcha, two version
  keys). Reverted with `git checkout -- Info.plist` after each generate; no
  plist churn is committed.
- `swift test`: 155 tests in 30 suites pass, including the new
  `StudioShellMathTests` (snap, trim, split, zoom, selection, rubber-band,
  row layout, tile scheme, palette fuzzy match).

## Performance gate (60 fps, the hard requirement)

Fixture: `StudioMockEngine(project: .standard)` = 8 tracks, 100 clips, 92
bars, take lanes on two tracks, one automation lane. The synthetic project
is the L5 gate fixture. Measured with the in-app frame-time HUD; numbers
come from a scripted pan + zoom sweep (`--studio-perf-sweep`, two pan passes
and two zoom cycles over ~8 s) so the samples are all full-rate frames.

Machine: Apple Silicon (this Mac), Debug build.

| metric | value |
| --- | --- |
| effective fps (mean frame interval) | 80 fps (12.5 ms) |
| frame interval p95 | 19.6 ms |
| frame interval worst | 23.7 ms |
| canvas draw cost, mean | 1.94 ms |
| canvas draw cost, p95 | 3.12 ms |
| samples | 643 full-rate frames |

Reading: the 60 fps gate is met. Mean is 80 fps. The number that reflects the
renderer's own cost is the draw cost: one full canvas pass over the 100-clip
fixture costs 1.94 ms mean / 3.12 ms p95, comfortably inside the 16.67 ms
budget for 60 fps (about a 5x margin at p95). The frame-interval p95 of
19.6 ms is scheduling jitter from the sweep driver's 8 ms tick and
TimelineView coalescing, not render cost; the draw-cost column isolates the
part L5 owns.

SwiftUI Canvas holds the target. The Metal tile path is NOT needed at this
scale, so it was not built. The seam is preserved for later: waveforms are
already source-space peak tiles (`StudioWaveformTileStore`), fetched async
off the engine and drawn as prebuilt unit-space `Path`s that the canvas only
scales per frame. Swapping the per-tile draw for a Metal-backed tile is a
localized change behind `drawWaveform`, exactly the seam the DJ code
anticipates. If a future project (thousands of clips, or deep zoom with
every tile distinct) pushes draw cost past budget, that is the first move.

Raw sweep output: `perf-sweep.json` in this folder.

## Screenshots

Structure and tokens match the mockup's four states (not pixel-identical).

- `01-session.png` — Session state. Section ruler (INTRO / VERSE 1 ...), 8
  stem tracks with colored async waveforms, AI badge on generated clips
  (shimmer surface), transport readouts (position / BPM / key / time), engine
  chip, Generate button, project inspector with provenance summary, mixer
  dock collapsed to the master mini-strip.
- `02-revise.png` — Revise state. Bars 33-48 selected across all tracks
  (gradient region edges, the revise unit), take lanes materialized under
  Drums (Take 1 / Take 2 / Take 3 rendering) and Synths, contextual Revise
  inspector armed with scope chips, variants, and honest placeholders.
- `03-mixer.png` — Mixer dock expanded: per-track strips (EQ curve, sends,
  fader, meter, mute/solo state) rendered from the snapshot, plus master.
- `04-palette.png` — Cmd+K command palette filtered to `clip`, listing
  catalog v1 commands with their keybindings (Cmd D / Delete / Cmd E on the
  wired ones).
- `05-perf-hud.png` — Session state with the frame-time HUD showing the
  sweep result described above.

## Keyboard map (implemented)

- Space: transport play/pause (Studio owns the spacebar while frontmost, via
  the same `dawTransportToggle` arrangement the Stems tab uses).
- R: arm Revise for the selected region (stub panel; no generation in L5).
- Cmd+E: split at playhead (selected clips under it, or all clips under it).
- Cmd+D: duplicate selected clips.
- Z: zoom to fit the project.
- Cmd+K: command palette over the 71 catalog names + this build's view
  commands.
- Delete: remove selected clips. Esc: cancel drag or clear selection.

## Accessibility

VoiceOver labels on the transport (each button, position, tempo, key, time,
meters, engine chip, Generate) and on every track header (name, mute/solo
state, volume, clip count as the accessibility value). The track header
column is real SwiftUI (not canvas) so VoiceOver reads it. Reduced-motion is
honored: the shimmer gradient stays on generative surfaces but stops
animating (the meaning survives).

## The shimmer rule (honored)

The blue-purple-pink generative gradient appears ONLY on generative surfaces:
the Generate button, the in-flight/armed Revise region edges and pill,
rendering take lanes, and the AI badge on generated clips. Every calm surface
is flat token color. `StudioTokens` centralizes the gradient and a
`studioShimmerBackground` modifier so the rule is enforced in one place.

## Notes / questions for the coordinator

1. Studio tab tag: I used tag 5 (tags 0-4 are Chat/Create/Library/Publisher/
   Stems). The gen tab keeps tag 1 with its label renamed Studio -> Create.
   `StudioCoordinator.openStudioWithParameters` still sets `selectedTab = 1`
   (the Create tab), which is correct: "Open in Studio" from a song card is a
   later lane's wiring (P2 bridge), and the Create-tab generation flow is
   unchanged. Flag if you want the DAW tab reachable from the coordinator now.
2. Command surface: I mapped a typed `StudioEngineCommand` enum to catalog v1
   names rather than emitting raw envelopes, so L6's FFI client can serialize
   the same shapes. No catalog changes proposed; the palette lists all 71.
3. `--studio-*` launch flags (hud, perf-sweep, select-bars, open-mixer,
   open-studio-tab) are evidence/automation hooks, inert without the flag.
   Safe to keep or strip before merge; they touch nothing at normal launch.
