//! Master loudness metering (EBU R128) on a dedicated control-side thread.
//!
//! The render callback CANNOT run ebur128 (it allocates and is not RT-safe),
//! so it taps every master frame into a bounded channel. This thread drains
//! the channel, feeds `ebur128::EbuR128` (integrated + short-term), and
//! publishes LUFS into the `MeterBank` atomics for any UI/API to read. A full
//! channel drops frames (counted in stats) rather than ever blocking audio.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use crossbeam_channel::Receiver;
use ebur128::{EbuR128, Mode};

use crate::stats::MeterBank;

pub struct LoudnessMeter {
    stop: Arc<AtomicBool>,
    handle: Option<thread::JoinHandle<()>>,
}

impl LoudnessMeter {
    /// Spawn the meter thread. `rx` receives interleaved-by-frame stereo
    /// master samples; `meters` is where LUFS gets published.
    pub fn spawn(sample_rate: u32, rx: Receiver<[f32; 2]>, meters: Arc<MeterBank>) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = Arc::clone(&stop);
        let handle = thread::Builder::new()
            .name("majiks-loudness".into())
            .spawn(move || run(sample_rate, rx, meters, thread_stop))
            .expect("spawn loudness meter");
        Self {
            stop,
            handle: Some(handle),
        }
    }
}

impl Drop for LoudnessMeter {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

fn run(sample_rate: u32, rx: Receiver<[f32; 2]>, meters: Arc<MeterBank>, stop: Arc<AtomicBool>) {
    let mut state = match EbuR128::new(2, sample_rate, Mode::I | Mode::S | Mode::M) {
        Ok(s) => s,
        Err(_) => return,
    };
    // Reusable interleaved batch buffer (control thread; allocation is fine
    // here, never on the audio path).
    let mut batch: Vec<f32> = Vec::with_capacity(8_192);
    let mut since_publish = 0_usize;
    // Publish LUFS about every 100 ms of audio.
    let publish_every = (sample_rate / 10).max(1) as usize;

    loop {
        // Block briefly for the first frame so an idle engine costs nothing.
        match rx.recv_timeout(Duration::from_millis(100)) {
            Ok(frame) => {
                batch.push(frame[0]);
                batch.push(frame[1]);
            }
            Err(crossbeam_channel::RecvTimeoutError::Timeout) => {
                if stop.load(Ordering::Relaxed) {
                    return;
                }
                continue;
            }
            Err(_) => return,
        }
        // Drain whatever else is queued without blocking.
        while let Ok(frame) = rx.try_recv() {
            batch.push(frame[0]);
            batch.push(frame[1]);
            if batch.len() >= 16_384 {
                break;
            }
        }
        let frames = batch.len() / 2;
        if frames > 0 {
            let _ = state.add_frames_f32(&batch);
            since_publish += frames;
            batch.clear();
        }
        if since_publish >= publish_every {
            since_publish = 0;
            let integrated = state
                .loudness_global()
                .ok()
                .map(|v| v as f32)
                .filter(|v| v.is_finite())
                .unwrap_or(f32::NEG_INFINITY);
            let short_term = state
                .loudness_shortterm()
                .ok()
                .map(|v| v as f32)
                .filter(|v| v.is_finite())
                .unwrap_or(f32::NEG_INFINITY);
            meters.publish_lufs(integrated, short_term);
        }
        if stop.load(Ordering::Relaxed) && rx.is_empty() {
            return;
        }
    }
}

/// Offline convenience: integrated LUFS of a finished buffer (bounce report).
pub fn integrated_lufs(samples: &[[f32; 2]], sample_rate: u32) -> f32 {
    let mut state = match EbuR128::new(2, sample_rate, Mode::I) {
        Ok(s) => s,
        Err(_) => return f32::NEG_INFINITY,
    };
    let flat: &[f32] = samples.as_flattened();
    if state.add_frames_f32(flat).is_err() {
        return f32::NEG_INFINITY;
    }
    state
        .loudness_global()
        .ok()
        .map(|v| v as f32)
        .filter(|v| v.is_finite())
        .unwrap_or(f32::NEG_INFINITY)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn integrated_lufs_of_a_known_tone_is_in_range() {
        // A 1 kHz sine at -20 dBFS should read near -23 LUFS (a full-scale
        // sine is about -3 LUFS; -20 dBFS is 20 dB down, but the K-weighting
        // and gating shift it, so allow a wide sane band).
        let sr = 48_000;
        let amp = 10.0_f32.powf(-20.0 / 20.0);
        let samples: Vec<[f32; 2]> = (0..sr * 3)
            .map(|i| {
                let v = (std::f32::consts::TAU * 1_000.0 * i as f32 / sr as f32).sin() * amp;
                [v, v]
            })
            .collect();
        let lufs = integrated_lufs(&samples, sr);
        assert!(
            (-30.0..-15.0).contains(&lufs),
            "1 kHz -20 dBFS integrated LUFS out of range: {lufs}"
        );
    }

    #[test]
    fn silence_reads_negative_infinity() {
        let samples = vec![[0.0_f32; 2]; 48_000];
        let lufs = integrated_lufs(&samples, 48_000);
        assert!(lufs.is_infinite() && lufs < 0.0, "silence LUFS = {lufs}");
    }
}
