//! `Session`: the command bus. Owns the `Project`, the hash-chained journal,
//! transactional undo units, undo/redo (journaled forward, history never
//! rewrites), a cheap snapshot, and a diff-cursor.
//!
//! Flow of `submit`: validate params against the embedded catalog, then apply
//! (which itself validates semantically and never partially mutates), then, if
//! the catalog marks the command journaled, append a hash-chained envelope and
//! record undo/diff bookkeeping. A failed command mutates nothing and is not
//! journaled. If the append fails after the apply, the already-computed inverse
//! is applied in memory and not itself journaled, so the rejection leaves no edit.

use std::collections::{HashSet, VecDeque};
use std::sync::Arc;

use serde_json::Value;

use crate::catalog::Catalog;
use crate::cmd::Cmd;
use crate::diff::{ChangeScope, Changes};
use crate::envelope::{result_ok, Actor, EntryMeta, Envelope, InverseRef, GENESIS_HASH};
use crate::error::CommandError;
use crate::journal::{JournalSink, MemoryJournal};
use crate::model::Project;

/// How many recent entries the diff-cursor can serve a delta for before it
/// tells a reader to resync.
const DIFF_WINDOW: usize = 512;

/// What every refusal on a poisoned bracket says. ONE spelling, because three
/// call sites needing to agree on a sentence is how a sentence stops being the
/// same sentence — and this one is the difference between a caller learning its
/// gesture was undone and a caller reading `Ok`.
const POISONED: &str =
    "transaction was aborted by an inner step: it applied nothing and cannot be committed";

/// One atomic undo unit: a single command's inverse, or a txn group's.
#[derive(Debug, Clone)]
struct UndoUnit {
    /// The inverse command sequences, one per contained journaled+undoable
    /// command, in APPLICATION order. To undo, apply them last-first, and
    /// each sequence in order.
    inverses: Vec<Vec<Cmd>>,
    /// The forward commands (to redo), in application order.
    forwards: Vec<Cmd>,
}

/// The open transaction bracket, which is RE-ENTRANT since one gesture that
/// composes two engine operations (a stem import is `import.stems` plus a
/// `track.add` and a whole `import_audio` per file) has to be one undo step.
///
/// # Why a depth counter and not nested units
///
/// v1 refused nesting outright, and the refusal was right about the thing it
/// was protecting: TWO undo units, or two journaled brackets, out of one
/// gesture is exactly the defect. What it also did was make composition
/// impossible, so `import_stems_params` opened no bracket at all and produced
/// 2N units instead of 1.
///
/// Depth restores composition without giving up the guarantee: there is still
/// exactly ONE `UndoUnit` and exactly ONE journaled `txn.begin`/`txn.commit`
/// pair per bracket, however many times it is re-entered. An inner `txn.begin`
/// pushes an id and journals NOTHING; an inner `txn.commit` pops it and
/// journals nothing. Only the outermost commit closes the unit.
///
/// The journal shape is the reason the inner markers are elided rather than
/// written: a journal containing nested markers is one an older build CANNOT
/// replay — its `Session` would hit the very "v1 transactions do not nest"
/// error above and refuse to open the project. Eliding keeps every journal
/// this code writes flat, which is the only shape both builds agree on.
#[derive(Debug, Clone)]
struct OpenTxn {
    /// The `txnId` of every open `txn.begin`, outermost first. `len()` IS the
    /// depth; a commit must name the innermost, so mismatched pairing is still
    /// a typed error at every level rather than only at the top.
    ids: Vec<String>,
    unit: UndoUnit,
    /// An inner step aborted this bracket. The unit has already been rolled
    /// back and journal-compensated; the frame stays open only so the outer
    /// caller's commit can be REFUSED rather than silently committing a
    /// transaction whose contents no longer exist. See [`Session::abort_txn`].
    poisoned: bool,
}

impl OpenTxn {
    fn opened(txn_id: String) -> Self {
        OpenTxn {
            ids: vec![txn_id],
            unit: UndoUnit {
                inverses: Vec::new(),
                forwards: Vec::new(),
            },
            poisoned: false,
        }
    }
}

/// A cheap immutable snapshot for UI/FFI/MCP readers.
#[derive(Debug, Clone)]
pub struct Snapshot {
    pub project: Arc<Project>,
    pub seq: u64,
}

/// What `submit` reports.
#[derive(Debug, Clone, PartialEq)]
pub struct Submitted {
    pub journaled: bool,
    pub mutated: bool,
    /// The new journal sequence (entry count) after this submit.
    pub seq: u64,
    /// True when the command id was already journaled (idempotent no-op).
    pub duplicate: bool,
    pub scopes: Vec<ChangeScope>,
}

/// Supplies per-entry metadata (id/ts/actor) for journaled entries, including
/// the fresh entries undo/redo append. The core mints nothing (no clock, no
/// id generator): the app supplies ULIDs and timestamps.
pub trait MetaSource {
    fn next_meta(&mut self, cmd: &Cmd) -> EntryMeta;
}

/// A deterministic MetaSource for tests, examples, and headless replay: ids
/// are zero-padded counters (valid ULID shape), ts is fixed-valid. Real apps
/// pass real ULIDs/timestamps instead.
#[derive(Debug, Clone)]
pub struct SeqMeta {
    next: u64,
    actor: Actor,
    ts: String,
}

impl SeqMeta {
    pub fn new(actor: Actor) -> Self {
        SeqMeta {
            next: 1,
            actor,
            ts: "2026-07-11T20:00:00Z".to_string(),
        }
    }

    pub fn user(name: &str) -> Self {
        SeqMeta::new(Actor::user(name))
    }

    /// Continue counting from `next` (so undo/redo entries do not reuse ids
    /// already in the journal, which replay would treat as duplicates).
    pub fn starting_at(next: u64, actor: Actor) -> Self {
        SeqMeta {
            next,
            actor,
            ts: "2026-07-11T20:00:00Z".to_string(),
        }
    }

    pub fn peek(&self) -> u64 {
        self.next
    }
}

impl MetaSource for SeqMeta {
    fn next_meta(&mut self, _cmd: &Cmd) -> EntryMeta {
        // 26-char Crockford-base32-valid id: leading digit in 0-7, rest 0-9.
        let id = format!("{:026}", self.next);
        self.next += 1;
        EntryMeta {
            id,
            ts: self.ts.clone(),
            actor: self.actor.clone(),
        }
    }
}

pub struct Session {
    project: Project,
    journal: Vec<Envelope>,
    // `+ Send` (additive tightening, requested by lane L6): every concrete
    // sink (MemoryJournal, FileJournal) is already Send, and the bound lets a
    // Session cross threads inside the agent surface's FFI/MCP `Arc<Mutex<..>>`
    // without a global. No wasm impact (the trait itself is unchanged).
    sink: Box<dyn JournalSink + Send>,
    tip_hash: String,
    undo_stack: Vec<UndoUnit>,
    redo_stack: Vec<UndoUnit>,
    open_txn: Option<OpenTxn>,
    seen_ids: HashSet<String>,
    snapshot_cache: Option<Snapshot>,
    change_log: VecDeque<(u64, Vec<ChangeScope>)>,
}

impl Session {
    pub fn new(project: Project) -> Self {
        Self::with_sink(project, Box::new(MemoryJournal::new()))
    }

    pub fn with_sink(project: Project, sink: Box<dyn JournalSink + Send>) -> Self {
        Session {
            project,
            journal: Vec::new(),
            sink,
            tip_hash: GENESIS_HASH.to_string(),
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            open_txn: None,
            seen_ids: HashSet::new(),
            snapshot_cache: None,
            change_log: VecDeque::new(),
        }
    }

    pub fn project(&self) -> &Project {
        &self.project
    }

    pub fn project_mut(&mut self) -> &mut Project {
        &mut self.project
    }

    /// Set each clip's `offline` flag via a predicate (package open uses this
    /// to mark clips whose asset is absent under audio/). Does not journal:
    /// offline is a load-time view of asset presence, not a model mutation.
    pub fn mark_offline_by(&mut self, mut is_offline: impl FnMut(&crate::model::Clip) -> bool) {
        for track in &mut self.project.tracks {
            for clip in &mut track.clips {
                clip.offline = is_offline(clip);
            }
        }
        self.snapshot_cache = None;
    }

    pub fn seq(&self) -> u64 {
        self.journal.len() as u64
    }

    pub fn tip_hash(&self) -> &str {
        &self.tip_hash
    }

    pub fn journal(&self) -> &[Envelope] {
        &self.journal
    }

    /// Point this session's appends at a NEW sink.
    ///
    /// `Package::save` rewrites `journal.jsonl` via tmp + atomic rename. That
    /// rename replaces the inode the old sink's file descriptor is bound to,
    /// so every command appended AFTER a save would land in an unlinked file
    /// and vanish. The saver must hand the session a sink reopened on the new
    /// path; this is that handoff. The caller is responsible for the new sink
    /// reporting the correct `len()` (the checkpoint pointer reads it).
    pub fn set_sink(&mut self, sink: Box<dyn JournalSink + Send>) {
        self.sink = sink;
    }

    /// Flush the journal sink durably (fsync for the file sink, no-op for the
    /// in-memory one). Appends are already pushed out of the process buffer on
    /// every command; this is the extra step that survives power loss.
    pub fn sync_journal(&mut self) -> Result<(), CommandError> {
        self.sink.sync()
    }

    pub fn undo_depth(&self) -> usize {
        self.undo_stack.len()
    }

    pub fn redo_depth(&self) -> usize {
        self.redo_stack.len()
    }

    pub fn in_txn(&self) -> bool {
        self.open_txn.is_some()
    }

    /// Untyped wire entry: parse name+params into a `Cmd`, then submit.
    pub fn submit_json(
        &mut self,
        meta: EntryMeta,
        name: &str,
        params: Value,
    ) -> Result<Submitted, CommandError> {
        // Validate against the catalog schema BEFORE typed parse so unknown
        // params produce a schema error, not a serde error.
        Catalog::get().validate_params(name, &params)?;
        let cmd = Cmd::from_wire(name, params)
            .map_err(|e| CommandError::SchemaViolation(format!("{name}: {e}")))?;
        self.submit(meta, cmd)
    }

    /// Submit a typed command through the bus.
    pub fn submit(&mut self, meta: EntryMeta, cmd: Cmd) -> Result<Submitted, CommandError> {
        self.submit_inner(meta, cmd, None)
    }

    /// Submit a command whose envelope inverse hint the host supplies
    /// (`import.audio`: the model records the io request, the host knows the
    /// clip it placed and thus the `clip.remove` that inverts it).
    pub fn submit_with_hint(
        &mut self,
        meta: EntryMeta,
        cmd: Cmd,
        hint: Cmd,
        undo_sequence: Vec<Cmd>,
    ) -> Result<Submitted, CommandError> {
        self.submit_inner(meta, cmd, Some((hint, undo_sequence)))
    }

    fn submit_inner(
        &mut self,
        meta: EntryMeta,
        cmd: Cmd,
        host_hint: Option<(Cmd, Vec<Cmd>)>,
    ) -> Result<Submitted, CommandError> {
        if self.seen_ids.contains(&meta.id) {
            return Ok(Submitted {
                journaled: false,
                mutated: false,
                seq: self.seq(),
                duplicate: true,
                scopes: Vec::new(),
            });
        }
        let name = cmd.name();
        let spec = Catalog::get()
            .spec(name)
            .ok_or_else(|| CommandError::UnknownCommand(name.to_string()))?;
        // Params validation (defense in depth; submit_json already did it, but
        // typed submit callers have not).
        Catalog::get().validate_params(name, &cmd.params_value())?;

        // Transaction markers are journaled records that bracket an undo unit.
        match &cmd {
            Cmd::TxnBegin { txn_id, .. } => {
                if let Some(open) = &mut self.open_txn {
                    if open.poisoned {
                        return Err(CommandError::Txn(POISONED.into()));
                    }
                    // RE-ENTRY. Not journaled: see `OpenTxn`. The bracket the
                    // caller believes it opened is the one already open, and
                    // its commit will be elided to match.
                    open.ids.push(txn_id.clone());
                    self.seen_ids.insert(meta.id);
                    return Ok(self.report(false, false, Vec::new()));
                }
                self.journal_entry(&meta, &cmd, None)?;
                self.open_txn = Some(OpenTxn::opened(txn_id.clone()));
                self.seen_ids.insert(meta.id);
                return Ok(self.report(true, false, Vec::new()));
            }
            Cmd::TxnCommit { txn_id } => {
                let open = self
                    .open_txn
                    .as_mut()
                    .ok_or_else(|| CommandError::Txn("txn.commit without open txn".into()))?;
                // A commit names the INNERMOST open bracket. Mismatch is a
                // typed error with nothing mutated and nothing popped, exactly
                // as it was when there was only ever one level.
                if open.ids.last().map(String::as_str) != Some(txn_id.as_str()) {
                    return Err(CommandError::Txn(format!(
                        "txn.commit id {txn_id} does not match open {}",
                        open.ids.last().cloned().unwrap_or_default()
                    )));
                }
                open.ids.pop();
                let outermost = open.ids.is_empty();
                let poisoned = open.poisoned;
                if poisoned {
                    // An inner step aborted. The unit is already rolled back
                    // and compensated in the journal, so there is nothing left
                    // to commit — and committing an empty unit while REPORTING
                    // success is the "half-applied transaction that says it
                    // worked" this whole mechanism exists to prevent. Refuse at
                    // every level so no caller in the chain reads Ok.
                    if outermost {
                        self.open_txn = None;
                    }
                    return Err(CommandError::Txn(POISONED.into()));
                }
                if !outermost {
                    // Inner close: no journal record, no undo unit. The
                    // outermost commit publishes the whole thing at once.
                    self.seen_ids.insert(meta.id);
                    return Ok(self.report(false, false, Vec::new()));
                }
                let mut open = self.open_txn.take().expect("checked above");
                if let Err(error) = self.journal_entry(&meta, &cmd, None) {
                    // The id was popped above to decide this was the outermost
                    // commit. Put the bracket back intact so the caller can
                    // retry or abort explicitly instead of losing the unit.
                    open.ids.push(txn_id.clone());
                    self.open_txn = Some(open);
                    return Err(error);
                }
                if !open.unit.forwards.is_empty() {
                    self.undo_stack.push(open.unit);
                    self.redo_stack.clear();
                }
                self.seen_ids.insert(meta.id);
                return Ok(self.report(true, false, Vec::new()));
            }
            _ => {}
        }

        // Nothing may join a bracket an inner step already rolled back. Without
        // this the outer caller's remaining commands would apply on top of a
        // reverted unit and then be published by a commit as though the reverted
        // half had happened — a half-applied transaction reporting success.
        if self.open_txn.as_ref().is_some_and(|t| t.poisoned) {
            return Err(CommandError::Txn(POISONED.into()));
        }

        // Undoable commands must carry an envelope inverse. Only import.audio
        // needs the host to supply it.
        if spec.undoable && host_hint.is_none() && matches!(cmd, Cmd::ImportAudio { .. } | Cmd::ImportStems { .. }) {
            return Err(CommandError::InvalidParams(
                "import commands must be submitted via submit_with_hint (host supplies the \
                 inverse of the material it places)"
                    .into(),
            ));
        }

        // Apply (validate-first, no partial mutation on error).
        let effect = self.project.apply_cmd(&cmd)?;

        let mut journaled = false;
        if spec.journaled {
            // Captured before journaling so a failed append can undo the apply
            // without a second trip through the bus (which would journal it).
            let rollback_commands = if spec.undoable {
                host_hint
                    .as_ref()
                    .map(|(_, sequence)| sequence.clone())
                    .unwrap_or_else(|| effect.inverse.clone())
            } else {
                Vec::new()
            };
            let inverse_ref = if spec.undoable {
                let Some(hint) = host_hint
                    .as_ref()
                    .map(|(h, _)| h.clone())
                    .or_else(|| effect.hint.clone())
                else {
                    let error = CommandError::Envelope(format!(
                        "undoable command {name} produced no inverse hint"
                    ));
                    return Err(self.rollback_unjournaled_mutation(
                        &rollback_commands,
                        effect.mutated,
                        error,
                    ));
                };
                Some(InverseRef::from_cmd(&hint))
            } else {
                None
            };
            if let Err(error) = self.journal_entry(&meta, &cmd, inverse_ref) {
                return Err(self.rollback_unjournaled_mutation(
                    &rollback_commands,
                    effect.mutated,
                    error,
                ));
            }
            journaled = true;

            if spec.undoable {
                let inverse_seq = host_hint
                    .map(|(_, seq)| seq)
                    .unwrap_or_else(|| effect.inverse.clone());
                self.push_undo(cmd.clone(), inverse_seq);
            }
            self.record_change(&effect.scopes);
        }

        self.seen_ids.insert(meta.id);
        self.snapshot_cache = None;
        Ok(self.report(journaled, effect.mutated, effect.scopes))
    }

    /// The model is applied before its envelope is appended so semantic
    /// validation can never leave a rejected entry in the journal. If that
    /// append then fails, apply the already-computed inverse directly (without
    /// journaling it) so a rejected command leaves no invisible in-memory edit.
    ///
    /// Distinct from [`Session::abort_txn`], which journals its rollback so a
    /// replay stays net-zero. Here the envelope never landed, so journaling
    /// the inverse would record an edit that undoes a command the journal
    /// does not contain.
    fn rollback_unjournaled_mutation(
        &mut self,
        inverse: &[Cmd],
        mutated: bool,
        original: CommandError,
    ) -> CommandError {
        if !mutated {
            return original;
        }
        if inverse.is_empty() {
            self.snapshot_cache = None;
            return CommandError::Io(format!(
                "{original}; the command mutated state but provided no rollback sequence—reload the project before continuing"
            ));
        }
        for command in inverse {
            if let Err(rollback_error) = self.project.apply_cmd(command) {
                self.snapshot_cache = None;
                return CommandError::Io(format!(
                    "{original}; in-memory journal rollback failed ({rollback_error})—reload the project before continuing"
                ));
            }
        }
        self.snapshot_cache = None;
        original
    }

    fn push_undo(&mut self, forward: Cmd, inverse_seq: Vec<Cmd>) {
        if let Some(txn) = &mut self.open_txn {
            txn.unit.forwards.push(forward);
            txn.unit.inverses.push(inverse_seq);
        } else {
            self.undo_stack.push(UndoUnit {
                inverses: vec![inverse_seq],
                forwards: vec![forward],
            });
            self.redo_stack.clear();
        }
    }

    fn journal_entry(
        &mut self,
        meta: &EntryMeta,
        cmd: &Cmd,
        inverse: Option<InverseRef>,
    ) -> Result<(), CommandError> {
        let env = Envelope {
            id: meta.id.clone(),
            ts: meta.ts.clone(),
            actor: meta.actor.clone(),
            name: cmd.name().to_string(),
            params: cmd.params_value(),
            inverse,
            result: result_ok(),
            hash: String::new(),
        }
        .finalize(&self.tip_hash)?;
        self.sink.append(&env)?;
        self.tip_hash = env.hash.clone();
        self.journal.push(env);
        Ok(())
    }

    fn record_change(&mut self, scopes: &[ChangeScope]) {
        if scopes.is_empty() {
            return;
        }
        self.change_log.push_back((self.seq(), scopes.to_vec()));
        while self.change_log.len() > DIFF_WINDOW {
            self.change_log.pop_front();
        }
    }

    fn report(&mut self, journaled: bool, mutated: bool, scopes: Vec<ChangeScope>) -> Submitted {
        self.snapshot_cache = None;
        Submitted {
            journaled,
            mutated,
            seq: self.seq(),
            duplicate: false,
            scopes,
        }
    }

    /// Abort the open transaction: roll back every command applied since the
    /// outermost `txn.begin` (inverses applied last-first) and JOURNAL that
    /// rollback forward, exactly the way `undo` journals its own. No
    /// `txn.commit` is emitted, so the begin marker stays in the journal with
    /// no matching commit — a documented v1 behaviour, and harmless now that
    /// the entries between them net out to nothing.
    ///
    /// # Why the rollback is journaled, which it was not
    ///
    /// The journal is append-only and REPLAYED. An abort that rolled back only
    /// the in-memory project left the applied entries sitting in the journal
    /// with nothing to cancel them, so `Session::replay` — crash recovery, and
    /// any open that misses the checkpoint fast path — put the aborted work
    /// back. The user was told the gesture failed, saw nothing, and found the
    /// half-import waiting for them on reopen. That is a half-applied
    /// transaction with a delayed fuse, and it is the one failure mode the
    /// composed import path would have made routine rather than rare.
    ///
    /// Journaling the inverses makes the bracket net-zero on replay: an older
    /// build reading this journal applies the same commands and the same
    /// inverses in the same order and lands on the same project. Nothing about
    /// the shape is new — every entry is an ordinary journaled command.
    ///
    /// # Depth
    ///
    /// The rollback is TOTAL at any depth: an inner abort reverts the whole
    /// bracket, not its own slice of it. Reverting only the inner slice and
    /// handing a usable frame back to the outer caller is precisely how a
    /// transaction ends up half-applied. Having reverted, it unwinds one level
    /// and POISONS whatever is left, so every enclosing commit refuses and
    /// every enclosing abort unwinds cleanly to nothing.
    pub fn abort_txn(&mut self, meta: &mut dyn MetaSource) -> Result<(), CommandError> {
        let mut open = self
            .open_txn
            .take()
            .ok_or_else(|| CommandError::Txn("no open txn to abort".into()))?;
        // Taken above, so the compensating entries below are journaled OUTSIDE
        // the unit (they must not join the thing being reverted).
        let inverses = std::mem::take(&mut open.unit.inverses);
        open.unit.forwards.clear();
        for inverse_seq in inverses.iter().rev() {
            for inv in inverse_seq {
                self.apply_journaled_forward(inv, meta)?;
            }
        }
        open.ids.pop();
        if !open.ids.is_empty() {
            open.poisoned = true;
            self.open_txn = Some(open);
        }
        self.snapshot_cache = None;
        Ok(())
    }

    /// How many `txn.begin` brackets are open (0 when none). The re-entrant
    /// depth, for tests and for a caller that needs to know whether it is the
    /// outermost.
    pub fn txn_depth(&self) -> usize {
        self.open_txn.as_ref().map(|t| t.ids.len()).unwrap_or(0)
    }

    /// Undo the most recent unit: apply its inverse commands (journaled
    /// forward, history never rewrites) and move it to the redo stack.
    /// Returns false when there is nothing to undo.
    pub fn undo(&mut self, meta: &mut dyn MetaSource) -> Result<bool, CommandError> {
        if self.open_txn.is_some() {
            return Err(CommandError::Txn("cannot undo with an open txn".into()));
        }
        let Some(unit) = self.undo_stack.pop() else {
            return Ok(false);
        };
        // Apply inverses last-first; each is journaled forward.
        for inverse_seq in unit.inverses.iter().rev() {
            for inv in inverse_seq {
                self.apply_journaled_forward(inv, meta)?;
            }
        }
        self.redo_stack.push(unit);
        self.snapshot_cache = None;
        Ok(true)
    }

    /// Redo the most recently undone unit: re-apply its forward commands
    /// (journaled forward) and move it back to the undo stack.
    pub fn redo(&mut self, meta: &mut dyn MetaSource) -> Result<bool, CommandError> {
        if self.open_txn.is_some() {
            return Err(CommandError::Txn("cannot redo with an open txn".into()));
        }
        let Some(unit) = self.redo_stack.pop() else {
            return Ok(false);
        };
        for fwd in &unit.forwards {
            self.apply_journaled_forward(fwd, meta)?;
        }
        self.undo_stack.push(unit);
        self.snapshot_cache = None;
        Ok(true)
    }

    /// Apply one command as a fresh journaled entry (used by undo/redo). The
    /// entry records its own inverse hint so the resulting journal is itself a
    /// valid, undoable history.
    fn apply_journaled_forward(
        &mut self,
        cmd: &Cmd,
        meta: &mut dyn MetaSource,
    ) -> Result<(), CommandError> {
        let spec = Catalog::get()
            .spec(cmd.name())
            .ok_or_else(|| CommandError::UnknownCommand(cmd.name().to_string()))?;
        let effect = self.project.apply_cmd(cmd)?;
        if spec.journaled {
            let inverse = if spec.undoable {
                effect.hint.as_ref().map(InverseRef::from_cmd)
            } else {
                None
            };
            let m = meta.next_meta(cmd);
            self.journal_entry(&m, cmd, inverse)?;
            self.record_change(&effect.scopes);
        }
        Ok(())
    }

    /// A cheap immutable snapshot; cached until the next mutation.
    pub fn snapshot(&mut self) -> Snapshot {
        let seq = self.seq();
        if let Some(s) = &self.snapshot_cache {
            if s.seq == seq {
                return s.clone();
            }
        }
        let snap = Snapshot {
            project: Arc::new(self.project.clone()),
            seq,
        };
        self.snapshot_cache = Some(snap.clone());
        snap
    }

    /// What changed since `since_seq`. `Delta` when the window still covers
    /// it, `Resync` when it was evicted, `None` when nothing changed.
    pub fn changes_since(&self, since_seq: u64) -> Changes {
        let now = self.seq();
        if since_seq >= now {
            return Changes::None;
        }
        // If the oldest retained change entry is newer than since_seq+1, some
        // changes between since_seq and it were evicted: resync.
        if let Some((oldest, _)) = self.change_log.front() {
            if *oldest > since_seq + 1 {
                return Changes::Resync;
            }
        } else {
            // No changes recorded but seq advanced (e.g. only non-mutating
            // journaled records like gen.* / txn markers): nothing to adopt.
            return Changes::None;
        }
        let mut scopes: Vec<ChangeScope> = Vec::new();
        for (seq, s) in &self.change_log {
            if *seq > since_seq {
                for scope in s {
                    if !scopes.contains(scope) {
                        scopes.push(scope.clone());
                    }
                }
            }
        }
        if scopes.is_empty() {
            Changes::None
        } else {
            Changes::Delta(scopes)
        }
    }

    /// Replay a journal (list of envelopes) onto a base project to rebuild
    /// state. Verifies the hash chain, applies each command, and reconstructs
    /// undo units from txn brackets. Idempotency-keyed by entry id.
    pub fn replay(base: Project, envelopes: Vec<Envelope>) -> Result<Session, CommandError> {
        Session::resume(base, envelopes, 0)
    }

    /// Like `replay`, but `base` already reflects the first `already_applied`
    /// envelopes (a checkpoint fast-open): those are included in the journal
    /// and idempotency set but NOT re-applied, and only the tail rebuilds undo
    /// units. The resulting session's journal, tip, and seq describe the WHOLE
    /// chain, so a later save rewrites the complete journal.
    pub fn resume(
        mut base: Project,
        envelopes: Vec<Envelope>,
        already_applied: usize,
    ) -> Result<Session, CommandError> {
        // Verify the chain first (bad tail is a recovery signal, not a panic).
        let mut prev = GENESIS_HASH.to_string();
        for env in &envelopes {
            env.verify(&prev)?;
            prev = env.hash.clone();
        }
        let catalog = Catalog::get();
        let mut undo_stack: Vec<UndoUnit> = Vec::new();
        let mut open: Option<OpenTxn> = None;
        let mut seen_ids = HashSet::new();
        let mut change_log = VecDeque::new();

        for (idx, env) in envelopes.iter().enumerate() {
            if !seen_ids.insert(env.id.clone()) {
                continue; // idempotent: skip a duplicate id
            }
            if idx < already_applied {
                continue; // already reflected in `base` (checkpoint prefix)
            }
            let spec = catalog
                .spec(&env.name)
                .ok_or_else(|| CommandError::UnknownCommand(env.name.clone()))?;
            let cmd = Cmd::from_wire(&env.name, env.params.clone()).map_err(|e| {
                CommandError::SchemaViolation(format!("replay {} at {idx}: {e}", env.name))
            })?;
            match &cmd {
                Cmd::TxnBegin { txn_id, .. } => {
                    // Nesting cannot reach the journal (inner markers are
                    // elided — see `OpenTxn`), so a begin while one is open can
                    // only be a bracket an abort left unclosed. Its contents
                    // are already applied and net-zero; start a fresh unit
                    // rather than folding two gestures into one.
                    open = Some(OpenTxn::opened(txn_id.clone()));
                }
                Cmd::TxnCommit { .. } => {
                    if let Some(o) = open.take() {
                        if !o.unit.forwards.is_empty() {
                            undo_stack.push(o.unit);
                        }
                    }
                }
                _ => {
                    let effect = base.apply_cmd(&cmd)?;
                    if spec.journaled && !effect.scopes.is_empty() {
                        change_log.push_back(((idx + 1) as u64, effect.scopes.clone()));
                        while change_log.len() > DIFF_WINDOW {
                            change_log.pop_front();
                        }
                    }
                    if spec.journaled && spec.undoable {
                        let seq = effect.inverse.clone();
                        let fwd = cmd.clone();
                        if let Some(o) = &mut open {
                            o.unit.forwards.push(fwd);
                            o.unit.inverses.push(seq);
                        } else {
                            undo_stack.push(UndoUnit {
                                inverses: vec![seq],
                                forwards: vec![fwd],
                            });
                        }
                    }
                }
            }
        }
        // An unclosed txn at end of journal: its commands are applied (state
        // is correct) but they do not form a closed undo unit.
        let tip_hash = envelopes
            .last()
            .map(|e| e.hash.clone())
            .unwrap_or_else(|| GENESIS_HASH.to_string());
        Ok(Session {
            project: base,
            journal: envelopes,
            sink: Box::new(MemoryJournal::new()),
            tip_hash,
            undo_stack,
            redo_stack: Vec::new(),
            open_txn: None,
            seen_ids,
            snapshot_cache: None,
            change_log,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::AutoTarget;
    use crate::tempo::{Bpm, TempoMap};
    use serde_json::json;

    fn session() -> Session {
        Session::new(Project::new(
            48_000,
            TempoMap::single(Bpm::from_int(120).unwrap()),
        ))
    }

    fn m(n: u64) -> EntryMeta {
        EntryMeta {
            id: format!("{n:026}"),
            ts: "2026-07-11T20:00:00Z".to_string(),
            actor: Actor::user("aaron"),
        }
    }

    fn track_add(id: &str, name: &str) -> Cmd {
        Cmd::TrackAdd {
            track_id: id.into(),
            name: name.into(),
            index: None,
        }
    }

    fn txn_begin(id: &str) -> Cmd {
        Cmd::TxnBegin {
            txn_id: id.into(),
            reason: None,
        }
    }

    fn txn_commit(id: &str) -> Cmd {
        Cmd::TxnCommit { txn_id: id.into() }
    }

    #[test]
    fn snapshot_is_cached_until_the_next_mutation() {
        let mut s = session();
        s.submit(
            m(1),
            Cmd::TrackAdd {
                track_id: "t1".into(),
                name: "T".into(),
                index: Some(0),
            },
        )
        .unwrap();
        let a = s.snapshot();
        let b = s.snapshot();
        assert!(
            Arc::ptr_eq(&a.project, &b.project),
            "same seq reuses the Arc"
        );
        s.submit(
            m(2),
            Cmd::TrackAdd {
                track_id: "t2".into(),
                name: "U".into(),
                index: Some(1),
            },
        )
        .unwrap();
        let c = s.snapshot();
        assert!(
            !Arc::ptr_eq(&a.project, &c.project),
            "mutation invalidates the cache"
        );
        assert_eq!(c.seq, 2);
    }

    #[test]
    fn diff_cursor_reports_none_delta_and_resync() {
        let mut s = session();
        assert_eq!(s.changes_since(0), Changes::None);
        s.submit(
            m(1),
            Cmd::TrackAdd {
                track_id: "t1".into(),
                name: "T".into(),
                index: Some(0),
            },
        )
        .unwrap();
        match s.changes_since(0) {
            Changes::Delta(scopes) => assert!(scopes.contains(&ChangeScope::Tracks)),
            other => panic!("expected Delta, got {other:?}"),
        }
        assert_eq!(s.changes_since(1), Changes::None, "nothing since the tip");

        // Overflow the diff window to force a Resync for an old cursor.
        let mut n = 2;
        for i in 0..(DIFF_WINDOW as u64 + 10) {
            let cmd = Cmd::MarkerSet {
                marker_id: format!("mk{i}"),
                position_ticks: 0,
                label: "m".into(),
                color: None,
            };
            s.submit(m(n), cmd).unwrap();
            n += 1;
        }
        assert_eq!(
            s.changes_since(0),
            Changes::Resync,
            "evicted cursor resyncs"
        );
    }

    #[test]
    fn duplicate_command_id_is_idempotent() {
        let mut s = session();
        let cmd = Cmd::TrackAdd {
            track_id: "t1".into(),
            name: "T".into(),
            index: Some(0),
        };
        let first = s.submit(m(1), cmd.clone()).unwrap();
        assert!(!first.duplicate);
        // same id, different command: acknowledged, not applied again
        let again = s
            .submit(
                m(1),
                Cmd::TrackAdd {
                    track_id: "t2".into(),
                    name: "U".into(),
                    index: Some(1),
                },
            )
            .unwrap();
        assert!(again.duplicate);
        assert_eq!(s.project().tracks.len(), 1, "duplicate id did not mutate");
        assert_eq!(s.seq(), 1);
    }

    #[test]
    fn a_transaction_is_one_undo_unit() {
        let mut s = session();
        s.submit(
            m(1),
            Cmd::TrackAdd {
                track_id: "t1".into(),
                name: "A".into(),
                index: Some(0),
            },
        )
        .unwrap();
        s.submit(
            m(2),
            Cmd::TrackAdd {
                track_id: "t2".into(),
                name: "B".into(),
                index: Some(1),
            },
        )
        .unwrap();
        // group two renames into one txn
        s.submit(
            m(3),
            Cmd::TxnBegin {
                txn_id: "x1".into(),
                reason: None,
            },
        )
        .unwrap();
        s.submit(
            m(4),
            Cmd::TrackRename {
                track_id: "t1".into(),
                name: "A2".into(),
            },
        )
        .unwrap();
        s.submit(
            m(5),
            Cmd::TrackRename {
                track_id: "t2".into(),
                name: "B2".into(),
            },
        )
        .unwrap();
        s.submit(
            m(6),
            Cmd::TxnCommit {
                txn_id: "x1".into(),
            },
        )
        .unwrap();
        assert_eq!(s.undo_depth(), 3, "2 track adds + 1 txn unit");

        let mut meta = SeqMeta::starting_at(100, Actor::user("undo"));
        assert!(s.undo(&mut meta).unwrap());
        // one undo reverted BOTH renames
        assert_eq!(s.project().track("t1").unwrap().name, "A");
        assert_eq!(s.project().track("t2").unwrap().name, "B");
        assert_eq!(s.undo_depth(), 2);

        assert!(s.redo(&mut meta).unwrap());
        assert_eq!(s.project().track("t1").unwrap().name, "A2");
        assert_eq!(s.project().track("t2").unwrap().name, "B2");
    }

    /// Re-entry is what lets one gesture that composes two engine operations
    /// stay one undo step. The three things that must all hold at once: ONE
    /// undo unit, ONE journaled bracket, and the inner markers nowhere in the
    /// journal — because a journal with nested markers is one an older build
    /// refuses to replay ("v1 transactions do not nest").
    #[test]
    fn a_re_entered_transaction_is_still_one_unit_and_one_journaled_bracket() {
        let mut s = session();
        s.submit(m(1), track_add("t1", "A")).unwrap();
        let before = s.undo_depth();

        s.submit(m(2), txn_begin("outer")).unwrap();
        assert_eq!(s.txn_depth(), 1);
        s.submit(m(3), txn_begin("inner")).unwrap();
        assert_eq!(s.txn_depth(), 2, "the inner begin joined rather than being refused");
        s.submit(m(4), track_add("t2", "B")).unwrap();
        s.submit(m(5), txn_commit("inner")).unwrap();
        assert_eq!(s.txn_depth(), 1, "the inner commit did not close the bracket");
        assert_eq!(s.undo_depth(), before, "the inner commit published a unit of its own");
        s.submit(m(6), track_add("t3", "C")).unwrap();
        s.submit(m(7), txn_commit("outer")).unwrap();

        assert_eq!(s.txn_depth(), 0);
        assert_eq!(s.undo_depth(), before + 1, "two brackets produced two undo units");
        let markers: Vec<&str> = s
            .journal()
            .iter()
            .map(|e| e.name.as_str())
            .filter(|n| n.starts_with("txn."))
            .collect();
        assert_eq!(
            markers,
            vec!["txn.begin", "txn.commit"],
            "the inner markers reached the journal, which an older build cannot replay"
        );

        // And the unit really holds both halves: one undo takes back the track
        // added inside the inner bracket AND the one added after it.
        let mut meta = SeqMeta::starting_at(100, Actor::user("undo"));
        assert!(s.undo(&mut meta).unwrap());
        assert!(s.project().track("t2").is_none(), "inner-bracket work survived the undo");
        assert!(s.project().track("t3").is_none(), "outer work survived the undo");
        assert!(s.project().track("t1").is_some(), "undo reached past the gesture");
    }

    /// A commit still names the bracket it closes, at every depth. Without this
    /// a mismatched id at depth 2 would pop the wrong level and the outer
    /// caller would commit something it never opened.
    #[test]
    fn a_commit_must_name_the_innermost_open_bracket() {
        let mut s = session();
        s.submit(m(1), txn_begin("outer")).unwrap();
        s.submit(m(2), txn_begin("inner")).unwrap();
        let wrong = s.submit(m(3), txn_commit("outer"));
        assert!(wrong.is_err(), "a commit naming the OUTER bracket closed the inner one");
        assert_eq!(s.txn_depth(), 2, "the failed commit popped a level anyway");
        s.submit(m(4), txn_commit("inner")).unwrap();
        s.submit(m(5), txn_commit("outer")).unwrap();
        assert_eq!(s.txn_depth(), 0);
    }

    /// THE FAILURE THAT MATTERS. An inner step aborts at depth 2: the WHOLE
    /// bracket rolls back, and the outer caller's commit must fail rather than
    /// publish a unit whose contents no longer exist. A half-applied
    /// transaction that reports success is worse than no grouping at all.
    #[test]
    fn an_inner_abort_rolls_back_everything_and_the_outer_commit_refuses() {
        let mut s = session();
        s.submit(m(1), track_add("t1", "A")).unwrap();
        let before_depth = s.undo_depth();

        s.submit(m(2), txn_begin("outer")).unwrap();
        s.submit(m(3), track_add("t2", "B")).unwrap(); // outer's own work
        s.submit(m(4), txn_begin("inner")).unwrap();
        s.submit(m(5), track_add("t3", "C")).unwrap(); // inner's work
        let mut meta = SeqMeta::starting_at(100, Actor::user("abort"));
        s.abort_txn(&mut meta).unwrap();

        // Everything the bracket did is gone, not just the inner half.
        assert!(s.project().track("t3").is_none(), "inner work survived the abort");
        assert!(s.project().track("t2").is_none(), "OUTER work survived an inner abort");
        assert!(s.project().track("t1").is_some(), "the abort reached past the bracket");

        // Nothing may join the reverted bracket ...
        assert!(
            s.submit(m(6), track_add("t4", "D")).is_err(),
            "a command joined a transaction that had already been rolled back"
        );
        // ... and the outer commit REFUSES rather than reporting success.
        let commit = s.submit(m(7), txn_commit("outer"));
        assert!(commit.is_err(), "the outer commit published a rolled-back transaction");
        assert_eq!(s.undo_depth(), before_depth, "a rolled-back bracket became an undo unit");
        assert_eq!(s.txn_depth(), 0, "the refused commit left the session wedged");
        // Not wedged: the very next gesture works.
        s.submit(m(8), track_add("t5", "E")).unwrap();
        assert_eq!(s.undo_depth(), before_depth + 1);
    }

    /// The rollback is JOURNALED, so a replay of this journal lands where the
    /// live project landed. It did not used to be: the applied entries stayed
    /// in an append-only journal with nothing to cancel them, so crash recovery
    /// put the aborted work back — a half-applied transaction with a delayed
    /// fuse.
    #[test]
    fn an_aborted_transaction_replays_to_the_state_it_rolled_back_to() {
        let mut s = session();
        s.submit(m(1), track_add("t1", "A")).unwrap();
        s.submit(m(2), txn_begin("x")).unwrap();
        s.submit(m(3), track_add("t2", "B")).unwrap();
        let mut meta = SeqMeta::starting_at(100, Actor::user("abort"));
        s.abort_txn(&mut meta).unwrap();
        assert!(s.project().track("t2").is_none());

        let replayed = Session::replay(
            Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap())),
            s.journal().to_vec(),
        )
        .unwrap();
        assert!(
            replayed.project().track("t2").is_none(),
            "replaying an aborted transaction put its work back: {:?}",
            replayed.project().tracks.iter().map(|t| &t.id).collect::<Vec<_>>()
        );
        assert!(replayed.project().track("t1").is_some(), "replay lost work from before the abort");
    }

    #[test]
    fn failed_command_does_not_journal_or_mutate() {
        let mut s = session();
        s.submit(
            m(1),
            Cmd::TrackAdd {
                track_id: "t1".into(),
                name: "T".into(),
                index: Some(0),
            },
        )
        .unwrap();
        // clip.place on a missing track: typed error, no journal entry.
        let err = s.submit(
            m(2),
            Cmd::ClipPlace {
                clip_id: "c1".into(),
                track_id: "nope".into(),
                asset_hash: "a".repeat(64),
                start_ticks: 0,
                length_ticks: 960,
                source_offset_ticks: None,
            },
        );
        assert!(err.is_err());
        assert_eq!(s.seq(), 1, "failed command was not journaled");
        assert_eq!(s.undo_depth(), 1);
    }

    /// Append fails after the in-memory apply. The inverse runs directly, so
    /// the caller sees the error and the project is unchanged.
    struct FailAfterJournal {
        accepted: usize,
        fail_after: usize,
    }

    impl JournalSink for FailAfterJournal {
        fn append(&mut self, _envelope: &Envelope) -> Result<(), CommandError> {
            if self.accepted >= self.fail_after {
                return Err(CommandError::Io("injected journal failure".into()));
            }
            self.accepted += 1;
            Ok(())
        }

        fn sync(&mut self) -> Result<(), CommandError> {
            Ok(())
        }

        fn len(&self) -> usize {
            self.accepted
        }
    }

    #[test]
    fn failed_journal_append_rolls_back_the_applied_edit() {
        let project = Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()));
        let mut s = Session::with_sink(
            project,
            Box::new(FailAfterJournal {
                accepted: 0,
                fail_after: 0,
            }),
        );

        let error = s
            .submit(
                m(1),
                Cmd::TrackAdd {
                    track_id: "t1".into(),
                    name: "Must Roll Back".into(),
                    index: Some(0),
                },
            )
            .expect_err("injected append failure must reach the caller");
        assert_eq!(error.code(), "io");
        assert!(
            s.project().tracks.is_empty(),
            "unrecorded edit was rolled back"
        );
        assert_eq!(s.seq(), 0);
        assert_eq!(s.undo_depth(), 0);
    }

    #[test]
    fn failed_transaction_commit_remains_open_for_retry_or_abort() {
        let project = Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()));
        let mut s = Session::with_sink(
            project,
            Box::new(FailAfterJournal {
                accepted: 0,
                fail_after: 2,
            }),
        );
        s.submit(
            m(1),
            Cmd::TxnBegin {
                txn_id: "txn".into(),
                reason: Some("fault injection".into()),
            },
        )
        .unwrap();
        s.submit(
            m(2),
            Cmd::TrackAdd {
                track_id: "t1".into(),
                name: "Recorded".into(),
                index: Some(0),
            },
        )
        .unwrap();

        let error = s.submit(
            m(3),
            Cmd::TxnCommit {
                txn_id: "txn".into(),
            },
        );
        assert!(error.is_err());
        assert!(
            s.in_txn(),
            "failed commit must not discard the open transaction"
        );
        assert_eq!(s.seq(), 2);
        assert_eq!(s.project().tracks.len(), 1);
        // The bracket id is still the one the caller named, so retry and
        // abort both still address it. `FailAfterJournal` keeps failing, so
        // the retry is refused and the transaction stays open.
        let retry = s.submit(
            m(4),
            Cmd::TxnCommit {
                txn_id: "txn".into(),
            },
        );
        assert!(
            retry.is_err(),
            "a sink that is still failing must refuse the retry"
        );
        assert!(s.in_txn(), "a refused retry must not drop the bracket");
        assert_eq!(s.txn_depth(), 1);
    }

    #[test]
    fn submit_json_validates_against_the_catalog() {
        let mut s = session();
        // unknown param rejected before typed parse
        let bad = s.submit_json(
            m(1),
            "track.add",
            json!({"trackId": "t", "name": "T", "zap": 1}),
        );
        assert!(bad.is_err());
        let ok = s.submit_json(m(2), "track.add", json!({"trackId": "t", "name": "T"}));
        assert!(ok.is_ok());
        // automation target enum flows through
        s.submit_json(
            m(3),
            "autopoint.add",
            json!({"trackId": "t", "target": "track.volume", "pointId": "p", "positionTicks": 0, "value": 0}),
        )
        .unwrap();
        assert_eq!(
            s.project()
                .track("t")
                .unwrap()
                .automation
                .lane(&AutoTarget::Volume.param_ref())
                .len(),
            1
        );
    }
}
