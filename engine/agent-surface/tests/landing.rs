//! L8 acceptance, headless: a finished song becomes a bar-aligned, stem-split,
//! lineage-carrying `.mstudio` session, the placed stems null against the mix,
//! sections land on musical truth, and everything survives save + reopen.
//!
//! Two different separators, on purpose:
//!
//!   * the PLACEMENT tests use `InterleaveFixtureSeparator` directly from Rust.
//!     Its four outputs sum back to the mix bit-exactly with no torch and no
//!     model download, which is exactly what a bar-alignment + null-test proof
//!     needs -- and its individual stems are UNUSABLE, which is why it is not
//!     reachable from the CLI or MCP and why `stem_usability_contract.rs`
//!     exists to say so out loud.
//!   * anything that asserts the SHAPE OF THE PRODUCT -- the app path, the
//!     agent's MCP call -- uses four genuinely distinct synthesized parts via
//!     `separator=provided`. Validating a product path with fixture stems is
//!     how the fixture became the default in the first place.

use std::f32::consts::PI;
use std::path::{Path, PathBuf};

use agent_surface::landing::{build_landing, InterleaveFixtureSeparator, BAR_TICKS};
use agent_surface::{dispatch_tool, LandingRequest, StudioHost};
use render::media::write_wav_f32;
use serde_json::{json, Value};
use timeline_core::envelope::ActorKind;
use timeline_core::Actor;

const RATE: u32 = 48_000;

/// A short, tempo-trackable "song": the proven click waveform from
/// `render::fixtures` (the golden tempo tests confirm it tracks its BPM),
/// emphasized on the downbeat (every 4th beat) so the downbeat phase is
/// recoverable, at an exact `bpm`.
fn synth_song(bpm: f64, bars: u32) -> Vec<[f32; 2]> {
    let beat = 60.0 / bpm;
    let total = beat * (bars * 4) as f64 + 0.5;
    let n = (total * RATE as f64) as usize;
    let mut out = vec![[0.0f32; 2]; n];
    let decay = 0.006;
    for i in 0..n {
        let t = i as f64 / RATE as f64;
        let beat_idx = (t / beat).floor();
        let into = t - beat_idx * beat;
        let v = if into < decay {
            let downbeat = (beat_idx as u64) % 4 == 0;
            let (freq, amp) = if downbeat { (1500.0, 0.9) } else { (2000.0, 0.55) };
            let env = 1.0 - into / decay;
            (amp * env * env * (2.0 * PI as f64 * freq * into).sin()) as f32
        } else {
            0.0
        };
        out[i] = [v, v];
    }
    out
}

/// Four spectrally distinct parts and their EXACT sum: what a working
/// separator hands back. The drums part is the proven click (so the mix is
/// still tempo-trackable); the other three are sustained tones in their own
/// registers, so each part is listenable on its own.
fn write_real_parts(dir: &Path, bpm: f64, bars: u32) -> (PathBuf, [PathBuf; 4]) {
    let mut drums = synth_song(bpm, bars);
    let n = drums.len();
    // Room tone under the clicks. `synth_song` is exactly 0.0 between hits, and
    // a stem that is 99% exact silence fails the usability contract for a
    // reason that has nothing to do with separation -- a real drum stem always
    // has a noise floor. Deterministic LCG so the fixture stays byte-stable.
    let mut rng = 0x0DDB_A11Eu32;
    let mut lp = 0.0f32;
    for f in drums.iter_mut() {
        rng = rng.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        let white = ((rng >> 8) as f32 / 8_388_608.0) - 1.0;
        lp += 0.12 * (white - lp); // gentle low-pass: room tone, not hiss
        f[0] += 0.004 * lp;
        f[1] += 0.004 * lp;
    }
    let mut parts = [
        vec![[0.0f32; 2]; n],
        drums,
        vec![[0.0f32; 2]; n],
        vec![[0.0f32; 2]; n],
    ];
    for i in 0..n {
        let t = i as f64 / RATE as f64;
        let hz = |f: f64, a: f64| (a * (2.0 * PI as f64 * f * t).sin()) as f32;
        parts[0][i] = [hz(330.0, 0.30), hz(330.0, 0.30)]; // vocals
        parts[2][i] = [hz(82.4, 0.35), hz(82.4, 0.35)]; // bass
        parts[3][i] = [hz(523.25, 0.18), hz(523.25, 0.18)]; // other
    }
    // Keep the sum inside full scale by scaling ALL four equally, so the mix
    // stays the exact sum of the parts (the null test depends on that).
    let mut peak = 0.0f32;
    for i in 0..n {
        for ch in 0..2 {
            peak = peak.max(parts.iter().map(|p| p[i][ch]).sum::<f32>().abs());
        }
    }
    if peak > 0.99 {
        let g = 0.99 / peak;
        for p in parts.iter_mut() {
            for f in p.iter_mut() {
                f[0] *= g;
                f[1] *= g;
            }
        }
    }
    let mut mix = vec![[0.0f32; 2]; n];
    for i in 0..n {
        for p in parts.iter() {
            mix[i][0] += p[i][0];
            mix[i][1] += p[i][1];
        }
    }
    let mix_path = dir.join("parts_mix.wav");
    write_wav_f32(&mix_path, &mix, RATE).unwrap();
    let names = ["vocals", "drums", "bass", "other"];
    let paths: Vec<PathBuf> = names
        .iter()
        .enumerate()
        .map(|(k, name)| {
            let p = dir.join(format!("part_{name}.wav"));
            write_wav_f32(&p, &parts[k], RATE).unwrap();
            p
        })
        .collect();
    (
        mix_path,
        [paths[0].clone(), paths[1].clone(), paths[2].clone(), paths[3].clone()],
    )
}

fn clip_start_and_offset(project: &Value, clip_id: &str) -> Option<(i64, i64)> {
    for t in project["tracks"].as_array()? {
        for c in t["clips"].as_array()? {
            if c["id"].as_str() == Some(clip_id) {
                return Some((c["start_ticks"].as_i64()?, c["source_offset_ticks"].as_i64()?));
            }
        }
    }
    None
}

/// 1-minute load average, for deciding whether a timing bound can measure
/// anything at all. Reading `/proc`-style APIs is not portable, so this shells
/// the same number `uptime` reports; a parse failure reads as "not saturated"
/// so the bound still runs rather than silently disappearing.
fn loadavg_1m() -> f64 {
    std::process::Command::new("sysctl")
        .args(["-n", "vm.loadavg"])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| {
            s.trim()
                .trim_start_matches('{')
                .split_whitespace()
                .next()
                .and_then(|v| v.parse::<f64>().ok())
        })
        .unwrap_or(0.0)
}

#[test]
fn song_lands_as_bar_aligned_stem_session_that_nulls_and_carries_lineage() {
    let dir = tempfile::tempdir().unwrap();
    let mix = dir.path().join("mysong.wav");
    // 120 bpm, 8 bars (16 s): bar = 2 s.
    write_wav_f32(&mix, &synth_song(120.0, 8), RATE).unwrap();

    let req = LandingRequest {
        mix_path: mix.clone(),
        prompt: "warm lo-fi beat with a soft kick and a low bass drone".into(),
        // A wrong declared BPM: the grid must NOT use this (P0-A binding fact).
        declared_bpm: Some(126.0),
        section_tags: vec!["Intro".into(), "Verse".into(), "Chorus".into(), "Outro".into()],
        // True section starts at bars 0, 2, 4, 6 -> times 0, 4, 8, 12 s at 120.
        section_times: vec![0.0, 4.0, 8.0, 12.0],
        truth_section_bars: Some(vec![0, 2, 4, 6]),
        seed: Some(4242),
        gen_model: Some("acestep-v15-turbo".into()),
        gen_device: Some("mlx".into()),
        source_kind: Some("generated".into()),
        ..Default::default()
    };

    let pkg = dir.path().join("MySong.mstudio");
    let work = dir.path().join("work");
    // The fixture is the right separator HERE: this test is about placement,
    // bar alignment and the null test, and the fixture's bit-exact sum is the
    // only way to prove those headlessly. It is not the right separator for a
    // listener, which is what `stem_usability_contract.rs` asserts.
    let report = build_landing(&pkg, &req, &InterleaveFixtureSeparator, &work, Actor::user("test"))
        .expect("landing builds");

    // --- Tempo is MEASURED, not the (wrong) declared BPM ---
    assert!(
        (report.measured_bpm - 120.0).abs() < 2.0,
        "measured bpm should track ~120, got {}",
        report.measured_bpm
    );
    assert!(
        (report.measured_bpm - 126.0).abs() > 2.0,
        "grid must not be the declared 126 bpm"
    );
    assert!(report.declared_vs_measured_pct.is_some());

    // --- Four stem tracks, colored, each with one clip ---
    assert_eq!(report.track_ids, vec!["trk_vocals", "trk_drums", "trk_bass", "trk_other"]);
    assert_eq!(report.stem_asset_hashes.len(), 4);

    // --- Bar alignment: every stem clip at the SAME lead-in, offset 0 (so they
    // stay sample-locked and their sum reproduces the mix), and the lead-in
    // lands the first downbeat on a bar line ---
    let host = StudioHost::open_package(&pkg).expect("reopen");
    let snap = host.snapshot(None);
    let project = &snap["project"];
    for stem in ["vocals", "drums", "bass", "other"] {
        let (start, offset) = clip_start_and_offset(project, &format!("clip_{stem}")).unwrap();
        assert_eq!(start, report.lead_in_ticks as i64, "{stem} start == lead-in");
        assert_eq!(offset, 0, "{stem} offset 0 (no trim; audio preserved)");
    }

    // --- Round-trip: tracks, clips, sections all persisted ---
    assert_eq!(project["trackCount"].as_i64(), Some(4));
    assert_eq!(project["clipCount"].as_i64(), Some(4));
    assert_eq!(
        project["sections"].as_array().map(|s| s.len()),
        Some(report.sections.len())
    );
    assert!(!report.sections.is_empty());

    // --- Null test: the fixture's sum is bit-exact, so both nulls floor deep.
    // Note how strong this looks while every stem is 75% silence: a sum test
    // cannot see the defect, which is the whole reason for the usability
    // contract. The report now carries that second number too. ---
    assert!(
        report.null_pure_peak_dbfs < -80.0,
        "pure stem-sum should reproduce the mix (got {} dBFS)",
        report.null_pure_peak_dbfs
    );
    assert!(
        report.null_render_peak_dbfs < -60.0,
        "rendered stem session should reproduce the mix (got {} dBFS)",
        report.null_render_peak_dbfs
    );

    // --- Sections within one bar of musical truth ---
    let (within, total) = report.section_within_one_bar.unwrap();
    assert_eq!(within, total, "all {total} sections within one bar; got {within}");
    assert!(report.sections.iter().all(|(_, t)| t % BAR_TICKS == 0), "sections on bar lines");

    // --- Lineage on every clip: the generation prompt + model/seed/engine ---
    for stem in ["vocals", "drums", "bass", "other"] {
        let lineage = host.lineage(&format!("clip_{stem}")).expect("lineage");
        let names: Vec<&str> = lineage["chain"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|e| e["name"].as_str())
            .collect();
        assert!(names.contains(&"clip.place"), "{stem}: clip.place in lineage");
        assert!(names.contains(&"gen.song"), "{stem}: gen.song (prompt) in lineage: {names:?}");
        assert!(names.contains(&"gen.landed"), "{stem}: gen.landed (model/seed) in lineage");

        // The prompt is recorded.
        let prompt_seen = lineage["chain"].as_array().unwrap().iter().any(|e| {
            e["name"] == "gen.song"
                && e["params"]["request"]["caption"].as_str() == Some(req.prompt.as_str())
        });
        assert!(prompt_seen, "{stem}: prompt recorded in gen.song");
    }
    // The gen.landed carries model/seed/device and all five content hashes.
    let landed = host
        .journal_page(None, 500)["entries"]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["name"] == "gen.landed")
        .cloned()
        .unwrap();
    assert_eq!(landed["params"]["engineIdentity"]["model"], "acestep-v15-turbo");
    assert_eq!(landed["params"]["engineIdentity"]["seed"], 4242);
    assert_eq!(landed["params"]["engineIdentity"]["device"], "mlx");
    for k in ["mix", "vocals", "drums", "bass", "other"] {
        assert!(landed["params"]["assetHashes"][k].is_string(), "assetHashes.{k}");
    }

    // --- Acceptance timing bound ---
    //
    // ⚠️ This is a real product claim ("song to session in under a minute"), so
    // it is NOT weakened. It is ISOLATED: it measures nothing on a machine that
    // is already saturated, and a bound that cannot measure should not fail.
    //
    // Four independent lanes hit this red while doing unrelated work — at load
    // 29–85 on a 12-core box running several test binaries at once — and each
    // one had to rediscover from scratch that the machine, not the pipeline,
    // was the variable. One measured 85.67 s under load and 38.87 s on the same
    // tree when quiet. That is not a signal, it is noise wearing a signal's
    // clothes, and it cost more hours than the regression it exists to catch.
    //
    // So: the assertion runs when the machine can actually be measured, and
    // otherwise says plainly that it did not measure. `MAJIKS_PERF=1` forces it
    // on regardless, for a deliberate acceptance run on a quiet box.
    let cores = std::thread::available_parallelism().map_or(8.0, |n| n.get() as f64);
    let load1 = loadavg_1m();
    let saturated = load1 > cores * 1.5;
    if std::env::var("MAJIKS_PERF").is_ok() || !saturated {
        assert!(
            report.total_seconds < 60.0,
            "song-to-session under 60 s (got {:.2}s, load {:.1} on {:.0} cores)",
            report.total_seconds,
            load1,
            cores
        );
    } else {
        eprintln!(
            "landing timing bound NOT MEASURED: load {load1:.1} on {cores:.0} cores \
             (took {:.2}s). Re-run quiet, or set MAJIKS_PERF=1 to force.",
            report.total_seconds
        );
    }

    // The report SAYS the stems are unusable, in numbers, rather than leaving
    // it to be discovered by ear. Hardcoded expectations: 3 of every 4 frames
    // are zeroed, and a quarter of the energy folds above 18 kHz.
    for stem in ["vocals", "drums", "bass", "other"] {
        let u = report.stem_usability.get(stem).expect("per-stem usability");
        assert!(
            u.zero_ratio > 0.70,
            "{stem}: expected ~75% exact zeros from the fixture, got {:.4}%",
            u.zero_ratio * 100.0
        );
        assert!(
            u.verdict().is_err(),
            "{stem}: the fixture's stems must not read as usable"
        );
    }

    // The reopened session bounces (it is playable).
    let out_wav = dir.path().join("bounce.wav");
    let bounce = host.bounce_master(&out_wav).expect("bounce");
    assert!(bounce.frames > 0);
}

#[test]
fn pre_separated_stems_land_without_a_separator_run() {
    // The app path: Swift asks the Python backend to separate, then hands the
    // engine four stem paths. Modelled with four REAL parts -- this used to
    // feed the interleave fixture's output through `provided`, which meant the
    // one test standing in for the shipped app was itself asserting on
    // unusable stems.
    use agent_surface::landing::{PreSeparated, StemSet};

    let dir = tempfile::tempdir().unwrap();
    let (mix, parts) = write_real_parts(dir.path(), 100.0, 4);
    let stems = StemSet {
        vocals: parts[0].clone(),
        drums: parts[1].clone(),
        bass: parts[2].clone(),
        other: parts[3].clone(),
    };
    let sep = PreSeparated { stems, model: "htdemucs".into() };

    let req = LandingRequest {
        mix_path: mix,
        prompt: "test".into(),
        ..Default::default()
    };
    let pkg = dir.path().join("S.mstudio");
    let report = build_landing(&pkg, &req, &sep, &dir.path().join("w2"), Actor::user("app"))
        .expect("landing");
    assert_eq!(report.separator_model, "htdemucs");
    assert_eq!(report.track_ids.len(), 4);
    // Real parts pass the usability contract the fixture fails.
    for stem in ["vocals", "drums", "bass", "other"] {
        let u = report.stem_usability.get(stem).expect("per-stem usability");
        u.verdict().unwrap_or_else(|why| panic!("{stem} must be usable alone: {why}"));
        assert!(u.zero_ratio < 0.02, "{stem} zeros {:.4}%", u.zero_ratio * 100.0);
    }
    // No tags, no times -> 8-bar fallback sections exist.
    assert!(!report.sections.is_empty());
    assert!(Path::new(&pkg).join("project.json").exists());
}

#[test]
fn agent_opens_a_song_in_the_studio_via_the_mcp_tool() {
    // Agent parity: `studio_open_in_studio` builds the session AND makes it the
    // engine's active project, so the same host now snapshots the landed song.
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("data");
    std::fs::create_dir_all(&data).unwrap();
    // Four real parts fed as `provided`: the agent path must be proved with
    // stems a listener could actually use. `bandsplit` used to be named here,
    // and it is now refused outright.
    let (mix, parts) = write_real_parts(dir.path(), 120.0, 6);

    let mut host = StudioHost::with_data_dir(&data).expect("host");
    let actor = Actor { kind: ActorKind::Agent, name: "sarge".into() };
    let out = dispatch_tool(
        &mut host,
        actor,
        "studio_open_in_studio",
        json!({
            "sourceAudioRef": mix.to_string_lossy(),
            "prompt": "an agent-built lo-fi loop",
            "separator": "provided",
            "stems": {
                "vocals": parts[0].to_string_lossy(),
                "drums": parts[1].to_string_lossy(),
                "bass": parts[2].to_string_lossy(),
                "other": parts[3].to_string_lossy()
            },
            "projectName": "AgentSong",
            "sectionTags": ["Intro", "Verse"],
            "sectionTimes": [0.0, 4.0]
        }),
    )
    .expect("open_in_studio tool");

    assert_eq!(out["ok"], true);
    assert_eq!(out["trackIds"].as_array().unwrap().len(), 4);
    // The host swapped to the landed project: its snapshot is the new session.
    let snap = host.snapshot(None);
    assert_eq!(snap["project"]["trackCount"].as_i64(), Some(4));
    assert_eq!(snap["project"]["name"], "AgentSong");
    assert!(snap["project"]["sections"].as_array().unwrap().len() >= 2);
    // Lineage survived the open (journal replay), so the agent's session is
    // provenance-complete.
    let lineage = host.lineage("clip_vocals").expect("lineage");
    let names: Vec<&str> = lineage["chain"].as_array().unwrap().iter()
        .filter_map(|e| e["name"].as_str()).collect();
    assert!(names.contains(&"gen.song"), "prompt lineage after open: {names:?}");
}
