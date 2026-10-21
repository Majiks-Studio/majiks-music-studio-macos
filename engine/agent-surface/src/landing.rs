//! `landing`: the "Open in Studio" bridge (lane L8).
//!
//! Turns a finished song (a mix WAV + its generation prompt/params) into an
//! editable, bar-aligned, stem-split `.mstudio` session on the timeline. This
//! is the single most important onboarding moment in the product (01-DESIGN
//! 3.1): a user's own song is already sitting there as an arrangement.
//!
//! The pipeline, every step through the SAME command bus the UI / MCP / CLI
//! use (so undo + provenance + parity are identical whoever drives):
//!   1. ANALYZE the mix with `engine/media` for a BEAT-TRACKED tempo + downbeat
//!      grid. Binding P0-A fact: generated audio drifts 1.2-2.9% off its
//!      declared BPM, so the grid MUST be measured from the audio, never the
//!      tag (`media::tempo`). Declared BPM is passed only as a tie-break hint.
//!   2. SEPARATE the mix into vocals/drums/bass/other (a `Separator`; the
//!      shipped one is htdemucs via the existing Python backend).
//!   3. BUILD the project: measured tempo, 4 stem tracks (suite stem colors),
//!      each stem placed BAR-ALIGNED to the beat-tracked grid (never the
//!      declared BPM), a section map from the lyric section tags refined by
//!      downbeats (8-bar fallback), and lineage journaled for every clip.
//!   4. NULL-TEST: the placed stems, summed through the render graph, reproduce
//!      the source within the separation model's tolerance.
//!
//! Bar-alignment decision (recorded here because 02-ARCH leaves the phase to
//! the landing lane): the project tempo is the MEASURED bpm, so the bar grid
//! stays locked to the music for the whole song (a 2% tempo error compounds to
//! seconds of drift by bar 60 -- that is the failure this guards). All four
//! stems are placed at ONE shared start tick with source offset 0, so they stay
//! sample-locked to each other and their sum reproduces the mix (the null test
//! stays valid). The shared start is a lead-in that lands the audio's first
//! tracked downbeat exactly on a project bar line, adding at most one bar of
//! silence and NEVER trimming audio. (v1 `TempoMap` has no phase anchor; a
//! project phase anchor would remove even that lead-in -- proposal on record.)

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

use serde_json::{json, Map, Value};

use render::media::{load_wav_stereo_48k, write_wav_f32};
use timeline_core::tempo::PPQ;
use timeline_core::Actor;

use crate::error::StudioError;
use crate::host::StudioHost;
use crate::stem_usability::{self, StemUsability};
use crate::ulid;

/// The four stems htdemucs produces, in a fixed order (vocals first: it is the
/// track a user looks at first, and gen.song's trackId points at it).
pub const STEM_NAMES: [&str; 4] = ["vocals", "drums", "bass", "other"];

/// Ticks in one 4/4 bar (fixed 4/4 in v1, matching timeline-core + media).
pub const BAR_TICKS: u64 = 4 * PPQ;

/// Suite-wide stem colors (01-DESIGN section 5; shared with the Majik's DJ
/// stems lane so both apps read the same). These four are the only saturated
/// constants on the canvas.
pub fn stem_color(stem: &str) -> &'static str {
    match stem {
        "vocals" => "#FF5FA2",
        "drums" => "#FFB020",
        "bass" => "#8B5CF6",
        "other" => "#2BD9C7",
        _ => "#8A93A6", // neutral slate (imported/unknown)
    }
}

/// Display name for a stem track ("vocals" -> "Vocals").
fn stem_title(stem: &str) -> String {
    let mut chars = stem.chars();
    match chars.next() {
        Some(c) => c.to_uppercase().collect::<String>() + chars.as_str(),
        None => stem.to_string(),
    }
}

// ---------------------------------------------------------------------------
// Separation
// ---------------------------------------------------------------------------

/// The four separated stem files (WAV), keyed by the fixed stem names.
#[derive(Debug, Clone)]
pub struct StemSet {
    pub vocals: PathBuf,
    pub drums: PathBuf,
    pub bass: PathBuf,
    pub other: PathBuf,
}

impl StemSet {
    pub fn path(&self, stem: &str) -> Option<&Path> {
        match stem {
            "vocals" => Some(&self.vocals),
            "drums" => Some(&self.drums),
            "bass" => Some(&self.bass),
            "other" => Some(&self.other),
            _ => None,
        }
    }

    /// (stem name, path) in the fixed `STEM_NAMES` order.
    pub fn iter(&self) -> impl Iterator<Item = (&'static str, &Path)> {
        STEM_NAMES
            .iter()
            .map(move |&n| (n, self.path(n).expect("stem name is one of STEM_NAMES")))
    }
}

/// A source of stems for a mix. The shipped separator is htdemucs (the existing
/// Python backend); `PreSeparated` wraps stems the caller already has.
///
/// A `Separator` implementation is a promise that each stem it returns is
/// USABLE ALONE -- see `crate::stem_usability` and the contract test every
/// registered separator runs through. The one implementation that cannot keep
/// that promise (`InterleaveFixtureSeparator`) says so in its name, is exempted
/// from the contract BY NAME, and cannot be reached from the CLI or MCP.
pub trait Separator {
    /// Separate `mix` into four stem WAVs, writing under `work_dir`.
    fn separate(&self, mix: &Path, work_dir: &Path) -> Result<StemSet, StudioError>;

    /// The model name recorded in lineage (`gen.landed` sourceCommand
    /// gen.separate), e.g. `"htdemucs"`.
    fn model_name(&self) -> String;
}

// ---------------------------------------------------------------------------
// The separator registry
// ---------------------------------------------------------------------------

/// What a registered separator IS. The distinction exists because the product
/// shipped a fixture as the default separator and nothing in the type system,
/// the name, the CLI help or the tool schema said it was one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SeparatorKind {
    /// Produces real, full-rate, spectrally distinct parts. Must pass the stem
    /// usability contract.
    Real,
    /// A deterministic stand-in for tests. Its individual stems are UNUSABLE;
    /// it exists only because its four outputs sum back to the mix bit-exactly,
    /// which is what the placement / alignment / null-test path needs.
    Fixture,
}

/// One entry in the separator registry: everything a caller (or a test) needs
/// to know about a separator without constructing it.
#[derive(Debug, Clone, Copy)]
pub struct SeparatorSpec {
    /// The name callers use (`--separator NAME`, `"separator": "NAME"`).
    pub name: &'static str,
    pub kind: SeparatorKind,
    /// Whether an ordinary CLI / MCP / UI caller can select it. A `Fixture` is
    /// never selectable: naming one is refused loudly rather than honoured.
    pub selectable: bool,
    /// One line, used in the CLI usage text and the tool schema description.
    pub summary: &'static str,
}

/// The name of the fixture, in ONE place, so the refusal, the contract test's
/// by-name exemption, and the lineage string cannot drift apart.
pub const INTERLEAVE_FIXTURE_NAME: &str = "interleave-fixture";

/// Every separator this build knows about. The contract test in
/// `tests/stem_usability_contract.rs` iterates this list, so a separator added
/// later is held to the usability contract ON ARRIVAL -- it has to be exempted
/// deliberately (by declaring `SeparatorKind::Fixture`) rather than by being
/// forgotten.
pub const SEPARATOR_REGISTRY: &[SeparatorSpec] = &[
    SeparatorSpec {
        name: "htdemucs",
        kind: SeparatorKind::Real,
        selectable: true,
        summary: "the shipped separator (demucs 4-stem, via the bundled Python runtime)",
    },
    SeparatorSpec {
        name: "provided",
        kind: SeparatorKind::Real,
        selectable: true,
        summary: "use four stem files the caller already separated",
    },
    SeparatorSpec {
        name: INTERLEAVE_FIXTURE_NAME,
        kind: SeparatorKind::Fixture,
        selectable: false,
        summary: "TEST FIXTURE -- produces unusable individual stems; not selectable",
    },
];

/// The default separator when a caller names none. It is a REAL one on purpose:
/// the defect this whole module was rewritten for is that the default was a
/// fixture, so a caller who said nothing silently got garbage.
pub const DEFAULT_SEPARATOR: &str = "htdemucs";

/// The comma list of selectable names, for usage text and error messages.
pub fn selectable_separator_names() -> String {
    SEPARATOR_REGISTRY
        .iter()
        .filter(|s| s.selectable)
        .map(|s| s.name)
        .collect::<Vec<_>>()
        .join("|")
}

/// The loud refusal a caller gets for naming the fixture. It names what would
/// happen to the audio, in numbers, because "unknown separator" would just make
/// the next caller try harder to spell it.
pub fn fixture_refusal(name: &str) -> String {
    format!(
        "'{name}' is a TEST FIXTURE, not a separator, and cannot be selected here.\n\
         It routes every 4th sample to a different stem and zeroes the other three, so each \
         'stem' is 75% exact silence and is the whole song decimated to 12 kHz. The four sum \
         back to the mix bit-exactly -- which is the only thing it is for -- but SOLOED, each \
         one is aliased garbage that screeches. Shipping its output to a listener is the \
         defect this refusal exists to prevent.\n\
         Use --separator {} instead. The fixture is reachable from Rust tests only \
         (agent_surface::landing::InterleaveFixtureSeparator).",
        selectable_separator_names()
    )
}

/// Wraps stems already separated by the caller (the app path: Swift asks the
/// Python backend to separate, then hands the four paths to the engine).
pub struct PreSeparated {
    pub stems: StemSet,
    pub model: String,
}

impl Separator for PreSeparated {
    fn separate(&self, _mix: &Path, _work_dir: &Path) -> Result<StemSet, StudioError> {
        for (name, p) in self.stems.iter() {
            if !p.exists() {
                return Err(StudioError::audio(format!(
                    "pre-separated {name} stem not found: {}",
                    p.display()
                )));
            }
        }
        Ok(self.stems.clone())
    }
    fn model_name(&self) -> String {
        self.model.clone()
    }
}

/// htdemucs via the existing Python backend. Shells out to a thin entry
/// (`src/python/majik_backend/separate_cli.py`) that calls the shipped
/// `export_stems` (htdemucs 4-stem) and prints the four paths as JSON, so the
/// engine reuses the one separation path the whole app already uses.
///
/// The interpreter is DISCOVERED, not assumed. The old code defaulted to
/// `python3` on PATH, which for a GUI-launched app is `/usr/bin/python3` -- an
/// interpreter with no torch, no demucs and nothing else the app ships. The
/// app already carries a full Python.framework (torch, numpy, librosa,
/// soundfile) at `Contents/Frameworks/Python.framework`, so that is what the
/// engine reaches for first: no second runtime, no managed venv duplicating a
/// 2 GB torch, and the separation runs against the same libraries the rest of
/// the backend was tested with.
pub struct HtdemucsSeparator {
    /// The python interpreter, already discovered.
    pub python: String,
    /// The dir holding `majik_backend` (on PYTHONPATH so it imports).
    pub python_src: PathBuf,
}

/// Everything an interpreter must be able to import before it can separate, IN
/// ORDER.
///
/// numpy comes FIRST and is checked separately on purpose: `pip install demucs`
/// does not pull numpy, but demucs imports it at module load. Probing demucs
/// first in that state fails with `ModuleNotFoundError: numpy` and would have
/// this code tell the user to install demucs -- advice that cannot work. torch
/// is not probed on its own: demucs imports it, so a missing torch surfaces
/// through the demucs probe with the interpreter's own message attached.
const SEPARATION_IMPORTS: [(&str, &str); 2] = [("numpy", "numpy"), ("demucs", "demucs")];

impl HtdemucsSeparator {
    /// The ONE constructor: discover both the backend dir and the interpreter,
    /// and refuse with a fix-it message if either is missing or cannot
    /// separate. `hint` is an explicit `--python-src` / `pythonSrc` when the
    /// caller gave one; an explicit hint that is wrong is an ERROR, never a
    /// silent fall-through to a guess (a caller who named a path wants that
    /// path).
    pub fn discover(hint: Option<PathBuf>) -> Result<Self, StudioError> {
        let python_src = discover_python_src(hint)?;
        let s = Self { python: discover_python(&python_src), python_src };
        s.preflight()?;
        Ok(s)
    }

    /// Prove the chosen interpreter can actually separate BEFORE any audio is
    /// touched, and say exactly how to fix it when it cannot. This is the whole
    /// point of the rewrite: the alternative -- quietly substituting the
    /// fixture -- is what shipped broken stems to a listener.
    pub fn preflight(&self) -> Result<(), StudioError> {
        for (module, package) in SEPARATION_IMPORTS {
            let out = Command::new(&self.python)
                .arg("-c")
                .arg(format!("import {module}"))
                .env("PYTHONPATH", &self.python_src)
                .output()
                .map_err(|e| {
                    StudioError::audio(format!(
                        "stem separation is unavailable: the Python interpreter `{}` would not \
                         launch ({e}).\n\
                         Fix: set MAJIKS_PYTHON to an interpreter that has demucs installed.",
                        self.python
                    ))
                })?;
            if !out.status.success() {
                // Carry the interpreter's OWN last line: when demucs is present
                // but torch is not, that line is the only thing that says so.
                let detail = String::from_utf8_lossy(&out.stderr)
                    .lines()
                    .rev()
                    .find(|l| !l.trim().is_empty())
                    .unwrap_or("(no detail)")
                    .trim()
                    .to_string();
                return Err(StudioError::audio(format!(
                    "stem separation is unavailable: `{}` cannot import {module} ({detail}).\n\
                     Fix: {} -m pip install {package}\n\
                     (demucs does NOT install numpy as a dependency but imports it at load, so \
                     install numpy too if it is missing.)\n\
                     No fallback was used: the unusable-stem stand-in exists for tests only, and \
                     landing refuses rather than hand you stems that screech when soloed.",
                    self.python, self.python
                )));
            }
        }
        Ok(())
    }
}

/// Pick the interpreter: an explicit override, else the runtime the app ships
/// (found relative to `python_src`, which in the bundle is
/// `Contents/Resources/python` and the framework is two levels up), else
/// whatever `python3` PATH offers.
fn discover_python(python_src: &Path) -> String {
    discover_python_with(python_src, std::env::var("MAJIKS_PYTHON").ok())
}

/// The same pick with the override PASSED IN rather than read from the process
/// environment, so the order can be asserted without two tests racing over one
/// global env var.
fn discover_python_with(python_src: &Path, override_path: Option<String>) -> String {
    if let Some(p) = override_path {
        if !p.trim().is_empty() {
            return p;
        }
    }
    // .../Contents/Resources/python -> .../Contents/Frameworks/Python.framework
    if let Some(contents) = python_src.parent().and_then(Path::parent) {
        let framework = contents.join("Frameworks/Python.framework/Versions");
        if let Ok(versions) = std::fs::read_dir(&framework) {
            // Take the highest version dir that actually carries a python3.N.
            let mut found: Option<PathBuf> = None;
            for entry in versions.flatten() {
                let v = entry.file_name();
                let v = v.to_string_lossy();
                if v == "Current" {
                    continue;
                }
                let bin = entry.path().join(format!("bin/python{v}"));
                if bin.is_file() && found.as_ref().map(|f| bin > *f).unwrap_or(true) {
                    found = Some(bin);
                }
            }
            if let Some(bin) = found {
                return bin.to_string_lossy().to_string();
            }
        }
    }
    "python3".to_string()
}

/// Find the dir that holds `majik_backend`: the caller's hint, then the env
/// override, then the app bundle relative to this executable, then a dev
/// checkout relative to the working dir. Mirrors `RealStudioEngine
/// .resolvePythonSrc()` on the Swift side so both find the same tree.
fn discover_python_src(hint: Option<PathBuf>) -> Result<PathBuf, StudioError> {
    let marker = "majik_backend/rpc_server.py";
    let ok = |p: PathBuf| -> Option<PathBuf> { p.join(marker).is_file().then_some(p) };

    // An explicit hint is honoured or refused; it is never quietly replaced by
    // a search result, because then a typo'd --python-src would look like it
    // worked and silently separate with some other tree.
    if let Some(h) = hint {
        return ok(h.clone()).ok_or_else(|| {
            StudioError::audio(format!(
                "stem separation is unavailable: no `majik_backend` under the python source dir \
                 you named ({}).\n\
                 Fix: point --python-src / MAJIKS_PYTHON_SRC at the repo's `src/python` (in the \
                 shipped app: `Majiks Music Studio.app/Contents/Resources/python`), or use \
                 --separator provided with stems you already have.",
                h.display()
            ))
        });
    }
    if let Ok(env) = std::env::var("MAJIKS_PYTHON_SRC") {
        if let Some(p) = ok(PathBuf::from(env)) {
            return Ok(p);
        }
    }
    // The shipped app: <...>/Contents/MacOS/<exe> -> <...>/Contents/Resources/python
    if let Ok(exe) = std::env::current_exe() {
        let mut dir = exe.parent().map(Path::to_path_buf);
        while let Some(d) = dir {
            if let Some(p) = ok(d.join("Resources/python")) {
                return Ok(p);
            }
            dir = d.parent().map(Path::to_path_buf);
        }
    }
    // A dev checkout, from wherever the CLI was run.
    if let Ok(cwd) = std::env::current_dir() {
        for cand in ["src/python", "../src/python", "../../src/python"] {
            if let Some(p) = ok(cwd.join(cand)) {
                return Ok(p);
            }
        }
    }
    Err(StudioError::audio(
        "stem separation is unavailable: could not find the Python backend (a directory \
         containing `majik_backend`).\n\
         Fix: set MAJIKS_PYTHON_SRC=/path/to/src/python (in the shipped app this is \
         `Majiks Music Studio.app/Contents/Resources/python`), or use --separator provided \
         with stems you already have."
            .to_string(),
    ))
}

impl Separator for HtdemucsSeparator {
    fn separate(&self, mix: &Path, work_dir: &Path) -> Result<StemSet, StudioError> {
        // Refuse before touching audio if this interpreter cannot separate, so
        // the caller gets the fix-it sentence instead of a python traceback.
        self.preflight()?;
        std::fs::create_dir_all(work_dir).map_err(StudioError::io)?;
        let out = Command::new(&self.python)
            .arg("-m")
            .arg("majik_backend.separate_cli")
            .arg("--in")
            .arg(mix)
            .arg("--out")
            .arg(work_dir)
            .env("PYTHONPATH", &self.python_src)
            .output()
            .map_err(|e| StudioError::audio(format!("htdemucs subprocess failed to launch: {e}")))?;
        if !out.status.success() {
            return Err(StudioError::audio(format!(
                "htdemucs separation failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            )));
        }
        parse_stems_json(&String::from_utf8_lossy(&out.stdout))
    }
    fn model_name(&self) -> String {
        "htdemucs".to_string()
    }
}

/// Parse the four stem paths from `separate_cli.py`'s stdout. Takes the LAST
/// JSON object line, so library chatter printed above it does not break the
/// parse.
fn parse_stems_json(text: &str) -> Result<StemSet, StudioError> {
    let line = text
        .lines()
        .rev()
        .find(|l| l.trim_start().starts_with('{'))
        .ok_or_else(|| StudioError::audio("htdemucs produced no JSON result".to_string()))?;
    let v: Value = serde_json::from_str(line)
        .map_err(|e| StudioError::audio(format!("htdemucs result not JSON: {e}")))?;
    let get = |k: &str| -> Result<PathBuf, StudioError> {
        v.get(k)
            .and_then(Value::as_str)
            .map(PathBuf::from)
            .ok_or_else(|| StudioError::audio(format!("htdemucs result missing {k}")))
    };
    Ok(StemSet {
        vocals: get("vocals")?,
        drums: get("drums")?,
        bass: get("bass")?,
        other: get("other")?,
    })
}

/// PRODUCES UNUSABLE INDIVIDUAL STEMS. This is a TEST FIXTURE, not a separator,
/// and no ordinary caller can select it (see `fixture_refusal`).
///
/// It deals every 4th sample frame whole into one of the four outputs and
/// leaves the other three zero. So each "stem" is 75% exact silence and is the
/// entire song decimated to a 12 kHz sample rate: played ALONE it is aliased
/// garbage that screeches. It was named `bandsplit` and made the default, and a
/// coordinator reading the CLI help reasonably believed it was a frequency-band
/// split and shipped its output to a listener. The name now says what it is.
///
/// The one thing it is good for: its four outputs sum back to the mix
/// BIT-EXACTLY and deterministically, with no torch and no model download, so
/// the placement / bar-alignment / null-test path can be exercised headlessly.
/// That is why it still exists -- and it is exactly why every sum-based check
/// passed while the audio was broken, so it is exempted from the stem usability
/// contract BY NAME rather than by being left out of the registry.
pub struct InterleaveFixtureSeparator;

impl Separator for InterleaveFixtureSeparator {
    fn separate(&self, mix: &Path, work_dir: &Path) -> Result<StemSet, StudioError> {
        std::fs::create_dir_all(work_dir).map_err(StudioError::io)?;
        let buf = load_wav_stereo_48k(mix).map_err(StudioError::audio)?;
        let n = buf.samples.len();
        let mut stems: [Vec<[f32; 2]>; 4] =
            [vec![[0.0; 2]; n], vec![[0.0; 2]; n], vec![[0.0; 2]; n], vec![[0.0; 2]; n]];
        for (i, frame) in buf.samples.iter().enumerate() {
            stems[i % 4][i] = *frame; // whole frame to one stem; sum is exact
        }
        let mut out = Vec::new();
        for (k, name) in STEM_NAMES.iter().enumerate() {
            let path = work_dir.join(format!("{name}.wav"));
            write_wav_f32(&path, &stems[k], buf.sample_rate).map_err(StudioError::audio)?;
            out.push(path);
        }
        Ok(StemSet {
            vocals: out[0].clone(),
            drums: out[1].clone(),
            bass: out[2].clone(),
            other: out[3].clone(),
        })
    }
    /// Says what it is IN THE LINEAGE, so a landed session built with the
    /// fixture is identifiable forever after -- `bandsplit-lossless` read like
    /// a real algorithm with a nice property, which is how it got shipped.
    fn model_name(&self) -> String {
        format!("{INTERLEAVE_FIXTURE_NAME}-unusable-stems")
    }
}

// ---------------------------------------------------------------------------
// Request / report
// ---------------------------------------------------------------------------

/// Everything the pipeline needs to land one song. Only `mix_path` and
/// `prompt` are essential; the rest sharpen the grid, the sections, and the
/// lineage.
#[derive(Debug, Clone, Default)]
pub struct LandingRequest {
    /// The finished-song mix WAV.
    pub mix_path: PathBuf,
    /// The generation prompt (recorded on every clip's lineage).
    pub prompt: String,
    /// The declared/tag BPM, if known. Used ONLY as a tie-break hint for the
    /// measured tempo (never as the grid); see `media::tempo`.
    pub declared_bpm: Option<f64>,
    /// The declared key ("C major" shape), if known. Falls back to the
    /// measured key.
    pub key: Option<String>,
    /// Ordered section names parsed from the generation lyrics
    /// (`[verse]`/`[chorus]`/...), used to label the section map.
    pub section_tags: Vec<String>,
    /// Optional per-tag start times in seconds (e.g. from an LRC). When present
    /// each section snaps to the nearest downbeat of its time; when absent the
    /// tags are distributed evenly across the bars.
    pub section_times: Vec<f64>,
    /// The generation seed, if known (recorded in lineage).
    pub seed: Option<i64>,
    /// The generation model, e.g. "acestep-v15-turbo" (recorded in lineage).
    pub gen_model: Option<String>,
    /// The generation device ("mlx"/"mps"/"cuda"/"cpu"/"remote"); default cpu.
    pub gen_device: Option<String>,
    /// Where the song came from ("generated"/"library"/"imported").
    pub source_kind: Option<String>,
    /// Project display name (defaults to the mix file stem).
    pub project_name: Option<String>,
    /// Optional GROUND-TRUTH section start bars (0-based), for the section
    /// accuracy measurement in tests/evidence only. Not used to build.
    pub truth_section_bars: Option<Vec<u64>>,
}

/// The result of one landing, all measured (no estimates).
#[derive(Debug, Clone)]
pub struct LandingReport {
    pub package_dir: PathBuf,
    pub project_name: String,
    pub measured_bpm: f64,
    pub declared_bpm: Option<f64>,
    pub declared_vs_measured_pct: Option<f64>,
    pub tempo_confidence: f64,
    pub key: Option<String>,
    pub duration_seconds: f64,
    pub bar_ticks: u64,
    pub lead_in_ticks: u64,
    pub track_ids: Vec<String>,
    pub stem_asset_hashes: BTreeMap<String, String>,
    pub mix_asset_hash: String,
    pub sections: Vec<(String, u64)>, // (name, startTicks)
    pub seq: u64,
    // Timing (the < 60 s acceptance).
    pub analyze_seconds: f64,
    pub separate_seconds: f64,
    pub build_seconds: f64,
    pub total_seconds: f64,
    // Null test (both dBFS; lower is better).
    pub null_render_peak_dbfs: f64,
    pub null_render_rms_dbfs: f64,
    pub null_pure_peak_dbfs: f64,
    pub separator_model: String,
    /// Per-stem usability, measured on the separator's own output (see
    /// `crate::stem_usability`). Reported rather than enforced: a genuinely
    /// silent stem is legitimate, so this is the number a reader can check --
    /// and the number that made the shipped defect visible in one glance.
    pub stem_usability: BTreeMap<String, StemUsability>,
    // Section accuracy (present only when truth_section_bars was supplied).
    pub section_within_one_bar: Option<(usize, usize)>, // (within, total)
}

impl LandingReport {
    pub fn to_json(&self) -> Value {
        let mut m = Map::new();
        m.insert("ok".into(), json!(true));
        m.insert("packageDir".into(), json!(self.package_dir.display().to_string()));
        m.insert("projectName".into(), json!(self.project_name));
        m.insert("measuredBpm".into(), json!(self.measured_bpm));
        m.insert("declaredBpm".into(), json!(self.declared_bpm));
        m.insert("declaredVsMeasuredPct".into(), json!(self.declared_vs_measured_pct));
        m.insert("tempoConfidence".into(), json!(self.tempo_confidence));
        m.insert("key".into(), json!(self.key));
        m.insert("durationSeconds".into(), json!(self.duration_seconds));
        m.insert("barTicks".into(), json!(self.bar_ticks));
        m.insert("leadInTicks".into(), json!(self.lead_in_ticks));
        m.insert("trackIds".into(), json!(self.track_ids));
        m.insert("mixAssetHash".into(), json!(self.mix_asset_hash));
        m.insert("stemAssetHashes".into(), json!(self.stem_asset_hashes));
        m.insert(
            "sections".into(),
            json!(self
                .sections
                .iter()
                .map(|(n, t)| json!({ "name": n, "startTicks": t }))
                .collect::<Vec<_>>()),
        );
        m.insert("seq".into(), json!(self.seq));
        m.insert(
            "timing".into(),
            json!({
                "analyzeSeconds": self.analyze_seconds,
                "separateSeconds": self.separate_seconds,
                "buildSeconds": self.build_seconds,
                "totalSeconds": self.total_seconds,
            }),
        );
        m.insert(
            "nullTest".into(),
            json!({
                "renderPeakDbfs": self.null_render_peak_dbfs,
                "renderRmsDbfs": self.null_render_rms_dbfs,
                "pureSumPeakDbfs": self.null_pure_peak_dbfs,
                "separatorModel": self.separator_model,
            }),
        );
        m.insert(
            "stemUsability".into(),
            json!(self
                .stem_usability
                .iter()
                .map(|(k, u)| (k.clone(), u.to_json()))
                .collect::<Map<String, Value>>()),
        );
        if let Some((within, total)) = self.section_within_one_bar {
            m.insert(
                "sectionAccuracy".into(),
                json!({ "withinOneBar": within, "total": total }),
            );
        }
        Value::Object(m)
    }
}

// ---------------------------------------------------------------------------
// Pure bar / section math (unit-tested without any io)
// ---------------------------------------------------------------------------

/// The shared lead-in (in ticks) that lands the audio's first tracked downbeat
/// on a project bar line, on a MEASURED-bpm grid, preserving all audio.
///
/// All four stems get this same start tick with source offset 0, so they stay
/// sample-locked and their sum reproduces the mix. Returns 0 when the song
/// already starts on (or within an eighth note of) a downbeat, or when there is
/// no downbeat to anchor to.
pub fn lead_in_ticks(downbeat_ticks: u64) -> u64 {
    // Distance of the first downbeat past the previous bar line.
    let rem = downbeat_ticks % BAR_TICKS;
    // Already on a bar line, or so close (< 1/8 note) that snapping would add
    // almost a full bar for nothing: start at 0.
    let snap_tol = PPQ / 2; // an eighth note
    if rem == 0 || downbeat_ticks <= snap_tol {
        0
    } else {
        BAR_TICKS - rem
    }
}

/// Convert a time in seconds to a project tick on a fixed-bpm map (round to
/// nearest tick). `frames_per_beat = rate * 60 / bpm`; `ticks = seconds * bpm /
/// 60 * PPQ`.
pub fn seconds_to_ticks(seconds: f64, bpm: f64) -> u64 {
    if bpm <= 0.0 || seconds <= 0.0 {
        return 0;
    }
    (seconds * bpm / 60.0 * PPQ as f64).round().max(0.0) as u64
}

/// Snap a project tick to the nearest bar line.
pub fn snap_to_bar(tick: u64) -> u64 {
    let bars = (tick + BAR_TICKS / 2) / BAR_TICKS;
    bars * BAR_TICKS
}

/// Derive the section map: (sectionId, name, startTicks), all in PROJECT ticks
/// (the caller has already offset audio times by the lead-in). Sections start
/// on project bar lines. Strategy, in order of available information:
///   - tags + per-tag target ticks -> each tag snaps to the bar of its nearest
///     downbeat (the "refined by downbeats" path).
///   - tags only                   -> tags distributed across the downbeats
///     (bars) evenly.
///   - neither                     -> 8-bar sections across the whole song.
/// Starts are deduplicated (one label per bar) and returned sorted.
pub fn derive_sections(
    section_tags: &[String],
    section_target_ticks: &[u64], // per-tag start, already in project ticks
    downbeat_ticks: &[u64],       // downbeat positions, already in project ticks
    total_bars: u64,
) -> Vec<(String, String, u64)> {
    let mut out: Vec<(String, String, u64)> = Vec::new();
    let push = |name: &str, start: u64, out: &mut Vec<(String, String, u64)>| {
        if out.iter().any(|(_, _, t)| *t == start) {
            return; // de-dupe by start tick; keep the first label at a bar
        }
        let id = format!("sec_{}", out.len() + 1);
        out.push((id, name.to_string(), start));
    };

    if !section_tags.is_empty() && section_target_ticks.len() == section_tags.len() {
        // Tags with real times: snap each to the nearest downbeat's bar.
        for (tag, &target) in section_tags.iter().zip(section_target_ticks.iter()) {
            push(tag, nearest_downbeat_bar(target, downbeat_ticks), &mut out);
        }
    } else if !section_tags.is_empty() {
        // Tags only: spread them across the tracked downbeats (bars).
        let n = section_tags.len() as u64;
        for (i, tag) in section_tags.iter().enumerate() {
            let start = if !downbeat_ticks.is_empty() {
                let idx = ((i as u64 * downbeat_ticks.len() as u64) / n) as usize;
                snap_to_bar(downbeat_ticks[idx.min(downbeat_ticks.len() - 1)])
            } else {
                ((i as u64 * total_bars) / n) * BAR_TICKS
            };
            push(tag, start, &mut out);
        }
    } else {
        // No tags: 8-bar sections.
        let mut bar = 0u64;
        let mut idx = 1u64;
        while bar < total_bars.max(1) {
            push(&format!("Section {idx}"), bar * BAR_TICKS, &mut out);
            bar += 8;
            idx += 1;
        }
    }
    out.sort_by_key(|(_, _, t)| *t);
    out
}

/// The bar line of the downbeat nearest `target_tick` (falls back to snapping
/// `target_tick` itself to a bar when there are no downbeats).
fn nearest_downbeat_bar(target_tick: u64, downbeat_ticks: &[u64]) -> u64 {
    match downbeat_ticks
        .iter()
        .min_by_key(|&&d| d.abs_diff(target_tick))
    {
        Some(&d) => snap_to_bar(d),
        None => snap_to_bar(target_tick),
    }
}

/// Peak and RMS of `a - b` over their overlap, in dBFS (a "null" residual).
/// Returns `(peak_dbfs, rms_dbfs)`; -inf floors at -200.
pub fn residual_dbfs(a: &[[f32; 2]], b: &[[f32; 2]]) -> (f64, f64) {
    let n = a.len().min(b.len());
    if n == 0 {
        return (-200.0, -200.0);
    }
    let mut peak = 0.0f64;
    let mut sum_sq = 0.0f64;
    for i in 0..n {
        for ch in 0..2 {
            let d = (a[i][ch] - b[i][ch]) as f64;
            peak = peak.max(d.abs());
            sum_sq += d * d;
        }
    }
    let rms = (sum_sq / (2 * n) as f64).sqrt();
    (lin_to_dbfs(peak), lin_to_dbfs(rms))
}

fn lin_to_dbfs(lin: f64) -> f64 {
    if lin > 0.0 {
        (20.0 * lin.log10()).max(-200.0)
    } else {
        -200.0
    }
}

/// Normalize a key string to the catalog `project.setKey` shape
/// (`^[A-G](#|b)? (major|minor)$`), or `None` if it does not fit (skip
/// project.setKey rather than fail the whole landing on a stray estimate).
fn normalize_key(key: &str) -> Option<String> {
    let key = key.trim();
    let (note, quality) = key.split_once(' ')?;
    if quality != "major" && quality != "minor" {
        return None;
    }
    let bytes = note.as_bytes();
    let first_ok = bytes.first().is_some_and(|c| (b'A'..=b'G').contains(c));
    let rest_ok = match note.len() {
        1 => true,
        2 => bytes[1] == b'#' || bytes[1] == b'b',
        _ => false,
    };
    if first_ok && rest_ok {
        Some(format!("{note} {quality}"))
    } else {
        None
    }
}

/// Map a device string to the `gen.landed.engineIdentity.device` enum; default
/// cpu for anything unknown/absent.
fn normalize_device(device: Option<&str>) -> &'static str {
    match device.unwrap_or("cpu") {
        "mlx" => "mlx",
        "mps" => "mps",
        "cuda" => "cuda",
        "remote" => "remote",
        _ => "cpu",
    }
}

/// Clamp + round a measured bpm into a `project.setTempo`-safe JSON number
/// (0 < bpm <= 999, <= 3 fractional digits so `Bpm::from_json_number` keeps it
/// exact).
fn bpm_number(bpm: f64) -> Value {
    let v = (bpm.clamp(0.001, 999.0) * 1000.0).round() / 1000.0;
    json!(v)
}

// ---------------------------------------------------------------------------
// The pipeline
// ---------------------------------------------------------------------------

/// Build a bar-aligned, stem-split, lineage-carrying `.mstudio` session at
/// `pkg_dir` from a finished song, through the command bus. Returns a measured
/// report (timing + null residual + section accuracy). `work_dir` holds the
/// separator's output + the null-test reference (safe to delete after).
pub fn build_landing(
    pkg_dir: &Path,
    req: &LandingRequest,
    separator: &dyn Separator,
    work_dir: &Path,
    actor: Actor,
) -> Result<LandingReport, StudioError> {
    let t_start = Instant::now();
    if !req.mix_path.exists() {
        return Err(StudioError::audio(format!(
            "mix not found: {}",
            req.mix_path.display()
        )));
    }
    let name = req.project_name.clone().unwrap_or_else(|| {
        req.mix_path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("Open in Studio")
            .to_string()
    });

    // 1. Analyze the mix: BEAT-TRACKED tempo + downbeats (never the tag BPM).
    let a0 = Instant::now();
    let report = media::report::analyze_file(&req.mix_path, req.declared_bpm)
        .map_err(|e| StudioError::audio(format!("analyze {}: {e}", req.mix_path.display())))?;
    let analyze_seconds = a0.elapsed().as_secs_f64();
    let measured_bpm = report.bpm.unwrap_or(120.0);
    let downbeats_sec = report.tempo.as_ref().map(|t| t.downbeats.clone()).unwrap_or_default();
    let confidence = report.tempo.as_ref().map(|t| t.confidence).unwrap_or(0.0);
    let duration = report.duration.unwrap_or(0.0);
    let measured_key = report.key.clone();

    // 2. Separate into vocals/drums/bass/other.
    let s0 = Instant::now();
    let stems = separator.separate(&req.mix_path, work_dir)?;
    let separate_seconds = s0.elapsed().as_secs_f64();

    // 3. Build the project through the bus.
    let b0 = Instant::now();
    let mut host = StudioHost::create_at(pkg_dir, &name)?;
    host.set_tempo_confidence(confidence);
    host.submit(actor.clone(), "project.setTempo", json!({ "bpm": bpm_number(measured_bpm) }))?;
    host.submit(actor.clone(), "project.setTimeSig", json!({ "numerator": 4, "denominator": 4 }))?;
    let key = req.key.clone().or(measured_key).and_then(|k| normalize_key(&k));
    if let Some(k) = &key {
        host.submit(actor.clone(), "project.setKey", json!({ "key": k }))?;
    }

    // Lead-in: land the first tracked downbeat on a project bar line.
    let d0_ticks = downbeats_sec
        .first()
        .map(|&d| seconds_to_ticks(d, measured_bpm))
        .unwrap_or(0);
    let lead_in = lead_in_ticks(d0_ticks);

    // Tracks + placed stems, all at the SAME lead-in (sample-locked).
    let mut track_ids = Vec::new();
    let mut stem_asset_hashes = BTreeMap::new();
    for (stem, path) in stems.iter() {
        let track_id = format!("trk_{stem}");
        host.submit(
            actor.clone(),
            "track.add",
            json!({ "trackId": track_id, "name": stem_title(stem) }),
        )?;
        host.submit(
            actor.clone(),
            "track.setColor",
            json!({ "trackId": track_id, "color": stem_color(stem) }),
        )?;
        let outcome = host.import_audio(
            &path.to_string_lossy(),
            &track_id,
            lead_in,
            Some(format!("clip_{stem}")),
        )?;
        stem_asset_hashes.insert(stem.to_string(), outcome.asset_hash);
        track_ids.push(track_id);
    }
    let vocals_track = track_ids.first().cloned().unwrap_or_else(|| "trk_vocals".into());

    // Lineage: the prompt (gen.song) + model/seed/engine + content hashes
    // (gen.landed). Both journaled, so a full replay-from-empty reproduces the
    // provenance; a per-clip view joins them by asset hash (see host.lineage).
    let mix_bytes = std::fs::read(&req.mix_path).map_err(StudioError::io)?;
    let mix_asset_hash = blake3::hash(&mix_bytes).to_hex().to_string();
    let source_kind = req.source_kind.clone().unwrap_or_else(|| "generated".into());
    let gen_model = req.gen_model.clone().unwrap_or_else(|| "unknown".into());
    let device = normalize_device(req.gen_device.as_deref());
    let request_id = ulid::new_ulid();
    let take_id = ulid::new_ulid();

    let mut gen_request = json!({
        "caption": if req.prompt.trim().is_empty() { "generated song".to_string() } else { req.prompt.clone() },
        "bpm": measured_bpm,
        "source": source_kind,
        "generated": true,
        "separator": separator.model_name(),
    });
    if let Some(k) = &key {
        gen_request["key"] = json!(k);
    }
    if duration > 0.0 {
        gen_request["durationSeconds"] = json!(duration);
    }
    if let Some(s) = req.seed {
        gen_request["seed"] = json!(s);
    }
    if req.gen_model.is_some() {
        gen_request["model"] = json!(gen_model);
    }
    host.submit(
        actor.clone(),
        "gen.song",
        json!({ "requestId": request_id, "trackId": vocals_track, "insertAtTicks": lead_in, "request": gen_request }),
    )?;

    let mut engine_identity = json!({ "model": gen_model, "device": device });
    if let Some(s) = req.seed {
        engine_identity["seed"] = json!(s);
    }
    let mut asset_hashes = Map::new();
    asset_hashes.insert("mix".into(), json!(mix_asset_hash));
    for (stem, hash) in &stem_asset_hashes {
        asset_hashes.insert(stem.clone(), json!(hash));
    }
    host.submit(
        actor.clone(),
        "gen.landed",
        json!({
            "requestId": request_id,
            "sourceCommand": "gen.song",
            "takeId": take_id,
            "assetHashes": Value::Object(asset_hashes),
            "engineIdentity": engine_identity,
        }),
    )?;

    // Section map: lyric tags refined by downbeats, else 8-bar fallback.
    let downbeat_ticks_proj: Vec<u64> = downbeats_sec
        .iter()
        .map(|&d| lead_in + seconds_to_ticks(d, measured_bpm))
        .collect();
    let section_targets_proj: Vec<u64> = req
        .section_times
        .iter()
        .map(|&t| lead_in + seconds_to_ticks(t, measured_bpm))
        .collect();
    let total_bars = (lead_in + seconds_to_ticks(duration, measured_bpm)).div_ceil(BAR_TICKS).max(1);
    let sections = derive_sections(&req.section_tags, &section_targets_proj, &downbeat_ticks_proj, total_bars);
    for (id, sec_name, start) in &sections {
        let label = if sec_name.trim().is_empty() { id.clone() } else { sec_name.clone() };
        host.submit(
            actor.clone(),
            "section.set",
            json!({ "sectionId": id, "name": label, "startTicks": start }),
        )?;
    }

    host.save()?;
    let seq = host.seq();
    let build_seconds = b0.elapsed().as_secs_f64();

    // 4. Null test: placed stems (rendered) vs the mix through the same graph,
    // plus a pure sum of the decoded stems vs the decoded mix (separator only).
    let stems_render = host.render_master()?;
    let ref_render = render_mix_reference(&req.mix_path, lead_in, measured_bpm, work_dir)?;
    let (null_render_peak_dbfs, null_render_rms_dbfs) = residual_dbfs(&stems_render, &ref_render);
    let (null_pure_peak_dbfs, _, stem_usability) = pure_sum_residual(&stems, &req.mix_path)?;

    // Section accuracy (only when ground truth was supplied): each true
    // boundary must have a derived section within one bar (in AUDIO bars).
    let section_within_one_bar = req.truth_section_bars.as_ref().map(|truth| {
        let derived_audio_bars: Vec<i64> = sections
            .iter()
            .map(|(_, _, t)| {
                let audio = (*t as i64 - lead_in as i64).max(0);
                (audio + BAR_TICKS as i64 / 2) / BAR_TICKS as i64
            })
            .collect();
        let within = truth
            .iter()
            .filter(|&&tb| derived_audio_bars.iter().any(|&db| (db - tb as i64).abs() <= 1))
            .count();
        (within, truth.len())
    });

    Ok(LandingReport {
        package_dir: pkg_dir.to_path_buf(),
        project_name: name,
        measured_bpm,
        declared_bpm: req.declared_bpm,
        declared_vs_measured_pct: report.declared_vs_measured_pct,
        tempo_confidence: confidence,
        key,
        duration_seconds: duration,
        bar_ticks: BAR_TICKS,
        lead_in_ticks: lead_in,
        track_ids,
        stem_asset_hashes,
        mix_asset_hash,
        sections: sections.into_iter().map(|(_, n, t)| (n, t)).collect(),
        seq,
        analyze_seconds,
        separate_seconds,
        build_seconds,
        total_seconds: t_start.elapsed().as_secs_f64(),
        null_render_peak_dbfs,
        null_render_rms_dbfs,
        null_pure_peak_dbfs,
        separator_model: separator.model_name(),
        stem_usability,
        section_within_one_bar,
    })
}

// ---------------------------------------------------------------------------
// The agent-parity entry (MCP tool `studio_open_in_studio` + the FFI method).
// Both build a fresh package and open it as the given host's active project, so
// the app / the agent lands on the new session.
// ---------------------------------------------------------------------------

/// Build a landing from a JSON args object (the `studio_open_in_studio` tool /
/// FFI shape) and open it on `host`. Returns the landing report JSON with the
/// package it opened.
pub fn dispatch_open_in_studio(
    host: &mut StudioHost,
    actor: Actor,
    args: &Value,
) -> Result<Value, StudioError> {
    let mix = args
        .get("sourceAudioRef")
        .and_then(Value::as_str)
        .ok_or_else(|| StudioError::invalid("sourceAudioRef is required"))?;
    let req = request_from_args(mix, args);
    let separator = separator_from_args(args)?;

    // Where to create the package: an explicit outputDir, else the host's data
    // dir, else the mix's own folder.
    let base = args
        .get("outputDir")
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .or_else(|| host.data_dir().map(Path::to_path_buf))
        .or_else(|| req.mix_path.parent().map(Path::to_path_buf))
        .ok_or_else(|| StudioError::invalid("no outputDir and no engine data dir to land into"))?;
    let stem = req
        .project_name
        .clone()
        .or_else(|| req.mix_path.file_stem().and_then(|s| s.to_str()).map(str::to_string))
        .unwrap_or_else(|| "OpenInStudio".to_string());
    let pkg_dir = base.join(format!("{}.mstudio", sanitize_pkg_name(&stem)));
    let work_dir = base.join(format!(".{}.landing-work", sanitize_pkg_name(&stem)));

    let report = build_landing(&pkg_dir, &req, separator.as_ref(), &work_dir, actor)?;
    // Make it the active project so snapshot()/the UI land on the new session.
    host.open_project_path(&pkg_dir.to_string_lossy())?;
    // The separator work dir is scratch; best-effort cleanup.
    let _ = std::fs::remove_dir_all(&work_dir);
    Ok(report.to_json())
}

fn request_from_args(mix: &str, args: &Value) -> LandingRequest {
    let str_arg = |k: &str| args.get(k).and_then(Value::as_str).map(str::to_string);
    let str_list = |k: &str| -> Vec<String> {
        args.get(k)
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
            .unwrap_or_default()
    };
    LandingRequest {
        mix_path: PathBuf::from(mix),
        prompt: str_arg("prompt").unwrap_or_default(),
        declared_bpm: args.get("declaredBpm").and_then(Value::as_f64),
        key: str_arg("key"),
        section_tags: str_list("sectionTags"),
        section_times: args
            .get("sectionTimes")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_f64).collect())
            .unwrap_or_default(),
        seed: args.get("seed").and_then(Value::as_i64),
        gen_model: str_arg("genModel"),
        gen_device: str_arg("genDevice"),
        source_kind: str_arg("source"),
        project_name: str_arg("projectName"),
        truth_section_bars: None,
    }
}

fn separator_from_args(args: &Value) -> Result<Box<dyn Separator>, StudioError> {
    // A caller who names nothing gets a REAL separator. The old default here
    // was the fixture, so "just land this song" silently produced four
    // unusable stems and every downstream check said fine.
    match args.get("separator").and_then(Value::as_str).unwrap_or(DEFAULT_SEPARATOR) {
        n if n == INTERLEAVE_FIXTURE_NAME => Err(StudioError::invalid(fixture_refusal(n))),
        "htdemucs" => {
            let src = args.get("pythonSrc").and_then(Value::as_str).map(PathBuf::from);
            Ok(Box::new(HtdemucsSeparator::discover(src)?))
        }
        "provided" => {
            let s = args
                .get("stems")
                .ok_or_else(|| StudioError::invalid("separator=provided needs a stems object"))?;
            let p = |k: &str| -> Result<PathBuf, StudioError> {
                s.get(k)
                    .and_then(Value::as_str)
                    .map(PathBuf::from)
                    .ok_or_else(|| StudioError::invalid(format!("stems.{k} is required")))
            };
            Ok(Box::new(PreSeparated {
                stems: StemSet {
                    vocals: p("vocals")?,
                    drums: p("drums")?,
                    bass: p("bass")?,
                    other: p("other")?,
                },
                model: args
                    .get("separatorModel")
                    .and_then(Value::as_str)
                    .unwrap_or("htdemucs")
                    .to_string(),
            }))
        }
        other => Err(StudioError::invalid(format!(
            "unknown separator '{other}' (want {})",
            selectable_separator_names()
        ))),
    }
}

/// Package-name sanitizer (mirrors the host's; keeps `[A-Za-z0-9_-]`).
fn sanitize_pkg_name(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' })
        .collect();
    if cleaned.is_empty() {
        "OpenInStudio".to_string()
    } else {
        cleaned
    }
}

/// Render the mix as a single clip at the same lead-in and tempo, through the
/// same offline graph, so the stem sum can be nulled against it apples-to-apples
/// (identical declick + tail).
fn render_mix_reference(
    mix: &Path,
    lead_in: u64,
    bpm: f64,
    work_dir: &Path,
) -> Result<Vec<[f32; 2]>, StudioError> {
    let ref_pkg = work_dir.join("_reference.mstudio");
    let _ = std::fs::remove_dir_all(&ref_pkg);
    let mut host = StudioHost::create_at(&ref_pkg, "reference")?;
    let sys = Actor::system();
    host.submit(sys.clone(), "project.setTempo", json!({ "bpm": bpm_number(bpm) }))?;
    host.submit(sys.clone(), "track.add", json!({ "trackId": "trk_mix", "name": "Mix" }))?;
    host.import_audio(&mix.to_string_lossy(), "trk_mix", lead_in, Some("clip_mix".into()))?;
    let out = host.render_master();
    let _ = std::fs::remove_dir_all(&ref_pkg);
    out
}

/// Sum the four decoded stems and null against the decoded mix: this isolates
/// the SEPARATOR's own reconstruction tolerance from placement. Lossless
/// separators floor near the numeric limit; htdemucs sits at its model residual.
///
/// The same decode pass also measures each stem ON ITS OWN (`stem_usability`),
/// because "the four sum back to the mix" is precisely the assertion the
/// interleave fixture satisfies perfectly while every individual stem is
/// unusable. One decode, both faces of the property.
fn pure_sum_residual(
    stems: &StemSet,
    mix: &Path,
) -> Result<(f64, f64, BTreeMap<String, StemUsability>), StudioError> {
    let mix_buf = load_wav_stereo_48k(mix).map_err(StudioError::audio)?;
    let mut sum = vec![[0.0f32; 2]; mix_buf.samples.len()];
    let mut usability = BTreeMap::new();
    for (stem, path) in stems.iter() {
        let s = load_wav_stereo_48k(path).map_err(StudioError::audio)?;
        usability.insert(stem.to_string(), stem_usability::measure(&s.samples));
        for i in 0..sum.len().min(s.samples.len()) {
            sum[i][0] += s.samples[i][0];
            sum[i][1] += s.samples[i][1];
        }
    }
    let (peak, rms) = residual_dbfs(&sum, &mix_buf.samples);
    Ok((peak, rms, usability))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lead_in_lands_first_downbeat_on_a_bar_line() {
        // On a bar line already -> no lead-in.
        assert_eq!(lead_in_ticks(0), 0);
        assert_eq!(lead_in_ticks(BAR_TICKS), 0);
        // Within an eighth note of a bar line -> no lead-in.
        assert_eq!(lead_in_ticks(120), 0);
        // A downbeat 1000 ticks into a bar -> lead-in pushes it to the next bar,
        // and lead_in + downbeat is exactly a bar line.
        let d = 1000;
        let lead = lead_in_ticks(d);
        assert_eq!((lead + d) % BAR_TICKS, 0, "downbeat must land on a bar line");
        assert!(lead < BAR_TICKS, "lead-in is under one bar");
        // Just past a bar line -> nearly a full bar of lead-in, still < 1 bar.
        let d2 = BAR_TICKS + 200;
        let lead2 = lead_in_ticks(d2);
        assert_eq!((lead2 + d2) % BAR_TICKS, 0);
    }

    #[test]
    fn seconds_to_ticks_matches_the_bpm_grid() {
        // 120 bpm: one beat = 0.5 s = 960 ticks; one bar = 2 s = 3840 ticks.
        assert_eq!(seconds_to_ticks(0.5, 120.0), 960);
        assert_eq!(seconds_to_ticks(2.0, 120.0), BAR_TICKS);
        // 92 bpm: one bar = 4 beats * (60/92) s.
        let bar_s = 4.0 * 60.0 / 92.0;
        assert_eq!(seconds_to_ticks(bar_s, 92.0), BAR_TICKS);
    }

    #[test]
    fn sections_from_tags_and_downbeats_snap_to_bars() {
        // Downbeats at bars 0,1,2,...,7 (project ticks), no lead-in.
        let downbeats: Vec<u64> = (0..8).map(|b| b * BAR_TICKS).collect();
        let tags = vec!["Intro".to_string(), "Verse".to_string(), "Chorus".to_string()];
        // Targets near bars 0, 2, 5 (a hair off, must snap to the bar).
        let targets = vec![80, 2 * BAR_TICKS + 90, 5 * BAR_TICKS - 70];
        let secs = derive_sections(&tags, &targets, &downbeats, 8);
        let starts: Vec<u64> = secs.iter().map(|(_, _, t)| *t).collect();
        assert_eq!(starts, vec![0, 2 * BAR_TICKS, 5 * BAR_TICKS]);
        // Every start is on a bar line.
        assert!(secs.iter().all(|(_, _, t)| t % BAR_TICKS == 0));
    }

    #[test]
    fn sections_fall_back_to_eight_bar_blocks() {
        let secs = derive_sections(&[], &[], &[], 20);
        let starts: Vec<u64> = secs.iter().map(|(_, _, t)| *t).collect();
        assert_eq!(starts, vec![0, 8 * BAR_TICKS, 16 * BAR_TICKS]);
    }

    #[test]
    fn tags_only_spread_across_the_downbeats() {
        let downbeats: Vec<u64> = (0..8).map(|b| b * BAR_TICKS).collect();
        let tags = vec!["A".to_string(), "B".to_string(), "C".to_string(), "D".to_string()];
        let secs = derive_sections(&tags, &[], &downbeats, 8);
        assert_eq!(secs.len(), 4);
        assert!(secs.iter().all(|(_, _, t)| t % BAR_TICKS == 0));
        assert_eq!(secs[0].2, 0); // first tag at the top
    }

    #[test]
    fn identical_buffers_null_to_the_floor() {
        let a = vec![[0.3f32, -0.2]; 1000];
        let (peak, rms) = residual_dbfs(&a, &a);
        assert_eq!(peak, -200.0);
        assert_eq!(rms, -200.0);
    }

    #[test]
    fn residual_measures_a_known_offset() {
        let a = vec![[0.5f32, 0.5]; 100];
        let b = vec![[0.4f32, 0.4]; 100]; // diff 0.1 -> -20 dBFS
        let (peak, _) = residual_dbfs(&a, &b);
        assert!((peak - -20.0).abs() < 0.01, "peak {peak}");
    }

    #[test]
    fn naming_the_fixture_is_refused_loudly_and_the_default_is_never_the_fixture() {
        // The parser the CLI, the MCP tool and the FFI all share. The refusal
        // has to SAY what the audio would be: "unknown separator" would only
        // teach the next caller to spell it more carefully.
        let refused = |args: Value| -> String {
            match separator_from_args(&args) {
                Ok(sep) => panic!("must be refused, got separator {}", sep.model_name()),
                Err(e) => e.message(),
            }
        };
        let err = refused(json!({ "separator": INTERLEAVE_FIXTURE_NAME }));
        assert!(err.contains("TEST FIXTURE"), "{err}");
        assert!(err.contains("75%"), "{err}");
        assert!(err.contains("12 kHz"), "{err}");
        assert!(err.contains("screech"), "{err}");
        assert!(err.contains("htdemucs"), "the refusal points at a real one: {err}");

        // The old, lying name resolves to nothing at all, and the "want ..."
        // list contains only real separators.
        let e2 = refused(json!({ "separator": "bandsplit" }));
        assert_eq!(e2, "unknown separator 'bandsplit' (want htdemucs|provided)");

        // And the default is a real separator: naming nothing cannot yield the
        // fixture. (It may still fail for want of demucs -- which is the point:
        // an honest refusal instead of silent garbage.)
        assert_eq!(DEFAULT_SEPARATOR, "htdemucs");
        match separator_from_args(&json!({})) {
            Ok(sep) => assert_eq!(sep.model_name(), "htdemucs"),
            Err(e) => {
                let m = e.message();
                assert!(m.contains("unavailable"), "{m}");
                assert!(
                    m.contains("pip install") || m.contains("MAJIKS_PYTHON"),
                    "an unavailable default must say how to fix it: {m}"
                );
                assert!(
                    !m.contains(INTERLEAVE_FIXTURE_NAME),
                    "and must not have quietly substituted the fixture: {m}"
                );
            }
        }
    }

    #[test]
    fn the_interpreter_the_app_ships_wins_over_whatever_path_offers() {
        // Lay out the bundle's shape: Contents/Resources/python beside
        // Contents/Frameworks/Python.framework/Versions/3.12/bin/python3.12.
        //
        // The engine must reach the runtime the app SHIPS -- it carries torch,
        // numpy and (now) demucs -- and not `python3` from PATH. A GUI-launched
        // app inherits launchd's PATH (/usr/bin:/bin:/usr/sbin:/sbin), so
        // `python3` there resolves to /usr/bin/python3, which has none of the
        // app's libraries. Defaulting to it is why the htdemucs branch existed
        // and never ran in a shipped build.
        let dir = tempfile::tempdir().unwrap();
        let contents = dir.path().join("Majiks Music Studio.app/Contents");
        let src = contents.join("Resources/python");
        std::fs::create_dir_all(src.join("majik_backend")).unwrap();
        std::fs::write(src.join("majik_backend/rpc_server.py"), "").unwrap();
        let bin = contents.join("Frameworks/Python.framework/Versions/3.12/bin");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::write(bin.join("python3.12"), "").unwrap();
        let bundled = bin.join("python3.12").to_string_lossy().to_string();

        assert_eq!(
            discover_python_with(&src, None),
            bundled,
            "the runtime the app ships must win over PATH"
        );
        // An explicit override still wins over everything (a dev pointing at a
        // venv, or a build machine with a purpose-built interpreter).
        assert_eq!(
            discover_python_with(&src, Some("/opt/venv/bin/python".into())),
            "/opt/venv/bin/python"
        );
        // An empty MAJIKS_PYTHON is not an override.
        assert_eq!(discover_python_with(&src, Some("   ".into())), bundled);

        // A dev checkout has no bundle beside it, so PATH is the honest answer.
        let repo = dir.path().join("repo/src/python");
        std::fs::create_dir_all(repo.join("majik_backend")).unwrap();
        std::fs::write(repo.join("majik_backend/rpc_server.py"), "").unwrap();
        assert_eq!(discover_python_with(&repo, None), "python3");

        // The source dir: an explicit hint that IS a backend is honoured...
        assert_eq!(discover_python_src(Some(src.clone())).unwrap(), src);
        // ...and one that is not is refused by name rather than silently
        // replaced with a search result.
        let bad = dir.path().join("not-a-backend");
        let err = match discover_python_src(Some(bad.clone())) {
            Ok(p) => panic!("a bad --python-src must refuse, got {}", p.display()),
            Err(e) => e.message(),
        };
        assert!(err.contains(&bad.display().to_string()), "{err}");
    }

    #[test]
    fn the_registry_agrees_with_the_parser() {
        // Every selectable name is one the parser knows, and the fixture is
        // registered but not selectable. Keeps the schema, the usage text and
        // the parser from drifting apart.
        assert_eq!(selectable_separator_names(), "htdemucs|provided");
        let fixture = SEPARATOR_REGISTRY
            .iter()
            .find(|s| s.name == INTERLEAVE_FIXTURE_NAME)
            .expect("the fixture is registered, so the contract test can exempt it BY NAME");
        assert_eq!(fixture.kind, SeparatorKind::Fixture);
        assert!(!fixture.selectable);
        assert!(InterleaveFixtureSeparator
            .model_name()
            .starts_with(INTERLEAVE_FIXTURE_NAME));
    }

    #[test]
    fn htdemucs_stdout_parses_last_json_line() {
        let stdout = "Some models will download...\nWARNING: cuda not found\n\
            {\"vocals\":\"/w/vocals.wav\",\"drums\":\"/w/drums.wav\",\"bass\":\"/w/bass.wav\",\"other\":\"/w/other.wav\"}\n";
        let stems = parse_stems_json(stdout).expect("parse");
        assert_eq!(stems.vocals, PathBuf::from("/w/vocals.wav"));
        assert_eq!(stems.other, PathBuf::from("/w/other.wav"));
        // No JSON at all -> a clean error, not a panic.
        assert!(parse_stems_json("just logs, no json\n").is_err());
        // Missing a stem key -> error.
        assert!(parse_stems_json("{\"vocals\":\"v\",\"drums\":\"d\",\"bass\":\"b\"}").is_err());
    }

    #[test]
    fn key_normalization_matches_the_catalog_pattern() {
        assert_eq!(normalize_key("D minor").as_deref(), Some("D minor"));
        assert_eq!(normalize_key("F# major").as_deref(), Some("F# major"));
        assert_eq!(normalize_key(" Bb minor ").as_deref(), Some("Bb minor"));
        assert_eq!(normalize_key("H minor"), None);
        assert_eq!(normalize_key("C lydian"), None);
        assert_eq!(normalize_key("Cmaj"), None);
    }
}
