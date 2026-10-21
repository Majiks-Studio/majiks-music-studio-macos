#!/usr/bin/env bash
# generate-catalog-names.sh - regenerate the Swift mirrors of the command
# catalog from engine/contracts/command-catalog.v2.json.
#
# Two files, one contract:
#   Sources/Studio/CatalogNames.swift    every command NAME, in catalog order
#   Sources/Studio/CatalogSchemas.swift  every command's paramsSchema, verbatim
#
# CatalogNames.swift's header has named this script since it was written, and
# for that entire time the script did not exist anywhere in the repo — the file
# was hand-maintained under a comment claiming it was generated. That is the
# same shape of lie as a green test on a dead assertion: the header stopped
# anyone from checking, so nothing did. Writing the script is what makes the
# header true, and CatalogSchemas.swift exists only because it is generated —
# 119 hand-transcribed parameter schemas would drift from the contract by the
# second edit.
#
# Every path is quoted: the canonical repo lives under a path with spaces.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CATALOG="$REPO_ROOT/engine/contracts/command-catalog.v2.json"
OUT_DIR="$REPO_ROOT/src/swift/Sources/Studio"

[[ -f "$CATALOG" ]] || { echo "ERROR: $CATALOG not found" >&2; exit 1; }

echo "==> catalog : $CATALOG"
echo "==> out     : $OUT_DIR"

CATALOG="$CATALOG" OUT_DIR="$OUT_DIR" python3 - <<'PY'
import json
import os

catalog_path = os.environ["CATALOG"]
out_dir = os.environ["OUT_DIR"]

with open(catalog_path) as fh:
    catalog = json.load(fh)

commands = catalog["commands"]

# ---------------------------------------------------------------------------
# The keywords the Swift subset validator (StudioCatalogSchema) implements.
# This list is the SAME subset engine/timeline-core/src/schema.rs supports, and
# it is checked here rather than trusted: if a future catalog revision adds a
# keyword Swift cannot evaluate, this script fails loudly instead of emitting a
# table that would be silently half-validated. A validator that ignores the
# keyword it does not know is a validator that passes everything.
# ---------------------------------------------------------------------------
SUPPORTED = {
    "type", "required", "properties", "additionalProperties", "enum", "const",
    "pattern", "minLength", "minimum", "maximum", "exclusiveMinimum",
    "minItems", "maxItems", "uniqueItems", "items", "minProperties",
    "propertyNames", "if", "then", "oneOf", "default", "description",
}

def check(node, where):
    if not isinstance(node, dict):
        return
    for key, value in node.items():
        if key not in SUPPORTED:
            raise SystemExit(
                f"ERROR: {where}: schema keyword {key!r} is outside the subset "
                f"StudioCatalogSchema implements. Teach the Swift validator first."
            )
        if key == "properties":
            for name, sub in value.items():
                check(sub, f"{where}/properties/{name}")
        elif key in ("items", "if", "then", "propertyNames"):
            check(value, f"{where}/{key}")
        elif key == "oneOf":
            for i, sub in enumerate(value):
                check(sub, f"{where}/oneOf/{i}")
        elif key == "additionalProperties" and isinstance(value, dict):
            check(value, f"{where}/additionalProperties")

for command in commands:
    check(command["paramsSchema"], command["name"])

# ---------------------------------------------------------------------------
# CatalogNames.swift - the names, in catalog order.
# ---------------------------------------------------------------------------
lines = [
    "/// Auto-generated from command-catalog.v2.json.",
    "/// Do not edit by hand.",
    "/// Run scripts/generate-catalog-names.sh to regenerate.",
    "",
    "enum CatalogNames {",
    "    static let names: [String] = [",
]
lines += [f'        "{c["name"]}",' for c in commands]
lines += [
    "    ]",
    "}",
    "",
]
with open(os.path.join(out_dir, "CatalogNames.swift"), "w") as fh:
    fh.write("\n".join(lines))

# ---------------------------------------------------------------------------
# CatalogSchemas.swift - `{commandName: paramsSchema}` as the contract wrote it.
#
# Embedded as JSON rather than transcribed into Swift declarations on purpose:
# a transcription is a second copy of the contract that a person maintains, and
# the whole reason this file exists is that the app had a second copy of the
# parameter names (StudioMockEngine's) which had drifted from the first.
# ---------------------------------------------------------------------------
schemas = {c["name"]: c["paramsSchema"] for c in commands}
blob = json.dumps(schemas, separators=(",", ":"), sort_keys=True)

# The Swift raw string below is delimited with `#"""`. JSON that contained the
# sequence `"#` would end the literal early and produce a file that does not
# compile — loud, but check it here so the failure names the cause.
if '"#' in blob:
    raise SystemExit('ERROR: a paramsSchema contains `"#`; widen the raw-string delimiter')

swift = f'''/// Auto-generated from command-catalog.v2.json.
/// Do not edit by hand.
/// Run scripts/generate-catalog-names.sh to regenerate.
///
/// Every command's `paramsSchema`, verbatim, keyed by command name. This is
/// what lets `StudioCatalogSchema` refuse a wrong parameter name in EVERY
/// build — including the mock — rather than only on the real engine, where a
/// refusal used to be the first and only sign that a shipped gesture had been
/// writing the wrong key all along.
enum CatalogSchemas {{
    /// The raw contract fragment. Parsed once, lazily, by `StudioCatalogSchema`.
    static let json: String = #"""
{blob}
"""#
}}
'''
with open(os.path.join(out_dir, "CatalogSchemas.swift"), "w") as fh:
    fh.write(swift)

print(f"==> wrote CatalogNames.swift   ({len(commands)} commands)")
print(f"==> wrote CatalogSchemas.swift ({len(blob)} bytes of schema)")
PY
