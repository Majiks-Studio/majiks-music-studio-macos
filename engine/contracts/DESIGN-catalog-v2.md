# E0 — Catalog v2, ParamRef automation, routing DAG

**Status:** design, locked for implementation · **Epic:** P-00122 E0 (`ed409ac8`)
**Blocks:** E1 notes/piano-roll · E2 instruments · E3 MIDI I/O · E5 routing · E7 warp markers · E8 racks

E0 exists so that E1–E8 add *commands*, never *contract surgery*. Every decision below is
judged by one question: **will this still be right when instruments, plugins and racks
need to automate parameters that do not exist yet?**

---

## 0. Ground truth (verified in-tree, not assumed)

| Fact | Where | Consequence |
|---|---|---|
| Catalog is data-driven JSON compiled in | `catalog.rs:13` `include_str!("../../contracts/command-catalog.v1.1.json")` | Adding a command = JSON entry + `apply.rs` arm. No parser work. |
| `CommandSpec` carries `journaled / undoable / inverse_mode / params_schema` | `catalog.rs:22-33` | Invertibility is declared in data; new commands must declare it too. |
| Automation target is a **JSON-Schema string enum** `["track.volume","track.pan"]` | catalog `autopoint.*`, `autolane.*` | **Widening an enum to a pattern that still admits both values keeps every existing journal entry valid.** This is the key that makes v2 non-breaking. |
| `AutoTarget` serializes as those same strings | `model.rs:271-286` | Wire form is already string-based → a path grammar is a superset, not a replacement. |
| `Automation` is a fixed struct `{ volume, pan }` | `model.rs:288-292` | This is the only part that genuinely cannot scale. |
| `AutoPoint.value` is `Num`, and `AutoPoint` has `extra: Map` | `model.rs:261-268` | Extension point already exists; values are already canonical. |
| `Num` wraps `serde_json::Number`, preserves the exact token; `2 != 2.0` on purpose | `num.rs:14-44` | **Parameter values must be `Num`, never `f64`** — the float view is explicitly "never used for journaling". |
| Sends are `{"bus": {"enum": ["a","b"]}}` | catalog `mix.send` | Exactly two fixed destinations. This is the routing ceiling E5 must break. |
| `catalogVersion` is the JSON **number** `1.1`, read by no Rust code; duplicated as a literal | catalog root; `registry.rs:645` | Inert and numerically lossy (`1.10 == 1.1`). Must become a string and actually be enforced. |

---

## 1. Invariants (violating any of these is a defect, not a tradeoff)

1. **Additive only.** No v1.1 command is renamed, renumbered, removed, or has a field
   repurposed. Journaled commands *are* journal event types.
2. **Old projects replay identically.** Byte-for-byte, including the blake3 chain.
3. **Golden conformance hash unchanged** for v1.1 content.
4. **RT-safety**: no alloc, no lock, no I/O on the audio thread.
5. **`timeline-core` stays wasm32-compilable.**
6. **Values on the wire are `Num`.** Any new parameter that reaches the journal is `Num`.

---

## 2. Catalog v2 mechanism

**Decision: one file, `command-catalog.v2.json`, that is a strict superset of v1.1.**

Rejected alternative — a v2 *delta* file layered over v1.1 at runtime: it makes the
effective contract a computed artifact, so "what is law" stops being greppable, and the
parity/codegen tests would validate the delta rather than the truth.

- `catalogVersion` becomes the **string** `"2.0"` (a string so `2.10` ≠ `2.1`), and
  `registry.rs:645` must read it from the catalog instead of hardcoding a literal.
- **Superset test (the load-bearing safety net):** a test loads `command-catalog.v1.1.json`
  (kept in-tree, frozen, never edited again) and asserts that for every v1.1 command, the
  v2 entry is *semantically identical* — same `name`, `journaled`, `undoable`, `inverseRule`,
  and a `paramsSchema` that still accepts every value the v1.1 schema accepted.
  Schema widening is allowed **only** where §3 says so, and each widening site is listed
  explicitly in the test so an accidental widening fails.
- **Compat direction is asymmetric and must be stated in the error text:** a v2 binary opens
  v1.1 projects (superset). A v1 binary opening a v2 project that uses new commands fails —
  it must fail *loudly and specifically* ("this project uses catalog v2 features: <names>"),
  never silently skip an unknown command, which would corrupt the journal chain.

---

## 3. `ParamRef` — the irreversible decision

Automation must address parameters that do not exist yet (instrument params, plugin params,
rack macros) without another wire-format change.

### Grammar

A `ParamRef` is a dotted ASCII path, serialized as a **string** — the same shape
`AutoTarget` already uses.

```
track.volume                      # LEGACY - byte-identical to v1.1
track.pan                         # LEGACY - byte-identical to v1.1
track.eq.<band>.<gain|freq|q>     # band 0-3 today, unbounded by the grammar
track.send.<sendId>.level
track.device.<deviceId>.<paramKey>   # E2 instruments, E4 plugins, E8 racks
master.gain
master.limiter.<ceiling|release>
bus.<busId>.gain
```

- **Segment charset** `[A-Za-z0-9_-]+`, segments joined by `.`. Ids are opaque strings
  (ULID-shaped in practice) and MUST NOT contain `.`.
- Parsing is **total and lossless**: an unrecognized-but-well-formed path is preserved
  verbatim rather than dropped, so a v2 file round-trips through a newer binary that adds
  parameters without the older one destroying them. (Dropping unknown lanes on save would
  be silent data loss — the failure mode this whole design exists to prevent.)
- The two legacy strings are **reserved and must render byte-identically**. Never emit
  `track.0.volume` or any "more consistent" variant: that would change the wire form of
  every existing automation event.

### Schema change (the one deliberate widening)

In `autopoint.add/move/remove`, `autolane.show/clear`, `target` changes from:

```json
{"type":"string","enum":["track.volume","track.pan"]}
```

to:

```json
{"type":"string","pattern":"^[A-Za-z0-9_-]+(\\.[A-Za-z0-9_-]+)*$","minLength":1}
```

Every previously-valid value still validates. This is the only place an enum is widened,
and the superset test pins it.

> **Open risk, flagged not hidden:** a `pattern` is weaker validation than an `enum` — a
> typo'd target that used to be rejected at the contract boundary now reaches `apply.rs`.
> Mitigation: `apply.rs` resolves a `ParamRef` against the *live* project and returns a
> typed `CommandError` for a path that names no existing parameter, so validation moves
> from schema-time to apply-time rather than disappearing. This must be tested.

---

## 4. Automation storage migration

```rust
pub struct Automation {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub volume: Vec<AutoPoint>,          // v1 legacy field - KEEP
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub pan: Vec<AutoPoint>,             // v1 legacy field - KEEP
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub lanes: BTreeMap<ParamRef, Vec<AutoPoint>>,   // v2, everything else
}
```

- **`BTreeMap`, never `HashMap`** — for `project.json` byte-stability and `Ord`-keyed
  determinism.
  > **CORRECTION.** An earlier draft justified this by blaming map ordering for the
  > "chain broken at entry 15" incident. **That attribution was wrong.** The chain cannot be
  > destabilised by map order: `write_canonical` sorts keys explicitly at every level
  > (`envelope.rs:301-313`) and `serde_json::Map` is already a `BTreeMap` (`preserve_order`
  > is off — verified absent from `Cargo.lock`). The real root cause was a **1-ULP float
  > parse asymmetry** — serde_json's default parser was not the exact inverse of its
  > shortest-round-trip serializer — fixed by the `float_roundtrip` feature
  > (`Cargo.toml:13-24`, regression tests `tests/journal_float_roundtrip.rs:23-41`).
  > `BTreeMap` remains the right choice; the reasoning was not.
  > *Second-order risk:* if any future dependency enables serde_json's `preserve_order`,
  > feature unification would silently change `project.json` bytes. Add a build-time guard.
- `volume` / `pan` continue to be written to their legacy fields, so a v2 file that only
  automates volume/pan is still readable by a v1 binary. Forward compat for the common case
  falls out for free.
- `lane()` / `lane_mut()` keep their signatures but route: legacy targets → legacy fields,
  everything else → `lanes`. **There must be exactly one storage location per ParamRef** —
  a lane that could live in both fields and map would desync. Enforce with a debug assert
  and a test.
- `sort_lane` ordering `(position_ticks, id)` is retained unchanged for every lane.

---

## 5. Routing DAG

*Finalized against the render-subsystem survey; see §5.1 for the constraints it must honor.*

Replace the fixed `track → {bus a, bus b} → master` path with an explicit graph:

- **Nodes**: track strips, buses/groups, master, (later) device chains.
- **Edges**: a send with a level (`Num`) and a pre/post-fader tap.
- Topology is **project data** (journaled, undoable) — not code.
- **Cycle rejection at command time**, not render time: `route.connect` fails with a typed
  error if it would create a cycle. The audio thread must never discover a cycle.
- **Evaluation order is precomputed** on the control thread (topological sort) and handed to
  the audio thread as an immutable ordered plan via the existing lock-free parameter path —
  the audio thread walks a flat, preallocated schedule and never sorts, allocates, or locks.
- **Bounce/live parity is preserved by construction**: both must consume the same schedule
  through the same `RenderCore::render` entry point. Any DAG work that forks that path
  breaks the bit-identical guarantee and is wrong.
- **Sidechain** is an edge whose source must be scheduled earlier; if the graph cannot
  satisfy that without a cycle, it is rejected at command time.
- Graph *model* lives in `timeline-core` (wasm32-safe, journaled); graph *evaluation* lives
  in `render`.

### 5.1 Constraints from the render survey (verified, file:line)

**The seam already exists — follow it, do not invent one.** `compile_session_full`
(`render/src/compile.rs:89-201`) already flattens a `timeline-core::Project` into an
immutable RT-safe `RtSession`. Routing does the same: model + validation + topological sort
in `timeline-core`; `compile.rs` bakes the sorted order into a new `Box<[NodeStep]>` field on
`RtSession`; the audio thread walks that slice **by index only**.

**`render` does NOT compile to wasm32 and is not meant to** (`render/Cargo.toml` pulls cpal,
libc, coreaudio-sys; spawns threads; calls `Instant::now`). Only `timeline-core` and `media`
are gated (`run-tests.sh:15-16`). This *confirms* the split in §5: graph model in
`timeline-core` (leaf crate, no path deps), evaluation in `render`.

**Today's topology is hard-coded in five independent places** — all five must move together:
`TrackParamAtomic::{send_a,send_b}` (`params.rs:50-57`), `track_send_{a,b}_target`
(`rt.rs:166-167`), `Strip::{send_a,send_b}` (`strip.rs:18-19`), `SendBus{A,B}`
(`cmd.rs:467-470`), `Sends{a,b}` (`model.rs:335-338`). Bus A→reverb / B→delay is literal code
(`rt.rs:603-609`), not a parameter.

**The RT primitives to reuse (there are three; none is a triple buffer):**
1. `AtomicF32` (relaxed both ways, `params.rs:26-42`) for scalars, read **once per block** in
   `load_block_targets` (`rt.rs:429-446`).
2. Bounded crossbeam MPMC channel for structural commands (`engine.rs:123`), drained
   non-blocking at block start (`rt.rs:377-378`). Heap payloads are built control-side and
   **moved in** (`rt.rs:110-126`) — this is how a new `Box<[NodeStep]>` must arrive.
3. Bounded drop channel + dedicated drop thread (`engine.rs:125-129`, `rt.rs:319-326`) — the
   callback never frees. Any graph payload it replaces must be handed to `defer_drop`.

**Node accumulators**: buses are today two scalar `[f32;2]` accumulators re-zeroed every
frame (`rt.rs:532-534`). A DAG needs a preallocated `Box<[[f32;2]]>` of `n` node
accumulators, zeroed at the same deterministic point. **A group feeding an earlier-indexed
group currently reads exactly `0.0`, not a delayed value** — silence, not a one-sample
error. That is why order must be a property of the snapshot.

**Bounce parity rests on one rule** (`dsp/mod.rs:1-5`, `rt.rs:19-22`): *all* signal state
advances per **frame**; block boundaries only read atomics into targets. There is exactly one
render function (`offline.rs:3-8`). A DAG must (a) advance every node's state exactly once
per frame, (b) never sort/allocate/look up on the audio thread, (c) keep block-boundary work
idempotent w.r.t. block size. Proven by null tests at 128/417/480/512 (`render/tests/graph.rs:593-660`).

**Sidechain**: no inter-track tap exists at all (zero hits for `sidechain`), and there is
**no latency-compensation machinery anywhere** — no per-node latency field, no PDC. The
limiter's 96-frame lookahead (`limiter.rs:28`) is declicked around but never compensated, so
master latency silently shifts 2 ms when the limiter toggles. A compensation-delay node can
be modeled on `DelayBus`'s fixed-ring/integer-tap pattern (`delay.rs:71-110`), but the
*accounting* (per-node latency, longest-path) must be written from scratch, control-side.

### 5.2 CORRECTION — automation has a second, separate scaling problem

My §3/§4 generalize the **model and wire** form. The survey shows the **render** side has the
identical problem one level down, and E0 must fix both or E2 will hit a wall:

- Automation does **not** flow through atomics. It is baked control-side into the snapshot as
  named struct fields `RtTrack::{vol_lane, pan_lane}` (`compile.rs:192-196`), evaluated
  per-sample by `AutoLane::value_at` (`automation.rs:78-124`).
- `AutomationStore` is keyed by `(track_id, AutoTarget)` with only `{Volume, Pan}`
  (`automation.rs:134-158`).

So today **a new automatable parameter needs four coordinated changes**: a new `AutoTarget`
variant, a new lane *field* on `RtTrack`, a new atomic, and a catalog change. E0 must replace
`RtTrack`'s named lanes with an **indexed, preallocated lane table** resolved at compile time
(ParamRef → dense lane index), so E2/E4/E8 add parameters without touching the RT struct.
Volume and pan keep dedicated fast paths if measurement justifies it, but must not remain the
*only* representable lanes.

> **Ramp correction:** an earlier draft of this doc referred to a ~20 ms declick ramp. That is
> wrong. The engine ramp is **5 ms / 240 frames** (`MICRO_FADE_FRAMES`, `rt.rs:53-55`) via
> `Slew` (`dsp/slew.rs:5-43`), which arrives *exactly* on target so settled values multiply
> bit-exactly. The 20 ms figure is the **offline** splice crossfade
> (`agent-surface/src/revise/splice.rs:29`) and never touches the audio thread.

### 5.3 Pre-existing defects found during the survey (NOT E0's to fix silently)

- **Solo is not implemented in the engine.** `Track.solo` exists in the model
  (`model.rs:363`) but `EngineParams` has no solo field (`params.rs:84-97`) and `sync_params`
  never pushes it (`agent-surface/src/host.rs:1490-1515`). The mixer S button toggles UI and
  model state and **changes nothing audible**. Filed separately; E5 should absorb it since
  solo is a routing concern.
- **Mute kills the send.** Gain (zeroed by mute, `params.rs:204-208`) is applied at
  `rt.rs:574` *before* the send tap at `rt.rs:584`, so there is no pre-fader send. E5 must
  decide this deliberately rather than inherit it.
- `docs/evidence/l2-render-graph.md`, cited by `render/README.md:38` for the 30-minute probe
  figures, **does not exist**. The published p95/underrun numbers are unverified against an
  artifact.
- `underruns` counts *source-read faults*, not device dropouts (`stats.rs:18-20`) — the
  "0 underruns" claim is a correctness claim, not a dropout claim. p95 is 100 µs-bucket
  resolution, so "0.1 ms" means "≤ first bucket edge".

---

## 6. Deferred contract proposals — decisions

| Proposal | Decision | Reasoning |
|---|---|---|
| Float canonicalization rule | **Accept — formalize existing behavior** | `Num` already preserves the exact token and documents `2 != 2.0`. Write it down as law and add the negative tests (NaN, ±inf, `-0.0`, exponent forms) rather than inventing new behavior. |
| First-class `channelEq` | **Accept** | ParamRef needs to address EQ bands (`track.eq.<band>.gain`); leaving EQ implicit forces a special case in the exact place that must be general. |
| Crossfade length-0 | **Accept** | Degenerate-case hygiene; cheap, and removes an apply-time ambiguity. |
| `split`/`take` inverse shapes | **Accept** | Invertibility is declared data (`inverse_mode`); an inexact inverse is an undo bug waiting to happen. |
| Track height 90-vs-64 | **Accept the contract value (90)** | Precedent already set: contract wins, doc gets fixed. Cosmetic. |
| Project phase anchor (L8) | **Accept** | Bar-aligned lead-in is needed by E7 warp markers; folding it in now avoids a second break. |
| Scope array (L9) | **Accept** | Revise scoping generalizes with ParamRef; same shape of problem. |
| `take.purge` (L10) | **Accept** | Already implemented host-side; the contract should reflect reality. |

All eight are additive. None alters a v1.1 command's accepted inputs.

---

## 7. Verification plan (raw exit codes only — never a printed summary)

1. `cargo test --workspace` — all 296 pre-existing tests green.
2. **Superset test**: every v1.1 command semantically identical in v2; widening only at the
   listed sites.
3. **Replay regression**: a v1.1 project fixture (with volume *and* pan automation) opens,
   replays, and produces an **unchanged blake3 chain** and unchanged golden hash.
4. **Round-trip**: a v2 project with an unknown-but-well-formed ParamRef survives
   load→save byte-identically (no silent lane loss).
5. **Determinism**: serializing the same `Automation` twice, with lanes inserted in
   different orders, yields identical bytes (proves `BTreeMap` ordering).
6. **Canonicalization negatives**: NaN / ±inf / `-0.0` / `1e3`-vs-`1000` behave as specified.
7. Catalog↔MCP parity green; regenerate `engine/docs/generated/mcp-tools.v1.json`.
8. wasm32 builds for `timeline-core` + `media`.
9. Swift mock build EXIT=0.
10. RT probe: 0 underruns, 0 alloc violations with a multi-node graph.

## 8. What E1–E8 inherit

- **E1** adds note commands; notes are timeline content, automation of note-level params is
  already addressable.
- **E2/E4/E8** automate device parameters via `track.device.<id>.<param>` — **no contract change**.
- **E5** implements sends/groups/sidechain on the DAG — no new wire format.
- **E7** uses the phase anchor for warp markers.

If any of E1–E8 requires a *contract* change rather than new commands, E0 failed and the
gap must be reported rather than worked around.

---

## 9. Journal invariants (verified — these override anything above that conflicts)

### 9.1 The hash is command-set-agnostic — adding commands is provably safe

The hash input is per-entry only: `blake3(prev_hash_hex ++ canonical(payload))`
(`envelope.rs:260-269`), where the payload is a **hand-built, fixed 7-key map**:

```rust
// envelope.rs:32-33  — PERMANENT
pub const ENVELOPE_HASHED_FIELDS: [&str; 7] =
    ["id", "ts", "actor", "name", "params", "inverse", "result"];
```

Nothing about the *set* of known commands is committed to. On reopen, `params` and
`inverse.params` are preserved **verbatim** as raw `Value` (`envelope.rs:226-229`) and never
round-tripped through the typed `Cmd`, so changing `Cmd`'s serde shape cannot alter a
historical payload. **Therefore adding commands, adding `Cmd` variants, and widening a
`paramsSchema` cannot change any pre-existing hash.**

> **THE way to break every existing project:** modify `hashed_payload()` — e.g. add an 8th
> hashed field. Every historical entry would re-hash and every project would fail with
> "chain broken at entry N". **The 7-field envelope is permanent.** Envelope-level metadata
> is not available to v2; put it in `params` of *new* commands.

### 9.2 HARD RULE — new semantics go in NEW command names, never new optional params on v1 commands

This is the most dangerous finding in the survey and it constrains every later epic.

- Live submit validates against the catalog schema (`additionalProperties: false`) → unknown
  param rejected (`session.rs:208`).
- **Replay does NOT validate params** (`session.rs:566-618` calls `spec()` + `Cmd::from_wire`
  only), and no type in the workspace uses `deny_unknown_fields`. Serde therefore **silently
  ignores** an unknown field.

So if v2 adds an optional field to an existing v1 command, an older binary opens the project,
**verifies the chain successfully**, and quietly builds a **wrong model** — with no integrity
signal. That is strictly worse than a hard failure. An unknown command *name*, by contrast,
fails the whole `Package::open` (`session.rs:573-575`, `package.rs:182-189`) — loud and safe.

### 9.3 Corrections to §1 and §2 of this document

- **Invariant 3 (golden hash) is nearly vacuous as a v2 safety property.** The golden
  (`minimal-project.json:109-112`, tip `8cf75844…`) covers only the 30 fixture journal
  entries. It is *structurally immune* to catalog growth. Keep it green, but do not treat it
  as evidence that v2 is non-breaking — invariant 2 (replay of real projects) is the real test.
- §2's "never silently skip an unknown command" is **already true today** — it hard-fails the
  open. The actual gap is only the error *text*: today it is `"unknown command: <name>"` with
  no version hint, and a v2 project with a new ParamRef target fails as a serde
  `SchemaViolation` (`session.rs:576-578`) rather than a version message. Fix the messages.
- **`Automation` has no `extra` map**, unlike `Clip`/`Track`/`AutoPoint`/`Project`, and
  `package.rs:863-872` reads only `volume`/`pan`. So an older binary would *destroy* unknown
  lanes on save, not merely ignore them. In practice a v2 project is v1-unopenable anyway
  (§9.2), which is the safe outcome — but §4's "keep the legacy fields" buys v1
  *readability*, not v1 *safety*. Do not oversell it.

### 9.4 Float canonicalization is DIVERGENT across languages today (pre-existing defect)

§6 accepted "formalize existing behavior" — but there is no single existing behavior:

- `timeline-core`'s canonicalizer **emits** floats (`envelope.rs:9-17`, `284-289`).
- The Rust contracts crate and the Python module both **hard-reject** floats
  (`contracts/conformance/src/lib.rs:53-60`, `conformance_py/canonical.py:29-40`), per
  `contracts/README.md:147-168` rule 4 ("integers only").

**A real project with a fractional gain therefore produces a journal that the contract
conformance suite cannot hash at all**, and the cross-language byte-parity test
(`timeline-core/tests/conformance.rs:61-86`) has **zero float coverage**. Formalizing means
changing two rejecting implementations and adding float fixtures. This is a latent
cross-language integrity gap, not a doc tidy-up.

Add `-0.0` to the negative tests for a second, subtler reason: `Num`'s `PartialEq` compares
`as_f64()` (`num.rs:47`), and IEEE says `-0.0 == 0.0` — so `Num(-0.0)` and `Num(0.0)` are
**equal in the model but hash differently**. Any "omit when equal to default" path
(`package.rs:420-432`) will drop a `-0.0` as if it were `0.0`. *(Derived, not test-covered —
verify before writing it into law.)*

### 9.5 Gates a new command must satisfy (all four, or CI fails)

1. Catalog entry with `journaled`/`undoable`/`inverseRule` consistent — enforced by
   `tests/conformance.rs:219-246`.
2. An `apply.rs` arm returning **`hint: Some(cmd)`** — mandatory for any `undoable` command
   (`session.rs:319-323` hard-errors otherwise). The hint **is hashed**. Inverse params must
   be `Num`, never `f32/f64`. Exactness is proptest-enforced (`tests/properties.rs:82-108`).
3. An entry in `tests/support.rs::representative_commands()` — must contain exactly the
   catalog's command set (`tests/conformance.rs:35-42`).
4. Bump the **hardcoded counts**: `catalog.rs:133`, `tests/conformance.rs:32`/`:35`,
   `agent-surface/tests/parity.rs:52-66` (87 commands / 86 tools), and regenerate
   `docs/generated/mcp-tools.v1.json` (byte-compared at `parity.rs:71-79`).

### 9.6 Also found: v1.1 is not schema-validated by anything

The conformance suites validate **`command-catalog.v1.json`** while the engine embeds
**`v1.1.json`** (`contracts/conformance/tests/conformance.rs:105`;
`conformance_py/test_conformance.py:42`). The file that is actually law is therefore unchecked
against `command-catalog.schema.json`. When adding v2, point the conformance suite at the
embedded catalog deliberately — and fix this gap rather than inheriting it.

### 9.8 CORRECTIONS FROM IMPLEMENTATION (these override the sections above)

Implementation disproved three claims in this document. Recorded rather than quietly patched,
because two of them came from a survey and were repeated downstream.

1. **§9.4's `-0.0` hazard does NOT occur at the site named.** The claim rested on
   "`Num`'s `PartialEq` compares `as_f64()` (`num.rs:47`)". Line 47 is only the
   **both-float branch**; `Num`'s equality is *shape-aware* across the full match
   (`num.rs:39-49`), so a cross-shape comparison returns false. `package.rs` compares against
   **integer-shaped** defaults, therefore a `-0.0` gain is **not** dropped by the
   omit-when-default path. The hazard is real only between two *float-shaped* values. Both
   directions are now covered by tests. §9.7 correctly flagged this as derived-not-tested —
   the flag did its job.

2. **§0's "`Num` … preserves the exact token" overstates it for floats.** The canonicalizer
   emits **shortest-round-trip**, so `1e3` serializes as `1000.0`. What is preserved is the
   integer/float **shape** (`2` vs `2.0`), not the spelling. Round-trip *value* fidelity is
   guaranteed by serde_json's `float_roundtrip`; token *spelling* is not. Written into
   `contracts/README.md` rule 4.

3. **§2 contradicted §6.** §2's superset test demands "same `inverseRule`" while §6 accepts
   the split/take inverse-shape proposal. Resolved by leaving `inverseRule` untouched (v1.1
   law) and adding a sibling **`inverseShape`** annotation enforced against `apply.rs`.
   Semantics: "**may** be a sequence" — `track.remove`/`clip.remove` restore in one command
   when there is no non-default state.

### 9.9 Pre-existing bugs found while implementing (fixed, none silent)

- **`contracts-conformance` never declared serde_json's `float_roundtrip`.** Its parser was
  not the inverse of its serializer, so it recomputed a *different* hash for a 1-ULP float —
  the same defect class as the original "chain broken at entry 15". `cargo test --workspace`
  **masked it via feature unification**; only `cargo test -p contracts-conformance` alone
  exposed it. Lesson: a workspace-wide green can hide a per-crate feature defect.
- **`timeline-core`'s subset validator did not implement `uniqueItems`**, so the array branch
  of v1.1's `gen.revise` `scope` `oneOf` failed to compile and matched zero schemas — **a
  shipped v1.1 feature was being rejected at the live-submit boundary** while the real
  `jsonschema` crate accepted it. Added `uniqueItems`/`maxItems`/`propertyNames`.
- §9.6's catalog-schema violations were fixed **in v2, not v1.1** (the design forbids editing
  the frozen file). v1.1's violations are now **pinned by a test** in both suites so they
  cannot be "fixed" by mutating history.

### 9.10 Explicitly NOT proven by E0 — carry into E5

- **RT probe not run**: no 0-underrun / 0-alloc measurement with a multi-node graph. The DAG
  has no render-side evaluation yet, and the probe needs an audio device. **E5 must run it.**
- **No-alloc on the audio thread rests on code inspection**, not an allocator hook, for the
  new lane table (fixed-size cursor array, control-side `Box`, sort in `compile`). The
  existing `null_and_alloc` guard remains green but does not specifically hammer lanes.
- **No before/after A/B bounce comparison** across the render refactor; reliance is on the
  existing null tests at 128/417/480/512 staying green (they do).
- **The volume/pan fast path was never benchmarked** — §5.2 permitted it "if measurement
  justifies it"; it was kept on inherited grounds.
- Cross-language float parity is **fixture-proven, not exhaustive** (11 adversarial tokens +
  an 8-entry Python-generated chain), not a property test over all f64.

### 9.7 Unverified claims carried from the survey — confirm before relying on them

- `-0.0` model-equality-vs-hash hazard (§9.4): derived from IEEE + serde semantics, no test.
- NaN/±inf unreachable via `Number::from_f64` returning `None`: derived, not exhaustively
  audited across `agent-surface` construction sites.
- Serde silently ignoring an unknown field inside an adjacently-tagged enum's `content`
  (§9.2): standard serde behavior, but it is the hinge of the worst failure mode — **write
  the 10-line test before depending on it.**
