# Journey audit 2 — findings

The second user-journey reachability audit. The first one's list existed only in
a chat message and was lost, which is why this file exists: **it is the
deliverable, not the afterthought.** Everything below is either fixed on
`fix/journey-audit-2` (marked FIXED) or left for a later lane with enough detail
that nobody has to rediscover it.

A journey here is a whole intention a human has, first click to result — not a
unit test. At every step the audit asks three questions:

1. **Can a human get here at all?** Is there a visible affordance, or does the
   feature exist only via a command nobody can find?
2. **Does it do what it says?** Or does it report success on work the engine
   refused?
3. **Does it tell the truth when it fails?** Or is it a bare `HTTP 401` for
   three different reasons, a generic toast, or silence?

The owner is **not a DAW user** and drives this on a 4K TV at couch distance.
"Discoverable by someone who has never opened a DAW" is the bar.

---

## The journeys walked, and how far each got

| # | Journey | Got to | Verdict |
|---|---|---|---|
| J1 | Cold open, no project → make a sound come out | End | Works. The empty-project path auto-shows the on-screen keyboard, the keys reach the engine's one note path, and a silent note explains itself once (`StudioSilentPreview`). One latent hole: J6-2 below replaces the project wholesale without saying so. |
| J2 | Import a song → split into stems → mute one → export the rest | Blocked at split | Owned by another lane (`StemSessions/`, `landing.rs`). Reported only — see "Other lanes' territory". |
| J3 | Play the on-screen keyboard → record → edit a wrong note → hear the fix | End | Works. Keyboard, record-landing and the roll all sit on one engine and one note path. |
| J4 | Browse the sounds vault → filter to something in key → drag it in → have it play in time | **Fails at the last step** | **J4-1 FIXED.** The filters were fixed by a previous lane (`fb66e95`); the *drop* still landed off-grid. |
| J5 | Sign in as publisher → publish a finished track → see it on the site | **Fails for a scheduled publish** | **J5-1 FIXED.** J5-2..J5-5 reported. |
| J6 | Save → quit → reopen → find everything as it was | **Fails in two ways** | **J6-2 FIXED.** J6-1 (data destruction) and J6-3/J6-4 reported. |
| J7 | Do any of the above, press ⌘Z, get exactly one step back | **Fails twice** | The *value* of one step holds on the paths walked (`e1621a8` fixed the transport). But ⌘Z is not in the menu bar at all (J7-2), and one stem gesture is still four steps (J7-1). Both reported, neither fixed — see below for why. |

---

## FIXED on this branch

### J4-1 — a sound dropped from the vault ignores Snap, so it lands off the beat

**Ranked #1: this is the journey the owner demos, and the failure is audible.**

`StudioTimelineView.handleStringDrop` turned the drop point into ticks and used
them raw:

```swift
let ticks = StudioTimelineMath.pxToTicks(point.x, pxPerTick: model.pxPerTick, scrollTicks: scroll)
...
model.placeSound(path: path, onTrack: trackID, atTicks: max(0, ticks))
```

Every *other* positioning gesture on that same canvas snaps through
`model.snapMode` — clip move (`StudioTimelineView.swift:1164`), clip trim
(`:1182`), automation points (`:1218`), the playhead (`:1083`), and the ruler's
region and loop drags via `StudioSelectionOps.rulerRegion`. The browser drop was
the only one that did not, while the transport bar sat there displaying
**Snap: Bar** (the default, `StudioViewModel.swift:69`).

Magnitude: default zoom is `24.0 / ppq` px per tick — about 96 px to the bar. One
pixel of pointer error is `ppq/24` ticks, so an ordinary hand-drop three or four
pixels off a bar line lands the loop an eighth of a beat late — roughly 60 ms at
120 BPM, which is not "slightly loose", it is audibly not in time. From a sofa
with a TV remote-grade pointer the error is larger.

**Why nothing caught it — the survivor.** The vault suite has 26 tests and one of
them, `testDroppingASoundIsExactlyOneJournaledCommand`, does assert where the
clip lands:

```swift
model.placeSound(path: ..., onTrack: track.id, atTicks: 3_840)
...
XCTAssertEqual(clip.startTicks, 3_840, "the sound did not land where it was dropped")
```

`3_840` is already an exact bar multiple, so the assertion is satisfied whether or
not anything snaps — **a wait predicate satisfied by a fixture that already
shipped the expected value.** The one line that decides the tick, in the view, was
asserted by nothing. Every component proven; the feed line unguarded.

**Fix.** `handleStringDrop` now snaps through `StudioTimelineMath.hardSnap` with
the project's own `snapMode`, time signature and phase anchor — the same helper
and the same phase anchor the ruler's region drag uses. `hardSnap` rather than the
magnetic `snap`: a *creation* drop has no pre-existing position worth preserving,
so "the pointer was 20 px from the bar" means "the user aimed roughly", not "the
user chose 47 ticks past the bar". `hardSnap` returns the tick untouched when
`snapMode == .off`, so the Snap control still governs it exactly.

Tests: `StudioSoundsDropSnapTests`.

### J6-2 — a project that fails to load is replaced by a synthetic demo, silently

**Ranked #2: if this fires during the video the owner demos eight tracks that are
not his, and nothing on screen says so.**

`StudioEngineFactory.makeDefault()`:

```swift
} catch {
    NSLog("StudioEngineFactory: real engine init failed (\(error)); falling back to mock")
    return StudioMockEngine()
}
```

`StudioMockEngine` is not an empty stand-in. Its own header calls it "the L5
performance-gate fixture: exactly 8 tracks and 100 clips". So when the real engine
cannot open the package — a corrupt checkpoint, a broken hash chain, a permissions
problem — the user is shown a fully populated, fully interactive project that is a
**test fixture**, and the only trace is an `NSLog` in Console.app.

This is the exact defect class the codebase has shipped before (a piano roll wired
to a mock while the real engine ran alongside), one layer up: now it is the whole
project.

**The dead affordance that was supposed to prevent it.** The factory already
carries the flag for this, with a comment stating it is used:

```swift
/// True when the roll is on the real engine. The UI uses it to say so
/// rather than presenting a demo clip as if it were the user's work.
static var noteEngineIsReal: Bool { ... }
```

`noteEngineIsReal` has **zero readers** anywhere in `Sources/` or `Tests/` — the
comment describes a UI that was never written. (The on-screen keyboard does
surface its own mock-ness, via `controller.isWired` at
`StudioOnScreenKeyboard.swift:99`; nothing surfaces the *engine's*.)

**Fix.** The fallback is recorded on the factory (`engineFallbackReason`) instead
of only going to `NSLog`, and the Studio says so on screen: a warning toast naming
what happened and that the work on screen is not the user's project. Phrased for
someone who has never opened a DAW — it does not say "mock engine", it says the
project could not be opened and that nothing shown belongs to them.

Tests: `StudioEngineFallbackTests`.

### J5-1 — a *scheduled* publish reports "Published" and hands over a dead link

**Ranked #3: the journey is literally "publish → see it on the site", and this
step says you can when you cannot.**

`MetadataEditSheet.swift:388` lets the user schedule a publish and tells them
exactly what will happen:

> "Track will be created with scheduled visibility and auto-publish at this time"

The app therefore *knows* the track is not going live now. It then reports it
identically to an immediate publish (`PublisherStore.swift:763`, `:810`):

```swift
candidates[index].status = .published(trackId: result.trackId, slug: result.slug)
...
ToastManager.shared.show("Published: \(candidate.title)", style: .success)
```

and `PublishStatus` (`PublisherModels.swift:72-92`) then renders `statusText`
`"Published"`, a green check (`PublishQueueView.swift:839`) and a live-looking
URL:

```swift
var trackURL: String? {
    if case .published(_, let slug) = self {
        return "https://majiks.online/track/\(slug)"
    }
    return nil
}
```

So the owner schedules a track, sees "Published", clicks the link, and finds
nothing there. Server-side the track is `visibility = 'scheduled'` with
`published_at = null`.

**Fix.** `PublishStatus.published` carries the scheduled date. `statusText` reads
"Scheduled for <date>" rather than "Published", the queue's colour is no longer
the same green as a live track, and `trackURL` returns nil until the track is
actually live — a link that 404s is worse than no link. The toast says it is
scheduled and when. Five call sites, all updated.

Tests: `PublisherScheduledStatusTests`.

---

## Reported, NOT fixed — ranked by demo impact

### J6-1 — reopening can silently destroy the journal (data loss)

**The most severe finding in this audit — silent, unrecoverable data
destruction.**

> 🔒 **OWNED BY `fix/journal-recovery` (worktree `wt-journal`). Do not fix it
> here or in any other lane.** A dedicated lane holds this with a wider brief
> than the single condition below: audit *every* `File::create` on a journal
> path, establish behaviour on a **partially** corrupt chain, and decide what
> the user is told when a recovery happens. This section is the analysis handed
> to that lane; it is kept here because it is what survives if either session
> dies.

**It is not hard — it is roughly six lines.** See "why this lane did not take
it" at the end of this section.

⚠️ **Correcting this section's own first draft.** It originally said the fix
needed "a recovery path in the engine, a bigger and riskier change". That was
wrong, and reading the engine disproved it. **The recovery path already exists,
already ships, and is already tested.** Do not scope this as engine work.

`StudioHost::open_or_create` decides using **only the checkpoint**
(`engine/agent-surface/src/host.rs:578-585`):

```rust
if pkg.join("project.json").exists() {
    Self::open_package(&pkg)
} else {
    Self::create_at(&pkg, name)
}
```

and `Package::create` (`engine/timeline-core/src/package.rs:122-132`) opens the
journal with `File::create`, which **truncates**:

```rust
fs::create_dir_all(Self::audio_dir(dir)).map_err(io)?;
// empty journal
File::create(Self::journal_path(dir)).map_err(io)?;
```

The journal is the durability mechanism — `StudioProjectSaver.swift:13-44` says so
explicitly, and every command is appended and fsynced as it is issued;
`project.json` is only a fast-reopen checkpoint. So a package with an **intact
journal and a missing checkpoint** is a fully recoverable project, and the app's
response to it is to overwrite the journal with an empty file. No warning, no
backup, nothing to undo.

How the checkpoint goes missing while the journal survives: `Package::create`
itself writes the journal *before* `write_checkpoint`, so any failure in between
(disk full, permissions, power loss on first run) leaves exactly that state. A
backup/sync tool or a partial restore does it too.

**THE RECOVERY ALREADY EXISTS.** `Package::open`
(`timeline-core/src/package.rs:191`) never depended on the checkpoint. It reads
the **journal** first, verifies the hash chain with `verify_lines` (dropping only
a torn final line), and then treats the checkpoint as nothing more than a fast
path:

```rust
let mut session = match Self::try_fast_open(dir, &envelopes, &chain_tip, chain_len) {
    Ok(Some(s)) => s,
    _ => {
        // Full replay from empty.
        let base = empty_project_from_checkpoint(dir).unwrap_or_else(default_project);
        Session::replay(base, envelopes)?
    }
};
```

and `empty_project_from_checkpoint` (`:335`) opens `project.json` with
`fs::read_to_string(...).ok()?` — a **missing checkpoint simply yields `None`**,
so the `unwrap_or_else(default_project)` branch runs and the project is rebuilt
from the journal in full.

That path is neither new nor speculative. `agent-surface/tests/persistence_bounce.rs`
already covers it, and both tests were observed passing in this lane's gate 1:

- `a_project_recovered_from_the_journal_alone_bounces_bit_identically`
- `edits_made_after_a_save_survive_the_next_reopen`

**So the entire defect is one condition asking the wrong file.** `open_or_create`
gates on the checkpoint when the journal is what holds the project. The fix:

```rust
let has_checkpoint = pkg.join("project.json").exists();
let has_history = std::fs::metadata(pkg.join("journal.jsonl"))
    .map(|m| m.len() > 0)
    .unwrap_or(false);
if has_checkpoint || has_history {
    Self::open_package(&pkg)      // already replays when the checkpoint is gone
} else {
    Self::create_at(&pkg, name)
}
```

An empty journal still takes the create path — that is the half-created package
described above, and creating it properly is correct. Only a journal with
something in it counts as a project.

Suggested test, in `persistence_bounce.rs` beside its siblings, asserting the
**rendered audio** rather than a flag:

```
a_package_whose_checkpoint_is_gone_is_recovered_not_overwritten
  built("CheckpointGone") -> project.save -> expected = render_master()
  remove project.json, leave journal.jsonl
  StudioHost::open_or_create(&pkg, ...) -> digest(render_master()) == digest(expected)
  and journal.jsonl is still non-empty (it was not truncated on the way in)
```

Mutation to confirm the guard bites: restore the old `project.json`-only
condition and the test must fail on the digest.

Do not fix this by deleting the journal "cleanly". The journal is the project.

**Why this lane did not take it.** Two independent reasons, either sufficient.

1. **Ownership.** `fix/journal-recovery` owns it, with a wider brief. Two lanes
   editing `host.rs` concurrently is the collision that has already cost this
   project real time today.
2. **Sequencing.** The change is in Rust, and gate 2 (`build-engine.sh`) had
   already produced the framework gates 4–7 link against. Editing Rust
   afterwards means either gate 7 testing a **stale framework** — a silently
   invalid green, precisely what `GATES.md` exists to prevent — or restarting
   the whole seven-gate chain on a box at load 160+ with two other lanes
   building.

Given the brief's standard (three journeys fixed properly beats twenty
half-fixes), shipping three fully mutation-checked fixes and handing this one
over fully scoped was the better trade.

### J7-2 — Undo is not in the menu bar; ⌘Z is a hidden button in the mixer dock

**High demo impact for THIS owner specifically.** He is not a DAW user. When
something goes wrong he will look in the menu bar for Edit ▸ Undo.

The only two ⌘Z bindings in the entire app are hidden buttons in
`StudioMixerDock`'s header (`StudioMixerDock.swift:229-246`):

```swift
Button { model.undo() } label: { ... }
    .keyboardShortcut("z", modifiers: .command)
Button { model.redo() } label: { ... }
    .keyboardShortcut("z", modifiers: [.command, .shift])
```

`Main.swift`'s `.commands { }` block declares `CommandGroup`s for `.appInfo`,
`.appSettings`, `.newItem` and `.help` and **no `.undoRedo` group at all**
(verified: `grep -n "undoRedo" Sources/Main.swift` returns nothing). So the Edit
menu still carries AppKit's *default* Undo/Redo items, which target the responder
chain's `undo:`/`redo:` — the focused text field's undo manager — and never
`StudioViewModel.undo()`.

Two consequences:

1. **Discoverability.** There is no menu item anywhere that undoes a DAW edit. The
   real control is an unlabelled chevron-header button on a bottom dock that may
   be collapsed or off-screen on a TV.
2. **A possible swallowed keystroke.** Two independent claims on the same key
   equivalent. A *disabled* default Edit ▸ Undo can still take the key event ahead
   of a view-local button shortcut, so ⌘Z may do nothing while a text field has
   focus. Not proven here — it needs a human at a window (see "Human checks").

**Not fixed: the fix belongs in `Main.swift`'s menu declarations, which another
lane owns.** The correct change is a `CommandGroup(replacing: .undoRedo)` driven
through the existing `StudioMenuBridge` (the same push-up mechanism the Song /
Track / Clip / Transport menus already use), so that Edit ▸ Undo and ⌘Z resolve to
one place instead of two.

### J7-3 — ⌘R is claimed twice: Publisher "Refresh" almost certainly beats Record

**Found by a full shortcut-collision sweep (below). New — not the pair the menu
lane is already fixing. It hits the record journey (J3) directly.**

Two live claims on ⌘R:

- `Main.swift:361` — Publisher ▸ **Refresh**, a real menu-bar item in a
  `CommandMenu`, present at all times regardless of which tab is showing.
- `StudioRootView.swift:618` — a hidden zero-size Button running
  `model.toggleRecord()`, guarded by `isFrontmost`, and documented in its own
  comment as *"Cmd+R: record. Toggles start / stop / cancel-count-in"*.

macOS dispatches menu-bar key equivalents ahead of view-local button shortcuts,
so pressing ⌘R in the Studio is expected to fire Publisher Refresh and never
reach Record. Record is the core gesture of the whole "play the keyboard →
record it" journey.

Not a total dead end — the Record button in the record/transport bar still works
— but the documented keystroke for the app's most important verb is bound to
something else entirely. Needs a human at a window to confirm which one wins
(see "Human checks").

**Not fixed:** both ends are out of reach or wrong to touch. The Publisher
`CommandMenu` is in `Main.swift`'s menu declarations, which another lane owns;
and moving the *DAW's* record shortcut off ⌘R to dodge a Publisher refresh would
be fixing the wrong end.

### J7-4 — nobody has ever swept for shortcut collisions, and there is a generator

The sweep that found J7-3 took one `grep`. Results across all of `Sources/`:

| Keys | Claim A | Claim B | Live? |
|---|---|---|---|
| ⌘R | `Main.swift:361` Publisher Refresh | `StudioRootView.swift:618` Record | **Yes — J7-3** |
| ⌥⌘L | `Main.swift:428` Pop Out Library | `Main.swift:499` `Window("Library")` | **Yes** — menu lane is fixing |
| ⌥⌘S | `Main.swift:433` Pop Out Studio | `Main.swift:522` `Window("Studio")` | **Yes** — menu lane is fixing |
| ⌘? | `Main.swift:440` Help | `Main.swift:552` `Window` help scene | **No** — that scene carries `.commandsRemoved()` at `:554`, so it generates no menu item and no key equivalent |
| ⌘Z | `StudioMixerDock.swift:235` | AppKit default Edit ▸ Undo | **Probably** — see J7-2 |

The ⌘? row is worth keeping precisely because it is a *negative*: it looks
identical to the ⌥⌘L / ⌥⌘S pairs in a grep and is not a defect, so a sweep that
does not read `.commandsRemoved()` will report it and burn someone's afternoon.

The structural risk behind all of this: **`StudioMenuCommands.swift:679` generates
`.command` shortcuts from a palette table** —

```swift
content.keyboardShortcut(KeyEquivalent(shortcut.key), modifiers: .command)
```

— with nothing anywhere asserting that a generated key does not already belong to
a hand-written `CommandMenu` in `Main.swift` or a hidden button in
`StudioRootView`. Adding one palette entry with the wrong letter silently steals a
keystroke from another surface. The durable fix is a test that collects every
`keyboardShortcut` claim (generated and hand-written) and fails on a duplicate
pair — cheap, and it would have caught all three live collisions above.

### J7-1 — "Open in Studio" from the Stems tab is one click and four undo steps

`StudioViewModel.importStemSession` (`StudioViewModel.swift:321-333`) loops over
`request.stems` calling `performImport(newTrack: true)` once per stem with **no
surrounding transaction bracket**. Each of those calls opens and commits its own
bracket (`StudioViewModel.swift:228-243`), so a four-stem session is four undo
units for one gesture.

The sibling path already fixed this and documents exactly why
(`separateIntoStemTracks`, `StudioViewModel.swift:401-467`):

> "`importStemSession` runs four `performImport`s, and each of those is already
> bracketed... Four brackets is four presses of Cmd-Z... One more bracket around
> the lot makes it one unit."

`separateIntoStemTracks` wraps its call in one more `txn.begin`/`txn.commit`
(`:457-466`). The direct entry point does not — and it is reachable directly from
"Open in Studio" on the Stems tab (`StudioRootView.swift:536-538` and the
`pendingStemImport` bridge at `:926-934`).

This is a textbook **"recurrence = missing primitive"**: the same bug written
twice, fixed once. The fix is four lines — the same bracket, around the loop.

**Not fixed deliberately.** The function is in `StudioViewModel.swift`, which is
not on the off-limits list, but it is the *stem import journey*, and the
concurrent stem lane is actively changing that journey. Applying a four-line
transaction change underneath an in-flight lane risks a semantic merge conflict
in exactly the code that decides undo grouping. It should be done by whoever lands
the stem work, or immediately after they land.

### J5-2 — the publish queue is lost on quit

`PublisherStore.candidates` (`PublisherStore.swift:38`) has no `Codable`
conformance and no save/load call site anywhere; `applicationWillTerminate`
(`Main.swift:854-892`) flushes the Studio project and the Library and never
touches the publisher store. A user who queues a batch, works through metadata,
hits a duplicate warning and quits finds an empty queue on relaunch with no record
it ever existed. Every metadata edit is retyped from scratch.

### J6-3 — loop points do not survive a reopen

`loop_region` lives on the runtime-only `Transport` struct
(`engine/agent-surface/src/host.rs:59-69`), which `open_package` reconstructs with
`Transport::default()` (`host.rs:596`). `to_project_json` never emits a loop key,
and `transport.loop.set/clear` mutate only `self.transport.loop_region`
(`host.rs:2150-2157`). Playhead position is lost the same way. "Find everything as
it was" is false for the loop a person spent the session working inside.

### J5-3 — a rejected refresh token signs the user out with no explanation

`ensureValidToken()` (`PublisherStore.swift:397-420`) catches a failed refresh and
only logs it:

```swift
} catch {
    AppLog.error("Token recovery via refresh token failed: \(error)")
}
```

`performTokenRefresh()` does flip `authState = .notAuthenticated`
(`PublisherStore.swift:366`), so the UI drops to "Not signed in" — with no toast
and no reason. The neighbouring path in `validAuthContext()`
(`PublisherStore.swift:440-445`) *does* toast "Your majiks.online session has
expired — please sign in again". The more common case is the silent one. Use the
same sentence in both.

### J5-4 — three different sign-in failures produce one generic sentence

`handleAuthCallback` (`PublisherStore.swift:172-174`) reports `"No authorization
code received"` whenever a `code` query item is absent. Nothing in the file ever
reads the `error` / `error_description` parameters Keycloak returns — so a user
who cancels consent (`access_denied`), a misconfigured client, and a genuinely
malformed redirect are one indistinguishable message. Token exchange failures
(`:208-212`) are reported as a bare `"Token exchange failed (HTTP <code>)"`. The
one good path is the network throw (`:262-264`), which carries the system's own
"The Internet connection appears to be offline".

Exactly the "bare `HTTP 401` for three different reasons" shape.

### J5-5 — a publish is never verified against the server

`publishTrack` flips a candidate to `.published` purely from the RPC response
shape; `BackendViewModel.publishTrack` (`BackendViewModel.swift:2037-2041`) treats
any response carrying `track_id`/`track_slug`/`url` strings as success. The one
call that could confirm it, `fetchCatalogue`, runs *after* the status is already
green (`PublisherStore.swift:589`, `:604`, `:622`) and never checks whether the
just-published id is actually in the returned list; its own failure sets
`catalogueState = .failed` with **no toast** (`:892`). So "Published" plus a
silently failed catalogue fetch is indistinguishable from a real publish.

Related, lower severity: `try?` swallows at `PublisherStore.swift:687-691`
(generation params dropped), `:697` (a corrupt LRC silently drops synced lyrics),
and `:236, 242, 379, 383` (Keychain writes — a locked keychain means auth appears
to work now and silently reverts to signed-out next launch).

### J4-2 — dropping an audio *file* on the timeline ignores where it was dropped

`StudioTimelineView.handleDrop` (`:105-114`) branches on `fileURL` **before** any
geometry is computed and calls `model.importAudio(path:)`, which always mints a
new track and places at tick 0:

```swift
file.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
    guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
    Task { @MainActor in model.importAudio(path: url.path) }
}
return true
```

So a Library song dragged onto track 3 at bar 17 — and the Library row's own help
text invites exactly that gesture (`StudioBrowserView.swift:661`, "drag it onto
the timeline") — lands on a brand-new track at bar 1. Defensible for "import a
whole song", but it is the same gesture as J4-1 with a different payload and a
different rule, which is not learnable.

Second, smaller problem in the same block: `return true` tells SwiftUI the drop was
accepted, then the `guard ... else { return }` inside the async completion can
discard it silently, and the `loadItem` error is `_`. A drop that fails to decode
is indistinguishable from one that worked.

### J6-4 — there is no way to open, name, or find a project

There is exactly one project, ever, at a fixed path
(`StudioEngineFactory.defaultProjectPath()`, `:103-114`). No New, no Open, no
Recent, no Save As, no `NSDocumentController` anywhere. This is a coherent design
for a single-project appliance and it is **not** a bug on its own — but it is worth
stating plainly, because "Save a project → quit → reopen → find everything as it
was" only works for one project, and starting a second piece of music means
destroying the first with no prompt. If the owner ever makes two songs, this is
the next thing to break.

---

## Other lanes' territory — reported, not touched

Per the brief these were not modified.

- **`Sources/StemSessions/*` and `engine/agent-surface/src/landing.rs`** (stem
  lanes + separation settings). J2 was walked only as far as the hand-off. Nothing
  new found beyond what the concurrent lane is already changing; the audit did not
  go deeper to avoid colliding with in-flight edits.
- **`Sources/Main.swift` menu declarations** (duplicate View/Window menus). Noted
  while tracing quit behaviour: `applicationWillTerminate` (`Main.swift:854-892`)
  flushes `StudioProjectSaver` and the Library but not `PublisherStore` — that is
  the mechanism behind J5-2 above. The fix for J5-2 belongs in `PublisherStore`
  (make the queue `Codable` and persist it), not in the menu declarations, so it
  can be done without entering that file.

---

## Test-integrity findings (not user-facing)

- **`testDroppingASoundIsExactlyOneJournaledCommand` is tautological about
  position.** It asserts `clip.startTicks == 3_840` having passed `atTicks: 3_840`
  — a bar-aligned fixture that already carries the expected value, so it cannot
  observe a missing snap. It is a good test of the *command count*; it is no test
  of placement. Left in place and now backed by `StudioSoundsDropSnapTests`, which
  passes a deliberately off-grid tick.
- **`StudioEngineFactory.noteEngineIsReal` has zero readers**, under a doc comment
  asserting the UI uses it. Dead code whose comment is the only thing keeping it
  looking alive — the same shape as an entry-point scan satisfied by a method's own
  definition.
- **⚠️ `GATES.md`'s own canonical sequence does not wipe `.build` between engine
  flags, so its gate 6 runs mock tests against a real-engine build.**

  ⚠️ **This is finding ONE of TWO, and it is NOT the cause of the other.** An
  earlier draft of this section called it "the likely explanation for the
  pre-existing failures three lanes reported". That is retracted. A fifth data
  point killed it: a **freshly wiped** run still produced **16** distinct
  failures, so "clean iff freshly wiped" is false. The gate-contract defect
  below is real and worth fixing on its own merits; the nondeterminism after it
  is a separate, still-unexplained phenomenon. Presenting the first as the cause
  of the second is the third such over-reading this investigation has had to
  walk back — after "load-sensitive" and after "`.build` state" — and each one
  came from a correlation that held until one more run.

  The canonical list wipes only before gate 3:

  ```
  rm -rf .build && MAJIKS_ENGINE=mock swift build   # 3
  MAJIKS_ENGINE=real  swift build                   # 4
  MAJIKS_ENGINE=real  swift build --build-tests     # 5
  MAJIKS_ENGINE=mock  swift test                    # 6  ← no wipe after a REAL build
  MAJIKS_ENGINE=real  swift test                    # 7  ← no wipe
  ```

  The prose in the same file says to `rm -rf .build` between engine flags. The
  sequence does not do it at 5→6. The stems lane confirmed the mechanism at
  source: `src/swift/Package.swift:21` gates `.define("REAL_ENGINE")` on **both**
  the app and test targets, and line 73's own comment records that the tests need
  that flag or a `#if REAL_ENGINE` test compiles out entirely. **The repo
  documented the hazard at the exact site; the gate list did not honour it.**

  Running mock tests against a real-engine build is wrong on its own merits,
  whatever it does or does not explain. **Every lane should add the wipes the
  prose demands and the sequence omits, and the fix belongs in the gate
  contract rather than in each lane's private scripts.** This lane's runners add
  them (`j2-gates27.sh:19`, `j2-window.sh:16`, `j2-window.sh:29`), which is the
  only reason its gate 6 numbers mean anything.

- **⚠️ A separate, still-unexplained nondeterminism in ~24 async tests.**
  Finding TWO. Not caused by the gate-contract defect above, and not caused by
  anything else yet identified.

  Roughly two dozen tests across `StudioReachabilityTests`,
  `StudioTransportTests`, `StudioMetronomeTests`, `StudioLoopAndMetersTests` and
  `StudioDiscoverabilityTests` fail in **varying subsets**. Observed draws across
  five runs: **0, 7, 16, 17, 24**.

  Three hypotheses have been proposed and all three are dead:

  | Hypothesis | Killed by |
  |---|---|
  | load-sensitive | a quiet run produced MORE failures (24) than a loaded one (17) |
  | nondeterministic-by-luck | 7 vs 17 on identical pristine code looked like flakiness, but the draw is not random-looking enough to leave there |
  | `.build` state | a **freshly wiped** run still produced **16** |

  No isolated variable predicts the draw — not load, not `.build` state, not the
  code under test. **Nobody has isolated it.** It should be stated that way
  rather than attached to whichever correlation held most recently; three
  retractions in one night is the cost of doing otherwise.

  **This lane's data point.** Gate 7 here ran **real tests against a real build
  after a fresh wipe** (`j2-gates27.sh:22`, `j2-gates567.sh:18`,
  `j2-window.sh:29`) — no engine mismatch possible — and drew exactly **one**
  failure: `StudioTransportTests.swift:87`, `afterStop → 53` vs
  `startTolerance → 48`. That is one more draw from the same pool, from a
  different gate and a different engine flag than the other lanes' runs.

  **Attribution, by set membership rather than by count.** A change cannot cause
  a failure that already occurs without it. `StudioTransportTests` fails on
  pristine `81bb183` in another lane's run, so this lane's diff cannot have
  introduced it. Independently: this diff contains no transport, playhead or
  loop file (`git diff --name-only`); it never touches `StudioViewModel.swift`;
  and no test in the bundle touches `StudioEngineFactory.shared`, so the factory
  change cannot reach an engine any transport test constructs. Counts move
  between runs and prove nothing on their own — **membership is the argument.**

- **Nothing in the test bundle may touch `StudioEngineFactory.shared`** — and
  today nothing does. `RealStudioEngine.init` OPENS the user's `.mstudio`
  package at `defaultProjectPath()`, so under gate 7 (`MAJIKS_ENGINE=real swift
  test`) any test that materializes `shared` opens **the owner's real project**,
  quite possibly while the shipping app has it open too. This lane nearly
  introduced the first such reader: an `engineFallbackReason` accessor that did
  `_ = shared` "so the answer is guaranteed to have been decided". Caught before
  it ran and rewritten to report only what has already been decided. Worth a
  standing guard — a test asserting that no file under `Tests/` references
  `StudioEngineFactory.shared` would be three lines and would hold the line
  permanently. Given J6-1 (a damaged package can be silently destroyed on the
  next open), this is not a theoretical tidiness point.
- **Run every new guard against the BROKEN state before trusting it.** A guard
  that has only ever been seen passing is not a guard. The menu lane's first-cut
  duplicate-title check reported `DUPLICATED: []` against the *broken* file,
  because the duplicates were app-vs-**system**, not app-vs-app — it would have
  shipped green on the exact bug it was written for. Every assertion added by this
  lane was mutation-checked in the other direction: break the fix, confirm the
  named test fails, revert. That table is in the lane report. Adopt it as
  standard: the first run of a new guard should be a FAILING one.
- **Ordering-dependent rendering assertions.** `ImageRenderer` is not
  bit-deterministic: the first render pair in a process differs by ~71
  channel-units and every later pair by 0 (glyph-cache warm-up). Any
  `XCTAssertEqual(mass, 0)` therefore depends on an alphabetically earlier test
  having paid that cost. Setting `RUST_TEST_THREADS` / changing test order can
  expose this. A test that is green only because of the order it runs in is
  unreliable signal; these should measure a floor first and bound against it, as
  `StudioSaveIndicatorWidthTests` does.
