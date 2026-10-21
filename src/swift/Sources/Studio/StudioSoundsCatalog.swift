import Foundation

// MARK: - The catalogue: the half of the vault that is NOT on this machine
//
// WHY THIS EXISTS.
//
// `StudioSoundsVault.swift` ends on an admission: "no such export exists. The
// server has the columns and they are populated; there is no downloader, no
// endpoint that emits this file, and no vault on this machine to write it
// beside." So the browser it feeds showed an empty list, and every loop that
// did somehow arrive read "tempo unknown". This file is the pipe. The content
// was never the bottleneck.
//
// WHAT WAS ESTABLISHED RATHER THAN ASSUMED, by reading the storefront's source
// and by measuring the live service:
//
//  * A catalogue API ALREADY EXISTS and is PUBLIC. `GET /api/sounds/packs`
//    and `GET /api/sounds/packs/<slug>` answer 200 with no credential at all,
//    and the pack detail carries `bpm`, `musicalKey`, `kind`, `tags` and
//    `durationSeconds` for every asset in the pack. Nothing had to be invented
//    server-side and nothing had to be deployed. The DAW simply had no client.
//
//  * The MASTERS are gated. `GET /api/sounds/assets/<id>/download` answers
//    401 without a bearer token — measured, not read off a comment. That gate
//    is the storefront's licensing, and this file does not go around it: the
//    token is the person's own, they paste it, and it is the ONLY thing here
//    that is ever secret. Nothing is embedded. See `StudioSoundsAccount`.
//
//  * PREVIEWS are public (200, `audio/mpeg`, Range-capable). They are 128 kbps
//    MP3 renders of the masters, which makes them right for auditioning a
//    thing you have not bought and WRONG as the thing you put in a song. This
//    file never downloads a preview as if it were an asset.
//
// THE FIELD THAT WAS MISSING, AND NOW IS NOT.
//
// This file used to end on a limitation, and the limitation was real: the
// public payload stripped `file_path`, so the server's own name for a file was
// not obtainable, and `StudioSoundsIndexExporter.refresh` could only describe
// files laid out the way the DOWNLOADER lays them out. Anything rsync'd,
// unzipped or dragged in carried the SERVER's filenames and could not be
// mapped back to a catalogue row. Every one of those loops kept reading "tempo
// unknown".
//
// The refusal to work around it was correct and is preserved below. The only
// other identity in the payload is `title`, and `title` REPEATS: measured
// across 250 packs / 4,758 assets of the live catalogue, **82.7% of assets sit
// in a within-pack title collision** — two loops in one pack are both
// "…drums loop", differing only in that one is 2 bars and the other 4. A
// title match would have attached one loop's tempo to a DIFFERENT loop, at
// scale. `TestFixtures/sounds-pack-detail.recorded.json` carries both of those
// real rows so the ambiguity is a fixture and not a claim.
//
// The server now emits `fileName` — the BASENAME only, never the path, so the
// storage layout is still withheld. `filePath` is still absent from every
// public payload (verified against the live service, and asserted by
// `testTheRecordedResponseStillWithholdsTheStoragePath`). That one field is
// what makes an exact join possible, so this file now does the join.
//
// WHAT WAS MEASURED BEFORE ANY OF IT WAS DESIGNED, against the live public API,
// unauthenticated, 250 of 739 packs sampled (33.8%), 4,758 assets:
//
//  * assets with no `fileName`:                            0  (0.00%)
//  * WITHIN-PACK basename collisions under the shipped fold: 0  (0.0000%)
//    — the fold being `lowercase(basename minus extension)`, with the `sku`
//    carried as a second key so a DOWNLOADED file (named `<sku>.wav`) and a
//    HAND-PLACED file (named `<fileName>`) both match through one code path.
//  * CROSS-pack basename reuse: 3 distinct basenames, `stem_drums.wav`,
//    `stem_bass.wav`, `stem_other.wav` — one of each per pack, 15.7% of
//    assets. Their `bpm` and `musicalKey` are null in every case, so nothing
//    could have been mis-attached even by a global match.
//
// Cross-pack reuse is IRRELEVANT BY CONSTRUCTION anyway, and that is the load-
// bearing design decision here: matching is scoped to ONE PACK, keyed on the
// folder the file sits in. `sounds/lo-fi-…-2f3f/stem_drums.wav` is only ever
// matched against the assets of pack `lo-fi-…-2f3f`. There is no global
// basename table and there is nowhere for one pack's `stem_drums.wav` to reach
// another's.
//
// AND THE COLLISION THAT IS STILL REFUSED. 0% today is not 0% forever, and a
// measurement is not a guarantee — the catalogue is somebody's live storefront
// and can publish two assets with one basename tomorrow. So when a pack's own
// rows claim one folded basename TWICE, the matcher writes NO entry for that
// file, counts it as REFUSED, and the browser keeps saying "tempo unknown".
// It does not pick the first row, or the lowest `idx`, or the one whose tempo
// looks more plausible. `testTwoCatalogueRowsClaimingOneBasenameAreRefused`
// is the guard. Silence beats a confident wrong number — the same judgement
// that (correctly) refused the title heuristic.
//
// THE DOWNLOADER IS UNCHANGED and still needs no matching at all: it names the
// file it writes, so it knows the key without a join. `StudioSoundsLayout` is
// still the single place that decides that layout.

// MARK: - Where the catalogue is

/// The storefront's HTTP surface, as URLs.
///
/// Host is a constant rather than a preference: this is where the Majiks
/// catalogue is, and a settable base URL on a client that sends a bearer token
/// is a way to post somebody's credential to an attacker's host. The one seam
/// that exists is for tests, which pass a `base` that no UI can reach.
enum StudioSoundsEndpoint {
    /// The storefront `StudioSoundsVaultLocation.storefront` already names in
    /// the empty state, so a person reads the same host in both places.
    static let base = URL(string: "https://\(StudioSoundsVaultLocation.storefront)")!

    /// The pack listing is the only enumerable surface. `limit` is CLAMPED
    /// SERVER-SIDE to 200 — asking for 1000 returns 200 and reports
    /// `"limit": 200`, so a client that trusted its own page size would walk
    /// off the end of the catalogue and call it complete. Measured against the
    /// live service; the clamp lives in the route AND again in the query
    /// builder, so it is not going to loosen by accident.
    static let maxPacksPerPage = 200

    static func packs(page: Int, limit: Int = maxPacksPerPage, base: URL = base) -> URL {
        var components = URLComponents(
            url: base.appendingPathComponent("api/sounds/packs"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "limit", value: String(min(maxPacksPerPage, max(1, limit)))),
        ]
        return components.url!
    }

    /// Pack detail resolves by SLUG, not by id — the route segment is named
    /// `[id]` and the handler calls `getSamplePackBySlug`. Passing the UUID
    /// answers 404 "Pack not found", which is a confusing way to learn this and
    /// is why it is written down here.
    static func pack(slug: String, base: URL = base) -> URL {
        base.appendingPathComponent("api/sounds/packs/\(slug)")
    }

    /// The master. Gated; see the file header.
    static func download(assetID: String, base: URL = base) -> URL {
        base.appendingPathComponent("api/sounds/assets/\(assetID)/download")
    }
}

// MARK: - Where a downloaded sound goes, decided once

/// The vault layout. ONE function, because the downloader and the index
/// exporter must agree byte for byte or the index describes files that are not
/// there.
///
/// `<pack-slug>/<sku>.<ext>`:
///
///  * the pack slug is the folder, which is what the scanner already reads as
///    `pack` and what the server's own storage uses;
///  * the sku is the file, because it is unique by constraint and because it is
///    what the download endpoint itself puts in `Content-Disposition`. A
///    prettier name would have to be invented, and two invented names collide.
///
/// The ugly filename is paid for in the index instead: the entry carries the
/// catalogue's `title`, so the browser shows "Riser Noise 4-Bar 120BPM" and
/// never the sku. That is the right trade — a name a machine chose, displayed
/// as the name a person wrote.
enum StudioSoundsLayout {
    static func relativePath(packSlug: String, sku: String, fileExtension: String = "wav") -> String {
        "\(packSlug)/\(sku).\(fileExtension)"
    }

    /// Where a file that failed verification goes.
    ///
    /// DOT-PREFIXED on purpose: `StudioVaultScanner` enumerates with
    /// `.skipsHiddenFiles`, so a quarantined file is unreachable from the
    /// browser BY CONSTRUCTION rather than by a filter somebody has to
    /// remember to write. A truncated WAV that plays as a click must never be
    /// one keystroke away from a song.
    static let quarantineFolder = ".majiks-quarantine"

    static func quarantineURL(root: URL, relativePath: String) -> URL {
        root.appendingPathComponent(quarantineFolder).appendingPathComponent(relativePath)
    }
}

// MARK: - What the catalogue says about a sound

/// One asset, as the storefront describes it. Every field here is SERVED, none
/// is derived, and `bpm`/`key` are `nil` when the catalogue's own column is
/// null — which for a one-shot is the correct and permanent answer.
struct StudioSoundsCatalogAsset: Sendable, Equatable, Codable {
    let id: String
    let sku: String
    let title: String
    let kind: StudioSoundKind
    let bpm: Double?
    let key: String?
    let durationSeconds: Double?
    /// The storefront's `access` object flattened. `free` means "free with a
    /// login" — the download endpoint auto-grants the entitlement — and NOT
    /// "free to anyone". `premium` costs credits and this client refuses it.
    let isFree: Bool

    /// The server's own BASENAME for the master — `stem_drums.wav`,
    /// `<slug>_melody_4bar_loop.wav`. Not the path: `filePath` is still
    /// stripped from every public payload, so the storage layout stays the
    /// server's business. This is the only field in the catalogue that
    /// identifies a file somebody already has on disk, and the whole of
    /// `StudioSoundsBasenameMatcher` rests on it.
    ///
    /// Optional because a payload without it must still decode — an older
    /// deployment, or a row whose column is null. A pack whose assets have no
    /// `fileName` simply matches nothing by basename; its files are REPORTED
    /// as unmatched rather than guessed at.
    let fileName: String?

    /// Defaulted so the many call sites that predate `fileName` keep compiling
    /// and keep meaning what they meant.
    init(
        id: String, sku: String, title: String, kind: StudioSoundKind,
        bpm: Double?, key: String?, durationSeconds: Double?, isFree: Bool,
        fileName: String? = nil
    ) {
        self.id = id
        self.sku = sku
        self.title = title
        self.kind = kind
        self.bpm = bpm
        self.key = key
        self.durationSeconds = durationSeconds
        self.isFree = isFree
        self.fileName = fileName
    }
}

/// One pack. `assets` is empty from the listing endpoint and filled by the
/// detail endpoint; the two are different shapes on the wire and are the same
/// shape here.
struct StudioSoundsCatalogPack: Sendable, Equatable, Codable {
    let id: String
    let slug: String
    let title: String
    let assetCount: Int
    let isFree: Bool
    var assets: [StudioSoundsCatalogAsset]

    init(id: String, slug: String, title: String, assetCount: Int,
         isFree: Bool, assets: [StudioSoundsCatalogAsset] = []) {
        self.id = id
        self.slug = slug
        self.title = title
        self.assetCount = assetCount
        self.isFree = isFree
        self.assets = assets
    }
}

// MARK: - Decoding, written against the shapes the live service actually sends

/// The wire format, kept in one place and kept PRIVATE, so the rest of the app
/// never learns that `access` is an object or that `musicalKey` is spelled with
/// a Y.
///
/// Unknown `kind` values decode to `.unknown` rather than throwing. The
/// storefront's enum already carries `midi` and `fx_preset`, neither of which
/// this app can place on a track; a client that threw on them would break the
/// day somebody publishes one.
enum StudioSoundsCatalogDecoder {

    private struct AccessWire: Decodable { let type: String }

    private struct AssetWire: Decodable {
        let id: String
        let sku: String
        let title: String?
        let kind: String?
        let bpm: Double?
        let musicalKey: String?
        let durationSeconds: Double?
        let access: AccessWire?
        /// Basename only. See `StudioSoundsCatalogAsset.fileName`.
        let fileName: String?
    }

    private struct PackWire: Decodable {
        let id: String
        let slug: String
        let title: String?
        let assetCount: Int?
        let access: AccessWire?
    }

    private struct PacksEnvelope: Decodable {
        struct Body: Decodable { let packs: [PackWire]; let page: Int?; let limit: Int? }
        let data: Body
    }

    private struct PackDetailEnvelope: Decodable {
        struct Body: Decodable { let pack: PackWire; let assets: [AssetWire] }
        let data: Body
    }

    private static func asset(_ wire: AssetWire) -> StudioSoundsCatalogAsset {
        StudioSoundsCatalogAsset(
            id: wire.id,
            sku: wire.sku,
            // A sku is a fine key and a poor label. Falling back to it is
            // better than an empty row, and the pack detail has always sent a
            // title on every asset measured.
            title: (wire.title?.isEmpty == false ? wire.title! : wire.sku),
            kind: wire.kind.flatMap(StudioSoundKind.init(rawValue:)) ?? .unknown,
            bpm: wire.bpm,
            key: wire.musicalKey,
            durationSeconds: wire.durationSeconds,
            isFree: wire.access?.type == "free",
            // Straight through, EMPTY NORMALISED TO NIL. An empty string would
            // fold to an empty key that every extension-less file on disk also
            // folds to, which is a collision manufactured out of a null column.
            fileName: wire.fileName.flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func pack(_ wire: PackWire, assets: [StudioSoundsCatalogAsset]) -> StudioSoundsCatalogPack {
        StudioSoundsCatalogPack(
            id: wire.id, slug: wire.slug,
            title: (wire.title?.isEmpty == false ? wire.title! : wire.slug),
            assetCount: wire.assetCount ?? assets.count,
            isFree: wire.access?.type == "free",
            assets: assets)
    }

    static func packs(from data: Data) throws -> [StudioSoundsCatalogPack] {
        try JSONDecoder().decode(PacksEnvelope.self, from: data)
            .data.packs.map { pack($0, assets: []) }
    }

    static func packDetail(from data: Data) throws -> StudioSoundsCatalogPack {
        let body = try JSONDecoder().decode(PackDetailEnvelope.self, from: data).data
        return pack(body.pack, assets: body.assets.map(asset))
    }
}

// MARK: - The transport seam

/// Everything this file does over the network goes through here, so every test
/// below runs with no network, no host and no credential — and so the ONE real
/// implementation is small enough to read.
protocol StudioSoundsTransport: Sendable {
    /// A whole body. JSON only; never used for audio.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// A body in pieces, so progress on a 40 MB pack is real rather than a
    /// spinner that jumps from 0 to 100. Audio only.
    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse)
}

/// The real one.
struct StudioSoundsURLSessionTransport: StudioSoundsTransport {
    /// Not `.shared`: a 30 MB pack behind a default 60-second resource timeout
    /// fails on a hotel connection, and the shared session's cache would keep
    /// a copy of every WAV in `~/Library/Caches`, doubling the disk cost of a
    /// library that is already the biggest thing on the machine.
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StudioSoundsError.badResponse("not an HTTP response")
        }
        return (data, http)
    }

    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StudioSoundsError.badResponse("not an HTTP response")
        }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    // 64 KiB, because yielding per byte across a 2 MB file is
                    // two million continuation resumptions and the progress
                    // bar cannot show more than a screenful of pixels anyway.
                    var chunk = Data(); chunk.reserveCapacity(65_536)
                    for try await byte in bytes {
                        chunk.append(byte)
                        if chunk.count >= 65_536 { continuation.yield(chunk); chunk.removeAll(keepingCapacity: true) }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, http)
    }
}

// MARK: - What can go wrong, said in words a person can act on

enum StudioSoundsError: Error, Equatable, LocalizedError {
    case badResponse(String)
    /// 401. The person has no key, or the key was revoked.
    case notSignedIn
    /// 403 / a premium asset. This client will not try to route around it.
    case notEntitled(String)
    case http(Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .badResponse(let why): return "The sounds service sent something unexpected (\(why))."
        case .notSignedIn:
            return "Add your \(StudioSoundsVaultLocation.storefront) key before downloading sounds."
        case .notEntitled(let name): return "\(name) is not included with your account."
        case .http(let code): return "The sounds service answered \(code)."
        case .cancelled: return "Download stopped."
        }
    }
}

// MARK: - The catalogue client

/// Reads the public half of the catalogue. **Sends no credential.** Listing
/// packs and reading their tempos is not a licensed act and does not need one;
/// keeping the token out of this half means the metadata refresh that makes the
/// browser useful works for somebody who has never signed in.
struct StudioSoundsCatalogClient: Sendable {
    let transport: any StudioSoundsTransport
    let base: URL

    init(transport: any StudioSoundsTransport = StudioSoundsURLSessionTransport(),
         base: URL = StudioSoundsEndpoint.base) {
        self.transport = transport
        self.base = base
    }

    /// `nonisolated`, so a call from the main actor hops off it. Every method
    /// here is `async` and none may be reached from a view body.
    nonisolated func packs(page: Int) async throws -> [StudioSoundsCatalogPack] {
        let (data, response) = try await transport.data(
            for: URLRequest(url: StudioSoundsEndpoint.packs(page: page, base: base)))
        try Self.check(response)
        return try StudioSoundsCatalogDecoder.packs(from: data)
    }

    nonisolated func pack(slug: String) async throws -> StudioSoundsCatalogPack {
        let (data, response) = try await transport.data(
            for: URLRequest(url: StudioSoundsEndpoint.pack(slug: slug, base: base)))
        try Self.check(response)
        return try StudioSoundsCatalogDecoder.packDetail(from: data)
    }

    /// Every pack, by walking pages until one comes back short.
    ///
    /// The listing returns no total and no page count, so "short page" is the
    /// only end-of-list signal there is. `pageLimit` is a hang guard, not a
    /// product limit: 739 packs at 200 a page is four requests, and a client
    /// that loops forever against a service that starts repeating itself is a
    /// worse failure than one that stops and says how far it got.
    nonisolated func allPacks(pageLimit: Int = 40) async throws -> [StudioSoundsCatalogPack] {
        var out: [StudioSoundsCatalogPack] = []
        var seen = Set<String>()
        for page in 1...max(1, pageLimit) {
            let batch = try await packs(page: page)
            for pack in batch where seen.insert(pack.id).inserted { out.append(pack) }
            if batch.count < StudioSoundsEndpoint.maxPacksPerPage { break }
            try Task.checkCancellation()
        }
        return out
    }

    static func check(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401: throw StudioSoundsError.notSignedIn
        case 403: throw StudioSoundsError.notEntitled("That sound")
        default: throw StudioSoundsError.http(response.statusCode)
        }
    }
}

// MARK: - The key, and the only secret in this feature

/// The person's own storefront key (`mk_…`), or a Keycloak access token.
///
/// Wrapped in `StudioKeychainItem` rather than read directly, for the reason
/// that type's header spells out at length: `SecItemCopyMatching` is a blocking
/// XPC round trip to securityd, and reading one from a place that LOOKS like a
/// field access is what pegged the main thread for eight hours. `hasKey` is
/// cheap after the first read and is the only accessor a view may touch;
/// `key()` is a function because a cold read pays.
enum StudioSoundsAccount {
    static let item = StudioKeychainItem(
        service: "studio.majiks.sounds", account: "api-key")

    /// Safe from a view body. One securityd round trip in the life of the
    /// process, asserted by `StudioSoundsDownloaderTests`.
    static var hasKey: Bool { item.hasValue }

    /// The token itself. Read ONCE per download run, off the main thread.
    static func key() -> String? { item.value() }

    static func setKey(_ value: String) { item.set(value) }
    static func clear() { item.delete() }

    /// The header the storefront's `requireAuth` accepts. There is no
    /// `X-API-Key` form — bearer or nothing.
    static func authorize(_ request: inout URLRequest, with token: String) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
}

// MARK: - Matching a file on disk to a catalogue row

/// The join, and the only place in this app that decides a file on disk IS a
/// particular catalogue asset.
///
/// SCOPED TO ONE PACK, always. The caller hands it the assets of exactly the
/// pack whose folder the file sits in, so there is no global basename table and
/// no route by which one pack's `stem_drums.wav` can lend its metadata to
/// another's. That is why the 15.7% cross-pack basename reuse measured in the
/// file header is not a hazard here: it is unreachable, not merely unlikely.
enum StudioSoundsBasenameMatcher {

    /// The fold. `Drums_2Bar_Loop.WAV` → `drums_2bar_loop`.
    ///
    /// Lower-cased because macOS filesystems are case-INSENSITIVE and
    /// case-preserving, so `Kick.wav` and `kick.wav` cannot both exist in one
    /// folder and treating them as different keys would strand one of them.
    /// Extension dropped so a person who converted the pack to AIFF still
    /// matches — that widens the match to files of the same NAME, never to a
    /// different sound, and it is safe here because it is what was measured
    /// (0 collisions in 4,758 assets).
    ///
    /// Deliberately NOT `StudioSoundsSearch.normalize`. That flattens every
    /// separator to a space and would fold `drums_2bar` and `drums-2bar` and
    /// `drums 2bar` together — a wider net, more collisions, and no benefit,
    /// because a filename is copied verbatim by every tool that moves it.
    static func fold(_ basename: String) -> String {
        (basename as NSString).deletingPathExtension.lowercased()
    }

    /// A pack's rows, indexed by every key a file on disk might carry.
    struct Lookup: Sendable {
        /// Folded key → the one asset that claims it.
        let unique: [String: StudioSoundsCatalogAsset]
        /// Folded keys claimed by MORE THAN ONE asset. A file whose name folds
        /// into this set is refused, not guessed at. Empty for every pack of
        /// the 250 sampled; not assumed empty.
        let ambiguous: Set<String>

        /// nil for "nothing claims this name" AND for "two rows claim it".
        /// The caller tells the two apart by asking `ambiguous`, because they
        /// are different things to report to a person: one is a file the
        /// catalogue has never heard of, the other is a file the catalogue
        /// describes twice and inconsistently.
        func asset(forFoldedBasename key: String) -> StudioSoundsCatalogAsset? {
            ambiguous.contains(key) ? nil : unique[key]
        }
    }

    /// Build the lookup for one pack.
    ///
    /// TWO keys per asset, both folded:
    ///
    ///  * its `fileName` — what a file rsync'd or unzipped from the server is
    ///    called;
    ///  * its `sku` — what `StudioSoundsLayout` names a file the DOWNLOADER
    ///    wrote.
    ///
    /// One code path for both, so a vault holding some downloaded packs and
    /// some hand-placed ones indexes in a single pass, and so the downloaded
    /// half cannot silently stop working when the hand-placed half changes.
    ///
    /// A key claimed by two DIFFERENT assets goes to `ambiguous` whichever kind
    /// of key it was. Two rows agreeing on tempo does not make it safe: they
    /// are still two different sounds and the index is keyed by path, so one
    /// of them would be described by the other's title and kind.
    static func lookup(for pack: StudioSoundsCatalogPack) -> Lookup {
        var claims: [String: String] = [:]      // folded key → asset id
        var unique: [String: StudioSoundsCatalogAsset] = [:]
        var ambiguous: Set<String> = []

        func claim(_ raw: String, by asset: StudioSoundsCatalogAsset) {
            let key = fold(raw)
            guard !key.isEmpty else { return }
            if let already = claims[key], already != asset.id {
                ambiguous.insert(key)
                unique.removeValue(forKey: key)
                return
            }
            if ambiguous.contains(key) { return }
            claims[key] = asset.id
            unique[key] = asset
        }

        for asset in pack.assets {
            if let fileName = asset.fileName { claim(fileName, by: asset) }
            claim(asset.sku, by: asset)
        }
        return Lookup(unique: unique, ambiguous: ambiguous)
    }
}

// MARK: - Saying what was matched and what was not

/// What one index refresh actually did, file by file.
///
/// This type exists because the alternative shipped once already elsewhere in
/// this repo: an action that reports only its successes, so a person pointing
/// it at 500 files and getting 412 tempos has no way to learn that the other 88
/// were never in the catalogue. Silence about a miss reads as "there was no
/// miss". Every present file lands in exactly one of the three buckets below
/// and `matched + unmatched.count + refused.count == filesConsidered` is
/// asserted, so a bucket cannot be quietly dropped.
struct StudioSoundsIndexReport: Sendable, Equatable {
    /// How many present files got a catalogue row.
    var matched: Int = 0
    /// Present files no catalogue row claims — a sound somebody made
    /// themselves, a pack from another vendor, or a folder whose name is not
    /// the pack slug. Sorted, so the report is stable.
    var unmatched: [String] = []
    /// Present files REFUSED because two catalogue rows claim the basename.
    /// Never guessed at. See the file header.
    var refused: [String] = []
    /// Pack details actually fetched.
    var packsConsulted: Int = 0
    /// Folders the catalogue has no pack for. The commonest real cause of a
    /// large `unmatched`, and the one a person can act on by renaming.
    var foldersNotInCatalogue: [String] = []

    var filesConsidered: Int { matched + unmatched.count + refused.count }

    /// The line a person reads. Never rounds a partial result up to done —
    /// same rule as `StudioSoundsPackOutcome.summary`.
    var summary: String {
        let total = filesConsidered
        guard total > 0 else { return "No sounds to look up." }
        if matched == 0 {
            var line = "The catalogue knows nothing about "
                + (total == 1 ? "that sound." : "those \(total) sounds.")
            if !foldersNotInCatalogue.isEmpty {
                line += " " + folderNote
            }
            return line
        }
        var line = "\(matched) of \(total) sound\(total == 1 ? "" : "s") matched"
        if !unmatched.isEmpty {
            line += ", \(unmatched.count) not in the catalogue"
        }
        if !refused.isEmpty {
            line += ", \(refused.count) skipped because the catalogue names "
                + (refused.count == 1 ? "it" : "them") + " twice"
        }
        line += "."
        if !foldersNotInCatalogue.isEmpty { line += " " + folderNote }
        return line
    }

    /// Named separately so the "which folder" hint is one string in one place.
    private var folderNote: String {
        let names = foldersNotInCatalogue.sorted()
        let shown = names.prefix(2).joined(separator: ", ")
        let more = names.count > 2 ? " and \(names.count - 2) more" : ""
        return "No pack called \(shown)\(more) on \(StudioSoundsVaultLocation.storefront)."
    }
}

// MARK: - The exporter: turning catalogue metadata into the sidecar index
//
// The highest-value lines in this file. `bpm` and `musical_key` are already in
// Postgres and already public; nothing here measures anything, detects
// anything or guesses anything. It is a serialisation, and the value of it is
// that fourteen thousand files stop reading "tempo unknown".

/// Writes `majiks-sounds-index.json` beside a vault.
enum StudioSoundsIndexExporter {

    /// Build entries for one pack's assets, keyed exactly as
    /// `StudioSoundsLayout` writes them.
    ///
    /// `only` is the set of relative paths that actually landed and VERIFIED.
    /// An asset that failed verification and went to quarantine gets no entry,
    /// because an index that describes a file which is not there is how a
    /// browser ends up showing a tempo for a sound nobody can play.
    static func entries(
        for pack: StudioSoundsCatalogPack,
        limitedTo only: Set<String>? = nil
    ) -> [String: StudioSoundsIndex.Entry] {
        var out: [String: StudioSoundsIndex.Entry] = [:]
        for asset in pack.assets {
            let relative = StudioSoundsLayout.relativePath(packSlug: pack.slug, sku: asset.sku)
            if let only, !only.contains(relative) { continue }
            out[relative] = StudioSoundsIndex.Entry(
                kind: asset.kind.rawValue,
                // Straight through. A null column stays nil and the browser
                // says "tempo unknown" — it does NOT become 120 because 120 is
                // a plausible number.
                bpm: asset.bpm,
                key: asset.key,
                pack: pack.title,
                title: asset.title)
        }
        return out
    }

    /// Merge new entries into whatever index is already beside the vault and
    /// write the result.
    ///
    /// MERGE, not replace. A person downloads one pack at a time; an exporter
    /// that wrote only the newest pack would silently strip the tempo off
    /// everything they already had, which is the same defect as a downloader
    /// that reports success on a failure — a green action that destroys data.
    /// `testExportingASecondPackKeepsTheFirstPacksTempos` is the guard.
    @discardableResult
    static func merge(
        _ entries: [String: StudioSoundsIndex.Entry],
        intoVaultAt root: URL,
        now: Date = Date()
    ) throws -> StudioSoundsIndex {
        var index = StudioSoundsIndex.read(at: root)
            ?? StudioSoundsIndex(version: StudioSoundsIndex.currentVersion, generated: nil, entries: [:])
        for (key, value) in entries { index.entries[key] = value }
        index.version = StudioSoundsIndex.currentVersion
        index.generated = ISO8601DateFormatter().string(from: now)
        try write(index, toVaultAt: root)
        return index
    }

    static func write(_ index: StudioSoundsIndex, toVaultAt root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(index)
        // Atomic: a half-written index is a file the reader silently ignores
        // (it fails to decode), which would present as "my tempos vanished".
        try data.write(to: root.appendingPathComponent(StudioSoundsIndex.fileName), options: .atomic)
    }

    /// Build entries for the files that are ACTUALLY ON DISK in one pack's
    /// folder, by matching each basename against the pack's catalogue rows.
    ///
    /// This is the last mile. `entries(for:limitedTo:)` above can only describe
    /// files the DOWNLOADER wrote, because it derives the path from the sku
    /// rather than reading it off the disk. This one goes the other way: it
    /// starts from the paths a scan found and asks the catalogue about each,
    /// so a folder somebody rsync'd or unzipped is describable for the first
    /// time.
    ///
    /// The entry is keyed by the file's REAL relative path, extension and all,
    /// because that is the key `StudioVaultScanner` looks the index up by. Not
    /// by the sku, and not by the catalogue's `fileName` — either of those
    /// would produce an index that describes a path which is not on the disk,
    /// which is exactly the "browser shows a tempo for a sound nobody can
    /// play" failure `entries(for:limitedTo:)` already guards against.
    ///
    /// Pure and synchronous, so the whole matching decision is testable with
    /// no network, no disk and no clock.
    static func entriesByBasename(
        for pack: StudioSoundsCatalogPack,
        presentRelativePaths: [String],
        into report: inout StudioSoundsIndexReport
    ) -> [String: StudioSoundsIndex.Entry] {
        let lookup = StudioSoundsBasenameMatcher.lookup(for: pack)
        var out: [String: StudioSoundsIndex.Entry] = [:]
        for path in presentRelativePaths {
            let basename = (path as NSString).lastPathComponent
            let key = StudioSoundsBasenameMatcher.fold(basename)
            if lookup.ambiguous.contains(key) {
                // TWO catalogue rows claim this name. Refused — see the file
                // header. The file keeps reading "tempo unknown", which is
                // true, rather than gaining one of two tempos at random.
                report.refused.append(path)
                continue
            }
            guard let asset = lookup.asset(forFoldedBasename: key) else {
                report.unmatched.append(path)
                continue
            }
            report.matched += 1
            out[path] = StudioSoundsIndex.Entry(
                kind: asset.kind.rawValue,
                // Straight through, exactly as `entries(for:limitedTo:)` does
                // it. A null column stays nil and the browser says "tempo
                // unknown"; it does NOT become 120 because 120 is a plausible
                // number.
                bpm: asset.bpm,
                key: asset.key,
                pack: pack.title,
                title: asset.title)
        }
        return out
    }

    /// Refresh the index for a vault that already has audio in it, from the
    /// public catalogue and with no credential.
    ///
    /// This is the path that is worth shipping ON ITS OWN. Somebody with a
    /// folder of packs put there by hand runs this and every loop in it gains
    /// a tempo. It only ever describes files that ARE present, which is why it
    /// takes the scan result rather than trusting the catalogue.
    ///
    /// `nonisolated async`: off the main actor, and `ranOnMainThread` comes
    /// back as data for the same reason the scanner's does.
    struct RefreshResult: Sendable {
        let packsConsulted: Int
        let entriesWritten: Int
        let ranOnMainThread: Bool
        /// What was matched, what was not, and what was refused. The half of
        /// this result that stops a partial run reading as a complete one.
        let report: StudioSoundsIndexReport
    }

    nonisolated static func refresh(
        vaultAt root: URL,
        presentRelativePaths: Set<String>,
        client: StudioSoundsCatalogClient,
        now: Date = Date()
    ) async throws -> RefreshResult {
        var onMain = StudioVaultScanner.isOnMainThread()

        // Group the present files by the folder they sit in, which IS the pack
        // slug for anything that came off this catalogue. Only the packs we
        // actually hold get fetched: pulling all 739 details to describe the
        // two somebody downloaded is 737 pointless round trips.
        var byFolder: [String: [String]] = [:]
        var looseFiles: [String] = []
        for path in presentRelativePaths {
            let parts = path.split(separator: "/")
            if parts.count >= 2 { byFolder[String(parts[0]), default: []].append(path) }
            // A file sitting loose at the vault root belongs to no pack, so
            // there is nothing to ask the catalogue about. It is UNMATCHED,
            // not invisible — dropping it here is how a report starts lying
            // about how many files it looked at.
            else { looseFiles.append(path) }
        }

        var report = StudioSoundsIndexReport()
        report.unmatched.append(contentsOf: looseFiles)

        var merged: [String: StudioSoundsIndex.Entry] = [:]
        for (folder, paths) in byFolder.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            if StudioVaultScanner.isOnMainThread() { onMain = true }
            guard let pack = try? await client.pack(slug: folder) else {
                // No such pack. Every file under it is unmatched, and the
                // folder is named so the person can see WHY rather than
                // reading a bare "88 not in the catalogue".
                report.foldersNotInCatalogue.append(folder)
                report.unmatched.append(contentsOf: paths)
                continue
            }
            report.packsConsulted += 1
            for (key, value) in entriesByBasename(
                for: pack, presentRelativePaths: paths.sorted(), into: &report
            ) {
                merged[key] = value
            }
        }

        report.unmatched.sort()
        report.refused.sort()
        report.foldersNotInCatalogue.sort()

        if !merged.isEmpty { try merge(merged, intoVaultAt: root, now: now) }
        return RefreshResult(
            packsConsulted: report.packsConsulted, entriesWritten: merged.count,
            ranOnMainThread: onMain, report: report)
    }
}
