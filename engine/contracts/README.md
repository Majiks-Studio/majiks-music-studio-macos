# engine/contracts

Lane P0-C's deliverable: schemas, fixtures, and conformance tests for the three
binding contracts named in `02-ARCHITECTURE.md` sections 4-6 (the command bus /
catalog, the Gen Protocol, and the `.mstudio` project format). No engine
behavior, no UI, nothing outside this directory. This lane turns prose into
machine-checked artifacts so later lanes cannot drift from each other.

## Directory map

```
engine/contracts/
  command-catalog.v1.json        catalog data: every command, params, undo/journal flags
  command-catalog.schema.json    schema for the catalog file itself + the journal envelope shape
  gen-protocol.v1.yaml           OpenAPI 3.1: the 10 Gen Protocol ops + job lifecycle + capabilities
  gen-protocol.schemas.json      the same request/response schemas as plain JSON (no YAML parser needed to validate)
  gen-protocol-mapping.md        field-by-field mapping onto the existing Python backend, with exact wire param names
  project-format.v1.md           .mstudio package prose + worked example
  project.schema.json            schema for project.json (forward-compatible: additionalProperties true)
  fixtures/
    project/                     minimal-project.json + minimal-journal.jsonl (30 entries, replayable hash chain)
    commands/valid/              13 valid command envelopes + manifest.json (12 original + marker_remove.json via approved proposal 1)
    commands/invalid/            12 invalid command envelopes + manifest.json (each with its expected failure reason)
    gen-protocol/                3 request/response pairs
    tools/generate_fixtures.py   deterministic generator; fixtures are committed static files, this is how they were produced and can reproduce them byte-for-byte
  conformance/                   standalone Rust crate: validates fixtures against schemas, verifies the hash chain
  conformance_py/                pytest module: the same checks from Python
```

## How a lane consumes these

- **Read, do not fork.** Import `command-catalog.v1.json` /
  `command-catalog.schema.json` to validate commands you emit or accept.
  Import `gen-protocol.schemas.json` (not the YAML, which is documentation-first)
  if you need to validate a Gen Protocol request/response programmatically.
  Import `project.schema.json` to validate `project.json`.
- **Rust engine code** (timeline-core, agent-surface, etc.): once `engine/`
  exists as a Cargo workspace (P0-B, a different branch), add
  `engine/contracts/conformance` as a workspace member (see "Joining the
  workspace at merge" below) and depend on its validated schema-loading code
  rather than re-parsing the JSON files ad hoc, so there is exactly one place
  that knows how to load a catalog entry's `paramsSchema` or chase the hash
  chain.
- **Python backend code**: import `conformance_py`'s helpers the same way, or
  treat `command-catalog.v1.json` / `gen-protocol.schemas.json` as plain data
  and validate with the `jsonschema` package directly; both are supported, the
  conformance module does not require being imported as a library, it is
  primarily a test suite.
- **MCP / agent-surface tool generation**: the tool registry is GENERATED from
  `command-catalog.v1.json`'s `commands` array (name, paramsSchema, description
  become the tool definition) plus `readSurface` (read-only tools). Do not
  hand-write a parallel list; the parity gate test described in 02-ARCH section
  2 (D4) means every catalog command needs a tool or a documented exclusion.

## Change control

Contracts here are law once merged (02-ARCH's own framing, restated in the
runbook as R7). If your lane needs a field that does not exist, a command that
is unrepresentable as specified, or you find a genuine gap (see the proposals
on record below), **do not rename or invent silently**. Put it in your report
to the coordinating session as a named proposal. Contracts change by an
explicit merge to this directory, reviewed the same way the rest of the
program is, never as a side effect of a lane that needed one more field.

Proposals on record from building this lane (repeated in the P0-C report, not
just here):

1. RESOLVED (APPROVED by the coordinating session 2026-07-11, implemented in
   this directory): `marker.set` had no `marker.remove` counterpart in 02-ARCH
   section 4's catalog list, unlike `section.set`/`section.remove`, so a
   marker's creation could not be undone. `marker.remove` is now in the
   catalog as marker.set's undo-completing inverse (both undoable+journaled,
   mirroring the section.* pair), exercised by the journal fixture's
   marker.set entry and the `marker_remove.json` valid fixture. This entry is
   kept as the change-control precedent: this is what the propose-then-merge
   path looks like.
2. The Gen Protocol `analyze` response's `downbeats` and `loudnessLufs` fields
   have no current producer in the Python backend (`loudnessLufs` is planned
   for the Rust engine's `media` crate per 02-ARCH section 3, not Python;
   `downbeats` has no owner anywhere yet). Both are nullable and always null in
   v1. See `gen-protocol-mapping.md`'s analyze section for the full note.
3. `gen.finalize`'s `standard` quality rung (`acestep-v15-quality`) has no
   step-count default observed in any shipped backend call site. See
   `gen-protocol-mapping.md`'s finalize section.

## Joining the workspace at merge

`engine/` does not exist on this branch's base (`main@1869a5e`): lane P0-B is
creating `engine/` as a Cargo workspace on a different branch, in parallel, per
this program's phase-0 design (P0-B owns `engine/timeline-core`, this lane owns
`engine/contracts`, no shared files). `engine/contracts/conformance/Cargo.toml`
is therefore a **standalone** package (no `[workspace]` reference, builds and
tests on its own with `cargo test` run from inside
`engine/contracts/conformance/`) rather than a workspace member. At merge time,
once `engine/Cargo.toml` exists, add:

```toml
[workspace]
members = [
  "timeline-core",
  "render",
  "media",
  "agent-surface",
  "contracts/conformance",
  "xtask",
]
```

and delete this crate's own `[workspace]`-exclusion note in its `Cargo.toml` (a
package with no `[workspace]` table auto-detects the nearest ancestor
workspace once one exists, so no other change should be needed; verify with
`cargo test -p contracts-conformance` from the repo root after the merge).

## Canonicalization and the hash chain

This is the precise algorithm; `fixtures/tools/generate_fixtures.py`,
`conformance_py/blake3_pure.py` + `conformance_py/test_conformance.py`, and
`conformance/src/main.rs` all implement it identically, and the pytest/cargo
runs cross-check each other's fixtures. If you change this section, you must
regenerate every fixture (`python3 engine/contracts/fixtures/tools/generate_fixtures.py`)
and re-run both conformance suites.

**What gets hashed.** Take one journal entry (a `commandEnvelope`, see
`command-catalog.schema.json`). Build the object containing exactly its seven
logical fields — `id`, `ts`, `actor`, `name`, `params`, `inverse`, `result` —
**excluding `hash`** (hashing has to exclude its own output). This object,
canonicalized as described next, is "the canonical JSON line" referred to
below. `hash` is computed from it and then attached as an eighth field to
produce the line actually written to `journal.jsonl`.

**Canonical JSON, precisely:**

1. Object members are sorted by key, byte-for-byte ascending (every key in this
   contract is a plain ASCII identifier, so this is unambiguous ordinary string
   sort; nothing here relies on Unicode collation). Sorting is applied at
   **every nesting level**, not just the top level — e.g. `actor`'s two keys
   sort as `kind`, `name`.
2. No insignificant whitespace: item separator is a single `,`, key separator
   is a single `:`, nothing else. (Equivalent to Python's
   `json.dumps(obj, sort_keys=True, separators=(",", ":"))`.)
3. Strings use standard JSON escaping. Every non-ASCII code point is escaped as
   `\uXXXX` with lowercase hex digits (equivalent to Python's default
   `ensure_ascii=True`), so the canonical text is always pure ASCII regardless
   of source content, and therefore its UTF-8 encoding is byte-identical to its
   ASCII encoding — this sidesteps any question of Unicode normalization
   affecting the hash. Forward slashes are not escaped.
4. **Numbers (PINNED by catalog v2; deferred proposal 1, ACCEPTED).** A number
   is canonicalized by its SOURCE SHAPE, and the shape is never changed:
   - An **integer-shaped** literal (no `.`, no `e`) emits as plain decimal
     digits: no decimal point, no exponent, no leading zeros, no leading `+`.
     An integer-shaped literal like `92` must NEVER pass through a code path
     that re-emits it as `92.0`, which happens if a parser coerces every JSON
     number to a float type before re-serializing. Every implementation here
     parses JSON numbers in a representation that preserves "this literal had
     no `.` or `e`" (Python's `json.loads` gives `int`; Rust's `serde_json`
     `Number` preserves the u64/i64 vs f64 distinction) and never routes a
     value through an `f64`-typed field on its way to being hashed.
   - A **float-shaped** literal emits as the **shortest round-trip decimal**.
     Rust reaches that via `serde_json`'s `Display` (ryu); Python via
     `json.dumps`/`repr(float)`. These agree byte-for-byte for every finite
     `f64`, which is what makes the rule cross-language-safe.
   - Consequence, stated explicitly because it surprises people: the float
     TOKEN is normalized. `1e3` canonicalizes to `1000.0`, and `1.50` to `1.5`.
     What is preserved across the integer/float boundary is the SHAPE, not the
     spelling. `2` and `2.0` remain distinct and hash differently.
   - `NaN`, `Infinity` and `-Infinity` are not JSON and can never appear.
     Rust's `serde_json::Number` cannot hold them (`Number::from_f64` returns
     `None`); the Python canonicalizer rejects them explicitly (`allow_nan=False`).
   - `-0.0` is a valid, distinct token: it canonicalizes to `-0.0` and
     therefore hashes differently from `0.0`, even though the two compare equal
     under IEEE. Engine code that omits a field "when equal to its default"
     must compare wire shapes, not `as_f64` (see `timeline-core/src/num.rs`,
     whose `PartialEq` is shape-aware for exactly this reason).

   Before catalog v2 this rule said "integer literals only", and BOTH the Rust
   and Python conformance canonicalizers hard-rejected floats. That meant a real
   project with a fractional gain produced a journal the conformance suite could
   not hash at all, while `timeline-core`'s own canonicalizer happily emitted it
   — a latent cross-language integrity gap, not a doc nicety. v2 closes it and
   `fixtures/project/float-journal.jsonl` gives it fixture coverage.

5. Arrays preserve source order (order is semantically meaningful, e.g.
   `audition.stems`).
6. The canonical text has no trailing newline. `journal.jsonl`'s newline
   between entries is a file-format separator, never part of what gets hashed.

**The chain.** For entry *n* (1-indexed):

```
prev_hash_hex(1)  = "0" * 64                      # GENESIS_HASH, reserved constant
prev_hash_hex(n)  = hash(n - 1)                    for n > 1
hash(n)           = blake3_hex( ascii_bytes(prev_hash_hex(n)) ++ utf8_bytes(canonical_json(entry_n_without_hash)) )
```

`++` is byte concatenation, no separator. Because the canonical JSON text is
always pure ASCII (rule 3 above), `ascii_bytes(...)` and `utf8_bytes(...)` are
the same 64 and N bytes respectively that you would get from either encoding —
stated as both only to make clear neither side is doing anything encoding-magic
under the hood. `blake3_hex` is the 32-byte BLAKE3 digest (unkeyed, default
output length) rendered as 64 lowercase hex characters.

**Checkpoint linkage.** `project.json`'s `journal` block
(`project.schema.json`) must satisfy `entryCount == ` the number of lines in
`journal.jsonl`, and `tipHash == hash(entryCount)` (or `tipHash == genesisHash`
and `entryCount == 0` for a brand-new project with no journal entries yet).
This is the "replay equals the checkpoint" fixture requirement: conformance
tooling recomputes the whole chain from `journal.jsonl` and checks it lands on
exactly the `tipHash`/`entryCount` `project.json` claims. This is a structural
proof (the checkpoint pointer is not lying about which journal state it
summarizes), not a semantic replay of the 30 commands into a reconstructed
project model — the latter is command-execution behavior that belongs to
timeline-core, out of scope for a contracts-only lane. `minimal-project.json`'s
`tracks`/`clips`/`sections` content is still hand-traced to match what the 30
commands in `minimal-journal.jsonl` actually produce (so the fixture is a
useful golden case for whoever builds that executor later); this lane's own
conformance check just does not re-derive it.

**`txn.begin`/`txn.commit` pairing.** Not part of the hash itself, but a
related structural invariant conformance also checks in the journal fixture:
every `txn.commit` entry's `params.txnId` must match an earlier, not-yet-closed
`txn.begin`'s `params.txnId` (v1 transactions do not nest).

## Boot-test (clean-checkout one-liners)

```
cd engine/contracts/conformance && cargo test
python3 -m pytest engine/contracts/          # run from the repo root
```

Both are documented again, verified, in `docs/evidence/p0c-contracts.md`.
