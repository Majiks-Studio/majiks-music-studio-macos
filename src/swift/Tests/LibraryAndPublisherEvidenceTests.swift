import Testing
import Foundation
import AppKit
import AVFoundation
@testable import MajiksMusicStudio

// MARK: - Library and Publisher evidence
//
// Every case below is a defect that was live on `feat/ms-342` and was found by
// reading the app against the SERVER it talks to
// (`/Users/aaronstransky/majiks.online`), not by guessing. Each test names the
// exact source of truth it was checked against.

// MARK: - ISRC on publish

@Suite("Publisher — ISRC survives a publish")
struct PublisherISRCTests {

    // `/api/studio-bridge/publish` is served by `server-wrapper.js`'s
    // `handleStudioPublish` (routed at server-wrapper.js:1678), NOT by the
    // Next.js route of the same path. That handler parses exactly one ISRC
    // input — `fields["request_isrc"]` (server-wrapper.js:1090). It never reads
    // `fields["isrc"]`. The PATCH route DOES honour it
    // (`body.isrc` at server-wrapper.js:535).
    //
    // The app meanwhile sends `isrc` as a form field AND suppresses
    // `request_isrc` whenever the candidate carries one
    // (`requestISRC: candidate.isrc.isEmpty && candidate.requestISRC`). So both
    // halves of "give this track an ISRC" failed at once, under a green
    // "Published: <title>" toast.

    @Test("a creator ISRC the publish endpoint drops is scheduled for the PATCH that honours it")
    func creatorISRCIsFollowedUp() {
        #expect(
            PublisherStore.isrcNeedingFollowUp(
                candidateISRC: "USABC1234567", returnedISRC: nil) == "USABC1234567",
            "the publish endpoint silently drops `isrc`; without a follow-up the track has none")
    }

    @Test("nothing to follow up when the candidate had no ISRC of its own")
    func noCandidateISRCNoFollowUp() {
        #expect(PublisherStore.isrcNeedingFollowUp(candidateISRC: "", returnedISRC: nil) == nil)
        #expect(PublisherStore.isrcNeedingFollowUp(candidateISRC: "   ", returnedISRC: nil) == nil)
    }

    @Test("the platform's own allocation wins — never clobber what the server assigned")
    func serverAssignedWins() {
        // Empty candidate, platform allocated: already handled by the existing
        // updateTrackISRC path, nothing to push.
        #expect(PublisherStore.isrcNeedingFollowUp(
            candidateISRC: "", returnedISRC: "USQT85926001") == nil)
        // Candidate AND server: the server row already carries one (the publish
        // upsert preserves `isrc` across re-publish — it is absent from the
        // ON CONFLICT DO UPDATE set at server-wrapper.js:1239). Pushing ours
        // would overwrite a live, possibly-registered code.
        #expect(PublisherStore.isrcNeedingFollowUp(
            candidateISRC: "USABC1234567", returnedISRC: "USQT85926001") == nil)
        // Same value both sides: no work.
        #expect(PublisherStore.isrcNeedingFollowUp(
            candidateISRC: "USABC1234567", returnedISRC: "USABC1234567") == nil)
    }

    @Test("an empty string from the server is treated as no ISRC, not as an ISRC")
    func emptyReturnedIsNotAnISRC() {
        // `publisher_rpc.py` builds the result with
        // `resp_data.get("data", {}).get("isrc", "")` and only sets the key when
        // truthy, but BackendViewModel also reads `isrcFormatted`. An empty
        // string reaching here must not be mistaken for a live code.
        #expect(PublisherStore.isrcNeedingFollowUp(
            candidateISRC: "USABC1234567", returnedISRC: "") == "USABC1234567")
    }
}

// MARK: - 401 vs 403

@Suite("Publisher — a plan cap is not a dead session")
struct PublisherAuthClassificationTests {

    // `authenticateBridge` (server-wrapper.js:136) answers 401 for EVERY genuine
    // auth failure — missing header, invalid token — and 400/404/503 for the
    // rest. It never returns 403. Every 403 a studio-bridge caller can receive
    // is an entitlement refusal: "Artist profile limit reached"
    // (server-wrapper.js:252), "Admin access required" (:867), the premium
    // sample gate in the sounds routes.
    //
    // `publisher_rpc.py` labelled 401 and 403 identically —
    // "Authentication failed (<code>)" — and `handleBridgeError` matched that
    // phrase and called `clearAuth()`, which DELETES the Keycloak access and
    // refresh tokens from the Keychain. Creating one artist profile too many on
    // the free tier signed the user out of majiks.online.

    @Test("a 403 entitlement refusal leaves the session alone")
    func permissionRefusalIsNotAuthFailure() {
        // The exact string the bridge produced before this was fixed on both
        // sides. The Swift guard must hold even if the Python wording regresses.
        #expect(PublisherStore.isSessionDead(
            #"Authentication failed (403): {"error":"Artist profile limit reached"}"#) == false,
            "hitting a plan cap must not delete the user's Keychain tokens")
        #expect(PublisherStore.isSessionDead(
            #"Permission denied (403): {"error":"Artist profile limit reached"}"#) == false)
        #expect(PublisherStore.isSessionDead("Server returned 403: premium asset") == false)
    }

    @Test("a real auth failure still ends the session — the guard is not blanket")
    func realAuthFailuresStillSignOut() {
        #expect(PublisherStore.isSessionDead(
            #"Authentication failed (401): {"error":"Invalid token"}"#) == true)
        #expect(PublisherStore.isSessionDead(
            "Not authenticated — sign in via the Publisher tab") == true)
        #expect(PublisherStore.isSessionDead("unauthorized_client") == true)
    }

    @Test("everything else is left to the caller")
    func unrelatedErrorsAreNeither() {
        #expect(PublisherStore.isSessionDead("Network error: The request timed out") == false)
        #expect(PublisherStore.isSessionDead(
            #"Server returned 402: {"error":"Promo track cap reached on the Free tier (10/10)."}"#) == false)
        #expect(PublisherStore.isSessionDead("Server returned 500: internal error") == false)
    }

    // Wiring, not just the pure function: a classifier nothing calls is
    // decoration. These drive the real `handleBridgeError` and read the real
    // published auth state.

    @MainActor
    @Test("handleBridgeError keeps an authenticated session across a 403")
    func handleBridgeErrorKeepsSessionOn403() {
        let store = PublisherStore()
        store.authState = .authenticated(keycloakId: "test-subject")
        store.handleBridgeError(NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                #"Authentication failed (403): {"error":"Artist profile limit reached"}"#]))
        #expect(store.authState.isAuthenticated == true,
                "a plan cap signed the user out of majiks.online")
    }

    @MainActor
    @Test("the 401 decision is still 'end it' — the guard did not disable sign-out")
    func theDecisionForARealAuthFailureIsStillSignOut() {
        // Deliberately asserts the DECISION rather than driving
        // `handleBridgeError` with a 401: the sign-out half calls `clearAuth()`,
        // which deletes the real `com.majik.musicstudio` Keychain items. A test
        // suite must not sign the developer out of majiks.online to prove a
        // point. `shouldEndSession` is the seam `handleBridgeError` guards on,
        // so this covers the same wiring without the destruction.
        let store = PublisherStore()
        #expect(store.shouldEndSession(for: NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                #"Authentication failed (401): {"error":"Invalid token"}"#])) == true)
        #expect(store.shouldEndSession(for: NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                #"Authentication failed (403): {"error":"Artist profile limit reached"}"#])) == false)
    }
}

// MARK: - Catalogue import

@Suite("Publisher — importing a catalogue track twice")
struct PublisherCatalogueImportTests {

    // `LibraryStore.addTrack` is `tracks.insert(track, at: 0)` — no dedupe. The
    // per-row Import button correctly hides itself once a row is
    // `.alreadyExists`, but "Import Selected" (CatalogueView.swift:416) imports
    // the whole selection without consulting per-row state, so
    // Select All → Import Selected re-imported every track that was already
    // local, adding a SECOND Track carrying an id already in the library.
    // Every `firstIndex(where: { $0.id == ... })` in the app then sees one of
    // the two, and `removeTrack` deletes both rows but only one audio file.

    @Test("states that mean the track is already here, or on its way")
    func redundantStates() {
        #expect(PublisherStore.importWouldDuplicate(
            .alreadyExists(localTrackId: UUID(), metadataDiffers: false)) == true)
        #expect(PublisherStore.importWouldDuplicate(
            .alreadyExists(localTrackId: UUID(), metadataDiffers: true)) == true)
        #expect(PublisherStore.importWouldDuplicate(.completed) == true)
        // An import already in flight: clicking "Import Selected" twice would
        // otherwise land the same track twice.
        #expect(PublisherStore.importWouldDuplicate(.downloading) == true)
        #expect(PublisherStore.importWouldDuplicate(.converting) == true)
        #expect(PublisherStore.importWouldDuplicate(.importing) == true)
    }

    @Test("states that must still be allowed through — the guard is not a mute button")
    func permittedStates() {
        #expect(PublisherStore.importWouldDuplicate(nil) == false)
        #expect(PublisherStore.importWouldDuplicate(.idle) == false)
        #expect(PublisherStore.importWouldDuplicate(
            .failed(message: "Download failed (HTTP 502)")) == false,
            "a failed import must stay retryable")
    }

    @MainActor
    @Test("importing an already-local track is a no-op, and an eligible one is not")
    func guardIsWiredIntoTheImport() async {
        let library = LibraryStore()
        let backend = BackendViewModel()
        let before = library.tracks.count

        // A URL that fails offline and immediately, so the only thing this test
        // measures is whether the guard ran BEFORE the download.
        let track = CatalogueTrack(from: [
            "trackId": .string("catalogue-row-1"),
            "title": .string("Fixture"),
            "audioUrl": .string("file:///majiks-does-not-exist/nothing.m4a"),
        ])

        let localId = UUID()
        let store = PublisherStore()
        store.importStates[track.trackId] = .alreadyExists(
            localTrackId: localId, metadataDiffers: false)
        await store.importCatalogueTrack(track, backend: backend, library: library)

        #expect(store.importStates[track.trackId]
                == .alreadyExists(localTrackId: localId, metadataDiffers: false),
                "the guard should have returned before the download even started")
        #expect(library.tracks.count == before)

        // Anti-vacuity: an eligible row must still reach the download and fail
        // there. If the guard swallowed everything, this state would not move.
        store.importStates[track.trackId] = .idle
        await store.importCatalogueTrack(track, backend: backend, library: library)
        if case .failed = store.importStates[track.trackId] {
            // expected — the download was attempted and failed
        } else {
            Issue.record("an idle row did not reach the download; the guard is too wide")
        }
        #expect(library.tracks.count == before)
    }
}

// MARK: - Server health

@Suite("Publisher — the server-health indicator measures the server")
struct PublisherHealthCheckTests {

    // Probed live on 2026-07-27, unauthenticated:
    //   GET https://majiks.online/api/studio-bridge/health -> 404
    //   GET https://majiks.online/api/health               -> 200 {"status":"ok"}
    // The old check polled the first URL and called anything under 500
    // reachable, so a 404 for a route that has never existed read as GREEN,
    // permanently, for any host that answers HTTP at all. Unmatched
    // `/api/studio-bridge/*` paths proxy to Next.js, which 404s
    // (majiks.online/CLAUDE.md:77); the health route the server actually serves
    // is `src/app/api/health/route.ts`.

    @Test("the health check points at the route that exists")
    func pointsAtTheRealRoute() {
        #expect(PublisherStore.healthCheckURL.path == "/api/health")
        #expect(PublisherStore.healthCheckURL.host == "majiks.online")
    }

    @Test("only a 2xx is healthy — a missing route is not")
    func onlySuccessIsHealthy() {
        #expect(PublisherStore.isHealthy(statusCode: 200) == true)
        #expect(PublisherStore.isHealthy(statusCode: 204) == true)
        #expect(PublisherStore.isHealthy(statusCode: 404) == false,
                "a 404 means the route is gone; the old check called it reachable")
        #expect(PublisherStore.isHealthy(statusCode: 401) == false)
        #expect(PublisherStore.isHealthy(statusCode: 301) == false)
        #expect(PublisherStore.isHealthy(statusCode: 500) == false)
        #expect(PublisherStore.isHealthy(statusCode: 503) == false)
        #expect(PublisherStore.isHealthy(statusCode: 0) == false)
    }
}

// MARK: - Library waveform

@Suite("Library — the player-bar waveform draws quiet audio visibly")
struct LibraryWaveformScaleTests {

    // `Sources/WaveformView.swift` normalises each file to its own peak, so the
    // absolute case the Studio waveform suffered (a whole file at -20 dBFS
    // rendering 4.2 pt of ink) does not arise here. What does arise is the
    // RELATIVE case: a file with one loud transient and a quiet body. Linear
    // amplitude drew that body at a tenth of the row and everything below about
    // -34 dBFS at the 2 pt floor, where all of it looks identical.
    //
    // This reuses `StudioWaveformScale` — the same curve, the same anchors —
    // rather than inventing a second one.

    @Test("a body at -20 dBFS under a full-scale transient is drawn, not implied")
    func quietBodyUnderALoudPeakIsVisible() {
        // A 90 pt row, the size the Library's rows and the player bar draw at.
        let row: Double = 90
        let linear = 0.1 * row * 0.9
        let curved = Double(StudioWaveformScale.height(forPeak: 0.1)) * row * 0.9

        #expect(linear < 9.0, "sanity: the shipped linear height for -20 dBFS")
        #expect(curved > 25.0,
                "the curve must lift -20 dBFS clear of the noise floor, got \(curved) pt")
    }

    @Test("the curve keeps loud and quiet ordered — it does not flatten dynamics")
    func dynamicsSurvive() {
        let loud = StudioWaveformScale.height(forPeak: 1.0)
        let mid = StudioWaveformScale.height(forPeak: 0.1)
        let quiet = StudioWaveformScale.height(forPeak: 0.01)
        #expect(loud > mid)
        #expect(mid > quiet)
        #expect(quiet > 0)
        #expect(loud / mid > 2.0,
                "a quiet passage and a loud one must not draw nearly the same height")
    }

    @Test("normalisation still puts the loudest bar at full height")
    func peakStillFillsTheRow() {
        // Order matters: normalise to the file peak FIRST, then curve. The curve
        // is anchored at 1.0, so the loudest bar is unchanged.
        #expect(StudioWaveformScale.height(forPeak: 1.0) == 1.0)
        #expect(StudioWaveformScale.height(forPeak: 0.0) == 0.0)
    }

    // The three tests above assert the CURVE. They passed identically whether or
    // not `WaveformView` applied it — reverting this view to linear left all of
    // them green, which is the whole "assert the artifact, not the assembly"
    // lesson. This one reads a real audio file through the real extraction
    // function and looks at the heights that come out.

    @Test("the view's own extraction returns curved heights, not raw amplitude")
    func extractionAppliesTheCurve() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("majiks-waveform-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("probe.wav")

        // 1000 frames, 10 buckets of 100. Bucket 0 holds a full-scale transient;
        // every other bucket is a steady -20 dBFS body. That is the real-world
        // shape this fix is about.
        let sampleRate = 44100.0
        let frames = 1000
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        // Scoped so the writer deallocates — AVAudioFile finalises the header on
        // deinit, and reading it back while the writer is still alive returns an
        // empty file. (It did, and the first version of this test read zero
        // buckets rather than wrong ones.)
        do {
            var writer: AVAudioFile? = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            let data = buffer.floatChannelData![0]
            for i in 0..<frames { data[i] = i < 100 ? 1.0 : 0.1 }
            try writer!.write(from: buffer)
            writer = nil
        }

        let heights = WaveformData.extractSamples(from: url, count: 10)
        #expect(heights.count == 10, "fixture did not decode; everything below would be vacuous")

        // The transient bucket: peak 1.0, normalised 1.0, curved 1.0.
        #expect(abs(heights[0] - 1.0) < 0.01)

        // The body buckets: peak 0.1 -> curved 0.3162. Linear would give 0.1.
        // The two are 3.16x apart, far outside any float-write tolerance.
        for (index, height) in heights.enumerated().dropFirst() {
            #expect(abs(height - 0.3162) < 0.01,
                    "bucket \(index) came back \(height); 0.1 means the curve was never applied")
        }
    }

    // The test above writes a MONO probe. That is exactly why nobody caught the
    // defect this one exists for.
    //
    // `extractSamples` built its own `AVAudioFormat(standardFormatWithSampleRate:
    // channels: 1)` and handed it to `AVAudioFile.read(into:)`, which does NOT
    // convert — it requires a buffer in the file's `processingFormat` and
    // returns kAudio_ParamError (-50) otherwise. So every file with more than
    // one channel decoded to `[]`, and EVERY view fed by `WaveformData` drew
    // nothing: these Library rows, the player bar's `CompactWaveformView` and
    // `AudioWaveformView`, and the Stem Sessions lanes. Three consumers, one
    // source, one bug.
    //
    // Not an edge case. Every audio file in the owner's library is
    // "2 ch, 48000 Hz, Int16" (afinfo), and htdemucs writes stereo stems, so
    // the failure rate on his machine was 100%. Measured on his own bass stem,
    // the shipped function returned 0 buckets.
    //
    // The ENGINE's waveform never had this bug, because it never touched
    // AVFoundation: `StudioHost::waveform` takes
    // `peak.max(frame[0].abs()).max(frame[1].abs())` over frames already
    // decoded by `load_wav_stereo_48k` — stereo by construction, no format to
    // negotiate. Two implementations of one idea disagreed and the one with a
    // format to get wrong got it wrong. This extractor now takes a true peak
    // across ALL channels, which is what the engine does.
    @Test("a stereo file decodes — the shipped code returned nothing for every file the owner owns")
    func stereoFilesDecodeLikeMonoOnes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "majiks-waveform-stereo-"
                + "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleRate = 44100.0
        let frames = 1000
        let mono = dir.appendingPathComponent("mono.wav")
        let stereo = dir.appendingPathComponent("stereo.wav")

        func write(_ url: URL, channels: AVAudioChannelCount) throws {
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
            // Scoped so the writer deallocates and finalises the header before
            // the read back, for the reason the mono test above documents.
            var writer: AVAudioFile? = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: Int(channels),
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for c in 0..<Int(channels) {
                let data = buffer.floatChannelData![c]
                for i in 0..<frames { data[i] = i < 100 ? 1.0 : 0.1 }
            }
            try writer!.write(from: buffer)
            writer = nil
        }

        try write(mono, channels: 1)
        try write(stereo, channels: 2)

        // VACUITY GUARD. If the "stereo" fixture is not actually stereo, every
        // assertion below passes against the shipped defect — which is the
        // whole reason this test sits next to a mono one.
        let opened = try AVAudioFile(forReading: stereo)
        // One interpolated literal, not a `+` concatenation: swift-testing's
        // message parameter is a `Comment`, which is ExpressibleByString
        // Interpolation but is not a `String`, so concatenation does not compile.
        #expect(opened.processingFormat.channelCount == 2,
                "the stereo fixture decoded as \(opened.processingFormat.channelCount) channel(s); this test cannot see the defect it was written for")

        let monoHeights = WaveformData.extractSamples(from: mono, count: 10)
        let stereoHeights = WaveformData.extractSamples(from: stereo, count: 10)

        #expect(monoHeights.count == 10,
                "the mono control failed to decode; the comparison below would be vacuous")
        #expect(stereoHeights.count == 10,
                "a stereo file produced \(stereoHeights.count) buckets. 0 is the shipped defect: AVAudioFile.read(into:) threw -50 into a mono buffer and the catch returned []")

        // Same signal in both channels, so the two must agree bucket for
        // bucket. Asserted as a difference against the mono CONTROL rather than
        // against hardcoded heights: the curve is already pinned by the tests
        // above, and this one is about the decode.
        for (index, expected) in monoHeights.enumerated()
        where index < stereoHeights.count {
            #expect(abs(stereoHeights[index] - expected) < 0.01,
                    "bucket \(index): stereo \(stereoHeights[index]) vs mono \(expected)")
        }
    }
}

// MARK: - Artwork cache and the one writer that overwrites in place

@Suite("Library — artwork cache invalidation")
struct LibraryArtworkInvalidationTests {

    // `ArtworkDecodeCache`'s own header states the Library "does not currently
    // overwrite in place (new UUID filenames)". That is true of every
    // `LibraryStore` setter — `setTrackArtwork`, `setAlbumArtwork`,
    // `setArtistPhoto` all mint `track-<uuid>.jpg` / `album-<uuid>.jpg` and all
    // call `remove` on the previous path first.
    //
    // It is NOT true of the Publisher. `importCatalogueTrack` writes to
    // `catalogue-<trackId>.jpg`, a path derived from the SERVER's stable track
    // id — so re-importing a row whose cover art changed on majiks.online
    // overwrites the same file, and the process-wide decode cache keeps serving
    // the old pixels for the life of the app.

    @Test("the catalogue import path is fixed per track — an overwrite, not a new file")
    func importPathIsStable() {
        let a = PublisherStore.importedArtworkURL(trackId: "abc-123")
        let b = PublisherStore.importedArtworkURL(trackId: "abc-123")
        #expect(a == b, "a stable path is exactly what makes this an in-place overwrite")
        #expect(a != PublisherStore.importedArtworkURL(trackId: "abc-124"))
    }

    @Test("without invalidation a same-path overwrite serves the old pixels; remove() cures it")
    func inPlaceOverwriteNeedsRemoval() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("majiks-art-invalidation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("catalogue-fixed.png")

        func png(width: Int, height: Int) throws -> Data {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            return rep.representation(using: .png, properties: [:])!
        }

        try png(width: 8, height: 8).write(to: path)
        let first = ArtworkDecodeCache.image(at: path)
        #expect(first?.size.width == 8, "fixture did not decode; the rest would be vacuous")

        // Replace IN PLACE, as the catalogue import does.
        try png(width: 32, height: 32).write(to: path)
        #expect(ArtworkDecodeCache.image(at: path)?.size.width == 8,
                "this stale read is the hazard the import fix has to prevent")

        ArtworkDecodeCache.remove(url: path)
        #expect(ArtworkDecodeCache.image(at: path)?.size.width == 32,
                "remove(url:) must be what lets the new bytes through")
    }

    @Test("the import's own artwork writer evicts before it writes")
    func importWriterEvicts() throws {
        // The test above proves the HAZARD and the CURE. It passed whether or
        // not the import used the cure, which is the survivor shape. This drives
        // the function the import actually calls, into a temp directory so it
        // never touches the real Artwork folder.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("majiks-import-art-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("catalogue-row-9.png")

        func png(_ side: Int) -> Data {
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                .representation(using: .png, properties: [:])!
        }

        try PublisherStore.writeImportedArtwork(png(8), to: path)
        #expect(ArtworkDecodeCache.image(at: path)?.size.width == 8,
                "fixture did not decode; the rest would be vacuous")

        // The re-import: same path, different cover.
        try PublisherStore.writeImportedArtwork(png(32), to: path)
        #expect(ArtworkDecodeCache.image(at: path)?.size.width == 32,
                "the import served the previous cover — the eviction is not wired in")
    }
}

// MARK: - Library durability at quit

@Suite("Library — an edit survives quitting")
struct LibraryQuitFlushTests {

    // `LibraryStore.updateTrack`, `setRating`, `updateTrackISRC` and
    // `setTrackArtwork` all use the DEBOUNCED `save()`, which waits 0.5 s of
    // quiet before writing. `saveImmediately()`'s doc comment claimed it was
    // "called from ... app termination" — and a grep for `saveImmediately`
    // outside LibraryStore.swift returned NOTHING. Quitting inside the debounce
    // window discarded the edit, under a comment saying it could not.
    //
    // The delegate method cannot be invoked from a unit test (it needs a real
    // NSApplication termination), so this is a source guard. Source guards are
    // the thing that gets satisfied by a COMMENT mentioning the line it polices,
    // so this one strips comments before it looks, and there is a mutation in
    // the lane report proving a comment does not satisfy it.

    @Test("applicationWillTerminate flushes the library, not just the Studio project")
    func quitFlushesTheLibrary() throws {
        let main = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // swift/
            .appendingPathComponent("Sources/Main.swift")
        let source = try String(contentsOf: main, encoding: .utf8)

        // Comments cannot vote.
        let code = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let slashes = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<slashes.lowerBound])
            }
            .joined(separator: "\n")

        guard let start = code.range(of: "func applicationWillTerminate(") else {
            Issue.record("applicationWillTerminate is gone from Main.swift; this guard is now vacuous")
            return
        }
        // Up to the next top-level func, which is the end of this one's body.
        let rest = code[start.upperBound...]
        let body = rest.range(of: "\n    func ").map { String(rest[..<$0.lowerBound]) } ?? String(rest)

        #expect(body.contains("saveImmediately()"),
                "a rating or retitle made in the last half second before quit is lost without this")
    }
}
