import Foundation

// MARK: - The sounds vault: what it is, where it is, and what it does not know
//
// WHY THIS EXISTS.
//
// There are 13,971 assets in the Majiks sounds catalogue — 5,943 one-shots
// (5,888 of them drums), 5,814 loops, 2,214 stems — and until this file the
// Studio could not reach one of them. The only way to get a sound into a
// project was `NSOpenPanel` or a Finder drop, which is a fine gesture for the
// file you already know the name of and a useless one for a library of
// fourteen thousand. `StudioInstrumentView` predicted this file in a comment:
// "a vault browser can be added later without touching anything here — a
// remote asset downloaded to a cache is just another path." That is exactly
// what this is.
//
// WHERE THE VAULT ACTUALLY LIVES, established rather than assumed.
//
// The catalogue is REMOTE. The masters sit on the majiks.online server under
// `/opt/majiks/data/majiks-online/audio/sounds/<pack>/`, the storefront is
// sounds.majiks.studio, and the authoritative index is a Postgres table
// (`sample_assets`) — not a file, not a bundle, and not anything this app can
// read. NOTHING of the vault ships inside Majiks Music Studio and nothing of
// it is on the machine this comment was written on.
//
// So a vault browser inside a desktop DAW can only be a browser of the assets
// a person HAS — the ones they downloaded. That is the honest model and it is
// also the right one: the engine only ever wants a local path (it decodes,
// content-addresses and stores the bytes itself), and a person auditioning a
// kick at couch distance should not be waiting on a network round trip.
//
// Hence: a VAULT ROOT, a folder on disk. Configurable, defaulted, and when it
// is empty the browser SAYS SO and says where the sounds come from, rather
// than showing an empty list that reads like a broken feature. (This codebase
// has shipped a Publish button that made no network call and an audition that
// changed no audio; an empty list with no explanation is the same genre.)
//
// WHAT THE FILESYSTEM CANNOT TELL US, AND THE FIELD FOR IT.
//
// A DAW needs two things about a loop that a directory listing does not carry:
// TEMPO and MUSICAL KEY. You cannot line a 128 BPM loop up against a 110 BPM
// project by eye, and a bassline in F minor over a track in A major is not a
// judgement call. `Track` has carried `bpm` and `key` for a long time; a
// sample had nowhere to put them.
//
// The field is `StudioSoundsIndex` — a sidecar JSON beside the audio, keyed by
// vault-relative path. It is the local shadow of the `bpm` / `musical_key`
// columns the catalogue already keeps server-side, so the values are OBTAINED
// (exported next to the download), never computed here and never guessed.
//
// WHERE THE INDEX COMES FROM, now that it comes from somewhere. This comment
// used to end "no such export exists", and twice over it no longer does:
//
//  * `StudioSoundsDownloader` writes an entry beside every master it lands,
//    keyed on the path it just wrote, so there is no matching to get wrong;
//  * `StudioSoundsIndexExporter.refresh` describes files that were ALREADY on
//    disk — rsync'd, unzipped, dragged in — by matching each basename against
//    the public catalogue. No credential: listing what a pack contains and how
//    fast it runs is not a licensed act.
//
// Both write the same file and neither invents a value. What is still true is
// the rule underneath: an asset the catalogue has no row for keeps `bpm ==
// nil`, `key == nil` and `metadata == .absent`, and the browser says "tempo
// unknown" rather than showing a number nobody measured. The refresh COUNTS
// those files and says how many there were, because a lookup that reports only
// its hits is a lookup a person cannot tell apart from a complete one. The
// one exception to "obtained, never derived" is the narrow, explicit filename
// form below, which is a READING and is labelled as one.

// MARK: - What kind of thing a sound is

/// The vault's own `kind` vocabulary (`one_shot | loop | stem`), which is what
/// the catalogue is actually indexed by. `unknown` is for a file found by a
/// scan that no index describes — most of them, today.
///
/// Deliberately NOT a general "instrument" taxonomy. The vault ships no
/// melodic instrument samples at all, so a Piano / Strings / Brass filter
/// would be four categories that are permanently empty — the exact shape of
/// the four guaranteed-empty nav cards the storefront already has.
enum StudioSoundKind: String, CaseIterable, Codable, Sendable {
    case oneShot = "one_shot"
    case loop
    case stem
    case unknown

    /// What a person who has never used a DAW should see.
    var label: String {
        switch self {
        case .oneShot: return "One-shots"
        case .loop: return "Loops"
        case .stem: return "Stems"
        case .unknown: return "Other"
        }
    }

    /// Singular, for a row's meta line.
    var rowLabel: String {
        switch self {
        case .oneShot: return "one-shot"
        case .loop: return "loop"
        case .stem: return "stem"
        case .unknown: return "sound"
        }
    }

    /// A one-shot is TEMPO-FREE by nature: a kick is a kick at any tempo. That
    /// is not the same as "tempo unknown", and conflating the two is what makes
    /// a tempo filter either hide every drum hit or admit every mystery loop.
    var isTempoFree: Bool { self == .oneShot }
}

/// Where a sound's tempo and key came from. Carried on the asset so the UI can
/// tell a MEASURED value from a READ one and never present a guess as fact.
enum StudioSoundMetadataSource: String, Codable, Sendable {
    /// From the sidecar index — the catalogue's own value, exported with the
    /// download. Authoritative.
    case index
    /// Parsed out of the file name, and only from an unambiguous form
    /// ("…128bpm…", "…_Fmin_…"). A reading of what somebody wrote down, not a
    /// measurement, and shown with a "from the name" qualifier.
    case filename
    /// Nothing knows. The browser says so instead of showing a number.
    case absent
}

// MARK: - One sound

/// One audio file in the vault, with everything the browser needs to find it,
/// sort it, say something true about it, and hand its path to the engine.
///
/// `Sendable` because it is built off the main actor by the scanner and
/// published onto it. `id` is the vault-RELATIVE path: stable across scans
/// (a fresh UUID per scan would make every row a new identity and defeat
/// `ForEach` diffing on a 14,000-row list), unique by construction, and
/// exactly the key the sidecar index is keyed by.
struct StudioSoundAsset: Identifiable, Hashable, Sendable {
    let id: String
    /// The file name without its extension — what a person reads.
    let name: String
    /// Absolute path. The only thing the engine ever wants.
    let path: String
    /// The containing folder. The vault is organised in packs and a pack name
    /// is most of what tells one kick from another.
    let pack: String
    let kind: StudioSoundKind
    /// Beats per minute, or nil when nothing knows it.
    let bpm: Double?
    /// Musical key as the catalogue spells it ("F min", "A maj"), or nil.
    let key: String?
    let metadata: StudioSoundMetadataSource

    /// The meta line under the name. Says "tempo unknown" rather than nothing,
    /// because a blank space reads as "no tempo" (which is TRUE of a one-shot
    /// and FALSE of a loop nobody has measured).
    var metaLine: String {
        var parts: [String] = [kind.rowLabel]
        if let bpm {
            let rounded = bpm.rounded()
            let shown = abs(bpm - rounded) < 0.05
                ? String(Int(rounded)) : String(format: "%.1f", bpm)
            parts.append(metadata == .filename ? "\(shown) BPM?" : "\(shown) BPM")
        } else if !kind.isTempoFree {
            parts.append("tempo unknown")
        }
        if let key { parts.append(metadata == .filename ? "\(key)?" : key) }
        if !pack.isEmpty { parts.append(pack) }
        return parts.joined(separator: " · ")
    }

    /// Lower-cased, separator-flattened haystack, computed ONCE at scan time.
    ///
    /// Doing this per keystroke over 14,000 assets is 14,000 string
    /// lowercasings per character typed. Precomputing it is why search stays
    /// responsive at vault scale, and it is the reason this is stored rather
    /// than derived.
    let haystack: String

    init(
        id: String, name: String, path: String, pack: String,
        kind: StudioSoundKind, bpm: Double?, key: String?,
        metadata: StudioSoundMetadataSource
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.pack = pack
        self.kind = kind
        self.bpm = bpm
        self.key = key
        self.metadata = metadata
        self.haystack = StudioSoundsSearch.normalize("\(name) \(pack) \(kind.rowLabel) \(key ?? "")")
    }
}

// MARK: - The sidecar index: the designed home for tempo and key

/// The file that gives a folder of audio the two things a filesystem cannot
/// carry. Lives at the vault root as `majiks-sounds-index.json`.
///
/// Keyed by vault-relative path so it survives the folder being moved, and so
/// a partial index (the packs you have) describes a partial vault correctly.
/// Every field on an entry is OPTIONAL: a one-shot legitimately has no tempo,
/// and the catalogue itself stores null there. An absent key is not a defect
/// to be filled in with a plausible number.
struct StudioSoundsIndex: Codable, Sendable {
    static let fileName = "majiks-sounds-index.json"

    struct Entry: Codable, Sendable {
        var kind: String?
        var bpm: Double?
        var key: String?
        var pack: String?
        /// The catalogue's own name for the sound.
        ///
        /// Added when the downloader landed, because the downloader names files
        /// by SKU — the only stable identity the public API exposes, since
        /// `file_path` is stripped from every payload — and a row reading
        /// "uplifting-pop-let-it-fly-004e-011" is a browser that is technically
        /// working and practically useless. Optional like everything else here:
        /// a file placed by hand has no title and keeps showing its filename,
        /// which is the right answer for a file somebody named themselves.
        ///
        /// Additive, so it needs no version bump: every field on an entry is
        /// already optional, so a v1 file decodes into this shape unchanged and
        /// an older build ignores the extra key rather than rejecting the file.
        var title: String?
    }

    /// Bumped when the shape changes. A reader that does not recognise the
    /// version ignores the file rather than half-reading it.
    var version: Int
    /// When the export ran, for a person debugging a stale index.
    var generated: String?
    var entries: [String: Entry]

    static let currentVersion = 1

    /// Read the index beside a vault root, or nil when there is none — which
    /// is the normal case today and is not an error.
    static func read(at root: URL) -> StudioSoundsIndex? {
        let url = root.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(StudioSoundsIndex.self, from: data),
              decoded.version == currentVersion
        else { return nil }
        return decoded
    }
}

// MARK: - Reading tempo and key out of a file name

/// The narrow, explicit filename forms — and nothing wider.
///
/// This exists for the sample packs a person buys elsewhere (Splice and its
/// like DO write the tempo into the name) and NOT for the Majiks catalogue,
/// which does not. It is deliberately strict, because the alternative is
/// inventing values: "Snare_120.wav" is far more likely to be the 120th snare
/// than a 120 BPM one, so a bare number is REFUSED. Only a number bound to the
/// literal token "bpm" counts.
///
/// Anything read here is tagged `.filename` and rendered with a "?" so the
/// screen never claims more than it knows.
enum StudioSoundNameMetadata {
    /// "…128bpm…" / "…bpm128…" / "…128 BPM…". Nothing else.
    static func bpm(fromName name: String) -> Double? {
        let lower = name.lowercased()
        let scalars = Array(lower.unicodeScalars)
        let digits = CharacterSet.decimalDigits

        func plausible(_ value: Int) -> Double? {
            (40...300).contains(value) ? Double(value) : nil
        }

        // number immediately followed by "bpm" (allowing one space/underscore)
        var i = 0
        while i < scalars.count {
            guard digits.contains(scalars[i]) else { i += 1; continue }
            var j = i
            while j < scalars.count, digits.contains(scalars[j]) { j += 1 }
            var k = j
            while k < scalars.count, scalars[k] == " " || scalars[k] == "_" || scalars[k] == "-" { k += 1 }
            let tail = String(String.UnicodeScalarView(scalars[k...]))
            if tail.hasPrefix("bpm"),
               let value = Int(String(String.UnicodeScalarView(scalars[i..<j]))),
               let ok = plausible(value) { return ok }
            i = j
        }

        // "bpm" immediately followed by a number
        if let range = lower.range(of: "bpm") {
            var rest = Substring(lower[range.upperBound...])
            while let f = rest.first, f == " " || f == "_" || f == "-" { rest = rest.dropFirst() }
            let number = rest.prefix { $0.isNumber }
            if !number.isEmpty, let value = Int(number), let ok = plausible(value) { return ok }
        }
        return nil
    }

    /// "…_Fmin_…", "…-F#maj-…", "…_Gm_…". A note letter, an optional accidental,
    /// and an explicit quality — bounded by separators at both ends so "Fm" in
    /// "Fmt_kick" is not read as F minor.
    static func key(fromName name: String) -> String? {
        let separators = CharacterSet(charactersIn: " _-.")
        let tokens = name.components(separatedBy: separators).filter { !$0.isEmpty }
        for token in tokens {
            guard let parsed = parseKeyToken(token) else { continue }
            return parsed
        }
        return nil
    }

    private static func parseKeyToken(_ token: String) -> String? {
        var chars = Array(token)
        guard let first = chars.first, "ABCDEFGabcdefg".contains(first) else { return nil }
        var note = String(first).uppercased()
        chars.removeFirst()
        if let next = chars.first, next == "#" || next == "b" {
            // A lone trailing "b" is ambiguous ("Ab" the key vs "ab" a word);
            // require something after it, which every quality suffix gives us.
            if next == "#" || chars.count > 1 {
                note += (next == "#") ? "#" : "b"
                chars.removeFirst()
            }
        }
        let quality = String(chars).lowercased()
        switch quality {
        case "min", "minor", "m": return "\(note) min"
        case "maj", "major":      return "\(note) maj"
        default: return nil
        }
    }
}

// MARK: - Search and filtering (pure, and the reason search stays responsive)

/// What the browser is currently showing. A value type so a change is one
/// `@Published` write and the recompute below happens once, not once per view
/// body evaluation.
struct StudioSoundFilter: Equatable, Sendable {
    var query: String = ""
    /// nil = every kind.
    var kind: StudioSoundKind?
    /// When on, only sounds that will line up with the project's tempo.
    var inTempo: Bool = false
    /// When on, only sounds in the project's key.
    var inKey: Bool = false

    /// How far either side of the project tempo still counts as "will line up".
    /// ±6 BPM is roughly the range a listener forgives without time-stretching;
    /// the engine has no warp, so this is a HONEST filter rather than a promise
    /// that anything can be conformed.
    static let tempoTolerance: Double = 6

    var isActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || kind != nil || inTempo || inKey
    }
}

/// The predicate, factored out of the view so it is unit-testable and so it
/// can be MEASURED — `filterCallCount` below is how "the view does not filter
/// 14,000 assets inside its body" stops being a claim and becomes a test.
enum StudioSoundsSearch {

    /// Lower-cased with every separator flattened to a space.
    ///
    /// This is the fix for a bug the storefront still has: "hip hop" returns
    /// nothing while "hip-hop" returns thousands, because the query was matched
    /// as one substring against un-normalised text. Flatten both sides and
    /// require every TOKEN to appear, and both spellings find the same rows.
    static func normalize(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                out.append(character)
            } else if out.last != " " {
                out.append(" ")
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func tokens(_ query: String) -> [String] {
        normalize(query).split(separator: " ").map(String.init)
    }

    /// Does one asset survive the filter?
    ///
    /// The tempo rule is the one worth reading twice. A one-shot PASSES an
    /// in-tempo filter because it is tempo-free — hiding every kick when
    /// someone asks for "things that fit my track" is wrong. A loop with an
    /// UNKNOWN tempo FAILS, because admitting it would be the browser saying
    /// "this fits" about something nothing has measured. That asymmetry is the
    /// whole reason `isTempoFree` exists as a separate concept from `bpm == nil`.
    static func matches(
        _ asset: StudioSoundAsset,
        filter: StudioSoundFilter,
        projectBPM: Double,
        projectKey: String?
    ) -> Bool {
        if let kind = filter.kind, asset.kind != kind { return false }

        if filter.inTempo, !asset.kind.isTempoFree {
            guard let bpm = asset.bpm else { return false }
            guard abs(bpm - projectBPM) <= StudioSoundFilter.tempoTolerance else { return false }
        }

        if filter.inKey {
            guard let projectKey, !projectKey.isEmpty else { return false }
            guard let key = asset.key, keysAgree(key, projectKey) else { return false }
        }

        for token in tokens(filter.query) where !asset.haystack.contains(token) {
            return false
        }
        return true
    }

    /// "F min" and "Fmin" and "f minor" are the same key. Compared on the
    /// normalised spelling rather than by string equality, because the
    /// catalogue, a file name and a person all write it differently.
    static func keysAgree(_ a: String, _ b: String) -> Bool {
        normalize(a).replacingOccurrences(of: "minor", with: "min")
            .replacingOccurrences(of: "major", with: "maj")
            .replacingOccurrences(of: " ", with: "")
        == normalize(b).replacingOccurrences(of: "minor", with: "min")
            .replacingOccurrences(of: "major", with: "maj")
            .replacingOccurrences(of: " ", with: "")
    }

    #if DEBUG
    /// Instrumentation, DEBUG-only, so "filtering does not happen in a view
    /// body" is asserted rather than believed. This is the same class of bug as
    /// the synchronous keychain round-trip that ran ten times a second inside a
    /// view body and pegged the main thread; the only difference is that this
    /// one would be over fourteen thousand strings.
    nonisolated(unsafe) private(set) static var filterCallCount = 0
    static func resetFilterCallCount() { filterCallCount = 0 }
    #endif

    static func filter(
        _ assets: [StudioSoundAsset],
        filter f: StudioSoundFilter,
        projectBPM: Double,
        projectKey: String?
    ) -> [StudioSoundAsset] {
        #if DEBUG
        filterCallCount += 1
        #endif
        guard f.isActive else { return assets }
        return assets.filter {
            matches($0, filter: f, projectBPM: projectBPM, projectKey: projectKey)
        }
    }

    /// How many sounds an in-tempo filter is hiding *because nobody knows their
    /// tempo* — as opposed to because they are the wrong tempo.
    ///
    /// That number is the honest half of the empty state. "No sounds match" is
    /// a dead end; "no sounds match, and 812 loops were left out because their
    /// tempo is unknown" tells a person the vault is fine and the metadata is
    /// missing, which is the actual situation today.
    static func hiddenForUnknownTempo(
        _ assets: [StudioSoundAsset],
        filter f: StudioSoundFilter
    ) -> Int {
        guard f.inTempo else { return 0 }
        return assets.reduce(into: 0) { count, asset in
            if !asset.kind.isTempoFree, asset.bpm == nil { count += 1 }
        }
    }
}

// MARK: - Where the vault root is

/// Resolving the folder the browser scans.
///
/// Configurable because there is no one right answer: the sounds are downloaded
/// from sounds.majiks.studio and a person with a 14,000-file library keeps it
/// on the big disk, not in the home folder. Defaulted so the first run has an
/// answer without a settings trip.
enum StudioSoundsVaultLocation {
    /// The `UserDefaults` key. Namespaced like every other Studio preference.
    static let defaultsKey = "MajiksStudioSoundsVaultRoot"

    /// `~/Music/Majiks Sounds`. Not `~/Library/Application Support`: a sample
    /// library is a person's own media, they will want to see it in Finder, and
    /// Application Support is where an app hides things from its user.
    static var fallback: URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music")
        return music.appendingPathComponent("Majiks Sounds", isDirectory: true)
    }

    static func resolved(defaults: UserDefaults = .standard) -> URL {
        if let path = defaults.string(forKey: defaultsKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return fallback
    }

    static func set(_ url: URL?, defaults: UserDefaults = .standard) {
        if let url { defaults.set(url.path, forKey: defaultsKey) }
        else { defaults.removeObject(forKey: defaultsKey) }
    }

    /// Where the sounds come from, for the empty state. A person looking at an
    /// empty browser needs the next step, not an apology.
    static let storefront = "sounds.majiks.studio"
}

// MARK: - The scan: off the main thread, or it is the bug we already shipped

/// What one scan found, INCLUDING the evidence that it did not run on the main
/// thread.
///
/// `ranOnMainThread` is recorded inside the enumeration loop and returned as
/// data precisely so a test can assert on the artifact rather than on the
/// shape of the code. A `nonisolated async` function is *supposed* to hop off
/// the caller's actor; "supposed to" is how this repo shipped a meter driven by
/// `abs(sin(t))`.
struct StudioVaultScanResult: Sendable {
    let root: URL
    let assets: [StudioSoundAsset]
    /// How many of them the sidecar index described.
    let indexed: Int
    /// True when the root does not exist — a different empty state from "the
    /// folder is there and has nothing in it".
    let rootMissing: Bool
    /// Non-nil when the walk stopped at its ceiling, so the browser can say
    /// "showing the first N" instead of quietly lying about the library size.
    let truncatedAt: Int?
    /// Evidence, not decoration. See the type comment.
    let ranOnMainThread: Bool
    let duration: TimeInterval
}

/// Walks a vault root and turns it into assets.
///
/// EVERYTHING here is off the main actor and none of it may ever be called
/// from a view body. `FileManager.enumerator` over 14,000 files is tens of
/// thousands of `stat` calls; run inside a SwiftUI body that re-evaluates at
/// display rate, that is the same failure as the synchronous XPC round-trip to
/// `securityd` that made the whole app unresponsive — just with a slower
/// syscall.
enum StudioVaultScanner {

    /// Extensions the engine can decode. Checked on the extension rather than
    /// via `URLResourceValues.typeIdentifier`, which is a per-file metadata
    /// round trip — 14,000 of them is the cost this scan exists to avoid.
    static let audioExtensions: Set<String> = ["wav", "aiff", "aif", "aifc", "mp3", "m4a", "flac", "caf", "ogg"]

    /// A ceiling so a person who points this at their whole home folder gets a
    /// slow-but-finite result instead of a hang. Generous: the real vault is
    /// 13,971 and a person may hold more than one.
    static let defaultLimit = 60_000

    #if DEBUG
    /// Counts scans, so "no view body starts a filesystem walk" is a test.
    nonisolated(unsafe) private(set) static var scanCallCount = 0
    static func resetScanCallCount() { scanCallCount = 0 }
    #endif

    /// Am I on the main thread right now?
    ///
    /// `pthread_main_np()` rather than `Thread.isMainThread`, because Swift
    /// makes the latter *unavailable* from an asynchronous context — which is
    /// a fair rule for code deciding what to do, and useless for code whose
    /// entire job is to REPORT where it ran. This is the report, so it goes to
    /// the C call underneath.
    nonisolated static func isOnMainThread() -> Bool { pthread_main_np() != 0 }

    /// `nonisolated` + `async`: called from the main actor this hops OFF it
    /// (SE-0338), and the `ranOnMainThread` field in the result proves it did.
    nonisolated static func scan(
        root: URL,
        limit: Int = defaultLimit
    ) async -> StudioVaultScanResult {
        #if DEBUG
        scanCallCount += 1
        #endif
        let started = Date()
        var onMain = false

        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return StudioVaultScanResult(
                root: root, assets: [], indexed: 0, rootMissing: true,
                truncatedAt: nil, ranOnMainThread: StudioVaultScanner.isOnMainThread(),
                duration: Date().timeIntervalSince(started))
        }

        let index = StudioSoundsIndex.read(at: root)
        var assets: [StudioSoundAsset] = []
        assets.reserveCapacity(min(limit, 16_384))
        var indexed = 0
        var truncatedAt: Int?

        let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])

        let rootComponents = root.standardizedFileURL.pathComponents
        while let next = enumerator?.nextObject() as? URL {
            // Recorded per file rather than once: a future edit that moves only
            // PART of this loop onto the main actor still trips the assertion.
            if StudioVaultScanner.isOnMainThread() { onMain = true }

            guard audioExtensions.contains(next.pathExtension.lowercased()) else { continue }
            if assets.count >= limit {
                truncatedAt = limit
                break
            }

            let components = next.standardizedFileURL.pathComponents
            let relative = components.count > rootComponents.count
                ? components[rootComponents.count...].joined(separator: "/")
                : next.lastPathComponent
            let entry = index?.entries[relative]
            if entry != nil { indexed += 1 }

            // The index's own name wins over the file's, and the index's own
            // pack title wins over the folder name. Both exist because the
            // downloader writes SKU-named files inside SLUG-named folders — the
            // only two identities the public catalogue exposes — and neither of
            // those is what a person wants to read. A file with no entry keeps
            // its filename and its folder, which is the right answer for a
            // sound somebody put there and named themselves.
            let filename = next.deletingPathExtension().lastPathComponent
            let name = entry?.title.flatMap { $0.isEmpty ? nil : $0 } ?? filename
            let folder = components.count > rootComponents.count + 1
                ? components[rootComponents.count]
                : ""
            let pack = entry?.pack.flatMap { $0.isEmpty ? nil : $0 } ?? folder

            var bpm = entry?.bpm
            var key = entry?.key
            var source: StudioSoundMetadataSource = (bpm != nil || key != nil) ? .index : .absent
            if bpm == nil && key == nil {
                // Read off the FILE name, never the catalogue title. The
                // "…128bpm…" convention is something a sample vendor writes
                // into a filename; reading it out of a display title would be
                // parsing prose.
                let readBPM = StudioSoundNameMetadata.bpm(fromName: filename)
                let readKey = StudioSoundNameMetadata.key(fromName: filename)
                if readBPM != nil || readKey != nil {
                    bpm = readBPM
                    key = readKey
                    source = .filename
                }
            }

            let kind = entry?.kind.flatMap(StudioSoundKind.init(rawValue:))
                ?? StudioSoundKind.unknown

            assets.append(StudioSoundAsset(
                id: relative, name: name, path: next.path, pack: pack,
                kind: kind, bpm: bpm, key: key, metadata: source))
        }

        // Sorted once, here, off the main thread. Sorting 14,000 rows inside a
        // view body would be the same mistake as filtering there.
        assets.sort { $0.id.localizedStandardCompare($1.id) == .orderedAscending }

        return StudioVaultScanResult(
            root: root, assets: assets, indexed: indexed, rootMissing: false,
            truncatedAt: truncatedAt, ranOnMainThread: onMain,
            duration: Date().timeIntervalSince(started))
    }
}

// MARK: - The model the browser reads

/// The main-actor half: holds the scan's result and the ONE derived list the
/// view renders.
///
/// `visible` is stored, not computed. That is the whole performance design:
/// the filter runs when the query or the assets change, and a view body reads
/// an array that is already correct. A computed property here would look
/// identical at the call site and would re-filter fourteen thousand assets on
/// every body evaluation — which is exactly how `BrigadeConfig.isConfigured`
/// read like a free field access and was a synchronous XPC round trip.
@MainActor
final class StudioSoundsVaultModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case scanning
        /// The root does not exist yet. The browser explains where sounds come
        /// from rather than showing an empty list.
        case missingRoot
        case ready
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var assets: [StudioSoundAsset] = []
    @Published private(set) var visible: [StudioSoundAsset] = []
    @Published private(set) var indexedCount = 0
    @Published private(set) var truncatedAt: Int?
    @Published private(set) var hiddenForUnknownTempo = 0
    @Published private(set) var root: URL

    @Published var filter = StudioSoundFilter() {
        didSet { if filter != oldValue { recompute() } }
    }

    /// The project's tempo and key, pushed in by the view when the snapshot
    /// changes. Held here so the filter has them without the model reaching
    /// into `StudioViewModel` — this type owns no engine and mutates nothing.
    @Published var projectBPM: Double = 120 { didSet { if filter.inTempo { recompute() } } }
    @Published var projectKey: String? { didSet { if filter.inKey { recompute() } } }

    private var scanTask: Task<Void, Never>?

    init(root: URL = StudioSoundsVaultLocation.resolved()) {
        self.root = root
    }

    /// Start (or restart) a scan. Safe to call repeatedly; the previous scan is
    /// cancelled so pointing at a new folder does not race the old one's
    /// results onto the screen.
    ///
    /// NEVER call this from a view body. `.task`/`.onAppear`/a button, only.
    func rescan(root newRoot: URL? = nil) {
        if let newRoot { root = newRoot }
        scanTask?.cancel()
        phase = .scanning
        let target = root
        scanTask = Task { [weak self] in
            let result = await StudioVaultScanner.scan(root: target)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.adopt(result) }
        }
    }

    func adopt(_ result: StudioVaultScanResult) {
        root = result.root
        assets = result.assets
        indexedCount = result.indexed
        truncatedAt = result.truncatedAt
        phase = result.rootMissing ? .missingRoot : .ready
        recompute()
    }

    /// Test seam: adopt a fixture without touching the filesystem. Deliberately
    /// goes through `adopt`, the same door a real scan comes in by, so a test
    /// fixture cannot diverge from a real result.
    func adoptForTesting(_ assets: [StudioSoundAsset], root: URL = URL(fileURLWithPath: "/tmp/vault")) {
        adopt(StudioVaultScanResult(
            root: root, assets: assets,
            indexed: assets.filter { $0.metadata == .index }.count,
            rootMissing: false, truncatedAt: nil, ranOnMainThread: false, duration: 0))
    }

    private func recompute() {
        visible = StudioSoundsSearch.filter(
            assets, filter: filter, projectBPM: projectBPM, projectKey: projectKey)
        hiddenForUnknownTempo = StudioSoundsSearch.hiddenForUnknownTempo(assets, filter: filter)
    }

    /// What the list should say when it has nothing to show. Pure, so the
    /// empty state is a tested string rather than a literal buried in a view.
    ///
    /// Four DIFFERENT sentences, because "nothing here" has four different
    /// causes and only one of them is the user's to fix by typing less.
    var emptyMessage: String? {
        guard visible.isEmpty else { return nil }
        switch phase {
        case .idle:      return "Sounds you have downloaded appear here."
        case .scanning:  return "Looking through your sounds…"
        case .missingRoot:
            return "No sounds folder yet. Choose one below, then download packs "
                 + "from \(StudioSoundsVaultLocation.storefront) into it."
        case .ready:
            if assets.isEmpty {
                return "That folder has no audio in it yet. Download packs from "
                     + "\(StudioSoundsVaultLocation.storefront) into \(root.lastPathComponent)."
            }
            // "In key" against a song with no key can only ever hide
            // everything (`matches` returns false the moment `projectKey` is
            // nil), so the generic "try fewer words" below would blame the
            // search for a filter that cannot possibly match. This is the
            // residual case after the feed line was fixed: an imported song
            // whose key was never detected still lands here, and it needs to
            // be told which control to reach for.
            if filter.inKey, (projectKey ?? "").isEmpty {
                return "In key is on, but this song has no key yet — so nothing can match it. "
                     + "Type one into KEY in the transport bar, or turn In key off."
            }
            if hiddenForUnknownTempo > 0 {
                return "Nothing matches. \(hiddenForUnknownTempo) "
                     + "\(hiddenForUnknownTempo == 1 ? "sound was" : "sounds were") left out "
                     + "because nobody has recorded their tempo."
            }
            return "No sounds match. Try fewer words, or turn a filter off."
        }
    }

    /// The count line above the list: how much of the vault you are looking at.
    var summary: String {
        guard phase == .ready, !assets.isEmpty else { return "" }
        let shown = visible.count
        let total = assets.count
        var line = shown == total
            ? "\(total) sound\(total == 1 ? "" : "s")"
            : "\(shown) of \(total)"
        if let truncatedAt { line += " (first \(truncatedAt) found)" }
        if indexedCount == 0 && total > 0 { line += " · no tempo data" }
        return line
    }
}
