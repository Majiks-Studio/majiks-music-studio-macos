//! `Num`: a wire-exact JSON scalar.
//!
//! The journal hash chain canonicalizes numbers by their SOURCE shape: an
//! integer literal must never re-emit as a float (contracts README rule 4).
//! Model state that flows back out through inverse params therefore has to
//! remember exactly what arrived on the wire. `Num` wraps
//! `serde_json::Number`, which preserves the u64/i64 vs f64 distinction.

use serde::{Deserialize, Serialize};
use serde_json::Number;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Num(pub Number);

impl Num {
    pub fn int(v: i64) -> Self {
        Num(Number::from(v))
    }

    /// Lossy float view for DSP/UI use. Never used for journaling.
    pub fn as_f64(&self) -> f64 {
        self.0.as_f64().unwrap_or(0.0)
    }

    pub fn is_integer_shaped(&self) -> bool {
        !self.0.is_f64()
    }

    pub fn to_value(&self) -> serde_json::Value {
        serde_json::Value::Number(self.0.clone())
    }
}

impl PartialEq for Num {
    /// Structural equality on the wire form: `2` != `2.0` on purpose (they
    /// hash differently, so replay equality must distinguish them).
    fn eq(&self, other: &Self) -> bool {
        match (self.0.is_f64(), other.0.is_f64()) {
            (false, false) => {
                // Compare integer values across i64/u64 backing.
                match (self.0.as_i64(), other.0.as_i64()) {
                    (Some(a), Some(b)) => a == b,
                    _ => self.0.as_u64() == other.0.as_u64(),
                }
            }
            (true, true) => self.0.as_f64() == other.0.as_f64(),
            _ => false,
        }
    }
}

impl From<i64> for Num {
    fn from(v: i64) -> Self {
        Num::int(v)
    }
}

impl From<Number> for Num {
    fn from(v: Number) -> Self {
        Num(v)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn integer_and_float_shapes_are_distinct() {
        let i: Num = serde_json::from_str("2").unwrap();
        let f: Num = serde_json::from_str("2.0").unwrap();
        assert!(i.is_integer_shaped());
        assert!(!f.is_integer_shaped());
        assert_ne!(i, f);
        assert_eq!(serde_json::to_string(&i).unwrap(), "2");
        assert_eq!(serde_json::to_string(&f).unwrap(), "2.0");
    }

    #[test]
    fn negative_int_round_trips() {
        let n: Num = serde_json::from_str("-6").unwrap();
        assert_eq!(serde_json::to_string(&n).unwrap(), "-6");
        assert_eq!(n, Num::int(-6));
    }
}
