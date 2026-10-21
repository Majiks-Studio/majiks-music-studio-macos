//! blake3 content hashing for asset-registry identity on ingest (see
//! 02-ARCHITECTURE.md section 6: ".mstudio ... All asset references
//! content-hashed (blake3)"). This hashes the SOURCE FILE bytes, not the
//! decoded/resampled PCM: an asset's identity should not change if a
//! project later decodes it at a different target rate.

/// Hash of in-memory bytes. Pure; wasm32-safe.
pub fn hash_bytes(bytes: &[u8]) -> String {
    blake3::hash(bytes).to_hex().to_string()
}

/// Streaming hash of a source file's bytes; used on ingest. Native-only
/// (std::fs).
#[cfg(feature = "native")]
pub fn hash_file(path: &std::path::Path) -> Result<String, crate::MediaError> {
    use std::io::Read;
    let file = std::fs::File::open(path).map_err(|e| crate::MediaError::Io(format!("open {}: {e}", path.display())))?;
    let mut hasher = blake3::Hasher::new();
    let mut reader = std::io::BufReader::new(file);
    let mut buf = [0u8; 65536];
    loop {
        let n = reader.read(&mut buf).map_err(|e| crate::MediaError::Io(format!("hash {}: {e}", path.display())))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher.finalize().to_hex().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_bytes_is_stable_and_hex64() {
        let a = hash_bytes(b"majiks studio");
        let b = hash_bytes(b"majiks studio");
        assert_eq!(a, b);
        assert_eq!(a.len(), 64);
    }

    #[test]
    fn different_bytes_hash_differently() {
        assert_ne!(hash_bytes(b"a"), hash_bytes(b"b"));
    }
}
