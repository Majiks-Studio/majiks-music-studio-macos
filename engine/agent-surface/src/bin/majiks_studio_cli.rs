//! `majiks-studio-cli`: the agents-render-anywhere surface and the acceptance
//! backbone. Opens/creates a `.mstudio`, applies a jsonl command script
//! through the SAME command bus the FFI and MCP server use, and bounces a WAV.
//!
//! Subcommands:
//!   run    --project DIR --script FILE.jsonl [--bounce OUT.wav] [--actor NAME]
//!          apply an envelope-per-line script, save, optionally bounce.
//!   read   --project DIR --tool NAME [--args JSON]
//!          call one READ tool and print its JSON. The counterpart `run` shipped
//!          without: this binary is described as the agents-render-anywhere
//!          surface and could only write, so the one harness an agent author can
//!          reach from a shell could not check its own work.
//!   bounce --project DIR --out OUT.wav [--start-ticks N --end-ticks N]
//!          open a package and bounce the master (or a region).
//!   interop [--dir DIR]
//!          the self-contained acceptance: create -> tempo -> 2 tracks ->
//!          2 imported clips -> move/trim -> save -> bounce, plus a null-match
//!          of the envelope route vs the tool route. Prints a transcript.
//!   tools  [--write PATH]
//!          print (or rewrite) the generated MCP tool manifest (regen check).
//!
//! AUDIO SAFETY: every subcommand is silent at any device (this binary never
//! opens one; the bounce runs the offline graph).

use std::path::{Path, PathBuf};
use std::process::exit;

use serde_json::{json, Value};

use agent_surface::landing::{
    build_landing, fixture_refusal, selectable_separator_names, HtdemucsSeparator, LandingRequest,
    PreSeparated, Separator, StemSet, DEFAULT_SEPARATOR, INTERLEAVE_FIXTURE_NAME,
};
use agent_surface::registry;
use agent_surface::stem_usability;
use agent_surface::{dispatch_tool, StudioHost};
use render::offline::residual;
use timeline_core::envelope::ActorKind;
use timeline_core::Actor;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let sub = args.first().map(String::as_str).unwrap_or("help");
    let result = match sub {
        "run" => cmd_run(&args),
        "read" => cmd_read(&args),
        "bounce" => cmd_bounce(&args),
        "land" => cmd_land(&args),
        "interop" => cmd_interop(&args),
        "live-proof" => cmd_live_proof(&args),
        "provenance" => cmd_provenance(&args),
        "check-stems" => cmd_check_stems(&args),
        "tools" => cmd_tools(&args),
        _ => {
            usage();
            Ok(())
        }
    };
    if let Err(e) = result {
        eprintln!("majiks-studio-cli {sub}: error: {e}");
        exit(1);
    }
}

fn usage() {
    eprintln!(
        "usage:\n  majiks-studio-cli run --project DIR --script FILE.jsonl [--bounce OUT.wav] [--actor NAME]\n  majiks-studio-cli read --project DIR --tool NAME [--args JSON]\n      read tools: {reads}\n  majiks-studio-cli bounce --project DIR --out OUT.wav [--start-ticks N --end-ticks N]\n  majiks-studio-cli land --mix WAV --out DIR.mstudio [--work DIR] [--prompt TEXT]\n      [--separator {separators}] (default {default}) [--python-src DIR]\n      [--stems-dir DIR | --vocals P --drums P --bass P --other P]\n      [--declared-bpm N] [--key \"C major\"] [--seed N] [--gen-model NAME]\n      [--gen-device mlx|mps|cuda|cpu|remote] [--source generated|library|imported]\n      [--tags \"Intro,Verse,Chorus\"] [--times \"0,8,24\"] [--bounce OUT.wav]\n  majiks-studio-cli interop [--dir DIR]\n  majiks-studio-cli live-proof [--dir DIR] [--seed-only]\n  majiks-studio-cli provenance [--dir DIR] [--loudness streaming|club|broadcast|none]\n  majiks-studio-cli check-stems [DIR...]\n      scan DIR(s) for stem files and report fixture-era content; exits non-zero on any\n  majiks-studio-cli tools [--write PATH]",
        separators = selectable_separator_names(),
        default = DEFAULT_SEPARATOR,
        reads = read_tool_names().join(" ")
    );
}

/// The read tools, named in the usage text rather than left to be discovered.
/// Generated from the registry, so a read tool added later shows up here for
/// free instead of being a thing the CLI silently declines to mention.
fn read_tool_names() -> Vec<String> {
    registry::tool_defs()
        .into_iter()
        .filter(|d| d.tier == registry::ToolTier::Read)
        .map(|d| d.name)
        .collect()
}

fn flag(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned()
}

fn require_flag(args: &[String], name: &str) -> Result<String, String> {
    flag(args, name).ok_or_else(|| format!("missing required flag {name}"))
}

// ---------------------------------------------------------------------------
// run: apply a jsonl command script
// ---------------------------------------------------------------------------

fn cmd_run(args: &[String]) -> Result<(), String> {
    let project = require_flag(args, "--project")?;
    let script = require_flag(args, "--script")?;
    let actor_name = flag(args, "--actor").unwrap_or_else(|| "agent".to_string());
    let actor = Actor {
        kind: timeline_core::envelope::ActorKind::Agent,
        name: actor_name,
    };

    let mut host = StudioHost::open_or_create(&project, "cli-project").map_err(|e| e.to_string())?;
    let text = std::fs::read_to_string(&script).map_err(|e| format!("read {script}: {e}"))?;
    let mut applied = 0;
    for (n, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let env: Value = serde_json::from_str(line)
            .map_err(|e| format!("line {}: not a JSON envelope: {e}", n + 1))?;
        let name = env
            .get("name")
            .and_then(Value::as_str)
            .ok_or_else(|| format!("line {}: envelope has no name", n + 1))?;
        let params = env.get("params").cloned().unwrap_or_else(|| json!({}));
        let out = host
            .submit(actor.clone(), name, params)
            .map_err(|e| format!("line {}: {name}: {e}", n + 1))?;
        println!("{} -> {}", name, compact(&out));
        applied += 1;
    }
    host.save().map_err(|e| e.to_string())?;
    println!("applied {applied} commands, saved {}", project);

    if let Some(out) = flag(args, "--bounce") {
        let report = host.bounce_master(Path::new(&out)).map_err(|e| e.to_string())?;
        println!("bounced {} ({:.2}s, peak {:.4})", out, report.seconds, report.peak);
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// read: call one read tool and print its JSON
//
// The other half of `run`. An agent driving this binary could apply a script
// and bounce a WAV, and had no way to ask what the project now IS — so the
// acceptance backbone could prove that a command was ACCEPTED and never that it
// LANDED. Read tools only: this subcommand opens the package read-only and
// never saves, so it cannot be the thing that changed the artifact it is being
// used to inspect.
// ---------------------------------------------------------------------------

fn cmd_read(args: &[String]) -> Result<(), String> {
    let project = require_flag(args, "--project")?;
    let name = require_flag(args, "--tool")?;
    let def = registry::tool_by_name(&name)
        .ok_or_else(|| format!("unknown tool {name}; read tools: {}", read_tool_names().join(" ")))?;
    // Refuse a write here rather than quietly performing one. `read` that can
    // mutate is a footgun in exactly the place a caller has stopped expecting
    // side effects.
    if def.tier != registry::ToolTier::Read {
        return Err(format!(
            "{name} is a {} tool, not a read tool; use `run` with a script. read tools: {}",
            def.tier.as_str(),
            read_tool_names().join(" ")
        ));
    }
    let args_json: Value = match flag(args, "--args") {
        Some(s) => serde_json::from_str(&s).map_err(|e| format!("--args is not JSON: {e}"))?,
        None => json!({}),
    };

    let mut host = StudioHost::open_package(&project).map_err(|e| e.to_string())?;
    let actor = Actor {
        kind: ActorKind::Agent,
        name: flag(args, "--actor").unwrap_or_else(|| "agent".to_string()),
    };
    let out = dispatch_tool(&mut host, actor, &name, args_json).map_err(|e| e.to_string())?;
    println!("{}", serde_json::to_string_pretty(&out).unwrap_or_default());
    Ok(())
}

// ---------------------------------------------------------------------------
// bounce: open + render
// ---------------------------------------------------------------------------

fn cmd_bounce(args: &[String]) -> Result<(), String> {
    let project = require_flag(args, "--project")?;
    let out = require_flag(args, "--out")?;
    let host = StudioHost::open_package(&project).map_err(|e| e.to_string())?;
    let report = match (flag(args, "--start-ticks"), flag(args, "--end-ticks")) {
        (Some(s), Some(e)) => {
            let s = s.parse::<u64>().map_err(|_| "bad --start-ticks")?;
            let e = e.parse::<u64>().map_err(|_| "bad --end-ticks")?;
            host.bounce_region(Path::new(&out), s, e).map_err(|e| e.to_string())?
        }
        _ => host.bounce_master(Path::new(&out)).map_err(|e| e.to_string())?,
    };
    println!(
        "bounced {} ({} frames, {:.2}s, peak {:.4})",
        out, report.frames, report.seconds, report.peak
    );
    Ok(())
}

// ---------------------------------------------------------------------------
// land: the L8 "Open in Studio" bridge, headless.
//
// A finished song (mix WAV + prompt) -> analyze (beat-tracked tempo/downbeats)
// -> separate -> bar-aligned stem tracks with lineage -> a saved .mstudio. The
// agents-render-anywhere face of the bridge: an agent says "open this song in
// the studio" and gets a built, playable project. Prints the landing report
// JSON (timing, null residual, section accuracy).
// ---------------------------------------------------------------------------

fn cmd_land(args: &[String]) -> Result<(), String> {
    let mix = require_flag(args, "--mix")?;
    let out = require_flag(args, "--out")?;
    let work = flag(args, "--work").unwrap_or_else(|| format!("{out}.work"));

    let separator = build_separator(args)?;
    let req = LandingRequest {
        mix_path: PathBuf::from(&mix),
        prompt: flag(args, "--prompt").unwrap_or_default(),
        declared_bpm: flag(args, "--declared-bpm").and_then(|s| s.parse::<f64>().ok()),
        key: flag(args, "--key"),
        section_tags: split_list(flag(args, "--tags")),
        section_times: split_list(flag(args, "--times"))
            .iter()
            .filter_map(|s| s.parse::<f64>().ok())
            .collect(),
        seed: flag(args, "--seed").and_then(|s| s.parse::<i64>().ok()),
        gen_model: flag(args, "--gen-model"),
        gen_device: flag(args, "--gen-device"),
        source_kind: flag(args, "--source"),
        project_name: flag(args, "--name"),
        truth_section_bars: None,
    };

    let actor = Actor {
        kind: ActorKind::Agent,
        name: flag(args, "--actor").unwrap_or_else(|| "open-in-studio".to_string()),
    };
    let report = build_landing(
        Path::new(&out),
        &req,
        separator.as_ref(),
        Path::new(&work),
        actor,
    )
    .map_err(|e| e.to_string())?;

    println!("{}", serde_json::to_string_pretty(&report.to_json()).unwrap_or_default());

    if let Some(bounce) = flag(args, "--bounce") {
        let host = StudioHost::open_package(&out).map_err(|e| e.to_string())?;
        let rep = host.bounce_master(Path::new(&bounce)).map_err(|e| e.to_string())?;
        eprintln!("bounced {} ({:.2}s, peak {:.4})", bounce, rep.seconds, rep.peak);
    }
    Ok(())
}

/// Build the requested `Separator` from the flags.
///
/// The default is a REAL separator. It used to be the interleave test fixture,
/// so `land` with no `--separator` silently produced four unusable stems and
/// every downstream check (which are all sum-shaped) passed. A caller who names
/// nothing now gets real separation or a refusal that says how to fix it --
/// never silent garbage.
fn build_separator(args: &[String]) -> Result<Box<dyn Separator>, String> {
    match flag(args, "--separator").as_deref().unwrap_or(DEFAULT_SEPARATOR) {
        n if n == INTERLEAVE_FIXTURE_NAME => Err(fixture_refusal(n)),
        "htdemucs" => {
            // --python-src is now optional: the interpreter and the backend dir
            // are discovered (bundled runtime first). An explicit path that is
            // wrong is still an error, not a fall-back to a guess.
            let src = flag(args, "--python-src").map(PathBuf::from);
            Ok(Box::new(HtdemucsSeparator::discover(src).map_err(|e| e.to_string())?))
        }
        "provided" => {
            let stems = if let Some(d) = flag(args, "--stems-dir") {
                let d = PathBuf::from(d);
                StemSet {
                    vocals: d.join("vocals.wav"),
                    drums: d.join("drums.wav"),
                    bass: d.join("bass.wav"),
                    other: d.join("other.wav"),
                }
            } else {
                StemSet {
                    vocals: require_flag(args, "--vocals")?.into(),
                    drums: require_flag(args, "--drums")?.into(),
                    bass: require_flag(args, "--bass")?.into(),
                    other: require_flag(args, "--other")?.into(),
                }
            };
            Ok(Box::new(PreSeparated {
                stems,
                model: flag(args, "--separator-model").unwrap_or_else(|| "htdemucs".to_string()),
            }))
        }
        other => Err(format!(
            "unknown --separator {other} (want {})",
            selectable_separator_names()
        )),
    }
}

/// Split a comma list flag into trimmed, non-empty items.
fn split_list(v: Option<String>) -> Vec<String> {
    v.map(|s| {
        s.split(',')
            .map(|x| x.trim().to_string())
            .filter(|x| !x.is_empty())
            .collect()
    })
    .unwrap_or_default()
}

// ---------------------------------------------------------------------------
// live-proof: the I1 "it's real" checkpoint, headless.
//
// Builds a real project (one imported fixture clip), then either stops there
// (`--seed-only`, the package the app opens for the GUI proof) or opens a LIVE
// audio session and proves, through the same command bus the app + MCP agents
// use, that (1) the transport RUNS against the real engine (position advances)
// and (2) an agent's clip.move (the tool route = what the MCP server
// dispatches) is reflected in the next snapshot.
//
// AUDIO SAFETY: the live stream is SILENCE-GATED (render::engine). Nothing is
// audible unless MAJIKS_TEST_AUDIBLE=1; --seed-only never opens a device.
// ---------------------------------------------------------------------------

fn cmd_live_proof(args: &[String]) -> Result<(), String> {
    use std::time::{Duration, Instant};

    let dir: PathBuf = flag(args, "--dir")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("majiks-studio-live-proof"));
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let pkg = dir.join("LiveProof.mstudio");
    let _ = std::fs::remove_dir_all(&pkg);

    let fixtures = render::fixtures::repo_fixtures_dir();
    render::fixtures::ensure(&fixtures).map_err(|e| format!("fixtures: {e}"))?;
    let click = fixtures.join("click_120bpm_48k_stereo.wav");

    let actor = Actor {
        kind: timeline_core::envelope::ActorKind::Agent,
        name: "sarge".into(),
    };

    println!("== live-proof: build a real project through the command bus ==");
    let mut host = StudioHost::create_at(&pkg, "Live Proof").map_err(|e| e.to_string())?;
    for (name, params) in [
        ("project.setTempo", json!({ "bpm": 120 })),
        ("track.add", json!({ "trackId": "t1", "name": "Drums" })),
        (
            "import.audio",
            json!({ "sourcePath": click.display().to_string(), "targetTrackId": "t1", "startTicks": 0, "clipId": "c1" }),
        ),
    ] {
        let out = host.submit(actor.clone(), name, params).map_err(|e| format!("{name}: {e}"))?;
        println!("  {} -> {}", name, compact(&out));
    }
    host.save().map_err(|e| e.to_string())?;
    println!("  saved   : {}", pkg.display());

    if args.iter().any(|a| a == "--seed-only") {
        println!("\nlive-proof (seed-only): PASS");
        println!("  the app opens this package with --studio-project {}", pkg.display());
        return Ok(());
    }

    println!("\n== go live (SILENT unless MAJIKS_TEST_AUDIBLE=1) ==");
    let info = host.start_live().map_err(|e| e.to_string())?;
    println!("  start_live -> {}", compact(&info));

    println!("\n== transport runs against the real engine ==");
    host.submit(actor.clone(), "transport.play", json!({})).map_err(|e| e.to_string())?;
    let mut last = 0_u64;
    let deadline = Instant::now() + Duration::from_secs(2);
    while Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
        let stats = host.engine_stats();
        last = stats["positionFrame"].as_u64().unwrap_or(0);
        println!(
            "  poll: positionFrame={} callbacks={} underruns={}",
            last,
            stats["callbacks"].as_u64().unwrap_or(0),
            stats["underruns"].as_u64().unwrap_or(0)
        );
        if last > 0 {
            break;
        }
    }
    if last == 0 {
        return Err("transport did not advance against the live engine".into());
    }
    host.submit(actor.clone(), "transport.stop", json!({})).map_err(|e| e.to_string())?;
    println!("  position advanced: {} frames ({:.3}s) -> live transport confirmed", last, last as f64 / 48_000.0);

    println!("\n== an agent moves the clip (tool route = MCP dispatch) ==");
    let before = clip_start_ticks(&host.snapshot(None), "c1");
    let moved = dispatch_tool(
        &mut host,
        actor.clone(),
        "studio_clip_move",
        json!({ "clipId": "c1", "trackId": "t1", "startTicks": 3840 }),
    )
    .map_err(|e| e.to_string())?;
    println!("  studio_clip_move -> {}", compact(&moved));
    let after = clip_start_ticks(&host.snapshot(None), "c1");
    println!("  clip c1 startTicks: {:?} -> {:?} (reflected in snapshot)", before, after);
    if after != Some(3840) {
        return Err(format!("snapshot did not reflect the agent move (got {after:?})"));
    }

    let stats = host.engine_stats();
    host.stop_live();
    println!("\nlive-proof: PASS");
    println!(
        "  engine health: underruns={} allocViolations={} deadlineMisses={}",
        stats["underruns"], stats["allocViolations"], stats["deadlineMisses"]
    );
    Ok(())
}

/// Pull clip `id`'s startTicks out of a snapshot's serialized project model.
fn clip_start_ticks(snapshot: &Value, id: &str) -> Option<i64> {
    let tracks = snapshot.get("project")?.get("tracks")?.as_array()?;
    for t in tracks {
        let Some(clips) = t.get("clips").and_then(|c| c.as_array()) else {
            continue;
        };
        for c in clips {
            if c.get("id").and_then(Value::as_str) == Some(id) {
                return c.get("start_ticks").and_then(Value::as_i64);
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// interop: the self-contained acceptance run
// ---------------------------------------------------------------------------

fn cmd_interop(args: &[String]) -> Result<(), String> {
    let dir: PathBuf = flag(args, "--dir")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("majiks-studio-interop"));
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let pkg = dir.join("Interop.mstudio");
    let _ = std::fs::remove_dir_all(&pkg);

    // Real engine testdata fixtures (generated on demand, pinned by blake3).
    let fixtures = render::fixtures::repo_fixtures_dir();
    render::fixtures::ensure(&fixtures).map_err(|e| format!("fixtures: {e}"))?;
    let click = fixtures.join("click_120bpm_48k_stereo.wav");
    let tone = fixtures.join("tone_440_48k_mono.wav");

    println!("== interop: build a project hands-free through the command bus ==");
    let transcript = run_interop_script(&pkg, &click, &tone)?;
    for (name, out) in &transcript {
        println!("  {} -> {}", name, compact(out));
    }

    // Null match: the SAME logical build through the ENVELOPE route (host.submit,
    // used by ffi_studio_command + the CLI script) vs the TOOL route
    // (dispatch_tool, used by the MCP server + FFI tool calls) must bounce
    // bit-identically.
    println!("\n== null match: envelope route vs tool route ==");
    let env_pkg = dir.join("RouteEnvelope.mstudio");
    let tool_pkg = dir.join("RouteTool.mstudio");
    let _ = std::fs::remove_dir_all(&env_pkg);
    let _ = std::fs::remove_dir_all(&tool_pkg);
    let a = build_via_envelope(&env_pkg, &click, &tone)?;
    let b = build_via_tool(&tool_pkg, &click, &tone)?;
    let res = residual(&a, &b);
    println!(
        "  envelope {} frames vs tool {} frames: peak {:.1} dBFS, bit_identical={}",
        a.len(),
        b.len(),
        res.peak_dbfs,
        res.bit_identical
    );
    if !res.bit_identical {
        return Err(format!(
            "null match FAILED: the two routes diverge (peak {} dBFS)",
            res.peak_dbfs
        ));
    }

    let master = pkg.parent().unwrap().join("Interop-master.wav");
    println!("\ninterop: PASS");
    println!("  project : {}", pkg.display());
    println!("  bounce  : {}", master.display());
    Ok(())
}

/// The interop command script, applied via the envelope route, saved, bounced.
/// Returns the (name, result) transcript.
fn run_interop_script(
    pkg: &Path,
    click: &Path,
    tone: &Path,
) -> Result<Vec<(String, Value)>, String> {
    let mut host = StudioHost::create_at(pkg, "Interop Demo").map_err(|e| e.to_string())?;
    let actor = Actor {
        kind: timeline_core::envelope::ActorKind::Agent,
        name: "sarge".into(),
    };
    let mut transcript = Vec::new();
    let mut submit = |host: &mut StudioHost, name: &str, params: Value| -> Result<(), String> {
        let out = host.submit(actor.clone(), name, params).map_err(|e| format!("{name}: {e}"))?;
        transcript.push((name.to_string(), out));
        Ok(())
    };

    submit(&mut host, "project.setTempo", json!({ "bpm": 120 }))?;
    submit(&mut host, "track.add", json!({ "trackId": "t1", "name": "Drums" }))?;
    submit(&mut host, "track.add", json!({ "trackId": "t2", "name": "Bass" }))?;
    // Two audio clips from fixtures (import = host io + journaled clip.place).
    submit(
        &mut host,
        "import.audio",
        json!({ "sourcePath": click.display().to_string(), "targetTrackId": "t1", "startTicks": 0, "clipId": "c1" }),
    )?;
    submit(
        &mut host,
        "import.audio",
        json!({ "sourcePath": tone.display().to_string(), "targetTrackId": "t2", "startTicks": 7680, "clipId": "c2" }),
    )?;
    // Move one clip (bar 2 -> bar 1) and trim one clip's end by a beat.
    submit(&mut host, "clip.move", json!({ "clipId": "c2", "trackId": "t2", "startTicks": 3840 }))?;
    submit(&mut host, "clip.trim", json!({ "clipId": "c1", "edge": "end", "deltaTicks": -960 }))?;
    submit(&mut host, "project.save", json!({}))?;
    // Bounce the master through export.master (host io -> offline graph).
    let master = pkg.parent().unwrap().join("Interop-master.wav");
    submit(
        &mut host,
        "export.master",
        json!({ "outputPath": master.display().to_string(), "format": "wav" }),
    )?;
    Ok(transcript)
}

/// Build the reference project through the ENVELOPE route and return master
/// samples.
fn build_via_envelope(pkg: &Path, click: &Path, tone: &Path) -> Result<Vec<[f32; 2]>, String> {
    let mut host = StudioHost::create_at(pkg, "Route Envelope").map_err(|e| e.to_string())?;
    let actor = Actor::user("route");
    for (name, params) in interop_ops(click, tone) {
        host.submit(actor.clone(), &name, params).map_err(|e| format!("{name}: {e}"))?;
    }
    host.render_master().map_err(|e| e.to_string())
}

/// Build the SAME project through the TOOL route (dispatch_tool) and return
/// master samples.
fn build_via_tool(pkg: &Path, click: &Path, tone: &Path) -> Result<Vec<[f32; 2]>, String> {
    let mut host = StudioHost::create_at(pkg, "Route Tool").map_err(|e| e.to_string())?;
    let actor = Actor {
        kind: timeline_core::envelope::ActorKind::Agent,
        name: "route".into(),
    };
    for (name, params) in interop_ops(click, tone) {
        let tool = registry::tool_name_for(&name);
        agent_surface::dispatch_tool(&mut host, actor.clone(), &tool, params)
            .map_err(|e| format!("{tool}: {e}"))?;
    }
    host.render_master().map_err(|e| e.to_string())
}

/// The mutation ops shared by both routes (no lifecycle/export; those differ
/// per route). import.audio is a catalog command tool on the tool route.
fn interop_ops(click: &Path, tone: &Path) -> Vec<(String, Value)> {
    vec![
        ("project.setTempo".into(), json!({ "bpm": 120 })),
        ("track.add".into(), json!({ "trackId": "t1", "name": "Drums" })),
        ("track.add".into(), json!({ "trackId": "t2", "name": "Bass" })),
        (
            "import.audio".into(),
            json!({ "sourcePath": click.display().to_string(), "targetTrackId": "t1", "startTicks": 0, "clipId": "c1" }),
        ),
        (
            "import.audio".into(),
            json!({ "sourcePath": tone.display().to_string(), "targetTrackId": "t2", "startTicks": 7680, "clipId": "c2" }),
        ),
        ("clip.move".into(), json!({ "clipId": "c2", "trackId": "t2", "startTicks": 3840 })),
        ("clip.trim".into(), json!({ "clipId": "c1", "edge": "end", "deltaTicks": -960 })),
    ]
}

// ---------------------------------------------------------------------------
// provenance: the L13 boot-test + evidence generator, headless.
//
// Build a MIXED session (a generated song landed as stems + one imported clip),
// then export the master to 24-bit WAV (loudness-normalized) and AAC, each with
// the AI-disclosure provenance manifest. Prints the manifest + the loudness
// landing + the export results. Silent at any device (offline bounce only).
// ---------------------------------------------------------------------------

fn cmd_provenance(args: &[String]) -> Result<(), String> {
    use agent_surface::landing::{build_landing, InterleaveFixtureSeparator, LandingRequest};

    let dir: PathBuf = flag(args, "--dir")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("majiks-studio-provenance"));
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let loudness = flag(args, "--loudness").unwrap_or_else(|| "streaming".to_string());

    // Synthesize a deterministic beat grid for the "generated" mix (never the
    // repo fixtures: the beat grid must be clean for the boot-test).
    let mix = dir.join("mix.wav");
    render::media::write_wav_f32(&mix, &synth_song(120.0, 8), 48_000).map_err(|e| e.to_string())?;
    let tone = dir.join("vo.wav");
    render::media::write_wav_f32(&tone, &synth_tone(2.0, 220.0), 48_000).map_err(|e| e.to_string())?;

    let pkg = dir.join("Provenance.mstudio");
    let _ = std::fs::remove_dir_all(&pkg);
    let work = dir.join("work");
    let _ = std::fs::remove_dir_all(&work);

    println!("== provenance: land a generated song + an imported clip ==");
    let req = LandingRequest {
        mix_path: mix,
        prompt: "warm lofi hip hop with a rhodes and vinyl noise".into(),
        declared_bpm: Some(120.0),
        key: Some("A minor".into()),
        section_tags: vec!["Intro".into(), "Verse".into(), "Chorus".into(), "Outro".into()],
        section_times: vec![0.0, 4.0, 8.0, 12.0],
        seed: Some(4242),
        gen_model: Some("acestep-v15-turbo".into()),
        gen_device: Some("mlx".into()),
        source_kind: Some("generated".into()),
        project_name: Some("Provenance".into()),
        truth_section_bars: None,
    };
    let actor = Actor { kind: ActorKind::Agent, name: "open-in-studio".into() };
    build_landing(&pkg, &req, &InterleaveFixtureSeparator, &work, actor).map_err(|e| e.to_string())?;

    let mut host = StudioHost::open_package(&pkg).map_err(|e| e.to_string())?;
    host.submit(Actor::user("app"), "track.add", json!({ "trackId": "vo", "name": "VO (imported)" }))
        .map_err(|e| e.to_string())?;
    host.import_audio(&tone.display().to_string(), "vo", 0, Some("vo1".into()))
        .map_err(|e| e.to_string())?;
    println!("  landed 4 generated stems + 1 imported clip");

    // Master WAV (24-bit), loudness-normalized, with a sidecar manifest.
    let wav = dir.join("Provenance-master.wav");
    let wav_res = host
        .submit(
            Actor::user("app"),
            "export.master",
            json!({ "outputPath": wav.display().to_string(), "format": "wav",
                    "loudnessTarget": loudness, "includeManifest": true }),
        )
        .map_err(|e| e.to_string())?;
    println!("\n== export.master (wav, 24-bit, loudness={loudness}) ==");
    println!("{}", serde_json::to_string_pretty(&wav_res).unwrap_or_default());

    // Master AAC (AudioToolbox), club target.
    let m4a = dir.join("Provenance-master.m4a");
    match host.submit(
        Actor::user("app"),
        "export.master",
        json!({ "outputPath": m4a.display().to_string(), "format": "aac", "loudnessTarget": "club" }),
    ) {
        Ok(res) => {
            println!("\n== export.master (aac, AudioToolbox, loudness=club) ==");
            println!("{}", serde_json::to_string_pretty(&res).unwrap_or_default());
        }
        Err(e) => println!("\n== export.master (aac): {e} (AAC needs macOS AudioToolbox) =="),
    }

    // Standalone manifest (also written next to the WAV above).
    let manifest_path = dir.join("Provenance.manifest.json");
    host.submit(
        Actor::user("app"),
        "export.manifest",
        json!({ "outputPath": manifest_path.display().to_string() }),
    )
    .map_err(|e| e.to_string())?;

    let manifest = host.manifest_value();
    println!("\n== provenance manifest (AI-disclosure, EU AI Act Art. 50) ==");
    println!("{}", serde_json::to_string_pretty(&manifest).unwrap_or_default());

    println!("\nprovenance: PASS");
    println!("  package : {}", pkg.display());
    println!("  master  : {}", wav.display());
    println!("  manifest: {}", manifest_path.display());
    Ok(())
}

/// A percussive click "song" with clear downbeats (deterministic beat grid).
fn synth_song(bpm: f64, bars: u32) -> Vec<[f32; 2]> {
    use std::f64::consts::PI;
    let rate = 48_000.0;
    let beat = 60.0 / bpm;
    let total = beat * (bars * 4) as f64 + 0.5;
    let n = (total * rate) as usize;
    let mut out = vec![[0.0f32; 2]; n];
    let decay = 0.006;
    for (i, frame) in out.iter_mut().enumerate() {
        let t = i as f64 / rate;
        let beat_idx = (t / beat).floor();
        let into = t - beat_idx * beat;
        if into < decay {
            let downbeat = (beat_idx as u64).is_multiple_of(4);
            let (freq, amp) = if downbeat { (1500.0, 0.9) } else { (2000.0, 0.55) };
            let env = 1.0 - into / decay;
            let v = (amp * env * env * (2.0 * PI * freq * into).sin()) as f32;
            *frame = [v, v];
        }
    }
    out
}

fn synth_tone(secs: f64, freq: f64) -> Vec<[f32; 2]> {
    use std::f64::consts::PI;
    let rate = 48_000.0;
    let n = (secs * rate) as usize;
    (0..n)
        .map(|i| {
            let v = (0.3 * (2.0 * PI * freq * i as f64 / rate).sin()) as f32;
            [v, v]
        })
        .collect()
}

// ---------------------------------------------------------------------------
// check-stems: scan directories for fixture-era stem files
// ---------------------------------------------------------------------------

fn cmd_check_stems(args: &[String]) -> Result<(), String> {
    let dirs: Vec<PathBuf> = if args.len() <= 1 {
        vec![std::env::current_dir().map_err(|e| e.to_string())?]
    } else {
        args[1..].iter().map(PathBuf::from).collect()
    };

    let mut found_any = false;
    let mut fixture_count = 0u32;
    let mut real_count = 0u32;

    for dir in &dirs {
        if !dir.is_dir() {
            eprintln!("  skipping (not a directory): {}", dir.display());
            continue;
        }
        visit_stems(dir, &mut found_any, &mut fixture_count, &mut real_count)?;
    }

    if !found_any {
        println!("no stem files found in the scanned paths");
        return Ok(());
    }

    println!();
    println!("== summary: {real_count} usable stems, {fixture_count} fixture-era stems");
    if fixture_count > 0 {
        eprintln!(
            "FAIL: {fixture_count} fixture-era stem(s) detected. Re-separate or remove them."
        );
        return Err(format!("{fixture_count} fixture-era stem(s) found"));
    }
    Ok(())
}

fn visit_stems(
    dir: &Path,
    found_any: &mut bool,
    fixture_count: &mut u32,
    real_count: &mut u32,
) -> Result<(), String> {
    let entries = std::fs::read_dir(dir).map_err(|e| format!("read_dir {}: {e}", dir.display()))?;
    for entry in entries {
        let entry = entry.map_err(|e| format!("entry {}: {e}", dir.display()))?;
        let path = entry.path();
        if path.is_dir() {
            visit_stems(&path, found_any, fixture_count, real_count)?;
        } else if path.extension().map_or(false, |ext| ext == "wav" || ext == "WAV") {
            *found_any = true;
                match stem_usability::measure_wav(&path) {
                Ok(usability) => {
                    if usability.verdict().is_ok() {
                        *real_count += 1;
                    } else {
                        *fixture_count += 1;
                    }
                    println!(
                        "  {}: zero={:.4}% hbf={:.4}%",
                        path.display(),
                        usability.zero_ratio * 100.0,
                        usability.high_band_fraction * 100.0
                    );
                }
                Err(e) => {
                    eprintln!("  {}: load error: {e}", path.display());
                }
            }
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// tools: emit / regen the generated tool manifest
// ---------------------------------------------------------------------------

fn cmd_tools(args: &[String]) -> Result<(), String> {
    let pretty = registry::tools_manifest_pretty();
    match flag(args, "--write") {
        Some(path) => {
            std::fs::write(&path, &pretty).map_err(|e| format!("write {path}: {e}"))?;
            println!("wrote {} ({} tools)", path, registry::tool_defs().len());
        }
        None => print!("{pretty}"),
    }
    Ok(())
}

fn compact(v: &Value) -> String {
    serde_json::to_string(v).unwrap_or_else(|_| "{}".to_string())
}
