import Foundation

// Credit and ISRCHelper are defined in Models.swift (shared with core)

// MARK: - Publisher Auth State

enum AuthState: Equatable {
    case notAuthenticated
    case authenticated(keycloakId: String)
    case failed(message: String)

    var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }

    var keycloakId: String? {
        if case .authenticated(let id) = self { return id }
        return nil
    }
}

// MARK: - Publish Errors

enum PublishError: Error, LocalizedError {
    case notAuthenticated
    case tokenExpired

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not authenticated. Please log in."
        case .tokenExpired: return "Session expired. Please log in again."
        }
    }
}

// MARK: - Publish Status

enum PublishStatus: Equatable {
    case unpublished
    case converting(progress: Double)
    case fingerprinting
    case checkingDuplicates
    case duplicateWarning(matches: [DuplicateMatch])
    case readyToPublish
    case uploading(progress: Double)
    /// Accepted by the server. `scheduledAt` is non-nil when the track was
    /// created with SCHEDULED visibility and is therefore **not on the site
    /// yet** — see `statusText` and `trackURL` for why that distinction is
    /// carried in the case rather than looked up from the candidate.
    case published(trackId: String, slug: String, scheduledAt: Date?)
    case failed(message: String)

    var isInProgress: Bool {
        switch self {
        case .converting, .fingerprinting, .checkingDuplicates, .uploading: return true
        default: return false
        }
    }

    var isPublished: Bool {
        if case .published = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var isDuplicateWarning: Bool {
        if case .duplicateWarning = self { return true }
        return false
    }

    var statusText: String {
        switch self {
        case .unpublished: return "Ready"
        case .converting(let progress): return "Converting \(Int(progress * 100))%"
        case .fingerprinting: return "Fingerprinting..."
        case .checkingDuplicates: return "Checking duplicates..."
        case .duplicateWarning(let matches):
            return "Possible duplicate (\(matches.count) match\(matches.count == 1 ? "" : "es"))"
        case .readyToPublish: return "Ready to publish"
        case .uploading(let progress): return "Uploading \(Int(progress * 100))%"
        case .published(_, _, let scheduledAt):
            // A SCHEDULED track is not published. The sheet that offers this
            // says so out loud -- "Track will be created with scheduled
            // visibility and auto-publish at this time" -- and then the queue
            // used to report it as "Published" with the same green tick as a
            // live track, because the scheduled date never reached the status.
            // Server-side it is `visibility = 'scheduled'`, `published_at =
            // null`: the journey is "publish a track and see it on the site",
            // and this is the step that claimed you could when you could not.
            guard let scheduledAt else { return "Published" }
            return "Scheduled for \(Self.scheduleFormatter.string(from: scheduledAt))"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    /// Short and local, because it goes in a capsule badge next to a title.
    private static let scheduleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// True only while the track is genuinely on the site.
    ///
    /// Separate from `isPublished`, which stays true for a scheduled track
    /// because the queue uses it to mean "this no longer needs publishing" --
    /// the upload really did happen. This one means "a person can go and look at
    /// it", which is a different question and the one the link answers.
    var isLiveOnSite: Bool {
        if case .published(_, _, let scheduledAt) = self { return scheduledAt == nil }
        return false
    }

    /// The public page, or nil when there is not one yet.
    ///
    /// A scheduled track has a slug and no page: the old version built the URL
    /// from the slug alone, so the queue offered a "view on the site" button
    /// that led somewhere with nothing at it. A link that 404s is worse than no
    /// link -- it reads as "the publish broke" rather than "it is not due yet".
    var trackURL: String? {
        if case .published(_, let slug, let scheduledAt) = self, scheduledAt == nil {
            return "https://majiks.online/track/\(slug)"
        }
        return nil
    }
}

// MARK: - Duplicate Match

struct DuplicateMatch: Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    let similarity: Double

    init(from dict: [String: JSONValue]) {
        self.id = dict["track_id"]?.stringValue ?? dict["trackId"]?.stringValue ?? UUID().uuidString
        self.title = dict["title"]?.stringValue ?? "Unknown"
        self.artist = dict["artist"]?.stringValue ?? ""
        self.similarity = dict["similarity"]?.doubleValue ?? 0
    }
}

// MARK: - Publish Candidate

struct PublishCandidate: Identifiable, Equatable {
    let id: UUID
    let sourceTrack: Track
    var title: String
    var genre: String
    var artist: String
    var album: String
    var lyrics: String
    var bpm: Double?
    var musicalKey: String?
    var duration: Double
    var artistProfileId: String?
    var parentTrackId: String?
    var skipDuplicateCheck: Bool
    var status: PublishStatus
    var description: String
    var backstory: String
    var backstoryVisibility: String
    var subgenre: String
    var mood: String
    var energy: Double?
    var language: String
    var isExplicit: Bool
    var tags: String
    var credits: [Credit]
    var scheduledAt: Date?
    var isrc: String
    var requestISRC: Bool

    init(from track: Track) {
        self.id = track.id
        self.sourceTrack = track
        self.title = track.title
        self.genre = track.genre ?? ""
        self.artist = track.artist ?? ""
        self.album = track.album ?? ""
        self.lyrics = track.lyrics ?? ""
        self.bpm = track.bpm
        self.musicalKey = track.key
        self.duration = track.duration
        self.artistProfileId = nil
        self.parentTrackId = nil
        self.skipDuplicateCheck = false
        self.status = .unpublished
        self.description = track.caption
        self.backstory = track.originalPrompt ?? ""
        self.backstoryVisibility = "public"
        self.subgenre = ""
        self.mood = track.mood ?? ""
        self.energy = nil
        self.language = "en"
        self.isExplicit = false
        self.tags = (track.topicTags ?? []).joined(separator: ", ")
        self.credits = track.credits ?? []
        self.scheduledAt = nil
        self.isrc = track.isrc ?? ""
        self.requestISRC = true
    }
}

extension PublishCandidate {
    /// Convenience to create a candidate pre-filled with all metadata from a library Track.
    /// This mirrors `init(from:)` but is available as a named factory for clarity in import flows.
    static func fromLibraryTrack(_ track: Track) -> PublishCandidate {
        PublishCandidate(from: track)
    }
}

// MARK: - Catalogue Track

struct CatalogueTrack: Identifiable, Equatable {
    let trackId: String
    let trackSlug: String
    var title: String
    var genre: String
    var artist: String
    var album: String
    var bpm: String
    var musicalKey: String
    var duration: Double
    var lyrics: String
    let studioTrackId: String
    let playCount: Int
    let rating: Double
    let publishedAt: Date?
    let artistProfileId: String?
    let parentTrackId: String?
    let audioUrl: String
    let pageUrl: String
    let artworkUrl: String
    let artworkThumbUrl: String
    let hasLossless: Bool
    var description: String
    var backstory: String
    var backstoryVisibility: String
    var subgenre: String
    var mood: String
    var energy: Double
    var language: String
    var isExplicit: Bool
    var tags: String
    var credits: [Credit]
    var isrc: String

    var id: String { trackId }

    init(from dict: [String: JSONValue]) {
        self.trackId = dict["trackId"]?.stringValue ?? dict["track_id"]?.stringValue ?? ""
        self.trackSlug = dict["trackSlug"]?.stringValue ?? dict["track_slug"]?.stringValue ?? ""
        self.title = dict["title"]?.stringValue ?? ""
        self.genre = dict["genre"]?.stringValue ?? ""
        self.artist = dict["artist"]?.stringValue ?? ""
        self.album = dict["album"]?.stringValue ?? ""
        self.musicalKey = dict["musicalKey"]?.stringValue ?? dict["musical_key"]?.stringValue ?? ""
        self.lyrics = dict["lyrics"]?.stringValue ?? ""
        self.studioTrackId = dict["studioTrackId"]?.stringValue ?? dict["studio_track_id"]?.stringValue ?? ""
        self.artistProfileId = dict["artistProfileId"]?.stringValue ?? dict["artist_profile_id"]?.stringValue
        self.parentTrackId = dict["parentTrackId"]?.stringValue ?? dict["parent_track_id"]?.stringValue
        self.audioUrl = dict["audioUrl"]?.stringValue ?? dict["audio_url"]?.stringValue ?? ""
        self.pageUrl = dict["pageUrl"]?.stringValue ?? dict["page_url"]?.stringValue ?? ""
        self.artworkUrl = dict["artworkUrl"]?.stringValue ?? dict["artwork_url"]?.stringValue ?? ""
        self.artworkThumbUrl = dict["artworkThumbUrl"]?.stringValue ?? dict["artwork_thumb_url"]?.stringValue ?? ""

        if case .bool(let val) = dict["hasLossless"] ?? dict["has_lossless"] {
            self.hasLossless = val
        } else {
            self.hasLossless = false
        }

        if let bpmVal = dict["bpm"]?.doubleValue {
            self.bpm = String(Int(bpmVal))
        } else if let bpmStr = dict["bpm"]?.stringValue {
            self.bpm = bpmStr
        } else {
            self.bpm = ""
        }

        self.duration = dict["duration"]?.doubleValue ?? 0
        self.playCount = Int(dict["playCount"]?.doubleValue ?? dict["play_count"]?.doubleValue ?? 0)
        self.rating = dict["rating"]?.doubleValue ?? 0

        if let dateStr = dict["publishedAt"]?.stringValue ?? dict["published_at"]?.stringValue {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            self.publishedAt = formatter.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr)
        } else {
            self.publishedAt = nil
        }

        self.description = dict["description"]?.stringValue ?? ""
        self.backstory = dict["backstory"]?.stringValue ?? ""
        self.backstoryVisibility = dict["backstoryVisibility"]?.stringValue ?? dict["backstory_visibility"]?.stringValue ?? "public"
        self.subgenre = dict["subgenre"]?.stringValue ?? ""
        self.mood = dict["mood"]?.stringValue ?? ""
        self.energy = dict["energy"]?.doubleValue ?? 0
        self.language = dict["language"]?.stringValue ?? "en"
        self.tags = dict["tags"]?.stringValue ?? ""

        if case .bool(let val) = dict["isExplicit"] ?? dict["is_explicit"] ?? dict["explicit"] {
            self.isExplicit = val
        } else if let str = dict["isExplicit"]?.stringValue ?? dict["is_explicit"]?.stringValue ?? dict["explicit"]?.stringValue {
            self.isExplicit = (str == "true")
        } else {
            self.isExplicit = false
        }

        // Parse credits from JSON string or array
        var parsedCredits: [Credit] = []
        if let creditsStr = dict["credits"]?.stringValue,
           let data = creditsStr.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([Credit].self, from: data) {
            parsedCredits = decoded
        } else if case .array(let items)? = dict["credits"] {
            for item in items {
                if case .object(let c) = item {
                    let name = c["name"]?.stringValue ?? ""
                    let role = c["role"]?.stringValue ?? ""
                    let displayName = c["displayName"]?.stringValue ?? c["display_name"]?.stringValue ?? ""
                    if !name.isEmpty {
                        parsedCredits.append(Credit(name: name, role: role, displayName: displayName))
                    }
                }
            }
        }
        self.credits = parsedCredits
        self.isrc = dict["isrc"]?.stringValue ?? ""
    }
}

struct MetadataDiff: Identifiable {
    let id = UUID()
    let fieldName: String
    let localValue: String
    let serverValue: String
}

enum SyncAction {
    case pushToServer(diffs: [MetadataDiff])
    case pullToLocal(diffs: [MetadataDiff])
    case inSync
    case serverOnly
}

enum SyncDirection {
    case pushToServer
    case pullToLocal
}

// MARK: - Pre-flight Validation

enum PreflightSeverity {
    case error      // Blocks publishing (red)
    case warning    // Allows publishing (orange)
    case info       // Informational (blue)
}

struct PreflightIssue: Identifiable {
    let id = UUID()
    let field: String
    let message: String
    let severity: PreflightSeverity
}

struct PreflightResult: Identifiable {
    let id: UUID  // matches candidate id
    let title: String
    let issues: [PreflightIssue]

    var hasErrors: Bool { issues.contains { $0.severity == .error } }
    var hasWarnings: Bool { issues.contains { $0.severity == .warning } }
    var isClean: Bool { issues.isEmpty }
}

extension PublishCandidate {
    func preflightCheck() -> PreflightResult {
        var issues: [PreflightIssue] = []

        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(PreflightIssue(field: "Title", message: "Title is required", severity: .error))
        }

        if artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(PreflightIssue(field: "Artist", message: "Artist is required", severity: .error))
        }

        if genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(PreflightIssue(field: "Genre", message: "Genre recommended for discoverability", severity: .warning))
        }

        if sourceTrack.customArtworkFileName == nil {
            issues.append(PreflightIssue(field: "Artwork", message: "No custom artwork — procedural art will be used", severity: .info))
        }

        if duration < 10 {
            issues.append(PreflightIssue(field: "Duration", message: "Track is very short (\(Int(duration))s)", severity: .warning))
        } else if duration > 600 {
            issues.append(PreflightIssue(field: "Duration", message: "Track is over 10 minutes (\(Int(duration / 60))m)", severity: .warning))
        }

        return PreflightResult(id: id, title: title, issues: issues)
    }
}

// MARK: - Artist Profile

struct ArtistProfile: Identifiable, Equatable {
    let id: String
    var artistName: String
    var website: String
    var socialLinks: [String: String]

    init(from dict: [String: JSONValue]) {
        self.id = dict["id"]?.stringValue ?? ""
        self.artistName = dict["artistName"]?.stringValue ?? dict["artist_name"]?.stringValue ?? ""
        self.website = dict["website"]?.stringValue ?? ""
        if let linksValue = dict["socialLinks"] ?? dict["social_links"],
           case .object(let links) = linksValue {
            var parsed: [String: String] = [:]
            for (k, v) in links {
                if case .string(let url) = v { parsed[k] = url }
            }
            self.socialLinks = parsed
        } else {
            self.socialLinks = [:]
        }
    }

    init(id: String, artistName: String, website: String = "", socialLinks: [String: String] = [:]) {
        self.id = id
        self.artistName = artistName
        self.website = website
        self.socialLinks = socialLinks
    }
}

// MARK: - Catalogue Load State

enum CatalogueLoadState: Equatable {
    case idle
    case loading
    case loaded(totalCount: Int)
    case failed(message: String)
}

// MARK: - Dashboard Models

struct SalesSummary: Equatable {
    let totalRevenue: Double
    let totalSales: Int
    let topTracks: [TopTrack]

    struct TopTrack: Identifiable, Equatable {
        let id: String
        let title: String
        let sales: Int
        let revenue: Double
    }

    init(from dict: [String: JSONValue]) {
        self.totalRevenue = dict["totalRevenue"]?.doubleValue ?? dict["total_revenue"]?.doubleValue ?? 0
        self.totalSales = Int(dict["totalSales"]?.doubleValue ?? dict["total_sales"]?.doubleValue ?? 0)

        var tops: [TopTrack] = []
        if case .array(let items)? = dict["topTracks"] ?? dict["top_tracks"] {
            for item in items {
                if case .object(let d) = item {
                    tops.append(TopTrack(
                        id: d["id"]?.stringValue ?? d["track_id"]?.stringValue ?? UUID().uuidString,
                        title: d["title"]?.stringValue ?? "",
                        sales: Int(d["sales"]?.doubleValue ?? 0),
                        revenue: d["revenue"]?.doubleValue ?? 0
                    ))
                }
            }
        }
        self.topTracks = tops
    }
}

struct SaleTransaction: Identifiable, Equatable {
    let id: String
    let date: String
    let trackTitle: String
    let amount: Double
    let buyer: String

    init(from dict: [String: JSONValue]) {
        self.id = dict["id"]?.stringValue ?? UUID().uuidString
        self.date = dict["date"]?.stringValue ?? ""
        self.trackTitle = dict["trackTitle"]?.stringValue ?? dict["track_title"]?.stringValue ?? ""
        self.amount = dict["amount"]?.doubleValue ?? 0
        self.buyer = dict["buyer"]?.stringValue ?? ""
    }
}

struct EarningsSummary: Equatable {
    let totalEarned: Double
    let thisMonth: Double
    let lastMonth: Double
    let balance: Double
    let pendingPayouts: Double
    let chartData: [MonthlyEarning]

    struct MonthlyEarning: Identifiable, Equatable {
        let id: String
        let month: String
        let amount: Double
    }

    init(from dict: [String: JSONValue]) {
        self.totalEarned = dict["totalEarned"]?.doubleValue ?? dict["total_earned"]?.doubleValue ?? 0
        self.thisMonth = dict["thisMonth"]?.doubleValue ?? dict["this_month"]?.doubleValue ?? 0
        self.lastMonth = dict["lastMonth"]?.doubleValue ?? dict["last_month"]?.doubleValue ?? 0
        self.balance = dict["balance"]?.doubleValue ?? 0
        self.pendingPayouts = dict["pendingPayouts"]?.doubleValue ?? dict["pending_payouts"]?.doubleValue ?? 0

        var chart: [MonthlyEarning] = []
        if case .array(let items)? = dict["chartData"] ?? dict["chart_data"] {
            for item in items {
                if case .object(let d) = item {
                    chart.append(MonthlyEarning(
                        id: d["month"]?.stringValue ?? UUID().uuidString,
                        month: d["month"]?.stringValue ?? "",
                        amount: d["amount"]?.doubleValue ?? 0
                    ))
                }
            }
        }
        self.chartData = chart
    }
}

struct PayoutRecord: Identifiable, Equatable {
    let id: String
    let date: String
    let amount: Double
    let status: String

    init(from dict: [String: JSONValue]) {
        self.id = dict["id"]?.stringValue ?? UUID().uuidString
        self.date = dict["date"]?.stringValue ?? ""
        self.amount = dict["amount"]?.doubleValue ?? 0
        self.status = dict["status"]?.stringValue ?? ""
    }
}

struct CatalogSummary: Equatable {
    let trackCount: Int
    let albumCount: Int
    let profileCount: Int
    let fingerprintStatus: String
    let provenanceStatus: String

    init(from dict: [String: JSONValue]) {
        self.trackCount = Int(dict["trackCount"]?.doubleValue ?? dict["track_count"]?.doubleValue ?? 0)
        self.albumCount = Int(dict["albumCount"]?.doubleValue ?? dict["album_count"]?.doubleValue ?? 0)
        self.profileCount = Int(dict["profileCount"]?.doubleValue ?? dict["profile_count"]?.doubleValue ?? 0)
        self.fingerprintStatus = dict["fingerprintStatus"]?.stringValue ?? dict["fingerprint_status"]?.stringValue ?? ""
        self.provenanceStatus = dict["provenanceStatus"]?.stringValue ?? dict["provenance_status"]?.stringValue ?? ""
    }
}
