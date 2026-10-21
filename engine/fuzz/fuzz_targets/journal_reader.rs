#![no_main]

use libfuzzer_sys::fuzz_target;
use timeline_core::envelope::Envelope;

fuzz_target!(|input: &[u8]| {
    if let Ok(line) = std::str::from_utf8(input) {
        let _ = Envelope::from_line(line);
    }
});
