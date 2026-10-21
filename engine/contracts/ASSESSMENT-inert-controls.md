# Assessment — inert controls, unreachable capability, and untrue UI

**Lane:** `docs/inert-hunt` (worktree `wt-inerthunt`), branched from `feat/ms-342` @ `2965425`.
**Date:** 2026-07-26.
**Scope:** `src/swift/Sources/**` (140 files, ~70k lines), `engine/**`, `src/python/majik_backend/**`,
`README.md` and `docs/**`, the 113-command catalog, and the generated MCP tool registry.

This is an **audit**. The document is the deliverable. §11 lists the small set of fixes actually applied.

---

## 0. How to read this

| Code | Meaning |
|---|---|
| **A — Inert** | A control exists, the user can operate it, and nothing happens (or something fake happens). |
| **B — Unreachable** | The engine can do it — journaled, tested, shipped — but no UI reaches it. |
| **C — Lying** | The UI states something untrue: a label, status, preview, help string, README claim, or an instruction naming a control that does not exist. |
| **D — Fake data** | A display fed by a constant, a sine, a placeholder, or a value invented app-side that the engine never supplied. |

**Counts.** 112 rows: **28 A** (§2), **11 B** (§3), **60 C** (§4a 28 + §4b 14 + §4c 6 + §4d 12), **8 D** (§5),
and **5 contract-surface** rows (§6) counted separately because they lie to an agent rather than to a person.

**Category C dominates, and that is the finding.** Roughly half of all rows are untrue *statements* rather
than dead *controls*. The app builds features and then describes them wrongly — sometimes over-claiming
(MP3 export, a ruler loop region, a Setup Wizard in Settings), sometimes **under**-claiming a feature that
works (`docs/USER_MANUAL.md:122` tells users the count-in makes no sound; it does). Four separate documents
disagree with the code about the command catalog's own version and size.
Rows carrying two codes are counted under their primary one. §10 lists 24 claims **checked and found true**,
plus **3 rows withdrawn** during verification.

**Coverage.** Every Swift source under `src/swift/Sources/**` was walked for interactive controls, plus the
full Rust engine, the Python backend, `README.md`, and `HelpView.swift`. Two areas got lighter treatment and
are called out as **not exhaustively audited**: `Publisher/**` (the 2317-line `CatalogueView` in particular —
three empty `Button { }` closures at `CatalogueView.swift:1434/1664/1800` and a "Coming Soon" at
`PublishQueueView.swift:165` were spotted but not run down) and `StemSessions/**`. Both are plausible homes
for more of this defect class.

**Evidence discipline.** This repo's comments, docs, and tests have lied repeatedly, so every row cites a
`file:line` that was read or the exact grep and its count. **Code comments are never treated as evidence for
behaviour.** Three claims in this audit were withdrawn during verification and are recorded in §10 as
corrections, because a confident wrong row is worse than an omission. Anything unsettled is marked
**UNVERIFIED** with the probe that would settle it.

---

## 1. The five worst

Ranked by likelihood a real user hits it × how badly it breaks trust.

### 1. "Publish to majiks.online" reports success and publishes nothing — `RealStudioEngine.swift:474-494`

The Studio export dialog's Publish button (`StudioExportDialog.swift:117-129`, tooltip *"Reuses the existing
majiks.online publisher (certs minted server-side); the manifest travels with it."*) calls
`engine.publishToMajiks`. That function writes a WAV into `~/Music/Majiks Studio Exports/` and returns
`ok: true`. **There is no network call in it.** The dialog then renders the green checkmark card with
`outputPath: "Published to majiks.online"` (`StudioExportDialog.swift:395-396`).

Verified: read `RealStudioEngine.swift:465-495` in full.
`grep -n "URLSession\|URLRequest\|http\|publish_track\|PublisherStore" Sources/Engine/RealStudioEngine.swift`
→ **one hit, line 477 — a comment naming the publisher it does not call.** The real path exists and works:
`BackendViewModel.swift:1880-1959` sends the `publish_track` RPC; `PublisherStore.swift:585` drives it. The
Studio dialog reaches neither.

A **confident false success on a network operation**. A user who publishes and quits believes the track is
live. Category **C + A**. Fix: **one line** to stop claiming success; **one lane-day** to route it properly.

### 2. The models-missing error sends users to a wizard that cannot be opened — `EnhancedStudioView.swift:264`

When generation fails for missing models, the app says:

> *"ACE-Step models are not installed or configured correctly. Please run the **Setup Wizard from Settings** to download the required models."*

`grep -rn "SetupWizardView" Sources/` → **2 hits**: the `struct` (`SetupWizard.swift:4`) and exactly one
instantiation, `Main.swift:151`, inside `.sheet(isPresented: $showFirstRunSetup)`. That flag comes from
`!UserDefaults.standard.bool(forKey: "HasLaunchedBefore")` (`Main.swift:92`), and `HasLaunchedBefore` is
written in exactly one place — the wizard's own `onComplete` (`Main.swift:152`).

Settings has nine tabs (`SettingsView.swift:13-32`): Agents, Sterling, LLM & Models, Models, Library
Location, Library Backup, Server Pool, MIDI, MCP / API. **None is a Setup Wizard.**

So a 1299-line wizard is unreachable after first launch, and the error message shown *precisely* when the
user needs it points there. This is a dead end at the app's single worst moment. Category **C**.
Fix: **one lane-day** (add a Settings entry point, or rewrite the message to the real remedy).

### 3. Per-stem audition mix changes nothing you can hear — `timeline-core/src/apply.rs:886-890`

```rust
Cmd::TakeAuditionMix { take_id, .. } => {
    self.take(take_id).ok_or_else(|| CommandError::UnknownTake(take_id.clone()))?;
    Ok(CmdEffect::unjournaled_noop())
}
```

It validates the take exists and returns. `grep -rn "auditionMix\|AuditionMix" engine/ --include='*.rs'` →
**5 hits total**: `cmd.rs:544`, `cmd.rs:545`, `cmd.rs:819`, `apply.rs:886`, `tests/support.rs:276`. **No
`agent-surface` handler, no render push.**

The UI path is fully wired to it: `StudioTakesBrowser.swift:252-255` → `StudioViewModel.auditionStemVariant`
(`:1318-1331`) → `RealStudioEngine.auditionMix` (`:583-585`) submits `take.auditionMix` and returns `ok: true`.

The catalog's own description promises audio: *"Select which stems of a per-stem take are **audible** while
auditioning candidates."* The pane's header comment says *"Drives take.auditionMix so an agent watching hears
the same mix."* (`StudioTakesBrowser.swift:215`). Nobody hears anything.

This ranks above the palette because it is an **A/B listening decision where the audio never changes**. The
user picks "drums from take 2, other from take 3", hears the same thing, and is asked to commit. Note the
feature is *half* real — `effectivePromotions` (`StudioViewModel.swift:1341`) does honour `perStemMix` at
commit, so the choice takes effect only after it can no longer be auditioned. Category **A**.
Fix: **one lane-day** (engine must push the stem selection to the renderer).

### 4. Region export is unreachable, and the dialog names a control that does not exist — `StudioExportDialog.swift:161-164`

Scope "Region" shows *"Set a loop region on the ruler to export a selection."* and Export is
`.disabled(busy || (scope == .region && loopRegion == nil))` (`:144`), where `loopRegion` reads
`snapshot.transport.loopRegion` (`:35`).

Nothing in the ruler sets that. `grep -rn "transportLoopSet\|transportLoopClear" Sources/` → the only
issue-sites are `StudioViewModel.swift:1105` and `:1114`, both inside the revise-audition flow, plus the clear
at `:1175`. `transport.loop.set` is also **not** among the 11 wired palette commands. A ruler drag sets
`model.selection.region` (`StudioTimelineView.swift:960-965`) — a UI-side value the export path never reads.

So "Export Region" is dead for a human outside an active audition, and the remedy the dialog names is a
gesture the app does not implement. The transport help repeats the promise: *"or just the bars you selected"*
(`StudioHelp.swift:239`). Category **C + A**. Fix: **one lane-day**.

### 5. Import and landing failures are completely silent — `StudioViewModel.swift:22-23, 103, 141, 151, 160` and `:1243-1256`

`importStatus` / `importProgress` are `@Published private(set)` and **no view reads them**.
`grep -rn "importStatus\|importProgress" Sources/ Tests/` → 21 hits: 8 writes in `StudioViewModel`, 6 test
assertions, 5 in `EnhancedStudioView.swift` that are an unrelated local `@State` of the same name on a
different screen (`:605`).

Four entry points feed it — toolbar `Import ▸ Audio File…`, Browser `Import audio…`
(`StudioBrowserView.swift:180-184`), timeline file-drop, library double-click. Each failure writes a specific
sentence (*"Create or open a project before importing audio."*, *"Could not create a track to import onto."*,
*"Created a track but could not read it back."*, plus the engine's own refusal) and the user sees **none** of
them. The file simply does not appear.

The same shape on the landing path: `landingError` (`:1243`) →
`grep -rn "landingError" Sources/ Tests/` → **3 hits: the declaration and two writes, zero reads.** A failed
"Open in Studio" is indistinguishable from one that did nothing.

**And the same defect exists independently on the Create tab**: `EnhancedStudioView.swift:605` `importStatus`
is written at `:1033`, `:1035`, `:1055`, `:1061` and never rendered — while `ToastManager` is used elsewhere
in that very file (`:584`).

This is the repo's sharpest example of a test proving the wrong thing:
`Tests/StudioImportTests.swift:190` asserts `XCTAssertNotNil(vm.importStatus, "a status explains why nothing
was imported")`. The variable is set. Nothing renders it. The suite is green. Category **A**.
Fix: **one line each** — sibling operations in the same file already use `ToastManager`
(`StudioViewModel.swift:335-337`, `:872-875`).

---

## 2. Category A — inert controls

| file:line | control | claims | actually | verified | fix |
|---|---|---|---|---|---|
| `RealStudioEngine.swift:474-494` | "Publish to majiks.online" | uploads, mints certs | writes a local WAV, returns `ok: true` | read in full; network-symbol grep → 1 hit, a comment | one line / one lane-day |
| `apply.rs:886-890` | per-stem audition mix | stems become audible | `unjournaled_noop()` | 5 repo-wide hits, no handler | one lane-day |
| `StudioExportDialog.swift:144,161-164` | Export scope "Region" | exportable via ruler loop | permanently disabled outside an audition | `transportLoopSet` grep | one lane-day |
| `StudioViewModel.swift:96-162` | 4 import entry points | reports why import failed | `importStatus` has zero readers | grep, 21 hits | one line |
| `StudioViewModel.swift:1243-1256` | "Open in Studio" | reports why landing failed | `landingError` has zero readers | grep, 3 hits | one line |
| `EnhancedStudioView.swift:605,1033-1061` | Create-tab import | "Importing…" / "Import failed: …" | written 5×, never rendered | grep, no `Text(` binding | one line |
| `StudioCommandPalette.swift:71-82` | **63 of 74** palette rows | listed as commands | toast: *"wires into Studio in a later build"* | parsed the array: 74 entries, 11 wired | one lane-day |
| `StudioInspectorView.swift:182-184` | "Retake" | *"Ask the model for another go at this clip"* | `stub(...)` → `ToastManager.show` (`:117-119`) | read both | one lane-day |
| `StudioInspectorView.swift:186-188` | "More like this" (shimmer) | *"Fill a new generation's prompt in from this clip"* | `stub(...)` → toast | read both | **needs design** — see note |
| `StudioTransportBar.swift:387-408` | "Generate" (shimmer) | — | popover says generation is not wired | read `:387-408` | one line (de-shimmer) |
| `EnhancedStudioView.swift:2265-2288` | Arrangement section boxes, *"Click sections to edit"* (`:2246`) | sections are editable | `.onTapGesture` sets local `@State` used only to tint the box; no edit path exists | read `:2231-2295` | needs design |
| `EnhancedStudioView.swift:2452,2551,2763-2768` | variant "picked" check + border | a picked state | `isPicked` declared `false`, never assigned | grep → 5 hits, all reads | one line |
| `EnhancedStudioView.swift:909,946` | `exportAs()`, `exportStems()` | WAV export, Demucs stem split | zero call sites; `exportStems` reaches a real backend RPC no button triggers | grep → definitions only | one lane-day |
| `Main.swift:366-374` | Window ▸ "Pop Out Library" / "Pop Out Studio" | opens a window; label flips to "Close…" | flips a `@Published Bool` read only by the menu item's own title; **no `openWindow(id:)` for it exists** | grep `library-window` | one line |
| `GenerationQueue.swift:152-157` | `cancelActiveJobs()` | "Cancel the currently active job(s)" | marks the model `.cancelled`; does not cancel the task or call `backend.cancelGeneration()` | grep → 6 hits, 5 in tests | **do not wire as-is** |
| `GenerationQueue.swift:148` | `moveJob` | queue reorder | zero production callers; no `.onMove`/`.draggable` in the queue views (the drag handle at `GenerationQueueView.swift:238` is decoration) | grep | one line |
| `LLMSettingsView.swift:1548-1551` | `checkDownloadedMLXModels()` | called from `.onAppear` beside 4 real refreshers | **empty body**; the comment says DownloadManager handles it globally, but `checkExistingDownloads()` is `private` and called only from `private init()` — once per launch, so badges stay stale until relaunch | read `:1128-1145`, `DownloadManager.swift:26,135` | one lane-day |
| `MidiSettingsView.swift:13,45` | `MidiLearnSheet` | a MIDI Learn sheet | `showLearnSheet` never set true | grep → 2 hits | one line |
| `MidiSettingsView.swift:270` | map row `.onTapGesture` | selects a map | `selectedMapKey` drives only Export's `.disabled`; the row renders no selection state | read `:235-271` | one line |
| `LicenseManager.swift:11,14,15` | `tier` / `isLicensed` / `canPublish` | tier gating | `canPublish` hard-coded `true`; no read sites. Real Ed25519 verification feeding nothing | grep | needs design |
| `UpgradePromptView.swift:4,150` | the whole upgrade sheet | paywall / "Get Publisher" | never instantiated. Because `LicenseEntryView` is constructed only from it, **there is no reachable way to enter a license key** | grep | needs design |
| `FirstRunSetupView.swift` · `GenerateConfirmationView.swift` · `TrackPickerSheet.swift` | three whole views | — | never instantiated; dead files | grep | one line each |
| `WindowManager.swift:15-49` | 4 window-opening functions | window API | zero callers | grep | one line |
| `EnhancedStudioView.swift:2701-2719` | "ACE Music / Soon" | share to acemusic.ai | empty closure — but `.disabled(true)` and badged "Soon". **Honest dead weight, not a lie** | read | one line (delete) |
| `EnhancedStudioView.swift:11,613,2460` | 3 `@EnvironmentObject licenseManager` | license-aware Create tab | never read in the file | grep | one line |
| `EnhancedStudioView.swift:606,2454` | 2 `exportStatus` | export progress | written-never-rendered, and unreachable (only writers are the dead functions above) | grep | one line |
| `EnhancedStudioView.swift:20`, `StudioModels.swift:428-433` | `GPUQueueStatus` cards | GPU utilisation | never mutated; `isActive` permanently false, both cards read 0%. Host view has no instantiation site | grep | one line (delete) |
| `StudioMockEngine.swift:2071-2074` | demo MIDI binding "Quantize Strength" → `tools.quantize` | a bindable quantize command | **`tools.quantize` is not in the catalog** — no `tools.*` command exists at all. Mock-only, so low blast radius, but a binding to a phantom command | parsed the catalog: `[n for n in names if n.startswith('tools')]` → `[]` | one line |

**Correction to a tempting "one-line" fix.** `StudioInspectorView`'s "More like this" looks like it should
call `StudioViewModel.rerollFromTake(_:)` (`:1372`), which is real and wired to the *Takes browser's*
identically-named menu item (`StudioTakesBrowser.swift:173`). It cannot: `rerollFromTake` takes a
`StudioTakeBrowserItem` and reads `item.lineage`, and `StudioClipSnapshot` (`StudioEngineModel.swift:78-102`)
carries **no lineage field** — verified by reading the whole struct. Wiring it needs a clip → take lineage
lookup, i.e. the "journal read surface" the inspector's own placeholder (`:176-181`) says has not landed.
**Fix cost is "needs design", not one line.**

---

## 3. Category B — built, tested, and unreachable from any UI

The MCP registry generates one tool per catalog command (`registry.rs:216-241`), so nothing is unreachable to
an *agent*. The honest category is "no human UI path".

| capability | evidence it exists | why no UI reaches it | fix |
|---|---|---|---|
| `project.new`, `project.open` | `host.rs:506`, `:511` | only palette rows (unwired). `Main.swift:198`'s `.newItem` slot is taken by **"New Conversation"** — there is no File ▸ New/Open Project | one lane-day |
| `track.reorder` | `apply.rs:1225`; `StudioViewModel.reorderTrack:688` exists | `grep -rn "reorderTrack" src/swift/` → 4 hits, sole caller is `Tests/StudioReachabilityTests.swift:213`. No drag-reorder in `StudioTrackHeaderColumn.swift` | one lane-day |
| `device.zone.add` / `.remove` | `compile.rs:1079-1090` builds the sampler zone map — **audible** | `StudioViewModel.swift:1794-1999` uses the same commands for sampler/drum loading | reachable from the UI; MCP-host wiring remains open |
| `import.stems` | `host.rs:520, 2527` | zero hits in `src/swift/` | one lane-day |
| `take.restore` | `apply.rs:3062` | zero hits outside `cmd.rs`/`apply.rs`/tests | one line |
| `midi.device.select`, `midi.reload` | `midi/mod.rs:120` | not in `MidiSettingsView`; `midi.reload` appears only in `StudioMockEngine.swift:902` | one line |
| `gen.retake` / `gen.cover` / `gen.autocomplete` / `gen.separate` | catalog + `apply.rs` | no submit site anywhere in app or host | needs design |
| Automation of 9 parameter families | `paramref.rs:128-159` resolves `track.eq.*`, `track.send.*.level`, `track.device.*`, `track.fx.*`, `bus.*.fx.*`, `master.fx.*`, `route.edge.*.level`, `master.gain`, `master.limiter.*`, `bus.*.gain` | the timeline offers two: `StudioAutoTarget` is `case volume, pan` (`StudioEngineModel.swift:158-159`) | needs design |
| Takes kind filter | `StudioTakesFilter.kind` declared and applied (`StudioTakesModel.swift:135`, `:144`) | no control sets it; the filter bar (`StudioTakesBrowser.swift:51-76`) offers only "Auditionable" and "This region" | one line |
| `transport.loop.set` | wired in both engines (`RealStudioEngine.swift:641-644`) | only the revise-audition flow issues it | one lane-day |
| Per-job generation cancel | `GenerationQueue.cancelActiveJobs()` | no call site outside tests — **and half-implemented** (§2) | needs design |

---

## 4. Category C — the UI states something untrue

### 4a. In-app controls and status

| file:line | the claim | the reality | verified | fix |
|---|---|---|---|---|
| `EnhancedStudioView.swift:264` | *"run the **Setup Wizard from Settings**"* | no such entry; the wizard is first-launch-only | grep → 2 hits; read 9 Settings tabs | one lane-day |
| `EnhancedStudioView.swift:1180-1199` | 7 selectable generation modes, each with a described behaviour (`StudioModels.swift:36-41`) | **only `.cover` and `.continuation` get mode-specific controls** (`:1139-1142`). `repaintStart/End`, `extractStems`, `legoInstruction` have **no UI anywhere** — always `0.0/-1.0`, `[]`, `""`. Repaint repaints the whole track; Extract requests zero stems; Lego sends an empty instruction. Worse: repaint/extract/autoComplete are `requiresSourceAudio == true` (`StudioModels.swift:70-72`) yet the source picker renders only for `.continuation`, and validation (`:242-250`) guards only cover/continuation — so Generate proceeds with no source and no warning | read `:1139-1142`, `:242-250`; grep the 4 params → 0 UI hits | needs design |
| `EnhancedStudioView.swift:719` | variant-count `.help`: *"Generate multiple versions **in parallel** with **different random seeds**"* | `GenerationQueue.enqueue` hands **every** job the identical `parameters` value (`:124`), seed included; local jobs run **sequentially** (`:223-229`, *"one at a time, restart backend between each"*). With a user-set seed, all N variants are identical | read both | one line (copy) |
| `EnhancedStudioView.swift:472-481` | per-variant note: "Original parameters" / "**Slightly faster tempo**" / "Alternative arrangement" / "Different mood" / "Experimental variation" | `generateVariantNote(index:)` picks by **array position**. All variants share one parameter set, so "Slightly faster tempo" is flatly false — and it is **persisted** into `StagingTrack.note` (`:438`) and carried into the library | read `:470-481`, `:325-338` | one line (delete) |
| `HelpView.swift:588` + `AlbumArtGenerator.swift:35-37` | *"unique, **deterministic** design"* | `abs(seed.hashValue)`. Swift's `String.hashValue` is **per-process randomly seeded**; `grep -rn "SWIFT_DETERMINISTIC_HASHING"` repo-wide → **0 hits**. Art changes every launch. **Consequence:** `PublisherStore.renderProceduralArtwork` (`:1314-1320`) renders this same view to a JPEG that is uploaded as the published cover — so the shipped cover permanently diverges from what the app shows, and re-publishing yields a different cover again | read both; env-var grep | one line (stable hash) |
| `SettingsView.swift:452-460` | "Backup Now" → green ✓ *"Backup created: `<file>`"* | `createBackup()` swallows every error into a `print` and returns `Void` (`LibraryStore.swift:322-324`), silently early-returns when `library.json` is absent (`:313`), and uses a second-resolution timestamp (`:318`) so `copyItem` throws on a same-second second press. `manualBackup()` then returns the newest file **by name** (`:345-348`) — possibly a stale one — and the UI reports success either way | read `LibraryStore.swift:311-349` | one line |
| `SettingsView.swift:581`, `HelpView.swift:455` | "Move Library" — *"All audio files, artwork, and **metadata** will be moved"* | `relocateLibrary` moves Audio/Artwork/StemSessions + 5 named JSONs (`FileStore.swift:111-159`). It leaves behind **`Backups/`**, **`track_modified_dates.json`**, and **`conversations.json`**. After a move the Backup pane reads "No backups yet" | read `FileStore.swift:84-188` + the 3 path sites | one lane-day |
| `MidiSettingsView.swift:291-297` | binding enable/disable `Toggle` | sends `midi.binding.set` **without** `valueMap`; the engine's create-or-replace `upsert_binding` writes `value_map = None`. Toggling a mapped fader **silently destroys its value map** | read Swift + `engine/agent-surface/src/midi/mod.rs:694-699, 195-209` | one lane-day |
| `MidiSettingsView.swift:54-59, 220, 338-342` | ✕ clear-binding, "Import Map…" | the engine refuses both in common cases; `sendCatalog` **discards** `StudioCommandResult`, so refusals are invisible and the row snaps back | read Swift + Rust | one lane-day (**one change fixes 3 rows**) |
| `GenerationQueue.swift:791-813` + `GenerationQueueView.swift:203-208` | job ✕, `.help("Cancel generation")` | calls `stopProcessing()`, which cancels **every pending job too** — clicking the X on one job silently discards the whole queue. For **remote/cloud** jobs only the Swift `Task` is cancelled and the status is faked to `.cancelled`; neither service exposes an abort, so the server keeps generating (and billing) | read both | one lane-day |
| `SetupWizard.swift:967-980` | 6-step wizard ending on "Setup Complete!" | `totalSteps = 6` but content cases are 0–5, so "Next" at step 5 lands on a **blank screen labelled "Step 7 of 6"** (`:131`) — and `applySettings()` is reachable only from that phantom step | read `:40, 52-67, 131, 967-980` | one line |
| `SetupWizard.swift:906-932` | completion checklist: green ✓ "LLM Configured", "Studio Copilot: Connected" | `icon: "checkmark.circle.fill"` is passed for **every** row regardless of state; "LLM Configured" is hard-coded `.green` and shows green with OpenRouter selected and an empty API key | read | one line each |
| `SetupWizard.swift:473-478` | "Install Automatically" → "Installation complete!" | Python returns `already_installed` because the **directory exists** (`rpc_server.py:584-597`) and ships a `validation` field Swift drops (`BackendViewModel.swift:1702`). A half-downloaded install reports success | read both | one lane-day |
| `SetupWizard.swift:1030` / `Main.swift:151-153` | "Skip for Now" / Esc | `HasLaunchedBefore` is written only in `onComplete`, reachable only from the phantom step — so Esc-dismissing re-opens the wizard every launch | read | one line |
| `AgentEditorView.swift:79-83` | "Built-in agent 🔒" | label only; Save is enabled, `upsert` persists, `normalize` keeps the edits | read + `AgentStore.swift:49-110` | one line |
| `LicenseEntryView.swift:65-69` | "✓ activated — restart the app for changes to take effect" | the key is genuinely verified and stored, but nothing reads `tier`/`isLicensed`, so nothing changes after the promised restart (and the view is unreachable anyway) | read + grep | needs design |
| `ChatView.swift:869-876` | Send | `.disabled(inputText.isEmpty)` only — not disabled while `backend.isThinking`, and `sendChatWithHistory` has no re-entry guard. A second Send starts a concurrent `ask_majik`; both read shared `backend.lastReply` | read `ChatView.swift:229-274`, `BackendViewModel.swift:463-520` | one line |
| `EnhancedStudioView.swift:1986` | *"Duration 0 = double the source length"* | the duration `Slider` range is `10...maxDuration` (`:1293`). 0 is unreachable | read | one line |
| `SettingsView.swift:721` | "Moving audio files…" | set once before one blocking call; never updated through the artwork/stems/metadata phases. Static text posing as progress | read `:717-743` | one lane-day |
| `StudioHelp.swift:225-227` | *"Set it to **1/4** and things land on beats"* | `StudioSnapMode` has four labels: `Off`, `Bar`, `Beat`, `1/16` (`StudioTimelineMath.swift:9-23`). There is no 1/4 | read the enum | **FIXED — §11** |
| `SterlingBrigade.swift:20-26, 188` | *"routing … and publishing a Studio-built agent … are the remaining follow-ups"* | both shipped. Routing: `StudioCopilotDock.swift:58-63` → `StudioCopilotModel.swift:154` → `RoutedCopilotBackend.send` (`Engine/SterlingCopilotBackend.swift:67-73`). Registration: `BrigadeRegistrationService.register` (`Studio/BrigadeRuntime.swift:262-290`), reached from `AgentEditorView.swift:494` | read all six sites | **FIXED — §11** |
| `StudioHelp.swift:688-690` | Takes: *"**Every recorded pass** … so nothing you played is ever lost"* | Takes are generative results; the browser's own empty state says *"Takes from Revise, Extend, and Add a Layer land here."* (`StudioTakesBrowser.swift:24-26`). See the correction in §10 — recorded takes *do* reach the list, but the "safety net" framing is not the product | read all three | one line (reword) |
| `StudioHelp.swift:694-695` | Files: *"Audio files **on your disk** that you can **drag straight onto a track**"* | the rows are built from `snapshot.tracks` filtered to `.imported` — clips already in the project — and are a plain `HStack` with **no `.onDrag` and no gesture** (`StudioBrowserView.swift:192-215`). The pane's own header, "Imported files", is correct; the help is not. `StudioLibrarySongRow:351` *does* carry `.onDrag`, so the omission shows by contrast | read `:178-216` | one line |
| `StudioHelp.swift:691-693` | Stems: *"… **so a part can be changed on its own**"* | `ForEach(model.snapshot?.tracks ?? [])` — every track, including MIDI instrument tracks that are not stems — as inert `HStack`s with no gesture (`StudioBrowserView.swift:159-175`) | read | one line |
| `StudioEngineFactory.swift:45-53` | *"**The UI uses it** to say so rather than presenting a demo clip as if it were the user's work"* | `grep -rn "noteEngineIsReal" src/swift/` → **1 hit, the definition.** No call site, not even a test. Mitigated in practice — see §10 | grep | one line |
| `StudioTakesModel.swift:17-24` | `isAlternativeKind` *"drives the browser's default filter"* | `grep -rn "isAlternativeKind" Sources/ Tests/` → **1 hit, the definition.** The default filter is `auditionableOnly` against the engine's boolean (`:143`) | grep | one line |
| `StudioCommandPalette.swift:32,75,79` | comment says "(71)"; every row subtitled *"command catalog v1"* | the array holds **74**; the shipping catalog is **v2 / 113**, and 39 v2 commands never appear in the palette | parsed both | one line |
| `StudioHelp.swift:666-668` | record scope: *"the last moment of your input drawn as a **wave**"* | `StudioInputScope` (`StudioRecordBar.swift:408-451`) draws a mirrored polygon over one scalar per 30 Hz tick from `StudioMeterScale.norm(meter.peakDB)`. Real data, wrong noun — a level *envelope*, not a waveform | read | one line |

### 4b. `HelpView.swift` — the in-app manual

The 1265-line Help page is the highest-density source of untrue statements in the app.

| file:line | claim | reality | verified |
|---|---|---|---|
| `:422-441` | "Memory Optimization: **Unload LLM**, **Unload All Models**, **Reload LLM**" | **no user-facing control for any of them.** `unloadLLM`/`unloadModels` fire only automatically (`LLMSettingsView.swift:551`, `:1204`, `GenerationQueue.swift:781`). "Reload LLM" does not exist at all — no UI, no RPC, no Python method | grep across Swift + Python |
| `:533` | OOM fix: "Unload unused models with the **Memory menu**" | there is no Memory menu. `Main.swift`'s CommandMenus are Library, Playback, Publisher, View, Window | read `Main.swift:223-382` |
| `:620`, `:721` | "Check the logs at `~/Library/Logs/MajiksMusicStudio/`" | that path appears **nowhere in the repo** except these two strings; `AppLog` writes to stderr only | repo-wide grep → 2 hits, both `HelpView` |
| `:283` | Export "MP3, 192k or 320k" | `ExportFormat` has 3 cases: wav, flac, m4a (`ExportView.swift:6-9`). No MP3 path | read |
| `:736` | StatCard "**6** Export Formats" | 3 exist; the page itself lists 4 | read |
| `:735` | StatCard "**9** Keyboard Shortcuts" | the page lists 18; `Main.swift` defines 26 `.keyboardShortcut` calls, plus ~14 in `Studio/` | counted |
| `:483`, `:583` | "**⌘⇧F** Show Audio Folder" (twice) | `Main.swift:262` binds **⌘⇧D**; ⌘⇧F is bound to nothing | read |
| `:169` | Step 4: 'Click "**Send to Studio**" to transfer parameters' | no such control in ChatView. The handoff is "Send to The Engineer". "Send to Studio" exists only in the **Library** | grep → 3 hits |
| `:170`, `:347` | "the **Studio** tab"; "Chat \| Studio \| Library \| Publisher tabs" | six tabs: Chat, **Create**, Studio, Stems, Library, Publisher (`ContentView.swift:103-132`). The tab Help calls "Studio" is now "Create"; the tab now called Studio is the DAW. Stems and Create are undocumented | read |
| `:172` | "Your track will appear in the **Library** when complete" | generated tracks land in staging; `collectAudioURLs()` **explicitly skips** the staging directory (`LibraryStore.swift:176-179`). The user must toggle Keep and click "Save Selected to Library" | read |
| `:330-331` | "Cancel & **Reorder** the queue while generation is in progress" | `moveJob` exists but no `.onMove`/`.draggable` in `GenerationQueueView.swift` | grep |
| `:219` | "Generate 1-5 variations **simultaneously**" | sequential within a target (`GenerationQueue.swift:223-229`) | read |
| `:366` vs `:973` | "Publisher (**Optional Upgrade**)" vs "Publishing to majiks.online is **free**" | self-contradictory in one file, and no upgrade path exists | read both |
| `:713`, `:717`, `:583` | `…/MajiksMusicStudio/audio/`, `…/staging/` | actual: `Audio/` (capital A) and `Audio/staging/` (`FileStore.swift:59-61`) | read |

### 4c. `README.md` — the top-of-funnel claim

The brief flags README falsehoods as mattering most. The quantize claim is confirmed gone
(`grep -rni "quantize" README.md` → 0 hits). One remains, stated twice:

| file:line | claim | reality | verified |
|---|---|---|---|
| `README.md:33` | *"…and export to WAV/FLAC/**MP3**/M4A."* | `ExportFormat` has exactly three cases — `wav`, `flac`, `m4a` (`ExportView.swift:6-9`). **There is no MP3 export path.** Every MP3 reference in the codebase is *import* (`LibraryView.swift:1416`, `LibraryStore.swift:183`, `Info.plist:13`) or the cloud service *downloading* one (`ACEMusicCloudService.swift:189-196, 513-517`) | read the enum; grep MP3 across Swift + Python |
| `README.md:113` | *"**Professional Export** — WAV, FLAC, **MP3 (192k/320k)**, M4A/AAC (128k/256k)."* | same — and the bitrate half is wrong too: `bitrateRange` is `128...256` for m4a and `256...256` otherwise (`ExportView.swift:78-83`). There is no 192k and no 320k anywhere. The **M4A/AAC (128k/256k)** half *is* accurate | read `ExportView.swift:55-143` |
| `HelpView.swift:283` | `FormatItem(format: "MP3", description: "Lossy, 192k or 320k bitrate options")` | the in-app manual repeats the identical false claim | read |

A user reads the README, buys or downloads for MP3 export, and finds three formats, none of them MP3.
Category **C**. Fix: **one line** in each of the three places.

Two more README defects, both verified:

| file:line | claim | reality | verified |
|---|---|---|---|
| `README.md:152, 157` | `cd majiks-music-studio/**macos**/src/swift` … "see `**macos**/build-release.sh`" | **`ls -d macos` → No such file or directory.** `src/swift/` and `build-release.sh` are at the repo root. The copy-pasteable build instructions fail at step 2, for every contributor, immediately | ran `ls`; confirmed both paths at root |
| `README.md:101` vs `README.md:327` | *"Generate tracks up to **10 minutes**"* vs *"Up to **8 minutes** (480s) on remote servers"* | The README contradicts itself, and neither number is what a default user gets: `maxDuration` is `serverURL.isEmpty ? 480 : 180` (`EnhancedStudioView.swift:1109-1111`), so **local-only users are capped at 180 s (3 min)** — and `:101` is in the paragraph headed "Local-First Generation" | read both README lines and the slider bound |

### 4d. `docs/` — the user manual and concept guide

| file:line | claim | reality | verified |
|---|---|---|---|
| `docs/USER_MANUAL.md:122-123` | *"It is a **visual countdown only; the app does not play a click**."* | **Inverted — the manual denies a shipped feature.** The count-in is audible: `StudioViewModel.beginCountIn` (`:541-572`) sends `setMetronome(countInBeats:)` and the engine clocks the beats **per frame** off its own counter, so they sound whether or not the metronome is on. `render/src/dsp/click.rs` is a real generator; `render/tests/metronome.rs` pins it. This is the rarer failure: docs that under-claim, so a user never tries a feature that works | read the manual and `beginCountIn` in full; independently confirmed the engine click path |
| `docs/CONCEPTS.md:23` | *"In magnetic mode, moving a clip will cause nearby clips to **shift rather than overlap**."* | No ripple/shove edit exists. `grep -rniE "\bripple\|\bshove\b\|pushNeighbo\|displaceClip"` over `src/swift/Sources` + `engine/*/src` → **0 hits** (an earlier looser grep returned 33, all of them `isHovered` — recorded so nobody repeats the false positive). An overlapping move **errors**: `apply.rs:2008` `self.check_overlap(dest, exclude, *start_ticks, length)?` | ran both greps; read the apply site |
| `docs/CONCEPTS.md:29` | *"**Full-screen timeline mode is available.**"* | `grep -rniE "full[- ]?screen\|maximi[sz]e"` over `src/swift/Sources` + `engine/*/src` → **0 hits**. Only per-pane collapse toggles exist | ran the grep |
| `docs/USER_MANUAL.md:207`, `docs/CONCEPTS.md:21` | *"A **three-band** EQ (low shelf, mid bell, high shelf)"* | It is **four-band**: `EQ_BANDS = 4` with `BAND_DEFAULT_HZ = [80, 400, 2500, 8000]` (`render/src/dsp/biquad.rs:13, 32`). The UI's own accessibility label says "EQ, 4 bands" | read the const and the label |
| `docs/CONCEPTS.md:67` | *"The inspector displays lineage as a **mini-tree** when a clip is selected."* | The panel body is the literal string *"The full parent chain … renders here when the journal read surface lands."* (`StudioInspectorView.swift:176-181`) | read |
| `docs/CONCEPTS.md:39` | Extend: *"You **drag the project edge into ghost bars**"* | No such gesture; `StudioDragKind` has no case for it. (The **E** key half is real.) | read the enum |
| `docs/USER_MANUAL.md:57-59` | Preview build: *"the app **tells you so** rather than pretending."* | The engine produces the refusal and **no view renders it** — this is the `landingError` hole in §1.5. The manual promises exactly the behaviour that is missing | grep, 3 hits, 0 reads |
| `docs/USER_MANUAL.md:89-90` | *"Undo history is **kept with the project**, so you can step back even after saving."* | Undo survives ⌘S in-session, but on **reopen** the fast path skips checkpointed entries (`package.rs:138-168`, `:311`; `session.rs:589-591`), so undo depth is 0. **UNVERIFIED at runtime** — settled by reopening a saved package and pressing ⌘Z |
| `docs/MCP_API.md:16-17, 21-22` | "Catalog version: **1.1** · Tool count: **109**" / "The **86** command tools … other **23**" — while `:10` calls the generated JSON "the source of truth" | that source says `catalogVersion: "2.0"`, `toolCount: 138`. The doc body enumerates 100 names, so **38 real tools are undocumented**, including every `studio_note_*`, `studio_fx_*`, `studio_route_*` and `studio_device_*`. Because no doc name is *fake*, the JSON-vs-registry parity test cannot catch it | read the doc header and the generated JSON |
| `engine/contracts/COMMAND-REFERENCE.md:2-3` | "Generated from command-catalog **v1** … all **71** command names" | the engine embeds **v2 / 113** (`catalog.rs:23` `include_str!(…v2.json)`). 42 commands undocumented — all of `note.*`, `fx.*`, `route.*`, `device.*` | counted both JSONs |
| `COMMAND-REFERENCE.md:405` | `export.stems`: `format ("wav", "flac")` | refuses anything but wav (`host.rs:2811-2816`). **The code comment directly above the refusal claims it is "matching the catalog format enum (wav\|flac)" — it is not.** A comment that contradicts the four lines under it | read `host.rs:2806-2816` |
| `ASSESSMENT-competitive-parity.md:3, 21, 182, 324, 399, 475` | dated at v3.4.6; headline *"they **cannot set the tempo**, **cannot hear a metronome**"*; and four live references to a README quantize claim, incl. action item 0.2 "delete the quantize claim (`:223`)" | all fixed at this tip. Tempo is editable (`StudioTransportBar.swift:209`), the metronome and count-in are audible, and the README quantize line is gone. **A sibling assessment in this very directory is now itself a source of false claims, and its remediation table still bills fixed work as open** | read the sites; `grep -rni "quantize" README.md` → 0 |

---

## 5. Category D — fake data

| file:line | display | fed by | verified | fix |
|---|---|---|---|---|
| `StudioTransportBar.swift:317-318` | master L/R meters | `0.55 + 0.25 * abs(sin(t * 2.1))` — never touches `model.snapshot`; wiggles on a silent or fully-muted project | read | one line — **lane in flight, do not duplicate** |
| `EnhancedStudioView.swift:2298-2316` | the **Arrangement** panel's background waveform | `(0..<500).map { CGFloat.random(in: 0.25...1.0) }` (`:2303`); call site `:2254` | read both | one lane-day |
| `EnhancedStudioView.swift:2862-2884` | the waveform on **every generated-variant card** | `(0..<40).map { CGFloat.random(in: 8...32) }` (`:2864`); call site `:2472`. It is a `static let`, so **every card shows the identical 40 bars** | read both | one lane-day |
| `EnhancedStudioView.swift:22-31, 74-79` | the Arrangement itself | `sections` is only ever `Self.defaultSections` — a hardcoded Intro/Verse1/Hook/Verse2/Hook/Outro at fixed 0–170 s, never derived from any track, rendered unconditionally even with zero variants | grep → 5 hits, no data source | needs design |
| `EnhancedStudioView.swift:331, 2564-2571` | 3 filled yellow stars, a11y "3 out of 5 stars" | `rating: 3` hardcoded on construction; no backend supplies it and there is **no tap handler** — the user cannot change it | read; grep `.rating` → 3 hits, all reads | one line |
| `AlbumArtGenerator.swift:36-37` | every procedural cover | `seed.hashValue` — per-process random (see §4a) | read; env-var grep → 0 | one line |
| `RealStudioEngine.swift:563` | Takes row kind label | engine `"record"` → Swift `.other` → **"Other"** (see §10 correction) | read | one line |
| `SetupWizard.swift:1148-1157`, `DownloadManager.swift:135-147` | "Downloaded ✓" | `FileManager.fileExists` on the HF cache **directory** — an aborted download leaves that directory, so a partial model shows green | read | one lane-day |

Both fake waveforms sit in a codebase that already has three real ones — `AudioWaveformView`,
`CompactWaveformView`, `InteractiveWaveformView` (`PersistentPlayerBar.swift:27,123`,
`EnhancedStudioView.swift:74`, `StemSessionsView.swift:974`). The generated-variant card is the most
looked-at surface in the Create flow, and its waveform is noise.

---

## 6. Contract-level defects — agent-facing, not GUI

These do not lie to a human in the GUI; they lie to an **agent or MCP client** reading the published contract.

**Inventory, counted rather than assumed:**
- catalog = **113** commands (`command-catalog.v2.json`; corroborated by `agent-surface/tests/parity.rs:54`).
- MCP tools = **138** (`engine/docs/generated/mcp-tools.v1.json` → `toolCount: 138`, `catalogVersion: "2.0"`,
  `excludedCommands: ["gen.landed"]`). *(The brief said 137.)*

Three stale self-descriptions found while counting:
`registry.rs:1` says "GENERATED from `command-catalog.v1.json`" (it reads v2 via `catalog.rs:23`);
`StudioMCPServer.swift:10` says "the generated **109-tool** registry" (138);
the manifest is named `mcp-tools.**v1**.json` while its own `catalogVersion` is `2.0`.
`cmd.rs:2` still claims "87 commands, catalog v1.1" while the enum carries all 113.

| where | claim | reality |
|---|---|---|
| `export.master/.stems/.region` | `format` enum includes `"flac"` | refused at runtime: `host.rs:3957-3959` returns `Unsupported("FLAC export lands with the IO codec pass; v1 exports WAV (24-bit) or AAC")` |
| `export.master` | `sampleRateHz` enum is `[44100, 48000]` | any value ≠ the project rate is refused (`host.rs:3757-3769`) |
| `take.auditionMix` | *"Select which stems … are **audible**"* | `unjournaled_noop()` (§1.3) |
| `autolane.show` | "Show or hide an automation lane in the timeline UI" | `unjournaled_noop()` (`apply.rs:879-885`). Correct for the GUI (lane visibility is Swift-side, `StudioViewModel.swift:50`) but an agent gets `ok: true` and nothing moves |
| `gen.cancel` | self-discloses the gap | `cancel_generation` is a single global `threading.Event()` (`rpc_server.py:164, 498`), not per-`requestId`. Honest — and correctly cleared per run (9 `clear()` sites), so it does not permanently poison the backend |

**Note on FLAC.** The GUI is *not* exposed to this: `StudioExportFormat` is `case wav, aac`
(`StudioExportModel.swift:26-27`). The shorthand "FLAC is offered and refused" implies a broken button that
does not exist. It is a contract-surface defect only.

### `take.purge` — the app's one destructive disk operation is off-journal

The catalog advertises `take.purge` as `journaled: true, undoable: true`, and `apply.rs:2977-2996` implements
exactly that: it marks the take `Offline` with a `TakeRestore` inverse.

**The app does not use it.** The purge button (`StudioTakesBrowser.swift:41`) → `RealStudioEngine.purgeTakes`
(`:594-602`) calls the tool `studio_purge_takes`, whose host implementation (`host.rs:3467-3554`) computes a
protection set and then calls `std::fs::remove_file` directly. `grep -n '"take.purge"' engine/agent-surface/src/`
→ **1 hit, `registry.rs:37`, which is the `MANAGE_COMMANDS` tier list, not a submit site.** No journal entry
is written; take status stays `Candidate` while the audio is gone.

So: the only irreversible operation in an otherwise fully-undoable app is the one that is not journaled, and
an agent using the catalog command gets **different semantics** than the human pressing the button. Category
**C** (contract) + a real durability concern. Fix: **needs design**.

### Engine state journaled, undone, persisted — and never rendered

**`clip.crossfade.set`.** `apply.rs:2360-2423` writes only `self.crossfades`; it never touches
`fade_in_frames`/`fade_out_frames`. `grep -n "crossfade" engine/render/src/compile.rs` → **0 hits**; every
"crossfade" elsewhere in `engine/render` is the unrelated session-swap declick.
`Project::crossfade_is_active` (`model.rs:1331-1333`) → `grep -rn "crossfade_is_active"` → **1 hit, the
definition.** It round-trips through `package.rs:797-800, 1175` and produces no audio.
*Trap for reviewers:* the Inspector's "Crossfade" slider (`StudioInspectorView.swift:260-266`) is
`reviseCrossfadeMs`, handled by `revise/splice.rs` — a different mechanism that does work.

**`clip.phaseAnchor.set`.** `apply.rs:2470-2480` writes `clips[ci].phase_anchor_ticks` (`model.rs:210`,
*"Timeline bar-grid phase anchor for warped source playback"*), restored on undo (`apply.rs:589-593`),
serialized (`package.rs:759-760, 1570`), covered by four test files. **The render crate never reads it.** Every
`phase_anchor` hit under `render/` is the *project*-level anchor driving the metronome click grid
(`dsp/click.rs:69,141`, `params.rs:517-537`) — a different field (`model.rs:1158`). The project-level twin
**is** wired (`host.rs:1457-1461`); the clip-level one is inert. Same lane, one real, one not.

Both are the same shape as `clip.warp.set`, which another lane is already fixing.

---

## 7. Cheap wins — under an hour each

1. `StudioHelp.swift:227` — "1/4" names a snap option that does not exist. ✅ **applied**
2. `SterlingBrigade.swift:20-26, 188` — the "deferred" disclaimer describes two shipped features. ✅ **applied**
3. `HelpView.swift:620, 721` — delete the `~/Library/Logs/MajiksMusicStudio/` path; it does not exist.
4. `HelpView.swift:483, 583` — ⌘⇧F → ⌘⇧D.
5. `HelpView.swift:735, 736` — the StatCards ("9 shortcuts", "6 export formats") contradict the same page.
6. `HelpView.swift:283` — remove MP3 from the export list.
7. `HelpView.swift:170, 347` — the tab list is two names and two tabs out of date.
8. `EnhancedStudioView.swift:472-481` — delete `generateVariantNote`; it fabricates and then **persists** a lie.
9. `EnhancedStudioView.swift:719` — the variant `.help` promises parallelism and seed variation; neither happens.
10. `AlbumArtGenerator.swift:36` — swap `seed.hashValue` for a stable hash. One line, and it fixes published cover art.
11. `StudioTakesModel.swift:14-15` — add the `record` case so a recorded pass is not labelled "Other".
12. `StudioTakesModel.swift:19-24` — `isAlternativeKind` has no call sites; delete it or wire it.
13. `StudioCommandPalette.swift:32, 75, 79` — "(71)" is 74, "catalog v1" is v2.
14. `StudioViewModel.swift:141, 151, 160, 1256` and `EnhancedStudioView.swift:1033-1061` — route through `ToastManager`.
15. `MidiSettingsView.swift:54-59` — surface `StudioCommandResult`; **one change makes three silent failures visible**.
16. `EnhancedStudioView.swift:2452` — `isPicked` is permanently false; delete the unreachable check + border.
17. **`README.md:152, 157`** — the `macos/` path in the build instructions does not exist. Every contributor
    hits this on their first command. Highest value-per-character in the list.
18. `docs/USER_MANUAL.md:122-123` — delete "the app does not play a click"; it does.
19. `docs/CONCEPTS.md:23, 29` — delete the ripple-move and full-screen-timeline sentences; neither exists.
20. `docs/USER_MANUAL.md:207`, `docs/CONCEPTS.md:21` — "three-band EQ" is four-band.
21. `README.md:101` vs `:327` — the two duration claims contradict each other and both overstate the local cap.
22. Regenerate `docs/MCP_API.md` and `engine/contracts/COMMAND-REFERENCE.md` from catalog v2. This is the
    single highest-leverage doc fix: **38 MCP tools and 42 commands are currently invisible to agents**, and
    the parity test cannot catch it because no documented name is fake — only absent.
23. `engine/agent-surface/src/host.rs:2809-2810` — the comment claims it matches the catalog enum `wav|flac`
    four lines above the code that refuses flac. Fix the comment or the enum.

Items 1–2 are applied here. The rest were left deliberately: several are user-facing copy decisions, and
8–11 and 14–15 change behaviour and deserve their own lane with mutation checks.

---

## 8. Architecturally blocked — needs a decision, not work

- **Publish from Studio.** `RealStudioEngine` is an FFI actor with no `BackendViewModel` handle, and the real
  publisher is on the Python RPC bridge behind Keycloak OAuth. Whether the engine reaches the backend or the
  dialog does is a layering decision. Until it is made, the button must stop claiming success.
- **The four half-built generation modes.** Repaint, Extract, Lego and Auto-Complete are selectable and
  described, and none has UI for its defining parameter or a source-audio picker. Either hide them behind the
  two that work, or build four control sets. This is the largest single gap in the product.
- **Licensing.** Ed25519 verification works and nothing reads the result; `canPublish` is hard-coded `true`;
  the only view that enters a key is unreachable. Either the tier model ships or the scaffolding comes out.
- **Region export / a ruler loop region.** The ruler owns *selection*; the transport owns *loop*. Making a
  ruler drag set the transport loop changes what it means for the audition flow, which already drives
  `transport.loop.set`. Needs a precedence decision.
- **Clip-level lineage.** "Retake" and "More like this" both need a clip → take lineage lookup the snapshot
  does not carry. `engine.takes(query:)` already returns lineage, so a partial path exists; the open question
  is whether the clip snapshot gains the field or the inspector queries takes.
- **Automation beyond volume/pan.** The engine resolves 11 `ParamRef` families and refuses per-frame ones it
  cannot render, by key, with a typed reason (`rt.rs:238-264`). Exposing them needs a lane-picker design and a
  decision about block-rate (`Coefficient`-class) params.
- **`take.purge` durability.** The human button deletes bytes off-journal while the catalog advertises an
  undoable purge. Reconciling them is a data-durability decision.
- **Per-job generation cancel.** The Python backend's cancel is one global flag; per-`requestId` is the Gen
  Protocol's target and the catalog says so. Until it lands, `cancelActiveJobs()` must not be wired.

---

## 9. Contradictions with the brief's premises

Recorded because the brief asked for them.

1. **The MCP manifest is 138 tools, not 137** (`mcp-tools.v1.json` → `toolCount: 138`).
2. **The palette lists 74, not 71** — its own comment says "(71)". 11 wired, so **63** inert rows, not 60.
3. **"FLAC and 44.1 kHz are offered in the export catalog and refused at runtime"** is true of the *catalog*
   but not of any GUI control: `StudioExportFormat` is `case wav, aac`. It is an agent-facing defect only.
4. **Four of the listed examples are already fixed** at this tip — solo, send automation, the metronome and
   count-in, the piano roll's mock engine, and `StudioProvenancePreview`. Evidence in §10. The transport
   meters and `clip.warp.set` are still present and have lanes in flight.
5. **The README's quantize claim is gone** — `grep -rni "quantize" README.md` → 0 hits. Two ghosts remain: a
   mock MIDI binding targets `tools.quantize` (`StudioMockEngine.swift:2073`), a command that does not exist
   in the catalog (`[n for n in names if n.startswith('tools')]` → `[]`); and
   `ASSESSMENT-competitive-parity.md` still cites the removed README line four times, including an open
   action item to delete it.
6. **A neighbouring document in this directory is now a source of false claims.**
   `ASSESSMENT-competitive-parity.md:21` leads with *"they cannot set the tempo, cannot hear a metronome"* —
   both fixed in 3.4.7, which is this tip. If that assessment is quoted externally it is wrong today. Any
   audit in this folder, **including this one**, should carry the commit it was verified against;
   this document names `2965425`.

---

## 10. Checked and found TRUE — and three corrections

Recorded so nobody re-litigates them, and so the three near-misses are on the record.

**Corrections made during verification — rows that were withdrawn:**

- **Key detection is real, not a lie.** `StudioHelp.swift:221` says the key *"is detected from the audio when
  a song is opened here."* A narrow grep suggested no detector existed. There is one:
  `engine/media/src/key.rs` implements Krumhansl–Kessler chroma correlation, and
  `agent-surface/src/landing.rs:596-608` uses `measured_key` as the fallback. **Row withdrawn.**
- **The Takes `record` gap does not hide recordings.** The engine classifies a recording as a take
  (`host.rs:2070` → `take_kind` `:4025` → `"record"`, auditionable at `:3359`), and Swift's `StudioTakeKind`
  has no `record` case, so `RealStudioEngine.swift:563` buckets it as `.other`. My first reading was that this
  filters recorded takes out. It does not — the default filter tests `item.auditionable`, the engine's boolean
  (`StudioTakesModel.swift:143`). The real consequence is narrower: a recorded pass is **labelled "Other"**
  and search matches "other" rather than "record". **Severity downgraded from A to C/D.**
- **The mock-engine fallback is surfaced, so `noteEngineIsReal` is less severe than it looks.**
  `makeNoteEngine()` returns the mock only when `shared` is not a `RealStudioEngine`, and in exactly that case
  the transport chip renders `"mock"` (`StudioMockEngine.swift:1653` supplies `engineLabel: "mock"`; the chip
  reads it at `StudioTransportBar.swift:351-358`). The comment is still false; the user-visible hole is
  largely covered. **Severity downgraded.**

**Confirmed working:**

- **Solo is audible.** `render/src/params.rs:568-620` — `track_gain_target` and `track_gate_target` share one
  `gated()` predicate so a pre-fader send cannot survive a solo; `host.rs:145` pushes it and
  `clear_track_solos_from` handles the stale-slot hazard. The historical bug is fixed.
- **Send automation reaches the render loop.** `rt.rs:975-1034` reads `send_a_lane`/`send_b_lane` and advances
  the slews. No longer a dead lane slot.
- **The metronome clicks and the count-in is audible.** `render/src/dsp/click.rs` is a real generator with a
  project-phase-anchored grid (`:135-141`); `StudioViewModel.beginCountIn` (`:541-572`) sends
  `setMetronome(countInBeats:)` to the engine, which clocks beats per frame, and keeps the on-screen countdown
  as the *visual* half only.
- **The piano roll runs on the real engine.** `StudioEngineFactory.makeNoteEngine()` (`:33-43`) returns the
  real engine when present and `NSLog`s the degradation otherwise.
- **`StudioProvenancePreview` no longer hardcodes `generative: false`.** `StudioExportModel.swift:173-200`
  derives from `clip.origin`, preferring the engine's own field (`RealStudioEngine.swift:850-851`; emitted at
  `export.rs:242`, `host.rs:3053`).
- **Track FX, buses and routing are audible.** `render/src/routing_rt.rs` exists and `rt.rs` evaluates the
  insert chains, so removing the "STORED, NOT YET AUDIBLE" badge (`StudioRoutingView.swift:65`) rested on a
  true premise. `rt.rs:238-264` additionally **refuses by key** any automation lane the renderer cannot read,
  with a typed reason — an explicit anti-inert mechanism pinned by `render/tests/inert_lanes.rs`.
- **`StudioViewModel.swift:1498-1500`'s `sin`/`cos`** is a scripted pan/zoom perf-sweep driver, not a display.
- **All mixer, routing and record-scope meters are engine-sourced.** The transport bar's are the only faked
  ones. `StudioRoutingView.swift:148` draws **nothing** when the engine reported no reading.
- **The EQ curve is a genuine RBJ biquad evaluation** (`StudioMixerControls.swift:307-348`), not a decorative spline.
- **Transport, mixer, routing/FX, piano roll, track headers, automation lanes, on-screen keyboard, copilot
  dock and the export dialog (apart from Publish and Region)** all reach real journaled commands — verified
  control-by-control.
- **`ManageModelsView.swift:442`'s "placeholder"** genuinely resolves: `loaded = false` → detached scan →
  `apply(snapshot)` sets `loaded = true` (`:469`), swapping in real `directorySize` figures.
- **`MidiSettingsView.swift:532`'s no-op-guard comment is true** — `commitIfChanged()` really does guard on
  `draft != lastCommitted` (`:570-572`).
- **All 8 `Main.swift` menu-item notifications have live receivers.**
- **HelpView claims verified true:** 9 LLM providers, 8 sort options, 5 filter categories, 3 view modes,
  3 model sizes, 150 art combinations (15 palettes × 10 patterns), the macOS 14 floor, 10 rolling backups,
  Art Studio on :8420, MPS cache clearing, the green playing badge, DMCA filing, CFG 1.0–20.0 default 4.5,
  and every keyboard shortcut except ⌘⇧F.

---

## 11. What this lane changed

Two fixes, both pure user-facing strings that removed outright falsehoods, chosen because they carry no
behavioural risk. Everything else is left to owning lanes.

1. **`Sources/Studio/StudioHelp.swift:227`** — the snap help told users to *"Set it to 1/4"*. `StudioSnapMode`
   offers `Off`, `Bar`, `Beat`, `1/16`. Now names the real options.
2. **`Sources/Studio/SterlingBrigade.swift:188`** (settings copy) **and `:20-26`** (file header) — both said
   Brigade routing and agent registration were "the remaining follow-ups"/"STUBBED". Both shipped:
   `RoutedCopilotBackend.send` dispatches `.brigade` (`Engine/SterlingCopilotBackend.swift:67-73`), and
   `BrigadeRegistrationService.register` posts to `/api/v1/agents` (`Studio/BrigadeRuntime.swift:262-290`).
   The copy now tells users the feature exists and states the real caveat (a Brigade agent chats but cannot
   drive the timeline). The header records what actually shipped.

No behavioural code was touched. No test asserts on either string
(`grep -rn "1/4\|Set it to\|remaining follow-ups" Tests/` → 0 hits).

### Verification

Raw exit codes, unfiltered, never piped through `tee`/`tail`.

| step | command | result |
|---|---|---|
| engine | `cd src/swift && ./scripts/build-engine.sh` | `EXIT=0` |
| baseline (pristine tree, real engine) | `swift test` | `EXIT=1` — **355 tests in 67 suites, exactly 1 issue**: `StudioMCPHostTests.swift:177` (the known pre-existing keychain failure) |
| mock build | `MAJIKS_ENGINE=mock swift build` | `MOCK_BUILD_EXIT=0` |
| real build | `MAJIKS_ENGINE=real swift build` | `REAL_BUILD_EXIT=0` |
| after fixes | `swift test` | `TEST_EXIT=1` — **355 tests in 67 suites, exactly 1 issue**, the same one |

The failing-issue sets are **byte-identical** between baseline and after, modulo wall-clock timings:

```
diff <(grep '✘' baseline-test.log | sed 's/after [0-9.]* seconds//') \
     <(grep '✘' after-test.log    | sed 's/after [0-9.]* seconds//')   # → no output
```

The baseline was captured on the pristine tree **before** any edit, on a genuine real-engine run —
`MajiksEngine.xcframework` present and `Tests/StudioPianoRollRealEngineTests.swift` (which is entirely inside
`#if REAL_ENGINE`) **compiled**, so the flag really reached the test target rather than compiling the file to
nothing and reporting a cheerful pass.

**Artifact check, not disk check.** Neither string is covered by any test
(`grep -rn "1/4\|Set it to\|remaining follow-ups" Tests/` → 0 hits), so a green suite proves nothing about
them and is not offered as proof. The proof is the built binary:

```
strings .build/arm64-apple-macosx/debug/MajiksMusicStudio | grep -c "Set it to Beat and things land on beats"  # 1
strings .build/arm64-apple-macosx/debug/MajiksMusicStudio | grep -c "Set it to 1/4"                            # 0
strings .build/arm64-apple-macosx/debug/MajiksMusicStudio | grep -c "Pick one in the Copilot dock"             # 1
```

The new copy is in the shipped artifact and the old lie is gone from it.
