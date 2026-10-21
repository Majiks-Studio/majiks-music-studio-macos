import Testing
import Foundation
import AVFoundation
@testable import MajiksMusicStudio

// MARK: - StemSessionLibraryExport Tests (hermetic: temp audio directory)

@Suite("Stem session library export")
struct StemSessionLibraryExportTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemLibraryExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a short stereo float32 WAV (scoped writer so the file closes
    /// before it is read back).
    private func writeTinyWAV(to url: URL, seconds: Double = 0.25) throws {
        let sampleRate = 44100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let frames = AVAudioFrameCount((seconds * sampleRate).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            for n in 0..<Int(frames) {
                buffer.floatChannelData![channel][n] = Float(0.25 * sin(2.0 * .pi * 441 * Double(n) / sampleRate))
            }
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    /// ISO-8601 truncates sub-second precision, so fixtures use whole seconds.
    private func wholeSecondDate(_ interval: TimeInterval) -> Date {
        Date(timeIntervalSince1970: interval.rounded())
    }

    private func makeDocument() -> StemSessionDocument {
        let created = wholeSecondDate(1_720_000_000)
        var params = MusicParameters()
        params.generationMode = .extract
        params.extractStems = ["vocals"]
        params.model = "acestep-v15-base"

        return StemSessionDocument(
            name: "Mix Night",
            createdAt: created,
            stems: [
                SessionStem(
                    fileName: "S/vox.wav",
                    displayName: "Vocals",
                    gainDB: -3,
                    pan: -0.4,
                    sourceTrackId: UUID(),
                    generationParams: GenerationParams(from: params, timestamp: created)
                ),
                SessionStem(fileName: "S/drums.wav", displayName: "Drums", gainDB: 1.5, muted: true, pan: 0.2)
            ],
            masterGainDB: -1,
            originOps: [
                StemOriginOp(timestamp: created, action: StemOriginOp.actionCreatedFromExtract, detail: "Extracted vocals from \"Song\""),
                StemOriginOp(timestamp: created, action: StemOriginOp.actionBounced, detail: "Bounced to Mix Night.wav")
            ]
        )
    }

    @Test("copies the bounce into Audio/StemBounces and builds a Track carrying full provenance")
    func makeTrackCarriesProvenance() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let audioDir = root.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

        let bounceURL = root.appendingPathComponent("Mix Night.wav")
        try writeTinyWAV(to: bounceURL, seconds: 0.25)

        let doc = makeDocument()
        let now = wholeSecondDate(1_720_001_000)
        let track = try StemSessionLibraryExport.makeTrack(
            from: doc,
            bounceURL: bounceURL,
            audioDirectory: audioDir,
            now: now
        )

        // File landed inside the audio tree under StemBounces/, and the
        // track's relative path points at it (Track.audioFileName convention).
        #expect(track.audioFileName.hasPrefix("StemBounces/"))
        #expect(!track.audioFileName.contains(" "))   // sanitized name
        let copied = audioDir.appendingPathComponent(track.audioFileName)
        #expect(FileManager.default.fileExists(atPath: copied.path))
        // The original stays where the user saved it.
        #expect(FileManager.default.fileExists(atPath: bounceURL.path))

        #expect(track.title == "Mix Night")
        #expect(track.caption.contains("2 stems"))
        #expect(track.createdAt == now)
        #expect(abs(track.duration - 0.25) < 0.001)

        // Provenance chain: session identity…
        let metadata = try #require(track.extendedMetadata)
        #expect(metadata[StemSessionLibraryExport.metadataSessionIdKey] == doc.id.uuidString)
        #expect(metadata[StemSessionLibraryExport.metadataSessionNameKey] == "Mix Night")
        #expect(metadata[StemSessionLibraryExport.metadataStemCountKey] == "2")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // …the append-only origin log survives verbatim…
        let opsJSON = try #require(metadata[StemSessionLibraryExport.metadataOriginOpsKey])
        let ops = try decoder.decode([StemOriginOp].self, from: Data(opsJSON.utf8))
        #expect(ops == doc.originOps)

        // …and every stem's mix position + generation params (the seed).
        let stemsJSON = try #require(metadata[StemSessionLibraryExport.metadataStemsKey])
        let stems = try decoder.decode([StemProvenance].self, from: Data(stemsJSON.utf8))
        #expect(stems == doc.stems.map { StemProvenance(stem: $0) })
        #expect(stems[0].generationParams?.model == "acestep-v15-base")
        #expect(stems[0].sourceTrackId == doc.stems[0].sourceTrackId)
        #expect(stems[0].pan == -0.4)
        #expect(stems[1].muted)
    }

    @Test("throws when the bounced file is missing")
    func missingBounceThrows() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let audioDir = root.appendingPathComponent("Audio", isDirectory: true)

        #expect(throws: StemSessionLibraryExportError.self) {
            _ = try StemSessionLibraryExport.makeTrack(
                from: makeDocument(),
                bounceURL: root.appendingPathComponent("nope.wav"),
                audioDirectory: audioDir
            )
        }
    }

    @Test("repeated exports of the same session never collide")
    func repeatedExportsUnique() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let audioDir = root.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

        let bounceURL = root.appendingPathComponent("Mix Night.wav")
        try writeTinyWAV(to: bounceURL)

        let doc = makeDocument()
        let first = try StemSessionLibraryExport.makeTrack(from: doc, bounceURL: bounceURL, audioDirectory: audioDir)
        let second = try StemSessionLibraryExport.makeTrack(from: doc, bounceURL: bounceURL, audioDirectory: audioDir)

        #expect(first.audioFileName != second.audioFileName)
        #expect(FileManager.default.fileExists(atPath: audioDir.appendingPathComponent(first.audioFileName).path))
        #expect(FileManager.default.fileExists(atPath: audioDir.appendingPathComponent(second.audioFileName).path))
    }
}
