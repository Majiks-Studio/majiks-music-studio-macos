# Majik's Music Studio: end-to-end demo script

The one thing to land: **generation is an edit operation.** You generate a song,
it becomes a real multitrack session, and you regenerate any section in place
with a seamless splice. No incumbent DAW does that.

Every key and button below is a real control (verified against docs/USER_MANUAL.md
and the shipped shortcut table). Total run time about 4 to 6 minutes.

## Before you roll (off camera)
- Real, packaged app running (not a preview build: "Open in Studio" and Sterling
  need the on-device engine). For audible playback, launch with
  `MAJIKS_TEST_AUDIBLE=1` on monitors you control. See HANDOFF-demo.md.
- Generation backend up (Create tab): pick it in Settings (Cmd+,). Confirm one
  test generation completes before you record.
- Sterling endpoint set (Studio, dock gear): Unicorn Commander gateway direct
  address on :4000 `/v1`, model `qwen3.6-35b`, your key. Confirm the "no endpoint"
  warning is gone.
- Window on screen and sized (the launch clamp handles this; the capture script
  also repositions it).

## Beat 1: Create (about 40s)
- Open the **Create** tab.
- Type a caption, for example: "warm lo-fi soul, 82 BPM, dusty Rhodes, tight
  drums, a short hook." Add a couple of lyric lines with a `[chorus]` tag so the
  section map has something to find later.
- Press **Generate**. Let it make 2 to 3 variants.
- Narration: "Start with a description. It writes a few versions."
- Capture note: hold on the shimmer on the Generate control and the new Library
  rows. The shimmer means a model made it. Remember that; it pays off in Beat 6.

## Beat 2: Open in Studio (about 30s)
- Go to **Library**, pick the best variant, open its row menu, choose **Open in
  Studio**.
- The app switches to the **Studio** tab and lands the song: it finds tempo and
  downbeats, separates into **vocals / drums / bass / other**, and lays them out
  as four bar-aligned tracks with a section map.
- Narration: "It is not a file. It is a session, separated into stems and lined
  up to the bar."
- Capture note: let the landing animate; catch the four stem tracks appearing on
  the grid.

## Beat 3: Revise a section in place (about 70s) -- THE MOMENT
- On the ruler, select the chorus bars (the selection snaps to bars).
- Press **R**. The Revise panel opens.
- Type: "half-time the drums and darken the pads."
- Scope it to **drums** and **other** (leave vocals and bass untouched).
- Ask for **3** variants.
- When the takes land, audition: press **1**, **2**, **3** to switch takes at the
  loop boundary; press **A** to hear the original. Land on the best one and press
  **Return** to commit.
- Narration: "Select a section, describe the change, regenerate just those stems
  in context. It splices in with a crossfade so there is no click. The rest of
  the song never moved. This is the thing no other DAW does."
- Capture note: this is the hero shot. Show the selection, the variants, the
  audition switch, and the commit chip. Keep the region looping audibly.

## Beat 4: Mix (about 40s)
- Open the **mixer** dock along the bottom.
- Pull the **vocals** fader up a touch; nudge **pan** on one track.
- Draw a short **volume automation** dip on the "other" bus under the vocal.
- Narration: "Normal mixing. Fader, pan, a little automation. Every move is one
  undoable step."
- Capture note: show a meter moving; show one Cmd+Z undo and redo so the audience
  sees moves are reversible.

## Beat 5: Sterling, hands-free (about 50s)
- Press **Cmd+Opt+C** to open Sterling's dock (or click the STERLING strip).
- Type: "Make the outro sixteen bars longer and duck the bed under the vocal in
  the last chorus."
- Watch the labeled chips land as he works, and the timeline change.
- Click one chip to flash the part of the timeline it touched; undo it right there
  to show it is the same command bus you drive by hand.
- Narration: "Or just tell the engineer. He drives the same session you do, one
  turn at a time, and every move is a chip you can click and undo."
- Capture note: catch the chips appearing and the outro visibly extending.

## Beat 6: Export with the provenance manifest (about 40s)
- Press **Export** in the transport bar.
- Choose **Master mix**, **WAV (24-bit)**, loudness **Streaming, -14 LUFS**.
- Leave **Include provenance manifest** on. Point out the preview bar showing how
  much of the session is generated versus human.
- Export to the default "Majiks Studio Exports" folder.
- Narration: "Bounce it with an AI-disclosure manifest, built from the project's
  own journal, so it is accurate, not guessed. That is the EU AI Act Article 50
  disclosure, for free, because every edit was a logged command."
- Capture note: show the manifest toggle and the generated-versus-human preview
  bar. Optionally open the written manifest file to show the per-clip lineage.

## Close (about 15s)
- Back on the timeline, point once more at the shimmer on the generated clips
  versus the plain look of anything human or imported.
- Narration: "If it shimmers, a model made it. Generate, revise, mix, and ship,
  with the disclosure baked in."

## Notes for the operator
- Pauses read as confidence. Give each generation and each Sterling turn room to
  finish; do not narrate over dead air, cut it in the edit.
- If a generation is slow on the day, pre-generate Beat 1 before rolling and start
  from Library, or shorten the caption. Keep Beat 3 live: it is the whole point.
- Keep audible playback on monitors you control (MAJIKS_TEST_AUDIBLE=1). This is
  your attended step; the capture script never forces audio.
