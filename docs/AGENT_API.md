# Majik's Music Studio: agent API guide

Majik's Music Studio exposes every DAW capability to agents over the same
command-bus model a person uses. Whether issued by a human clicking in the UI,
an agent calling an MCP tool, or a script hitting the API, each edit is the
same command. Every command is journaled to the project's append-only command
journal (the provenance log), and almost every command is undoable. Even
generation -- text2music, region revision, stem layering -- is itself a set of
commands that stage takes and then promote or discard them. The result: an agent
can build an arrangement from scratch, revise it, layer new parts, mix it, and
export with a full provenance trail, all through the same commands that drive
the DAW.

## The shape of a command

Every command is a JSON object with at minimum:

  - `command`: the dotted command name (e.g. `track.add`, `gen.song`).
  - `params`: a JSON object whose keys match that command's declared parameters.
  - `timestamp`: ISO-8601 millisecond-precision timestamp.

Commands that journal write a matching row to `journal.jsonl` inside the
`.mstudio` package. The journal is the undo/redo stack and the provenance
record. Non-journaled commands (transport, view-state toggles, lifecycle
actions like `project.new`) are still real commands but do not appear in the
journal.

The DAW also exposes a read surface that is not a command. These are queries
that return current state without mutating anything. They are listed here under
the names an agent actually calls -- this section previously invented a
parallel, dotted vocabulary (`project.snapshot`, `track.meters`, `takes.list`
and so on) that exists nowhere in the engine, so an agent following this guide
got `unknown tool` on its first read:

  - `studio_snapshot` -- full in-memory project state: tracks, clips, notes,
    instruments and their parameters, effect chains, the routing graph,
    automation lanes, transport (play/stop, position, loop region, metronome),
    undo/redo depth, and the input-device list. Takes an optional `sinceSeq` to
    return only what changed.
  - `studio_meters` -- per-track, per-bus and master peak/RMS, plus true peak,
    LUFS, limiter gain reduction and stereo correlation on the master, and
    per-channel input peak/RMS with a latched clip flag when an input is open.
    Meters are NOT part of the snapshot; this is a separate call.
  - `studio_capabilities` -- the closed vocabularies you have to choose from:
    instrument and effect kinds, their accepted parameter keys, the named
    instrument presets, and the node-ref/ParamRef addressing grammars.
  - `studio_takes` -- candidate takes for a clip or request.
  - `studio_lineage` -- per-clip provenance chain (gen.landed, take.promote,
    import.audio).
  - `studio_journal` -- paginated read of journal.jsonl entries.
  - `studio_manifest` -- the full provenance / AI-disclosure manifest for the
    current state, without writing a file.
  - `studio_waveform` -- peak-tile arrays for canvas drawing at a zoom bucket.
  - `studio_engine_stats` -- render engine health (callback underruns, p95
    latency).

## Command categories at a glance

Every command is documented in full in
[../engine/contracts/COMMAND-REFERENCE.md](../engine/contracts/COMMAND-REFERENCE.md),
and the machine-checked source is the catalog
[../engine/contracts/command-catalog.v2.json](../engine/contracts/command-catalog.v2.json).
The table below shows the top-level categories and their sizes as of catalog
**v2.0**. (This table described catalog v1.1 and 87 commands long after v2
landed; the v1.1 file is frozen and never edited again, so a guide pointing at
it was pointing at a superseded contract.)

| Category | Commands | Purpose |
|----------|----------|---------|
| project  | 11 | Create, open, save projects; set tempo, time signature, key, and the bar-grid phase anchor; manage section markers and timeline markers. |
| transport | 11 | Play, stop, seek, set loop region, toggle metronome; start, rotate, stop, cancel live-input recording; open an input for metering only. |
| midi    | 9 | Select device maps, set a port's role, control learn sessions, set and clear bindings, import and export maps, reload maps from disk. |
| track   | 16 | Add, remove, rename, reorder tracks; set color, height and input channel; mute, solo, arm; add and remove instrument devices, their key zones, and their parameters. |
| clip    | 20 | Place audio and MIDI clips, move, trim, split, duplicate, remove; set gain, mute, fade, crossfade, warp, phase anchor, rename; add, remove, move, resize, re-velocity and duplicate notes. |
| automation | 5 | Show/hide automation lanes; add, move, remove automation points; clear a lane. |
| mixer   | 13 | Set track gain, pan, EQ band, send levels; set master gain and master limiter; add, remove, reorder insert effects and set, clear and sidechain their parameters. |
| routing | 6 | Add and remove bus/group nodes, connect and disconnect edges, set an edge's level and tap, set a node's own mixer state. |
| gen     | 16 | Generate, revise, extend, layer, retake, autocomplete, cover, separate audio; cancel and finalize generation; promote, discard, purge, restore, audition takes. |
| io      | 7 | Import audio and stems; export master, stems, region; write provenance manifest; publish with certification. |
| txn     | 2 | Open and close atomic transaction brackets. |
| session | 1 | Import a Stem Sessions multitrack session. |

*Total: 117 commands.* The five transport-category record.* commands are the
live-input capture verbs and the nine midi.* commands are the unjournaled
transport-class MIDI control-surface verbs. One of the gen commands,
`gen.landed`, is written by the engine when an async generation completes and is
not agent-invocable, so 116 commands map to MCP tools. See
COMMAND-REFERENCE.md for every command's parameters, journaling status,
undoability, and inverse.

As MCP tools, these commands are exposed with a `studio_` prefix and dots folded
to underscores (`project.setTempo` becomes `studio_project_set_tempo`). The full
tool registry (all 146 tools, including the read, revise-workflow, Gen Protocol
proxy, landing, take-maintenance and session tools that are not catalog
commands) is documented in
[MCP_API.md](MCP_API.md) and generated into
[../engine/docs/generated/mcp-tools.v1.json](../engine/docs/generated/mcp-tools.v1.json).

## Generating and editing audio

Generation is ten operations defined in
[../engine/contracts/gen-protocol.v1.yaml](../engine/contracts/gen-protocol.v1.yaml).
Every op runs asynchronously: the engine accepts a request, returns a job ID,
and later writes a `gen.landed` journal entry with the resulting take and its
provenance (asset hashes, engine identity, latency).

The ten ops are `generate` (text2music, backs `gen.song`), `revise` (region
repaint with an instruction delta, backs `gen.revise`), `extend` (continue
audio from where a clip ends, backs `gen.extend`), `layer` (generate a new
stem that fits existing context audio, backs `gen.layer`), `retake`
(fresh-seed variation of an existing take, same prompt, backs `gen.retake`),
`autocomplete` (fill in missing instruments, flag v1.1, backs
`gen.autocomplete`), `cover` (style-transfer from a reference clip, flag v1.1,
backs `gen.cover`), `separate` (stem separation via demucs or ACE-Step
generative extraction, backs `gen.separate`), `analyze` (measure bpm, key,
downbeats, duration, and loudness; used by the Open in Studio landing rather
than a `gen.*` command), and `finalize` (re-render a committed draft take at
full quality, backs `gen.finalize`). An agent can poll job state via `getJob`,
cancel via `cancelJob`, and discover available routes and models via
`getCapabilities`.

The key pattern for agents: the `revise` op is how you select a region on a
clip, describe the change you want (e.g. "make the intro build more gradually
over 8 bars"), and get back alternative takes. You can also scope the revision
to individual stems (`all-stems`, `vocals`, `drums`, `bass`, `other`). Each
revision or generation produces one or more takes that you then `take.promote`
(commit into the timeline) or `take.discard`. The gen op itself is not undoable;
the `take.promote` that lands the result is.

## Recording live input

An agent can capture live audio, not only generate it. The flow mirrors the UI:

1. `track.arm(trackId, armed=true)` -- arm the capture target. Arming is
   journaled and undoable.
2. `record.start(trackId, deviceId?, startTicks?, punchOutTicks?)` -- open an
   input-only capture onto the armed track. `deviceId` picks an input device
   (system default when omitted). The result reports `captureOriginTicks` and
   `rolling`; while rolling, an omitted `startTicks` uses the live playhead and
   a supplied value is reported in `ignoredParams` unless it is a punch-in.
   `punchOutTicks`, when set, bounds the capture to a punch region.
3. For loop recording, `record.rotate` completes the current pass without
   closing the input stream. The next pass captures immediately while media
   preparation for the completed pass runs asynchronously. Every pass is
   resampled to the project's rate when the input device differs (same as
   `record.stop`); the response reports `deviceSampleRate`, `landedSampleRate`,
   `projectSampleRate` and `resampled` so a caller can confirm a pass landed
   clean.
4. `record.stop` -- stop the capture and land it as a candidate take plus a
   placed clip. The landing is journaled through a transaction as a human-origin
   take (`sourceCommand` `record.commit`), so the provenance layer classifies it
   as human, not AI. `record.cancel` instead discards the capture with nothing
   landed.

Two behaviors matter for agents. With `punchOutTicks` set, the landed clip is
exactly `punchOutTicks - startTicks` long: the capture is trimmed or
silence-padded to fit the punch region. And repeated captures over the SAME
(track, start, punch-out) region stack as take-only comp takes under one
request, filling a take lane to audition and promote, rather than placing a new
clip each pass.

The record.start / record.rotate / record.stop / record.cancel commands are unjournaled
transport-class actions; the take and clip that `record.stop` lands are the
journaled, undoable unit. Capture is input-only and never opens an output
stream, so monitoring stays silent.

## Walkthrough: build an arrangement end to end

The sequence below proves an agent can drive the DAW from an empty project to a
finished export with full provenance. Each step names the exact command or gen
op from the sources.

1. `project.new("my-track")` -- Create a new .mstudio package with an empty
   timeline and the default project structure.

2. `project.setTempo(bpm=128)` -- Set the global tempo to 128 BPM.

3. `project.setTimeSig(numerator=4, denominator=4)` -- Set 4/4 time signature.

4. `project.setKey(key="C minor")` -- Set the key and scale metadata.

5. `gen.song(requestId, trackId, insertAtTicks=0, request={caption: "dark
   electronic intro with a steady kick and atmospheric pads"})` -- Request a
   text2music generation on the default track. The engine returns a job ID and
   later writes a `gen.landed` entry with the take.

6. `take.promote(takeId, targetClipId)` -- Commit the generated song into the
   timeline as a clip. This is the undoable step.

7. `gen.revise(requestId, clipId, regionStartTicks, regionEndTicks,
   scope="all-stems", request={instruction: "make the intro build more
   gradually over 8 bars"})` -- Select the intro region of the clip and
   request a repaint with an instruction delta. The engine produces a new take.

8. `take.promote(takeId, targetClipId)` -- Commit the revised intro take,
   splicing it into the existing clip.

9. `gen.layer(requestId, targetTrackId, instruction="add a soaring synth
   lead", request, contextClipId)` -- Generate a new stem (synth lead) that
   fits the existing arrangement harmonically and rhythmically (lego mode).

10. `take.promote(takeId, targetClipId)` -- Commit the layer onto its own
    track as a new clip.

11. `track.add(trackId, name="Bass")` -- Add a fresh track to hold an
    imported bass loop.

12. `import.audio(sourcePath, targetTrackId, separate=true)` -- Import an
    external audio file, copy it content-addressed into the project, and run
    htdemucs stem separation on import placing the stems on individual tracks.

13. `mix.gain(trackId, gainDb=-3.0)` -- Set the imported track's mixer channel
    gain to -3 dB to balance levels.

14. `mix.pan(trackId, pan=0.3)` -- Pan the track slightly to the right.

15. `mix.master.gain(gainDb=-1.5)` -- Lower the master bus gain by 1.5 dB for
    headroom before export.

16. `export.master(outputPath="my-track-master.wav", format="wav",
    sampleRateHz=44100)` -- Bounce the full master mix to a 44.1 kHz WAV file
    via the render graph's offline path.

17. `export.manifest(outputPath="my-track-provenance.json")` -- Write the
    provenance manifest, a rebuildable view over the journal that records
    every command and generation that produced the export.

## Safety and parity

Every command in the reference is available to agents as an MCP tool or an API
endpoint. There is no hidden DAW capability that only the human UI can reach,
with one deliberate exception: OPENING AN AUDIO DEVICE. Starting a live audio
session and enabling audible output are FFI-only (`start_live`,
`set_audible_output`), because a tool that can make a machine's speakers play is
not something an agent should be able to reach across a network socket. An agent
can set and read every transport state, and `snapshot.transport.live` says
whether a live engine is behind it; what it cannot do is be the one that starts
the sound. Offline bounce and export are fully agent-drivable, so nothing about
producing a finished record depends on that exception.

Agents operate within a tiered permission model. The exact tier of every tool
is in [MCP_API.md](MCP_API.md); the shape is:

  - **Read tier:** The read tools (`studio_snapshot`, `studio_journal`,
    `studio_engine_stats`, `studio_meters`, `studio_capabilities`,
    `studio_manifest`, `studio_waveform`, `studio_takes`, `studio_lineage`),
    plus `studio_audition`. Never mutate; safe to call freely. Transport state
    comes back inside the snapshot; METERS DO NOT -- this section used to say
    they did, and they were not on the agent surface at all.

  - **Perform tier:** Commands that mutate the project. The journal ensures
    every mutation is recorded and undoable. Write tools are rate limited to
    one call per 10 ms; reads are not.

  - **Manage tier (confirm required):** Actions that delete content or write
    outside the project: `track.remove`, `clip.remove`, `take.purge`, the four
    `export.*` commands, and `publish.track` (plus the host take-purge
    maintenance tool). These will not run unless the call carries
    `confirm: true`. Note that `project.new`, `project.open`, and
    `studio.importStemSession` are ordinary Perform-tier commands, not Manage.

The design intent is parity: an agent can do anything a human can, at the same
granularity, through the same commands, with the same journaling and undo
guarantees. The tier model exists so hosts can grant capability incrementally.
