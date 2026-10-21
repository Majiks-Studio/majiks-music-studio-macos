#!/usr/bin/env python3
"""Regenerate COMMAND-REFERENCE.md from command-catalog.v2.json."""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
CONTRACTS = os.path.join(REPO, "engine", "contracts")
OUT = os.path.join(CONTRACTS, "COMMAND-REFERENCE.md")

with open(os.path.join(CONTRACTS, "command-catalog.v2.json")) as f:
    cat = json.load(f)

commands = cat["commands"]
cats = {}
for c in commands:
    cats.setdefault(c["category"], []).append(c)

lines = [
    "# Majik's Music Studio: command reference",
    f"Generated from command-catalog v2 ({len(commands)} commands). "
    "Every edit in the DAW is one of these commands, whether issued by "
    "a person, an agent, or the API.",
    "",
    "## How to read this",
    "- Journaled: the command is written to the project's command journal "
    "(the provenance and undo log).",
    "- Undoable: the command can be reversed. Non-undoable commands say why.",
    "- Inverse: how the command is reversed (self = applying it again with "
    "prior values; explicit = a specific paired command).",
    "",
]

for cat_name in sorted(cats.keys()):
    cmds = cats[cat_name]
    lines.append(f"## {cat_name}  ({len(cmds)} commands)")
    for c in cmds:
        lines.append(f"### {c['name']}")
        desc = c.get("description", "")
        lines.append(f"What it does: {desc}")

        params = c.get("paramsSchema", {}).get("properties", {})
        required = c.get("paramsSchema", {}).get("required", [])
        param_descs = []
        for pname, p in params.items():
            req = " (required)" if pname in required else " (optional)"
            pdesc = p.get("description", "")
            param_descs.append(f"{pname}{req}, {pdesc}")
        if param_descs:
            lines.append(f"Parameters: {'; '.join(param_descs)}")
        else:
            lines.append("Parameters: No parameters.")

        journaled = c.get("journaled", False)
        undoable = c.get("undoable", False)
        lines.append(f"Journaled: {'yes' if journaled else 'no'}."
                     f"{'' if journaled else (c.get('journaledReason', '') or '')}")
        lines.append(f"Undoable: {'yes' if undoable else 'no'}."
                     f"{'' if undoable else (c.get('undoableReason', '') or '')}")

        rule = c.get("inverseRule", {})
        imode = rule.get("mode", "none")
        iname = rule.get("name")
        if imode == "self":
            lines.append("Inverse: self.")
        elif imode == "explicit" and iname:
            lines.append(f"Inverse: explicit ({iname}).")
        else:
            lines.append("Inverse: none.")

        lines.append("")

with open(OUT, "w") as f:
    f.write("\n".join(lines) + "\n")

print(f"Written {len(commands)} commands to {OUT}")
