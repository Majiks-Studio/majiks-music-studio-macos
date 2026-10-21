//! A tiny, dependency-free ULID generator + RFC3339 timestamp, used to mint
//! journal entry metadata (`EntryMeta { id, ts, actor }`) for the command bus.
//!
//! timeline-core reads no clock and mints no ids by rule (`MetaSource`), so the
//! agent surface supplies them. The ids are Crockford base32, 26 chars, first
//! char in 0..7 (48-bit ms timestamp + 80-bit entropy), which also satisfies
//! the catalog's gen `requestId` pattern when an agent needs a fresh one.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use timeline_core::{Actor, EntryMeta};

const CROCKFORD: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// One process-wide monotone counter so two ULIDs minted in the same
/// millisecond never collide (mixed into the entropy).
static SEQ: AtomicU64 = AtomicU64::new(0);

/// splitmix64: a good, tiny scrambler for deriving entropy from a seed.
fn splitmix64(mut x: u64) -> u64 {
    x = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
    let mut z = x;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

fn encode_128(bytes: &[u8; 16]) -> String {
    // Standard ULID Crockford encoding: 128 bits -> 26 chars. The first char
    // carries only the top 3 bits of byte 0, so a 48-bit ms timestamp (top
    // byte 0 in this era) yields a leading '0'..'7'.
    let b = bytes;
    let idx = [
        (b[0] & 224) >> 5,
        b[0] & 31,
        (b[1] & 248) >> 3,
        ((b[1] & 7) << 2) | ((b[2] & 192) >> 6),
        (b[2] & 62) >> 1,
        ((b[2] & 1) << 4) | ((b[3] & 240) >> 4),
        ((b[3] & 15) << 1) | ((b[4] & 128) >> 7),
        (b[4] & 124) >> 2,
        ((b[4] & 3) << 3) | ((b[5] & 224) >> 5),
        b[5] & 31,
        (b[6] & 248) >> 3,
        ((b[6] & 7) << 2) | ((b[7] & 192) >> 6),
        (b[7] & 62) >> 1,
        ((b[7] & 1) << 4) | ((b[8] & 240) >> 4),
        ((b[8] & 15) << 1) | ((b[9] & 128) >> 7),
        (b[9] & 124) >> 2,
        ((b[9] & 3) << 3) | ((b[10] & 224) >> 5),
        b[10] & 31,
        (b[11] & 248) >> 3,
        ((b[11] & 7) << 2) | ((b[12] & 192) >> 6),
        (b[12] & 62) >> 1,
        ((b[12] & 1) << 4) | ((b[13] & 240) >> 4),
        ((b[13] & 15) << 1) | ((b[14] & 128) >> 7),
        (b[14] & 124) >> 2,
        ((b[14] & 3) << 3) | ((b[15] & 224) >> 5),
        b[15] & 31,
    ];
    idx.iter().map(|&i| CROCKFORD[i as usize] as char).collect()
}

/// A fresh ULID string (26 Crockford chars, first char 0..7).
pub fn new_ulid() -> String {
    let ms = now_millis();
    let seq = SEQ.fetch_add(1, Ordering::Relaxed);
    let e0 = splitmix64(ms ^ seq.wrapping_mul(0xD1B5_4A32_D192_ED03));
    let e1 = splitmix64(e0 ^ seq);
    let mut bytes = [0u8; 16];
    // 48-bit ms timestamp, big-endian, in bytes[0..6].
    bytes[0] = ((ms >> 40) & 0xFF) as u8;
    bytes[1] = ((ms >> 32) & 0xFF) as u8;
    bytes[2] = ((ms >> 24) & 0xFF) as u8;
    bytes[3] = ((ms >> 16) & 0xFF) as u8;
    bytes[4] = ((ms >> 8) & 0xFF) as u8;
    bytes[5] = (ms & 0xFF) as u8;
    // 80 bits of entropy in bytes[6..16].
    bytes[6..14].copy_from_slice(&e0.to_be_bytes());
    bytes[14] = (e1 & 0xFF) as u8;
    bytes[15] = ((e1 >> 8) & 0xFF) as u8;
    encode_128(&bytes)
}

/// Current UTC time as `YYYY-MM-DDTHH:MM:SSZ` (RFC3339, seconds precision).
/// Civil-from-days per Howard Hinnant's algorithm; no chrono dependency.
pub fn now_rfc3339() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0) as i64;
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (hh, mm, ss) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    // days since 1970-01-01 -> civil date.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if m <= 2 { y + 1 } else { y };
    format!("{year:04}-{m:02}-{d:02}T{hh:02}:{mm:02}:{ss:02}Z")
}

/// Mint entry metadata for a journaled command from a given actor.
pub fn entry_meta(actor: Actor) -> EntryMeta {
    EntryMeta {
        id: new_ulid(),
        ts: now_rfc3339(),
        actor,
    }
}

/// A `MetaSource` that mints fresh ULIDs + timestamps for undo/redo entries
/// (which journal forward), attributed to `actor`.
pub struct UlidMeta {
    actor: Actor,
}

impl UlidMeta {
    pub fn new(actor: Actor) -> Self {
        Self { actor }
    }
}

impl timeline_core::session::MetaSource for UlidMeta {
    fn next_meta(&mut self, _cmd: &timeline_core::Cmd) -> EntryMeta {
        entry_meta(self.actor.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ulids_are_26_crockford_chars_leading_0_to_7() {
        for _ in 0..1000 {
            let u = new_ulid();
            assert_eq!(u.len(), 26, "ulid {u}");
            let first = u.as_bytes()[0];
            assert!((b'0'..=b'7').contains(&first), "leading char {u}");
            assert!(
                u.bytes().all(|c| CROCKFORD.contains(&c)),
                "non-crockford char in {u}"
            );
        }
    }

    #[test]
    fn ulids_are_unique_in_a_tight_loop() {
        let mut seen = std::collections::HashSet::new();
        for _ in 0..10_000 {
            assert!(seen.insert(new_ulid()), "duplicate ulid");
        }
    }

    #[test]
    fn timestamp_is_rfc3339_shaped() {
        let ts = now_rfc3339();
        assert_eq!(ts.len(), 20, "{ts}");
        assert!(ts.ends_with('Z'));
        assert_eq!(&ts[4..5], "-");
        assert_eq!(&ts[10..11], "T");
    }
}
