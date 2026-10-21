//! timeline-core: the pure model + math + command spine of the Majik's Music
//! Studio DAW engine.
//!
//! Contents: rational tempo map (960 PPQ integer ticks, no float beat math),
//! project model (tracks, clips, sources, sections, markers, automation,
//! mixer, takes), the full catalog command bus (87 commands per
//! `engine/contracts/command-catalog.v1.1.json`) with typed validate/apply/
//! inverse, a blake3 hash-chained journal (canonicalization per
//! `engine/contracts/README.md`), transactional undo/redo, a snapshot +
//! diff-cursor read API, and `.mstudio` package io behind a small trait.
//!
//! HARD CONSTRAINT: this crate stays wasm32-compilable. No cpal, no OS clock,
//! no threads. Filesystem access lives behind the `JournalSink` /
//! `PackageStore` traits; the native implementations are gated
//! `#[cfg(not(target_arch = "wasm32"))]`. See INTERFACE.md.

pub mod apply;
pub mod catalog;
pub mod cmd;
pub mod command;
pub mod diff;
pub mod envelope;
pub mod error;
pub mod journal;
pub mod model;
pub mod note;
pub mod num;
pub mod paramref;
pub mod routing;
pub mod schema;
pub mod session;
pub mod tempo;

#[cfg(not(target_arch = "wasm32"))]
pub mod package;

// Legacy P0-B surface (render + P0-B tests build against this).
pub use command::{Applied, Command, TrimEdge};
pub use error::CommandError;
pub use model::{Clip, ClipKind, FadeShape, Project, Source, Track};
pub use tempo::{Bpm, TempoMap, PPQ};

// Catalog bus surface (INTERFACE.md sections 2-5).
pub use apply::CmdEffect;
pub use catalog::{Catalog, CommandSpec, InverseMode, InverseShape};
pub use cmd::Cmd;
pub use diff::{ChangeScope, Changes};
pub use envelope::{Actor, EntryMeta, Envelope, GENESIS_HASH};
pub use journal::{JournalSink, MemoryJournal};
pub use note::Note;
pub use num::Num;
pub use paramref::{ParamRef, ParamRefKind};
pub use routing::{NodeKind, NodeRef, RouteEdge, RouteNode, Routing, ScheduleStep, Tap};
pub use session::{Session, Snapshot, Submitted};
