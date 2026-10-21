//! 10k-command fuzz: drive a session with a long stream of legal-by-
//! construction commands and assert no panic and that the model invariants
//! hold throughout: clips stay within their track, same-track clips never
//! overlap (crossfade rule aside, which is edge metadata not overlap), every
//! clip has positive length, materialized frames match the tick source, and
//! the journal hash chain stays intact.

#[path = "support.rs"]
mod support;

use support::Conductor;
use timeline_core::envelope::GENESIS_HASH;
use timeline_core::journal::verify_lines;
use timeline_core::model::Project;
use timeline_core::session::Session;
use timeline_core::{TempoMap};
use timeline_core::tempo::Bpm;

fn check_invariants(project: &Project) {
    for track in &project.tracks {
        // clips sorted by start_frame and non-overlapping in ticks
        let mut prev_end_ticks: Option<u64> = None;
        let mut prev_start_frame = 0u64;
        for clip in &track.clips {
            assert!(clip.length_ticks > 0, "clip {} has zero length", clip.id);
            assert!(clip.len_frames > 0, "clip {} has zero frame length", clip.id);
            // materialization matches a fresh recompute
            let start = project.tempo.tick_to_frame(clip.start_ticks, project.sample_rate);
            assert_eq!(clip.start_frame, start, "clip {} start frame stale", clip.id);
            // sorted by start_frame
            assert!(
                clip.start_frame >= prev_start_frame,
                "track {} clips not sorted",
                track.id
            );
            prev_start_frame = clip.start_frame;
            // no overlap in ticks
            if let Some(pe) = prev_end_ticks {
                assert!(
                    clip.start_ticks >= pe,
                    "track {} overlap: clip {} starts {} before prev end {}",
                    track.id,
                    clip.id,
                    clip.start_ticks,
                    pe
                );
            }
            prev_end_ticks = Some(clip.end_ticks());
        }
    }
}

#[test]
fn fuzz_10k_commands_no_panic_invariants_hold() {
    let target = 10_000usize;
    let mut conductor = Conductor::new(0xC0FFEE_1234_5678);
    let project = Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()));
    let mut session = Session::new(project);

    let mut applied = 0usize;
    let mut attempts = 0usize;
    let mut n = 1u64;
    let mut rejected = 0usize;
    while applied < target && attempts < target * 6 {
        attempts += 1;
        let cmd = conductor.gen(session.project());
        match session.submit(support::user_meta(n), cmd) {
            Ok(sub) if !sub.duplicate => {
                n += 1;
                applied += 1;
                if applied % 500 == 0 {
                    check_invariants(session.project());
                }
            }
            Ok(_) => {}
            Err(_) => rejected += 1,
        }
    }

    assert!(
        applied >= target,
        "only applied {applied}/{target} commands ({rejected} rejected)"
    );
    check_invariants(session.project());

    // journal chain intact end to end
    let lines: Vec<String> = session.journal().iter().map(|e| e.to_jsonl()).collect();
    let (tip, count) = verify_lines(&lines).expect("fuzz journal chain verifies");
    assert_eq!(count, session.seq() as usize, "journal length");
    assert_eq!(tip, session.tip_hash(), "journal tip");
    assert_ne!(tip, GENESIS_HASH, "chain advanced past genesis");

    // full replay reproduces the fuzzed state
    let base = Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()));
    let replayed = Session::replay(base, session.journal().to_vec()).expect("replay fuzz journal");
    assert!(
        session.project() == replayed.project(),
        "fuzz replay diverged from live state"
    );

    println!(
        "fuzz OK: {applied} commands applied ({rejected} illegal candidates skipped), \
         {} tracks, chain tip {}",
        session.project().tracks.len(),
        &tip[..12]
    );
}
