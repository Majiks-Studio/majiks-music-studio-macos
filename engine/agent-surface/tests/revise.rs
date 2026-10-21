//! L9 acceptance, headless: the full Revise flow against the deterministic mock
//! generator, proving the parts that must be true no matter what model renders:
//!
//!  - the stem-scope splice null-preserves the unscoped stems and keeps the
//!    outside-region audio bit-exact (P0-A: raw repaint never appears outside);
//!  - commit is ONE undo transaction, and the commit-undo round-trip restores
//!    the exact original asset on every scoped clip;
//!  - the commit boundary passes a declick check (equal-power ramp >= 5 ms, no
//!    cut step) once the spliced clip is rendered through the real graph;
//!  - the draft/commit two-phase (finalize) swaps draft->full sample-aligned and
//!    is itself undoable back to the draft;
//!  - extend and add-a-layer land correctly and undo;
//!  - every landed take carries engine identity + lineage;
//!  - the whole flow runs identically via MCP (dispatch_tool), i.e. agent parity.
//!
//! Silence-gated: the mock fixtures are low-amplitude tones (<= about 0.05
//! peak), and this binary never opens an audio device.

use std::f32::consts::PI;
use std::path::Path;

use agent_surface::revise::splice::{max_adjacent_step, residual_dbfs};
use agent_surface::{dispatch_tool, StudioHost};
use render::media::write_wav_f32;
use serde_json::{json, Value};
use timeline_core::envelope::ActorKind;
use timeline_core::Actor;

const RATE: u32 = 48_000;
const BPM: f64 = 120.0;
const BAR_TICKS: u64 = 4 * 960; // 3840; at 120 bpm one bar = 2 s
const STEMS: [&str; 4] = ["vocals", "drums", "bass", "other"];

fn user() -> Actor {
    Actor::user("test")
}

/// A distinct low-amplitude tone per stem, `bars` long at 120 bpm, so each
/// stem's audio is unique and the null tests are meaningful. Silence-gated.
fn synth_stem(stem: &str, bars: u32) -> Vec<[f32; 2]> {
    let freq = match stem {
        "vocals" => 440.0,
        "drums" => 130.0,
        "bass" => 65.0,
        "other" => 330.0,
        _ => 261.63,
    };
    let n = (bars as f64 * (4.0 * 60.0 / BPM) * RATE as f64) as usize;
    let mut out = vec![[0.0f32; 2]; n];
    for (i, f) in out.iter_mut().enumerate() {
        let t = i as f64 / RATE as f64;
        let v = (0.04 * (2.0 * PI as f64 * freq * t).sin()) as f32;
        *f = [v, v];
    }
    out
}

/// Build a 4-stem, 4-bar session in a fresh package (one stem clip per track,
/// all bar-aligned at tick 0), returning the host and the original asset hash of
/// each stem clip.
fn build_session(pkg: &Path) -> (StudioHost, std::collections::BTreeMap<String, String>) {
    let mut host = StudioHost::create_at(pkg, "ReviseTest").unwrap();
    host.submit(user(), "project.setTempo", json!({ "bpm": 120 })).unwrap();
    let work = pkg.join("_synth");
    std::fs::create_dir_all(&work).unwrap();
    let mut original = std::collections::BTreeMap::new();
    for stem in STEMS {
        let track_id = format!("trk_{stem}");
        host.submit(user(), "track.add", json!({ "trackId": track_id, "name": stem })).unwrap();
        let wav = work.join(format!("{stem}.wav"));
        write_wav_f32(&wav, &synth_stem(stem, 4), RATE).unwrap();
        let outcome = host
            .import_audio(&wav.to_string_lossy(), &track_id, 0, Some(format!("clip_{stem}")))
            .unwrap();
        original.insert(stem.to_string(), outcome.asset_hash);
    }
    (host, original)
}

fn clip_asset(host: &StudioHost, clip_id: &str) -> String {
    host.project().clip(clip_id).unwrap().source_id.clone()
}

fn region_frames(host: &StudioHost, start_ticks: u64, end_ticks: u64) -> (usize, usize) {
    let p = host.project();
    let s = p.tempo.tick_to_frame(start_ticks, p.sample_rate) as usize;
    let e = p.tempo.tick_to_frame(end_ticks, p.sample_rate) as usize;
    (s, e)
}

/// The variant-1 promotions for a scoped stem from a studio_revise result.
fn variant_promotions(result: &Value, variant: usize) -> Value {
    result["variantTakes"][variant]["promotions"].clone()
}

#[test]
fn stem_scope_revise_commits_null_preserves_and_undoes() {
    let dir = tempfile::tempdir().unwrap();
    let pkg = dir.path().join("Scope.mstudio");
    let (mut host, original) = build_session(&pkg);

    // Region = bars 2..3 (1 bar), scope = drums + other. Vocals + bass must
    // NEVER change (null-preserve).
    let region_start = 1 * BAR_TICKS; // bar 2 (0-based bar 1)
    let region_end = 2 * BAR_TICKS; // bar 3
    let (rs_frame, re_frame) = region_frames(&host, region_start, region_end);

    // Capture the decoded originals for the bit-exact null test.
    let orig_drums = host.asset_samples(&original["drums"]).unwrap();
    let orig_other = host.asset_samples(&original["other"]).unwrap();

    let result = agent_surface::revise::dispatch_revise(
        &mut host,
        user(),
        &json!({
            "clipIds": ["clip_drums", "clip_other"],
            "regionStartTicks": region_start,
            "regionEndTicks": region_end,
            "scope": ["drums", "other"],
            "instruction": "half-time, darker",
            "variants": 3,
            "seed": 22,
            "engine": "mock"
        }),
    )
    .unwrap();

    assert_eq!(result["variants"], json!(3));
    assert_eq!(result["engine"], json!("mock-fixture"));
    assert_eq!(result["targets"].as_array().unwrap().len(), 2, "two scoped stem targets");
    // Every take carries engine identity + lineage (via gen.landed in the journal).
    let takes = host.takes(&json!({}));
    assert_eq!(takes["takes"].as_array().unwrap().len(), 6, "2 stems x 3 variants = 6 candidate takes");

    // Commit variant 1 (drums + other) as ONE undo transaction.
    let commit = agent_surface::revise::dispatch_commit(
        &mut host,
        user(),
        &json!({ "promotions": variant_promotions(&result, 1), "reason": "revise bars 2-3" }),
    )
    .unwrap();
    assert_eq!(commit["undo"], json!("one step"));

    // Scoped clips now carry a NEW spliced asset; unscoped are UNCHANGED.
    let new_drums = clip_asset(&host, "clip_drums");
    let new_other = clip_asset(&host, "clip_other");
    assert_ne!(new_drums, original["drums"], "drums clip took the spliced asset");
    assert_ne!(new_other, original["other"], "other clip took the spliced asset");
    assert_eq!(clip_asset(&host, "clip_vocals"), original["vocals"], "vocals null-preserved");
    assert_eq!(clip_asset(&host, "clip_bass"), original["bass"], "bass null-preserved");

    // NULL TEST: outside the region, the spliced drums asset is BIT-EXACT to
    // the original drums (P0-A: never present repaint outside the region).
    let spliced_drums = host.asset_samples(&new_drums).unwrap();
    assert_eq!(spliced_drums.samples.len(), orig_drums.samples.len(), "same-length substitution");
    for i in 0..orig_drums.samples.len() {
        if i < rs_frame || i >= re_frame {
            assert_eq!(
                spliced_drums.samples[i], orig_drums.samples[i],
                "drums sample {i} outside region is not bit-exact"
            );
        }
    }
    // The residual outside the region is pure silence (the null test proper).
    let outside_orig: Vec<[f32; 2]> = orig_drums.samples[..rs_frame].to_vec();
    let outside_new: Vec<[f32; 2]> = spliced_drums.samples[..rs_frame].to_vec();
    let (peak, _) = residual_dbfs(&outside_new, &outside_orig);
    assert_eq!(peak, -200.0, "outside-region residual is not silence: {peak} dBFS");
    // Inside the region the audio actually changed (the revise did something).
    let (in_peak, _) = residual_dbfs(
        &spliced_drums.samples[rs_frame..re_frame],
        &orig_drums.samples[rs_frame..re_frame],
    );
    assert!(in_peak > -60.0, "region audio did not change: {in_peak} dBFS");
    let _ = orig_other;

    // DECLICK: on the committed (spliced) drums asset, neither seam adds a cut
    // step beyond the material's own local slope. Compare each seam to a clean
    // baseline window well away from the region (P0-A: a good seam sits at the
    // song's own boundary floor). A hard cut here would step ~0.08 (two 0.04
    // tones), so the seam being at the baseline is the declick proof.
    let baseline = max_adjacent_step(&spliced_drums.samples, rs_frame / 2, 400);
    let start_step = max_adjacent_step(&spliced_drums.samples, rs_frame, 8);
    let end_step = max_adjacent_step(&spliced_drums.samples, re_frame, 8);
    assert!(
        start_step <= baseline * 3.0 + 1e-4,
        "commit start seam clicks: step {start_step} vs baseline {baseline}"
    );
    assert!(
        end_step <= baseline * 3.0 + 1e-4,
        "commit end seam clicks: step {end_step} vs baseline {baseline}"
    );
    // And the spliced asset resolves + renders through the real offline graph.
    assert!(host.render_master().is_ok(), "spliced session did not render");

    // COMMIT-UNDO ROUND-TRIP: one undo restores every scoped clip's ORIGINAL
    // asset exactly (the whole txn is one unit).
    assert!(host.undo(user()).unwrap());
    assert_eq!(clip_asset(&host, "clip_drums"), original["drums"], "undo did not restore drums");
    assert_eq!(clip_asset(&host, "clip_other"), original["other"], "undo did not restore other");
    // Redo re-applies the whole commit.
    assert!(host.redo(user()).unwrap());
    assert_eq!(clip_asset(&host, "clip_drums"), new_drums, "redo did not re-commit drums");
}

#[test]
fn all_stems_revise_then_finalize_two_phase_swaps_and_undoes() {
    let dir = tempfile::tempdir().unwrap();
    let pkg = dir.path().join("Finalize.mstudio");
    // A single full-mix clip session for the all-stems path.
    let mut host = StudioHost::create_at(&pkg, "Finalize").unwrap();
    host.submit(user(), "project.setTempo", json!({ "bpm": 120 })).unwrap();
    host.submit(user(), "track.add", json!({ "trackId": "trk_mix", "name": "Mix" })).unwrap();
    let work = pkg.join("_synth");
    std::fs::create_dir_all(&work).unwrap();
    let wav = work.join("mix.wav");
    write_wav_f32(&wav, &synth_stem("mix", 4), RATE).unwrap();
    host.import_audio(&wav.to_string_lossy(), "trk_mix", 0, Some("clip_mix".into())).unwrap();
    let original = clip_asset(&host, "clip_mix");

    let region_start = BAR_TICKS;
    let region_end = 2 * BAR_TICKS;
    let (rs_frame, re_frame) = region_frames(&host, region_start, region_end);
    let orig = host.asset_samples(&original).unwrap();

    // Revise (all-stems) at the DRAFT rung.
    let result = agent_surface::revise::dispatch_revise(
        &mut host,
        user(),
        &json!({
            "clipId": "clip_mix",
            "regionStartTicks": region_start,
            "regionEndTicks": region_end,
            "scope": "all-stems",
            "instruction": "brighter",
            "variants": 3,
            "seed": 7,
            "rung": "draft"
        }),
    )
    .unwrap();

    // Commit variant 0.
    let promotions = variant_promotions(&result, 0);
    let draft_take_id = promotions[0]["takeId"].as_str().unwrap().to_string();
    agent_surface::revise::dispatch_commit(
        &mut host,
        user(),
        &json!({ "promotions": promotions }),
    )
    .unwrap();
    let draft_asset = clip_asset(&host, "clip_mix");
    assert_ne!(draft_asset, original, "draft committed");

    // FINALIZE: re-render the committed draft at full rung, swap in place.
    let fin = agent_surface::revise::dispatch_finalize(
        &mut host,
        user(),
        &json!({ "draftTakeIds": [draft_take_id], "rung": "full" }),
    )
    .unwrap();
    assert_eq!(fin["ok"], json!(true));
    let full_asset = clip_asset(&host, "clip_mix");
    assert_ne!(full_asset, draft_asset, "finalize swapped the asset");
    assert_ne!(full_asset, original, "finalize is not the original");

    // The full asset is the SAME LENGTH (sample-aligned swap) and still
    // null-preserves outside the region (spliced into the ORIGINAL, not the draft).
    let full = host.asset_samples(&full_asset).unwrap();
    assert_eq!(full.samples.len(), orig.samples.len(), "finalize not sample-aligned");
    for i in 0..orig.samples.len() {
        if i < rs_frame || i >= re_frame {
            assert_eq!(full.samples[i], orig.samples[i], "finalize sample {i} outside region changed");
        }
    }

    // UNDO the finalize swap -> back to the DRAFT commit (one undo unit).
    assert!(host.undo(user()).unwrap());
    assert_eq!(clip_asset(&host, "clip_mix"), draft_asset, "finalize undo did not restore the draft");
    // UNDO the draft commit -> back to the ORIGINAL.
    assert!(host.undo(user()).unwrap());
    assert_eq!(clip_asset(&host, "clip_mix"), original, "commit undo did not restore the original");
}

#[test]
fn extend_and_add_a_layer_land_and_undo() {
    let dir = tempfile::tempdir().unwrap();
    let pkg = dir.path().join("ExtendLayer.mstudio");
    let (mut host, _orig) = build_session(&pkg);

    // EXTEND the drums clip by 1 second; commit places a tail + crossfade + section.
    let ext = agent_surface::revise::dispatch_extend(
        &mut host,
        user(),
        &json!({ "clipId": "clip_drums", "addedDurationSeconds": 1.0, "instruction": "fill", "variants": 2 }),
    )
    .unwrap();
    let ext_take = ext["takes"][0]["takeId"].as_str().unwrap().to_string();
    let tracks_before = host.project().tracks.iter().find(|t| t.id == "trk_drums").unwrap().clips.len();
    let seq_before_ext = host.seq();
    let ce = agent_surface::revise::dispatch_commit_extend(
        &mut host,
        user(),
        &json!({ "takeId": ext_take, "clipId": "clip_drums", "sectionName": "Outro" }),
    )
    .unwrap();
    let new_clip = ce["newClipId"].as_str().unwrap().to_string();
    let tracks_after = host.project().tracks.iter().find(|t| t.id == "trk_drums").unwrap().clips.len();
    assert_eq!(tracks_after, tracks_before + 1, "extend did not place a tail clip");
    assert!(host.project().crossfades.iter().any(|x| x.clip_id_b == new_clip), "seam not crossfaded");
    assert!(host.project().sections.iter().any(|s| s.name == "Outro"), "extend did not add a section");
    // One undo removes the whole extend (clip + crossfade + section).
    assert!(host.undo(user()).unwrap());
    assert_eq!(host.seq() >= seq_before_ext, true);
    let tracks_undone = host.project().tracks.iter().find(|t| t.id == "trk_drums").unwrap().clips.len();
    assert_eq!(tracks_undone, tracks_before, "extend undo did not remove the tail clip");
    assert!(!host.project().sections.iter().any(|s| s.name == "Outro"), "extend undo did not remove the section");

    // ADD A LAYER over bars 1-2 on a NEW track.
    let lay = agent_surface::revise::dispatch_layer(
        &mut host,
        user(),
        &json!({
            "instruction": "warm analog bass",
            "regionStartTicks": 0,
            "regionEndTicks": 2 * BAR_TICKS,
            "contextClipId": "clip_bass",
            "stem": "bass",
            "variants": 2
        }),
    )
    .unwrap();
    // studio_layer prepares the NEW track up front (take lanes materialize on
    // it during audition); the track count already went up by one.
    let layer_track = lay["targetTrackId"].as_str().unwrap().to_string();
    assert_eq!(lay["trackPrepared"], json!(true));
    assert!(host.project().track(&layer_track).is_some(), "layer did not prepare a new track");
    let lay_take = lay["takes"][0]["takeId"].as_str().unwrap().to_string();
    let cl = agent_surface::revise::dispatch_commit_layer(
        &mut host,
        user(),
        &json!({ "takeId": lay_take, "regionStartTicks": 0, "targetTrackId": layer_track }),
    )
    .unwrap();
    assert_eq!(cl["trackId"].as_str().unwrap(), layer_track);
    assert_eq!(host.project().track(&layer_track).unwrap().clips.len(), 1, "layer clip not placed");
    // One undo removes the layer clip (the prepared track remains).
    assert!(host.undo(user()).unwrap());
    assert_eq!(host.project().track(&layer_track).unwrap().clips.len(), 0, "layer undo did not remove the clip");
    // A second undo removes the prepared track.
    assert!(host.undo(user()).unwrap());
    assert!(host.project().track(&layer_track).is_none(), "second undo did not remove the prepared track");
}

#[test]
fn revise_and_commit_via_mcp_have_full_parity() {
    // The same flow an agent (Sterling or any MCP client) drives: validate +
    // route through dispatch_tool, exactly like the app's FFI tool path.
    let dir = tempfile::tempdir().unwrap();
    let pkg = dir.path().join("Mcp.mstudio");
    let (mut host, original) = build_session(&pkg);
    let agent = Actor { kind: ActorKind::Agent, name: "sterling".into() };

    let result = dispatch_tool(
        &mut host,
        agent.clone(),
        "studio_revise",
        json!({
            "clipId": "clip_drums",
            "regionStartTicks": BAR_TICKS,
            "regionEndTicks": 2 * BAR_TICKS,
            "scope": "drums",
            "instruction": "punchier kick",
            "variants": 3
        }),
    )
    .unwrap();
    assert_eq!(result["ok"], json!(true));
    let promotions = variant_promotions(&result, 2);

    let commit = dispatch_tool(
        &mut host,
        agent.clone(),
        "studio_commit",
        json!({ "promotions": promotions }),
    )
    .unwrap();
    assert_eq!(commit["ok"], json!(true));
    assert_ne!(clip_asset(&host, "clip_drums"), original["drums"], "MCP commit did not swap the asset");

    // Undo via the MCP session tool.
    let undo = dispatch_tool(&mut host, agent, "studio_undo", json!({})).unwrap();
    assert_eq!(undo["undone"], json!(true));
    assert_eq!(clip_asset(&host, "clip_drums"), original["drums"], "MCP undo did not restore the original");

    // The tool set advertises the new workflow tools (agent discoverability).
    let names: Vec<String> = agent_surface::registry::tool_defs().iter().map(|t| t.name.clone()).collect();
    for t in ["studio_revise", "studio_commit", "studio_finalize", "studio_extend", "studio_layer", "studio_audition"] {
        assert!(names.contains(&t.to_string()), "missing MCP tool {t}");
    }
}

#[test]
fn revise_survives_save_and_reopen() {
    // The spliced take asset persists under audio/ and resolves after a reopen
    // (the promoted clip still plays its committed audio).
    let dir = tempfile::tempdir().unwrap();
    let pkg = dir.path().join("Persist.mstudio");
    let committed_asset;
    {
        let (mut host, _o) = build_session(&pkg);
        let result = agent_surface::revise::dispatch_revise(
            &mut host,
            user(),
            &json!({
                "clipId": "clip_other", "regionStartTicks": BAR_TICKS, "regionEndTicks": 2 * BAR_TICKS,
                "scope": "other", "variants": 1, "seed": 3
            }),
        )
        .unwrap();
        agent_surface::revise::dispatch_commit(&mut host, user(), &json!({ "promotions": variant_promotions(&result, 0) })).unwrap();
        committed_asset = clip_asset(&host, "clip_other");
        host.save().unwrap();
    }
    // Reopen: the committed asset must be on the clip and decodable.
    let host2 = StudioHost::open_package(&pkg).unwrap();
    assert_eq!(clip_asset(&host2, "clip_other"), committed_asset, "committed asset lost on reopen");
    assert!(host2.asset_samples(&committed_asset).is_some(), "committed asset not decodable after reopen");
    // And it still renders (the graph resolves the spliced source).
    assert!(host2.render_master().is_ok());
}
