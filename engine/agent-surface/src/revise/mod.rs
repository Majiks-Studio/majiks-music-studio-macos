//! `revise`: the L9 killer feature, engine side.
//!
//! Select bars, describe a change, get variants, commit one. This module is the
//! orchestration + splice + commit/undo spine that drives it, for the app UI,
//! for MCP agents (Sterling and any other), and for the headless CLI, all
//! through the SAME timeline-core command bus, so provenance and undo are
//! identical whoever drives.
//!
//! The pipeline (01-DESIGN 3.2, grounded by P0-A):
//!   1. REVISE: for each scoped stem clip, generate N draft variants
//!      (turbo-8 rung) of the region, splice each into the ORIGINAL clip audio
//!      with an equal-power crossfade INSIDE the region (P0-A: raw repaint never
//!      appears outside the region), ingest the spliced result as a take asset,
//!      and journal gen.revise + gen.landed. Non-blocking: the app keeps editing
//!      while this runs.
//!   2. AUDITION: loop the region with 2 bars of pre-roll; the UI switches which
//!      take is audible (keys 1-9), A returns to the original, per-stem mixing is
//!      allowed. This surface returns the loop bounds; audibility is a live
//!      transport concern.
//!   3. COMMIT: promote the chosen variant's take(s) into the clip(s) as ONE
//!      undo transaction, with the crossfade already baked into the spliced
//!      asset (P0-A's fades-inside-the-region keep the outside bit-exact).
//!      DISCARD keeps the takes as candidates in the Takes history.
//!   4. FINALIZE (the draft/commit two-phase, 01-DESIGN 3.2 step 6): re-render
//!      the committed draft take at the COMMIT rung (base-50) in the background,
//!      reconstructing the region from journaled provenance (the finalize needs
//!      only the draft take id), then swap the clip's asset draft->full as one
//!      undoable transaction, sample-aligned because both assets are same-length
//!      substitutions of the original.
//!
//! STEM SCOPE (P0-A section 6): a scoped revise (e.g. "drums only") targets one
//! stem clip per scoped stem; the unscoped stems are NEVER touched
//! (null-preserved). Because the frozen catalog's gen.revise.scope is a single
//! enum, a multi-stem selection is journaled as one gen.revise per scoped stem
//! (each records its own scope), and the variants that share a seed come from
//! one conceptual repaint (P0-A: repaint the mix once, re-separate, splice the
//! scoped stems). A genuine single full-mix clip uses scope "all-stems".

pub mod generator;
pub mod splice;

use serde_json::{json, Map, Value};

use timeline_core::tempo::PPQ;
use timeline_core::Actor;

use crate::error::StudioError;
use crate::host::StudioHost;
use crate::ulid;

pub use generator::{GenOp, GenSpec, MockGenerator, QualityRung, RegionGenerator};
pub use splice::{crossfade_frames, splice_region, DEFAULT_CROSSFADE_MS, MIN_DECLICK_MS};

/// Default variant count (P0-A: seed dominates instruction, so 3 is right).
pub const DEFAULT_VARIANTS: u32 = 3;
/// Hard cap on variants (01-DESIGN 3.2: 1-8).
pub const MAX_VARIANTS: u32 = 8;
/// One 4/4 bar in ticks (fixed 4/4 in v1, matching landing + timeline-core).
pub const BAR_TICKS: u64 = 4 * PPQ;
/// Audition pre-roll (01-DESIGN 3.2 step 4: loop the region with 2 bars lead-in).
pub const AUDITION_PREROLL_BARS: u64 = 2;

/// The four suite stems, in canonical order.
pub const STEMS: [&str; 4] = ["vocals", "drums", "bass", "other"];

// ---------------------------------------------------------------------------
// Generator selection (mock is the deterministic default; live is documented).
// ---------------------------------------------------------------------------

/// Pick a generator. The deterministic fixture generator is the default, so the
/// whole flow is reproducible with no Gen Node. `engine: "live"` (or
/// "gen-node") asks for the real ACE-Step path, which forwards to L4's Gen
/// Protocol RPC; that path is honest about needing a configured node rather than
/// inventing a render.
fn select_generator(args: &Value) -> Result<Box<dyn RegionGenerator>, StudioError> {
    match args.get("engine").and_then(Value::as_str).unwrap_or("mock") {
        "mock" | "fixture" => Ok(Box::new(MockGenerator)),
        "live" | "gen-node" | "acestep" => Err(StudioError::Gen(
            "live generation needs a Gen Node (set MAJIKS_GEN_RPC_URL and use the gen proxy); \
             the deterministic fixture generator is the default engine for revise/extend/layer"
                .to_string(),
        )),
        other => Err(StudioError::invalid(format!(
            "unknown revise engine '{other}' (want mock|live)"
        ))),
    }
}

// ---------------------------------------------------------------------------
// Region math
// ---------------------------------------------------------------------------

/// Where a project-tick region lands inside one clip's source audio.
struct ClipRegion {
    track_id: String,
    source_id: String,
    region_start_frame: usize,
    region_frames: usize,
}

/// Resolve the overlap of a project-tick region with a clip, mapped to source
/// frames. `None` when the region does not cover the clip at all.
fn resolve_clip_region(
    host: &StudioHost,
    clip_id: &str,
    region_start_ticks: u64,
    region_end_ticks: u64,
) -> Option<ClipRegion> {
    let project = host.project();
    let (ti, ci) = project.find_clip(clip_id)?;
    let clip = &project.tracks[ti].clips[ci];
    let clip_start = clip.start_ticks;
    let clip_end = clip.end_ticks();
    let overlap_start = region_start_ticks.max(clip_start);
    let overlap_end = region_end_ticks.min(clip_end);
    if overlap_start >= overlap_end {
        return None;
    }
    let rate = project.sample_rate;
    let tempo = &project.tempo;
    let src_start_tick = clip.source_offset_ticks + (overlap_start - clip_start);
    let src_end_tick = clip.source_offset_ticks + (overlap_end - clip_start);
    let region_start_frame = tempo.tick_to_frame(src_start_tick, rate) as usize;
    let region_end_frame = tempo.tick_to_frame(src_end_tick, rate) as usize;
    if region_end_frame <= region_start_frame {
        return None;
    }
    Some(ClipRegion {
        track_id: project.tracks[ti].id.clone(),
        source_id: clip.source_id.clone(),
        region_start_frame,
        region_frames: region_end_frame - region_start_frame,
    })
}

/// Deterministic per-variant seed from a base seed. Shared across the stems of
/// one variant (P0-A: one repaint, re-separate the scoped stems).
fn variant_seed(base: u64, variant: u32) -> u64 {
    let mut x = base ^ ((variant as u64).wrapping_add(1)).wrapping_mul(0x9E37_79B9_7F4A_7C15);
    x = (x ^ (x >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    x = (x ^ (x >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    x ^ (x >> 31)
}

fn arg_u64(args: &Value, key: &str) -> Option<u64> {
    args.get(key).and_then(Value::as_u64)
}

fn arg_str(args: &Value, key: &str) -> Option<String> {
    args.get(key).and_then(Value::as_str).map(str::to_string)
}

/// Parse the scope: either "all-stems" (a single full-mix clip revise) or a set
/// of stem names selecting which stem clips to regenerate. Accepts a string or
/// an array of strings (the UI multi-select).
fn parse_scope(args: &Value) -> Result<Vec<String>, StudioError> {
    match args.get("scope") {
        Some(Value::String(s)) if s == "all-stems" => Ok(vec!["all-stems".to_string()]),
        Some(Value::String(s)) if STEMS.contains(&s.as_str()) => Ok(vec![s.clone()]),
        Some(Value::Array(a)) => {
            let mut out = Vec::new();
            for v in a {
                let s = v.as_str().ok_or_else(|| StudioError::invalid("scope entries must be strings"))?;
                if s == "all-stems" {
                    return Ok(vec!["all-stems".to_string()]);
                }
                if !STEMS.contains(&s) {
                    return Err(StudioError::invalid(format!("unknown scope stem '{s}'")));
                }
                if !out.contains(&s.to_string()) {
                    out.push(s.to_string());
                }
            }
            if out.is_empty() {
                return Err(StudioError::invalid("scope selects no stems"));
            }
            Ok(out)
        }
        _ => Err(StudioError::invalid(
            "scope is required: 'all-stems', a stem name, or an array of stem names",
        )),
    }
}

/// One revise target: a stem and the clip that carries it.
struct Target {
    stem: String,
    clip_id: String,
    request_id: String,
}

/// Map the scope + clip args to concrete targets. `clipIds` (array) pairs one
/// clip per scoped stem in order; a single `clipId` is used for an all-stems
/// revise (one full-mix clip) or a single-stem scope.
fn resolve_targets(host: &StudioHost, args: &Value, scope: &[String]) -> Result<Vec<Target>, StudioError> {
    let clip_ids: Vec<String> = if let Some(arr) = args.get("clipIds").and_then(Value::as_array) {
        arr.iter().filter_map(|v| v.as_str().map(str::to_string)).collect()
    } else if let Some(one) = arg_str(args, "clipId") {
        vec![one]
    } else {
        return Err(StudioError::invalid("clipId or clipIds is required"));
    };

    if scope == ["all-stems"] {
        let clip_id = clip_ids
            .first()
            .cloned()
            .ok_or_else(|| StudioError::invalid("all-stems revise needs a clipId"))?;
        if !host.project().clip_id_exists(&clip_id) {
            return Err(StudioError::invalid(format!("unknown clip: {clip_id}")));
        }
        return Ok(vec![Target { stem: "mix".to_string(), clip_id, request_id: ulid::new_ulid() }]);
    }

    // Stem scope: one clip per scoped stem. Either clipIds lines up 1:1 with the
    // scope, or a single clipId is reused (a single-stem scope).
    if clip_ids.len() == scope.len() {
        let mut out = Vec::new();
        for (stem, clip_id) in scope.iter().zip(clip_ids.iter()) {
            if !host.project().clip_id_exists(clip_id) {
                return Err(StudioError::invalid(format!("unknown clip: {clip_id}")));
            }
            out.push(Target { stem: stem.clone(), clip_id: clip_id.clone(), request_id: ulid::new_ulid() });
        }
        Ok(out)
    } else if clip_ids.len() == 1 && scope.len() == 1 {
        let clip_id = clip_ids[0].clone();
        if !host.project().clip_id_exists(&clip_id) {
            return Err(StudioError::invalid(format!("unknown clip: {clip_id}")));
        }
        Ok(vec![Target { stem: scope[0].clone(), clip_id, request_id: ulid::new_ulid() }])
    } else {
        Err(StudioError::invalid(format!(
            "clipIds ({}) must pair one clip per scoped stem ({})",
            clip_ids.len(),
            scope.len()
        )))
    }
}

// ---------------------------------------------------------------------------
// REVISE (draft variants -> take lanes)
// ---------------------------------------------------------------------------

/// `studio_revise`: generate N draft variants of a region for each scoped stem,
/// splice each into the original clip audio, and land them as candidate takes.
/// Returns the per-variant promotions the caller commits with `studio_commit`.
pub fn dispatch_revise(host: &mut StudioHost, actor: Actor, args: &Value) -> Result<Value, StudioError> {
    let generator = select_generator(args)?;
    let region_start = arg_u64(args, "regionStartTicks")
        .ok_or_else(|| StudioError::invalid("regionStartTicks is required"))?;
    let region_end = arg_u64(args, "regionEndTicks")
        .ok_or_else(|| StudioError::invalid("regionEndTicks is required"))?;
    if region_start >= region_end {
        return Err(StudioError::invalid("regionStartTicks must be before regionEndTicks"));
    }
    let scope = parse_scope(args)?;
    let targets = resolve_targets(host, args, &scope)?;
    let variants = arg_u64(args, "variants")
        .map(|v| v as u32)
        .unwrap_or(DEFAULT_VARIANTS)
        .clamp(1, MAX_VARIANTS);
    let instruction = arg_str(args, "instruction").filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| "revise region".to_string());
    let keep_lyrics = args.get("keepLyrics").and_then(Value::as_bool).unwrap_or(true);
    let crossfade_ms = args.get("crossfadeMs").and_then(Value::as_f64).unwrap_or(DEFAULT_CROSSFADE_MS);
    let base_seed = arg_u64(args, "seed").unwrap_or_else(|| region_start ^ (region_end << 1) ^ 0x5EED);
    // Audition renders at the DRAFT rung (turbo-8); commit finalizes at full.
    let rung = args
        .get("rung")
        .and_then(Value::as_str)
        .map(QualityRung::from_wire)
        .unwrap_or(QualityRung::Draft);

    let family = ulid::new_ulid();
    let mut target_json = Vec::new();
    // variant index -> promotions [{takeId, clipId, stem}]
    let mut variant_promotions: Vec<Vec<Value>> = vec![Vec::new(); variants as usize];

    for target in &targets {
        let region = resolve_clip_region(host, &target.clip_id, region_start, region_end)
            .ok_or_else(|| StudioError::invalid(format!(
                "region [{region_start}, {region_end}) does not cover clip {}",
                target.clip_id
            )))?;
        let xfade = crossfade_frames(crossfade_ms, region.region_frames);
        let original = host
            .asset_samples(&region.source_id)
            .ok_or_else(|| StudioError::audio(format!("clip {} asset not loaded", target.clip_id)))?;

        // One gen.revise request record per target (journaled provenance; the
        // finalize reconstructs region + clip + scope + crossfade from it).
        let scope_wire = if target.stem == "mix" { "all-stems".to_string() } else { target.stem.clone() };
        host.submit(
            actor.clone(),
            "gen.revise",
            json!({
                "requestId": target.request_id,
                "clipId": target.clip_id,
                "regionStartTicks": region_start,
                "regionEndTicks": region_end,
                "scope": scope_wire,
                "request": {
                    "instruction": instruction,
                    "variants": variants,
                    "keepLyrics": keep_lyrics,
                    "crossfadeMs": crossfade_ms,
                    "baseSeed": base_seed,
                    "family": family,
                    "rung": rung.wire(),
                },
            }),
        )?;

        let context = original.samples[region.region_start_frame
            ..(region.region_start_frame + region.region_frames).min(original.samples.len())]
            .to_vec();

        for v in 0..variants {
            let seed = variant_seed(base_seed, v);
            let spec = GenSpec {
                op: GenOp::Revise,
                stem: target.stem.clone(),
                region_frames: region.region_frames,
                seed,
                rung,
                instruction: instruction.clone(),
                context: context.clone(),
            };
            let replacement = generator.generate(&spec)?;
            let spliced = splice_region(&original.samples, &replacement, region.region_start_frame, xfade);
            let asset_hash = host.ingest_asset(&spliced)?;
            let take_id = ulid::new_ulid();
            land_take(
                host,
                actor.clone(),
                &target.request_id,
                "gen.revise",
                &take_id,
                &target.stem,
                &asset_hash,
                generator.as_ref(),
                rung,
                seed,
            )?;
            variant_promotions[v as usize].push(json!({
                "takeId": take_id,
                "clipId": target.clip_id,
                "stem": target.stem,
            }));
        }

        target_json.push(json!({
            "stem": target.stem,
            "clipId": target.clip_id,
            "trackId": region.track_id,
            "requestId": target.request_id,
            "regionStartFrame": region.region_start_frame,
            "regionFrames": region.region_frames,
            "crossfadeFrames": xfade,
        }));
    }

    let variant_takes: Vec<Value> = variant_promotions
        .into_iter()
        .enumerate()
        .map(|(v, promotions)| {
            json!({
                "variant": v,
                "seed": variant_seed(base_seed, v as u32),
                "promotions": promotions,
            })
        })
        .collect();

    Ok(json!({
        "ok": true,
        "op": "revise",
        "family": family,
        "engine": generator.label(),
        "regionStartTicks": region_start,
        "regionEndTicks": region_end,
        "scope": scope,
        "variants": variants,
        "rung": rung.wire(),
        "crossfadeMs": crossfade_ms,
        "instruction": instruction,
        "keepLyrics": keep_lyrics,
        "targets": target_json,
        "variantTakes": variant_takes,
        "audition": audition_bounds(host, region_start, region_end),
        "seq": host.seq(),
    }))
}

/// Journal a `gen.landed` for a spliced take asset. `stem` keys the asset map
/// (single-asset take: take.promote swaps the clip to this asset).
#[allow(clippy::too_many_arguments)]
fn land_take(
    host: &mut StudioHost,
    actor: Actor,
    request_id: &str,
    source_command: &str,
    take_id: &str,
    stem: &str,
    asset_hash: &str,
    generator: &dyn RegionGenerator,
    rung: QualityRung,
    seed: u64,
) -> Result<(), StudioError> {
    let mut asset_hashes = Map::new();
    asset_hashes.insert(stem.to_string(), json!(asset_hash));
    host.submit(
        actor,
        "gen.landed",
        json!({
            "requestId": request_id,
            "sourceCommand": source_command,
            "takeId": take_id,
            "assetHashes": Value::Object(asset_hashes),
            "engineIdentity": {
                "model": generator.model_name(rung),
                "steps": rung.steps(),
                "seed": seed as i64,
                "device": generator.device(),
            },
        }),
    )?;
    Ok(())
}

/// The audition loop: the region with `AUDITION_PREROLL_BARS` of pre-roll.
fn audition_bounds(_host: &StudioHost, region_start: u64, region_end: u64) -> Value {
    let pre = AUDITION_PREROLL_BARS * BAR_TICKS;
    json!({
        "loopStartTicks": region_start.saturating_sub(pre),
        "loopEndTicks": region_end,
        "regionStartTicks": region_start,
        "regionEndTicks": region_end,
        "preRollBars": AUDITION_PREROLL_BARS,
    })
}

// ---------------------------------------------------------------------------
// AUDITION (loop bounds; audibility is a live-transport concern)
// ---------------------------------------------------------------------------

/// `studio_audition`: the loop region (with pre-roll) for auditioning a revise.
/// Switching which take is audible (keys 1-9, A for original, per-stem mixing)
/// is a live-transport concern the app drives; this returns the loop to set.
pub fn dispatch_audition(host: &StudioHost, args: &Value) -> Result<Value, StudioError> {
    let region_start = arg_u64(args, "regionStartTicks")
        .ok_or_else(|| StudioError::invalid("regionStartTicks is required"))?;
    let region_end = arg_u64(args, "regionEndTicks")
        .ok_or_else(|| StudioError::invalid("regionEndTicks is required"))?;
    if region_start >= region_end {
        return Err(StudioError::invalid("regionStartTicks must be before regionEndTicks"));
    }
    Ok(json!({ "ok": true, "audition": audition_bounds(host, region_start, region_end) }))
}

// ---------------------------------------------------------------------------
// COMMIT (promote a variant's takes as ONE undo transaction)
// ---------------------------------------------------------------------------

/// Parse `promotions: [{takeId, clipId}]`, validating each take is a live
/// candidate and each clip exists BEFORE any mutation, so the commit txn never
/// half-applies.
fn parse_promotions(host: &StudioHost, args: &Value) -> Result<Vec<(String, String)>, StudioError> {
    let arr = args
        .get("promotions")
        .and_then(Value::as_array)
        .ok_or_else(|| StudioError::invalid("promotions array is required"))?;
    if arr.is_empty() {
        return Err(StudioError::invalid("promotions is empty"));
    }
    let mut out = Vec::new();
    for p in arr {
        let take_id = p.get("takeId").and_then(Value::as_str)
            .ok_or_else(|| StudioError::invalid("promotion needs takeId"))?;
        let clip_id = p.get("clipId").and_then(Value::as_str)
            .ok_or_else(|| StudioError::invalid("promotion needs clipId"))?;
        let take = host.project().take(take_id)
            .ok_or_else(|| StudioError::invalid(format!("unknown take {take_id}")))?;
        if take.status == timeline_core::model::TakeStatus::Promoted {
            return Err(StudioError::invalid(format!("take {take_id} is already promoted")));
        }
        if !host.project().clip_id_exists(clip_id) {
            return Err(StudioError::invalid(format!("unknown clip {clip_id}")));
        }
        out.push((take_id.to_string(), clip_id.to_string()));
    }
    Ok(out)
}

/// `studio_commit`: promote the chosen variant's take(s) into their clip(s) as
/// ONE undo transaction (the crossfade is already baked into each spliced asset).
pub fn dispatch_commit(host: &mut StudioHost, actor: Actor, args: &Value) -> Result<Value, StudioError> {
    let promotions = parse_promotions(host, args)?;
    let reason = arg_str(args, "reason").unwrap_or_else(|| "commit revise".to_string());
    let txn_id = ulid::new_ulid();
    host.submit(actor.clone(), "txn.begin", json!({ "txnId": txn_id, "reason": reason }))?;
    let mut promoted = Vec::new();
    for (take_id, clip_id) in &promotions {
        host.submit(
            actor.clone(),
            "take.promote",
            json!({ "takeId": take_id, "targetClipId": clip_id }),
        )?;
        promoted.push(json!({ "takeId": take_id, "clipId": clip_id }));
    }
    host.submit(actor, "txn.commit", json!({ "txnId": txn_id }))?;
    Ok(json!({
        "ok": true,
        "committed": promoted,
        "undo": "one step",
        "seq": host.seq(),
    }))
}

/// `studio_discard`: keep the takes as candidates in the Takes history (v1
/// discard of an un-committed audition is a no-op on the journal; the candidate
/// takes already exist from gen.landed, and purging them is L10's Takes browser).
pub fn dispatch_discard(host: &StudioHost, args: &Value) -> Result<Value, StudioError> {
    let ids: Vec<String> = args
        .get("takeIds")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
        .unwrap_or_default();
    let kept: Vec<&String> = ids.iter().filter(|id| host.project().take(id).is_some()).collect();
    Ok(json!({
        "ok": true,
        "kept": kept,
        "note": "takes remain as candidates in the Takes history; nothing was committed",
    }))
}

// ---------------------------------------------------------------------------
// FINALIZE (draft -> full-quality re-render + sample-aligned swap, undoable)
// ---------------------------------------------------------------------------

/// `studio_finalize`: re-render committed draft take(s) at the target rung
/// (default full/base-50) and swap each clip's asset draft->full as ONE undo
/// transaction. Reconstructs region + clip + crossfade from journaled
/// provenance, so it needs only the draft take ids. The two assets are
/// same-length substitutions of the original, so the swap is sample-aligned.
pub fn dispatch_finalize(host: &mut StudioHost, actor: Actor, args: &Value) -> Result<Value, StudioError> {
    let generator = select_generator(args)?;
    let draft_ids: Vec<String> = args
        .get("draftTakeIds")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
        .ok_or_else(|| StudioError::invalid("draftTakeIds array is required"))?;
    if draft_ids.is_empty() {
        return Err(StudioError::invalid("draftTakeIds is empty"));
    }
    let rung = QualityRung::from_wire(args.get("rung").and_then(Value::as_str).unwrap_or("full"));

    // Resolve every finalize plan up front (fail before any mutation).
    struct Plan {
        draft_take_id: String,
        clip_id: String,
        stem: String,
        spliced: Vec<[f32; 2]>,
        seed: u64,
        finalize_request_id: String,
    }
    let mut plans = Vec::new();
    for draft_take_id in &draft_ids {
        let take = host.project().take(draft_take_id)
            .ok_or_else(|| StudioError::invalid(format!("unknown draft take {draft_take_id}")))?
            .clone();
        if take.status != timeline_core::model::TakeStatus::Promoted {
            return Err(StudioError::invalid(format!(
                "draft take {draft_take_id} is not committed; finalize follows a commit"
            )));
        }
        let clip_id = take.promoted_into.clone()
            .ok_or_else(|| StudioError::invalid("draft take has no clip"))?;
        let prior = take.prior_asset.clone()
            .ok_or_else(|| StudioError::invalid("draft take has no original asset to splice into"))?;
        let stem = take.asset_hashes.keys().next().cloned().unwrap_or_else(|| "mix".to_string());
        let seed = take.engine_identity.get("seed").and_then(Value::as_i64).unwrap_or(0) as u64;
        let req = host.gen_request_params(&take.request_id)
            .ok_or_else(|| StudioError::invalid("draft take's gen.revise request not found in journal"))?;
        let region_start = req.get("regionStartTicks").and_then(Value::as_u64).unwrap_or(0);
        let region_end = req.get("regionEndTicks").and_then(Value::as_u64).unwrap_or(0);
        let request_obj = req.get("request").cloned().unwrap_or_else(|| json!({}));
        let instruction = request_obj.get("instruction").and_then(Value::as_str).unwrap_or("revise region").to_string();
        let crossfade_ms = request_obj.get("crossfadeMs").and_then(Value::as_f64).unwrap_or(DEFAULT_CROSSFADE_MS);
        let region = resolve_clip_region(host, &clip_id, region_start, region_end)
            .ok_or_else(|| StudioError::invalid("finalize region no longer covers the clip"))?;
        let original = host.asset_samples(&prior)
            .ok_or_else(|| StudioError::audio("original (pre-draft) asset not loaded for finalize"))?;
        let context = original.samples[region.region_start_frame
            ..(region.region_start_frame + region.region_frames).min(original.samples.len())]
            .to_vec();
        let spec = GenSpec {
            op: GenOp::Revise,
            stem: stem.clone(),
            region_frames: region.region_frames,
            seed,
            rung,
            instruction,
            context,
        };
        let replacement = generator.generate(&spec)?;
        let xfade = crossfade_frames(crossfade_ms, region.region_frames);
        let spliced = splice_region(&original.samples, &replacement, region.region_start_frame, xfade);
        plans.push(Plan {
            draft_take_id: draft_take_id.clone(),
            clip_id,
            stem,
            spliced,
            seed,
            finalize_request_id: ulid::new_ulid(),
        });
    }

    // Land the finalized (full-rung) takes as candidates.
    let mut final_take_ids = Vec::new();
    for plan in &plans {
        let asset = host.ingest_asset(&plan.spliced)?;
        // Journal the finalize request (draft/commit re-render provenance).
        host.submit(
            actor.clone(),
            "gen.finalize",
            json!({
                "requestId": plan.finalize_request_id,
                "draftTakeId": plan.draft_take_id,
                "targetQualityRung": rung.wire(),
                "request": { "instruction": "finalize", "rung": rung.wire() },
            }),
        )?;
        let final_take_id = ulid::new_ulid();
        land_take(
            host,
            actor.clone(),
            &plan.finalize_request_id,
            "gen.finalize",
            &final_take_id,
            &plan.stem,
            &asset,
            generator.as_ref(),
            rung,
            plan.seed,
        )?;
        final_take_ids.push(final_take_id);
    }

    // Swap draft -> full as ONE undo transaction: un-splice the draft (clip back
    // to original), splice in the full take. Undo restores the draft commit.
    let txn_id = ulid::new_ulid();
    host.submit(actor.clone(), "txn.begin", json!({ "txnId": txn_id, "reason": "finalize swap" }))?;
    let mut swaps = Vec::new();
    for (plan, final_take_id) in plans.iter().zip(final_take_ids.iter()) {
        host.submit(actor.clone(), "take.discard", json!({ "takeId": plan.draft_take_id }))?;
        host.submit(
            actor.clone(),
            "take.promote",
            json!({ "takeId": final_take_id, "targetClipId": plan.clip_id }),
        )?;
        swaps.push(json!({
            "draftTakeId": plan.draft_take_id,
            "finalTakeId": final_take_id,
            "clipId": plan.clip_id,
        }));
    }
    host.submit(actor, "txn.commit", json!({ "txnId": txn_id }))?;

    Ok(json!({
        "ok": true,
        "rung": rung.wire(),
        "swaps": swaps,
        "undo": "one step (restores the draft commit)",
        "seq": host.seq(),
    }))
}

// ---------------------------------------------------------------------------
// EXTEND (01-DESIGN 3.3): a new tail clip crossfaded at the seam + a section
// ---------------------------------------------------------------------------

/// `studio_extend`: generate variant tails past a clip's end. Lands as candidate
/// takes; `studio_commit_extend` places the chosen tail as a new clip crossfaded
/// at the seam plus a section, as one undo transaction.
pub fn dispatch_extend(host: &mut StudioHost, actor: Actor, args: &Value) -> Result<Value, StudioError> {
    let generator = select_generator(args)?;
    let clip_id = arg_str(args, "clipId").ok_or_else(|| StudioError::invalid("clipId is required"))?;
    let added_seconds = args.get("addedDurationSeconds").and_then(Value::as_f64)
        .ok_or_else(|| StudioError::invalid("addedDurationSeconds is required"))?;
    if added_seconds <= 0.0 {
        return Err(StudioError::invalid("addedDurationSeconds must be > 0"));
    }
    let variants = arg_u64(args, "variants").map(|v| v as u32).unwrap_or(1).clamp(1, MAX_VARIANTS);
    let instruction = arg_str(args, "instruction").filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| "extend".to_string());
    let base_seed = arg_u64(args, "seed").unwrap_or(0xE47E4D);
    let crossfade_ms = args.get("crossfadeMs").and_then(Value::as_f64).unwrap_or(DEFAULT_CROSSFADE_MS);

    let (track_id, clip_end_ticks, source_id) = {
        let project = host.project();
        let (ti, ci) = project.find_clip(&clip_id)
            .ok_or_else(|| StudioError::invalid(format!("unknown clip {clip_id}")))?;
        let clip = &project.tracks[ti].clips[ci];
        (project.tracks[ti].id.clone(), clip.end_ticks(), clip.source_id.clone())
    };
    let rate = host.project().sample_rate;
    let added_frames = (added_seconds * rate as f64).round() as usize;
    if added_frames == 0 {
        return Err(StudioError::invalid("addedDurationSeconds too small to produce audio"));
    }
    // Tail context = the end of the clip's source (for the seam continuity).
    let ctx = host.asset_samples(&source_id).map(|a| {
        let n = a.samples.len();
        let start = n.saturating_sub(added_frames.min(n));
        a.samples[start..].to_vec()
    }).unwrap_or_default();

    let request_id = ulid::new_ulid();
    host.submit(actor.clone(), "gen.extend", json!({
        "requestId": request_id,
        "clipId": clip_id,
        "addedDurationSeconds": added_seconds,
        "request": { "instruction": instruction, "variants": variants, "crossfadeMs": crossfade_ms },
    }))?;

    let mut takes = Vec::new();
    for v in 0..variants {
        let seed = variant_seed(base_seed, v);
        let spec = GenSpec {
            op: GenOp::Extend,
            stem: "mix".to_string(),
            region_frames: added_frames,
            seed,
            rung: QualityRung::Draft,
            instruction: instruction.clone(),
            context: ctx.clone(),
        };
        let tail = generator.generate(&spec)?;
        let asset = host.ingest_asset(&tail)?;
        let take_id = ulid::new_ulid();
        land_take(host, actor.clone(), &request_id, "gen.extend", &take_id, "mix", &asset,
            generator.as_ref(), QualityRung::Draft, seed)?;
        takes.push(json!({ "takeId": take_id, "seed": seed as i64, "assetHash": asset }));
    }

    Ok(json!({
        "ok": true,
        "op": "extend",
        "engine": generator.label(),
        "clipId": clip_id,
        "trackId": track_id,
        "seamTicks": clip_end_ticks,
        "addedDurationSeconds": added_seconds,
        "variants": variants,
        "takes": takes,
        "seq": host.seq(),
    }))
}

/// `studio_commit_extend`: place the chosen tail take as a new clip butt-joined
/// at the seam, crossfade the seam, and add a section, as one undo transaction.
pub fn dispatch_commit_extend(host: &mut StudioHost, actor: Actor, args: &Value) -> Result<Value, StudioError> {
    let take_id = arg_str(args, "takeId").ok_or_else(|| StudioError::invalid("takeId is required"))?;
    let anchor_clip = arg_str(args, "clipId").ok_or_else(|| StudioError::invalid("clipId (the extended clip) is required"))?;
    let crossfade_ms = args.get("crossfadeMs").and_then(Value::as_f64).unwrap_or(DEFAULT_CROSSFADE_MS);
    let section_name = arg_str(args, "sectionName").unwrap_or_else(|| "Extension".to_string());

    let take = host.project().take(&take_id)
        .ok_or_else(|| StudioError::invalid(format!("unknown take {take_id}")))?
        .clone();
    let asset = take.asset_hashes.values().next().cloned()
        .ok_or_else(|| StudioError::invalid("take has no asset"))?;
    let tail_frames = host.asset_samples(&asset).map(|a| a.samples.len()).unwrap_or(0);
    if tail_frames == 0 {
        return Err(StudioError::audio("tail asset not loaded"));
    }
    let (track_id, seam_ticks) = {
        let project = host.project();
        let (ti, ci) = project.find_clip(&anchor_clip)
            .ok_or_else(|| StudioError::invalid(format!("unknown clip {anchor_clip}")))?;
        (project.tracks[ti].id.clone(), project.tracks[ti].clips[ci].end_ticks())
    };
    let rate = host.project().sample_rate;
    let tempo = host.project().tempo.clone();
    let tail_len_ticks = tempo.frame_to_tick(tail_frames as u64, rate).max(1);
    let xfade_frames = crossfade_frames(crossfade_ms, tail_frames.min(tail_len_ticks as usize).max(1));
    let xfade_ticks = tempo.frame_to_tick(xfade_frames as u64, rate).max(1);
    let new_clip = format!("clip_{}", ulid::new_ulid());

    let txn_id = ulid::new_ulid();
    host.submit(actor.clone(), "txn.begin", json!({ "txnId": txn_id, "reason": "commit extend" }))?;
    host.submit(actor.clone(), "clip.place", json!({
        "clipId": new_clip,
        "trackId": track_id,
        "assetHash": asset,
        "startTicks": seam_ticks,
        "lengthTicks": tail_len_ticks,
    }))?;
    host.submit(actor.clone(), "clip.crossfade.set", json!({
        "clipIdA": anchor_clip,
        "clipIdB": new_clip,
        "lengthTicks": xfade_ticks,
        "shape": "equalPower",
    }))?;
    host.submit(actor.clone(), "section.set", json!({
        "sectionId": format!("sec_ext_{}", &new_clip[5..13.min(new_clip.len())]),
        "name": section_name,
        "startTicks": seam_ticks,
    }))?;
    host.submit(actor, "txn.commit", json!({ "txnId": txn_id }))?;

    Ok(json!({
        "ok": true,
        "op": "commit_extend",
        "newClipId": new_clip,
        "trackId": track_id,
        "seamTicks": seam_ticks,
        "crossfadeTicks": xfade_ticks,
        "undo": "one step",
        "seq": host.seq(),
    }))
}

// ---------------------------------------------------------------------------
// ADD A LAYER (01-DESIGN 3.3b, lego): a NEW track that fits the context region
// ---------------------------------------------------------------------------

/// `studio_layer`: generate a new instrument layer that fits a context region.
/// Lands as candidate takes; `studio_commit_layer` creates a NEW track and
/// places the chosen layer clip on it, as one undo transaction.
pub fn dispatch_layer(host: &mut StudioHost, actor: Actor, args: &Value) -> Result<Value, StudioError> {
    let generator = select_generator(args)?;
    let instruction = arg_str(args, "instruction").filter(|s| !s.trim().is_empty())
        .ok_or_else(|| StudioError::invalid("instruction is required (e.g. 'warm analog bass')"))?;
    let region_start = arg_u64(args, "regionStartTicks")
        .ok_or_else(|| StudioError::invalid("regionStartTicks is required"))?;
    let region_end = arg_u64(args, "regionEndTicks")
        .ok_or_else(|| StudioError::invalid("regionEndTicks is required"))?;
    if region_start >= region_end {
        return Err(StudioError::invalid("regionStartTicks must be before regionEndTicks"));
    }
    let variants = arg_u64(args, "variants").map(|v| v as u32).unwrap_or(1).clamp(1, MAX_VARIANTS);
    let base_seed = arg_u64(args, "seed").unwrap_or(0x1E60);
    let stem = arg_str(args, "stem").unwrap_or_else(|| "other".to_string());
    // Context region audio (the layer fits it); optional context clip.
    let ctx = arg_str(args, "contextClipId")
        .and_then(|c| resolve_clip_region(host, &c, region_start, region_end).map(|r| (c, r)))
        .and_then(|(c, r)| {
            host.project().clip(&c).and_then(|cl| host.asset_samples(&cl.source_id)).map(|a| {
                let end = (r.region_start_frame + r.region_frames).min(a.samples.len());
                a.samples[r.region_start_frame.min(a.samples.len())..end].to_vec()
            })
        })
        .unwrap_or_default();
    let rate = host.project().sample_rate;
    let tempo = host.project().tempo.clone();
    let region_frames = (tempo.tick_to_frame(region_end, rate) - tempo.tick_to_frame(region_start, rate)) as usize;
    if region_frames == 0 {
        return Err(StudioError::invalid("region is too short to produce a layer"));
    }

    let target_track_id = arg_str(args, "targetTrackId")
        .unwrap_or_else(|| format!("trk_layer_{}", &ulid::new_ulid()[..10]));
    let track_name = arg_str(args, "trackName").unwrap_or_else(|| "Layer".to_string());
    let color = arg_str(args, "color").unwrap_or_else(|| crate::landing::stem_color(&stem).to_string());

    // gen.layer requires its target track to exist, and 01-DESIGN 3.3b says the
    // layer "lands as a NEW track with take lanes": so the new track is created
    // up front (as one undo unit), the take lanes materialize under it during
    // audition, and commit places the chosen take's clip on it. `track_exists`
    // lets a caller re-run studio_layer against the same prepared track.
    let track_exists = host.project().track(&target_track_id).is_some();
    if !track_exists {
        let prep_txn = ulid::new_ulid();
        // The reason is a CONSTANT because the snapshot reads it back to tell
        // the user this track exists because they asked for a layer
        // (`StudioHost::track_origins`). Two copies of a magic string is how
        // that quietly stops being true — the same lesson `PERFORMANCE_ACTOR`
        // records one file over.
        host.submit(actor.clone(), "txn.begin",
            json!({ "txnId": prep_txn, "reason": crate::host::LAYER_TXN_REASON }))?;
        host.submit(actor.clone(), "track.add", json!({ "trackId": target_track_id, "name": track_name }))?;
        host.submit(actor.clone(), "track.setColor", json!({ "trackId": target_track_id, "color": color }))?;
        host.submit(actor.clone(), "txn.commit", json!({ "txnId": prep_txn }))?;
    }

    let request_id = ulid::new_ulid();
    host.submit(actor.clone(), "gen.layer", json!({
        "requestId": request_id,
        "targetTrackId": target_track_id,
        "instruction": instruction,
        "request": { "instruction": instruction, "variants": variants, "stem": stem },
    }))?;

    let mut takes = Vec::new();
    for v in 0..variants {
        let seed = variant_seed(base_seed, v);
        let spec = GenSpec {
            op: GenOp::Layer,
            stem: stem.clone(),
            region_frames,
            seed,
            rung: QualityRung::Draft,
            instruction: instruction.clone(),
            context: ctx.clone(),
        };
        let layer = generator.generate(&spec)?;
        let asset = host.ingest_asset(&layer)?;
        let take_id = ulid::new_ulid();
        land_take(host, actor.clone(), &request_id, "gen.layer", &take_id, &stem, &asset,
            generator.as_ref(), QualityRung::Draft, seed)?;
        takes.push(json!({ "takeId": take_id, "seed": seed as i64, "assetHash": asset }));
    }

    Ok(json!({
        "ok": true,
        "op": "layer",
        "engine": generator.label(),
        "targetTrackId": target_track_id,
        "trackName": track_name,
        "trackPrepared": !track_exists,
        "instruction": instruction,
        "stem": stem,
        "regionStartTicks": region_start,
        "regionEndTicks": region_end,
        "variants": variants,
        "takes": takes,
        "seq": host.seq(),
    }))
}

/// `studio_commit_layer`: place the chosen layer take's clip on its prepared new
/// track (created by studio_layer) at the region, as one undo transaction. Undo
/// removes the layer clip; a second undo removes the prepared track.
pub fn dispatch_commit_layer(host: &mut StudioHost, actor: Actor, args: &Value) -> Result<Value, StudioError> {
    let take_id = arg_str(args, "takeId").ok_or_else(|| StudioError::invalid("takeId is required"))?;
    let region_start = arg_u64(args, "regionStartTicks")
        .ok_or_else(|| StudioError::invalid("regionStartTicks is required"))?;
    let target_track_id = arg_str(args, "targetTrackId")
        .ok_or_else(|| StudioError::invalid("targetTrackId is required (the track studio_layer prepared)"))?;
    if host.project().track(&target_track_id).is_none() {
        return Err(StudioError::invalid(format!("unknown layer track {target_track_id}; run studio_layer first")));
    }

    let take = host.project().take(&take_id)
        .ok_or_else(|| StudioError::invalid(format!("unknown take {take_id}")))?
        .clone();
    let asset = take.asset_hashes.values().next().cloned()
        .ok_or_else(|| StudioError::invalid("take has no asset"))?;
    let frames = host.asset_samples(&asset).map(|a| a.samples.len()).unwrap_or(0);
    if frames == 0 {
        return Err(StudioError::audio("layer asset not loaded"));
    }
    let rate = host.project().sample_rate;
    let tempo = host.project().tempo.clone();
    let len_ticks = tempo.frame_to_tick(frames as u64, rate).max(1);
    let new_clip = format!("clip_{}", ulid::new_ulid());

    let txn_id = ulid::new_ulid();
    host.submit(actor.clone(), "txn.begin", json!({ "txnId": txn_id, "reason": "commit add-a-layer" }))?;
    host.submit(actor.clone(), "clip.place", json!({
        "clipId": new_clip,
        "trackId": target_track_id,
        "assetHash": asset,
        "startTicks": region_start,
        "lengthTicks": len_ticks,
    }))?;
    host.submit(actor, "txn.commit", json!({ "txnId": txn_id }))?;

    Ok(json!({
        "ok": true,
        "op": "commit_layer",
        "trackId": target_track_id,
        "newClipId": new_clip,
        "undo": "one step (a second undo removes the prepared track)",
        "seq": host.seq(),
    }))
}
