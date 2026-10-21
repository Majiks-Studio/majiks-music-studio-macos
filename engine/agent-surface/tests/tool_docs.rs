//! THE TOOL-DOC GATE: the 148-tool MCP surface an agent actually reads.
//!
//! `timeline-core/tests/catalog_descriptions.rs` holds the CATALOG to account,
//! which covers the 118 command tools because their `inputSchema` is the
//! catalog `paramsSchema` verbatim. It cannot see the other 30: the read tools,
//! the gen proxies, the L8 landing bridge, the L9 revise pipeline, the session
//! and maintenance tools are all authored HERE, in `registry.rs`, in Rust.
//!
//! Nor can it see the two schema decorations the registry applies on the way
//! out: `with_confirm` adds a `confirm` property to every Manage tool, and
//! `command_input_schema` adds `clipId`/`startTicks` to `studio_import_audio`.
//! Those are parameters an agent must fill in and the catalog has never heard
//! of them.
//!
//! So this walks the generated manifest — the same bytes committed to
//! `docs/generated/mcp-tools.v1.json` — and applies the same floor. Anyone
//! adding a tool to `registry.rs` without describing it, or adding a parameter
//! to one, fails the build by tool name.

use agent_surface::registry;
use serde_json::Value;

/// Same floor as the catalog gate. A description shorter than this cannot say
/// what a tool does and when to reach for it.
const MIN_DESCRIPTION_CHARS: usize = 20;

/// THE traversal over a tool's inputSchema: every property, including nested
/// objects and array items.
///
/// One of these, called by both tests below. A coverage assertion that counted
/// with its own copy of the walk would stay green while the walk it is meant to
/// police stopped descending — a mutation that SURVIVED the first pass of the
/// sibling catalog gate for exactly that reason.
fn declared_paths(schema: &Value, prefix: &str, out: &mut Vec<(String, Value)>) {
    let Some(props) = schema.get("properties").and_then(Value::as_object) else {
        return;
    };
    for (key, sub) in props {
        let path = format!("{prefix}{key}");
        out.push((path.clone(), sub.clone()));
        if sub.get("type").and_then(Value::as_str) == Some("object") {
            declared_paths(sub, &format!("{path}."), out);
        }
        if sub.get("type").and_then(Value::as_str) == Some("array") {
            if let Some(items) = sub.get("items") {
                declared_paths(items, &format!("{path}[]."), out);
            }
        }
    }
}

fn check_schema(tool: &str, schema: &Value, fails: &mut Vec<String>) {
    let mut declared = Vec::new();
    declared_paths(schema, "", &mut declared);
    for (path, sub) in declared {
        match sub.get("description").and_then(Value::as_str) {
            None => fails.push(format!(
                "{tool} :: {path}: NO DESCRIPTION. An agent filling this in has nothing to \
                 read but the type."
            )),
            Some(d) if d.trim().chars().count() < MIN_DESCRIPTION_CHARS => fails.push(format!(
                "{tool} :: {path}: description is {} characters, under the \
                 {MIN_DESCRIPTION_CHARS} floor: {d:?}",
                d.trim().chars().count()
            )),
            Some(_) => {}
        }
    }
}

#[test]
fn every_tool_and_every_tool_parameter_is_described() {
    let manifest = registry::tools_manifest();
    let tools = manifest["tools"].as_array().expect("tools array");
    let mut fails = Vec::new();

    for tool in tools {
        let name = tool["name"].as_str().expect("tool name");
        match tool.get("description").and_then(Value::as_str) {
            None => fails.push(format!("{name}: NO DESCRIPTION")),
            Some(d) if d.trim().chars().count() < MIN_DESCRIPTION_CHARS => fails.push(format!(
                "{name}: description is {} characters, under the {MIN_DESCRIPTION_CHARS} floor: {d:?}",
                d.trim().chars().count()
            )),
            Some(_) => {}
        }
        check_schema(name, &tool["inputSchema"], &mut fails);
    }

    assert!(
        fails.is_empty(),
        "THE TOOL-DOC GATE FAILED ({} problems) across {} tools:\n{}",
        fails.len(),
        tools.len(),
        fails.join("\n")
    );
}

/// The surface this gate walks, pinned — otherwise a change that stopped
/// descending would leave it green over a fraction of the tools. `GATES.md`:
/// a suite can run and assert nothing.
#[test]
fn the_gate_covers_the_whole_generated_surface() {
    let manifest = registry::tools_manifest();
    let tools = manifest["tools"].as_array().expect("tools array");
    assert_eq!(tools.len(), 148, "148 tools = 118 command tools + 30 authored here");

    // Counted with THE traversal, never a copy of it.
    let mut declared = Vec::new();
    for tool in tools {
        declared_paths(&tool["inputSchema"], "", &mut declared);
    }
    let params = declared.len();
    assert!(
        declared.iter().any(|(p, _)| p.contains("[].")),
        "the walk must descend into array items (studio_commit's promotions[] carry two \
         parameters of their own)"
    );
    assert!(
        declared.iter().any(|(p, _)| p.contains('.') && !p.contains("[]")),
        "the walk must descend into nested objects (studio_open_in_studio's stems)"
    );
    assert_eq!(
        params, 432,
        "the generated tool surface declares 432 parameters (nested and array-item \
         properties included). Update this in the SAME commit as the tool that changed it."
    );

    // The registry's own decorations are reachable from here and from nowhere
    // else, so name them: if these stop appearing, this gate has silently
    // narrowed to what the catalog gate already covered.
    let confirm = tools
        .iter()
        .filter(|t| t["inputSchema"]["properties"].get("confirm").is_some())
        .count();
    assert_eq!(
        confirm, 10,
        "the 9 Manage command tools plus studio_purge_takes each carry a `confirm` parameter"
    );
    let import = tools
        .iter()
        .find(|t| t["name"] == "studio_import_audio")
        .expect("studio_import_audio");
    for added in ["clipId", "startTicks"] {
        assert!(
            import["inputSchema"]["properties"][added]["description"].is_string(),
            "studio_import_audio's host-added {added} must stay described"
        );
    }
}
