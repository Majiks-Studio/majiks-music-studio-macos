//! Crate error type. This type itself is pure (String payloads only, no
//! native-only fields), so it compiles under wasm32 even though most
//! variants are only ever constructed by `native`-gated code.

use thiserror::Error;

#[derive(Debug, Error)]
pub enum MediaError {
    #[error("io error: {0}")]
    Io(String),
    #[error("decode error: {0}")]
    Decode(String),
    #[error("loudness error: {0}")]
    Loudness(String),
    #[error("tile cache error: {0}")]
    TileCache(String),
}
