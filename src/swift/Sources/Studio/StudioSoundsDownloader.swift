import Foundation

// MARK: - Getting the sounds onto the machine, and proving they arrived intact
//
// THE SIZE OF THE PROBLEM, measured rather than estimated.
//
// The vault is 13,971 WAV masters totalling 29,191,567,908 bytes — 27.2 GiB —
// across 739 packs, plus 3.2 GiB of preview MP3s. Average pack: about 40 MB.
// A downloader with a "get everything" button is a downloader that fills a
// laptop, so there isn't one: the unit of download is a PACK, always, and the
// UI never offers a gesture whose cost it cannot state up front.
//
// THREE THINGS THAT MUST BE TRUE, each of which is a scar somewhere in this
// repo or in this file's own history.
//
//  1. NOT ON THE MAIN THREAD. A download is the single most likely place to
//     repeat the P0 that shipped in 3.4.13, where `BrigadeConfig.isConfigured`
//     read like a field access and did a blocking XPC round trip on every
//     view-body pass. So every function here that touches the network or the
//     filesystem is `nonisolated async`, and — like the scanner next door —
//     each one RECORDS where it ran and returns that as data. "Supposed to hop
//     off the actor" is not evidence.
//
//  2. A BAD FILE IS NEVER KEPT. This repo has already been burned by a
//     truncated WAV fixture (`host_undo.rs`). A truncated WAV does not fail to
//     open: it opens, and it plays as a click, and it does that inside somebody's
//     song. So every downloaded file is verified against TWO independent
//     things — the length the server declared, and the length the file declares
//     about ITSELF in its own RIFF header — and a failure is QUARANTINED, not
//     deleted and never kept in place. See `StudioSoundsVerifier`.
//
//  3. NOTHING HERE IS A PROJECT MUTATION. Downloading journals nothing, exactly
//     as auditioning journals nothing. This file cannot reach the command bus:
//     it holds no engine and no view model, which is enforcement rather than
//     intention.

// MARK: - Verification

/// What a check of a downloaded file concluded. An enum rather than a `Bool`
/// because "this file is wrong" and "this file is wrong IN THIS WAY" are
/// different amounts of help, and the second one is what a person needs when
/// three files out of nineteen fail.
enum StudioSoundsVerification: Sendable, Equatable {
    case ok(bytes: Int)
    /// The server said how many bytes it was sending and sent fewer.
    case shortOfDeclaredLength(expected: Int, got: Int)
    /// The file's own RIFF header describes more audio than the file contains.
    /// This is the one that catches a truncation the transport did not notice,
    /// including one the server itself served short.
    case truncatedAudio(declaredDataBytes: Int, availableBytes: Int)
    /// Not a WAV at all. Usually an error page saved with a `.wav` name, which
    /// is what a proxy or a captive portal hands you.
    case notAudio(String)
    case empty

    var isOK: Bool { if case .ok = self { return true }; return false }

    /// One line, for a person, naming the file's problem and not the code's.
    var complaint: String? {
        switch self {
        case .ok: return nil
        case .shortOfDeclaredLength(let expected, let got):
            return "arrived incomplete (\(got) of \(expected) bytes)"
        case .truncatedAudio(let declared, let available):
            return "is cut short — its header describes \(declared) bytes of audio and only \(available) arrived"
        case .notAudio(let why): return "is not an audio file (\(why))"
        case .empty: return "arrived empty"
        }
    }
}

/// Checks that a file on disk is the whole file.
///
/// Reads only the HEADER, not the audio: a WAV states the byte length of its
/// own `data` chunk, so comparing that against the file size catches truncation
/// for the cost of a 4 KB read no matter how big the file is. That is the whole
/// trick, and it is why this needs no checksum from the server — which is just
/// as well, because the catalogue has none. (Established: `sample_assets` has
/// no `checksum`, `sha256`, `content_hash` or `size_bytes` column;
/// `provenanceHash` is a hash of the certificate, whose own `contentHash` field
/// is literally null; and `X-Majiks-Manifest-Sha256` is the digest of the
/// manifest JSON, not of the audio. There is no server-side integrity signal to
/// use, so the file has to answer for itself.)
enum StudioSoundsVerifier {

    /// How much of the front of the file to read. A WAV's `data` chunk is
    /// normally the second chunk; 64 KB clears even a file carrying a large
    /// `LIST`/`INFO` block before it.
    static let headerWindow = 65_536

    /// `declaredLength` is the server's `Content-Length` when there was one.
    /// Passing nil is not a free pass — the structural check still runs.
    static func verify(fileAt url: URL, declaredLength: Int?) -> StudioSoundsVerification {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil else {
            return .notAudio("it is not on disk")
        }
        if size == 0 { return .empty }

        if let declaredLength, declaredLength > 0, size < declaredLength {
            return .shortOfDeclaredLength(expected: declaredLength, got: size)
        }

        // Only WAV is structurally checked, because only WAV is what the
        // catalogue serves (13,971 files, all `.wav` — counted on the server).
        // A different extension is not failed on a check this cannot perform;
        // saying "corrupt" about a format you did not parse is a lie of the
        // same family as inventing a tempo.
        guard url.pathExtension.lowercased() == "wav" else { return .ok(bytes: size) }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .notAudio("it could not be opened")
        }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headerWindow), head.count >= 12 else {
            return .notAudio("it is too small to be a WAV")
        }
        return checkRIFF(head, fileSize: size)
    }

    /// The RIFF walk, factored out so a test can hand it bytes without a disk.
    static func checkRIFF(_ head: Data, fileSize: Int) -> StudioSoundsVerification {
        let bytes = [UInt8](head)
        func tag(_ at: Int) -> String {
            guard at + 4 <= bytes.count else { return "" }
            return String(bytes: bytes[at..<(at + 4)], encoding: .ascii) ?? ""
        }
        func u32(_ at: Int) -> Int? {
            guard at + 4 <= bytes.count else { return nil }
            return Int(UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8
                       | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24)
        }

        guard tag(0) == "RIFF" else { return .notAudio("it does not start with RIFF") }
        guard tag(8) == "WAVE" else { return .notAudio("it is a RIFF file but not WAVE") }

        // The RIFF size field counts everything after the first 8 bytes. A file
        // cut in half keeps the original number here, so this alone catches the
        // commonest truncation — but it is checked as a FLOOR, not for
        // equality: a trailing tag block appended by another tool makes the
        // file legitimately longer than the field claims.
        if let riffSize = u32(4), fileSize < riffSize + 8 {
            return .truncatedAudio(declaredDataBytes: riffSize + 8, availableBytes: fileSize)
        }

        var cursor = 12
        while cursor + 8 <= bytes.count {
            let id = tag(cursor)
            guard let size = u32(cursor + 4), size >= 0 else { break }
            let payload = cursor + 8
            if id == "data" {
                guard payload + size <= fileSize else {
                    return .truncatedAudio(declaredDataBytes: size, availableBytes: max(0, fileSize - payload))
                }
                return .ok(bytes: fileSize)
            }
            // Chunks are word-aligned: an odd size is followed by a pad byte.
            cursor = payload + size + (size % 2)
        }
        // Ran off the end of the window without finding `data`. Do not claim a
        // verdict a 64 KB read cannot support.
        return .ok(bytes: fileSize)
    }
}

// MARK: - What one download did

struct StudioSoundsAssetOutcome: Sendable, Equatable {
    let assetID: String
    let relativePath: String
    let bytes: Int
    /// Where a resumed download picked up. 0 for a fresh one; a test asserts
    /// this is non-zero after an interrupted attempt.
    let resumedFrom: Int
    let verification: StudioSoundsVerification
    /// Set when verification failed and the file was moved out of the vault.
    let quarantinedAt: String?

    var succeeded: Bool { verification.isOK && quarantinedAt == nil }
}

struct StudioSoundsPackOutcome: Sendable {
    let packSlug: String
    let packTitle: String
    let outcomes: [StudioSoundsAssetOutcome]
    /// Entries actually written to `majiks-sounds-index.json`.
    let indexedCount: Int
    /// Evidence, not decoration — same contract as `StudioVaultScanResult`.
    let ranOnMainThread: Bool

    var succeeded: [StudioSoundsAssetOutcome] { outcomes.filter(\.succeeded) }
    var failed: [StudioSoundsAssetOutcome] { outcomes.filter { !$0.succeeded } }

    /// What the toast says. Never rounds a partial result up to done: three
    /// good files out of nineteen is reported as three out of nineteen.
    var summary: String {
        let good = succeeded.count
        let bad = failed.count
        if bad == 0 { return "Got \(good) sound\(good == 1 ? "" : "s") from \(packTitle)." }
        if good == 0 { return "Could not get \(packTitle). \(bad) file\(bad == 1 ? "" : "s") failed." }
        return "Got \(good) of \(good + bad) sounds from \(packTitle). \(bad) failed and \(bad == 1 ? "was" : "were") set aside."
    }
}

/// Progress, pushed out of the work as it happens.
struct StudioSoundsProgress: Sendable, Equatable {
    let packTitle: String
    let assetIndex: Int
    let assetCount: Int
    let bytesSoFar: Int
    let bytesExpected: Int?

    /// 0...1, or nil when nothing said how big the pack is.
    var fraction: Double? {
        guard assetCount > 0 else { return nil }
        return min(1, max(0, Double(assetIndex) / Double(assetCount)))
    }

    /// The line under the bar. Short by construction — it renders in a 172-point
    /// rail where an unconstrained string wraps to one character per line.
    var line: String { "\(assetIndex) of \(assetCount) · \(packTitle)" }
}

// MARK: - The downloader

/// Fetches a pack's masters, verifies each one, and writes the sidecar index.
///
/// A struct with `nonisolated` methods rather than an actor: there is no shared
/// mutable state to protect (each call owns its files), and an actor would put
/// a serialisation point in front of work whose whole job is to not block
/// anybody.
struct StudioSoundsDownloader: Sendable {
    let transport: any StudioSoundsTransport
    let client: StudioSoundsCatalogClient

    init(transport: any StudioSoundsTransport = StudioSoundsURLSessionTransport(),
         base: URL = StudioSoundsEndpoint.base) {
        self.transport = transport
        self.client = StudioSoundsCatalogClient(transport: transport, base: base)
    }

    /// Download one pack into a vault.
    ///
    /// `token` is passed IN, never read from the keychain here: a securityd
    /// round trip belongs at the edge where somebody pressed a button, once,
    /// and not inside a loop that runs nineteen times.
    ///
    /// Refuses premium content outright rather than trying and reading the 403.
    /// The point is not to save a round trip — it is that this client must not
    /// contain a code path that attempts to obtain paid content.
    nonisolated func download(
        packSlug: String,
        into root: URL,
        token: String?,
        onProgress: @Sendable @escaping (StudioSoundsProgress) -> Void = { _ in }
    ) async throws -> StudioSoundsPackOutcome {
        var onMain = StudioVaultScanner.isOnMainThread()

        let pack = try await client.pack(slug: packSlug)
        guard let token, !token.isEmpty else { throw StudioSoundsError.notSignedIn }

        // Free means "free with a login" — the storefront auto-grants the
        // entitlement on the first download. Premium costs credits and is not
        // this app's to hand out.
        let payable = pack.assets.filter(\.isFree)
        guard !payable.isEmpty else { throw StudioSoundsError.notEntitled(pack.title) }

        let folder = root.appendingPathComponent(pack.slug, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var outcomes: [StudioSoundsAssetOutcome] = []
        for (offset, asset) in payable.enumerated() {
            try Task.checkCancellation()
            if StudioVaultScanner.isOnMainThread() { onMain = true }
            onProgress(StudioSoundsProgress(
                packTitle: pack.title, assetIndex: offset, assetCount: payable.count,
                bytesSoFar: outcomes.reduce(0) { $0 + $1.bytes }, bytesExpected: nil))

            let outcome = await downloadOne(asset: asset, packSlug: pack.slug, into: root, token: token)
            outcomes.append(outcome)
        }
        onProgress(StudioSoundsProgress(
            packTitle: pack.title, assetIndex: payable.count, assetCount: payable.count,
            bytesSoFar: outcomes.reduce(0) { $0 + $1.bytes }, bytesExpected: nil))

        // The index describes ONLY what verified. This is the line that makes
        // "tempo unknown" become "125 BPM", and it is deliberately last: an
        // index written before the bytes landed would describe files that are
        // not there.
        let landed = Set(outcomes.filter(\.succeeded).map(\.relativePath))
        let entries = StudioSoundsIndexExporter.entries(for: pack, limitedTo: landed)
        if !entries.isEmpty {
            try StudioSoundsIndexExporter.merge(entries, intoVaultAt: root)
        }

        return StudioSoundsPackOutcome(
            packSlug: pack.slug, packTitle: pack.title, outcomes: outcomes,
            indexedCount: entries.count, ranOnMainThread: onMain)
    }

    /// One asset: resume if there is a part file, stream, verify, and either
    /// commit or quarantine. Never throws for a bad FILE — a bad file is a
    /// result, and one rotten asset must not abandon the other eighteen.
    /// Throws only for cancellation and for things that end the whole run.
    nonisolated func downloadOne(
        asset: StudioSoundsCatalogAsset,
        packSlug: String,
        into root: URL,
        token: String
    ) async -> StudioSoundsAssetOutcome {
        let relative = StudioSoundsLayout.relativePath(packSlug: packSlug, sku: asset.sku)
        let final = root.appendingPathComponent(relative)
        let part = final.appendingPathExtension("part")
        let fm = FileManager.default

        func fail(_ verdict: StudioSoundsVerification, bytes: Int, resumed: Int) -> StudioSoundsAssetOutcome {
            StudioSoundsAssetOutcome(
                assetID: asset.id, relativePath: relative, bytes: bytes,
                resumedFrom: resumed, verification: verdict, quarantinedAt: nil)
        }

        // Already have it, whole? Then this is free. Re-verified rather than
        // assumed present, so a file corrupted after the fact is caught by the
        // next run instead of living forever.
        if fm.fileExists(atPath: final.path) {
            let verdict = StudioSoundsVerifier.verify(fileAt: final, declaredLength: nil)
            if verdict.isOK {
                let size = ((try? fm.attributesOfItem(atPath: final.path)[.size] as? Int) ?? nil) ?? 0
                return StudioSoundsAssetOutcome(
                    assetID: asset.id, relativePath: relative, bytes: size,
                    resumedFrom: size, verification: verdict, quarantinedAt: nil)
            }
            try? fm.removeItem(at: final)
        }

        let alreadyHave = ((try? fm.attributesOfItem(atPath: part.path)[.size] as? Int) ?? nil) ?? 0

        var request = URLRequest(url: StudioSoundsEndpoint.download(assetID: asset.id, base: client.base))
        StudioSoundsAccount.authorize(&request, with: token)
        if alreadyHave > 0 {
            // Resume. The server may ignore this and answer 200 with the whole
            // body, which is handled below rather than assumed away.
            request.setValue("bytes=\(alreadyHave)-", forHTTPHeaderField: "Range")
        }

        let stream: AsyncThrowingStream<Data, Error>
        let response: HTTPURLResponse
        do {
            (stream, response) = try await transport.stream(for: request)
        } catch {
            return fail(.notAudio("the download could not start"), bytes: 0, resumed: alreadyHave)
        }

        guard (200..<300).contains(response.statusCode) else {
            return fail(.notAudio("the service answered \(response.statusCode)"), bytes: 0, resumed: alreadyHave)
        }

        // 206 means the resume was honoured; 200 means it was not and the body
        // is the WHOLE file, so the part file must be thrown away rather than
        // appended to — appending would produce a file that is too LONG, which
        // no length check catches and which decodes as audio with a stutter in
        // the middle.
        let resuming = response.statusCode == 206 && alreadyHave > 0
        if !resuming { try? fm.removeItem(at: part) }
        let resumedFrom = resuming ? alreadyHave : 0

        let declared = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init)
        let expectedTotal = declared.map { $0 + resumedFrom }

        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: part) else {
            return fail(.notAudio("a file could not be written"), bytes: 0, resumed: resumedFrom)
        }
        var written = resumedFrom
        do {
            try handle.seekToEnd()
            for try await chunk in stream {
                try handle.write(contentsOf: chunk)
                written += chunk.count
            }
            try handle.close()
        } catch {
            try? handle.close()
            // The part file STAYS. That is the whole of resumability: the next
            // run reads its length and asks for the rest.
            return fail(.shortOfDeclaredLength(expected: expectedTotal ?? written, got: written),
                        bytes: written, resumed: resumedFrom)
        }

        let verdict = StudioSoundsVerifier.verify(fileAt: part, declaredLength: expectedTotal)
        guard verdict.isOK else {
            // QUARANTINE, not delete. Deleting hides the evidence from whoever
            // has to work out why a pack keeps failing, and keeping it in place
            // puts a file that plays as a click one keystroke from a song.
            let quarantine = StudioSoundsLayout.quarantineURL(root: root, relativePath: relative)
            try? fm.createDirectory(at: quarantine.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: quarantine)
            try? fm.moveItem(at: part, to: quarantine)
            return StudioSoundsAssetOutcome(
                assetID: asset.id, relativePath: relative, bytes: written,
                resumedFrom: resumedFrom, verification: verdict,
                quarantinedAt: quarantine.path)
        }

        // Commit only after it verified. Until this line the vault contains no
        // file the browser can see.
        try? fm.removeItem(at: final)
        do { try fm.moveItem(at: part, to: final) }
        catch { return fail(.notAudio("it could not be moved into place"), bytes: written, resumed: resumedFrom) }

        return StudioSoundsAssetOutcome(
            assetID: asset.id, relativePath: relative, bytes: written,
            resumedFrom: resumedFrom, verification: verdict, quarantinedAt: nil)
    }
}

// MARK: - The main-actor half the browser watches

/// Download state for the UI. Holds no engine, journals nothing, and — like
/// `StudioSoundsVaultModel` — stores its derived strings rather than computing
/// them in a body.
@MainActor
final class StudioSoundsGetModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        /// Reading the pack list. Public, no key needed.
        case loadingCatalogue
        case ready
        case working(StudioSoundsProgress)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var packs: [StudioSoundsCatalogPack] = []
    /// The last thing that happened, in words. Shown once, not accumulated:
    /// a rail this narrow cannot hold a log.
    @Published private(set) var note: String?
    /// The last index refresh's full accounting. Published so a test can assert
    /// on the ARTIFACT the person's gesture produced rather than on a function
    /// it called in isolation — the same reason `ranOnMainThread` is data.
    @Published private(set) var lastReport: StudioSoundsIndexReport?
    @Published var selectedSlug: String?

    private let downloader: StudioSoundsDownloader
    private let client: StudioSoundsCatalogClient

    /// Where the key comes from. A seam, so the wiring tests can prove that the
    /// browser's button reaches this model and this model reaches the vault
    /// root — without a test suite writing a credential into a real keychain,
    /// and without the "N accesses, one securityd round trip" claim next door
    /// being disturbed by a test that plants an item.
    private let tokenProvider: @Sendable () -> String?

    private var task: Task<Void, Never>?

    init(downloader: StudioSoundsDownloader = StudioSoundsDownloader(),
         client: StudioSoundsCatalogClient = StudioSoundsCatalogClient(),
         tokenProvider: @escaping @Sendable () -> String? = { StudioSoundsAccount.key() }) {
        self.downloader = downloader
        self.client = client
        self.tokenProvider = tokenProvider
    }

    /// Cheap enough for a view body — `StudioKeychainItem` pays one securityd
    /// round trip in the life of the process and `StudioSoundsDownloaderTests`
    /// asserts that rendering does not move the counter.
    var hasKey: Bool { StudioSoundsAccount.hasKey }

    var isBusy: Bool { if case .working = phase { return true }; return false }

    /// The pack list. NEVER call from a body — `.task` or a button.
    func loadCatalogue() {
        guard packs.isEmpty, !isBusy else { return }
        phase = .loadingCatalogue
        task?.cancel()
        task = Task { [weak self, client] in
            do {
                let found = try await client.allPacks()
                await MainActor.run {
                    self?.packs = found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                    self?.phase = .ready
                }
            } catch {
                await MainActor.run { self?.phase = .failed(Self.wording(error)) }
            }
        }
    }

    /// Fetch one pack. `onFinished` hands the vault root back so the browser can
    /// rescan — the download does not reach into the vault model, because these
    /// two things having no reference to each other is what keeps a download
    /// from ever becoming a project edit.
    func download(slug: String, into root: URL, onFinished: @escaping (StudioSoundsPackOutcome) -> Void) {
        guard !isBusy else { return }
        // The ONE keychain read, here, at the edge, where a person pressed a
        // button. Not in the loop and not in a body.
        guard let token = tokenProvider() else {
            phase = .failed(StudioSoundsError.notSignedIn.errorDescription ?? "No key.")
            return
        }
        phase = .working(StudioSoundsProgress(
            packTitle: packs.first { $0.slug == slug }?.title ?? slug,
            assetIndex: 0, assetCount: 1, bytesSoFar: 0, bytesExpected: nil))
        task?.cancel()
        task = Task { [weak self, downloader] in
            do {
                let outcome = try await downloader.download(
                    packSlug: slug, into: root, token: token,
                    onProgress: { progress in
                        Task { @MainActor in self?.phase = .working(progress) }
                    })
                await MainActor.run {
                    self?.phase = .ready
                    self?.note = outcome.summary
                    onFinished(outcome)
                }
            } catch {
                await MainActor.run { self?.phase = .failed(Self.wording(error)) }
            }
        }
    }

    /// Give the sounds already on disk their tempos, from the PUBLIC catalogue.
    ///
    /// No key, and deliberately so: this is the half that works for somebody
    /// who has never signed in, and it is the half worth shipping on its own.
    /// Hands the root back so the caller can rescan — this model never touches
    /// the vault model, which is what keeps a metadata refresh from ever
    /// becoming a project edit.
    func refreshTempos(
        vaultAt root: URL,
        present: Set<String>,
        onFinished: @escaping (URL) -> Void
    ) {
        guard !isBusy, !present.isEmpty else { return }
        phase = .working(StudioSoundsProgress(
            packTitle: "tempos", assetIndex: 0, assetCount: 1, bytesSoFar: 0, bytesExpected: nil))
        task?.cancel()
        task = Task { [weak self, client] in
            do {
                let result = try await StudioSoundsIndexExporter.refresh(
                    vaultAt: root, presentRelativePaths: present, client: client)
                await MainActor.run {
                    self?.phase = .ready
                    // The REPORT's own words, not a count of what worked.
                    // "Tempos updated for 412 sounds" over a 500-file folder is
                    // a true sentence that leaves a person with no way to learn
                    // the other 88 were never in the catalogue — the same
                    // family as a toast that reports only its successes.
                    self?.note = result.report.summary
                    self?.lastReport = result.report
                    onFinished(root)
                }
            } catch {
                await MainActor.run { self?.phase = .failed(Self.wording(error)) }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if isBusy { phase = .ready; note = "Download stopped." }
    }

    static func wording(_ error: Error) -> String {
        (error as? StudioSoundsError)?.errorDescription
            ?? (error is CancellationError ? "Download stopped." : error.localizedDescription)
    }

    /// The line the panel shows. Stored-derived rather than assembled in a body,
    /// and short: this renders in a 172-point rail.
    var statusLine: String {
        switch phase {
        case .idle: return ""
        case .loadingCatalogue: return "Reading the catalogue…"
        case .ready: return note ?? ""
        case .working(let progress): return progress.line
        case .failed(let why): return why
        }
    }
}
