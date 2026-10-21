//! `.mstudio` package io (native only; not compiled for wasm32).
//!
//! Layout per `engine/contracts/project-format.v1.md`:
//! ```text
//! Song.mstudio/
//!   project.json     checkpoint of the journal (fast open)
//!   journal.jsonl    hash-chained command log (truth; replay = recovery)
//!   audio/           content-addressed assets (blake3-named)
//!   takes/ tiles/ manifest.json  (rebuildable; not required to open)
//! ```
//!
//! Crash-safety (contract section 6): the journal is the truth and is fsynced
//! per command batch. A save writes a NEW checkpoint durably (tmp + fsync +
//! atomic rename + dir fsync) with the old checkpoint retained until the new
//! one lands, so a crash mid-save never loses data: the next open replays a
//! little more journal than strictly necessary. Open takes the checkpoint
//! fast-path when it matches the journal tip, and falls back to a full replay
//! from empty whenever the checkpoint is missing, stale, or corrupt (the
//! kill -9 case).

use std::collections::BTreeSet;
use std::fs::{self, File, OpenOptions};
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

use crate::envelope::{Envelope, GENESIS_HASH};
use crate::error::CommandError;
use crate::journal::{verify_lines, JournalSink};
use crate::model::{
    AutoPoint, Automation, Clip, Crossfade, EqBand, FadeCurve, FadeSpec, Limiter, Marker,
    MasterBus, Project, Section, Sends, TakeRecord, TakeStatus, TimeSig, Track, Warp, WarpMode,
    DEFAULT_TRACK_COLOR, DEFAULT_TRACK_HEIGHT_PX,
};
use crate::num::Num;
use crate::session::Session;
use crate::tempo::{Bpm, TempoMap};

fn io<E: std::fmt::Display>(e: E) -> CommandError {
    CommandError::Io(e.to_string())
}

/// serde_json has no `as_number`; this is the missing accessor.
fn as_number(v: &Value) -> Option<&serde_json::Number> {
    match v {
        Value::Number(n) => Some(n),
        _ => None,
    }
}

/// A native journal sink that appends canonical lines to `journal.jsonl` and
/// fsyncs on demand.
pub struct FileJournal {
    writer: BufWriter<File>,
    count: usize,
}

impl FileJournal {
    /// Open (creating) the journal file for appending. `existing` is how many
    /// lines are already present (from a prior open).
    pub fn open_append(path: &Path, existing: usize) -> Result<Self, CommandError> {
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .map_err(io)?;
        Ok(FileJournal {
            writer: BufWriter::new(file),
            count: existing,
        })
    }
}

impl JournalSink for FileJournal {
    fn append(&mut self, envelope: &Envelope) -> Result<(), CommandError> {
        self.writer
            .write_all(envelope.to_jsonl().as_bytes())
            .map_err(io)?;
        self.writer.write_all(b"\n").map_err(io)?;
        // Push the line OUT OF THIS PROCESS on every append.
        //
        // Without this the BufWriter holds up to 8 KiB in user space and only
        // hands it to the kernel on flush/drop. `Drop` never runs for the host
        // the app holds in a `static` — AppKit tears the process down with
        // exit(), which skips destructors — so a whole session's commands died
        // in that buffer. Observed live: `journal.jsonl` 0 bytes after a day of
        // work. `write(2)` costs a syscall, not a disk seek, and once the bytes
        // are in the page cache they survive SIGKILL, a panic, and exit().
        // `sync()` is still the only fsync (power-loss durability), called at
        // save/autosave rather than per command.
        self.writer.flush().map_err(io)?;
        self.count += 1;
        Ok(())
    }

    fn sync(&mut self) -> Result<(), CommandError> {
        self.writer.flush().map_err(io)?;
        self.writer.get_ref().sync_data().map_err(io)?;
        Ok(())
    }

    fn len(&self) -> usize {
        self.count
    }
}

/// What `Package::open` had to do to hand back a session.
///
/// Every field is a FACT ABOUT THIS OPEN, never state that is persisted: the
/// caller reads it once and, if it says anything, tells the person. A recovery
/// that works but says nothing is only half a fix — the owner of the project
/// deserves to know his work was rebuilt rather than simply loaded, because
/// that is the moment to check it and take a copy.
///
/// A DEFAULT value means "an ordinary reopen": checkpoint present, chain whole,
/// nothing dropped. That is the overwhelmingly common case and it is silent.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct OpenRecovery {
    /// `project.json` was absent altogether, so there was no fast path to take.
    /// This is the state a package is left in by any failure between
    /// `Package::create`'s journal write and its first checkpoint, and the one
    /// a partial restore from a backup tool produces.
    pub checkpoint_missing: bool,
    /// The checkpoint was missing, stale or corrupt, so the session was rebuilt
    /// by replaying the journal from empty rather than read from the checkpoint.
    pub replayed_from_journal: bool,
    /// How many journal commands the returned session actually contains.
    pub commands_recovered: usize,
    /// A single torn final line was dropped: the ordinary crash signature (the
    /// process died between the start and the end of the last `write(2)`).
    /// Losing that one command is recovery, not damage.
    pub torn_tail_dropped: usize,
    /// Lines discarded because the hash chain broke BEFORE them — real
    /// corruption rather than a torn write. The prefix ahead of the break is
    /// verified from genesis, so the work it carries is authentic and kept;
    /// everything after the break is unreachable and is counted here.
    pub corrupt_lines_dropped: usize,
    /// Where the ORIGINAL journal bytes were copied before the file was
    /// shortened. Only set when `corrupt_lines_dropped > 0` — an ordinary torn
    /// tail is half a line of garbage and worth nothing, but bytes we could not
    /// chain-verify may still be readable by a human or a later build, so they
    /// are never simply deleted.
    pub quarantined_journal: Option<PathBuf>,
    /// The checkpoint summarizes MORE commands than the journal holds. The
    /// journal is the truth by contract, so the extra state in the checkpoint is
    /// not adopted — which means this open returns less work than the package
    /// once had. Reported rather than repaired (see the note on `open`).
    pub checkpoint_ahead_of_journal: bool,
}

impl OpenRecovery {
    /// True when this open was anything other than an ordinary reopen — i.e.
    /// when there is something the person using the app should be told.
    pub fn is_noteworthy(&self) -> bool {
        self.checkpoint_missing
            || self.corrupt_lines_dropped > 0
            || self.torn_tail_dropped > 0
            || self.checkpoint_ahead_of_journal
    }
}

pub struct Package;

impl Package {
    fn project_json_path(dir: &Path) -> PathBuf {
        dir.join("project.json")
    }
    fn journal_path(dir: &Path) -> PathBuf {
        dir.join("journal.jsonl")
    }
    fn audio_dir(dir: &Path) -> PathBuf {
        dir.join("audio")
    }

    /// Create a new empty package on disk and return a Session writing into it.
    ///
    /// REFUSES to run over an existing non-empty journal. `File::create` below
    /// TRUNCATES, and `journal.jsonl` is not a cache — it is the project (see
    /// this module's header and `StudioProjectSaver.swift`). Creating over one
    /// destroys every command the user ever issued, with no warning, no backup
    /// and nothing to undo, so the only correct answer is to stop and name the
    /// file. This is the LAST line of defence rather than the first: callers
    /// that might be looking at an existing project (`StudioHost::open_or_create`)
    /// decide on the journal and open it instead, and `create_package` picks a
    /// name that is not already taken. The guard is here anyway because it is
    /// the one place every create path funnels through, and because a caller
    /// added later will not have read either of those.
    pub fn create(dir: &Path, project: Project) -> Result<Session, CommandError> {
        fs::create_dir_all(Self::audio_dir(dir)).map_err(io)?;
        let journal = Self::journal_path(dir);
        if fs::metadata(&journal).map(|m| m.len() > 0).unwrap_or(false) {
            return Err(CommandError::Io(format!(
                "refusing to create a new project over the existing journal at {} \
                 -- it holds this project's command history and creating would \
                 erase it. Open the package instead, or move that file aside.",
                journal.display()
            )));
        }
        // empty journal
        File::create(&journal).map_err(io)?;
        let session = Session::with_sink(
            project,
            Box::new(FileJournal::open_append(&journal, 0)?),
        );
        Self::write_checkpoint(dir, &session)?;
        Ok(session)
    }

    /// Save: write the checkpoint durably. The journal is already on disk
    /// (appended per submit); this refreshes it atomically too, then writes
    /// the new checkpoint, then fsyncs the directory. Old checkpoint is
    /// overwritten only by atomic rename, so a crash cannot corrupt it.
    pub fn save(dir: &Path, session: &mut Session) -> Result<(), CommandError> {
        // 1. Rewrite journal.jsonl atomically from the in-memory chain and
        //    fsync it FIRST (truth before checkpoint).
        let jtmp = dir.join("journal.jsonl.tmp");
        {
            let mut w = BufWriter::new(File::create(&jtmp).map_err(io)?);
            for env in session.journal() {
                w.write_all(env.to_jsonl().as_bytes()).map_err(io)?;
                w.write_all(b"\n").map_err(io)?;
            }
            w.flush().map_err(io)?;
            w.get_ref().sync_data().map_err(io)?;
        }
        fs::rename(&jtmp, Self::journal_path(dir)).map_err(io)?;
        sync_dir(dir)?;
        // 1b. REATTACH the sink. The rename above swapped a new inode in under
        //     `journal.jsonl`; the session's existing fd still points at the
        //     old, now-unlinked one. Keep appending through it and every
        //     command issued after the first save writes into a file no one
        //     can ever open again — i.e. saving once would start silently
        //     discarding the work that followed. Reopen on the new path and
        //     hand the session the fresh sink.
        let written = session.journal().len();
        session.set_sink(Box::new(FileJournal::open_append(
            &Self::journal_path(dir),
            written,
        )?));
        // 2. Write the new checkpoint durably.
        Self::write_checkpoint(dir, session)?;
        Ok(())
    }

    fn write_checkpoint(dir: &Path, session: &Session) -> Result<(), CommandError> {
        let value = to_project_json(session);
        let text = serde_json::to_string_pretty(&value).map_err(io)?;
        let tmp = dir.join("project.json.tmp");
        {
            let mut f = File::create(&tmp).map_err(io)?;
            f.write_all(text.as_bytes()).map_err(io)?;
            f.sync_data().map_err(io)?;
        }
        fs::rename(&tmp, Self::project_json_path(dir)).map_err(io)?;
        sync_dir(dir)?;
        Ok(())
    }

    /// Open a package. Reads and verifies the journal chain, then:
    /// - fast path: if project.json's journal pointer matches a prefix of the
    ///   chain, reconstruct the model from the checkpoint and replay only the
    ///   tail entries beyond it;
    /// - fallback: on any missing/corrupt/mismatched checkpoint, replay the
    ///   whole journal from empty (the crash-recovery path).
    /// Clips whose asset is absent under audio/ are marked `offline`.
    ///
    /// A MISSING checkpoint is a first-class recovery case, not an error and
    /// not a reason to start over: the journal alone is enough to rebuild the
    /// whole session, and the fallback above is exactly that path.
    ///
    /// KNOWN GAP, reported rather than repaired: when the checkpoint summarizes
    /// MORE commands than the journal holds (`checkpoint_ahead_of_journal`), the
    /// fallback replays only what the journal has and the checkpoint's extra
    /// state is dropped. Adopting it instead would mean re-applying a journal
    /// tail over a model that may already contain it, which is how duplicate
    /// state gets written; `Session::resume` can only bridge the other
    /// direction. So the loss is REPORTED to the caller and left visible rather
    /// than papered over with a guess.
    pub fn open(dir: &Path) -> Result<Session, CommandError> {
        Self::open_reporting(dir).map(|(session, _)| session)
    }

    /// `open`, plus the account of what it had to do to get there. Callers that
    /// face a person (the app) use this one and surface anything noteworthy;
    /// `open` is the same path for callers that do not.
    pub fn open_reporting(dir: &Path) -> Result<(Session, OpenRecovery), CommandError> {
        let journal_text = fs::read_to_string(Self::journal_path(dir)).map_err(io)?;
        let mut lines: Vec<String> = journal_text
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(String::from)
            .collect();
        let on_disk_lines = lines.len();
        let mut recovery = OpenRecovery::default();

        // Verify the whole chain up front (a bad tail is a recovery signal).
        // A TORN FINAL LINE is the ordinary crash signature now that every
        // command is written straight through: the process died between the
        // start and the end of the last `write(2)`. Losing that one command is
        // recovery; refusing to open the project because of it is data loss.
        //
        // A break EARLIER than the last line is real corruption rather than a
        // torn write, and this used to refuse the whole package for it. That
        // refusal cost the user EVERY command in the file to protect against a
        // rewritten history -- and on the app's own launch path the refusal did
        // not even show as a refusal (`StudioEngineFactory.makeDefault` catches
        // it and presents a fixture project). The prefix ahead of the break is
        // chain-verified from genesis, so it is exactly as authentic as a torn
        // tail's prefix: it is kept, the unreachable remainder is counted, and
        // the ORIGINAL bytes are quarantined beside the package. Partial
        // recovery beats none, and the guard the old refusal was protecting is
        // preserved by being LOUD (`OpenRecovery`) rather than by being fatal --
        // nothing here is quiet.
        let (chain_tip, chain_len) = match verify_lines(&lines) {
            Ok(v) => v,
            Err(_) => {
                let (good, tip) = longest_verified_prefix(&lines);
                let dropped = on_disk_lines - good;
                lines.truncate(good);
                // One line is indistinguishable from a half-finished write and
                // is classified as one, exactly as it was before.
                if dropped == 1 {
                    recovery.torn_tail_dropped = 1;
                } else {
                    recovery.corrupt_lines_dropped = dropped;
                }
                (tip, good)
            }
        };
        // Lines were dropped above, but the bytes are still in the file.
        // Truncate the file to the verified prefix BEFORE we attach an append
        // sink, or the next command lands after garbage and the chain is
        // unopenable for good. tmp + rename so the old file stays intact until
        // the good one is in place -- and for real corruption, copy the whole
        // original aside first so shortening the file never destroys bytes a
        // human or a later build might still make sense of.
        if lines.len() != on_disk_lines {
            if recovery.corrupt_lines_dropped > 0 {
                recovery.quarantined_journal =
                    Some(Self::quarantine_journal(dir, journal_text.as_bytes())?);
            }
            Self::rewrite_journal(dir, &lines)?;
        }

        let envelopes: Vec<Envelope> = lines
            .iter()
            .map(|l| Envelope::from_line(l))
            .collect::<Result<_, _>>()?;
        let on_disk = envelopes.len();
        recovery.commands_recovered = on_disk;
        recovery.checkpoint_missing = !Self::project_json_path(dir).exists();
        recovery.checkpoint_ahead_of_journal =
            Self::checkpoint_entry_count(dir).is_some_and(|c| c > chain_len);

        // Try the checkpoint fast path.
        let mut session = match Self::try_fast_open(dir, &envelopes, &chain_tip, chain_len) {
            Ok(Some(s)) => s,
            _ => {
                // Full replay from empty.
                recovery.replayed_from_journal = true;
                let base = empty_project_from_checkpoint(dir).unwrap_or_else(default_project);
                Session::replay(base, envelopes)?
            }
        };
        // ATTACH THE FILE SINK. `Session::replay`/`resume` construct with a
        // MemoryJournal, so without this every command issued in a REOPENED
        // project was journaled to RAM only -- `journal.jsonl` stayed exactly
        // as it was created and a quit destroyed the whole session. This is the
        // defect that made a day of work vanish: only the very first launch of
        // a package (the `Package::create` path) ever had a file sink.
        session.set_sink(Box::new(FileJournal::open_append(
            &Self::journal_path(dir),
            on_disk,
        )?));
        mark_offline(dir, &mut session)?;
        Ok((session, recovery))
    }

    /// Copy the journal's original bytes to `journal.jsonl.corrupt-N` beside the
    /// package before the live file is shortened. Never overwrites an earlier
    /// quarantine: each incident keeps its own evidence.
    fn quarantine_journal(dir: &Path, original: &[u8]) -> Result<PathBuf, CommandError> {
        for n in 0..1_000u32 {
            let candidate = dir.join(format!("journal.jsonl.corrupt-{n}"));
            if candidate.exists() {
                continue;
            }
            // create_new so two processes racing here cannot clobber one
            // another's evidence.
            match OpenOptions::new().write(true).create_new(true).open(&candidate) {
                Ok(mut f) => {
                    f.write_all(original).map_err(io)?;
                    f.sync_data().map_err(io)?;
                    sync_dir(dir)?;
                    return Ok(candidate);
                }
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(io(e)),
            }
        }
        Err(CommandError::Io(format!(
            "could not set aside the damaged journal in {}: 1000 quarantine slots are taken",
            dir.display()
        )))
    }

    /// `entryCount` from the checkpoint's journal pointer, if there is one that
    /// parses. Used only to notice that the checkpoint describes more history
    /// than the journal holds.
    fn checkpoint_entry_count(dir: &Path) -> Option<usize> {
        let text = fs::read_to_string(Self::project_json_path(dir)).ok()?;
        let cp: Value = serde_json::from_str(&text).ok()?;
        cp.get("journal")?
            .get("entryCount")
            .and_then(Value::as_u64)
            .map(|c| c as usize)
    }

    /// Atomically replace `journal.jsonl` with exactly `lines`.
    fn rewrite_journal(dir: &Path, lines: &[String]) -> Result<(), CommandError> {
        let jtmp = dir.join("journal.jsonl.tmp");
        {
            let mut w = BufWriter::new(File::create(&jtmp).map_err(io)?);
            for l in lines {
                w.write_all(l.as_bytes()).map_err(io)?;
                w.write_all(b"\n").map_err(io)?;
            }
            w.flush().map_err(io)?;
            w.get_ref().sync_data().map_err(io)?;
        }
        fs::rename(&jtmp, Self::journal_path(dir)).map_err(io)?;
        sync_dir(dir)?;
        Ok(())
    }

    fn try_fast_open(
        dir: &Path,
        envelopes: &[Envelope],
        chain_tip: &str,
        chain_len: usize,
    ) -> Result<Option<Session>, CommandError> {
        let text = fs::read_to_string(Self::project_json_path(dir)).map_err(io)?;
        let checkpoint: Value = serde_json::from_str(&text).map_err(io)?;
        let jblock = checkpoint
            .get("journal")
            .and_then(Value::as_object)
            .ok_or_else(|| CommandError::Io("checkpoint has no journal block".into()))?;
        let cp_count = jblock
            .get("entryCount")
            .and_then(Value::as_u64)
            .ok_or_else(|| CommandError::Io("checkpoint entryCount missing".into()))?
            as usize;
        let cp_tip = jblock
            .get("tipHash")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if cp_count > chain_len {
            return Ok(None); // checkpoint claims more than the journal has
        }
        // The checkpoint must summarize a real prefix of THIS chain.
        let expected_tip_at_cp = if cp_count == 0 {
            GENESIS_HASH.to_string()
        } else {
            envelopes[cp_count - 1].hash.clone()
        };
        if cp_tip != expected_tip_at_cp {
            return Ok(None);
        }
        // Reconstruct model at the checkpoint, then resume with the FULL chain
        // (the checkpoint prefix is not re-applied; the tail rebuilds state and
        // undo units). The session's journal/tip then describe the whole chain.
        let base = from_project_json(&checkpoint)?;
        let session = Session::resume(base, envelopes.to_vec(), cp_count)?;
        // Sanity: the resumed tip must equal the whole chain tip.
        if session.tip_hash() != chain_tip {
            return Ok(None);
        }
        Ok(Some(session))
    }
}

/// How much of `lines` chains cleanly from genesis, and the hash at that point.
///
/// `verify_lines` answers yes/no for the WHOLE file, which is the right question
/// when deciding whether a package is intact. This answers "how much of it is
/// still the user's real work", which is the right question once the answer to
/// the first is no. It stops at the first line that fails to parse or fails to
/// verify against its predecessor; everything before that point was hashed in
/// order from `GENESIS_HASH` and is as trustworthy as any other opened journal.
fn longest_verified_prefix(lines: &[String]) -> (usize, String) {
    let mut prev = GENESIS_HASH.to_string();
    for (i, line) in lines.iter().enumerate() {
        let Ok(env) = Envelope::from_line(line) else {
            return (i, prev);
        };
        if env.verify(&prev).is_err() {
            return (i, prev);
        }
        prev = env.hash.clone();
    }
    (lines.len(), prev)
}

/// fsync a directory so a rename within it is durable.
fn sync_dir(dir: &Path) -> Result<(), CommandError> {
    if let Ok(f) = File::open(dir) {
        let _ = f.sync_all();
    }
    Ok(())
}

fn default_project() -> Project {
    Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()))
}

/// A base project carrying only the identity/config the journal does not set
/// via commands (projectId, sampleRate, ppq). project.new/setTempo/etc. in the
/// journal set the rest, so full replay starts from this shell.
fn empty_project_from_checkpoint(dir: &Path) -> Option<Project> {
    let text = fs::read_to_string(Package::project_json_path(dir)).ok()?;
    let cp: Value = serde_json::from_str(&text).ok()?;
    let mut p = default_project();
    if let Some(id) = cp.get("projectId").and_then(Value::as_str) {
        p.project_id = id.to_string();
    }
    if let Some(name) = cp.get("name").and_then(Value::as_str) {
        p.name = name.to_string();
    }
    if let Some(sr) = cp.get("sampleRateHz").and_then(Value::as_u64) {
        p.sample_rate = sr as u32;
    }
    Some(p)
}

/// Mark clips offline when their asset hash has no file under audio/.
fn mark_offline(dir: &Path, session: &mut Session) -> Result<(), CommandError> {
    let audio = Package::audio_dir(dir);
    let mut present: BTreeSet<String> = BTreeSet::new();
    if let Ok(entries) = fs::read_dir(&audio) {
        for e in entries.flatten() {
            if let Some(name) = e.file_name().to_str() {
                // asset files are named by (or prefixed with) their hash
                present.insert(name.to_string());
            }
        }
    }
    session.mark_offline_by(|clip| {
        // E1: a note-backed clip has no asset, so "asset missing" is not a
        // state it can be in. Without this guard an empty audio/ directory
        // would mark every MIDI clip offline (the empty-prefix `starts_with`
        // below matches nothing when `present` is empty).
        if clip.is_midi() {
            return false;
        }
        let hash = clip.source_id.clone();
        // present if any file name starts with the hash (allows extensions).
        !present.iter().any(|n| n.starts_with(&hash))
    });
    Ok(())
}

// ---------------------------------------------------------------------------
// Checkpoint mapping: model <-> project.json (contract shape, camelCase).
// Default-valued fields are omitted so a never-customized track/clip round-
// trips to the same shape as the P0-C fixtures; `extra` maps carry unknown
// fields forward (contract section 6 forward-compat).
// ---------------------------------------------------------------------------

fn num_val(n: &Num) -> Value {
    n.to_value()
}

fn with_extra(mut obj: Map<String, Value>, extra: &Map<String, Value>) -> Value {
    for (k, v) in extra {
        obj.entry(k.clone()).or_insert_with(|| v.clone());
    }
    Value::Object(obj)
}

fn fade_val(f: &FadeSpec) -> Value {
    let mut m = Map::new();
    m.insert("lengthTicks".into(), Value::from(f.length_ticks));
    m.insert(
        "shape".into(),
        Value::String(f.curve.wire_name().to_string()),
    );
    Value::Object(m)
}

/// One sampler zone / drum pad in the checkpoint. `gain`/`pan` are omitted at
/// their canonical default so a never-customized zone round-trips minimally,
/// exactly like every other default-omitted field here.
fn device_zone_val(z: &crate::model::DeviceZone) -> Value {
    let mut m = Map::new();
    m.insert("zoneId".into(), Value::String(z.id.clone()));
    m.insert("sourceId".into(), Value::String(z.source_id.clone()));
    m.insert("rootPitch".into(), num_val(&z.root_pitch));
    m.insert("loPitch".into(), num_val(&z.lo_pitch));
    m.insert("hiPitch".into(), num_val(&z.hi_pitch));
    if z.gain != crate::model::DeviceZone::default_gain() {
        m.insert("gainDb".into(), num_val(&z.gain));
    }
    if z.pan != crate::model::DeviceZone::default_pan() {
        m.insert("pan".into(), num_val(&z.pan));
    }
    with_extra(m, &z.extra)
}

fn auto_points_val(points: &[AutoPoint]) -> Value {
    Value::Array(
        points
            .iter()
            .map(|p| {
                let mut m = Map::new();
                m.insert("pointId".into(), Value::String(p.id.clone()));
                m.insert("positionTicks".into(), Value::from(p.position_ticks));
                m.insert("value".into(), num_val(&p.value));
                with_extra(m, &p.extra)
            })
            .collect(),
    )
}

/// One note in the checkpoint (camelCase, `Num` values rendered by `num_val`
/// so `100` never becomes `100.0`).
fn note_val(n: &crate::note::Note) -> Value {
    let mut m = Map::new();
    m.insert("noteId".into(), Value::String(n.id.clone()));
    m.insert("startTicks".into(), Value::from(n.start_ticks));
    m.insert("lengthTicks".into(), Value::from(n.length_ticks));
    m.insert("pitch".into(), Value::from(n.pitch));
    m.insert("velocity".into(), num_val(&n.velocity));
    with_extra(m, &n.extra)
}

const NOTE_KNOWN_KEYS: &[&str] = &[
    "noteId",
    "startTicks",
    "lengthTicks",
    "pitch",
    "velocity",
];

fn parse_note(v: &Value) -> crate::note::Note {
    let o = v.as_object().cloned().unwrap_or_default();
    crate::note::Note {
        id: o
            .get("noteId")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        start_ticks: o.get("startTicks").and_then(Value::as_u64).unwrap_or(0),
        length_ticks: o.get("lengthTicks").and_then(Value::as_u64).unwrap_or(1),
        pitch: o
            .get("pitch")
            .and_then(Value::as_u64)
            .unwrap_or(60)
            .min(127) as u8,
        velocity: o
            .get("velocity")
            .and_then(as_number)
            .map(|n| Num(n.clone()))
            .unwrap_or_else(|| Num::int(100)),
        // Forward-compat: an unknown per-note field written by a NEWER build
        // survives load->save. Without this it would be DESTROYED, not merely
        // ignored (design §9.3, the gap E0 found on `Automation`).
        extra: extra_of(&o, NOTE_KNOWN_KEYS),
    }
}

pub fn to_project_json(session: &Session) -> Value {
    let p = session.project();
    let mut root = Map::new();
    root.insert("formatVersion".into(), Value::from(1));
    root.insert("projectId".into(), Value::String(p.project_id.clone()));
    root.insert("name".into(), Value::String(p.name.clone()));

    let mut tempo = Map::new();
    tempo.insert("bpm".into(), num_val(&p.bpm_wire));
    root.insert("tempo".into(), Value::Object(tempo));

    let mut ts = Map::new();
    ts.insert("numerator".into(), Value::from(p.time_sig.numerator));
    ts.insert("denominator".into(), Value::from(p.time_sig.denominator));
    root.insert("timeSig".into(), Value::Object(ts));

    if !p.key.is_empty() {
        root.insert("key".into(), Value::String(p.key.clone()));
    }
    root.insert("sampleRateHz".into(), Value::from(p.sample_rate));
    root.insert("ppq".into(), Value::from(crate::tempo::PPQ));

    if !p.sections.is_empty() {
        root.insert(
            "sections".into(),
            Value::Array(
                p.sections
                    .iter()
                    .map(|s| {
                        let mut m = Map::new();
                        m.insert("sectionId".into(), Value::String(s.id.clone()));
                        m.insert("name".into(), Value::String(s.name.clone()));
                        m.insert("startTicks".into(), Value::from(s.start_ticks));
                        if let Some(c) = &s.color {
                            m.insert("color".into(), Value::String(c.clone()));
                        }
                        with_extra(m, &s.extra)
                    })
                    .collect(),
            ),
        );
    }
    if !p.markers.is_empty() {
        root.insert(
            "markers".into(),
            Value::Array(
                p.markers
                    .iter()
                    .map(|mk| {
                        let mut m = Map::new();
                        m.insert("markerId".into(), Value::String(mk.id.clone()));
                        m.insert("positionTicks".into(), Value::from(mk.position_ticks));
                        m.insert("label".into(), Value::String(mk.label.clone()));
                        if let Some(c) = &mk.color {
                            m.insert("color".into(), Value::String(c.clone()));
                        }
                        with_extra(m, &mk.extra)
                    })
                    .collect(),
            ),
        );
    }

    // tracks (with index); clips flattened to the top level.
    let mut tracks = Vec::new();
    let mut clips = Vec::new();
    for (index, t) in p.tracks.iter().enumerate() {
        let mut m = Map::new();
        m.insert("trackId".into(), Value::String(t.id.clone()));
        m.insert("name".into(), Value::String(t.name.clone()));
        m.insert("index".into(), Value::from(index as u64));
        if t.color != DEFAULT_TRACK_COLOR {
            m.insert("color".into(), Value::String(t.color.clone()));
        }
        if t.height_px != DEFAULT_TRACK_HEIGHT_PX {
            m.insert("heightPx".into(), Value::from(t.height_px));
        }
        if t.mute {
            m.insert("muted".into(), Value::Bool(true));
        }
        if t.solo {
            m.insert("soloed".into(), Value::Bool(true));
        }
        if t.armed {
            m.insert("armed".into(), Value::Bool(true));
        }
        // Which hardware input this track records from. It was journaled,
        // undoable, honoured by the capture path and NOT WRITTEN HERE, so the
        // four-input case `track.setInputChannel` exists for — set four tracks
        // to four channels, arm them, record once — came back from a reopen
        // with every track on channel 0 while `armed` survived. That is a
        // project that reopens looking correct and records the same mic four
        // times. Default 0 stays absent, exactly like every other field above.
        if t.input_channel != 0 {
            m.insert("inputChannel".into(), Value::from(t.input_channel));
        }
        if t.gain != Num::int(0) {
            m.insert("gainDb".into(), num_val(&t.gain));
        }
        if t.pan != Num::int(0) {
            m.insert("pan".into(), num_val(&t.pan));
        }
        let mut sends = Map::new();
        if t.sends.a != Num::int(0) {
            sends.insert("a".into(), num_val(&t.sends.a));
        }
        if t.sends.b != Num::int(0) {
            sends.insert("b".into(), num_val(&t.sends.b));
        }
        if !sends.is_empty() {
            m.insert("sends".into(), Value::Object(sends));
        }
        // Automation. The two legacy lanes keep their v1 keys byte-identically
        // so a v2 file that only automates volume/pan is still readable by a v1
        // binary. Everything else goes under `lanes`, keyed by the verbatim
        // ParamRef — NESTED, so a lane that happens to be spelled "volume"
        // cannot collide with the legacy array.
        //
        // A well-formed path this build does not recognize is written back
        // exactly as it was read. Dropping it would be silent data loss.
        let mut auto = Map::new();
        for (k, v) in &t.automation.extra {
            auto.insert(k.clone(), v.clone());
        }
        if !t.automation.volume.is_empty() {
            auto.insert("volume".into(), auto_points_val(&t.automation.volume));
        }
        if !t.automation.pan.is_empty() {
            auto.insert("pan".into(), auto_points_val(&t.automation.pan));
        }
        let mut lanes = Map::new();
        for (path, points) in &t.automation.lanes {
            debug_assert!(
                !path.is_legacy(),
                "legacy path {path} must live in its legacy field, not the lanes map"
            );
            if !points.is_empty() {
                lanes.insert(path.as_str().to_string(), auto_points_val(points));
            }
        }
        if !lanes.is_empty() {
            auto.insert("lanes".into(), Value::Object(lanes));
        }
        if !auto.is_empty() {
            m.insert("automation".into(), Value::Object(auto));
        }
        // E1/E2 devices. Omitted entirely when a track has none, so a pre-E1
        // track's bytes are unchanged.
        if !t.devices.is_empty() {
            m.insert(
                "devices".into(),
                Value::Array(
                    t.devices
                        .iter()
                        .map(|d| {
                            let mut dm = Map::new();
                            dm.insert("deviceId".into(), Value::String(d.id.clone()));
                            dm.insert(
                                "kind".into(),
                                Value::String(d.kind.wire_name().to_string()),
                            );
                            if !d.params.is_empty() {
                                let mut pm = Map::new();
                                for (k, v) in &d.params {
                                    pm.insert(k.clone(), num_val(v));
                                }
                                dm.insert("params".into(), Value::Object(pm));
                            }
                            // Sampler/drum source bindings. Omitted entirely
                            // when there are none, so a synth device's bytes
                            // are unchanged. Written here rather than left to
                            // the derived serialization for the same reason
                            // `Automation`'s lanes had to be: this hand-built
                            // checkpoint is what `parse_device` reads back, and
                            // a field it does not write is DESTROYED on save,
                            // not merely ignored (E0 §9.3).
                            if !d.zones.is_empty() {
                                dm.insert(
                                    "zones".into(),
                                    Value::Array(
                                        d.zones.iter().map(device_zone_val).collect(),
                                    ),
                                );
                            }
                            with_extra(dm, &d.extra)
                        })
                        .collect(),
                ),
            );
        }
        // E5: the track's INSERT chain (`Track::fx`), a SEPARATE collection from
        // `devices`. Omitted entirely when empty, so a pre-E5 track's bytes are
        // unchanged. Hand-written for the same reason `devices` is: a field this
        // checkpoint does not write is DESTROYED on save (E0 §9.3).
        if !t.fx.is_empty() {
            m.insert("fx".into(), fx_chain_val(&t.fx));
        }
        // Per-track EQ. v1 had no first-class field in project.schema.json, so
        // it was persisted under the namespaced `engineEq` key. Deferred
        // proposal 2 (ACCEPTED in catalog v2) makes `eq` first-class: ParamRef
        // has to address EQ bands (`track.eq.<band>.gain`), and leaving EQ
        // implicit forces a special case in the exact place that must be
        // general. `engineEq` is still READ (see parse_track) so older
        // checkpoints load unchanged; it is no longer written.
        // Emitted only when a band differs from default.
        let eq_defaults = crate::model::default_eq();
        if t.eq[..] != eq_defaults[..] {
            let bands: Vec<Value> =
                t.eq.iter()
                    .map(|b| {
                        let mut bm = Map::new();
                        bm.insert("freqHz".into(), num_val(&b.freq_hz));
                        bm.insert("gainDb".into(), num_val(&b.gain_db));
                        bm.insert("q".into(), num_val(&b.q));
                        Value::Object(bm)
                    })
                    .collect();
            m.insert("eq".into(), Value::Array(bands));
        }
        tracks.push(with_extra(m, &t.extra));

        for c in &t.clips {
            let mut cm = Map::new();
            cm.insert("clipId".into(), Value::String(c.id.clone()));
            cm.insert("trackId".into(), Value::String(t.id.clone()));
            if c.name != c.id {
                cm.insert("name".into(), Value::String(c.name.clone()));
            }
            // E1: a note-backed clip has NO audio asset. `kind` and `notes`
            // are additive keys (project.schema.json is
            // additionalProperties:true); an AUDIO clip emits neither, so its
            // bytes are unchanged by E1 — that is what
            // tests/v1_1_replay_regression.rs pins.
            //
            // REPORTED CONTRACT GAP (E0 §8: "report rather than work around"):
            // project.schema.json REQUIRES `assetHash` on every clip and
            // constrains it to 64 hex chars, which a note-backed clip cannot
            // honestly satisfy. It is omitted rather than filled with a
            // sentinel hash, because a sentinel would make `mark_offline`
            // resolve a nonexistent asset and flag the clip offline.
            if c.is_midi() {
                cm.insert("kind".into(), Value::String(c.kind.wire_name().to_string()));
            } else {
                cm.insert("assetHash".into(), Value::String(c.source_id.clone()));
            }
            cm.insert("startTicks".into(), Value::from(c.start_ticks));
            cm.insert("lengthTicks".into(), Value::from(c.length_ticks));
            if c.source_offset_ticks != 0 {
                cm.insert(
                    "sourceOffsetTicks".into(),
                    Value::from(c.source_offset_ticks),
                );
            }
            if c.gain != Num::int(0) {
                cm.insert("gainDb".into(), num_val(&c.gain));
            }
            if c.muted {
                cm.insert("muted".into(), Value::Bool(true));
            }
            if c.fade_in != FadeSpec::default() {
                cm.insert("fadeIn".into(), fade_val(&c.fade_in));
            }
            if c.fade_out != FadeSpec::default() {
                cm.insert("fadeOut".into(), fade_val(&c.fade_out));
            }
            if !c.warp.is_unwarped() {
                let mut w = Map::new();
                w.insert(
                    "mode".into(),
                    Value::String(
                        match c.warp.mode {
                            WarpMode::Ratio => "ratio",
                            WarpMode::Conform => "conform",
                        }
                        .to_string(),
                    ),
                );
                if c.warp.mode == WarpMode::Ratio {
                    w.insert("stretchRatio".into(), num_val(&c.warp.stretch_ratio));
                }
                cm.insert("warp".into(), Value::Object(w));
            }
            if c.phase_anchor_ticks != 0 {
                cm.insert("phaseAnchorTicks".into(), Value::from(c.phase_anchor_ticks));
            }
            if c.offline {
                cm.insert("offline".into(), Value::Bool(true));
            }
            if !c.notes.is_empty() {
                cm.insert(
                    "notes".into(),
                    Value::Array(c.notes.iter().map(note_val).collect()),
                );
            }
            clips.push(with_extra(cm, &c.extra));
        }
    }
    root.insert("tracks".into(), Value::Array(tracks));
    root.insert("clips".into(), Value::Array(clips));

    // masterBus (omit when fully default).
    if p.master != MasterBus::default() {
        let mut mb = Map::new();
        if p.master.gain_db != Num::int(0) {
            mb.insert("gainDb".into(), num_val(&p.master.gain_db));
        }
        let mut lim = Map::new();
        lim.insert("enabled".into(), Value::Bool(p.master.limiter.enabled));
        lim.insert("ceilingDb".into(), num_val(&p.master.limiter.ceiling_db));
        lim.insert("releaseMs".into(), num_val(&p.master.limiter.release_ms));
        mb.insert("limiter".into(), Value::Object(lim));
        // E5 §16.2: the MASTER insert chain. Omitted when empty.
        if !p.master.fx.is_empty() {
            mb.insert("fx".into(), fx_chain_val(&p.master.fx));
        }
        root.insert("masterBus".into(), with_extra(mb, &p.master.extra));
    }

    // crossfades / takes are engine state beyond the schema's named fields;
    // carried under a namespaced key preserved by additionalProperties:true.
    if !p.crossfades.is_empty() {
        root.insert(
            "engineCrossfades".into(),
            Value::Array(p.crossfades.iter().map(crossfade_val).collect()),
        );
    }
    if !p.takes.is_empty() {
        root.insert(
            "engineTakes".into(),
            Value::Array(p.takes.iter().map(take_val).collect()),
        );
    }
    // Routing DAG (design §5) and the project phase anchor (deferred proposal
    // L8). Both are omitted when at their v1 default, so an untouched project
    // checkpoints to exactly the bytes it did before.
    if !p.routing.is_empty() {
        root.insert("engineRouting".into(), routing_val(&p.routing));
    }
    if p.phase_anchor_ticks != 0 {
        root.insert(
            "phaseAnchorTicks".into(),
            Value::from(p.phase_anchor_ticks),
        );
    }

    // journal pointer.
    let mut jb = Map::new();
    jb.insert("entryCount".into(), Value::from(session.seq()));
    if let Some(last) = session.journal().last() {
        jb.insert("tipId".into(), Value::String(last.id.clone()));
    } else {
        jb.insert("tipId".into(), Value::Null);
    }
    jb.insert(
        "tipHash".into(),
        Value::String(session.tip_hash().to_string()),
    );
    jb.insert(
        "genesisHash".into(),
        Value::String(GENESIS_HASH.to_string()),
    );
    root.insert("journal".into(), Value::Object(jb));

    // preserve any unknown top-level fields.
    with_extra(root, &p.extra)
}

/// One effect from a chain (E5 §16.1).
///
/// Written by hand, like `device_zone_val`, and read back by `parse_fx`. A field
/// this function does not write is **DESTROYED on save, not merely ignored**
/// (E0 §9.3) — which is why `params`, `sidechain` and `extra` are all here and
/// why `parse_fx` reads every one of them.
fn fx_val(f: &crate::model::Fx) -> Value {
    let mut m = Map::new();
    m.insert("fxId".into(), Value::String(f.id.clone()));
    m.insert("kind".into(), Value::String(f.kind.wire_name().into()));
    if !f.params.is_empty() {
        let mut pm = Map::new();
        for (k, v) in &f.params {
            pm.insert(k.clone(), num_val(v));
        }
        m.insert("params".into(), Value::Object(pm));
    }
    if let Some(src) = &f.sidechain {
        m.insert("sidechain".into(), Value::String(src.wire_name()));
    }
    with_extra(m, &f.extra)
}

fn fx_chain_val(chain: &[crate::model::Fx]) -> Value {
    Value::Array(chain.iter().map(fx_val).collect())
}

/// An effect from the checkpoint. An UNKNOWN `kind` yields `None` (the effect is
/// skipped) rather than being coerced, for the same reason `parse_device` does
/// it: a project written by a newer build with an effect this one cannot
/// evaluate must not be silently reinterpreted as a different effect.
fn parse_fx(v: &Value) -> Option<crate::model::Fx> {
    use crate::model::{Fx, FxKind};
    let o = v.as_object()?;
    let kind = FxKind::parse(o.get("kind").and_then(Value::as_str)?)?;
    let mut f = Fx::new(
        o.get("fxId").and_then(Value::as_str).unwrap_or("").to_string(),
        kind,
    );
    if let Some(pm) = o.get("params").and_then(Value::as_object) {
        for (k, v) in pm {
            if let Some(n) = as_number(v) {
                f.params.insert(k.clone(), Num(n.clone()));
            }
        }
    }
    f.sidechain = o
        .get("sidechain")
        .and_then(Value::as_str)
        .and_then(crate::routing::NodeRef::parse);
    f.extra = extra_of(o, &["fxId", "kind", "params", "sidechain"]);
    Some(f)
}

fn parse_fx_chain(v: Option<&Value>) -> Vec<crate::model::Fx> {
    v.and_then(Value::as_array)
        .map(|a| a.iter().filter_map(parse_fx).collect())
        .unwrap_or_default()
}

fn routing_val(r: &crate::routing::Routing) -> Value {
    let mut m = Map::new();
    if !r.nodes.is_empty() {
        m.insert(
            "nodes".into(),
            Value::Array(
                r.nodes
                    .iter()
                    .map(|n| {
                        let mut nm = Map::new();
                        nm.insert("nodeId".into(), Value::String(n.id.clone()));
                        nm.insert("kind".into(), Value::String(n.kind.wire_name().into()));
                        nm.insert("name".into(), Value::String(n.name.clone()));
                        // The node fader (`route.node.set`). Omitted while it
                        // is still the INT-shaped 0 default, so a pre-fader
                        // node's bytes are unchanged; a float-shaped 0.0 is a
                        // real value and IS written (shape-aware equality).
                        if !crate::routing::gain_db_is_default(&n.gain_db) {
                            nm.insert("gainDb".into(), num_val(&n.gain_db));
                        }
                        // E5: the node's insert chain. Omitted when empty, so a
                        // pre-E5 node's bytes are unchanged.
                        if !n.fx.is_empty() {
                            nm.insert("fx".into(), fx_chain_val(&n.fx));
                        }
                        with_extra(nm, &n.extra)
                    })
                    .collect(),
            ),
        );
    }
    if !r.edges.is_empty() {
        m.insert(
            "edges".into(),
            Value::Array(
                r.edges
                    .iter()
                    .map(|e| {
                        let mut em = Map::new();
                        em.insert("edgeId".into(), Value::String(e.id.clone()));
                        em.insert("from".into(), Value::String(e.from.wire_name()));
                        em.insert("to".into(), Value::String(e.to.wire_name()));
                        em.insert("level".into(), num_val(&e.level));
                        em.insert("tap".into(), Value::String(e.tap.wire_name().into()));
                        with_extra(em, &e.extra)
                    })
                    .collect(),
            ),
        );
    }
    with_extra(m, &r.extra)
}

fn parse_routing(v: &Value) -> crate::routing::Routing {
    use crate::routing::{NodeKind, NodeRef, RouteEdge, RouteNode, Routing, Tap};
    let mut r = Routing::default();
    let Some(o) = v.as_object() else {
        return r;
    };
    if let Some(ns) = o.get("nodes").and_then(Value::as_array) {
        for nv in ns {
            let Some(no) = nv.as_object() else { continue };
            let Some(id) = no.get("nodeId").and_then(Value::as_str) else {
                continue;
            };
            r.nodes.push(RouteNode {
                id: id.to_string(),
                kind: no
                    .get("kind")
                    .and_then(Value::as_str)
                    .and_then(NodeKind::parse)
                    .unwrap_or(NodeKind::Bus),
                name: no
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or(id)
                    .to_string(),
                // READ what the writer writes, or a saved fader is DESTROYED
                // on the next save (the E0 §9.3 bug class): a field the
                // checkpoint does not read back reopens at unity and then
                // saves as unity.
                gain_db: no
                    .get("gainDb")
                    .and_then(as_number)
                    .map(|n| Num(n.clone()))
                    .unwrap_or_else(crate::routing::gain_db_default),
                fx: parse_fx_chain(no.get("fx")),
                extra: extra_of(no, &["nodeId", "kind", "name", "gainDb", "fx"]),
            });
        }
    }
    if let Some(es) = o.get("edges").and_then(Value::as_array) {
        for ev in es {
            let Some(eo) = ev.as_object() else { continue };
            let (Some(id), Some(from), Some(to)) = (
                eo.get("edgeId").and_then(Value::as_str),
                eo.get("from").and_then(Value::as_str).and_then(NodeRef::parse),
                eo.get("to").and_then(Value::as_str).and_then(NodeRef::parse),
            ) else {
                continue;
            };
            r.edges.push(RouteEdge {
                id: id.to_string(),
                from,
                to,
                level: eo
                    .get("level")
                    .and_then(as_number)
                    .map(|n| Num(n.clone()))
                    .unwrap_or_else(|| Num::int(1)),
                tap: eo
                    .get("tap")
                    .and_then(Value::as_str)
                    .and_then(Tap::parse)
                    .unwrap_or(Tap::Post),
                extra: extra_of(eo, &["edgeId", "from", "to", "level", "tap"]),
            });
        }
    }
    r.extra = extra_of(o, &["nodes", "edges"]);
    r
}

fn crossfade_val(x: &Crossfade) -> Value {
    let mut m = Map::new();
    m.insert("clipIdA".into(), Value::String(x.clip_id_a.clone()));
    m.insert("clipIdB".into(), Value::String(x.clip_id_b.clone()));
    m.insert("lengthTicks".into(), Value::from(x.length_ticks));
    m.insert(
        "shape".into(),
        Value::String(x.curve.wire_name().to_string()),
    );
    Value::Object(m)
}

fn take_val(t: &TakeRecord) -> Value {
    let mut m = Map::new();
    m.insert("takeId".into(), Value::String(t.take_id.clone()));
    m.insert("requestId".into(), Value::String(t.request_id.clone()));
    m.insert(
        "sourceCommand".into(),
        Value::String(t.source_command.clone()),
    );
    let mut hashes = Map::new();
    for (k, v) in &t.asset_hashes {
        hashes.insert(k.clone(), Value::String(v.clone()));
    }
    m.insert("assetHashes".into(), Value::Object(hashes));
    m.insert("engineIdentity".into(), t.engine_identity.clone());
    m.insert(
        "status".into(),
        Value::String(
            match t.status {
                TakeStatus::Candidate => "candidate",
                TakeStatus::Promoted => "promoted",
                TakeStatus::Discarded => "discarded",
                TakeStatus::Offline => "offline",
            }
            .to_string(),
        ),
    );
    if let Some(c) = &t.promoted_into {
        m.insert("promotedInto".into(), Value::String(c.clone()));
    }
    if let Some(a) = &t.prior_asset {
        m.insert("priorAsset".into(), Value::String(a.clone()));
    }
    Value::Object(m)
}

const KNOWN_ROOT_KEYS: &[&str] = &[
    "formatVersion",
    "projectId",
    "name",
    "tempo",
    "timeSig",
    "key",
    "sampleRateHz",
    "ppq",
    "sections",
    "markers",
    "tracks",
    "clips",
    "masterBus",
    "engineCrossfades",
    "engineTakes",
    "engineRouting",
    "phaseAnchorTicks",
    "journal",
];

/// Reconstruct a Project from a project.json checkpoint value.
pub fn from_project_json(v: &Value) -> Result<Project, CommandError> {
    let obj = v
        .as_object()
        .ok_or_else(|| CommandError::Io("project.json is not an object".into()))?;
    let sample_rate = obj
        .get("sampleRateHz")
        .and_then(Value::as_u64)
        .unwrap_or(48_000) as u32;
    let bpm_wire = obj
        .get("tempo")
        .and_then(|t| t.get("bpm"))
        .and_then(as_number)
        .map(|n| Num(n.clone()))
        .unwrap_or_else(|| Num::int(120));
    let bpm = Bpm::from_json_number(&bpm_wire.0)?;
    let mut p = Project::new(sample_rate, TempoMap::single(bpm));
    p.bpm_wire = bpm_wire;
    if let Some(id) = obj.get("projectId").and_then(Value::as_str) {
        p.project_id = id.to_string();
    }
    if let Some(name) = obj.get("name").and_then(Value::as_str) {
        p.name = name.to_string();
    }
    if let Some(key) = obj.get("key").and_then(Value::as_str) {
        p.key = key.to_string();
    }
    if let Some(ts) = obj.get("timeSig").and_then(Value::as_object) {
        p.time_sig = TimeSig {
            numerator: ts.get("numerator").and_then(Value::as_u64).unwrap_or(4) as u32,
            denominator: ts.get("denominator").and_then(Value::as_u64).unwrap_or(4) as u32,
        };
    }
    if let Some(sections) = obj.get("sections").and_then(Value::as_array) {
        for s in sections {
            p.sections.push(parse_section(s)?);
        }
    }
    if let Some(markers) = obj.get("markers").and_then(Value::as_array) {
        for mk in markers {
            p.markers.push(parse_marker(mk)?);
        }
    }
    if let Some(mb) = obj.get("masterBus") {
        p.master = parse_master(mb);
    }

    // tracks then clips (clips reference trackId).
    let mut tracks: Vec<Track> = Vec::new();
    if let Some(ts) = obj.get("tracks").and_then(Value::as_array) {
        for t in ts {
            tracks.push(parse_track(t)?);
        }
    }
    // index order.
    tracks.sort_by_key(|_| 0usize); // stable; explicit index applied below
    if let Some(ts) = obj.get("tracks").and_then(Value::as_array) {
        // reorder by declared index
        let mut indexed: Vec<(u64, Track)> = ts
            .iter()
            .zip(tracks.into_iter())
            .map(|(tv, t)| (tv.get("index").and_then(Value::as_u64).unwrap_or(0), t))
            .collect();
        indexed.sort_by_key(|(i, _)| *i);
        tracks = indexed.into_iter().map(|(_, t)| t).collect();
    }
    p.tracks = tracks;

    if let Some(cs) = obj.get("clips").and_then(Value::as_array) {
        for cv in cs {
            let (track_id, clip) = parse_clip(cv)?;
            let ti = p.track_index(&track_id).ok_or_else(|| {
                CommandError::Io(format!("clip references unknown track {track_id}"))
            })?;
            p.tracks[ti].clips.push(clip);
        }
    }

    if let Some(xs) = obj.get("engineCrossfades").and_then(Value::as_array) {
        for x in xs {
            p.crossfades.push(parse_crossfade(x));
        }
    }
    if let Some(tk) = obj.get("engineTakes").and_then(Value::as_array) {
        for t in tk {
            p.takes.push(parse_take(t));
        }
    }
    if let Some(r) = obj.get("engineRouting") {
        p.routing = parse_routing(r);
    }
    p.phase_anchor_ticks = obj
        .get("phaseAnchorTicks")
        .and_then(Value::as_u64)
        .unwrap_or(0);

    // preserve unknown top-level fields.
    for (k, val) in obj {
        if !KNOWN_ROOT_KEYS.contains(&k.as_str()) {
            p.extra.insert(k.clone(), val.clone());
        }
    }

    p.rematerialize_all();
    p.sort_sections_markers();
    Ok(p)
}

fn extra_of(obj: &Map<String, Value>, known: &[&str]) -> Map<String, Value> {
    let mut m = Map::new();
    for (k, v) in obj {
        if !known.contains(&k.as_str()) {
            m.insert(k.clone(), v.clone());
        }
    }
    m
}

fn parse_section(v: &Value) -> Result<Section, CommandError> {
    let o = v
        .as_object()
        .ok_or_else(|| CommandError::Io("section not object".into()))?;
    Ok(Section {
        id: o
            .get("sectionId")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        name: o
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        start_ticks: o.get("startTicks").and_then(Value::as_u64).unwrap_or(0),
        color: o.get("color").and_then(Value::as_str).map(String::from),
        extra: extra_of(o, &["sectionId", "name", "startTicks", "color"]),
    })
}

fn parse_marker(v: &Value) -> Result<Marker, CommandError> {
    let o = v
        .as_object()
        .ok_or_else(|| CommandError::Io("marker not object".into()))?;
    Ok(Marker {
        id: o
            .get("markerId")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        position_ticks: o.get("positionTicks").and_then(Value::as_u64).unwrap_or(0),
        label: o
            .get("label")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        color: o.get("color").and_then(Value::as_str).map(String::from),
        extra: extra_of(o, &["markerId", "positionTicks", "label", "color"]),
    })
}

fn parse_master(v: &Value) -> MasterBus {
    let o = match v.as_object() {
        Some(o) => o,
        None => return MasterBus::default(),
    };
    let mut mb = MasterBus::default();
    if let Some(g) = o.get("gainDb").and_then(as_number) {
        mb.gain_db = Num(g.clone());
    }
    if let Some(lim) = o.get("limiter").and_then(Value::as_object) {
        mb.limiter = Limiter {
            enabled: lim.get("enabled").and_then(Value::as_bool).unwrap_or(false),
            ceiling_db: lim
                .get("ceilingDb")
                .and_then(as_number)
                .map(|n| Num(n.clone()))
                .unwrap_or_else(|| Num::int(-1)),
            release_ms: lim
                .get("releaseMs")
                .and_then(as_number)
                .map(|n| Num(n.clone()))
                .unwrap_or_else(|| Num::int(50)),
        };
    }
    mb.fx = parse_fx_chain(o.get("fx"));
    mb.extra = extra_of(o, &["gainDb", "limiter", "fx"]);
    mb
}

fn parse_track(v: &Value) -> Result<Track, CommandError> {
    let o = v
        .as_object()
        .ok_or_else(|| CommandError::Io("track not object".into()))?;
    let id = o
        .get("trackId")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let name = o
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let mut t = Track::new(id, name);
    if let Some(c) = o.get("color").and_then(Value::as_str) {
        t.color = c.to_string();
    }
    if let Some(h) = o.get("heightPx").and_then(Value::as_u64) {
        t.height_px = h as u32;
    }
    t.mute = o.get("muted").and_then(Value::as_bool).unwrap_or(false);
    t.solo = o.get("soloed").and_then(Value::as_bool).unwrap_or(false);
    t.armed = o.get("armed").and_then(Value::as_bool).unwrap_or(false);
    // Absent means channel 0, which is both the model default and what every
    // project written before this field existed meant.
    t.input_channel = o
        .get("inputChannel")
        .and_then(Value::as_u64)
        .unwrap_or(0) as u32;
    if let Some(g) = o.get("gainDb").and_then(as_number) {
        t.gain = Num(g.clone());
    }
    if let Some(pan) = o.get("pan").and_then(as_number) {
        t.pan = Num(pan.clone());
    }
    if let Some(s) = o.get("sends").and_then(Value::as_object) {
        t.sends = Sends {
            a: s.get("a")
                .and_then(as_number)
                .map(|n| Num(n.clone()))
                .unwrap_or_else(|| Num::int(0)),
            b: s.get("b")
                .and_then(as_number)
                .map(|n| Num(n.clone()))
                .unwrap_or_else(|| Num::int(0)),
        };
    }
    if let Some(a) = o.get("automation").and_then(Value::as_object) {
        let mut auto = Automation::default();
        if let Some(v) = a.get("volume").and_then(Value::as_array) {
            auto.volume = v.iter().map(parse_auto_point).collect();
        }
        if let Some(v) = a.get("pan").and_then(Value::as_array) {
            auto.pan = v.iter().map(parse_auto_point).collect();
        }
        if let Some(lanes) = a.get("lanes").and_then(Value::as_object) {
            for (k, v) in lanes {
                let Ok(path) = crate::paramref::ParamRef::parse(k) else {
                    // Not even well-formed. Park it in `extra` rather than
                    // discard it: this build cannot represent it as a lane, but
                    // it must still survive a round-trip.
                    auto.extra.insert(k.clone(), v.clone());
                    continue;
                };
                let points: Vec<_> = v
                    .as_array()
                    .map(|arr| arr.iter().map(parse_auto_point).collect())
                    .unwrap_or_default();
                auto.lanes.insert(path, points);
            }
        }
        // Unknown keys under `automation` survive round-trip (design §9.3: the
        // absence of this map is why an older binary would DESTROY, not merely
        // ignore, automation-level metadata).
        auto.extra.extend(
            a.iter()
                .filter(|(k, _)| !matches!(k.as_str(), "volume" | "pan" | "lanes"))
                .map(|(k, v)| (k.clone(), v.clone())),
        );
        // Exactly one storage location per ParamRef: if a foreign writer put a
        // legacy path in the map, fold it into its legacy field.
        auto.normalize();
        t.automation = auto;
    }
    // `eq` is the v2 first-class key; `engineEq` is the v1 namespaced one and
    // is still accepted so older checkpoints load byte-identically.
    if let Some(bands) = o
        .get("eq")
        .or_else(|| o.get("engineEq"))
        .and_then(Value::as_array)
    {
        for (i, bv) in bands.iter().take(4).enumerate() {
            if let Some(bo) = bv.as_object() {
                if let Some(f) = bo.get("freqHz").and_then(as_number) {
                    t.eq[i].freq_hz = Num(f.clone());
                }
                if let Some(g) = bo.get("gainDb").and_then(as_number) {
                    t.eq[i].gain_db = Num(g.clone());
                }
                if let Some(q) = bo.get("q").and_then(as_number) {
                    t.eq[i].q = Num(q.clone());
                }
            }
        }
    }
    if let Some(arr) = o.get("devices").and_then(Value::as_array) {
        t.devices = arr.iter().filter_map(parse_device).collect();
    }
    t.fx = parse_fx_chain(o.get("fx"));
    t.extra = extra_of(
        o,
        &[
            "trackId",
            "name",
            "index",
            "color",
            "heightPx",
            "muted",
            "soloed",
            "armed",
            "inputChannel",
            "gainDb",
            "pan",
            "sends",
            "automation",
            "eq",
            "engineEq",
            "devices",
            "fx",
        ],
    );
    Ok(t)
}

/// A device from the checkpoint. An UNKNOWN `kind` yields `None` (the device
/// is skipped) rather than being coerced to a synth: a project written by a
/// newer build with a device kind this one cannot evaluate must not be silently
/// reinterpreted as an instrument.
fn parse_device(v: &Value) -> Option<crate::model::Device> {
    use crate::model::{Device, DeviceKind};
    let o = v.as_object()?;
    let kind = match o.get("kind").and_then(Value::as_str)? {
        "synth" => DeviceKind::Synth,
        "sampler" => DeviceKind::Sampler,
        "drum" => DeviceKind::Drum,
        _ => return None,
    };
    let mut d = Device::new(
        o.get("deviceId")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        kind,
    );
    if let Some(pm) = o.get("params").and_then(Value::as_object) {
        for (k, v) in pm {
            if let Some(n) = as_number(v) {
                d.params.insert(k.clone(), Num(n.clone()));
            }
        }
    }
    if let Some(arr) = o.get("zones").and_then(Value::as_array) {
        d.zones = arr.iter().filter_map(parse_device_zone).collect();
        // Re-establish the total order on load. The writer already sorts, but
        // a checkpoint from a foreign writer must not be able to change which
        // of two overlapping zones wins at note-on.
        d.sort_zones();
    }
    d.extra = extra_of(o, &["deviceId", "kind", "params", "zones"]);
    Some(d)
}

/// One zone from the checkpoint. A zone with no `sourceId` is DROPPED rather
/// than defaulted to the empty string: a binding that names no asset is the
/// silent-degradation case this whole feature exists to close, and compile
/// would only turn it into "references unloaded source ''".
fn parse_device_zone(v: &Value) -> Option<crate::model::DeviceZone> {
    use crate::model::DeviceZone;
    let o = v.as_object()?;
    let source_id = o.get("sourceId").and_then(Value::as_str)?;
    if source_id.is_empty() {
        return None;
    }
    let num = |k: &str, d: Num| o.get(k).and_then(as_number).map(|n| Num(n.clone())).unwrap_or(d);
    Some(DeviceZone {
        id: o
            .get("zoneId")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        source_id: source_id.to_string(),
        root_pitch: num("rootPitch", Num::int(60)),
        lo_pitch: num("loPitch", Num::int(0)),
        hi_pitch: num("hiPitch", Num::int(crate::model::MAX_PITCH)),
        gain: num("gainDb", DeviceZone::default_gain()),
        pan: num("pan", DeviceZone::default_pan()),
        extra: extra_of(
            o,
            &[
                "zoneId",
                "sourceId",
                "rootPitch",
                "loPitch",
                "hiPitch",
                "gainDb",
                "pan",
            ],
        ),
    })
}

fn parse_auto_point(v: &Value) -> AutoPoint {
    let o = v.as_object().cloned().unwrap_or_default();
    AutoPoint {
        id: o
            .get("pointId")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        position_ticks: o.get("positionTicks").and_then(Value::as_u64).unwrap_or(0),
        value: o
            .get("value")
            .and_then(as_number)
            .map(|n| Num(n.clone()))
            .unwrap_or_else(|| Num::int(0)),
        extra: extra_of(&o, &["pointId", "positionTicks", "value"]),
    }
}

fn parse_clip(v: &Value) -> Result<(String, Clip), CommandError> {
    let o = v
        .as_object()
        .ok_or_else(|| CommandError::Io("clip not object".into()))?;
    let id = o
        .get("clipId")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let track_id = o
        .get("trackId")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let asset = o
        .get("assetHash")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let start = o.get("startTicks").and_then(Value::as_u64).unwrap_or(0);
    let length = o.get("lengthTicks").and_then(Value::as_u64).unwrap_or(1);
    let offset = o
        .get("sourceOffsetTicks")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let mut c = Clip::new_catalog(id.clone(), asset, start, length, offset);
    // E1: `kind` is absent on every clip written before E1 and on every audio
    // clip written after, so the default is Audio and old files are untouched.
    if o.get("kind").and_then(Value::as_str) == Some("midi") {
        c.kind = crate::model::ClipKind::Midi;
    }
    if let Some(arr) = o.get("notes").and_then(Value::as_array) {
        c.notes = arr.iter().map(parse_note).collect();
        crate::note::sort_notes(&mut c.notes);
    }
    if let Some(n) = o.get("name").and_then(Value::as_str) {
        c.name = n.to_string();
    }
    if let Some(g) = o.get("gainDb").and_then(as_number) {
        c.gain = Num(g.clone());
        c.gain_db = c.gain.as_f64() as f32;
    }
    c.muted = o.get("muted").and_then(Value::as_bool).unwrap_or(false);
    if let Some(f) = o.get("fadeIn") {
        c.fade_in = parse_fade(f);
    }
    if let Some(f) = o.get("fadeOut") {
        c.fade_out = parse_fade(f);
    }
    if let Some(w) = o.get("warp").and_then(Value::as_object) {
        let mode = match w.get("mode").and_then(Value::as_str) {
            Some("conform") => WarpMode::Conform,
            _ => WarpMode::Ratio,
        };
        c.warp = Warp {
            mode,
            stretch_ratio: w
                .get("stretchRatio")
                .and_then(as_number)
                .map(|n| Num(n.clone()))
                .unwrap_or_else(|| Num::int(1)),
        };
    }
    c.phase_anchor_ticks = o
        .get("phaseAnchorTicks")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    c.offline = o.get("offline").and_then(Value::as_bool).unwrap_or(false);
    c.extra = extra_of(
        o,
        &[
            "clipId",
            "trackId",
            "name",
            "assetHash",
            "startTicks",
            "lengthTicks",
            "sourceOffsetTicks",
            "gainDb",
            "muted",
            "fadeIn",
            "fadeOut",
            "warp",
            "phaseAnchorTicks",
            "offline",
            "kind",
            "notes",
        ],
    );
    Ok((track_id, c))
}

fn parse_fade(v: &Value) -> FadeSpec {
    let o = v.as_object().cloned().unwrap_or_default();
    FadeSpec {
        length_ticks: o.get("lengthTicks").and_then(Value::as_u64).unwrap_or(0),
        curve: parse_curve(o.get("shape").and_then(Value::as_str)),
    }
}

fn parse_curve(s: Option<&str>) -> FadeCurve {
    match s {
        Some("linear") => FadeCurve::Linear,
        Some("exponential") => FadeCurve::Exponential,
        Some("logarithmic") => FadeCurve::Logarithmic,
        _ => FadeCurve::EqualPower,
    }
}

fn parse_crossfade(v: &Value) -> Crossfade {
    let o = v.as_object().cloned().unwrap_or_default();
    Crossfade {
        clip_id_a: o
            .get("clipIdA")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        clip_id_b: o
            .get("clipIdB")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        length_ticks: o.get("lengthTicks").and_then(Value::as_u64).unwrap_or(0),
        curve: parse_curve(o.get("shape").and_then(Value::as_str)),
    }
}

fn parse_take(v: &Value) -> TakeRecord {
    let o = v.as_object().cloned().unwrap_or_default();
    let mut asset_hashes = std::collections::BTreeMap::new();
    if let Some(h) = o.get("assetHashes").and_then(Value::as_object) {
        for (k, val) in h {
            if let Some(s) = val.as_str() {
                asset_hashes.insert(k.clone(), s.to_string());
            }
        }
    }
    TakeRecord {
        take_id: o
            .get("takeId")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        request_id: o
            .get("requestId")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        source_command: o
            .get("sourceCommand")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        asset_hashes,
        engine_identity: o.get("engineIdentity").cloned().unwrap_or(Value::Null),
        // Every status the writer above can emit needs an arm here. `"offline"`
        // did not have one, so a PURGED take reloaded as a Candidate: the take
        // came back looking available while `take.purge`'s host path had
        // already removed its audio from disk, and `take.restore` — whose
        // precondition is `Offline` — became impossible after a reopen.
        // An unknown status still falls back to Candidate, which is the right
        // reading of a future writer's value, not a licence to drop ours.
        status: match o.get("status").and_then(Value::as_str) {
            Some("promoted") => TakeStatus::Promoted,
            Some("discarded") => TakeStatus::Discarded,
            Some("offline") => TakeStatus::Offline,
            _ => TakeStatus::Candidate,
        },
        promoted_into: o
            .get("promotedInto")
            .and_then(Value::as_str)
            .map(String::from),
        prior_asset: o
            .get("priorAsset")
            .and_then(Value::as_str)
            .map(String::from),
    }
}

// keep EqBand import used (parse_track reads eq defaults from Track::new).
#[allow(unused_imports)]
use crate::model::default_eq as _default_eq_marker;
#[allow(dead_code)]
fn _eq_marker() -> [EqBand; 4] {
    crate::model::default_eq()
}
