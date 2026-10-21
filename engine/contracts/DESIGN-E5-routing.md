# E5 — Routing and effects: buses, groups, sends, effect devices, sidechain, PDC

*Part I (§0–§14): routing. Part II (§15–§22): effect devices, the keyed dynamics processor,
sidechain, delay compensation, and the honest parity roadmap beyond E5.*

**Status:** seam spec, locked before implementation · **Epic:** P-00122 E5
**Depends on:** E0 (`DESIGN-catalog-v2.md`) — landed · E1/E2 (`DESIGN-E1-E2-notes-instruments.md`) — landed
**Baseline:** `feat/ms-342` @ `bae6def`. `cd engine && ./run-tests.sh; echo EXIT=$?` → **EXIT=0** (verified 2026-07-25).

> ## ⚠️ AMENDED — Part II (§15–§22) is in force
>
> Part I (§0–§14) was written to a routing-only scope and asked one open question: *should
> E5 invent an effect-device contract and a dynamics processor, or refuse to?* Part I refused,
> and said the answer was a product call.
>
> **Aaron made the call: "we need to be on parity if not exceeding, of competitors, so we
> need full DAW capabilities."** Effect devices are IN. So is the keyed dynamics processor
> that makes §5's sidechain legality rules mean something.
>
> **Part II (§15–§22) EXTENDS Part I; it does not replace it.** Every decision in Part I
> survives verbatim except where a section carries an explicit
> **⚠️ AMENDED BY §n** marker. Where a marker appears, §n wins. There are exactly **five**
> amended sections — §2.1 (counts), §4.3 (what a node is), §5 (sidechain), §9 (PDC), §13
> (out of scope) — and §15.1 tabulates every Part I decision with its status so nothing is
> quietly changed. **Read §15.1 before reading anything else in Part II.**

This document exists for ONE reason: **four lanes run in parallel, and they must agree on the
seams before they write code.** Everything below is a decision with a reason, not a suggestion.

> **If a lane believes a decision here is wrong, it REPORTS AND STOPS on that point.**
> It does not substitute its own. A lane that silently picks a different seam is the merge
> conflict this document exists to prevent, and worse, it is a *semantic* conflict that
> compiles. The two prior documents in this series (`DESIGN-catalog-v2.md` for E0,
> `DESIGN-E1-E2-notes-instruments.md` for E1/E2) produced merges with **zero conflicts across
> five lanes** precisely because nobody improvised a seam.

---

## 0. Ground truth — verified in this tree, at this commit, by probe

Every row was confirmed by reading the code at the cited `file:line` **and**, where marked ⚑,
by a throwaway probe test that rendered actual buffers. Line numbers cited in the E0 document
are stale; these are current.

| # | Fact | Where | Status |
|---|---|---|---|
| 1 | **The full routing command set already exists.** `route.node.add`, `route.node.remove`, `route.connect`, `route.disconnect`, `route.edge.set` — journaled, undoable, with truthful inverses (`route.node.remove` correctly declares `inverseShape: "multi"`). | `command-catalog.v2.json`; `cmd.rs:618-640`; `apply.rs:2706-2845` | ✅ landed |
| 2 | **The model, validation and topo sort exist and are correct.** `NodeKind`, `Tap`, `RouteNode`, `RouteEdge`, `NodeRef`, `Routing`, `ScheduleStep`, `find_cycle`, `validate_new_edge`, `schedule` (Kahn, deterministic tie-break on enumeration order). | `timeline-core/src/routing.rs` | ✅ landed |
| 3 | **`compile.rs` already bakes the schedule onto the snapshot.** `RtSession::node_order: Box<[NodeStep]>`, `NodeStepKind::{Track(usize), Node(usize), Master}`. | `compile.rs:252-282`; `rt.rs:223-250` | ✅ landed |
| 4 | ⚑ **`node_order` is READ BY NOTHING.** Probe: a project with a group node and two edges renders **bit-identical** to the same project with an empty `Routing`. `grep node_order render/src/rt.rs` → the field declaration only. | probe; `rt.rs:1042-1166` | ❗ E5's core work |
| 5 | ⚑ **There is no pre-fader send.** Gain is applied at `rt.rs:1135` (`x = clip_sum * g * gl`), EQ at `:1136`, send taps at `:1138` / `:1143` read `x`. Probe: send=1.0 + mute → output **bit-identical** to send=0.0 + mute. | ⚑ probe; `rt.rs:1129-1147` | ❗ E5 decides (§3) |
| 6 | ⚑ **Solo also kills a non-soloed track's send** — same `g`. Probe: soloing t2 with t1's reverb send at 1.0 is bit-identical to soloing t2 with no send at all. Not recorded anywhere before now. | ⚑ probe | ❗ new finding |
| 7 | ⚑ **`track.send.<id>.level` automation is SILENTLY INERT.** The lane compiles into slot 2 of the dense lane table (`lane_index = {track.pan:1, track.send.a.level:2, track.volume:0}`) and **nothing reads it**: `rt.rs` reads `LANE_VOLUME` and `LANE_PAN` only (`:1123`); everything else comes from atomics. Probe: a 0→1 send ramp renders bit-identical to no automation. | ⚑ probe; `rt.rs:1120-1132` | ❗❗ **same bug class as the old solo bug** |
| 8 | **Solo IS implemented and audible.** `EngineParams::{set_track_solo, any_solo, clear_track_solos_from, track_gain_target}` (`params.rs:53-57,144-160,223-259`), resolved once per block (`rt.rs:918-941`), pushed from both hosts (`render/src/host.rs:145`, `agent-surface/src/host.rs:1949`), proven on rendered buffers by `render/tests/solo.rs` (10 tests) and `agent-surface/tests/solo_audible.rs` (3 tests). | verified + green | ✅ **E0 §5.3 is STALE — see §7** |
| 9 | ⚑ **`route.node.add {"nodeId":"a"}` is accepted today.** Only `"master"` is reserved (`apply.rs:2720`). So a user-created node can collide with the legacy bus letter. | ⚑ probe | ❗ E5 decides (§2) |
| 10 | ⚑ **Nothing expresses the absence of the implicit master feed.** Every strip sums into `master` unconditionally (`rt.rs:1149-1150`). Connecting `track.t1 → bus.grp` adds a path; it does not remove the direct one. | ⚑ probe | ❗ E5 decides (§4) |
| 11 | ⚑ **Send ids beyond `a`/`b` are rejected at apply time** with the literal message *"v1 has exactly two sends, 'a' and 'b' (E5 generalizes this)"*. | ⚑ probe; `apply.rs:251-257` | ❗ E5 decides (§2) |
| 12 | **`ParamRef::BusGain { bus_id }` already resolves against the live routing graph** (`apply.rs:265-270`) — the node fader is already contract-addressable and automatable. | verified | ✅ use it |
| 13 | **There is no dynamics processor anywhere.** `render/src/dsp/` = biquad, delay, drum, env, instrument, limiter, note, osc, pan, reverb, sampler, slew, svf, synth, truepeak. No compressor, no gate. `grep -ri sidechain` over the whole tree hits only comments. | verified | ❗❗ reshapes §5 |
| 14 | **A `RouteNode` has no processor.** `{id, kind, name, extra}`. `DeviceKind` is instrument-only (`Synth`/`Sampler`/`Drum`, `model.rs`). Bus A→Freeverb / bus B→tempo-delay is literal code (`rt.rs:1157-1166`). | verified | ❗❗ reshapes §9 |
| 15 | **There is still no PDC anywhere.** No per-node latency field, no longest-path accounting. The limiter's 96-frame lookahead (`limiter.rs:28`) is declicked around but never compensated. | verified | ❗ E5 decides (§6) |
| 16 | **`parse_routing` silently skips malformed nodes/edges** (`package.rs:794-845`, bare `continue`) and performs **no cycle check on load**. `compile_session_full` errors on a cyclic graph, and `push_live_session` **swallows compile errors** (`agent-surface/src/host.rs:743-750`). | verified | ❗ silent-degradation hole (§10) |
| 17 | **Every mutation recompiles the whole session.** `sync_after_mutation` → `push_live_session` → `compile_session_full` (`agent-surface/src/host.rs:465-491,743-750`). | verified | drives §6's atomics decision |
| 18 | `docs/evidence/l2-render-graph.md`, cited by `render/README.md:38`, **still does not exist**. The published p95/underrun figures remain unbacked by an artifact. | verified | E0 §5.3 still true |
| 19 | Catalog is **105 commands / 128 MCP tools**. Six hardcoded counts: `catalog.rs:207`, `timeline-core/tests/conformance.rs:32` and `:35`, `agent-surface/tests/parity.rs:54` and `:66`, `contracts/conformance/tests/conformance.rs:156`, plus `tests/support.rs::representative_commands()` and `agent-surface/src/registry.rs:715`. | verified | §11 |

### 0.1 Corrections to the E0 document (record, do not repeat)

- **E0 §5.3 bullet 1 ("Solo is not implemented in the engine") is STALE.** It was true when
  written; it is false now (row 8). Solo crosses the control→RT boundary, is bounded by the
  live track count, rides the same 5 ms `Slew` as mute, follows the Live convention (mute
  wins), is cleared to solo-safe for stem export (`agent-surface/src/host.rs:2079`), and is
  proven on **rendered buffers** by thirteen tests. **E5 does not "absorb" solo; E5 extends
  it to nodes.** Anyone citing §5.3 for "solo is broken" is citing a stale line.
- **E0 §5.3 bullet 2 ("Mute kills the send") is TRUE and reconfirmed by probe** (row 5) — and
  incomplete: **solo kills it too** (row 6).
- **The line numbers in E0 §5.3 are stale** (`params.rs:204-208` is now `params.rs:246-259`;
  `rt.rs:574/584` is now `rt.rs:1135/1138`). Cite the current ones.
- **"Widen the `mix.send` enum to a pattern" is NOT E5's path, and E5 must not do it.**
  See §2. E0 §2's enum→pattern trick was correct *for `autopoint.target`*; applying it to
  `mix.send` now would create a second, divergent way to express the same fact.

---

## 1. Invariants (violating any is a defect, not a tradeoff)

These are inherited from E0 §1 and re-stated because E5 is the epic most able to break them.

1. **Additive only.** No v1.1 command is renamed, removed, or has a field repurposed.
2. **Old projects replay identically**, byte-for-byte, including the blake3 chain.
3. **RT-safety**: no allocation, no locks, no I/O, no logging on the audio thread. Fixed
   preallocated pools. Deterministic stealing.
4. **`timeline-core` stays wasm32-compilable.** Graph *model* in `timeline-core`; graph
   *evaluation* in `render` (which deliberately does not target wasm32).
5. **Values on the wire are `Num`**, never `f32`/`f64`. The integer/float *shape* is hashed.
6. **ALL signal state advances per FRAME.** Block boundaries only read atomics into targets.
   This is the single rule that makes the offline bounce bit-identical to the live callback at
   128 / 417 / 480 / 512 (`render/tests/graph.rs:667-767`, `:788-906`;
   `render/tests/null_and_alloc.rs:181-221`). **§6 is where E5 can break this. Read §6.1.**
7. **There is exactly one render function** (`RenderCore::render`, `rt.rs:945`). Live, offline
   bounce, stem export and every null test run *that* code. Any routing work that forks it is
   wrong by construction.

---

## 2. Contract surface — DECISION: ROUTING adds no new commands

> ⚠️ **AMENDED BY §16.4.** The claim below — "the six hardcoded counts stay at 105/128" — was
> true for routing alone and is now **false for E5 as a whole**. Effect devices add **7
> commands**: 105 → **112**, 128 → **135** MCP tools. Everything else in §2 stands, including
> the frozen `mix.send`, the render-side-only legacy buses, and the §9.2 quotation, which
> governs the 7 new names too.

**The routing command set already exists and is sufficient (row 1). Routing itself adds zero
catalog entries; `mcp-tools.v1.json` changes only by description text on account of §2.3.**

This is the single most important thing to internalise before writing code. The instinct
("E5 needs arbitrary sends, therefore widen `mix.send`") is wrong three times over:

1. **`route.connect` is strictly more expressive** than a widened `mix.send`: arbitrary
   destination, level range 0..4 (vs 0..1), and an explicit pre/post tap.
2. **Two representations of one fact desync.** A widened `mix.send` would write
   `Track::sends`, while `route.connect` writes `Routing::edges`. Save/load, undo, and the
   diff-cursor would then have to reconcile two sources of truth for "how loud is t1 into the
   reverb". That is a bug factory.
3. **E0 §9.2 HARD RULE**, quoted in full below, exists to stop exactly this class of change.

> ### E0 §9.2 — quoted verbatim, non-negotiable
>
> **New semantics go in NEW command names, never new optional params on v1 commands.**
>
> - Live submit validates against the catalog schema (`additionalProperties: false`) → an
>   unknown param is rejected (`session.rs:208`).
> - **Replay does NOT validate params** (`session.rs:566-618` calls `spec()` +
>   `Cmd::from_wire` only), and **no type in the workspace uses `deny_unknown_fields`**.
>   Serde therefore **silently ignores** an unknown field.
>
> So if a later catalog adds an optional field to an existing v1 command, an older binary
> opens the project, **verifies the chain successfully**, and quietly builds a **wrong
> model** — with no integrity signal. That is strictly worse than a hard failure. An unknown
> command *name*, by contrast, fails the whole `Package::open` — loud and safe.
>
> **Never touch `ENVELOPE_HASHED_FIELDS`** (`envelope.rs:32-33`). The 7-field envelope is
> permanent. Modifying `hashed_payload()` re-hashes every historical entry and breaks every
> existing project.
>
> Everything journaled is `Num`, never `f32`/`f64`. New structs get
> `extra: Map<String, Value>`. Collections need a total deterministic order. Truthful
> inverses: if an inverse is a sequence, `inverseShape: "multi"`; **never** `inverseRule: self`
> for add/remove/duplicate. Any lane that *does* add a command must register it in
> `timeline-core/tests/deferred_proposals.rs` and bump all six hardcoded counts plus
> regenerate `docs/generated/mcp-tools.v1.json`.

### 2.1 DECISION — `mix.send` is FROZEN, and the legacy topology is desugared render-side

- **`mix.send` keeps its `{"bus": {"enum": ["a","b"]}}` schema forever.** Its apply arm keeps
  writing `Track::sends.{a,b}`. Untouched schema + untouched apply arm = every existing
  journal entry replays byte-identically, trivially and provably.
- **The two legacy FX buses are NOT modelled as `RouteNode`s.** They become **render-side-only
  compiled nodes**, `NodeStepKind::LegacyFx(FxSlot::{A,B})`, with **no wire form at all**.

  Rejected alternative — reserving the node ids `"a"` and `"b"` so the legacy buses live in
  the `bus.` namespace: `route.node.add`'s id pattern is `^[A-Za-z0-9_-]+$`, so *every*
  user-creatable id is collidable; reserving two of them **narrows an already-shipped v2
  command**, which means a project that already journaled `route.node.add {"nodeId":"a"}`
  would fail to replay. A render-side-only identity has **zero contract risk and zero replay
  risk**, and the legacy buses were never wire-addressable in the first place.
  Consequence: row 9 stays as it is. `route.node.add {"nodeId":"a"}` remains legal and
  creates an ordinary, *distinct* user bus. That is correct, not a collision.
- **Desugaring is a pure function, applied in `compile.rs`, never written to the model.**
  Writing synthetic nodes into `Routing` would change `project.json` bytes and pollute the
  journal. The model stays empty for a v1 project; the *compiled* graph always contains the
  two `LegacyFx` nodes plus one implicit post-tap edge per track carrying `Track::sends.a/b`.
  **`Routing::is_empty()` therefore continues to mean exactly "the v1 topology".**

### 2.2 DECISION — one new `ParamRef` segment, and it needs no catalog change

`route.edge.<edgeId>.level`

- `ParamRef::parse` is total for any well-formed dotted ASCII path; this one is well-formed
  and today classifies as `ParamRefKind::Unrecognized` (verified). Adding a
  `ParamRefKind::RouteEdgeLevel { edge_id }` variant plus a `require_param_ref_on` arm is a
  **pure Rust addition**.
- The catalog schema for `autopoint.*` / `autolane.*` `target` is already the widened
  `pattern: "^[A-Za-z0-9_-]+(\\.[A-Za-z0-9_-]+)*$"` (verified in `command-catalog.v2.json`).
  **No catalog edit.**
- `track.send.<a|b>.level` stays as the legacy spelling and keeps its apply-time restriction
  to `a`/`b` (row 11). Do **not** relax that message — it is the correct, loud, typed
  rejection, and §2.1 means there is nothing to relax it *to*.
- `bus.<id>.gain` (row 12) is the **node fader** and already resolves. Use it. Do not invent
  `route.node.<id>.gain`.

### 2.3 What E5 IS allowed to edit in the catalog

Only the `description` strings of the five `route.*` commands, to document the implicit-master-
feed rule (§4) and the tap semantics (§3). Descriptions are not part of the superset test
(which pins `name` / `journaled` / `undoable` / `inverseRule` / `paramsSchema`). Editing them
**does** change `docs/generated/mcp-tools.v1.json`, which is byte-compared at
`agent-surface/tests/parity.rs:71-79` — regenerate it:

```
cargo run -p agent-surface --bin majiks-studio-cli -- tools --write engine/docs/generated/mcp-tools.v1.json
```

**Do not touch any `paramsSchema`.** If a lane concludes it must, that is a §0-style
"report and stop".

---

## 3. Pre-fader vs post-fader — DECIDED

Today's tap is post-fader, post-pan **and post-EQ** (row 5). `Tap::{Pre, Post}` already exists
in the model and `route.connect` already *requires* it, so both spellings are already
journalable — E5 is deciding what they **mean in the DSP**, not whether they exist.

### 3.1 DECISION — `Tap::Post` = today's tap point, bit-exactly

`Tap::Post` taps `x` *after* `clip_sum * g * gl/gr` and *after* `strip.eq.process_frame`
(`rt.rs:1135-1136`) — i.e. **post-fader, post-pan, post-EQ**. This is not a preference; it is
the only definition that leaves the existing signal path bit-identical, which is what makes
the legacy-null gate in §12 provable.

### 3.2 DECISION — `Tap::Pre` = post-pan, **PRE-EQ**, pre-fader

`Tap::Pre` taps `[clip_sum[0] * gl, clip_sum[1] * gr]` **before** `strip.eq.process_frame`.

**Why not post-EQ pre-fader (which is what Ableton and Logic mean by "pre-fader"):** three
candidate implementations, all rejected, with the reason:

| Candidate | Rejected because |
|---|---|
| Compute `x` post-fader, EQ it, then divide by `g` to undo the fader | Division by zero the instant the track is muted. Non-starter. |
| Reorder the strip so EQ runs *before* the fader, then tap between them | A biquad commutes with a *constant* gain but **not** with a *ramping* one, and `g` is a `Slew` (`rt.rs:1129`). This changes the legacy signal path and **breaks the null gate**. |
| Give every strip a **second** `EqBank` fed by the pre-fader signal | Correct, but doubles per-strip filter state and cost for all 64 strips, and its filter state diverges depending on whether a pre-tap exists — a session swap that adds a pre-tap would start from cold state. Deferred, not forbidden: if a musician complains, this is the upgrade path, and it is purely additive. |

**The consequence must be stated in the UI, the catalog description, and a test, not buried:**
**a pre-fader send does not carry the channel EQ.** Shipping a `pre` that silently means
"pre-EQ as well" without saying so is exactly the silent-degradation class this program keeps
catching. §12 mandates a test that *pins* the EQ-free property so a later lane cannot
"improve" it into a divergence.

### 3.3 DECISION — mute and solo gate BOTH taps. Mute still kills the send.

- **`Post`**: gated by the fader, therefore by mute and by solo, exactly as today. Unchanged.
- **`Pre`**: **not** gated by the fader, but **gated by mute and by solo.**

Reasons:
1. **Mute is the channel activator**, and `params.rs:239-245` already documents that mute wins
   over solo (the Live convention). A mute that leaves a reverb tail ringing is
   indistinguishable, to a user, from a broken mute.
2. **Solo must mean "nothing else is audible anywhere."** If a pre-fader send bypassed the
   solo gate, soloing a kick would leave every other track's reverb in the mix. That is not
   solo; that is a bug that will be filed as "solo is broken" for the second time.
3. The useful pre-fader case — *pull the fader to zero and the reverb tail continues* — is
   fully delivered by "not gated by the fader". The mute/solo gating costs nothing musically.

**Implementation constraint (load-bearing, do not paraphrase it away):** the pre-tap gate must
ride its **own** 5 ms `Slew`, not be folded into the existing `strip.gain`. Add
`Strip::gate: Slew` targeting `0.0` when `muted || solo_gated` else `1.0`. Do **not** refactor
`gain_target = track_gain_target[idx] * vol_auto; let g = strip.gain.advance(gain_target)` into
a product of two slews — floating-point multiplication is not associative and that refactor
**breaks the legacy-null gate**. Two independent slews; the post path's arithmetic is
untouched, byte for byte.

`EngineParams` gains a companion to `track_gain_target` that returns the gate alone:

```rust
/// The mute/solo gate WITHOUT the fader: 0.0 when muted or solo-gated, else 1.0.
/// Read once per block alongside track_gain_target, using the SAME `any_solo`
/// so a block is internally consistent.
pub fn track_gate_target(&self, track: usize, any_solo: bool) -> f32;
```

---

## 4. Return/aux tracks, groups, and the implicit master feed

### 4.1 DECISION — capacity

| Cap | Value | Enforced |
|---|---|---|
| `MAX_ROUTE_NODES` | **32** | control-side in `compile`, typed error, mirroring `MAX_TRACK_LANES = 32`'s precedent (`compile.rs:557-577`) |
| `MAX_ROUTE_EDGES` | **512** | ditto (64 tracks × 8 sends is the real ceiling) |

Both are `pub const` in `render/src/rt.rs` next to `MAX_TRACK_LANES`, and the compile error
must name the cap and the count, the way the lane-table error already does. **The audio thread
never sees an over-cap session**; failing control-side is the whole point.

Preallocation: `RenderCore` gains
`node_acc: Box<[[f32; 2]]>` of length `MAX_ROUTE_NODES + 2 (LegacyFx) + 1 (Master)`, and
`node_gain: Box<[Slew]>`, `edge_level: Box<[Slew]>` of `MAX_ROUTE_NODES` / `MAX_ROUTE_EDGES`,
**all allocated once in `RenderCore::new` from `CoreConfig`, never per session.**

### 4.2 DECISION — the implicit master feed rule

> **After desugaring, a node N (a track strip, or a bus/group) has an implicit
> `N → master` post-tap edge at unity IF AND ONLY IF the project's routing declares no
> `post`-tap edge with `from == N`. Pre-tap edges are sends and never suppress the implicit
> feed.**

Worked consequences (each of these is a mandated test in §12):

| Graph | Result |
|---|---|
| `Routing` empty | Every track → master. Exactly v1. |
| `track.t1 → bus.grp` (post) | t1 feeds **only** the group. No double-count. |
| `track.t1 → bus.rev` (pre) | t1 feeds master **and** the reverb. A send. |
| `track.t1 → bus.grp` (post) **and** `track.t1 → master` (post, level 0.5) | Both, with a trim on the direct path. Fully expressible. |
| `route.disconnect` of the last post edge from N | The implicit feed comes back. |

Rejected alternative — *"once `Routing` is non-empty, every node must declare its own master
edge"*: adding a single group would require re-declaring 64 master edges, and would make
`Routing::is_empty()` stop being the clean v1 predicate that `package.rs:721` relies on.

This rule is why row 10 is not a gap in the model: **the model already carries enough
information**; E5 only has to define what it means. Document it in `route.connect`'s catalog
description (§2.3).

### 4.3 DECISION — what a node IS in E5: a gain-summing point, not an effect host

> ⚠️ **AMENDED BY §16.** **A node IS now an effect host.** The reasoning below — that an
> effect on a bus needs an effect-device contract surface, which is a full epic's worth of
> design — was correct, and §16 is that design, brought into E5 by Aaron's scope call. What
> survives from this section unchanged: the caps (§4.1), the implicit-master-feed rule (§4.2),
> and the node fader addressed by `bus.<id>.gain`. What is superseded: the paragraph beginning
> "**E5 ships bus/group nodes as summing points … and nothing else**" and the closing "you
> cannot put a reverb on a bus you created". You can now. **Read it for the reasoning, not for
> the conclusion.**

Row 14 is the finding that most changes E5's shape. **A `RouteNode` has no processor, and
there is no effect-device model anywhere in the tree** (`DeviceKind` is instrument-only).

**E5 ships bus/group nodes as summing points with a gain (addressed by the existing
`bus.<id>.gain` ParamRef) and nothing else. Effects on nodes are NOT E5.**

Reason: putting an arbitrary effect on a bus requires an effect-device contract surface —
a `DeviceKind` extension or a new `node.device.*` command family, with its own params,
inverses, and automation. That is a full epic's worth of contract design and it belongs with
E4 (plugins) / E8 (racks). E5 inventing it under time pressure is how a program ends up with
two device models.

**What E5 therefore actually delivers, and it is musically real:**
- **N group/submix buses** with their own fader, so stems and bus mixing work.
- **Arbitrary routing** of any track to any bus, and bus→bus, with cycle rejection.
- **Arbitrary send counts** with per-edge levels and pre/post taps.
- The **two legacy FX buses keep working exactly as today**, now as first-class schedule
  nodes rather than a hardcoded tail.

**What E5 explicitly does NOT deliver, so nobody discovers it at review:** you cannot put a
reverb on a bus you created. There are exactly two reverb/delay destinations, as before. If
that is unacceptable to the product, **that is a scope decision for Aaron, not a thing a lane
quietly builds** — report and stop.

---

## 5. Sidechain — DECIDED: E5 specifies the legality, and does NOT ship the feature

> ⚠️ **AMENDED BY §18.** **E5 now ships sidechain**, because §17 ships the keyed compressor
> and gate that give it a consumer. §5.1's decision is reversed; **§5.2's legality table is
> unchanged and is now load-bearing** — it stops being a specification of what would be legal
> and becomes the specification of what `fx.sidechain.set` accepts and rejects. Everything in
> §5.2 stands verbatim.

The E1/E2 document assigned sidechain to E5. **Row 13 makes that impossible as stated: there
is no dynamics processor anywhere in `render/src/dsp/`.** A sidechain edge would be a control
with no effect — the "green on the wrong axis" failure mode, shipped deliberately.

### 5.1 DECISION

**E5 adds no sidechain concept.** A sidechain, in this graph, is just an ordinary edge into a
node whose processor is *keyed*. When such a processor exists (E4/E8), the routing is already
expressible with `route.connect` — **no contract work will be needed then either.** That is E0
paying off, not E5 punting.

### 5.2 What E5 DOES owe: the legality spec, pinned by tests

`validate_new_edge` already answers the cycle question correctly. E5 must prove it answers it
for the *musical* cases, because "a sidechain is the classic way to introduce a cycle" is true
but is usually asserted about the wrong graph:

| Scenario | Legal? | Why |
|---|---|---|
| Kick → bass-bus (key), kick → master, bass-bus → master | **LEGAL** | Not a cycle. This is the canonical sidechain and it must be accepted. |
| Bus X → bus Y and bus Y → bus X | **REJECTED at command time** | Cycle. `validate_new_edge` returns `CommandError::Routing` naming the path. |
| Track T → group G, G → master, G → T | **REJECTED at command time** | Cycle. |
| Anything with `from == master` | **REJECTED** | Master is the sink (`routing.rs:249-254`). |
| Self-loop | **REJECTED** | `routing.rs:246-248`. |

**The audio thread must never discover a cycle.** It cannot: `schedule()` is called
control-side in `compile.rs:256`, and a cyclic graph fails the compile. §10 closes the one
remaining door (a cyclic graph arriving from disk).

---

## 6. Evaluation order in the RT graph

### 6.1 ⚠️ THE INVARIANT THAT MUST NOT BREAK — read this before writing a line

> **Every node's signal state advances exactly once per FRAME.** Block boundaries do nothing
> but read atomics into plain targets.
>
> **The obvious way to write a graph engine is to render each node's whole block and then mix
> the blocks. THAT IS FORBIDDEN HERE AND IT WILL BREAK THE PRODUCT.** It makes a node's output
> depend on the block size, which destroys bit-identity between the live callback (128) and
> the offline bounce (512) — the guarantee proven at 128 / 417 / 480 / 512 by
> `render/tests/graph.rs:667-767` and `:788-906` and `render/tests/null_and_alloc.rs:181-221`,
> and the reason a bounce sounds like what the user heard.
>
> If any routing feature you are asked to build cannot be expressed per-frame, **stop and
> report it.** Do not "temporarily" render per block.

Corollary from the E0 survey, still true: a group feeding an earlier-indexed group currently
reads exactly `0.0`, not a delayed value — **silence, not a one-sample error**. That is why
evaluation order must be a property of the compiled snapshot and not of array index order.

### 6.2 DECISION — the baked structures

`ScheduleStep` / `NodeStep` carry a node identity and nothing else, so the audio thread would
have to *search* for a node's outgoing edges. It must not. Extend the snapshot:

```rust
// render/src/rt.rs — RtSession
pub node_order: Box<[NodeStep]>,   // EXISTS (compile.rs:252-282); gains the fields below
pub edges:      Box<[RtEdge]>,     // NEW: flat, sorted by source in SCHEDULE order
pub edge_index: BTreeMap<String, usize>,  // NEW: edgeId -> slot. CONTROL-SIDE ONLY.

pub struct NodeStep {
    pub kind: NodeStepKind,
    /// Half-open range into `RtSession::edges`. The audio thread slices by
    /// index and never searches.
    pub out_edges: (u32, u32),
}

pub enum NodeStepKind {
    Track(usize),          // index into RtSession::tracks
    Node(usize),           // index into the routing node list -> node_acc slot
    LegacyFx(FxSlot),      // NEW, render-side only: A = Freeverb, B = tempo delay
    Master,
}

#[derive(Clone, Copy)]
pub struct RtEdge {
    pub dest: u16,   // node_acc slot
    pub tap: Tap,
    pub level_slot: u16,  // index into EngineParams' edge-level atomics
}
```

`RtEdge` is `Copy` and allocation-free. `edge_index` is on the snapshot for the host's benefit
(same role as the existing `lane_index`, `rt.rs:225-229`) and is **never touched by the audio
thread**.

### 6.3 DECISION — edge level and node gain are ATOMICS, not snapshot constants

`RouteEdge::level` is `Num` on the model. If the RT read the level from the snapshot, every
send-fader movement would go through `sync_after_mutation` → `push_live_session` →
`compile_session_full` (row 17) — a full rebuild of every clip, note and lane, per mouse move.

**Decision:** the snapshot carries **topology and slot indices**; **levels come from atomics**,
read once per block into targets and ramped by a per-edge `Slew`.

This is not an invention — it is the pattern the file already documents:
> *"the compile only bakes clips + automation; gain/pan/eq/sends/master/limiter are params,
> exactly like the live engine"* — `agent-surface/src/host.rs:1941-1944`

New `EngineParams` surface (**this is the seam between two lanes — the signatures are law**):

```rust
pub fn set_edge_level(&self, slot: usize, level: f32);            // clamped 0.0..=4.0
pub fn edge_level_target(&self, slot: usize) -> f32;
pub fn clear_edge_levels_from(&self, from: usize);                // see the hazard below
pub fn set_node_gain_db(&self, slot: usize, gain_db: f32);        // clamped MIN/MAX_GAIN_DB
pub fn node_gain_target(&self, slot: usize) -> f32;               // linear
pub fn clear_node_gains_from(&self, from: usize);
pub fn track_gate_target(&self, track: usize, any_solo: bool) -> f32;   // §3.3
```

> ⚠️ **STALE-SLOT HAZARD — this is the solo bug's twin and it will bite.** Slots are assigned
> by `compile`. After a session swap the mapping changes, and a level left in a retired slot
> is either harmless (nothing points at it) or **wrong** (a recycled edge inherits a level the
> user never set for it). This is structurally identical to the reason
> `clear_track_solos_from` exists (`params.rs:152-160`). Every host that pushes edge levels
> **must** call `clear_edge_levels_from(n)` / `clear_node_gains_from(n)` immediately after,
> exactly as `sync_params` already does for solo (`agent-surface/src/host.rs:1965-1967`).
> §12 mandates a test that leaves a stale slot dirty and asserts the render is unaffected.

### 6.4 DECISION — the per-frame evaluation

Inside the existing frame loop in `RenderCore::render` (`rt.rs:999`), replacing the current
strips → buses → master tail (`rt.rs:1042-1177`):

1. **Zero `node_acc`** for this frame — one `for` over a fixed-size slice, at exactly one
   point per frame. (Today's `bus_a`/`bus_b` are re-zeroed at `rt.rs:1044-1045`; this is the
   same act, generalised.)
2. **Walk `node_order` by index.** For each `NodeStep`:
   - **`Track(i)`** — compute the strip exactly as today: clip sum + instrument, then
     `g = strip.gain.advance(...)`, pan, EQ → `x` (the post signal), and separately
     `pre = [clip_sum[0]*gl, clip_sum[1]*gr] * strip.gate.advance(gate_target)` (§3.2/§3.3).
     Meter `x` as today. Then, for each edge in `out_edges`:
     `node_acc[e.dest] += (if e.tap == Post { x } else { pre }) * edge_level[e.level_slot].advance(target)`.
   - **`Node(i)`** — read `node_acc[slot]`, multiply by `node_gain[i].advance(target)` (and
     its automation lane, §6.5), then push to `out_edges` the same way. **A bus node's input
     is complete when it is reached**, because the topo sort guarantees every feeder was
     scheduled earlier. That is the entire point of the schedule.
   - **`LegacyFx(A)`** — `reverb.process_frame(node_acc[fx_a], damping, feedback)`, then
     `* return_a.advance(return_a_target)`, then push to out-edges (which, after desugaring,
     is exactly one edge to master).
     **`LegacyFx(B)`** — the tempo delay, symmetrically.
   - **`Master`** — read `node_acc[master]`, master gain → limiter → toggle declick → meters →
     output. Unchanged from `rt.rs:1168-1225`.
3. **No sorting, no allocation, no lookup, no branch on a `String`** anywhere in the loop.

**Bounce/live parity is preserved by construction** because all of the above lives inside the
one `RenderCore::render` and inside the existing per-frame loop.

### 6.5 DECISION — automation of routing parameters, and the §0 row-7 bug

**Row 7 is a shipped silent-degradation bug and E5 must fix it, because E5 is the epic that
makes send levels matter.** `track.send.a.level` compiles into a real lane slot and nothing
ever reads it. The lane table (`RtTrack::lanes`, `Strip::lane_value`) is fully general and
already correct; only the *reader* is missing.

- **Edge levels are automated through the existing per-track lane table.** Every send and every
  group feed has a *track* as its source, so its lane lives on that track's `RtTrack.lanes`
  under `route.edge.<edgeId>.level` and is read with `strip.lane_value(...)`, exactly like
  volume and pan. `build_lane_index` already assigns the slot with zero changes.
- **The legacy spelling must keep working.** `track.send.a.level` and `track.send.b.level`
  must resolve to the desugared legacy edges' lanes, so that automation authored before E5
  becomes audible rather than staying inert. **This is a behaviour change to existing
  projects and it must be called out in the release notes**: automation that silently did
  nothing will start doing something. It is a bug fix, but it is not invisible.
- **Node gain (`bus.<id>.gain`) is automated through a new one-dimensional node lane table**
  on the snapshot: `RtSession::node_lanes: Box<[Option<AutoLane>]>` indexed by node slot, with
  a `[usize; MAX_ROUTE_NODES]` cursor array on `RenderCore`. Same `AutoLane::value_at` machinery,
  one dimension instead of two.
  Rejected alternative — *reject `bus.<id>.gain` as an automation target in E5*: `apply.rs`
  **already accepts it** (row 12), so rejecting it would be a narrowing, with the same replay
  hazard §2.1 rejects.
- **Edges whose source is a bus** (bus→bus) have no `RtTrack` to hang a lane on. E5 ships
  those levels as **atomic-only, not automatable**, and `require_param_ref_on` returns a typed
  error naming the deferral for `route.edge.<id>.level` when the edge's source is not a track.
  Called out here rather than discovered later.

---

## 7. Solo as a routing concern — DECIDED

**First, the correction (row 8): solo works.** E0 §5.3's "solo is not implemented in the
engine" was true when written and is false now. Do not repeat it. Current, verified semantics:

- A global gate: `any_solo(live_track_count)` is resolved **once per block** so every strip in
  a block agrees (`rt.rs:918-924`).
- **Mute wins** — a track that is both muted and soloed stays silent (the Live activator
  convention, documented at `params.rs:239-245`).
- It rides the **same 5 ms `Slew` as mute**, so it declicks instead of stepping.
- Bounded by the **live** track count, not `max_tracks`, so a stale flag on a retired slot
  cannot silence the whole mix.
- **Stem export is solo-safe**: `clear_track_solos_from(0)` before isolating by mute
  (`agent-surface/src/host.rs:2079`).
- Proven on **rendered buffers** by `render/tests/solo.rs` (10 tests) and
  `agent-surface/tests/solo_audible.rs` (3 tests). Not one of them asserts a model flag.

### 7.1 DECISION — solo is SOLO-IN-PLACE; bus and group nodes are implicitly SOLO-SAFE

**Solo gates source nodes (track strips) only. It never gates a bus, a group, or a return.**

Reasons, in order of weight:
1. **It is what the engine already does**, and it is right. Because solo gates the strip gain,
   a soloed track's own send still reaches the reverb while every other track's is zeroed —
   so the reverb, unprompted, already renders "the soloed track's reverb only". Changing this
   would be an unforced behaviour break against thirteen green tests.
2. **Solo-in-place preserves the mix context** — pan, EQ, sends, reverb, group gain. That
   context is the reason you press solo.
3. **A solo-gated bus is a famous footgun**: soloing a track whose group is not soloed would
   produce silence, and the user would file "solo is broken" for the second time in this
   product's life.
4. **Solo-safe returns are the universal convention** (Live, Logic, Pro Tools).

This composes with groups for free and costs no new code: soloing a track gates every
non-soloed strip at the source, so the group receives only the soloed track and passes it
through. §12 mandates a rendered-buffer test for exactly that.

### 7.2 DECISION — E5 does NOT add solo to bus/group nodes

`track.solo` is a v1.1 command keyed by `trackId`; soloing a node requires a **new command
name** per §9.2, and "does soloing a group solo its members?" is a second design question that
deserves its own decision, not a guess made inside a routing epic.

**Reserved name for the future: `route.node.solo`.** Do not add it. Do not add anything else
under that name. A later epic owns it.

---

## 8. Metering and UI invalidation

Two small surfaces that will otherwise be discovered late, by the UI lane, after the engine
lanes have merged.

- **`MeterBank` is sized to `max_tracks`** (`stats.rs:165-194`): per-track peak/RMS slots plus
  a fixed set of master slots. **Bus and group nodes have no meter slot**, so a bus fader with
  no meter is what E5-ui would otherwise ship.
  **DECISION:** `MeterBank` gains `nodes: Box<[TrackMeterAtomic]>` of `MAX_ROUTE_NODES + 2`
  (the two `LegacyFx` slots included, so the reverb and delay returns finally meter), written
  by the `Node` / `LegacyFx` steps in §6.4 exactly where `strip.meter_frame` is written today
  (`rt.rs:1148`), and flushed once per block through the existing block-epilogue path. Meters
  are **block-accumulated and flushed at the boundary**, never per-frame writes to an atomic —
  that is the existing pattern (`strip.rs:120-145`) and it keeps the frame loop clean.
  Owned by **E5-graph** (the writer) with the `stats.rs` accessor owned by **E5-params**;
  the two must agree on the accessor signature before either starts:
  ```rust
  pub fn node_meters(&self, count: usize) -> Vec<(f32, f32, f32)>;  // (peak_l, peak_r, rms)
  ```
- **`ChangeScope::Routing` already exists** (`diff.rs:29-30`) and is already emitted by the
  `route.*` apply arms. **E5 adds no new scope.** E5-ui subscribes to it for narrow
  invalidation; if the UI finds itself wanting a finer scope (per-edge), that is a
  report-and-stop, not a quiet addition — `ChangeScope` is serialized.



---

## 9. Latency compensation — DECIDED: E5 owns the HOOK, defers the ALGORITHM, and fails closed

> ⚠️ **AMENDED BY §19. E5 now IMPLEMENTS delay compensation.** §9.1's safety argument —
> *"every node E5 introduces is latency-free"* — was true of a gain-only node and is **false
> the moment §17 puts effects on buses**, because the existing `Limiter` (96-frame lookahead,
> `limiter.rs:28`) is a one-line reuse that a lane will absolutely make. §9.1 said that safety
> "evaporates the moment anything with latency lands on a node"; §17 is that moment.
> **§9.2's `latency_frames()` hook survives and is now load-bearing** — it stops being a
> tripwire and becomes the input to the compensation pass. The hard-error survives too, but
> only above a preallocation cap (§19.3).

Row 15: there is still no PDC anywhere, and the limiter's 96-frame lookahead is uncompensated,
so master latency silently shifts 2 ms when the limiter toggles. That is a **pre-existing**
defect. E5 neither fixes it nor inherits it — but E5 must not make it worse, and E5 is the
epic that creates parallel paths, so it cannot leave the topic unmentioned.

### 9.1 The reason E5 is safe without PDC — and it is a narrow reason

**Every node E5 introduces is latency-free.** A group is `track → gain → master`: zero extra
delay versus `track → master`. The two `LegacyFx` nodes are wet-only sends whose delay is the
effect (a reverb is *supposed* to be late) and whose relationship to the dry path is unchanged
from today. Therefore **E5 introduces no differing delay between parallel paths, and needs no
PDC.**

That safety evaporates the moment anything with latency lands on a node — a lookahead
compressor, a linear-phase EQ, a plugin. §4.3 defers exactly that, but a deferral that relies
on everyone remembering is not an engineering control.

### 9.2 DECISION — the fail-closed hook

E5 introduces, on whatever trait or enum a node processor is expressed through:

```rust
/// Frames of latency this node adds to every path through it. MUST be 0 until
/// PDC exists: `compile` refuses a graph containing a non-zero node.
fn latency_frames(&self) -> u32 { 0 }
```

…and `compile_session_full` **hard-errors** if any scheduled node reports non-zero, with a
message that names the node and says *"latency compensation is not implemented; see
DESIGN-E5-routing.md §9"*.

This converts "we forgot PDC" from a silent phase error the user hears as a thin, hollow mix —
the hardest class of audio bug to diagnose — into a **build-time refusal the moment a later
epic adds a latency-bearing effect to a bus.** The *accounting* (per-node latency, longest-path
over the DAG, a compensation-delay node modelled on `DelayBus`'s fixed-ring integer-tap
pattern, `delay.rs:71-110`) is written when it is needed, by the epic that needs it.

**A lane that finds itself wanting to return non-zero from `latency_frames` has left E5's
scope. Report and stop.**

---

## 10. Closing the silent-failure hole on load

Row 16 is a live silent-degradation path and E5 must close it, because E5 is the first epic
where the routing graph carries audio:

1. `parse_routing` (`package.rs:794-845`) **silently `continue`s** past a malformed node or
   edge — data loss on load→save, with no signal. Contrast E0 §3's deliberate asymmetry for
   `ParamRef`, which *preserves* unknown-but-well-formed paths verbatim.
2. `parse_routing` performs **no cycle check**, so a hand-edited or corrupt `.mstudio` yields
   a cyclic `Routing` in the model.
3. `compile_session_full` then returns `Err`, and `push_live_session`
   (`agent-surface/src/host.rs:743-750`) **swallows it by design**. Result: live audio silently
   freezes on the previous session and nothing is reported.

**DECISION.** Validate the routing graph at `Package::open` and **fail the open loudly**, with
a message naming the cycle path (`find_cycle` already produces it). This is the E0 doctrine
applied consistently: an unknown command name hard-fails the open because a loud failure beats
a silently wrong model — a cyclic graph is the same class of problem and deserves the same
answer.

Malformed nodes/edges: **also fail the open**, naming the offending id. A routing graph is not
a forward-compatibility surface the way a `ParamRef` is — a dropped edge is a *changed mix*,
not an unknown parameter.

---

## 11. Ownership — who touches what

This table is why five lanes merged clean on E1/E2. It is file-disjoint on purpose: **two
lanes must never own the same file.**

| Lane | OWNS (exclusively) | MUST NOT TOUCH |
|---|---|---|
| **E5-model** | `timeline-core/src/{routing,apply,paramref,package}.rs`; `contracts/command-catalog.v2.json` (**`description` strings only**); `timeline-core/tests/**` | `render/**` entirely; any Swift; any `paramsSchema` |
| **E5-params** | `render/src/params.rs`; `render/src/host.rs`; `agent-surface/src/host.rs` | `render/src/{rt,compile,strip}.rs`; `timeline-core/**`; the catalog |
| **E5-graph** | `render/src/{rt,compile,strip}.rs`; NEW `render/src/routing_rt.rs`; `render/tests/**` | `render/src/params.rs`; `agent-surface/**`; `timeline-core/**`; the catalog |
| **E5-ui** | `src/swift/Sources/Studio/**` (bus strips, send controls, tap toggle) | `engine/**` entirely |

### 11.1 The cross-lane seams — code against these as fixtures, do not wait

- **E5-params lands FIRST** and lands only the `EngineParams` surface in §6.3, with unit tests
  on the setters/getters (clamping, stale-slot clearing). **E5-graph codes against those exact
  signatures as a fixture** the way E2 coded against `NoteEvent` before E1 landed it. The
  signatures in §6.3 are law; neither lane may change them unilaterally.
- **E5-model lands the `ParamRefKind::RouteEdgeLevel` variant and the implicit-master-feed
  predicate** as a pure function on `Routing`:
  ```rust
  /// True when N still has its implicit unity edge to master (§4.2).
  pub fn has_implicit_master_feed(&self, n: &NodeRef) -> bool;
  ```
  **E5-graph calls it; E5-graph does not reimplement it.** Two implementations of this
  predicate that disagree is a mix that changes depending on which code path ran.
- **E5-ui codes against the MCP tool surface**, which already exists (`studio_route_connect`
  et al., 128 tools, verified). No engine change is needed for the UI to become useful.

### 11.2 Merge order

`E5-params` → `E5-model` → `E5-graph` → `E5-ui`. E5-graph is the only lane that can break the
null gate; it merges after the two lanes it depends on, so a bisect over it is meaningful.

---

## 12. Verification — raw exit codes only

This program has caught **nine** false-green tests. Every clause below exists because one of
them got through.

### 12.1 The gates

```
cd engine && ./run-tests.sh; echo EXIT=$?      # THE gate. Baseline @ bae6def = EXIT=0.
```

- **`./run-tests.sh` is the real gate, not `cargo test --workspace`.** A bare workspace test
  fails two `agent-surface/tests/import.rs` tests on generated fixtures; the script generates
  them first (`run-tests.sh:6-11`). It also runs the copilot-feature tests, the wasm32 check,
  and it is `set -euo pipefail`.
- **Never pipe it through `tee`** — a `tee` pipeline returns *tee's* exit code, not the
  script's. If you must capture, use `./run-tests.sh > log 2>&1; echo EXIT=$?`.
- **A `--filter` matching nothing returns EXIT=0 with 0 tests run.** Always read the
  `running N tests` line. `0 passed` is not a pass.
- ⚠️ **`swift test` prints "Executed N tests, with 0 failures" AND EXITS 1** — two test
  frameworks in one target. There is one pre-existing `StudioMCPHostTests` keychain failure.
  **Confirm the failure set is byte-identical to the baseline; never weaken the assertion to
  make it green.** The Swift gate is:
  ```
  cd src/swift && rm -rf .build && MAJIKS_ENGINE=mock swift build; echo EXIT=$?
  ```
  `rm -rf .build` is mandatory: Swift's incremental build has produced false greens here.
- `cargo check -p timeline-core --target wasm32-unknown-unknown` (already in the script).
- Catalog↔MCP parity green; `docs/generated/mcp-tools.v1.json` regenerated if any `route.*`
  description changed (§2.3). Counts stay **105 / 128** — if a lane changed them, it violated §2.

### 12.2 The regression gate that matters most

**Capture a reference bounce from the merge-base commit BEFORE touching the render loop.**

```
git stash && git checkout bae6def
# bounce a fixture project that uses mix.send a AND b, mute, solo, EQ and automation
```

Then assert the post-E5 binary produces a **bit-identical** bounce for that project. A v1
project has an empty `Routing`, so after desugaring it must render *exactly* the same samples.
If it does not, §3.1 or §3.3's "do not refactor `g`" was violated. **This single test catches
more than the rest of §12 combined.**

### 12.3 Audio proofs — assert on RENDERED BUFFERS, never on model state

> **Solo shipped broken for months because a UI-state test passed while nothing was audible.**
> Row 7 shows send-level automation is *still* in that state today. Every assertion below
> compares samples.

Follow the `render/tests/solo.rs` pattern: constant-DC clips at distinguishable levels
(0.25 / 0.50) so each contribution is identifiable by inspection.

1. **Group sums**: two tracks → one group → master equals the direct mix. No double-count.
2. **Implicit-feed rule** (§4.2), one test per row of that table.
3. **Group fader**: `bus.<id>.gain` at −6 dB halves the group's contribution and nothing else.
4. **Post-fader send is killed by mute** *and* **by solo** — the current behaviour, now pinned.
5. **Pre-fader send survives fader-down**: fader to −∞, reverb tail continues.
6. **Pre-fader send is killed by mute** and **by solo** (§3.3).
7. **Pre-fader tap is EQ-free** (§3.2): a −24 dB notch on the strip must not appear in the
   pre-tap's contribution. *This test pins a deliberate divergence — label it as such in the
   test's doc comment so a later lane does not "fix" it.*
8. **Both gates declick**: the mute/solo transition on the pre tap ramps over
   `MICRO_FADE_FRAMES` (240 frames @ 48k) and does not step. Assert the ramp, not just the
   endpoints — `solo.rs` already shows how.
9. **Solo-in-place keeps the soloed track's reverb** (§7.1), and **solo does not silence a
   group**.
10. **Send-level automation is now AUDIBLE** (row 7): a 0→1 ramp on
    `route.edge.<id>.level` — *and* on the legacy `track.send.a.level` — changes the rendered
    buffer. **Note in the test that this asserts the inverse of what the tree does today.**
11. **Stale-slot hygiene** (§6.3): dirty a retired edge/node slot, swap the session, assert
    the render is unaffected.
12. **Bit-identity at 128 / 417 / 480 / 512** with a group *and* a send active. Extend
    `render/tests/graph.rs`, do not write a parallel harness.

### 12.4 Mutation checks — MANDATORY, one per proof above

**Neuter the feature; confirm the test FAILS.** For each of 1–12: force the tap to `Post`,
force the gate to `1.0`, zero the edge level, skip the `node_acc` write — and confirm red.
A test that stays green when you break the feature is not a test.

### 12.5 Test-seam honesty — name the hops

> ⚠️ **A test seam that bypasses the production path is structurally incapable of catching
> bugs in it.** A 15 ms MIDI input delay shipped with the entire suite green because the test
> seam dispatched on the caller's thread and skipped the pump.

Every new test must state, in its doc comment, which production hops it traverses. For E5 the
honest accounting is:

| Seam | Hops traversed | Hops SKIPPED |
|---|---|---|
| `ManualRenderer` + `render_offline_with` | `RenderCommand` channel → `drain_commands` → `install_session` → the one `RenderCore::render` | cpal device callback; real-time deadline |
| `EngineParams` setters called directly in a test | the atomic store and the block-boundary load | `host.rs::sync_params` / `sync_track_params` — **so a test that sets params directly does NOT prove the host pushes them.** This is exactly how the solo bug survived. |
| `compile_session_full` called directly | model → snapshot | `sync_after_mutation` → `push_live_session` |

**Therefore at least one E5 test must drive the full host path** — apply a `route.connect`
command through `Session::submit_json`, let `sync_after_mutation` run, and assert the bounce
changed. Without it, §12.3 proves the renderer and proves nothing about whether a user
pressing a button reaches it.

### 12.6 Structural proofs

- **Cycle rejection**: the §5.2 table, one test per row, asserting the error *text* names the
  cycle path.
- **Cyclic graph on disk fails the OPEN loudly** (§10) — construct the file by hand.
- **Malformed edge on disk fails the OPEN loudly**, naming the id (§10).
- **Cap enforcement**: 33 nodes / 513 edges fail in `compile` with a typed error naming the
  cap and the count. The audio thread never sees them.
- **Replay**: `v1_1_replay_regression.rs` green — unchanged blake3 chain.
- **Determinism**: the same project with edges declared in different orders compiles to an
  identical `node_order` and `edges` (`routing.rs` already tests the schedule half; extend it
  through `compile`).

### 12.7 Allocation and the RT probe

- **`render/tests/null_and_alloc.rs` pattern with a 32-node / 512-edge graph**:
  `guard::violations() == 0`. The test binary **must** install
  `#[global_allocator] static ALLOC: guard::CountingAlloc` or the assertion is vacuously
  green — `render/tests/solo.rs:29-31` documents this trap. Include the positive control
  (allocate on purpose inside a render scope, confirm the counter moves) before the negative.
- **E0 §9.10 explicitly assigns the RT probe to E5** and it is still not run: *"no
  0-underrun / 0-alloc measurement with a multi-node graph … E5 must run it."* Run
  `render/src/probe.rs` / `engine_proof` against a live device with a multi-node graph.
  Report honestly: **`underruns` counts source-read faults, not device dropouts**
  (`stats.rs:18-20`), and p95 is 100 µs-bucket resolution, so "0.1 ms" means "≤ the first
  bucket edge". If `docs/evidence/l2-render-graph.md` is written this time, that closes row 18.

---

## 13. Explicitly out of scope for E5

> ⚠️ **AMENDED BY §15.2.** The first four bullets are **now IN scope**. The last four remain
> out. §15.2 restates the whole list in its amended form — use that one.

Report and stop if any of these starts pulling itself in:

- ~~**Effects on user-created buses** (§4.3)~~ → **IN**, see §16.
- ~~**A compressor, a gate, or any dynamics processor** (row 13)~~ → **IN**, see §17.
- ~~**Sidechain as a feature** (§5)~~ → **IN**, see §18.
- ~~**Plugin delay compensation** (§9)~~ → **IN**, see §19.
- **`route.node.solo`** (§7.2) — the name is reserved, the command is not added. **Still out.**
- **Bus→bus edge level automation** (§6.5) — atomic-only in E5. **Still out.**
- **Post-EQ pre-fader sends** (§3.2) — the second `EqBank` is the documented upgrade path. **Still out.**
- **Multi-output / hardware bus routing.** No audio-device routing surface exists. **Still out.**

---

## 14. Proposed lane breakdown

> ⚠️ **AMENDED BY §21.** Four lanes became six. §21's table is the one to fan out from;
> §11's ownership table is extended, not replaced, by §21.1.

| Lane | Deliverable | Rough shape |
|---|---|---|
| **E5-params** | §6.3 `EngineParams` surface + §3.3 `track_gate_target`, unit-tested, plus both hosts' sync paths and the stale-slot clears | small, merges first, unblocks E5-graph |
| **E5-model** | §2.2 `ParamRefKind::RouteEdgeLevel`, §4.2 `has_implicit_master_feed`, §10 load-time validation, §2.3 descriptions + manifest regen | medium |
| **E5-graph** | §6.2 baked structures, §6.4 per-frame evaluation, §2.1 desugaring, §3.2 pre tap, §4.1 caps, §6.5 lane readers (**including the row-7 fix**), §9.2 latency hook, and all of §12.3 | **large — this is the epic** |
| **E5-ui** | Bus/group strips, send controls with a pre/post toggle, against the existing MCP surface | medium, fully parallel |

**If E5-graph proves too large to land as one branch**, the only safe internal split is
*(a)* desugaring + the per-frame walk over `node_order` with post-taps only, proven by the
§12.2 legacy-null gate, then *(b)* the pre tap, the gate slew and the automation readers.
**Do not split it by file** — `rt.rs` cannot be co-owned.

---
---

# PART II — Effect devices, dynamics, sidechain, and real PDC

**Scope call, Aaron, 2026-07-25:** *"we need to be on parity if not exceeding, of competitors,
so we need full DAW capabilities."*

Part I refused to invent an effect-device contract or a dynamics processor under time
pressure, and said so as a report-and-stop. That refusal was answered, not overruled: the
scope grew, so the design grows with it. Part II is written to the same standard — every
statement below is a decision with a reason, verified against this tree, and **a lane that
disagrees reports and stops rather than substituting its own.**

---

## 15. Scope amendment — exactly what changed

### 15.1 Every Part I decision, with its status

**Nothing in this table is changed silently. If a decision you are implementing is not
listed here, it is unchanged.**

| Part I decision | § | Status under Part II |
|---|---|---|
| `mix.send` frozen forever; enum never widened | §2.1 | **INTACT** |
| Legacy FX buses are render-side-only `NodeStepKind::LegacyFx`, no wire form | §2.1 | **INTACT** |
| `route.edge.<id>.level` is the one new *routing* ParamRef segment | §2.2 | **INTACT** — §16.3 adds *fx* segments; they are a different family |
| `track.send.<a\|b>.level` keeps its apply-time a/b restriction | §2.2 | **INTACT** |
| `bus.<id>.gain` is the node fader; do not invent `route.node.<id>.gain` | §2.2 | **INTACT** |
| No `paramsSchema` of any existing command is edited | §2.3 | **INTACT** — the 7 new commands are new *names* (§16.4) |
| `Tap::Post` = today's tap point, bit-exactly | §3.1 | **INTACT** |
| `Tap::Pre` = post-pan, pre-EQ, pre-fader | §3.2 | **INTACT** |
| Mute and solo gate both taps; mute still kills the send | §3.3 | **INTACT** |
| Do not refactor `g` into a product of two Slews | §3.3 | **INTACT — still the top null-gate hazard** |
| `MAX_ROUTE_NODES = 32`, `MAX_ROUTE_EDGES = 512` | §4.1 | **INTACT** — §16.5 adds two more caps |
| Implicit-master-feed rule | §4.2 | **INTACT** |
| A node is a gain-summing point and nothing else | §4.3 | ⚠️ **AMENDED — §16** |
| Sidechain legality table (which graphs are legal/cyclic) | §5.2 | **INTACT, and now load-bearing** |
| Sidechain ships as a spec only, not a feature | §5.1 | ⚠️ **AMENDED — §18** |
| Per-FRAME advance; per-block node rendering is forbidden | §6.1 | **INTACT — the single hardest rule in the document** |
| `RtEdge`, per-step `out_edges` ranges, walk by index | §6.2 | **INTACT** — §19.4 adds one field |
| Edge level and node gain are ATOMICS, not snapshot constants | §6.3 | **INTACT** — §16.6 extends the pattern to fx params |
| Stale-slot hazard: `clear_*_from` after every push | §6.3 | **INTACT — and now applies to fx param slots too** |
| Per-frame evaluation walk | §6.4 | **INTACT** — §16.7 inserts the fx chain into it |
| Row-7 fix: send-level automation must become audible | §6.5 | **INTACT** |
| Bus→bus edge level automation deferred | §6.5 | **INTACT** |
| Node meters (`MAX_ROUTE_NODES + 2` slots) | §8 | **INTACT** |
| Solo-in-place; buses implicitly solo-safe | §7.1 | **INTACT** |
| `route.node.solo` reserved, not added | §7.2 | **INTACT** |
| PDC deferred behind a fail-closed hook | §9 | ⚠️ **AMENDED — §19: PDC is implemented** |
| Load-time graph validation fails the open loudly | §10 | **INTACT** — §18.4 extends it to sidechain links |
| Ownership table, file-disjoint | §11 | **EXTENDED — §21.1** |
| Verification: raw exit codes, buffers not flags, mutation checks, seam honesty | §12 | **INTACT — and extended by §20** |
| Zero catalog commands, counts stay 105/128 | §2 | ⚠️ **AMENDED — §16.4: 112 / 135** |

### 15.2 Out of scope for E5 — the amended list

**IN, by the scope call:** effect devices on tracks, buses and master (§16); a zero-latency
effect suite including a keyed compressor and gate (§17); sidechain (§18); delay compensation
(§19).

**Still OUT — report and stop:**
- **`route.node.solo`** (§7.2). The name is reserved; the command is not added.
- **Bus→bus edge level automation** (§6.5). Atomic-only in E5.
- **Post-EQ pre-fader sends** (§3.2). The second `EqBank` is the documented upgrade path.
- **Multi-output / hardware bus routing.** No audio-device routing surface exists at all.
- **Third-party plugin hosting (AU/VST3).** That is E4 and it is deferred for a *contract*
  reason, not a capacity reason — see §22.2. **A lane that reaches for a plugin SDK has left
  the epic.**
- **Freeze / bounce-in-place, ARA, comping playlists, notation, video.** See §22.

---

## 16. The effect-device contract

### 16.0 Ground truth — re-verified for Part II, at `bae6def`

The coordinator's brief said: *"reuse the existing `track.device.<deviceId>.<paramKey>`
ParamRef … E0 states that path needs no contract change for new device kinds, so verify that
holds for effects too."* **It half holds, and the half that fails is the important half.**

| # | Fact | Where | Consequence |
|---|---|---|---|
| 20 | **`Device`'s own docstring already anticipates this**: *"An instrument (later: an effect) on a track."* | `model.rs:672` | The intent was recorded; the mechanism was not built. |
| 21 | **`device.add`'s `kind` is a CLOSED JSON enum** `["synth","sampler","drum"]`, and `DeviceKind` is a closed serde enum. | `command-catalog.v2.json`; `model.rs:555-559` | Adding `"compressor"` here would **widen a shipped v2 command's enum**. |
| 22 | **`DEVICE_PARAM_KEYS` is a closed 10-element const**, and `apply.rs` rejects any `param` segment outside it. | `model.rs:580-591`; `apply.rs:278-281` | Effect params (`threshold`, `ratio`, `mix`, …) are **rejected at apply time today**. |
| 23 | ❗ **`build_instrument` HARD-ERRORS on a track with more than one device**: *"track {} has {} devices; this build binds ONE instrument per track."* | `compile.rs:307-322` | **Adding an effect to a `Track::devices` would break the compile of every track that has an instrument.** This is the blocking one. |
| 24 | ❗❗ **No command in the entire catalog can write `Device::params`.** E1/E2 deliberately omitted the setter: *"its inverse cannot be exact without per-parameter defaults that the DSP lane owns, and inventing them would ship a booby trap."* `device.remove` **refuses** a device whose params are non-empty, for exactly that reason. | `apply.rs:1004-1021` | **An effect with no way to set its parameters is not an effect.** E5 must add the setter — and E5 *is* the DSP lane, so it can supply the defaults E1/E2 could not. |
| 25 | **`MasterBus` is `{gain_db, limiter, extra}`** — no device collection. | `model.rs:864-869` | A master-bus effect chain needs a new field. |
| 26 | **The automation half genuinely does hold.** `build_lane_index` is keyed by the verbatim ParamRef string and is device-agnostic (`compile.rs:557-577`); `Strip::lane_value` is a constant-index cursor read for *any* slot (`strip.rs:64-82`); the `autopoint.*` `target` schema is already the open pattern. | verified | **Effect params automate through the identical dense lane path with zero contract change** — which is the property the brief actually wanted, and it is preserved. |

**Verdict on the brief's premise:** the ParamRef/automation path needs **no contract change**
(row 26 — E0's promise holds). **Creation and parameter-setting need new commands** (rows
21–24). Anyone who reads E0 §3 as "effects are free" will hit row 23 in the first hour and
row 24 in the second.

### 16.1 DECISION — a separate `Fx` registry, NOT an extension of `Device`

**Effects live in a new `Fx` struct in a new, additive `fx: Vec<Fx>` collection on
`Track`, `RouteNode` and `MasterBus`. `Device`, `DeviceKind` and `device.add` are NOT
touched.**

```rust
/// An audio effect in an insert chain. Chain order IS Vec order.
/// Parameters are Num (E0 §1 invariant 6) in a BTreeMap for project.json byte
/// stability, exactly like Device::params. `extra` because every sibling struct
/// has one and E0 §9.3 showed that omitting it DESTROYS a future field.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Fx {
    pub id: String,
    pub kind: FxKind,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub params: BTreeMap<String, Num>,
    /// Sidechain key source, or None for the internal (self) detector.
    /// Serialized as the NodeRef wire grammar — `track.<id>` | `bus.<id>` | `master`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sidechain: Option<NodeRef>,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub extra: Map<String, Value>,
}

/// CLOSED, for the same reason DeviceKind is closed: an unknown kind must fail
/// loudly at the contract boundary rather than build a silent no-op node.
#[serde(rename_all = "lowercase")]
pub enum FxKind { Eq, Compressor, Gate, Delay, Reverb, Saturator, Chorus, Utility, Limiter }
```

Rejected alternative — **widening `DeviceKind` / `device.add`'s `kind` enum** (which would
reuse `track.device.<id>.<key>` verbatim, as the brief suggested):

1. **Row 23 kills it outright.** `build_instrument` refuses a track with two devices. An
   effect in `Track::devices` breaks the compile of every instrument track that also has an
   effect — which is every instrument track a user would build. Fixing it means rewriting
   `build_instrument`'s device selection *and* re-proving E1/E2's instrument tests. A separate
   collection makes that change **unnecessary**: `Track::devices` stays instruments-only and
   `build_instrument` is untouched.
2. It widens a **shipped v2 enum**. That widening is *loud*-safe (an unknown serde enum
   variant fails `Cmd::from_wire`, which hard-fails `Package::open`) rather than silent, so it
   is not a §9.2 violation — but "not a violation" is a weaker standard than "no widening at
   all", and E0 §2 requires every widening site to be enumerated in the superset test. Zero
   sites is better than one.
3. `Device` has `zones: Vec<DeviceZone>` (sampler/drum source bindings) which no effect will
   ever use, and `Fx` has `sidechain` which no instrument will ever use. Two shapes wearing one
   struct is how a model rots.

**Instruments precede effects by construction**: an instrument is a *source* (`Track::devices`,
summed at the clip layer, `rt.rs:1062`), the fx chain is an *insert* (`Track::fx`, applied in
the strip). There is no interleaving rule to invent, because there is no interleaving.

**Byte compatibility:** all three `fx` fields are `#[serde(default, skip_serializing_if =
"Vec::is_empty")]`, so a project without effects serializes to **exactly the bytes it does
today**. Pin it with the existing `device_bytes_unchanged_without_zones` pattern.

### 16.2 DECISION — `NodeRef` is the addressing scheme for an fx host

An fx chain can live on a track, a bus/group, **or master**. `NodeRef` already parses exactly
that set (`master` | `track.<id>` | `bus.<id>`, `routing.rs:126-142`) and already has a
`Serialize`/`Deserialize` that round-trips the wire string. **Use it. Do not invent a second
"where does this effect live" type.**

This is what makes a **master-bus effect chain** fall out for free, which is table stakes for
parity and which a `trackId`-keyed command family could never have expressed.

`MasterBus` gains `#[serde(default, skip_serializing_if = "Vec::is_empty")] pub fx: Vec<Fx>`.

### 16.3 DECISION — three new ParamRef segments, and NO catalog schema change

```
track.fx.<fxId>.<paramKey>          # fx on a track strip
bus.<nodeId>.fx.<fxId>.<paramKey>   # fx on a bus/group node
master.fx.<fxId>.<paramKey>         # fx on the master bus
```

- All three are well-formed under the **existing** `autopoint.*` / `autolane.*` `target`
  pattern `^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$` (verified in `command-catalog.v2.json`), and
  all three classify as `ParamRefKind::Unrecognized` today. Adding
  `ParamRefKind::{TrackFxParam, BusFxParam, MasterFxParam}` plus `require_param_ref_on` arms
  is a **pure Rust addition. Zero catalog schema edits.**
- **This is E0 §3 paying off exactly as designed**, and it is the half of the brief's premise
  that survives (row 26): effect parameters automate through `build_lane_index` →
  `RtTrack.lanes` / node lanes → `Strip::lane_value` → `AutoLane::value_at`, the identical
  dense path instruments use. **No new automation machinery.**

**Why `track.fx.` and not `track.device.`** (deviating from the brief's letter, not its
intent): `track.device.<id>.<key>` resolves against `Track::devices`, which §16.1 keeps
instrument-only, and its `param` segment is validated against `DEVICE_PARAM_KEYS` (row 22).
Reusing it would force the two registries to share an id namespace and force
`require_param_ref_on` to search both collections for every path. A sibling segment costs
nothing — the grammar and the schema already admit it — and keeps the registries disjoint.
**The property the brief was protecting (same dense lane path) is fully preserved.**

**`FX_PARAM_KEYS`**: a closed const in `timeline-core`, the direct analogue of
`DEVICE_PARAM_KEYS`, listing every key any `FxKind` honours. Adding keys to it is a
**widening** of what `apply.rs` accepts, which is the safe direction — nothing previously
valid becomes invalid.

> **DECISION — do NOT validate the (kind, key) pairing at apply time.** E1/E2 deliberately
> left it unvalidated (`model.rs:575-579`) and E5 keeps that, for a hard reason: `apply.rs`
> **does** run on replay (`session.rs:566-618` → `apply_cmd` → `require_param_ref_on`), so
> tightening the pairing would break replay of any project that ever automated a key its kind
> ignores. That is a narrowing, and §2.1 rejects narrowings.
>
> **But the hole this leaves is exactly the row-7 bug class**, at ~40 keys × 9 kinds instead
> of 10 × 3: automation bound to a key the kind ignores is silently inert. Close it without
> narrowing anything:
>
> **`compile_session_full` returns a `CompileReport { inert_lanes: Vec<String> }`** alongside
> the session, listing every compiled lane that binds to no live parameter. The host surfaces
> it. Nothing fails; the silence becomes *visible*. **§20.3 mandates a test that the report
> fires.** This is the general fix for row 7's whole class and it should outlive E5.

### 16.4 DECISION — seven new commands. Blast radius, stated in full.

Per E0 §9.2 (quoted in §2), **new semantics go in NEW command names.** All seven are new
names; **no existing command's `paramsSchema` is touched.**

| # | Command | `inverseRule` | `inverseShape` | Notes |
|---|---|---|---|---|
| 1 | `fx.add {target, fxId, kind}` | explicit → `fx.remove` | `explicit` | `target` is a `NodeRef` string; `fxId` pattern `^[A-Za-z0-9_-]+$` so the ParamRef path stays parseable. Appends to the chain. |
| 2 | `fx.remove {target, fxId}` | explicit → `fx.add` | **`multi`** | Undo restores the fx, its chain index, every stored param, and its sidechain link. **Never `self`** (E0 rule for add/remove). |
| 3 | `fx.move {target, fxId, index}` | self | `self` | Chain reorder. Self-inverse carries the prior index. |
| 4 | `fx.param.set {target, fxId, key, value}` | explicit → `fx.param.set` | **`multi`** | `value` is a `Num`. The real inverse is a `fx.param.set` with the prior value **or** a `fx.param.clear` when the key was absent — which is precisely what `inverseShape: "multi"` means ("**may** be a sequence", E0 §9.8.3), and it mirrors how `route.node.remove` already declares one name and emits a sequence. |
| 5 | `fx.param.clear {target, fxId, key}` | explicit → `fx.param.set` | `explicit` | Restores sparsity. Absent key = the DSP default; see below. |
| 6 | `fx.sidechain.set {target, fxId, source}` | explicit → `fx.sidechain.set` | **`multi`** | `source` is a `NodeRef` string. Validated against §5.2 + §18.2 at command time. Inverse is a set-to-prior or a clear. |
| 7 | `fx.sidechain.clear {target, fxId}` | explicit → `fx.sidechain.set` | `explicit` | |

**Params stay SPARSE.** An absent key means "the DSP default", exactly as
`build_instrument` already implements it (`InstrumentParams::default()` then override,
`compile.rs:349-363`). Rejected alternative — *materialize every default at `fx.add`*: it
would make `Device`/`Fx` diverge in how a missing key reads, and would bloat `project.json`
for no gain. One rule, both registries.

**`device.remove`'s non-empty-params guard (row 24) has an `fx` analogue and it must NOT be
copied.** `device.remove` refuses a device with stored params because E1/E2 had no way to
restore them. `fx.remove` **does** have a way — `fx.param.set` — so `fx.remove` restores them
in its `multi` inverse and refuses nothing. Copying the guard would make every configured
effect unremovable.

#### The six hardcoded counts — every one, with its current value

**105 → 112 commands. 128 → 135 MCP tools** (104 → 111 command tools; 24 non-command tools
unchanged; the only exclusion remains `gen.landed`).

| Site | Current | New |
|---|---|---|
| `timeline-core/src/catalog.rs:207` | `105` | `112` (and extend the explanatory string) |
| `timeline-core/tests/conformance.rs:32` | `105` | `112` |
| `timeline-core/tests/conformance.rs:35` | `105` | `112` |
| `agent-surface/tests/parity.rs:54` | `105` | `112` |
| `agent-surface/tests/parity.rs:66` | `104` | `111` |
| `contracts/conformance/tests/conformance.rs:156` | `105` | `112` |
| `agent-surface/src/registry.rs:715` | comment says 105 | update the comment |
| `timeline-core/tests/support.rs::representative_commands()` | 105 entries | **+7 entries** — `conformance.rs:35` asserts the table equals the catalog set exactly |
| `timeline-core/tests/deferred_proposals.rs` | lists the 5 `route.*` names | **+7 `fx.*` names** |
| `docs/generated/mcp-tools.v1.json` | `toolCount: 128` | regenerate — byte-compared at `parity.rs:71-79` |

```
cargo run -p agent-surface --bin majiks-studio-cli -- tools --write engine/docs/generated/mcp-tools.v1.json
```

**All ten sites move in ONE commit, by ONE lane (E5-model).** A partial bump is a red
workspace for everyone else.

**And the four E0 §9.5 gates apply to each of the seven:** a catalog entry with consistent
`journaled`/`undoable`/`inverseRule`; an `apply.rs` arm returning `hint: Some(cmd)` (the hint
**is hashed**, and its params must be `Num`); an entry in `representative_commands()`; the
count bumps above.

### 16.5 DECISION — capacity

| Cap | Value | Why |
|---|---|---|
| `MAX_FX_PER_CHAIN` | **16** | Deep enough for any real chain; keeps a per-chain `[Option<u8>; N]` slot table small. |
| `MAX_FX_TOTAL` | **256** | The RT fx pool is one flat preallocated slab; 256 × (64 tracks + 32 nodes + master) is generous and bounds the worst-case block cost. |
| `MAX_COMP_FRAMES` | **4096** (≈85 ms @ 48k) | §19.3. |

All enforced **control-side in `compile`**, typed error naming the cap and the count, exactly
as `build_lane_index` already does (`compile.rs:565-570`). The audio thread never sees an
over-cap session.

### 16.6 DECISION — fx params are ATOMICS, following §6.3 unchanged

The same argument as §6.3 applies with more force: turning a compressor's threshold knob must
not trigger `sync_after_mutation` → `push_live_session` → a full rebuild of every clip, note
and lane (row 17). **The snapshot carries the chain topology and the slot indices; the values
come from atomics**, read once per block into targets and ramped by a `Slew`.

```rust
// EngineParams — the seam between E5-params and E5-fx. These signatures are law.
pub fn set_fx_param(&self, slot: usize, value: f32);       // slot = flat fx-param slot
pub fn fx_param_target(&self, slot: usize) -> f32;
pub fn clear_fx_params_from(&self, from: usize);           // ⚠️ STALE-SLOT HAZARD, §6.3
pub fn set_fx_bypass(&self, fx_slot: usize, bypassed: bool);
```

> ⚠️ **The §6.3 stale-slot hazard applies verbatim and is now three-dimensional** (edges,
> nodes, fx params). Every host push must be followed by the matching `clear_*_from`. This is
> the same shape as `clear_track_solos_from` (`params.rs:152-160`), which exists because a
> stale flag on a retired slot silences the whole mix. A stale fx-param slot is worse: it is
> *inaudible* until the slot is recycled, and then it is a wrong sound with no cause.

**Bypass is a param, not a command.** `fx.param.set {key: "bypass", value: 0|1}` — no eighth
command, and it automates for free. It must ramp over `MICRO_FADE_FRAMES` or it clicks.

### 16.7 DECISION — where the fx chain runs in the per-frame walk

Inserted into §6.4's walk, changing nothing else about it:

- **`Track(i)` step** — clip sum + instrument → **fx chain (in `Vec` order)** → `g`/pan → EQ →
  `x` (post) / `pre` (§3.2). **The fx chain runs BEFORE the fader**, which is where an insert
  belongs and which keeps `Tap::Post`'s definition (post-fader, post-pan, post-EQ) exactly as
  §3.1 froze it.
- **`Node(i)` step** — `node_acc[slot]` → **fx chain** → node gain → out-edges.
- **`Master` step** — `node_acc[master]` → **fx chain** → master gain → the existing master
  limiter → toggle declick → meters → out.
- **`LegacyFx(A|B)`** — unchanged. The hardcoded Freeverb and tempo delay stay exactly as they
  are, so §12.2's legacy-null gate still passes. **They are not reimplemented as `FxKind::Reverb`
  / `FxKind::Delay`**, even though those kinds now exist. Reimplementing them would change the
  rendered output of every existing project. *(A later epic may migrate them behind an explicit
  project-format version bump. Not E5.)*

**Every fx `process_frame` advances per FRAME (§6.1). An fx with a per-block process method
is forbidden and will break bit-identity at 128/417/480/512.** No exceptions, including for
FFT-based effects — which is one more reason none ship in E5.

---

## 17. The effect suite, and the keyed dynamics processor

### 17.1 DECISION — nine kinds, seven of them reusing DSP that already exists

| `FxKind` | Implementation | Latency | New DSP? |
|---|---|---|---|
| `Eq` | **`EqBank`** (`dsp/biquad.rs`) — 4 bands, already declicked | 0 | **reuse** |
| `Delay` | **`DelayBus`** (`dsp/delay.rs`) — fixed ring, integer tap, tempo divisions | 0 | **reuse** |
| `Reverb` | **`ReverbBus`** (`dsp/reverb.rs`) — Freeverb, 4 combs + 2 allpass | 0 | **reuse** |
| `Limiter` | **`Limiter`** (`dsp/limiter.rs`) — true-peak, **96-frame lookahead** | **96** | **reuse** — and *this* is why §19 exists |
| `Utility` | gain / pan (`dsp/pan.rs`) / width / polarity invert | 0 | trivial |
| `Saturator` | waveshaper + oversample-free `tanh`-style curve, `Slew`'d drive | 0 | small, new |
| `Chorus` | short modulated delay off `DelayBus`'s ring pattern | 0 | small, new |
| **`Compressor`** | §17.2 | **0** | **new — the centrepiece** |
| **`Gate`** | §17.2, same detector, inverted decision | **0** | new |

**Seven of nine are reuse or near-reuse.** That is the whole reason a real effect suite fits
inside E5 at all, and it is a direct dividend of E1/E2's discipline about fixed-size,
per-frame, allocation-free DSP primitives. **Do not rewrite any of the four reused
primitives** — wrap them.

**Every kind except `Limiter` reports `latency_frames() == 0`.** That is a deliberate suite
design, not a coincidence: no lookahead compressor, no linear-phase EQ, no FFT. See §19.1.

### 17.2 DECISION — the compressor is feed-forward with a keyable detector

```
                 ┌──────────────────────────────────────────┐
   key input ───►│ detector: |x| or RMS → attack/release env │──► gain reduction
  (self OR a     └──────────────────────────────────────────┘            │
   sidechain                                                             ▼
   node's                          audio in ──────────────────────────► × ──► out
   accumulator)                                          (+ makeup, + dry/wet mix)
```

- **Params** (all in `FX_PARAM_KEYS`, all `Num` on the wire, all automatable through §16.3):
  `threshold` (dB), `ratio`, `knee` (dB), `attack` (ms), `release` (ms), `makeup` (dB),
  `mix` (0..1, parallel/NY compression), `detector` (0 = peak, 1 = RMS), `bypass`.
- **Zero lookahead, by decision.** A lookahead compressor is the *only* thing in this suite
  that would need latency, and its musical benefit (catching transients a feed-forward
  detector overshoots) is small next to the cost of being the sole reason the graph carries
  delay. Most DAW compressors are feed-forward. **If a lane wants lookahead, that is a
  report-and-stop** — §19 makes it *possible*, not *approved*.
- **Per-FRAME envelope.** The detector's attack/release coefficients are computed once per
  block from the atomics (`(-1.0 / (ms * 0.001 * sample_rate)).exp()` — the exact form
  `EngineParams::limiter_release_coeff` already uses, `params.rs:306-309`); the envelope
  itself advances every frame. **A per-block envelope changes the sound with the buffer size
  and breaks the null gate.**
- **Gain reduction must reach and hold exactly 1.0 when the signal is below threshold**, and
  the smoothed envelope must flush denormals (`dsp::flush_denormal`) — otherwise an idle
  compressor costs real CPU forever, which is the trap `dsp/mod.rs:26-37` already documents.
- **`Gate`** is the same detector with the decision inverted (below threshold → attenuate),
  plus `hold` (ms) and `range` (dB). Sharing the detector is why it costs almost nothing.
- **Metering**: gain reduction is the one number a user must see. Report it through the
  §8 node/track meter path as a fourth value, block-flushed, never a per-frame atomic write.

### 17.3 What "the key input" reads — this is the load-bearing detail

**With `sidechain: None`** the detector reads the fx's own input, frame by frame. Trivial.

**With `sidechain: Some(source)`** the detector reads **`node_acc[source_slot]` for the
current frame** — the source node's fully-summed output at this instant.

That value is **complete and undelayed** if and only if the source node was evaluated earlier
in `node_order` this frame. The topological sort already guarantees ordering for *audio*
edges; a sidechain link is not an audio edge, so **the sort must be told about it** — §18.

> **If the sort is not told, the detector reads `node_acc[source]` before it has been
> written this frame, i.e. exactly `0.0`.** Not a one-sample error — **silence**. The
> compressor would never duck. This is precisely the failure E0 §5.1 documented for
> early-indexed groups ("reads exactly `0.0`, not a delayed value") and it would present as
> "sidechain does nothing", with every test that asserts the *model* passing. **Assert on
> rendered buffers (§20.2).**

---

## 18. Sidechain — now a feature

§5.2's legality table is unchanged and is now the specification of what `fx.sidechain.set`
accepts. §5.1's "spec only" decision is reversed.

### 18.1 DECISION — a sidechain is an ORDERING constraint, not an audio edge

`fx.sidechain.set {target, fxId, source}` stores `Fx::sidechain = Some(source)`. It creates
**no `RouteEdge`** and contributes **no audio** to the host node. What it creates is a
constraint: *`source` must be scheduled before `target`.*

Rejected alternative — *extend `NodeRef` / `route.connect`'s `to` pattern to address a key
input* (e.g. `bus.grp.key`): it would widen a shipped v2 command's `pattern` **and** require a
second `NodeRef` grammar, and it would put a zero-audio edge in `Routing::edges` where every
other edge carries signal. A field on the fx says what is true.

### 18.2 DECISION — `Routing::schedule` and `find_cycle` take the extra links

**This is a cross-lane seam. These signatures are law; neither lane changes them
unilaterally.**

```rust
/// `links` are ordering-only constraints (sidechain keys): (source, dest).
/// They participate in cycle detection and topological ordering exactly like
/// edges, and contribute no audio.
pub fn schedule(&self, track_ids: &[&str], links: &[(NodeRef, NodeRef)])
    -> Result<Vec<ScheduleStep>, CommandError>;

pub fn find_cycle(&self, track_ids: &BTreeSet<&str>, links: &[(NodeRef, NodeRef)])
    -> Option<Vec<NodeRef>>;

/// Command-time validation for fx.sidechain.set, mirroring validate_new_edge:
/// both endpoints resolve, source != host, master is never a key source,
/// and — the important one — no cycle.
pub fn validate_new_link(&self, source: &NodeRef, host: &NodeRef,
                         existing: &[(NodeRef, NodeRef)],
                         track_ids: &BTreeSet<&str>) -> Result<(), CommandError>;
```

Existing call sites — `compile.rs:256`, `routing.rs`'s own tests — pass `&[]` and behave
identically. `compile.rs` collects the links by walking every fx chain on every track, node
and master.

**Cycle rejection stays at command time** (§5.2, `routing.rs` doc header: *"the audio thread
must never discover a cycle"*). `validate_new_link` runs inside `fx.sidechain.set`'s apply arm
**before** the mutation, exactly as `validate_new_edge` does (`apply.rs:2797`).

### 18.3 The legality table, restated as acceptance criteria

Straight from §5.2, now with the command that exercises each:

| Scenario | `fx.sidechain.set` result |
|---|---|
| Kick keys a compressor on the bass bus; kick → master; bass bus → master | **ACCEPTED.** The canonical sidechain. Not a cycle. |
| Bus X keys an fx on bus Y **and** bus Y already feeds bus X | **REJECTED**, `CommandError::Routing`, message names the cycle path |
| An fx on node N keyed by N itself | **REJECTED** — that is `sidechain: None`, not a link |
| `source == master` | **REJECTED** — master is the sink and can never be a source (`routing.rs:249-254`) |
| `source` names a track/node that does not exist | **REJECTED** — dangling ref |
| A chain of links A→B→C→A | **REJECTED** — `find_cycle` is total over links + edges |

### 18.4 Load-time validation extends §10

§10 already requires the routing graph to be validated at `Package::open` and to **fail the
open loudly** on a cycle or a malformed edge. **Sidechain links join that check**, because a
hand-edited file can now express `fx.sidechain` and a cyclic link would otherwise surface as a
swallowed compile error and silently frozen live audio (`agent-surface/src/host.rs:743-750`).

Same doctrine, same reason: **a loud failure beats a silently wrong model.**

---

## 19. Latency compensation — DECIDED: E5 implements PDC

The coordinator put it correctly: *"A DAW that silently phases parallel paths is worse than
one that refuses the effect."* Part I's fail-closed hook was the right call while every node
was latency-free. §17 makes non-zero latency reachable **inside E5**, so the hook is no longer
sufficient.

### 19.1 The decision, and why it is not the other one

**E5 implements delay compensation.** The alternative — *ship effects restricted to
zero-latency processing, keep the hook failing closed* — was seriously considered and
rejected on one concrete fact:

> **`FxKind::Limiter` is a one-line reuse of `dsp/limiter.rs`, which has a 96-frame
> lookahead.** A bus limiter is a normal thing to want and a trivial thing to add. Under the
> zero-latency restriction, the very first useful thing a lane reaches for hard-errors at
> compile — and the pressure to "just return 0 from `latency_frames`" would be immediate,
> undetectable in review, and would ship a 2 ms phase error on every parallel path through
> that bus. **A restriction that everyone is motivated to defeat is not a control.**

And the cost is genuinely small, because **the hard part is already built**: longest-path over
a DAG is one forward pass in topological order, and `Routing::schedule` already produces that
order deterministically. PDC here is ~100 lines of control-side arithmetic plus an integer-tap
ring the tree already has a template for (`DelayBus`, `delay.rs:71-110`).

### 19.2 The algorithm — control-side, in `compile.rs`, one forward pass

```
for step in schedule_order:                      # already topologically sorted
    n = step.node
    incoming = [e for e in edges if e.to == n]
    upstream = max(latency[e.from] for e in incoming, default 0)
    latency[n] = upstream + own_latency(n)       # own = Σ fx latency_frames() on n

for e in edges:
    comp[e] = latency[e.to] - own_latency(e.to) - latency[e.from]   # ≥ 0 by construction
```

`comp[e]` frames of delay are inserted **on that edge**, so every path arriving at a node is
time-aligned. A node with one incoming path gets `comp == 0` on it and is bit-exactly
unchanged.

**Sidechain links participate in `latency` propagation but never receive compensation** — a
key signal is a control signal; delaying it to match an audio path would make the compressor
duck late. Stated explicitly because it is the non-obvious case and it will otherwise be got
wrong.

### 19.3 DECISION — `MAX_COMP_FRAMES = 4096`, and the hook still fails closed above it

- Compensation rings are allocated **control-side, per session, sized to their computed need**,
  and moved into the RT in the snapshot — the established pattern for heap payloads
  (`rt.rs:110-126`), with the replaced payload handed to `defer_drop` (`rt.rs:319-326`). The
  audio thread allocates nothing.
  Rejected alternative — *a fixed `MAX_ROUTE_EDGES × MAX_COMP_FRAMES` slab*: 512 × 4096 × 2 ×
  4 B ≈ **16 MB** resident for a feature almost every project uses at size zero.
- **`compile` hard-errors above the cap**, naming the node and the frame count. §9.2's
  fail-closed hook survives in exactly this form: `latency_frames()` is still the input, and an
  effect that wants 100 ms of lookahead still gets refused rather than silently truncated.
- **A zero-frame compensation must be a bit-exact passthrough**, not a ring read at offset 0.
  §20.2 mandates the test: a v1 project with no effects must bounce bit-identical (§12.2), and
  that gate runs *through* the new PDC code path.

### 19.4 What it adds to §6.2's baked structures

```rust
pub struct RtEdge {
    pub dest: u16,
    pub tap: Tap,
    pub level_slot: u16,
    pub comp: u32,        // NEW: compensation frames on THIS edge (§19.2). 0 = passthrough.
}
```
plus `RtSession::comp_rings: Box<[CompDelay]>`, indexed by edge slot, allocated control-side.
**Nothing else in §6.2 changes.**

### 19.5 What PDC does NOT fix — stated so it is not assumed

**The master limiter's uncompensated 96 frames (row 15) is NOT a PDC bug and E5 does not fix
it.** Master is the topological sink; there is no parallel path to phase against. What it
actually causes is a **whole-output timing offset that shifts by 2 ms when the limiter
toggles** — a transport/render-alignment concern (does a bounce start where the timeline says
it does?), owned by whoever owns transport alignment. **E5 must not "fix" it inside PDC**;
compensating the sink would shift the entire output relative to the timeline, which is a
different bug wearing the first one's clothes. Hand it on with this paragraph attached.

---

## 20. Verification — Part II additions

§12 stands in full. Everything below is **in addition**, and every clause in §12.4
(mutation checks), §12.5 (seam honesty) and §12.7 (allocation + the RT probe) applies to it.

### 20.1 The gate that must not move

**§12.2's legacy-null gate is now the gate for Part II as well.** A v1 project — no routing
graph, no fx — must bounce **bit-identical** to the reference captured from `bae6def`, *while
running through* the fx-chain walk (§16.7), the PDC pass (§19.2) and the sidechain-aware
schedule (§18.2). An empty chain, a zero-frame comp and an empty link set must each be exact
passthroughs. **If this goes red, stop; do not adjust a tolerance.**

### 20.2 Audio proofs — rendered buffers, never model state

1. **An fx changes the audio**: a `Utility` at −6 dB on a bus halves that bus's contribution.
2. **Chain order matters**: saturator→EQ ≠ EQ→saturator, rendered. `fx.move` swaps them and
   the buffer changes to match.
3. **Bypass is exact**: a bypassed fx is bit-identical to no fx, *and* the bypass transition
   ramps over `MICRO_FADE_FRAMES` rather than stepping.
4. **Compressor reduces gain**: a signal above threshold comes out quieter, by the ratio, with
   the envelope's attack visible in the buffer. Below threshold, gain reduction is exactly 1.0.
5. ⚑ **THE sidechain proof**: a kick on track A keys a compressor on bus B carrying a
   sustained tone. **Assert B's output dips in time with A's transients.** Then remove the
   link and assert it does not. *Mutation check: force `sidechain` to `None` in the compile
   and confirm this test goes RED.*
6. **The ordering proof (§17.3's failure mode)**: with the sidechain link present, assert the
   detector sees a **non-zero** key value on the first frame of the kick. A test that only
   checks "output changed" would pass while the detector read `0.0` from a not-yet-written
   accumulator on a later, reordered graph. **Assert the key value, not just the effect.**
7. **PDC proof**: a dry track and a track through a bus carrying `FxKind::Limiter` (96 frames)
   both feed master. **Null the two paths against each other and assert cancellation.**
   *Mutation check: force `comp = 0` and confirm the null FAILS.* Without this exact test PDC
   is unverified, because a phase error is inaudible in a single path.
8. **Master fx chain**: an fx on `master` affects the bounce; its position relative to the
   existing master limiter is the one in §16.7 and is asserted.
9. **Fx param automation is audible**: a ramp on `track.fx.<id>.<key>`,
   `bus.<id>.fx.<id>.<key>` and `master.fx.<id>.<key>` each change the rendered buffer.
   **This is row 7's lesson applied prospectively — a compiled lane that nothing reads is
   the default outcome, not the unlikely one.**
10. **Denormal hygiene**: an idle compressor's envelope reaches exactly 1.0 and its state
    flushes to zero.
11. **Bit-identity at 128 / 417 / 480 / 512** with a full graph: groups, sends, a track fx
    chain, a bus fx chain, a master fx, a sidechain and non-zero PDC, all active. Extend
    `render/tests/graph.rs`; do not build a parallel harness.

### 20.3 Structural proofs

- **`CompileReport::inert_lanes` fires** (§16.3) for a lane bound to a key its kind ignores,
  and is **empty** for a correct project. Both directions, or the report is decoration.
- **Cycle rejection for links**: every row of §18.3, asserting the error *text* names the path.
- **A cyclic sidechain link on disk fails the OPEN loudly** (§18.4). Construct the file by hand.
- **Cap enforcement**: 17 fx in a chain, 257 fx total, and a 5000-frame latency each fail in
  `compile` with a typed error naming the cap and the count.
- **Byte compatibility**: a project with no `fx` anywhere serializes to bytes identical to
  `bae6def`. Extend `v1_1_replay_regression.rs`.
  > **Minor finding while verifying this:** `model.rs:683` cites a test named
  > `device_bytes_unchanged_without_zones` as pinning exactly this property for `Device::zones`.
  > **No test by that name exists in the tree** (`grep` finds only the docstring). Either the
  > test was renamed or it was never written; either way the citation is dangling. E5-model
  > should write the `fx` version *and* resolve the `zones` one rather than inheriting a
  > comment that points at nothing.
- **Inverse exactness for all seven commands** (proptest, `tests/properties.rs:82-108`), with
  the two `multi` cases explicitly covered: `fx.remove` of a configured, sidechained fx at a
  non-terminal chain index restores id, kind, index, every param and the link;
  `fx.param.set` on an absent key undoes to *absent*, not to a written default.
- **The serde claim E0 §9.7 asked for, in its mirror form**: a 10-line test proving an unknown
  `FxKind` variant **fails** `Cmd::from_wire` loudly rather than deserializing to a default.
  §16.1's whole safety argument rests on it — **write the test before depending on it.**
- **Catalog**: 112 / 135, all ten sites (§16.4), `mcp-tools.v1.json` regenerated,
  `deferred_proposals.rs` extended, superset test still green with **zero** widening sites.

---

## 21. Updated ownership and lanes

### 21.1 Ownership — extends §11, still file-disjoint

**Two lanes must never own the same file.** Two rows are added and one is narrowed.

| Lane | OWNS (exclusively) | MUST NOT TOUCH |
|---|---|---|
| **E5-params** | `render/src/params.rs`; `render/src/host.rs`; `agent-surface/src/host.rs` | `render/src/{rt,compile,strip}.rs`; `render/src/dsp/**`; `timeline-core/**`; the catalog |
| **E5-model** | `timeline-core/src/{routing,apply,paramref,package,model,cmd,catalog}.rs`; `contracts/command-catalog.v2.json`; `timeline-core/tests/**`; `contracts/conformance/**`; `agent-surface/tests/parity.rs`; `docs/generated/mcp-tools.v1.json` | `render/**` entirely; any Swift |
| **E5-graph** | `render/src/{rt,compile,strip}.rs`; NEW `render/src/routing_rt.rs`; NEW `render/src/pdc.rs`; `render/tests/{graph,null_and_alloc,solo}.rs` | `render/src/params.rs`; `render/src/dsp/**`; `agent-surface/**`; `timeline-core/**` |
| **E5-fx** *(new)* | `render/src/dsp/**` — NEW `fx.rs`, `compressor.rs`, `gate.rs`, `saturator.rs`, `chorus.rs`, `utility.rs`; NEW `render/tests/fx.rs` | `render/src/{rt,compile,strip,params}.rs`; `timeline-core/**`; the catalog |
| **E5-ui** | `src/swift/Sources/Studio/**` | `engine/**` entirely |

> **`agent-surface/tests/parity.rs` moved to E5-model** (§11 left it implicit). It carries two
> of the six hardcoded counts and must move in the same commit as the catalog, or the
> workspace is red for every other lane.

### 21.2 The cross-lane seams — code against these as fixtures, do not wait

§11.1's three seams stand. Three more:

1. **`EngineParams`'s fx surface (§16.6)** — E5-params lands it first with unit tests;
   **E5-graph and E5-fx code against those exact signatures.** Neither may change them
   unilaterally.
2. **The fx node interface** — E5-fx owns the implementations, E5-graph owns the call site.
   The trait is law before either starts:
   ```rust
   pub trait FxNode {
       /// Per FRAME (§6.1). Never per block. `key` is the sidechain input for
       /// this frame, or the fx's own input when unkeyed (§17.3).
       fn process_frame(&mut self, x: [f32; 2], key: [f32; 2]) -> [f32; 2];
       /// Read once per block from atomics into targets. No allocation.
       fn load_block_targets(&mut self, p: &EngineParams, base_slot: usize);
       /// Frames of latency (§19). MUST be a constant for the life of the node.
       fn latency_frames(&self) -> u32 { 0 }
       /// Block-flushed telemetry, e.g. compressor gain reduction (§17.2).
       fn take_block_meter(&mut self) -> f32 { 1.0 }
       fn reset(&mut self);
   }
   ```
   **E5-fx builds every kind against this trait with its own harness and never touches
   `rt.rs`.** That is exactly how E2 built instruments against `NoteEvent` before E1 landed it.
3. **`Routing::schedule` / `find_cycle` / `validate_new_link` (§18.2)** — E5-model lands the
   signature change; **E5-graph calls it and never reimplements the ordering rule.** Two
   implementations of a scheduling constraint that disagree is a mix that changes depending on
   which code path ran.

### 21.3 Lanes and merge order

| Lane | Deliverable | Size |
|---|---|---|
| **E5-params** | §6.3 + §16.6 `EngineParams` surface, §3.3 `track_gate_target`, both hosts' sync paths, every `clear_*_from` | small — **merges first, unblocks two lanes** |
| **E5-model** | §2.2/§16.3 ParamRef variants, §4.2 `has_implicit_master_feed`, §16.1 `Fx`/`FxKind` model, §16.4 the seven commands + all ten count sites, §18.2 schedule signature + `validate_new_link`, §10/§18.4 load-time validation | **medium-large — the contract lane; everything downstream waits on its types** |
| **E5-fx** | §17 all nine kinds against the §21.2 trait, own test harness, no engine wiring | **medium — fully parallel from day one**, needs only the trait |
| **E5-graph** | §6.2/§19.4 baked structures, §6.4/§16.7 per-frame walk, §2.1 desugaring, §3.2 pre tap, §4.1/§16.5 caps, §6.5 lane readers (**including the row-7 fix**), §19 PDC, §12.3 + §20.2 audio proofs | **large — this is the epic** |
| **E5-ui** | Bus/group strips, sends with a pre/post toggle, fx chain UI with drag-reorder and bypass, sidechain source picker, gain-reduction meters | **medium — parallel against the MCP surface** |

**Merge order: `E5-params` → `E5-model` → (`E5-fx` ∥ `E5-graph`) → `E5-ui`.**

E5-fx and E5-graph can merge in either order once both are green, because they are file-
disjoint and meet only at the §21.2 trait. **E5-graph is the only lane that can break the
§20.1 null gate**, so it merges late enough that a bisect over it is meaningful.

**If E5-graph is too large for one branch**, the only safe internal split is:
*(a)* routing evaluation — desugaring + the `node_order` walk, post-taps only, proven by
§12.2/§20.1; then *(b)* fx chain insertion + PDC + the pre tap + the automation readers.
**Do not split it by file** — `rt.rs` cannot be co-owned.

---

## 22. What parity honestly requires beyond E5

Aaron's bar is competitors' feature set or better. E5 as amended is a large step and it is not
the whole distance. This is the honest gap, from the clearest view of the tree anyone
currently has. **Assessments are judgement, not measurement; treat the ordering as the
recommendation and the sizes as estimates.**

### 22.1 What E5 (amended) delivers against the bar

Full routing graph; groups/submixes; arbitrary sends with pre/post taps; **effects on tracks,
buses and master**; a 9-effect suite with a **keyed compressor and gate**; **sidechain**;
**delay compensation**; solo-in-place with solo-safe returns; every parameter automatable
through one dense lane path. Combined with what already ships — MIDI notes and piano roll,
three instruments (synth, sampler, drum rack), 4-band channel EQ, a true-peak master limiter,
tempo/warp, takes and comping-by-take, stem export, loudness-targeted bounce, MIDI capture and
mapping, a journaled undo history with a blake3 integrity chain — that is a credible DAW.

### 22.2 The gaps, in the order they should land

| # | Gap | Why it matters | Assessment |
|---|---|---|---|
| **1** | **E4 — third-party plugin hosting (AU/VST3)** | **The single largest parity gap, by a wide margin.** No amount of first-party effects substitutes for a user's own plugins; for most working musicians it is the buy/don't-buy question. | **Large, and deferred for a *contract* reason, not a capacity one: a plugin's opaque state cannot be journaled, so it breaks the provenance chain that is this product's differentiator.** That tension needs a *design decision* before any code — most likely an opaque, hashed state blob that participates in the chain by hash only, with the honest admission that the audio is not reproducible from the journal alone. **Do this design next, even if the implementation waits.** |
| **2** | **Effect presets + a browser** | A 9-effect suite with no presets reads as a tech demo. This is a small amount of work that changes the perceived quality of everything E5 built. | **Small.** `Fx::params` is already a `BTreeMap<String, Num>`; a preset is that map plus a name. Reuse the sounds-vault browser pattern. **Highest value per unit of effort on this list.** |
| **3** | **E8 — instrument/effect racks + macros** | Chains, parallel racks, and 8 macro knobs. `ParamRef` was designed for this (`track.device.<id>.<param>` was E0's stated E8 use), and E5's fx chain is the substrate. | **Medium.** Mostly a model + UI epic once E5's chain exists. |
| **4** | **Audio comping / playlists** | Takes exist (`take.promote/discard/purge/restore/auditionMix`, 5 commands) but comping across takes on a timeline lane is what tracking sessions actually need. | **Medium.** The take model is already journaled; this is lane UI + a splice-per-region model, and `revise/splice.rs` already solves the crossfade. |
| **5** | **Freeze / bounce-in-place** | The CPU escape valve that makes deep chains usable on a laptop. | **Medium.** Needs a rendered-audio cache keyed by a hash of the chain state — and E5's snapshot is already a complete description of that state, so the key is nearly free. |
| **6** | **E7 — warp markers** | `clip.warp.set` and `clip.phaseAnchor.set` exist; free warp markers are the audible gap for tempo-flexible material. | **Medium.** E0 landed the phase anchor specifically for this. |
| **7** | **Automation UX + curve shapes** | The *engine* automation is now excellent (dense lanes, any parameter). Drawing, curve shapes, latch/touch/write modes, clip-relative automation are the gap. | **Medium — and it needs a CONTRACT change, which is easy to miss.** Verified: `render`'s `CurveKind` already supports `Step`/`Linear`/`Pow{k}` (`automation.rs:26-32`), but **`AutoPoint` has no curve field and `autopoint.add` has no curve param** (`model.rs:341-347`), so the host hardcodes `CurveKind::Linear` (`agent-surface/src/host.rs:1932`). Per E0 §9.2 the curve **cannot** be added as an optional param on `autopoint.add` — it needs a **new command name**. The DSP is already there; the contract is not. |
| **8** | **Multi-output / hardware routing** | Cue mixes, outboard sends, multi-out interfaces. §13 keeps it out of E5 because no audio-device routing surface exists at all. | **Medium.** cpal device enumeration exists; the *model* is the work, and E5's `NodeRef` grammar extends to it naturally. |
| **9** | **Control-surface / HUI support** | MIDI mapping exists (9 `midi.*` commands); a fader-bank protocol does not. | **Small-medium**, and lower priority than it looks — a nice-to-have for most users. |
| **10** | **ARA, notation, video track** | Genuine competitor features. | **Large each, low priority.** Notation and video are separate products in disguise. **Do not let any of these into a routing or effects epic.** |

### 22.3 The recommendation

**Land E5 as amended. Then do the E4 plugin-provenance *design* (#1) and ship presets (#2)
in parallel** — the first is the thing that decides whether this can be someone's main DAW,
the second is the cheapest large improvement to what E5 already built. **Then racks (#3) and
comping (#4).**

One caution, stated plainly because it is the risk in a "parity or better" mandate: **the
things that make this product better than a competitor are the journal, the provenance chain,
and the agent surface — not the effect count.** Every item above is a parity item; none of
them is a differentiator. E4's plugin-provenance design is the one place where parity and
differentiation collide, and it deserves a real decision rather than a default.

---

# Part III — Orchestration addenda (decided after E5-params landed)

E5-params raised three structural questions the lane table could not answer by itself. These are
decisions, not suggestions, and they bind every remaining E5 lane.

## §23.1 The edge-level PUSH — E5-graph is authorized a bounded edit to `sync_params`

`RtSession::edge_index` is *schedule* order and is produced by `compile` (E5-graph). A host cannot
derive it — declaration order is not schedule order — so E5-params correctly landed only the CLEAR
half, which depends solely on the live edge *count* and is therefore order-independent.

If we simply wait for a follow-up commit, there is a merge window in which the RT reader exists and
nothing pushes into it: **every send level reads zero, silently.** That is row 7's bug wearing new
clothes, and shipping it even briefly is unacceptable given it is the exact defect this epic was
started to fix.

**Decision:** E5-graph MAY edit `sync_params` (and `sync_track_params` if required) solely to land
the edge-level push, as its final commit. Conditions, all mandatory:
- Touch nothing else in those files. Name the exact functions and line ranges in the report.
- Land a test that drives the **full public path** — `submit_json` → `sync_after_mutation` →
  bounce — and asserts a non-zero edge level is audible. A test that pokes `EngineParams` directly
  cannot see this bug; that is precisely how the solo bug survived for months.
- Mutation-check it by deleting the push and confirming the test fails.

This is a deliberate, bounded exception to the one-owner-per-file rule, taken because the
alternative is a window of silent zeros.

## §23.2 Capacity constants have exactly one declaration

`MAX_ROUTE_NODES` (32) and `MAX_ROUTE_EDGES` (512) live in `params.rs`, at the point where the
arrays are actually allocated. §4.1's placement in `rt.rs` is superseded.

**E5-graph must `pub use crate::params::{MAX_ROUTE_NODES, MAX_ROUTE_EDGES};` in `rt.rs`** so
`rt::MAX_ROUTE_NODES` still resolves as the rest of this document spells it. **Do not redeclare
them.** Two declarations of one capacity is the class of disagreement this document exists to
prevent, and the failure would be a buffer sized by one number and indexed by another.

## §23.3 `render/src/stats.rs` belongs to E5-graph

§8 split it — `MeterBank::nodes` writer to E5-graph, the `node_meters` accessor to E5-params — while
§11 forbids two lanes owning one file, and `stats.rs` appears in no ownership row. The accessor
cannot compile without the field.

**Decision: `stats.rs` is E5-graph's, entire.** The writer and the field must land together; the
accessor is trivial alongside them. E5-params did not touch it.

## §23.4 Additions to the pinned param seam

E5-params added two things beyond the verbatim §6.3/§16.6 surface. Both are now law for E5-graph
and E5-fx:

- **`fx_bypassed(fx_slot) -> bool`** — §16.6 listed only the setter; the render side needs a load.
- **`MAX_FX_PARAMS_PER_FX = 32`**, with `base_slot = fx_slot * MAX_FX_PARAMS_PER_FX`. §16.6
  specified a flat slot space and §21.2's `load_block_targets(.., base_slot)` requires each fx's
  slots to be contiguous, so the stride is fixed. **`compile` must reject an fx kind that needs
  more than 32 parameter keys, naming the cap** rather than aliasing into the next fx's slots.
  ⚠️ **E5-fx: no effect may declare more than 32 parameter keys.** If a design needs more, report
  and stop rather than working around it.

Also pinned: non-finite parameter writes are **dropped, not clamped** — `f32::NAN.clamp()` is NaN,
and one NaN at a summing point destroys the entire mix with no cause visible anywhere in the model.

## §23.5 Seam decisions from E5-fx — binding on E5-graph and E5-model

E5-fx landed all nine effect nodes. Three of its findings are now law, and two of them are the
row-7 bug class if ignored.

- ⚠️ **`bypass` occupies NO parameter slot.** It is read only via `EngineParams::fx_bypassed(fx_slot)`.
  **E5-graph and E5-model must map the `bypass` key to `set_fx_bypass`, never to a `set_fx_param`
  slot.** Two spellings of one fact desync, and a slot nothing reads is precisely the inert-lane
  defect this epic began with.
- ⚠️ **`compile.rs` MUST call `seed_fx_defaults` before applying stored parameters.** An unseeded
  compressor reads `ratio = 0`. The clamp catches it, so it will not blow up — it will simply be
  *neutral*, which means the user's effect silently does nothing while every model-level test
  passes. That is the failure shape this document exists to prevent.
- `FxKindId::latency_frames()` is available **before construction**, so §19.2's PDC pass runs
  without instantiating any node. Only `Limiter` reports non-zero (96), and it does not vary with
  bypass — a latency that changed with bypass would make PDC wrong exactly when a user toggles it.
- `division` is the one `FX_PARAM_KEYS` entry no kind implements (`Delay` takes absolute `time` in
  ms; tempo resolution is control-side). A test asserts that unimplemented set is exactly
  `["division"]`, so drift in either direction is visible.

## §23.6 A DSP bug worth remembering

E5-fx found that its own `converge_exact` **never arrived at its target**: a textbook one-pole hits
an f32 rounding fixed point, because `fl(target + r)` quantises the residual to ULPs of `target`
and stalls once `|r| < 0.5/(1 - coeff)` ULPs. Measured **0.29% short at a 2 s release** — a −51 dB
residual that never decays, meaning **a gate would never actually close**. Fixed with a one-ULP
progress step at the stall.

Any future lane writing a smoother, envelope or ramp in f32 should assume this failure until it has
asserted arrival, not approach. `Slew` already solves it (it arrives exactly on target); prefer it.
