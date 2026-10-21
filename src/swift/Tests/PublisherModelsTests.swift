import Testing
import Foundation
@testable import MajiksMusicStudio

// MARK: - Credit Tests (Core — always available)

@Suite("Credit")
struct CreditTests {

    @Test("credit has expected standard roles")
    func standardRoles() {
        #expect(!Credit.standardRoles.isEmpty)
        #expect(Credit.standardRoles.contains("producer"))
    }

    @Test("credit initializes with correct fields")
    func init_() {
        let credit = Credit(name: "John Doe", role: "producer")
        #expect(credit.name == "John Doe")
        #expect(credit.role == "producer")
        #expect(credit.displayName == "")
    }

    @Test("credit initializes with displayName")
    func initWithDisplayName() {
        let credit = Credit(name: "John Doe", role: "producer", displayName: "JD")
        #expect(credit.name == "John Doe")
        #expect(credit.role == "producer")
        #expect(credit.displayName == "JD")
    }

    @Test("credit round-trips through JSON with displayName")
    func codableRoundTrip() throws {
        let original = Credit(name: "Jane", role: "lyricist", displayName: "J. Smith")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Credit.self, from: data)
        #expect(decoded.name == "Jane")
        #expect(decoded.role == "lyricist")
        #expect(decoded.displayName == "J. Smith")
    }

    @Test("credit decodes without displayName field for backward compat")
    func backwardCompat() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000000","name":"Old","role":"writer"}"#
        let decoded = try JSONDecoder().decode(Credit.self, from: Data(json.utf8))
        #expect(decoded.name == "Old")
        #expect(decoded.displayName == "")
    }

    @Test("standardRoles includes new roles")
    func newRoles() {
        #expect(Credit.standardRoles.contains("lyricist"))
        #expect(Credit.standardRoles.contains("co-creator"))
        #expect(Credit.standardRoles.contains("inspiration"))
        #expect(Credit.standardRoles.contains("engineer"))
    }
}

// MARK: - Track Credits Tests (Core — always available)

@Suite("TrackCredits")
struct TrackCreditsTests {

    @Test("track with credits round-trips through JSON")
    func creditsRoundTrip() throws {
        var track = Track(
            id: UUID(),
            title: "Test",
            caption: "",
            audioFileName: "test.wav",
            createdAt: Date(),
            duration: 120
        )
        track.credits = [
            Credit(name: "Alice", role: "producer", displayName: "A"),
            Credit(name: "Bob", role: "engineer")
        ]
        track.internalMetadata = ["source": "pipeline", "batch": "42"]

        let encoder = JSONEncoder()
        let data = try encoder.encode(track)
        let decoded = try JSONDecoder().decode(Track.self, from: data)

        #expect(decoded.credits?.count == 2)
        #expect(decoded.credits?[0].name == "Alice")
        #expect(decoded.credits?[0].displayName == "A")
        #expect(decoded.credits?[1].displayName == "")
        #expect(decoded.internalMetadata?["source"] == "pipeline")
        #expect(decoded.internalMetadata?["batch"] == "42")
    }

    @Test("track without credits decodes fine")
    func noCredits() throws {
        let track = Track(
            id: UUID(),
            title: "No Credits",
            caption: "",
            audioFileName: "test.wav",
            createdAt: Date(),
            duration: 60
        )
        let data = try JSONEncoder().encode(track)
        let decoded = try JSONDecoder().decode(Track.self, from: data)
        #expect(decoded.credits == nil)
        #expect(decoded.internalMetadata == nil)
    }
}

// MARK: - ISRC Tests (Core — always available)

@Suite("ISRC")
struct ISRCTests {

    @Test("formatISRC formats valid 12-char code")
    func formatValid() {
        #expect(ISRCHelper.formatISRC("USQT85926001") == "US-QT8-59-26001")
    }

    @Test("formatISRC returns input unchanged for invalid length")
    func formatInvalid() {
        #expect(ISRCHelper.formatISRC("short") == "short")
    }

    @Test("isValidISRC accepts valid codes")
    func validCode() {
        #expect(ISRCHelper.isValidISRC("USQT85926001"))
    }

    @Test("isValidISRC rejects short codes")
    func shortCode() {
        #expect(!ISRCHelper.isValidISRC("US123"))
    }

    @Test("isValidISRC rejects codes not starting with letters")
    func badPrefix() {
        #expect(!ISRCHelper.isValidISRC("12QT85926001"))
    }
}

// ============================================================
// Publisher tests (core feature)
// ============================================================

// MARK: - AuthState Tests

@Suite("AuthState")
struct AuthStateTests {

    @Test("notAuthenticated is not authenticated")
    func notAuthenticated() {
        let state = AuthState.notAuthenticated
        #expect(!state.isAuthenticated)
        #expect(state.keycloakId == nil)
    }

    @Test("authenticated state provides keycloak ID")
    func authenticated() {
        let state = AuthState.authenticated(keycloakId: "abc-123")
        #expect(state.isAuthenticated)
        #expect(state.keycloakId == "abc-123")
    }

    @Test("failed state is not authenticated")
    func failed() {
        let state = AuthState.failed(message: "Token expired")
        #expect(!state.isAuthenticated)
        #expect(state.keycloakId == nil)
    }
}

// MARK: - PublishStatus Tests

@Suite("PublishStatus")
struct PublishStatusTests {

    @Test("unpublished is not in progress or published")
    func unpublished() {
        let status = PublishStatus.unpublished
        #expect(!status.isInProgress)
        #expect(!status.isPublished)
        #expect(!status.isFailed)
        #expect(!status.isDuplicateWarning)
    }

    @Test("converting is in progress")
    func converting() {
        let status = PublishStatus.converting(progress: 0.5)
        #expect(status.isInProgress)
        #expect(!status.isPublished)
    }

    @Test("fingerprinting is in progress")
    func fingerprinting() {
        let status = PublishStatus.fingerprinting
        #expect(status.isInProgress)
    }

    @Test("checkingDuplicates is in progress")
    func checkingDuplicates() {
        let status = PublishStatus.checkingDuplicates
        #expect(status.isInProgress)
    }

    @Test("uploading is in progress")
    func uploading() {
        let status = PublishStatus.uploading(progress: 0.8)
        #expect(status.isInProgress)
    }

    @Test("published is published and not in progress")
    func published() {
        let status = PublishStatus.published(trackId: "tid", slug: "my-track", scheduledAt: nil)
        #expect(status.isPublished)
        #expect(!status.isInProgress)
        #expect(!status.isFailed)
    }

    @Test("failed has correct state")
    func failed() {
        let status = PublishStatus.failed(message: "Server error")
        #expect(status.isFailed)
        #expect(!status.isInProgress)
        #expect(!status.isPublished)
    }

    @Test("duplicateWarning has correct state")
    func duplicateWarning() {
        let match = DuplicateMatch(from: [
            "id": .string("m1"),
            "title": .string("Similar Track"),
            "artist": .string("Someone"),
            "similarity": .number(0.95)
        ])
        let status = PublishStatus.duplicateWarning(matches: [match])
        #expect(status.isDuplicateWarning)
        #expect(!status.isInProgress)
        #expect(!status.isPublished)
    }

    @Test("statusText returns non-empty string for all cases")
    func statusText() {
        let cases: [PublishStatus] = [
            .unpublished,
            .converting(progress: 0.5),
            .fingerprinting,
            .checkingDuplicates,
            .readyToPublish,
            .uploading(progress: 0.8),
            .published(trackId: "t", slug: "s", scheduledAt: nil),
            .published(trackId: "t", slug: "s", scheduledAt: Date(timeIntervalSince1970: 1_800_000_000)),
            .failed(message: "err"),
        ]
        for status in cases {
            #expect(!status.statusText.isEmpty, "statusText should be non-empty for \(status)")
        }
    }
}

// MARK: - PreflightCheck Tests

@Suite("PreflightCheck")
struct PreflightCheckTests {

    private func makeCandidate(
        title: String = "Test Track",
        artist: String = "Test Artist",
        genre: String = "Electronic",
        duration: Double = 120
    ) -> PublishCandidate {
        let track = Track(
            id: UUID(),
            title: title,
            caption: "",
            audioFileName: "test.wav",
            createdAt: Date(),
            duration: duration
        )
        var candidate = PublishCandidate(from: track)
        candidate.title = title
        candidate.artist = artist
        candidate.genre = genre
        candidate.duration = duration
        return candidate
    }

    @Test("clean candidate passes preflight with no errors or warnings")
    func cleanCandidate() {
        let candidate = makeCandidate()
        let result = candidate.preflightCheck()
        #expect(!result.hasErrors)
        #expect(!result.hasWarnings)
        // May have .info issues (e.g. no custom artwork) but no blocking errors
    }

    @Test("empty title produces error")
    func emptyTitle() {
        let candidate = makeCandidate(title: "")
        let result = candidate.preflightCheck()
        #expect(result.hasErrors)
        #expect(result.issues.contains { $0.field == "Title" && $0.severity == .error })
    }

    @Test("empty artist produces error")
    func emptyArtist() {
        let candidate = makeCandidate(artist: "")
        let result = candidate.preflightCheck()
        #expect(result.hasErrors)
        #expect(result.issues.contains { $0.field == "Artist" && $0.severity == .error })
    }

    @Test("empty genre produces warning not error")
    func emptyGenre() {
        let candidate = makeCandidate(genre: "")
        let result = candidate.preflightCheck()
        #expect(!result.hasErrors)
        #expect(result.hasWarnings)
        #expect(result.issues.contains { $0.field == "Genre" && $0.severity == .warning })
    }

    @Test("very short duration produces warning")
    func shortDuration() {
        let candidate = makeCandidate(duration: 5)
        let result = candidate.preflightCheck()
        #expect(result.issues.contains { $0.field == "Duration" })
    }

    @Test("very long duration produces warning")
    func longDuration() {
        let candidate = makeCandidate(duration: 700)
        let result = candidate.preflightCheck()
        #expect(result.issues.contains { $0.field == "Duration" })
    }
}

// MARK: - MetadataDiff Tests

@Suite("MetadataDiff")
struct MetadataDiffTests {

    @Test("diff has correct properties")
    func basicDiff() {
        let diff = MetadataDiff(fieldName: "title", localValue: "Local Title", serverValue: "Server Title")
        #expect(diff.fieldName == "title")
        #expect(diff.localValue == "Local Title")
        #expect(diff.serverValue == "Server Title")
    }

    @Test("diff is identifiable with unique IDs")
    func identifiable() {
        let diff1 = MetadataDiff(fieldName: "title", localValue: "A", serverValue: "B")
        let diff2 = MetadataDiff(fieldName: "artist", localValue: "C", serverValue: "D")
        #expect(diff1.id != diff2.id)
    }
}

// MARK: - SyncAction Tests

@Suite("SyncAction")
struct SyncActionTests {

    @Test("pushToServer contains diffs")
    func pushToServer() {
        let diffs = [MetadataDiff(fieldName: "title", localValue: "A", serverValue: "B")]
        let action = SyncAction.pushToServer(diffs: diffs)
        if case .pushToServer(let d) = action {
            #expect(d.count == 1)
        } else {
            Issue.record("Expected pushToServer")
        }
    }

    @Test("inSync has no associated data")
    func inSync() {
        let action = SyncAction.inSync
        if case .inSync = action {
            // OK
        } else {
            Issue.record("Expected inSync")
        }
    }
}

// MARK: - CatalogueTrack Tests

@Suite("CatalogueTrack")
struct CatalogueTrackTests {

    @Test("init from dict parses camelCase fields")
    func camelCaseParsing() {
        let dict: [String: JSONValue] = [
            "trackId": .string("t-123"),
            "trackSlug": .string("my-track"),
            "studioTrackId": .string("s-456"),
            "title": .string("My Track"),
            "genre": .string("Electronic"),
            "artist": .string("Test Artist"),
            "bpm": .string("120"),
            "duration": .number(180.5),
            "playCount": .number(42),
            "audioUrl": .string("https://example.com/audio.m4a"),
            "artworkUrl": .string("https://example.com/art.jpg"),
            "artworkThumbUrl": .string("https://example.com/art-thumb.jpg"),
            "pageUrl": .string("https://example.com/track"),
            "hasLossless": .bool(true),
            "isExplicit": .bool(false),
            "publishedAt": .string("2024-01-15T10:30:00Z")
        ]

        let track = CatalogueTrack(from: dict)

        #expect(track.trackId == "t-123")
        #expect(track.trackSlug == "my-track")
        #expect(track.studioTrackId == "s-456")
        #expect(track.title == "My Track")
        #expect(track.genre == "Electronic")
        #expect(track.artist == "Test Artist")
        #expect(track.bpm == "120")
        #expect(track.duration == 180.5)
        #expect(track.playCount == 42)
        #expect(track.hasLossless == true)
        #expect(track.isExplicit == false)
    }

    @Test("init from dict handles snake_case fields")
    func snakeCaseParsing() {
        let dict: [String: JSONValue] = [
            "track_id": .string("t-789"),
            "track_slug": .string("another-track"),
            "studio_track_id": .string("s-012"),
            "title": .string("Another Track"),
            "genre": .string("Rock"),
            "artist": .string("Band"),
            "bpm": .string("140"),
            "duration": .number(200.0),
            "play_count": .number(10),
            "audio_url": .string("https://example.com/rock.m4a"),
            "artwork_url": .string(""),
            "artwork_thumb_url": .string(""),
            "page_url": .string(""),
            "has_lossless": .bool(false),
            "is_explicit": .bool(true)
        ]

        let track = CatalogueTrack(from: dict)

        #expect(track.trackId == "t-789")
        #expect(track.trackSlug == "another-track")
        #expect(track.studioTrackId == "s-012")
        #expect(track.isExplicit == true)
        #expect(track.hasLossless == false)
    }

    @Test("missing fields default to empty/zero")
    func missingFields() {
        let track = CatalogueTrack(from: [:])

        #expect(track.trackId.isEmpty)
        #expect(track.title.isEmpty)
        #expect(track.duration == 0)
        #expect(track.playCount == 0)
        #expect(!track.hasLossless)
        #expect(!track.isExplicit)
    }
}

// MARK: - ArtistProfile Tests

@Suite("ArtistProfile")
struct ArtistProfileTests {

    @Test("init from dict parses correctly")
    func basicParsing() {
        let dict: [String: JSONValue] = [
            "id": .string("profile-1"),
            "artistName": .string("Majik"),
            "website": .string("https://majik.com"),
            "socialLinks": .object(["twitter": .string("https://twitter.com/majik")])
        ]

        let profile = ArtistProfile(from: dict)

        #expect(profile.id == "profile-1")
        #expect(profile.artistName == "Majik")
        #expect(profile.website == "https://majik.com")
        #expect(profile.socialLinks["twitter"] == "https://twitter.com/majik")
    }

    @Test("init from dict handles snake_case")
    func snakeCaseParsing() {
        let dict: [String: JSONValue] = [
            "id": .string("profile-2"),
            "artist_name": .string("Magic Unicorn"),
            "website": .string(""),
            "social_links": .object(["instagram": .string("https://instagram.com/mu")])
        ]

        let profile = ArtistProfile(from: dict)

        #expect(profile.artistName == "Magic Unicorn")
        #expect(profile.socialLinks["instagram"] == "https://instagram.com/mu")
    }

    @Test("equatable compares all fields")
    func equatable() {
        let a = ArtistProfile(from: ["id": .string("same-id"), "artistName": .string("A")])
        let b = ArtistProfile(from: ["id": .string("same-id"), "artistName": .string("A")])
        let c = ArtistProfile(from: ["id": .string("diff-id"), "artistName": .string("A")])

        #expect(a == b) // Same ID and name
        #expect(a != c) // Different ID
    }
}

// MARK: - PublishCandidate Credits Tests

@Suite("PublishCandidateCredits")
struct PublishCandidateCreditsTests {

    @Test("PublishCandidate inherits credits from Track")
    func candidateInheritsCredits() {
        var track = Track(
            id: UUID(),
            title: "Credited",
            caption: "",
            audioFileName: "test.wav",
            createdAt: Date(),
            duration: 120
        )
        track.credits = [Credit(name: "Eve", role: "vocalist", displayName: "E")]

        let candidate = PublishCandidate(from: track)
        #expect(candidate.credits.count == 1)
        #expect(candidate.credits[0].name == "Eve")
        #expect(candidate.credits[0].displayName == "E")
    }

    @Test("PublishCandidate defaults to empty credits when track has none")
    func candidateNoCredits() {
        let track = Track(
            id: UUID(),
            title: "No Credits",
            caption: "",
            audioFileName: "test.wav",
            createdAt: Date(),
            duration: 60
        )
        let candidate = PublishCandidate(from: track)
        #expect(candidate.credits.isEmpty)
    }
}

// MARK: - DuplicateMatch Tests

@Suite("DuplicateMatch")
struct DuplicateMatchTests {

    @Test("init from dict parses camelCase")
    func camelCase() {
        let dict: [String: JSONValue] = [
            "id": .string("match-1"),
            "title": .string("Similar Song"),
            "artist": .string("Other Artist"),
            "similarity": .number(0.92)
        ]
        let match = DuplicateMatch(from: dict)
        #expect(match.title == "Similar Song")
        #expect(match.artist == "Other Artist")
        #expect(match.similarity == 0.92)
    }

    @Test("init from dict handles snake_case")
    func snakeCase() {
        let dict: [String: JSONValue] = [
            "id": .string("match-2"),
            "title": .string("Another Song"),
            "artist": .string("Person"),
            "similarity": .number(0.87)
        ]
        let match = DuplicateMatch(from: dict)
        #expect(match.similarity == 0.87)
    }
}
