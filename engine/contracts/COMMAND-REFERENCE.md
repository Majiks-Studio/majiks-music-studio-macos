# Majik's Music Studio: command reference
Generated from command-catalog v2 (119 commands). Every edit in the DAW is one of these commands, whether issued by a person, an agent, or the API.

## How to read this
- Journaled: the command is written to the project's command journal (the provenance and undo log).
- Undoable: the command can be reversed. Non-undoable commands say why.
- Inverse: how the command is reversed (self = applying it again with prior values; explicit = a specific paired command).

## automation  (5 commands)
### autolane.show
What it does: Declared as showing or hiding an automation lane in the timeline. The ENGINE stores no such state: this validates the track and the target and returns ok without changing anything, and the Studio UI keeps lane visibility in its own view model. Calling it over the agent surface moves nothing on screen.
Parameters: trackId (required), Id of the track whose automation lane is shown or hidden.; target (required), A ParamRef: dotted ASCII path addressing one automatable parameter. 'track.volume' and 'track.pan' are the reserved v1 spellings and MUST render byte-identically. Unrecognised but well-formed paths are preserved verbatim rather than dropped.; visible (required), true would show the lane, false hide it. NOT IMPLEMENTED in the engine: the command validates trackId and target and returns ok with mutated:false, storing nothing — the Studio UI keeps lane visibility in its own view state, so calling this over the agent surface moves nothing on screen and nothing reads the flag back.
Journaled: no.
Undoable: no.
Inverse: none.

### autopoint.add
What it does: Add an automation point on a track parameter lane. v1 automation targets are track.volume and track.pan only.
Parameters: trackId (required), Id of the track that owns the lane.; target (required), A ParamRef: dotted ASCII path addressing one automatable parameter. 'track.volume' and 'track.pan' are the reserved v1 spellings and MUST render byte-identically. Unrecognised but well-formed paths are preserved verbatim rather than dropped.; pointId (required), Caller-minted, stable id for the point; the engine never mints one, because a minted id would make replay diverge from the live model. Must be unique on the lane.; positionTicks (required), Where the point sits, in absolute timeline ticks from 0 (PPQ 960: 960 ticks is a quarter note, 3840 is one 4/4 bar).; value (required), track.volume: dB. track.pan: -1..1.
Journaled: yes.
Undoable: yes.
Inverse: explicit (autopoint.remove).

### autopoint.move
What it does: Drag an existing automation breakpoint to a new time and/or value. Self-inverse: undo carries the prior position and value.
Parameters: trackId (required), Id of the track that owns the lane.; target (required), A ParamRef: dotted ASCII path addressing one automatable parameter. 'track.volume' and 'track.pan' are the reserved v1 spellings and MUST render byte-identically. Unrecognised but well-formed paths are preserved verbatim rather than dropped.; pointId (required), Id of an existing point on this lane.; positionTicks (required), New position for the point, in absolute timeline ticks from 0 (PPQ 960: 960 ticks is a quarter note, 3840 is one 4/4 bar).; value (required), New value at the point, in the target parameter's OWN units: dB for track.volume, -1..1 for track.pan.
Journaled: yes.
Undoable: yes.
Inverse: self.

### autopoint.remove
What it does: Delete one breakpoint from an automation lane. The lane and its other points stay; use autolane.clear to empty the lane instead.
Parameters: trackId (required), Id of the track that owns the lane.; target (required), A ParamRef: dotted ASCII path addressing one automatable parameter. 'track.volume' and 'track.pan' are the reserved v1 spellings and MUST render byte-identically. Unrecognised but well-formed paths are preserved verbatim rather than dropped.; pointId (required), Id of an existing point on this lane.
Journaled: yes.
Undoable: yes.
Inverse: explicit (autopoint.add).

### autolane.clear
What it does: Remove every automation point on a lane. Undo restores the full prior point set (runtime snapshot, not expressed field-by-field in this schema).
Parameters: trackId (required), Id of the track that owns the lane.; target (required), A ParamRef: dotted ASCII path addressing one automatable parameter. 'track.volume' and 'track.pan' are the reserved v1 spellings and MUST render byte-identically. Unrecognised but well-formed paths are preserved verbatim rather than dropped.
Journaled: yes.
Undoable: yes.
Inverse: self.

## clip  (22 commands)
### clip.place
What it does: Put an existing content-addressed audio asset on a track as a clip. The asset must already be in the package (import.audio is what brings one in); clips on a track may not overlap.
Parameters: clipId (required), Caller-minted, stable id for the new clip; the engine never mints one. Must not already be in use anywhere in the project.; trackId (required), Id of the track to place the clip on. Clips on one track may NOT overlap — an overlapping placement is refused, not nudged.; assetHash (required), blake3 hash of the audio asset under audio/: 64 lowercase hex characters. The asset must already be in the package — this command references, it does not import.; startTicks (required), Where the clip starts on the timeline, in absolute timeline ticks from 0 (PPQ 960: 960 ticks is a quarter note, 3840 is one 4/4 bar).; lengthTicks (required), How long the clip is, in ticks. The schema admits 0 for historical reasons but the executor REFUSES it: this must be greater than 0.; sourceOffsetTicks (optional), Optional offset INTO the asset at which the clip starts reading, in ticks. Default 0 (play from the top of the file). offset + length must stay inside the asset's extent.
Journaled: yes.
Undoable: yes.
Inverse: explicit (clip.remove).

### clip.placeMidi
What it does: Place an empty NOTE-BACKED (MIDI) clip on a track. A NEW command name, not an optional param on clip.place: catalog v2 design 9.2 — replay does not validate params, so an older binary would verify the chain and silently build a wrong model, whereas an unknown command name hard-fails the open.
Parameters: clipId (required), Caller-minted, stable id for the new note clip; the engine never mints one. Must not already be in use anywhere in the project.; trackId (required), Id of the track to place the clip on. Clips on one track may NOT overlap — an overlapping placement is refused.; startTicks (required), Where the clip starts on the timeline, in absolute timeline ticks from 0 (PPQ 960: 960 ticks is a quarter note, 3840 is one 4/4 bar).; lengthTicks (required), How long the clip is, in ticks; must be greater than 0. Note positions are CLIP-RELATIVE, so this is the window they live in.
Journaled: yes.
Undoable: yes.
Inverse: explicit (clip.remove).

### clip.move
What it does: Move a clip to a new start position, optionally onto a different track. This is the exact command shown as the worked example in 02-ARCHITECTURE.md section 4.
Parameters: clipId (required), Id of the clip to move.; trackId (required), Destination track; equal to the clip's current track for a same-lane move.; startTicks (required), New clip start, in absolute timeline ticks from 0 (PPQ 960: 960 ticks is a quarter note, 3840 is one 4/4 bar). The destination must be clear — clips on one track may not overlap.
Journaled: yes.
Undoable: yes.
Inverse: self.

### clip.trim
What it does: Move one edge of a clip to crop or extend it, without moving the audio inside it. Delta-based and self-inverse. The start edge is refused on a note-backed clip.
Parameters: clipId (required), Id of the clip to trim.; edge (required), Which edge moves: 'start' or 'end'. 'start' is REFUSED on a note-backed clip (it would shift every note relative to the clip); 'end' works on audio and note clips alike.; deltaTicks (required), Signed tick delta, and it may not be 0. On the 'start' edge a positive value shortens from the front (the start moves later); on the 'end' edge a positive value lengthens. The result must leave a length greater than 0 and must not collide with a neighbouring clip.
Journaled: yes.
Undoable: yes.
Inverse: self.

### clip.split
What it does: Cut one clip into two at a point strictly inside it. The left piece keeps the original id, the right piece takes newClipId, and no audio is re-encoded.
Parameters: clipId (required), Id of the clip to split. It becomes the LEFT piece and keeps this id; the right piece gets newClipId.; atTicks (required), Split point, in absolute timeline ticks from 0 (PPQ 960: 960 ticks is a quarter note, 3840 is one 4/4 bar), STRICTLY inside the clip: after its start and before its end. A split exactly on an edge is refused rather than silently ignored.; newClipId (required), Caller-minted id for the RIGHT-hand piece the split creates; must not already be in use. The left piece keeps the original clipId.
Journaled: yes.
Undoable: yes.
Inverse: self.

### clip.duplicate
What it does: Copy a clip and place the copy at another position on the SAME track — despite what earlier wording implied, this command carries no destination track and cannot move a copy to another lane. Use clip.duplicate then clip.move for that.
Parameters: clipId (required), Id of the clip to copy. The original is untouched.; newClipId (required), Caller-minted id for the copy; must not already be in use.; startTicks (required), Where the copy starts, in absolute timeline ticks from 0 (PPQ 960: 960 ticks is a quarter note, 3840 is one 4/4 bar). The copy always lands on the SOURCE clip's own track — this command carries no destination track — so that span must be clear.
Journaled: yes.
Undoable: yes.
Inverse: explicit (clip.remove).

### clip.remove
What it does: Remove a clip from the timeline. The underlying audio asset is not deleted (content-addressed, may be referenced elsewhere).
Parameters: clipId (required), Id of the clip to remove from the timeline. The underlying audio asset under audio/ is NOT deleted: it is content-addressed and other clips may reference it.
Journaled: yes.
Undoable: yes.
Inverse: explicit (clip.place).

### clip.setGain
What it does: Trim one clip's level without touching the channel fader, so a single quiet line can be brought up inside an otherwise balanced mix.
Parameters: clipId (required), Id of the clip whose trim changes.; gainDb (required), Clip gain trim in dB, -60 to 12; 0 is unity. Applied ON TOP OF the track fader (mix.gain), not instead of it. The bound is enforced by the executor, not only by this schema.
Journaled: yes.
Undoable: yes.
Inverse: self.

### clip.mute
What it does: Silence one clip while leaving the rest of its track audible — the usual way to drop a bad line out of a comp without deleting it.
Parameters: clipId (required), Id of the clip to mute or unmute.; muted (required), true silences just this clip, false unmutes it. Absolute, not a toggle, and independent of track.mute.
Journaled: yes.
Undoable: yes.
Inverse: self.

### clip.fade.set
What it does: Shape the head or tail of a clip so it does not start or stop abruptly, or remove an existing fade by setting its length to 0.
Parameters: clipId (required), Id of the clip whose fade changes.; edge (required), Which fade this sets: 'in' (the clip's head) or 'out' (its tail).; lengthTicks (required), Fade length in ticks, 0 or more; 0 removes the fade. The fade may not be longer than the clip — a trim or split that would leave it hanging over the edge is refused instead.; shape (required), Fade curve: 'linear', 'equalPower', 'exponential' or 'logarithmic'. equalPower holds perceived loudness roughly constant and is the usual choice where two clips meet.
Journaled: yes.
Undoable: yes.
Inverse: self.

### clip.crossfade.set
What it does: Blend the joint between two adjacent clips on one track so the seam is inaudible, or remove an existing crossfade by setting its length to 0.
Parameters: clipIdA (required), Id of the EARLIER clip of the adjacent pair. Both clips must sit on the same track.; clipIdB (required), Id of the LATER clip of the adjacent pair.; lengthTicks (required), Crossfade length in ticks, 0 or more; 0 means no crossfade. Required rather than optional by the self-inverse rule — the pre-state of a joint's FIRST crossfade is 'none', and the inverse has to be able to say so.; shape (optional), Crossfade curve: 'linear', 'equalPower', 'exponential' or 'logarithmic'. Default 'equalPower'.
Journaled: yes.
Undoable: yes.
Inverse: self.

### clip.warp.set
What it does: Set how a clip's audio is stretched against the timeline: a fixed ratio, or 'conform', which this build resolves to the ratio the clip already carried rather than matching the project tempo (see the mode parameter).
Parameters: clipId (required), Id of the clip whose time-warp changes.; mode (required), 'ratio' applies the fixed stretchRatio you supply and is the mode that does something. 'conform' is accepted and journaled, but this build resolves it to whatever stretchRatio the clip already carried: conform-to-project-tempo needs a stored SOURCE tempo the engine does not have yet (E7 warp markers), so it is not a tempo match today.; stretchRatio (optional), Playback stretch factor, greater than 0; 1.0 is unwarped and 2.0 plays at half speed. Optional at the top level of this schema but REQUIRED when mode is 'ratio' (the if/then branch pins it), and meaningless when mode is 'conform'. The renderer clamps what it can actually stretch to 0.25x..4x.
Journaled: yes.
Undoable: yes.
Inverse: self.

### clip.phaseAnchor.set
What it does: Tell a warped clip where its own bar grid begins, so a performance with a lead-in locks to the bars a person sees rather than to tick 0.
Parameters: clipId (required), Id of the clip whose bar-grid phase anchor changes.; anchorTicks (required), Where this clip's warped source considers the bar grid to begin, in ticks, 0 or more. 0 is the unshifted default.
Journaled: yes.
Undoable: yes.
Inverse: self.

### clip.rename
What it does: Change the label drawn on a clip. The clipId is unaffected — ids are the wire identity and never change.
Parameters: clipId (required), Id of the clip to relabel. Its id does not change — only the label a person sees.; name (required), New display label for the clip. Non-empty.
Journaled: yes.
Undoable: yes.
Inverse: self.

### note.add
What it does: Add a batch of MIDI notes to a note-backed clip in one journal entry. Rejected on an audio clip. NOT self-inverse: undoing an add is a removal, so inverseRule is explicit (note.remove).
Parameters: clipId (required), Id of a NOTE-BACKED clip (one made by clip.placeMidi). Rejected on an audio clip.; notes (required), The notes to add, at least one. Each entry carries its own caller-minted noteId plus start, length, pitch and velocity. One call is ONE journal entry, so a whole chord adds and undoes as a unit.
Journaled: yes.
Undoable: yes.
Inverse: explicit (note.remove).

### note.remove
What it does: Remove a batch of MIDI notes from a note-backed clip. NOT self-inverse: the removed notes' full state has to come back, so the inverse is a single note.add carrying it.
Parameters: clipId (required), Id of the note-backed clip the notes live in. Rejected on an audio clip.; noteIds (required), The batch this command acts on. One chord drag is ONE journal entry, so relative offsets inside the selection are a property of the command rather than the caller's responsibility.
Journaled: yes.
Undoable: yes.
Inverse: explicit (note.add).

### note.move
What it does: Move a batch of notes in time and/or pitch (the piano-roll drag). DELTA-based, so the inverse is simply the negated delta and relative voicing inside the selection is preserved by construction. The engine does NOT clamp: if the batch would move any note out of range the WHOLE command is refused with a typed error and nothing is applied. Clamping here would break self-inversion (clamp then negate the delta does not return the original) and would collapse a chord onto the boundary note by note; group-clamping that preserves voicing is the caller's job.
Parameters: clipId (required), Id of the note-backed clip the batch lives in. Rejected on an audio clip.; noteIds (required), The batch this command acts on. One chord drag is ONE journal entry, so relative offsets inside the selection are a property of the command rather than the caller's responsibility.; deltaTicks (required), Signed time offset applied to every note in the batch.; deltaPitch (required), Signed semitone offset applied to every note in the batch, -127 to 127. No clamping: if any note would leave 0..127 the whole command is refused.
Journaled: yes.
Undoable: yes.
Inverse: self.

### note.resize
What it does: Resize a batch of notes from one edge. DELTA-based and self-inverse (same edge, negated delta). The engine does NOT clamp: if the batch would move any note out of range the WHOLE command is refused with a typed error and nothing is applied. Clamping here would break self-inversion (clamp then negate the delta does not return the original) and would collapse a chord onto the boundary note by note; group-clamping that preserves voicing is the caller's job.
Parameters: clipId (required), Id of the note-backed clip the batch lives in. Rejected on an audio clip.; noteIds (required), The batch this command acts on. One chord drag is ONE journal entry, so relative offsets inside the selection are a property of the command rather than the caller's responsibility.; edge (required), leading moves the note start and shortens by the same amount; trailing changes the length only.; deltaTicks (required), Signed length/start offset. Positive on the leading edge shortens from the front; positive on the trailing edge lengthens.
Journaled: yes.
Undoable: yes.
Inverse: self.

### note.velocity.set
What it does: Nudge the velocity of a batch of notes by a signed integer offset. Named .set for symmetry with the rest of the catalog; the parameter is a DELTA, which is what makes it self-inverse. The engine does NOT clamp: if the batch would move any note out of range the WHOLE command is refused with a typed error and nothing is applied. Clamping here would break self-inversion (clamp then negate the delta does not return the original) and would collapse a chord onto the boundary note by note; group-clamping that preserves voicing is the caller's job.
Parameters: clipId (required), Id of the note-backed clip the batch lives in. Rejected on an audio clip.; noteIds (required), The batch this command acts on. One chord drag is ONE journal entry, so relative offsets inside the selection are a property of the command rather than the caller's responsibility.; deltaVelocity (required), Signed velocity offset applied to every note in the batch, -127 to 127. Integer, so the journaled Num shape is stable by construction. No clamping: if any note would leave 0..127 the whole command is refused.
Journaled: yes.
Undoable: yes.
Inverse: self.

### note.duplicate
What it does: Copy a batch of notes at a time/pitch offset, using caller-minted ids. NOT self-inverse: undoing a duplicate removes the copies, so inverseRule is explicit (note.remove). The engine does NOT clamp: if the batch would move any note out of range the WHOLE command is refused with a typed error and nothing is applied. Clamping here would break self-inversion (clamp then negate the delta does not return the original) and would collapse a chord onto the boundary note by note; group-clamping that preserves voicing is the caller's job.
Parameters: clipId (required), Id of the note-backed clip the batch lives in. Rejected on an audio clip.; noteIds (required), The batch this command acts on. One chord drag is ONE journal entry, so relative offsets inside the selection are a property of the command rather than the caller's responsibility.; newNoteIds (required), Ids for the copies, positionally paired with noteIds and the same length. Minted UI-side.; deltaTicks (required), Signed time offset applied to the copies.; deltaPitch (required), Signed semitone offset applied to the copies, -127 to 127. No clamping: if any copy would leave 0..127 the whole command is refused.
Journaled: yes.
Undoable: yes.
Inverse: explicit (note.remove).

### note.timing.set
What it does: Set the ABSOLUTE start and length of a batch of notes. The one note command that is not delta-shaped, and it exists for exactly one reason: an inverse that has to restore per-note positions no single delta describes. note.quantize names it as its inverse. Self-inverse because the inverse is the same command carrying the pre-state values, the clip.move pattern. Pitch and velocity are untouched: this command is about TIME only, so it can never silently retune a chord.
Parameters: clipId (required), Id of the note-backed clip the batch lives in. Rejected on an audio clip.; notes (required), One entry per note. Every noteId must be distinct and must already exist in the clip.
Journaled: yes.
Undoable: yes.
Inverse: self.

### note.quantize
What it does: Pull a batch of notes toward a grid at a given strength. NEVER automatic: nothing in the engine issues this on capture, on import or on load, because the point of a tempo-mapped recording is that the grid was fitted to the performance rather than the other way round. NOT self-inverse and not a delta command: every note moves by its own amount, so the inverse is one note.timing.set carrying the EXACT prior start and length of every note in the batch. Refused whole (nothing applied) if any note would land before tick 0 or, with quantizeEnds, be squeezed below one tick.
Parameters: clipId (required), Id of the note-backed clip the batch lives in. Rejected on an audio clip.; noteIds (required), The batch this command acts on. REQUIRED and non-empty: there is deliberately no "quantize the whole clip" spelling, because quantize is destructive to a performance that was played off the grid on purpose. A caller that means every note enumerates every note.; gridTicks (required), The grid division to pull toward, in ticks (960 = a quarter at PPQ 960, 240 = a sixteenth). Lines are measured from the project's phaseAnchorTicks, so a song with a lead-in quantizes to its real bar 1 rather than to tick 0.; strengthPercent (required), How far each note travels toward its grid line, as an INTEGER percent. 100 is mechanical; 50-80 tightens the timing while keeping the feel. Integer rather than a 0..1 float because journaled values are Num and the hash chain depends on their integer/float shape (0.8 and 80 are not interchangeable under canonicalization).; quantizeEnds (required), false: only note STARTS move, lengths are preserved exactly. true: the note END is pulled to the same grid at the same strength, so lengths change. Off is the musical default; legato passages get chopped by an ends-quantize.
Journaled: yes.
Undoable: yes.
Inverse: explicit (note.timing.set).

## gen  (16 commands)
### gen.song
What it does: Journal a request for a new text2music generation. RECORDS the request on the bus and returns; it does not itself call a generation backend, and nothing is placed on the timeline until a take lands and take.promote commits it. Gen Protocol op: generate.
Parameters: requestId (required), Caller-minted ULID naming this job: Crockford base32, 26 characters, first character 0-7. gen.landed quotes it back and gen.cancel takes it. Mint a fresh one per request.; trackId (required), Id of the track the result is destined for; it must already exist. Nothing is placed by this command — take.promote does that once the take lands.; insertAtTicks (required), Where the result is meant to land, in absolute timeline ticks from 0 (PPQ 960: 960 ticks is a quarter note, 3840 is one 4/4 bar). Recorded on the request record; the actual placement happens at take.promote.; request (required), The rest of the Gen Protocol 'generate' request. caption is the one field this schema pins; the full shape is in gen-protocol.v1.yaml (see gen-protocol-mapping.md).
Journaled: yes.
Undoable: no.
Inverse: none.

### gen.revise
What it does: Journal a request to repaint a region of a clip with an instruction delta. RECORDS the request on the bus and returns; it does not itself call a backend. The pipeline tool studio_revise is what actually runs the revise/land/promote sequence. Gen Protocol op: revise.
Parameters: requestId (required), Caller-minted ULID naming this job: Crockford base32, 26 characters, first character 0-7. Mint a fresh one per request.; clipId (required), Id of the clip whose region is repainted. Must exist.; regionStartTicks (required), Region start, in absolute timeline ticks from 0 (PPQ 960: 960 ticks is a quarter note, 3840 is one 4/4 bar). Must be strictly before regionEndTicks — an empty or inverted region is refused.; regionEndTicks (required), Region end, in absolute timeline ticks from 0 (PPQ 960: 960 ticks is a quarter note, 3840 is one 4/4 bar). Must be strictly after regionStartTicks.; scope (required), What the repaint touches: the scalar 'all-stems', or one stem name, or an array of stem names from 'vocals', 'drums', 'bass' and 'other'. 'all-stems' is valid only as a scalar; an array selects those stems and null-preserves the rest.; request (required), The rest of the Gen Protocol 'revise' request. instruction is required and variants optional; the full shape is in gen-protocol.v1.yaml (see gen-protocol-mapping.md).
Journaled: yes.
Undoable: no.
Inverse: none.

### gen.extend
What it does: Journal a request to continue a clip's audio by addedDurationSeconds. RECORDS the request on the bus and returns; it does not itself call a backend. The pipeline tool studio_extend runs the whole sequence. Gen Protocol op: extend.
Parameters: requestId (required), Caller-minted ULID naming this job: Crockford base32, 26 characters, first character 0-7. Mint a fresh one per request.; clipId (required), Id of the clip whose audio is continued. Must exist.; addedDurationSeconds (required), How much new audio to append, in SECONDS (not ticks), greater than 0.; request (required), The Gen Protocol 'extend' request body; free-form here, with the full shape in gen-protocol.v1.yaml (see gen-protocol-mapping.md).
Journaled: yes.
Undoable: no.
Inverse: none.

### gen.layer
What it does: Journal a request for a new stem that fits existing context audio (lego mode). RECORDS the request on the bus and returns; it does not itself call a backend. The pipeline tool studio_layer runs the whole sequence. Gen Protocol op: layer.
Parameters: requestId (required), Caller-minted ULID naming this job: Crockford base32, 26 characters, first character 0-7. Mint a fresh one per request.; targetTrackId (required), Id of the track the new stem is destined for; it must already exist.; contextClipId (optional), Optional id of an existing clip to fit the new stem against harmonically and rhythmically. Omitted generates without existing-audio context.; instruction (required), What the new stem should be, e.g. 'bass' or 'sax lead' — matched verbatim against ace_generator.generate_lego's instruction. Non-empty.; request (required), The Gen Protocol 'layer' request body; free-form here, with the full shape in gen-protocol.v1.yaml (see gen-protocol-mapping.md).
Journaled: yes.
Undoable: no.
Inverse: none.

### gen.retake
What it does: Journal a request for a fresh-seed variation of an existing take, same prompt. RECORDS the request on the bus and returns; it does not itself call a backend. Gen Protocol op: retake.
Parameters: requestId (required), Caller-minted ULID naming this job: Crockford base32, 26 characters, first character 0-7. Mint a fresh one per request.; sourceTakeId (required), Id of the existing take to re-roll: same prompt, fresh seed. Must be a take this project knows.; request (required), The Gen Protocol 'retake' request body: the same prompt as sourceTakeId with a fresh seed and no instruction changes. Full shape in gen-protocol.v1.yaml (see gen-protocol-mapping.md).
Journaled: yes.
Undoable: no.
Inverse: none.

### gen.autocomplete
What it does: Journal a request to fill missing instruments in around an existing partial mix. RECORDS the request on the bus and returns; it does not itself call a backend. Gen Protocol op: autocomplete. Flag v1.1.
Parameters: requestId (required), Caller-minted ULID naming this job: Crockford base32, 26 characters, first character 0-7. Mint a fresh one per request.; clipId (required), Id of the partial-mix clip to fill instruments in around. Must exist.; request (required), The Gen Protocol 'autocomplete' request body; free-form here, with the full shape in gen-protocol.v1.yaml (see gen-protocol-mapping.md).
Journaled: yes.
Undoable: no.
Inverse: none.

### gen.cover
What it does: Journal a request for a style-transfer cover of a reference clip. RECORDS the request on the bus and returns; it does not itself call a backend. Gen Protocol op: cover. Flag v1.1.
Parameters: requestId (required), Caller-minted ULID naming this job: Crockford base32, 26 characters, first character 0-7. Mint a fresh one per request.; referenceClipId (required), Id of the clip whose performance is re-styled. Must exist.; request (required), The Gen Protocol 'cover' request body, including coverStrength; the full shape is in gen-protocol.v1.yaml (see gen-protocol-mapping.md).
Journaled: yes.
Undoable: no.
Inverse: none.

### gen.separate
What it does: Journal a request to split a clip into stems. Like every gen.* command this RECORDS the request on the bus and returns; it does not itself call a backend. The working paths are the studio_revise/extend/layer pipeline tools and studio_open_in_studio.
Parameters: requestId (required), Caller-minted ULID naming this job: Crockford base32, 26 characters, first character 0-7. Mint a fresh one per request.; clipId (required), Id of the clip to split into stems. Must exist.; engine (required), Which separator to run: 'demucs' (htdemucs 4-stem separation, the default separator) or 'ace-extract' (ACE-Step generative extraction, which lineage labels GENERATIVE rather than separated).
Journaled: yes.
Undoable: no.
Inverse: none.

### gen.cancel
What it does: Cancel an in-flight gen request. KNOWN v1 BACKEND GAP (see gen-protocol-mapping.md): the current Python backend's cancel_generation RPC is a single global cancel flag, not per-job; the Gen Protocol's per-requestId cancel is the target contract, not yet the shipped behavior.
Parameters: requestId (required), The requestId of the job to cancel: Crockford base32 ULID, 26 characters, first character 0-7. See this command's own note — the shipped backend cancel is global, not per-request.
Journaled: yes.
Undoable: no.
Inverse: none.

### gen.finalize
What it does: Re-render a committed draft take at full quality and splice it in place: same region, same lineage, journaled as a swap. This is the draft/commit re-render swap named in 02-ARCH section 4's gen catalog line.
Parameters: requestId (required), Caller-minted ULID naming this re-render job: Crockford base32, 26 characters, first character 0-7. Distinct from the requestId that produced draftTakeId.; draftTakeId (required), The committed draft take being re-rendered at higher quality.; targetQualityRung (required), Quality rung to re-render at: 'draft' (acestep-v15-turbo, 8 steps), 'standard' (acestep-v15-quality) or 'full' (acestep-v15-base, 50 steps). finalize always targets a rung above the draft's own.; request (required), The same request body as the revise op that produced draftTakeId — identical region, instruction and scope. Only the model/steps rung changes. See gen-protocol-mapping.md.
Journaled: yes.
Undoable: no.
Inverse: none.

### gen.landed
What it does: Written by the engine (actor.kind=system) when any async gen.* request reaches a terminal success state. Carries the provenance the lineage tree and export manifests read: asset hashes + engine identity, per 02-ARCH section 4 ('completion journals gen.landed with asset hashes') and section 5 ('terminal ... with artifact paths + content hashes + engine identity for lineage').
Parameters: requestId (required), Matches the requestId of the gen.* command that started this job.; sourceCommand (required), Dotted catalog name of the gen.* command that started this job, e.g. 'gen.revise'. Lineage and the export manifest read it to say which operation produced the take.; takeId (required), Id of the candidate take this job produced. take.promote / take.discard / take.purge address it by this id.; assetHashes (required), The audio this job produced, keyed by 'mix' for a single-file take or by stem name ('vocals', 'drums', 'bass', 'other') for a per-stem take. Each value is a 64-character lowercase blake3 hex hash.; engineIdentity (required), Which engine produced the audio, for lineage and the AI-disclosure manifest: model and device are required, steps and seed are optional and present only when the backend reported them.; latencySeconds (optional), Optional wall-clock duration of the job in seconds, 0 or more. Omitted when it was not measured.
Journaled: yes.
Undoable: no.
Inverse: none.

### take.promote
What it does: Commit a generated take into the timeline, splicing it into (or creating) a clip. This is the undoable step that actually mutates the visible project; the gen.* request that produced the take is not itself undoable.
Parameters: takeId (required), Id of the candidate take to commit — the takeId gen.landed reported.; targetClipId (required), Clip the take is spliced into; for a new gen.song this may be a clip created as part of promotion.
Journaled: yes.
Undoable: yes.
Inverse: explicit (take.discard).

### take.discard
What it does: Discard a generated take. The take's asset stays under takes/ until the user purges it (section 6); discard only removes it from the active candidate list, so it remains reversible.
Parameters: takeId (required), Id of the candidate take to drop from the active list. Its audio stays under takes/ until a purge, so this stays reversible.
Journaled: yes.
Undoable: yes.
Inverse: explicit (take.promote).

### take.purge
What it does: Mark an un-promoted candidate take offline so its unreferenced audio may be reclaimed. The journaled state change preserves lineage and is undoable.
Parameters: takeId (required), Id of an UN-PROMOTED candidate take to mark offline so its audio can be reclaimed. Manage tier: the tool also needs confirm: true.
Journaled: yes.
Undoable: yes.
Inverse: self.

### take.restore
What it does: Restore an offline candidate take's journal state after undoing take.purge. Audio reclamation is host-managed and may require regeneration or recovery before audition.
Parameters: takeId (required), Id of an offline take to bring back to candidate status. Only the journal state is restored — the audio may need regeneration before it can be auditioned.
Journaled: yes.
Undoable: yes.
Inverse: explicit (take.purge).

### take.auditionMix
What it does: Declared as choosing which stems of a per-stem take are audible while auditioning. NOT IMPLEMENTED: the executor checks the takeId, ignores the stem list and returns ok with mutated:false, so nothing changes about what you hear.
Parameters: takeId (required), Id of the per-stem take being auditioned. Must be a take this project knows.; stems (required), Which stems should be audible: at least one of 'vocals', 'drums', 'bass', 'other', 'mix'. NOT IMPLEMENTED: the executor checks takeId, ignores this list entirely and returns ok with mutated:false. Nothing in the engine stores or reads it, so what you hear does not change.
Journaled: no.
Undoable: no.
Inverse: none.

## io  (7 commands)
### import.audio
What it does: Import an external audio file, copy it content-addressed into audio/, and place it as a clip.
Parameters: sourcePath (required), Filesystem path of the audio file to bring in. It is COPIED content-addressed into the package's audio/ directory, so the original may move afterwards.; targetTrackId (required), Id of the existing track the imported clip is placed on.; separate (optional), Declared as 'run htdemucs on import and place stems as separate tracks'. NOT IMPLEMENTED and silently ignored: the file is imported and placed as one ordinary clip. Use studio_open_in_studio for separation, or import.stems with stems you separated yourself. Default false.; conform (optional), Declared as 'time-stretch the imported audio to the project tempo on import'. NOT IMPLEMENTED and silently ignored: the audio is imported at its own length. Default false. To fit it to the tempo, place it and then call clip.warp.set.; startTicks (optional), Optional clip start on the target track, in absolute timeline ticks from 0 (PPQ 960: 960 ticks is a quarter note, 3840 is one 4/4 bar). Default 0.; clipId (optional), Optional caller-minted id for the placed clip. Omitted, the host mints one and returns it in the result.
Journaled: yes.
Undoable: yes.
Inverse: explicit (clip.remove).

### import.stems
What it does: Bring a folder of stem files in as one aligned track per stem, each copied content-addressed into audio/. This is the working multi-track import — studio.importStemSession is not.
Parameters: sourceDir (required), Filesystem path of a directory of stem files. Every audio file directly in it is copied content-addressed into audio/ and placed on its own track.; targetTrackId (required), Id of the FIRST track of the group; the remaining stems land on tracks created after it.; startTicks (optional), Optional common start for every stem, in absolute timeline ticks from 0 (PPQ 960: 960 ticks is a quarter note, 3840 is one 4/4 bar). Default 0, which keeps the stems aligned with each other.; groupName (optional), Optional label for the imported group, echoed back in the result. Defaults to 'Imported stems'.
Journaled: yes.
Undoable: yes.
Inverse: explicit (track.remove).

### export.master
What it does: Bounce the full master mix to a file, via the render graph's offline path (same graph as realtime, per 02-ARCH section 3). WAV is 24-bit at the project rate; AAC via Apple AudioToolbox. Optional loudness target + provenance manifest (L13).
Parameters: outputPath (required), Filesystem path to write the bounce to, file name included. Manage tier: this writes outside the project, so the tool also needs confirm: true.; format (required), Deliverable format. 'wav' (24-bit at the project rate) and 'aac' (AAC-LC via Apple AudioToolbox) are what this build writes; 'flac' is in the enum but the exporter REFUSES it with a typed Unsupported error — it lands with the IO codec pass.; sampleRateHz (optional), Optional output rate. The enum admits 44100 and 48000, but v1 always exports at the PROJECT rate and refuses any value that differs from it, so the only value accepted is whichever of the two the project already runs at. Omit unless you are asserting that rate.; loudnessTarget (optional), Optional EBU R128 integrated-LUFS normalization for the master: 'streaming' (-14), 'club' (-7), 'broadcast' (-16), or 'none'. Omitted or 'none' writes the mix exactly as bounced.; includeManifest (optional), Optional. true also writes the AI-disclosure provenance manifest next to the audio (<output>.manifest.json). Omitted is false.
Journaled: yes.
Undoable: no.
Inverse: none.

### export.stems
What it does: Bounce one 24-bit WAV per TRACK into a directory, at the project rate and without loudness normalization. The declared 'stems' filter and the 'flac' format are not implemented; see those parameters.
Parameters: outputDir (required), Directory to write one file per track into; created if missing. Manage tier: the tool also needs confirm: true.; format (required), Stem format. Only 'wav' (24-bit, project rate, never loudness-normalized) is written; 'flac' is in the enum but the exporter refuses anything that is not wav with a typed Unsupported error.; stems (optional), Declared as a filter over the four separated stems 'vocals', 'drums', 'bass' and 'other'. NOT IMPLEMENTED and optional in every sense: the exporter ignores it and always writes one WAV per TRACK, whether it is present or omitted.; includeManifest (optional), Optional. true also writes the AI-disclosure provenance manifest next to the stems (stems.manifest.json). Omitted is false.
Journaled: yes.
Undoable: no.
Inverse: none.

### export.region
What it does: Bounce a time region of the master mix to a file (24-bit WAV or AAC). Optional loudness target + provenance manifest (L13).
Parameters: outputPath (required), Filesystem path to write the region bounce to, file name included. Manage tier: this writes outside the project, so the tool also needs confirm: true.; startTicks (required), Region start, in absolute timeline ticks from 0 (PPQ 960: 960 ticks is a quarter note, 3840 is one 4/4 bar).; endTicks (required), Region end, in absolute timeline ticks from 0 (PPQ 960: 960 ticks is a quarter note, 3840 is one 4/4 bar); must be after startTicks.; format (required), Deliverable format. 'wav' (24-bit at the project rate) and 'aac' (AAC-LC via Apple AudioToolbox) are what this build writes; 'flac' is in the enum but the exporter REFUSES it with a typed Unsupported error.; loudnessTarget (optional), Optional EBU R128 integrated-LUFS normalization for the region: 'streaming' (-14), 'club' (-7), 'broadcast' (-16), or 'none'. Omitted or 'none' writes the region exactly as bounced.; includeManifest (optional), Optional. true also writes the AI-disclosure provenance manifest next to the audio (<output>.manifest.json). Omitted is false.
Journaled: yes.
Undoable: no.
Inverse: none.

### export.manifest
What it does: Write the provenance manifest (rebuildable view over the journal, per section 6) to a standalone file.
Parameters: outputPath (required), Filesystem path to write the provenance manifest JSON to. Manage tier: this writes outside the project, so the tool also needs confirm: true. Use the studio_manifest READ tool if you only want to look at it.
Journaled: yes.
Undoable: no.
Inverse: none.

### publish.track
What it does: Journal the intent to publish an exported asset with its provenance certificate. The engine surface RECORDS this and returns executed:false — the majiks.online pipeline itself is the app's, shipped pre-Studio and out of this surface's scope.
Parameters: assetHash (required), blake3 hash of the already-exported asset to publish: 64 lowercase hex characters, the same spelling clip.place's assetHash uses.; title (required), Title the track is published under. Non-empty.; metadata (optional), Optional free-form metadata object handed to the publish pipeline unchanged. No shape is enforced here, and this build records it rather than sending it.
Journaled: yes.
Undoable: no.
Inverse: none.

## midi  (9 commands)
### midi.device.select
What it does: Pin a specific control map to a MIDI input port, or hand it back to auto-detect. Reach for this when a controller is being matched to the wrong map.
Parameters: device (required), Reported port name, e.g. 'USB MIDI Interface'.; map (optional), Optional map key (file stem or map name) to pin to this port, 'none' to leave the port unmapped, or 'auto' to go back to pattern auto-detect. Omitted leaves the current selection alone.
Journaled: no.
Undoable: no.
Inverse: none.

### midi.port.role.set
What it does: Set what a MIDI input port's KEYS do: play the instrument (default) or drive its control bindings.
Parameters: port (required), Reported port name, e.g. 'USB MIDI Interface'.; role (required), instrument (the DEFAULT): note messages play the selected instrument track and are recordable; the port's note-matched control bindings are suppressed, while its CC/pitch-bend bindings still fire. control: every binding fires and notes never sound.
Journaled: no.
Undoable: no.
Inverse: none.

### midi.learn.start
What it does: Begin listening for the next control a person touches, so the following midi.binding.set can bind it without anyone having to know its channel and CC number.
Parameters: device (optional), Optional port name to scope capture to, e.g. 'USB MIDI Interface'. Omitted takes the first control from any device.
Journaled: no.
Undoable: no.
Inverse: none.

### midi.learn.stop
What it does: Stop listening for a control. Any binding the session produced stays: it is undone with midi.binding.clear, not by closing the session.
Parameters: No parameters.
Journaled: no.
Undoable: no.
Inverse: none.

### midi.binding.set
What it does: Bind a physical knob, pad or key to a Studio action and persist it, so a controller can drive commands. Usually issued right after midi.learn.start captures the control.
Parameters: device (optional), Optional port name whose resolved map takes the binding. Omitted uses the learn session's captured device.; control (optional), Optional explicit control coordinates (type, channel, and number for note/CC). Omitted uses the learn session's captured control.; target (required), What firing this control DOES. kind 'command' submits a catalog command (name + a params template that may carry the '$value' and '$track:N' placeholders), 'builtin' runs a named built-in action, 'sterling' queues instruction text for the Sterling copilot.; valueMap (optional), Optional scaling from the controller's raw reading to the value the target receives. Omitted, the raw is normalized to 0..1 and handed over as-is.; label (optional), Optional human-readable name for the binding, shown in MIDI settings. Omitted leaves it unlabelled.; enabled (optional), Whether the binding fires at all. Default true; false keeps it on file without it acting.
Journaled: no.
Undoable: no.
Inverse: none.

### midi.binding.clear
What it does: Drop one binding from a port's user overlay map, so that control goes back to doing nothing (or to whatever the bundled map says).
Parameters: device (required), Reported MIDI port name whose user overlay map holds the binding, e.g. 'USB MIDI Interface'.; control (required), The exact control coordinates of the binding to drop — the same type/channel/number shape midi.binding.set matched on. There are no wildcards: a binding is cleared by naming it exactly.
Journaled: no.
Undoable: no.
Inverse: none.

### midi.map.import
What it does: Copy a MIDI map file someone else wrote into the user maps directory so this install can resolve ports against it. The file is copied, not linked.
Parameters: sourcePath (required), Filesystem path of the MIDI map file to bring in. It is COPIED into the user maps directory, so later edits to the original have no effect.; overwrite (optional), Optional. true replaces an existing user map with the same file name; false (the default) refuses rather than clobbering it.
Journaled: no.
Undoable: no.
Inverse: none.

### midi.map.export
What it does: Write a MIDI map out verbatim to a path of your choosing, e.g. to share it or check it into a repository. Manage tier because it writes outside the app's directories.
Parameters: map (required), Map key (file stem or map name).; outputPath (required), Filesystem path to write the map file to. Manage tier: this writes outside the app's own directories, so the tool also needs confirm: true.
Journaled: no.
Undoable: no.
Inverse: none.

### midi.reload
What it does: Re-read every bundled and user MIDI map from disk and re-resolve the connected ports against them — what to call after editing a map file by hand.
Parameters: No parameters.
Journaled: no.
Undoable: no.
Inverse: none.

## mixer  (13 commands)
### mix.gain
What it does: Set a track's mixer channel gain (distinct from clip.setGain, which trims an individual clip).
Parameters: trackId (required), Id of the track whose channel fader moves.; gainDb (required), Channel fader in dB, -60 to 12; 0 is unity. The bound is enforced by the executor, not only by this schema.
Journaled: yes.
Undoable: yes.
Inverse: self.

### mix.pan
What it does: Place a track in the stereo field, from hard left to hard right. Distinct from a drum pad's own pan, which device.zone.add carries.
Parameters: trackId (required), Id of the track whose pan moves.; pan (required), Stereo position, -1 is hard left and 1 is hard right; 0 is centre.
Journaled: yes.
Undoable: yes.
Inverse: self.

### mix.eq
What it does: Move one of the four fixed channel-EQ bands on a track: its frequency, its cut or boost, and optionally its bandwidth. Bands are addressed by index, not created.
Parameters: trackId (required), Id of the track whose channel EQ changes.; band (required), v1 channel EQ: 4 bands, index 0-3.; freqHz (required), Band centre frequency in Hz, 20 to 20000. The four bands start at 80, 250, 2500 and 8000 Hz.; gainDb (required), Cut or boost for this band in dB, -24 to 24; 0 is flat.; q (optional), Optional bandwidth (resonance): greater than 0, at most 10, higher is narrower. Bands start at 1. OMITTING it leaves the band's stored Q exactly as it was — it is not reset — and the inverse then leaves Q alone too.
Journaled: yes.
Undoable: yes.
Inverse: self.

### mix.send
What it does: Feed a track into one of the two fixed effect returns — 'a' is the reverb, 'b' is the delay — without routing the track away from master.
Parameters: trackId (required), Id of the track being sent from.; bus (required), Which of the two fixed effect returns to feed: 'a' is the REVERB return, 'b' is the DELAY return. Both sum into master.; amount (required), Send level, 0 sends nothing and 1 is unity. LINEAR, not dB.
Journaled: yes.
Undoable: yes.
Inverse: self.

### mix.master.gain
What it does: Move the master fader — the last gain stage before the limiter and the file. Reach for this to trim an export that is too hot, rather than pulling every channel down.
Parameters: gainDb (required), Master fader in dB, -60 to 12; 0 is unity. The bound is enforced by the executor, not only by this schema.
Journaled: yes.
Undoable: yes.
Inverse: self.

### mix.limiter.set
What it does: Enable/disable and configure the master limiter. mute/solo are on track.mute/track.solo, not here.
Parameters: enabled (required), true engages the master limiter, false bypasses it. Absolute, not a toggle; a new project starts with it off.; ceilingDb (optional), Optional output ceiling in dBFS, -6 to 0. A new project starts at -1; OMITTING this leaves the stored ceiling exactly as it was rather than resetting it.; releaseMs (optional), Optional release time in milliseconds, 1 to 1000. A new project starts at 50; OMITTING this leaves the stored release exactly as it was rather than resetting it.
Journaled: yes.
Undoable: yes.
Inverse: self.

### fx.add
What it does: Append an effect to the insert chain on a track, a bus/group node, or master. A SEPARATE registry from device.add, whose 'kind' enum is NOT widened: build_instrument hard-errors on a track with more than one device, so an effect in Track.devices would break the compile of every instrument track that also carries an effect. Its parameters become automatable IMMEDIATELY through track.fx.<fxId>.<paramKey> / bus.<nodeId>.fx.<fxId>.<paramKey> / master.fx.<fxId>.<paramKey> - no catalog schema change, because the autopoint/autolane target pattern already admits them. A NEW command name (E0 9.2).
Parameters: target (required), The fx HOST, as a NodeRef: 'track.<id>', 'bus.<id>' or 'master'. Master is addressable because a master-bus effect chain is table stakes for parity and falls out of the NodeRef grammar for free.; fxId (required), Opaque fx id, unique within this host's chain. Must not contain '.' so the ParamRef paths track.fx.<fxId>.<paramKey>, bus.<nodeId>.fx.<fxId>.<paramKey> and master.fx.<fxId>.<paramKey> stay parseable.; kind (required), Which effect to insert, from the CLOSED E5 vocabulary: 'eq', 'compressor', 'gate', 'delay', 'reverb', 'saturator', 'chorus', 'utility' or 'limiter'. An unknown kind fails loudly at the contract boundary rather than building a silent no-op node.
Journaled: yes.
Undoable: yes.
Inverse: explicit (fx.remove).

### fx.remove
What it does: Remove an effect from an insert chain. Undo restores the effect, its chain index, every stored parameter and its sidechain link - a multi-command inverse; the catalog hint is the declared fx.add. Unlike device.remove this refuses nothing for stored parameters: fx.param.set can restore them, so the guard device.remove needs would only make every configured effect unremovable. Refused only if the effect carries unknown fields no command in this build can restore.
Parameters: target (required), The fx HOST, as a NodeRef: 'track.<id>', 'bus.<id>' or 'master'. Master is addressable because a master-bus effect chain is table stakes for parity and falls out of the NodeRef grammar for free.; fxId (required), Opaque fx id, unique within this host's chain. Must not contain '.' so the ParamRef paths track.fx.<fxId>.<paramKey>, bus.<nodeId>.fx.<fxId>.<paramKey> and master.fx.<fxId>.<paramKey> stay parseable.
Journaled: yes.
Undoable: yes.
Inverse: explicit (fx.add).

### fx.move
What it does: Reorder one effect within its insert chain. Self-inverse: the inverse carries the prior index, and remove+insert is a rotation whose reverse restores exactly.
Parameters: target (required), The fx HOST, as a NodeRef: 'track.<id>', 'bus.<id>' or 'master'. Master is addressable because a master-bus effect chain is table stakes for parity and falls out of the NodeRef grammar for free.; fxId (required), Opaque fx id, unique within this host's chain. Must not contain '.' so the ParamRef paths track.fx.<fxId>.<paramKey>, bus.<nodeId>.fx.<fxId>.<paramKey> and master.fx.<fxId>.<paramKey> stay parseable.; index (required), New 0-based position in the chain. Chain order IS processing order.
Journaled: yes.
Undoable: yes.
Inverse: self.

### fx.param.set
What it does: Set one effect parameter. Parameters stay SPARSE: an absent key means the DSP default, exactly as build_instrument already implements it, so no default is ever materialized into the project. inverseShape is 'multi' because the declared inverse name cannot cover both directions - the real inverse is a fx.param.set carrying the prior value, OR a fx.param.clear when the key was absent, so an undo returns the key to ABSENT rather than to a written default. This is the parameter setter E1/E2 deliberately omitted for Device; E5 is the DSP lane and can supply the semantics E1/E2 could not.
Parameters: target (required), The fx HOST, as a NodeRef: 'track.<id>', 'bus.<id>' or 'master'. Master is addressable because a master-bus effect chain is table stakes for parity and falls out of the NodeRef grammar for free.; fxId (required), Opaque fx id, unique within this host's chain. Must not contain '.' so the ParamRef paths track.fx.<fxId>.<paramKey>, bus.<nodeId>.fx.<fxId>.<paramKey> and master.fx.<fxId>.<paramKey> stay parseable.; key (required), An effect parameter key from FX_PARAM_KEYS. Which keys a given kind honours is deliberately NOT validated: apply.rs runs on replay, so tightening the (kind, key) pairing later would break replay of a project that automated a key its kind ignores. A lane bound to an ignored key is surfaced by CompileReport.inert_lanes instead.; value (required), Parameter value. Journaled as a Num, so the integer/float SHAPE round-trips exactly.
Journaled: yes.
Undoable: yes.
Inverse: explicit (fx.param.set).

### fx.param.clear
What it does: Drop one stored effect parameter, restoring sparsity so the key reads as the DSP default again. Clearing a key that stores no value is a typed error, not a silent no-op: a no-op has no exact inverse to journal.
Parameters: target (required), The fx HOST, as a NodeRef: 'track.<id>', 'bus.<id>' or 'master'. Master is addressable because a master-bus effect chain is table stakes for parity and falls out of the NodeRef grammar for free.; fxId (required), Opaque fx id, unique within this host's chain. Must not contain '.' so the ParamRef paths track.fx.<fxId>.<paramKey>, bus.<nodeId>.fx.<fxId>.<paramKey> and master.fx.<fxId>.<paramKey> stay parseable.; key (required), An effect parameter key from FX_PARAM_KEYS. Which keys a given kind honours is deliberately NOT validated: apply.rs runs on replay, so tightening the (kind, key) pairing later would break replay of a project that automated a key its kind ignores. A lane bound to an ignored key is surfaced by CompileReport.inert_lanes instead.
Journaled: yes.
Undoable: yes.
Inverse: explicit (fx.param.set).

### fx.sidechain.set
What it does: Key an effect's detector from another node. A sidechain is an ORDERING CONSTRAINT, not an audio edge: it creates no routing edge and contributes no audio, but the source must be scheduled before the host or the detector reads a not-yet-written accumulator - exactly 0.0, i.e. silence, not a small error. Rejected at command time if the source does not resolve, is the host itself (that is the internal detector, not a link), is master, or would create a cycle over edges and links together. inverseShape is 'multi' because the inverse is a set-to-prior OR a clear.
Parameters: target (required), The fx HOST, as a NodeRef: 'track.<id>', 'bus.<id>' or 'master'. Master is addressable because a master-bus effect chain is table stakes for parity and falls out of the NodeRef grammar for free.; fxId (required), Opaque fx id, unique within this host's chain. Must not contain '.' so the ParamRef paths track.fx.<fxId>.<paramKey>, bus.<nodeId>.fx.<fxId>.<paramKey> and master.fx.<fxId>.<paramKey> stay parseable.; source (required), The KEY source, as a NodeRef: 'track.<id>' or 'bus.<id>'. Master is the sink and can never be a key source.
Journaled: yes.
Undoable: yes.
Inverse: explicit (fx.sidechain.set).

### fx.sidechain.clear
What it does: Return an effect's detector to its internal (self) key. Clearing an effect that has no link is a typed error, not a silent no-op.
Parameters: target (required), The fx HOST, as a NodeRef: 'track.<id>', 'bus.<id>' or 'master'. Master is addressable because a master-bus effect chain is table stakes for parity and falls out of the NodeRef grammar for free.; fxId (required), Opaque fx id, unique within this host's chain. Must not contain '.' so the ParamRef paths track.fx.<fxId>.<paramKey>, bus.<nodeId>.fx.<fxId>.<paramKey> and master.fx.<fxId>.<paramKey> stay parseable.
Journaled: yes.
Undoable: yes.
Inverse: explicit (fx.sidechain.set).

## project  (11 commands)
### project.new
What it does: Create a new .mstudio package on disk with an empty timeline. Initial tempo/timeSig/key are set by follow-up project.setTempo/setTimeSig/setKey commands so those mutations are uniformly journaled.
Parameters: name (required), Display name for the new project; also the .mstudio package's name on disk. Non-empty. This is a NAME, not a path — project.open is the one that takes a path.
Journaled: no.
Undoable: no.
Inverse: none.

### project.open
What it does: Open an existing .mstudio package: read project.json (checkpoint), replay any journal segment newer than the checkpoint, and hydrate the in-memory model.
Parameters: path (required), Filesystem path to an existing .mstudio package directory. Non-empty, and the package must already exist: this command never creates one.
Journaled: no.
Undoable: no.
Inverse: none.

### project.save
What it does: Write project.json as a checkpoint of the current journal tip and mark prior journal segments eligible for truncation once the write is durable.
Parameters: No parameters.
Journaled: no.
Undoable: no.
Inverse: none.

### project.setTempo
What it does: Set the project's global tempo in beats per minute. v1 has one tempo for the whole project (no tempo map / tempo automation).
Parameters: bpm (required), Tempo in beats per minute, greater than 0 and at most 999. Journaled as a Num, so the integer/float SHAPE is part of the hash chain: send 120, not 120.0, unless you mean a fractional tempo.
Journaled: yes.
Undoable: yes.
Inverse: self.

### project.setTimeSig
What it does: Set the bar length the grid, ruler and metronome count in, e.g. 4/4 or 6/8. One signature for the whole project in v1 — there is no signature map.
Parameters: numerator (required), Beats per bar — the TOP number of 4/4 — from 1 to 32.; denominator (required), Beat unit — the BOTTOM number of 4/4 — one of 1, 2, 4, 8, 16 or 32.
Journaled: yes.
Undoable: yes.
Inverse: self.

### project.setKey
What it does: Set the project's key/scale metadata (informational for v1; not enforced against note content).
Parameters: key (required), Key and scale as '<root> <mode>', e.g. 'C major' or 'A minor'. Root is A-G with an optional '#' or 'b'; mode is 'major' or 'minor'. Matches the keyscale vocabulary ace_generator.py already uses. Metadata only — note content is not checked against it.
Journaled: yes.
Undoable: yes.
Inverse: self.

### section.set
What it does: Create or update a named arrangement section marker. Catalog default inverse is section.remove (correct for the create case); when section.set updates an EXISTING sectionId's fields, the runtime executor uses a self-inverse (section.set with the prior name/startTicks/color) instead. See engine/contracts/README.md open question: this is an upsert command with a context-dependent inverse, which a static per-command inverseRule cannot fully express.
Parameters: sectionId (required), Caller-minted, stable id for the section; the engine never mints one. A fresh id CREATES a section, an existing id UPDATES it (this command is an upsert).; name (required), Section label shown in the arrangement ruler, e.g. 'Verse', 'Chorus', 'Bridge' or 'Drop'. Non-empty.; startTicks (required), Where the section begins, in absolute timeline ticks from 0 (PPQ 960: 960 ticks is a quarter note, 3840 is one 4/4 bar).; color (optional), Optional swatch, '#RRGGBB' hex with six digits and no alpha (e.g. '#FF8800'). Omitted leaves the section with no explicit colour.
Journaled: yes.
Undoable: yes.
Inverse: explicit (section.remove).

### section.remove
What it does: Delete an arrangement section marker. Only the label goes — no audio, clip or track is touched.
Parameters: sectionId (required), Id of an existing section. Removing an id that is not there is a typed error, not a silent no-op.
Journaled: yes.
Undoable: yes.
Inverse: explicit (section.set).

### marker.set
What it does: Create or update a timeline marker. Catalog default inverse is marker.remove (correct for the create case; P0-C proposal 1, APPROVED by the coordinating session 2026-07-11, mirroring section.set/section.remove); when marker.set updates an EXISTING markerId's fields, the runtime executor uses a self-inverse (marker.set with the prior positionTicks/label/color) instead, the same upsert nuance as section.set.
Parameters: markerId (required), Caller-minted, stable id for the marker; the engine never mints one. A fresh id CREATES a marker, an existing id UPDATES it (this command is an upsert).; positionTicks (required), Marker position, in absolute timeline ticks from 0 (PPQ 960: 960 ticks is a quarter note, 3840 is one 4/4 bar).; label (required), Text drawn on the marker in the ruler, e.g. 'Solo starts'. Non-empty.; color (optional), Optional swatch, '#RRGGBB' hex with six digits and no alpha (e.g. '#FF8800'). Omitted leaves the marker with no explicit colour.
Journaled: yes.
Undoable: yes.
Inverse: explicit (marker.remove).

### marker.remove
What it does: Remove a timeline marker. Added as marker.set's undo-completing counterpart (P0-C proposal 1, APPROVED by the coordinating session 2026-07-11), mirroring section.remove.
Parameters: markerId (required), Id of an existing marker. Removing an id that is not there is a typed error, not a silent no-op.
Journaled: yes.
Undoable: yes.
Inverse: explicit (marker.set).

### project.setPhaseAnchor
What it does: Set the project-level phase anchor for the bar grid (L8 proposal). Warp markers (E7) and stem lead-in alignment both read it.
Parameters: anchorTicks (required), Ticks the project bar grid is shifted by, so the first tracked downbeat lands on a bar line without a lead-in. 0 is the v1 behaviour.
Journaled: yes.
Undoable: yes.
Inverse: self.

## routing  (6 commands)
### route.node.add
What it does: Add a routing node (bus or group) to the project routing graph. Track strips and master are implicit nodes and are never added or removed here.
Parameters: nodeId (required), Opaque id. Must not contain '.' so node refs stay parseable.; kind (required), What kind of node this is: 'bus' (an aux/effect destination fed by sends) or 'group' (a submix whose members route into it instead of straight to master).; name (required), Display name for the bus or group, e.g. 'Drum Bus'. Non-empty; nodeId, not this, is the wire identity.
Journaled: yes.
Undoable: yes.
Inverse: explicit (route.node.remove).

### route.node.remove
What it does: Remove a routing node and every edge incident to it. Undo restores the node and all removed edges (multi-command inverse; the catalog hint is the declared route.node.add).
Parameters: nodeId (required), Id of the bus/group node to remove. Every edge touching it is removed too, and undo restores the node with all of them.
Journaled: yes.
Undoable: yes.
Inverse: explicit (route.node.add).

### route.connect
What it does: Connect two routing nodes. Rejected at command time if the edge would create a cycle, so the audio thread can never discover one.
Parameters: edgeId (required), Caller-minted, stable id for the new edge: letters, digits, '_' and '-' only, never '.'. Must not already be in use.; from (required), Source node ref: 'track.<id>', 'bus.<id>' or 'master'.; to (required), Destination node ref: 'track.<id>', 'bus.<id>' or 'master'.; level (required), Linear send level for the new edge, 0 (silent) to 4; 1 is unity. Linear, not dB.; tap (required), Where the source is tapped: 'pre' (before its fader, so the send is independent of the fader) or 'post' (after it).
Journaled: yes.
Undoable: yes.
Inverse: explicit (route.disconnect).

### route.disconnect
What it does: Delete one edge from the routing graph, silencing that path. Undo re-creates the edge with the level and tap it had, so this is the safe way to try a routing change.
Parameters: edgeId (required), Id of the edge to remove. Undo re-creates it with the same level and tap.
Journaled: yes.
Undoable: yes.
Inverse: explicit (route.connect).

### route.edge.set
What it does: Set an existing routing edge's level and tap. Both are required so the self-inverse restores the exact prior edge state.
Parameters: edgeId (required), Id of an existing edge.; level (required), Linear send level, 0 (silent) to 4; 1 is unity. Linear, not dB.; tap (required), Where the source is tapped: 'pre' (before its fader, so the send is independent of the fader) or 'post' (after it, so the fader rides the send too).
Journaled: yes.
Undoable: yes.
Inverse: self.

### route.node.set
What it does: Set a routing node's (bus or group) fader gain in dB — the node fader of DESIGN-E5-routing.md §4.3. The static half of the same fader the bus.<nodeId>.gain automation lane drives (when that lane exists, the lane value takes precedence for the rendered gain). Self-inverse carries the prior gain.
Parameters: nodeId (required), Id of the bus/group node whose fader moves. Track strips and master are not addressable here — mix.gain and mix.master.gain own those.; gainDb (required), Node fader in dB, -60 to 12; 0 is unity. When a bus.<nodeId>.gain automation lane exists, the lane value wins for the rendered gain and this is the static fallback.
Journaled: yes.
Undoable: yes.
Inverse: self.

## session  (1 commands)
### studio.importStemSession
What it does: Declared as bringing a Stem Sessions multitrack session onto the timeline as tracks+clips. What it actually does in this build is add ONE empty placeholder track named after the id — no session is looked up, no audio is copied, no clips are created. import.stems is the working multi-track import. Flag v1.1.
Parameters: stemSessionId (required), Id of the Stem Sessions session to bring in. In this build it is used ONLY to mint a placeholder track ('trk_stems_<id>', named 'Stem Session <id>'): no session is looked up, no audio is copied and no clips are created.
Journaled: yes.
Undoable: yes.
Inverse: explicit (track.remove).

## track  (16 commands)
### track.add
What it does: Create an empty track to put clips, an instrument or effects on. The id is yours to mint and is permanent; index optionally places it in the list, otherwise it is appended.
Parameters: trackId (required), Caller-minted, stable id for the new track; the engine never mints one, because a minted id would make replay diverge from the live model. An id already in use is refused, never merged.; name (required), Display name on the track header, e.g. 'Lead Vocal'. Non-empty, need not be unique, and is NOT the identity — trackId is.; index (optional), Optional 0-based insert position; 0 makes it the first track. May equal the current track count (append), and anything larger is refused. Omitted appends.
Journaled: yes.
Undoable: yes.
Inverse: explicit (track.remove).

### track.remove
What it does: Delete a track along with every clip, device, effect, send and automation lane on it. Undo restores all of it, so this is reversible; the audio assets under audio/ are content-addressed and are not deleted.
Parameters: trackId (required), Id of the track to delete. Every clip, device, effect, send and automation lane on it goes too, and undo restores all of them.
Journaled: yes.
Undoable: yes.
Inverse: explicit (track.add).

### track.rename
What it does: Change the display name a person sees on a track header. The trackId is unaffected: ids are the wire identity and never change, so every clip, lane and binding that names this track keeps working.
Parameters: trackId (required), Id of the track to rename. The id itself never changes — it is the wire identity for the life of the project.; name (required), New display name for the track. Non-empty.
Journaled: yes.
Undoable: yes.
Inverse: self.

### track.reorder
What it does: Move a track to a different slot in the track list. Display order only: it changes nothing about routing or the mix.
Parameters: trackId (required), Id of the track to move.; newIndex (required), 0-based destination slot. Must be strictly LESS than the current track count — unlike track.add's index, which may equal it.
Journaled: yes.
Undoable: yes.
Inverse: self.

### track.setColor
What it does: Give a track a colour in the timeline and mixer, so an arrangement can be read at a glance. Display only — it changes nothing about the audio.
Parameters: trackId (required), Id of the track being recoloured.; color (required), Track colour as '#RRGGBB' hex: six hex digits, leading '#' required, no alpha channel (e.g. '#3AA6FF').
Journaled: yes.
Undoable: yes.
Inverse: self.

### track.setHeight
What it does: Set how tall a track's lane is drawn in the timeline, e.g. to give the one you are editing more room. Display only.
Parameters: trackId (required), Id of the track whose lane height changes.; heightPx (required), Lane height in points, 24 to 400. Purely how tall the lane is drawn; it changes nothing about the audio.
Journaled: yes.
Undoable: yes.
Inverse: self.

### track.mute
What it does: Silence a whole track, or bring it back. Absolute rather than a toggle, so it is safe to send the same value twice; the state is journaled and undoable, and it is honoured by playback and by the master bounce.
Parameters: trackId (required), Id of the track to mute or unmute.; muted (required), true silences the track in playback and in every bounce, false unmutes it. Absolute, not a toggle.
Journaled: yes.
Undoable: yes.
Inverse: self.

### track.solo
What it does: Hear one track (or a set of them) on its own by silencing everything not soloed. Honoured by playback and the master bounce, and deliberately IGNORED by stem export, which always writes every track.
Parameters: trackId (required), Id of the track to solo or unsolo.; soloed (required), true solos the track (only soloed tracks are heard), false unsolos. Absolute, not a toggle. Honoured by the master bounce and deliberately IGNORED by stem export, which always writes every track.
Journaled: yes.
Undoable: yes.
Inverse: self.

### track.arm
What it does: Arm or disarm a track for recording. The armed track is the capture target for record.start; arming is journaled and undoable. Arming does not open the microphone — that happens at record.start (or opt-in record.inputListen).
Parameters: trackId (required), Id of the track to arm. record.start captures onto armed tracks.; armed (required), true arms the track for recording, false disarms. Absolute, not a toggle. Arming alone never opens the microphone — record.start or record.inputListen does.
Journaled: yes.
Undoable: yes.
Inverse: self.

### track.setInputChannel
What it does: Choose which hardware input channel an audio track records from. On a four-input interface (e.g. Zoom AMS-44), set track 1 to channel 0, track 2 to channel 1, and so on, arm all four, and record once — each track lands its own channel. Journaled and undoable.
Parameters: trackId (required), Id of the audio track whose hardware input assignment changes.; channel (required), 0-based hardware input channel this track records from: channel 0 is the first input on the interface. On a four-input box, set 0, 1, 2, 3 across four armed tracks and one pass lands each channel on its own track.
Journaled: yes.
Undoable: yes.
Inverse: self.

### device.add
What it does: Add an instrument to a track. Its parameters become automatable IMMEDIATELY through the existing ParamRef path track.device.<deviceId>.<paramKey> — no contract change, which is what E0 3 promised. A NEW command name (E0 9.2).
Parameters: trackId (required), Id of the track that will host the instrument. Give a track only ONE device: a second device is accepted here (only a duplicate deviceId is refused) but the render compile then hard-errors, because the baked note lane is per track and a second instrument would have no notes to play.; deviceId (required), Opaque device id. Must not contain '.' so the ParamRef path track.device.<deviceId>.<paramKey> stays parseable.; kind (required), Which instrument to build: 'synth' (the four-waveform subtractive synth), 'sampler' (pitched, zone-mapped audio) or 'drum' (one pad per key). The E2 instrument vocabulary, and CLOSED — an unknown kind fails at the contract boundary.
Journaled: yes.
Undoable: yes.
Inverse: explicit (device.remove).

### device.remove
What it does: Remove an instrument from a track. Refused if the device carries stored parameters this build has no command to restore, so removing it is always undoable.
Parameters: trackId (required), Id of the track the instrument sits on.; deviceId (required), Opaque device id. Must not contain '.' so the ParamRef path track.device.<deviceId>.<paramKey> stays parseable.
Journaled: yes.
Undoable: yes.
Inverse: explicit (device.add).

### device.zone.add
What it does: Bind an audio source to a sampler zone or a drum pad. This is what makes kind 'sampler' and kind 'drum' reachable at all: Device.params is Num-only and could never name an asset. A NEW command name (E0 9.2) — device.add is deliberately NOT widened with an optional sourceId, because replay does not validate params and an older binary would verify the chain and then silently build a sampler with no audio.
Parameters: trackId (required), Id of the track the sampler/drum device sits on.; deviceId (required), Opaque device id. Must not contain '.' so the ParamRef path track.device.<deviceId>.<paramKey> stays parseable.; zoneId (required), Opaque, stable zone id. Identity for edit and undo.; sourceId (required), Content-addressed asset id — the SAME registry clip.place's assetHash names. Resolved render-side through the same loaded-source map, with the same loud 'references unloaded source' failure.; rootPitch (required), The MIDI note the recording sounds at, 0 to 127; a sampler reads at 2^((pitch-rootPitch)/12). Ignored by kind 'drum', which does not pitch-track.; loPitch (required), Lowest MIDI key the zone covers, 0 to 127.; hiPitch (required), Highest MIDI key the zone covers, 0 to 127. Must be >= loPitch, and must EQUAL loPitch on a 'drum' device, because a pad is one key.; gainDb (optional), Optional zone/pad gain in dB. Default 0, which is unity.; pan (optional), Optional pad pan, -1 is hard left and 1 is hard right; default 0 is centre. Honoured by kind 'drum'; IGNORED by 'sampler', which is a pitched instrument sitting on the track's own pan.
Journaled: yes.
Undoable: yes.
Inverse: explicit (device.zone.remove).

### device.zone.remove
What it does: Remove one source binding from a sampler or drum device. The inverse carries every field the zone held, gain and pan included, so remove+add is exact. Refused if the zone carries unknown fields this build has no command to restore. There is no device.zone.set: an edit is remove+add, which keeps every inverse exact without inventing per-field defaults.
Parameters: trackId (required), Id of the track the sampler/drum device sits on.; deviceId (required), Opaque device id. Must not contain '.' so the ParamRef path track.device.<deviceId>.<paramKey> stays parseable.; zoneId (required), Opaque, stable zone id.
Journaled: yes.
Undoable: yes.
Inverse: explicit (device.zone.add).

### device.param.set
What it does: Set one instrument parameter — the waveform an oscillator runs, its filter cutoff, its ADSR envelope. This is the setter E1/E2 deliberately omitted ("its inverse cannot be exact without per-parameter defaults that the DSP lane owns"); E5 answered that for fx.param.set and this is the same answer for Device: parameters stay SPARSE, an absent key means the DSP default exactly as build_instrument already implements it, so the inverse of setting an ABSENT key is device.param.clear and no default is ever materialized into the project. inverseShape is 'multi' because the declared inverse name cannot cover both directions. A NEW command name (E0 9.2) — device.add is deliberately NOT widened with optional params, because replay does not validate params and an older binary would verify the chain and then silently build an instrument with a different sound.
Parameters: trackId (required), Id of the track the instrument sits on.; deviceId (required), Opaque device id. Must not contain '.' so the ParamRef path track.device.<deviceId>.<paramKey> stays parseable.; key (required), An instrument parameter key from DEVICE_PARAM_KEYS — the SAME token the ParamRef path track.device.<deviceId>.<paramKey> already carries, so a value authored here and a lane automating it name the parameter identically. Which keys a given kind honours is deliberately NOT validated: apply.rs runs on replay, so tightening the (kind, key) pairing later would break replay of a project that authored a key its kind ignores (a drum rack ignores 'waveform'; every kind but 'synth' ignores it).; value (required), Parameter value. Journaled as a Num, so the integer/float SHAPE round-trips exactly.
Journaled: yes.
Undoable: yes.
Inverse: explicit (device.param.set).

### device.param.clear
What it does: Drop one stored instrument parameter, restoring sparsity so the key reads as the DSP default again. Clearing a key that stores no value is a typed error, not a silent no-op: a no-op has no exact inverse to journal.
Parameters: trackId (required), Id of the track the instrument sits on.; deviceId (required), Opaque device id. Must not contain '.' so the ParamRef path track.device.<deviceId>.<paramKey> stays parseable.; key (required), An instrument parameter key from DEVICE_PARAM_KEYS — the SAME token the ParamRef path track.device.<deviceId>.<paramKey> already carries, so a value authored here and a lane automating it name the parameter identically. Which keys a given kind honours is deliberately NOT validated: apply.rs runs on replay, so tightening the (kind, key) pairing later would break replay of a project that authored a key its kind ignores (a drum rack ignores 'waveform'; every kind but 'synth' ignores it).
Journaled: yes.
Undoable: yes.
Inverse: explicit (device.param.set).

## transport  (11 commands)
### transport.play
What it does: Start playback from the current transport position. Unjournaled per 02-ARCH section 4: transport commands are real commands on the bus but never appear in journal.jsonl.
Parameters: No parameters.
Journaled: no.
Undoable: no.
Inverse: none.

### transport.stop
What it does: Stop playback and leave the playhead exactly where it stopped. Use transport.seek afterwards to move it. Unjournaled per 02-ARCH section 4.
Parameters: No parameters.
Journaled: no.
Undoable: no.
Inverse: none.

### transport.seek
What it does: Jump the playhead to a position without starting or stopping playback. Unjournaled per 02-ARCH section 4.
Parameters: positionTicks (required), Where to put the playhead, in absolute timeline ticks from 0 (PPQ 960: 960 ticks is a quarter note, 3840 is one 4/4 bar). Seeking past the end of the material is allowed.
Journaled: no.
Undoable: no.
Inverse: none.

### transport.loop.set
What it does: Mark the region the transport should loop over. Start must be strictly before end, so a zero-length loop cannot be set. Unjournaled view/transport state.
Parameters: startTicks (required), Loop start, in absolute timeline ticks from 0 (PPQ 960: 960 ticks is a quarter note, 3840 is one 4/4 bar). Must be strictly BEFORE endTicks; equal or inverted is refused, so a zero-length loop cannot be set.; endTicks (required), Loop end, in absolute timeline ticks from 0 (PPQ 960: 960 ticks is a quarter note, 3840 is one 4/4 bar). Must be strictly AFTER startTicks.
Journaled: no.
Undoable: no.
Inverse: none.

### transport.loop.clear
What it does: Turn looping off and leave the transport playing straight through. Unjournaled view/transport state.
Parameters: No parameters.
Journaled: no.
Undoable: no.
Inverse: none.

### transport.metronome
What it does: Toggle the metronome click. v1 metronome is a simple click, no accent patterns or sound choices.
Parameters: enabled (required), true starts the click, false stops it. Absolute, not a toggle: sending true twice leaves the click on.
Journaled: no.
Undoable: no.
Inverse: none.

### record.start
What it does: Begin capturing from an audio input onto an armed track. The host reports captureOriginTicks and rolling from the actual input-ready transport clock; while rolling, an omitted startTicks records at the live playhead and a supplied startTicks is ignored unless punchOutTicks defines a punch region. Opens an INPUT-only stream and never an output stream; monitoring stays silent. Unjournaled transport-class action: the take and clip landed by record.stop are the journaled, undoable unit.
Parameters: trackId (required), The armed track to capture onto.; deviceId (optional), Optional input device name to open. Omitted opens the system default input.; startTicks (optional), With punchOutTicks, the punch-in position. Otherwise, when stopped, the position where the take lands after snapping to the anchored bar grid; while rolling without a punch it is ignored. Default: the capture origin.; punchOutTicks (optional), Punch-out position. When set, record.stop lands a clip of exactly punchOutTicks minus startTicks (the punch region), truncating or silence-padding the capture to fit. Omitted means open-ended capture until record.stop.
Journaled: no.
Undoable: no.
Inverse: none.

### record.rotate
What it does: Complete the current loop-record pass without stopping or reopening the input stream. The host rotates the writer-side capture accumulator, immediately continues filling the next pass, and prepares the completed pass asynchronously before committing its atomic record transaction. Every pass is resampled to the project's sample rate if the input device differs, same as record.stop; the response reports deviceSampleRate, landedSampleRate, projectSampleRate and resampled. No-op when nothing is recording.
Parameters: No parameters.
Journaled: no.
Undoable: no.
Inverse: none.

### record.stop
What it does: Stop the active capture and land the recorded audio as a candidate take and a placed clip with human-origin lineage (txn.begin / gen.landed sourceCommand record.commit / clip.place / txn.commit). No-op when nothing is recording.
Parameters: No parameters.
Journaled: no.
Undoable: no.
Inverse: none.

### record.cancel
What it does: Discard the active capture without landing a take or clip. No-op when nothing is recording.
Parameters: No parameters.
Journaled: no.
Undoable: no.
Inverse: none.

### record.inputListen
What it does: Opt-in input listen for gain-staging and per-channel metering WITHOUT recording. Arming a track never opens the mic; this command (or record.start) does. The snapshot reports inputOpen so the UI can show when an input is live. Monitoring (hearing yourself through speakers) stays double-gated and is not enabled by this command.
Parameters: enabled (required), true opens the input for metering only (no landing); false closes it. Does not enable speaker monitoring.; deviceId (optional), Optional input device name to open. Omitted opens the system default input.
Journaled: no.
Undoable: no.
Inverse: none.

## txn  (2 commands)
### txn.begin
What it does: Open an atomic transaction: journaled commands until the matching txn.commit undo/redo as one unit. v1 transactions do not nest (one open txnId at a time).
Parameters: txnId (required), Caller-minted, stable id for the transaction; txn.commit must quote the same one. v1 does not nest — exactly one txnId may be open at a time.; reason (optional), Optional human-readable label for the unit of work, e.g. 'drag 3 clips'. Shown in undo history; omitted leaves it unlabelled.
Journaled: yes.
Undoable: no.
Inverse: none.

### txn.commit
What it does: Close the atomic transaction opened by the txn.begin with the same txnId. Conformance checks that every txn.commit has a preceding, matching, not-yet-closed txn.begin.
Parameters: txnId (required), The txnId of the open transaction to close. It must match a preceding txn.begin that is still open.
Journaled: yes.
Undoable: no.
Inverse: none.

