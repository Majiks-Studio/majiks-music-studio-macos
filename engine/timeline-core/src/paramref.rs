//! `ParamRef` — the address of one automatable parameter.
//!
//! Design: `DESIGN-catalog-v2.md` §3. This is the irreversible decision of E0:
//! automation must address parameters that do not exist yet (instrument params,
//! plugin params, rack macros) without another wire-format change.
//!
//! # Grammar
//!
//! A dotted ASCII path, serialized as a **string** — the same shape the v1
//! `AutoTarget` enum already used, so a path grammar is a superset of the wire
//! form rather than a replacement.
//!
//! ```text
//! track.volume                      # LEGACY - byte-identical to v1.1
//! track.pan                         # LEGACY - byte-identical to v1.1
//! track.eq.<band>.<gain|freq|q>     # band 0-3 today, unbounded by the grammar
//! track.send.<sendId>.level
//! track.device.<deviceId>.<paramKey>   # E2 instruments, E4 plugins, E8 racks
//! master.gain
//! master.limiter.<ceiling|release>
//! bus.<busId>.gain
//! route.edge.<edgeId>.level            # E5 routing edge level (§2.2)
//! track.fx.<fxId>.<paramKey>           # E5 effect on a track strip (§16.3)
//! bus.<nodeId>.fx.<fxId>.<paramKey>    # E5 effect on a bus/group node
//! master.fx.<fxId>.<paramKey>          # E5 effect on the master bus
//! ```
//!
//! The four E5 additions are **pure Rust additions with ZERO catalog schema
//! edits**: the `autopoint.*`/`autolane.*` `target` schema is already the
//! widened `pattern: "^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$"`, all four are
//! well-formed under it, and all four classified as `Unrecognized` before now.
//! This is E0 §3 paying off exactly as designed.
//!
//! **Why `track.fx.` and not `track.device.`** (E5 §16.3): `track.device.*`
//! resolves against `Track::devices`, which stays instrument-only, and its
//! `param` segment validates against the closed `DEVICE_PARAM_KEYS`. Reusing it
//! would force the two registries to share an id namespace and force
//! `require_param_ref_on` to search both collections for every path. A sibling
//! segment costs nothing and keeps the registries disjoint; the property that
//! matters — effect params automate through the identical dense lane path
//! instruments use — is fully preserved.
//!
//! Segment charset is `[A-Za-z0-9_-]+`, segments joined by `.`. Ids are opaque
//! strings (ULID-shaped in practice) and MUST NOT contain `.`.
//!
//! # Two rules that are not negotiable
//!
//! 1. **Parsing is total and lossless.** A well-formed path this build does not
//!    recognize is `ParamRefKind::Unrecognized` and is preserved VERBATIM. It is
//!    never normalized, never dropped. Dropping unknown lanes on save is silent
//!    data loss — the exact failure mode this design exists to prevent.
//! 2. **`track.volume` and `track.pan` render byte-identically.** Never emit
//!    `track.0.volume` or any "more consistent" variant; that would change the
//!    wire form of every automation event ever journaled.

use std::fmt;

use serde::de::{self, Visitor};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

pub const TRACK_VOLUME: &str = "track.volume";
pub const TRACK_PAN: &str = "track.pan";

/// A parsed, well-formed parameter path. The stored string is the verbatim
/// wire form; `ParamRef` never rewrites it.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ParamRef(String);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParamRefError {
    /// Empty string, an empty segment (`a..b`, `.a`, `a.`), or a byte outside
    /// `[A-Za-z0-9_-]`.
    Malformed(String),
}

impl fmt::Display for ParamRefError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ParamRefError::Malformed(s) => {
                write!(f, "malformed parameter path {s:?}: expected dot-separated [A-Za-z0-9_-] segments")
            }
        }
    }
}

impl std::error::Error for ParamRefError {}

fn segment_ok(seg: &str) -> bool {
    !seg.is_empty()
        && seg
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

impl ParamRef {
    /// Total parse. Succeeds for every well-formed path, whether or not this
    /// build understands what it names.
    pub fn parse(s: &str) -> Result<ParamRef, ParamRefError> {
        if s.is_empty() || !s.split('.').all(segment_ok) {
            return Err(ParamRefError::Malformed(s.to_string()));
        }
        Ok(ParamRef(s.to_string()))
    }

    /// The verbatim wire form. Byte-identical to what was parsed.
    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn segments(&self) -> std::str::Split<'_, char> {
        self.0.split('.')
    }

    pub fn track_volume() -> ParamRef {
        ParamRef(TRACK_VOLUME.to_string())
    }

    pub fn track_pan() -> ParamRef {
        ParamRef(TRACK_PAN.to_string())
    }

    pub fn is_legacy(&self) -> bool {
        self.0 == TRACK_VOLUME || self.0 == TRACK_PAN
    }

    /// Classify. `Unrecognized` is a normal, non-error outcome: it means "this
    /// build does not know this parameter", not "this path is invalid".
    pub fn kind(&self) -> ParamRefKind<'_> {
        let seg: Vec<&str> = self.0.split('.').collect();
        match seg.as_slice() {
            ["track", "volume"] => ParamRefKind::TrackVolume,
            ["track", "pan"] => ParamRefKind::TrackPan,
            ["track", "eq", band, field] => match (band.parse::<u32>(), EqField::parse(field)) {
                (Ok(band), Some(field)) => ParamRefKind::TrackEq { band, field },
                _ => ParamRefKind::Unrecognized,
            },
            ["track", "send", send_id, "level"] => ParamRefKind::TrackSendLevel { send_id },
            ["track", "device", device_id, param] => ParamRefKind::TrackDeviceParam {
                device_id,
                param,
            },
            // E5 §16.3. Listed BEFORE the shorter `bus.<id>.gain` arm only for
            // readability — the slice patterns are disjoint by length and by
            // literal segment, so order is not load-bearing.
            ["track", "fx", fx_id, param] => ParamRefKind::TrackFxParam { fx_id, param },
            ["bus", bus_id, "fx", fx_id, param] => ParamRefKind::BusFxParam {
                bus_id,
                fx_id,
                param,
            },
            ["master", "fx", fx_id, param] => ParamRefKind::MasterFxParam { fx_id, param },
            // E5 §2.2 — the one new ROUTING segment.
            ["route", "edge", edge_id, "level"] => ParamRefKind::RouteEdgeLevel { edge_id },
            ["master", "gain"] => ParamRefKind::MasterGain,
            ["master", "limiter", field] => ParamRefKind::MasterLimiter { field },
            ["bus", bus_id, "gain"] => ParamRefKind::BusGain { bus_id },
            _ => ParamRefKind::Unrecognized,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EqField {
    Gain,
    Freq,
    Q,
}

impl EqField {
    fn parse(s: &str) -> Option<EqField> {
        match s {
            "gain" => Some(EqField::Gain),
            "freq" => Some(EqField::Freq),
            "q" => Some(EqField::Q),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            EqField::Gain => "gain",
            EqField::Freq => "freq",
            EqField::Q => "q",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParamRefKind<'a> {
    TrackVolume,
    TrackPan,
    TrackEq { band: u32, field: EqField },
    TrackSendLevel { send_id: &'a str },
    TrackDeviceParam { device_id: &'a str, param: &'a str },
    MasterGain,
    MasterLimiter { field: &'a str },
    BusGain { bus_id: &'a str },
    /// E5 §2.2: the level of one routing edge. Automatable only when the edge's
    /// SOURCE is a track (the lane hangs on that track's dense lane table);
    /// bus→bus edge levels are atomic-only in E5 and `require_param_ref_on`
    /// returns a typed error naming the deferral (§6.5).
    RouteEdgeLevel { edge_id: &'a str },
    /// E5 §16.3: a parameter of an effect in a TRACK's insert chain.
    TrackFxParam { fx_id: &'a str, param: &'a str },
    /// E5 §16.3: a parameter of an effect in a BUS/GROUP node's insert chain.
    BusFxParam {
        bus_id: &'a str,
        fx_id: &'a str,
        param: &'a str,
    },
    /// E5 §16.3: a parameter of an effect in the MASTER insert chain.
    MasterFxParam { fx_id: &'a str, param: &'a str },
    /// Well-formed, but this build does not know what it names. PRESERVED.
    Unrecognized,
}

impl fmt::Display for ParamRef {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::str::FromStr for ParamRef {
    type Err = ParamRefError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        ParamRef::parse(s)
    }
}

impl AsRef<str> for ParamRef {
    fn as_ref(&self) -> &str {
        &self.0
    }
}

impl Serialize for ParamRef {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.0)
    }
}

struct ParamRefVisitor;

impl<'de> Visitor<'de> for ParamRefVisitor {
    type Value = ParamRef;

    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("a dot-separated parameter path of [A-Za-z0-9_-] segments")
    }

    fn visit_str<E: de::Error>(self, v: &str) -> Result<ParamRef, E> {
        ParamRef::parse(v).map_err(|e| E::custom(e.to_string()))
    }
}

impl<'de> Deserialize<'de> for ParamRef {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        // `deserialize_str` (not `deserialize_string`) so this also works as a
        // serde_json MAP KEY, which is how `Automation::lanes` round-trips.
        d.deserialize_str(ParamRefVisitor)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_paths_render_byte_identically() {
        assert_eq!(ParamRef::track_volume().as_str(), "track.volume");
        assert_eq!(ParamRef::track_pan().as_str(), "track.pan");
        assert_eq!(
            serde_json::to_string(&ParamRef::track_volume()).unwrap(),
            "\"track.volume\""
        );
        assert!(ParamRef::track_volume().is_legacy());
        assert!(!ParamRef::parse("track.eq.0.gain").unwrap().is_legacy());
    }

    #[test]
    fn parse_is_total_for_well_formed_paths_and_preserves_them() {
        for s in [
            "track.volume",
            "track.pan",
            "track.eq.0.gain",
            "track.eq.3.q",
            "track.send.a.level",
            "track.device.01J8XZ.cutoff",
            "master.gain",
            "master.limiter.ceiling",
            "bus.reverb.gain",
            // Well-formed but meaningless to this build. Still parses, still
            // round-trips verbatim.
            "quantum.flux.capacitor",
            "a",
            "A-B_c.9",
        ] {
            let r = ParamRef::parse(s).unwrap_or_else(|e| panic!("{s}: {e}"));
            assert_eq!(r.as_str(), s, "{s} was rewritten");
            let json = serde_json::to_string(&r).unwrap();
            let back: ParamRef = serde_json::from_str(&json).unwrap();
            assert_eq!(back.as_str(), s);
        }
    }

    #[test]
    fn malformed_paths_are_rejected() {
        for s in ["", ".", "a.", ".a", "a..b", "a b", "a.b/c", "a.b.c."] {
            assert!(ParamRef::parse(s).is_err(), "{s:?} should be malformed");
        }
    }

    #[test]
    fn classification() {
        use ParamRefKind::*;
        let k = |s: &str| {
            let r = ParamRef::parse(s).unwrap();
            format!("{:?}", r.kind())
        };
        assert_eq!(ParamRef::parse("track.volume").unwrap().kind(), TrackVolume);
        assert_eq!(ParamRef::parse("track.pan").unwrap().kind(), TrackPan);
        assert_eq!(
            ParamRef::parse("track.eq.2.freq").unwrap().kind(),
            TrackEq {
                band: 2,
                field: EqField::Freq
            }
        );
        assert_eq!(
            ParamRef::parse("track.send.b.level").unwrap().kind(),
            TrackSendLevel { send_id: "b" }
        );
        assert_eq!(
            ParamRef::parse("track.device.dev1.cutoff").unwrap().kind(),
            TrackDeviceParam {
                device_id: "dev1",
                param: "cutoff"
            }
        );
        assert_eq!(ParamRef::parse("master.gain").unwrap().kind(), MasterGain);
        assert_eq!(
            ParamRef::parse("master.limiter.ceiling").unwrap().kind(),
            MasterLimiter { field: "ceiling" }
        );
        assert_eq!(
            ParamRef::parse("bus.a.gain").unwrap().kind(),
            BusGain { bus_id: "a" }
        );
        // Unrecognized is a NORMAL outcome, not an error.
        assert_eq!(ParamRef::parse("nope.nope").unwrap().kind(), Unrecognized);
        assert_eq!(ParamRef::parse("track.eq.x.gain").unwrap().kind(), Unrecognized);
        assert_eq!(ParamRef::parse("track.eq.0.wobble").unwrap().kind(), Unrecognized);
        assert!(k("track.volume").contains("TrackVolume"));
    }

    #[test]
    fn ordering_is_by_wire_string_so_btreemap_is_deterministic() {
        let mut v = vec![
            ParamRef::parse("track.pan").unwrap(),
            ParamRef::parse("bus.a.gain").unwrap(),
            ParamRef::parse("master.gain").unwrap(),
        ];
        v.sort();
        assert_eq!(
            v.iter().map(ParamRef::as_str).collect::<Vec<_>>(),
            ["bus.a.gain", "master.gain", "track.pan"]
        );
    }
}
