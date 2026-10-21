//! QA properties for the persistence invariants that are easy to break with
//! an otherwise valid-looking command or number.

#[path = "support.rs"]
mod support;

use proptest::prelude::*;
use serde_json::json;
use std::fs;
use std::path::PathBuf;
use timeline_core::envelope::{Actor, Envelope, GENESIS_HASH};
use timeline_core::journal::verify_lines;
use timeline_core::package::Package;
use timeline_core::tempo::Bpm;
use timeline_core::{Project, TempoMap};

fn base() -> Project {
    Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()))
}

fn package_dir(seed: u64) -> PathBuf {
    std::env::temp_dir().join(format!("majiks-qa-fuzz-{}-{seed}", std::process::id()))
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 72, ..ProptestConfig::default() })]

    /// The reopen path must parse exactly the same float bits that were used
    /// when the envelope was hashed. This includes the known one-ULP landing
    /// regression and arbitrary finite f64 values.
    #[test]
    fn arbitrary_finite_float_params_keep_the_chain(bits in any::<u64>()) {
        let value = f64::from_bits(bits);
        prop_assume!(value.is_finite());
        let mut previous = GENESIS_HASH.to_string();
        let mut lines = Vec::new();
        for (index, field) in ["tempo", "gain", "pan"].into_iter().enumerate() {
            let envelope = Envelope {
                id: format!("{index:026}"),
                ts: "2026-07-12T00:00:00Z".into(),
                actor: Actor::system(),
                name: "mix.gain".into(),
                params: json!({"field": field, "value": value}),
                inverse: None,
                result: json!({"ok": true}),
                hash: String::new(),
            }.finalize(&previous).expect("finite JSON float finalizes");
            let line = envelope.to_jsonl();
            let reopened = Envelope::from_line(&line).expect("serialized envelope parses");
            reopened.verify(&previous).expect("reopened envelope verifies");
            previous = envelope.hash;
            lines.push(line);
        }
        let (tip, count) = verify_lines(&lines).expect("whole reopened chain verifies");
        prop_assert_eq!(tip, previous);
        prop_assert_eq!(count, 3);
    }

    /// Saving a random, legal command stream and saving it again after a
    /// reopen must be byte-stable. Asset placeholders keep this property
    /// focused on persistence rather than the expected offline-asset rule.
    #[test]
    fn random_mstudio_save_load_save_is_byte_stable(seed in any::<u64>(), steps in 0usize..45) {
        let (source, commands, next_seq) = support::build_random(seed, steps);
        let dir = package_dir(seed);
        let _ = fs::remove_dir_all(&dir);
        let mut saved = Package::create(&dir, base()).expect("create package");
        for (offset, command) in commands.iter().cloned().enumerate() {
            saved.submit(support::user_meta((offset + 1) as u64), command).expect("replay generated command");
        }
        prop_assert_eq!(saved.project(), source.project());
        for clip in saved.project().tracks.iter().flat_map(|t| &t.clips) {
            // E1: a note-backed clip references no asset (source_id is ""), so
            // there is no placeholder to write — and joining "" would target the
            // audio DIRECTORY itself.
            if clip.is_midi() { continue; }
            fs::write(dir.join("audio").join(&clip.source_id), b"qa-placeholder").expect("asset placeholder");
        }
        Package::save(&dir, &mut saved).expect("first save");
        let first_project = fs::read(dir.join("project.json")).expect("project bytes");
        let first_journal = fs::read(dir.join("journal.jsonl")).expect("journal bytes");
        let mut reopened = Package::open(&dir).expect("reopen package");
        prop_assert_eq!(reopened.project(), saved.project());
        Package::save(&dir, &mut reopened).expect("second save");
        prop_assert_eq!(fs::read(dir.join("project.json")).expect("project bytes"), first_project);
        prop_assert_eq!(fs::read(dir.join("journal.jsonl")).expect("journal bytes"), first_journal);
        prop_assert_eq!(reopened.seq(), next_seq - 1);
        let _ = fs::remove_dir_all(&dir);
    }
}
