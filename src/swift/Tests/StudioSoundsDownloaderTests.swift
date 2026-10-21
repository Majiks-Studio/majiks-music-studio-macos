import XCTest
import SwiftUI
@testable import MajiksMusicStudio

// The pipe's gates.
//
// The browser next door was proven at scale and then shipped against a vault
// that did not exist on any machine. What is at risk in closing that gap, in
// the order it would hurt:
//
//  1. A BAD FILE KEPT. A truncated WAV does not fail to open — it plays as a
//     click, inside somebody's song, and this repo has already been burned by
//     exactly that fixture (`host_undo.rs`). Verification is asserted on both
//     halves: that a whole file passes, and that four DIFFERENT kinds of broken
//     file are refused and moved out of reach. A verifier that failed
//     everything would satisfy half of that and is caught by the positive.
//
//  2. THE MAIN THREAD. A downloader is the most likely place in this app to
//     repeat the P0 where a computed property that read like a field access did
//     a blocking XPC round trip on every view-body pass. Asserted the way the
//     scanner's is: the work RECORDS where it ran and returns it as data, and
//     the main actor is separately proven to keep answering while a download is
//     in flight.
//
//  3. THE INDEX. The one job worth shipping on its own. Asserted end to end —
//     empty folder, download, scan, and a browser row that says "125 BPM" — and
//     asserted in the negative, that an asset the catalogue has no tempo for
//     still reads "tempo unknown" rather than a plausible number.
//
//  4. THE LICENSING BOUNDARY. This client must not contain a path that tries to
//     obtain paid content, and the metadata half must not send a credential.
//     Both are asserted against a transport that records every request.
//
// Nothing here touches the network, and nothing here needs a key.

final class StudioSoundsDownloaderTests: XCTestCase {

    // MARK: - Fixtures

    /// A structurally valid WAV: RIFF/WAVE, a `fmt ` chunk, and a `data` chunk
    /// whose declared size matches the samples that follow it.
    ///
    /// Built by hand rather than through AVFoundation because the tests below
    /// need to CUT one, and cutting a file you generated is only meaningful if
    /// you know exactly where its header claims the audio ends.
    private func wav(dataBytes: Int) -> Data {
        var out = Data()
        func ascii(_ s: String) { out.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { out.append(contentsOf: [
            UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]) }
        func u16(_ v: Int) { out.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }

        ascii("RIFF"); u32(4 + 24 + 8 + dataBytes); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1); u32(44_100); u32(88_200); u16(2); u16(16)
        ascii("data"); u32(dataBytes)
        out.append(Data(repeating: 0x7F, count: dataBytes))
        return out
    }

    /// A WAV whose RIFF envelope is HONEST about the file length while its
    /// `data` chunk claims more audio than the file holds.
    ///
    /// This is the truncation the coarse check cannot see, and it is not
    /// hypothetical: it is what you get whenever something re-wraps a short
    /// payload — a proxy that buffers, a tool that repacks, a server that
    /// streams a partial file behind a correct envelope. The half-a-file
    /// fixture above trips the RIFF floor first, so without THIS one the
    /// `data`-chunk check is dead code that no assertion holds. A mutation run
    /// proved exactly that: deleting the check left the whole suite green.
    private func wavWithOverclaimedDataChunk(actualDataBytes: Int, claimedDataBytes: Int) -> Data {
        var out = Data()
        func ascii(_ s: String) { out.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { out.append(contentsOf: [
            UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]) }
        func u16(_ v: Int) { out.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }

        // "WAVE" + the fmt chunk + the data header + what is really there.
        ascii("RIFF"); u32(4 + 24 + 8 + actualDataBytes); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1); u32(44_100); u32(88_200); u16(2); u16(16)
        ascii("data"); u32(claimedDataBytes)
        out.append(Data(repeating: 0x7F, count: actualDataBytes))
        return out
    }

    private func temporaryVault() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("get-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func catalogueAsset(
        _ sku: String, id: String = UUID().uuidString, title: String = "A Sound",
        kind: StudioSoundKind = .loop, bpm: Double? = 125, key: String? = "D major",
        free: Bool = true, fileName: String? = nil
    ) -> StudioSoundsCatalogAsset {
        StudioSoundsCatalogAsset(
            id: id, sku: sku, title: title, kind: kind, bpm: bpm, key: key,
            durationSeconds: nil, isFree: free, fileName: fileName)
    }

    private func cataloguePack(
        slug: String = "uplifting-pop-let-it-fly-004e",
        title: String = "Let It Fly — Uplifting-Pop Kit",
        assets: [StudioSoundsCatalogAsset]
    ) -> StudioSoundsCatalogPack {
        StudioSoundsCatalogPack(
            id: UUID().uuidString, slug: slug, title: title, assetCount: assets.count,
            isFree: assets.allSatisfy(\.isFree), assets: assets)
    }

    // MARK: A transport that records what was asked of it
    //
    // Recording every request is what makes "the catalogue half sends no
    // credential" and "premium content is never even attempted" assertable.
    // A stub that only returned bodies could not see either.

    private final class StubTransport: StudioSoundsTransport, @unchecked Sendable {
        struct Recorded: Sendable {
            let url: String
            let authorization: String?
            let range: String?
        }

        private let lock = NSLock()
        private var _requests: [Recorded] = []
        var requests: [Recorded] { lock.lock(); defer { lock.unlock() }; return _requests }

        /// url-substring -> (status, headers, body)
        var bodies: [String: (Int, [String: String], Data)] = [:]
        /// Cut every streamed body to this many bytes and then stop, without an
        /// error — the shape a dropped connection actually has.
        var truncateStreamTo: Int?
        /// Throw part-way through the stream, the shape an interrupted download
        /// has. `(afterBytes)`.
        var failStreamAfter: Int?
        /// Runs inside the streaming call, so a test can observe where the work
        /// is happening.
        var onStream: (@Sendable () -> Void)?
        /// Answer a Range request with 200 and the WHOLE body, which a server
        /// behind a proxy that strips the header genuinely does.
        var ignoreRange = false

        private func match(_ request: URLRequest) -> (Int, [String: String], Data)? {
            let url = request.url?.absoluteString ?? ""
            for (needle, value) in bodies where url.contains(needle) { return value }
            return nil
        }

        private func record(_ request: URLRequest) {
            lock.lock()
            _requests.append(Recorded(
                url: request.url?.absoluteString ?? "",
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                range: request.value(forHTTPHeaderField: "Range")))
            lock.unlock()
        }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            record(request)
            guard let (status, headers, body) = match(request) else {
                return (Data(), HTTPURLResponse(
                    url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
            return (body, HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }

        func stream(for request: URLRequest) async throws
            -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
            record(request)
            onStream?()
            guard let (status, headers, body) = match(request) else {
                return (AsyncThrowingStream { $0.finish() }, HTTPURLResponse(
                    url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
            // Honour a Range header the way the real service does, so the
            // resume test exercises the client's real branch rather than a
            // convenient one.
            var payload = body
            var effectiveStatus = status
            var effectiveHeaders = headers
            if !ignoreRange,
               let range = request.value(forHTTPHeaderField: "Range"),
               range.hasPrefix("bytes="),
               let from = Int(range.dropFirst("bytes=".count).split(separator: "-").first ?? ""),
               from < body.count {
                payload = body.subdata(in: from..<body.count)
                effectiveStatus = 206
                effectiveHeaders["Content-Length"] = String(payload.count)
            }
            let cut = truncateStreamTo
            let boom = failStreamAfter
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                var sent = 0
                var offset = 0
                while offset < payload.count {
                    let end = min(offset + 4096, payload.count)
                    if let cut, sent >= cut { break }
                    if let boom, sent >= boom {
                        continuation.finish(throwing: URLError(.networkConnectionLost)); return
                    }
                    let chunk = payload.subdata(in: offset..<end)
                    continuation.yield(chunk)
                    sent += chunk.count
                    offset = end
                }
                continuation.finish()
            }
            return (stream, HTTPURLResponse(
                url: request.url!, statusCode: effectiveStatus, httpVersion: nil,
                headerFields: effectiveHeaders)!)
        }
    }

    /// Wires a stub with a pack detail body and one download body per asset.
    private func stub(
        pack: StudioSoundsCatalogPack, audio: [String: Data]
    ) -> StubTransport {
        let transport = StubTransport()
        transport.bodies["api/sounds/packs/\(pack.slug)"] = (200, [:], packDetailJSON(pack))
        for asset in pack.assets {
            let bytes = audio[asset.sku] ?? wav(dataBytes: 8192)
            transport.bodies["assets/\(asset.id)/download"] =
                (200, ["Content-Length": String(bytes.count)], bytes)
        }
        return transport
    }

    /// The wire shape the live service sends, written out longhand so the
    /// decoder is tested against the real JSON rather than against a Swift
    /// value round-tripped through itself. Field names copied from a recorded
    /// response: `musicalKey`, and `access` as an object.
    private func packDetailJSON(_ pack: StudioSoundsCatalogPack) -> Data {
        func assetJSON(_ a: StudioSoundsCatalogAsset) -> [String: Any] {
            var out: [String: Any] = [
                "id": a.id, "sku": a.sku, "title": a.title, "kind": a.kind.rawValue,
                "tags": [], "access": ["type": a.isFree ? "free" : "premium"],
            ]
            out["bpm"] = a.bpm ?? NSNull()
            out["musicalKey"] = a.key ?? NSNull()
            out["durationSeconds"] = a.durationSeconds ?? NSNull()
            // The field the whole basename join rests on. Emitted as an
            // explicit null when absent, because that is what the live service
            // sends for a row whose column is empty and a decoder that only
            // ever saw the key present would not be tested against it.
            out["fileName"] = a.fileName ?? NSNull()
            return out
        }
        let body: [String: Any] = ["data": [
            "pack": ["id": pack.id, "slug": pack.slug, "title": pack.title,
                     "assetCount": pack.assetCount,
                     "access": ["type": pack.isFree ? "free" : "premium"]],
            "assets": pack.assets.map(assetJSON),
            "shares": [],
        ]]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func packsListJSON(_ packs: [StudioSoundsCatalogPack]) -> Data {
        let body: [String: Any] = ["data": [
            "packs": packs.map { ["id": $0.id, "slug": $0.slug, "title": $0.title,
                                  "assetCount": $0.assetCount,
                                  "access": ["type": $0.isFree ? "free" : "premium"]] },
            "page": 1, "limit": 200,
        ]]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - 1. Verification: the whole file, and four ways of not being it

    /// The positive control. Without it a verifier that refused EVERYTHING
    /// would pass every other test in this section — which is exactly the shape
    /// of the "green signal on the wrong axis" failures this repo keeps hitting.
    func testAWholeWavPassesVerification() throws {
        let url = try temporaryVault().appendingPathComponent("whole.wav")
        let bytes = wav(dataBytes: 16_384)
        try bytes.write(to: url)
        XCTAssertEqual(
            StudioSoundsVerifier.verify(fileAt: url, declaredLength: bytes.count),
            .ok(bytes: bytes.count))
    }

    /// The failure this whole section exists for. The file is a real WAV, its
    /// header is intact, and the audio behind it is half there — which is the
    /// file that opens fine and plays as a click.
    func testATruncatedWavIsCaughtByItsOwnHeader() throws {
        let url = try temporaryVault().appendingPathComponent("cut.wav")
        let whole = wav(dataBytes: 16_384)
        try whole.prefix(whole.count / 2).write(to: url)

        // Note: NO declared length is passed. The server may not have sent one,
        // or may itself have served short; the file has to answer for itself.
        let verdict = StudioSoundsVerifier.verify(fileAt: url, declaredLength: nil)
        guard case .truncatedAudio(let declared, let available) = verdict else {
            return XCTFail("a half a WAV was accepted: \(verdict)")
        }
        XCTAssertGreaterThan(declared, available)
        XCTAssertNotNil(verdict.complaint)
    }

    /// SURVIVOR, closed.
    ///
    /// A mutation that deleted the `data`-chunk length check left every test in
    /// this file green, because the half-a-file fixture above trips the coarser
    /// RIFF floor before the precise check is ever reached. This is the file
    /// that only the precise check can catch: its RIFF envelope is exactly
    /// right for the bytes present, and its `data` chunk lies.
    func testAWavWhoseDataChunkOverclaimsIsRefusedEvenThoughItsEnvelopeIsHonest() throws {
        let url = try temporaryVault().appendingPathComponent("overclaim.wav")
        let bytes = wavWithOverclaimedDataChunk(actualDataBytes: 1_024, claimedDataBytes: 200_000)
        try bytes.write(to: url)

        // THE CONTROL, and the reason this test is not passing for the wrong
        // reason: the same builder with an HONEST data chunk produces a file of
        // the same shape and the same envelope that verifies clean. So the only
        // difference between green and red here is the `data`-chunk length —
        // which is precisely the check the mutation deleted.
        let control = try temporaryVault().appendingPathComponent("honest.wav")
        let honest = wavWithOverclaimedDataChunk(actualDataBytes: 1_024, claimedDataBytes: 1_024)
        try honest.write(to: control)
        XCTAssertEqual(StudioSoundsVerifier.verify(fileAt: control, declaredLength: honest.count),
                       .ok(bytes: honest.count),
                       "the control file does not verify, so this fixture shape proves nothing")

        let verdict = StudioSoundsVerifier.verify(fileAt: url, declaredLength: bytes.count)
        guard case .truncatedAudio(let declared, let available) = verdict else {
            return XCTFail("a WAV claiming 200,000 bytes of audio in a 1,024-byte file was accepted: \(verdict)")
        }
        XCTAssertEqual(declared, 200_000)
        XCTAssertLessThan(available, declared)
    }

    func testABodyShorterThanTheServerDeclaredIsRefused() throws {
        let url = try temporaryVault().appendingPathComponent("short.wav")
        let bytes = wav(dataBytes: 4096)
        try bytes.write(to: url)
        XCTAssertEqual(
            StudioSoundsVerifier.verify(fileAt: url, declaredLength: bytes.count + 1000),
            .shortOfDeclaredLength(expected: bytes.count + 1000, got: bytes.count))
    }

    /// A captive portal or a proxy answers an HTML page with a 200. Saved under
    /// a `.wav` name it is a file the browser would list and the engine would
    /// choke on.
    func testAnErrorPageSavedAsAWavIsNotAcceptedAsAudio() throws {
        let url = try temporaryVault().appendingPathComponent("portal.wav")
        try Data("<!DOCTYPE html><html><body>Sign in to continue</body></html>".utf8).write(to: url)
        guard case .notAudio = StudioSoundsVerifier.verify(fileAt: url, declaredLength: nil) else {
            return XCTFail("an HTML page was accepted as audio")
        }
    }

    func testAnEmptyFileIsRefused() throws {
        let url = try temporaryVault().appendingPathComponent("nothing.wav")
        try Data().write(to: url)
        XCTAssertEqual(StudioSoundsVerifier.verify(fileAt: url, declaredLength: nil), .empty)
    }

    // MARK: - 2. The downloader keeps nothing it cannot verify

    func testATruncatedDownloadIsQuarantinedRatherThanKept() async throws {
        let root = try temporaryVault()
        let asset = catalogueAsset("kit-001")
        let pack = cataloguePack(assets: [asset])
        let whole = wav(dataBytes: 32_768)
        let transport = stub(pack: pack, audio: [asset.sku: whole])
        // The connection drops half way and the stream ENDS rather than
        // erroring — the shape that looks like success to a naive client.
        transport.truncateStreamTo = whole.count / 2

        let outcome = try await StudioSoundsDownloader(transport: transport)
            .download(packSlug: pack.slug, into: root, token: "mk_test")

        let one = try XCTUnwrap(outcome.outcomes.first)
        XCTAssertFalse(one.succeeded, "a half-downloaded WAV was reported as a success")
        XCTAssertNotNil(one.quarantinedAt, "a bad file was not quarantined")

        let landed = root.appendingPathComponent(
            StudioSoundsLayout.relativePath(packSlug: pack.slug, sku: asset.sku))
        XCTAssertFalse(FileManager.default.fileExists(atPath: landed.path),
                       "a file that failed verification was left in the vault")
        XCTAssertTrue(FileManager.default.fileExists(atPath: one.quarantinedAt!),
                      "the bad file was deleted rather than set aside for diagnosis")
    }

    /// The quarantine folder is dot-prefixed and the scanner skips hidden
    /// files, so a rejected file is unreachable from the browser BY
    /// CONSTRUCTION. Asserted against the real scanner, not against the naming
    /// convention — the convention is only the mechanism.
    func testAQuarantinedFileIsInvisibleToTheBrowser() async throws {
        let root = try temporaryVault()
        let asset = catalogueAsset("kit-001")
        let pack = cataloguePack(assets: [asset])
        let whole = wav(dataBytes: 32_768)
        let transport = stub(pack: pack, audio: [asset.sku: whole])
        transport.truncateStreamTo = whole.count / 2

        _ = try await StudioSoundsDownloader(transport: transport)
            .download(packSlug: pack.slug, into: root, token: "mk_test")

        let scan = await StudioVaultScanner.scan(root: root)
        XCTAssertTrue(scan.assets.isEmpty,
                      "a quarantined file showed up in the browser: \(scan.assets.map(\.id))")
    }

    /// A failure must never be summarised as a success. This is the mutation
    /// "make a failed download report success" in assertion form.
    func testAPartlyFailedPackSaysHowManyFailed() async throws {
        let root = try temporaryVault()
        let good = catalogueAsset("kit-001", title: "Good")
        let pack = cataloguePack(assets: [good])
        let whole = wav(dataBytes: 32_768)
        let transport = stub(pack: pack, audio: [good.sku: whole])
        transport.truncateStreamTo = whole.count / 2

        let outcome = try await StudioSoundsDownloader(transport: transport)
            .download(packSlug: pack.slug, into: root, token: "mk_test")

        XCTAssertEqual(outcome.succeeded.count, 0)
        XCTAssertEqual(outcome.failed.count, 1)
        XCTAssertTrue(outcome.summary.lowercased().contains("could not"),
                      "a total failure was summarised as \"\(outcome.summary)\"")
        XCTAssertEqual(outcome.indexedCount, 0,
                       "a file that never landed was written into the index")
    }

    // MARK: - 3. Resumability

    /// An interrupted download leaves a part file; the next attempt asks for the
    /// REST rather than starting over. Both halves are asserted: that the
    /// second attempt sent a Range header naming where it stopped, and that the
    /// file it finally committed is whole.
    func testAnInterruptedDownloadResumesFromWhereItStopped() async throws {
        let root = try temporaryVault()
        let asset = catalogueAsset("kit-001")
        let pack = cataloguePack(assets: [asset])
        let whole = wav(dataBytes: 40_960)
        let transport = stub(pack: pack, audio: [asset.sku: whole])
        transport.failStreamAfter = 8192

        let downloader = StudioSoundsDownloader(transport: transport)
        let first = try await downloader.download(packSlug: pack.slug, into: root, token: "mk_test")
        XCTAssertFalse(try XCTUnwrap(first.outcomes.first).succeeded)

        transport.failStreamAfter = nil
        let second = try await downloader.download(packSlug: pack.slug, into: root, token: "mk_test")
        let two = try XCTUnwrap(second.outcomes.first)

        XCTAssertTrue(two.succeeded, "the retry did not complete")
        XCTAssertGreaterThan(two.resumedFrom, 0,
                             "the retry started from zero — nothing was resumed")
        let ranges = transport.requests.compactMap(\.range)
        XCTAssertFalse(ranges.isEmpty, "no Range header was ever sent, so nothing could resume")
        XCTAssertTrue(ranges.contains { $0.hasPrefix("bytes=\(two.resumedFrom)-") },
                      "the Range asked for the wrong offset: \(ranges)")

        let landed = root.appendingPathComponent(
            StudioSoundsLayout.relativePath(packSlug: pack.slug, sku: asset.sku))
        let bytes = try Data(contentsOf: landed)
        XCTAssertEqual(bytes.count, whole.count,
                       "the resumed file is the wrong length, so the resume double-counted or lost bytes")
        XCTAssertEqual(bytes, whole, "the resumed file's bytes do not match what was served")
    }

    // MARK: - 4. Off the main thread, asserted the way the scanner's is

    func testTheDownloadDoesNotRunOnTheMainThread() async throws {
        let root = try temporaryVault()
        let asset = catalogueAsset("kit-001")
        let pack = cataloguePack(assets: [asset])
        let transport = stub(pack: pack, audio: [:])

        let outcome = try await StudioSoundsDownloader(transport: transport)
            .download(packSlug: pack.slug, into: root, token: "mk_test")
        XCTAssertFalse(outcome.ranOnMainThread,
                       "the download ran on the main thread — the shape of the 3.4.13 P0")
    }

    /// The complementary half, and the property a person actually feels: the
    /// app keeps answering while a download runs. Measured the way the
    /// scanner's is — by racing main-actor hops against live work — because a
    /// `ranOnMainThread` flag is a claim the code makes about itself, and this
    /// is a claim about the main actor made from the main actor.
    @MainActor
    func testTheMainActorKeepsRunningWhileADownloadIsInFlight() async throws {
        let root = try temporaryVault()
        let assets = (0..<40).map { catalogueAsset("kit-\($0)") }
        let pack = cataloguePack(assets: assets)
        let transport = stub(pack: pack, audio: [:])

        let work = Task {
            try await StudioSoundsDownloader(transport: transport)
                .download(packSlug: pack.slug, into: root, token: "mk_test")
        }

        // If the download held the main actor, none of these would get a turn
        // until it finished.
        var hops = 0
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, hops < 50 {
            await Task.yield()
            hops += 1
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let outcome = try await work.value

        XCTAssertGreaterThanOrEqual(
            hops, 50,
            "the main actor only got \(hops) turns while a 40-asset download ran; it was being blocked")
        XCTAssertEqual(outcome.succeeded.count, 40)
        XCTAssertFalse(outcome.ranOnMainThread)
    }

    final class ManagedAtomicish: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
        func bump() { lock.lock(); _value += 1; lock.unlock() }
    }

    // MARK: - 5. The licensing boundary

    /// The metadata half is public and must stay that way. A catalogue read
    /// that carried the person's key would post a credential on every browse,
    /// and would make the index refresh useless to somebody who has not signed
    /// in.
    func testTheCatalogueSendsNoCredential() async throws {
        let pack = cataloguePack(assets: [catalogueAsset("kit-001")])
        let transport = StubTransport()
        transport.bodies["api/sounds/packs?"] = (200, [:], packsListJSON([pack]))
        transport.bodies["api/sounds/packs/\(pack.slug)"] = (200, [:], packDetailJSON(pack))

        let client = StudioSoundsCatalogClient(transport: transport)
        _ = try await client.allPacks()
        _ = try await client.pack(slug: pack.slug)

        XCTAssertFalse(transport.requests.isEmpty, "no request was made, so nothing was proven")
        for request in transport.requests {
            XCTAssertNil(request.authorization,
                         "a catalogue read carried a credential: \(request.url)")
        }
    }

    /// A pack whose assets are all premium is refused OUTRIGHT — no download
    /// request is issued at all. The point is not to save a round trip: it is
    /// that this client must not contain a path that attempts to obtain paid
    /// content.
    func testPremiumContentIsRefusedRatherThanAttempted() async throws {
        let root = try temporaryVault()
        let asset = catalogueAsset("kit-001", free: false)
        let pack = cataloguePack(assets: [asset])
        let transport = stub(pack: pack, audio: [:])

        do {
            _ = try await StudioSoundsDownloader(transport: transport)
                .download(packSlug: pack.slug, into: root, token: "mk_test")
            XCTFail("a premium pack was downloaded")
        } catch let error as StudioSoundsError {
            guard case .notEntitled = error else { return XCTFail("wrong refusal: \(error)") }
        }
        XCTAssertFalse(transport.requests.contains { $0.url.contains("/download") },
                       "a download was attempted for premium content")
    }

    func testDownloadingWithoutAKeyRefusesBeforeAskingForBytes() async throws {
        let root = try temporaryVault()
        let pack = cataloguePack(assets: [catalogueAsset("kit-001")])
        let transport = stub(pack: pack, audio: [:])
        do {
            _ = try await StudioSoundsDownloader(transport: transport)
                .download(packSlug: pack.slug, into: root, token: nil)
            XCTFail("a download was attempted with no key")
        } catch let error as StudioSoundsError {
            XCTAssertEqual(error, .notSignedIn)
        }
        XCTAssertFalse(transport.requests.contains { $0.url.contains("/download") })
    }

    /// The master fetch DOES carry the key — the other half of the boundary.
    func testTheMasterFetchCarriesTheKey() async throws {
        let root = try temporaryVault()
        let asset = catalogueAsset("kit-001")
        let pack = cataloguePack(assets: [asset])
        let transport = stub(pack: pack, audio: [:])
        _ = try await StudioSoundsDownloader(transport: transport)
            .download(packSlug: pack.slug, into: root, token: "mk_secret")
        let download = try XCTUnwrap(transport.requests.first { $0.url.contains("/download") })
        XCTAssertEqual(download.authorization, "Bearer mk_secret")
    }

    // MARK: - 6. The index exporter — the highest value per line

    /// The headline: from an EMPTY FOLDER to a browser row carrying a real
    /// tempo, through the real downloader, the real exporter, the real scanner
    /// and the real filter. No step is stubbed except the wire.
    func testEndToEndAnEmptyFolderBecomesABrowserRowWithARealTempo() async throws {
        let root = try temporaryVault()
        let loop = catalogueAsset(
            "uplifting-pop-let-it-fly-004e-011", title: "Melody Ringout 4-Bar",
            kind: .loop, bpm: 125, key: "D major")
        let pack = cataloguePack(assets: [loop])
        let transport = stub(pack: pack, audio: [:])

        // Nothing here to begin with — the state a real machine is in today.
        let before = await StudioVaultScanner.scan(root: root)
        XCTAssertTrue(before.assets.isEmpty)

        let outcome = try await StudioSoundsDownloader(transport: transport)
            .download(packSlug: pack.slug, into: root, token: "mk_test")
        XCTAssertEqual(outcome.succeeded.count, 1)
        XCTAssertEqual(outcome.indexedCount, 1)

        let after = await StudioVaultScanner.scan(root: root)
        let row = try XCTUnwrap(after.assets.first)

        XCTAssertEqual(row.bpm, 125, "the tempo the catalogue holds did not reach the row")
        XCTAssertEqual(row.key, "D major")
        XCTAssertEqual(row.kind, .loop)
        XCTAssertEqual(row.metadata, .index,
                       "the tempo was attributed to a guess rather than to the catalogue")
        XCTAssertEqual(row.name, "Melody Ringout 4-Bar",
                       "the row shows the sku instead of the name a person wrote")
        XCTAssertTrue(row.metaLine.contains("125 BPM"),
                      "the row still does not say its tempo: \"\(row.metaLine)\"")
        XCTAssertFalse(row.metaLine.contains("BPM?"),
                       "a catalogue tempo was hedged as if it had been read off a filename")

        // And it survives the filter a person would actually use.
        let model = await StudioSoundsVaultModel(root: root)
        await MainActor.run {
            model.adopt(after)
            model.projectBPM = 125
            model.filter.inTempo = true
            XCTAssertEqual(model.visible.count, 1,
                           "the in-tempo filter hid a loop whose tempo is now known")
            XCTAssertEqual(model.hiddenForUnknownTempo, 0)
        }
    }

    /// The negative, and the one that keeps this honest. An asset the catalogue
    /// has NO tempo for must stay unknown. Inventing 120 because 120 is
    /// plausible is the failure this whole feature was written not to commit.
    func testAnAssetTheCatalogueHasNoTempoForStillReadsTempoUnknown() async throws {
        let root = try temporaryVault()
        let mystery = catalogueAsset(
            "kit-002", title: "Untitled Loop", kind: .loop, bpm: nil, key: nil)
        let pack = cataloguePack(assets: [mystery])
        let transport = stub(pack: pack, audio: [:])

        _ = try await StudioSoundsDownloader(transport: transport)
            .download(packSlug: pack.slug, into: root, token: "mk_test")

        let scan = await StudioVaultScanner.scan(root: root)
        let row = try XCTUnwrap(scan.assets.first)
        XCTAssertNil(row.bpm, "a tempo was invented for an asset the catalogue has none for")
        XCTAssertTrue(row.metaLine.contains("tempo unknown"),
                      "the row does not admit it has no tempo: \"\(row.metaLine)\"")

        // And the index says nil rather than omitting the entry or writing 0.
        let index = try XCTUnwrap(StudioSoundsIndex.read(at: root))
        let entry = try XCTUnwrap(index.entries.values.first)
        XCTAssertNil(entry.bpm)
        XCTAssertEqual(entry.kind, "loop", "the kind was lost, so the filters cannot see it")
    }

    /// A one-shot is tempo-FREE, which is a different statement from tempo
    /// unknown — and the row must not nag about a tempo a kick will never have.
    func testAOneShotSaysNothingAboutTempoRatherThanUnknown() async throws {
        let root = try temporaryVault()
        let hit = catalogueAsset("kit-003", title: "Kick 01", kind: .oneShot, bpm: nil, key: nil)
        let transport = stub(pack: cataloguePack(assets: [hit]), audio: [:])
        _ = try await StudioSoundsDownloader(transport: transport)
            .download(packSlug: "uplifting-pop-let-it-fly-004e", into: root, token: "mk_test")
        let scan = await StudioVaultScanner.scan(root: root)
        let row = try XCTUnwrap(scan.assets.first)
        XCTAssertFalse(row.metaLine.contains("tempo unknown"))
    }

    /// MERGE, not replace. Downloading a second pack must not strip the tempo
    /// off the first — a green action that destroys data is the same family of
    /// defect as a download that reports success on a failure.
    func testDownloadingASecondPackKeepsTheFirstPacksTempos() async throws {
        let root = try temporaryVault()

        let first = cataloguePack(
            slug: "pack-one", title: "Pack One",
            assets: [catalogueAsset("one-001", bpm: 90, key: "A minor")])
        _ = try await StudioSoundsDownloader(transport: stub(pack: first, audio: [:]))
            .download(packSlug: first.slug, into: root, token: "mk_test")

        let second = cataloguePack(
            slug: "pack-two", title: "Pack Two",
            assets: [catalogueAsset("two-001", bpm: 140, key: "F minor")])
        _ = try await StudioSoundsDownloader(transport: stub(pack: second, audio: [:]))
            .download(packSlug: second.slug, into: root, token: "mk_test")

        let index = try XCTUnwrap(StudioSoundsIndex.read(at: root))
        XCTAssertEqual(index.entries.count, 2,
                       "the second export replaced the first instead of merging: \(index.entries.keys)")
        XCTAssertEqual(index.entries["pack-one/one-001.wav"]?.bpm, 90)
        XCTAssertEqual(index.entries["pack-two/two-001.wav"]?.bpm, 140)

        let scan = await StudioVaultScanner.scan(root: root)
        XCTAssertEqual(scan.indexed, 2, "the browser lost the tempos of the pack downloaded first")
    }

    /// The exporter on its own, against a vault somebody filled by hand. This
    /// is the half worth shipping even with no downloader at all: a folder of
    /// sounds becomes a filterable library, over the PUBLIC api, with no key.
    func testRefreshingTheIndexGivesAHandPlacedVaultItsTempos() async throws {
        let root = try temporaryVault()
        let asset = catalogueAsset("kit-007", title: "Bass Loop", kind: .loop, bpm: 174, key: "G minor")
        let pack = cataloguePack(slug: "dnb-pack", title: "DnB Pack", assets: [asset])

        // Place the file by hand, exactly where the layout says it goes.
        let relative = StudioSoundsLayout.relativePath(packSlug: pack.slug, sku: asset.sku)
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try wav(dataBytes: 4096).write(to: url)

        let cold = await StudioVaultScanner.scan(root: root)
        XCTAssertNil(cold.assets.first?.bpm, "the fixture already had a tempo, so this proves nothing")

        let transport = StubTransport()
        transport.bodies["api/sounds/packs/\(pack.slug)"] = (200, [:], packDetailJSON(pack))
        let result = try await StudioSoundsIndexExporter.refresh(
            vaultAt: root, presentRelativePaths: [relative],
            client: StudioSoundsCatalogClient(transport: transport))

        XCTAssertEqual(result.entriesWritten, 1)
        XCTAssertFalse(result.ranOnMainThread)
        XCTAssertTrue(transport.requests.allSatisfy { $0.authorization == nil },
                      "the index refresh required a credential")

        let warm = await StudioVaultScanner.scan(root: root)
        XCTAssertEqual(warm.assets.first?.bpm, 174)
        XCTAssertEqual(warm.assets.first?.metadata, .index)
    }

    /// The refresh only asks about packs that are actually present. Pulling all
    /// 739 pack details to describe the two somebody has is 737 pointless round
    /// trips against a live service.
    func testTheRefreshOnlyAsksAboutPacksThatArePresent() async throws {
        let root = try temporaryVault()
        let pack = cataloguePack(slug: "here", title: "Here", assets: [catalogueAsset("here-001")])
        let transport = StubTransport()
        transport.bodies["api/sounds/packs/here"] = (200, [:], packDetailJSON(pack))

        _ = try await StudioSoundsIndexExporter.refresh(
            vaultAt: root, presentRelativePaths: ["here/here-001.wav"],
            client: StudioSoundsCatalogClient(transport: transport))
        XCTAssertEqual(transport.requests.count, 1,
                       "the refresh asked about packs nobody has: \(transport.requests.map(\.url))")
    }

    /// The previous lane deliberately REFUSES to read a bare `Snare_120` as a
    /// tempo. Nothing added here may loosen that: an index that is absent must
    /// leave the row silent, not fall back to a plausible-looking number.
    func testTheRefusalToReadABareNumberAsATempoSurvivesTheIndex() {
        XCTAssertNil(StudioSoundNameMetadata.bpm(fromName: "Snare_120"))
        XCTAssertEqual(StudioSoundNameMetadata.bpm(fromName: "Snare_120bpm"), 120)
    }

    // MARK: - 7. Decoding the shapes the live service actually sends

    func testTheDecoderReadsTheLiveWireShape() throws {
        let asset = catalogueAsset("kit-001", title: "Melody Ringout", kind: .loop,
                                   bpm: 125, key: "D major")
        let pack = cataloguePack(assets: [asset])
        let decoded = try StudioSoundsCatalogDecoder.packDetail(from: packDetailJSON(pack))
        XCTAssertEqual(decoded.slug, pack.slug)
        XCTAssertEqual(decoded.assets.first?.bpm, 125)
        XCTAssertEqual(decoded.assets.first?.key, "D major")
        XCTAssertEqual(decoded.assets.first?.kind, .loop)
        XCTAssertTrue(decoded.assets.first!.isFree)
    }

    /// The storefront's `kind` enum already carries `midi` and `fx_preset`,
    /// neither of which this app can put on a track. A client that threw on
    /// them would break the day one is published.
    func testAnUnknownKindDecodesRatherThanThrowing() throws {
        let body = Data("""
        {"data":{"pack":{"id":"p","slug":"s","title":"T","assetCount":1,"access":{"type":"free"}},
        "assets":[{"id":"a","sku":"k","title":"K","kind":"fx_preset","bpm":null,"musicalKey":null,
        "access":{"type":"free"}}]}}
        """.utf8)
        let decoded = try StudioSoundsCatalogDecoder.packDetail(from: body)
        XCTAssertEqual(decoded.assets.first?.kind, .unknown)
    }

    /// The listing clamps to 200 server-side and returns no total, so a short
    /// page is the ONLY end-of-list signal. A client that paged forever against
    /// a service that repeats itself is a worse failure than one that stops.
    func testTheCatalogueWalkStopsOnAShortPage() async throws {
        let transport = StubTransport()
        let packs = (0..<3).map {
            cataloguePack(slug: "p\($0)", title: "P\($0)", assets: [])
        }
        transport.bodies["api/sounds/packs?"] = (200, [:], packsListJSON(packs))
        let found = try await StudioSoundsCatalogClient(transport: transport).allPacks()
        XCTAssertEqual(found.count, 3)
        XCTAssertEqual(transport.requests.count, 1,
                       "a short first page did not end the walk")
    }

    func testA401IsSaidInWordsAPersonCanActOn() throws {
        let message = try XCTUnwrap(StudioSoundsError.notSignedIn.errorDescription)
        XCTAssertTrue(message.contains(StudioSoundsVaultLocation.storefront),
                      "the sign-in error does not say where to get a key: \"\(message)\"")
    }

    // MARK: - 8. The seam that keeps costing this repo a P0

    /// Rendering the Get panel must not pay a securityd round trip per body
    /// pass. Counted at the SYSCALL, through the same seam that caught
    /// `BrigadeConfig.isConfigured` — asserting that a cache variable was set
    /// would prove nothing.
    @MainActor
    func testRenderingTheGetPanelDoesNotReadTheKeychainPerPass() throws {
        let model = StudioSoundsGetModel()
        _ = model.hasKey                                   // warm it, as a first body would
        let before = StudioSoundsAccount.item.keychainReadCount
        for _ in 0..<50 { _ = model.hasKey }
        XCTAssertEqual(StudioSoundsAccount.item.keychainReadCount, before,
                       "fifty reads of `hasKey` cost \(StudioSoundsAccount.item.keychainReadCount - before) "
                       + "securityd round trips — this is the 3.4.13 P0 verbatim")
    }

    // MARK: - 9. Downloading is not an edit

    /// Same rule as auditioning, and enforced the same way: this path holds no
    /// engine and no view model, so it could not journal if somebody wanted it
    /// to. Asserted against the real journal anyway, because "could not" is a
    /// claim about code shape and this is a claim about behaviour.
    @MainActor
    func testDownloadingJournalsNothingAndCreatesNoTrack() async throws {
        let engine = StudioMockEngine()
        let model = StudioViewModel(engine: engine)
        model.startPolling()
        defer { model.stopPolling() }
        try await Task.sleep(nanoseconds: 200_000_000)

        let tracksBefore = try XCTUnwrap(model.snapshot?.tracks.count)
        let journalBefore = await engine.journal.count

        let root = try temporaryVault()
        let pack = cataloguePack(assets: (0..<4).map { catalogueAsset("kit-\($0)") })
        let outcome = try await StudioSoundsDownloader(transport: stub(pack: pack, audio: [:]))
            .download(packSlug: pack.slug, into: root, token: "mk_test")
        XCTAssertEqual(outcome.succeeded.count, 4, "nothing downloaded, so this proves nothing")
        try await Task.sleep(nanoseconds: 200_000_000)

        let journalAfter = await engine.journal.count
        XCTAssertEqual(
            journalAfter, journalBefore,
            "downloading four sounds put \(journalAfter - journalBefore) command(s) in the journal. "
            + "Getting a sound is not editing a song; every one of those would be an undo step "
            + "between the user and their last real change.")
        XCTAssertEqual(model.snapshot?.tracks.count, tracksBefore, "a download created a track")
    }

    /// SURVIVOR, closed.
    ///
    /// A mutation that raised the client's page size to 500 left every test
    /// green — and would have hidden 539 of the 739 packs. The server CLAMPS
    /// `limit` to 200 and reports the clamp; ask for 500 and a completely full
    /// page comes back as 200 rows, which the "short page ends the walk" rule
    /// reads as the end of the catalogue.
    ///
    /// The literal 200 here is deliberate and is NOT the constant under test:
    /// it is the clamp measured against the live service, so pinning the
    /// request to it is what makes raising the constant fail.
    func testTheClientNeverAsksForAPageSizeTheServerWillClamp() {
        let url = StudioSoundsEndpoint.packs(page: 1).absoluteString
        XCTAssertTrue(url.contains("limit=200"),
                      "the client asks for a page size the storefront clamps to 200, so a FULL page "
                      + "comes back looking short and the walk stops after the first 200 of 739 packs: \(url)")

        // SURVIVOR, closed. The assertion above passes the DEFAULT limit, which
        // already IS `maxPacksPerPage` — so `min(maxPacksPerPage, limit)` is a
        // no-op on that path and deleting the clamp outright left this test
        // green. It was satisfied by the default value, not by the guard it
        // was written to hold: the same shape as a wait predicate satisfied by
        // a fixture that already shipped the expected answer.
        //
        // A caller ASKING for more is the case that matters, because that is
        // the request the server silently clamps to 200 — and a full page then
        // reads as short to a "short page ends the walk" reader, which would
        // have hidden 539 of 739 packs.
        let greedy = StudioSoundsEndpoint.packs(page: 1, limit: 1_000).absoluteString
        XCTAssertTrue(greedy.contains("limit=200"),
                      "the client asked the storefront for a page of 1,000. The server clamps "
                      + "that to 200 and reports 200, so the client believes a FULL page is a "
                      + "short one and stops after the first 200 of 739 packs: \(greedy)")
        XCTAssertFalse(greedy.contains("limit=1000"))

        // And the floor, so a mutation that clamps everything to 1 is caught by
        // the same test rather than shipping a 739-request walk.
        XCTAssertTrue(StudioSoundsEndpoint.packs(page: 1, limit: 50).absoluteString.contains("limit=50"),
                      "a legitimate smaller page size was clamped away")
    }

    /// The other half of the same survivor: a page that comes back FULL must
    /// continue the walk.
    func testAFullPageContinuesTheWalk() async throws {
        let transport = StubTransport()
        let full = (0..<StudioSoundsEndpoint.maxPacksPerPage).map {
            cataloguePack(slug: "p\($0)", title: "P\($0)", assets: [])
        }
        let tail = [cataloguePack(slug: "last", title: "Last", assets: [])]
        transport.bodies["page=1"] = (200, [:], packsListJSON(full))
        transport.bodies["page=2"] = (200, [:], packsListJSON(tail))

        let found = try await StudioSoundsCatalogClient(transport: transport).allPacks()
        XCTAssertEqual(found.count, full.count + 1,
                       "a full first page ended the walk, so most of the catalogue is invisible")
        XCTAssertEqual(transport.requests.count, 2)
    }

    /// SURVIVOR, closed.
    ///
    /// A mutation that appended to the part file when the server answered 200
    /// instead of 206 left every test green, because the stub always honoured
    /// Range. The result would be a file that is too LONG — which no length
    /// check catches, and which decodes as audio with a stutter spliced into
    /// the middle. That is worse than a failed download, because it is
    /// silent.
    func testAServerThatIgnoresRangeRestartsTheFileRatherThanAppendingToIt() async throws {
        let root = try temporaryVault()
        let asset = catalogueAsset("kit-001")
        let pack = cataloguePack(assets: [asset])
        let whole = wav(dataBytes: 40_960)
        let transport = stub(pack: pack, audio: [asset.sku: whole])
        transport.failStreamAfter = 8192

        let downloader = StudioSoundsDownloader(transport: transport)
        _ = try await downloader.download(packSlug: pack.slug, into: root, token: "mk_test")

        // Now the server stops honouring Range and sends the whole body.
        transport.failStreamAfter = nil
        transport.ignoreRange = true
        let second = try await downloader.download(packSlug: pack.slug, into: root, token: "mk_test")
        let two = try XCTUnwrap(second.outcomes.first)
        XCTAssertTrue(two.succeeded, "the retry did not complete")

        let landed = root.appendingPathComponent(
            StudioSoundsLayout.relativePath(packSlug: pack.slug, sku: asset.sku))
        let bytes = try Data(contentsOf: landed)
        XCTAssertEqual(
            bytes.count, whole.count,
            "the part file was appended to after a 200, so the committed file is "
            + "\(bytes.count - whole.count) bytes too long — audio with a splice in it")
        XCTAssertEqual(bytes, whole)
    }

    /// The decoder against BYTES THE LIVE SERVICE ACTUALLY SENT.
    ///
    /// Every other decode test here builds its JSON from a Swift value and
    /// decodes it back, which proves the two halves of one understanding agree
    /// with each other and nothing at all about the wire. This is a verbatim
    /// recording of `GET /api/sounds/packs/lo-fi-ambient-first-light-2f3f`,
    /// trimmed to three assets and otherwise untouched — so if the storefront
    /// renames a field, this fails instead of the browser going quietly blank.
    ///
    /// RE-RECORDED for `fileName`. The previous recording predated the field,
    /// so anything written against it would have been agreeing with invented
    /// JSON about the one field this lane's whole join depends on. The third
    /// asset was added on purpose: `-004` and `-008` are two DIFFERENT loops
    /// (2-bar and 4-bar) with byte-identical titles, which is the real
    /// ambiguity that correctly blocked the previous lane from matching by
    /// title. Both are in the fixture so it is evidence, not a claim.
    func testTheDecoderReadsBytesTheLiveServiceActuallySent() throws {
        let pack = try Self.recordedPack()

        XCTAssertEqual(pack.slug, "lo-fi-ambient-first-light-2f3f")
        XCTAssertTrue(pack.isFree)
        XCTAssertEqual(pack.assets.count, 3)

        let loop = try XCTUnwrap(pack.assets.first { $0.sku.hasSuffix("-004") })
        XCTAssertEqual(loop.bpm, 70, "the real response's bpm did not survive decoding")
        XCTAssertEqual(loop.key, "F major")
        XCTAssertEqual(loop.kind, .loop)
        XCTAssertTrue(loop.isFree)
        XCTAssertEqual(loop.fileName, "lo-fi-ambient-first-light-2f3f_drums_2bar_loop.wav",
                       "the live service's fileName did not survive decoding")

        // A one-shot's tempo column is genuinely null in the catalogue, and
        // that null must arrive as nil rather than as a number.
        let hit = try XCTUnwrap(pack.assets.first { $0.kind == .oneShot })
        XCTAssertNil(hit.bpm)
        XCTAssertEqual(hit.fileName, "lo-fi-ambient-first-light-2f3f_oneshot_00_kick.wav")
    }

    /// The premise of this whole lane, held against REAL BYTES: `title` cannot
    /// identify a file and `fileName` can.
    ///
    /// If the storefront ever starts sending distinct titles this goes red,
    /// which is right — it would mean the reasoning in `StudioSoundsCatalog`'s
    /// header no longer describes the service, and somebody should re-read it
    /// rather than inherit a conclusion that has quietly expired.
    func testTheRecordedResponseShowsWhyTitleCannotIdentifyAFileAndFileNameCan() throws {
        let pack = try Self.recordedPack()
        let four = try XCTUnwrap(pack.assets.first { $0.sku.hasSuffix("-004") })
        let eight = try XCTUnwrap(pack.assets.first { $0.sku.hasSuffix("-008") })

        XCTAssertEqual(four.title, eight.title,
                       "the recorded titles stopped colliding, so this fixture no longer "
                       + "demonstrates why matching by title was refused")
        XCTAssertNotEqual(four.fileName, eight.fileName,
                          "two different loops share a fileName in a real response — the "
                          + "basename join is not safe and must be reconsidered")

        // And the matcher built from those very bytes keeps them apart.
        let lookup = StudioSoundsBasenameMatcher.lookup(for: pack)
        XCTAssertTrue(lookup.ambiguous.isEmpty, "a real pack produced an ambiguous basename")
        XCTAssertEqual(
            lookup.asset(forFoldedBasename: StudioSoundsBasenameMatcher
                .fold("lo-fi-ambient-first-light-2f3f_drums_2bar_loop.wav"))?.sku,
            four.sku)
        XCTAssertEqual(
            lookup.asset(forFoldedBasename: StudioSoundsBasenameMatcher
                .fold("lo-fi-ambient-first-light-2f3f_drums_4bar_loop.wav"))?.sku,
            eight.sku)
    }

    /// The server gave up the BASENAME and kept the PATH. That distinction is
    /// why emitting the field was safe to do at all, so it is asserted on the
    /// recorded bytes rather than trusted.
    ///
    /// Read off the RAW JSON, not off the decoded value. A decoder that simply
    /// has no `filePath` property would satisfy an assertion on the decoded
    /// shape no matter what the service actually sent — that is the tautology
    /// this test is written to avoid being.
    func testTheRecordedResponseStillWithholdsTheStoragePath() throws {
        let raw = try String(contentsOf: Self.recordedFixtureURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("filePath"),
                       "the public payload now leaks filePath — the storage layout is exposed")
        XCTAssertFalse(raw.contains("/opt/majiks"),
                       "the public payload now leaks a server storage path")
        XCTAssertTrue(raw.contains("\"fileName\""),
                      "the recording predates fileName, so every basename test here is "
                      + "agreeing with invented JSON")
    }

    static var recordedFixtureURL: URL {
        StudioSoundsVaultTests.sourcesDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("TestFixtures/sounds-pack-detail.recorded.json")
    }

    static func recordedPack() throws -> StudioSoundsCatalogPack {
        try StudioSoundsCatalogDecoder.packDetail(from: Data(contentsOf: recordedFixtureURL))
    }

    // MARK: - 10. The feed lines
    //
    // Every lane on this repo so far has had a survivor, and the commonest
    // shape is every component proven and the single line in the VIEW that
    // feeds it unasserted. Both new buttons are checked twice: that the panel
    // calls the tested function, and that the tested function does what the
    // button promises.

    /// The panel's two gestures are the ones that were tested, and the macOS
    /// trap stayed shut.
    func testTheGetPanelIsWiredToTheTestedActions() throws {
        let text = try String(
            contentsOf: StudioSoundsVaultTests.sourcesDirectory
                .appendingPathComponent("Studio/StudioSoundsBrowser.swift"),
            encoding: .utf8)
        XCTAssertTrue(text.contains("StudioSoundsBrowserActions.getPack("),
                      "the pack row no longer goes through the tested download path")
        XCTAssertTrue(text.contains("StudioSoundsBrowserActions.refreshTempos("),
                      "the tempo button no longer goes through the tested export path")
        XCTAssertTrue(text.contains("liveGet.loadCatalogue()"),
                      "the disclosure button no longer loads the catalogue, so the pack list is empty")
        // A horizontal ScrollView silently eats Button clicks on macOS, and a
        // row of pack titles is exactly what tempts one. This assertion already
        // guarded the filter chips; the pack list is now inside its reach too.
        XCTAssertFalse(text.contains(".horizontal)"),
                       "a horizontal ScrollView appeared in the sounds browser; macOS will eat its clicks")
        // The catalogue read must not hang off a body or a `.task` that runs
        // for anybody who merely clicks the Sounds tab.
        XCTAssertFalse(text.contains(".task { liveGet"),
                       "the catalogue read moved into a .task, so opening Sounds makes a network call")
    }

    /// The button downloads into the folder the BROWSER is showing — not the
    /// default one — and the list is rescanned afterwards so the sounds
    /// actually appear. A success toast over an unchanged empty list is the
    /// "Publish button that made no network call" defect with the halves
    /// swapped.
    @MainActor
    func testGetPackLandsInTheBrowsersOwnFolderAndRefreshesTheList() async throws {
        // A root that is NOT the default, so a downloader that ignored the
        // browser's folder would put the files somewhere this test cannot see.
        let root = try temporaryVault()
        XCTAssertNotEqual(root, StudioSoundsVaultLocation.fallback)

        let asset = catalogueAsset("kit-001", title: "Wired Loop", kind: .loop, bpm: 96, key: "C minor")
        let pack = cataloguePack(assets: [asset])
        let transport = stub(pack: pack, audio: [:])

        let vault = StudioSoundsVaultModel(root: root)
        let get = StudioSoundsGetModel(
            downloader: StudioSoundsDownloader(transport: transport),
            client: StudioSoundsCatalogClient(transport: transport),
            tokenProvider: { "mk_test" })

        StudioSoundsBrowserActions.getPack(pack.slug, get: get, vault: vault)

        // Wait for the download and the rescan it triggers to land.
        let deadline = Date().addingTimeInterval(5)
        while vault.assets.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(vault.assets.count, 1,
                       "the browser never rescanned, so a person sees a success and an empty list")
        XCTAssertEqual(vault.assets.first?.bpm, 96)
        XCTAssertEqual(vault.assets.first?.name, "Wired Loop")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(
                StudioSoundsLayout.relativePath(packSlug: pack.slug, sku: asset.sku)).path),
            "the pack landed somewhere other than the folder the browser is showing")
    }

    /// The tempo button passes the paths the SCAN found. Handing the catalogue
    /// a guess about what is on disk is how an index ends up describing files
    /// that are not there.
    @MainActor
    func testRefreshTemposAsksAboutExactlyTheSoundsTheBrowserFound() async throws {
        let root = try temporaryVault()
        let asset = catalogueAsset("kit-009", title: "Held Loop", kind: .loop, bpm: 88, key: "A minor")
        let pack = cataloguePack(slug: "held-pack", title: "Held Pack", assets: [asset])

        let relative = StudioSoundsLayout.relativePath(packSlug: pack.slug, sku: asset.sku)
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try wav(dataBytes: 2048).write(to: url)

        let transport = StubTransport()
        transport.bodies["api/sounds/packs/held-pack"] = (200, [:], packDetailJSON(pack))

        let vault = StudioSoundsVaultModel(root: root)
        vault.adopt(await StudioVaultScanner.scan(root: root))
        XCTAssertNil(vault.assets.first?.bpm, "the fixture already had a tempo, so this proves nothing")

        let get = StudioSoundsGetModel(
            downloader: StudioSoundsDownloader(transport: transport),
            client: StudioSoundsCatalogClient(transport: transport),
            tokenProvider: { nil })   // deliberately NO key: this half needs none

        StudioSoundsBrowserActions.refreshTempos(get: get, vault: vault)

        let deadline = Date().addingTimeInterval(5)
        while vault.assets.first?.bpm == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(vault.assets.first?.bpm, 88,
                       "the tempo button did not reach the browser's rows")
        XCTAssertTrue(transport.requests.allSatisfy { $0.authorization == nil },
                      "updating tempos sent a credential")
    }

    // MARK: - 11. The strings the rail has to hold

    /// The progress line renders in a 172-point rail. An unconstrained string
    /// there is the exact shape that blew a toolbar row to 475 points.
    func testTheProgressLineStaysShortEnoughForTheRail() {
        let progress = StudioSoundsProgress(
            packTitle: "Kitchen Floor Confessions — Lo-Fi Indie Kit",
            assetIndex: 7, assetCount: 19, bytesSoFar: 0, bytesExpected: nil)
        XCTAssertTrue(progress.line.hasPrefix("7 of 19"))
        XCTAssertFalse(progress.line.contains("\n"),
                       "the progress line contains a newline, which a one-line Text will eat")
    }

    // MARK: - 12. Indexing files that are ALREADY on disk, by basename
    //
    // The last mile, and the half that works with NO CREDENTIAL: a folder
    // somebody rsync'd or unzipped stops reading "tempo unknown".
    //
    // What is at risk here, in the order it would hurt:
    //
    //  1. ATTACHING ONE LOOP'S TEMPO TO A DIFFERENT LOOP. The previous lane
    //     refused to ship a `title` heuristic for exactly this reason, and the
    //     measurement backs it: 82.7% of assets sit in a within-pack title
    //     collision. Basename collisions measured 0 of 4,758 across 250 live
    //     packs — but 0% today is not 0% forever, so the REFUSAL is tested,
    //     not the measurement.
    //  2. A REPORT THAT ONLY COUNTS ITS HITS. "412 matched" over a 500-file
    //     folder is a true sentence that hides 88 misses.
    //  3. THE MAIN THREAD, recorded inside the work and returned as data.

    /// Place a file on disk inside a vault, creating its folder.
    @discardableResult
    private func place(_ relative: String, in root: URL, bytes: Int = 2048) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try wav(dataBytes: bytes).write(to: url)
        return url
    }

    /// END TO END, and the reason this lane exists.
    ///
    /// A folder of files carrying the SERVER's names — the shape an rsync or an
    /// unzipped pack actually has, and the shape the downloader never produces
    /// — with no index beside it. Before: every row reads "tempo unknown".
    /// After: browser rows carrying the catalogue's real tempo, real key, real
    /// kind and real title.
    ///
    /// Asserted on `metaLine`, the string a person actually reads, rather than
    /// on the index file: a correct JSON file that the scanner fails to join is
    /// the exact "every component proven, the line that feeds it unasserted"
    /// survivor this repo keeps producing.
    func testAFolderOfServerNamedFilesGetsRealTemposWithNoCredential() async throws {
        let root = try temporaryVault()

        // Server-named, NOT sku-named. A matcher that only understood the
        // downloader's layout would find none of these.
        let loop = catalogueAsset(
            "dnb-pack-004", title: "Rolling Break 4-Bar", kind: .loop, bpm: 174, key: "G minor",
            fileName: "dnb-pack_drums_4bar_loop.wav")
        let shot = catalogueAsset(
            "dnb-pack-012", title: "Kick 01", kind: .oneShot, bpm: nil, key: nil,
            fileName: "dnb-pack_oneshot_00_kick.wav")
        let pack = cataloguePack(slug: "dnb-pack", title: "DnB Pack", assets: [loop, shot])

        try place("dnb-pack/dnb-pack_drums_4bar_loop.wav", in: root)
        try place("dnb-pack/dnb-pack_oneshot_00_kick.wav", in: root)

        // BEFORE. Without this the test could pass on a fixture that already
        // carried the value — the "wait predicate satisfied by a fixture that
        // already shipped the expected answer" trap.
        let cold = await StudioVaultScanner.scan(root: root)
        XCTAssertEqual(cold.assets.count, 2)
        XCTAssertEqual(cold.indexed, 0, "something already indexed this vault")
        let coldLoop = try XCTUnwrap(cold.assets.first { $0.id.contains("4bar_loop") })
        XCTAssertNil(coldLoop.bpm)
        XCTAssertTrue(coldLoop.metaLine.contains("tempo unknown"),
                      "the starting state is not 'tempo unknown', so this proves nothing")

        let transport = StubTransport()
        transport.bodies["api/sounds/packs/dnb-pack"] = (200, [:], packDetailJSON(pack))

        let result = try await StudioSoundsIndexExporter.refresh(
            vaultAt: root, presentRelativePaths: Set(cold.assets.map(\.id)),
            client: StudioSoundsCatalogClient(transport: transport))

        XCTAssertEqual(result.report.matched, 2)
        XCTAssertTrue(result.report.unmatched.isEmpty, "\(result.report.unmatched)")
        XCTAssertFalse(result.ranOnMainThread, "the basename match ran on the main thread")
        XCTAssertTrue(transport.requests.allSatisfy { $0.authorization == nil },
                      "indexing a hand-placed folder required a credential")

        // AFTER, through the scanner — the door the browser comes in by.
        let warm = await StudioVaultScanner.scan(root: root)
        XCTAssertEqual(warm.indexed, 2)
        let warmLoop = try XCTUnwrap(warm.assets.first { $0.id.contains("4bar_loop") })
        XCTAssertEqual(warmLoop.bpm, 174)
        XCTAssertEqual(warmLoop.key, "G minor")
        XCTAssertEqual(warmLoop.kind, .loop)
        XCTAssertEqual(warmLoop.metadata, .index,
                       "the tempo was read off the filename, not obtained from the catalogue")
        XCTAssertEqual(warmLoop.name, "Rolling Break 4-Bar")
        XCTAssertEqual(warmLoop.metaLine, "loop · 174 BPM · G minor · DnB Pack")

        // The one-shot's tempo column is genuinely null. It must come back
        // tempo-FREE, not tempo-unknown, and it must not gain a number.
        let warmShot = try XCTUnwrap(warm.assets.first { $0.id.contains("kick") })
        XCTAssertNil(warmShot.bpm)
        XCTAssertEqual(warmShot.kind, .oneShot)
        XCTAssertFalse(warmShot.metaLine.contains("tempo unknown"),
                       "a one-shot is tempo-free, not tempo-unknown")
        XCTAssertFalse(warmShot.metaLine.contains("BPM"),
                       "a one-shot with a null tempo column gained a number")
    }

    /// THE COLLISION DECISION, and the case this lane REFUSES.
    ///
    /// Two catalogue rows in one pack claiming the same basename. Measured at
    /// zero across 250 live packs / 4,758 assets, which is a reason to ship the
    /// join and NOT a reason to skip this test: the catalogue is somebody's
    /// live storefront and can publish a duplicate tomorrow.
    ///
    /// The file gets NO entry, is counted as refused, and keeps reading "tempo
    /// unknown". It does not get the first row's tempo, or the lowest sku's, or
    /// the more plausible-looking one — which is the same judgement that
    /// refused the title heuristic and refused to read `Snare_120`.
    func testTwoCatalogueRowsClaimingOneBasenameAreRefused() async throws {
        let root = try temporaryVault()
        let slow = catalogueAsset("twin-001", title: "Twin Slow", kind: .loop,
                                  bpm: 90, key: "A minor", fileName: "twin_loop.wav")
        let fast = catalogueAsset("twin-002", title: "Twin Fast", kind: .loop,
                                  bpm: 174, key: "G minor", fileName: "twin_loop.wav")
        let clean = catalogueAsset("twin-003", title: "Unambiguous", kind: .loop,
                                   bpm: 128, key: "C major", fileName: "solo_loop.wav")
        let pack = cataloguePack(slug: "twins", title: "Twins", assets: [slow, fast, clean])

        try place("twins/twin_loop.wav", in: root)
        try place("twins/solo_loop.wav", in: root)

        let transport = StubTransport()
        transport.bodies["api/sounds/packs/twins"] = (200, [:], packDetailJSON(pack))
        let result = try await StudioSoundsIndexExporter.refresh(
            vaultAt: root, presentRelativePaths: ["twins/twin_loop.wav", "twins/solo_loop.wav"],
            client: StudioSoundsCatalogClient(transport: transport))

        XCTAssertEqual(result.report.refused, ["twins/twin_loop.wav"])
        XCTAssertEqual(result.report.matched, 1, "the ambiguous file was given one of two tempos")
        XCTAssertEqual(result.report.unmatched, [],
                       "an ambiguous file was reported as merely absent from the catalogue, "
                       + "which is a different and less honest thing")

        // The artifact: the browser still says it does not know.
        let warm = await StudioVaultScanner.scan(root: root)
        let twin = try XCTUnwrap(warm.assets.first { $0.id.contains("twin_loop") })
        XCTAssertNil(twin.bpm, "an ambiguous basename was resolved by guessing")
        XCTAssertNotEqual(twin.bpm, 90)
        XCTAssertNotEqual(twin.bpm, 174)
        XCTAssertTrue(twin.metaLine.contains("tempo unknown"))

        // And the unambiguous file in the SAME pack is unharmed: a refusal
        // must be surgical, not a whole-pack bail-out.
        let solo = try XCTUnwrap(warm.assets.first { $0.id.contains("solo_loop") })
        XCTAssertEqual(solo.bpm, 128)
    }

    /// Files the catalogue has never heard of are COUNTED, not dropped, and
    /// still read "tempo unknown".
    ///
    /// The failure this prevents is silence: a person points this at 500 files,
    /// gets 412 tempos, and has no way to learn that the other 88 were never in
    /// the catalogue at all.
    func testFilesTheCatalogueDoesNotKnowAreCountedRatherThanSilentlyDropped() async throws {
        let root = try temporaryVault()
        let known = catalogueAsset("mix-001", title: "Known", kind: .loop, bpm: 100,
                                   key: "E minor", fileName: "known_loop.wav")
        let pack = cataloguePack(slug: "mixed", title: "Mixed", assets: [known])

        try place("mixed/known_loop.wav", in: root)
        try place("mixed/my_own_bounce.wav", in: root)          // theirs, not the catalogue's
        try place("some-other-vendor/kick.wav", in: root)        // a folder with no pack
        try place("loose_at_the_root.wav", in: root)             // in no folder at all

        let transport = StubTransport()
        transport.bodies["api/sounds/packs/mixed"] = (200, [:], packDetailJSON(pack))

        let present = Set((await StudioVaultScanner.scan(root: root)).assets.map(\.id))
        XCTAssertEqual(present.count, 4)

        let result = try await StudioSoundsIndexExporter.refresh(
            vaultAt: root, presentRelativePaths: present,
            client: StudioSoundsCatalogClient(transport: transport))
        let report = result.report

        XCTAssertEqual(report.matched, 1)
        XCTAssertEqual(report.unmatched, ["loose_at_the_root.wav",
                                          "mixed/my_own_bounce.wav",
                                          "some-other-vendor/kick.wav"])
        XCTAssertEqual(report.foldersNotInCatalogue, ["some-other-vendor"])
        XCTAssertEqual(report.packsConsulted, 1)

        // Nothing is lost between the buckets. This is the assertion that stops
        // a future edit dropping a whole category on the floor while every
        // other number still looks right.
        XCTAssertEqual(report.filesConsidered, present.count,
                       "the report accounts for \(report.filesConsidered) of "
                       + "\(present.count) files it was given")

        // And an unmatched file is unchanged on screen, not blanked or invented.
        let warm = await StudioVaultScanner.scan(root: root)
        let mine = try XCTUnwrap(warm.assets.first { $0.id.contains("my_own_bounce") })
        XCTAssertNil(mine.bpm)
        XCTAssertEqual(mine.name, "my_own_bounce", "a file with no catalogue row lost its own name")
        XCTAssertTrue(mine.metaLine.contains("tempo unknown"))
    }

    /// The person's sentence names the misses.
    ///
    /// Asserted on the exact wording because this string IS the deliverable —
    /// "412 of 500 sounds matched, 88 not in the catalogue" rather than
    /// "tempos updated", which is a true sentence that answers nothing.
    func testTheReportSaysWhatWasMatchedAndWhatWasNot() {
        var many = StudioSoundsIndexReport()
        many.matched = 412
        many.unmatched = (0..<88).map { "elsewhere/file-\($0).wav" }
        XCTAssertEqual(many.summary, "412 of 500 sounds matched, 88 not in the catalogue.")

        var refused = StudioSoundsIndexReport()
        refused.matched = 3
        refused.refused = ["p/a.wav", "p/b.wav"]
        XCTAssertEqual(
            refused.summary,
            "3 of 5 sounds matched, 2 skipped because the catalogue names them twice.")

        var none = StudioSoundsIndexReport()
        none.unmatched = ["vendor/one.wav", "vendor/two.wav"]
        none.foldersNotInCatalogue = ["vendor"]
        XCTAssertEqual(
            none.summary,
            "The catalogue knows nothing about those 2 sounds. "
            + "No pack called vendor on sounds.majiks.studio.")

        XCTAssertEqual(StudioSoundsIndexReport().summary, "No sounds to look up.")
    }

    /// Matching is scoped to ONE PACK, so cross-pack basename reuse cannot
    /// carry metadata sideways.
    ///
    /// This is not hypothetical: `stem_drums.wav`, `stem_bass.wav` and
    /// `stem_other.wav` appear once in EVERY pack — 15.7% of the sampled
    /// catalogue by asset count. A global basename table would be wrong for
    /// roughly one file in six.
    func testABasenameFromOnePackNeverDescribesAFileInAnother() async throws {
        let root = try temporaryVault()
        let a = catalogueAsset("alpha-001", title: "Alpha Stem", kind: .stem, bpm: 90,
                               key: "A minor", fileName: "stem_drums.wav")
        let b = catalogueAsset("beta-001", title: "Beta Stem", kind: .stem, bpm: 174,
                               key: "G minor", fileName: "stem_drums.wav")
        let alpha = cataloguePack(slug: "alpha", title: "Alpha", assets: [a])
        let beta = cataloguePack(slug: "beta", title: "Beta", assets: [b])

        try place("alpha/stem_drums.wav", in: root)
        try place("beta/stem_drums.wav", in: root)

        let transport = StubTransport()
        transport.bodies["api/sounds/packs/alpha"] = (200, [:], packDetailJSON(alpha))
        transport.bodies["api/sounds/packs/beta"] = (200, [:], packDetailJSON(beta))

        let result = try await StudioSoundsIndexExporter.refresh(
            vaultAt: root, presentRelativePaths: ["alpha/stem_drums.wav", "beta/stem_drums.wav"],
            client: StudioSoundsCatalogClient(transport: transport))
        XCTAssertEqual(result.report.matched, 2)
        XCTAssertTrue(result.report.refused.isEmpty,
                      "a name reused across packs was treated as ambiguous, which would "
                      + "strand one file in six")

        let warm = await StudioVaultScanner.scan(root: root)
        XCTAssertEqual(warm.assets.first { $0.id == "alpha/stem_drums.wav" }?.bpm, 90)
        XCTAssertEqual(warm.assets.first { $0.id == "beta/stem_drums.wav" }?.bpm, 174)
        XCTAssertEqual(warm.assets.first { $0.id == "alpha/stem_drums.wav" }?.pack, "Alpha")
    }

    /// A vault holding BOTH a downloaded pack and a hand-placed one indexes in
    /// one pass. The sku is carried as a second matching key precisely so the
    /// downloader's layout does not need a separate code path that can rot
    /// while nobody is looking at it.
    func testDownloadedAndHandPlacedSoundsIndexThroughTheSamePass() async throws {
        let root = try temporaryVault()
        let asset = catalogueAsset("both-001", title: "Either Way", kind: .loop, bpm: 140,
                                   key: "B minor", fileName: "both_drums_loop.wav")
        let pack = cataloguePack(slug: "both", title: "Both", assets: [asset])

        // The downloader's name for it…
        try place(StudioSoundsLayout.relativePath(packSlug: "both", sku: "both-001"), in: root)
        // …and the server's name for the same sound, in the same folder.
        try place("both/both_drums_loop.wav", in: root)

        let transport = StubTransport()
        transport.bodies["api/sounds/packs/both"] = (200, [:], packDetailJSON(pack))
        let result = try await StudioSoundsIndexExporter.refresh(
            vaultAt: root, presentRelativePaths: ["both/both-001.wav", "both/both_drums_loop.wav"],
            client: StudioSoundsCatalogClient(transport: transport))

        XCTAssertEqual(result.report.matched, 2)
        XCTAssertEqual(result.report.packsConsulted, 1, "the same pack was fetched twice")
        let warm = await StudioVaultScanner.scan(root: root)
        XCTAssertEqual(warm.indexed, 2)
        XCTAssertTrue(warm.assets.allSatisfy { $0.bpm == 140 })
    }

    /// Case only. macOS filesystems are case-insensitive, so `Kick.WAV` on disk
    /// and `kick.wav` in the catalogue are the same file and must match.
    func testTheMatchIsCaseInsensitiveBecauseTheFilesystemIs() async throws {
        let root = try temporaryVault()
        let asset = catalogueAsset("case-001", title: "Shouty", kind: .loop, bpm: 111,
                                   key: "F minor", fileName: "kick_loop.wav")
        let pack = cataloguePack(slug: "casing", title: "Casing", assets: [asset])
        try place("casing/Kick_Loop.WAV", in: root)

        let transport = StubTransport()
        transport.bodies["api/sounds/packs/casing"] = (200, [:], packDetailJSON(pack))
        let result = try await StudioSoundsIndexExporter.refresh(
            vaultAt: root, presentRelativePaths: ["casing/Kick_Loop.WAV"],
            client: StudioSoundsCatalogClient(transport: transport))
        XCTAssertEqual(result.report.matched, 1)
        let warm = await StudioVaultScanner.scan(root: root)
        XCTAssertEqual(warm.assets.first?.bpm, 111)
    }

    /// An asset with NO `fileName` — an older deployment, or a null column —
    /// must not fold to an empty key that then swallows unrelated files.
    func testAnAssetWithNoFileNameStillMatchesBySkuAndSwallowsNothingElse() async throws {
        let root = try temporaryVault()
        let bare = catalogueAsset("old-001", title: "Legacy", kind: .loop, bpm: 100,
                                  key: "C major", fileName: nil)
        let pack = cataloguePack(slug: "legacy", title: "Legacy", assets: [bare])

        try place("legacy/old-001.wav", in: root)      // the downloader's name: matches by sku
        try place("legacy/something_else.wav", in: root)

        let transport = StubTransport()
        transport.bodies["api/sounds/packs/legacy"] = (200, [:], packDetailJSON(pack))
        let result = try await StudioSoundsIndexExporter.refresh(
            vaultAt: root, presentRelativePaths: ["legacy/old-001.wav", "legacy/something_else.wav"],
            client: StudioSoundsCatalogClient(transport: transport))

        XCTAssertEqual(result.report.matched, 1)
        XCTAssertEqual(result.report.unmatched, ["legacy/something_else.wav"])
        let warm = await StudioVaultScanner.scan(root: root)
        XCTAssertEqual(warm.assets.first { $0.id.contains("old-001") }?.bpm, 100)
        XCTAssertNil(warm.assets.first { $0.id.contains("something_else") }?.bpm,
                     "an empty fileName folded into a key that swallowed an unrelated file")
    }

    /// SURVIVOR, closed.
    ///
    /// A mutation that widened the fold from `lowercased()` to
    /// `StudioSoundsSearch.normalize` — which flattens every separator to a
    /// space, so `drums_2bar`, `drums-2bar` and `drums 2bar` become ONE key —
    /// left the whole suite green. Nothing pinned how narrow the fold is, so
    /// the net could be widened silently.
    ///
    /// Widening it buys nothing: a filename is copied verbatim by every tool
    /// that moves a file, so there is no separator drift to absorb. And it
    /// costs the one thing this join has: collision headroom. Every collision
    /// under the narrow fold is also one under the wide fold, and the wide fold
    /// can collide where the narrow one cannot — which turns matched files into
    /// refused ones, i.e. tempos a person had into "tempo unknown".
    ///
    /// Asserted on the ARTIFACT, not on `fold` itself: two sounds whose names
    /// differ only in their separators must each keep their OWN tempo. Under
    /// the wide fold both go ambiguous and both lose theirs.
    func testTheFoldIsNarrowSoNamesDifferingOnlyInSeparatorsStayDistinct() async throws {
        let root = try temporaryVault()
        let under = catalogueAsset("sep-001", title: "Underscored", kind: .loop, bpm: 90,
                                   key: "A minor", fileName: "sep_2bar_loop.wav")
        let dashed = catalogueAsset("sep-002", title: "Dashed", kind: .loop, bpm: 174,
                                    key: "G minor", fileName: "sep-2bar-loop.wav")
        let pack = cataloguePack(slug: "seps", title: "Seps", assets: [under, dashed])

        try place("seps/sep_2bar_loop.wav", in: root)
        try place("seps/sep-2bar-loop.wav", in: root)

        let transport = StubTransport()
        transport.bodies["api/sounds/packs/seps"] = (200, [:], packDetailJSON(pack))
        let result = try await StudioSoundsIndexExporter.refresh(
            vaultAt: root, presentRelativePaths: ["seps/sep_2bar_loop.wav", "seps/sep-2bar-loop.wav"],
            client: StudioSoundsCatalogClient(transport: transport))

        XCTAssertEqual(result.report.matched, 2,
                       "the fold was widened until two distinct filenames collided, so files "
                       + "that had tempos now read 'tempo unknown': \(result.report.refused)")
        XCTAssertTrue(result.report.refused.isEmpty)

        let warm = await StudioVaultScanner.scan(root: root)
        XCTAssertEqual(warm.assets.first { $0.id.contains("sep_2bar") }?.bpm, 90)
        XCTAssertEqual(warm.assets.first { $0.id.contains("sep-2bar") }?.bpm, 174)
    }

    /// The button a person presses produces the report a person reads.
    ///
    /// The wiring test next door proves the button reaches `refreshTempos`; this
    /// proves `refreshTempos` surfaces the accounting rather than a count of its
    /// own successes. Both halves, because "every component proven and the line
    /// that feeds it unasserted" is this repo's most common survivor.
    @MainActor
    func testTheTempoButtonSurfacesTheMissesAndNotOnlyTheHits() async throws {
        let root = try temporaryVault()
        let known = catalogueAsset("btn-001", title: "Found", kind: .loop, bpm: 123,
                                   key: "D minor", fileName: "found_loop.wav")
        let pack = cataloguePack(slug: "button", title: "Button", assets: [known])

        try place("button/found_loop.wav", in: root)
        try place("button/never_heard_of_it.wav", in: root)

        let transport = StubTransport()
        transport.bodies["api/sounds/packs/button"] = (200, [:], packDetailJSON(pack))

        let vault = StudioSoundsVaultModel(root: root)
        vault.adopt(await StudioVaultScanner.scan(root: root))
        XCTAssertTrue(vault.assets.allSatisfy { $0.bpm == nil },
                      "the fixture already had tempos, so this proves nothing")

        let get = StudioSoundsGetModel(
            downloader: StudioSoundsDownloader(transport: transport),
            client: StudioSoundsCatalogClient(transport: transport),
            tokenProvider: { nil })          // deliberately NO key: this half needs none

        StudioSoundsBrowserActions.refreshTempos(get: get, vault: vault)

        let deadline = Date().addingTimeInterval(5)
        while get.lastReport == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let report = try XCTUnwrap(get.lastReport, "the tempo button produced no report")
        XCTAssertEqual(report.matched, 1)
        XCTAssertEqual(report.unmatched, ["button/never_heard_of_it.wav"])
        XCTAssertEqual(get.statusLine, "1 of 2 sounds matched, 1 not in the catalogue.")
        XCTAssertTrue(transport.requests.allSatisfy { $0.authorization == nil },
                      "updating tempos sent a credential")
    }

    func testProgressReportsEveryAssetRatherThanJumpingFromNothingToDone() async throws {
        let root = try temporaryVault()
        let assets = (0..<5).map { catalogueAsset("kit-\($0)") }
        let pack = cataloguePack(assets: assets)
        let seen = ManagedAtomicish()
        _ = try await StudioSoundsDownloader(transport: stub(pack: pack, audio: [:]))
            .download(packSlug: pack.slug, into: root, token: "mk_test",
                      onProgress: { _ in seen.bump() })
        XCTAssertGreaterThanOrEqual(seen.value, assets.count,
                                    "progress was reported \(seen.value) times for \(assets.count) assets")
    }
}
