"""Render markdown tables from gen manifest + analysis JSON.

Standard library only.

Usage:
    python -m repaint_harness.report --manifest out/manifest.json \
        --analysis out/analysis.json
"""

from __future__ import annotations

import argparse
import json


def fmt(v, nd=2):
    if v is None:
        return "n/a"
    if isinstance(v, float):
        return f"{v:.{nd}f}"
    return str(v)


def matrix_table(analysis: dict) -> str:
    rows = ["| op | model | steps | seed | raw null strict RMS dB | raw null gain-comp dB | "
            "click@0ms | click@20ms | flux z@20ms (max) | RMS step dB@20ms | "
            "region tempo drift % | wall s |",
            "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for oid, r in sorted(analysis["repaints"].items()):
        if r["stage"] not in ("matrix", "probes", "trimmed"):
            continue
        sp = r.get("splices") or {}
        c0 = max(sp["0"]["start"]["click_ratio"], sp["0"]["end"]["click_ratio"]) if "0" in sp else None
        c20 = max(sp["20"]["start"]["click_ratio"], sp["20"]["end"]["click_ratio"]) if "20" in sp else None
        z20 = max(sp["20"]["start"]["flux_zscore"], sp["20"]["end"]["flux_zscore"]) if "20" in sp else None
        s20 = max(sp["20"]["start"]["rms_step_db"], sp["20"]["end"]["rms_step_db"]) if "20" in sp else None
        drift = r["tempo"]["repaint_region"]["beat_interval_drift_pct"]
        rows.append("| " + " | ".join([
            oid, r["model"].replace("acestep-v15-", ""), str(r["steps"]),
            str(r["seed"]),
            fmt(r["raw_null"]["strict"]["residual_rms_db"], 1),
            fmt(r["raw_null"]["strict"]["residual_rms_db_gain_compensated"], 1),
            fmt(c0, 1), fmt(c20, 1), fmt(z20, 2), fmt(s20, 2),
            fmt(drift, 2), fmt(r.get("wall_s"), 1),
        ]) + " |")
    return "\n".join(rows)


def fade_table(analysis: dict, op_id: str) -> str:
    r = analysis["repaints"][op_id]
    rows = [f"Fade comparison on {op_id}:",
            "| fade ms | click (max) | flux z (max) | RMS step dB (max) |",
            "|---|---|---|---|"]
    for ms, sp in (r.get("splices") or {}).items():
        rows.append("| " + " | ".join([
            ms,
            fmt(max(sp["start"]["click_ratio"], sp["end"]["click_ratio"]), 1),
            fmt(max(sp["start"]["flux_zscore"], sp["end"]["flux_zscore"]), 2),
            fmt(max(sp["start"]["rms_step_db"], sp["end"]["rms_step_db"]), 2),
        ]) + " |")
    return "\n".join(rows)


def ladder_table(manifest: dict, analysis: dict) -> str:
    rows = ["| model | steps | wall s | s per 8-bar region | click@20ms | flux z@20ms |",
            "|---|---|---|---|---|---|"]
    ladder_ids = [op["id"] for op in manifest["ops"] if op.get("stage") == "ladder"
                  and op.get("status") == "ok"]
    ladder_ids += ["A_rp_halftime_s11_base50", "A_rp_halftime_s11_xl50"]
    seen = []
    for lid in ladder_ids:
        r = analysis["repaints"].get(lid)
        op = next((o for o in manifest["ops"] if o["id"] == lid), None)
        if not r or not op or lid in seen:
            continue
        seen.append(lid)
        sp = r.get("splices") or {}
        c20 = max(sp["20"]["start"]["click_ratio"], sp["20"]["end"]["click_ratio"]) if "20" in sp else None
        z20 = max(sp["20"]["start"]["flux_zscore"], sp["20"]["end"]["flux_zscore"]) if "20" in sp else None
        rows.append("| " + " | ".join([
            op["model"].replace("acestep-v15-", ""), str(op["steps"]),
            fmt(op.get("wall_s"), 1), fmt(op.get("wall_s"), 1),
            fmt(c20, 1), fmt(z20, 2),
        ]) + " |")
    return "\n".join(rows)


def latency_table(manifest: dict) -> str:
    rows = ["| op | task | model | steps | wall s | dit load s |",
            "|---|---|---|---|---|---|"]
    for op in manifest["ops"]:
        if op.get("status") != "ok":
            continue
        rows.append("| " + " | ".join([
            op["id"], op["task_type"], op["model"].replace("acestep-v15-", ""),
            str(op["steps"]), fmt(op.get("wall_s"), 1), fmt(op.get("dit_load_s"), 1),
        ]) + " |")
    return "\n".join(rows)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--analysis", required=True)
    args = ap.parse_args()
    with open(args.manifest) as fh:
        manifest = json.load(fh)
    with open(args.analysis) as fh:
        analysis = json.load(fh)

    print("## Songs\n")
    for name, s in analysis["songs"].items():
        print(f"- {name}: {fmt(s['duration_s'], 1)} s, declared {s['declared_bpm']} bpm, "
              f"measured {fmt(s['measured_tempo_bpm'], 1)} bpm, grid offset "
              f"{fmt(s['grid_offset_s'] * 1000, 0)} ms, region {s['region_seconds']}")
    print("\n## Repaint matrix + probes\n")
    print(matrix_table(analysis))
    best = analysis.get("selection", {}).get("best")
    if best:
        print(f"\n## Fades (best take {best})\n")
        print(fade_table(analysis, best))
    print("\n## Steps ladder\n")
    print(ladder_table(manifest, analysis))
    print("\n## Stem scope\n")
    print(json.dumps(analysis.get("stem_scope", {}), indent=2, default=str)[:4000])
    print("\n## Extend\n")
    print(json.dumps(analysis.get("extend", {}), indent=2, default=str)[:2000])
    print("\n## Lego\n")
    print(json.dumps(analysis.get("lego", {}), indent=2, default=str)[:2000])
    print("\n## Demucs timings\n")
    print(json.dumps(analysis.get("demucs", {}), indent=2, default=str)[:2000])
    print("\n## Full latency\n")
    print(latency_table(manifest))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
