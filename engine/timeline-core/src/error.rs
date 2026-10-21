//! Typed command errors. Unknown command or bad params is a typed error,
//! never a partial apply (02-ARCHITECTURE.md section 4).
//!
//! `code()` returns the stable machine-readable string used in envelope
//! `result.error.code`. Codes are additive-stable: existing codes never
//! change meaning.

use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Error, Serialize, Deserialize)]
#[serde(tag = "kind", content = "detail")]
pub enum CommandError {
    #[error("unknown track: {0}")]
    UnknownTrack(String),
    #[error("unknown clip: {0}")]
    UnknownClip(String),
    #[error("unknown source: {0}")]
    UnknownSource(String),
    #[error("duplicate id: {0}")]
    DuplicateId(String),
    #[error("invalid params: {0}")]
    InvalidParams(String),
    #[error("out of range: {0}")]
    OutOfRange(String),
    #[error("track not empty: {0}")]
    TrackNotEmpty(String),

    // Catalog-bus additions (0.2).
    /// Design §2/§9.3: an unknown command NAME hard-fails the whole
    /// `Package::open`, which is the SAFE outcome (unlike an unknown param,
    /// which serde silently ignores — see §9.2). The gap was never the
    /// behaviour, only the message: it gave no version hint, so a v1 binary
    /// opening a v2 project produced a bare "unknown command" with no clue
    /// that the file is simply newer. Compat is ASYMMETRIC and the text now
    /// says so.
    #[error(
        "unknown command: {0} — this build's catalog does not define it. If the \
         project was written by a newer build, it uses catalog features this one \
         does not have; opening it is refused rather than replayed incorrectly. \
         (A newer build always opens an older project: catalog versions are \
         supersets.)"
    )]
    UnknownCommand(String),
    #[error("schema violation: {0}")]
    SchemaViolation(String),
    #[error("unknown section: {0}")]
    UnknownSection(String),
    #[error("unknown marker: {0}")]
    UnknownMarker(String),
    #[error("unknown automation point: {0}")]
    UnknownAutoPoint(String),
    /// E1: a note id that does not exist on the addressed clip. Note ids are
    /// unique per CLIP, not globally.
    #[error("unknown note: {0}")]
    UnknownNote(String),
    /// E1/E2: a device id that does not exist on the addressed track.
    #[error("unknown device: {0}")]
    UnknownDevice(String),
    #[error("unknown take: {0}")]
    UnknownTake(String),
    #[error("clips overlap: {0}")]
    Overlap(String),
    #[error("clips not adjacent: {0}")]
    NotAdjacent(String),
    #[error("transaction error: {0}")]
    Txn(String),
    #[error("envelope error: {0}")]
    Envelope(String),
    #[error("take state: {0}")]
    TakeState(String),
    #[error("io: {0}")]
    Io(String),
    #[error("duplicate command id (already journaled): {0}")]
    DuplicateCommandId(String),

    // Catalog v2 additions.
    /// A well-formed ParamRef that names no parameter in the LIVE project.
    /// Catalog v2 widened the automation `target` from an enum to a pattern, so
    /// validation of WHICH parameter is named moved from schema-time to
    /// apply-time rather than disappearing (design §3, "Open risk, flagged not
    /// hidden").
    #[error("unknown parameter: {0}")]
    UnknownParameter(String),
    /// A routing command that would create a cycle, or names a node/edge that
    /// does not exist. Cycles are rejected at COMMAND time so the audio thread
    /// can never discover one (design §5).
    #[error("routing: {0}")]
    Routing(String),
}

impl CommandError {
    /// Stable machine-readable code for envelope `result.error.code`.
    pub fn code(&self) -> &'static str {
        match self {
            CommandError::UnknownTrack(_) => "unknown_track",
            CommandError::UnknownClip(_) => "unknown_clip",
            CommandError::UnknownSource(_) => "unknown_source",
            CommandError::DuplicateId(_) => "duplicate_id",
            CommandError::InvalidParams(_) => "invalid_params",
            CommandError::OutOfRange(_) => "out_of_range",
            CommandError::TrackNotEmpty(_) => "track_not_empty",
            CommandError::UnknownCommand(_) => "unknown_command",
            CommandError::SchemaViolation(_) => "schema_violation",
            CommandError::UnknownSection(_) => "unknown_section",
            CommandError::UnknownMarker(_) => "unknown_marker",
            CommandError::UnknownAutoPoint(_) => "unknown_autopoint",
            CommandError::UnknownNote(_) => "unknown_note",
            CommandError::UnknownDevice(_) => "unknown_device",
            CommandError::UnknownTake(_) => "unknown_take",
            CommandError::Overlap(_) => "overlap",
            CommandError::NotAdjacent(_) => "not_adjacent",
            CommandError::Txn(_) => "txn",
            CommandError::Envelope(_) => "envelope",
            CommandError::TakeState(_) => "take_state",
            CommandError::Io(_) => "io",
            CommandError::DuplicateCommandId(_) => "duplicate_command_id",
            CommandError::UnknownParameter(_) => "unknown_parameter",
            CommandError::Routing(_) => "routing",
        }
    }
}
