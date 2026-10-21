//! Tool dispatch: the single place every MCP tool call (and the FFI tool path)
//! is validated, tier-gated, and routed to the host. The order mirrors the DJ
//! server: validate args against the tool schema, enforce the Manage confirm
//! gate, then route by tool kind. Rate limiting is applied by the MCP layer
//! before this (it is transport policy, not host logic).

use serde_json::{json, Value};

use timeline_core::Actor;

use crate::error::StudioError;
use crate::host::{StudioHost, WAVEFORM_MAX_BINS};
use crate::registry::{tool_by_name, ToolDef, ToolKind};

/// Validate + route a tool call by name.
pub fn dispatch_tool(
    host: &mut StudioHost,
    actor: Actor,
    tool_name: &str,
    args: Value,
) -> Result<Value, StudioError> {
    let def = tool_by_name(tool_name)
        .ok_or_else(|| StudioError::invalid(format!("unknown tool: {tool_name}")))?;
    dispatch_def(host, actor, &def, args)
}

/// Validate args against the tool's own inputSchema (drift-proof: the schema
/// is the catalog's for command tools), then route.
pub fn dispatch_def(
    host: &mut StudioHost,
    actor: Actor,
    def: &ToolDef,
    args: Value,
) -> Result<Value, StudioError> {
    let errors = timeline_core::schema::validate(&def.input_schema, &args);
    if !errors.is_empty() {
        return Err(StudioError::InvalidArgument(format!(
            "{}: {}",
            def.name,
            errors.join("; ")
        )));
    }

    match def.kind {
        ToolKind::Command => {
            let catalog = def
                .catalog_name
                .clone()
                .ok_or_else(|| StudioError::invalid("command tool missing catalog name"))?;
            let mut params = args;
            if def.confirm_required {
                let confirmed = params
                    .get("confirm")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                if !confirmed {
                    return Err(StudioError::ConfirmationRequired(format!(
                        "{} requires confirm: true (Manage tier)",
                        def.name
                    )));
                }
                // The bus never sees `confirm` (catalog schemas are
                // additionalProperties:false); strip it after the gate.
                if let Value::Object(m) = &mut params {
                    m.remove("confirm");
                }
            }
            host.submit(actor, &catalog, params)
        }
        ToolKind::Session => match def.name.as_str() {
            "studio_undo" => {
                let did = host.undo(actor)?;
                Ok(json!({ "ok": true, "undone": did, "seq": host.seq() }))
            }
            "studio_redo" => {
                let did = host.redo(actor)?;
                Ok(json!({ "ok": true, "redone": did, "seq": host.seq() }))
            }
            "studio_metronome_set" => {
                let enabled = args.get("enabled").and_then(Value::as_bool);
                let level_db = args.get("levelDb").and_then(Value::as_f64);
                let count_in = args
                    .get("countInBeats")
                    .and_then(Value::as_u64)
                    .map(|v| v as u32);
                Ok(host.set_metronome(enabled, level_db, count_in))
            }
            "studio_note_preview" => host.preview_note(&args),
            "studio_performance_keep" => host.performance_keep(&args),
            "studio_performance_discard" => host.performance_discard(&args),
            other => Err(StudioError::invalid(format!("unknown session tool: {other}"))),
        },
        ToolKind::Read => dispatch_read(host, &def.name, &args),
        ToolKind::Gen => crate::gen::dispatch(&def.name, &args),
        ToolKind::Landing => crate::landing::dispatch_open_in_studio(host, actor, &args),
        ToolKind::Revise => dispatch_revise_tool(host, actor, &def.name, &args),
        ToolKind::Maintenance => dispatch_maintenance(host, &def.name, &args),
    }
}

/// Host-io maintenance tools (reclaim disk). Not catalog commands (they touch
/// the package on disk, not the journaled timeline), but agent-reachable so the
/// UI and an agent share one path. Purge is destructive, so it carries its own
/// `confirm: true` gate (enforced by the host).
fn dispatch_maintenance(
    host: &mut StudioHost,
    name: &str,
    args: &Value,
) -> Result<Value, StudioError> {
    match name {
        "studio_purge_takes" => host.purge_takes(args),
        other => Err(StudioError::invalid(format!("unknown maintenance tool: {other}"))),
    }
}

/// Route the L9 revise/extend/layer workflow tools (each drives a pipeline of
/// catalog commands through the same bus).
fn dispatch_revise_tool(
    host: &mut StudioHost,
    actor: Actor,
    name: &str,
    args: &Value,
) -> Result<Value, StudioError> {
    use crate::revise;
    match name {
        "studio_revise" => revise::dispatch_revise(host, actor, args),
        "studio_audition" => revise::dispatch_audition(host, args),
        "studio_commit" => revise::dispatch_commit(host, actor, args),
        "studio_finalize" => revise::dispatch_finalize(host, actor, args),
        "studio_discard" => revise::dispatch_discard(host, args),
        "studio_extend" => revise::dispatch_extend(host, actor, args),
        "studio_commit_extend" => revise::dispatch_commit_extend(host, actor, args),
        "studio_layer" => revise::dispatch_layer(host, actor, args),
        "studio_commit_layer" => revise::dispatch_commit_layer(host, actor, args),
        other => Err(StudioError::invalid(format!("unknown revise tool: {other}"))),
    }
}

fn dispatch_read(host: &StudioHost, name: &str, args: &Value) -> Result<Value, StudioError> {
    match name {
        "studio_snapshot" => Ok(host.snapshot(args.get("sinceSeq").and_then(Value::as_u64))),
        "studio_journal" => {
            let after = args.get("afterId").and_then(Value::as_str);
            let limit = args.get("limit").and_then(Value::as_u64).unwrap_or(100) as usize;
            Ok(host.journal_page(after, limit))
        }
        "studio_engine_stats" => Ok(host.engine_stats()),
        "studio_meters" => Ok(host.meters()),
        // Static: takes no host state, so it answers before a project is open.
        "studio_capabilities" => Ok(crate::capabilities::capabilities()),
        "studio_manifest" => Ok(host.manifest_value()),
        "studio_waveform" => {
            let clip = req_str(args, "clipId")?;
            let zoom = args.get("zoom").and_then(Value::as_u64).unwrap_or(0) as u32;
            let start_bin = args.get("startBin").and_then(Value::as_u64).unwrap_or(0);
            let max_bins = args
                .get("maxBins")
                .and_then(Value::as_u64)
                .unwrap_or(WAVEFORM_MAX_BINS as u64) as usize;
            host.waveform(&clip, zoom, start_bin, max_bins)
        }
        "studio_takes" => Ok(host.takes(args)),
        "studio_lineage" => {
            let clip = req_str(args, "clipId")?;
            host.lineage(&clip)
        }
        other => Err(StudioError::invalid(format!("unknown read tool: {other}"))),
    }
}

fn req_str(args: &Value, key: &str) -> Result<String, StudioError> {
    args.get(key)
        .and_then(Value::as_str)
        .map(String::from)
        .ok_or_else(|| StudioError::invalid(format!("missing string arg '{key}'")))
}
