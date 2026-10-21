# Manual QA: record over the song (PR #7, round 1)

Run this with headphones on, a guitar or another instrument on an audio
interface, and a **throwaway/scratch project** — not your real library. Grant
microphone access when macOS first asks (steps 8 tests the denied path
separately). Any count-in beats below assume Count-in is set to 2 unless a
step says otherwise.

1. **New scratch project, one track armed, transport stopped, no punch
   region, Count-in Off. Press Record.**
   Expected: the song starts rolling immediately (no clicks, no countdown),
   the bar shows RECORDING and a running timer. Press Stop, then play back —
   the take starts exactly where the playhead was, not snapped to a bar you
   didn't ask for.

2. **Same setup, Count-in = 2, still stopped. Press Record.**
   Expected: you hear two clicks (the first louder — beat one) and see a
   countdown (2 → 1) before capture starts; the song is playing by the time
   the count-in ends. Play back the take: it starts clean on the beat right
   after the count-in.

3. **Select a 4-bar region on the ruler, stay stopped, press Record.**
   Expected: the transport jumps to the region's first bar, counts in,
   plays, records, and stops itself exactly at the region's last bar — you
   never press Stop. The landed clip's waveform fills exactly those 4 bars
   in the timeline.

4. **Press Play with no punch region selected, let it run a few bars, then
   press Record mid-song.**
   Expected: capture begins immediately, right where the playhead already
   was — no re-seek, no restart, no count-in. Play back: the take starts at
   that exact spot.

5. **Select a punch region, press Play, and wait until playback has run
   PAST the end of that region before pressing Record.**
   Expected: since the punch has already gone by, Record falls back to a
   normal open take from wherever you are — press Stop yourself. Nothing
   should misplace itself, and the app should not treat this as an error.
   (There's no on-screen note that the punch was skipped yet — see the
   review's nits.)

6. **Select a region, turn Loop on, and press Record while the song is
   STOPPED.**
   Expected: nothing rolls — Loop does not seek, count in, or auto-play.
   Press Play yourself, then Record, to get real loop passes; each pass
   should add "Loop · 2", "Loop · 3"... to the loop chip.

7. **With Loop still on and the song playing, do 2-3 passes on an interface
   whose sample rate does not match the project (e.g. a 44.1 kHz interface
   against a 48 kHz song, if your interface offers that).**
   Expected: every pass — not just the last — plays back at the right pitch
   and speed. None of them sound sped up, slowed down, or detuned.

8. **In System Settings > Privacy & Security > Microphone, turn off access
   for Majik's Music Studio, then press Listen or Record in the app.**
   Expected: a red line reading "Microphone access is off for Majik's Music
   Studio" appears in the record bar with an "Open Microphone Settings"
   button; clicking it opens the Microphone pane directly. No crash, no
   silent no-op.

9. **Turn microphone access back on, record a short guitar phrase, press
   Stop, then press Play from the normal transport (not while recording).**
   Expected: you hear nothing of your input while capturing (monitoring is
   off by design), but pressing Play afterward plays back exactly what you
   played, at the right pitch and level.

10. **Mash Record twice, fast, right as a count-in or a permission prompt is
    in flight.**
    Expected: one clean take, not two overlapping recordings and not a
    countdown that never resolves.
