//! PROJECT PERSISTENCE: the journal actually reaches disk, a save does not
//! orphan the sink, and a reopened project is the SAME project.
//!
//! # The defect these tests exist for
//!
//! A 92-note performance, a day of arranging, and `journal.jsonl` was 0 bytes
//! with an mtime from the day the package was created. Three independent
//! faults stacked up, every one of them invisible to the suite that was
//! already green:
//!
//! 1. `Session::resume` (and therefore EVERY `Package::open`) constructed the
//!    session with a `MemoryJournal`. Only the very first launch of a package
//!    — the `Package::create` path — ever had a file sink. Reopen the project
//!    and the journal was RAM, permanently.
//! 2. `FileJournal::append` wrote into a `BufWriter` and nothing ever called
//!    `sync()` (zero call sites in the whole engine). AppKit tears the process
//!    down with `exit()`, which never runs `Drop` on the host the app holds in
//!    a `static`, so even the create-path buffer evaporated.
//! 3. `Package::save` renames a fresh `journal.jsonl` over the old one. The
//!    session's fd still pointed at the unlinked inode, so every command after
//!    the first save wrote into a file nothing could ever open.
//!
//! # Seam honesty
//!
//! | Traversed | SKIPPED |
//! |---|---|
//! | `Session::submit` -> `FileJournal` -> real bytes in a real file | the FFI, `StudioHost`, and the Swift app's save affordance |
//! | `Package::save` / `Package::open` / checkpoint fast path / full replay | whether the reopened project SOUNDS the same (that is `agent-surface/tests/persistence_bounce.rs`) |
//!
//! Nothing here asserts on an in-memory `session.journal()` where the point is
//! the FILE: every durability claim reads `journal.jsonl` off the disk with a
//! fresh `fs::read`, because the whole bug class was "the model was right and
//! the file was empty".

#[path = "support.rs"]
mod support;

use std::path::PathBuf;

use serde_json::{json, Value};
use timeline_core::catalog::Catalog;
use timeline_core::cmd::Cmd;
use timeline_core::envelope::Actor;
use timeline_core::package::{to_project_json, Package};
use timeline_core::session::{MetaSource, SeqMeta, Session};
use timeline_core::tempo::Bpm;
use timeline_core::{Project, TempoMap};

fn tmp(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "mstudio_persist_{name}_{}_{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

fn base() -> Project {
    Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()))
}

/// Validate against the embedded catalog FIRST, exactly as live submit does,
/// so no test here can build params the contract boundary would reject.
fn cmd(name: &str, params: Value) -> Cmd {
    Catalog::get()
        .validate_params(name, &params)
        .unwrap_or_else(|e| panic!("{name} params invalid: {e}"));
    Cmd::from_wire(name, params).unwrap_or_else(|e| panic!("{name}: {e}"))
}

/// A meta source that continues where the reopened journal left off. Reusing
/// `SeqMeta::user` after a reopen mints ids the replayed journal already
/// contains, and `Session` correctly treats those as idempotent duplicates --
/// which would make every "did the reopened session journal?" assertion below
/// vacuous. The live host mints ULIDs and has no such collision.
fn continuing(session: &Session) -> SeqMeta {
    SeqMeta::starting_at(session.seq() + 1, Actor::user("aaron"))
}

/// Put the referenced assets under `audio/` so `mark_offline` does not flip
/// `Clip::offline` on reopen. That flag is engine truth about the FILE, not a
/// round-trip loss, but leaving it to chance would make a deep-equality assert
/// fail for a reason that has nothing to do with persistence.
fn seed_assets(dir: &PathBuf, hashes: &[&str]) {
    let audio = dir.join("audio");
    std::fs::create_dir_all(&audio).unwrap();
    for h in hashes {
        std::fs::write(audio.join(format!("{h}.wav")), b"RIFF").unwrap();
    }
}

fn submit_all(session: &mut Session, meta: &mut SeqMeta, cmds: Vec<Cmd>) {
    for c in cmds {
        session
            .submit(meta.next_meta(&c), c.clone())
            .unwrap_or_else(|e| panic!("submit {}: {e}", c.name()));
    }
}

/// Non-empty lines actually present in `journal.jsonl` ON DISK. Never the
/// in-memory journal — that is the thing that lied.
fn journal_lines_on_disk(dir: &PathBuf) -> Vec<String> {
    std::fs::read_to_string(dir.join("journal.jsonl"))
        .unwrap_or_default()
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(String::from)
        .collect()
}

// ---------------------------------------------------------------------------
// 1. Fault #2: an appended command is on disk BEFORE anything asks for a save.
// ---------------------------------------------------------------------------

#[test]
fn every_command_reaches_the_file_without_a_save_or_a_drop() {
    let dir = tmp("append");
    let mut session = Package::create(&dir, base()).unwrap();
    let mut meta = SeqMeta::user("aaron");

    submit_all(
        &mut session,
        &mut meta,
        vec![cmd("track.add", json!({"trackId": "t1", "name": "Drums"}))],
    );

    // Read the file while the session is still ALIVE and no save has happened.
    // Under the old BufWriter this was 0 bytes, which is exactly what the user
    // found after a day of work.
    let lines = journal_lines_on_disk(&dir);
    assert_eq!(
        lines.len(),
        1,
        "one submitted command must be one line in journal.jsonl BEFORE any \
         save and WITHOUT relying on Drop; got {lines:?}"
    );
    assert!(lines[0].contains("track.add"));

    // And it keeps holding as the session grows past the old 8 KiB buffer edge
    // in BOTH directions (a small session is the case that used to vanish).
    for i in 0..40 {
        submit_all(
            &mut session,
            &mut meta,
            vec![cmd(
                "track.add",
                json!({"trackId": format!("t{}", i + 2), "name": format!("T{i}")}),
            )],
        );
    }
    assert_eq!(journal_lines_on_disk(&dir).len(), 41);
    let _ = std::fs::remove_dir_all(&dir);
}

// ---------------------------------------------------------------------------
// 2. Fault #1: a REOPENED project journals to the file, not to RAM.
// ---------------------------------------------------------------------------

#[test]
fn a_reopened_project_still_journals_to_disk() {
    let dir = tmp("reopen_sink");
    {
        let mut session = Package::create(&dir, base()).unwrap();
        let mut meta = SeqMeta::user("aaron");
        submit_all(
            &mut session,
            &mut meta,
            vec![cmd("track.add", json!({"trackId": "t1", "name": "Drums"}))],
        );
        Package::save(&dir, &mut session).unwrap();
    }

    // Session 2: the shape of every launch after the first.
    let mut session = Package::open(&dir).unwrap();
    let mut meta = continuing(&session);
    submit_all(
        &mut session,
        &mut meta,
        vec![cmd("track.add", json!({"trackId": "t2", "name": "Bass"}))],
    );
    assert_eq!(
        journal_lines_on_disk(&dir).len(),
        2,
        "a command issued in a REOPENED package must land in journal.jsonl; \
         Session::resume used to hand back a MemoryJournal, so it landed in RAM \
         and died with the process"
    );

    // Session 3: prove it by reopening WITHOUT a save. This is the exact user
    // flow — work, then quit — and the work has to come back.
    drop(session);
    let third = Package::open(&dir).unwrap();
    assert_eq!(third.project().tracks.len(), 2, "both tracks survive a quit");
    assert!(third.project().tracks.iter().any(|t| t.id == "t2"));
    let _ = std::fs::remove_dir_all(&dir);
}

// ---------------------------------------------------------------------------
// 3. Fault #3: work done AFTER a save survives.
// ---------------------------------------------------------------------------

#[test]
fn commands_after_a_save_are_not_written_into_an_unlinked_file() {
    let dir = tmp("after_save");
    let mut session = Package::create(&dir, base()).unwrap();
    let mut meta = SeqMeta::user("aaron");

    submit_all(
        &mut session,
        &mut meta,
        vec![cmd("track.add", json!({"trackId": "t1", "name": "Drums"}))],
    );
    Package::save(&dir, &mut session).unwrap();

    // Package::save renamed a NEW journal.jsonl into place. Without reattaching
    // the sink, this next command goes to the orphaned inode and is lost.
    submit_all(
        &mut session,
        &mut meta,
        vec![
            cmd("track.add", json!({"trackId": "t2", "name": "Bass"})),
            cmd("mix.gain", json!({"trackId": "t2", "gainDb": -3})),
        ],
    );
    assert_eq!(
        journal_lines_on_disk(&dir).len(),
        3,
        "post-save commands must append to the CURRENT journal.jsonl"
    );

    drop(session);
    let reopened = Package::open(&dir).unwrap();
    assert_eq!(reopened.project().tracks.len(), 2);
    assert_eq!(reopened.seq(), 3);
    let _ = std::fs::remove_dir_all(&dir);
}

// ---------------------------------------------------------------------------
// 4. Atomicity: a save NEVER destroys the last good file.
//
//    Simulated by leaving a stale `.tmp` and a truncated checkpoint behind and
//    proving open still recovers; the real kill-during-save is
//    `package_crash.rs::kill9_mid_save_recovers_to_last_journaled_command`,
//    which this suite deliberately does not duplicate.
// ---------------------------------------------------------------------------

#[test]
fn a_torn_checkpoint_never_costs_a_journaled_command() {
    let dir = tmp("torn_ckpt");
    let mut session = Package::create(&dir, base()).unwrap();
    let mut meta = SeqMeta::user("aaron");
    submit_all(
        &mut session,
        &mut meta,
        vec![
            cmd("project.setTempo", json!({"bpm": 92})),
            cmd("track.add", json!({"trackId": "t1", "name": "Drums"})),
        ],
    );
    drop(session);

    // Half-written checkpoint + an abandoned tmp from an interrupted save.
    std::fs::write(dir.join("project.json"), b"{ \"formatVersion\": 1, \"tra").unwrap();
    std::fs::write(dir.join("project.json.tmp"), b"garbage").unwrap();

    let reopened = Package::open(&dir).unwrap();
    assert_eq!(reopened.seq(), 2, "full replay recovers both commands");
    assert_eq!(reopened.project().tracks.len(), 1);
    let _ = std::fs::remove_dir_all(&dir);
}

/// THE ATOMICITY ASSERTION.
///
/// The discipline is tmp + fsync + atomic rename: the previous good
/// `project.json` is replaced only by a rename, so a save that fails partway
/// through can never leave a truncated checkpoint behind.
///
/// Proving that deterministically means making the checkpoint write FAIL in the
/// middle, which is what pre-creating `project.json.tmp` as a DIRECTORY does:
/// `File::create` on it returns EISDIR. With the discipline, `save` reports the
/// error and `project.json` is byte-identical to what it was. Without it -- if
/// the writer opened `project.json` directly -- the same call would truncate the
/// only good copy before it wrote a byte, and would report success while having
/// silently rewritten the user's project file.
///
/// (The mutation harness confirms this: reverting `write_checkpoint` to an
/// in-place write turns this test red, and turned nothing else red.)
#[test]
fn a_checkpoint_write_that_cannot_start_leaves_the_previous_file_byte_identical() {
    let dir = tmp("atomicity");
    let mut session = Package::create(&dir, base()).unwrap();
    let mut meta = SeqMeta::user("aaron");
    submit_all(
        &mut session,
        &mut meta,
        vec![
            cmd("track.add", json!({"trackId": "t1", "name": "Drums"})),
            cmd("mix.gain", json!({"trackId": "t1", "gainDb": -6})),
        ],
    );
    Package::save(&dir, &mut session).unwrap();
    let good = std::fs::read(dir.join("project.json")).unwrap();
    assert!(good.len() > 100, "control: a real checkpoint was written");

    // More work, so the next checkpoint would differ from the good one.
    submit_all(
        &mut session,
        &mut meta,
        vec![cmd("track.add", json!({"trackId": "t2", "name": "Bass"}))],
    );

    // Block the temp path. Any writer that goes through it now fails.
    std::fs::create_dir(dir.join("project.json.tmp")).unwrap();
    let result = Package::save(&dir, &mut session);
    assert!(
        result.is_err(),
        "a save whose temp file cannot be created must REPORT failure. If this \
         passes, the checkpoint is being written in place -- which means the \
         previous good project.json was truncated before the first byte landed."
    );
    assert_eq!(
        std::fs::read(dir.join("project.json")).unwrap(),
        good,
        "the previous good checkpoint must be byte-identical after a failed save"
    );

    // And recovery still works: the journal carries the work the failed
    // checkpoint did not.
    let _ = std::fs::remove_dir(dir.join("project.json.tmp"));
    drop(session);
    let reopened = Package::open(&dir).unwrap();
    assert_eq!(
        reopened.project().tracks.len(),
        2,
        "the failed checkpoint cost nothing: the journal replays the newer track"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// A torn FINAL journal line is the ordinary crash signature once every command
/// is written straight through. Losing that one command is recovery; refusing
/// to open is data loss.
///
/// A break EARLIER than the last line used to be REFUSED outright, to keep this
/// from quietly swallowing a rewritten history. That refusal cost the user every
/// command in the file — including all the ones ahead of the break, which chain
/// back to `GENESIS_HASH` and are exactly as authentic as a torn tail's prefix —
/// and on the app's launch path it did not even present as a refusal
/// (`StudioEngineFactory.makeDefault` catches the error and shows a fixture
/// project). So the prefix is now KEPT, the unreachable remainder is counted,
/// and the original bytes are quarantined beside the package. The guard the
/// refusal existed for is preserved by being loud rather than by being fatal:
/// `OpenRecovery` reports exactly how many lines were discarded and where the
/// originals went, and nothing about it is quiet.
#[test]
fn a_torn_final_journal_line_is_recovered_and_a_broken_middle_keeps_its_prefix() {
    let dir = tmp("torn_tail");
    let mut session = Package::create(&dir, base()).unwrap();
    let mut meta = SeqMeta::user("aaron");
    submit_all(
        &mut session,
        &mut meta,
        vec![
            cmd("track.add", json!({"trackId": "t1", "name": "Drums"})),
            cmd("track.add", json!({"trackId": "t2", "name": "Bass"})),
            cmd("track.add", json!({"trackId": "t3", "name": "Keys"})),
        ],
    );
    drop(session);
    let good = journal_lines_on_disk(&dir);
    assert_eq!(good.len(), 3);

    // (a) torn tail: the last write was cut short.
    let torn = format!("{}\n{}\n{}", good[0], good[1], &good[2][..good[2].len() / 2]);
    std::fs::write(dir.join("journal.jsonl"), torn).unwrap();
    let mut recovered = Package::open(&dir).unwrap();
    assert_eq!(recovered.seq(), 2, "recovers to the last INTACT command");
    assert_eq!(recovered.project().tracks.len(), 2);
    // The truncation is persisted, so appending after recovery cannot land
    // behind garbage.
    assert_eq!(journal_lines_on_disk(&dir).len(), 2);
    let mut meta2 = continuing(&recovered);
    submit_all(
        &mut recovered,
        &mut meta2,
        vec![cmd("track.add", json!({"trackId": "t9", "name": "New"}))],
    );
    drop(recovered);
    assert_eq!(Package::open(&dir).unwrap().project().tracks.len(), 3);

    // (b) a break in the MIDDLE is corruption, not a torn write. Keep the
    //     verified prefix, discard what the break made unreachable, and set the
    //     original bytes aside.
    let mangled = format!("{}\n{}\n{}", good[0], good[0], good[2]);
    std::fs::write(dir.join("journal.jsonl"), &mangled).unwrap();
    let _ = std::fs::remove_file(dir.join("project.json"));
    let (salvaged, report) =
        Package::open_reporting(&dir).expect("a broken middle is recoverable, not fatal");
    assert_eq!(
        salvaged.project().tracks.len(),
        1,
        "the one entry that chains from genesis is kept (1, not 3, and not 0)"
    );
    assert_eq!(salvaged.project().tracks[0].name, "Drums");
    assert_eq!(report.corrupt_lines_dropped, 2);
    assert_eq!(report.torn_tail_dropped, 0, "this is corruption, not a torn write");
    assert!(report.is_noteworthy());
    let quarantine = report
        .quarantined_journal
        .as_ref()
        .expect("the bytes we could not chain-verify are set aside, never deleted");
    assert_eq!(
        std::fs::read(quarantine).unwrap(),
        mangled.as_bytes(),
        "the quarantine is the original file, byte for byte"
    );
    assert_eq!(journal_lines_on_disk(&dir).len(), 1);
    let _ = std::fs::remove_dir_all(&dir);
}

// ---------------------------------------------------------------------------
// 5. THE LOAD-BEARING TEST.
//
//    A project carrying EVERY feature the engine models, saved, reopened, and
//    compared for DEEP EQUALITY. A round-trip that loses one fx param or one
//    routing edge is the silent-degradation class this exists to catch, so the
//    assertion is `==` on the whole `Project`, not a field checklist that a
//    later field can quietly fall out of.
// ---------------------------------------------------------------------------

/// Every modelled feature, built through catalog commands exactly as the app
/// builds it. Returns the command list so the same script can drive the render
/// side (`agent-surface/tests/persistence_bounce.rs`).
pub fn kitchen_sink_commands() -> Vec<Cmd> {
    let asset_a = "a".repeat(64);
    let asset_b = "b".repeat(64);
    vec![
        // --- project identity / tempo / meter / key / phase anchor ---
        cmd("project.setTempo", json!({"bpm": 92})),
        cmd("project.setTimeSig", json!({"numerator": 7, "denominator": 8})),
        cmd("project.setKey", json!({"key": "A minor"})),
        cmd("project.setPhaseAnchor", json!({"anchorTicks": 480})),
        cmd(
            "section.set",
            json!({"sectionId": "s1", "name": "Chorus", "startTicks": 3840, "color": "#12AB34"}),
        ),
        cmd(
            "marker.set",
            json!({"markerId": "m1", "positionTicks": 1920, "label": "drop", "color": "#FF0000"}),
        ),
        // --- tracks + every track-level property ---
        cmd("track.add", json!({"trackId": "t1", "name": "Drums", "index": 0})),
        cmd("track.add", json!({"trackId": "t2", "name": "Bass", "index": 1})),
        cmd("track.add", json!({"trackId": "t3", "name": "Keys", "index": 2})),
        cmd("track.setColor", json!({"trackId": "t1", "color": "#E05252"})),
        cmd("track.setHeight", json!({"trackId": "t1", "heightPx": 137})),
        cmd("track.mute", json!({"trackId": "t2", "muted": true})),
        cmd("track.solo", json!({"trackId": "t1", "soloed": true})),
        cmd("track.arm", json!({"trackId": "t3", "armed": true})),
        // The four-input case, and the reason this list is the guard it is:
        // `track.setInputChannel` shipped with a model field, a catalog
        // command, a tool and a capture path, and was never added HERE — so the
        // deep-equality round-trip below had nothing to compare and the value
        // was silently dropped on every save. Two tracks, two different
        // channels, neither of them the default.
        cmd("track.setInputChannel", json!({"trackId": "t2", "channel": 1})),
        cmd("track.setInputChannel", json!({"trackId": "t3", "channel": 3})),
        // --- mixer: gain, pan, all four EQ bands, both sends, master, limiter ---
        cmd("mix.gain", json!({"trackId": "t1", "gainDb": -3.5})),
        cmd("mix.pan", json!({"trackId": "t1", "pan": -0.25})),
        cmd("mix.eq", json!({"trackId": "t1", "band": 0, "freqHz": 80, "gainDb": 4, "q": 0.7})),
        cmd("mix.eq", json!({"trackId": "t1", "band": 1, "freqHz": 400, "gainDb": -2.5, "q": 1.2})),
        cmd("mix.eq", json!({"trackId": "t1", "band": 2, "freqHz": 2500, "gainDb": 3, "q": 2})),
        cmd("mix.eq", json!({"trackId": "t1", "band": 3, "freqHz": 9000, "gainDb": -1, "q": 0.5})),
        cmd("mix.send", json!({"trackId": "t1", "bus": "a", "amount": 0.35})),
        cmd("mix.send", json!({"trackId": "t2", "bus": "b", "amount": 0.6})),
        cmd("mix.master.gain", json!({"gainDb": -1.5})),
        cmd(
            "mix.limiter.set",
            json!({"enabled": true, "ceilingDb": -0.3, "releaseMs": 120}),
        ),
        // --- audio clips + every clip property ---
        cmd(
            "clip.place",
            json!({"clipId": "c1", "trackId": "t1", "assetHash": asset_a,
                   "startTicks": 0, "lengthTicks": 3840, "sourceOffsetTicks": 240}),
        ),
        cmd(
            "clip.place",
            json!({"clipId": "c2", "trackId": "t1", "assetHash": asset_b,
                   "startTicks": 3840, "lengthTicks": 3840}),
        ),
        cmd("clip.setGain", json!({"clipId": "c1", "gainDb": -4})),
        cmd("clip.mute", json!({"clipId": "c2", "muted": true})),
        cmd("clip.rename", json!({"clipId": "c1", "name": "Verse loop"})),
        cmd(
            "clip.fade.set",
            json!({"clipId": "c1", "edge": "in", "lengthTicks": 240, "shape": "equalPower"}),
        ),
        cmd(
            "clip.fade.set",
            json!({"clipId": "c1", "edge": "out", "lengthTicks": 480, "shape": "logarithmic"}),
        ),
        cmd(
            "clip.crossfade.set",
            json!({"clipIdA": "c1", "clipIdB": "c2", "lengthTicks": 240, "shape": "linear"}),
        ),
        cmd(
            "clip.warp.set",
            json!({"clipId": "c2", "mode": "ratio", "stretchRatio": 1.25}),
        ),
        cmd("clip.phaseAnchor.set", json!({"clipId": "c2", "anchorTicks": 120})),
        // --- MIDI clip + notes (the 92-note performance's shape) ---
        cmd(
            "clip.placeMidi",
            json!({"clipId": "cm1", "trackId": "t3", "startTicks": 0, "lengthTicks": 7680}),
        ),
        cmd(
            "note.add",
            json!({"clipId": "cm1", "notes": (0..24).map(|i| json!({
                "noteId": format!("n{i:02}"),
                "startTicks": i as u64 * 240,
                "lengthTicks": 200,
                "pitch": 48 + (i as u64 % 12) as u8,
                "velocity": 64 + (i % 40),
            })).collect::<Vec<_>>()}),
        ),
        // --- devices + sampler zones ---
        cmd("device.add", json!({"trackId": "t3", "deviceId": "dev1", "kind": "sampler"})),
        cmd(
            "device.zone.add",
            json!({"trackId": "t3", "deviceId": "dev1", "zoneId": "z1", "sourceId": asset_a,
                   "rootPitch": 60, "loPitch": 48, "hiPitch": 72, "gainDb": -2, "pan": 0.4}),
        ),
        cmd(
            "device.zone.add",
            json!({"trackId": "t3", "deviceId": "dev1", "zoneId": "z2", "sourceId": asset_b,
                   "rootPitch": 36, "loPitch": 24, "hiPitch": 47}),
        ),
        // --- routing: nodes, edges, taps, bus faders ---
        cmd("route.node.add", json!({"nodeId": "busRev", "kind": "bus", "name": "Reverb"})),
        cmd("route.node.add", json!({"nodeId": "grpDrums", "kind": "group", "name": "Drum Bus"})),
        cmd(
            "route.connect",
            json!({"edgeId": "e1", "from": "track.t1", "to": "bus.grpDrums",
                   "level": 1, "tap": "post"}),
        ),
        cmd(
            "route.connect",
            json!({"edgeId": "e2", "from": "bus.grpDrums", "to": "master",
                   "level": 0.8, "tap": "post"}),
        ),
        cmd(
            "route.connect",
            json!({"edgeId": "e3", "from": "track.t2", "to": "bus.busRev",
                   "level": 0.25, "tap": "pre"}),
        ),
        cmd(
            "route.connect",
            json!({"edgeId": "e4", "from": "bus.busRev", "to": "master",
                   "level": 0.9, "tap": "post"}),
        ),
        cmd("route.edge.set", json!({"edgeId": "e3", "level": 0.42, "tap": "pre"})),
        cmd("route.node.set", json!({"nodeId": "grpDrums", "gainDb": -2.5})),
        cmd("route.node.set", json!({"nodeId": "busRev", "gainDb": -6})),
        // --- fx chains on all three host kinds, with params + sidechain ---
        cmd("fx.add", json!({"target": "track.t1", "fxId": "fxComp", "kind": "compressor"})),
        cmd("fx.add", json!({"target": "track.t1", "fxId": "fxSat", "kind": "saturator"})),
        cmd("fx.add", json!({"target": "bus.busRev", "fxId": "fxVerb", "kind": "reverb"})),
        cmd("fx.add", json!({"target": "master", "fxId": "fxLim", "kind": "limiter"})),
        cmd("fx.param.set", json!({"target": "track.t1", "fxId": "fxComp", "key": "threshold", "value": -18})),
        cmd("fx.param.set", json!({"target": "track.t1", "fxId": "fxComp", "key": "ratio", "value": 4})),
        cmd("fx.param.set", json!({"target": "track.t1", "fxId": "fxComp", "key": "attack", "value": 12.5})),
        cmd("fx.param.set", json!({"target": "track.t1", "fxId": "fxSat", "key": "mix", "value": 0.3})),
        cmd("fx.param.set", json!({"target": "bus.busRev", "fxId": "fxVerb", "key": "mix", "value": 0.45})),
        cmd("fx.param.set", json!({"target": "master", "fxId": "fxLim", "key": "threshold", "value": -0.5})),
        cmd("fx.move", json!({"target": "track.t1", "fxId": "fxSat", "index": 0})),
        cmd(
            "fx.sidechain.set",
            json!({"target": "track.t1", "fxId": "fxComp", "source": "track.t2"}),
        ),
        // --- automation lanes: reserved spellings AND an fx/bus param path ---
        cmd("autolane.show", json!({"trackId": "t1", "target": "track.volume", "visible": true})),
        cmd(
            "autopoint.add",
            json!({"trackId": "t1", "target": "track.volume", "pointId": "p1",
                   "positionTicks": 0, "value": -6}),
        ),
        cmd(
            "autopoint.add",
            json!({"trackId": "t1", "target": "track.volume", "pointId": "p2",
                   "positionTicks": 1920, "value": 0}),
        ),
        cmd(
            "autopoint.add",
            json!({"trackId": "t1", "target": "track.pan", "pointId": "p3",
                   "positionTicks": 960, "value": 0.5}),
        ),
        cmd(
            "autopoint.add",
            json!({"trackId": "t1", "target": "track.fx.fxComp.threshold", "pointId": "p4",
                   "positionTicks": 480, "value": -24}),
        ),
        cmd(
            "autopoint.move",
            json!({"trackId": "t1", "target": "track.volume", "pointId": "p2",
                   "positionTicks": 2400, "value": 1.5}),
        ),
        // --- takes ---
        cmd(
            "gen.landed",
            json!({"requestId": "01ARZ3NDEKTSV4RRFFQ69G5FAV", "sourceCommand": "gen.song",
                   "takeId": "tk1", "assetHashes": {"mix": asset_a},
                   "engineIdentity": {"model": "ace-step", "device": "mlx", "steps": 60, "seed": 7},
                   "latencySeconds": 12.5}),
        ),
        cmd(
            "gen.landed",
            json!({"requestId": "01ARZ3NDEKTSV4RRFFQ69G5FAW", "sourceCommand": "gen.layer",
                   "takeId": "tk2", "assetHashes": {"drums": asset_b},
                   "engineIdentity": {"model": "ace-step", "device": "cpu"}}),
        ),
        cmd("take.promote", json!({"takeId": "tk1", "targetClipId": "c1"})),
        // Promote-then-discard so BOTH take states (promoted, un-promoted) are
        // present in the saved project: v1 journals a discard only as an
        // un-promote, so a bare discard on a candidate is refused.
        cmd("take.promote", json!({"takeId": "tk2", "targetClipId": "c2"})),
        cmd("take.discard", json!({"takeId": "tk2"})),
        // ...and then PURGE it, so the fourth take status (`Offline`) is in the
        // saved project too. `parse_take` had no `"offline"` arm and folded the
        // status back to `candidate` on every reopen: the take the user purged
        // came back looking available, pointing at audio the purge removed.
        cmd("take.purge", json!({"takeId": "tk2"})),
    ]
}

/// Build the kitchen-sink package on disk and return the directory.
pub fn build_kitchen_sink(dir: &PathBuf) -> Session {
    // A non-default project NAME, so the checkpoint's `name` key carries state.
    // The mutation canary below caught this: with the default "Untitled" the
    // key was present but droppable without effect, which is indistinguishable
    // from a reader that ignores it.
    let mut shell = base();
    shell.name = "Kitchen Sink".to_string();
    let mut session = Package::create(dir, shell).unwrap();
    seed_assets(dir, &[&"a".repeat(64), &"b".repeat(64)]);
    let mut meta = SeqMeta::user("aaron");
    submit_all(&mut session, &mut meta, kitchen_sink_commands());
    session
}

#[test]
fn every_modelled_feature_survives_save_and_reopen() {
    let dir = tmp("kitchen_sink");
    let mut session = build_kitchen_sink(&dir);

    // Guard against a vacuous pass: if the builder silently stopped applying
    // things, the deep-equality assert below would compare two empty projects
    // and go green. Pin the shape first.
    {
        let p = session.project();
        assert_eq!(p.tracks.len(), 3, "tracks");
        assert_eq!(p.tracks[0].clips.len(), 2, "audio clips on t1");
        assert_eq!(p.tracks[2].clips.len(), 1, "midi clip on t3");
        assert_eq!(p.tracks[2].clips[0].notes.len(), 24, "notes");
        assert_eq!(p.tracks[2].devices.len(), 1, "device");
        assert_eq!(p.tracks[2].devices[0].zones.len(), 2, "sampler zones");
        assert_eq!(p.tracks[0].fx.len(), 2, "track fx chain");
        assert_eq!(p.master.fx.len(), 1, "master fx chain");
        assert_eq!(p.routing.nodes.len(), 2, "routing nodes");
        assert_eq!(p.routing.edges.len(), 4, "routing edges");
        assert_eq!(p.takes.len(), 2, "takes");
        assert!(!p.tracks[0].automation.lanes.is_empty() || !p.tracks[0].automation.volume.is_empty());
        assert_eq!(p.phase_anchor_ticks, 480);
        assert_eq!(p.sections.len(), 1);
        assert_eq!(p.markers.len(), 1);
    }

    let before = session.project().clone();
    let before_seq = session.seq();
    let before_tip = session.tip_hash().to_string();
    Package::save(&dir, &mut session).unwrap();
    drop(session);

    let reopened = Package::open(&dir).unwrap();

    // DEEP EQUALITY on the whole model. Not a field checklist -- a checklist is
    // exactly how the next field added gets silently dropped.
    assert_eq!(
        reopened.project(),
        &before,
        "the reopened project must be the SAME project"
    );
    assert_eq!(reopened.seq(), before_seq, "journal length preserved");
    assert_eq!(reopened.tip_hash(), before_tip, "hash chain tip preserved");

    let _ = std::fs::remove_dir_all(&dir);
}

/// The same round-trip, but WITHOUT a save: quit-then-relaunch is the flow the
/// user actually performs, and it must not need ceremony to survive.
#[test]
fn every_modelled_feature_survives_a_quit_with_no_save_at_all() {
    let dir = tmp("kitchen_sink_nosave");
    let session = build_kitchen_sink(&dir);
    let before = session.project().clone();
    let before_seq = session.seq();
    // No Package::save. Just walk away, as `exit()` does.
    std::mem::forget(session);

    let reopened = Package::open(&dir).unwrap();
    assert_eq!(
        reopened.project(),
        &before,
        "everything must come back from the journal alone, with no save and \
         with Drop never running"
    );
    assert_eq!(reopened.seq(), before_seq);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Round-trip FIXED POINT: a project written by this build reopens and rewrites
/// byte-identically. `qa_roundtrips.rs` proves this for random command scripts;
/// this pins it for the kitchen sink, where every feature is present at once.
#[test]
fn save_load_save_is_byte_identical_for_the_kitchen_sink() {
    let dir = tmp("fixed_point");
    let mut session = build_kitchen_sink(&dir);
    Package::save(&dir, &mut session).unwrap();
    let first_ckpt = std::fs::read_to_string(dir.join("project.json")).unwrap();
    let first_journal = std::fs::read_to_string(dir.join("journal.jsonl")).unwrap();
    drop(session);

    let mut reopened = Package::open(&dir).unwrap();
    Package::save(&dir, &mut reopened).unwrap();
    let second_ckpt = std::fs::read_to_string(dir.join("project.json")).unwrap();
    let second_journal = std::fs::read_to_string(dir.join("journal.jsonl")).unwrap();

    assert_eq!(first_ckpt, second_ckpt, "project.json is a fixed point");
    assert_eq!(first_journal, second_journal, "journal.jsonl is a fixed point");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The MUTATION CANARY for the writer/reader pair. `to_project_json` and
/// `from_project_json` are hand-written for the additive-bytes reason E5 spells
/// out, which means a new model field can be written and not read (or the
/// reverse) with nothing complaining. Dropping any key from the checkpoint must
/// change the reconstructed project.
#[test]
fn dropping_any_checkpoint_key_changes_the_reconstructed_project() {
    let dir = tmp("mutation_canary");
    let session = build_kitchen_sink(&dir);
    let full = to_project_json(&session);
    let expect = timeline_core::package::from_project_json(&full).unwrap();
    assert_eq!(&expect, session.project(), "control: full checkpoint reads back");

    // Every top-level key except the ones that are pure journal bookkeeping or
    // fixed identity carries state a reader must consume.
    let skip = ["formatVersion", "journal", "projectId", "sampleRateHz", "ppq"];
    let obj = full.as_object().unwrap();
    let mut checked = 0;
    for key in obj.keys() {
        if skip.contains(&key.as_str()) {
            continue;
        }
        let mut mutated = obj.clone();
        mutated.remove(key);
        let got = timeline_core::package::from_project_json(&Value::Object(mutated));
        match got {
            Err(_) => {}
            Ok(p) => assert_ne!(
                &p, &expect,
                "dropping checkpoint key {key:?} produced an IDENTICAL project -- \
                 either the reader ignores it (data loss on reopen) or the \
                 kitchen sink does not exercise it"
            ),
        }
        checked += 1;
    }
    assert!(
        checked >= 8,
        "expected the kitchen sink to populate many top-level keys, checked {checked}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

// ---------------------------------------------------------------------------
// 6. v1.1 compatibility: an older project must still open on this build.
// ---------------------------------------------------------------------------

#[test]
fn a_v1_1_era_project_still_opens() {
    let dir = tmp("v1_1");
    let mut session = Package::create(&dir, base()).unwrap();
    seed_assets(&dir, &[&"a".repeat(64)]);
    let mut meta = SeqMeta::user("aaron");
    // Only v1/v1.1 verbs: no routing, no fx, no devices, no notes.
    submit_all(
        &mut session,
        &mut meta,
        vec![
            cmd("project.setTempo", json!({"bpm": 128})),
            cmd("track.add", json!({"trackId": "t1", "name": "Drums"})),
            cmd(
                "clip.place",
                json!({"clipId": "c1", "trackId": "t1", "assetHash": "a".repeat(64),
                       "startTicks": 0, "lengthTicks": 1920}),
            ),
            cmd("mix.gain", json!({"trackId": "t1", "gainDb": -2})),
        ],
    );
    Package::save(&dir, &mut session).unwrap();
    let before = session.project().clone();
    drop(session);

    // Strip every post-v1.1 key from the checkpoint, the way a project written
    // by the older build would look on disk, and re-open.
    let mut ckpt: Value =
        serde_json::from_str(&std::fs::read_to_string(dir.join("project.json")).unwrap()).unwrap();
    let o = ckpt.as_object_mut().unwrap();
    for k in ["engineRouting", "phaseAnchorTicks", "takes", "masterBus"] {
        o.remove(k);
    }
    std::fs::write(
        dir.join("project.json"),
        serde_json::to_string_pretty(&ckpt).unwrap(),
    )
    .unwrap();

    let reopened = Package::open(&dir).unwrap();
    assert_eq!(
        reopened.project(),
        &before,
        "a v1.1-shaped checkpoint must open and reconstruct via journal replay"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
