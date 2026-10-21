//! CHECKPOINT ROUND-TRIP, ONE COMMAND AT A TIME, ACROSS THE WHOLE CATALOG.
//!
//! # Why this exists
//!
//! `persistence_durability.rs` proves the round-trip with a **hand-written**
//! kitchen sink: 45 commands chosen by a human. That list is the guard that
//! caught `track.setInputChannel` being dropped on every save — and it caught
//! it only because somebody remembered to add the command to the list. A
//! command whose author forgets that step is a command whose state has NO
//! round-trip coverage, and the deep-equality assert over there goes green
//! comparing two projects that never contained the field.
//!
//! Counted rather than assumed: the catalog carries 94 journaled commands and
//! the kitchen sink names 45 of them. **49 journaled commands have never been
//! through a checkpoint round-trip.**
//!
//! So this file drives the round-trip from the *catalog* instead of from a
//! list. For every command in `support::representative_commands()` — which
//! `conformance.rs` already pins to be the complete catalog — it applies that
//! one command to a seeded session and asserts
//! `from_project_json(to_project_json(s)) == *s.project()`.
//!
//! # Seam honesty
//!
//! | Traversed | SKIPPED |
//! |---|---|
//! | `Cmd::apply` -> model -> `to_project_json` -> `from_project_json` | the file, fsync, and the journal chain (that is `persistence_durability.rs`) |
//! | every catalog command, including the ones no human listed | whether the reopened project SOUNDS the same (`agent-surface/tests/persistence_bounce.rs`) |
//!
//! # What it caught
//!
//! `parse_take` had no `"offline"` arm. `take_val` writes `"offline"` for a
//! purged take; the reader's `_ =>` catch-all folded it back to `candidate`.
//! A take the user purged reopened looking AVAILABLE, pointing at audio the
//! purge had already removed, and `take.restore` (precondition: `Offline`)
//! became impossible for the rest of that project's life. Journal replay
//! recovered it, so the loss was visible only through the checkpoint fast
//! path — which is the path `Package::open` takes on every healthy project.
//!
//! # No allow-list
//!
//! All 119 commands apply and all 119 are asserted. There is deliberately no
//! "expected unapplied" list: exempting a command is how a command ends up
//! with no coverage and nothing saying so. Seed `fixture()` instead.

#[path = "support.rs"]
mod support;

use serde_json::{json, Value};
use timeline_core::cmd::Cmd;
use timeline_core::package::{from_project_json, to_project_json};
use timeline_core::session::{MetaSource, SeqMeta, Session};
use timeline_core::tempo::Bpm;
use timeline_core::{Project, TempoMap};

const HASH_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const HASH_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const ULID_A: &str = "01J8Z4G9K2X4Q6R8T0V2W4Y6A8";

/// The fixture, as an ORDERED list of (label, command). Order is dependency
/// order, so "the prefix ending just before label L" is exactly the state in
/// which the command that creates L is legal. That is how a creating command
/// (`track.add trk1`, `fx.add fx1`, …) gets tested with its representative
/// params instead of with ids invented for the test — the representative table
/// is the contract, and a fixture that forced different ids would be testing
/// something the catalog never described.
fn fixture() -> Vec<(&'static str, Cmd)> {
    vec![
        ("trk1", support::cmd("track.add", json!({"trackId": "trk1", "name": "Drums", "index": 0}))),
        ("trk2", support::cmd("track.add", json!({"trackId": "trk2", "name": "Bass", "index": 1}))),
        // A SAMPLER, not a synth: `device.zone.add` is refused on a device that
        // reads no audio, and a zone is the state most at risk of being dropped.
        ("dev1", support::cmd(
            "device.add",
            json!({"trackId": "trk1", "deviceId": "dev1", "kind": "sampler"}),
        )),
        ("z1", support::cmd(
            "device.zone.add",
            json!({"trackId": "trk1", "deviceId": "dev1", "zoneId": "z1",
                   "sourceId": HASH_A, "rootPitch": 60, "loPitch": 0, "hiPitch": 127}),
        )),
        ("devparam", support::cmd(
            "device.param.set",
            json!({"trackId": "trk1", "deviceId": "dev1", "key": "waveform", "value": 3}),
        )),
        ("c1", support::cmd(
            "clip.place",
            json!({"clipId": "c1", "trackId": "trk1", "assetHash": HASH_A,
                   "startTicks": 0, "lengthTicks": 3840}),
        )),
        ("c2", support::cmd(
            "clip.place",
            json!({"clipId": "c2", "trackId": "trk1", "assetHash": HASH_B,
                   "startTicks": 3840, "lengthTicks": 3840}),
        )),
        ("cm1", support::cmd(
            "clip.placeMidi",
            json!({"clipId": "cm1", "trackId": "trk2", "startTicks": 0, "lengthTicks": 3840}),
        )),
        ("notes", support::cmd(
            "note.add",
            json!({"clipId": "cm1", "notes": [
                {"noteId": "nt1", "startTicks": 0, "lengthTicks": 480, "pitch": 60, "velocity": 100},
                {"noteId": "nt2", "startTicks": 960, "lengthTicks": 480, "pitch": 64, "velocity": 90}
            ]}),
        )),
        ("ap1", support::cmd(
            "autopoint.add",
            json!({"trackId": "trk1", "target": "track.volume", "pointId": "ap1",
                   "positionTicks": 0, "value": 0}),
        )),
        ("grp1", support::cmd(
            "route.node.add",
            json!({"nodeId": "grp1", "kind": "group", "name": "Drums Bus"}),
        )),
        ("e1", support::cmd(
            "route.connect",
            json!({"edgeId": "e1", "from": "track.trk1", "to": "bus.grp1",
                   "level": 1, "tap": "post"}),
        )),
        ("fx1", support::cmd(
            "fx.add",
            json!({"target": "track.trk1", "fxId": "fx1", "kind": "compressor"}),
        )),
        ("fxbus", support::cmd(
            "fx.add",
            json!({"target": "bus.grp1", "fxId": "fx1", "kind": "reverb"}),
        )),
        ("fxmaster", support::cmd(
            "fx.add",
            json!({"target": "master", "fxId": "fx1", "kind": "limiter"}),
        )),
        ("fxparam", support::cmd(
            "fx.param.set",
            json!({"target": "master", "fxId": "fx1", "key": "threshold", "value": -18}),
        )),
        ("sec1", support::cmd(
            "section.set",
            json!({"sectionId": "sec1", "name": "Verse", "startTicks": 0}),
        )),
        ("mk1", support::cmd(
            "marker.set",
            json!({"markerId": "mk1", "positionTicks": 960, "label": "drop"}),
        )),
        ("tk1", support::cmd(
            "gen.landed",
            json!({"requestId": ULID_A, "sourceCommand": "gen.song", "takeId": "tk1",
                   "assetHashes": {"mix": HASH_B},
                   "engineIdentity": {"model": "acestep-v15", "device": "mlx"}}),
        )),
        ("sidechain", support::cmd(
            "fx.sidechain.set",
            json!({"target": "bus.grp1", "fxId": "fx1", "source": "track.trk1"}),
        )),
        // The take state machine, walked in full so every take verb has a
        // legal starting state somewhere in this list:
        // Candidate -> (purge) Offline -> (restore) Candidate -> (promote)
        // Promoted -> (discard) Candidate.
        ("purged", support::cmd("take.purge", json!({"takeId": "tk1"}))),
        ("restored", support::cmd("take.restore", json!({"takeId": "tk1"}))),
        ("promoted", support::cmd(
            "take.promote",
            json!({"takeId": "tk1", "targetClipId": "c1"}),
        )),
    ]
}

/// Where in the fixture a command needs the world to stop. A command that
/// CREATES an object runs against the prefix that stops just short of that
/// object; a command that needs an empty slot or an earlier take state names
/// the step that would fill it. Everything else runs against the whole fixture.
///
/// This exists so each command is exercised with the params the CATALOG
/// publishes. Inventing fresh ids per command would make every call apply and
/// prove nothing about the representative table the agent surface actually
/// describes.
fn fixture_stop(name: &str) -> Option<&'static str> {
    Some(match name {
        "track.add" => "trk1",
        // trk1 must still be empty of clips to be removable.
        "track.remove" => "c1",
        "device.add" => "dev1",
        "device.zone.add" => "z1",
        "clip.place" => "c1",
        // The representative places a note clip on trk1 at [0, 3840) — c1's
        // slot — and the representative move/duplicate land on c2's.
        "clip.placeMidi" => "c1",
        "clip.move" => "c2",
        // c1 carries the promoted take in the full fixture, and a clip under a
        // promoted take is deliberately not removable.
        "clip.remove" => "promoted",
        "clip.duplicate" => "c2",
        "note.add" => "notes",
        "autopoint.add" => "ap1",
        "route.node.add" => "grp1",
        "route.connect" => "e1",
        "fx.add" => "fx1",
        "fx.sidechain.set" => "sidechain",
        "gen.landed" => "tk1",
        // Take verbs, each at the state that makes it legal.
        "take.purge" => "purged",
        "take.restore" => "restored",
        "take.promote" => "promoted",
        _ => return None,
    })
}

/// The fixture applied up to (but not including) `stop_before`, together with
/// the meta source positioned AFTER it. Handing the caller a fresh `SeqMeta`
/// instead would mint an entry id the fixture already journaled, and the
/// session would treat the command under test as an idempotent duplicate — a
/// silent `mutated: false` that makes the whole sweep vacuous.
fn seeded(stop_before: Option<&str>) -> (Session, SeqMeta) {
    let mut s = Session::new(Project::new(
        48_000,
        TempoMap::single(Bpm::from_int(120).unwrap()),
    ));
    let mut meta = SeqMeta::user("aaron");
    for (label, c) in fixture() {
        if Some(label) == stop_before {
            break;
        }
        let m = meta.next_meta(&c);
        s.submit(m, c)
            .unwrap_or_else(|e| panic!("fixture step {label} must apply: {e}"));
    }
    (s, meta)
}

#[test]
fn every_catalog_command_survives_the_checkpoint_round_trip() {
    let reps = support::representative_commands();
    let reps_len = reps.len();
    assert!(
        reps.len() >= 119,
        "the representative table must be the whole catalog, got {}",
        reps.len()
    );

    let mut mutating = 0usize;
    let mut mutating_names: Vec<&str> = Vec::new();
    let mut norecord_names: Vec<&str> = Vec::new();
    let mut unapplied: Vec<(String, String)> = Vec::new();
    let mut failures: Vec<String> = Vec::new();

    for (name, params) in reps {
        let cmd = match Cmd::from_wire(name, params) {
            Ok(c) => c,
            Err(e) => {
                unapplied.push((name.to_string(), format!("does not parse: {e}")));
                continue;
            }
        };
        let (mut s, mut meta) = seeded(fixture_stop(name));
        // `txn.commit` is the one verb whose precondition is a session state
        // rather than a model object.
        if name == "txn.commit" {
            let begin = support::cmd("txn.begin", json!({"txnId": "txn1", "reason": "drag"}));
            let m = meta.next_meta(&begin);
            s.submit(m, begin).expect("txn.begin opens");
        }
        let m = meta.next_meta(&cmd);
        // The import verbs are refused by `submit` on purpose: the host owns
        // the inverse of the material they place. Submitting them the way the
        // host does keeps them inside the sweep instead of quietly outside it.
        let submitted = if name.starts_with("import.") {
            let undo = support::cmd("clip.remove", json!({"clipId": "c1"}));
            s.submit_with_hint(m, cmd, undo.clone(), vec![undo])
        } else {
            s.submit(m, cmd)
        };
        match submitted {
            Err(e) => {
                unapplied.push((name.to_string(), e.to_string()));
                continue;
            }
            Ok(out) => {
                if !out.mutated {
                    // A legal no-op (transport, midi routing, a request that
                    // lands later). It cannot lose state it never wrote, but
                    // the round-trip is still asserted below.
                    norecord_names.push(name);
                } else {
                    mutating += 1;
                    mutating_names.push(name);
                }
            }
        }
        let ckpt = to_project_json(&s);
        match from_project_json(&ckpt) {
            Err(e) => failures.push(format!("{name}: checkpoint does not read back: {e}")),
            Ok(back) => {
                if &back != s.project() {
                    failures.push(format!(
                        "{name}: state does NOT survive the checkpoint round-trip\n\
                         {}",
                        first_difference(s.project(), &back)
                    ));
                }
            }
        }
    }

    // Every catalog command applies. There is deliberately NO allow-list here:
    // a command exempted from the sweep is a command with no round-trip
    // coverage, and an allow-list is how that becomes permanent and invisible.
    // Seed `fixture()` for the new command instead.
    assert!(
        unapplied.is_empty(),
        "{} catalog command(s) could not be applied to the fixture, so they \
         have NO round-trip coverage. Seed `fixture()` (and `fixture_stop`) so \
         they can run:\n{}",
        unapplied.len(),
        unapplied
            .iter()
            .map(|(n, e)| format!("  {n}: {e}"))
            .collect::<Vec<_>>()
            .join("\n")
    );

    assert!(
        mutating >= 70,
        "vacuous-pass guard: only {mutating} commands actually mutated the \
         model, so the round-trip below compared mostly-empty projects"
    );

    // Printed rather than merely counted: the next sweep needs to see WHICH
    // commands this file covers without re-deriving it.
    if std::env::var("MSTUDIO_ROUNDTRIP_LIST").is_ok() {
        println!("MUTATING: {}", mutating_names.join(" "));
        println!("RECORD-ONLY: {}", norecord_names.join(" "));
    }
    println!(
        "checkpoint round-trip: {} catalog commands, {} mutated the model, \
         {} unapplied ({})",
        reps_len,
        mutating,
        unapplied.len(),
        unapplied
            .iter()
            .map(|(n, _)| n.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    );

    assert!(
        failures.is_empty(),
        "{} command(s) lose state across the checkpoint:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

/// A readable first-difference between two projects, so a failure names the
/// field rather than dumping two whole models.
fn first_difference(a: &Project, b: &Project) -> String {
    let ja = serde_json::to_value(a).unwrap();
    let jb = serde_json::to_value(b).unwrap();
    let mut out = String::new();
    diff_into(&ja, &jb, "project", &mut out);
    if out.is_empty() {
        out.push_str("  (serde views agree; the difference is in a field serde skips)");
    }
    out
}

fn diff_into(a: &Value, b: &Value, path: &str, out: &mut String) {
    if a == b || out.len() > 4000 {
        return;
    }
    match (a, b) {
        (Value::Object(ma), Value::Object(mb)) => {
            let mut keys: Vec<&String> = ma.keys().chain(mb.keys()).collect();
            keys.sort();
            keys.dedup();
            for k in keys {
                let av = ma.get(k).unwrap_or(&Value::Null);
                let bv = mb.get(k).unwrap_or(&Value::Null);
                diff_into(av, bv, &format!("{path}.{k}"), out);
            }
        }
        (Value::Array(va), Value::Array(vb)) if va.len() == vb.len() => {
            for (i, (x, y)) in va.iter().zip(vb).enumerate() {
                diff_into(x, y, &format!("{path}[{i}]"), out);
            }
        }
        _ => {
            out.push_str(&format!("  {path}: saved={a}  reloaded={b}\n"));
        }
    }
}
