# Majik's Music Studio: MCP tool reference

This is the reference for the Studio's MCP tool registry: the exact set of tools
an agent can call to drive the DAW. It is the tool-name companion to the
conceptual guide in [AGENT_API.md](AGENT_API.md) and the command-level reference
in [../engine/contracts/COMMAND-REFERENCE.md](../engine/contracts/COMMAND-REFERENCE.md).

Every tool listed here is generated into, and checked against,
[../engine/docs/generated/mcp-tools.v1.json](../engine/docs/generated/mcp-tools.v1.json).
That file is the source of truth. The registry test in the engine
(`agent-surface/tests/parity.rs`) fails the build if the committed JSON and the
generated tool set ever disagree, and if any catalog command lacks a tool
without a documented exclusion. If a name is not in that JSON, it is not a real
tool.

- Catalog version: **2.0**
- Tool count: **146**
- Excluded command (has no tool): **`gen.landed`** (written by the engine itself
  when an async generation completes; not agent-invocable).

The 116 command tools are one-per-catalog-command, with their input schema taken
verbatim from the catalog's `paramsSchema`. The other 30 tools are the host
surface: read tools, the revise/extend/layer workflow, the Gen Protocol proxy,
undo/redo, the metronome/note-preview/retro-capture session tools, the landing
bridge, and take maintenance.

## Connecting

The Studio ships one MCP server, owned by the engine. It is an `rmcp`
localhost streamable-HTTP server:

- Host and port: `127.0.0.1:8478` by default (chosen distinct from Majik's DJ's
  8471 so both can run at once). The port is configurable.
- Path: `/mcp`. A `GET /health` route returns `ok` and is the only route that
  does not require the token.
- Auth: a bearer personal access token (PAT). Every request except `/health`
  must send `Authorization: Bearer <token>`.
- Off by default, and it fails closed: it refuses to start unless it is enabled
  and a non-empty PAT is present, and it binds `127.0.0.1` only.

There are two ways to turn it on, and both take the same path through the host
(`src/swift/Sources/StudioMCPServer.swift`) into the engine's
`mcp_start` FFI export.

### Settings ▸ MCP / API (the normal way)

Open Settings and pick the **MCP / API** tab. Turn the server on, and the app
mints a PAT into your login Keychain, starts the server, and shows a live
health indicator (it really calls `GET /health`, so a server that failed to
bind cannot show as running). **Copy connection line** puts the ready-to-paste
`claude mcp add` command on the clipboard. The token is masked in the UI until
you explicitly reveal it, and is never written to the log on this path.

The toggle is persisted, so an enabled server comes back up on the next launch.

### `--studio-mcp-pat` (the headless / scripted way)

Launch the packaged app with the token argument:

```
--studio-mcp-pat <TOKEN> [--studio-mcp-port <N>]
```

With no `--studio-mcp-pat`, no server starts. Launch arguments take precedence
over the Settings toggle and are not written to the Keychain — they are scoped
to that run. Because the operator already put the token on the command line
(where `ps` can see it), the app logs the full, paste-ready connection line on
this path:

```
claude mcp add majiks-studio --transport http --url http://127.0.0.1:8478/mcp --header "Authorization: Bearer <TOKEN>"
```

Either way the server is started from `applicationDidFinishLaunching`, so it is
reachable as soon as the app is up — you do not have to open the Studio tab
first. Starting it does bring the engine (and the active `.mstudio` project) up
at launch; when MCP is off, the engine stays lazy exactly as before.

### Rate limit

Write tools (Perform and Manage tier) are rate limited to one call per 10 ms.
Read tools are not limited. Exceeding the limit returns a rate-limit error you
can retry.

## Tiers

Every tool has a tier. It is the coarse permission model a host uses to grant
capability step by step.

| Tier | Count | What it means |
|------|-------|---------------|
| `read` | 10 | Never mutates the project. Safe to call freely. |
| `perform` | 126 | Mutates the project through the command bus. Journaled and (almost always) undoable. |
| `manage` | 10 | Deletes content, or writes/publishes outside the project. Requires `confirm: true` in the arguments. |

The `read`-tier count includes the nine read tools plus `studio_audition`, which
only sets up an audition loop and does not mutate.

### The confirm gate

Ten tools are Manage tier and will not run unless you pass `confirm: true`:

`studio_track_remove`, `studio_clip_remove`, `studio_take_purge`,
`studio_purge_takes`, `studio_export_master`, `studio_export_stems`,
`studio_export_region`, `studio_export_manifest`, `studio_publish_track`,
`studio_midi_map_export`.

The `confirm` field is part of each of these tools' input schema. The dispatcher
checks it and strips it before the call reaches the command bus.

## How a call is handled

A tool call goes through one choke point, whether it comes from an external MCP
client, the in-app Sterling copilot, or the FFI: validate arguments against the
tool's schema, apply the tier confirm gate, apply the write rate limit, then
route to the host. Command tools submit their catalog command to the command
bus; the result is journaled. This is agent parity by construction: there is no
capability the human UI has that these tools do not.

An unknown tool name is a protocol error. A known tool that runs and fails (bad
params, a missing confirm, a bus rejection) returns a readable error result you
can reason about and adapt to, not a crash.

## Read tools

Never mutate. All are `read` tier.

| Tool | Purpose | Example arguments |
|------|---------|-------------------|
| `studio_snapshot` | Full current project state, or a change delta when `sinceSeq` is given. | `{}` or `{"sinceSeq": 42}` |
| `studio_journal` | A page of hash-chained journal (provenance) entries after `afterId`. | `{"limit": 100}` |
| `studio_engine_stats` | Render engine health: underruns and callback p95. | `{}` |
| `studio_meters` | Current levels: per-track, per-bus/group node, master (true peak, LUFS, limiter gain reduction, stereo correlation), and per-channel input peak/RMS with a latched clip flag when an input is open. Says `live: false` and reports an honest -120 dB floor when no live session is running. | `{}` |
| `studio_capabilities` | The closed vocabularies: instrument and effect kinds, the parameter keys `device.param.set` / `fx.param.set` accept, the named instrument presets (with the exact values each one is), the node-ref and ParamRef grammars, export formats, loudness targets, separators. Static; answers before a project is open. | `{}` |
| `studio_manifest` | The full provenance / AI-disclosure manifest for the current state, byte-identical to what `export.manifest` writes, without writing a file. | `{}` |
| `studio_waveform` | Capped peak-tile array for a clip's window at a zoom bucket. Never returns raw audio. | `{"clipId": "c1", "zoom": 6}` |
| `studio_takes` | Generative takes for the Takes browser, each with its kind and joined lineage. Filter by `clipId`, `requestId`, `kind`, `auditionableOnly`, `includePurged`. | `{"clipId": "c1", "auditionableOnly": true}` |
| `studio_lineage` | Per-clip provenance chain: the journal entries that produced this clip's current audio. | `{"clipId": "c1"}` |

Note: transport state (playing, position, loop region, metronome, whether a live
engine is running, whether an input is open) comes back inside
`studio_snapshot`, not as a separate tool.

This note used to claim "the command catalog's read surface also defines
`track.meters` and `transport.state`". It defines neither -- the catalog has no
read commands at all, its 117 entries are all mutations plus the unjournaled
transport/midi/lifecycle verbs -- and meters did not come back inside the
snapshot either. Levels were computed by the host and reachable only over the
FFI, so they were a capability the human half of the app could see and an agent
could not. `studio_meters` is that surface.

## Project, sections, and markers

`project.*` shapes the project. `project.new`, `project.open`, and
`project.save` are lifecycle (not journaled); the rest are journaled and
undoable. All are `perform` tier.

| Tool | Command | Purpose | Example arguments |
|------|---------|---------|-------------------|
| `studio_project_new` | `project.new` | Create a new `.mstudio` package with an empty timeline. | `{"name": "My Track"}` |
| `studio_project_open` | `project.open` | Open an existing `.mstudio` package (checkpoint plus journal replay). | `{"path": "/Music/My Track.mstudio"}` |
| `studio_project_save` | `project.save` | Write `project.json` as a checkpoint of the current journal tip. | `{}` |
| `studio_project_set_tempo` | `project.setTempo` | Set the global tempo in BPM (v1 has one tempo for the whole project). | `{"bpm": 128}` |
| `studio_project_set_time_sig` | `project.setTimeSig` | Set the global time signature. | `{"numerator": 4, "denominator": 4}` |
| `studio_project_set_key` | `project.setKey` | Set the key/scale metadata (informational in v1). | `{"key": "C minor"}` |
| `studio_section_set` | `section.set` | Create or update a named arrangement section marker. | `{"sectionId": "s1", "name": "Chorus", "startTicks": 30720}` |
| `studio_section_remove` | `section.remove` | Remove an arrangement section marker. | `{"sectionId": "s1"}` |
| `studio_marker_set` | `marker.set` | Create or update a timeline marker. | `{"markerId": "m1", "positionTicks": 3840, "label": "drop"}` |
| `studio_marker_remove` | `marker.remove` | Remove a timeline marker. | `{"markerId": "m1"}` |

## Transport

Real commands on the bus, but unjournaled (they never appear in the journal).
All `perform` tier.

| Tool | Command | Purpose | Example arguments |
|------|---------|---------|-------------------|
| `studio_transport_play` | `transport.play` | Start playback from the current position. | `{}` |
| `studio_transport_stop` | `transport.stop` | Stop playback. | `{}` |
| `studio_transport_seek` | `transport.seek` | Move the playhead to an absolute tick position. | `{"positionTicks": 7680}` |
| `studio_transport_loop_set` | `transport.loop.set` | Set the loop region. | `{"startTicks": 0, "endTicks": 15360}` |
| `studio_transport_loop_clear` | `transport.loop.clear` | Clear the loop region. | `{}` |
| `studio_transport_metronome` | `transport.metronome` | Toggle the metronome click. | `{"enabled": true}` |

## Recording

Live input capture (L19). Real commands on the bus, but unjournaled, like
transport: the take and clip that `record.stop` lands are the journaled,
undoable unit. Capture is input-only and never opens an output stream, so
monitoring stays silent. All `perform` tier. Arm the capture target first with
`studio_track_arm`.

| Tool | Command | Purpose | Example arguments |
|------|---------|---------|-------------------|
| `studio_record_start` | `record.start` | Open an input-only capture onto an armed track. `deviceId` picks an input (system default when omitted); `startTicks` is where the clip lands (bar-snapped; defaults to the transport position); `punchOutTicks`, when set, bounds the capture to a punch region and auto-stops it there. | `{"trackId": "t1", "deviceId": "Scarlett 2i2", "startTicks": 30720, "punchOutTicks": 46080}` |
| `studio_record_rotate` | `record.rotate` | Complete a loop pass without closing the input stream. The next pass captures immediately while the completed pass prepares asynchronously for an atomic landing. | `{}` |
| `studio_record_stop` | `record.stop` | Stop the active capture and land it as a candidate take plus a placed clip with human-origin lineage (`sourceCommand` `record.commit`). No-op when nothing is recording. | `{}` |
| `studio_record_cancel` | `record.cancel` | Discard the active capture without landing a take or clip. No-op when nothing is recording. | `{}` |

## Tracks

Journaled and undoable. All `perform` tier except `studio_track_remove`, which
is `manage`.

| Tool | Command | Tier | Purpose | Example arguments |
|------|---------|------|---------|-------------------|
| `studio_track_add` | `track.add` | perform | Add a new track (`index` optional; append if omitted). | `{"trackId": "t1", "name": "Bass"}` |
| `studio_track_remove` | `track.remove` | manage | Remove a track and every clip on it. | `{"trackId": "t1", "confirm": true}` |
| `studio_track_rename` | `track.rename` | perform | Rename a track. | `{"trackId": "t1", "name": "Sub Bass"}` |
| `studio_track_reorder` | `track.reorder` | perform | Move a track to a new position. | `{"trackId": "t1", "newIndex": 0}` |
| `studio_track_set_color` | `track.setColor` | perform | Set a track's display color. | `{"trackId": "t1", "color": "#8A5CF6"}` |
| `studio_track_set_height` | `track.setHeight` | perform | Set a track's lane height. | `{"trackId": "t1", "heightPx": 96}` |
| `studio_track_mute` | `track.mute` | perform | Mute or unmute a track. | `{"trackId": "t1", "muted": true}` |
| `studio_track_solo` | `track.solo` | perform | Solo or unsolo a track. | `{"trackId": "t1", "soloed": true}` |
| `studio_track_arm` | `track.arm` | perform | Arm or disarm a track for recording. | `{"trackId": "t1", "armed": true}` |

## Clips

Journaled and undoable. All `perform` tier except `studio_clip_remove`, which is
`manage`.

| Tool | Command | Tier | Purpose | Example arguments |
|------|---------|------|---------|-------------------|
| `studio_clip_place` | `clip.place` | perform | Place a content-addressed audio asset as a clip on a track. | `{"clipId": "c1", "trackId": "t1", "assetHash": "b3:...", "startTicks": 0, "lengthTicks": 15360}` |
| `studio_clip_move` | `clip.move` | perform | Move a clip to a new start, optionally onto another track. | `{"clipId": "c1", "trackId": "t1", "startTicks": 3840}` |
| `studio_clip_trim` | `clip.trim` | perform | Trim a clip's start or end edge. | `{"clipId": "c1", "edge": "end", "deltaTicks": -960}` |
| `studio_clip_split` | `clip.split` | perform | Split a clip into two at a tick position. | `{"clipId": "c1", "atTicks": 7680, "newClipId": "c1b"}` |
| `studio_clip_duplicate` | `clip.duplicate` | perform | Duplicate a clip onto the same or another track. | `{"clipId": "c1", "newClipId": "c2", "startTicks": 15360}` |
| `studio_clip_remove` | `clip.remove` | manage | Remove a clip (the audio asset is not deleted). | `{"clipId": "c1", "confirm": true}` |
| `studio_clip_set_gain` | `clip.setGain` | perform | Set a clip's gain trim (independent of the mixer). | `{"clipId": "c1", "gainDb": -3.0}` |
| `studio_clip_mute` | `clip.mute` | perform | Mute or unmute an individual clip. | `{"clipId": "c1", "muted": true}` |
| `studio_clip_fade_set` | `clip.fade.set` | perform | Set a clip's fade-in or fade-out. | `{"clipId": "c1", "edge": "in", "lengthTicks": 480, "shape": "equalPower"}` |
| `studio_clip_crossfade_set` | `clip.crossfade.set` | perform | Set a crossfade between two adjacent clips on a track. | `{"clipIdA": "c1", "clipIdB": "c2", "lengthTicks": 960}` |
| `studio_clip_warp_set` | `clip.warp.set` | perform | Set a clip's time-warp (fixed ratio, or conform to tempo). | `{"clipId": "c1", "mode": "conform"}` |
| `studio_clip_phase_anchor_set` | `clip.phaseAnchor.set` | perform | Set the timeline phase anchor for a warped clip locked to the grid. | `{"clipId": "c1", "anchorTicks": 3840}` |
| `studio_clip_rename` | `clip.rename` | perform | Rename a clip's display label. | `{"clipId": "c1", "name": "Verse bed"}` |

## Automation

Volume and pan automation lanes. `autolane.show` is a UI-state toggle
(unjournaled); the point edits are journaled and undoable. All `perform` tier.

| Tool | Command | Purpose | Example arguments |
|------|---------|---------|-------------------|
| `studio_autolane_show` | `autolane.show` | Show or hide an automation lane. | `{"trackId": "t1", "target": "volume", "visible": true}` |
| `studio_autopoint_add` | `autopoint.add` | Add an automation point (targets: `volume`, `pan`). | `{"trackId": "t1", "target": "volume", "pointId": "p1", "positionTicks": 3840, "value": -6.0}` |
| `studio_autopoint_move` | `autopoint.move` | Move an automation point to a new position/value. | `{"trackId": "t1", "target": "volume", "pointId": "p1", "positionTicks": 4800, "value": -3.0}` |
| `studio_autopoint_remove` | `autopoint.remove` | Remove an automation point. | `{"trackId": "t1", "target": "volume", "pointId": "p1"}` |
| `studio_autolane_clear` | `autolane.clear` | Remove every point on a lane (undo restores the full set). | `{"trackId": "t1", "target": "pan"}` |

## Mixer

Journaled and undoable. All `perform` tier.

| Tool | Command | Purpose | Example arguments |
|------|---------|---------|-------------------|
| `studio_mix_gain` | `mix.gain` | Set a track's channel gain. | `{"trackId": "t1", "gainDb": -6.0}` |
| `studio_mix_pan` | `mix.pan` | Set a track's pan (-1 left to 1 right). | `{"trackId": "t1", "pan": 0.3}` |
| `studio_mix_eq` | `mix.eq` | Set one EQ band on a track. | `{"trackId": "t1", "band": "high", "freqHz": 8000, "gainDb": 2.0}` |
| `studio_mix_send` | `mix.send` | Set a track's send level to bus A or B. | `{"trackId": "t1", "bus": "a", "amount": 0.25}` |
| `studio_mix_master_gain` | `mix.master.gain` | Set the master bus gain. | `{"gainDb": -1.5}` |
| `studio_mix_limiter_set` | `mix.limiter.set` | Enable/configure the master limiter. | `{"enabled": true, "ceilingDb": -1.0}` |

## Generation

Each `gen.*` command starts an asynchronous generation and stages the result as
a take. The command journals, but the request itself is not undoable; the
`take.promote` that lands the result is. All `perform` tier. The Gen Protocol op
each one runs is named in its catalog description.

| Tool | Command | Purpose | Example arguments |
|------|---------|---------|-------------------|
| `studio_gen_song` | `gen.song` | New text2music generation staged as a take (op: generate). | `{"requestId": "r1", "trackId": "t1", "insertAtTicks": 0, "request": {"caption": "dark synthwave, steady kick"}}` |
| `studio_gen_revise` | `gen.revise` | Region repaint with an instruction delta (op: revise). | `{"requestId": "r2", "clipId": "c1", "regionStartTicks": 0, "regionEndTicks": 15360, "scope": "all-stems", "request": {"instruction": "build the intro gradually"}}` |
| `studio_gen_extend` | `gen.extend` | Continue a clip's audio by `addedDurationSeconds` (op: extend). | `{"requestId": "r3", "clipId": "c1", "addedDurationSeconds": 8.0, "request": {}}` |
| `studio_gen_layer` | `gen.layer` | New stem that fits existing context audio, lego mode (op: layer). | `{"requestId": "r4", "targetTrackId": "t2", "instruction": "warm analog bass", "request": {}}` |
| `studio_gen_retake` | `gen.retake` | Fresh-seed variation of an existing take, same prompt (op: retake). | `{"requestId": "r5", "sourceTakeId": "tk1", "request": {}}` |
| `studio_gen_autocomplete` | `gen.autocomplete` | Fill in missing instruments around a partial mix (op: autocomplete; flag v1.1). | `{"requestId": "r6", "clipId": "c1", "request": {}}` |
| `studio_gen_cover` | `gen.cover` | Style-transfer cover from a reference clip (op: cover; flag v1.1). | `{"requestId": "r7", "referenceClipId": "c1", "request": {}}` |
| `studio_gen_separate` | `gen.separate` | Stem separation of a clip (op: separate). | `{"requestId": "r8", "clipId": "c1", "engine": "htdemucs"}` |
| `studio_gen_cancel` | `gen.cancel` | Cancel an in-flight gen request. | `{"requestId": "r2"}` |
| `studio_gen_finalize` | `gen.finalize` | Re-render a committed draft take at full quality and splice it in (op: finalize). | `{"requestId": "r9", "draftTakeId": "tk1", "targetQualityRung": "full", "request": {}}` |

The `gen.cancel` command has a known v1 backend gap: the current Python backend's
cancel is a single global flag, not per-request. The per-`requestId` cancel is
the target contract.

## Takes

Manage the staged variants. `take.promote`, `take.discard`, `take.restore`, and
`take.auditionMix` are `perform`; `take.purge` is `manage`.

| Tool | Command | Tier | Purpose | Example arguments |
|------|---------|------|---------|-------------------|
| `studio_take_promote` | `take.promote` | perform | Commit a generated take into the timeline (the undoable landing step). | `{"takeId": "tk1", "targetClipId": "c1"}` |
| `studio_take_discard` | `take.discard` | perform | Drop a take from the active candidate list (stays reversible until purged). | `{"takeId": "tk1"}` |
| `studio_take_purge` | `take.purge` | manage | Mark an un-promoted take offline so its audio may be reclaimed. | `{"takeId": "tk1", "confirm": true}` |
| `studio_take_restore` | `take.restore` | perform | Restore an offline take's journal state after undoing a purge. | `{"takeId": "tk1"}` |
| `studio_take_audition_mix` | `take.auditionMix` | perform | Choose which stems of a per-stem take are audible while auditioning. | `{"takeId": "tk1", "stems": ["drums", "bass"]}` |

## Import, export, publish

`import.*` are `perform`. All `export.*` and `publish.track` are `manage` and
need `confirm: true`.

| Tool | Command | Tier | Purpose | Example arguments |
|------|---------|------|---------|-------------------|
| `studio_import_audio` | `import.audio` | perform | Import an audio file, copy it content-addressed, and place it as a clip. Optional `separate`, `conform`, and placement hints `clipId`/`startTicks`. | `{"sourcePath": "/Music/loop.wav", "targetTrackId": "t1", "separate": false}` |
| `studio_import_stems` | `import.stems` | perform | Import a directory of stems as aligned tracks. | `{"sourceDir": "/Music/stems", "targetTrackId": "t1"}` |
| `studio_export_master` | `export.master` | manage | Bounce the full master mix through the offline render path. WAV is 24-bit; AAC via AudioToolbox. | `{"outputPath": "/Music/track.wav", "format": "wav", "loudnessTarget": "streaming", "includeManifest": true, "confirm": true}` |
| `studio_export_stems` | `export.stems` | manage | Bounce per-track stems (24-bit WAV, not loudness-normalized). | `{"outputDir": "/Music/track-stems", "format": "wav", "includeManifest": true, "confirm": true}` |
| `studio_export_region` | `export.region` | manage | Bounce a time region of the master. | `{"outputPath": "/Music/hook.wav", "startTicks": 0, "endTicks": 15360, "format": "wav", "confirm": true}` |
| `studio_export_manifest` | `export.manifest` | manage | Write the provenance manifest to a standalone file. | `{"outputPath": "/Music/track.manifest.json", "confirm": true}` |
| `studio_publish_track` | `publish.track` | manage | Publish an exported asset with a provenance cert via the majiks.online path. | `{"assetHash": "b3:...", "title": "My Track", "confirm": true}` |

## Transactions

Group journaled commands into a single undo unit. Both `perform` tier. v1
transactions do not nest.

| Tool | Command | Purpose | Example arguments |
|------|---------|---------|-------------------|
| `studio_txn_begin` | `txn.begin` | Open an atomic transaction. | `{"txnId": "x1", "reason": "build the chorus"}` |
| `studio_txn_commit` | `txn.commit` | Close the transaction opened with the same `txnId`. | `{"txnId": "x1"}` |

## Stem session import

| Tool | Command | Tier | Purpose | Example arguments |
|------|---------|------|---------|-------------------|
| `studio_studio_import_stem_session` | `studio.importStemSession` | perform | Bring an existing Stem Sessions multitrack onto the Studio timeline (flag v1.1). | `{"stemSessionId": "ss1"}` |

## Undo and redo

Not catalog commands. Both `perform` tier. Undo and redo append forward; the
journal history never rewrites.

| Tool | Purpose | Example arguments |
|------|---------|-------------------|
| `studio_undo` | Undo the most recent undo unit. | `{}` |
| `studio_redo` | Redo the most recently undone unit. | `{}` |

## Playing an instrument

Neither of these is a catalog command. Both `perform` tier.

| Tool | Purpose | Example arguments |
|------|---------|-------------------|
| `studio_note_preview` | Sound one note on a track's instrument right now, outside the timeline. | `{"pitch": 60, "velocity": 100, "gate": "on"}` |
| `studio_performance_keep` | Keep what was just played: land the retro-capture buffer as real notes. | `{}` |

`studio_note_preview` is feedback, not an edit: the note itself is never
journaled, undoable, or replayed. `trackId` is optional — omit it to play the
project's instrument (the armed one, else the first). If the project has no
instrument yet, ONE is created, and *that* creation is journaled as a single
undoable step, because an empty project has to be playable.

**Audio safety.** The device is opened by a played note only on a host whose GUI
called `set_audible_output` — the shipping app, at launch, and nothing else. On a
headless host, under `cargo test`, or over MCP against a CLI-hosted server, this
returns `audible: false` with a reason and makes no sound. Live *microphone*
monitoring is a separate rule about a separate hazard (an acoustic feedback loop)
and remains refused unconditionally.

Everything played is held in a bounded rolling buffer whether or not anything was
armed or recording — people find out something was worth keeping after they play
it, not before. `snapshot.performance` reports `keepableNotes` and the `sounding`
pitches; `studio_performance_keep` lands the buffer as one clip, one batched
`note.add`, one undo step. It refuses while a `record.start` take is open, where
`record.stop` is the right verb.

## Open in Studio (the landing bridge)

`perform` tier. Not a catalog command; it is a whole pipeline (beat-track,
separate, place, section-map) behind one call, so an agent can "open this song
in the Studio" in one step. It builds a new `.mstudio` and makes it active.

| Tool | Purpose | Example arguments |
|------|---------|-------------------|
| `studio_open_in_studio` | Open a finished song as a bar-aligned stem session with lineage and a section map. | `{"sourceAudioRef": "/Music/song.wav", "prompt": "dark synthwave", "separator": "htdemucs"}` |

Optional arguments record provenance and shape the landing: `declaredBpm`,
`key`, `sectionTags`, `sectionTimes`, `seed`, `genModel`, `genDevice`, `source`,
`projectName`, `separator` (`htdemucs` (default) or `provided`), `stems`
(when `separator` is `provided`), `separatorModel`, `pythonSrc` (optional;
discovered from the app bundle when omitted), `outputDir`.

Every separator offered here must produce stems that are usable ALONE. There is
a fourth `Separator` in the engine, `interleave-fixture`, which is a TEST
FIXTURE: its four outputs sum back to the mix bit-exactly but each one is 75%
exact silence and screeches when soloed. It is deliberately not in the enum and
naming it is refused. If demucs is unavailable, `studio_open_in_studio` fails
with a message telling you how to install it; it never silently substitutes
anything.

## Revise, extend, and layer (the workflow tools)

These wrap the whole "select bars, describe a change, get variants, commit one"
flow into single calls, over the same command bus and undo a person uses. The
timeline-commit primitives (`studio_take_promote`, `studio_take_discard`) also
exist as plain command tools, so an agent can drive either way.

| Tool | Tier | Purpose | Example arguments |
|------|------|---------|-------------------|
| `studio_revise` | perform | Revise a bar region: generate N draft variants per scoped stem, splice each into the clip with an equal-power crossfade inside the region, land them as takes. Returns per-variant promotions. Non-blocking. | `{"clipId": "c1", "regionStartTicks": 30720, "regionEndTicks": 46080, "scope": "all-stems", "instruction": "half-time drums, darker pads", "variants": 3}` |
| `studio_audition` | read | Set up the audition loop for a revise region (the region plus 2 bars of pre-roll). | `{"regionStartTicks": 30720, "regionEndTicks": 46080}` |
| `studio_commit` | perform | Commit a chosen variant: promote its takes into their clips as one undo transaction. | `{"promotions": [{"takeId": "tk1", "clipId": "c1"}], "reason": "revise bars 33-48"}` |
| `studio_finalize` | perform | Re-render committed draft takes at the full rung and swap draft to full as one undo transaction. | `{"draftTakeIds": ["tk1"], "rung": "full"}` |
| `studio_discard` | perform | Discard an audition without committing (the takes stay in Takes history). | `{"takeIds": ["tk1", "tk2"]}` |
| `studio_extend` | perform | Extend a clip past its end: generate variant tails as takes. | `{"clipId": "c1", "addedDurationSeconds": 16.0, "instruction": "outro that decays to vinyl noise", "variants": 3}` |
| `studio_commit_extend` | perform | Place a chosen extend tail as a new clip butt-joined and crossfaded at the seam, add a section, as one undo transaction. | `{"takeId": "tk1", "clipId": "c1", "sectionName": "Outro"}` |
| `studio_layer` | perform | Generate a new instrument that fits a context region, as takes. | `{"instruction": "sax lead answering the vocal", "regionStartTicks": 30720, "regionEndTicks": 46080}` |
| `studio_commit_layer` | perform | Create a new track and place a chosen layer take on it, as one undo transaction. | `{"takeId": "tk1", "regionStartTicks": 30720, "trackName": "Sax"}` |

Shared options on the revise/extend/layer tools include `variants` (1 to 8,
default 3), `seed`, `crossfadeMs` (default 20, 5 ms floor), `rung`
(`draft`, `standard`, `full`; default `draft`, finalized at commit), and
`engine` (`mock`, `live`, `gen-node`; `mock` is the deterministic default).
`studio_revise` also takes `keepLyrics` and either `clipId` (all-stems / single
stem) or `clipIds` (one stem clip per scoped stem).

## Gen Protocol proxy

Thin proxies to the Gen Protocol service. All `perform` tier. `op` is one of
`generate`, `revise`, `extend`, `layer`, `retake`, `separate`, `analyze`,
`autocomplete`, `cover`.

| Tool | Purpose | Example arguments |
|------|---------|-------------------|
| `gen_submit` | Submit a generation job to the Gen Protocol service. Returns a `jobId`. | `{"op": "generate", "request": {"caption": "warm lofi beat"}}` |
| `gen_status` | Poll a job's progress/terminal state. | `{"jobId": "job_123"}` |
| `gen_cancel` | Cancel an in-flight job by id. | `{"jobId": "job_123"}` |
| `gen_capabilities` | Per-endpoint supported ops, models, and concurrent slots. | `{}` |

## Take maintenance

| Tool | Tier | Purpose | Example arguments |
|------|------|---------|-------------------|
| `studio_purge_takes` | manage | Reclaim disk by deleting the audio of purgeable candidate takes (never a placed clip, a promoted take, or a landing anchor). The take records stay queryable as lineage. | `{"confirm": true}` |

Optional `takeId` (purge only that take) or `requestId` (purge that request's
candidate takes); with neither, all purgeable candidates are purged.
