//! CLI: decode + analyze one audio file, emit `AnalyzeReport` JSON to
//! stdout. Used by agents and by this lane's own evidence-gathering
//! (docs/evidence/l3-media-analysis.md); the JSON shape is documented in
//! `src/types.rs`.
//!
//! Usage: `analyze <audio-file> [--declared-bpm N]`
//!
//! `--declared-bpm` is a hint (a generation request's requested BPM, or a
//! file tag), echoed back as `declaredBpm`/`declaredVsMeasuredPct`; it does
//! not change the measured `bpm` except as a documented tie-breaker (see
//! `media::tempo::estimate_tempo`).

use std::env;
use std::path::Path;
use std::process::ExitCode;

use media::report::analyze_file;

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: analyze <audio-file> [--declared-bpm N]");
        return ExitCode::FAILURE;
    }
    let path = Path::new(&args[1]);

    let mut declared_bpm = None;
    let mut i = 2;
    while i < args.len() {
        if args[i] == "--declared-bpm" && i + 1 < args.len() {
            match args[i + 1].parse::<f64>() {
                Ok(v) => declared_bpm = Some(v),
                Err(_) => {
                    eprintln!("--declared-bpm expects a number, got {:?}", args[i + 1]);
                    return ExitCode::FAILURE;
                }
            }
            i += 2;
        } else {
            eprintln!("unrecognized argument: {}", args[i]);
            return ExitCode::FAILURE;
        }
    }

    match analyze_file(path, declared_bpm) {
        Ok(report) => match serde_json::to_string_pretty(&report) {
            Ok(json) => {
                println!("{json}");
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("json encode error: {e}");
                ExitCode::FAILURE
            }
        },
        Err(e) => {
            eprintln!("analyze failed for {}: {e}", path.display());
            ExitCode::FAILURE
        }
    }
}
