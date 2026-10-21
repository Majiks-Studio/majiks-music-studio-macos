//! THE JOURNAL IS THE PROJECT — reopening one must never destroy it.
//!
//! The defect these pin: `StudioHost::open_or_create` decided whether a package
//! existed by looking at `project.json` ALONE, and `Package::create` opens the
//! journal with `File::create`, which truncates. A package with an intact
//! `journal.jsonl` and a missing checkpoint is a fully recoverable project, and
//! the app's every-launch path answered it by overwriting the truth with an
//! empty file. No warning, no backup, nothing to undo.
//!
//! WHAT IS ASSERTED, AND WHY IT IS ASSERTED THAT WAY
//!
//! Not "no error was returned", and not a count. The fixtures below name three
//! tracks the assertions do not otherwise mention ("Drums", "Bass", "Keys") and
//! move a clip to a tick nothing else supplies, so a recovery that returned an
//! empty project, a default project, or a project of the right SIZE would fail.
//! And every one of them re-reads `journal.jsonl` and compares its BYTES to what
//! was on disk before the reopen — because the failure mode is a file being
//! silently emptied, and a session that looks right in memory proves nothing
//! about the file the next launch will read.
//!
//! Temp dirs are namespaced by process id: a shared fixture path once had ~30
//! worktrees fighting over one directory.

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::json;

use agent_surface::StudioHost;
use timeline_core::Actor;

fn tmp(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "majiks-journal-recovery-{}-{name}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn journal_bytes(pkg: &Path) -> Vec<u8> {
    fs::read(pkg.join("journal.jsonl")).expect("journal.jsonl")
}

fn track_names(host: &StudioHost) -> Vec<String> {
    host.project().tracks.iter().map(|t| t.name.clone()).collect()
}

/// A package carrying real, named work: three tracks and a MIDI clip parked at a
/// tick no assertion below passes in. Returns the package dir.
fn seeded_package(dir: &Path, tag: &str) -> PathBuf {
    let pkg = dir.join(format!("{tag}.mstudio"));
    let mut host = StudioHost::create_at(&pkg, tag).unwrap();
    let a = Actor::user("aaron");
    for (id, name) in [("t1", "Drums"), ("t2", "Bass"), ("t3", "Keys")] {
        host.submit(a.clone(), "track.add", json!({ "trackId": id, "name": name }))
            .unwrap();
    }
    host.submit(
        a.clone(),
        "clip.placeMidi",
        json!({ "clipId": "c1", "trackId": "t3", "startTicks": 1920, "lengthTicks": 3840 }),
    )
    .unwrap();
    host.submit(a, "mix.gain", json!({ "trackId": "t2", "gainDb": -4.5 }))
        .unwrap();
    drop(host);
    pkg
}

/// The reported defect, end to end: checkpoint gone, journal intact, reopen.
#[test]
fn a_package_with_no_checkpoint_is_recovered_from_its_journal_not_erased() {
    let dir = tmp("no-checkpoint");
    let pkg = seeded_package(&dir, "Song");

    // The state a failed first run, or a partial restore, leaves behind.
    fs::remove_file(pkg.join("project.json")).unwrap();
    let before = journal_bytes(&pkg);
    assert!(!before.is_empty(), "the fixture must have a real journal");

    let host = StudioHost::open_or_create(&pkg, "Song").expect("reopen must recover, not refuse");

    // BY CONTENT. A count would pass on any three tracks; a default project has
    // none of these names.
    assert_eq!(
        track_names(&host),
        vec!["Drums", "Bass", "Keys"],
        "the recovered session must carry the commands that were journaled"
    );
    let clip = host
        .project()
        .tracks
        .iter()
        .flat_map(|t| &t.clips)
        .find(|c| c.id == "c1")
        .expect("the placed clip survived the replay");
    assert_eq!(clip.start_ticks, 1_920, "the clip came back where it was put");
    let bass = host.project().tracks.iter().find(|t| t.id == "t2").unwrap();
    assert_eq!(bass.gain.as_f64(), -4.5, "a mix edit survived the replay");

    // THE ARTIFACT. The file the next launch reads must be untouched.
    assert_eq!(
        journal_bytes(&pkg),
        before,
        "reopening must not rewrite a single byte of an intact journal"
    );

    // And the caller is told this was a recovery rather than an ordinary open.
    let r = host.open_recovery();
    assert!(r.is_noteworthy(), "a rebuilt session is not an ordinary reopen");
    assert!(r.checkpoint_missing);
    assert!(r.replayed_from_journal);
    assert_eq!(r.commands_recovered, 5);
    assert_eq!(r.corrupt_lines_dropped, 0);
}

/// The floor under every other create path: never truncate a journal, whoever
/// asks. The error has to NAME the file, because the person reading it is being
/// told their project was not opened and needs to know which one.
#[test]
fn creating_a_project_over_an_existing_journal_is_refused_by_name() {
    let dir = tmp("refuse");
    let pkg = seeded_package(&dir, "Song");
    fs::remove_file(pkg.join("project.json")).unwrap();
    let before = journal_bytes(&pkg);

    // `StudioHost` is not Debug, so this cannot be `expect_err`.
    let text = match StudioHost::create_at(&pkg, "Song") {
        Ok(_) => panic!("creating over a non-empty journal must be refused"),
        Err(e) => e.to_string(),
    };
    assert!(
        text.contains("journal.jsonl"),
        "the refusal must name the file it protected: {text}"
    );
    assert_eq!(
        journal_bytes(&pkg),
        before,
        "a refused create must leave the journal byte-identical"
    );
}

/// "New Project" twice with the same name used to resolve to one directory and
/// truncate it. No failure was required — just a name typed twice.
#[test]
fn a_second_project_with_the_same_name_leaves_the_first_untouched() {
    let dir = tmp("collide");
    let first = seeded_package(&dir, "Song");
    let before = journal_bytes(&first);

    let mut base = StudioHost::with_data_dir(&dir).unwrap();
    base.submit(Actor::user("aaron"), "project.new", json!({ "name": "Song" }))
        .expect("a second project of the same name must be possible");

    assert_ne!(
        base.package_dir().unwrap(),
        first.as_path(),
        "the new project must land somewhere else"
    );
    assert_eq!(
        journal_bytes(&first),
        before,
        "the first project's journal is untouched"
    );
    // The first one still opens and is still itself.
    let reopened = StudioHost::open_package(&first).unwrap();
    assert_eq!(track_names(&reopened), vec!["Drums", "Bass", "Keys"]);
}

/// A chain that breaks partway used to cost the user EVERY command in the file.
/// The prefix ahead of the break verifies from genesis, so it is kept; the
/// unreachable remainder is counted and the original bytes are set aside.
#[test]
fn a_break_in_the_middle_of_the_chain_keeps_the_work_before_it() {
    let dir = tmp("mid-break");
    let pkg = seeded_package(&dir, "Song");
    let original = journal_bytes(&pkg);
    let lines: Vec<String> = String::from_utf8(original.clone())
        .unwrap()
        .lines()
        .map(String::from)
        .collect();
    assert_eq!(lines.len(), 5);

    // Corrupt the chain at entry 2 by repeating entry 0 there: entries 0 and 1
    // still verify, everything from 2 on is unreachable.
    let mangled = format!(
        "{}\n{}\n{}\n{}\n{}\n",
        lines[0], lines[1], lines[0], lines[3], lines[4]
    );
    fs::write(pkg.join("journal.jsonl"), &mangled).unwrap();
    fs::remove_file(pkg.join("project.json")).unwrap();

    let host = StudioHost::open_or_create(&pkg, "Song").expect("a damaged chain is not a dead end");

    // The two tracks ahead of the break are real work and they survive; the
    // third does not, and 2 != 3 != 5 so this cannot be satisfied by accident.
    assert_eq!(
        track_names(&host),
        vec!["Drums", "Bass"],
        "everything chain-verified before the break must be kept"
    );

    let r = host.open_recovery();
    assert_eq!(r.commands_recovered, 2);
    assert_eq!(r.corrupt_lines_dropped, 3);
    assert!(r.is_noteworthy());

    // The bytes we could not read are SET ASIDE, never deleted.
    let quarantine = r
        .quarantined_journal
        .as_ref()
        .expect("damaged bytes must be quarantined");
    assert_eq!(
        fs::read(quarantine).unwrap(),
        mangled.as_bytes(),
        "the quarantine holds the original file, byte for byte"
    );
    // And the live journal was shortened to the verified prefix, so the next
    // command cannot land behind garbage.
    assert_eq!(
        String::from_utf8(journal_bytes(&pkg)).unwrap().lines().count(),
        2
    );
}

/// The common case stays silent. If an ordinary reopen reported a recovery the
/// notice would be noise, and a notice that fires every launch is one nobody
/// reads when it matters.
#[test]
fn an_ordinary_reopen_reports_nothing() {
    let dir = tmp("ordinary");
    let pkg = seeded_package(&dir, "Song");
    {
        // A checkpoint, exactly as autosave/quit writes one.
        let mut host = StudioHost::open_package(&pkg).unwrap();
        host.save().unwrap();
    }
    let before = journal_bytes(&pkg);

    let host = StudioHost::open_or_create(&pkg, "Song").unwrap();
    assert_eq!(track_names(&host), vec!["Drums", "Bass", "Keys"]);
    let r = host.open_recovery();
    assert!(
        !r.is_noteworthy(),
        "an intact package must not claim it was recovered: {r:?}"
    );
    assert!(!r.checkpoint_missing);
    assert!(!r.replayed_from_journal, "the checkpoint fast path was available");
    assert_eq!(journal_bytes(&pkg), before);
}

/// THE LOSS THIS LANE DID NOT REPAIR, made visible.
///
/// A checkpoint can summarize MORE commands than the journal holds — the
/// journal was truncated or restored short while `project.json` survived whole.
/// The journal is the truth by contract, so the fast path correctly refuses the
/// checkpoint and replays what the log has; the consequence is that the open
/// returns LESS work than the package once had, and nothing about that
/// announces itself.
///
/// Adopting the checkpoint instead would mean re-applying a journal tail over a
/// model that may already contain it (`Session::resume` only bridges the other
/// direction), which is how duplicate state gets written into someone's song.
/// So this is REPORTED rather than guessed at — and this test is what stops the
/// reporting from silently stopping.
#[test]
fn a_checkpoint_that_claims_more_than_the_journal_holds_is_reported() {
    let dir = tmp("cp-ahead");
    let pkg = seeded_package(&dir, "Song");
    {
        // A checkpoint describing all five commands.
        let mut host = StudioHost::open_package(&pkg).unwrap();
        host.save().unwrap();
    }
    // Now lose the tail of the journal only — the shape a short restore leaves.
    let text = String::from_utf8(journal_bytes(&pkg)).unwrap();
    let head: Vec<&str> = text.lines().take(2).collect();
    fs::write(pkg.join("journal.jsonl"), format!("{}\n", head.join("\n"))).unwrap();

    let host = StudioHost::open_or_create(&pkg, "Song").unwrap();
    let r = host.open_recovery();
    assert!(
        r.checkpoint_ahead_of_journal,
        "an open that returned less work than the package had must say so"
    );
    assert!(r.is_noteworthy());
    assert_eq!(r.commands_recovered, 2);
    // The journal really is the truth here: only the two logged tracks come back.
    assert_eq!(track_names(&host), vec!["Drums", "Bass"]);
}

/// An empty package directory is still a NEW project — the recovery path must
/// not make first launch impossible.
#[test]
fn an_empty_directory_still_creates_a_project() {
    let dir = tmp("fresh");
    let pkg = dir.join("Fresh.mstudio");
    let host = StudioHost::open_or_create(&pkg, "Fresh").expect("first launch creates");
    assert!(pkg.join("journal.jsonl").exists());
    assert!(pkg.join("project.json").exists());
    assert!(!host.open_recovery().is_noteworthy());
}
