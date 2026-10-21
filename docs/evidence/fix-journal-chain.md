# Fix: landing journal hash chain "chain broken at entry 15"

**Date:** 2026-07-12
**Branch:** fix/journal-chain-landing (base main eb4a7e3)
**Platform:** macOS (Darwin 24.6.0), Apple Silicon
**Toolchain:** cargo 1.93.0

## The bug

`build_landing` (L8 "Open in Studio") on the repo fixture
`click_120bpm_48k_stereo.wav` (the Rust `engine/fixtures` 32-bit-float set, the
canonical engine fixture) produced an `.mstudio` package whose `journal.jsonl`
blake3 hash chain FAILED verification on reopen:

```
OPEN FAILED: envelope error: chain broken at entry 15: envelope error:
hash mismatch on 01KXAV2V4BMBA2BY9HHJ8E8J46:
stored   a7b716ce8e228e9ca1c706647318c96667bc0911e03a1802dce3dd9b056200fb,
computed aa38e5844ae0755a8d122222218f08863ca8620fc37416b2001ce81f023c2bd1
```

Entry 15 is the landing's `gen.song` command. Its hashed params carry the
MEASURED bpm the tempo analysis produced for the click:

```json
"request":{"bpm":120.00000000000003,"durationSeconds":8.0, ...}
```

A synthesized song lands and reopens cleanly, so the defect is specific to
certain input audio, which is why it slipped through: some real input audio
produces an unopenable project on the primary onboarding flow.

## Root cause (the exact value + mechanism)

The measured bpm is the f64 with bit pattern `0x405e000000000002`
(= `120.00000000000003`, i.e. `120.0` + 2 ULP). The journal hashes the
canonical JSON text on APPEND and RE-parses that text on REOPEN
(`envelope::from_line` then `verify`). The break is a float serialize/parse
round-trip inconsistency INSIDE serde_json:

```
f64 in memory (measured bpm)                     bits = 0x405e000000000002
serde_json Number Display (ryu, write_canonical) = "120.00000000000003"
serde_json parse of "120.00000000000003"         bits = 0x405e000000000003  (1 ULP high)
re-canonicalized from the reparsed f64           = "120.00000000000004"
```

serde_json's DEFAULT float parser is not the exact inverse of its ryu-based
serializer: for this 17-significant-digit value it misrounds by 1 ULP. So the
bytes hashed at append (`...120.00000000000003...`) differ from the bytes
`verify` recomputes after reparsing the stored line
(`...120.00000000000004...`), and the entry re-hashes to a different value.
`write_canonical` and the hashing are correct and identical on both sides; the
fault is entirely the parser losing precision on read. Rust's std
`str::parse::<f64>` recovers `0x405e000000000002` correctly from the same text,
confirming ryu's output is right and serde_json's default parse is the weak
link.

The click fixture hits this because a pure periodic click train tracks to a bpm
whose shortest decimal is one of the values serde_json misrounds; a synth
song's measured bpm happens to be a parser fixed point.

## The fix (minimal, in timeline-core's canonicalization round-trip)

Enable serde_json's `float_roundtrip` feature on the workspace dependency
(`engine/Cargo.toml`). It makes float parsing bit-exact, so
`parse(canonical(f)) == f` for every finite f64, and the text the journal wrote
reparses to the identical value the hash was computed over.

```toml
serde_json = { version = "1", features = ["float_roundtrip"] }
```

Why this is the right, total, minimal fix:

- It touches only the READ path. `write_canonical` (the hasher) and its ryu
  "shortest round-trip" output are unchanged, so NO hash that was ever produced
  changes. It only makes reopen recompute the same hash it should always have.
- It is total: with the feature, every representable finite float is a fixed
  point of `parse(canonical(.))`, so NO input audio (or any float param from any
  caller: gain, pan, duration, stretch ratio) can produce an unopenable package.
  A 200k-value adversarial probe (the failing value, its ULP neighbourhood,
  random bit patterns, denormals, 17-digit forcers) went from 6614
  non-converging / 19599 non-fixed-point down to 0 / 0.
- Integers are unaffected (parsed and formatted identically), so the pinned
  golden conformance chain is byte-for-byte unchanged.
- Non-finite floats (NaN/Inf) cannot occur: `serde_json::Number` rejects them at
  construction, so a param is never a non-finite number.

The alternative (rounding the landing's measured bpm before journaling, like
`bpm_number` already does for `project.setTempo`) would only patch one call site
and leave every other float param exposed, so the canonicalization-round-trip
fix is preferred per the correctness bar for the onboarding flow.

## Before / after (same on-disk journal, byte-identical)

The reproduction wrote a package with the old (feature-off) build. The SAME
`journal.jsonl` bytes:

- feature OFF: `Package::open` -> `chain broken at entry 15` (above).
- feature ON:  `Package::open` -> `OPENED OK (chain valid), seq=18`.

End to end with the fixed CLI:

```
$ majiks-studio-cli land --mix fixtures/click_120bpm_48k_stereo.wav \
    --out click120.mstudio --separator bandsplit
  "measuredBpm": 120.00000000000003,
  "ok": true
$ majiks-studio-cli run --project click120.mstudio --script empty.jsonl
applied 0 commands, saved click120.mstudio          # Package::open verified the chain; exit 0
```

## Regression tests

- `timeline-core/tests/journal_float_roundtrip.rs`
  (`pathological_float_params_survive_the_journal_hash_chain`): builds a
  `gen.song` chain carrying the exact failing f64 (`0x405e000000000002`), its
  ULP neighbourhood, and other 17-digit values, then reparses each stored line
  and re-verifies, plus a full `verify_lines` over the chain. Reproduces the
  original `hash mismatch on ... reopen` failure with the feature off.
- `agent-surface/tests/landing_chain.rs`
  (`landed_gen_song_with_edge_case_bpm_reopens_with_valid_chain`): drives the
  pathological bpm through the same command bus + `Package` save/open the landing
  uses and asserts reopen succeeds. Deterministic and needs no audio fixture (the
  analysis fixtures are gitignored). Fails (`chain broken`) with the feature off.

Both were confirmed to FAIL with `float_roundtrip` removed and PASS with it.

## Verification

```
cargo test -p timeline-core --test journal_float_roundtrip : 1 passed
cargo test -p agent-surface  --test landing_chain          : 1 passed
cargo test -p agent-surface  --test landing (L8 acceptance) : 3 passed
cargo test -p timeline-core  --test conformance             : 7 passed
cargo test -p contracts-conformance                         : 23 passed
cargo test --workspace                                      : all green (0 failed)
```

Golden conformance tip hash unchanged:
`8cf75844f07da91612a0f094dc4d2639755565c630680aa386b58daf5d2bf1bb`
(`engine/contracts/fixtures/project/minimal-project.json`; the fixture journal
has no float-valued params, so the fix cannot move it). `Cargo.lock` is
unchanged (the feature pulls in no new dependency).

## How to reproduce

```bash
cd engine
cargo run -q -p render --bin gen-fixtures          # writes engine/fixtures/*.wav (gitignored)
cargo run -p agent-surface --bin majiks-studio-cli -- \
  land --mix fixtures/click_120bpm_48k_stereo.wav --out /tmp/j.mstudio --separator bandsplit
cargo run -p agent-surface --bin majiks-studio-cli -- \
  run --project /tmp/j.mstudio --script /dev/null   # reopens + verifies the chain
```
