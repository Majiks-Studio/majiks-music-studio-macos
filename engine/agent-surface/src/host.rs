//! `StudioHost`: the one engine INSTANCE the agent surface drives.
//!
//! Owns a timeline-core `Session` (the command bus + hash-chained journal +
//! undo), the decoded audio sources keyed by content hash, the open `.mstudio`
//! package dir, and a small tracked transport view. Every mutation an agent,
//! the FFI, the CLI, or a test makes flows through `submit`, so undo /
//! provenance / parity are identical whoever drives.
//!
//! The host is deliberately Send: it holds NO live cpal stream (that type is
//! `!Send` and is why the DJ engine went global). Live playback is the app's
//! audio thread at integration checkpoint I1; here the "real engine" is the
//! render crate's OFFLINE graph (`ManualRenderer`), which is the same
//! `RenderCore::render` the device callback runs, so a bounce is truthful.

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver, TryRecvError};
use std::sync::Arc;

use serde_json::{json, Map, Value};

use render::automation::{AutomationStore, CurveKind, RawPoint};
use render::compile::{compile_session_full, session_end_frame, DeclickPolicy};
// The rack's pad count, taken from the DSP rather than restated: the UI-facing
// refusal has to mean the same 16 that `build_drum_kit` enforces.
use render::dsp::drum::RACK_PADS;
use render::encode::{encode_aac_m4a, normalize_to_target, write_wav_i24, LoudnessTarget, NormalizeReport};
use render::engine::EngineConfig;
use render::media::{load_wav_stereo_48k, write_wav_f32, AudioBuf};
use render::offline::{render_offline_with, ManualRenderer, ScheduledCommand};
use render::rt::RtSession;
use render::warp::{is_identity, WarpCache, WarpEntry, WarpKey, WarpOverlay, MAX_RATIO, MIN_RATIO};
use render::{RenderCommand, ENGINE_SAMPLE_RATE};

use crate::live::LiveAudio;
use crate::midi_record::MidiCapture;
use crate::record_input::LiveInput;
use crate::midi::MidiState;

use timeline_core::model::{TakeRecord, TakeStatus};
use timeline_core::package::{OpenRecovery, Package};
use timeline_core::{Actor, Bpm, Cmd, Project, TempoMap};

use crate::error::StudioError;
use crate::ulid;

/// The 1-second tail appended to a full bounce so bus/reverb/delay ring-outs
/// and clip fade-outs are captured (deterministic; not a musical decision).
const BOUNCE_TAIL_FRAMES: u64 = ENGINE_SAMPLE_RATE as u64;

/// Waveform read tool hard cap: agents never pull raw audio, and one call
/// returns at most this many peak bins (the "capped bins" rule).
pub const WAVEFORM_MAX_BINS: usize = 2048;

/// A tracked, audio-free transport view. Live cpal playback is wired at I1;
/// until then transport commands validate on the bus and update this view so
/// snapshots read honestly (playing/position/loop), the device stays silent.
#[derive(Debug, Clone, Default)]
struct Transport {
    playing: bool,
    position_ticks: u64,
    loop_region: Option<(u64, u64)>,
    metronome: bool,
    /// Click level in dB relative to the default reference. MONITOR state:
    /// never journaled, never persisted into the project, and — because the
    /// click only exists on a monitoring core — structurally incapable of
    /// reaching an exported mix. `None` means "the engine default".
    metronome_level_db: Option<f64>,
}

/// Result of a bounce (offline render to a file).
#[derive(Debug, Clone)]
pub struct BounceReport {
    pub output_path: PathBuf,
    pub frames: u64,
    pub seconds: f64,
    pub peak: f32,
    pub sample_rate: u32,
}

impl BounceReport {
    pub fn to_json(&self) -> Value {
        json!({
            "ok": true,
            "outputPath": self.output_path.display().to_string(),
            "frames": self.frames,
            "seconds": self.seconds,
            "peak": self.peak,
            "sampleRateHz": self.sample_rate,
        })
    }
}

/// A file that has become a content-addressed ASSET: decoded, hashed, copied
/// into `audio/<hash>.wav`, registered in the live `sources` map, tiled.
///
/// This type exists so there is exactly ONE ingest path in the host.
/// `import.audio` (which then places a clip) and `bind_samples` (which places
/// no clip at all, only a sampler zone / drum pad) both produce this and then
/// diverge. A second ingest is how a sampler ends up resolving through a
/// different map than a clip does, which is the failure `resolve_zone_audio`'s
/// doc comment exists to forbid.
#[derive(Debug, Clone)]
pub struct AssetIngest {
    /// blake3 of the ORIGINAL file bytes — the `source_id` a zone names and the
    /// `assetHash` a clip names. The same value for the same file, always.
    pub hash: String,
    pub len_frames: u64,
    pub tiles_ready: bool,
    /// Where the bytes came from. For DISPLAY only: never a lookup key, because
    /// the model deliberately holds no filesystem path.
    pub source_path: String,
}

/// ONE source binding the UI is asking for: a file, and where on the keyboard
/// it should answer.
#[derive(Debug, Clone)]
pub struct SampleBinding {
    pub source_path: String,
    /// The key the recording sounds at. Ignored by a drum rack, which does not
    /// pitch-track; `lo_pitch` is a pad's identity there.
    pub root_pitch: i64,
    pub lo_pitch: i64,
    pub hi_pitch: i64,
    pub gain_db: Option<f64>,
    pub pan: Option<f64>,
}

/// "Put these sounds into this instrument", as ONE undoable gesture.
///
/// # Why this is a host method and not a new catalog command
///
/// The MUTATIONS it makes are `device.add` + `device.zone.remove` +
/// `device.zone.add` — all three already exist, and E0 §9.2 says a new
/// semantic gets a new NAME, not that an existing pair needs a third wrapper.
/// What the UI could not do for itself is the other half: the asset io.
/// `import.audio` is the only path that turns a file into a `source_id`, and it
/// also places a CLIP and opens its own transaction — and v1 transactions do
/// not nest, so a UI-side bracket around it is impossible. That is the whole
/// gap: a gesture that ingests an asset and binds it, atomically, with no clip.
///
/// So this sits exactly where `import_audio` sits: a host method that does io
/// and then journals ordinary catalog commands inside one txn.
#[derive(Debug, Clone)]
pub struct BindSamplesRequest {
    pub track_id: String,
    /// An EXISTING device to bind into, or `None` to create one.
    pub device_id: Option<String>,
    /// Required when creating: `"sampler"` or `"drum"`. A synth reads no audio
    /// and is refused.
    pub kind: Option<String>,
    /// Zones to remove BEFORE the additions land, so "change this pad's sound"
    /// is one step and never a moment with two sounds on one key.
    pub remove_zone_ids: Vec<String>,
    pub bindings: Vec<SampleBinding>,
    /// What the undo step is called in the journal.
    pub reason: String,
}

/// What a bound zone became.
#[derive(Debug, Clone)]
pub struct BoundZone {
    pub zone_id: String,
    pub source_id: String,
    pub source_path: String,
    pub root_pitch: i64,
    pub lo_pitch: i64,
    pub hi_pitch: i64,
}

#[derive(Debug, Clone)]
pub struct BindSamplesOutcome {
    pub track_id: String,
    pub device_id: String,
    pub kind: String,
    pub created_device: bool,
    pub removed_zone_ids: Vec<String>,
    pub zones: Vec<BoundZone>,
    pub seq: u64,
}

impl BindSamplesOutcome {
    pub fn to_json(&self) -> Value {
        json!({
            "ok": true,
            "trackId": self.track_id,
            "deviceId": self.device_id,
            "kind": self.kind,
            "createdDevice": self.created_device,
            "removedZoneIds": self.removed_zone_ids,
            "zones": self.zones.iter().map(|z| json!({
                "zoneId": z.zone_id,
                "sourceId": z.source_id,
                "sourcePath": z.source_path,
                "rootPitch": z.root_pitch,
                "loPitch": z.lo_pitch,
                "hiPitch": z.hi_pitch,
            })).collect::<Vec<_>>(),
            "seq": self.seq,
        })
    }
}

/// Result of importing an audio file (host io + a journaled clip.place).
#[derive(Debug, Clone)]
pub struct ImportOutcome {
    pub clip_id: String,
    pub track_id: String,
    pub asset_hash: String,
    pub start_ticks: u64,
    pub length_ticks: u64,
    pub seq: u64,
    pub measured_bpm: Option<f64>,
    pub loudness_lufs: Option<f64>,
    pub tiles_ready: bool,
}

/// Result of an offline/synthetic recording landing.  `tiles_ready` and
/// `loudness_lufs` are computed before the command is reported complete, so a
/// landed take has the same media guarantees as an imported asset.
#[derive(Debug, Clone)]
pub struct RecordingOutcome {
    pub take_id: String,
    pub clip_id: String,
    pub track_id: String,
    pub asset_hash: String,
    pub start_ticks: u64,
    pub length_ticks: u64,
    pub tiles_ready: bool,
    pub loudness_lufs: Option<f64>,
    pub seq: u64,
}

impl RecordingOutcome {
    pub fn to_json(&self) -> Value {
        json!({"ok": true, "takeId": self.take_id, "clipId": self.clip_id,
            "trackId": self.track_id, "assetHash": self.asset_hash,
            "startTicks": self.start_ticks, "lengthTicks": self.length_ticks,
            "tilesReady": self.tiles_ready, "loudnessLufs": self.loudness_lufs,
            "seq": self.seq})
    }
}

impl ImportOutcome {
    pub fn to_json(&self) -> Value {
        json!({
            "ok": true,
            "clipId": self.clip_id,
            "trackId": self.track_id,
            "assetHash": self.asset_hash,
            "startTicks": self.start_ticks,
            "lengthTicks": self.length_ticks,
            "seq": self.seq,
            "measuredBpm": self.measured_bpm,
            "loudnessLufs": self.loudness_lufs,
            "tilesReady": self.tiles_ready,
        })
    }
}

/// Live input capture state for the record.* commands. `#[derive(Default)]` so
/// each constructor adds a single `record: RecordState::default()` line, and so
/// `Option<LiveInput>` starts `None` (nothing here auto-opens a device).
#[derive(Default)]
struct RecordState {
    /// The running audio capture, when one is open. `None` = not capturing audio.
    /// Dropping it stops the input stream and releases the device.
    input: Option<LiveInput>,
    /// Opt-in listen-only input (meter without landing). Opened ONLY by
    /// `record.inputListen {enabled: true}`, never by arming. Dropped when a
    /// real capture starts. Best-effort: if no device is available this stays
    /// `None` and the meter is silent.
    listen: Option<LiveInput>,
    /// MIDI take buffer while recording an instrument track. Independent of the
    /// audio input stream — instrument record does not open a mic.
    midi: Option<MidiCapture>,
    /// The primary armed track `record.start` named (for UI focus).
    track_id: Option<String>,
    /// Every armed audio track that will receive a demuxed channel on stop.
    capture_targets: Vec<CaptureTarget>,
    /// Where the captured clip lands (bar-snapped at landing time).
    start_ticks: u64,
    /// The transport position sampled when the capture input became ready.
    capture_origin_ticks: u64,
    /// Whether the transport was rolling at that same capture-origin sample.
    rolling: bool,
    /// Punch-out position: when set, record.stop trims/pads the capture to
    /// exactly punch_out_ticks - start_ticks long (the punch region).
    punch_out_ticks: Option<u64>,
    /// Cached input-device names for the UI picker; refreshed on arm / start.
    devices: Vec<String>,
    /// Richer device info (channel counts + rates) for multi-channel UI.
    device_info: Vec<render::recording::InputDeviceInfo>,
    /// The open comp session (loop-record): repeated captures over the SAME
    /// region stack as take-only siblings under one requestId.
    session: Option<RecordSession>,
    /// Ordered media-preparation jobs for completed loop passes.
    landings: VecDeque<PendingRecording>,
    /// Bounded completion history for errors and device-free acceptance tests.
    completed_landings: VecDeque<Result<RecordingOutcome, StudioError>>,
}

/// One track that will receive a demuxed channel from a multi-channel capture.
#[derive(Debug, Clone)]
struct CaptureTarget {
    track_id: String,
    /// 0-based device channel.
    channel: u32,
}

impl RecordState {
    fn is_recording(&self) -> bool {
        self.input.as_ref().map(|i| i.is_capturing()).unwrap_or(false) || self.midi.is_some()
    }

    /// True when any input stream is open (capturing OR opt-in listen).
    fn input_open(&self) -> bool {
        self.input.is_some() || self.listen.is_some()
    }
}

/// An open comp session: after the first capture over a (track, start, punch)
/// region places the comp clip, later captures over the same region land as
/// take-only takes under this requestId, so loop-record fills a take lane.
struct RecordSession {
    track_id: String,
    start_ticks: u64,
    punch_out_ticks: Option<u64>,
    request_id: String,
    /// The comp clip placed by the first pass. If it no longer exists (undo /
    /// clip.remove / track.remove), the session is stale and a new pass starts
    /// a fresh comp clip instead of a headless take-only landing.
    comp_clip_id: Option<String>,
}

struct PendingRecording {
    track_id: String,
    start_ticks: u64,
    capture_origin_ticks: u64,
    rolling: bool,
    rate: u32,
    engine_model: String,
    request_id: String,
    prepared: Receiver<Result<PreparedRecording, StudioError>>,
}

struct PreparedRecording {
    frames: Vec<[f32; 2]>,
    hash: String,
    tiles_ready: bool,
    loudness_lufs: Option<f64>,
}

pub struct StudioHost {
    session: timeline_core::Session,
    /// Base directory the FFI initialized with; `.mstudio` packages live here.
    data_dir: Option<PathBuf>,
    /// The currently open package directory (`<data_dir>/<name>.mstudio`).
    package_dir: Option<PathBuf>,
    /// assetHash -> decoded stereo/48k audio, for compile + waveform reads.
    sources: HashMap<String, Arc<AudioBuf>>,
    transport: Transport,
    declick: DeclickPolicy,
    /// The live audio session, when one is open. `None` = offline (the tracked
    /// transport + silence-floor meters). `Some` = a cpal stream is running on
    /// the audio-host thread; transport + edits reach it, and meters / stats /
    /// position read from the live engine. Silent at the device by default.
    /// Kept last, and it is the only `!Send`-adjacent state, but the handle
    /// itself is `Send` (see `live::LiveAudio`), so `StudioHost` stays `Send`.
    live: Option<LiveAudio>,

    /// Why the last recompile-and-push to the live engine FAILED, if it did.
    ///
    /// `Some` means the audio thread is still rendering the previous session
    /// while the model has moved on — the user edits and hears nothing change.
    /// This field is what makes that state visible instead of silent; see
    /// `push_live_session`. Cleared on the next successful push, and always
    /// `None` when no live session is open.
    live_render_error: Option<String>,

    /// Whether the next live session opens an AUDIBLE output device. False by
    /// default (the device hears zeros): the CLI, tests, and headless/CI runs
    /// leave it false, so the automated-blast safety cannot regress. Only the
    /// GUI app flips it true (`set_audible_output`, wired from the Swift app at
    /// launch) so a user pressing Play is heard.
    audible_output: bool,

    /// Live input capture state (record.start/stop/cancel) plus the cached
    /// input-device list for the UI picker. `LiveInput` is `Send` (see
    /// `record_input`), so this keeps `StudioHost` `Send`.
    record: RecordState,

    /// THE RETRO-CAPTURE BUFFER: a rolling record of what the player has just
    /// played, kept whether or not anything was armed or recording.
    ///
    /// This exists because the shipped app made a person choose, BEFORE playing,
    /// between hearing and keeping — and the only way to choose "keep" was to
    /// learn the word "arm". People do not know in advance that the thing they
    /// are about to play is worth keeping; they find out afterwards. So the app
    /// keeps it anyway, bounded, and offers it back (`performance_keep`).
    ///
    /// Fed from `preview_note`, which is the ONE place a played note goes,
    /// whichever surface it came from (hardware MIDI key, piano-roll gutter,
    /// on-screen keyboard, an agent). Nothing is journaled until a human asks to
    /// keep it. Bounded by `PERFORMANCE_WINDOW_BEATS` and `PERFORMANCE_MAX_NOTES`.
    ///
    /// `None` until the first note is played; suspended while a real
    /// `record.start` take owns the input (the take IS the capture, and two
    /// buffers landing the same performance twice is worse than none).
    performance: Option<MidiCapture>,

    /// The track `ensure_instrument_target` last created for a played note.
    ///
    /// Remembered ONLY so an undo of that creation can be recognised as such —
    /// see `auto_create_held_off`. Nothing reads it as "the instrument"; that
    /// question is always answered from the project (`midi_instrument_target`).
    auto_created_instrument_track: Option<String>,

    /// The keys that were DOWN at the moment the user undid an auto-create, and
    /// have not been lifted since. While this is non-empty, auto-create is held
    /// off.
    ///
    /// Auto-create is state-based: a note-on with no instrument anywhere in the
    /// project makes one. That rule alone fights the user at exactly one moment
    /// — they press Cmd-Z to take back the track a played note just created,
    /// and the note-ons still queued behind their fingers immediately make
    /// another. So the undo captures the keys that were down, and nothing is
    /// re-created until every one of THOSE keys is up. A fresh press then
    /// creates again, because a person pressing a key is asking to hear
    /// something and permanent silence is the bug this whole path exists to
    /// kill.
    ///
    /// A SET rather than a flag on purpose: a flag tested against "any key is
    /// down" is satisfied by the very note being decided, so the hold-off could
    /// never end (`lifting_the_keys_re_arms_auto_create` caught exactly that).
    /// This set only ever shrinks, on key-up.
    ///
    /// Deliberately NOT a session-long disarm: "you undid this once, so the
    /// keyboard is dead until you restart" is the same defect wearing a
    /// different hat.
    auto_create_holdoff_keys: std::collections::BTreeSet<u8>,

    /// Which pitches are physically DOWN right now, fed by EVERY note gate the
    /// host sees whether or not it had anywhere to send it.
    ///
    /// The retro-capture buffer cannot answer this question. It only receives
    /// notes that actually reached an instrument, so the moment auto-create is
    /// held off its `sounding` set freezes with the held keys stuck down — and a
    /// hold-off keyed to a frozen set is a PERMANENT disarm, i.e. the exact bug
    /// it was written to avoid. (Found by `lifting_the_keys_re_arms_auto_create`
    /// before this set existed.)
    keys_down: std::collections::BTreeSet<u8>,

    /// Pre-rendered stretched audio for every warped clip, content-addressed.
    ///
    /// `clip.warp.set` is model state (`Clip::warp`), which is what makes it
    /// journaled, saved and undoable. This is the RENDER side of that state:
    /// the buffers the compiled session actually plays. It is derived — never
    /// authored — so it needs no command of its own, cannot drift from the
    /// model, and survives undo/redo/reload for free.
    ///
    /// Interior mutability on purpose: the offline bounce paths take `&self`
    /// and must still be able to render a warp they have not seen before, or a
    /// bounce would silently drop the stretch that live playback applies.
    warp_cache: WarpCache,

    /// What the LAST open of this host's package had to do to rebuild it.
    ///
    /// Default (all-false) means an ordinary reopen and there is nothing to say.
    /// Anything else — a missing checkpoint replayed from the journal, a torn or
    /// damaged chain — is a fact the person using the app is entitled to, and
    /// the FFI surfaces it (`open_recovery`) so the Studio can say so on screen.
    /// A recovery that works but says nothing is only half a fix.
    open_recovery: OpenRecovery,

    pub(crate) midi: MidiState,
}

/// How much of a performance the retro-capture buffer keeps, in BEATS rather
/// than seconds so the window is musically meaningful at any tempo: 128 beats is
/// 32 bars of 4/4, comfortably more than anyone plays before deciding they liked
/// it, and ~64 s at 120 BPM.
const PERFORMANCE_WINDOW_BEATS: u64 = 128;

/// Hard cap on buffered notes, because a window alone does not bound a dense
/// performance. 4096 notes is a very busy 32 bars.
const PERFORMANCE_MAX_NOTES: usize = 4096;

/// The actor name `ensure_instrument_target` stamps its commands with, and the
/// ONLY thing in the tree that submits under it — the mirror of `export.rs`'s
/// `RECORD_ACTOR`. Reading it back out of the journal is how the snapshot knows
/// a track exists because a key was pressed.
const PERFORMANCE_ACTOR: &str = "performance";

/// The actor every import path stamps its commands with. `import_audio` uses
/// it for a clip on a track that already exists, and `import_stems_params` uses
/// it for the track it mints per stem file — which is the one that reads back
/// as provenance, because it is the one that puts a row on screen nobody typed.
pub(crate) const IMPORT_ACTOR: &str = "import";

/// The `txn.begin` reason `revise::dispatch_layer` opens its track-preparation
/// unit with. Read back out of the journal to know that a track exists because
/// somebody asked for a layer.
///
/// A REASON rather than an actor, because `studio_layer` is dispatched under
/// whatever actor called the tool — `Actor::user("app")` from the GUI, the
/// agent's own name over MCP — so the actor says who, not what. The reason says
/// what, it is already journaled on every layer, and it is the same string the
/// undo stack shows the user. Named here, once, for the same reason
/// `PERFORMANCE_ACTOR` is: two copies of a magic string is how a derived
/// sentence quietly stops being derived.
pub(crate) const LAYER_TXN_REASON: &str = "add-a-layer track";

/// The snapshot's words for a track the app made itself. The UI decodes these
/// strings; they are a contract, so each is named once and used at both ends of
/// the injection.
const TRACK_ORIGIN_PLAYED: &str = "played";
const TRACK_ORIGIN_LAYERED: &str = "layered";
const TRACK_ORIGIN_IMPORTED: &str = "imported";

impl StudioHost {
    /// An in-memory host (no package on disk): tests, quick agent sessions,
    /// and the FFI before a project.new/open. Journals to memory.
    pub fn in_memory() -> Self {
        Self {
            session: timeline_core::Session::new(default_project(None)),
            data_dir: None,
            package_dir: None,
            sources: HashMap::new(),
            transport: Transport::default(),
            declick: DeclickPolicy::Auto,
            live: None,
            audible_output: false,
            live_render_error: None,
            record: RecordState::default(),
            performance: None,
            auto_created_instrument_track: None,
            auto_create_holdoff_keys: std::collections::BTreeSet::new(),
            keys_down: std::collections::BTreeSet::new(),
            warp_cache: WarpCache::new(),
            open_recovery: OpenRecovery::default(),
            midi: MidiState::new(None),
        }
    }

    /// Initialize with a base data directory (FFI entry). Does not open a
    /// project yet; project.new/open switch to a package on disk under it.
    pub fn with_data_dir(dir: impl Into<PathBuf>) -> Result<Self, StudioError> {
        let dir = dir.into();
        if !dir.is_absolute() {
            return Err(StudioError::invalid("data_dir must be an absolute path"));
        }
        std::fs::create_dir_all(&dir).map_err(StudioError::io)?;
        Ok(Self {
            data_dir: Some(dir.clone()),
            midi: MidiState::new(Some(&dir)),
            ..Self::in_memory()
        })
    }

    /// Create a new `.mstudio` package named `name` under `dir` and open it
    /// (`<dir>/<name>.mstudio`).
    ///
    /// The path is made UNIQUE first. Two projects called "Song" used to resolve
    /// to one directory, and `Package::create` answered that by truncating the
    /// journal — so "New Project" with a name the user had already used silently
    /// destroyed the earlier project, no failure required, just a name typed
    /// twice. `Package::create` now refuses instead of destroying, but a refusal
    /// is only the floor: a person naming a second song after the first has done
    /// nothing wrong, so the second one gets "Song 2.mstudio" and both exist.
    pub fn create_package(dir: impl AsRef<Path>, name: &str) -> Result<Self, StudioError> {
        let pkg = unique_package_path(dir.as_ref(), &sanitize_name(name));
        Self::create_at(pkg, name)
    }

    /// Create a package at an explicit directory path (the CLI's `--project`).
    pub fn create_at(pkg_dir: impl AsRef<Path>, name: &str) -> Result<Self, StudioError> {
        let pkg = pkg_dir.as_ref().to_path_buf();
        std::fs::create_dir_all(&pkg).map_err(StudioError::io)?;
        let session = Package::create(&pkg, default_project(Some(name)))?;
        Ok(Self {
            session,
            data_dir: pkg.parent().map(Path::to_path_buf),
            package_dir: Some(pkg.clone()),
            sources: HashMap::new(),
            transport: Transport::default(),
            declick: DeclickPolicy::Auto,
            live: None,
            audible_output: false,
            live_render_error: None,
            record: RecordState::default(),
            performance: None,
            auto_created_instrument_track: None,
            auto_create_holdoff_keys: std::collections::BTreeSet::new(),
            keys_down: std::collections::BTreeSet::new(),
            warp_cache: WarpCache::new(),
            open_recovery: OpenRecovery::default(),
            midi: MidiState::new(pkg.parent()),
        })
    }

    /// Open the package at `pkg_dir` if there is a project there, else create it.
    ///
    /// This is the app's EVERY-LAUNCH path (`ffi::initialize` ->
    /// `StudioEngineFactory.defaultProjectPath`), so what it decides on matters
    /// more than anything else in this file.
    ///
    /// It used to decide on `project.json` alone, and `Package::create` opens
    /// the journal with `File::create`, which truncates. A package with an
    /// intact `journal.jsonl` and no checkpoint is a FULLY RECOVERABLE project —
    /// the journal is the truth and the checkpoint is only a fast-open cache —
    /// and the answer to finding one was to overwrite the truth with an empty
    /// file and call it a new project. No warning, no backup, nothing to undo.
    /// That state is not exotic: `Package::create` itself writes the journal
    /// before the first checkpoint, so any failure in between (disk full,
    /// permissions, power loss on first run) leaves exactly it, and so does a
    /// backup tool or a partial restore that carried one file and not the other.
    ///
    /// So the decision is made on the JOURNAL first. A non-empty journal means
    /// there is a project here, whatever else is or is not on disk, and
    /// `Package::open` already knows how to rebuild a session from one — its
    /// full-replay fallback is the same path a `kill -9` takes. Recovery here is
    /// therefore reuse of an existing, tested path, not new machinery, and it
    /// needs no new command.
    pub fn open_or_create(pkg_dir: impl AsRef<Path>, name: &str) -> Result<Self, StudioError> {
        let pkg = pkg_dir.as_ref().to_path_buf();
        if has_project_on_disk(&pkg) {
            Self::open_package(&pkg)
        } else {
            Self::create_at(&pkg, name)
        }
    }

    /// Open an existing `.mstudio` package and decode its audio assets.
    pub fn open_package(dir: impl AsRef<Path>) -> Result<Self, StudioError> {
        let pkg = dir.as_ref().to_path_buf();
        let (session, open_recovery) = Package::open_reporting(&pkg)?;
        let mut host = Self {
            session,
            data_dir: pkg.parent().map(Path::to_path_buf),
            package_dir: Some(pkg.clone()),
            sources: HashMap::new(),
            transport: Transport::default(),
            declick: DeclickPolicy::Auto,
            live: None,
            audible_output: false,
            live_render_error: None,
            record: RecordState::default(),
            performance: None,
            auto_created_instrument_track: None,
            auto_create_holdoff_keys: std::collections::BTreeSet::new(),
            keys_down: std::collections::BTreeSet::new(),
            warp_cache: WarpCache::new(),
            open_recovery,
            midi: MidiState::new(pkg.parent()),
        };
        host.load_audio_dir(&pkg)?;
        Ok(host)
    }

    /// What the last open of this host's package had to do to rebuild it. All
    /// defaults = an ordinary reopen with nothing to report.
    pub fn open_recovery(&self) -> &OpenRecovery {
        &self.open_recovery
    }

    /// `open_recovery` as the wire shape the app reads. camelCase to match every
    /// other JSON this host hands the Swift side.
    pub fn open_recovery_json(&self) -> Value {
        let r = &self.open_recovery;
        json!({
            "noteworthy": r.is_noteworthy(),
            "checkpointMissing": r.checkpoint_missing,
            "replayedFromJournal": r.replayed_from_journal,
            "commandsRecovered": r.commands_recovered,
            "tornTailDropped": r.torn_tail_dropped,
            "corruptLinesDropped": r.corrupt_lines_dropped,
            "quarantinedJournal": match &r.quarantined_journal {
                Some(p) => Value::String(p.display().to_string()),
                None => Value::Null,
            },
            "checkpointAheadOfJournal": r.checkpoint_ahead_of_journal,
        })
    }

    /// Decode every asset under `<pkg>/audio/` into the sources map, keyed by
    /// the content hash (the filename stem before the first dot).
    fn load_audio_dir(&mut self, pkg: &Path) -> Result<(), StudioError> {
        let audio = pkg.join("audio");
        let Ok(entries) = std::fs::read_dir(&audio) else {
            return Ok(());
        };
        for e in entries.flatten() {
            let path = e.path();
            if !path.is_file() {
                continue;
            }
            let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
                continue;
            };
            let hash = name.split('.').next().unwrap_or(name).to_string();
            if hash.len() != 64 {
                continue;
            }
            let buf = load_wav_stereo_48k(&path).map_err(StudioError::audio)?;
            self.sources.insert(hash, Arc::new(buf));
        }
        Ok(())
    }

    pub fn package_dir(&self) -> Option<&Path> {
        self.package_dir.as_deref()
    }

    /// The base data directory `.mstudio` packages live under (the FFI init
    /// dir's parent). L8 lands a new "Open in Studio" package here, then opens
    /// it as the active project.
    pub fn data_dir(&self) -> Option<&Path> {
        self.data_dir.as_deref()
    }

    /// Open the package at `path` as this host's active project (host-io swap;
    /// the same path `project.open` takes). Used by the landing bridge to make
    /// a freshly built session the live one.
    pub fn open_project_path(&mut self, path: &str) -> Result<(), StudioError> {
        self.host_project_open(path)
    }

    pub fn seq(&self) -> u64 {
        self.session.seq()
    }

    pub fn set_declick(&mut self, policy: DeclickPolicy) {
        self.declick = policy;
    }

    // -----------------------------------------------------------------------
    // The command bus entry (all transports funnel here).
    // -----------------------------------------------------------------------

    /// Submit a wire envelope `{name, params}` from `actor`, routing the few
    /// host-io commands (project lifecycle, import, export) and passing every
    /// other command straight to the timeline-core bus. Returns a result JSON.
    pub fn submit(
        &mut self,
        actor: Actor,
        name: &str,
        params: Value,
    ) -> Result<Value, StudioError> {
        // Workers only prepare media. Reap their ordered results between bus
        // commands and perform the short atomic journal tail on this owner.
        if name != "record.rotate" { self.reap_record_landings(false); }
        match name {
            "project.save" => {
                self.save()?;
                Ok(json!({ "ok": true, "seq": self.seq() }))
            }
            "project.new" => {
                let pname = str_param(&params, "name")?;
                self.host_project_new(&pname)?;
                Ok(json!({ "ok": true, "package": self.package_dir_display(), "seq": self.seq() }))
            }
            "project.open" => {
                let path = str_param(&params, "path")?;
                self.host_project_open(&path)?;
                Ok(json!({ "ok": true, "package": self.package_dir_display(), "seq": self.seq() }))
            }
            "import.audio" => {
                let outcome = self.import_audio_params(&params)?;
                let mut out = outcome.to_json();
                // SAY WHAT WAS IGNORED. `import.audio` advertises `separate`
                // ("run htdemucs on import and place stems as separate tracks")
                // and `conform` ("time-stretch the imported audio to the project
                // tempo"), and `import_audio_params` reads NEITHER — so
                // `separate: true` returned ok, landed one ordinary clip, and
                // left the caller believing four stem tracks existed. A person
                // sees one clip appear and knows; an agent gets `ok: true` and a
                // clip id and has nothing to notice.
                //
                // REFUSING them is not available: `apply.rs` runs on replay and
                // narrowing what a journaled command accepts breaks reopening any
                // project that ever passed one. So the honest move is additive —
                // the RESULT names the ignored flag and the thing that does do
                // the job. Results are never replayed, so this costs nothing.
                let ignored: Vec<&str> = ["separate", "conform"]
                    .into_iter()
                    .filter(|k| params.get(*k).and_then(Value::as_bool) == Some(true))
                    .collect();
                if !ignored.is_empty() {
                    if let Value::Object(m) = &mut out {
                        m.insert("ignoredParams".into(), json!(ignored));
                        m.insert("ignoredParamsNote".into(), json!(
                            "These parameters are declared in the catalog and are NOT implemented by \
                             import.audio: the file was imported and placed as one ordinary clip. \
                             For stem separation use studio_open_in_studio (beat-tracked tempo, \
                             separation, bar-aligned stem tracks with lineage) or import.stems with \
                             stems you separated yourself. To fit imported audio to the project \
                             tempo, place it and then set clip.warp.set with mode 'conform'."
                        ));
                    }
                }
                Ok(out)
            }
            // `gen.song` has the SAME defect `import.audio` had, one field over.
            // The catalog and `studio_gen_song`'s schema both make
            // `insertAtTicks` REQUIRED, and nothing reads it: `apply.rs` matches
            // `Cmd::GenSong { track_id, .. }` and records the request, and the
            // song is placed later by whoever handles the landing — `landing.rs`
            // computes its own lead-in and never consults the value it wrote.
            // An agent that asks for a song at bar 9 gets one at bar 1 and is
            // told `ok`.
            //
            // Same remedy, same reason: the parameter cannot be refused (it is
            // journaled and replayed), so the RESULT names it. A zero is the
            // "no opinion" value and stays quiet, so the advisory only appears
            // when the caller actually asked for a position.
            "gen.song" => {
                let asked = params
                    .get("insertAtTicks")
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
                let mut out = self.bus_submit(actor, name, params)?;
                if asked != 0 {
                    if let Value::Object(m) = &mut out {
                        m.insert("ignoredParams".into(), json!(["insertAtTicks"]));
                        m.insert("ignoredParamsNote".into(), json!(
                            "insertAtTicks is declared in the catalog and is NOT implemented by \
                             gen.song: the request is recorded, and where the result lands is \
                             decided when the take is placed, not here. To control the position, \
                             promote the take onto a clip you placed (take.promote), or place the \
                             landed asset with clip.place at the tick you want."
                        ));
                    }
                }
                Ok(out)
            }
            "import.stems" => self.import_stems_params(&params),
            "export.master" => self.host_export_master(&params),
            "export.region" => self.host_export_region(&params),
            "export.stems" => self.host_export_stems(&params),
            "export.manifest" => self.host_export_manifest(actor, &params),
            "publish.track" => self.host_publish(actor, &params),
            // Transport: validate on the bus, update the tracked view, and (when
            // live) mirror it onto the audio thread as a frame-domain command.
            "transport.play" | "transport.stop" | "transport.seek" | "transport.loop.set"
            | "transport.loop.clear" | "transport.metronome" => {
                self.bus_submit(actor, name, params.clone())?;
                self.apply_transport(name, &params);
                self.forward_transport_live(name, &params);
                Ok(json!({ "ok": true, "transport": self.transport_json() }))
            }
            // Record: validate on the bus (an unjournaled no-op at the model
            // layer), then run the host-side capture effect. The take + clip that
            // record.stop lands is the journaled, undoable unit.
            "record.start" | "record.rotate" | "record.stop" | "record.cancel"
            | "record.inputListen" => {
                self.bus_submit(actor, name, params.clone())?;
                self.apply_record(name, &params)
            }
            // MIDI: validate on the bus (an unjournaled no-op at the model
            // layer), then run the host-side config effect. Mirrors record.*.
            name if name.starts_with("midi.") => {
                self.bus_submit(actor, name, params.clone())?;
                self.midi.apply(name, &params)
            }
            // Everything else is a pure bus command. Arming a track refreshes the
            // cached input-device list so the UI's device picker is current, and
            // may open a listen-only input stream for gain-staging (no landing).
            _ => {
                let is_arm = name == "track.arm";
                let sub = self.bus_submit(actor, name, params)?;
                if is_arm {
                    self.refresh_input_devices();
                    self.sync_input_listen();
                }
                Ok(sub)
            }
        }
    }

    /// The plain bus path: mint meta, submit, map the report to JSON.
    fn bus_submit(
        &mut self,
        actor: Actor,
        name: &str,
        params: Value,
    ) -> Result<Value, StudioError> {
        let meta = ulid::entry_meta(actor);
        let sub = self.session.submit_json(meta, name, params)?;
        self.sync_after_mutation();
        Ok(json!({
            "ok": true,
            "command": name,
            "seq": sub.seq,
            "journaled": sub.journaled,
            "mutated": sub.mutated,
            "duplicate": sub.duplicate,
            // The command SUCCEEDED — it is applied, journaled and undoable —
            // but if the live engine could not take the new session, say so on
            // the very command that caused it. `null` is the normal case.
            // Without this an agent gets `ok: true` while playback is frozen on
            // a stale session, which is the failure this field exists to end.
            "liveRenderError": self.live_render_error,
        }))
    }

    /// Roll the open transaction back, journaling the compensation under
    /// `actor` so a replay of this journal lands exactly where the live project
    /// just landed (see `Session::abort_txn`). Every failure path inside a
    /// bracket goes through here.
    ///
    /// The rollback's own result is swallowed, as it was at all five call sites
    /// before this existed: each of them is already returning the error that
    /// caused the abort, and "the compensation for the failure also failed" is
    /// not a better thing to tell the caller. The frame is closed either way,
    /// so the session cannot wedge.
    fn rollback_txn(&mut self, actor: Actor) {
        let mut meta = ulid::UlidMeta::new(actor);
        let _ = self.session.abort_txn(&mut meta);
    }

    fn sync_after_mutation(&mut self) {
        // When a live session is open, every edit recompiles the render session
        // and pushes it (plus current mixer params) to the audio thread, so
        // live playback tracks the model. A compile hiccup (e.g. an
        // intermediate edit that momentarily references an unloaded source) is
        // swallowed here: the next successful mutation re-pushes, and the bus is
        // never broken by a live recompile. The offline bounce recompiles
        // independently on demand.
        self.push_live_session();
    }

    // -----------------------------------------------------------------------
    // Live audio (the I1 "it's real" surface).
    //
    // The render `Engine` (and its !Send cpal Stream) lives on a dedicated
    // audio-host thread inside `LiveAudio`; the host holds only a Send handle
    // and drives it through the same command bus everything else uses. Starting
    // a live session is explicit (the FFI `start_live`, a user pressing play);
    // nothing here auto-opens a device, and the stream is silent by default.
    // -----------------------------------------------------------------------

    /// Enable (or disable) AUDIBLE live output for this host. Silent by default;
    /// the GUI app calls this once at launch (before the first Play opens the
    /// stream) so a user pressing Play is heard. The CLI, tests, and
    /// headless/CI runs never call it, so they keep the device silent (the
    /// automated-blast safety). Takes effect on the next `start_live` (and any
    /// device-switch rehydrate, since the flag rides the engine config).
    pub fn set_audible_output(&mut self, audible: bool) {
        self.audible_output = audible;
    }

    /// Open a live audio session on the default output device and prime it with
    /// the current project + transport. Idempotent: a second call returns the
    /// running stream's info. Silent at the device unless the GUI opted in via
    /// `set_audible_output` (or `MAJIKS_TEST_AUDIBLE=1` was set) before the
    /// stream was built (render::engine audio-safety rule).
    pub fn start_live(&mut self) -> Result<Value, StudioError> {
        if self.live.is_some() {
            return Ok(self.live_info_json());
        }
        let default_tracks = EngineConfig::default().max_tracks;
        let (sample_rate, max_tracks) = {
            let p = self.session.project();
            (p.sample_rate, p.tracks.len().max(default_tracks))
        };
        let cfg = EngineConfig {
            sample_rate,
            max_tracks,
            // Carry the GUI's explicit audibility opt-in into the render engine
            // BEFORE the live stream is built. Default false keeps every non-GUI
            // context silent.
            audible: self.audible_output,
            ..EngineConfig::default()
        };
        let live = LiveAudio::start(cfg)?;
        self.live = Some(live);
        // Prime the engine with the current session, mixer params, and the
        // tracked transport (position, loop, play state) so starting live
        // mid-session is seamless.
        self.push_live_session();
        self.prime_live_transport();
        Ok(self.live_info_json())
    }

    /// Close the live audio session if one is open. Dropping the handle sends
    /// Shutdown and joins the audio thread, so the device is released before
    /// this returns. Returns whether a session was actually closed.
    pub fn stop_live(&mut self) -> bool {
        self.live.take().is_some()
    }

    pub fn is_live(&self) -> bool {
        self.live.is_some()
    }

    /// The no-hardware PORT seam — the companion to `midi::feed_event` (spec
    /// 11). `feed_event` injects an event as if a device sent it; this declares
    /// the device PRESENT, so the snapshot's port row (its resolved map, its
    /// role, and which of its bindings that role suppresses) can be asserted
    /// headlessly. The real pump overwrites this table on its next scan.
    pub fn midi_declare_port(&self, name: &str, connected: bool) {
        if let Ok(mut ports) = self.midi.shared.ports.lock() {
            ports.retain(|p| p.name != name);
            ports.push(crate::midi::PortState {
                name: name.to_string(),
                connected,
            });
        }
    }

    /// Which track a MIDI keyboard's keys play, or `None` when the project has
    /// no instrument yet.
    ///
    /// The rule, in order, chosen to be predictable rather than clever:
    /// 1. the first ARMED track that carries an instrument device — arming is
    ///    the existing "this is the track I am playing into" gesture; then
    /// 2. the first track that carries an instrument device at all, which makes
    ///    the overwhelmingly common one-instrument project unambiguous.
    /// The MIDI subsystem's shared state (port table, registry, counters, and
    /// the running pump's event inlet). Handed out as an `Arc` deliberately: a
    /// caller measuring or driving MIDI must be able to hold it WITHOUT holding
    /// the host lock, or the measurement would be of its own contention.
    pub fn midi_shared(&self) -> std::sync::Arc<crate::midi::MidiShared> {
        std::sync::Arc::clone(&self.midi.shared)
    }

    pub fn midi_instrument_target(&self) -> Option<String> {
        let tracks = &self.session.project().tracks;
        tracks
            .iter()
            .find(|t| t.armed && !t.devices.is_empty())
            .or_else(|| tracks.iter().find(|t| !t.devices.is_empty()))
            .map(|t| t.id.clone())
    }

    /// The track a played note goes to, CREATING one when the project has no
    /// instrument at all.
    ///
    /// # Why an empty project creates a track on the first key
    ///
    /// The app already sees hardware note events before any track exists
    /// (Settings ▸ MIDI shows a live monitor of them), so it knows perfectly
    /// well that a person is playing — it just had nowhere to send it and went
    /// silent. Requiring the user to first find and press an "Instrument" button
    /// is a click that only exists because of how the project model is shaped;
    /// it teaches nothing and it is the difference between a keyboard that works
    /// and one that appears broken.
    ///
    /// This is the ONE journaled side effect on the play-a-note path. It is a
    /// single undo step (`track.add` + `device.add` inside a txn), and it does
    /// NOT place a clip: a clip is a commitment to keeping something, and at
    /// this point the user has only asked to hear something.
    /// `performance_keep` places the clip if and when they decide to keep the
    /// take.
    ///
    /// # The rule is STATE-BASED, not once-per-project
    ///
    /// The condition is "the project has no instrument track", asked afresh on
    /// every note. It is emphatically NOT "we have already done this once" —
    /// that rule breaks the moment a user removes the instrument they were
    /// given (Remove Instrument in the track header) and plays again: the
    /// keyboard would go silent for the rest of the project's life with no
    /// affordance anywhere to bring it back.
    ///
    /// This doc comment used to claim "at most once per project" while the code
    /// below already asked the state question. The comment was the wrong half:
    /// the tests in `play_a_note.rs` now pin the state-based reading so a future
    /// reader cannot "fix" the code to match a stale sentence.
    ///
    /// Note-OFF never reaches here (see `preview_note` and
    /// `dispatch_note_to_instrument`): a stray key-up must not conjure a track.
    /// For the undo interaction, see [`Self::instrument_target_for_note`] — this
    /// method itself is unconditional and always creates when there is nothing.
    pub fn ensure_instrument_target(&mut self) -> Result<String, StudioError> {
        if let Some(existing) = self.midi_instrument_target() {
            return Ok(existing);
        }
        let index = self.session.project().tracks.len();
        let track_id = format!("t_{}", ulid::new_ulid());
        let device_id = format!("inst_{}", ulid::new_ulid());
        let txn_id = format!("first_inst_{}", ulid::new_ulid());
        // The literal used to be spelled here. It is a CONSTANT now because the
        // snapshot reads it back to tell the user this track was made when they
        // played (`performance_created_tracks`), and two copies of a magic
        // string is how that quietly stops being true.
        let actor = || ulid::entry_meta(Actor::user(PERFORMANCE_ACTOR));

        self.session.submit_json(
            actor(),
            "txn.begin",
            json!({"txnId": txn_id, "reason": "play.firstInstrument"}),
        )?;
        let built = (|| -> Result<(), StudioError> {
            self.session.submit_json(
                actor(),
                "track.add",
                json!({
                    "trackId": track_id,
                    "name": format!("Instrument {}", index + 1),
                    "index": index,
                }),
            )?;
            // `deviceId` must not contain '.', or the ParamRef path
            // `track.device.<deviceId>.<paramKey>` stops parsing. A ULID is safe.
            self.session.submit_json(
                actor(),
                "device.add",
                json!({ "trackId": track_id, "deviceId": device_id, "kind": "synth" }),
            )?;
            Ok(())
        })();
        if let Err(e) = built {
            self.rollback_txn(Actor::user(PERFORMANCE_ACTOR));
            return Err(e);
        }
        self.session
            .submit_json(actor(), "txn.commit", json!({"txnId": txn_id}))?;
        self.sync_after_mutation();
        self.auto_created_instrument_track = Some(track_id.clone());
        Ok(track_id)
    }

    /// Every track that exists because the APP made it rather than the user,
    /// and WHY — read out of the journal.
    ///
    /// # Why this is a view over the chain and not a field
    ///
    /// `auto_created_instrument_track` above is deliberately NOT the answer. It
    /// holds one id, it is cleared on undo, and it is in-memory — reopen the
    /// project tomorrow and it knows nothing. The journal knows: `track.add`
    /// carries `actor` (one of the seven hashed envelope fields), and the
    /// enclosing `txn.begin` carries `reason`. Both are already written down,
    /// permanently, so the UI's sentence is derived from what happened rather
    /// than kept alongside it. Same reasoning as `clip_origins` (`export.rs`),
    /// and the same reason: a parallel flag is a thing that can disagree with
    /// the facts.
    ///
    /// # The three cases, and why each is read the way it is
    ///
    /// * **played** — `ensure_instrument_target` is the ONLY place in the tree
    ///   that submits under `Actor::user("performance")` (the record path uses
    ///   `"record"`, the app uses its own), so the actor alone is decisive.
    /// * **layered** — `revise::dispatch_layer` runs under the CALLER's actor,
    ///   which is `"app"` from the GUI and the agent's own name over MCP, so
    ///   the actor cannot tell a layer track from a track the user added by
    ///   hand. Its `txn.begin` reason can, and does: `LAYER_TXN_REASON`.
    /// * **imported** — `import_stems_params` mints one track per stem file
    ///   past the first under `Actor::user("import")`, outside any txn. Note
    ///   that `import_audio` also runs under that actor but never adds a track,
    ///   so there is nothing here for an ordinary import to mark.
    ///
    /// Deliberately NOT marked: the four tracks `landing` builds and the clip
    /// `land_midi_capture` lands. Those sit inside gestures that plainly ask
    /// for them ("Open in Studio", "Keep") and already say what they made — a
    /// note explaining a thing the user just requested is noise, not
    /// provenance. `landing` submits under the caller's actor with no txn
    /// reason, so it falls through to `None` here without a special case.
    ///
    /// Bounded to the tracks still in the project by the caller, and it survives
    /// undo-then-redo on purpose: redo re-applies `track.add` with the same id,
    /// and a track that came back is still the track that was made when you
    /// played.
    ///
    /// ONE journal pass, because this is a 30 Hz path — the same discipline as
    /// `clip_origins` next to it.
    fn track_origins(&self) -> std::collections::HashMap<&str, &'static str> {
        let mut origins = std::collections::HashMap::new();
        // The reason of the txn currently open, if any. `txn.begin` /
        // `txn.commit` are ordinary journaled records, so the bracket is
        // readable from the chain alone. An abort never reaches the journal
        // (the entries are rolled back with it), so there is nothing to clear.
        let mut open_reason: Option<&str> = None;
        for e in self.session.journal().iter() {
            match e.name.as_str() {
                "txn.begin" => open_reason = e.params.get("reason").and_then(Value::as_str),
                "txn.commit" => open_reason = None,
                "track.add" => {
                    let Some(id) = e.params.get("trackId").and_then(Value::as_str) else {
                        continue;
                    };
                    let origin = if e.actor.name == PERFORMANCE_ACTOR {
                        Some(TRACK_ORIGIN_PLAYED)
                    } else if open_reason == Some(LAYER_TXN_REASON) {
                        Some(TRACK_ORIGIN_LAYERED)
                    } else if e.actor.name == IMPORT_ACTOR {
                        Some(TRACK_ORIGIN_IMPORTED)
                    } else {
                        None
                    };
                    if let Some(origin) = origin {
                        origins.insert(id, origin);
                    }
                }
                _ => {}
            }
        }
        origins
    }

    /// The track a played NOTE-ON should sound on, applying the auto-create
    /// policy. `Ok(None)` means "nothing to play on, and creating one right now
    /// would be fighting the user" — the caller reports that rather than
    /// creating.
    ///
    /// The only case that returns `None` is the undo one: the user took back
    /// the track a played note had just created, and their fingers are still on
    /// the keys, so the note-ons queued behind them must not rebuild it. See
    /// `auto_create_held_off`. Lift the keys and the next press creates again.
    pub fn instrument_target_for_note(&mut self) -> Result<Option<String>, StudioError> {
        if let Some(existing) = self.midi_instrument_target() {
            // An instrument exists again (played, added by hand, or restored by
            // redo). Nothing left to hold off.
            self.auto_create_holdoff_keys.clear();
            return Ok(Some(existing));
        }
        if !self.auto_create_holdoff_keys.is_empty() {
            return Ok(None);
        }
        self.ensure_instrument_target().map(Some)
    }

    /// Record one note gate as it arrives, BEFORE anything decides whether it
    /// can be played. Called by every note surface (hardware pump, on-screen
    /// keys, roll gutter, agents) so a key-up still registers when the note
    /// itself is being refused — see `keys_down` and `auto_create_holdoff_keys`.
    ///
    /// `"on"` holds, `"off"` releases, and a one-shot holds nothing: a click has
    /// no key-up and must not leave a pitch stuck down forever.
    pub fn observe_note_gate(&mut self, pitch: u8, gate: &str) {
        match gate {
            "on" => {
                self.keys_down.insert(pitch);
            }
            "off" => {
                self.keys_down.remove(&pitch);
                // A key that has been LIFTED is no longer one of the keys the
                // undo was protecting, so re-pressing it counts as fresh.
                self.auto_create_holdoff_keys.remove(&pitch);
            }
            _ => {}
        }
    }

    /// Called after every undo/redo: if the auto-created instrument track has
    /// just left the project under the user's fingers, disarm auto-create until
    /// those fingers come up.
    fn note_auto_create_undo(&mut self) {
        let Some(track) = self.auto_created_instrument_track.clone() else { return };
        let still_there = self
            .session
            .project()
            .tracks
            .iter()
            .any(|t| t.id == track);
        if still_there {
            return;
        }
        self.auto_created_instrument_track = None;
        self.auto_create_holdoff_keys = self.keys_down.clone();
    }

    /// Bring the output device up because a human is PLAYING AN INSTRUMENT.
    ///
    /// # Why this is allowed, when opening a monitor stream is not
    ///
    /// The house audio-safety rule (`render::recording::monitoring_allowed`,
    /// still returning false, untouched by this lane) exists to stop ONE thing:
    /// a live MICROPHONE reaching the speakers. That is a closed acoustic loop —
    /// mic → speaker → mic — which builds to a howl on its own, needs no further
    /// user action once armed, and can hurt ears and drivers. It is a genuine
    /// hazard and it stays refused.
    ///
    /// An instrument note is not that shape. Its signal originates in a
    /// deterministic oscillator inside the render graph, in response to one
    /// discrete human gesture, with no input transducer anywhere in the path.
    /// There is no loop to close. It cannot start unattended — no key, no sound —
    /// and it ends itself (a one-shot releases; a held note releases on key-up).
    /// The two cases share the word "monitoring" and nothing else.
    ///
    /// The blast-safety property that actually matters is preserved intact:
    /// **only the GUI ever opts into audible output.** `audible_output` is set by
    /// `set_audible_output`, which the Swift app calls at launch and which the
    /// CLI, `cargo test`, `swift test`, and every headless/CI run never call. So
    /// this method is a no-op in all of them, and an MCP agent talking to a
    /// headless host still cannot make a machine sing. What changes is only the
    /// *moment* the GUI's already-granted permission takes effect: the first note
    /// instead of the first Play.
    ///
    /// Deliberately NOT gated on `MAJIKS_TEST_AUDIBLE` — that flag forces the
    /// render engine audible for the attended `engine_proof` run, and letting it
    /// also trigger a device open here would widen the blast radius for no gain.
    ///
    /// `None` when a live session is running afterwards; otherwise the sentence
    /// saying why it is not, ready to be reported to the caller verbatim.
    ///
    /// The device opening on a first note is deliberately NOT announced — see
    /// `preview_note`, which is where the decision is written down. What IS
    /// announced is the FAILURE, and it used to go to `eprintln!` and nowhere
    /// else: the caller was handed a flat "the output device could not be
    /// opened" while the sentence naming the actual cause (device in use by
    /// another app, sample rate refused, no output hardware) was printed to a
    /// stderr no GUI user has open. Silence about a reason we already had is
    /// the same defect as silence about a track we already made.
    fn ensure_live_for_performance(&mut self) -> Option<String> {
        if self.live.is_some() {
            return None;
        }
        if !self.audible_output {
            return Some(
                "this host is not configured for audible output \
                 (set_audible_output was never called), so playing a note does not open a device"
                    .to_string(),
            );
        }
        match self.start_live() {
            Ok(_) => None,
            Err(e) => Some(format!("the output device could not be opened: {e}")),
        }
    }

    /// Buffer one played note into the retro-capture buffer, opening the buffer
    /// on the first note. `off_ticks` is `None` for a held note (closed by a
    /// later note-off) and `Some(len)` for a one-shot, which has no key-up.
    ///
    /// No-op while a real `record.start` take is open: that take owns the input,
    /// and two buffers landing the same performance twice is worse than none.
    fn performance_note(&mut self, track_id: &str, pitch: u8, velocity: u8, gate: &str, hold_ticks: u64) {
        if self.record.midi.is_some() {
            self.performance = None;
            return;
        }
        let now = self.performance_now_ticks();
        let (bpm_num, bpm_den, window) = {
            let bpm = self.session.project().tempo.first_bpm();
            (
                bpm.num,
                bpm.den,
                PERFORMANCE_WINDOW_BEATS.saturating_mul(u64::from(timeline_core::PPQ)),
            )
        };
        let buf = self.performance.get_or_insert_with(|| {
            MidiCapture::new(track_id.to_string(), now, None, bpm_num, bpm_den)
        });
        // A buffer that has emptied (kept, trimmed away, or invalidated) is a
        // fresh performance: re-anchor it so its wall clock restarts here rather
        // than stamping the new notes however many minutes past the old origin.
        if buf.is_empty() {
            buf.reanchor(now);
        }
        if buf.track_id != track_id {
            // The player moved to a different instrument. The previous buffer
            // belongs to the previous track and cannot be landed onto this one.
            buf.clear();
            buf.reanchor(now);
            buf.track_id = track_id.to_string();
        }
        match gate {
            "off" => buf.note_off(pitch, now),
            "on" => buf.note_on(pitch, velocity, now),
            _ => {
                // A one-shot has no key-up, so it is buffered complete: on now,
                // off after exactly the length it will actually sound for.
                buf.note_on(pitch, velocity, now);
                buf.note_off(pitch, now.saturating_add(hold_ticks.max(1)));
            }
        }
        buf.trim_completed_before(now.saturating_sub(window));
        buf.cap_completed(PERFORMANCE_MAX_NOTES);
    }

    /// Absolute project ticks for stamping a retro-captured note. Same rule as
    /// the record path (`midi_capture_now_ticks`): the live play head while the
    /// transport is advancing, otherwise a wall clock from the buffer's origin
    /// so a performance without an explicit Play still lands on the grid.
    fn performance_now_ticks(&mut self) -> u64 {
        // 1. Deterministic override (tests driving a melody without sleeping).
        //    Consumed, exactly like the record path's, so a test sets one tick
        //    per event rather than pinning every note to the same instant.
        if let Some(buf) = self.performance.as_mut() {
            if let Some(t) = buf.take_override() {
                return t;
            }
        }
        // 2. The live play head while the transport is advancing.
        if let Some(live) = self.live.as_ref() {
            if live.playing() {
                let rate = self.session.project().sample_rate;
                let tempo = &self.session.project().tempo;
                return tempo.frame_to_tick(live.position_frame(), rate);
            }
        }
        // 3. Wall clock from the buffer's origin, so a performance with no
        //    transport Play still lands at the ticks that were played.
        match self.performance.as_ref() {
            Some(buf) => buf.wall_now_ticks(),
            None => self.transport.position_ticks,
        }
    }

    /// Deterministic retro-capture clock for tests (absolute project ticks).
    /// The buffer must already exist (play one note first).
    #[doc(hidden)]
    pub fn performance_set_now_ticks(&mut self, ticks: u64) {
        if let Some(buf) = self.performance.as_mut() {
            buf.set_now_ticks(ticks);
        }
    }

    /// What the UI needs to show the difference between HEARING and KEEPING.
    ///
    /// `sounding` is the set of keys physically down right now, read from the
    /// same buffer the audio came from rather than from a parallel UI guess —
    /// so a lit key means "this is making sound", not "we think we sent one".
    fn performance_json(&self) -> Value {
        let Some(buf) = self.performance.as_ref() else {
            return json!({
                "keepableNotes": 0,
                "sounding": Vec::<u8>::new(),
                "trackId": Value::Null,
                "startTicks": Value::Null,
                "endTicks": Value::Null,
            });
        };
        json!({
            "keepableNotes": buf.completed_len(),
            "sounding": buf.sounding_pitches(),
            "trackId": buf.track_id,
            "startTicks": buf.first_on_ticks(),
            "endTicks": buf.first_on_ticks().map(|_| buf.end_ticks()),
        })
    }

    /// End of the last clip on any track, in TICKS — "how far the music this
    /// project already contains actually goes".
    ///
    /// Deliberately not `content_end_frame`: the retro-capture buffer stamps in
    /// ticks, and converting frames back through the tempo map to compare would
    /// introduce rounding into a comparison that is about musical position.
    fn content_end_ticks(&self) -> u64 {
        self.session
            .project()
            .tracks
            .iter()
            .flat_map(|t| t.clips.iter())
            .map(|c| c.end_ticks())
            .max()
            .unwrap_or(0)
    }

    fn ticks_per_bar(&self) -> u64 {
        let ts = &self.session.project().time_sig;
        let beats = u64::from(ts.numerator.max(1));
        let per_beat = u64::from(timeline_core::PPQ) * 4 / u64::from(ts.denominator.max(1));
        (beats * per_beat).max(1)
    }

    /// WHERE a kept performance goes, and why it is not simply "wherever the
    /// clock said".
    ///
    /// The bug this exists for: a person played a two-handed 56-note passage
    /// and pressed Keep. The notes were perfect and the clip landed at tick
    /// 4,128,895 — **bar 1076**, 1,075 bars past everything else in the
    /// project, off screen, with no indication it had happened. The transport
    /// had been left rolling for about 36 minutes, and both branches of
    /// `performance_now_ticks` are unbounded monotonic clocks: the live play
    /// head, or a wall clock from the buffer's origin. Neither is wrong on its
    /// own; what was missing is any relationship to the music.
    ///
    /// The rule, in one sentence: **play along with something and you land where
    /// you played; play with nothing there and you land at the start of the next
    /// bar after the music.**
    ///
    /// - Inside (or within a bar of) existing content, the played position is
    ///   kept verbatim. That is the case the playhead anchor was designed for
    ///   and it is genuinely right: someone playing along to a rolling
    ///   transport means the bar they were listening to.
    /// - Past everything the project contains, the position cannot have meant
    ///   "along with" anything, because there is nothing there to play along
    ///   WITH. It is the clock having run, and it is snapped to the next bar
    ///   line at or after the content end — which is exactly where a person
    ///   adding a part wants it, and is bar 1 of an empty project.
    ///
    /// Nothing musical is lost either way: `to_note_specs` writes notes
    /// relative to this anchor, so the passage's internal rhythm is identical
    /// and only the clip's own position moves. A one-bar grace keeps a slightly
    /// late entry just after the last clip from being treated as a runaway.
    ///
    /// Returns `(start_ticks, snapped_from)` — `snapped_from` is `Some(played)`
    /// when the position was moved, so the caller can SAY so rather than
    /// silently relocating a person's work.
    fn anchor_performance_start(&self, played_at: u64) -> (u64, Option<u64>) {
        let content = self.content_end_ticks();
        let bar = self.ticks_per_bar();
        if played_at <= content.saturating_add(bar) {
            return (played_at, None);
        }
        // Next bar line at or after the content end. `content == 0` (an empty
        // project) gives 0, i.e. bar 1, which is the whole point.
        let snapped = content.div_ceil(bar).saturating_mul(bar);
        if snapped == played_at {
            (played_at, None)
        } else {
            (snapped, Some(played_at))
        }
    }

    /// THROW AWAY what was just played, without putting any of it in the
    /// project.
    ///
    /// The counterpart Keep never had. The buffer is a rolling 128 beats, so a
    /// bad pass and a good pass sit in the same count, and the only ways out
    /// were to keep everything and undo, or to stop playing for a minute and
    /// wait for it to roll off. "How do I NOT keep notes?" was a fair question
    /// with no answer.
    ///
    /// SAFE BY CONSTRUCTION, and this is the part worth being careful about: it
    /// touches ONLY `self.performance`, which is a buffer of things that have
    /// been heard and never written. It submits no command, journals nothing,
    /// and cannot reach a clip, a note or a take — so there is nothing here for
    /// an undo to have to protect, which is also why it is not undoable and
    /// says so in its own result.
    ///
    /// Refuses while a real `record.start` take is open, for the same reason
    /// `performance_keep` does: that take is the capture, and `record.cancel`
    /// is how it is thrown away.
    pub fn performance_discard(&mut self, _params: &Value) -> Result<Value, StudioError> {
        if self.record.midi.is_some() {
            return Err(StudioError::invalid(
                "a MIDI take is recording; discard that take with record.cancel",
            ));
        }
        let Some(buf) = self.performance.take() else {
            return Ok(json!({
                "discarded": false,
                "reason": "nothing has been played yet",
                "noteCount": 0,
            }));
        };
        Ok(json!({
            "discarded": true,
            "noteCount": buf.completed_len(),
            "trackId": buf.track_id,
        }))
    }

    /// KEEP what was just played: land the retro-capture buffer as real notes.
    ///
    /// This is the whole point of the buffer. It is the same landing the record
    /// path performs (`land_midi_capture`) — one clip, one batched `note.add`,
    /// one txn, one undo step — reached without the user having armed anything
    /// or learned the word "arm". They played, they liked it, they keep it.
    ///
    /// Refuses (rather than silently doing something else) while a real take is
    /// recording: that take is the capture, and `record.stop` is how it lands.
    pub fn performance_keep(&mut self, _params: &Value) -> Result<Value, StudioError> {
        if self.record.midi.is_some() {
            return Err(StudioError::invalid(
                "a MIDI take is recording; stop it with record.stop to land that take",
            ));
        }
        let close_at = self.performance_now_ticks();
        let Some(mut buf) = self.performance.take() else {
            return Ok(json!({ "kept": false, "reason": "nothing has been played yet", "noteCount": 0 }));
        };
        // Close anything still held so a key that is down when the user hits
        // Keep is kept too, at its true length so far.
        buf.close_all_at(close_at.max(buf.end_ticks()));
        let Some(played_at) = buf.first_on_ticks() else {
            return Ok(json!({ "kept": false, "reason": "nothing has been played yet", "noteCount": 0 }));
        };
        let track_id = buf.track_id.clone();
        if !self.session.project().tracks.iter().any(|t| t.id == track_id) {
            return Ok(json!({
                "kept": false,
                "reason": "the track that was played no longer exists",
                "noteCount": 0,
            }));
        }
        // WHERE it goes. See `anchor_performance_start`: the playhead is the
        // right answer while there is something to play along to and a runaway
        // clock once there is not.
        let (start_ticks, snapped_from) = self.anchor_performance_start(played_at);
        // Move the whole take, not just the clip around it. `to_note_specs`
        // writes each note relative to the clip start, so moving the clip alone
        // would have left the NOTES 1,075 bars out inside a clip at bar 1 —
        // the same bug wearing a different hat. `rebase` shifts every on and
        // off by one delta, so the rhythm is bit-for-bit what was played.
        let length_ticks = buf.end_ticks().saturating_sub(played_at).max(1);
        buf.rebase(start_ticks);
        let mut out = self.land_midi_capture(&buf, &track_id, start_ticks, "performance")?;
        if let Value::Object(map) = &mut out {
            map.insert("kept".into(), json!(true));
            // The caller has to be able to SHOW the person where this landed —
            // a clip placed somewhere they are not looking is the bug this
            // whole path exists to stop repeating.
            map.insert("startTicks".into(), json!(start_ticks));
            map.insert("lengthTicks".into(), json!(length_ticks));
            map.insert("snapped".into(), json!(snapped_from.is_some()));
            if let Some(from) = snapped_from {
                map.insert("playedAtTicks".into(), json!(from));
            }
        }
        Ok(out)
    }

    /// AUDITION a note on a track's instrument right now, outside the timeline:
    /// the piano-roll gutter key, a note being drawn, a MIDI keyboard key.
    ///
    /// # This is feedback, not an edit — so it is NOT a catalog command
    ///
    /// Nothing here is journaled, undoable, or replayed. Pressing a key to hear
    /// what a pitch sounds like must not push an entry onto the undo stack, and
    /// it must not appear in the provenance manifest of a bounce. That is why
    /// there is no `note.preview` in the catalog: a catalog command is by
    /// definition a change to the project, and this changes nothing.
    ///
    /// # AUDIO SAFETY — what changed, and what did NOT
    ///
    /// This used to refuse to open the output device under any circumstance, so
    /// a person had to press Play and then Stop — an internal lifecycle detail —
    /// before a keyboard made any sound at all. That is not a safety property,
    /// it is a ritual, and it is now gone: a played note opens the device when
    /// (and only when) the GUI has already opted into being audible.
    ///
    /// The safety property that DOES matter is untouched: `audible_output` is
    /// set only by `set_audible_output`, which only the Swift GUI calls at
    /// launch. The CLI, `cargo test`, `swift test`, and every headless/CI run
    /// never call it, so in all of them this still opens nothing and still
    /// reports `audible: false` with a reason. An MCP agent on a headless host
    /// still cannot make a machine sing.
    ///
    /// The live-MICROPHONE monitoring refusal (`render::recording::
    /// monitoring_allowed`) is a different rule about a different hazard — an
    /// acoustic feedback loop — and this lane does not touch it. See
    /// [`StudioHost::ensure_live_for_performance`] for the full reasoning.
    ///
    /// Params:
    /// - `trackId` — the instrument track to sound. **Optional**: omit it to play
    ///   the project's instrument (the armed one, else the first), creating one
    ///   if the project has none yet. See [`Self::ensure_instrument_target`].
    /// - `pitch` (required) — 0..=127.
    /// - `velocity` — 0..=127, default 100.
    /// - `gate` — `"oneShot"` (default): sound and release itself after
    ///   `holdMs`. `"on"`: sound and HOLD until a matching `"off"` (a MIDI key
    ///   held down). `"off"`: release the held note at that pitch.
    /// - `holdMs` — one-shot length in milliseconds, default 350, clamped to
    ///   1..=5000.
    ///
    /// Returns `{audible, reason, trackId, trackIndex, pitch, velocity, gate}`.
    /// There is deliberately no `ok` field: the only question worth asking is
    /// whether a sound was actually made, and a caller must not be able to read
    /// "the call succeeded" as "the user heard something".
    pub fn preview_note(&mut self, params: &Value) -> Result<Value, StudioError> {
        // The KEY STATE is recorded first, before anything decides whether this
        // note can be played. A gate that is only recorded on the success path
        // leaves keys stuck down whenever a note is refused, which silently
        // turns the auto-create hold-off into a permanent disarm.
        if let (Some(p), Some(g)) = (
            params.get("pitch").and_then(Value::as_i64),
            params.get("gate").and_then(Value::as_str),
        ) {
            if (0..=127).contains(&p) {
                self.observe_note_gate(p as u8, g);
            }
        }
        // No trackId = "play the instrument", which an empty project answers by
        // creating one. A note-OFF never creates anything: a stray key-up with no
        // matching key-down must not conjure a track.
        let explicit_track = params.get("trackId").and_then(Value::as_str);
        let is_note_off = params.get("gate").and_then(Value::as_str) == Some("off");
        let track_id = match explicit_track {
            Some(id) => id.to_string(),
            None if is_note_off => match self.midi_instrument_target() {
                Some(id) => id,
                None => {
                    return Ok(json!({
                        "audible": false,
                        "reason": "the project has no instrument track",
                        "trackId": Value::Null, "pitch": params.get("pitch").cloned().unwrap_or(Value::Null),
                        "gate": "off",
                    }))
                }
            },
            None => match self.instrument_target_for_note()? {
                Some(id) => id,
                // Auto-create is held off because the user just undid the track
                // a played note created and has not lifted their hands yet.
                None => {
                    return Ok(json!({
                        "audible": false,
                        "reason": "you just undid the instrument that was created for you; \
                                   lift the keys and play again, or add an instrument to a track",
                        "trackId": Value::Null,
                        "pitch": params.get("pitch").cloned().unwrap_or(Value::Null),
                        "gate": params.get("gate").cloned().unwrap_or(json!("oneShot")),
                    }))
                }
            },
        };
        let pitch_raw = params
            .get("pitch")
            .and_then(Value::as_i64)
            .ok_or_else(|| StudioError::invalid("preview_note needs a pitch"))?;
        if !(0..=127).contains(&pitch_raw) {
            return Err(StudioError::invalid(format!(
                "pitch {pitch_raw} is outside the MIDI range 0..=127"
            )));
        }
        let pitch = pitch_raw as u8;
        let velocity_raw = params.get("velocity").and_then(Value::as_i64).unwrap_or(100);
        let velocity = velocity_raw.clamp(0, 127) as u8;
        let gate = params
            .get("gate")
            .and_then(Value::as_str)
            .unwrap_or("oneShot")
            .to_string();
        if !matches!(gate.as_str(), "oneShot" | "on" | "off") {
            return Err(StudioError::invalid(format!(
                "gate must be oneShot|on|off, got {gate}"
            )));
        }
        let hold_ms = params
            .get("holdMs")
            .and_then(Value::as_i64)
            .unwrap_or(350)
            .clamp(1, 5_000) as u64;

        let (index, has_instrument, sample_rate) = {
            let project = self.session.project();
            let Some(index) = project.tracks.iter().position(|t| t.id == track_id) else {
                return Err(StudioError::invalid(format!("no track {track_id}")));
            };
            let has_instrument = !project.tracks[index].devices.is_empty();
            (index, has_instrument, project.sample_rate)
        };

        let mut report = json!({
            "trackId": track_id.clone(),
            "trackIndex": index,
            "pitch": pitch,
            "velocity": velocity,
            "gate": gate.clone(),
        });
        let not_audible = |reason: &str, mut report: Value| {
            report["audible"] = json!(false);
            report["reason"] = json!(reason);
            Ok(report)
        };

        if !has_instrument {
            return not_audible("the track has no instrument device", report);
        }

        // KEEP WHAT WAS PLAYED. Buffered BEFORE the audio work and before the
        // audibility verdict, deliberately: a note the player felt themselves
        // play is keepable whether or not this machine had a working output
        // device at that instant. Tying the record of the performance to the
        // speaker working would lose takes for exactly the users least able to
        // diagnose why.
        let hold_ticks = {
            let bpm = self.session.project().tempo.first_bpm().as_f64().max(1.0);
            // ticks = (ms / 60_000) * bpm * PPQ
            ((hold_ms as f64 / 60_000.0) * bpm * timeline_core::PPQ as f64)
                .round()
                .max(1.0) as u64
        };
        self.performance_note(&track_id, pitch, velocity, &gate, hold_ticks);

        // The device comes up HERE, on a played note, and not on a transport
        // Play the user had no reason to press. Gated on the GUI's audible
        // opt-in, so nothing else in the workspace changes behaviour.
        //
        // And it is deliberately NOT announced when it WORKS. Every other item
        // this lane surfaced leaves an artifact behind — a row in the
        // arrangement, an instrument on a track — that a person will find later
        // and have to explain to themselves. Opening the output device leaves
        // nothing: nothing is journaled, there is no undo step, and the
        // evidence that it happened is the note they just heard. A toast at the
        // instant a key goes down is the interruption the whole design forbids,
        // and it would be announcing that the app did the thing that was asked
        // for. The half worth saying is the failure, and that is below.
        if let Some(why) = self.ensure_live_for_performance() {
            return not_audible(&why, report);
        }
        let Some(live) = self.live.as_ref() else {
            return not_audible("the output device could not be opened", report);
        };

        // One audition voice per (track, pitch): a physical key cannot be
        // pressed twice without being released, and the piano roll auditions
        // one pitch at a time, so this is the exact identity a note-off needs.
        let hint = render::PREVIEW_HINT_BASE + pitch as u32;
        match gate.as_str() {
            "off" => live.command(RenderCommand::PreviewNoteOff { track: index, hint }),
            other => {
                let hold_frames = if other == "on" {
                    0 // held until an explicit off
                } else {
                    (hold_ms * sample_rate as u64 / 1000).max(1)
                };
                live.command(RenderCommand::PreviewNoteOn {
                    track: index,
                    pitch,
                    velocity: velocity as f32 / 127.0,
                    hint,
                    hold_frames,
                });
            }
        }
        report["audible"] = json!(true);
        report["reason"] = Value::Null;
        Ok(report)
    }

    /// The render-side warp overlay, DERIVED from the model's per-clip
    /// `Clip::warp`.
    ///
    /// This is the function that was missing. `clip.warp.set` has always
    /// written `Clip::warp`, and `compile_session_full` has always known how to
    /// play a pre-rendered stretched buffer — but every one of this host's
    /// compile sites handed it `WarpOverlay::new()`, an empty map, so the two
    /// halves never met and the command was journaled, saved, undoable and
    /// completely inaudible.
    ///
    /// Rules, all of them chosen so an UNWARPED project is untouched:
    /// * a clip whose effective ratio is identity (within `IDENTITY_EPSILON`)
    ///   gets NO overlay entry, so `compile` takes the byte-for-byte same
    ///   branch it took before this existed. A project with no warps produces
    ///   an EMPTY overlay, which is exactly what used to be passed.
    /// * note clips have no audio to stretch and are skipped outright.
    /// * a clip whose source is not loaded, or whose extent is outside the
    ///   loaded buffer, is skipped — `compile` already refuses those with a
    ///   precise error, and inventing one here would only mask it.
    /// * the ratio is clamped to `MIN_RATIO..=MAX_RATIO` (0.25x..4x), the same
    ///   clamp `Stretcher::stretch` applies internally, so the entry's recorded
    ///   `stretched_ratio` cannot disagree with the audio it describes.
    ///
    /// `WarpMode::Conform` is resolved as the ratio the MODEL carries for it
    /// (`apply.rs` preserves the prior `stretchRatio` across a conform), and
    /// nothing more. True conform-to-project-tempo needs a source tempo that no
    /// part of this engine stores yet; that is E7's warp-marker work, and
    /// guessing a BPM here would be an invention that sounds like a feature.
    ///
    /// `WarpEntry::generation` is 0 for every entry: generations exist to drop
    /// STALE async results (`ProjectHost::pump_warp_results`), and this path is
    /// synchronous, so there is no such thing as a stale entry here. `compile`
    /// does not read the field.
    fn warp_overlay(&self) -> WarpOverlay {
        let mut overlay = WarpOverlay::new();
        let mut live: std::collections::HashSet<WarpKey> = std::collections::HashSet::new();
        let project = self.session.project();
        let rate = project.sample_rate;
        for track in &project.tracks {
            for clip in &track.clips {
                if clip.is_midi() {
                    continue;
                }
                let raw = clip.warp.stretch_ratio.as_f64();
                if !raw.is_finite() || raw <= 0.0 {
                    continue;
                }
                let ratio = raw.clamp(MIN_RATIO, MAX_RATIO);
                if is_identity(ratio) {
                    continue;
                }
                let Some(source) = self.sources.get(&clip.source_id) else {
                    continue;
                };
                let start = clip.offset_frames as usize;
                let end = start.saturating_add(clip.len_frames as usize);
                let Some(extent) = source.samples.get(start..end) else {
                    continue;
                };
                if extent.is_empty() {
                    continue;
                }
                let key = WarpKey::new(
                    &clip.source_id,
                    clip.offset_frames,
                    clip.len_frames,
                    ratio,
                );
                let audio = self.warp_cache.resolve(key.clone(), extent, ratio, rate);
                live.insert(key);
                overlay.insert(
                    clip.id.clone(),
                    WarpEntry {
                        ratio,
                        generation: 0,
                        stretched: Some(audio),
                        stretched_ratio: ratio,
                    },
                );
            }
        }
        // Anything no longer referenced by the model is dropped, so an
        // edited-away or undone warp does not pin its buffer for the session.
        self.warp_cache.retain_keys(&live);
        overlay
    }

    /// Stretches actually executed by this host (cache misses). Observability
    /// for tests and the report; not part of any wire contract.
    pub fn warp_renders(&self) -> u64 {
        self.warp_cache.renders()
    }

    /// Compile the current model into a render session sized for the live
    /// engine's track capacity.
    fn compile_current_session(&self, max_tracks: usize) -> Result<Box<RtSession>, StudioError> {
        let project = self.session.project();
        let automation = self.build_automation();
        compile_session_full(
            project,
            &self.sources,
            &self.warp_overlay(),
            &automation,
            max_tracks,
            self.declick,
        )
        .map_err(StudioError::audio)
    }

    /// Recompile + push the session and current mixer params to the live
    /// engine. No-op offline.
    ///
    /// ⚠️ **A compile error here is RECORDED, never swallowed.** It used to be
    /// `if let Ok(session) = … { }` with no else branch, which meant the audio
    /// thread silently kept rendering the PREVIOUS session: the user edited,
    /// heard nothing change, and no error existed anywhere. That is the
    /// silent-degradation class this engine keeps getting bitten by, and it
    /// became reachable the moment `build_lane_index` started refusing lanes
    /// with no reader.
    ///
    /// It is NOT propagated as a command error, and that is deliberate. Every
    /// caller reaches here through `sync_after_mutation`, i.e. AFTER
    /// `Session::submit_json` has already applied the command, journaled it and
    /// hashed it into the chain. Returning `Err` from `bus_submit` at that point
    /// would tell the caller the edit failed when it actually landed — a second
    /// lie on top of the first, and undo would then disagree with the caller
    /// about what happened.
    ///
    /// So the failure becomes OBSERVABLE STATE instead, on two surfaces a human
    /// actually reads:
    ///   * every command report (`bus_submit`) carries `liveRenderError`, so an
    ///     agent or MCP client sees it on the very command that broke playback;
    ///   * `snapshot()` carries `liveRenderError`, so the app can show a banner.
    ///
    /// It clears on the next successful push, which keeps the genuinely
    /// transient case honest — an intermediate edit that momentarily references
    /// an unloaded source reports for exactly as long as it is true.
    fn push_live_session(&mut self) {
        // The lane-reader gate runs ALWAYS, live or not. It is the same
        // `compile::refuse_unreadable_lanes` the compiler itself calls — one
        // implementation, so the host can never report a lane the compiler
        // accepts — and it is cheap: one pass over the lane keys, no clips, no
        // notes, no instruments. Running it offline too means a refused lane is
        // reported the moment it is DRAWN, in the report of the very command
        // that drew it, instead of being discovered later at bounce.
        let lane_fault = {
            // `Automation::iter_lanes` hands back owned `ParamRef`s (and has
            // already dropped empty lanes), so materialise the keys once and
            // then borrow. This is O(lanes), not O(points).
            let project = self.session.project();
            let keys: Vec<(String, String)> = project
                .tracks
                .iter()
                .flat_map(|t| {
                    t.automation
                        .iter_lanes()
                        .into_iter()
                        .map(|(path, _)| (t.id.clone(), path.as_str().to_string()))
                        .collect::<Vec<_>>()
                })
                .collect();
            // `LaneTargets` carries the resolution half of the sweep: which
            // routing nodes exist and which devices each track carries, so a
            // lane STRANDED by route.node.remove / device.remove (or born of a
            // typo'd id — forward-legal since the require_param_ref_on
            // widening) is reported the moment it exists, not at bounce.
            render::compile::refuse_unreadable_lanes(
                keys.iter().map(|(t, p)| (t.as_str(), p.as_str())),
                &render::compile::LaneTargets::of(project),
            )
            .err()
        };

        let Some(max_tracks) = self.live.as_ref().map(|l| l.max_tracks()) else {
            // Offline there is no live session to desync — but an unreadable
            // lane still means this project cannot be rendered, and the user
            // should hear that now rather than at export.
            self.live_render_error = lane_fault;
            return;
        };
        match self.compile_current_session(max_tracks) {
            Ok(session) => {
                self.live_render_error = None;
                let live = self.live.as_ref().expect("checked above");
                self.sync_params(live.params());
                live.command(RenderCommand::SetSession(session));
            }
            Err(e) => {
                // The audio thread keeps rendering the previous session — which
                // is the right thing to do (it is still valid audio, and cutting
                // to silence mid-playback would be worse). What was wrong before
                // was doing it invisibly.
                self.live_render_error = Some(e.to_string());
            }
        }
    }

    /// The live render fault, if the last recompile-and-push failed.
    ///
    /// `Some` means the audio thread is rendering a STALE session: the model has
    /// moved on and playback has not. Clears on the next successful push.
    pub fn live_render_error(&self) -> Option<&str> {
        self.live_render_error.as_deref()
    }

    /// Restore the tracked transport view into a freshly opened live engine.
    fn prime_live_transport(&self) {
        let Some(live) = self.live.as_ref() else {
            return;
        };
        let rate = self.session.project().sample_rate;
        let tempo = self.session.project().tempo.clone();
        if let Some((s, e)) = self.transport.loop_region {
            live.command(RenderCommand::LoopSet {
                start_frame: tempo.tick_to_frame(s, rate),
                end_frame: tempo.tick_to_frame(e, rate),
            });
        }
        live.command(RenderCommand::Seek {
            frame: tempo.tick_to_frame(self.transport.position_ticks, rate),
        });
        if self.transport.playing {
            live.command(RenderCommand::Play);
        }
    }

    /// Forward a transport command to the live engine (frames, not ticks). The
    /// bus already validated it; this only mirrors it onto the audio thread.
    fn forward_transport_live(&self, name: &str, params: &Value) {
        let Some(live) = self.live.as_ref() else {
            return;
        };
        let rate = self.session.project().sample_rate;
        let tempo = self.session.project().tempo.clone();
        match name {
            "transport.play" => live.command(RenderCommand::Play),
            "transport.stop" => live.command(RenderCommand::Stop),
            "transport.seek" => {
                let t = params.get("positionTicks").and_then(Value::as_u64).unwrap_or(0);
                live.command(RenderCommand::Seek {
                    frame: tempo.tick_to_frame(t, rate),
                });
            }
            "transport.loop.set" => {
                if let (Some(s), Some(e)) = (
                    params.get("startTicks").and_then(Value::as_u64),
                    params.get("endTicks").and_then(Value::as_u64),
                ) {
                    live.command(RenderCommand::LoopSet {
                        start_frame: tempo.tick_to_frame(s, rate),
                        end_frame: tempo.tick_to_frame(e, rate),
                    });
                }
            }
            "transport.loop.clear" => live.command(RenderCommand::LoopClear),
            // The enable flag is params, not a RenderCommand: the click grid
            // lives in `EngineParams` so a tempo edit updates it without a
            // transport command. `apply_transport` has already stored the new
            // value on `self.transport` by the time this runs.
            "transport.metronome" => self.sync_metronome_params(live.params()),
            _ => {}
        }
    }

    fn live_info_json(&self) -> Value {
        match self.live.as_ref() {
            Some(live) => {
                let info = live.stream_info();
                json!({
                    "ok": true,
                    "live": true,
                    "deviceName": info.device_name,
                    "deviceSampleRate": info.device_default_rate,
                    "configuredRate": info.configured_rate,
                    "channels": info.channels,
                    "audible": info.audible,
                    "generation": info.generation,
                })
            }
            None => json!({ "ok": true, "live": false }),
        }
    }

    /// Push the metronome's enable flag, level and musical GRID to an engine
    /// params block.
    ///
    /// The grid is the model's exact rational BPM plus the project phase
    /// anchor, handed over as integers — not a pre-divided "frames per beat".
    /// Rounding the beat spacing here would make the click drift away from the
    /// grid the clips sit on, by an amount that depends on how far into the
    /// song you are. The render side redoes the same round-half-up rational
    /// division `TempoMap::tick_to_frame` does, per beat, so the click lands on
    /// the frame the timeline says the beat is on.
    ///
    /// Safe to call on an OFFLINE params block: a bounce core has
    /// `monitor: false`, so none of this can reach a rendered file.
    fn sync_metronome_params(&self, params: &render::params::EngineParams) {
        let project = self.session.project();
        let bpm = project.tempo.first_bpm();
        params.set_metronome_grid(
            bpm.num,
            bpm.den,
            project.phase_anchor_ticks,
            // v1 is 4/4 everywhere (`TempoMap::bar_to_tick` hardcodes 4), but
            // `project.time_sig` is real model state and the accent test is
            // already `beat % beats_per_bar`, so reading it here means the
            // downbeat follows the meter the moment `project.setTimeSig`
            // becomes more than a stored number.
            project.time_sig.numerator.max(1),
        );
        params.set_metronome_enabled(self.transport.metronome);
        if let Some(db) = self.transport.metronome_level_db {
            params.set_metronome_level(render::dsp::click::DEFAULT_LEVEL * render::dsp::db_to_lin(db as f32));
        } else {
            params.set_metronome_level(render::dsp::click::DEFAULT_LEVEL);
        }
    }

    /// Frames per count-in beat at the project's current tempo.
    fn beat_frames(&self) -> u64 {
        let project = self.session.project();
        let rate = project.sample_rate;
        let tempo = &project.tempo;
        tempo
            .tick_to_frame(timeline_core::tempo::PPQ, rate)
            .saturating_sub(tempo.tick_to_frame(0, rate))
            .max(1)
    }

    /// Push the current metronome state at the live engine (if any).
    fn push_metronome_live(&self) {
        if let Some(live) = self.live.as_ref() {
            self.sync_metronome_params(live.params());
        }
    }

    /// Set metronome monitor state. Not a catalog command: nothing here is
    /// journaled, undoable or replayed, and none of it is part of the project.
    /// It is the click you play along to, in the same family as
    /// `studio_note_preview` — feedback, never an edit.
    ///
    /// `count_in_beats` sounds that many clicks starting immediately, which is
    /// what makes a count-in something you can hear rather than a number that
    /// counts down in silence.
    pub fn set_metronome(
        &mut self,
        enabled: Option<bool>,
        level_db: Option<f64>,
        count_in_beats: Option<u32>,
    ) -> Value {
        if let Some(e) = enabled {
            self.transport.metronome = e;
        }
        if let Some(db) = level_db {
            self.transport.metronome_level_db = Some(db.clamp(-40.0, 6.0));
        }
        self.push_metronome_live();
        let period = self.beat_frames();
        if let Some(beats) = count_in_beats {
            // OPEN THE DEVICE FOR A COUNT-IN.
            //
            // Unlike the running click, a count-in sounds with the transport
            // STOPPED — and the output device is only opened on the first
            // `transport.play` (or the first played note). Someone who arms a
            // track and hits Record without ever having pressed Play would
            // therefore have got a count-in that counted down in silence: the
            // exact defect this work exists to remove, reappearing one layer
            // down. Same policy as a played note (`ensure_live_for_performance`):
            // gated on the GUI's explicit audibility opt-in, so a headless host
            // or a test still makes no sound and opens no device.
            if beats > 0 {
                // The reason is dropped HERE and only here: `set_metronome`
                // returns the metronome's state, not an audibility verdict, and
                // the `live.is_some()` check on the next line is what actually
                // decides whether a click is sent. A headless host reaching
                // this line is the normal case, not a fault.
                let _ = self.ensure_live_for_performance();
            }
            if let Some(live) = self.live.as_ref() {
                if beats == 0 {
                    live.command(RenderCommand::CountInCancel);
                } else {
                    live.command(RenderCommand::CountIn {
                        beats: beats.min(16),
                        period_frames: period,
                    });
                }
            }
        }
        json!({
            "ok": true,
            "enabled": self.transport.metronome,
            "levelDb": self.transport.metronome_level_db.unwrap_or(0.0),
            "beatFrames": period,
            "live": self.live.is_some(),
        })
    }

    fn apply_transport(&mut self, name: &str, params: &Value) {
        match name {
            "transport.play" => self.transport.playing = true,
            "transport.stop" => self.transport.playing = false,
            "transport.seek" => {
                if let Some(t) = params.get("positionTicks").and_then(Value::as_u64) {
                    self.transport.position_ticks = t;
                }
            }
            "transport.loop.set" => {
                let s = params.get("startTicks").and_then(Value::as_u64);
                let e = params.get("endTicks").and_then(Value::as_u64);
                if let (Some(s), Some(e)) = (s, e) {
                    self.transport.loop_region = Some((s, e));
                }
            }
            "transport.loop.clear" => self.transport.loop_region = None,
            "transport.metronome" => {
                self.transport.metronome =
                    params.get("enabled").and_then(Value::as_bool).unwrap_or(false);
            }
            _ => {}
        }
    }

    pub fn undo(&mut self, actor: Actor) -> Result<bool, StudioError> {
        let mut meta = ulid::UlidMeta::new(actor);
        let did = self.session.undo(&mut meta)?;
        self.sync_after_mutation();
        self.note_auto_create_undo();
        Ok(did)
    }

    pub fn redo(&mut self, actor: Actor) -> Result<bool, StudioError> {
        let mut meta = ulid::UlidMeta::new(actor);
        let did = self.session.redo(&mut meta)?;
        self.sync_after_mutation();
        self.note_auto_create_undo();
        Ok(did)
    }

    /// Build the MIDI resolver's read-only context from host state (spec 3). The
    /// pump captures this under one short host lock per dispatch; the resolver
    /// touches no host state beyond it, which is what makes dispatch testable.
    pub(crate) fn midi_dispatch_ctx(&self) -> crate::midi::resolve::DispatchCtx {
        let project = self.session.project();
        let playing = self.live.as_ref().map(|l| l.playing()).unwrap_or(self.transport.playing);
        crate::midi::resolve::DispatchCtx {
            playing,
            recording: self.record.is_recording(),
            metronome: self.transport.metronome,
            armed_track_id: project.tracks.iter().find(|t| t.armed).map(|t| t.id.clone()),
            track_ids: project.tracks.iter().map(|t| t.id.clone()).collect(),
            track_gains_db: project.tracks.iter().map(|t| t.gain.as_f64()).collect(),
        }
    }

    // -----------------------------------------------------------------------
    // Project lifecycle (host io).
    // -----------------------------------------------------------------------

    fn host_project_new(&mut self, name: &str) -> Result<(), StudioError> {
        let base = self
            .data_dir
            .clone()
            .ok_or_else(|| StudioError::NotInitialized("no data dir; initialize first".into()))?;
        let fresh = Self::create_package(&base, name)?;
        // Preserve the MIDI subsystem (pump + registry/learn/ports) across the
        // host swap: it is app-level config, not project state. Dropping it here
        // would kill the live pump on every project switch AND deadlock, because
        // MidiPump::drop would run while a caller holds the host lock. mem::take
        // leaves a pump-less Default for `fresh` to drop.
        let midi = std::mem::take(&mut self.midi);
        *self = fresh;
        self.midi = midi;
        Ok(())
    }

    fn host_project_open(&mut self, path: &str) -> Result<(), StudioError> {
        // `path` may be an absolute .mstudio dir, or a bare name under data_dir.
        let candidate = {
            let p = PathBuf::from(path);
            if p.is_absolute() {
                p
            } else if let Some(base) = &self.data_dir {
                let n = if path.ends_with(".mstudio") {
                    path.to_string()
                } else {
                    format!("{}.mstudio", sanitize_name(path))
                };
                base.join(n)
            } else {
                p
            }
        };
        let opened = Self::open_package(&candidate)?;
        // Preserve the MIDI subsystem across the host swap (see host_project_new).
        let midi = std::mem::take(&mut self.midi);
        *self = opened;
        self.midi = midi;
        Ok(())
    }

    pub fn save(&mut self) -> Result<(), StudioError> {
        let dir = self
            .package_dir
            .clone()
            .ok_or_else(|| StudioError::NotInitialized("no open package to save".into()))?;
        Package::save(&dir, &mut self.session)?;
        Ok(())
    }

    fn package_dir_display(&self) -> Value {
        match &self.package_dir {
            Some(p) => Value::String(p.display().to_string()),
            None => Value::Null,
        }
    }

    // -----------------------------------------------------------------------
    // Audio import: decode -> content-hash -> copy into audio/ -> clip.place.
    //
    // v1 host decomposition (proposal on record): the agent-facing `import.audio`
    // resolves to io + a single journaled `clip.place` carrying the real
    // assetHash + length, rather than a literal `import.audio` envelope. The
    // clip's content hash is the provenance link, and a journal of clip.place
    // replays deterministically without re-reading the imported file.
    // -----------------------------------------------------------------------

    fn import_audio_params(&mut self, params: &Value) -> Result<ImportOutcome, StudioError> {
        let source_path = str_param(params, "sourcePath")?;
        let track_id = str_param(params, "targetTrackId")?;
        let start_ticks = params
            .get("startTicks")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let clip_id = params
            .get("clipId")
            .and_then(Value::as_str)
            .map(String::from);
        self.import_audio(&source_path, &track_id, start_ticks, clip_id)
    }

    /// Ingest an audio file as a content-addressed ASSET and nothing else.
    ///
    /// Decode to the project's rate, hash the ORIGINAL bytes, copy into
    /// `audio/<hash>.wav`, register in the live `sources` map, build tiles.
    /// This is the whole io half of `import.audio`, lifted out so the sampler /
    /// drum source binding uses THE SAME path rather than a second one — a zone
    /// resolves through the very same `sources` map a clip does, so it cannot
    /// drift onto its own pipeline.
    ///
    /// Deliberately NOT journaled. What makes an asset durable is the bytes in
    /// `audio/`, which `load_audio_dir` re-reads on every open; that is already
    /// why a reopened project's clips resolve without replaying their import.
    ///
    /// Sibling of `ingest_asset`, which lands already-decoded FRAMES (a
    /// recording, a rendered revise). The split is the hash: this one addresses
    /// the ORIGINAL file bytes, so re-importing the same file is the same
    /// `source_id` and a clip and a zone naming that file agree.
    fn ingest_asset_file(&mut self, source_path: &str) -> Result<AssetIngest, StudioError> {
        let src = Path::new(source_path);
        let bytes = std::fs::read(src).map_err(|e| StudioError::io(format!("read {source_path}: {e}")))?;
        let hash = blake3::hash(&bytes).to_hex().to_string();
        let decoded = media::decode::decode_to_stereo(src, self.session.project().sample_rate)
            .map_err(|e| StudioError::audio(e.to_string()))?;
        let len_frames = decoded.frames.len() as u64;
        if len_frames == 0 {
            return Err(StudioError::audio(format!("{source_path} decodes to 0 frames")));
        }

        // Copy content-addressed into audio/<hash>.wav when a package is open.
        if let Some(pkg) = &self.package_dir {
            let audio_dir = pkg.join("audio");
            std::fs::create_dir_all(&audio_dir).map_err(StudioError::io)?;
            let dest = audio_dir.join(format!("{hash}.wav"));
            if !dest.exists() {
                write_wav_f32(&dest, &decoded.frames, decoded.sample_rate)
                    .map_err(|e| StudioError::io(format!("write decoded asset: {e}")))?;
            }
        }
        let audio = AudioBuf {
            samples: decoded.frames.clone().into_boxed_slice(),
            sample_rate: decoded.sample_rate,
            source_sample_rate: decoded.source_sample_rate,
            source_channels: decoded.source_channels,
            path: src.to_path_buf(),
        };
        self.sources.insert(hash.clone(), Arc::new(audio));
        let tiles_ready = self.generate_tiles(&hash, &decoded.frames)?;
        Ok(AssetIngest {
            hash,
            len_frames,
            tiles_ready,
            source_path: source_path.to_string(),
        })
    }

    // -----------------------------------------------------------------------
    // The source binding: what makes a sampler / drum rack REACHABLE.
    //
    // Before this the multi-zone sampler and the 16-pad rack were fully built,
    // RT-safe, tested — and unusable, because nothing outside a Rust test could
    // put a sound into one. `Device::zones` existed; `device.zone.add` existed;
    // the one missing piece was a way to turn a FILE into the `source_id` those
    // commands take without also placing a clip on the timeline.
    // -----------------------------------------------------------------------

    /// Wire entry point: parse the UI's args and bind. Returns the outcome JSON.
    pub fn bind_samples_json(&mut self, params: &Value) -> Result<Value, StudioError> {
        Ok(self.bind_samples_params(params)?.to_json())
    }

    fn bind_samples_params(&mut self, params: &Value) -> Result<BindSamplesOutcome, StudioError> {
        let track_id = str_param(params, "trackId")?;
        let device_id = params
            .get("deviceId")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(String::from);
        let kind = params
            .get("kind")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(String::from);
        let remove_zone_ids = params
            .get("removeZoneIds")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(Value::as_str)
                    .map(String::from)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let mut bindings = Vec::new();
        for (i, b) in params
            .get("bindings")
            .and_then(Value::as_array)
            .map(|a| a.as_slice())
            .unwrap_or(&[])
            .iter()
            .enumerate()
        {
            let source_path = b
                .get("sourcePath")
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    StudioError::invalid(format!("bindings[{i}]: sourcePath is required"))
                })?
                .to_string();
            let lo = b.get("loPitch").and_then(Value::as_i64).unwrap_or(0);
            let hi = b.get("hiPitch").and_then(Value::as_i64).unwrap_or(127);
            bindings.push(SampleBinding {
                source_path,
                root_pitch: b.get("rootPitch").and_then(Value::as_i64).unwrap_or(60),
                lo_pitch: lo,
                hi_pitch: hi,
                gain_db: b.get("gainDb").and_then(Value::as_f64),
                pan: b.get("pan").and_then(Value::as_f64),
            });
        }
        let reason = params
            .get("reason")
            .and_then(Value::as_str)
            .unwrap_or("bind samples")
            .to_string();
        self.bind_samples(BindSamplesRequest {
            track_id,
            device_id,
            kind,
            remove_zone_ids,
            bindings,
            reason,
        })
    }

    /// Ingest each file and bind it as a sampler zone / drum pad, creating the
    /// instrument if it does not exist yet, in ONE journaled transaction.
    ///
    /// # The two rules this method exists to keep
    ///
    /// **1. A sampler with no zones can never be journaled.** `build_sample_map`
    /// and `build_drum_kit` refuse an empty instrument outright — by design,
    /// because an instrument that could only render silence is not a state the
    /// project is allowed to reach. So creation and binding happen in the same
    /// txn: there is no window, not even one command wide, in which the project
    /// holds an uncompilable device. Every refusal below is checked BEFORE
    /// `txn.begin`, so a rejected gesture leaves the journal untouched rather
    /// than aborting a half-open transaction.
    ///
    /// **2. One gesture, one undo step.** `device.add` + N × `device.zone.add`
    /// (+ the removes a replacement implies) land inside one txn bracket, so
    /// Cmd-Z takes the whole thing back. `device.remove`'s multi-inverse already
    /// restores zones, so the reverse direction was free.
    pub fn bind_samples(
        &mut self,
        req: BindSamplesRequest,
    ) -> Result<BindSamplesOutcome, StudioError> {
        use timeline_core::model::DeviceKind;

        let track = self
            .session
            .project()
            .tracks
            .iter()
            .find(|t| t.id == req.track_id)
            .ok_or_else(|| StudioError::invalid(format!("unknown track {}", req.track_id)))?;

        // ---- which device, and is it allowed to hold zones at all? ----------
        let existing = req
            .device_id
            .as_deref()
            .and_then(|id| track.devices.iter().find(|d| d.id == id));
        let (device_id, kind, created_device) = match (&req.device_id, existing) {
            (Some(id), Some(dev)) => {
                if dev.kind == DeviceKind::Synth {
                    return Err(StudioError::invalid(format!(
                        "device {id} is a Synth, which synthesizes its sound and reads no \
                         audio file; a sound can only be loaded into a Sampler or a Drum Rack"
                    )));
                }
                (id.clone(), dev.kind, false)
            }
            (Some(id), None) => {
                return Err(StudioError::invalid(format!(
                    "unknown device {id} on track {}",
                    req.track_id
                )))
            }
            (None, _) => {
                // Creating. One instrument per track is a compile-time law
                // (`build_instrument` refuses a second), so refuse here rather
                // than journal a project that cannot render.
                if let Some(dev) = track.devices.first() {
                    return Err(StudioError::invalid(format!(
                        "track {} already plays a {}; remove it first (right-click the track \
                         header) before loading a different instrument",
                        req.track_id,
                        dev.kind.wire_name()
                    )));
                }
                let kind = match req.kind.as_deref() {
                    Some("sampler") => DeviceKind::Sampler,
                    Some("drum") => DeviceKind::Drum,
                    Some("synth") => {
                        return Err(StudioError::invalid(
                            "a Synth has no sound to load: it synthesizes. Use device.add for one"
                                .to_string(),
                        ))
                    }
                    other => {
                        return Err(StudioError::invalid(format!(
                            "kind must be \"sampler\" or \"drum\", got {other:?}"
                        )))
                    }
                };
                // The ParamRef path is `track.device.<deviceId>.<param>`, so a
                // '.' in the id stops that path parsing — mint without one.
                (
                    format!("inst_{}", ulid::new_ulid()),
                    kind,
                    true,
                )
            }
        };

        if req.bindings.is_empty() && req.remove_zone_ids.is_empty() {
            return Err(StudioError::invalid(
                "no sounds to load and nothing to remove".to_string(),
            ));
        }

        // ---- would the RESULT compile? ---------------------------------------
        //
        // Modelled here, before anything is journaled, against exactly the rules
        // `build_sample_map` / `build_drum_kit` enforce. The compile stays the
        // real fence; this is what stops the fence ever being hit, because the
        // failure it would produce is not one a person can act on from the UI.
        let mut surviving: Vec<(i64, i64)> = existing
            .map(|d| {
                d.zones
                    .iter()
                    .filter(|z| !req.remove_zone_ids.iter().any(|r| r == &z.id))
                    .map(|z| (pitch_of(&z.lo_pitch), pitch_of(&z.hi_pitch)))
                    .collect()
            })
            .unwrap_or_default();
        for id in &req.remove_zone_ids {
            let known = existing.map(|d| d.zone(id).is_some()).unwrap_or(false);
            if !known {
                return Err(StudioError::invalid(format!(
                    "device {device_id} has no zone {id} to replace"
                )));
            }
        }
        for (i, b) in req.bindings.iter().enumerate() {
            for (what, v) in [
                ("rootPitch", b.root_pitch),
                ("loPitch", b.lo_pitch),
                ("hiPitch", b.hi_pitch),
            ] {
                if !(0..=timeline_core::model::MAX_PITCH).contains(&v) {
                    return Err(StudioError::invalid(format!(
                        "bindings[{i}]: {what} {v} is not a MIDI note in 0..=127"
                    )));
                }
            }
            if b.hi_pitch < b.lo_pitch {
                return Err(StudioError::invalid(format!(
                    "bindings[{i}]: hiPitch {} is below loPitch {}",
                    b.hi_pitch, b.lo_pitch
                )));
            }
            if kind == DeviceKind::Drum && b.hi_pitch != b.lo_pitch {
                return Err(StudioError::invalid(format!(
                    "bindings[{i}]: a drum pad covers exactly one key, but this one spans \
                     {}..={}",
                    b.lo_pitch, b.hi_pitch
                )));
            }
            surviving.push((b.lo_pitch, b.hi_pitch));
        }
        if surviving.is_empty() {
            return Err(StudioError::invalid(format!(
                "that would leave {} with no sounds at all, and an instrument with nothing \
                 to play cannot render; remove the instrument instead",
                kind.wire_name()
            )));
        }
        if kind == DeviceKind::Drum {
            let mut keys: Vec<i64> = surviving.iter().map(|(lo, _)| *lo).collect();
            keys.sort_unstable();
            if let Some(dup) = keys.windows(2).find(|w| w[0] == w[1]) {
                return Err(StudioError::invalid(format!(
                    "two pads would land on the same key ({}); replace the pad instead of \
                     stacking on it",
                    dup[0]
                )));
            }
            let span = keys[keys.len() - 1] - keys[0];
            if span as usize >= RACK_PADS {
                return Err(StudioError::invalid(format!(
                    "those pads span keys {}..={}, wider than the {RACK_PADS}-pad rack; a \
                     rack holds {RACK_PADS} keys in a row (a General MIDI kit, 36..=49, fits)",
                    keys[0],
                    keys[keys.len() - 1]
                )));
            }
        }

        // ---- io FIRST: a failed read must not strand an open txn -------------
        let mut ingested = Vec::with_capacity(req.bindings.len());
        for b in &req.bindings {
            ingested.push(self.ingest_asset_file(&b.source_path)?);
        }

        // ---- one transaction, ordinary catalog commands ----------------------
        let txn_id = format!("bind_{}", ulid::new_ulid());
        let actor = Actor::user("sampler");
        self.session.submit_json(
            ulid::entry_meta(actor.clone()),
            "txn.begin",
            json!({"txnId": txn_id, "reason": req.reason}),
        )?;
        let mut run = || -> Result<(u64, Vec<BoundZone>), StudioError> {
            if created_device {
                self.session.submit_json(
                    ulid::entry_meta(actor.clone()),
                    "device.add",
                    json!({
                        "trackId": req.track_id,
                        "deviceId": device_id,
                        "kind": kind.wire_name(),
                    }),
                )?;
            }
            for zone_id in &req.remove_zone_ids {
                self.session.submit_json(
                    ulid::entry_meta(actor.clone()),
                    "device.zone.remove",
                    json!({
                        "trackId": req.track_id,
                        "deviceId": device_id,
                        "zoneId": zone_id,
                    }),
                )?;
            }
            let mut zones = Vec::with_capacity(req.bindings.len());
            let mut seq = 0;
            for (b, asset) in req.bindings.iter().zip(ingested.iter()) {
                let zone_id = format!("zone_{}", ulid::new_ulid());
                let mut p = json!({
                    "trackId": req.track_id,
                    "deviceId": device_id,
                    "zoneId": zone_id,
                    "sourceId": asset.hash,
                    "rootPitch": b.root_pitch,
                    "loPitch": b.lo_pitch,
                    "hiPitch": b.hi_pitch,
                });
                if let Some(g) = b.gain_db {
                    p["gainDb"] = json!(g);
                }
                if let Some(pan) = b.pan {
                    p["pan"] = json!(pan);
                }
                let sub =
                    self.session
                        .submit_json(ulid::entry_meta(actor.clone()), "device.zone.add", p)?;
                seq = sub.seq;
                zones.push(BoundZone {
                    zone_id,
                    source_id: asset.hash.clone(),
                    source_path: asset.source_path.clone(),
                    root_pitch: b.root_pitch,
                    lo_pitch: b.lo_pitch,
                    hi_pitch: b.hi_pitch,
                });
            }
            Ok((seq, zones))
        };
        let result = run();
        // Whatever happened, the bracket closes. An abort rolls the partial
        // unit back so a refusal leaves nothing half-applied; the commit path
        // is the ordinary one.
        let outcome = match result {
            Ok((mut seq, zones)) => {
                let sub = self.session.submit_json(
                    ulid::entry_meta(actor),
                    "txn.commit",
                    json!({"txnId": txn_id}),
                )?;
                seq = sub.seq.max(seq);
                BindSamplesOutcome {
                    track_id: req.track_id.clone(),
                    device_id,
                    kind: kind.wire_name().to_string(),
                    created_device,
                    removed_zone_ids: req.remove_zone_ids.clone(),
                    zones,
                    seq,
                }
            }
            Err(e) => {
                self.rollback_txn(actor.clone());
                self.sync_after_mutation();
                return Err(e);
            }
        };
        self.sync_after_mutation();
        Ok(outcome)
    }

    /// Import an audio file onto a track at `start_ticks`. Returns the placed
    /// clip. `clip_id` is minted if not supplied.
    pub fn import_audio(
        &mut self,
        source_path: &str,
        track_id: &str,
        start_ticks: u64,
        clip_id: Option<String>,
    ) -> Result<ImportOutcome, StudioError> {
        let src = Path::new(source_path);
        let analysis = media::report::analyze_file(src, None).map_err(|e| StudioError::audio(e.to_string()))?;
        // The io half, shared verbatim with the sampler/drum source binding.
        let ingest = self.ingest_asset_file(source_path)?;
        let hash = ingest.hash;
        let len_frames = ingest.len_frames;
        let tiles_ready = ingest.tiles_ready;

        // Full-source length in ticks, clamped so the clip never reads past
        // the decoded audio (tick<->frame rounding is otherwise a footgun).
        let rate = self.session.project().sample_rate;
        let tempo = self.session.project().tempo.clone();
        let mut length_ticks = tempo.frame_to_tick(len_frames, rate).max(1);
        while length_ticks > 1 && tempo.tick_to_frame(length_ticks, rate) > len_frames {
            length_ticks -= 1;
        }

        let clip_id = clip_id.unwrap_or_else(|| format!("clip_{}", ulid::new_ulid()));
        let bar = self.session.project().time_sig.numerator as u64
            * 960 * 4 / self.session.project().time_sig.denominator as u64;
        let start_ticks = if bar == 0 { start_ticks } else { ((start_ticks + bar / 2) / bar) * bar };
        // ONE bracket, re-entrant. Called on its own this opens and closes the
        // journaled `txn.begin`/`txn.commit` pair it always did; called from
        // inside a bigger gesture (`import_stems_params`) it JOINS that
        // gesture's bracket, journals no marker of its own, and its clip lands
        // in the caller's single undo unit. See `timeline_core::Session`.
        let txn_id = format!("import_{}", ulid::new_ulid());
        let meta = || ulid::entry_meta(Actor::user(IMPORT_ACTOR));
        self.session.submit_json(meta(), "txn.begin", json!({
            "txnId": txn_id, "reason": "import.audio"
        }))?;
        // Everything between the markers runs in a closure so that ANY failure
        // aborts. It used to `?` straight out, leaving the transaction OPEN —
        // which wedged undo, redo and every later gesture for the rest of the
        // session, the same leak `land_recorded_frames` closed for recording.
        let placed = (|| -> Result<(), StudioError> {
            let import_cmd = Cmd::ImportAudio {
                source_path: source_path.to_string(), target_track_id: track_id.to_string(),
                separate: None, conform: None, start_ticks: Some(start_ticks), clip_id: Some(clip_id.clone()),
            };
            self.session.submit_with_hint(
                meta(), import_cmd,
                Cmd::ClipRemove { clip_id: clip_id.clone() }, Vec::new())?;
            let place = json!({
                "clipId": clip_id,
                "trackId": track_id,
                "assetHash": hash,
                "startTicks": start_ticks,
                "lengthTicks": length_ticks,
            });
            self.session.submit_json(meta(), "clip.place", place)?;
            Ok(())
        })();
        if let Err(e) = placed {
            self.rollback_txn(Actor::user(IMPORT_ACTOR));
            self.sync_after_mutation();
            return Err(e);
        }
        let sub = self.session.submit_json(meta(), "txn.commit", json!({"txnId": txn_id}))?;
        self.sync_after_mutation();
        Ok(ImportOutcome {
            clip_id,
            track_id: track_id.to_string(),
            asset_hash: hash,
            start_ticks,
            length_ticks,
            seq: sub.seq,
            measured_bpm: analysis.bpm,
            loudness_lufs: analysis.loudness_lufs,
            tiles_ready,
        })
    }

    /// Land an offline/synthetic input as a normal candidate take and clip.
    /// This is the deterministic acceptance path; it never calls `start_live`
    /// and therefore never opens an output stream. The live capture path
    /// (record.stop) feeds the same writer-side landing once its ring has been
    /// drained.
    pub fn record_synthetic_input(
        &mut self,
        track_id: &str,
        start_ticks: u64,
        frames: &[[f32; 2]],
    ) -> Result<RecordingOutcome, StudioError> {
        if frames.is_empty() { return Err(StudioError::audio("recording contains no frames")); }
        if !self.session.project().tracks.iter().any(|t| t.id == track_id && t.armed) {
            return Err(StudioError::invalid("recording requires an armed track"));
        }
        let rate = self.session.project().sample_rate;
        self.land_capture(track_id, start_ticks, None, frames.to_vec(), rate, "synthetic-input", start_ticks, false)
    }

    /// Device-free multi-channel simultaneous land: demux interleaved samples
    /// onto every armed audio track by its `inputChannel`.
    #[doc(hidden)]
    pub fn record_synthetic_multichannel(
        &mut self,
        start_ticks: u64,
        interleaved: &[f32],
        channel_count: usize,
    ) -> Result<Vec<RecordingOutcome>, StudioError> {
        let channel_count = channel_count.max(1);
        if interleaved.is_empty() {
            return Err(StudioError::audio("recording contains no frames"));
        }
        let targets: Vec<CaptureTarget> = self
            .session
            .project()
            .tracks
            .iter()
            .filter(|t| t.armed && t.devices.is_empty())
            .map(|t| CaptureTarget {
                track_id: t.id.clone(),
                channel: t.input_channel,
            })
            .collect();
        if targets.is_empty() {
            return Err(StudioError::invalid("recording requires an armed audio track"));
        }
        let rate = self.session.project().sample_rate;
        let mut outcomes = Vec::with_capacity(targets.len());
        for target in &targets {
            let frames = LiveInput::demux_stereo(
                interleaved,
                channel_count,
                target.channel as usize,
            );
            let outcome = self.land_capture(
                &target.track_id,
                start_ticks,
                None,
                frames,
                rate,
                "synthetic-multichannel",
                start_ticks,
                false,
            )?;
            outcomes.push(outcome);
        }
        Ok(outcomes)
    }

    /// Inject a listen-only virtual input (capturing=false) without recording.
    /// Proves input_device_is_open is not a thin alias of is_recording.
    #[doc(hidden)]
    pub fn test_begin_virtual_listen(&mut self, channel_count: usize, sample_rate: u32) {
        self.record.input = None;
        self.record.listen = Some(LiveInput::start_virtual(channel_count, sample_rate, false));
    }

    #[doc(hidden)]
    pub fn test_begin_virtual_capture(
        &mut self,
        track_id: &str,
        channel_count: usize,
        sample_rate: u32,
    ) -> Result<(), StudioError> {
        if !self.session.project().tracks.iter().any(|t| t.id == track_id && t.armed) {
            return Err(StudioError::invalid("virtual capture requires an armed track"));
        }
        if self.record.is_recording() {
            return Err(StudioError::invalid("already recording"));
        }
        self.record.listen = None;
        let targets = self.armed_audio_capture_targets(track_id);
        let input = LiveInput::start_virtual(channel_count, sample_rate, true);
        let (origin_ticks, rolling) = self.capture_origin();
        self.record.input = Some(input);
        self.record.track_id = Some(track_id.to_string());
        self.record.capture_targets = targets;
        self.record.capture_origin_ticks = origin_ticks;
        self.record.rolling = rolling;
        self.record.start_ticks = origin_ticks;
        Ok(())
    }

    /// Sample the position that audio capture actually begins at. A live
    /// session owns the advancing clock; the offline transport is the
    /// deterministic/device-free equivalent.
    fn capture_origin(&self) -> (u64, bool) {
        if let Some(live) = self.live.as_ref() {
            let rate = self.session.project().sample_rate;
            let tempo = &self.session.project().tempo;
            return (tempo.frame_to_tick(live.position_frame(), rate), live.playing());
        }
        (self.transport.position_ticks, self.transport.playing)
    }

    #[doc(hidden)]
    pub fn test_feed_virtual_capture(&self, interleaved: &[f32]) -> usize {
        self.record
            .input
            .as_ref()
            .map(|i| i.feed_virtual(interleaved))
            .unwrap_or(0)
    }

    #[doc(hidden)]
    pub fn test_stop_virtual_capture(&mut self) -> Result<Value, StudioError> {
        self.host_record_stop()
    }

    /// Queue one device-free loop pass through the same asynchronous landing
    /// path as `record.rotate`. Never opens an input or output device.
    #[doc(hidden)]
    pub fn queue_synthetic_loop_pass(
        &mut self,
        track_id: &str,
        start_ticks: u64,
        punch_out_ticks: u64,
        frames: Vec<[f32; 2]>,
    ) -> Result<(), StudioError> {
        if !self.session.project().tracks.iter().any(|t| t.id == track_id && t.armed) {
            return Err(StudioError::invalid("recording requires an armed track"));
        }
        let rate = self.session.project().sample_rate;
        self.queue_record_landing(track_id, start_ticks, Some(punch_out_ticks), frames, rate, "synthetic-input", start_ticks, false)
    }

    /// Wait for queued recording workers and return results in boundary order.
    #[doc(hidden)]
    pub fn wait_for_record_landings(&mut self) -> Vec<Result<RecordingOutcome, StudioError>> {
        self.reap_record_landings(true);
        self.record.completed_landings.drain(..).collect()
    }

    fn queue_record_landing(
        &mut self,
        track_id: &str,
        start_ticks: u64,
        punch_out_ticks: Option<u64>,
        mut frames: Vec<[f32; 2]>,
        rate: u32,
        engine_model: &str,
        capture_origin_ticks: u64,
        rolling: bool,
    ) -> Result<(), StudioError> {
        if frames.is_empty() { return Err(StudioError::audio("recording contains no frames")); }
        apply_record_placement(&self.session.project().tempo, self.session.project().phase_anchor_ticks,
            start_ticks, capture_origin_ticks, rolling, punch_out_ticks, rate, &mut frames);
        let matching = self.record.session.as_ref().filter(|s| {
            s.track_id == track_id
                && s.start_ticks == start_ticks
                && s.punch_out_ticks == punch_out_ticks
                && s.comp_clip_id.as_ref().map(|id| self.clip_exists(id)).unwrap_or(true)
        });
        let request_id = if let Some(session) = matching {
            session.request_id.clone()
        } else {
            let request_id = ulid::new_ulid();
            self.record.session = Some(RecordSession {
                track_id: track_id.to_string(), start_ticks, punch_out_ticks,
                request_id: request_id.clone(), comp_clip_id: None,
            });
            request_id
        };
        let package_dir = self.package_dir.clone();
        let (prepared_tx, prepared_rx) = channel();
        std::thread::Builder::new()
            .name("majiks-record-land".to_string())
            .spawn(move || {
                let _ = prepared_tx.send(prepare_recording_media(package_dir.as_deref(), frames, rate));
            })
            .map_err(|e| StudioError::audio(format!("spawn record landing worker: {e}")))?;
        self.record.landings.push_back(PendingRecording {
            track_id: track_id.to_string(), start_ticks, capture_origin_ticks, rolling, rate,
            engine_model: engine_model.to_string(), request_id, prepared: prepared_rx,
        });
        Ok(())
    }

    fn reap_record_landings(&mut self, wait: bool) {
        if self.session.in_txn() { return; }
        loop {
            let prepared = {
                let Some(front) = self.record.landings.front() else { break };
                if wait {
                    front.prepared.recv().ok()
                } else {
                    match front.prepared.try_recv() {
                        Ok(value) => Some(value),
                        Err(TryRecvError::Empty) => break,
                        Err(TryRecvError::Disconnected) => Some(Err(StudioError::audio(
                            "record landing worker exited without a result"))),
                    }
                }
            };
            let Some(prepared) = prepared else { break };
            let pending = self.record.landings.pop_front().expect("front exists");
            let outcome = prepared.and_then(|prepared| self.finish_prepared_recording(
                &pending.track_id, pending.start_ticks, pending.capture_origin_ticks, pending.rolling,
                pending.rate, &pending.engine_model,
                &pending.request_id, prepared));
            if self.record.completed_landings.len() == 64 { self.record.completed_landings.pop_front(); }
            self.record.completed_landings.push_back(outcome);
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn finish_prepared_recording(
        &mut self,
        track_id: &str,
        start_ticks: u64,
        _capture_origin_ticks: u64,
        rolling: bool,
        rate: u32,
        engine_model: &str,
        request_id: &str,
        prepared: PreparedRecording,
    ) -> Result<RecordingOutcome, StudioError> {
        let PreparedRecording { frames, hash, tiles_ready, loudness_lufs } = prepared;
        let frame_len = frames.len() as u64;
        let tempo = self.session.project().tempo.clone();
        let mut length_ticks = tempo.frame_to_tick(frame_len, rate).max(1);
        while length_ticks > 1 && tempo.tick_to_frame(length_ticks, rate) > frame_len { length_ticks -= 1; }
        self.sources.insert(hash.clone(), AudioBuf::from_samples(frames, "recorded"));
        let bar = self.session.project().time_sig.numerator as u64 * 960 * 4
            / self.session.project().time_sig.denominator.max(1) as u64;
        let start_ticks = placement_start_ticks(&self.session.project().tempo,
            self.session.project().phase_anchor_ticks, start_ticks, rolling, bar);
        let place_clip = self.record.session.as_ref()
            .filter(|s| s.request_id == request_id)
            .and_then(|s| s.comp_clip_id.as_ref())
            .filter(|id| self.clip_exists(id)).is_none();
        let take_id = format!("take_{}", ulid::new_ulid());
        let txn_id = format!("record_{}", ulid::new_ulid());
        self.session.submit_json(ulid::entry_meta(Actor::user("record")), "txn.begin",
            json!({"txnId": txn_id, "reason": "record.commit"}))?;
        let landed = self.finish_recorded_txn(&txn_id, &take_id, &hash, engine_model,
            request_id, place_clip, track_id, start_ticks, length_ticks);
        let (clip_id, seq) = match landed {
            Ok(value) => value,
            Err(error) => { self.rollback_txn(Actor::user("record")); return Err(error); }
        };
        if place_clip {
            if let Some(session) = self.record.session.as_mut().filter(|s| s.request_id == request_id) {
                session.comp_clip_id = Some(clip_id.clone());
            }
        }
        self.sync_after_mutation();
        Ok(RecordingOutcome { take_id, clip_id, track_id: track_id.to_string(), asset_hash: hash,
            start_ticks, length_ticks, tiles_ready, loudness_lufs, seq })
    }

    /// Trim/pad a captured buffer to the punch region (when set), then land it,
    /// managing the comp session: the first capture over a (track, start, punch)
    /// region places the comp clip; later captures over the SAME region land as
    /// take-only siblings under one requestId (loop-record fills a take lane).
    fn land_capture(
        &mut self,
        track_id: &str,
        start_ticks: u64,
        punch_out_ticks: Option<u64>,
        mut frames: Vec<[f32; 2]>,
        rate: u32,
        engine_model: &str,
        capture_origin_ticks: u64,
        rolling: bool,
    ) -> Result<RecordingOutcome, StudioError> {
        if frames.is_empty() {
            return Err(StudioError::audio("recording contains no frames"));
        }
        apply_record_placement(&self.session.project().tempo, self.session.project().phase_anchor_ticks,
            start_ticks, capture_origin_ticks, rolling, punch_out_ticks, rate, &mut frames);
        // Continue an open comp session only if it matches the region AND its
        // comp clip still exists; otherwise start a fresh comp clip.
        let matched = self
            .record
            .session
            .as_ref()
            .filter(|s| {
                s.track_id == track_id
                    && s.start_ticks == start_ticks
                    && s.punch_out_ticks == punch_out_ticks
            })
            .map(|s| (s.request_id.clone(), s.comp_clip_id.clone()));
        let continuation = matched.and_then(|(rid, cid)| {
            cid.filter(|clip_id| self.clip_exists(clip_id)).map(|_| rid)
        });
        let place_clip = continuation.is_none();
        let request_id = continuation.unwrap_or_else(ulid::new_ulid);
        let outcome =
            self.land_recorded_frames(track_id, start_ticks, &frames, rate, engine_model, place_clip, &request_id, rolling)?;
        if place_clip {
            self.record.session = Some(RecordSession {
                track_id: track_id.to_string(),
                start_ticks,
                punch_out_ticks,
                request_id,
                comp_clip_id: Some(outcome.clip_id.clone()),
            });
        }
        Ok(outcome)
    }

    /// Shared landing tail for a captured buffer (synthetic OR live input): write
    /// the WAV at the capture `rate`, content-address it, generate tiles, and
    /// journal the take as a bar-snapped clip through the normal
    /// txn.begin / gen.landed(sourceCommand record.commit) / clip.place /
    /// txn.commit sequence. `engine_model` is lineage only ("synthetic-input" vs
    /// "coreaudio-input"); the sourceCommand stays "record.commit" so the
    /// export/provenance layer classifies the clip as human-origin either way.
    fn land_recorded_frames(
        &mut self,
        track_id: &str,
        start_ticks: u64,
        frames: &[[f32; 2]],
        rate: u32,
        engine_model: &str,
        place_clip: bool,
        request_id: &str,
        rolling: bool,
    ) -> Result<RecordingOutcome, StudioError> {
        if frames.is_empty() { return Err(StudioError::audio("recording contains no frames")); }
        let tmp = std::env::temp_dir().join(format!("majiks-record-{}.wav", ulid::new_ulid()));
        render::media::write_wav_f32(&tmp, frames, rate).map_err(StudioError::audio)?;
        let bytes = std::fs::read(&tmp).map_err(StudioError::io)?;
        let hash = blake3::hash(&bytes).to_hex().to_string();
        let analysis = media::loudness::measure_loudness(frames, rate).ok();
        if let Some(pkg) = &self.package_dir {
            let audio = pkg.join("audio");
            std::fs::create_dir_all(&audio).map_err(StudioError::io)?;
            let dest = audio.join(format!("{hash}.wav"));
            if !dest.exists() { std::fs::copy(&tmp, dest).map_err(StudioError::io)?; }
        }
        let _ = std::fs::remove_file(&tmp);
        self.sources.insert(hash.clone(), AudioBuf::from_samples(frames.to_vec(), "recorded"));
        let tiles_ready = self.generate_tiles(&hash, frames)?;
        let tempo = self.session.project().tempo.clone();
        let mut length_ticks = tempo.frame_to_tick(frames.len() as u64, rate).max(1);
        while length_ticks > 1 && tempo.tick_to_frame(length_ticks, rate) > frames.len() as u64 { length_ticks -= 1; }
        let bar = self.session.project().time_sig.numerator as u64 * 960 * 4
            / self.session.project().time_sig.denominator.max(1) as u64;
        let start_ticks = placement_start_ticks(&self.session.project().tempo,
            self.session.project().phase_anchor_ticks, start_ticks, rolling, bar);
        let take_id = format!("take_{}", ulid::new_ulid());
        let txn_id = format!("record_{}", ulid::new_ulid());
        self.session.submit_json(ulid::entry_meta(Actor::user("record")), "txn.begin", json!({"txnId": txn_id, "reason": "record.commit"}))?;
        // Once the txn is open, ANY failure (e.g. a clip.place Overlap when the
        // landing region already holds a clip) must abort it. A leaked open txn
        // would wedge undo/redo and every future recording for the session.
        let landed = self.finish_recorded_txn(
            &txn_id, &take_id, &hash, engine_model, request_id, place_clip, track_id, start_ticks, length_ticks);
        let (clip_id, seq) = match landed {
            Ok(v) => v,
            Err(e) => {
                self.rollback_txn(Actor::user("record"));
                return Err(e);
            }
        };
        self.sync_after_mutation();
        Ok(RecordingOutcome { take_id, clip_id, track_id: track_id.to_string(), asset_hash: hash,
            start_ticks, length_ticks, tiles_ready, loudness_lufs: analysis.map(|x| x.integrated_lufs), seq })
    }

    /// gen.landed + (optional) clip.place + txn.commit inside an already-open
    /// record txn. Split out so `land_recorded_frames` can abort_txn() on any
    /// failure. The first capture over a region places the comp clip; loop-record
    /// passes are take-only (they stack in the take lane, not the grid).
    #[allow(clippy::too_many_arguments)]
    fn finish_recorded_txn(
        &mut self,
        txn_id: &str,
        take_id: &str,
        hash: &str,
        engine_model: &str,
        request_id: &str,
        place_clip: bool,
        track_id: &str,
        start_ticks: u64,
        length_ticks: u64,
    ) -> Result<(String, u64), StudioError> {
        self.session.submit_json(ulid::entry_meta(Actor::user("record")), "gen.landed", json!({
            "requestId": request_id, "sourceCommand": "record.commit", "takeId": take_id,
            "assetHashes": {"mix": hash}, "engineIdentity": {"model": engine_model, "device": "cpu"}
        }))?;
        let clip_id = if place_clip {
            let cid = format!("clip_{}", ulid::new_ulid());
            self.session.submit_json(ulid::entry_meta(Actor::user("record")), "clip.place", json!({
                "clipId": cid, "trackId": track_id, "assetHash": hash,
                "startTicks": start_ticks, "lengthTicks": length_ticks
            }))?;
            cid
        } else {
            String::new()
        };
        let sub = self.session.submit_json(ulid::entry_meta(Actor::user("record")), "txn.commit", json!({"txnId": txn_id}))?;
        Ok((clip_id, sub.seq))
    }

    /// True when a clip with this id is still on any track. Used to invalidate a
    /// stale comp session whose anchor clip was undone, removed, or whose track
    /// was removed.
    fn clip_exists(&self, clip_id: &str) -> bool {
        !clip_id.is_empty()
            && self.session.project().tracks.iter().any(|t| t.clips.iter().any(|c| c.id == clip_id))
    }

    /// Refresh the cached list of input-device names for the UI picker.
    /// Enumeration only; it never opens a stream, so it makes no sound.
    fn refresh_input_devices(&mut self) {
        self.record.device_info = render::recording::list_input_device_info();
        self.record.devices = self
            .record
            .device_info
            .iter()
            .map(|d| d.name.clone())
            .collect();
    }

    /// Whether `track_id` carries an instrument device (MIDI record target).
    fn track_is_instrument(&self, track_id: &str) -> bool {
        self.session
            .project()
            .tracks
            .iter()
            .any(|t| t.id == track_id && !t.devices.is_empty())
    }

    /// Privacy surface: true when an input device stream is actually open.
    pub fn input_device_is_open(&self) -> bool {
        self.record.input_open()
    }

    fn armed_audio_capture_targets(&self, primary: &str) -> Vec<CaptureTarget> {
        let tracks = &self.session.project().tracks;
        let mut targets: Vec<CaptureTarget> = tracks
            .iter()
            .filter(|t| t.armed && t.devices.is_empty())
            .map(|t| CaptureTarget {
                track_id: t.id.clone(),
                channel: t.input_channel,
            })
            .collect();
        if let Some(idx) = targets.iter().position(|t| t.track_id == primary) {
            if idx != 0 {
                targets.swap(0, idx);
            }
        }
        targets
    }

    /// Sync listen state after arm/disarm: NEVER opens a device.
    fn sync_input_listen(&mut self) {
        if self.record.input.is_some() {
            self.record.listen = None;
        }
        // Never call LiveInput::start here: arming a track should not open the
        // microphone. See host_record_input_listen / host_record_start.
    }

    /// Absolute project ticks for stamping a MIDI event during capture.
    fn midi_capture_now_ticks(&mut self) -> u64 {
        // 1. Deterministic override (tests driving feed_event without sleep).
        if let Some(cap) = self.record.midi.as_mut() {
            if let Some(t) = cap.take_override() {
                return t;
            }
        }
        // 2. Live playhead when the transport is advancing (frame → tick).
        if let Some(live) = self.live.as_ref() {
            if live.playing() {
                let rate = self.session.project().sample_rate;
                let tempo = &self.session.project().tempo;
                return tempo.frame_to_tick(live.position_frame(), rate);
            }
        }
        // 3. Wall-clock from capture start so a performance without Play still
        //    lands at the ticks that were played (tempo map).
        if let Some(cap) = self.record.midi.as_ref() {
            return cap.wall_now_ticks();
        }
        self.transport.position_ticks
    }

    /// Buffer a note-on/off into the active MIDI capture (if any). Always still
    /// auditioned by the caller.
    pub(crate) fn midi_record_event(&mut self, pitch: u8, velocity: u8, is_on: bool) {
        if self.record.midi.is_none() {
            return;
        }
        let ticks = self.midi_capture_now_ticks();
        let Some(cap) = self.record.midi.as_mut() else {
            return;
        };
        if is_on {
            cap.note_on(pitch, velocity, ticks);
        } else {
            cap.note_off(pitch, ticks);
        }
    }

    /// Deterministic MIDI capture clock for tests (absolute project ticks).
    #[doc(hidden)]
    pub fn midi_record_set_now_ticks(&mut self, ticks: u64) {
        if let Some(cap) = self.record.midi.as_mut() {
            cap.set_now_ticks(ticks);
        }
    }

    /// Clear the latched input clip indicator (UI reset).
    pub fn clear_input_clip_latch(&mut self) {
        if let Some(inp) = self.record.input.as_ref() {
            inp.clear_clip_latch();
        }
        if let Some(listen) = self.record.listen.as_ref() {
            listen.clear_clip_latch();
        }
    }

    /// Dispatch a record.* session command to its host-side capture effect. The
    /// params were already validated on the bus by `submit`.
    fn apply_record(&mut self, name: &str, params: &Value) -> Result<Value, StudioError> {
        match name {
            "record.start" => self.host_record_start(params),
            "record.rotate" => self.host_record_rotate(),
            "record.stop" => self.host_record_stop(),
            "record.cancel" => Ok(self.host_record_cancel()),
            "record.inputListen" => self.host_record_input_listen(params),
            other => Err(StudioError::invalid(format!("not a record command: {other}"))),
        }
    }

    fn host_record_input_listen(&mut self, params: &Value) -> Result<Value, StudioError> {
        let enabled = params
            .get("enabled")
            .and_then(Value::as_bool)
            .ok_or_else(|| StudioError::invalid("record.inputListen requires enabled"))?;
        if !enabled {
            self.record.listen = None;
            return Ok(json!({
                "ok": true,
                "inputOpen": self.record.input_open(),
                "listening": false,
            }));
        }
        if self.record.input.is_some() {
            return Ok(json!({
                "ok": true,
                "inputOpen": true,
                "listening": false,
                "note": "capture already open; meters come from the recording stream",
            }));
        }
        if self.record.listen.is_some() {
            return Ok(json!({
                "ok": true,
                "inputOpen": true,
                "listening": true,
            }));
        }
        let device = params.get("deviceId").and_then(Value::as_str).map(String::from);
        self.refresh_input_devices();
        let channel_hint = self.channel_hint_for_device(device.as_deref());
        match LiveInput::start(device, false, channel_hint) {
            Ok(listen) => {
                let name = listen.device_name().to_string();
                let rate = listen.sample_rate();
                let channels = listen.channel_count();
                self.record.listen = Some(listen);
                Ok(json!({
                    "ok": true,
                    "inputOpen": true,
                    "listening": true,
                    "deviceName": name,
                    "sampleRate": rate,
                    "channels": channels,
                }))
            }
            Err(e) => Ok(json!({
                "ok": true,
                "inputOpen": false,
                "listening": false,
                "note": format!("no input device: {e}"),
            })),
        }
    }

    fn channel_hint_for_device(&self, device: Option<&str>) -> usize {
        let info = match device {
            Some(want) => self.record.device_info.iter().find(|d| d.name == want),
            None => self.record.device_info.first(),
        };
        info.map(|d| d.input_channels as usize)
            .unwrap_or(2)
            .max(1)
    }

    /// Complete one loop pass without stopping the input stream. The next pass
    /// fills a fresh accumulator while this pass prepares off the capture path.
    ///
    /// MIDI loop-pass take stacking is **out of scope** for this lane: rotate
    /// on a MIDI capture is a no-op (notes keep buffering until stop). Audio
    /// rotate behaviour is unchanged.
    fn host_record_rotate(&mut self) -> Result<Value, StudioError> {
        if self.record.midi.is_some() {
            return Ok(json!({
                "ok": true,
                "recording": true,
                "rotated": false,
                "kind": "midi",
                "note": "MIDI loop-pass stacking is not implemented; notes keep buffering until record.stop",
            }));
        }
        let (interleaved, rate, channel_count, primary_channel) = {
            let Some(input) = self.record.input.as_ref() else {
                return Ok(json!({"ok": true, "recording": false, "rotated": false,
                    "pendingLandings": self.record.landings.len()}));
            };
            let primary_channel = self
                .record
                .capture_targets
                .first()
                .map(|t| t.channel as usize)
                .unwrap_or(0);
            (
                input.rotate(),
                input.sample_rate(),
                input.channel_count() as usize,
                primary_channel,
            )
        };
        if interleaved.is_empty() {
            return Ok(json!({"ok": true, "recording": true, "rotated": false,
                "pendingLandings": self.record.landings.len(), "note": "no audio captured"}));
        }
        let frames = LiveInput::demux_stereo(&interleaved, channel_count.max(1), primary_channel);
        let project_rate = self.session.project().sample_rate;
        let (frames, land_rate, resampled) = if rate != project_rate {
            let rs = render::media::resample_stereo_sinc(&frames, rate, project_rate)
                .map_err(StudioError::audio)?;
            (rs, project_rate, true)
        } else {
            (frames, rate, false)
        };
        let track_id = self.record.track_id.clone().unwrap_or_default();
        let start_ticks = self.record.start_ticks;
        let punch = self.record.punch_out_ticks;
        let first_pass_origin = self.record.capture_origin_ticks;
        let first_pass_rolling = self.record.rolling;
        self.queue_record_landing(&track_id, start_ticks, punch, frames, land_rate, "coreaudio-input",
            first_pass_origin, first_pass_rolling)?;
        self.record.rolling = false;
        self.record.capture_origin_ticks = start_ticks;
        self.reap_record_landings(false);
        Ok(json!({"ok": true, "recording": true, "rotated": true,
            "pendingLandings": self.record.landings.len(),
            "deviceSampleRate": rate, "landedSampleRate": land_rate,
            "projectSampleRate": project_rate, "resampled": resampled}))
    }

    fn host_record_start(&mut self, params: &Value) -> Result<Value, StudioError> {
        if self.record.is_recording() {
            return Err(StudioError::invalid("a recording is already in progress; stop it first"));
        }
        let track_id = str_param(params, "trackId")?;
        if !self.session.project().tracks.iter().any(|t| t.id == track_id && t.armed) {
            return Err(StudioError::invalid("record.start requires an armed track (send track.arm first)"));
        }
        let requested_start_ticks = params
            .get("startTicks")
            .and_then(Value::as_u64)
            ;
        let requested_punch_out = params
            .get("punchOutTicks")
            .and_then(Value::as_u64);
        let (capture_origin_ticks, rolling) = self.capture_origin();
        let punch_start = requested_start_ticks.unwrap_or(capture_origin_ticks);
        let punch_out = requested_punch_out.filter(|po| {
            *po > punch_start && (!rolling || *po > capture_origin_ticks)
        });
        let ignored_start = requested_start_ticks.is_some() && rolling && punch_out.is_none();
        let ignored_punch = requested_punch_out.is_some() && punch_out.is_none();
        let start_ticks = if punch_out.is_some() {
            requested_start_ticks.unwrap_or(capture_origin_ticks)
        } else if rolling {
            capture_origin_ticks
        } else {
            requested_start_ticks.unwrap_or(capture_origin_ticks)
        };

        if self.track_is_instrument(&track_id) {
            self.record.listen = None;
            self.record.capture_targets.clear();
            self.performance = None;
            let bpm = self.session.project().tempo.first_bpm();
            let (bpm_num, bpm_den) = (bpm.num, bpm.den);
            self.record.midi = Some(MidiCapture::new(
                track_id.clone(),
                start_ticks,
                punch_out,
                bpm_num,
                bpm_den,
            ));
            self.record.track_id = Some(track_id.clone());
            self.record.capture_origin_ticks = capture_origin_ticks;
            self.record.rolling = rolling;
            self.record.start_ticks = start_ticks;
            self.record.punch_out_ticks = punch_out;
            return Ok(json!({
                "ok": true,
                "recording": true,
                "kind": "midi",
                "trackId": track_id,
                "startTicks": start_ticks,
                "punchOutTicks": punch_out,
                "captureOriginTicks": capture_origin_ticks,
                "rolling": rolling,
                "ignoredParams": ignored_record_params(ignored_start, ignored_punch),
                "note": ignored_record_note(ignored_start, ignored_punch),
                "inputOpen": false,
            }));
        }

        let targets = self.armed_audio_capture_targets(&track_id);
        if targets.is_empty() {
            return Err(StudioError::invalid(
                "record.start on an audio track requires at least one armed audio track",
            ));
        }
        let max_channel = targets.iter().map(|t| t.channel).max().unwrap_or(0) as usize + 1;
        let device = params.get("deviceId").and_then(Value::as_str).map(String::from);
        self.refresh_input_devices();
        let channel_hint = self
            .channel_hint_for_device(device.as_deref())
            .max(max_channel);
        let input = if let Some(listen) = self.record.listen.take() {
            listen.set_capturing(true);
            listen
        } else {
            LiveInput::start(device, true, channel_hint)?
        };
        let device_name = input.device_name().to_string();
        let sample_rate = input.sample_rate();
        let channels = input.channel_count();
        let project_rate = self.session.project().sample_rate;
        let rate_mismatch = sample_rate != project_rate;
        let (origin_ticks, rolling) = self.capture_origin();
        let punch_out = requested_punch_out.filter(|po| {
            *po > requested_start_ticks.unwrap_or(origin_ticks)
                && (!rolling || *po > origin_ticks)
        });
        let ignored_start = requested_start_ticks.is_some() && rolling && punch_out.is_none();
        let ignored_punch = requested_punch_out.is_some() && punch_out.is_none();
        let start_ticks = if punch_out.is_some() {
            requested_start_ticks.unwrap_or(origin_ticks)
        } else if rolling {
            origin_ticks
        } else {
            requested_start_ticks.unwrap_or(origin_ticks)
        };
        self.record.input = Some(input);
        self.record.track_id = Some(track_id.clone());
        self.record.capture_targets = targets.clone();
        self.record.start_ticks = start_ticks;
        self.record.capture_origin_ticks = origin_ticks;
        self.record.rolling = rolling;
        self.record.punch_out_ticks = punch_out;
        Ok(json!({
            "ok": true,
            "recording": true,
            "kind": "audio",
            "trackId": track_id,
            "deviceName": device_name,
            "sampleRate": sample_rate,
            "projectSampleRate": project_rate,
            "rateMismatch": rate_mismatch,
            "channels": channels,
            "captureTargets": targets.iter().map(|t| json!({
                "trackId": t.track_id,
                "channel": t.channel,
            })).collect::<Vec<_>>(),
            "startTicks": start_ticks,
            "punchOutTicks": punch_out,
            "captureOriginTicks": origin_ticks,
            "rolling": rolling,
            "ignoredParams": ignored_record_params(ignored_start, ignored_punch),
            "note": ignored_record_note(ignored_start, ignored_punch),
            "inputOpen": true,
        }))
    }

    fn host_record_stop(&mut self) -> Result<Value, StudioError> {
        if self.record.midi.is_some() {
            return self.host_record_stop_midi();
        }
        let Some(mut input) = self.record.input.take() else {
            return Ok(json!({ "ok": true, "recording": false, "landed": false, "inputOpen": false }));
        };
        let track_id = self.record.track_id.take().unwrap_or_default();
        let targets = std::mem::take(&mut self.record.capture_targets);
        let start_ticks = self.record.start_ticks;
        let capture_origin_ticks = self.record.capture_origin_ticks;
        let rolling = self.record.rolling;
        let punch = self.record.punch_out_ticks.take();
        let rate = input.sample_rate();
        let channel_count = input.channel_count() as usize;
        let interleaved = input.finish();
        self.sync_input_listen();
        if interleaved.is_empty() {
            self.reap_record_landings(true);
            return Ok(json!({
                "ok": true,
                "recording": false,
                "landed": false,
                "inputOpen": self.record.input_open(),
                "note": "no audio captured",
            }));
        }
        self.reap_record_landings(true);
        let project_rate = self.session.project().sample_rate;
        let targets = if targets.is_empty() {
            vec![CaptureTarget { track_id: track_id.clone(), channel: 0 }]
        } else {
            targets
        };
        let mut landed = Vec::new();
        for target in &targets {
            let frames =
                LiveInput::demux_stereo(&interleaved, channel_count.max(1), target.channel as usize);
            let (frames, land_rate, resampled) = if rate != project_rate {
                let rs = render::media::resample_stereo_sinc(&frames, rate, project_rate)
                    .map_err(StudioError::audio)?;
                (rs, project_rate, true)
            } else {
                (frames, rate, false)
            };
            let outcome = self.land_capture(
                &target.track_id,
                start_ticks,
                punch,
                frames,
                land_rate,
                "coreaudio-input",
                capture_origin_ticks,
                rolling,
            )?;
            landed.push(json!({
                "takeId": outcome.take_id,
                "clipId": outcome.clip_id,
                "trackId": outcome.track_id,
                "channel": target.channel,
                "startTicks": outcome.start_ticks,
                "lengthTicks": outcome.length_ticks,
                "seq": outcome.seq,
                "assetHash": outcome.asset_hash,
                "deviceSampleRate": rate,
                "landedSampleRate": land_rate,
                "resampled": resampled,
            }));
        }
        let primary = landed.first().cloned().unwrap_or(json!({}));
        Ok(json!({
            "ok": true,
            "recording": false,
            "kind": "audio",
            "landed": true,
            "inputOpen": self.record.input_open(),
            "takeId": primary.get("takeId").cloned().unwrap_or(Value::Null),
            "clipId": primary.get("clipId").cloned().unwrap_or(Value::Null),
            "trackId": primary.get("trackId").cloned().unwrap_or(json!(track_id)),
            "startTicks": primary.get("startTicks").cloned().unwrap_or(json!(start_ticks)),
            "lengthTicks": primary.get("lengthTicks").cloned().unwrap_or(Value::Null),
            "seq": primary.get("seq").cloned().unwrap_or(Value::Null),
            "landings": landed,
            "deviceSampleRate": rate,
            "projectSampleRate": project_rate,
            "resampled": rate != project_rate,
        }))
    }

    /// Land a MIDI take: close open notes, place a MIDI clip if needed, one
    /// batched `note.add`, all inside a txn for a single undo step.
    fn host_record_stop_midi(&mut self) -> Result<Value, StudioError> {
        let Some(mut cap) = self.record.midi.take() else {
            return Ok(json!({ "ok": true, "recording": false, "landed": false }));
        };
        let track_id = self.record.track_id.take().unwrap_or_else(|| cap.track_id.clone());
        let start_ticks = self.record.start_ticks;
        let punch = self.record.punch_out_ticks.take();
        // Force-close at punch-out or the capture clock so nothing sticks.
        // Prefer: punch-out > deterministic override (tests) > wall clock.
        let close_at = punch.unwrap_or_else(|| {
            cap.peek_override()
                .unwrap_or_else(|| cap.wall_now_ticks())
                .max(cap.end_ticks())
        });
        cap.close_all_at(close_at);

        if cap.completed().is_empty() {
            return Ok(json!({
                "ok": true,
                "recording": false,
                "kind": "midi",
                "landed": false,
                "note": "no MIDI captured",
            }));
        }

        let mut out = self.land_midi_capture(&cap, &track_id, start_ticks, "record")?;
        if let Value::Object(map) = &mut out {
            map.insert("recording".into(), json!(false));
        }
        Ok(out)
    }

    /// Land a buffer of captured MIDI notes onto a track as real, journaled
    /// notes: place a MIDI clip if there is not already one at `start_ticks`,
    /// then one batched `note.add`, all inside a txn so the whole take is a
    /// SINGLE undo step.
    ///
    /// Shared verbatim by the two ways notes get kept — `record.stop` landing an
    /// armed take, and `performance_keep` landing the retro-capture buffer. They
    /// differ only in how the notes were collected and in the `origin` stamped
    /// on the journal entries; the landing itself must not be written twice, or
    /// the two would drift and one of them would quietly start producing
    /// differently-shaped clips.
    fn land_midi_capture(
        &mut self,
        cap: &MidiCapture,
        track_id: &str,
        start_ticks: u64,
        origin: &'static str,
    ) -> Result<Value, StudioError> {
        if cap.completed().is_empty() {
            return Ok(json!({
                "ok": true, "kind": "midi", "landed": false, "noteCount": 0,
                "note": "no MIDI captured",
            }));
        }
        let end_ticks = cap.end_ticks().max(start_ticks.saturating_add(1));
        let length_ticks = end_ticks.saturating_sub(start_ticks).max(1);

        // Prefer an existing MIDI clip on this track that starts at start_ticks
        // (or contains the take). Otherwise place a new one.
        let existing_clip = self
            .session
            .project()
            .tracks
            .iter()
            .find(|t| t.id == track_id)
            .and_then(|t| {
                t.clips
                    .iter()
                    .find(|c| c.is_midi() && c.start_ticks == start_ticks)
                    .map(|c| c.id.clone())
            });

        let txn_id = format!("midi_{origin}_{}", ulid::new_ulid());
        let actor = || ulid::entry_meta(Actor::user(origin));
        self.session.submit_json(
            actor(),
            "txn.begin",
            json!({"txnId": txn_id, "reason": format!("{origin}.midi")}),
        )?;

        let land = (|| -> Result<(String, usize), StudioError> {
            let clip_id = if let Some(id) = existing_clip {
                id
            } else {
                let cid = format!("clip_{}", ulid::new_ulid());
                self.session.submit_json(
                    actor(),
                    "clip.placeMidi",
                    json!({
                        "clipId": cid,
                        "trackId": track_id,
                        "startTicks": start_ticks,
                        "lengthTicks": length_ticks,
                    }),
                )?;
                cid
            };

            // If the clip already existed and is shorter than the take, extend
            // via clip.trim is out of scope — notes with start past the clip
            // content still store; bake crops. Prefer length that covers notes
            // when we just placed the clip (done above).

            let notes = cap.to_note_specs(start_ticks, |_| format!("{origin}_{}", ulid::new_ulid()));
            let note_count = notes.len();
            self.session.submit_json(
                actor(),
                "note.add",
                json!({ "clipId": clip_id, "notes": notes }),
            )?;
            Ok((clip_id, note_count))
        })();

        let (clip_id, note_count) = match land {
            Ok(v) => v,
            Err(e) => {
                self.rollback_txn(Actor::user(origin));
                return Err(e);
            }
        };

        let sub = self
            .session
            .submit_json(actor(), "txn.commit", json!({"txnId": txn_id}))?;
        self.sync_after_mutation();

        Ok(json!({
            "ok": true,
            "kind": "midi",
            "landed": true,
            "clipId": clip_id,
            "trackId": track_id,
            "startTicks": start_ticks,
            "lengthTicks": length_ticks,
            "noteCount": note_count,
            "seq": sub.seq,
        }))
    }

    /// record.cancel: discard the active capture without landing anything.
    fn host_record_cancel(&mut self) -> Value {
        let was_audio = self.record.input.take().is_some();
        let was_midi = self.record.midi.take().is_some();
        self.record.track_id = None;
        self.record.capture_targets.clear();
        self.record.punch_out_ticks = None;
        self.performance = None;
        self.sync_input_listen();
        json!({
            "ok": true,
            "recording": false,
            "cancelled": was_audio || was_midi,
            "inputOpen": self.record.input_open(),
        })
    }

    fn generate_tiles(&self, hash: &str, frames: &[[f32; 2]]) -> Result<bool, StudioError> {
        generate_tiles_at(self.package_dir.as_deref(), hash, frames)
    }

    fn import_stems_params(&mut self, params: &Value) -> Result<Value, StudioError> {
        let dir = str_param(params, "sourceDir")?;
        let first_track = str_param(params, "targetTrackId")?;
        let start = params.get("startTicks").and_then(Value::as_u64).unwrap_or(0);
        let group = params.get("groupName").and_then(Value::as_str).unwrap_or("Imported stems");
        let mut files: Vec<PathBuf> = std::fs::read_dir(&dir)
            .map_err(|e| StudioError::io(format!("read stem directory {dir}: {e}")))?
            .filter_map(Result::ok)
            .map(|e| e.path())
            .filter(|p| p.is_file() && matches!(p.extension().and_then(|e| e.to_str()).map(|e| e.to_ascii_lowercase()).as_deref(), Some("wav") | Some("aiff") | Some("aif") | Some("flac") | Some("mp3") | Some("m4a")))
            .collect();
        files.sort();
        if files.is_empty() { return Err(StudioError::invalid("stem directory contains no supported audio files")); }

        // ONE GESTURE, ONE UNDO STEP.
        //
        // Dropping a folder of stems on the arrangement is one drag. It used to
        // cost 2N presses of Cmd-Z to take back — the `import.stems` record, a
        // bare `track.add` per file past the first, and a transaction of its own
        // per `import_audio` — so taking back a four-stem drop meant watching
        // the session come apart in eight pieces. `apply.rs` has said since v1
        // that "the host expands the directory into ordinary track.add and
        // clip.place commands IN THE SAME TRANSACTION"; the host simply never
        // opened one, because `Session` refused to let `import_audio` nest
        // inside it. It is re-entrant now, so the intent and the code agree.
        let txn_id = format!("stems_{}", ulid::new_ulid());
        self.session.submit_json(
            ulid::entry_meta(Actor::user(IMPORT_ACTOR)),
            "txn.begin",
            json!({"txnId": txn_id, "reason": "import.stems"}),
        )?;
        let built = self.import_stems_inside_txn(&dir, &first_track, start, group, &files);
        let (tracks, imported) = match built {
            Ok(v) => v,
            Err(e) => {
                // A stem that will not decode takes the WHOLE drop back — the
                // tracks already minted, the clips already placed, and (via
                // `Session::abort_txn`) the journal entries that recorded them.
                // Half a folder is not what anyone dragged.
                self.rollback_txn(Actor::user(IMPORT_ACTOR));
                self.sync_after_mutation();
                return Err(e);
            }
        };
        self.session.submit_json(
            ulid::entry_meta(Actor::user(IMPORT_ACTOR)),
            "txn.commit",
            json!({"txnId": txn_id}),
        )?;
        self.sync_after_mutation();
        Ok(json!({"ok": true, "groupName": group, "count": imported.len(), "tracks": tracks, "stems": imported, "sourceDir": dir}))
    }

    /// The mutating half of a stem import, run inside the caller's open
    /// transaction. Split out so every failure path lands on ONE abort rather
    /// than on `?` returning through an open bracket.
    ///
    /// Returns `(tracks, stems)` — the rows the caller can now see, and the
    /// per-file import outcomes.
    fn import_stems_inside_txn(
        &mut self,
        dir: &str,
        first_track: &str,
        start: u64,
        group: &str,
        files: &[PathBuf],
    ) -> Result<(Vec<Value>, Vec<Value>), StudioError> {
        // The ids of the tracks this import will MINT, chosen up front so the
        // record journaled below can name one of them. `files[0]` lands on the
        // track the CALLER supplied, so the group is that track plus one new
        // track per remaining stem.
        let minted: Vec<String> = (1..files.len())
            .map(|index| format!("stem_{}_{}", ulid::new_ulid(), index))
            .collect();

        // WHAT REVERSES THIS RECORD, STATED TRUTHFULLY.
        //
        // The envelope's `inverse` is a hash-chained CLAIM about how to take
        // this entry back. It used to name `track.remove` of the CALLER'S
        // track — a track this import never created and must never touch.
        // `tests/import.rs`'s one-undo test says exactly that in as many words
        // ("a device on the caller's track: an inverse that rebuilt the track
        // instead of never touching it would lose this and nothing else would
        // notice"), so the record was carrying the very statement that test
        // exists to refute.
        //
        // It is never executed: `apply.rs` answers `record_only`, the undo
        // sequence passed here is empty, and real reversal comes from the
        // `track.add` / `clip.place` inverses inside this transaction. But the
        // journal is a replayed, hash-chained record, and a wrong claim in it
        // is a wrong claim.
        //
        // The declared NAME stays `track.remove`. `inverseRule` is v1.1 law and
        // `timeline-core/tests/catalog_superset.rs` pins it byte-equal to the
        // frozen v1.1 file, so the catalog is not where this could be fixed —
        // only WHICH track the claim names, and that is the first track this
        // import mints.
        //
        // ⚠️ RESIDUAL, deliberate and pinned by
        // `the_stem_import_record_names_a_track_the_import_made`: a folder
        // holding a SINGLE stem mints no track at all. `undoable: true` is also
        // v1.1 law and `contracts/conformance` refuses a null inverse under it
        // ("catalog says undoable=true but envelope inverse is null"), so there
        // is no way to say "nothing to remove" and no truthful `track.remove`
        // to name. That one case keeps the caller's track.
        let declared_inverse_target = minted.first().cloned().unwrap_or_else(|| first_track.to_string());
        self.session.submit_with_hint(
            ulid::entry_meta(Actor::user(IMPORT_ACTOR)),
            Cmd::ImportStems { source_dir: dir.to_string(), target_track_id: first_track.to_string(), start_ticks: Some(start), group_name: Some(group.to_string()) },
            Cmd::TrackRemove { track_id: declared_inverse_target }, Vec::new())?;
        let mut imported = Vec::new();
        // WHICH tracks, not HOW MANY. A count is unusable to the caller that
        // has to do the next thing — an agent told "4" has to diff two
        // snapshots to find out what it now owns, and a person told "4" has
        // learnt nothing about the four rows that just appeared. Every entry
        // carries the name the row shows and whether this call is what put it
        // there, so "the ones I made" is answerable without a second call.
        let mut tracks = Vec::new();
        for (index, path) in files.iter().enumerate() {
            let name = path.file_stem().and_then(|s| s.to_str()).unwrap_or("Stem").to_string();
            let created = index > 0;
            let track = if created {
                // Minted above, not here: the record's declared inverse has to
                // name one of these and it is journaled before this loop runs.
                let id = minted[index - 1].clone();
                self.bus_submit(Actor::user(IMPORT_ACTOR), "track.add", json!({"trackId": id, "name": name}))?;
                id
            } else {
                first_track.to_string()
            };
            // The first stem lands on the track the CALLER supplied, so its
            // name is whatever that track already had — reading it back beats
            // reporting the file's stem for a row that does not say it.
            let shown = if created {
                name.clone()
            } else {
                self.session.project().tracks.iter()
                    .find(|t| t.id == track).map(|t| t.name.clone()).unwrap_or(name.clone())
            };
            tracks.push(json!({ "trackId": track, "name": shown, "created": created }));
            imported.push(self.import_audio(&path.display().to_string(), &track, start, None)?.to_json());
        }
        Ok((tracks, imported))
    }

    // -----------------------------------------------------------------------
    // Bounce (offline render through the SAME graph as the device callback).
    // -----------------------------------------------------------------------

    /// Bounce the whole master mix to `out`. Deterministic; silent at any
    /// device (this path never opens one).
    pub fn bounce_master(&self, out: &Path) -> Result<BounceReport, StudioError> {
        let audio = self.render_full()?;
        self.write_bounce(out, &audio)
    }

    /// Render the whole master mix to samples (no file written). Backs the
    /// null-match tests: two routes that build the same journal must bounce
    /// bit-identically.
    pub fn render_master(&self) -> Result<Vec<[f32; 2]>, StudioError> {
        self.render_full()
    }

    /// Bounce a tick region [start, end) of the master mix to `out`.
    pub fn bounce_region(
        &self,
        out: &Path,
        start_ticks: u64,
        end_ticks: u64,
    ) -> Result<BounceReport, StudioError> {
        if start_ticks >= end_ticks {
            return Err(StudioError::invalid("startTicks must be before endTicks"));
        }
        let project = self.session.project();
        let rate = project.sample_rate;
        let start_f = project.tempo.tick_to_frame(start_ticks, rate) as usize;
        let end_f = project.tempo.tick_to_frame(end_ticks, rate) as usize;
        let full = self.render_to(end_f as u64)?;
        let slice = full.get(start_f..end_f.min(full.len())).unwrap_or(&[]).to_vec();
        self.write_bounce(out, &slice)
    }

    /// Render the whole project (content end + a 1s tail) offline.
    fn render_full(&self) -> Result<Vec<[f32; 2]>, StudioError> {
        let total = self.content_end_frame()? + BOUNCE_TAIL_FRAMES;
        self.render_to(total)
    }

    /// Compile the model + synced params and render `total_frames` offline.
    fn render_to(&self, total_frames: u64) -> Result<Vec<[f32; 2]>, StudioError> {
        let project = self.session.project();
        let automation = self.build_automation();
        let max_tracks = project.tracks.len().max(1);
        let session = compile_session_full(
            project,
            &self.sources,
            &self.warp_overlay(),
            &automation,
            max_tracks,
            self.declick,
        )
        .map_err(StudioError::audio)?;

        let cfg = EngineConfig {
            sample_rate: project.sample_rate,
            max_tracks,
            ..EngineConfig::default()
        };
        let mut renderer = ManualRenderer::new(&cfg);
        self.sync_params(renderer.params());
        let audio = render_offline_with(
            &mut renderer,
            vec![
                ScheduledCommand {
                    at_frame: 0,
                    command: RenderCommand::SetSession(session),
                },
                ScheduledCommand {
                    at_frame: 0,
                    command: RenderCommand::Play,
                },
            ],
            total_frames,
            512,
        );
        Ok(audio)
    }

    /// Content end frame from the compiled session (warp-aware), falling back
    /// to the model's materialized clip extents.
    fn content_end_frame(&self) -> Result<u64, StudioError> {
        let project = self.session.project();
        let automation = self.build_automation();
        let max_tracks = project.tracks.len().max(1);
        let session = compile_session_full(
            project,
            &self.sources,
            &self.warp_overlay(),
            &automation,
            max_tracks,
            self.declick,
        )
        .map_err(StudioError::audio)?;
        Ok(session_end_frame(&session).max(project.content_end_frame()))
    }

    fn write_bounce(&self, out: &Path, audio: &[[f32; 2]]) -> Result<BounceReport, StudioError> {
        let rate = self.session.project().sample_rate;
        if let Some(parent) = out.parent() {
            std::fs::create_dir_all(parent).map_err(StudioError::io)?;
        }
        write_wav_f32(out, audio, rate).map_err(StudioError::audio)?;
        let peak = audio
            .iter()
            .flat_map(|f| [f[0].abs(), f[1].abs()])
            .fold(0.0_f32, f32::max);
        Ok(BounceReport {
            output_path: out.to_path_buf(),
            frames: audio.len() as u64,
            seconds: audio.len() as f64 / f64::from(rate),
            peak,
            sample_rate: rate,
        })
    }

    /// Build a render-side automation store from the model's per-track lanes.
    ///
    /// Generic over ParamRef: EVERY lane crosses the seam, not just volume and
    /// pan. A lane whose parameter has no render-side consumer yet is carried
    /// into the compiled snapshot's slot table and simply not read — E2/E4/E8
    /// wire the consumer without touching this function or `RtTrack`.
    fn build_automation(&self) -> AutomationStore {
        let mut store = AutomationStore::new();
        for track in &self.session.project().tracks {
            for (path, points) in track.automation.iter_lanes() {
                for p in points {
                    store.add_point_path(
                        &track.id,
                        path.as_str(),
                        RawPoint {
                            tick: p.position_ticks,
                            value: p.value.as_f64() as f32,
                            curve: CurveKind::Linear,
                        },
                    );
                }
            }
        }
        store
    }

    /// Mirror the model's mixer + master state into a renderer's atomic params
    /// (the compile only bakes clips + automation; gain/pan/eq/sends/master/
    /// limiter are params, exactly like the live engine).
    ///
    /// `pub` so the push itself is observable. Every offline bounce builds a
    /// FRESH `ManualRenderer`, whose params start at their cleared defaults, so
    /// the stale-slot clears below are invisible through `render_master` no
    /// matter how wrong they are — a mutation that deletes them leaves the
    /// bounce tests green (verified). The only params block that survives a
    /// session swap belongs to the LIVE engine, and the live tests are opt-in
    /// behind `MAJIKS_TEST_LIVE=1`, i.e. skipped in the gate. Exposing the
    /// production function is what lets the gate cover it without a device.
    pub fn sync_params(&self, params: &render::params::EngineParams) {
        let project = self.session.project();
        self.sync_metronome_params(params);
        for (i, t) in project.tracks.iter().enumerate() {
            params.set_track_mute(i, t.mute);
            params.set_track_solo(i, t.solo);
            params.set_track_gain_db(i, t.gain.as_f64() as f32);
            params.set_track_pan(i, t.pan.as_f64() as f32);
            for (band, eq) in t.eq.iter().enumerate() {
                params.set_track_eq(
                    i,
                    band,
                    eq.freq_hz.as_f64() as f32,
                    eq.gain_db.as_f64() as f32,
                    eq.q.as_f64() as f32,
                );
            }
            params.set_track_send(i, false, t.sends.a.as_f64() as f32);
            params.set_track_send(i, true, t.sends.b.as_f64() as f32);
        }
        // Solo is a GLOBAL gate: a flag left on a slot past the current track
        // count would silence the whole mix (unlike a stale mute, which only
        // affects its own strip).
        params.clear_track_solos_from(project.tracks.len());
        // The E5 routing atomics have the SAME hazard, one dimension out
        // (DESIGN-E5-routing.md §6.3): edge-level and node-gain slots are
        // assigned by `compile` and change on every session swap, so a level
        // left in a retired slot is either harmless (nothing points at it) or
        // wrong (a recycled edge inherits a level the user never set).
        //
        // §23.1 — THE EDGE-LEVEL PUSH, and E5-graph's one bounded edit to this
        // file. `RtSession::edge_index` is SCHEDULE order and only `compile`
        // produces it, so the push cannot be written here: the host cannot
        // derive the mapping (declaration order is not schedule order) and
        // guessing it would permute the mix. `compile::sync_graph_params` is
        // that mapping's owner, so push and clear live together, in one
        // function, in the file that assigns the slots. It also carries the
        // effect-parameter push (`seed_fx_defaults` before stored params,
        // §23.5) and every `clear_*_from`, which are the same slot-ordering
        // problem with the same stale-slot hazard.
        //
        // Without this call, every send level would read zero, silently —
        // row 7's bug wearing new clothes, and the exact defect this epic was
        // started to fix.
        render::compile::sync_graph_params(project, params);
        params.set_master_gain_db(project.master.gain_db.as_f64() as f32);
        let lim = &project.master.limiter;
        params.set_limiter(
            lim.enabled,
            lim.ceiling_db.as_f64() as f32,
            lim.release_ms.as_f64() as f32,
        );
    }

    // -----------------------------------------------------------------------
    // Host-io export commands (bounce to file + journal the provenance record).
    // -----------------------------------------------------------------------

    fn host_export_master(&mut self, params: &Value) -> Result<Value, StudioError> {
        let out = str_param(params, "outputPath")?;
        let format = DeliverableFormat::parse(&str_param(params, "format")?)?;
        self.reject_rate_override(params)?;
        let target = loudness_target(params);
        // Bounce through the offline graph, normalize to the loudness target,
        // then write the deliverable (24-bit WAV or AudioToolbox AAC).
        let mut audio = self.render_master()?;
        let norm = normalize_to_target(&mut audio, self.session.project().sample_rate, target);
        let report = self.write_deliverable(Path::new(&out), &audio, format)?;
        self.journal_record("export.master", params.clone())?;
        let manifest_path = self.maybe_write_manifest(params, Path::new(&out))?;
        Ok(self.export_result(&report, format, Some(&norm), manifest_path))
    }

    fn host_export_region(&mut self, params: &Value) -> Result<Value, StudioError> {
        let out = str_param(params, "outputPath")?;
        let format = DeliverableFormat::parse(&str_param(params, "format")?)?;
        self.reject_rate_override(params)?;
        let start = params.get("startTicks").and_then(Value::as_u64).unwrap_or(0);
        let end = params.get("endTicks").and_then(Value::as_u64).unwrap_or(0);
        if start >= end {
            return Err(StudioError::invalid("startTicks must be before endTicks"));
        }
        let target = loudness_target(params);
        let mut audio = self.render_region_samples(start, end)?;
        let norm = normalize_to_target(&mut audio, self.session.project().sample_rate, target);
        let report = self.write_deliverable(Path::new(&out), &audio, format)?;
        self.journal_record("export.region", params.clone())?;
        let manifest_path = self.maybe_write_manifest(params, Path::new(&out))?;
        Ok(self.export_result(&report, format, Some(&norm), manifest_path))
    }

    fn host_export_stems(&mut self, params: &Value) -> Result<Value, StudioError> {
        let out_dir = str_param(params, "outputDir")?;
        // Stems are a mastering deliverable; v1 writes 24-bit WAV per track and
        // does NOT loudness-normalize individual stems (that is a master-only
        // decision). AAC stems are not offered (stems feed a DAW/mixer, not a
        // player), matching the catalog format enum (wav|flac).
        let fmt = str_param(params, "format")?;
        if !fmt.eq_ignore_ascii_case("wav") {
            return Err(StudioError::Unsupported(format!(
                "stem export is 24-bit WAV in v1 (asked for {fmt})"
            )));
        }
        let dir = PathBuf::from(&out_dir);
        std::fs::create_dir_all(&dir).map_err(StudioError::io)?;
        let track_ids: Vec<String> = self
            .session
            .project()
            .tracks
            .iter()
            .map(|t| t.id.clone())
            .collect();
        let mut written = Vec::new();
        for tid in &track_ids {
            let audio = self.render_track_solo(tid)?;
            let path = dir.join(format!("{}.wav", sanitize_name(tid)));
            write_wav_i24(&path, &audio, self.session.project().sample_rate)
                .map_err(StudioError::audio)?;
            written.push(json!({ "trackId": tid, "outputPath": path.display().to_string() }));
        }
        self.journal_record("export.stems", params.clone())?;
        let manifest_path = self.maybe_write_manifest(params, &dir.join("stems"))?;
        Ok(json!({
            "ok": true,
            "format": "wav",
            "bitDepth": 24,
            "stems": written,
            "manifestPath": manifest_path,
            "provenance": self.provenance_brief(),
        }))
    }

    /// Render a single track in isolation (all other tracks muted).
    fn render_track_solo(&self, keep_track_id: &str) -> Result<Vec<[f32; 2]>, StudioError> {
        let project = self.session.project();
        let automation = self.build_automation();
        let max_tracks = project.tracks.len().max(1);
        let session = compile_session_full(
            project,
            &self.sources,
            &self.warp_overlay(),
            &automation,
            max_tracks,
            self.declick,
        )
        .map_err(StudioError::audio)?;
        let cfg = EngineConfig {
            sample_rate: project.sample_rate,
            max_tracks,
            ..EngineConfig::default()
        };
        let mut renderer = ManualRenderer::new(&cfg);
        self.sync_params(renderer.params());
        // Mute everything except the kept track. Stem export isolates by
        // MUTE, so the model's solo state must not also gate here (a soloed
        // other track would silence this stem).
        renderer.params().clear_track_solos_from(0);
        for (i, t) in project.tracks.iter().enumerate() {
            renderer.params().set_track_mute(i, t.id != keep_track_id || t.mute);
        }
        let total = self.content_end_frame()? + BOUNCE_TAIL_FRAMES;
        let audio = render_offline_with(
            &mut renderer,
            vec![
                ScheduledCommand { at_frame: 0, command: RenderCommand::SetSession(session) },
                ScheduledCommand { at_frame: 0, command: RenderCommand::Play },
            ],
            total,
            512,
        );
        Ok(audio)
    }

    fn host_export_manifest(&mut self, _actor: Actor, params: &Value) -> Result<Value, StudioError> {
        let out = str_param(params, "outputPath")?;
        let manifest = self.manifest_value();
        let text = serde_json::to_string_pretty(&manifest).map_err(StudioError::io)?;
        if let Some(parent) = Path::new(&out).parent() {
            std::fs::create_dir_all(parent).map_err(StudioError::io)?;
        }
        std::fs::write(&out, text).map_err(StudioError::io)?;
        self.journal_record("export.manifest", params.clone())?;
        Ok(json!({
            "ok": true,
            "outputPath": out,
            "provenance": self.provenance_brief(),
        }))
    }

    fn host_publish(&mut self, _actor: Actor, params: &Value) -> Result<Value, StudioError> {
        // The majiks.online publish pipeline is out of the engine surface's
        // scope (02-ARCH: shipped pre-Studio). Journal the intent for
        // provenance and report it as recorded-not-executed, no invention.
        self.journal_record("publish.track", params.clone())?;
        Ok(json!({
            "ok": true,
            "recorded": true,
            "executed": false,
            "note": "publish is handled by the app's existing majiks.online path; the engine surface records intent only"
        }))
    }

    /// Journal a non-undoable provenance record (export.* / publish.track).
    fn journal_record(&mut self, name: &str, params: Value) -> Result<(), StudioError> {
        let meta = ulid::entry_meta(Actor::system());
        self.session.submit_json(meta, name, params)?;
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Read surface (backs the MCP read tools + FFI snapshot).
    // -----------------------------------------------------------------------

    /// Full snapshot, or a delta description when `since` is given.
    pub fn snapshot(&self, since: Option<u64>) -> Value {
        let seq = self.session.seq();
        let mut root = Map::new();
        root.insert("seq".into(), json!(seq));
        // The live render fault rides EVERY snapshot, including the `unchanged`
        // and `resync` early paths — the UI polls this, and a fault that only
        // appeared on a full delta would be invisible for exactly as long as the
        // user stopped editing, which is precisely when they are listening.
        root.insert("liveRenderError".into(), json!(self.live_render_error));
        if let Some(since) = since {
            match self.session.changes_since(since) {
                timeline_core::Changes::None => {
                    root.insert("unchanged".into(), json!(true));
                    return Value::Object(root);
                }
                timeline_core::Changes::Resync => {
                    root.insert("resync".into(), json!(true));
                }
                timeline_core::Changes::Delta(scopes) => {
                    root.insert("scopes".into(), json!(scopes));
                }
            }
        }
        root.insert("project".into(), self.project_json());
        root.insert("transport".into(), self.transport_json());
        root.insert("stats".into(), self.engine_stats());
        // Cached input-device names for the record UI's device picker.
        root.insert("audioInputs".into(), json!(self.record.devices.clone()));
        root.insert(
            "audioInputDevices".into(),
            json!(self
                .record
                .device_info
                .iter()
                .map(|d| json!({
                    "name": d.name,
                    "inputChannels": d.input_channels,
                    "sampleRate": d.sample_rate,
                }))
                .collect::<Vec<_>>()),
        );
        root.insert("inputOpen".into(), json!(self.record.input_open()));
        root.insert("midi".into(), self.midi.snapshot_json());
        // What is SOUNDING versus what is KEEPABLE. The whole point of shipping
        // it in the snapshot is that the UI can show the difference without
        // guessing: `sounding` comes from the same buffer the audio came from.
        root.insert("performance".into(), self.performance_json());
        Value::Object(root)
    }

    fn project_json(&self) -> Value {
        // The model derives Serialize; expose it plus a couple of derived
        // conveniences agents ask for first (track/clip counts).
        let p = self.session.project();
        let mut v = serde_json::to_value(p).unwrap_or(Value::Null);
        if let Value::Object(map) = &mut v {
            map.insert("trackCount".into(), json!(p.tracks.len()));
            let clip_count: usize = p.tracks.iter().map(|t| t.clips.len()).sum();
            map.insert("clipCount".into(), json!(clip_count));

            // ---- which assets are actually LOADED, and where each came from -
            //
            // A `source_id` is a 64-hex content hash; the model holds no path,
            // deliberately. That is right for the journal and useless for a
            // person, who needs to read "Kick 01.wav" on a drum pad rather than
            // "9f3c…". This is the host's own `sources` map — the SAME map
            // `compile.rs` resolves a zone and a clip through — exposed as a
            // read surface so the UI can name a binding and, just as
            // importantly, show a MISSING one as missing instead of blank.
            // A read surface, not a command: no catalog change.
            map.insert(
                "loadedSources".into(),
                Value::Object(
                    self.sources
                        .iter()
                        .map(|(hash, buf)| {
                            (
                                hash.clone(),
                                json!({
                                    "path": buf.path.display().to_string(),
                                    "lenFrames": buf.len_frames(),
                                }),
                            )
                        })
                        .collect(),
                ),
            );

            // ---- E1: what a correct bar grid needs -------------------------
            //
            // These are NOT new model state; every one of them already existed
            // and was simply unreachable from the snapshot, which is why the
            // arrangement canvas has been drawing bar lines from naive
            // `bar * ticksPerBar` BPM math. P0-A measured generated audio
            // drifting 1.2-2.9% off its declared BPM, so for the app's primary
            // content path that grid cannot have been right.
            //
            // `phaseAnchorTicks`: the project's bar-grid origin, written by
            // `project.setPhaseAnchor` (catalog v2). A lead-in that is not
            // bar-aligned shifts every bar line, and nothing downstream can
            // reconstruct it.
            map.insert("phaseAnchorTicks".into(), json!(p.phase_anchor_ticks));
            // `tempoMap`: a LIST, always — even in v1 where it holds exactly
            // one segment. The shape is the contract, so a future tempo change
            // extends the data instead of breaking the reader. `bpm` is carried
            // BOTH as the exact rational the engine actually computes with and
            // as a float for display; position math must use the rational.
            map.insert(
                "tempoMap".into(),
                Value::Array(
                    p.tempo
                        .segments()
                        .iter()
                        .map(|seg| {
                            json!({
                                "startTicks": seg.start_tick,
                                "bpm": seg.bpm.as_f64(),
                                "bpmNum": seg.bpm.num,
                                "bpmDen": seg.bpm.den,
                            })
                        })
                        .collect::<Vec<_>>(),
                ),
            );
            // Confidence is the one honest signal that the neutral 120 BPM
            // fallback was used. It is persisted by the landing path in the
            // project extras and rides the existing JSON snapshot boundary.
            // Existing projects have no measurement record, so absence means
            // unknown rather than failed detection.
            let tempo_confidence = self
                .session
                .journal()
                .iter()
                .rev()
                .find(|entry| entry.name == "gen.landed")
                .and_then(|entry| entry.params.get("tempoConfidence"))
                .and_then(Value::as_f64)
                .or_else(|| {
                    p.extra
                        .get("tempoConfidence")
                        .and_then(Value::as_f64)
                });
            if let Some(confidence) = tempo_confidence {
                map.insert("tempoConfidence".into(), json!(confidence));
            }
            map.insert("ppq".into(), json!(timeline_core::PPQ));
            map.insert(
                "timeSignature".into(),
                json!({
                    "numerator": p.time_sig.numerator,
                    "denominator": p.time_sig.denominator,
                }),
            );
            // Toolbar affordances: a disabled undo button beats one that does
            // nothing.
            map.insert("undoDepth".into(), json!(self.session.undo_depth()));
            map.insert("redoDepth".into(), json!(self.session.redo_depth()));

            // Build a map from asset hash to the request_id of the first take
            // that produced it. This lets the take-lane builder find which
            // request_id "owns" a clip (the clip's source_id matches a take's
            // asset hash when the take was the first pass of a comp session).
            let mut request_for_hash: HashMap<&str, &str> = HashMap::new();
            for take in &p.takes {
                for hash in take.asset_hashes.values() {
                    request_for_hash.entry(hash.as_str()).or_insert(&take.request_id);
                }
            }

            // Per-clip provenance for the read model. The UI used to GUESS this
            // (the export dialog counted every non-generative clip as
            // "imported", the inspector inferred origin from `kind == midi`),
            // and a guess that disagrees with the exported manifest is its own
            // defect. This is the manifest's OWN classifier, so the preview and
            // the artifact cannot drift. Built in one journal pass for the whole
            // project, not one per clip: this is a 30 Hz path.
            let origins = crate::export::clip_origins(p, self.session.journal());

            // Per-TRACK provenance, on the same principle and from the same
            // chain. Three gestures create a track the user did not ask for by
            // name — playing a key on a project with no instrument, asking for
            // a layer, and importing a folder of stems — and the app said
            // NOTHING about any of them. Rows appeared in the arrangement out
            // of nowhere. This hands the UI the journal's own answer to "where
            // did that come from", so the sentence it shows cannot drift from
            // the fact: there is no flag to forget to set, and undoing the
            // creation removes the track and its entry together.
            let auto_created = self.track_origins();

            // Inject take-lane data per track so the inline take-lane under
            // each comp clip renders on the real engine (was nil at I1).
            if let Value::Array(tracks) = &mut map["tracks"] {
                for (track_val, track) in tracks.iter_mut().zip(p.tracks.iter()) {
                    if let Value::Object(track_map) = track_val {
                        // OMITTED, not "user", for a track someone made
                        // themselves: absence is the honest shape for "nothing
                        // remarkable happened here", it is what every pre-this
                        // project decodes as, and it means the UI cannot show
                        // the note on a track it has no evidence about.
                        if let Some(origin) = auto_created.get(track.id.as_str()) {
                            track_map.insert("origin".into(), json!(origin));
                        }
                        if let Some(Value::Array(clip_vals)) = track_map.get_mut("clips") {
                            for (clip_val, clip) in clip_vals.iter_mut().zip(track.clips.iter()) {
                                if let (Value::Object(cm), Some(origin)) =
                                    (clip_val, origins.get(&clip.id))
                                {
                                    cm.insert("origin".into(), json!(origin.as_str()));
                                }
                            }
                        }
                        let mut take_lanes: Vec<Value> = Vec::new();
                        for clip in &track.clips {
                            let clip_rid = request_for_hash.get(clip.source_id.as_str()).copied();
                            let mut clip_takes: Vec<&TakeRecord> = p.takes.iter()
                                .filter(|t| {
                                    t.promoted_into.as_deref() == Some(&clip.id)
                                    || clip_rid.map(|rid| rid == t.request_id.as_str()).unwrap_or(false)
                                })
                                .collect();
                            if !clip_takes.is_empty() {
                                // Sort by ULID order (creation time).
                                clip_takes.sort_by(|a, b| a.take_id.cmp(&b.take_id));
                                let has_promoted = clip_takes.iter().any(|t| t.status == TakeStatus::Promoted);
                                let take_entries: Vec<Value> = clip_takes.iter().enumerate().map(|(i, t)| {
                                    let kind = take_kind(&t.source_command);
                                    let last = i == clip_takes.len() - 1;
                                    let picked = if has_promoted {
                                        t.status == TakeStatus::Promoted
                                    } else {
                                        last
                                    };
                                    // FNV-1a seed from the first asset hash (same
                                    // algorithm as Swift seedFor in RealStudioEngine).
                                    let seed = fnv1a_seed(
                                        t.asset_hashes.values().next()
                                            .map(|s| s.as_bytes())
                                            .unwrap_or(t.take_id.as_bytes())
                                    );
                                    json!({
                                        "takeId": t.take_id,
                                        "kind": kind,
                                        "seed": seed,
                                        "picked": picked,
                                    })
                                }).collect();
                                take_lanes.push(json!({
                                    "clipId": clip.id,
                                    "regionStartTicks": clip.start_ticks,
                                    "regionLengthTicks": clip.length_ticks,
                                    "takes": take_entries,
                                }));
                            }
                        }
                        track_map.insert("takeLanes".into(), json!(take_lanes));
                    }
                }
            }
        }
        v
    }

    fn transport_json(&self) -> Value {
        // Live: the play head + play flag come from the render thread's atomics
        // (frames -> ticks), so the UI reads the real engine clock. Offline:
        // the tracked view (position only moves on an explicit seek).
        let (playing, position_ticks) = match self.live.as_ref() {
            Some(live) => {
                let rate = self.session.project().sample_rate;
                let tempo = self.session.project().tempo.clone();
                (live.playing(), tempo.frame_to_tick(live.position_frame(), rate))
            }
            None => (self.transport.playing, self.transport.position_ticks),
        };
        json!({
            "playing": playing,
            "positionTicks": position_ticks,
            "loop": self.transport.loop_region.map(|(s, e)| json!({ "startTicks": s, "endTicks": e })),
            "metronomeEnabled": self.transport.metronome,
            "live": self.live.is_some(),
            "recording": self.record.is_recording(),
            "recordingTrackId": self.record.track_id.clone(),
            "inputOpen": self.record.input_open(),
            "inputListening": self.record.listen.is_some(),
        })
    }

    /// Engine health. Live: the render thread's real callback timing, fault,
    /// and device telemetry. Offline: a clean, honest baseline (no device = no
    /// callbacks, no underruns).
    pub fn engine_stats(&self) -> Value {
        let Some(live) = self.live.as_ref() else {
            return json!({
                "underruns": 0,
                "callbackP95Ms": 0.0,
                // No device means no monitor path, so no click could have
                // sounded and no frame could have reached one. Reported as a
                // real zero (not omitted) so a reader never has to decide
                // whether an absent field means "none" or "unknown".
                "metronomeClicks": 0,
                "deviceFramesAudible": 0,
                "live": false,
                "sourceCount": self.sources.len(),
                "seq": self.session.seq(),
            });
        };
        let info = live.stream_info();
        let mut v = engine_stats_json(&live.stats_snapshot());
        let obj = v.as_object_mut().expect("engine_stats_json returns an object");
        obj.insert("deviceName".into(), json!(info.device_name));
        obj.insert("audible".into(), json!(info.audible));
        obj.insert("sourceCount".into(), json!(self.sources.len()));
        obj.insert("seq".into(), json!(self.session.seq()));
        v
    }

    /// Per-track live meters, plus per-routing-node (bus/group) meters under
    /// `nodes`, keyed by node id in `routing.nodes` order. Live: real post-EQ
    /// peaks + block RMS read (and reset) from the render thread's atomics, in
    /// dBFS. Offline: no device, so an honest silence floor (-120 dB).
    pub fn meters(&self) -> Value {
        const FLOOR_DB: f64 = -120.0;
        let to_db = |lin: f32| -> f64 {
            if lin > 0.0 {
                (20.0 * lin.log10() as f64).max(FLOOR_DB)
            } else {
                FLOOR_DB
            }
        };
        // Live INPUT meter: peak/RMS/clip from the input ring's callback atomics.
        // Present while capturing OR opt-in listen is open.
        let input_src = self
            .record
            .input
            .as_ref()
            .or(self.record.listen.as_ref());
        let input_json = input_src.map(|inp| {
            let m = inp.meter();
            let channels: Vec<Value> = m
                .channels
                .iter()
                .map(|c| {
                    json!({
                        "channel": c.channel,
                        "peakDb": to_db(c.peak),
                        "rmsDb": to_db(c.rms),
                        "clipLatched": c.clip_latched,
                    })
                })
                .collect();
            json!({
                "peakDb": to_db(m.peak),
                "rmsDb": to_db(m.rms),
                "clipLatched": m.clip_latched,
                "capturedFrames": m.frames,
                "dropped": m.dropped,
                "sampleRate": inp.sample_rate(),
                "channelCount": inp.channel_count(),
                "deviceName": inp.device_name(),
                "channels": channels,
                "inputOpen": true,
            })
        });
        let tracks_model = &self.session.project().tracks;
        // E5 §8: routing-node (bus/group) meters, keyed by node id. Meter-bank
        // slot `i` IS `routing.nodes[i]` — compile bakes `NodeStepKind::Node(i)`
        // from `routing.node_index(id)` and the walk meters into that same
        // index — so zipping model order against bank order is the identity the
        // render side already guarantees. The two legacy return slots
        // (`LEGACY_FX_A/B_METER`) are deliberately NOT exposed here: they are
        // not addressable nodes and no surface draws them.
        let route_nodes = &self.session.project().routing.nodes;
        let Some(live) = self.live.as_ref() else {
            let tracks: Vec<Value> = tracks_model
                .iter()
                .map(|t| json!({ "trackId": t.id, "peakDb": FLOOR_DB, "rmsDb": FLOOR_DB }))
                .collect();
            let nodes: Vec<Value> = route_nodes
                .iter()
                .map(|n| json!({ "nodeId": n.id, "peakDb": FLOOR_DB, "rmsDb": FLOOR_DB }))
                .collect();
            return json!({
                "live": false,
                "tracks": tracks,
                "nodes": nodes,
                "master": { "peakDb": FLOOR_DB, "rmsDb": FLOOR_DB },
                "input": input_json,
            });
        };
        let snap = live.meters_snapshot(tracks_model.len());
        let tracks: Vec<Value> = tracks_model
            .iter()
            .enumerate()
            .map(|(i, t)| {
                let (peak, rms) = snap
                    .tracks
                    .get(i)
                    .map(|m| (m.peak_l.max(m.peak_r), m.block_rms))
                    .unwrap_or((0.0, 0.0));
                json!({ "trackId": t.id, "peakDb": to_db(peak), "rmsDb": to_db(rms) })
            })
            .collect();
        let node_meters = live.node_meters(route_nodes.len());
        let nodes: Vec<Value> = route_nodes
            .iter()
            .enumerate()
            .map(|(i, n)| {
                let (peak, rms) = node_meters
                    .get(i)
                    .map(|&(l, r, m)| (l.max(r), m))
                    .unwrap_or((0.0, 0.0));
                json!({ "nodeId": n.id, "peakDb": to_db(peak), "rmsDb": to_db(rms) })
            })
            .collect();
        json!({
            "live": true,
            "tracks": tracks,
            "nodes": nodes,
            "master": {
                "peakDb": to_db(snap.master_peak_l.max(snap.master_peak_r)),
                "rmsDb": to_db(snap.master_block_rms),
                "truePeakDb": to_db(snap.master_true_peak),
                "lufsIntegrated": if snap.lufs_integrated.is_finite() { json!(snap.lufs_integrated) } else { Value::Null },
                "lufsShortTerm": if snap.lufs_short_term.is_finite() { json!(snap.lufs_short_term) } else { Value::Null },
                // Positive dB of gain reduction the limiter applied this block (0 = transparent).
                "gainReductionDb": snap.limiter_gr_db,
                // Stereo correlation [-1, 1]; null when the master is silent this block.
                "correlation": if snap.master_correlation.is_finite() { json!(snap.master_correlation) } else { Value::Null },
            },
            "input": input_json,
        })
    }

    /// A page of journal entries after `after_id` (exclusive), capped.
    pub fn journal_page(&self, after_id: Option<&str>, limit: usize) -> Value {
        let limit = limit.clamp(1, 500);
        let journal = self.session.journal();
        let start = match after_id {
            Some(id) => journal
                .iter()
                .position(|e| e.id == id)
                .map(|i| i + 1)
                .unwrap_or(0),
            None => 0,
        };
        let slice: Vec<Value> = journal
            .iter()
            .skip(start)
            .take(limit)
            .map(|e| {
                json!({
                    "id": e.id,
                    "ts": e.ts,
                    "actor": { "kind": actor_kind_str(&e.actor), "name": e.actor.name },
                    "name": e.name,
                    "params": e.params,
                    "hash": e.hash,
                })
            })
            .collect();
        let next = journal.get(start + slice.len()).map(|e| e.id.clone());
        json!({
            "entries": slice,
            "nextAfterId": next,
            "total": journal.len(),
        })
    }

    /// The Takes browser read (`takes.list`): every generative take in the
    /// project, each enriched with its classification + joined lineage
    /// (prompt/seed/model/engine, the region it revised) so the browser and any
    /// agent read the same rich record. Optional filters (all additive):
    ///   `clipId`         only takes promoted into this clip
    ///   `requestId`      only takes from this gen request
    ///   `kind`           only takes of this kind (revise/extend/layer/landing/...)
    ///   `auditionableOnly` only alternatives you can audition (drops landing
    ///                     provenance + finalize intermediates + offline takes)
    ///   `includePurged`  keep offline (purged/missing-asset) takes (default true)
    ///
    /// L8 FOLLOW-UP (recorded): a landed song's `gen.landed` (sourceCommand
    /// `gen.song`) is a PROVENANCE anchor for the whole placed song, not an
    /// alternative take. It is classified `kind: "landing"`, `provenance: true`,
    /// `auditionable: false`, so the browser filters it out of the auditionable
    /// list while it stays queryable as lineage (and via `lineage.get`).
    pub fn takes(&self, args: &Value) -> Value {
        let clip_id = args.get("clipId").and_then(Value::as_str);
        let request_id = args.get("requestId").and_then(Value::as_str);
        let kind_filter = args.get("kind").and_then(Value::as_str);
        let auditionable_only = args.get("auditionableOnly").and_then(Value::as_bool).unwrap_or(false);
        let include_purged = args.get("includePurged").and_then(Value::as_bool).unwrap_or(true);

        let mut takes: Vec<Value> = Vec::new();
        for t in &self.session.project().takes {
            if let Some(c) = clip_id {
                if t.promoted_into.as_deref() != Some(c) {
                    continue;
                }
            }
            if let Some(r) = request_id {
                if t.request_id != r {
                    continue;
                }
            }
            let kind = take_kind(&t.source_command);
            if let Some(k) = kind_filter {
                if kind != k {
                    continue;
                }
            }
            // Offline = no resolvable audio at all (purged or missing). A
            // multi-asset landing take stays online while any stem resolves
            // (its whole-song "mix" blob is never decoded into sources).
            let offline = !t.asset_hashes.is_empty()
                && t.asset_hashes.values().all(|h| !self.sources.contains_key(h));
            let status = format!("{:?}", t.status).to_lowercase();
            // Auditionable = a live candidate ALTERNATIVE with resolvable audio.
            // Landing (whole-song anchor) and finalize (re-render intermediate)
            // are provenance/plumbing, not alternatives.
            let auditionable = status == "candidate"
                && !offline
                && matches!(kind, "revise" | "extend" | "layer" | "retake" | "record");
            if auditionable_only && !auditionable {
                continue;
            }
            if !include_purged && offline {
                continue;
            }
            takes.push(self.take_record_json(t, kind, offline, auditionable));
        }
        json!({ "takes": takes })
    }

    /// One enriched take record: the stored fields + classification + the
    /// lineage joined from the gen request that produced it.
    fn take_record_json(
        &self,
        t: &timeline_core::model::TakeRecord,
        kind: &str,
        offline: bool,
        auditionable: bool,
    ) -> Value {
        let stem = t
            .asset_hashes
            .keys()
            .next()
            .cloned()
            .unwrap_or_else(|| "mix".to_string());
        // Lineage: prompt (from the gen request) + seed/model/steps/device (from
        // engine identity) + the region a revise touched. The gen.landed entry
        // that recorded this take gives its creation order + timestamp.
        let req = self.gen_request_params(&t.request_id);
        let prompt = req.as_ref().and_then(|r| {
            r.get("request")
                .and_then(|rq| {
                    rq.get("instruction")
                        .or_else(|| rq.get("caption"))
                        .and_then(Value::as_str)
                })
                .or_else(|| r.get("instruction").and_then(Value::as_str))
                .map(str::to_string)
        });
        let region = req.as_ref().and_then(|r| {
            match (
                r.get("regionStartTicks").and_then(Value::as_u64),
                r.get("regionEndTicks").and_then(Value::as_u64),
            ) {
                (Some(s), Some(e)) => Some((s, e)),
                _ => None,
            }
        });
        let ei = &t.engine_identity;
        let (created_seq, created_ts) = self
            .session
            .journal()
            .iter()
            .enumerate()
            .find(|(_, e)| {
                e.name == "gen.landed"
                    && e.params.get("takeId").and_then(Value::as_str) == Some(t.take_id.as_str())
            })
            .map(|(i, e)| (Some(i as u64), Some(e.ts.clone())))
            .unwrap_or((None, None));

        let mut lineage = Map::new();
        if let Some(p) = &prompt {
            lineage.insert("prompt".into(), json!(p));
        }
        for k in ["model", "seed", "steps", "device"] {
            if let Some(v) = ei.get(k) {
                lineage.insert(k.into(), v.clone());
            }
        }
        lineage.insert("sourceCommand".into(), json!(t.source_command));
        if let Some((s, e)) = region {
            lineage.insert("regionStartTicks".into(), json!(s));
            lineage.insert("regionEndTicks".into(), json!(e));
        }

        json!({
            "takeId": t.take_id,
            "requestId": t.request_id,
            "sourceCommand": t.source_command,
            "kind": kind,
            "stem": stem,
            "status": format!("{:?}", t.status).to_lowercase(),
            "promotedInto": t.promoted_into,
            "assetHashes": t.asset_hashes,
            "engineIdentity": t.engine_identity,
            // Classification the browser filters on (L8 follow-up).
            "auditionable": auditionable,
            "provenance": kind == "landing",
            "offline": offline,
            "createdSeq": created_seq,
            "createdTs": created_ts,
            "lineage": Value::Object(lineage),
        })
    }

    /// Purge take audio to reclaim disk (design 3.2 / MSTUDIO-FORMAT `takes/`).
    /// A host-io operation, NOT a journaled catalog mutation: it deletes the
    /// on-disk + decoded audio of purgeable CANDIDATE takes, so their space is
    /// reclaimed, while the take RECORD (lineage) stays queryable. A purged take
    /// reads back `offline: true`, exactly like any missing asset. Never touches
    /// audio a placed clip, a promoted take's un-splice, or a landing anchor
    /// still relies on. Requires `confirm: true` (destructive).
    ///
    /// Args: `confirm` (required true), optional `takeId` or `requestId` to
    /// scope; default purges every purgeable candidate.
    pub fn purge_takes(&mut self, args: &Value) -> Result<Value, StudioError> {
        if !args.get("confirm").and_then(Value::as_bool).unwrap_or(false) {
            return Err(StudioError::invalid(
                "purge_takes requires confirm: true (it deletes take audio to reclaim space)",
            ));
        }
        let only_take = args.get("takeId").and_then(Value::as_str);
        let only_request = args.get("requestId").and_then(Value::as_str);

        // Assets that must never be deleted: every placed clip's audio, and
        // every promoted take's pre-splice original (needed to un-splice on
        // discard/undo). Landing stems are placed clips, so they are covered.
        let mut protected: std::collections::HashSet<String> = std::collections::HashSet::new();
        for track in &self.session.project().tracks {
            for clip in &track.clips {
                protected.insert(clip.source_id.clone());
            }
        }
        for t in &self.session.project().takes {
            if t.status == timeline_core::model::TakeStatus::Promoted {
                if let Some(prior) = &t.prior_asset {
                    protected.insert(prior.clone());
                }
                for h in t.asset_hashes.values() {
                    protected.insert(h.clone());
                }
            }
        }

        // The takes we purge: candidates in scope (never landing anchors, whose
        // assets are placed clips anyway; the protection above already guards
        // them, and they are not `Candidate` status once the song is placed).
        let purge_ids: Vec<String> = self
            .session
            .project()
            .takes
            .iter()
            .filter(|t| t.status == timeline_core::model::TakeStatus::Candidate)
            .filter(|t| take_kind(&t.source_command) != "landing")
            .filter(|t| only_take.is_none_or(|id| t.take_id == id))
            .filter(|t| only_request.is_none_or(|r| t.request_id == r))
            .map(|t| t.take_id.clone())
            .collect();

        // Assets still referenced by a take we are KEEPING stay protected.
        let purge_set: std::collections::HashSet<&String> = purge_ids.iter().collect();
        for t in &self.session.project().takes {
            if !purge_set.contains(&t.take_id) {
                for h in t.asset_hashes.values() {
                    protected.insert(h.clone());
                }
            }
        }

        // Delete each purgeable asset once.
        let mut deletable: std::collections::HashSet<String> = std::collections::HashSet::new();
        for t in &self.session.project().takes {
            if purge_set.contains(&t.take_id) {
                for h in t.asset_hashes.values() {
                    if !protected.contains(h) {
                        deletable.insert(h.clone());
                    }
                }
            }
        }

        let mut bytes_reclaimed: u64 = 0;
        let mut assets_deleted: Vec<String> = Vec::new();
        for hash in &deletable {
            if let Some(pkg) = &self.package_dir {
                let path = pkg.join("audio").join(format!("{hash}.wav"));
                if let Ok(meta) = std::fs::metadata(&path) {
                    bytes_reclaimed += meta.len();
                }
                let _ = std::fs::remove_file(&path);
            }
            self.sources.remove(hash);
            assets_deleted.push(hash.clone());
        }
        assets_deleted.sort();

        Ok(json!({
            "ok": true,
            "purgedTakeIds": purge_ids,
            "assetsDeleted": assets_deleted.len(),
            "bytesReclaimed": bytes_reclaimed,
            "note": "take audio reclaimed; the take records stay queryable as lineage and read back offline",
        }))
    }

    /// The provenance chain for a clip: journal entries that reference it
    /// (place / move / trim / gen.landed of a take promoted into it, etc.).
    pub fn lineage(&self, clip_id: &str) -> Result<Value, StudioError> {
        let Some((ti, ci)) = self.session.project().find_clip(clip_id) else {
            return Err(StudioError::Command {
                code: "unknown_clip".into(),
                message: format!("unknown clip: {clip_id}"),
            });
        };
        // The clip's current content-addressed asset (its `source_id`). Landing
        // (L8) and any per-stem generative flow records provenance as a take
        // whose `asset_hashes` carry this stem's hash, without ever promoting a
        // "mix" over the clip; matching by asset hash links that generation
        // record to the clip (additive: it only ever ADDS entries to the chain).
        let clip_asset = self.session.project().tracks[ti].clips[ci].source_id.clone();
        // Takes promoted into this clip, and their request ids.
        let mut take_ids = std::collections::HashSet::new();
        let mut request_ids = std::collections::HashSet::new();
        for t in &self.session.project().takes {
            if t.promoted_into.as_deref() == Some(clip_id)
                || t.asset_hashes.values().any(|h| *h == clip_asset)
            {
                take_ids.insert(t.take_id.clone());
                request_ids.insert(t.request_id.clone());
            }
        }
        let chain: Vec<Value> = self
            .session
            .journal()
            .iter()
            .filter(|e| entry_touches_clip(e, clip_id, &take_ids, &request_ids))
            .map(|e| {
                json!({
                    "id": e.id,
                    "ts": e.ts,
                    "name": e.name,
                    "actor": actor_kind_str(&e.actor),
                    "params": e.params,
                })
            })
            .collect();
        Ok(json!({ "clipId": clip_id, "chain": chain }))
    }

    /// Capped peak-tile array for a clip's window at a zoom bucket. Never raw
    /// audio; at most `WAVEFORM_MAX_BINS` bins.
    pub fn waveform(&self, clip_id: &str, zoom: u32, start_bin: u64, max_bins: usize) -> Result<Value, StudioError> {
        let project = self.session.project();
        let (ti, ci) = project.find_clip(clip_id).ok_or_else(|| StudioError::Command {
            code: "unknown_clip".into(),
            message: format!("unknown clip: {clip_id}"),
        })?;
        let clip = &project.tracks[ti].clips[ci];
        let Some(audio) = self.sources.get(&clip.source_id) else {
            return Ok(json!({ "clipId": clip_id, "offline": true, "peaks": [] }));
        };
        // Samples per bin doubles per zoom bucket from a 256-sample base.
        let spp = (256usize << zoom.min(16)).max(1);
        let cap = max_bins.clamp(1, WAVEFORM_MAX_BINS);
        let win_start = clip.offset_frames as usize;
        let win_end = (clip.offset_frames + clip.len_frames).min(audio.len_frames()) as usize;
        let samples = &audio.samples[win_start.min(audio.samples.len())..win_end.min(audio.samples.len())];
        let total_bins = samples.len().div_ceil(spp);
        let begin = (start_bin as usize).min(total_bins);
        let mut peaks = Vec::new();
        for bin in begin..total_bins {
            if peaks.len() >= cap {
                break;
            }
            let s = bin * spp;
            let e = (s + spp).min(samples.len());
            let mut peak = 0.0f32;
            for frame in &samples[s..e] {
                peak = peak.max(frame[0].abs()).max(frame[1].abs());
            }
            peaks.push(peak);
        }
        Ok(json!({
            "clipId": clip_id,
            "zoom": zoom,
            "samplesPerBin": spp,
            "startBin": begin,
            "totalBins": total_bins,
            "peaks": peaks,
        }))
    }

    /// The full machine-readable provenance / AI-disclosure manifest, built from
    /// the command journal + clip lineage + the hash-chain head (L13). This is
    /// the differentiator: generated/imported/recorded split, per-clip lineage,
    /// engine identities, and the EU AI Act Art. 50 disclosure fields.
    pub fn manifest_value(&self) -> Value {
        crate::export::build_manifest(
            self.session.project(),
            self.session.journal(),
            self.session.tip_hash(),
            self.session.seq(),
        )
    }

    /// A compact provenance summary (the split + a one-line human summary), for
    /// export result JSON and the empty-project inspector line.
    pub fn provenance_brief(&self) -> Value {
        let comp = crate::export::composition(self.session.project(), self.session.journal());
        json!({
            "summary": comp.summary_line(),
            "clipCount": comp.clip_count,
            "generatedClips": comp.generated_clips,
            "importedClips": comp.imported_clips,
            "recordedClips": comp.recorded_clips,
            "authoredClips": comp.authored_clips,
            "generatedFraction": (comp.generated_fraction() * 10_000.0).round() / 10_000.0,
        })
    }

    // -----------------------------------------------------------------------
    // Export deliverable helpers (offline bounce -> normalize -> write).
    // -----------------------------------------------------------------------

    /// Render a tick region [start, end) of the master mix to samples (no file).
    fn render_region_samples(&self, start_ticks: u64, end_ticks: u64) -> Result<Vec<[f32; 2]>, StudioError> {
        let project = self.session.project();
        let rate = project.sample_rate;
        let start_f = project.tempo.tick_to_frame(start_ticks, rate) as usize;
        let end_f = project.tempo.tick_to_frame(end_ticks, rate) as usize;
        let full = self.render_to(end_f as u64)?;
        Ok(full.get(start_f..end_f.min(full.len())).unwrap_or(&[]).to_vec())
    }

    /// Write the deliverable (24-bit WAV or AudioToolbox AAC) and report it.
    fn write_deliverable(
        &self,
        out: &Path,
        audio: &[[f32; 2]],
        format: DeliverableFormat,
    ) -> Result<BounceReport, StudioError> {
        let rate = self.session.project().sample_rate;
        match format {
            DeliverableFormat::Wav => write_wav_i24(out, audio, rate).map_err(StudioError::audio)?,
            DeliverableFormat::Aac => encode_aac_m4a(out, audio, rate).map_err(|e| {
                // On non-macOS the encoder is unavailable; surface it as typed.
                if e.contains("requires macOS") {
                    StudioError::Unsupported(e)
                } else {
                    StudioError::Audio(e)
                }
            })?,
        }
        let peak = audio
            .iter()
            .flat_map(|f| [f[0].abs(), f[1].abs()])
            .fold(0.0_f32, f32::max);
        Ok(BounceReport {
            output_path: out.to_path_buf(),
            frames: audio.len() as u64,
            seconds: audio.len() as f64 / f64::from(rate),
            peak,
            sample_rate: rate,
        })
    }

    /// Assemble the export result JSON (report + format + loudness landing).
    fn export_result(
        &self,
        report: &BounceReport,
        format: DeliverableFormat,
        norm: Option<&NormalizeReport>,
        manifest_path: Option<String>,
    ) -> Value {
        let mut v = report.to_json();
        if let Value::Object(m) = &mut v {
            m.insert("format".into(), json!(format.wire()));
            if format == DeliverableFormat::Wav {
                m.insert("bitDepth".into(), json!(24));
            }
            if let Some(n) = norm {
                m.insert("loudness".into(), loudness_json(n));
            }
            m.insert("manifestPath".into(), manifest_path.map_or(Value::Null, Value::String));
            m.insert("provenance".into(), self.provenance_brief());
        }
        v
    }

    /// When `includeManifest` is set, write the provenance manifest next to the
    /// audio deliverable (`<out>.manifest.json`) and return its path.
    fn maybe_write_manifest(&self, params: &Value, out: &Path) -> Result<Option<String>, StudioError> {
        if !params.get("includeManifest").and_then(Value::as_bool).unwrap_or(false) {
            return Ok(None);
        }
        let manifest = self.manifest_value();
        let text = serde_json::to_string_pretty(&manifest).map_err(StudioError::io)?;
        let path = manifest_sidecar_path(out);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(StudioError::io)?;
        }
        std::fs::write(&path, text).map_err(StudioError::io)?;
        Ok(Some(path.display().to_string()))
    }

    /// Reject a sampleRateHz that differs from the project rate (v1 exports at
    /// the project rate, per 01-DESIGN 3.8; an SRC export lands with the AAC/IO
    /// pass later). A matching or absent value is fine.
    fn reject_rate_override(&self, params: &Value) -> Result<(), StudioError> {
        if let Some(req) = params.get("sampleRateHz").and_then(Value::as_u64) {
            let rate = u64::from(self.session.project().sample_rate);
            if req != rate {
                return Err(StudioError::Unsupported(format!(
                    "v1 exports at the project rate ({rate} Hz); asked for {req} Hz"
                )));
            }
        }
        Ok(())
    }

    /// Direct read access (tests / FFI adapters).
    pub fn project(&self) -> &Project {
        self.session.project()
    }

    /// Attach measured landing metadata to the checkpoint without widening a
    /// journal command's closed schema. The snapshot exposes it as its one
    /// additive `tempoConfidence` field.
    pub fn set_tempo_confidence(&mut self, confidence: f64) {
        self.session
            .project_mut()
            .extra
            .insert("tempoConfidence".into(), json!(confidence));
    }

    pub fn sources(&self) -> &HashMap<String, Arc<AudioBuf>> {
        &self.sources
    }

    // -----------------------------------------------------------------------
    // L9 revise/take support (additive engine exports).
    //
    // A generative take carries a SPLICED, full-length asset (the original clip
    // audio with the revised region substituted and equal-power crossfaded in,
    // per P0-A: raw repaint output must never be presented outside the region).
    // That asset is produced in memory by the revise orchestrator, is NOT placed
    // as a clip until `take.promote`, and must be resolvable by the render graph
    // and by a package reopen. `ingest_asset` registers one; `gen_request_params`
    // lets the finalize re-render reconstruct a region from journaled provenance.
    // -----------------------------------------------------------------------

    /// Ingest an in-memory stereo/48k PCM buffer as a content-addressed asset:
    /// key it by a stable blake3 hash of its samples, decode-cache it into
    /// `sources` (so compile/render/promote resolve it), and persist it to
    /// `audio/<hash>.wav` when a package is open (so a reopen finds it). Returns
    /// the asset hash. No clip is placed; a later `take.promote` / `clip.place`
    /// references the hash.
    pub fn ingest_asset(&mut self, samples: &[[f32; 2]]) -> Result<String, StudioError> {
        if samples.is_empty() {
            return Err(StudioError::audio("cannot ingest a zero-length asset"));
        }
        // Content address over the raw little-endian f32 samples: deterministic,
        // 64 hex chars (the audio/ filename-stem contract), and independent of
        // any WAV container quirk.
        let mut bytes = Vec::with_capacity(samples.len() * 8);
        for f in samples {
            bytes.extend_from_slice(&f[0].to_le_bytes());
            bytes.extend_from_slice(&f[1].to_le_bytes());
        }
        let hash = blake3::hash(&bytes).to_hex().to_string();
        let rate = self.session.project().sample_rate;
        if let Some(pkg) = &self.package_dir {
            let audio_dir = pkg.join("audio");
            std::fs::create_dir_all(&audio_dir).map_err(StudioError::io)?;
            let dest = audio_dir.join(format!("{hash}.wav"));
            if !dest.exists() {
                write_wav_f32(&dest, samples, rate).map_err(StudioError::audio)?;
            }
        }
        self.sources
            .insert(hash.clone(), AudioBuf::from_samples(samples.to_vec(), &hash));
        Ok(hash)
    }

    /// The decoded samples of an asset by hash (the revise splicer reads the
    /// clip's current, or a take's prior, audio to splice into).
    pub fn asset_samples(&self, hash: &str) -> Option<Arc<AudioBuf>> {
        self.sources.get(hash).cloned()
    }

    /// The params object of the journaled gen.* request with this requestId
    /// (the finalize re-render reconstructs region + clip + scope from here, so
    /// it needs only a draft take id, not the whole original request re-passed).
    pub fn gen_request_params(&self, request_id: &str) -> Option<Value> {
        self.session
            .journal()
            .iter()
            .find(|e| {
                e.name.starts_with("gen.")
                    && e.params.get("requestId").and_then(Value::as_str) == Some(request_id)
            })
            .map(|e| e.params.clone())
    }
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn placement_start_ticks(
    _tempo: &TempoMap,
    phase_anchor_ticks: u64,
    start_ticks: u64,
    rolling: bool,
    bar: u64,
) -> u64 {
    if rolling || bar == 0 { return start_ticks; }
    let delta = start_ticks as i128 - phase_anchor_ticks as i128;
    let n = (delta as f64 / bar as f64).round() as i128;
    (phase_anchor_ticks as i128 + n * bar as i128).max(0) as u64
}

fn ignored_record_params(ignored_start: bool, ignored_punch: bool) -> Value {
    let mut ignored = Vec::new();
    if ignored_start { ignored.push("startTicks"); }
    if ignored_punch { ignored.push("punchOutTicks"); }
    json!(ignored)
}

fn ignored_record_note(ignored_start: bool, ignored_punch: bool) -> Value {
    if ignored_start && ignored_punch { json!("startTicks and punchOutTicks were ignored because the punch region is behind the rolling playhead") }
    else if ignored_start { json!("startTicks is ignored while the transport is rolling") }
    else if ignored_punch { json!("punchOutTicks was ignored because the punch region is behind the capture origin") }
    else { Value::Null }
}

fn apply_record_placement(
    tempo: &TempoMap,
    _phase_anchor_ticks: u64,
    start_ticks: u64,
    capture_origin_ticks: u64,
    rolling: bool,
    punch_out_ticks: Option<u64>,
    rate: u32,
    frames: &mut Vec<[f32; 2]>,
) {
    if rolling {
        if let Some(punch_out_ticks) = punch_out_ticks {
            if capture_origin_ticks < start_ticks {
                let drop = tempo.tick_to_frame(start_ticks - capture_origin_ticks, rate) as usize;
                if drop >= frames.len() { frames.clear(); } else { frames.drain(..drop); }
            } else if capture_origin_ticks > start_ticks {
                let pad = tempo.tick_to_frame(capture_origin_ticks - start_ticks, rate) as usize;
                let mut padded = vec![[0.0, 0.0]; pad];
                padded.append(frames);
                *frames = padded;
            }
            let max_frames = (rate as usize).saturating_mul(60 * 30);
            let target = (tempo.tick_to_frame(punch_out_ticks.saturating_sub(start_ticks), rate) as usize)
                .min(max_frames);
            frames.resize(target, [0.0, 0.0]);
        }
        return;
    }
    let Some(punch_out_ticks) = punch_out_ticks else { return };
    let max_frames = (rate as usize).saturating_mul(60 * 30);
    let target = (tempo.tick_to_frame(punch_out_ticks.saturating_sub(start_ticks), rate) as usize)
        .min(max_frames);
    if target > 0 { frames.resize(target, [0.0, 0.0]); }
}

fn prepare_recording_media(
    package_dir: Option<&Path>,
    frames: Vec<[f32; 2]>,
    rate: u32,
) -> Result<PreparedRecording, StudioError> {
    if frames.is_empty() { return Err(StudioError::audio("recording contains no frames")); }
    let tmp = std::env::temp_dir().join(format!("majiks-record-{}.wav", ulid::new_ulid()));
    let result = (|| {
        render::media::write_wav_f32(&tmp, &frames, rate).map_err(StudioError::audio)?;
        let bytes = std::fs::read(&tmp).map_err(StudioError::io)?;
        let hash = blake3::hash(&bytes).to_hex().to_string();
        let loudness_lufs = media::loudness::measure_loudness(&frames, rate)
            .ok().map(|analysis| analysis.integrated_lufs);
        if let Some(pkg) = package_dir {
            let audio = pkg.join("audio");
            std::fs::create_dir_all(&audio).map_err(StudioError::io)?;
            let dest = audio.join(format!("{hash}.wav"));
            if !dest.exists() { std::fs::copy(&tmp, dest).map_err(StudioError::io)?; }
        }
        let tiles_ready = generate_tiles_at(package_dir, &hash, &frames)?;
        Ok(PreparedRecording { frames, hash, tiles_ready, loudness_lufs })
    })();
    let _ = std::fs::remove_file(&tmp);
    result
}

fn generate_tiles_at(
    package_dir: Option<&Path>,
    hash: &str,
    frames: &[[f32; 2]],
) -> Result<bool, StudioError> {
    let Some(pkg) = package_dir else { return Ok(false) };
    let cache = pkg.join("tiles");
    let stereo: Arc<[[f32; 2]]> = Arc::from(frames.to_vec().into_boxed_slice());
    let mut ready = true;
    for zoom in [64, 256, 1024] {
        match media::tile_job::get_or_spawn(&cache, hash, stereo.clone(), zoom) {
            media::tile_job::TileReadiness::Ready(_) => {}
            media::tile_job::TileReadiness::Pending(job) => {
                if job.done.recv_timeout(std::time::Duration::from_secs(10)).is_err() { ready = false; }
            }
        }
    }
    Ok(ready)
}

fn default_project(name: Option<&str>) -> Project {
    let mut p = Project::new(
        ENGINE_SAMPLE_RATE,
        TempoMap::single(Bpm::from_int(120).expect("120 bpm")),
    );
    p.project_id = ulid::new_ulid();
    if let Some(n) = name {
        p.name = n.to_string();
    }
    p
}

fn sanitize_name(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' })
        .collect();
    if cleaned.is_empty() {
        "untitled".to_string()
    } else {
        cleaned
    }
}

/// Whether `pkg` already holds a project that must be opened rather than
/// created over.
///
/// The JOURNAL is asked first and it is the answer that matters: it is the
/// durability mechanism, every command is written through to it at submit time,
/// and a package that has one has a project in it whether or not a checkpoint
/// survived alongside. `project.json` is still consulted so that a freshly
/// created, never-edited package — journal legitimately 0 bytes, checkpoint
/// present — is reopened rather than recreated, which would throw away its
/// project id and name.
fn has_project_on_disk(pkg: &Path) -> bool {
    let journal_has_bytes = std::fs::metadata(pkg.join("journal.jsonl"))
        .map(|m| m.len() > 0)
        .unwrap_or(false);
    journal_has_bytes || pkg.join("project.json").exists()
}

/// `<dir>/<stem>.mstudio`, or the first `<stem> N.mstudio` that is not already a
/// project. See `create_package` for why creating over one is not an option.
fn unique_package_path(dir: &Path, stem: &str) -> PathBuf {
    let first = dir.join(format!("{stem}.mstudio"));
    if !has_project_on_disk(&first) {
        return first;
    }
    for n in 2..10_000u32 {
        let candidate = dir.join(format!("{stem} {n}.mstudio"));
        if !has_project_on_disk(&candidate) {
            return candidate;
        }
    }
    // Nothing sane got here. Fall through to the plain path and let
    // `Package::create` refuse by name rather than invent a stranger one.
    first
}

/// A model pitch as the integer MIDI note it is contractually required to be.
/// `apply.rs` validates every zone boundary to an integer 0..=127 at write
/// time, so the integer view is exact for every zone this build can create; a
/// float from a foreign writer floors deterministically rather than panicking,
/// exactly as `DeviceZone::pitch_key` does.
fn pitch_of(n: &timeline_core::Num) -> i64 {
    n.0.as_i64().unwrap_or_else(|| n.as_f64().floor() as i64)
}

fn str_param(params: &Value, key: &str) -> Result<String, StudioError> {
    params
        .get(key)
        .and_then(Value::as_str)
        .map(String::from)
        .ok_or_else(|| StudioError::invalid(format!("missing string param '{key}'")))
}

/// The deliverable audio formats the master/region export writes in v1.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DeliverableFormat {
    /// 24-bit signed PCM WAV at the project rate (the master deliverable).
    Wav,
    /// AAC-LC in an .m4a via Apple AudioToolbox.
    Aac,
}

impl DeliverableFormat {
    fn parse(s: &str) -> Result<Self, StudioError> {
        match s.to_ascii_lowercase().as_str() {
            "wav" => Ok(DeliverableFormat::Wav),
            "aac" | "m4a" => Ok(DeliverableFormat::Aac),
            "flac" => Err(StudioError::Unsupported(
                "FLAC export lands with the IO codec pass; v1 exports WAV (24-bit) or AAC".into(),
            )),
            other => Err(StudioError::invalid(format!(
                "unknown export format '{other}' (want wav or aac)"
            ))),
        }
    }

    fn wire(self) -> &'static str {
        match self {
            DeliverableFormat::Wav => "wav",
            DeliverableFormat::Aac => "aac",
        }
    }
}

/// Read the optional `loudnessTarget` param (default none).
fn loudness_target(params: &Value) -> LoudnessTarget {
    params
        .get("loudnessTarget")
        .and_then(Value::as_str)
        .map(LoudnessTarget::from_wire)
        .unwrap_or(LoudnessTarget::None)
}

fn loudness_json(n: &NormalizeReport) -> Value {
    let opt = |x: f32| if x.is_finite() { json!(round1(x)) } else { Value::Null };
    json!({
        "target": n.target.wire_name(),
        "integratedLufsBefore": opt(n.measured_before_lufs),
        "appliedGainDb": round2f(n.applied_gain_db),
        "integratedLufsAfter": opt(n.measured_after_lufs),
        "samplePeakDbfs": opt(n.sample_peak_dbfs),
        "errorLu": round2f(n.error_lu()),
    })
}

/// The render thread's stats, on the wire.
///
/// A FREE FUNCTION on purpose. Everything else in `engine_stats()` needs a
/// live device, so until this was lifted out the only way to assert what the
/// app reads was to open one — which no default test run may do, so nothing
/// asserted it at all and a renamed key would have shipped green. Given a
/// `StatsSnapshot` (which `ManualRenderer` hands out with no hardware
/// whatsoever) this is the whole mapping, testable in a millisecond.
///
/// `StudioHost::engine_stats` adds the four fields that genuinely need the
/// device and the host — `deviceName`, `audible`, `sourceCount`, `seq` — and
/// changes nothing here.
pub fn engine_stats_json(s: &render::stats::StatsSnapshot) -> Value {
    let ns_to_ms = |ns: u64| ns as f64 / 1.0e6;
    json!({
        "live": true,
        "playing": s.playing,
        "underruns": s.underruns,
        "callbacks": s.callbacks,
        "callbackP95Ms": ns_to_ms(s.callback_ns_p95),
        "callbackMaxMs": ns_to_ms(s.callback_ns_max),
        "callbackMeanMs": ns_to_ms(s.callback_ns_mean),
        "deadlineMisses": s.deadline_misses,
        "commandOverruns": s.command_overruns,
        "leakedBuffers": s.leaked_buffers,
        "streamErrors": s.stream_errors,
        "allocViolations": s.alloc_violations,
        "positionFrame": s.position_frame,
        "framesRendered": s.frames_rendered,
        // THE CLICK, MADE OBSERVABLE. The metronome is excluded from the
        // master bus, the meters and the capture tap on purpose, so until
        // these two landed the only way to know whether it was running was to
        // listen. `metronomeClicks` climbing while the room is silent puts the
        // fault between the core's buffer and the speakers; `deviceFramesAudible`
        // stuck at 0 while `framesRendered` climbs names the silence gate as
        // the reason.
        "metronomeClicks": s.metronome_clicks,
        "deviceFramesAudible": s.device_frames_audible,
        "deviceSampleRate": s.device_sample_rate,
    })
}

/// `/x/Song.wav` -> `/x/Song.manifest.json`; `/x/stems` (dir stem) -> `/x/stems.manifest.json`.
fn manifest_sidecar_path(out: &Path) -> PathBuf {
    let stem = out
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("export");
    let parent = out.parent().map(Path::to_path_buf).unwrap_or_default();
    parent.join(format!("{stem}.manifest.json"))
}

fn round1(x: f32) -> f32 {
    (x * 10.0).round() / 10.0
}

fn round2f(x: f32) -> f32 {
    (x * 100.0).round() / 100.0
}

/// Classify a take by the gen command that produced it, for the Takes browser.
/// `gen.song` = a landed whole song (a provenance anchor, not an alternative).
fn take_kind(source_command: &str) -> &'static str {
    match source_command {
        "gen.song" => "landing",
        "gen.revise" => "revise",
        "gen.extend" => "extend",
        "gen.layer" => "layer",
        "gen.retake" => "retake",
        "gen.finalize" => "finalize",
        "gen.cover" => "cover",
        "gen.autocomplete" => "autocomplete",
        "record.commit" => "record",
        _ => "other",
    }
}

/// FNV-1a 64-bit hash, matching RealStudioEngine.seedFor in Swift so the
/// same asset hash produces the same waveform seed on both sides.
fn fnv1a_seed(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf29ce484222325;
    for &b in bytes {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash | 1
}

fn actor_kind_str(actor: &Actor) -> &'static str {
    use timeline_core::envelope::ActorKind;
    match actor.kind {
        ActorKind::User => "user",
        ActorKind::Agent => "agent",
        ActorKind::Api => "api",
        ActorKind::Copilot => "copilot",
        ActorKind::System => "system",
    }
}

fn entry_touches_clip(
    e: &timeline_core::Envelope,
    clip_id: &str,
    take_ids: &std::collections::HashSet<String>,
    request_ids: &std::collections::HashSet<String>,
) -> bool {
    let p = &e.params;
    for key in ["clipId", "targetClipId", "newClipId", "clipIdA", "clipIdB", "contextClipId", "referenceClipId"] {
        if p.get(key).and_then(Value::as_str) == Some(clip_id) {
            return true;
        }
    }
    if let Some(tid) = p.get("takeId").and_then(Value::as_str) {
        if take_ids.contains(tid) {
            return true;
        }
    }
    if let Some(rid) = p.get("requestId").and_then(Value::as_str) {
        if request_ids.contains(rid) {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod meters_nodes_tests {
    //! E5-ui-truth: the snapshot contract for routing-node meters.
    //!
    //! The Swift routing pane keys its bus meters off `meters()["nodes"]`
    //! (nodeId + peakDb/rmsDb, in `routing.nodes` order). Before this landed,
    //! `MeterBank::node_meters` existed render-side with NO reader, so the pane
    //! had nothing to draw. These pin the exposure: the key exists, it follows
    //! the model order, and offline it reports the honest -120 floor — a
    //! fabricated constant level here would go red, not green.

    use super::StudioHost;
    use serde_json::json;
    use timeline_core::Actor;

    fn host_with_buses() -> StudioHost {
        let tmp = tempfile::tempdir().unwrap();
        let pkg = tmp.path().join("Meters.mstudio");
        let mut host = StudioHost::create_at(&pkg, "Meters").unwrap();
        std::mem::forget(tmp);
        let user = Actor::user("aaron");
        host.submit(
            user.clone(),
            "route.node.add",
            json!({"nodeId": "revBus", "kind": "bus", "name": "Reverb"}),
        )
        .unwrap();
        host.submit(
            user,
            "route.node.add",
            json!({"nodeId": "drums", "kind": "group", "name": "Drums"}),
        )
        .unwrap();
        host
    }

    #[test]
    fn meters_carry_one_entry_per_routing_node_in_model_order() {
        let host = host_with_buses();
        let m = host.meters();
        let nodes = m["nodes"].as_array().expect("meters() must carry `nodes`");
        let ids: Vec<&str> = nodes.iter().map(|n| n["nodeId"].as_str().unwrap()).collect();
        assert_eq!(
            ids,
            vec!["revBus", "drums"],
            "node meters must be keyed by node id, in routing.nodes order \
             (meter-bank slot i IS routing.nodes[i])"
        );
    }

    #[test]
    fn offline_node_meters_report_the_silence_floor_not_a_fabricated_level() {
        let host = host_with_buses();
        let m = host.meters();
        assert_eq!(m["live"], json!(false), "this host never opened a device");
        for n in m["nodes"].as_array().unwrap() {
            assert_eq!(
                n["peakDb"].as_f64(),
                Some(-120.0),
                "offline there is no signal; anything above the floor here is \
                 an invented meter, the exact defect the routing pane exists to avoid"
            );
            assert_eq!(n["rmsDb"].as_f64(), Some(-120.0));
        }
    }

    #[test]
    fn a_project_without_buses_still_carries_an_empty_nodes_array() {
        let tmp = tempfile::tempdir().unwrap();
        let pkg = tmp.path().join("NoBuses.mstudio");
        let host = StudioHost::create_at(&pkg, "NoBuses").unwrap();
        std::mem::forget(tmp);
        let m = host.meters();
        assert_eq!(
            m["nodes"].as_array().map(Vec::len),
            Some(0),
            "`nodes` is part of the meters contract even when empty: an absent \
             key and an empty graph are different statements"
        );
    }

    #[test]
    fn snapshot_carries_tempo_confidence_from_landing_metadata() {
        let mut host = StudioHost::in_memory();
        host.set_tempo_confidence(0.42);

        assert_eq!(
            host.snapshot(None)["project"]["tempoConfidence"],
            json!(0.42),
            "tempo confidence must cross the existing snapshot JSON boundary"
        );
    }

    #[test]
    fn snapshot_omits_tempo_confidence_when_project_was_not_landed() {
        let host = StudioHost::in_memory();
        assert!(
            host.snapshot(None)["project"].get("tempoConfidence").is_none(),
            "unknown confidence must not be serialized as a failed detection"
        );
    }
}
