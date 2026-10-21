# Majik's Music Studio: concepts

This glossary defines the terms used in Majik's Music Studio's design documents, in plain language for people new to digital audio workstations.

## Core DAW concepts

**automation**  A lane on a track that stores parameter changes over time. In v1, automation lanes let you draw or edit volume and pan curves on a per-track basis, with sample-accurate ramps handled by the engine.

**bar and beat**  The timeline's timing grid. A bar is a measure; a beat is a subdivision of a bar. The DAW uses integer ticks at 960 ticks per quarter note (PPQ) for all beat math, never floating-point numbers. Bar-snapped selection means your drag or edit will always snap to bar boundaries.

**bounce**  Rendering the full mix to an audio file using the same graph that playback uses. Offline bounce produces a file that should be indistinguishable from the realtime mix (null-tests within -120 dBFS).

**bus**  A routing path that collects audio from multiple tracks and sends it to a single destination. In v1, the mixer has two send buses per track: Bus A (reverb) and Bus B (delay), each with a fixed quality preset and an amount control.

**clip**  A piece of audio placed on a track in the timeline. It has start/end boundaries, waveforms, and can be moved, trimmed, split, duplicated, faded, or replaced. Generated clips carry a shimmer badge. Imported clips do not.

**export**  Writing audio out of the project. Options include master WAV (24-bit, project sample rate) plus AAC, per-stem WAV export, and region export. Every export can also include a machine-readable provenance manifest and can route through the majiks.online publishing path. Exports are journaled like every other action.

**master**  The final output strip in the mixer, before export. It carries a limiter (true-peak ceiling defaults to -1 dBTP), an LUFS meter (integrated and short-term), and a correlation meter. Export loudness targets (Streaming -14, Club -7, Broadcast -16) are set in the export dialog.

**mixer**  The bottom dock of the DAW, collapsible to a master mini-strip. Each track strip has a fader, pan, mute/solo, 3-band EQ (low shelf, mid bell, high shelf), two sends (A reverb, B delay), and a meter showing peak and RMS. The master strip adds limiter, LUFS, and correlation controls.

**snap**  The behavior that forces edits to align with the timeline grid. Snap can be toggled between bar, beat, division, or off. In magnetic mode, moving a clip will cause nearby clips to shift rather than overlap.

**stem**  A single instrument layer within a multi-track session. Majik's Music Studio is stems-native: generated songs land as four stem tracks (vocals, drums, bass, other), and imported audio can be separated into stems on import. Stem colors are suite-wide constants.

**tempo map**  The project's tempo-over-time definition. It uses rational time (integer ticks at 960 PPQ) so all timing math is exact. A tempo map is required before generated audio can be aligned to bars.

**timeline**  The central arrangement surface where tracks, clips, sections, and automation lanes are placed in horizontal time. The timeline always occupies the main viewport; panels around it are collapsible. Full-screen timeline mode is available.

**track**  A vertical lane on the timeline that holds clips of one type (a stem, a voiceover, etc.). Tracks can be added, removed, renamed, reordered, recolored, and resized. Each has a channel strip in the mixer with volume, pan, EQ, sends, and mute/solo.

## AI-native concepts

**add a layer**  A generative operation that creates a new instrument track layered on top of existing audio in a selected region. With a region selected, you type an instruction (e.g. "warm analog bass") and the result lands as a new track with take lanes and the same audition/commit flow. Triggered from the Revise panel or Shift+R.

**commit and draft rendering**  The two-speed rendering flow for takes. When you revise a region, the model first renders fast draft takes (fewer steps or region-trimmed) so you can audition immediately. When you commit a take, a full-quality re-render runs in the background (gen.finalize) and splices in cleanly when ready, with a quiet badge on the clip until it lands. The UI never blocks.

**extend**  A generative operation that continues the project past its current endpoint. You drag the project edge into ghost bars or press E at the end, optionally provide an instruction ("16-bar outro, decays to vinyl noise"), and the model generates new section stems crossfaded at the seam.

**generate**  The operation that produces audio from a text prompt and other parameters. In v1, generate can create a full song (text2music) or repaint a selected region (revise). It runs on local MLX, a Gen Node box, or UC cloud. The result lands on the timeline as stems.

**retake**  Producing new variants of an existing clip or region using the same prompt but different random seeds. Retakes create take lanes with the same audition flow. "More like this, but..." prefills the Revise panel with the clip's original prompt for editing.

**revise a region**  The signature generative edit. You select bars on the ruler (bar-snapped), press R, and the Revise panel opens with an instruction, scope chips (all or per-stem), variant count, and optional advanced controls. The model regenerates only the selected region in context and lands takes under the affected tracks.

**the shimmer rule**  The visual design rule that an iridescent pink-violet-teal gradient sheen appears only on generative surfaces: the Generate button, an in-flight revise region border, rendering take lanes, and the small generated badge on AI-born clips. Nothing else uses it. The rule signals: if it shimmers, a model made it; if it is calm, a human did.

**takes**  Variant auditions for a generated or revised region. Each revision creates take lanes under the affected tracks. Audition mode loops the region with 2 bars of pre-roll; keys 1-9 switch takes at the loop boundary; A returns to the original; Return commits the chosen take and Esc discards the audition. Per-stem take mixing is allowed (e.g. drums from take 2, other from take 3).

**audition rung**  The render quality of a take. Revisions render at the draft rung first (fewer steps, fast) so you can audition immediately; committing a take then finalizes it at the full rung in the background and swaps it in when ready. The rungs are draft, standard, and full.

## Provenance concepts

**command bus**  The single entry point for every project mutation. Every action, regardless of source (UI click, agent, API, copilot), goes through the command bus as a structured JSON envelope. This guarantees that undo, provenance, and agent parity all work from the same mechanism. Unknown commands or bad parameters produce typed errors rather than partial application.

**command journal**  An append-only, hash-chained log (blake3) of every command that modifies a project. Each journal line contains the command envelope, its inverse for undo, and a hash linking to the previous line. The journal is the source of truth: replaying it from empty reproduces the project byte-identically. It is also the provenance event log. Undo and redo append forward (a new inverse entry); the journal never rewrites history.

**.mstudio package**  The on-disk project format. An `.mstudio` project is a directory package holding a fast-open checkpoint (`project.json`), the append-only hash-chained command journal (`journal.jsonl`) that is the source of truth, content-addressed `audio/` and `takes/` folders, a rebuildable waveform tile cache (`tiles/`), and a rebuildable provenance `manifest.json`. Replaying the journal from empty reproduces the checkpoint. The full layout is in engine/contracts/MSTUDIO-FORMAT.md.

**checkpoint**  The `project.json` snapshot inside an `.mstudio` package. It records the project as of a journal tip so opening is fast (no full replay), and it pins itself to the journal (entry count and tip hash) so "this checkpoint matches this journal" is a checkable fact. Saving writes a new checkpoint, then marks older journal segments eligible for truncation only after the write is durable, so a crash mid-save cannot lose data.

**content-addressed asset**  Audio stored under `audio/` and `takes/` by its blake3 content hash rather than a file path. A clip references audio by `assetHash`, so identical audio is stored once and a moved or renamed file never breaks a reference. If an asset is missing when a project opens, only that one clip degrades to offline; the project still opens.

**transaction**  A bracket that groups several journaled commands into one undo unit, opened with `txn.begin` and closed with `txn.commit`. Committing a revision or an extend uses a transaction so the whole edit undoes and redoes as a single step. In v1, transactions do not nest.

**lineage**  The ancestry tree attached to every clip, showing its prompt, model, seed, engine, and parent clip IDs. The inspector displays lineage as a mini-tree when a clip is selected. Generated audio is always traceable back to the command and parameters that produced it.

**provenance manifest**  A machine-readable JSON file that can be included with every export. It documents which parts of the session are human-made versus AI-generated, and carries the information required by EU AI Act Article 50 (AI-disclosure). It is built as a view over the command journal plus asset content hashes.

**generated audio is labeled and traceable**  A design principle: every generated clip is visually marked (the shimmer badge) and carries full lineage metadata (prompt, model, seed, engine, parent clips). Imported audio gets a neutral (non-shimmer) color treatment. Human vs generated is visible at a glance, and full chain of custody starts at import (audio fingerprinting) and ends at export (manifest).

**recorded performance**  Audio captured from a live input (a vocal, an instrument) onto an armed track. A recording is a first-class object on the same command bus as every other edit: `record.stop` lands it as a candidate take and a placed clip whose lineage carries the sourceCommand `record.commit`, so the provenance manifest classifies it as human, not AI. It gets the calm, non-shimmer treatment of all human audio, and Sterling or the Revise flow can build an arrangement around it (the "Build around this" bridge) exactly as they would around imported audio.

## Agent concepts

**agent parity**  The rule that every human action in the DAW is also a command, and every command is an API call and an MCP tool. An agent can build a full arrangement end to end using the same tools a human uses through the UI. There are no private paths that only humans can take.

**the copilot dock**  The right-rail agent interface (toggled with Cmd+Opt+C). It contains a chat surface with the studio copilot (persona: Sterling, the Producer — distinct from the built-in "The Engineer" technical agent, which handles BPM/key detection, mixing advice, and parameter extraction) and an Actions log where every agent action appears as a clickable command chip. Clicking a chip flashes the affected timeline region. Each chip has undo. The copilot uses the command bus and MCP tools, not a separate system.

**MCP**  The Model Context Protocol. Majik's Music Studio ships with an engine-owned MCP server (rmcp over localhost HTTP on 127.0.0.1:8478, bearer personal access token, off by default and fails closed). The tool registry is generated from the command catalog and includes read/snapshot tools plus Gen Protocol tools proxied to the Python backend. Agents interact with the DAW entirely through these tools. The full tool set is documented in docs/MCP_API.md.
