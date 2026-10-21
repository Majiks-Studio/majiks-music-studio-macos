//! ProjectHost: glues the pure model to the engine.
//!
//! Every model mutation goes through `apply` as a timeline-core command: the
//! model applies it (returning inverses for undo), the host mirrors mixer +
//! automation + warp state, recompiles the session snapshot (Auto declick),
//! and swaps it into the render core. Transport commands translate to render
//! commands (ticks resolve to frames through the tempo map at translation).
//! This is the command-bus spine the full app (UI, MCP, copilot) sits on;
//! journaling/envelopes are P0-C scope.
//!
//! Mixer + automation + warp commands are handled here as render-side state
//! because timeline-core's P0-B command subset does not carry them yet; the
//! host exposes typed methods the surface layer (L5/L6) calls, and the L2
//! report requests the matching timeline-core command handlers from L1.

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

use timeline_core::{Applied, Command, Project, Source};

use crate::automation::{AutoTarget, AutomationStore, CurveKind, RawPoint};
use crate::compile::{compile_session_full, DeclickPolicy};
use crate::engine::Engine;
use crate::media::{load_wav_stereo_48k, AudioBuf};
use crate::rt::RenderCommand;
use crate::warp::{is_identity, WarpEntry, WarpJob, WarpOverlay, WarpWorker};

pub struct ProjectHost {
    pub project: Project,
    sources: HashMap<String, Arc<AudioBuf>>,
    warp: WarpOverlay,
    automation: AutomationStore,
    engine: Engine,
    warp_worker: Option<WarpWorker>,
    /// Globally monotonic warp generation. Survives overlay entry removal
    /// (an identity clear deletes the entry), so a stale in-flight result
    /// can never share a generation with a later request for the same clip.
    warp_gen: u64,
    undo_stack: Vec<Applied>,
    redo_stack: Vec<Applied>,
    declick: DeclickPolicy,
}

impl ProjectHost {
    pub fn new(project: Project, engine: Engine) -> Self {
        Self {
            project,
            sources: HashMap::new(),
            warp: WarpOverlay::new(),
            automation: AutomationStore::new(),
            engine,
            warp_worker: None,
            warp_gen: 0,
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            declick: DeclickPolicy::Auto,
        }
    }

    /// Override the declick policy (tests that want raw scheduler output).
    pub fn set_declick(&mut self, policy: DeclickPolicy) {
        self.declick = policy;
    }

    pub fn engine(&self) -> &Engine {
        &self.engine
    }

    pub fn engine_mut(&mut self) -> &mut Engine {
        &mut self.engine
    }

    pub fn sources(&self) -> &HashMap<String, Arc<AudioBuf>> {
        &self.sources
    }

    /// Attach an off-thread warp worker (the render callback never stretches).
    pub fn attach_warp_worker(&mut self, worker: WarpWorker) {
        self.warp_worker = Some(worker);
    }

    pub fn warp_worker(&self) -> Option<&WarpWorker> {
        self.warp_worker.as_ref()
    }

    /// Current monotonic warp generation (observability: total non-identity
    /// warp requests issued since construction).
    pub fn warp_generation(&self) -> u64 {
        self.warp_gen
    }

    /// Decode + register an audio source (model registry + loaded buffer).
    pub fn load_source(&mut self, id: &str, path: &Path) -> Result<(), String> {
        let audio = Arc::new(load_wav_stereo_48k(path)?);
        self.project
            .add_source(Source {
                id: id.to_string(),
                path: path.display().to_string(),
                len_frames: audio.len_frames(),
            })
            .map_err(|e| e.to_string())?;
        self.sources.insert(id.to_string(), audio);
        Ok(())
    }

    /// Register a synthetic buffer (tests, probe).
    pub fn register_source(&mut self, id: &str, audio: Arc<AudioBuf>) -> Result<(), String> {
        self.project
            .add_source(Source {
                id: id.to_string(),
                path: format!("synthetic:{id}"),
                len_frames: audio.len_frames(),
            })
            .map_err(|e| e.to_string())?;
        self.sources.insert(id.to_string(), audio);
        Ok(())
    }

    pub fn compile(&self) -> Result<Box<crate::rt::RtSession>, String> {
        compile_session_full(
            &self.project,
            &self.sources,
            &self.warp,
            &self.automation,
            self.engine.config().max_tracks,
            self.declick,
        )
    }

    /// Recompile and swap the render session (called after model edits; also
    /// used directly by the stress probe to hammer the swap path).
    pub fn push_session(&self) -> Result<(), String> {
        let session = self.compile()?;
        if !self.engine.command(RenderCommand::SetSession(session)) {
            return Err("command channel full (SetSession dropped, counted as overrun)".into());
        }
        Ok(())
    }

    /// Mirror model mixer state (mute + solo -> params) into the engine.
    pub fn sync_track_params(&self) {
        for (idx, track) in self.project.tracks.iter().enumerate() {
            self.engine.params().set_track_mute(idx, track.mute);
            self.engine.params().set_track_solo(idx, track.solo);
        }
        self.engine
            .params()
            .clear_track_solos_from(self.project.tracks.len());
        self.sync_routing_params();
    }

    /// Stale-slot hygiene for the E5 routing atomics
    /// (DESIGN-E5-routing.md §6.3).
    ///
    /// Edge-level and node-gain slots are assigned by `compile` and change on
    /// every session swap, so a value left in a slot the current session no
    /// longer uses is either harmless or WRONG once that slot is recycled.
    /// The discipline is push-then-clear-from-the-live-count, exactly as
    /// `clear_track_solos_from` does for solo.
    ///
    /// ⚠️ **The push half is NOT here yet, and that is a lane seam, not an
    /// oversight.** `RouteEdge::level` is model state, but the edgeId -> slot
    /// mapping lives on `RtSession::edge_index` (§6.2) — "flat, sorted by
    /// source in SCHEDULE order", which E5-graph's `compile` produces. The
    /// host cannot derive it (declaration order is not schedule order) and
    /// guessing it would permute the mix. When `edge_index` lands, the push
    /// goes in immediately above the clear.
    ///
    /// The CLEAR half is already correct and complete, because it depends only
    /// on the live COUNT, which is order-independent: slots `0..n` belong to
    /// this session's edges whatever permutation `compile` chose within them.
    ///
    /// Node gain has no push at all by design: `RouteNode` carries no gain
    /// field and no command writes one (§2.2 — `bus.<id>.gain` is an
    /// automation ParamRef and a live fader, both atomic-only).
    fn sync_routing_params(&self) {
        let routing = &self.project.routing;
        self.engine
            .params()
            .clear_edge_levels_from(routing.edges.len());
        self.engine
            .params()
            .clear_node_gains_from(routing.nodes.len());
    }

    // ---- mixer surface (render-side state; L1 command handlers requested) ----

    fn track_index(&self, track_id: &str) -> Option<usize> {
        self.project.track_index(track_id)
    }

    pub fn set_gain_db(&self, track_id: &str, gain_db: f32) {
        if let Some(idx) = self.track_index(track_id) {
            self.engine.params().set_track_gain_db(idx, gain_db);
        }
    }

    pub fn set_pan(&self, track_id: &str, pan: f32) {
        if let Some(idx) = self.track_index(track_id) {
            self.engine.params().set_track_pan(idx, pan);
        }
    }

    pub fn set_eq(&self, track_id: &str, band: usize, freq_hz: f32, gain_db: f32, q: f32) {
        if let Some(idx) = self.track_index(track_id) {
            self.engine
                .params()
                .set_track_eq(idx, band, freq_hz, gain_db, q);
        }
    }

    pub fn set_send(&self, track_id: &str, bus_b: bool, amount: f32) {
        if let Some(idx) = self.track_index(track_id) {
            self.engine.params().set_track_send(idx, bus_b, amount);
        }
    }

    pub fn set_master_gain_db(&self, gain_db: f32) {
        self.engine.params().set_master_gain_db(gain_db);
    }

    pub fn set_limiter(&self, enabled: bool, ceiling_db: f32, release_ms: f32) {
        self.engine
            .params()
            .set_limiter(enabled, ceiling_db, release_ms);
    }

    /// Resolve a tempo-sync division (numerator/denominator of a beat) to
    /// frames through the tempo map, then set the delay bus.
    pub fn set_delay_division(&self, num: u32, den: u32, feedback: f32, tone: f32) {
        let beat_ticks = timeline_core::PPQ;
        let ticks = (beat_ticks as u128 * num as u128 / den.max(1) as u128) as u64;
        let frames = self
            .project
            .tempo
            .tick_to_frame(ticks, self.project.sample_rate)
            .max(1) as u32;
        self.engine.params().set_delay(frames, feedback, tone);
    }

    pub fn set_reverb(&self, damping: f32, feedback: f32) {
        self.engine.params().set_reverb(damping, feedback);
    }

    pub fn set_return_db(&self, bus_b: bool, gain_db: f32) {
        self.engine.params().set_return_db(bus_b, gain_db);
    }

    // ---- automation surface (baked at compile) ----

    pub fn add_automation_point(
        &mut self,
        track_id: &str,
        target: AutoTarget,
        tick: u64,
        value: f32,
    ) -> Result<(), String> {
        self.automation.add_point(
            track_id,
            target,
            RawPoint {
                tick,
                value,
                curve: CurveKind::Linear,
            },
        );
        self.push_session()
    }

    pub fn clear_automation(&mut self, track_id: &str, target: AutoTarget) -> Result<(), String> {
        self.automation.clear_lane(track_id, target);
        self.push_session()
    }

    // ---- warp surface (off-thread stretch, swap when ready) ----

    /// Request a per-clip warp ratio. Identity clears any warp. A non-
    /// identity ratio submits an off-thread stretch job; the clip keeps
    /// playing (unwarped, or its previous stretched buffer) until the result
    /// lands and `pump_warp_results` swaps it in.
    pub fn set_warp_ratio(&mut self, clip_id: &str, ratio: f64) -> Result<(), String> {
        let (source, offset, len) = {
            let (ti, ci) = self
                .project
                .find_clip(clip_id)
                .ok_or_else(|| format!("unknown clip {clip_id}"))?;
            let clip = &self.project.tracks[ti].clips[ci];
            let source = self
                .sources
                .get(&clip.source_id)
                .ok_or_else(|| format!("clip {clip_id} source not loaded"))?;
            (Arc::clone(source), clip.offset_frames, clip.len_frames)
        };

        if is_identity(ratio) {
            self.warp.remove(clip_id);
            return self.push_session();
        }

        // Monotonic across the whole host, so a leftover result from a prior
        // (since-removed) entry can never equal a new entry's generation.
        self.warp_gen += 1;
        let generation = self.warp_gen;
        let entry = self.warp.entry(clip_id.to_string()).or_insert(WarpEntry {
            ratio,
            generation,
            stretched: None,
            stretched_ratio: 1.0,
        });
        entry.ratio = ratio;
        entry.generation = generation;

        if let Some(worker) = self.warp_worker.as_ref() {
            worker.submit(WarpJob {
                clip_id: clip_id.to_string(),
                source,
                offset_frames: offset,
                len_frames: len,
                ratio,
                generation,
            });
        }
        // Recompile now so the timeline extent updates even before the
        // stretched audio lands (the clip plays unwarped meanwhile).
        self.push_session()
    }

    /// Drain finished warp results and swap in any that are still current.
    /// Returns how many clips were updated. Call from the control loop.
    pub fn pump_warp_results(&mut self) -> Result<usize, String> {
        let results = match self.warp_worker.as_ref() {
            Some(w) => w.try_results(),
            None => return Ok(0),
        };
        let mut updated = 0;
        for r in results {
            if let Some(entry) = self.warp.get_mut(&r.clip_id) {
                // Drop stale results (a newer ratio was requested since).
                if r.generation == entry.generation {
                    entry.stretched = Some(r.audio);
                    entry.stretched_ratio = r.ratio;
                    updated += 1;
                }
            }
        }
        if updated > 0 {
            self.push_session()?;
        }
        Ok(updated)
    }

    fn route_transport(&self, command: &Command) {
        let rate = self.project.sample_rate;
        match command {
            Command::TransportPlay {} => {
                self.engine.command(RenderCommand::Play);
            }
            Command::TransportStop {} => {
                self.engine.command(RenderCommand::Stop);
            }
            Command::TransportSeek { to_tick, to_frame } => {
                let frame = match (to_tick, to_frame) {
                    (Some(t), None) => self.project.tempo.tick_to_frame(*t, rate),
                    (None, Some(f)) => *f,
                    _ => return,
                };
                self.engine.command(RenderCommand::Seek { frame });
            }
            Command::TransportLoopSet {
                start_tick,
                end_tick,
            } => {
                self.engine.command(RenderCommand::LoopSet {
                    start_frame: self.project.tempo.tick_to_frame(*start_tick, rate),
                    end_frame: self.project.tempo.tick_to_frame(*end_tick, rate),
                });
            }
            Command::TransportLoopClear {} => {
                self.engine.command(RenderCommand::LoopClear);
            }
            _ => {}
        }
    }

    fn apply_internal(&mut self, command: &Command) -> Result<Applied, String> {
        let applied = self.project.apply(command).map_err(|e| e.to_string())?;
        if command.is_transport() {
            self.route_transport(command);
        } else {
            self.sync_track_params();
            self.push_session()?;
        }
        Ok(applied)
    }

    /// Apply a command through the bus: model, params, render swap, undo.
    pub fn apply(&mut self, command: &Command) -> Result<Applied, String> {
        let applied = self.apply_internal(command)?;
        if command.is_undoable() {
            self.undo_stack.push(applied.clone());
            self.redo_stack.clear();
        }
        Ok(applied)
    }

    pub fn undo(&mut self) -> Result<bool, String> {
        let Some(applied) = self.undo_stack.pop() else {
            return Ok(false);
        };
        for inverse in &applied.inverse {
            self.apply_internal(inverse)?;
        }
        self.redo_stack.push(applied);
        Ok(true)
    }

    pub fn redo(&mut self) -> Result<bool, String> {
        let Some(applied) = self.redo_stack.pop() else {
            return Ok(false);
        };
        self.apply_internal(&applied.command)?;
        self.undo_stack.push(applied);
        Ok(true)
    }

    pub fn undo_depth(&self) -> usize {
        self.undo_stack.len()
    }

    /// Rehydrate the output stream onto the current default device after a
    /// device change or fault (DJ P7): restart the stream, re-push the
    /// session, re-seek to the last published position, and resume transport
    /// if it was playing. Sources, params, meters, warp, and automation are
    /// all intact across the switch.
    pub fn rehydrate_output(&mut self) -> Result<(), String> {
        let was_playing = self.engine.stats().playing;
        let position = self.engine.position_frame();
        self.engine.restart_output()?;
        self.sync_track_params();
        self.push_session()?;
        self.engine.command(RenderCommand::Seek { frame: position });
        if was_playing {
            self.engine.command(RenderCommand::Play);
        }
        Ok(())
    }
}
