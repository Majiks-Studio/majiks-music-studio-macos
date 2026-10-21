import Foundation
import SwiftUI

@MainActor
final class SessionStore: ObservableObject {
    @Published var currentSession: StudioSession?
    @Published private(set) var recentSessions: [StudioSession] = []

    private let fileStore = FileStore.shared

    init() {
        loadRecentSessions()
    }

    // MARK: - Session Management

    /// Creates a new studio session with the given parameters
    func createNewSession(from params: MusicParameters, conversationId: UUID? = nil) {
        let session = StudioSession(
            id: UUID(),
            name: "Studio Session",
            stagingTracks: [],
            parameters: params,
            conversationId: conversationId,
            createdAt: Date(),
            updatedAt: Date()
        )
        currentSession = session
        recentSessions.insert(session, at: 0)

        // Create staging directory for this session
        _ = fileStore.createStagingSessionDirectory(id: session.id)

        saveSession()

        print("[SessionStore] Created new session: \(session.id)")
    }

    /// Loads recent sessions from sessions.json
    func loadRecentSessions() {
        do {
            let data = try Data(contentsOf: fileStore.sessionsURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([StudioSession].self, from: data)
            recentSessions = decoded.sorted { $0.updatedAt > $1.updatedAt }

            print("[SessionStore] Loaded \(recentSessions.count) sessions")
        } catch {
            recentSessions = []
            print("[SessionStore] No sessions file found or decode error: \(error)")
        }
    }

    /// Loads a session by ID
    func loadSession(id: UUID) {
        guard let session = recentSessions.first(where: { $0.id == id }) else {
            print("[SessionStore] Session not found: \(id)")
            return
        }

        currentSession = session
        print("[SessionStore] Loaded session: \(id)")
    }

    /// Updates the current session's parameters (syncs UI state back to session)
    func updateParameters(_ params: MusicParameters) {
        guard var session = currentSession else { return }
        session.parameters = params
        session.updatedAt = Date()
        currentSession = session
    }

    /// Saves the current session to disk
    func saveSession() {
        guard var session = currentSession else {
            print("[SessionStore] No current session to save")
            return
        }

        // Update timestamp
        session.updatedAt = Date()
        currentSession = session

        // Update or add to recent sessions
        if let index = recentSessions.firstIndex(where: { $0.id == session.id }) {
            recentSessions[index] = session
        } else {
            recentSessions.insert(session, at: 0)
        }

        // Keep only last 20 sessions
        if recentSessions.count > 20 {
            let prunedSessions = Array(recentSessions.dropFirst(20))
            recentSessions = Array(recentSessions.prefix(20))

            // Clean up staging directories for pruned sessions — skip if tracks remain
            for session in prunedSessions {
                if session.stagingTracks.isEmpty {
                    fileStore.cleanupStagingDirectory(id: session.id)
                    print("[SessionStore] Cleaned up staging for pruned session: \(session.id)")
                } else {
                    print("[SessionStore] Skipped cleanup for session \(session.id) — has \(session.stagingTracks.count) staging track(s)")
                }
            }
        }

        saveRecentSessions()

        print("[SessionStore] Saved session: \(session.id)")
    }

    /// Clears the current session and deletes staging files
    func clearCurrentSession() {
        guard let session = currentSession else {
            print("[SessionStore] No current session to clear")
            return
        }

        // Cleanup staging directory
        fileStore.cleanupStagingDirectory(id: session.id)

        currentSession = nil
        print("[SessionStore] Cleared current session")
    }

    /// Deletes a session from recent sessions
    func deleteSession(id: UUID) {
        // Remove from recent sessions
        recentSessions.removeAll { $0.id == id }
        saveRecentSessions()

        // Cleanup staging directory
        fileStore.cleanupStagingDirectory(id: id)

        // Clear current session if it was deleted
        if currentSession?.id == id {
            currentSession = nil
        }

        print("[SessionStore] Deleted session: \(id)")
    }

    // MARK: - Track Lifecycle

    /// Converts marked staging tracks to Library tracks and returns them
    func keepSelectedTracks() -> [Track] {
        guard var session = currentSession else {
            print("[SessionStore] No current session")
            return []
        }

        let markedTracks = session.stagingTracks.filter { $0.isMarkedForKeep }
        var libraryTracks: [Track] = []
        var keptTrackIDs = Set<UUID>()

        for stagingTrack in markedTracks {
            // Move file from staging to permanent library location
            let sourceURL = stagingTrack.audioURL
            let trackID = UUID()
            let destinationDirectory = fileStore.audioDirectory.appendingPathComponent(trackID.uuidString)

            do {
                // Create track-specific directory
                try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

                // Generate new filename for library (use unique variant ID)
                let fileName = "\(stagingTrack.variantId).wav"
                let destinationURL = destinationDirectory.appendingPathComponent(fileName)

                // Copy file to library
                if FileManager.default.fileExists(atPath: sourceURL.path) {
                    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

                    // Create Track object - use style prompt as caption (more useful than variant note)
                    var track = Track(
                        id: trackID,
                        title: stagingTrack.title,
                        caption: session.parameters.style,
                        audioFileName: "\(trackID.uuidString)/\(fileName)",
                        createdAt: stagingTrack.createdAt,
                        duration: stagingTrack.duration,
                        rating: 0,
                        bpm: stagingTrack.bpm ?? session.parameters.bpm,
                        key: stagingTrack.key ?? session.parameters.key,
                        artist: stagingTrack.artist ?? (session.parameters.artist.isEmpty ? nil : session.parameters.artist),
                        album: stagingTrack.album ?? (session.parameters.album.isEmpty ? nil : session.parameters.album),
                        genre: stagingTrack.genre ?? Self.extractGenre(from: session.parameters.style),
                        lyrics: session.parameters.lyrics.isEmpty ? nil : session.parameters.lyrics,
                        sessionId: session.id,
                        conversationId: session.conversationId,
                        originalPrompt: session.parameters.style,
                        generationParams: session.parameters.toGenerationParams()
                    )

                    // Copy pipeline metadata from staging track
                    track.mood = stagingTrack.mood ?? (session.parameters.mood.isEmpty ? nil : session.parameters.mood)
                    track.contentType = stagingTrack.contentType ?? (session.parameters.contentType.isEmpty ? nil : session.parameters.contentType)
                    track.topic = stagingTrack.topic ?? (session.parameters.topic.isEmpty ? nil : session.parameters.topic)
                    track.topicTags = stagingTrack.topicTags ?? (session.parameters.topicTags.isEmpty ? nil : session.parameters.topicTags)
                    track.extendedMetadata = stagingTrack.extendedMetadata

                    libraryTracks.append(track)
                    keptTrackIDs.insert(stagingTrack.id)
                    print("[SessionStore] Kept track: \(track.title) -> \(track.audioFileName)")
                } else {
                    print("[SessionStore] Warning: Source file not found: \(sourceURL.path)")
                }
            } catch {
                print("[SessionStore] Error keeping track: \(error)")
            }
        }

        // Remove only tracks that were successfully copied into the library.
        session.stagingTracks.removeAll { keptTrackIDs.contains($0.id) }
        currentSession = session
        saveSession()

        return libraryTracks
    }

    /// Generates LRC (timestamped lyrics) files for tracks that have lyrics.
    /// This runs asynchronously in the background and updates the library when complete.
    /// If generation fails for any track, the track is kept without an LRC file.
    func generateLRCForTracks(_ tracks: [Track], backend: BackendViewModel, library: LibraryStore) {
        let tracksWithLyrics = tracks.filter { $0.lyrics != nil && !($0.lyrics?.isEmpty ?? true) }
        guard !tracksWithLyrics.isEmpty else { return }

        Task {
            for track in tracksWithLyrics {
                let audioURL = track.audioURL
                let audioPath = audioURL.path

                // Build LRC output path: same directory and base name as audio, but with .lrc extension
                let lrcFileName = (track.audioFileName as NSString).deletingPathExtension + ".lrc"
                let lrcURL = FileStore.shared.audioDirectory.appendingPathComponent(lrcFileName)
                let lrcPath = lrcURL.path

                guard FileManager.default.fileExists(atPath: audioPath) else {
                    print("[SessionStore] Skipping LRC generation — audio file not found: \(audioPath)")
                    continue
                }

                do {
                    let _ = try await backend.generateLyricsTimestamps(
                        audioPath: audioPath,
                        lyrics: track.lyrics ?? "",
                        outputPath: lrcPath
                    )

                    // Update the track in the library with the LRC file reference
                    var updatedTrack = track
                    updatedTrack.lrcFileName = lrcFileName
                    library.updateTrack(updatedTrack)

                    print("[SessionStore] Generated LRC file for: \(track.title) -> \(lrcFileName)")
                } catch {
                    // Non-fatal: track is kept without LRC file
                    print("[SessionStore] LRC generation failed for \(track.title): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Deletes a single track from the current session
    func deleteTrack(_ trackId: UUID) {
        guard var session = currentSession else {
            print("[SessionStore] No current session")
            return
        }

        // Find the track
        guard let track = session.stagingTracks.first(where: { $0.id == trackId }) else {
            print("[SessionStore] Track not found: \(trackId)")
            return
        }

        // Delete the audio file
        let fileURL = track.audioURL
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
                print("[SessionStore] Deleted track file: \(track.title)")
            }
        } catch {
            print("[SessionStore] Error deleting track file: \(error)")
        }

        // Remove from session
        session.stagingTracks.removeAll { $0.id == trackId }
        currentSession = session
        saveSession()
    }

    /// Adds a staging track to the current session
    func addStagingTrack(_ track: StagingTrack) {
        guard var session = currentSession else {
            print("[SessionStore] No current session")
            return
        }

        session.stagingTracks.append(track)
        currentSession = session
        saveSession()

        print("[SessionStore] Added staging track: \(track.title)")
    }

    /// Updates a staging track in the current session
    func updateStagingTrack(_ track: StagingTrack) {
        guard var session = currentSession else {
            print("[SessionStore] No current session")
            return
        }

        if let index = session.stagingTracks.firstIndex(where: { $0.id == track.id }) {
            session.stagingTracks[index] = track
            currentSession = session
            saveSession()

            print("[SessionStore] Updated staging track: \(track.title)")
        }
    }

    // MARK: - Persistence

    /// Saves recent sessions to sessions.json
    private func saveRecentSessions() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(recentSessions)
            try data.write(to: fileStore.sessionsURL, options: .atomic)
            print("[SessionStore] Saved \(recentSessions.count) sessions")
        } catch {
            print("[SessionStore] Error saving sessions: \(error)")
        }
    }

    // MARK: - Helper Methods

    /// Returns the staging directory URL for a given session ID
    func stagingDirectory(for sessionId: UUID) -> URL {
        return fileStore.stagingDirectory.appendingPathComponent(sessionId.uuidString)
    }

    /// Cleans up old staging files (older than 30 days).
    /// Always preserves the directory belonging to the current session and
    /// any session still listed in `recentSessions`, even if it's old —
    /// otherwise a long-running unsaved session could be deleted out from
    /// under the user.
    func cleanupOldStagingFiles() {
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)

        // Build a set of session-IDs we must not delete. Staging directories
        // are named after the session UUID, so we compare by lastPathComponent.
        var protectedIDs = Set(recentSessions.map { $0.id.uuidString })
        if let current = currentSession?.id.uuidString {
            protectedIDs.insert(current)
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: fileStore.stagingDirectory,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            )

            for url in contents {
                if protectedIDs.contains(url.lastPathComponent) {
                    continue
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                if let creationDate = attributes[.creationDate] as? Date,
                   creationDate < thirtyDaysAgo {
                    try FileManager.default.removeItem(at: url)
                    print("[SessionStore] Cleaned up old staging file: \(url.lastPathComponent)")
                }
            }
        } catch {
            print("[SessionStore] Error cleaning up staging files: \(error)")
        }
    }

    // MARK: - Genre Extraction

    /// Extract a simple genre label from a style/prompt string.
    /// Checks for common genre keywords in order of specificity (multi-word first).
    static func extractGenre(from style: String) -> String? {
        let lowered = style.lowercased()
        let genreKeywords: [(keywords: [String], genre: String)] = [
            // Multi-word genres (check first)
            (["blues rock", "blues-rock"], "Blues Rock"),
            (["boom bap", "boom-bap"], "Boom Bap"),
            (["classic rock"], "Classic Rock"),
            (["indie rock", "indie-rock"], "Indie Rock"),
            (["pop punk", "pop-punk"], "Pop Punk"),
            (["synth pop", "synth-pop", "synthpop"], "Synth Pop"),
            (["electro pop", "electro-pop", "electropop"], "Electro Pop"),
            (["trip hop", "trip-hop", "triphop"], "Trip Hop / EDM"),
            (["hip hop", "hip-hop", "hiphop"], "Hip Hop"),
            // Single-word genres
            (["reggae"], "Reggae"),
            (["lullaby"], "Ballad"),
            (["ballad"], "Ballad"),
            (["blues"], "Blues"),
            (["country"], "Country"),
            (["jazz"], "Jazz"),
            (["swing"], "Swing"),
            (["soul", "r&b", "motown"], "Soul / R&B"),
            (["funk"], "Funk"),
            (["rock"], "Rock"),
            (["pop"], "Pop"),
            (["rap"], "Rap"),
            (["trap"], "Trap"),
            (["edm"], "EDM"),
            (["alternative", "grunge"], "Alternative"),
            (["folk"], "Folk"),
            (["metal"], "Metal"),
            (["punk"], "Punk"),
        ]

        for (keywords, genre) in genreKeywords {
            for keyword in keywords {
                if lowered.contains(keyword) {
                    return genre
                }
            }
        }
        return nil
    }
}
