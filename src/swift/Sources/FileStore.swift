import Foundation

final class FileStore: @unchecked Sendable {
    static let shared = FileStore()

    /// UserDefaults key for custom library path
    static let libraryPathKey = "majik_custom_library_path"

    /// Lock for thread-safe property access during relocation
    private let lock = NSLock()

    /// The default Application Support path
    static var defaultBaseDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("MajiksMusicStudio", isDirectory: true)
    }

    /// The active base directory (custom or default)
    private(set) var baseDirectory: URL
    private(set) var appSupportDirectory: URL
    private(set) var audioDirectory: URL
    private(set) var libraryURL: URL
    private(set) var stagingDirectory: URL
    private(set) var sessionsURL: URL
    private(set) var artworkDirectory: URL
    private(set) var stemSessionsURL: URL
    private(set) var stemSessionsDirectory: URL

    /// Whether a custom library location is configured
    var isUsingCustomLocation: Bool {
        UserDefaults.standard.string(forKey: Self.libraryPathKey) != nil
    }

    /// Set to true at init if a custom library path is configured but the directory is missing (e.g. external drive disconnected).
    /// The app should check this on startup and show a user-facing alert.
    private(set) var customPathMissing = false
    private(set) var missingCustomPath: String?

    private init() {
        // Check for a custom library path in UserDefaults
        let base: URL
        if let customPath = UserDefaults.standard.string(forKey: Self.libraryPathKey) {
            if FileManager.default.fileExists(atPath: customPath) {
                base = URL(fileURLWithPath: customPath, isDirectory: true)
                print("[FileStore] Using custom library location: \(customPath)")
            } else {
                // Custom path configured but doesn't exist (drive disconnected?)
                base = Self.defaultBaseDirectory
                customPathMissing = true
                missingCustomPath = customPath
                print("[FileStore] WARNING: Custom library path not found: \(customPath) — falling back to default")
            }
        } else {
            base = Self.defaultBaseDirectory
        }

        baseDirectory = base
        appSupportDirectory = base
        audioDirectory = base.appendingPathComponent("Audio", isDirectory: true)
        libraryURL = base.appendingPathComponent("library.json")
        stagingDirectory = audioDirectory.appendingPathComponent("staging", isDirectory: true)
        sessionsURL = base.appendingPathComponent("sessions.json")
        artworkDirectory = base.appendingPathComponent("Artwork", isDirectory: true)
        stemSessionsURL = base.appendingPathComponent("stem_sessions.json")
        stemSessionsDirectory = base.appendingPathComponent("StemSessions", isDirectory: true)

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: stemSessionsDirectory, withIntermediateDirectories: true)
        } catch {
            print("[FileStore] Error creating directories: \(error)")
            // Continue anyway; UI will show empty library.
        }
    }

    // MARK: - Library Relocation

    /// Moves the library to a new location and updates the stored path.
    /// - Parameter newBase: The new base directory URL
    func relocateLibrary(to newBase: URL) throws {
        let fileManager = FileManager.default

        // Guard: same-path relocation is a no-op
        lock.lock()
        let currentBase = baseDirectory
        let currentAudio = audioDirectory
        let currentArtwork = artworkDirectory
        let currentStemSessions = stemSessionsDirectory
        lock.unlock()

        if newBase.path == currentBase.path {
            print("[FileStore] Relocation skipped: destination is same as current location")
            return
        }

        // Pre-flight: check destination is writable
        try fileManager.createDirectory(at: newBase, withIntermediateDirectories: true)
        let testFile = newBase.appendingPathComponent(".majiks_write_test")
        do {
            try Data().write(to: testFile)
            try fileManager.removeItem(at: testFile)
        } catch {
            throw NSError(domain: "FileStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Destination is not writable: \(newBase.path)"
            ])
        }

        let newAudio = newBase.appendingPathComponent("Audio", isDirectory: true)
        let newArtwork = newBase.appendingPathComponent("Artwork", isDirectory: true)
        let newStemSessions = newBase.appendingPathComponent("StemSessions", isDirectory: true)

        // Move Audio directory
        if fileManager.fileExists(atPath: currentAudio.path) {
            if fileManager.fileExists(atPath: newAudio.path) {
                // Merge: move contents into existing directory
                if let contents = try? fileManager.contentsOfDirectory(at: currentAudio, includingPropertiesForKeys: nil) {
                    for item in contents {
                        let dest = newAudio.appendingPathComponent(item.lastPathComponent)
                        if !fileManager.fileExists(atPath: dest.path) {
                            try fileManager.moveItem(at: item, to: dest)
                        }
                    }
                }
            } else {
                try fileManager.moveItem(at: currentAudio, to: newAudio)
            }
        }

        // Move Artwork directory
        if fileManager.fileExists(atPath: currentArtwork.path) {
            if !fileManager.fileExists(atPath: newArtwork.path) {
                try fileManager.moveItem(at: currentArtwork, to: newArtwork)
            }
        }

        // Move StemSessions directory
        if fileManager.fileExists(atPath: currentStemSessions.path) {
            if !fileManager.fileExists(atPath: newStemSessions.path) {
                try fileManager.moveItem(at: currentStemSessions, to: newStemSessions)
            }
        }

        // Copy metadata files, then delete originals after all copies succeed
        let metadataFiles = ["library.json", "sessions.json", "stem_sessions.json", "artist_metadata.json", "album_metadata.json"]
        var copiedSources: [URL] = []
        for filename in metadataFiles {
            let source = currentBase.appendingPathComponent(filename)
            let dest = newBase.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: source.path) {
                if fileManager.fileExists(atPath: dest.path) {
                    try fileManager.removeItem(at: dest)
                }
                try fileManager.copyItem(at: source, to: dest)
                copiedSources.append(source)
            }
        }
        // All copies succeeded — clean up originals
        for source in copiedSources {
            try? fileManager.removeItem(at: source)
        }

        // Update UserDefaults and in-memory paths atomically
        lock.lock()
        if newBase.path == Self.defaultBaseDirectory.path {
            UserDefaults.standard.removeObject(forKey: Self.libraryPathKey)
        } else {
            UserDefaults.standard.set(newBase.path, forKey: Self.libraryPathKey)
        }
        baseDirectory = newBase
        appSupportDirectory = newBase
        audioDirectory = newAudio
        libraryURL = newBase.appendingPathComponent("library.json")
        stagingDirectory = newAudio.appendingPathComponent("staging", isDirectory: true)
        sessionsURL = newBase.appendingPathComponent("sessions.json")
        artworkDirectory = newArtwork
        stemSessionsURL = newBase.appendingPathComponent("stem_sessions.json")
        stemSessionsDirectory = newStemSessions
        customPathMissing = false
        missingCustomPath = nil
        lock.unlock()

        // Ensure staging + stem session directories exist at new location
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stemSessionsDirectory, withIntermediateDirectories: true)

        print("[FileStore] Library relocated to: \(newBase.path)")
    }

    /// Resets the library location to the default Application Support path.
    /// Does NOT move files back - use relocateLibrary() for that.
    func resetToDefaultLocation() {
        lock.lock()
        UserDefaults.standard.removeObject(forKey: Self.libraryPathKey)
        let base = Self.defaultBaseDirectory
        baseDirectory = base
        appSupportDirectory = base
        audioDirectory = base.appendingPathComponent("Audio", isDirectory: true)
        libraryURL = base.appendingPathComponent("library.json")
        stagingDirectory = audioDirectory.appendingPathComponent("staging", isDirectory: true)
        sessionsURL = base.appendingPathComponent("sessions.json")
        artworkDirectory = base.appendingPathComponent("Artwork", isDirectory: true)
        stemSessionsURL = base.appendingPathComponent("stem_sessions.json")
        stemSessionsDirectory = base.appendingPathComponent("StemSessions", isDirectory: true)
        customPathMissing = false
        missingCustomPath = nil
        lock.unlock()
        print("[FileStore] Library location reset to default")
    }

    // MARK: - Staging Directory Management

    /// Creates a staging session directory for a specific session ID
    /// - Parameter id: The UUID of the generation session
    /// - Returns: URL of the created staging session directory
    func createStagingSessionDirectory(id: UUID) -> URL {
        let sessionDirectory = stagingDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
            print("[FileStore] Created staging directory: \(id.uuidString)")
        } catch {
            print("[FileStore] ERROR creating staging directory: \(error)")
            // Return URL anyway; caller can handle errors when writing files
        }

        return sessionDirectory
    }

    /// Cleans up a staging session directory and all its contents
    /// - Parameter id: The UUID of the generation session to clean up
    func cleanupStagingDirectory(id: UUID) {
        let sessionDirectory = stagingDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        let fileManager = FileManager.default

        do {
            try fileManager.removeItem(at: sessionDirectory)
        } catch {
            print("[FileStore] Error cleaning up staging directory: \(error)")
            // Continue anyway; directory may not exist or already be deleted
        }
    }

    // MARK: - Audio File Operations

    /// Copies an audio file to a new unique path so copies are independent.
    /// - Parameter sourceFileName: The relative filename within the audio directory
    /// - Returns: The new filename (relative to audioDirectory)
    func copyAudioFile(from sourceFileName: String) throws -> String {
        let sourceURL = audioDirectory.appendingPathComponent(sourceFileName)
        let ext = sourceURL.pathExtension
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let newFileName = "\(baseName)_copy_\(UUID().uuidString.prefix(8)).\(ext)"
        let destURL = audioDirectory.appendingPathComponent(newFileName)
        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        return newFileName
    }

}
