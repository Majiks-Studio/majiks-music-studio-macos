//! Regression (L1 journal): the hash chain must survive save + reopen for ANY
//! float param value, not only ones that happen to be a fixed point of
//! serde_json's float parser.
//!
//! Origin: landing the repo click fixture produced a `gen.song` whose measured
//! bpm was `120.00000000000003` (the f64 at bits `0x405e000000000002`). The
//! journal hashes the canonical (ryu) text on append and RE-parses that text on
//! reopen (`Envelope::from_line` -> `verify`). serde_json's DEFAULT float parser
//! is not the exact inverse of its ryu serializer: it parsed that text to the
//! f64 one ULP higher, so the reopened entry re-hashed to a different value and
//! the chain failed to verify ("chain broken at entry N"). The workspace enables
//! serde_json's `float_roundtrip` feature, which makes float parsing bit-exact
//! so `parse(canonical(f)) == f` for every finite f64. This test reproduces the
//! failing value (and its ULP neighbourhood) and fails if that feature is ever
//! dropped.

use serde_json::json;
use timeline_core::envelope::{Actor, Envelope, GENESIS_HASH};
use timeline_core::journal::verify_lines;

/// The exact f64 whose ryu text serde_json's default parser misrounds, plus its
/// ULP neighbourhood and other values that force 17 significant digits.
fn adversarial_floats() -> Vec<f64> {
    let mut v = vec![
        120.00000000000003_f64, // the reproducing value (bits ...0002)
        8.0,
        92.5,
        174.0,
        119.98765,
        0.1,
        0.2,
        0.3,
        1.0 / 3.0,
        -3.5,
    ];
    let base = f64::from_bits(0x405e000000000002);
    for d in -4i64..=4 {
        v.push(f64::from_bits((base.to_bits() as i64 + d) as u64));
    }
    v
}

/// A `gen.song`-shaped envelope carrying `bpm` in its (hashed) request params,
/// exactly as the landing pipeline journals a measured bpm.
fn gen_song_with_bpm(id_n: u64, prev: &str, bpm: f64) -> Envelope {
    Envelope {
        id: format!("{id_n:026}"),
        ts: "2026-07-12T00:00:00Z".into(),
        actor: Actor::system(),
        name: "gen.song".into(),
        params: json!({
            "requestId": format!("{id_n:026}"),
            "trackId": "trk_vocals",
            "insertAtTicks": 0,
            "request": { "bpm": bpm, "durationSeconds": bpm / 15.0 },
        }),
        inverse: None,
        result: json!({ "ok": true }),
        hash: String::new(),
    }
    .finalize(prev)
    .expect("finalize")
}

#[test]
fn pathological_float_params_survive_the_journal_hash_chain() {
    let mut lines = Vec::new();
    let mut prev = GENESIS_HASH.to_string();
    for (i, bpm) in adversarial_floats().into_iter().enumerate() {
        let env = gen_song_with_bpm(i as u64 + 1, &prev, bpm);
        // The line exactly as journal.jsonl stores it.
        let line = env.to_jsonl();
        // The reopen path: reparse the stored line and re-hash it against its
        // predecessor. This is what broke before float_roundtrip.
        let reparsed = Envelope::from_line(&line).expect("parse journal line");
        reparsed
            .verify(&prev)
            .unwrap_or_else(|e| panic!("entry {i} (bpm {bpm}) failed to re-verify on reopen: {e}"));
        prev = env.hash.clone();
        lines.push(line);
    }
    // The whole chain verifies on reopen (exactly Package::open's up-front check).
    let (tip, count) = verify_lines(&lines).expect("full chain verifies on reopen");
    assert_eq!(count, lines.len());
    assert_eq!(tip, prev);
}
