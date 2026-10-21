# Gapless loop-record evidence

Branch: `feat/gapless-loop-record`

## Result

- `LiveInput::rotate()` drains and swaps the owner-thread accumulator without stopping the CPAL input stream. The real-time callback remains limited to ring writes.
- `record.rotate` queues completed passes for ordered background preparation while the next pass continues capturing.
- Prepared passes retain the atomic `txn.begin` to `gen.landed` to `clip.place` to `txn.commit` tail, with `abort_txn` on failure.
- Every pass is fitted to the punch range before landing. Loop passes share one comp request and land as take-only siblings.
- A virtual continuous-input test verifies two exact passes with no dropped, duplicated, or missing boundary frames. A failure test verifies that aborting one landing does not stop capture or wedge the comp session or undo.

## Verification

- `cargo test -p agent-surface -p timeline-core`: passed.
- `MAJIKS_ENGINE=mock swift build`: passed.
- `MAJIKS_ENGINE=mock swift test --filter StudioRecordingTests`: 11 tests passed.
- `cargo check -p agent-surface --features ffi`: passed.
- ARM64 XCFramework generation: passed.
- `MAJIKS_ENGINE=real swift build`: passed.
- Real Xcode Debug and Release builds: passed.
- Generated UniFFI sources are unchanged.

The fresh real artifacts contained 731 to 739 symbols matching `agent_surface`, depending on Release or Debug linkage, rather than the expected 660. The generated UniFFI bindings are byte-identical, so this branch does not add or remove the exported bindings.

## Safety

No application or hardware capture was launched. No output stream was added or opened, and `MAJIKS_TEST_AUDIBLE` was never set.
