//! E5-graph: plugin delay compensation (`DESIGN-E5-routing.md` §19).
//!
//! One forward pass over the already-topologically-sorted schedule, entirely
//! CONTROL-SIDE. The audio thread only ever reads `RtEdge::comp` and, when it
//! is non-zero, an integer-tap ring that was allocated here.
//!
//! ```text
//! for step in schedule_order:
//!     upstream   = max(latency[from] for every incoming edge OR link)
//!     latency[n] = upstream + own_latency(n)
//!
//! for e in edges:
//!     comp[e] = latency[e.to] - own_latency(e.to) - latency[e.from]   # >= 0
//! ```
//!
//! Two details that are easy to get wrong and are therefore stated:
//!
//! * **Sidechain links propagate latency but never RECEIVE compensation**
//!   (§19.2). A key is a control signal; delaying it to match an audio path
//!   would make the compressor duck late. Links appear in the `upstream` max
//!   and never in the `comp` output.
//! * **A zero-frame compensation is a bit-exact passthrough**, not a ring read
//!   at offset 0 (§19.3). `RtEdge::comp == 0` means the caller adds the sample
//!   it already has; the ring for that edge is empty and never touched. This
//!   is what lets the §12.2 legacy-null gate run *through* the PDC code path
//!   and still produce identical bytes.
//! * **Master's own latency is not compensated** (§19.5). Master is the
//!   topological sink; there is no parallel path to phase against. The master
//!   limiter's uncompensated 96 frames is a transport-alignment concern owned
//!   by whoever owns transport alignment, and "fixing" it here would shift the
//!   whole output relative to the timeline — a different bug in the first
//!   one's clothes.
//!
//! The node identity used here is the **accumulator slot** (`routing_rt`'s
//! flat slot space), not `NodeRef`: the two render-side-only `LegacyFx` nodes
//! have no wire form at all (§2.1), so a `NodeRef`-keyed pass could not name
//! them.

use crate::routing_rt::MAX_COMP_FRAMES;

/// The result of one compensation pass.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pdc {
    /// Accumulated latency at each accumulator slot's OUTPUT.
    pub latency: Vec<u32>,
    /// Compensation frames per input edge, index-aligned with the `edges`
    /// argument.
    pub comp: Vec<u32>,
}

/// Longest-path compensation over a scheduled DAG.
///
/// * `order` — accumulator slots in topological order (the compiled schedule).
/// * `edges` — audio edges as `(from_slot, to_slot)`, in any order.
/// * `links` — sidechain ordering constraints as `(source_slot, host_slot)`.
/// * `own` — frames of latency the node itself adds (its fx chain).
/// * `n_slots` — size of the accumulator slot space.
/// * `name` — human name for a slot, used only in the hard-error message.
pub fn compute(
    order: &[usize],
    edges: &[(usize, usize)],
    links: &[(usize, usize)],
    own: &[u32],
    n_slots: usize,
    name: &dyn Fn(usize) -> String,
) -> Result<Pdc, String> {
    let mut latency = vec![0_u32; n_slots];

    // Incoming adjacency, edges and links together: both constrain arrival
    // time, and the sort was told about both (§18.2).
    let mut incoming: Vec<Vec<usize>> = vec![Vec::new(); n_slots];
    for (from, to) in edges.iter().chain(links.iter()) {
        if *to < n_slots && *from < n_slots {
            incoming[*to].push(*from);
        }
    }

    for &n in order {
        if n >= n_slots {
            continue;
        }
        let upstream = incoming[n].iter().map(|f| latency[*f]).max().unwrap_or(0);
        let own_n = own.get(n).copied().unwrap_or(0);
        latency[n] = upstream.saturating_add(own_n);
        if own_n > MAX_COMP_FRAMES {
            return Err(format!(
                "node {} reports {own_n} frames of latency, above the \
                 MAX_COMP_FRAMES cap of {MAX_COMP_FRAMES}; refusing rather than \
                 silently truncating the compensation (DESIGN-E5-routing.md §19.3)",
                name(n)
            ));
        }
    }

    let mut comp = Vec::with_capacity(edges.len());
    for (from, to) in edges {
        let (from, to) = (*from, *to);
        if from >= n_slots || to >= n_slots {
            comp.push(0);
            continue;
        }
        let target = latency[to].saturating_sub(own.get(to).copied().unwrap_or(0));
        let c = target.saturating_sub(latency[from]);
        if c > MAX_COMP_FRAMES {
            return Err(format!(
                "edge into {} needs {c} frames of delay compensation, above the \
                 MAX_COMP_FRAMES cap of {MAX_COMP_FRAMES}; refusing rather than \
                 silently phasing the parallel paths (DESIGN-E5-routing.md §19.3)",
                name(to)
            ));
        }
        comp.push(c);
    }

    Ok(Pdc { latency, comp })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn nm(i: usize) -> String {
        format!("slot{i}")
    }

    /// A graph with no latency anywhere compensates nothing. This is the
    /// property that makes the legacy-null gate run *through* PDC.
    #[test]
    fn zero_latency_graph_compensates_nothing() {
        // 0 -> 2, 1 -> 2
        let p = compute(&[0, 1, 2], &[(0, 2), (1, 2)], &[], &[0, 0, 0], 3, &nm).unwrap();
        assert_eq!(p.comp, vec![0, 0]);
        assert_eq!(p.latency, vec![0, 0, 0]);
    }

    /// The §20.2 proof 7 shape: a dry path and a path through a 96-frame node
    /// both land on master; the dry one is delayed to match.
    #[test]
    fn parallel_paths_are_aligned() {
        // 0 (dry) -> 3 (master); 1 -> 2 (limiter bus, 96) -> 3
        let own = [0, 0, 96, 0];
        let p = compute(
            &[0, 1, 2, 3],
            &[(0, 3), (1, 2), (2, 3)],
            &[],
            &own,
            4,
            &nm,
        )
        .unwrap();
        assert_eq!(p.latency[2], 96);
        assert_eq!(p.latency[3], 96);
        // dry edge 0->3 gets 96 frames; 1->2 gets 0; 2->3 gets 0.
        assert_eq!(p.comp, vec![96, 0, 0]);
    }

    /// §19.2: a link constrains arrival time but is never compensated.
    #[test]
    fn links_propagate_latency_but_are_not_compensated() {
        // 0 -> 1 (audio); 2 keys 1 (link) and 2 has 64 frames of its own.
        let own = [0, 0, 64];
        let p = compute(&[0, 2, 1], &[(0, 1)], &[(2, 1)], &own, 3, &nm).unwrap();
        assert_eq!(p.latency[1], 64, "the key's latency reaches the host");
        // Exactly ONE comp value: the audio edge. The link produced none.
        assert_eq!(p.comp.len(), 1);
        assert_eq!(p.comp, vec![64]);
    }

    #[test]
    fn an_over_cap_node_is_refused_by_name() {
        let own = [0, MAX_COMP_FRAMES + 1];
        let err = compute(&[0, 1], &[(0, 1)], &[], &own, 2, &nm).unwrap_err();
        assert!(err.contains("slot1"), "{err}");
        assert!(err.contains(&MAX_COMP_FRAMES.to_string()), "{err}");
        assert!(err.contains("4097"), "{err}");
    }
}
