# Majik's Music Studio: user manual

This guide walks a musician through a whole song, from the first idea to a
finished file. You do not need to know audio engineering. Where a step names a
key or a button, it is the real control in the app.

The app has six tabs across the top: **Chat**, **Create**, **Studio**,
**Stems**, **Library**, and **Publisher**. This manual is about making a song,
so it lives mostly in **Create** (where you generate) and **Studio** (the
timeline, where you arrange, revise, mix, and export).

## The short version

1. **Create**: describe the song and generate it.
2. **Library**: find the version you like and choose **Open in Studio**.
3. **Studio**: the song lands as separate stem tracks on a timeline, aligned to
   bars.
4. Arrange: move, trim, split, and duplicate clips.
5. Revise a section: select some bars, press **R**, describe the change, and
   pick from the variants (takes).
6. Mix: use the mixer dock at the bottom to balance the tracks.
7. Export: open the export dialog from the transport bar and write a file.

Sterling, the in-app engineer, can do any of steps 4 through 7 for you if you
ask him in plain words. See "Sterling, the engineer" below.

## 1. Create: generate a song

Open the **Create** tab. Write a description of the music you want (a caption),
add lyrics if you have them, and press **Generate**. The app can make several
versions at once with different random seeds, so you have options to compare.
Generated songs are saved to your **Library**.

Generation runs on a model. Where it runs (on this Mac, on a Gen Node box, or in
the cloud) and which language model enhances your caption are set in
**Settings** (open with Cmd+,). If generation fails for lack of memory, the
in-app Help window (Cmd+?) has a troubleshooting section with concrete steps
(use a smaller model, generate fewer variants, close other GPU apps).

## 2. Open a song in the Studio

Go to the **Library**, find the track you want to work on, open its row menu,
and choose **Open in Studio**. The app switches to the **Studio** tab and runs
the landing step:

- It listens to the mix to find the tempo and the downbeats, so the grid lines
  up with the music.
- It separates the song into four stems: **vocals**, **drums**, **bass**, and
  **other**.
- It lays those stems out as four tracks, aligned to bars, and maps out the
  sections (from your lyric tags like `[verse]` and `[chorus]` when they are
  present).

You now have a real multi-track session built from your song. This is saved as
an `.mstudio` project (see CONCEPTS.md).

The "Open in Studio" landing runs on the on-device engine in the packaged app.
In a preview build it is not available, and the app tells you so rather than
pretending.

## 3. Get around the Studio

The **timeline** is the center of the screen: tracks stacked vertically, time
running left to right, with a ruler marked in bars along the top. The
**transport bar** (play position, and the export button) sits with the
timeline. The **mixer** is a dock along the bottom. **Sterling**, the engineer,
is a dock on the right.

Play and stop with the **Space** bar while the Studio tab is open. The Studio
runs its own transport, so the small player bar that follows you around the
other tabs steps aside here.

Generated audio carries a faint iridescent shimmer (on the clip, and on the
Generate control). Imported or human audio stays calm and plain. The rule is
simple: if it shimmers, a model made it.

## 4. Arrange

Work with clips on the timeline the way you would expect:

- **Move** a clip by dragging it. Edits snap to the grid (bar or beat) so things
  stay in time.
- **Split** the selected clip at the playhead with **Cmd+E**.
- **Duplicate** the selection with **Cmd+D**.
- **Trim** a clip by dragging its edge; add a **fade** at an edge, or a
  **crossfade** where two clips meet, to keep the seam clickless.
- Open the **command palette** with **Cmd+K** to search for an action by name.

Anything you do is undoable with **Cmd+Z**, and **Cmd+Shift+Z** redoes it. Undo
history is kept with the project, so you can step back even after saving.

## 5. Record a part

You can record live audio, a vocal or an instrument on an input, straight onto a
track, then hand what you played to the engineer.

**Arm a track.** Each track header has a round record dot. Click it to arm the
track; it fills red to mark that track as the capture target. Arming a track
slides the **record cockpit** in under the transport bar.

**The record cockpit.** This is the red bar that appears when a track is armed.
It holds the **Record** button, the input device picker, a live input meter and
scope, the count-in and loop controls, and the "Build around this" button. It is
red because a recording is a human performance, not a generated one.

**Record.** Press the **Record** button, or **Cmd+R**. Cmd+R toggles: press to
start, press again to stop. If the song is stopped, Record starts it after the
count-in; if it is already playing, capture begins at the live playhead. When
you stop, the take lands where you played it rather than being moved to the
nearest bar line. macOS asks for microphone access the first time you Record or
Listen; denying it leaves recording off and offers a link to Microphone settings.

**Set your level (meter and scope).** The cockpit shows a live **input meter**
(peak and level, with a clip light) and a rolling **scope** (the incoming
waveform) whenever an input is open. Arming a track does **not** open the
microphone — that would listen to the room while you decide what to do next,
with no indication. Press **Listen** to open the mic for gain-staging without
starting a take, or press **Record** to open it and capture. A red **MIC OPEN**
(or **MIC LISTEN**) chip is always visible while the mic is live. If the clip
light turns red, lower the source.

**Input device.** The device picker chooses which interface to capture from.
Leave it on **System Default**, or pick a specific interface (for example a
Zoom AMS-44).

**Input channel.** On a multi-input interface, **In N** on the record bar picks
which physical mic this track records from. Set four tracks to Input 1–4, arm
them all, and press Record once — all four mics land as four clips in one take.
The small numbered meters next to the main meter show each channel so you can
tell which mic is which before you commit.

**Count-in.** Choose a count-in of **Off**, **1**, **2**, or **4** beats. When
set, Record shows a visual countdown before capture begins so you can come in on
time. It plays an audible click, accented on the downbeat, and shows the count on screen.

**Punch in and out.** Select a region on the ruler before you record, and Record
captures only those bars: it starts at the region's start and auto-stops exactly
at its end, landing a clip the exact length of the punch. This lands bar-exact
whether the song was stopped or already playing when you pressed Record. The one
exception: if playback has already run past the end of the region, there is
nothing left to punch into, so Record falls back to a normal open take from the
live playhead instead. Use punch to drop a fix into a set number of bars without
watching the clock.

**Loop-record (comping).** With a region selected, turn on **Loop**. Loop record
does not seek or start the song for you the way a normal punch or free take
does — get the song to the region yourself and press Record when you are ready.
Record then keeps capturing pass after pass over the same region, and each pass
is kept as a take.
Stop when you have enough, then audition the passes in the **Takes** browser (see
"Takes: audition and keep the best") and promote the one you like. That is
comping: many passes, one keeper.

**Build around this.** After a take lands, press **Build around this** in the
cockpit. It selects your take and opens Revise, so you can ask the engineer to
build the arrangement around what you just played (for example, "add drums and
bass under this"). This is the one button in the cockpit that shimmers, because
it hands your human performance to generation.

**Not yet available.** Two things are deliberately off in this build:

- **Hearing yourself (monitoring).** You will not hear your input back through the
  app while recording. This is silent by design, so nothing surprises your
  speakers; the meter and scope are your guide instead.
- **A live meter on arm.** The input meter reads only while you are recording or
  explicitly listening, not the moment you arm. Arming shows the cockpit, but
  the meter goes live when an input is opened.

## 6. Revise a section

This is the heart of the app: regenerate just a part of the song, in place,
without touching the rest.

1. On the ruler, select the bars you want to change. The selection snaps to
   bars.
2. Press **R**. The Revise panel opens.
3. Type an instruction for what should change, for example "strip the drums to
   half-time and darken the pads."
4. Choose the scope: the whole mix, or only certain stems (say, just drums, or
   drums and bass). Stems you do not scope are left exactly as they are.
5. Choose how many variants to try. Each one is a **take**.

The model regenerates only the selected region, in the context of the
surrounding music, and lands the variants as takes under the affected tracks.
The edit is spliced in with a short crossfade at each boundary so it does not
click.

Two more moves work the same way:

- **Extend** the song past its current end: press **E**. Optionally say what the
  new part should be ("16-bar outro that decays to vinyl noise"). The new
  section is crossfaded at the seam.
- **Add a layer**: press **Shift+R** to generate a new instrument part that fits
  the region you selected (for example "warm analog bass"). It lands on its own
  new track.

## 7. Takes: audition and keep the best

When a revision produces takes, you audition them:

- The region loops with two bars of lead-in so you hear it in context.
- Press number keys **1** through **9** to switch between takes at the loop
  boundary.
- Press **A** to hear the original again.
- You can mix takes per stem, for example keep the drums from take 2 and the
  "other" from take 3.
- Press **Return** to commit the take you chose. Press **Esc** to discard the
  audition (the takes stay in your take history; nothing is lost).

When you commit, the app splices your choice into the timeline as one undoable
step. It then quietly re-renders that region at full quality in the background
and swaps it in when ready, so you never wait on a dialog. This two-phase
"draft then commit" flow is described in CONCEPTS.md.

The **Takes** browser lists the variants for a clip with their history (prompt,
seed, model). Takes you do not keep stay on disk until you purge them to reclaim
space.

## 8. Mix

Open the **mixer** dock along the bottom of the Studio. Each track has a channel
strip:

- **Fader** (level) and **pan** (left to right).
- **Mute** and **solo**.
- A three-band **EQ** (low shelf, mid bell, high shelf).
- Two **sends**: send A feeds a reverb, send B feeds a delay.
- A **meter** showing peak and level.

The **master** strip at the end adds a **limiter** (a true-peak ceiling, so the
output does not clip), a **loudness** meter (LUFS), and a correlation meter.

You can also draw **automation** for a track's volume or pan, so a level or a
pan position changes over time (for example, a slow fade or a duck under a
vocal).

## 9. Export

Press the **Export** button in the transport bar to open the export dialog.

**What to export:**

- **Master mix**: the whole song as one file.
- **Stems (per track)**: each track as its own file, for handing off to another
  DAW.
- **Selected region**: just the part inside your loop region. Set a loop region
  on the ruler first.

**Format:** **WAV (24-bit)** or **AAC (.m4a)**. Stems always export as 24-bit
WAV, since they feed a mixer, not a player.

**Loudness (master and region only):**

- **None**: written as you mixed it.
- **Streaming, -14 LUFS**: common target for streaming services.
- **Club, -7 LUFS**: louder, for club playback.
- **Broadcast, -16 LUFS**.

The loudness is measured on the actual bounce (EBU R128), not estimated.

**Include provenance manifest** (on by default): writes a small machine-readable
file next to your audio that discloses which parts are AI-generated and which
are human, with the per-clip lineage (prompt, model, seed). This is the EU AI
Act Article 50 disclosure. The manifest is built from the project's command
journal, so it is accurate, not guessed. The dialog shows a preview bar of how
much of the session is generated versus imported; the exported manifest is the
authoritative version.

**Destination:** choose a folder. The default is a "Majiks Studio Exports"
folder in your Music folder.

The dialog also has two shortcuts:

- **Manifest only**: write just the disclosure manifest, no audio.
- **Publish to majiks.online**: send the export to the majiks.online publisher,
  with the manifest traveling alongside it.

Every export is recorded in the project's journal like any other action, so the
project always knows what was exported and how.

## Sterling, the engineer

Sterling is an engineer who works inside your session. Open his dock on the
right with **Cmd+Opt+C** (or click the STERLING strip on the right edge). Ask
for what you want in plain words, for example:

- "Make the outro sixteen bars longer and keep the mood."
- "Duck the bed under my vocal in the last chorus."
- "The second verse drums are too busy. Try a couple of simpler takes."

Sterling drives the same Studio you do. Every move he makes shows up as a
labeled chip in the dock. Click a chip to flash the part of the timeline it
touched, and undo it right there if you do not like it. He works one turn at a
time and reads the session before he acts, so he is working from what is
actually there.

What he will and will not do on his own:

- He reads and edits freely: tracks, clips, sections, the mixer, generation,
  and takes are all his to work with, and all undoable.
- He will not delete your content, export, or publish unless you ask him to do
  exactly that. The finished file is yours.
- He never touches keys, endpoints, or his own settings. Those are yours to set.

### Point Sterling at a model

Sterling needs an OpenAI-compatible chat endpoint. Open his settings with the
gear icon in the dock header (or the "Open settings" link when no endpoint is
set). Fill in:

- **Endpoint**: any OpenAI-compatible URL, for example
  `http://gateway.internal:4000/v1`. This can be your Unicorn Commander gateway,
  or a local server such as llama.cpp, Ollama, or LM Studio, or a cloud
  provider. For the Unicorn Commander gateway, use the direct address, not the
  Cloudflare host, so a long request is not cut off at 120 seconds.
- **Model**: the model name the endpoint serves, for example `qwen3.6-35b`.
- **API key**: optional for local gateways that need none. If you enter one, it
  is stored in your macOS Keychain and sent only as the request's authorization
  header, never to the model as text and never written to logs. You can remove a
  stored key from the same panel.

Sterling and any outside agent both use the same command bus and the same set of
tools you drive by hand, so nothing he does is a private path you could not do
yourself. If you want to connect an outside agent (Claude Code, for instance) to
the Studio, see the agent guide (AGENT_API.md) and the tool reference
(MCP_API.md).

## Keyboard shortcuts in the Studio

| Key | Action |
|-----|--------|
| Space | Play / pause |
| R | Revise the selected region |
| E | Extend past the end |
| Shift+R | Add a layer over the selection |
| 1 to 9 | Switch to that take (while auditioning) |
| A | Hear the original (while auditioning) |
| Return | Commit the auditioned take |
| Esc | Discard the audition, or clear the selection |
| Cmd+R | Record onto the armed track (press again to stop) |
| Cmd+E | Split the selected clip at the playhead |
| Cmd+D | Duplicate the selection |
| Cmd+K | Open the command palette |
| Cmd+Z / Cmd+Shift+Z | Undo / redo |
| Cmd+Opt+C | Open or close Sterling's dock |

App-wide shortcuts (New, Settings, Import, Library, Playback, Windows, Help) are
listed in the in-app Help window, which you open with **Cmd+?**.
