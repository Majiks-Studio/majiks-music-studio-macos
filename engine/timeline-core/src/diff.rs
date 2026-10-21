//! Change scopes for the snapshot diff-cursor: a coarse, cheap description of
//! WHAT changed per journaled entry, so UI adoption can invalidate narrowly
//! without diffing whole snapshots.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ChangeScope {
    /// Project-level fields (name, key, time signature).
    Project,
    /// Tempo map changed: every materialized frame position moved.
    Tempo,
    /// Track list membership or order changed.
    Tracks,
    /// One track's own fields (name, color, height, mute, solo, arm).
    Track(String),
    /// Clip membership or clip fields on one track (by track id).
    Clips(String),
    /// Mixer state of one track (gain, pan, eq, sends).
    Mixer(String),
    /// One automation lane (track id, target wire name).
    Automation(String, String),
    Sections,
    Markers,
    Master,
    Takes,
    Crossfades,
    /// The routing graph (nodes and/or edges) changed. Catalog v2.
    Routing,
}

/// What `Session::changes_since` returns.
#[derive(Debug, Clone, PartialEq)]
pub enum Changes {
    /// Nothing changed since the given seq.
    None,
    /// The scopes touched since the given seq (deduplicated, order-free).
    Delta(Vec<ChangeScope>),
    /// The window was evicted; adopt a full snapshot.
    Resync,
}
