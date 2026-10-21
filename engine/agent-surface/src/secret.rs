//! The MCP bearer PAT source. NEVER hardcoded, NEVER logged, NEVER echoed in a
//! tool result. The Swift app owns the Keychain (KeychainStore.swift) and hands
//! the value to `ffi_mcp_start`; the Rust side additionally accepts the token
//! from the environment for headless runs and tests. Generation is here so the
//! app can mint one on first enable.

const PAT_ENV: &str = "MAJIKS_STUDIO_MCP_PAT";

/// Read the PAT from the environment (headless / CI / dev). Returns None when
/// unset or blank; the caller then falls back to the Keychain value the app
/// passes in explicitly.
pub fn pat_from_env() -> Option<String> {
    std::env::var(PAT_ENV)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Mint a fresh opaque PAT (two ULIDs of entropy, `mms_` prefixed). The app
/// stores it in the Keychain; it is never written to disk by this crate.
pub fn generate_pat() -> String {
    format!("mms_{}{}", crate::ulid::new_ulid(), crate::ulid::new_ulid())
}

/// Redact a token for display (connection snippet, logs): first 4 chars then
/// dots. Used only when the UI has NOT explicitly revealed the token.
pub fn redact(token: &str) -> String {
    let head: String = token.chars().take(4).collect();
    format!("{head}\u{2022}\u{2022}\u{2022}\u{2022}")
}
