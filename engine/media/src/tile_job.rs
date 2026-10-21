//! Cancel-safe, off-caller-thread waveform tile generation with disk
//! caching under a project's `tiles/` directory (02-ARCHITECTURE.md section
//! 6: ".mstudio / tiles/ ... waveform tile cache (rebuildable,
//! gitignored-class)"). Native-only (std::thread, std::fs): not part of the
//! wasm32 pure-math surface (`tiles` itself is; this wrapper is not).
//!
//! "Async" here means off the caller's thread with cancellation and a
//! subscribable completion channel, not necessarily Rust's `async`/`await`
//! keyword: the engine workspace (render, timeline-core) does not use an
//! async runtime, and pulling one in just for this crate would be an
//! inconsistent, heavier dependency than the job needs. A Future-based
//! wrapper for a Swift/JS caller (if L5 wants one) is a thin adapter over
//! `TileJobHandle`'s channel, not a reason to change this module.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;

use crossbeam_channel::{unbounded, Receiver};

use crate::tiles::{compute_tile, decode_tile, encode_tile, WaveformTile};

pub struct TileJobHandle {
    cancel: Arc<AtomicBool>,
    /// Completion channel: `subscribe` by cloning/holding this receiver (or
    /// polling `try_recv`), matching the brief's "API returns ready tiles +
    /// subscribes to completion".
    pub done: Receiver<Result<WaveformTile, String>>,
}

impl TileJobHandle {
    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::SeqCst);
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancel.load(Ordering::SeqCst)
    }

    /// Non-blocking poll. `None` means still running.
    pub fn try_recv(&self) -> Option<Result<WaveformTile, String>> {
        self.done.try_recv().ok()
    }
}

pub enum TileReadiness {
    Ready(WaveformTile),
    Pending(TileJobHandle),
}

fn cache_path(cache_dir: &Path, content_hash: &str, zoom: u32) -> PathBuf {
    cache_dir.join(format!("{content_hash}.{zoom}.mmtl"))
}

/// Returns a ready tile immediately if a matching cache entry already
/// exists under `cache_dir` (keyed by the asset's content hash + zoom, see
/// `hash::hash_file`); otherwise spawns a background thread to compute and
/// cache it and returns a handle the caller can poll or cancel.
///
/// `stereo` is `Arc` so spawning does not copy the decoded audio; callers
/// generating tiles at multiple zooms for the same asset should share one
/// `Arc` across calls.
pub fn get_or_spawn(cache_dir: &Path, content_hash: &str, stereo: Arc<[[f32; 2]]>, zoom_samples_per_pixel: u32) -> TileReadiness {
    let path = cache_path(cache_dir, content_hash, zoom_samples_per_pixel);
    if let Ok(bytes) = std::fs::read(&path) {
        if let Ok(tile) = decode_tile(&bytes) {
            return TileReadiness::Ready(tile);
        }
        // Corrupt/truncated cache entry: fall through and regenerate.
    }

    let cancel = Arc::new(AtomicBool::new(false));
    let (tx, rx) = unbounded();
    let handle = TileJobHandle { cancel: cancel.clone(), done: rx };
    let path_for_thread = path.clone();

    thread::spawn(move || {
        if cancel.load(Ordering::SeqCst) {
            let _ = tx.send(Err("cancelled".to_string()));
            return;
        }
        let tile = compute_tile(&stereo, zoom_samples_per_pixel);
        if cancel.load(Ordering::SeqCst) {
            let _ = tx.send(Err("cancelled".to_string()));
            return;
        }
        let bytes = encode_tile(&tile);
        if let Some(parent) = path_for_thread.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        // Write-to-temp-then-rename for cache-write atomicity: a reader
        // (or a crash) never observes a torn cache file. Best-effort: a
        // failure to persist must not fail the in-memory result the
        // caller is waiting on.
        let tmp_path = path_for_thread.with_extension("mmtl.tmp");
        if std::fs::write(&tmp_path, &bytes).is_ok() {
            let _ = std::fs::rename(&tmp_path, &path_for_thread);
        }
        let _ = tx.send(Ok(tile));
    });

    TileReadiness::Pending(handle)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    fn temp_dir(label: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("media-tile-job-test-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn wait_ready(handle: &TileJobHandle) -> WaveformTile {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(result) = handle.try_recv() {
                return result.expect("job should not fail");
            }
            assert!(Instant::now() < deadline, "tile job did not complete in time");
            thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn first_call_computes_and_caches_second_call_is_ready_immediately() {
        let dir = temp_dir("basic");
        let stereo: Arc<[[f32; 2]]> = Arc::from(vec![[0.1f32, -0.1f32]; 48_000]);

        let first = get_or_spawn(&dir, "contenthash123", stereo.clone(), 256);
        let tile = match first {
            TileReadiness::Pending(handle) => wait_ready(&handle),
            TileReadiness::Ready(t) => t,
        };
        assert!(!tile.left.is_empty());

        let second = get_or_spawn(&dir, "contenthash123", stereo, 256);
        match second {
            TileReadiness::Ready(cached) => assert_eq!(cached, tile),
            TileReadiness::Pending(_) => panic!("second call should hit the disk cache"),
        }
    }

    #[test]
    fn cancel_is_observed_by_the_background_thread() {
        let dir = temp_dir("cancel");
        // A large-ish buffer so the background thread has time to observe
        // the cancel flag before finishing.
        let stereo: Arc<[[f32; 2]]> = Arc::from(vec![[0.2f32, -0.2f32]; 20_000_000]);
        match get_or_spawn(&dir, "cancelhash", stereo, 64) {
            TileReadiness::Pending(handle) => {
                handle.cancel();
                let deadline = Instant::now() + Duration::from_secs(10);
                loop {
                    if let Some(result) = handle.try_recv() {
                        assert!(result.is_err(), "cancelled job should report an error result, not a tile");
                        break;
                    }
                    assert!(Instant::now() < deadline, "cancelled job never reported back");
                    thread::sleep(Duration::from_millis(5));
                }
            }
            TileReadiness::Ready(_) => {
                // Finished before we could cancel; acceptable on a very
                // fast machine, just not the case this test targets.
            }
        }
    }
}
