# L10 evidence: the Takes system

Lane: `lane/l10-takes`. Base: `main` 46e6c31. Date: 2026-07-12.
Platform: macOS 15 (arm64), rustc 1.93.0, Apple Swift 6.2.

L10 completes the take experience on top of L9's take engine (Revise built the
take lanes, the audition loop, and take persistence in the `.mstudio` package;
L10 does not rebuild that). It adds: the left Browser "Takes" tab, per-stem take
mixing, take-lineage reads, purge-to-reclaim-space, re-roll from lineage, and
the drag-a-take-onto-the-timeline path. Every surface reads `takes.list` and
drives `take.promote` / `take.discard` / `take.auditionMix` / purge, the SAME
commands an agent uses, so the UI and an agent share one path.

Silence-gated: the deterministic mock generator emits low-amplitude tones
(<= about 0.05 peak); no test opens an audio device.

## 1. What the Takes system does

1. TAKES BROWSER (`StudioTakesBrowser`, the left Browser "Takes" tab). Lists
   every generative result in the project, read from `takes.list` (the enriched
   `studio_takes` read). Each row shows its lineage: the prompt, the stem, the
   seed, the model, and the bar range it revised. Filter by prompt (search), by
   region ("This region"), and by whether it is an auditionable alternative.
   Click a take to preview it in place (the timeline navigates to its region and
   its lineage shows in the inspector). Drag a take onto a clip to use it there.
   "More like this" prefills the Revise panel from the take's lineage.
2. PER-STEM TAKE MIXING (`StudioPerStemMixView` in the audition panel). Within
   an auditioned region, pick which take each stem uses independently (drums
   from take 1, other from take 3). Commit composes ONE take per stem and writes
   them as ONE undo step (building on L9's audition, not duplicating it). While
   auditioning it drives `take.auditionMix` so an agent watching hears the same
   per-stem mix.
3. PERSISTENCE. Takes are journaled by L9 (`gen.landed`) and checkpointed under
   `engineTakes` with their engine identity, so they survive save + reopen with
   their lineage and promoted state. The browser reads them back through the
   same `takes.list`.
4. PURGE (`studio_purge_takes`, confirm-gated). Reclaims the audio of purgeable
   candidate takes to free space. It never touches a placed clip's audio, a
   promoted take's un-splice original, or a landing anchor. The take RECORDS
   stay queryable as lineage and read back `offline: true`, exactly like any
   missing asset (the same degradation rule as a moved file). Purge is a host-io
   operation, not a journaled catalog mutation, so it does not fight the
   checkpoint-equals-replay invariant.
5. RE-ROLL. "More like this" is the design 3.4 path: a take's prompt + seed +
   region prefill the Revise panel for one edit and a re-generate.

## 2. The L8 follow-up: landing provenance is not a take (decision + proof)

L8 asked: a landed song writes a `gen.landed` (sourceCommand `gen.song`)
provenance record, which surfaced as a "candidate take" in the browser.

DECISION: a landed song's `gen.song` take is a PROVENANCE ANCHOR for the whole
placed song, not an alternative you would audition. It is classified
`kind: "landing"`, `provenance: true`, `auditionable: false`. The browser's
auditionable list (its default view) filters it OUT, so it never clutters the
alternatives. It stays fully queryable: it is returned by an unfiltered
`takes.list`, reachable by `kind: "landing"`, and still the head of the clip's
`lineage.get` chain. Rationale: the whole song's stems are already ON the
timeline (placed by landing); presenting the song as a "take to promote" would
be misleading, but its prompt/seed/model are exactly the lineage a user wants to
see. Classifying (not deleting) keeps both truths.

Measured (`landing_song_take_is_provenance_not_auditionable`, `tests/takes.rs`),
a bandsplit landing of an 8-bar song:

| read | result |
|---|---|
| unfiltered `takes.list` | 1 take, `kind: landing`, `provenance: true` |
| `auditionableOnly: true` | 0 takes (filtered out of the alternatives) |
| `kind: landing` | 1 take (still queryable as lineage) |
| its lineage | prompt "warm lofi with a sax hook", model, seed 4242 all present |
| `offline` | false (its stems resolve; only the undecoded "mix" blob is absent) |

The classification lives in the engine read (`host.takes`), so an agent and the
UI both see it; the browser is not the only place the rule holds.

## 3. Per-stem take mixing commits the chosen take per stem (measured)

Design 3.2 step 4: "drums from take 2, other from take 3". The commit is
composed from L9's per-variant promotions, one take per stem, as one undo txn.

Measured (`per_stem_mix_commits_the_chosen_take_per_stem`, `tests/takes.rs`),
a drums+other revise with 2 variants (4 candidate takes), committing drums from
variant 0 + other from variant 1:

| check | result |
|---|---|
| drums clip asset after commit | == variant 0's drums take asset |
| other clip asset after commit | == variant 1's other take asset |
| the two drums variants | differ (a genuine mix, not the same variant twice) |
| commit undo unit | one step (both clips restored) |
| promoted takes read back | drums-v0 + other-v1 promoted into their clips |

UI side (`testPerStemMixCommitsChosenTakePerStem`, Swift): driving the view
model's audition, `auditionStemVariant(.other, variant: 1)` over base variant 0,
then Commit, promotes drums-v0 + other-v1 and leaves drums-v1 + other-v0 as
candidates. The compose respects the per-stem override where the user set one
and the base variant elsewhere.

## 4. Takes survive save + reopen (measured)

Measured (`takes_survive_save_and_reopen_with_lineage`, `tests/takes.rs`):
revise (2 stems x 2 variants), commit one, `host.save()`, then reopen the
package from disk:

- all four take records survive (`engineTakes` checkpoint + `gen.landed` in the
  journal);
- the committed take reads back `status: promoted`, `promotedInto: clip_drums`;
- its joined lineage (`prompt`, `model`) survives the round-trip;
- the committed clip still resolves its promoted asset (not offline).

## 5. Purge reclaims space, keeps lineage, protects placed audio (measured)

Measured (`purge_reclaims_candidate_audio_keeps_lineage_and_protects_placed`):
after committing variant 0 (2 promoted, 2 candidates remain), `purge_takes`
with confirm:

| check | result |
|---|---|
| assets deleted | 2 (the un-promoted candidate assets only) |
| bytes reclaimed | > 0 (real files removed from `audio/`) |
| take records after purge | all 4 remain (queryable as lineage) |
| purged candidates | read `offline: true`, `auditionable: false` |
| purged candidate lineage | prompt still present |
| committed clip's audio | still on disk + resolvable (protected) |
| purge without `confirm` | typed error (destructive gate) |

Note on the `takes/` directory: L9 content-addresses generated take audio into
`audio/<hash>.wav` (the one asset store), not a separate `takes/` tree, so purge
deletes the un-referenced take assets from `audio/`. The MSTUDIO-FORMAT `takes/`
slot is nominal in v1; the reclaim behaviour it describes is what purge does.

## 6. Drag a take onto the timeline

The take rows are draggable (`onDrag` carrying the take id). The timeline canvas
`.onDrop` resolves the drop point to the clip under it (X -> ticks, Y -> track
lane, using the same `StudioRowLayoutBuilder` the canvas draws with) and
promotes the take into that clip via `take.promote` (undoable). Proven UI-side
by `testDropTakePromotesOntoClipUnderPoint`: dropping a take on a clip promotes
it (`status: promoted`, `promotedInto` = the clip).

## 7. Agent parity

`takes.list`, `take.promote`, `take.discard`, and `take.auditionMix` are already
the command/tool surface; the browser drives exactly them. `studio_takes` (the
enriched read) and the new `studio_purge_takes` are agent-reachable tools, so an
agent lists, previews-by-region, mixes per stem, and reclaims space over the
same path a person does. Proven by
`takes_browser_reads_and_purges_via_mcp_for_agent_parity` (`dispatch_tool`).
The regenerated `mcp-tools.v1.json` is 93 tools; the parity gate + counts stay
green.

## 8. Tests

Engine (`cargo test --workspace`, all green):
- `tests/takes.rs` (6): classification + joined lineage; per-stem mix commit;
  save/reopen persistence; purge protect + reclaim; landing provenance; MCP
  parity of the read + purge.
- `tests/revise.rs` (5), `tests/landing.rs` (3), `tests/parity.rs` (3), and the
  rest of the workspace stay green (the `host.takes` signature change is
  additive; the one internal caller was updated).

Swift (`MAJIKS_ENGINE=mock swift test`, all green):
- `StudioTakesTests` (8): the pure browser filter (prompt / region /
  auditionable / kind); the mock's take list + landing classification;
  per-stem mix commit; purge; re-roll prefill; drag-to-timeline promote.
- `StudioReviseTests` (7): unchanged, still green.

Boot test: the browser lists real takes from a revised session (the mock seeds
a landed-song anchor + revise candidates, and a live revise appends more), a
per-stem mix commits the chosen take per stem, and purge reclaims the rest. The
mock Swift build compiles and its tests pass, so `MAJIKS_ENGINE=mock` exercises
the whole hands-on flow.

## 9. The screenshot

`l10-takes-browser.svg` renders the shipped layout: the Takes tab (filter bar,
lineage rows, the SOURCE badge on the landed song, IN MIX on a committed take,
PURGED on a reclaimed one, the Purge control) and the audition panel's per-stem
mix (drums take 1 + other take 3, a real cross-variant mix). The app UI cannot
be screenshotted headless in CI; this is a rendering of the SwiftUI layout with
the shipped tokens + copy.

## 10. How to reproduce

```bash
cd engine
cargo test -p agent-surface --test takes            # the L10 acceptance suite
cargo test --workspace                              # everything, all green

cd ../src/swift
MAJIKS_ENGINE=mock swift build
MAJIKS_ENGINE=mock swift test --filter StudioTakesTests
```

## 11. Additive engine exports (for coordinator reconciliation)

- `StudioHost::takes(&Value)` now takes a filter args object (was
  `Option<&str>`) and returns each take enriched with `kind` / `stem` /
  `engineIdentity` / `auditionable` / `provenance` / `offline` / `createdSeq` /
  `lineage`; the one internal caller (`tests/revise.rs`) was updated.
- `StudioHost::purge_takes(&Value)` (new): confirm-gated host-io reclaim.
- Registry: `studio_takes` schema gained the filter fields; `studio_purge_takes`
  is a new `ToolKind::Maintenance` tool (Manage tier); `dispatch` routes it.
  `engine/docs/generated/mcp-tools.v1.json` regenerated (93 tools).
- No catalog command was added or changed (catalog stays 71 / 70 command
  tools); purge is host-io, take.auditionMix is the existing catalog command.

Shared Swift files touched (additive, listed for reconciliation with L13/others):
`StudioEngineModel.swift` (4 protocol requirements), `StudioViewModel.swift`
(takes-browser state + per-stem-mix compose + purge/place/reroll), `Studio
InspectorView.swift` (+1 line embedding the per-stem-mix view), `StudioBrowser
View.swift` (the Takes tab body), `StudioTimelineView.swift` (+`.onDrop` for
drag-to-timeline), `StudioMockEngine.swift` + `RealStudioEngine.swift` (the 4
new methods). New files owned by L10: `StudioTakesModel.swift`,
`StudioTakesBrowser.swift`, `Tests/StudioTakesTests.swift`, `tests/takes.rs`.
No export/manifest files were touched (L13's lane).

## 12. Deviations and proposals (on record)

1. Purge is host-io (like save/export), not a journaled catalog command, so the
   frozen catalog + parity counts (71 / 70) are untouched. A future `take.purge`
   catalog command would let a replay reproduce a purge exactly; today a purge
   is a disk-space reclaim whose only observable effect is that an asset becomes
   `offline`, which the format's missing-asset rule already covers. Proposal: a
   catalog `take.purge` in a future rev if purge must be journaled.
2. The RealStudioEngine (FFI) methods route through `client.tool` /
   `client.submit` (`studio_takes`, `take.auditionMix`, `take.promote`,
   `studio_purge_takes`), matching L9's pattern, so no regenerated FFI binding
   is needed. They compile under the real build's `REAL_ENGINE` flag; this lane
   could not link the `MajiksEngine.xcframework` here (mock build), so they are
   reviewed against the established client API rather than compiled in CI.
3. Drag-to-timeline promotes a take into the clip under the drop (use-this-take-
   here, the length-preserving, undoable `take.promote`). Dropping into empty
   space to create a NEW clip from a take (which needs engine-side length math)
   is a small follow-up.

## 13. Questions

1. Purge as host-io vs a journaled `take.purge` catalog command (proposal 1):
   is "purge is a disk reclaim; a purged take reads offline, journal unchanged"
   acceptable for v1, or should a catalog rev add `take.purge` before launch?
2. Drag-to-timeline currently promotes onto the dropped-on clip. Do we also want
   dropping a take into empty track space to place a NEW clip (proposal 3)?
3. The Takes rail is 172 pt wide, so the browser filter is compact (search +
   Auditionable + This-region chips; kind is reachable by toggling Auditionable
   off). Is a wider Takes panel (or a kind menu) wanted, or is the compact rail
   right for v1?
