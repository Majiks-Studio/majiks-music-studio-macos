# L9 evidence: Revise + Extend + Add-a-Layer

Lane: `lane/l9-revise`. Base: `main` a7687a5. Date: 2026-07-12.
Platform: macOS 15 (arm64), rustc 1.93.0, Apple Swift 6.2.
The killer feature (01-DESIGN 3.2/3.3/3.3b): select bars on the timeline,
describe a change, get variants, commit one. Built end to end through the same
timeline-core command bus the UI, MCP, and CLI use, so undo and provenance are
identical whoever drives.

Silence-gated: the deterministic fixture generator emits low-amplitude tones
(<= about 0.05 peak) and no test opens an audio device.

## 1. What the flow does

1. REVISE. Drag a bar region (bar-snapped, on the beat-tracked grid), pick a
   scope (All / a stem / a multi-select), type an instruction, choose a variant
   count (default 3). For each scoped stem the engine generates N draft variants
   (turbo-8 rung), splices each into the ORIGINAL clip audio with an equal-power
   crossfade placed INSIDE the region, ingests each spliced result as a
   candidate take, and journals `gen.revise` + `gen.landed`. Take lanes
   materialize under the affected tracks. Non-blocking.
2. AUDITION. The region loops with 2 bars of pre-roll. Keys 1-9 switch which
   take is audible, A returns to the original.
3. COMMIT. `take.promote` swaps each scoped clip to its spliced asset, wrapped in
   a `txn.begin`/`txn.commit` bracket so the whole commit is ONE undo step. The
   crossfade is already baked into the spliced asset (P0-A: fades inside the
   region keep the outside bit-exact). DISCARD keeps the takes as candidates in
   the Takes history.
4. FINALIZE (the draft/commit two-phase, 3.2 step 6). In the background the
   committed draft take re-renders at the commit rung (base-50), reconstructing
   the region + crossfade from journaled provenance (finalize needs only the
   draft take id), then swaps the clip draft->full as one undoable transaction.
   The two assets are same-length substitutions of the original, so the swap is
   sample-aligned.
5. EXTEND (3.3). Generate variant tails past a clip's end; commit places the
   chosen tail butt-joined at the seam, crossfades the seam, and adds a section,
   as one undo transaction.
6. ADD A LAYER (3.3b, lego). Generate an instrument that fits a context region;
   the new track is prepared up front (take lanes materialize on it), and commit
   places the chosen take's clip on it.

## 2. Stem-scope splice + the null test (the P0-A rule, measured)

P0-A (docs/evidence/p0a-repaint.md) proved raw repaint does NOT preserve audio
outside the region (median residual about -21 dBFS, never silence), so the DAW
must never present raw repaint outside the region. Commit splices the region
into the ORIGINAL waveform; unscoped stems are never touched (null-preserved).

Measured, headless (`stem_scope_revise_commits_null_preserves_and_undoes`), a
4-stem session, region = bar 2 (96000 frames), scope = drums + other, 3 variants
(6 candidate takes), 20 ms equal-power crossfade:

| measure | value | meaning |
|---|---|---|
| outside-region residual (spliced drums vs original), peak | **-200.0 dBFS** | bit-exact silence; the outside is the original by construction |
| unscoped stems (vocals, bass) clip asset | **unchanged** | null-preserved, byte-identical |
| in-region change, peak | -21.9 dBFS | the revise actually changed the region |
| commit undo unit | **one step** | `txn.begin` .. 2x `take.promote` .. `txn.commit` |
| after undo, drums + other clip asset | **== original** | exact un-splice (TakeRecord.prior_asset) |

The null test proper: for every sample outside `[regionStart, regionEnd)` the
spliced asset equals the original asset (a per-sample `assert_eq!`), and the
residual of the outside window floors at -200 dBFS.

## 3. Declick at the commit boundary

The splice is a 20 ms (960-frame) equal-power ramp inside the region at both
seams, well over the 5 ms declick floor (01-DESIGN section 8). Measured on the
committed spliced asset, comparing each seam step to a clean baseline window away
from the region:

| point | max adjacent-sample step |
|---|---|
| declick baseline (clean window) | 0.000681 |
| region-start seam | 0.000681 |
| region-end seam | 0.000681 |

The seam sits exactly at the material's own local slope (a hard cut of the two
distinct stem tones would step by roughly 0.08). Unit tests
(`revise::splice::tests`) also prove the equal-power law `g_a^2 + g_b^2 == 1`
across the ramp, that a hard cut steps ~0.2 while the declicked seam stays under
0.01, and that the outside region is bit-exact.

## 4. The draft/commit two-phase (finalize)

Measured (`all_stems_revise_then_finalize_two_phase_swaps_and_undoes`), a single
full-mix clip, all-stems revise at the draft rung, commit variant 0, then
finalize at full:

- after finalize the clip's asset differs from both the draft asset and the
  original (a real full-rung re-render), stays the SAME length (sample-aligned
  swap), and still null-preserves outside the region (spliced into the ORIGINAL,
  not the draft);
- one undo restores the draft commit; a second undo restores the original.

`engineIdentity` on the draft take records `model: acestep-v15-turbo-mock,
steps: 8`; on the finalize take `model: acestep-v15-base-mock, steps: 50`
(the P0-A draft=turbo-8 / commit=base-50 rungs). Device is `cpu` for the mock;
the "this is a stand-in" honesty lives in the `-mock` model suffix, never in a
false device or a fabricated latency.

## 5. Latency to display honestly (live path, from P0-A)

The engine PROXIES generation; it renders nothing itself. On a Gen Node (3090)
for a 2-minute song, P0-A measured: about 4 s per draft take (turbo-8), about
16 s for the committed re-render (base-50), + about 2 s separation when
scope != all stems. Cost scales with SONG length, not selection length. Mac-MLX
numbers are still owed by a later lane. The UI quotes latency as a function of
song length, per P0-A.

Live wiring: `engine: "live"` on any revise tool asks for the real ACE-Step
route; it forwards to L4's Gen Protocol RPC named by `MAJIKS_GEN_RPC_URL` (the
Python backend / Majiks Gen Node). Absent a node it returns an honest "needs a
Gen Node" error rather than inventing a render. The splice + commit + undo +
finalize orchestration is identical for the live and mock generators (the only
difference is who produces the region PCM).

## 6. Agent parity (MCP + FFI)

Every step is an MCP tool, so Sterling or any agent drives the killer feature
over the same bus a person does (`revise_and_commit_via_mcp_have_full_parity`
runs the flow through `dispatch_tool` and undoes via `studio_undo`). New
workflow tools: `studio_revise`, `studio_audition`, `studio_commit`,
`studio_finalize`, `studio_discard`, `studio_extend`, `studio_commit_extend`,
`studio_layer`, `studio_commit_layer`. The timeline-commit side also stays as
plain catalog command tools (`studio_take_promote`, `studio_take_discard`), so
an agent can drive the commit either way. The MCP handshake test serves all of
them; the parity gate + regenerated `docs/generated/mcp-tools.v1.json` (92
tools) stay green. The app FFI adds user-attributed verbs (`revise`, `commit`,
`finalize`, `extend`, `layer`, ...) that route through the same dispatch.

## 7. Tests

Engine (`cargo test --workspace`, all green):
- `revise::splice::tests` (6): equal-power law, outside bit-exact, pure middle,
  cut-step kill, declick floor + region cap, stem-scope null identity.
- `revise::generator::tests` (5): determinism, seed variance, rung difference,
  silence-gated, no edge click.
- `tests/revise.rs` (5): stem-scope null-preserve + declick + commit-undo
  round-trip; all-stems revise + finalize swap + undo; extend + add-a-layer
  land + undo; MCP parity; save/reopen persistence.

Swift (`MAJIKS_ENGINE=mock swift test`, all green):
- `StudioReviseTests` (7): audition-state key math, the preview engine's whole
  revise/commit/discard/extend/layer flow, and the view model's region->scoped-
  clip target resolution.

Boot test: the revise flow runs end to end against the mock generator and the
commit+undo round-trips (the 5 integration tests are exactly this). The mock
Swift build compiles and its tests pass, so `MAJIKS_ENGINE=mock` exercises the
hands-on flow.

## 8. A note on the panel + take lanes (the screenshot)

`l9-revise-panel.svg` renders the shipped Revise/audition panel layout and the
take lanes on the timeline (dark identity, stem colors, the shimmer only on the
generative Commit control). The panel: a bar-range title, the instruction field,
scope chips (unscoped stems stay calm), a variant stepper, keep-lyrics (shown
only when vocals are in scope), an advanced disclosure (seed + crossfade), then
the audition take list with 1-9 / A key hints and Commit / Discard. This is a
rendering of the SwiftUI layout (the app UI cannot be screenshotted headless in
CI); the layout, tokens, and copy are the shipped ones.

## 9. Deviations and proposals (contracts are law; these are on record)

1. `gen.revise.scope` is a single enum in catalog v1, but 01-DESIGN's scope
   chips are multi-select. A multi-stem selection is journaled as one
   `gen.revise` per scoped stem (each records its own scope), which respects the
   frozen catalog and keeps each take single-asset (clean `take.promote`).
   Proposal: a `scope` array (or `scopes`) in a future catalog rev would let one
   request carry a multi-stem selection.
2. `gen.layer`'s executor requires its target track to already exist, but
   add-a-layer creates a NEW track. So the layer track is created up front (as
   one undo unit) and `gen.layer` targets it accurately (take lanes materialize
   on it during audition); commit places the clip. Undo removes the layer clip;
   a second undo removes the prepared track. Proposal: a compound layer-commit,
   or a `gen.layer` that permits a not-yet-created target, would make it one
   undo step.
3. The commit crossfade is baked into the spliced asset at generate time (with
   the panel's crossfade value) and re-applied identically at finalize, rather
   than being re-spliceable at commit. This matches P0-A (the crossfade is a
   property of the spliced waveform). Exposing a commit-time crossfade edit is a
   small follow-up (re-splice the stored region replacement).
4. `engineIdentity.device` has no `mock` enum value, so the fixture generator
   reports `cpu` and carries its stand-in honesty in the `-mock` model suffix.
5. `take.discard` in catalog v1 only un-promotes a PROMOTED take (no
   `take.restore` for candidates), so DISCARD of an un-committed audition is a
   report that the candidate takes stay in the Takes history (purging is L10's
   Takes browser), not a journal mutation.

## 10. How to reproduce

```bash
cd engine
cargo test --workspace                              # unit + integration, all green
cargo test -p agent-surface --test revise           # the L9 acceptance suite
cargo test -p agent-surface --features mcp --test mcp_handshake   # MCP serves the tools

cd ../src/swift
MAJIKS_ENGINE=mock swift build                      # the mock build the acceptance needs
MAJIKS_ENGINE=mock swift test --filter StudioReviseTests
```

Additive engine exports (for coordinator reconciliation): `StudioHost::ingest_asset`,
`StudioHost::asset_samples`, `StudioHost::gen_request_params`, the `revise`
module (`dispatch_revise`/`dispatch_commit`/`dispatch_finalize`/`dispatch_discard`/
`dispatch_extend`/`dispatch_commit_extend`/`dispatch_layer`/`dispatch_commit_layer`/
`dispatch_audition` + the `splice` and `generator` submodules), and `ToolKind::Revise`.

## 11. Questions

1. Multi-stem `gen.revise.scope`: is the "one `gen.revise` per scoped stem"
   journaling acceptable for v1, or should a catalog rev add a scope array
   before launch? (Proposal 1.)
2. Add-a-layer as two undo steps (clip, then prepared track) vs one: acceptable,
   or worth a compound layer-commit in a catalog rev? (Proposal 2.)
3. Single-letter Revise starters (R/E) can be intercepted by the instruction
   text field while it is focused (a SwiftUI limitation); the audition keys
   (1-9, A, Return) exist only while auditioning, so they are conflict-free. Is
   the R/E caveat acceptable, or should R/E move to a modifier (e.g. Cmd+R)?
