//! The routing DAG — **model, validation and topological sort only**.
//!
//! Design `DESIGN-catalog-v2.md` §5. Evaluation lives in `render` and is E5's
//! work; E0 delivers the model, the commands and the compile-time ordering so
//! E5 has no contract work left.
//!
//! Why this crate: `timeline-core` is a wasm-clean leaf crate with no path
//! dependencies, and `render` deliberately does NOT compile to wasm32 (cpal,
//! libc, coreaudio-sys, threads, `Instant::now`). The seam already exists —
//! `compile_session_full` flattens a `Project` into an immutable RT-safe
//! `RtSession`. Routing follows it: model + validation + topological sort here,
//! `compile.rs` bakes the sorted order into the snapshot, the audio thread
//! walks that slice BY INDEX ONLY.
//!
//! **Cycles are rejected at command time, never at render time.** The audio
//! thread must never discover a cycle.
//!
//! Today's topology is hard-coded in five independent places
//! (`TrackParamAtomic::{send_a,send_b}`, `track_send_{a,b}_target`,
//! `Strip::{send_a,send_b}`, `SendBus{A,B}`, `Sends{a,b}`) with bus A→reverb /
//! B→delay as literal code. This module is the data model that replaces them;
//! E5 moves the five sites together.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::error::CommandError;
use crate::num::Num;

/// Reserved node id for the master bus. Master is an IMPLICIT node: it is never
/// added or removed, and it is always the topological sink.
pub const MASTER: &str = "master";

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum NodeKind {
    /// An aux/effect destination fed by sends.
    #[serde(rename = "bus")]
    Bus,
    /// A submix whose members route into it instead of straight to master.
    #[serde(rename = "group")]
    Group,
}

impl NodeKind {
    pub fn wire_name(self) -> &'static str {
        match self {
            NodeKind::Bus => "bus",
            NodeKind::Group => "group",
        }
    }

    pub fn parse(s: &str) -> Option<NodeKind> {
        match s {
            "bus" => Some(NodeKind::Bus),
            "group" => Some(NodeKind::Group),
            _ => None,
        }
    }
}

/// Whether an edge taps its source before or after that source's fader.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum Tap {
    #[serde(rename = "pre")]
    Pre,
    #[serde(rename = "post")]
    Post,
}

impl Tap {
    pub fn wire_name(self) -> &'static str {
        match self {
            Tap::Pre => "pre",
            Tap::Post => "post",
        }
    }

    pub fn parse(s: &str) -> Option<Tap> {
        match s {
            "pre" => Some(Tap::Pre),
            "post" => Some(Tap::Post),
            _ => None,
        }
    }
}

/// An explicitly-created node. Track strips and master are implicit and never
/// appear here.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RouteNode {
    pub id: String,
    pub kind: NodeKind,
    pub name: String,
    /// The node FADER, in dB (`Num`, wire-exact — invariant 6). §4.3 promises
    /// buses "with their own fader"; this is that fader's static half, set by
    /// `route.node.set` and pushed into `EngineParams::set_node_gain_db` by
    /// `compile::sync_graph_params` (the `bus.<id>.gain` automation lane is
    /// the other half and needs no model field). Additive: defaults to
    /// integer 0 dB and is omitted from serde AND the hand-built checkpoint
    /// while it still IS integer 0, so a pre-fader project's bytes are
    /// unchanged. The default is INT-shaped on purpose: `Num`'s equality is
    /// shape-aware, so a journaled float `0.0` (or `-0.0`) survives as a
    /// written float rather than being dropped as "the default".
    #[serde(default = "gain_db_default", skip_serializing_if = "gain_db_is_default")]
    pub gain_db: Num,
    /// E5 §16.1/§16.2: the INSERT chain on this bus/group. Chain order is `Vec`
    /// order. Additive and omitted when empty, so a pre-E5 node's bytes are
    /// unchanged. §4.3's "a node is a summing point and nothing else" is
    /// AMENDED by §16: a node IS an effect host.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub fx: Vec<crate::model::Fx>,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub extra: Map<String, Value>,
}

/// The unset node fader: integer-shaped 0 dB (see `RouteNode::gain_db`).
pub fn gain_db_default() -> Num {
    Num::int(0)
}

/// True only for the INT-shaped 0 (`Num`'s `PartialEq` is shape-aware): a
/// float-shaped `0.0` is a real, user-written value and must serialize.
pub fn gain_db_is_default(n: &Num) -> bool {
    *n == Num::int(0)
}

/// A directed edge with a level and a tap point. `level` is `Num`, never
/// `f32`/`f64` — values on the wire are `Num` (invariant 6).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RouteEdge {
    pub id: String,
    pub from: NodeRef,
    pub to: NodeRef,
    pub level: Num,
    pub tap: Tap,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub extra: Map<String, Value>,
}

/// A reference to a node in the graph, serialized as the string grammar
/// `master` | `track.<id>` | `bus.<id>` — deliberately the same segment charset
/// as `ParamRef` so E5 can map one onto the other without a second parser.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum NodeRef {
    Master,
    Track(String),
    /// Any explicitly-created node (bus OR group); the wire prefix is `bus.`
    /// for both because the prefix names the *namespace*, not the kind.
    Node(String),
}

impl NodeRef {
    pub fn parse(s: &str) -> Option<NodeRef> {
        fn id_ok(s: &str) -> bool {
            !s.is_empty()
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        }
        if s == MASTER {
            return Some(NodeRef::Master);
        }
        if let Some(rest) = s.strip_prefix("track.") {
            return id_ok(rest).then(|| NodeRef::Track(rest.to_string()));
        }
        if let Some(rest) = s.strip_prefix("bus.") {
            return id_ok(rest).then(|| NodeRef::Node(rest.to_string()));
        }
        None
    }

    pub fn wire_name(&self) -> String {
        match self {
            NodeRef::Master => MASTER.to_string(),
            NodeRef::Track(id) => format!("track.{id}"),
            NodeRef::Node(id) => format!("bus.{id}"),
        }
    }
}

impl std::fmt::Display for NodeRef {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.wire_name())
    }
}

impl Serialize for NodeRef {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.wire_name())
    }
}

impl<'de> Deserialize<'de> for NodeRef {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        NodeRef::parse(&s)
            .ok_or_else(|| serde::de::Error::custom(format!("malformed node ref {s:?}")))
    }
}

/// The project's routing graph. Empty is the v1 topology (every track straight
/// to master plus the two hard-coded aux buses), so an untouched project
/// serializes to nothing and existing files are unaffected.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct Routing {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub nodes: Vec<RouteNode>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub edges: Vec<RouteEdge>,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub extra: Map<String, Value>,
}

/// One step of the baked evaluation order. `compile.rs` turns this into a flat,
/// preallocated `Box<[NodeStep]>` on the RT snapshot; the audio thread walks it
/// by index and never sorts, allocates or looks anything up.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScheduleStep {
    pub node: NodeRef,
}

impl Routing {
    pub fn is_empty(&self) -> bool {
        self.nodes.is_empty() && self.edges.is_empty() && self.extra.is_empty()
    }

    pub fn node(&self, id: &str) -> Option<&RouteNode> {
        self.nodes.iter().find(|n| n.id == id)
    }

    pub fn node_index(&self, id: &str) -> Option<usize> {
        self.nodes.iter().position(|n| n.id == id)
    }

    pub fn edge(&self, id: &str) -> Option<&RouteEdge> {
        self.edges.iter().find(|e| e.id == id)
    }

    pub fn edge_index(&self, id: &str) -> Option<usize> {
        self.edges.iter().position(|e| e.id == id)
    }

    /// Does `r` name something that exists? `track_ids` comes from the live
    /// project because track nodes are implicit.
    pub fn resolves(&self, r: &NodeRef, track_ids: &BTreeSet<&str>) -> bool {
        match r {
            NodeRef::Master => true,
            NodeRef::Track(id) => track_ids.contains(id.as_str()),
            NodeRef::Node(id) => self.node(id).is_some(),
        }
    }

    /// True when `n` still has its implicit unity edge to master (E5 §4.2).
    ///
    /// > After desugaring, a node N has an implicit `N -> master` post-tap edge
    /// > at unity IF AND ONLY IF the routing declares no `post`-tap edge with
    /// > `from == N`. Pre-tap edges are sends and never suppress it.
    ///
    /// **E5-graph CALLS this; E5-graph does not reimplement it.** Two
    /// implementations of this predicate that disagree is a mix that changes
    /// depending on which code path ran (§11.1).
    ///
    /// Master is the sink and never feeds itself, so it is always `false`.
    pub fn has_implicit_master_feed(&self, n: &NodeRef) -> bool {
        if *n == NodeRef::Master {
            return false;
        }
        !self
            .edges
            .iter()
            .any(|e| e.from == *n && e.tap == Tap::Post)
    }

    /// Validate an edge BEFORE it is added: both endpoints resolve, master is
    /// never a source, no self-loop, no duplicate edge id, and — the important
    /// one — no cycle.
    ///
    /// Equivalent to `validate_new_edge_with_links(edge, track_ids, &[])`;
    /// retained because it is the pre-E5 signature and every caller that has no
    /// sidechain links to declare should keep using it.
    pub fn validate_new_edge(
        &self,
        edge: &RouteEdge,
        track_ids: &BTreeSet<&str>,
    ) -> Result<(), CommandError> {
        self.validate_new_edge_with_links(edge, track_ids, &[])
    }

    /// `validate_new_edge`, aware of the project's sidechain ORDERING links
    /// (E5 §18.1).
    ///
    /// A link is not an audio edge, but it constrains the topological order
    /// exactly as an edge does, so an audio edge can close a cycle *through* a
    /// link. Without this, `route.connect` would accept such an edge, `schedule`
    /// would then fail at compile, and `push_live_session` swallows compile
    /// errors by design (`agent-surface/src/host.rs:743-750`) — live audio would
    /// silently freeze on the previous session. Cycles are rejected at COMMAND
    /// time; the audio thread must never discover one.
    pub fn validate_new_edge_with_links(
        &self,
        edge: &RouteEdge,
        track_ids: &BTreeSet<&str>,
        links: &[(NodeRef, NodeRef)],
    ) -> Result<(), CommandError> {
        let bad = |m: String| Err(CommandError::Routing(m));
        if self.edge(&edge.id).is_some() {
            return bad(format!("edge {} already exists", edge.id));
        }
        if !self.resolves(&edge.from, track_ids) {
            return bad(format!("edge {}: source {} does not exist", edge.id, edge.from));
        }
        if !self.resolves(&edge.to, track_ids) {
            return bad(format!(
                "edge {}: destination {} does not exist",
                edge.id, edge.to
            ));
        }
        if edge.from == edge.to {
            return bad(format!("edge {}: self-loop on {}", edge.id, edge.from));
        }
        if edge.from == NodeRef::Master {
            return bad(format!(
                "edge {}: master is the sink and can never be a source",
                edge.id
            ));
        }
        // Cycle check on the prospective graph, links included.
        let mut probe = self.clone();
        probe.edges.push(edge.clone());
        if let Some(cycle) = probe.find_cycle(track_ids, links) {
            return bad(format!(
                "edge {} would create a cycle: {}",
                edge.id,
                cycle
                    .iter()
                    .map(NodeRef::wire_name)
                    .collect::<Vec<_>>()
                    .join(" -> ")
            ));
        }
        Ok(())
    }

    /// Command-time validation for `fx.sidechain.set` (E5 §18.2/§18.3),
    /// mirroring `validate_new_edge`.
    ///
    /// `host` is the node whose fx chain carries the keyed processor; `source`
    /// is the key. `existing` is every OTHER sidechain link already in the
    /// project (the caller excludes the link being replaced, so re-pointing an
    /// existing link is not rejected against itself).
    ///
    /// The rules are §18.3's acceptance table verbatim:
    /// both endpoints resolve, `source != host` (that is `sidechain: None`, not
    /// a link), master is never a key source, and — the important one — no
    /// cycle over edges + links together.
    pub fn validate_new_link(
        &self,
        source: &NodeRef,
        host: &NodeRef,
        existing: &[(NodeRef, NodeRef)],
        track_ids: &BTreeSet<&str>,
    ) -> Result<(), CommandError> {
        let bad = |m: String| Err(CommandError::Routing(m));
        if !self.resolves(source, track_ids) {
            return bad(format!("sidechain source {source} does not exist"));
        }
        if !self.resolves(host, track_ids) {
            return bad(format!("sidechain host {host} does not exist"));
        }
        if source == host {
            return bad(format!(
                "sidechain source {source} is the fx's own host; that is the internal \
                 detector (no link), not a sidechain"
            ));
        }
        if *source == NodeRef::Master {
            return bad(
                "master is the sink and can never be a sidechain key source".to_string(),
            );
        }
        let mut links: Vec<(NodeRef, NodeRef)> = existing.to_vec();
        links.push((source.clone(), host.clone()));
        if let Some(cycle) = self.find_cycle(track_ids, &links) {
            return bad(format!(
                "sidechain {source} -> {host} would create a cycle: {}",
                cycle
                    .iter()
                    .map(NodeRef::wire_name)
                    .collect::<Vec<_>>()
                    .join(" -> ")
            ));
        }
        Ok(())
    }

    /// Every node in the graph, in deterministic order: tracks (project order),
    /// then explicit nodes (declaration order), then master.
    fn all_nodes(&self, track_ids: &[&str]) -> Vec<NodeRef> {
        let mut v: Vec<NodeRef> = track_ids
            .iter()
            .map(|t| NodeRef::Track((*t).to_string()))
            .collect();
        v.extend(self.nodes.iter().map(|n| NodeRef::Node(n.id.clone())));
        v.push(NodeRef::Master);
        v
    }

    /// Successors over audio edges PLUS ordering-only links (E5 §18.1).
    ///
    /// A sidechain link contributes no audio but constrains the order exactly
    /// like an edge, so the two are indistinguishable to the sort and to cycle
    /// detection — which is the whole point.
    fn adjacency_with(&self, links: &[(NodeRef, NodeRef)]) -> BTreeMap<NodeRef, Vec<NodeRef>> {
        let mut out: BTreeMap<NodeRef, Vec<NodeRef>> = BTreeMap::new();
        for e in &self.edges {
            out.entry(e.from.clone()).or_default().push(e.to.clone());
        }
        for (from, to) in links {
            out.entry(from.clone()).or_default().push(to.clone());
        }
        // Deterministic successor order regardless of declaration order.
        for v in out.values_mut() {
            v.sort();
            v.dedup();
        }
        out
    }

    /// Every node an edge or a link mentions but `all_nodes` did not enumerate.
    fn referenced_nodes(&self, links: &[(NodeRef, NodeRef)]) -> Vec<NodeRef> {
        let mut v = Vec::new();
        for e in &self.edges {
            v.push(e.from.clone());
            v.push(e.to.clone());
        }
        for (from, to) in links {
            v.push(from.clone());
            v.push(to.clone());
        }
        v
    }

    /// Return one cycle if the graph has any, as the node sequence that closes
    /// it. `None` means the graph is a DAG.
    ///
    /// `links` are ordering-only constraints (sidechain keys): `(source, dest)`.
    /// They participate in cycle detection exactly like edges and contribute no
    /// audio (E5 §18.2). Pass `&[]` for the pure audio graph.
    pub fn find_cycle(
        &self,
        track_ids: &BTreeSet<&str>,
        links: &[(NodeRef, NodeRef)],
    ) -> Option<Vec<NodeRef>> {
        let ids: Vec<&str> = track_ids.iter().copied().collect();
        let nodes = self.all_nodes(&ids);
        let adj = self.adjacency_with(links);

        #[derive(Clone, Copy, PartialEq)]
        enum Mark {
            White,
            Grey,
            Black,
        }
        let mut mark: BTreeMap<NodeRef, Mark> =
            nodes.iter().map(|n| (n.clone(), Mark::White)).collect();
        // Edges and links may reference nodes we did not enumerate (e.g. an
        // edge left behind for a track that was removed). Include them so the
        // walk is total rather than silently skipping part of the graph.
        for n in self.referenced_nodes(links) {
            mark.entry(n).or_insert(Mark::White);
        }

        // Iterative DFS so a pathological graph cannot blow the stack.
        let roots: Vec<NodeRef> = mark.keys().cloned().collect();
        let mut path: Vec<NodeRef> = Vec::new();
        for root in roots {
            if mark[&root] != Mark::White {
                continue;
            }
            let mut stack: Vec<(NodeRef, usize)> = vec![(root.clone(), 0)];
            mark.insert(root.clone(), Mark::Grey);
            path.push(root);
            while let Some((node, idx)) = stack.pop() {
                let succs = adj.get(&node).map(Vec::as_slice).unwrap_or(&[]);
                if idx < succs.len() {
                    stack.push((node.clone(), idx + 1));
                    let next = succs[idx].clone();
                    match mark.get(&next).copied().unwrap_or(Mark::White) {
                        Mark::Grey => {
                            // Found a back edge: cut the path at `next`.
                            let start = path.iter().position(|p| *p == next).unwrap_or(0);
                            let mut cycle = path[start..].to_vec();
                            cycle.push(next);
                            return Some(cycle);
                        }
                        Mark::White => {
                            mark.insert(next.clone(), Mark::Grey);
                            path.push(next.clone());
                            stack.push((next, 0));
                        }
                        Mark::Black => {}
                    }
                } else {
                    mark.insert(node.clone(), Mark::Black);
                    if path.last() == Some(&node) {
                        path.pop();
                    }
                }
            }
        }
        None
    }

    /// The baked evaluation order: a topological sort where every node is
    /// scheduled strictly after every node that feeds it, master last.
    ///
    /// Deterministic by construction: ties break on the enumeration order from
    /// `all_nodes` (project track order, then node declaration order), so the
    /// same project always produces the same schedule and therefore the same
    /// bounce.
    ///
    /// `links` are ordering-only constraints (sidechain keys): `(source, dest)`.
    /// They participate in topological ordering exactly like edges and
    /// contribute no audio (E5 §18.2). Pass `&[]` for the pure audio graph.
    ///
    /// ⚠️ **A sidechain link is NOT an audio edge, so the sort MUST be told
    /// about it** (§17.3). If it is not, a keyed processor reads
    /// `node_acc[source]` before it has been written this frame — i.e. exactly
    /// `0.0`, **silence, not a small error** — and the compressor never ducks.
    /// Every model-level test would still pass. `tests/fx_sidechain_order.rs`
    /// is the test that catches it.
    pub fn schedule(
        &self,
        track_ids: &[&str],
        links: &[(NodeRef, NodeRef)],
    ) -> Result<Vec<ScheduleStep>, CommandError> {
        let nodes = self.all_nodes(track_ids);
        let adj = self.adjacency_with(links);

        let mut order_index: BTreeMap<NodeRef, usize> = BTreeMap::new();
        for (i, n) in nodes.iter().enumerate() {
            order_index.insert(n.clone(), i);
        }
        let mut extra: Vec<NodeRef> = Vec::new();
        for n in self.referenced_nodes(links) {
            if !order_index.contains_key(&n) {
                order_index.insert(n.clone(), nodes.len() + extra.len());
                extra.push(n);
            }
        }
        let mut all = nodes;
        all.extend(extra);

        let mut indegree: BTreeMap<NodeRef, usize> =
            all.iter().map(|n| (n.clone(), 0usize)).collect();
        for tos in adj.values() {
            for t in tos {
                if let Some(d) = indegree.get_mut(t) {
                    *d += 1;
                }
            }
        }

        // Kahn's algorithm, always taking the lowest enumeration index that is
        // ready. Master is last in the enumeration, so it falls out last unless
        // something genuinely feeds off it (which validate_new_edge forbids).
        let mut ready: Vec<NodeRef> = all
            .iter()
            .filter(|n| indegree[*n] == 0)
            .cloned()
            .collect();
        ready.sort_by_key(|n| order_index[n]);
        let mut out: Vec<ScheduleStep> = Vec::with_capacity(all.len());

        while !ready.is_empty() {
            let n = ready.remove(0);
            if let Some(tos) = adj.get(&n) {
                for t in tos {
                    if let Some(d) = indegree.get_mut(t) {
                        *d -= 1;
                        if *d == 0 {
                            ready.push(t.clone());
                        }
                    }
                }
            }
            out.push(ScheduleStep { node: n });
            // Keep the frontier in enumeration order so the schedule is a pure
            // function of the project, not of edge discovery order.
            ready.sort_by_key(|n| order_index[n]);
        }

        if out.len() != all.len() {
            let set: BTreeSet<&str> = track_ids.iter().copied().collect();
            let cycle = self
                .find_cycle(&set, links)
                .map(|c| {
                    c.iter()
                        .map(NodeRef::wire_name)
                        .collect::<Vec<_>>()
                        .join(" -> ")
                })
                .unwrap_or_else(|| "unknown".into());
            return Err(CommandError::Routing(format!(
                "routing graph is not a DAG (cycle: {cycle}); it should have been \
                 rejected at command time"
            )));
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn edge(id: &str, from: &str, to: &str) -> RouteEdge {
        RouteEdge {
            id: id.into(),
            from: NodeRef::parse(from).unwrap(),
            to: NodeRef::parse(to).unwrap(),
            level: Num::int(1),
            tap: Tap::Post,
            extra: Map::new(),
        }
    }

    fn node(id: &str) -> RouteNode {
        RouteNode {
            id: id.into(),
            kind: NodeKind::Bus,
            name: id.into(),
            gain_db: gain_db_default(),
            fx: Vec::new(),
            extra: Map::new(),
        }
    }

    #[test]
    fn node_ref_round_trips() {
        for s in ["master", "track.t1", "bus.rev", "track.01J8X-Z_9"] {
            let r = NodeRef::parse(s).unwrap();
            assert_eq!(r.wire_name(), s);
            assert_eq!(serde_json::to_string(&r).unwrap(), format!("\"{s}\""));
        }
        for s in ["", "track.", "bus.", "track.a.b", "nope.x", "Master"] {
            assert!(NodeRef::parse(s).is_none(), "{s:?} should not parse");
        }
    }

    #[test]
    fn empty_graph_schedules_tracks_then_master() {
        let r = Routing::default();
        let sched = r.schedule(&["t1", "t2"], &[]).unwrap();
        assert_eq!(
            sched.iter().map(|s| s.node.wire_name()).collect::<Vec<_>>(),
            ["track.t1", "track.t2", "master"]
        );
    }

    #[test]
    fn sources_are_scheduled_before_their_destinations() {
        let mut r = Routing::default();
        r.nodes.push(node("grp"));
        r.edges.push(edge("e1", "track.t1", "bus.grp"));
        r.edges.push(edge("e2", "bus.grp", "master"));
        let sched: Vec<String> = r
            .schedule(&["t1", "t2"], &[])
            .unwrap()
            .iter()
            .map(|s| s.node.wire_name())
            .collect();
        let pos = |n: &str| sched.iter().position(|s| s == n).unwrap();
        assert!(pos("track.t1") < pos("bus.grp"));
        assert!(pos("bus.grp") < pos("master"));
        assert_eq!(sched.len(), 4);
    }

    #[test]
    fn schedule_is_deterministic_regardless_of_edge_declaration_order() {
        let mk = |rev: bool| {
            let mut r = Routing::default();
            r.nodes.push(node("a"));
            r.nodes.push(node("b"));
            let mut es = vec![
                edge("e1", "track.t1", "bus.a"),
                edge("e2", "track.t2", "bus.b"),
                edge("e3", "bus.a", "master"),
                edge("e4", "bus.b", "master"),
            ];
            if rev {
                es.reverse();
            }
            r.edges = es;
            r.schedule(&["t1", "t2"], &[])
                .unwrap()
                .iter()
                .map(|s| s.node.wire_name())
                .collect::<Vec<_>>()
        };
        assert_eq!(mk(false), mk(true));
    }

    #[test]
    fn cycles_are_detected() {
        let mut r = Routing::default();
        r.nodes.push(node("a"));
        r.nodes.push(node("b"));
        r.edges.push(edge("e1", "bus.a", "bus.b"));
        r.edges.push(edge("e2", "bus.b", "bus.a"));
        let ids: BTreeSet<&str> = BTreeSet::new();
        assert!(r.find_cycle(&ids, &[]).is_some());
        assert!(r.schedule(&[], &[]).is_err());
    }

    #[test]
    fn validate_rejects_the_cycle_closing_edge_at_command_time() {
        let mut r = Routing::default();
        r.nodes.push(node("a"));
        r.nodes.push(node("b"));
        r.edges.push(edge("e1", "bus.a", "bus.b"));
        let ids: BTreeSet<&str> = ["t1"].into_iter().collect();
        let err = r
            .validate_new_edge(&edge("e2", "bus.b", "bus.a"), &ids)
            .unwrap_err();
        assert!(format!("{err}").contains("cycle"), "{err}");
        // ... and the graph is unchanged, because validation happens first.
        assert_eq!(r.edges.len(), 1);
        assert!(r.find_cycle(&ids, &[]).is_none());
    }

    #[test]
    fn validate_rejects_self_loops_master_sources_and_dangling_refs() {
        let mut r = Routing::default();
        r.nodes.push(node("a"));
        let ids: BTreeSet<&str> = ["t1"].into_iter().collect();
        assert!(r.validate_new_edge(&edge("x", "bus.a", "bus.a"), &ids).is_err());
        assert!(r.validate_new_edge(&edge("x", "master", "bus.a"), &ids).is_err());
        assert!(r.validate_new_edge(&edge("x", "track.zz", "bus.a"), &ids).is_err());
        assert!(r.validate_new_edge(&edge("x", "bus.zz", "master"), &ids).is_err());
        assert!(r.validate_new_edge(&edge("x", "track.t1", "bus.a"), &ids).is_ok());
        r.edges.push(edge("x", "track.t1", "bus.a"));
        assert!(
            r.validate_new_edge(&edge("x", "track.t1", "master"), &ids).is_err(),
            "duplicate edge id"
        );
    }

    /// E5 §4.2's table, one assertion per row. **E5-graph calls this predicate;
    /// it must not reimplement it** — two implementations that disagree is a mix
    /// that changes depending on which code path ran.
    #[test]
    fn implicit_master_feed_matches_the_table_in_section_4_2() {
        let t1 = NodeRef::Track("t1".into());
        let grp = NodeRef::Node("grp".into());

        // Row 1: empty Routing -> every track feeds master. Exactly v1.
        let r = Routing::default();
        assert!(r.has_implicit_master_feed(&t1));

        // Row 2: a POST edge to a group suppresses the implicit feed, so t1
        // feeds only the group and is not double-counted.
        let mut r = Routing::default();
        r.nodes.push(node("grp"));
        r.edges.push(edge("e1", "track.t1", "bus.grp"));
        assert!(!r.has_implicit_master_feed(&t1));
        assert!(r.has_implicit_master_feed(&grp), "the group still feeds master");

        // Row 3: a PRE edge is a SEND and never suppresses the implicit feed —
        // t1 feeds master AND the bus.
        let mut r = Routing::default();
        r.nodes.push(node("rev"));
        let mut send = edge("e1", "track.t1", "bus.rev");
        send.tap = Tap::Pre;
        r.edges.push(send);
        assert!(r.has_implicit_master_feed(&t1));

        // Row 4: an explicit post edge to master coexists with a post edge to a
        // group; the implicit feed is gone because a post edge exists at all.
        let mut r = Routing::default();
        r.nodes.push(node("grp"));
        r.edges.push(edge("e1", "track.t1", "bus.grp"));
        r.edges.push(edge("e2", "track.t1", "master"));
        assert!(!r.has_implicit_master_feed(&t1));

        // Row 5: disconnecting the last post edge brings the implicit feed back.
        r.edges.retain(|e| e.tap != Tap::Post);
        assert!(r.has_implicit_master_feed(&t1));

        // Master is the sink and never feeds itself.
        assert!(!Routing::default().has_implicit_master_feed(&NodeRef::Master));
    }

    #[test]
    fn a_long_chain_still_sorts() {
        let mut r = Routing::default();
        for i in 0..64 {
            r.nodes.push(node(&format!("n{i}")));
        }
        for i in 0..63 {
            r.edges
                .push(edge(&format!("e{i}"), &format!("bus.n{i}"), &format!("bus.n{}", i + 1)));
        }
        r.edges.push(edge("elast", "bus.n63", "master"));
        let sched = r.schedule(&[], &[]).unwrap();
        assert_eq!(sched.len(), 65);
        assert_eq!(sched.last().unwrap().node, NodeRef::Master);
        for i in 0..63 {
            let a = sched
                .iter()
                .position(|s| s.node == NodeRef::Node(format!("n{i}")))
                .unwrap();
            let b = sched
                .iter()
                .position(|s| s.node == NodeRef::Node(format!("n{}", i + 1)))
                .unwrap();
            assert!(a < b);
        }
    }
}
