//! Property tests (proptest): the three acceptance properties from the brief.
//! (a) journal replay from empty == the live checkpoint model on random
//! command sequences; (b) undo(redo(x)) == x (full undo then redo returns the
//! exact state); (c) every applied command's inverse restores the exact
//! pre-state (inverse coverage on real state).

#[path = "support.rs"]
mod support;

use proptest::prelude::*;
use timeline_core::catalog::Catalog;
use timeline_core::envelope::Actor;
use timeline_core::session::{Session, SeqMeta};
use timeline_core::{Project, TempoMap};
use timeline_core::tempo::Bpm;

fn empty() -> Project {
    Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()))
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 120, ..ProptestConfig::default() })]

    /// (a) Replaying the journal from empty reproduces the live model exactly.
    #[test]
    fn replay_from_empty_equals_live_checkpoint(seed in any::<u64>(), steps in 3usize..90) {
        let (session, _cmds, _n) = support::build_random(seed, steps);
        let journal = session.journal().to_vec();
        let replayed = Session::replay(empty(), journal).expect("replay");
        prop_assert!(
            session.project() == replayed.project(),
            "replay diverged from checkpoint at seed {seed}, steps {steps}"
        );
        // and the tip hash matches (the chain is the same)
        prop_assert_eq!(session.tip_hash(), replayed.tip_hash());
    }

    /// (b) Full undo then full redo returns the exact state (undo(redo(x))==x).
    #[test]
    fn undo_then_redo_is_identity(seed in any::<u64>(), steps in 3usize..90) {
        let (mut session, _cmds, n) = support::build_random(seed, steps);
        let before = session.project().clone();
        let depth = session.undo_depth();
        let mut meta = SeqMeta::starting_at(n + 1, Actor::user("undo"));

        // undo everything
        let mut undone = 0;
        while session.undo(&mut meta).expect("undo") {
            undone += 1;
            prop_assert!(undone <= depth + 1, "undo looped");
        }
        prop_assert_eq!(undone, depth, "undo unit count");

        // redo everything
        let mut redone = 0;
        while session.redo(&mut meta).expect("redo") {
            redone += 1;
            prop_assert!(redone <= depth + 1, "redo looped");
        }
        prop_assert_eq!(redone, depth, "redo unit count");

        prop_assert!(
            before == *session.project(),
            "undo+redo changed state at seed {seed}, steps {steps}"
        );
    }

    /// Full undo returns to the empty baseline (nothing left behind).
    #[test]
    fn full_undo_returns_to_baseline(seed in any::<u64>(), steps in 3usize..90) {
        let (mut session, _cmds, n) = support::build_random(seed, steps);
        let baseline = empty();
        let mut meta = SeqMeta::starting_at(n + 1, Actor::user("undo"));
        while session.undo(&mut meta).expect("undo") {}
        // Tracks/clips/sections/markers all gone; tempo back to 120.
        prop_assert_eq!(session.project().tracks.len(), baseline.tracks.len());
        prop_assert_eq!(session.project().sections.len(), 0);
        prop_assert_eq!(session.project().markers.len(), 0);
        prop_assert_eq!(&session.project().bpm_wire, &baseline.bpm_wire);
    }

    /// (c) Every single applied command's inverse restores the exact pre-state.
    #[test]
    fn single_command_inverse_restores_prestate(seed in any::<u64>(), steps in 0usize..40) {
        // Build a random state, then generate one more legal command and check
        // its inverse round-trips at the model level.
        let (session, _cmds, _n) = support::build_random(seed, steps);
        let mut project = session.project().clone();
        let mut conductor = support::Conductor::new(seed ^ 0x5DEECE66D);
        let cmd = conductor.gen(&project);
        let name = cmd.name();
        let spec = Catalog::get().spec(name).unwrap();
        let pre = project.clone();
        match project.apply_cmd(&cmd) {
            Ok(effect) => {
                if spec.undoable {
                    for inv in &effect.inverse {
                        project.apply_cmd(inv).unwrap_or_else(|e| {
                            panic!("inverse of {name} failed to apply: {e}")
                        });
                    }
                    prop_assert!(
                        pre == project,
                        "inverse of {name} did not restore pre-state (seed {seed})"
                    );
                }
            }
            Err(_) => { /* illegal candidate for this state: skip */ }
        }
    }
}
