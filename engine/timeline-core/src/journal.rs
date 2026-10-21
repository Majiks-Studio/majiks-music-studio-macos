//! Journal sink: the append-only, hash-chained command log behind a small
//! trait so `timeline-core` stays wasm32-compilable (the native file sink
//! lives in `package.rs`, gated off wasm).

use crate::envelope::{Envelope, GENESIS_HASH};
use crate::error::CommandError;

/// Where journaled envelopes go. Implementations append one canonical JSONL
/// line per entry and can flush durably. `sync` is a no-op for the in-memory
/// sink; the native file sink fsyncs.
pub trait JournalSink {
    /// Append one already-hashed envelope (its `to_jsonl()` line).
    fn append(&mut self, envelope: &Envelope) -> Result<(), CommandError>;
    /// Flush buffered writes durably.
    fn sync(&mut self) -> Result<(), CommandError>;
    /// Total entries appended (for the checkpoint pointer).
    fn len(&self) -> usize;
    fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// In-memory sink (tests, wasm, and the pre-save buffer). Retains full lines
/// so a checkpoint can serialize them and a replay can re-read them.
#[derive(Debug, Default, Clone)]
pub struct MemoryJournal {
    pub lines: Vec<String>,
}

impl MemoryJournal {
    pub fn new() -> Self {
        MemoryJournal { lines: Vec::new() }
    }

    pub fn from_lines(lines: Vec<String>) -> Self {
        MemoryJournal { lines }
    }
}

impl JournalSink for MemoryJournal {
    fn append(&mut self, envelope: &Envelope) -> Result<(), CommandError> {
        self.lines.push(envelope.to_jsonl());
        Ok(())
    }

    fn sync(&mut self) -> Result<(), CommandError> {
        Ok(())
    }

    fn len(&self) -> usize {
        self.lines.len()
    }
}

/// Recompute the whole chain over parsed lines, returning `(tip_hash, count)`
/// if every stored hash matches, else the 0-based index of the first bad
/// entry. Mirrors the contract's `verify_chain`.
pub fn verify_lines(lines: &[String]) -> Result<(String, usize), CommandError> {
    let mut prev = GENESIS_HASH.to_string();
    for (i, line) in lines.iter().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let env = Envelope::from_line(line)?;
        env.verify(&prev)
            .map_err(|e| CommandError::Envelope(format!("chain broken at entry {i}: {e}")))?;
        prev = env.hash.clone();
    }
    Ok((prev, lines.iter().filter(|l| !l.trim().is_empty()).count()))
}
