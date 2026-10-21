# Competitive parity assessment — Majik's Music Studio vs Ableton Live and the field

**Branch:** `feat/ms-342` @ `8508127` (v3.4.6) · **Date:** 2026-07-26 · **Method:** read of the tree only. No GUI instance was launched. No product code was changed.

**The question this answers**, as the owner asked it:

> "Do we have all the tools and features of Ableton and the competition, and does it function and is it usable in an intuitive way for someone who's familiar with that software?"

---

## 0. Headline verdict

**No. Not at parity, and not close on the axis that decides purchases.**

The engine is genuinely strong — in places better-engineered than the commercial field. The **product** is not, because a large fraction of that engine has no control attached to it. This is not a DSP problem. It is a wiring problem, and that is good news: most of the gap is cheap.

Stated precisely, three sentences the owner can quote:

> **The audio engine is at roughly 60% of Ableton Live Standard's feature surface and is architecturally better than Live's in determinism, provenance and agent control. The application on top of it exposes roughly half of that engine, so what a musician can actually reach is closer to 30%. An experienced Ableton user opening this today cannot complete a track end to end: they cannot set the tempo, cannot hear a metronome, cannot load a sample, cannot place a marker, cannot use their own plugins, and cannot find a Session View — and four of those five are wiring, not engineering.**

**Shortest credible path to "a musician can make a track end to end without hitting a wall":** roughly **6–9 lane-weeks** of work, almost all of it in Swift, none of it requiring new DSP. See §6. That gets to *usable*. It does not get to *parity* — parity requires plugin hosting (§7), which is blocked on a design decision only the owner can make.

**Do not publish against a "feature parity, if not exceeding" bar today.** The claim is not currently true and the README already overstates it in at least one verifiable place (§1.5).

---

## 1. What actually exists — verified in the tree

Everything in this section was read from source on this branch. Where a repo document contradicts the code, the code wins and the contradiction is flagged.

### 1.0 Shape of the thing

The DAW is **one tab inside a larger app**. `src/swift/Sources/ContentView.swift:101-133` — the `TabView` is Chat (tag 0, **default**), Create (1), Studio/DAW (5), Stems (4), Library (2), Publisher (3). `StudioRootView.tabTag = 5`.

**A user launching this app lands in a chat window, not a DAW.** That is a first-five-minutes fact worth more than any feature bullet below.

Counts, all verified:

| Thing | Count | Source |
|---|---|---|
| Catalog commands | **113** | `engine/contracts/command-catalog.v2.json`, parsed |
| …journaled | 89 | same |
| …undoable | 71 | same |
| MCP tools | **137** | `engine/docs/generated/mcp-tools.v1.json` |
| Effect kinds | **9** | `engine/render/src/dsp/fx.rs:401-425` |
| Instrument kinds | **3** | `engine/timeline-core/src/model.rs:553-559` |
| Rust `#[test]` fns in `engine/` | **887** | counted |
| Help/tooltip entries | **161** | `src/swift/Sources/Studio/StudioHelp.swift`, counted |

> **Correction to the brief:** the brief said "113 commands" — correct. A sub-audit reported 156; that was wrong. 113 is the parsed count.

### 1.1 The three-state map

This is the core deliverable. Categories:

- **(a) Engine-capable AND reachable from the GUI** — a user can do it with a mouse or key.
- **(b) Engine-capable but NO user-facing surface** — built, tested, journaled, invisible.
- **(c) Absent** — not in the engine at all.

A fourth state turned out to be necessary and is the most damaging finding in this document:

- **(b-decoy) Listed in the UI but inert** — the app shows the user a control that does nothing.

#### (b-decoy) — the command palette is a decoy for 60 of 71 entries

`src/swift/Sources/Studio/StudioCommandPalette.swift`. ⌘K opens a palette listing **71 command names** (`:32-53`, a hand-copied and now-stale mirror of catalog **v1**; the engine is on **v2** with 113). Of those 71, exactly **11 are wired** (`:56-68`). The other 60 do this when invoked (`:212-216`):

```swift
case .catalogListed:
    ToastManager.shared.show(
        "\(entry.id) is in the catalog; it wires into Studio in a later build.",
        style: .info)
```

This is worse than the feature being absent. A user searching ⌘K for "tempo" finds `project.setTempo`, presses Return, and is told the app will do it in a future version. **Ship-blocking on its own.** The palette should filter to wired entries (a ten-line change) or be removed until it is real.

Also decoys, verified:

- **Transport master meters are synthetic.** `StudioTransportBar.swift:204-205` — the level is `0.55 + 0.25 * abs(sin(t * 2.1))` while playing. It is not engine data. (The *mixer dock* meters are real; these are not.)
- **The Studio's Generate button does nothing.** `StudioTransportBar.swift:289-294` opens a popover reading "Generation wires into the Studio timeline in a later build."
- **Inspector lineage fields are literal placeholders** — "wires in P2" strings at `StudioInspectorView.swift:153-165`.

#### (b) Built, tested, journaled — and unreachable

**This is the cheapest value in the product.** Each of these has engine code, passing tests, an inverse for undo, and an MCP tool — and no way for a human to get at it.

| Capability | Engine evidence | Why unreachable | Cost to surface |
|---|---|---|---|
| **Sampler** (multi-zone, root-note pitch tracking, Hermite interpolation, per-zone gain, ADSR) | `dsp/sampler.rs` (500 LOC), 6 unit + 18 integration tests (`render/tests/sampler_binding.rs`) | `StudioViewModel.swift:800` hardcodes `kind: "synth"`. No sample-picking flow exists. `device.zone.add` / `device.zone.remove` appear **nowhere in Swift** | **S–M** |
| **Drum rack** (16 pads, per-pad sample/gain/pan) | `dsp/drum.rs` (412 LOC), 8 unit + 3 integration tests incl. bit-identity at every block size | same — no picker, no pad grid | **M** |
| **Tempo** | `project.setTempo` fully implemented and journaled | BPM is a **read-only `Text`** — `StudioTransportBar.swift:145-150`, `readout()` at `:164-174` renders plain Text, not a field | **XS** |
| **Time signature / key** | `project.setTimeSig`, `project.setKey` | same read-only readouts (`:151-160`) | **XS** (but see §1.4 — 4/4 is hardcoded in the engine) |
| **Markers and sections** | `marker.set/remove`, `section.set/remove` | sections are *drawn* from engine truth (`StudioTimelineView.swift:611-627`) and selectable, but cannot be created, renamed, moved or deleted. Markers have no UI at all | **S** |
| **Track rename / reorder / colour / height** | 4 commands, all journaled | palette-listed only | **S** |
| **Clip rename / gain / mute / crossfade** | 4 commands | palette-listed only. Crossfade has real DSP and zero UI | **S** |
| **Loop region** | `transport.loop.set/clear` | issued **programmatically** only, for revise auditioning (`StudioViewModel.swift:966,975`). **No draggable loop brace in the ruler** | **S** |
| **Take restore / purge** | `take.restore`, `take.purge` | `take.restore` appears nowhere in Swift; purge exists in the takes browser context menu but restore does not | **XS** |
| **Stem-session import** | `studio.importStemSession`, `import.stems` | palette-listed / absent | **S** |
| **Automation targets beyond volume+pan** | Engine accepts lanes on **22 fx params**, instrument params, send levels, bus gains, edge levels — all with real per-frame readers (`render/src/rt.rs:151-211`) | `StudioAutoTarget` in `StudioEngineModel.swift:158-170` is **`case volume, pan`**. Two. The other ~20 automatable paths have no lane picker | **S–M**, and the single highest value/effort item in this table |
| **MCP server** | 137 tools, rate-limited, tiered, PAT-gated | Off by default; `StudioMCPSettingsView.swift` exists so it *is* reachable, but nothing in the Studio surfaces it | n/a — correct as designed |

#### (c) Absent from the engine entirely

Verified by exhaustive grep, not inferred:

| Absent | Evidence |
|---|---|
| **Session View / clip launcher / scenes / follow actions** | No scene grid, no clip slots, no launch buttons anywhere in Swift. Exhaustive search for `scene`, `clip slot`, `launcher`, `slot` returns only SwiftUI's `some Scene` and unrelated `StemSession` types. **The Studio is arrangement-only.** |
| **Plugin hosting (AU / VST3 / CLAP / AUv3)** | No plugin host, no `AudioComponentFindNext`, no `AUAudioUnit`, no scanner. The only `AVAudioUnit` hits are `AVAudioUnitEQ` inside the unrelated Stems player (`StemSessions/StemEngine.swift`). |
| **Quantize** | **See §1.5 — this contradicts the brief.** |
| **Metronome audio** | `transport.metronome` sets `self.transport.metronome = bool` at `agent-surface/src/host.rs:1448-1451` and is **never forwarded to the render engine**. There is no click generator, no click oscillator, no click sample. The `Transport` struct is documented as "A tracked, audio-free transport view" (`host.rs:52-57`). **And there is no metronome button in the transport bar at all.** |
| **Count-in** | No `countIn` in the engine. Follows from the metronome: nothing to count in with. (A *count-in picker* exists in the Swift record bar, `StudioRecordBar.swift:203-230` — so the UI offers a count-in the engine cannot sound.) |
| **Multi-segment tempo / tempo changes** | `timeline-core/src/tempo.rs:81-93`: "v1 projects hold exactly one, starting at tick 0." `segments` is private with no push API. `frame_to_tick` hardcodes `segment_at(0)` (`:193-199`). |
| **Time signatures other than 4/4** | `bar_to_tick(bar) = bar * 4 * PPQ` (`tempo.rs:202-204`). Hardcoded. |
| **Warp markers** | Fixed ratio per clip only. No marker/anchor list. |
| **Audio-to-MIDI, pitch correction, pitch shifting** | No pitch detection, no PSOLA, no formant work. The sampler's pitch shift is naive resampling (changes duration). |
| **MIDI file import/export (.mid / SMF)** | No SMF reader or writer anywhere in the repo. |
| **MIDI clock / MTC / MPE / program change / aftertouch / MIDI out** | `midi/event.rs:13-23` parses exactly four message types: NoteOn, NoteOff, CC, PitchBend. Everything else returns `None`. |
| **Freeze / bounce-in-place** | Not present. |
| **Comp editing** | Loop-record *capture* into take lanes exists (`host.rs:182-193`). Splicing across takes does not. |
| **Effect / instrument presets** | `Fx::params` is a `BTreeMap`; there is no preset concept, no preset browser, no default patches. |
| **Groove pool, follow actions, clip envelopes, Max-for-Live-equivalent** | None. |
| **Video track, notation, ARA** | None. |

#### (a) Reachable and real — the working product

Stated so the good is not lost in the gaps. All verified to reach the real FFI engine (`StudioEngineFactory.swift:22,55-70`; `project.yml:45` hardcodes `REAL_ENGINE`; the xcframework is present).

- **Import audio** — three routes: toolbar Import menu (`StudioRootView.swift:80-84`), browser button (`StudioBrowserView.swift:180-192`), **drag-and-drop onto the timeline** (`StudioTimelineView.swift:51-53`). Real `import.audio`, blake3-hashed into the package.
- **Timeline editing** — clip move (incl. cross-track), trim both edges, fade in/out by dragging corner handles, marquee select, right-click delete, snap picker (Off/Bar/Beat/1-16), pinch and ⌘-scroll zoom, playhead scrub, region select, take drop. Split is ⌘E.
- **Piano roll on the real engine** — draw (drag or double-click), move, ⌥-drag copy, resize both edges, velocity lane drag, marquee, shift-click, arrow-key nudge, 9 grid divisions incl. triplets, ⌘ to bypass snap, tool picker, undo/redo. This is a genuinely competent piano roll.
- **Mixer** — 4-band draggable-node EQ, pan knob, two fixed sends, fader, real peak+RMS meters, mute/solo, master strip with integrated **and** short-term LUFS, correlation, true-peak, limiter with ceiling/release and GR readout.
- **Routing & FX pane** — create buses and groups, connect anything to anything with per-edge level and **pre/post tap**, bus faders, real bus meters, insert chains on tracks/buses/master with **drag-to-reorder**, all 9 effect kinds pickable, per-effect bypass, **sidechain key picker** on compressor and gate, per-param clear. Refusals are shown inline with reasons and the control is disabled.
- **Recording** — arm, record, punch (from region), loop-record stacking into take lanes, input device picker, live input meter + scope, take browser with filter/audition/drag-to-timeline/per-stem comping, and **retro-capture "Keep"** (`StudioOnScreenKeyboard.swift:100-125` → `keepPerformance()`).
- **MIDI input** — hardware keyboard plays the instrument, per-port role (Keys vs Control surface), MIDI learn, CC bindings, map import/export.
- **Automation drawing** — click to add, drag to move, **⌥-click to delete** (`StudioTimelineView.swift:880-882`). Volume and pan only.
- **Export** — master / stems / region; WAV 24-bit or AAC; EBU R128 loudness targets (−14 / −7 / −16 LUFS) with a measure→correct→re-measure pass; optional provenance manifest; publish to majiks.online.
- **Undo/redo** — ⌘Z / ⇧⌘Z in the mixer dock header. Restores devices, sampler zones, fx, automation.
- **Persistence** — see §1.3.
- **Help layer** — 161 teaching tooltips with a teaching/terse/off preference, and accessibility hints that survive turning tooltips off (a good decision, `StudioHelp.swift:100-115`).

### 1.2 Menus — the missing furniture

`src/swift/Sources/Main.swift:182-383`. Complete list of menus: App, File, **Library**, **Playback**, **Publisher**, View, Window, Help.

**There is no Edit menu, no Track menu, no Clip menu, no Transport menu, no Insert/Device menu.** There is no Undo or Redo *menu item* anywhere — undo exists only as two buttons in the mixer dock. There is no Cut/Copy/Paste/Select All.

The menus that do exist belong to the *other* app: "Library ▸ Import Audio… ⌘I" imports into the music **Library**, not the Studio timeline. A DAW user pressing ⌘I gets the wrong import.

This is the single most jarring thing about the app for a professional user and it is nearly free to fix.

### 1.3 Persistence — verified, and the brief was wrong

The brief said "checkpoint appears not to write on quit — verify." **Refuted. It is wired.**

- `Main.swift:788-794`, `applicationWillTerminate` → `MainActor.assumeIsolated { StudioProjectSaver.shared.saveSynchronouslyForQuit() }`.
- `StudioProjectSaver.swift:160-176` pumps the runloop rather than blocking a semaphore, with a 3 s bound, specifically to avoid the deadlock the old path had.
- Autosave every 20 s when dirty (`:180-192`), checkpoint on resign-active (`:196-201`), ⌘S force (`Main.swift:215-220`).
- **The journal is the durability mechanism, not the save button.** `FileJournal::append` (`timeline-core/src/package.rs:75-99`) `flush()`es on **every** append — with an excellent comment explaining exactly why (AppKit `exit()` skips `Drop`, so a BufWriter ate a whole session's commands; observed live, `journal.jsonl` at 0 bytes after a day of work). `sync_data()` (real fsync) is called at save/autosave, not per command. That is the right trade and it is stated honestly.

One caveat: `saveSynchronouslyForQuit` guards on `engine != nil`, so if the Studio tab was never opened no checkpoint is written — which is correct.

**Verdict: persistence is sound.** Better than the brief credited.

### 1.4 Two things the brief credited that are audibly broken

**1. `clip.warp.set` is a no-op you can hear nothing from.** The stretch DSP is real and good — Signalsmith primary, WSOLA reference, off-thread worker, bit-exact identity bypass, ratio clamped 0.25×–4× (`render/src/warp.rs`). The command applies correctly to the model with a proper inverse (`apply.rs:2426-2468`). **But `agent-surface` never populates the warp overlay** — every compile call passes `&WarpOverlay::new()`, an empty overlay (`agent-surface/src/host.rs:1254, 2487, 2528, 2733`). `set_warp_ratio` is called from exactly three places, all of them tests or probes, **zero in `agent-surface`**. So a warp lands in the project, saves, undoes correctly, and changes nothing you can hear. `WarpMode::Conform` has no render implementation at all, and `import.audio`'s `conformTempo` / `separateStems` params are hardcoded `None` (`host.rs:1632-1635`).

No test covers `clip.warp.set` → audible stretch, which is exactly why this was invisible. This is a textbook instance of the repo's own "green signal on the wrong axis" pattern.

> **RESOLVED on `feat/warp-alive` (2026-07-26).** `StudioHost::warp_overlay` now derives the overlay from `Clip::warp` and all four compile sites consume it; a 2× warp set through `submit_json` renders 7.9996 s of 440 Hz where the source was 3.9986 s, and the pinned legacy digest is unchanged. `agent-surface/tests/warp_audible.rs` is the missing audible-stretch test (four ratios incl. 1.37× and 3×, measured duration + pitch). No new command was needed. **Still open:** `WarpMode::Conform` is resolved as the ratio the model carries, not as true conform-to-project-tempo (that needs source-BPM metadata — E7); `import.audio`'s `conformTempo` / `separateStems` are still hardcoded `None`; and there is no GUI control for warping yet. A second, previously unknown defect was found and fixed on the way: Signalsmith randomises per-bin time factors above 2× from a `std::random_device` seed, so warped bounces above 2× were not reproducible — see `render/src/warp.rs::deterministic_stretcher`.

**2. FLAC is advertised and refused.** `command-catalog.v2.json:3333-3339` offers `wav | flac | aac`. `host.rs:3830-3844` returns `Unsupported("FLAC export lands with the IO codec pass")`. Same for `sampleRateHz: 44100` — offered in the catalog, refused at runtime (`host.rs:3639-3649`). An agent reading the schema will build a request the engine rejects.

### 1.5 Quantize — the brief is wrong, and so is the README

> Brief: *"Quantize exists only as an MCP command."*

**Refuted. Quantize does not exist anywhere.**

- No Rust implementation. The complete `note.*` command set is `add / duplicate / move / remove / resize / velocity.set`. **No `note.quantize`.**
- No MCP tool. All 137 enumerated; none is quantize.
- The only `tools.quantize` string in the repo is a **fabricated demo row in a Swift mock**: `StudioMockEngine.swift:1899-1902`, a MIDI binding pointing at a command that does not exist.
- **`README.md:223` claims: "Piano roll — draw, move, resize, and quantize notes on a real MIDI clip."** That claim is false.

The repo already documents this exact failure mode about itself. `Engine/RealStudioNoteEngine.swift:5-10`:

> "E1-ui built the piano roll against `StudioNoteEngineProtocol` and shipped it running on `StudioMockNoteEngine.demoSession()`… It looked completely finished: 22 notes, velocity lane, grid, tools, **quantize**, undo/redo. **None of it reached the project.**"

The mock's quantize was deleted from the real path and the README bullet describing it was never removed. **Fix the README before anything ships.**

Quantize is also, for a MIDI DAW, table stakes — it is the single most-used MIDI edit in Live, Logic and FL. Its absence is a §6 P0.

---

## 2. The comparison — organised by what a musician is trying to do

Scale: **●●●** at or above the field · **●●○** usable but behind · **●○○** present but not usable for real work · **○○○** absent.

### Get sound in

| | Majik's | Live | Notes |
|---|---|---|---|
| Import audio file | ●●● | ●●● | Drag-drop, menu, browser. Blake3-hashed into the package — better provenance than Live's file reference. |
| Record audio | ●●○ | ●●● | Capture, punch, loop-record takes, metering all real. **No input monitoring** (deliberately gated, `record_input.rs:4-10`) and **no count-in that sounds**. Tracking vocals is not possible without monitoring. |
| Record MIDI | ●●● | ●●● | Genuinely good. 4–7 ms key-to-sound, event-driven pump. |
| **Retro-capture** | ●●● | ●●● | Live 11+ has this; so does this app, and it is well-built (bounded 32 bars / 4096 notes, take starts at first note-on so no leading silence). **At parity with the best in the field.** |
| Metronome | ○○○ | ●●● | **Does not make a sound.** |
| Tempo detection on import | ●●● | ●●● | `media/src/tempo.rs` (637 LOC) — spectral flux onsets, autocorrelation + comb candidates, OLS phase fit. Real work. But it cannot be *applied* (warp is inert, §1.4). |

### Arrange

| | Majik's | Live | Notes |
|---|---|---|---|
| Arrangement timeline | ●●○ | ●●● | Move/trim/fade/split/snap/zoom all work. No markers, no loop brace, no clip rename/gain/mute, no crossfade UI, no Edit menu. |
| **Session View** | ○○○ | ●●● | **Absent.** This is *the* Ableton feature. See §3. |
| Tempo changes | ○○○ | ●●● | One constant tempo. Live, Logic, Reaper, Bitwig all do tempo maps. |
| Time signature | ○○○ | ●●● | 4/4 hardcoded in the engine. Rules out anything in 3/4, 6/8, 7/8. |
| Warp / elastic audio | ●○○ | ●●● | DSP is real; the wire is not (§1.4). Live's warping is a defining feature. |
| Groups / folders | ●●● | ●●● | Real group nodes with faders and meters. Good. |
| Comping | ●○○ | ●●● | Take capture only, no comp editing. Logic's comping is the bar here and it is far ahead. |

### Edit MIDI

| | Majik's | Live | Notes |
|---|---|---|---|
| Piano roll editing | ●●● | ●●● | Draw, move, resize, ⌥-copy, marquee, velocity lane, nudge, triplet grids. Legitimately good. |
| **Quantize** | ○○○ | ●●● | Absent (§1.5). The most-used MIDI edit in every DAW in the field. |
| Groove / swing | ○○○ | ●●● | Absent. |
| Scale / key lock | ○○○ | ●●● | Absent. Live's Scale mode is a headline 12.x feature. |
| MIDI file I/O | ○○○ | ●●● | Cannot import or export a `.mid`. Rules out any collaboration workflow. |
| MPE | ○○○ | ●●● | Absent (a `mpeTimbre` key round-trips as opaque data; nothing reads it). |
| Note expression / per-note curves | ○○○ | ●●● | Absent. |

### Sample

| | Majik's | Live | Notes |
|---|---|---|---|
| Load a sample into an instrument | ○○○ *(UI)* / ●●○ *(engine)* | ●●● | **The clearest category-(b) item.** Engine sampler is real and tested; there is no way to pick a file. |
| Sampler depth | ●○○ | ●●● | Multi-zone + root-note + ADSR — but **no loop points, no start/end, no velocity layers, no round-robin, no filter** (its `cutoff`/`resonance` params are silently ignored). Live's Simpler alone beats this; Sampler is far beyond it. |
| Drum rack | ●○○ | ●●● | 16 pads, per-pad gain/pan — **no choke groups, no per-pad pitch** (explicitly scoped out, `dsp/drum.rs:9-10`), and no UI. |
| Slicing / chopping | ○○○ | ●●● | Absent. |

### Mix

| | Majik's | Live | Notes |
|---|---|---|---|
| Faders, pan, mute, solo, meters | ●●● | ●●● | Real, with solo-in-place and solo-safe returns. |
| Channel EQ | ●●● | ●●● | 4-band RBJ with per-frame coefficient ramping and bit-exact bypass at 0 dB. Good. |
| Buses, groups, sends, pre/post | ●●● | ●●● | Full graph with per-edge level and tap. **Ahead of Live**, whose routing is more constrained. |
| Sidechain | ●●● | ●●● | Real, and correctly implemented as an ordering constraint in the topological sort — with a comment (`compile.rs:265-269`) explaining that without it the keyed processor reads its source before it is written, producing exact silence while every model-level test still passes. That is a subtle bug most DAWs have shipped. |
| Delay compensation | ●●○ | ●●● | Correct algorithm, but nothing has latency except the limiter's 96 frames, and legacy send legs are uncompensated by design. It matters once plugins exist; today it compensates almost nothing. |
| Automation — engine | ●●● | ●●● | Dense per-frame lanes, 22 fx params + instrument params + sends + bus gains + edge levels. **Refusals are best-in-class**: named path, named tracks, the exact `autolane.clear` to fix it, the list of what *does* work, and "NOTHING IS LOST — the points are still in the project, still saved, still undoable" (`compile.rs:1377-1390`). No commercial DAW does this. |
| Automation — UI | ●○○ | ●●● | **Two targets: volume and pan.** No curve shapes (the DSP has Step/Linear/Pow, the contract has no curve field — see §6), no latch/touch/write modes, no clip envelopes. |
| Effect count | ●●○ | ●●● | 9 vs Live Suite's ~60. Quality is high; breadth is not. **No presets and no default patches**, which makes 9 feel like 3. |
| Freeze / bounce-in-place | ○○○ | ●●● | Absent. |

### Use plugins

| | Majik's | Live/Logic/Reaper/Bitwig |
|---|---|---|
| AU / VST3 / CLAP | **○○○** | ●●● all four |

**This is the single largest gap and it is not close.** For most working musicians it is the buy/don't-buy question — their sound *is* their plugin folder. See §7; it is architecturally blocked, not backlogged.

### Perform

| | Majik's | Live | Notes |
|---|---|---|---|
| Session View / scene launch | ○○○ | ●●● | Absent. |
| Control-surface / fader banks | ○○○ | ●●● | MIDI CC mapping exists; no HUI/Mackie protocol. |
| MIDI clock / sync | ○○○ | ●●● | Not parsed at all. Cannot slave to or drive anything. |
| Low-latency live play | ●●● | ●●● | Allocation-free audio thread, verified by an allocation counter in `render/tests/null_and_alloc.rs`. Genuinely rigorous. |

### Export

| | Majik's | Live | Notes |
|---|---|---|---|
| Master / stems / region | ●●● | ●●● | All three, journaled for provenance. |
| Formats | ●●○ | ●●● | WAV 24-bit + AAC. **FLAC advertised and refused** (§1.4). No 16-bit, no 32-float, no sample-rate conversion (48 k only), no dither. |
| Loudness normalisation | ●●● | ●●○ | EBU R128 with measure→correct→re-measure and a 0.5 LU acceptance bar. **Ahead of Live**, which has no loudness target on export. |
| True peak | ●●● | ●●○ | Real 4× polyphase BS.1770-4 detector. Honest naming: the export report's `sample_peak_dbfs` is explicitly labelled as sample peak, not TP (`encode.rs:76-78`). |
| **Provenance manifest** | ●●● | ○○○ | Nothing in the field has this. §4. |

---

## 3. The first-five-minutes test

An experienced Ableton user, sat down cold, told "make something."

**0:00 — the app opens on a Chat tab.** Not a DAW. They look at six tabs — Chat, Create, Studio, Stems, Library, Publisher — and have to guess. Two of them ("Create", "Studio") both sound like the DAW; the DAW is "Studio", the AI generator is "Create". *First confusion, before any music.*

**0:30 — they find Studio.** The layout reads correctly: browser left, timeline centre, inspector right, mixer bottom, transport top. It looks like a DAW. Good.

**0:45 — they press Tab.** Nothing. In Live, Tab flips Session↔Arrangement, and it is the most reflexive keystroke an Ableton user has. **Wall 1 confirmed: there is no Session View.** Verified absent — no scene grid, no clip slots, no launch buttons anywhere in the tree. For a user whose entire workflow is "loop ideas in Session, then record into Arrangement", this is not a missing feature; it is a missing *product*.

**1:00 — they go to the browser to drag in a drum kit.** They find four sections: Songs, Takes, Stems, Files. Songs lists their *music library*. Stems is a **read-only list of the project's own track names, with no gestures at all**. Files is a **read-only list of already-imported clips**. **Wall 2 confirmed: there is no device browser, no instrument browser, no sample browser, no preset browser.** There is nothing to drag except a finished song. Verified: `StudioBrowserView.swift` read in full; the only draggable items are library songs (`:351`) and takes.

**1:30 — they click "Instrument" in the toolbar.** A track appears with a synth and an empty MIDI clip. This works, and it is a nice touch. They open the piano roll and draw a few notes. **This part is good** — grid picker with triplets, velocity lane, ⌥-drag copy, marquee. It behaves the way a piano roll should.

**2:15 — the timing is loose, so they select all and reach for ⌘U.** Nothing. They look for a quantize control in the piano roll toolbar. There is none. They open ⌘K and type "quant". **Nothing matches** — because it does not exist (§1.5). *Wall 3, and it was not on the owner's list.* Quantize is the most-used MIDI edit in every competing DAW.

**2:45 — they want the tempo at 140.** They click the BPM readout in the transport. It does not respond — it is a `Text` view. They double-click. Nothing. They open ⌘K, type "tempo", find `project.setTempo`, press Return, and get a toast: *"project.setTempo is in the catalog; it wires into Studio in a later build."* **This is the worst moment in the five minutes** — not because tempo is missing, but because the app *offered* it and then declined. A missing feature is a gap; a listed-then-refused feature reads as a broken product.

**3:15 — they turn on the metronome to hear the grid.** There is no metronome button in the transport. ⌘K → `transport.metronome` → same toast. Even if it were wired, **it makes no sound** (§1.1). *Wall 4.*

**3:30 — they reach for their plugins.** Right-click a track, look for an insert slot. They find the routing & FX pane, which is actually good — real chain, drag-to-reorder, 9 built-in effects, sidechain picker. But **there is no plugin list, no scan, no AU folder**. **Wall 5 confirmed: no plugin hosting.** For most users this ends the evaluation. Their compressor, their reverb, their synth — none of it is available.

**4:00 — they try to save-as or start a second project.** There is no New/Open. There is exactly one project, reopened every launch. This is a *deliberate and defensible* decision (`StudioProjectSaver.swift:16-30`, written explicitly for a non-DAW-user owner), and for a beginner it is genuinely better than the field. But a Live user with forty projects will read it as the app having no file model.

**4:30 — they hit ⌘Z twice after a mistake.** It works, and it works *well* — the undo restores devices, sampler zones, fx and automation. But they had to find the buttons in the mixer dock header, because **there is no Edit menu and no ⌘Z menu item**.

**5:00 — verdict from the chair.** "The piano roll and the routing are real. Everything around them is missing or lies to me." They would not use it again without being asked to.

### On the owner's three predicted walls

| Predicted | Verdict |
|---|---|
| No Session View | **Confirmed.** Verified absent, exhaustively. |
| No device/sample browser to drag from | **Confirmed, and worse than stated.** The browser exists but two of its four sections are read-only lists with no gestures at all. |
| No plugin hosting | **Confirmed.** No host, no scanner, no AU/VST code of any kind. |

**Three more the owner did not list, all of which bite earlier:**

4. **The ⌘K palette actively lies** — 60 inert entries that toast a promise. Cheapest and most damaging.
5. **No quantize** — and the README says there is.
6. **Tempo, time signature and key are read-only text.** A DAW where you cannot set the tempo is not a DAW.

---

## 4. Where this product is genuinely ahead

Stated with the same rigour. These are real, verified, and in three cases have no equivalent anywhere in the commercial field.

### 4.1 Agent control of the entire command surface — no equivalent, anywhere

**137 MCP tools**, generated from the command catalog so the tool set *cannot* drift from the bus (`registry.rs:1-9`; a parity gate test fails the build if any command lacks a tool). Exactly one documented exclusion: `gen.landed`, which the engine writes itself.

Tiered — Read / Perform / Manage, with `confirm: true` required for anything that deletes user content or writes outside the project (`registry.rs:26-38`). Localhost, fixed free port 8478, PAT bearer, **off by default and fails closed** (`mcp.rs:1-9`).

**The important property is not "it has an API."** It is that *the agent and the human use the same command bus*, so anything an agent does is journaled, undoable, and provenance-tracked identically to a mouse gesture. Live has Max-for-Live and a Python remote-script API; Reaper has ReaScript; Bitwig has a controller API. **None of them route agent actions through the same undoable, hash-chained journal as user actions.** This is architecturally distinct, not a marketing distinction.

**Who it matters to:** developers, studios building automated workflows, and anyone whose "collaborator" is an LLM. It is close to irrelevant to a working musician evaluating the app on sound — which is worth being clear-eyed about.

### 4.2 Blake3 hash-chained provenance journal with EU AI Act Article 50(2) disclosure

Verified real, not aspirational:

- Append-only hash-chained command log (`timeline-core/src/journal.rs:1`), with a `verify_chain` that recomputes the whole chain and reports the exact entry where it breaks (`:55-66`).
- `engine/contracts/provenance-manifest.schema.json` — a machine-readable manifest over that chain: the **authored / recorded / generated / imported** split, per-clip lineage, engine identities, asset content hashes, the chain head, and **IPTC DigitalSourceType IRIs** (`trainedAlgorithmicMedia` when all-AI, `compositeWithTrainedAlgorithmicMedia` when mixed, `digitalCapture` when none).
- Tested end to end: `agent-surface/tests/export.rs:123-132` asserts the composite IPTC term, `aiGenerated: true`, `standard == "EU AI Act Article 50(2)"`, and that the generating model appears in the disclosure.
- The schema documents its own compatibility discipline — every change must keep already-exported manifests valid; `authored` was added as a widening with nothing added to any `required` list.

**Who it matters to:** sync/library licensing, production music catalogues, broadcasters, and anyone who will need to answer "was AI used, and where" under the AI Act — which from August 2026 is a large and growing set of buyers. **No DAW in the field has anything comparable.** This is a genuine, defensible, standards-anchored differentiator and it should lead the marketing rather than trail it.

**Do not overstate it:** the manifest describes what the *journal* knows. Plugin state would break that (§7), and today `clip.warp.set` is journaled but inaudible (§1.4), so the journal is currently *more* accurate than the render — a direction that is safe, but worth knowing.

### 4.3 Per-command undo fidelity, and refusal discipline

- **71 of 113 commands are undoable**, with declared inverse rules in the contract. Every one of the 42 non-undoable commands carries a written `nonUndoableReason` in the catalog — and reading them, they are correct classifications (transport, export, publish, MIDI machine-config, txn brackets, async gen requests), not excuses.
- Undo restores **devices, sampler zones, fx and automation** together, guarded by generative tests. The changelog records seventeen silent data-loss paths closed in one pass.
- **Refuse rather than silently ignore** is enforced at compile: an automation lane with no render-side reader is a *named compile error*, not a shrug (`compile.rs:1296-1400`). The refusal names the path, every track carrying it, the exact remedy command, and what still works. `rt.rs:215-272` carries a written reason per refusal class — including the honest "the channel EQ retargets coefficients at BLOCK boundaries, and every piece of signal state in this engine must advance per FRAME or the bounce stops being bit-identical."

**Who it matters to:** everyone, invisibly. It is the difference between a DAW that loses your work in edge cases and one that does not. It is also the least marketable of the three advantages, because users only notice it when it is absent.

### 4.4 Determinism and honesty as engineering culture

Not a feature, but the strongest thing in the tree. Bit-identical offline bounce vs live callback, verified by null test. Allocation-free audio thread, verified by an allocation counter. Exact rational tempo (`Bpm { num, den }`, 960 PPQ, u128 tick→frame) so 92 BPM is as first-class as 120. Bit-exact bypass at unity for EQ, pan, width, and warp. Deterministic `oldest-quietest` voice stealing with a 5 ms declick.

And the code says what it cannot do, in writing, at the site — `drum.rs:9-10` on choke groups, `compressor.rs:15-20` on zero lookahead, `saturator.rs:14-18` on no oversampling, `record_input.rs:4-10` on never opening an output stream.

**This is the asset.** The gaps in this document are almost all *product* gaps sitting on top of an engine that was built properly.

### 4.5 Local AI generation

Real, but qualify it. Generation is a **proxy** — `agent-surface/src/gen.rs:1-9` states plainly: "PROXY ONLY - this lane implements no generation," forwarding to the Python backend / Gen Node named by `MAJIKS_GEN_RPC_URL`, and returning an honest `not configured` rather than a fake job id when unset. The backend (`src/python/majik_backend/gen_protocol.py`) has three routes: local-MLX (ACE-Step on-device), remote-ACE, and gen-node.

**But it is not in the DAW.** Generation lives in the *Create* tab; the Studio's Generate button is a stub (§1.1). The `gen.*` commands are palette-listed only. So "local AI generation inside a DAW" is true of the *product* and not yet true of the *Studio*, and the revise/extend/layer agent workflows (`studio_revise`, `studio_extend`, `studio_layer` MCP tools) are reachable to agents but only partially to a human.

---

## 5. The honest summary of §1–§4

- The **engine** is at roughly **60%** of Live Standard by feature surface, and *ahead* of the field on determinism, routing flexibility, loudness/TP export, refusal quality, and provenance.
- The **application** exposes roughly **half** of that engine, so reachable capability is nearer **30%**.
- The gap between those two numbers — sampler, drum rack, tempo, markers, 20 automation targets, loop brace, clip properties — is **the cheapest value in the product** and is almost entirely Swift.
- Three absences are structural rather than cheap: **Session View**, **plugin hosting**, and **tempo/time-signature maps**.
- Two shipped things are **actively misleading** and should be fixed before anything is published: the **inert ⌘K palette** and the **README quantize claim**. Add the **synthetic transport meters** and the **advertised-but-refused FLAC**.

---

## 6. Ranked roadmap — for a musician, not a spec sheet

Ordering rule: *what stops someone finishing a track*, then *what makes them stay*. Effort is rough lane-days (1 lane-day ≈ one focused agent-lane day at this repo's observed velocity).

### P0 — Stop lying. Do this before anything else. **~3 days**

| # | Work | Effort | Why |
|---|---|---|---|
| 0.1 | **Filter ⌘K to wired commands** (or remove the palette) | 0.5 d | 60 inert entries that promise a future build. The single worst UX artefact in the app. |
| 0.2 | **Fix the README** — delete the quantize claim (`:223`); audit the rest of the Studio bullets against the tree | 0.5 d | A verifiably false feature claim in a published README. |
| 0.3 | **Delete or wire the synthetic transport meters** (`StudioTransportBar.swift:204-205`) | 0.5 d | A meter that shows `sin(t)` is a fabricated instrument reading. |
| 0.4 | **Remove FLAC and 44.1 kHz from the catalog** until implemented | 0.5 d | An advertised-then-refused schema misleads every agent. |
| 0.5 | **Remove or gate the count-in picker** until the metronome sounds | 0.25 d | Offering a count-in with no click. |
| 0.6 | ~~**Either wire the warp overlay or mark `clip.warp.set` unimplemented**~~ **DONE** (`feat/warp-alive`, 2026-07-26) | 1 d (wire) | Journaled, saved, undoable, inaudible. Add the missing `clip.warp.set` → audible-stretch test. **Both done; §1.4 for what remains (Conform, GUI control).** |

### P1 — Make it finishable. **~15 days.** After this, a musician can complete a track.

| # | Work | Effort | Why |
|---|---|---|---|
| 1.1 | **Metronome that makes a sound** + count-in | 2 d | You cannot record to a grid without it. Generate the click in the render graph; do not sample-play it. |
| 1.2 | **Quantize** — `note.quantize` command + inverse + piano-roll control (strength, swing, grid) | 3 d | Most-used MIDI edit in the field. New command, so it needs a catalog entry with a proper inverse (store prior positions). |
| 1.3 | **Editable tempo / time-signature / key fields** in the transport | 1 d | Commands exist and are journaled. Purely swapping `Text` for a field. **Note:** the engine hardcodes 4/4 (`tempo.rs:202-204`), so time signature needs engine work or must stay read-only and honest. |
| 1.4 | **Sample loading UI** — file picker → `device.add(kind: "sampler")` + `device.zone.add` | 3 d | Unlocks a fully built, fully tested engine sampler. Highest capability-per-day on the list. |
| 1.5 | **Drum rack pad grid** — 16 pads, drop a file on a pad | 3 d | Same: unlocks built engine. Live's Drum Rack is the single most-used device in the product. |
| 1.6 | **Loop brace in the ruler** + markers | 2 d | Commands exist. Loop is how anyone works on eight bars. |
| 1.7 | **Edit menu** — Undo/Redo/Cut/Copy/Paste/Select All/Delete/Split/Duplicate, plus a Track menu | 1 d | The furniture. Its absence is what makes the app feel unfinished to a pro on first contact. |

### P2 — Make it good. **~13 days**

| # | Work | Effort | Why |
|---|---|---|---|
| 2.1 | **Automation targets beyond volume/pan** — widen `StudioAutoTarget` to the engine's real accept-list | 2 d | ~20 automatable paths already have per-frame readers and refusals. Pure Swift. |
| 2.2 | **Effect presets + a preset browser** | 3 d | `Fx::params` is already a `BTreeMap`; a preset is that map plus a name. **9 effects with no presets read as 3.** Cheapest large perceived-quality jump. |
| 2.3 | **Device / instrument / sample browser** with drag-to-track | 4 d | Wall 2. The browser shell exists; two of its four sections are dead lists. |
| 2.4 | **Clip properties** — rename, gain, mute, crossfade UI | 2 d | Commands exist; palette-listed only. |
| 2.5 | **Automation curve shapes** | 2 d + **contract change** | `render`'s `CurveKind` already has Step/Linear/Pow (`automation.rs:26-32`), but `AutoPoint` has **no curve field** and `autopoint.add` has no curve param, so the host hardcodes Linear (`host.rs:1932`). Per catalog rule this **cannot** be an optional param on an existing command — it needs a **new command name**. Easy to under-scope. |

### P3 — Structural. Weeks each; each needs an owner decision first.

| # | Work | Effort | Note |
|---|---|---|---|
| 3.1 | **E4 — plugin hosting** | **Blocked.** See §7. | The largest parity gap by a wide margin. |
| 3.2 | **Session View / clip launcher** | 4–6 weeks | Not a feature; a second product mode. Model (scenes, slots, follow actions, quantized launch), engine (launch-quantized clip start), UI (grid), and a Session↔Arrangement record path. **Decide whether this app is competing with Live or with Reaper/Logic** — if the latter, its absence is defensible; if the former, it is not. |
| 3.3 | **Tempo map + non-4/4** | 2–3 weeks | `tempo.rs` is *shaped* for it (private `segments: Vec`), but `segment_frame_origin` has per-boundary rounding with a `TODO L1: exact rational accumulation` and `frame_to_tick` hardcodes segment 0 (`:193-199`) — it would be **wrong**, not merely absent, on a multi-segment map. Needs the exact-rational work first. |
| 3.4 | **E7 warp markers** | 2 weeks | Blocked behind fixing the warp overlay wire (0.6). Phase anchor already landed for it. |
| 3.5 | **E8 racks + macros** | 3 weeks | `ParamRef` was designed for this; E5's chain is the substrate. |
| 3.6 | **Audio comping across takes** | 2 weeks | Take model is journaled; `revise/splice.rs` already solves the crossfade. |
| 3.7 | **MIDI file import/export** | 1 week | Blocks all collaboration. Cheaper than its impact suggests. |
| 3.8 | **Freeze / bounce-in-place** | 2 weeks | Only matters once plugins exist. |
| 3.9 | **Input monitoring** | 1 week + safety review | Deliberately gated today. **You cannot track vocals without it.** |

### The path, in one line

**P0 (3 d) → P1 (15 d) → P2 (13 d) ≈ 6–7 lane-weeks to "a musician can make a track end to end without hitting a wall."** That is a real, defensible claim at the end of it — for someone making electronic or beat-driven music in 4/4 with the built-in instruments. It is **not** "parity with Ableton", and it should never be marketed as such while §7 is open.

---

## 7. The architectural fork the owner must decide: E4 plugin hosting

This is not a backlog item and must not be treated as one.

**The tension, stated exactly.** A plugin's internal state is opaque — a VST3/AU blob the host cannot interpret. This product's differentiator is that the journal is a *complete, verifiable, replayable* description of the project: hash-chained, per-command invertible, and the substrate for the AI Act manifest. **Journaling an opaque blob breaks that property.** You would have a chain that verifies but no longer *proves* the audio, because replaying the journal on a machine without that plugin — or with a different version of it — produces different sound.

The repo already names this. `DESIGN-E1-E2-notes-instruments.md:161`: "plugin hosting (E4 — deferred, breaks the provenance journal)". `DESIGN-E5-routing.md:1631` calls it "the single largest parity gap, by a wide margin… deferred for a *contract* reason, not a capacity one."

**The three options, and what each costs:**

| Option | What it means | Cost |
|---|---|---|
| **A. Hash-only participation** | The blob enters the chain **by blake3 hash only**. The manifest states plainly: *"this project contains third-party processing whose state is recorded by hash; the audio is not reproducible from the journal alone."* | Honest, shippable, and weakens the strongest claim. Recommended by the existing design doc. |
| **B. Two-tier projects** | A project is either **Verifiable** (first-party only, full provenance) or **Extended** (plugins allowed, degraded provenance), stated in the UI and stamped in the manifest. Verifiable stays fully reproducible. | Preserves the differentiator *and* ships plugins. More model and UI work. **My recommendation** — it makes the trade-off the user's, visibly, which is exactly this product's stated posture on refusals. |
| **C. No plugins, ever** | Provenance stays absolute. Compete on determinism, provenance and agent control rather than on breadth. | Coherent, and rules out most working musicians as customers. |

**This is the owner's decision and nobody else's** — it is a positioning decision wearing an engineering costume. Whichever way it goes, **do the design before the implementation**, and do it soon: every month of first-party effect work is a month spent on a substitute for the thing users actually want.

Note the second-order effect: the PDC machinery (`render/src/pdc.rs`) is correct, tested, and today compensates essentially one thing (the limiter's 96 frames). It exists *for* plugins. If option C wins, PDC is largely dead weight.

---

## 8. What contradicts the brief

Listed plainly, since the brief asked.

| Brief said | Verified reality |
|---|---|
| "Quantize exists only as an MCP command" | **False.** No quantize anywhere — not in Rust, not in the catalog, not in the 137 MCP tools. The only trace is a fabricated row in a Swift mock (`StudioMockEngine.swift:1899-1902`). **And `README.md:223` claims the piano roll can quantize.** |
| "Checkpoint appears not to write on quit" | **False.** Wired at `Main.swift:788-794` → `saveSynchronouslyForQuit`, runloop-pumped with a 3 s bound. Persistence is sound. |
| "Metronome is currently a silent flag (a lane is fixing it)" | **True on this tip, and worse:** there is no metronome *button* in the transport either, and the record bar offers a **count-in** that cannot possibly sound. |
| "9 effect kinds, 22 automatable params, bus faders, node meters" | **All true and verified.** |
| "Sampler and drum rack exist and are tested but have no sample-loading UI" | **True, and the strongest finding in the document.** `StudioViewModel.swift:800` hardcodes `kind: "synth"`; the doc comment at `:780-787` states the omission and why. |
| "Undo restores devices/zones/fx/automation" | **True.** |
| "Provenance manifest with authored/recorded/generated/imported" | **True**, with AI Act Article 50(2) fields and IPTC terms, tested. |
| "E7 warp markers and E8 racks specced but NOT built" | **True** — and additionally **`clip.warp.set` itself is audibly inert**, which the brief did not know. |
| "Help/tooltip layer just landed" | **True.** 161 entries, counted. README says 161; correct. |
| "113 commands" | **True.** (A sub-audit said 156; that was wrong.) |

**Not in the brief and worth the owner's attention:**

1. **The ⌘K palette shows 60 inert commands that toast a promise.** Ship-blocking.
2. **Tempo, time signature and key are read-only text.**
3. **There is no Edit menu, and no Undo/Redo menu item anywhere.**
4. **The app opens on a Chat tab**, and the DAW tab is third.
5. **Transport master meters are `sin()`.**
6. **FLAC and 44.1 kHz are advertised in the catalog and refused at runtime.**
7. **The engine hardcodes 4/4** — this is a real limit, not a UI gap.
8. **`DESIGN-E5-routing.md:1620-1625` concludes "that is a credible DAW"** on the strength of engine capability. It is a fair assessment *of the engine* and it is not true *of the product*, because it does not account for reachability. That document should carry a pointer to this one.

---

*Verification method: static read of the tree at `8508127`. Command/GUI reachability was computed by parsing `command-catalog.v2.json` and matching each command name as a string literal across `src/swift/Sources/**/*.swift`, then excluding `StudioCommandPalette.swift`, `StudioMockEngine.swift` and `StudioHelp.swift` to separate real dispatch sites from listings, mocks and tooltip text. Engine claims were read from source and cross-checked against test files. No build was run and no GUI instance was launched. Claims I could not confirm from the tree are marked as such; there are none material to the verdict.*
