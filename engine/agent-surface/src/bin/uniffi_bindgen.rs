//! Standalone uniffi-bindgen helper (library mode): generates the Swift
//! bindings from the built dylib. Gated behind `ffi-bindgen` so default builds
//! keep exactly ONE bin (the CLI) - same packaging rule as the DJ core.
//!
//! Usage (from engine/):
//!   cargo run -p agent-surface --features ffi-bindgen --bin uniffi-bindgen -- \
//!     generate --library target/<triple>/release/libagent_surface.dylib \
//!     --language swift --out-dir <dir>

fn main() {
    uniffi::uniffi_bindgen_main()
}
