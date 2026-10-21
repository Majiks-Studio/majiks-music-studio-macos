//! THE PARITY GATE (DJ `parity_gate` discipline): every command in
//! `command-catalog.v1.json` has a tool, or it is a documented exclusion.
//! Fails the build otherwise. Plus a regen check so the committed tool manifest
//! never drifts from the generated one.

use std::collections::HashSet;
use std::path::Path;

use agent_surface::{registry, EXCLUDED_COMMANDS};
use timeline_core::catalog::Catalog;

#[test]
fn parity_gate_every_catalog_command_has_a_tool_or_a_documented_exclusion() {
    let catalog = Catalog::get();
    let tool_commands: HashSet<String> = registry::tool_defs()
        .iter()
        .filter_map(|t| t.catalog_name.clone())
        .collect();

    let mut missing: Vec<String> = Vec::new();
    for name in catalog.names() {
        if EXCLUDED_COMMANDS.contains(&name.as_str()) {
            continue;
        }
        if !tool_commands.contains(name) {
            missing.push(name.clone());
        }
    }
    assert!(
        missing.is_empty(),
        "PARITY GATE FAILED: catalog commands with no tool and no documented exclusion: {missing:?}"
    );

    // No stale exclusions: every excluded name must still be a real command.
    for ex in EXCLUDED_COMMANDS {
        assert!(
            catalog.spec(ex).is_some(),
            "documented exclusion {ex} is not a catalog command (stale exclusion)"
        );
    }

    // And every command tool maps to a real command (no phantom tools).
    for name in &tool_commands {
        assert!(
            catalog.spec(name).is_some(),
            "tool references unknown command {name}"
        );
    }
}

#[test]
fn parity_counts_are_exactly_v2() {
    let catalog = Catalog::get();
    assert_eq!(catalog.len(), 119, "catalog v2 is 119 commands");
    assert_eq!(
        EXCLUDED_COMMANDS,
        &["gen.landed"],
        "the only exclusion is the system-authored completion record"
    );
    let command_tools = registry::tool_defs()
        .iter()
        .filter(|t| t.catalog_name.is_some())
        .count();
    assert_eq!(
        command_tools, 118,
        "118 command tools = 119 catalog - 1 exclusion"
    );
}

#[test]
fn regen_check_committed_manifest_is_current() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../docs/generated/mcp-tools.v1.json");
    let committed = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("committed tool manifest missing at {}: {e}", path.display()));
    let fresh = registry::tools_manifest_pretty();
    assert_eq!(
        committed, fresh,
        "docs/generated/mcp-tools.v1.json is STALE. Regenerate:\n  cargo run -p agent-surface --bin majiks-studio-cli -- tools --write engine/docs/generated/mcp-tools.v1.json"
    );
}
