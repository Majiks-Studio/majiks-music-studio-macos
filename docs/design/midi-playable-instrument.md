# Playable MIDI instrument

Status: proposed implementation design for P-00122, Dev Lane H  
Branch: `feat/midi-instruments`  
Decision to build: approved by Aaron on 2026-07-24  
Scope gate: approve or amend this design before implementation

## Outcome and scope

A connected MIDI keyboard can be switched between its existing control-surface
role and an instrument role. In instrument mode, note-on and note-off events
drive a polyphonic built-in voice. An explicitly enabled live session can
monitor that voice. While an audio track is armed and the transport rolls, the
instrument bus can be captured and landed through the existing recording
take/clip path. The resulting human-performance audio clip then plays, mixes,
automates, bounces, and exports like every other timeline clip.

The first program deliberately does not add MIDI clips, a piano roll, external
MIDI output, Audio Unit hosting, or real-time agent improvisation. Those create
a second timeline media model and should be separate decisions after the
audio-recording workflow is proven.

## Decision: built-in synth first

Phase 1 uses a small deterministic synth, not a sampler.

- A synth proves note routing, polyphony, release behavior, monitoring, capture,
  and render-graph integration without asset loading, resampling, looping, or
  sample-root metadata.
- The initial voice is a band-limited-enough-for-v1 oscillator with selectable
  `sine`, `triangle`, and conservatively shaped `saw`, velocity-to-gain, and an
  attack/release envelope. The default is triangle.
- Pitch is equal temperament with A4 = 440 Hz:
  `frequency = 440 * 2^((note - 69) / 12)`.
- The engine owns a fixed pool of 32 voices. Note-on takes a free voice or
  steals the quietest oldest releasing voice. Note-off moves every matching
  channel/note voice into release. All-notes-off releases the pool.
- Phase 3 may add a sampler using the existing decoded-audio asset pipeline.
  A loaded sample will carry a root note and pitch ratio, but sample playback is
  not allowed to complicate the first real-time proof.

## Engine and real-time design

The instrument lives in `render`, beside `RenderCore`, because that is the only
place where live and offline signal behavior can share the engine's lock-free
discipline.

Control-side MIDI events become bounded render commands:

- `InstrumentNoteOn { channel, note, velocity }`
- `InstrumentNoteOff { channel, note }`
- `InstrumentAllNotesOff`
- `InstrumentSetPatch(InstrumentPatch)`, with the patch allocated and validated
  off the render thread
- `InstrumentCaptureStart(CaptureBuf)`, rotate, stop, and cancel in Phase 2

At block start, `RenderCore` drains the existing bounded command channel. Voice
state is fixed-size `Copy` data allocated when the core is built. Oscillator and
envelope processing performs no allocation, locking, logging, file I/O, or
channel send per sample. Retired heap-shaped patch/capture payloads use the
existing deferred-drop channel.

The synth produces one stereo `instrument_bus` frame. That frame enters a
dedicated strip before the existing sends/master stage, so it receives gain,
pan, EQ, send, metering, limiter, and master processing rather than bypassing
the graph. Phase 1 exposes a stable instrument-strip index outside the timeline
track array. Phase 2 binds it to the armed destination track's mixer parameters
while recording.

Instrument voices sound while the live engine is running even when timeline
transport is stopped. Timeline clip playback remains transport-gated. This is
required to audition a sound before recording.

## MIDI routing and control-surface coexistence

The current MIDI callback and pump remain the sole hardware input path. No
second CoreMIDI/midir stack is introduced.

Routing is per input port:

- `control`: current behavior; events resolve through the MIDI map.
- `instrument`: note-on/off go to the instrument; non-note controls may still
  resolve through the map.
- `both`: notes drive the instrument and continue through mapped note bindings.
  This is opt-in because a mapped key could otherwise both sound and mutate the
  project.

The default is `control`, preserving every existing map. Learn mode continues
to swallow the captured event before either destination. Note-on with velocity
zero is normalized to note-off. Channel and velocity are preserved.

Hardware callbacks remain limited to parse plus bounded `try_send`. Dispatch,
route lookup, host access, command journaling, and snapshot updates occur on
the MIDI pump/control side, never in the audio callback.

## Monitoring safety

There are three independent conditions for audible instrument monitoring:

1. A person explicitly opens the existing live session.
2. The journaled setting `instrument.monitor.set { enabled: true }` is active.
3. `MAJIKS_TEST_AUDIBLE=1` was present when the output stream was built.

If any condition is false, the device receives zeros. Enabling monitoring never
opens or restarts an output device. Opening a project, discovering a MIDI
device, selecting instrument mode, loading a patch, receiving a note, running a
test, or invoking an MCP tool never opens an output stream.

The environment gate is not exposed as a UI or agent mutation. Tests remove it
unless they are the named attended test. The snapshot reports `requested`,
`environmentAllowed`, `live`, and `audible` separately so the UI never claims
monitoring is audible when only one gate is set.

## Recording and landing

Phase 2 records only the dry instrument strip output, before master processing
and before timeline audio is added. Recording the master would bake the existing
mix into the new take and make overdubbing unusable.

`instrument.record.start` requires:

- an armed audio track,
- a running live session,
- a rolling transport, or an explicit start that rolls transport,
- no other instrument capture already active.

The render core writes the instrument bus into preallocated stereo capture
buffers. Buffer rotation and return use bounded channels; media preparation,
WAV writing, hashing, tile generation, and journal commits remain off the audio
thread. Stop/rotate retrieves the completed buffer through the live-audio
owner and calls the existing `land_capture`/`land_recorded_frames` tail with
source `midi-instrument`.

The landed object is audio, classified as a human recorded performance. It is a
candidate take with comping parity. Punch length, loop-pass rotation, trimming,
silence padding, content addressing, waveform tiles, undo, and take promotion
reuse the existing recording implementation. Playback requires no new path:
the placed audio clip compiles into `RtSession` and layers through the normal
render graph.

Raw MIDI events are not journal entries. They are a live data stream, like
input samples. The single landed `record.commit`-style mutation records the
performance asset and its provenance. This avoids an unbounded command journal
while retaining reproducible project state.

## Catalog commands and agent parity

Every persistent/configuration mutation is added to
`command-catalog.v1.1.json`, validated by `timeline-core`, hash-journaled, and
therefore generated as an MCP tool:

- `instrument.set`: waveform, output gain, attack, release, pitch reference,
  and polyphony within fixed engine limits.
- `instrument.monitor.set`: request monitoring on/off. It cannot defeat the
  environment or live-session gates.
- `midi.route.set`: port plus `control`, `instrument`, or `both`.
- `instrument.record.start`, `instrument.record.rotate`,
  `instrument.record.stop`, and `instrument.record.cancel`: session verbs that
  mirror `record.*`; the landed take/clip is the durable journaled mutation.
- `instrument.load`: reserved for the sampler phase, not accepted in phase 1.

Snapshot state exposes patch, route, voice count, monitor gates, and capture
state. Sterling and MCP can configure and record the instrument using the same
catalog path as the UI. Ephemeral hardware note events are intentionally not
MCP tools. A later agent performance feature should schedule a bounded musical
region, not stream network-timed note calls into the audio engine.

## FFI and Swift surface

This is not an FFI-free change.

- UniFFI adds typed `instrument_note_on`, `instrument_note_off`, and
  `instrument_all_notes_off` methods for an on-screen keyboard, deterministic
  integration tests, and future non-midir producers. Hardware MIDI continues
  directly from the Rust pump to the same host methods.
- The existing generic catalog submit method carries persistent commands.
- Snapshot JSON gains an `instrument` object, decoded into Swift instrument,
  monitoring, routing, and recording models.
- Generated Swift bindings and headers are regenerated and checked in with the
  Rust change. Mock engine behavior is updated at the same time.

No FFI method opens audio. The existing explicit live-session method remains
the only device-open boundary.

## Phases and gates

### Phase 1: sound source, routing, and attended monitoring

Implement the fixed voice pool, render commands, instrument strip, MIDI route,
catalog settings, snapshot, FFI, Swift mock/model controls, and monitoring
gates.

Gate:

- render allocation guard reports 0 allocations/frees on the voice path;
- command pressure reports 0 audio underruns and bounded dropped-note telemetry;
- 32-voice chord/release/steal tests are deterministic across block sizes;
- default route remains `control`, default monitoring remains silent;
- mock Swift build and tests exit 0;
- real-engine build exits 0;
- the only audible check is attended with controlled monitor level and
  `MAJIKS_TEST_AUDIBLE=1`.

### Phase 2: instrument audio capture and take landing

Add the dry instrument capture tap, rotate/stop retrieval, armed-track workflow,
exact punch fitting, loop comping, and landing through the existing recording
tail.

Gate:

- a deterministic note schedule records to a take and placed clip;
- offline playback of that clip nulls against the captured dry instrument audio
  within the existing bit-sane tolerance;
- playback with an existing timeline clip equals the expected sample sum before
  nonlinear master processing;
- punch length and loop comp siblings match recording-lane behavior;
- undo/replay and provenance classify the result as human performance;
- no device is opened in tests.

### Phase 3: sampler

Add `instrument.load`, root-note metadata, immutable decoded sample payloads,
bounded polyphonic sample voices, interpolation quality tests, missing-asset
behavior, and project recall. This phase follows, rather than blocks, the
play-record-layer proof.

### Follow-up decision: MIDI clips

Only after audio capture is accepted, decide whether editable MIDI clips earn a
new timeline content type. That program requires note persistence, scheduling,
clip editing, instrument state recall, provenance, export, and a piano-roll or
bounded repair UI. It is not part of P-00122's first playable instrument.

## Scope veto points

Aaron can amend these independently before implementation:

1. synth-first versus sampler-first;
2. 32 fixed voices and the initial waveform set;
3. per-port `control` / `instrument` / `both` routing;
4. dry instrument audio as the recorded source;
5. audio clips now, MIDI clips later;
6. typed FFI note injection in addition to the Rust hardware path.
