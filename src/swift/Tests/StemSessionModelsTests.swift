import Testing
import Foundation
@testable import MajiksMusicStudio

// MARK: - StemSessionDocument Codable Tests

@Suite("StemSessionDocument Codable")
struct StemSessionDocumentCodableTests {

    /// ISO-8601 truncates sub-second precision, so fixtures use whole-second dates.
    private func wholeSecondDate(_ interval: TimeInterval) -> Date {
        Date(timeIntervalSince1970: interval.rounded())
    }

    private func makeFullDocument() -> StemSessionDocument {
        let created = wholeSecondDate(1_720_000_000)
        let updated = wholeSecondDate(1_720_000_500)
        let sourceTrackId = UUID()

        var params = MusicParameters()
        params.generationMode = .extract
        params.extractStems = ["vocals", "drums"]
        params.sourceAudioPath = "/tmp/source.wav"
        params.model = "acestep-v15-base"
        let generationParams = GenerationParams(from: params, timestamp: created)

        return StemSessionDocument(
            id: UUID(),
            name: "Test Session",
            createdAt: created,
            updatedAt: updated,
            stems: [
                SessionStem(
                    fileName: "ABC/1a2b3c4d_vocals.wav",
                    displayName: "Vocals",
                    gainDB: -4.5,
                    muted: false,
                    solo: true,
                    pan: -0.25,
                    sourceTrackId: sourceTrackId,
                    generationParams: generationParams
                ),
                SessionStem(
                    fileName: "ABC/5e6f7a8b_drums.wav",
                    displayName: "Drums",
                    gainDB: 3.0,
                    muted: true,
                    solo: false,
                    pan: 0.5
                )
            ],
            masterGainDB: -6.0,
            originOps: [
                StemOriginOp(
                    timestamp: created,
                    action: StemOriginOp.actionCreatedFromExtract,
                    detail: "Extracted vocals, drums from \"Source\""
                ),
                StemOriginOp(
                    timestamp: updated,
                    action: StemOriginOp.actionAddedExtractedStem,
                    detail: "Added \"Vocals\""
                )
            ]
        )
    }

    @Test("round-trip preserves the full document including provenance seed")
    func roundTrip() throws {
        let original = makeFullDocument()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StemSessionDocument.self, from: data)

        #expect(decoded == original)
        // Spot-check the provenance seed survived verbatim.
        #expect(decoded.stems[0].generationParams?.model == "acestep-v15-base")
        #expect(decoded.stems[0].sourceTrackId == original.stems[0].sourceTrackId)
        #expect(decoded.stems[0].pan == -0.25)
        #expect(decoded.stems[1].pan == 0.5)
        #expect(decoded.originOps.count == 2)
        #expect(decoded.originOps[0].action == StemOriginOp.actionCreatedFromExtract)
    }

    @Test("decoding minimal JSON applies defaults (forward compatibility)")
    func minimalDecoding() throws {
        let json = """
        {
            "id": "11111111-2222-3333-4444-555555555555",
            "name": "Old Session",
            "stems": [
                { "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "fileName": "X/stem.wav" }
            ]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(StemSessionDocument.self, from: Data(json.utf8))

        #expect(doc.name == "Old Session")
        #expect(doc.masterGainDB == 0)
        #expect(doc.originOps.isEmpty)
        #expect(doc.stems.count == 1)
        #expect(doc.stems[0].displayName == "Stem")
        #expect(doc.stems[0].gainDB == 0)
        #expect(doc.stems[0].muted == false)
        #expect(doc.stems[0].solo == false)
        #expect(doc.stems[0].pan == 0)   // pre-pan documents migrate to center
        #expect(doc.stems[0].sourceTrackId == nil)
        #expect(doc.stems[0].generationParams == nil)
    }

    @Test("hasSolo reflects the solo set")
    func hasSolo() {
        var doc = makeFullDocument()
        #expect(doc.hasSolo)
        doc.stems[0].solo = false
        #expect(!doc.hasSolo)
    }
}

// MARK: - StemMix Gain Math Tests

@Suite("StemMix gain resolution")
struct StemMixTests {

    @Test("dB to linear conversion")
    func dbToLinear() {
        #expect(StemMix.linearGain(fromDB: 0) == 1.0)
        #expect(abs(StemMix.linearGain(fromDB: -6) - 0.5012) < 0.001)
        #expect(abs(StemMix.linearGain(fromDB: 6) - 1.9953) < 0.001)
        #expect(abs(StemMix.linearGain(fromDB: 12) - 3.9811) < 0.001)
        // Slider floor maps to true silence.
        #expect(StemMix.linearGain(fromDB: -60) == 0)
        #expect(StemMix.linearGain(fromDB: -100) == 0)
    }

    @Test(
        "effective mute matrix (mute wins; any solo mutes non-soloed stems)",
        arguments: [
            // (muted, solo, anySolo, expectedMuted)
            (false, false, false, false),  // plain stem, nothing soloed
            (true, false, false, true),    // muted stem
            (false, false, true, true),    // someone else soloed → implicitly muted
            (false, true, true, false),    // soloed stem plays
            (true, true, true, true),      // muted AND soloed → mute wins
            (true, true, false, true)      // (degenerate) mute wins regardless
        ]
    )
    func effectiveMuteMatrix(entry: (muted: Bool, solo: Bool, anySolo: Bool, expected: Bool)) {
        #expect(
            StemMix.isEffectivelyMuted(muted: entry.muted, solo: entry.solo, anySolo: entry.anySolo)
                == entry.expected
        )
    }

    @Test("effective linear gain honors mute state and dB value")
    func effectiveLinearGain() {
        // Unmuted, no solo anywhere: dB curve applies.
        #expect(abs(StemMix.effectiveLinearGain(gainDB: -6, muted: false, solo: false, anySolo: false) - 0.5012) < 0.001)
        // Muted → 0 regardless of gain.
        #expect(StemMix.effectiveLinearGain(gainDB: 6, muted: true, solo: false, anySolo: false) == 0)
        // Solo elsewhere → 0.
        #expect(StemMix.effectiveLinearGain(gainDB: 0, muted: false, solo: false, anySolo: true) == 0)
        // Soloed → plays at its gain.
        #expect(abs(StemMix.effectiveLinearGain(gainDB: 6, muted: false, solo: true, anySolo: true) - 1.9953) < 0.001)
        // Floor → hard 0 even when soloed.
        #expect(StemMix.effectiveLinearGain(gainDB: -60, muted: false, solo: true, anySolo: true) == 0)
    }

    @Test("whole-document gain resolution with a solo set")
    func documentResolution() {
        let a = SessionStem(fileName: "a.wav", displayName: "A", gainDB: 0)
        let b = SessionStem(fileName: "b.wav", displayName: "B", gainDB: -6, muted: true)
        let c = SessionStem(fileName: "c.wav", displayName: "C", gainDB: 6, solo: true)
        var doc = StemSessionDocument(name: "T", stems: [a, b, c])

        // With C soloed: A implicitly muted, B muted, C plays at +6 dB.
        var gains = StemMix.effectiveLinearGains(for: doc)
        #expect(gains[a.id] == 0)
        #expect(gains[b.id] == 0)
        #expect(abs((gains[c.id] ?? 0) - 1.9953) < 0.001)

        // Solo cleared: A plays at unity, B still muted, C plays at +6 dB.
        doc.stems[2].solo = false
        gains = StemMix.effectiveLinearGains(for: doc)
        #expect(gains[a.id] == 1.0)
        #expect(gains[b.id] == 0)
        #expect(abs((gains[c.id] ?? 0) - 1.9953) < 0.001)
    }

    @Test("dB label formatting")
    func formatDB() {
        #expect(StemMix.formatDB(0) == "0.0 dB")
        #expect(StemMix.formatDB(-6) == "-6.0 dB")
        #expect(StemMix.formatDB(3.5) == "+3.5 dB")
        #expect(StemMix.formatDB(-60) == "-∞ dB")
        #expect(StemMix.formatDB(-75) == "-∞ dB")
    }

    @Test("pan label formatting")
    func formatPan() {
        #expect(StemMix.formatPan(0) == "C")
        #expect(StemMix.formatPan(-1) == "L100")
        #expect(StemMix.formatPan(1) == "R100")
        #expect(StemMix.formatPan(-0.64) == "L64")
        #expect(StemMix.formatPan(0.25) == "R25")
        #expect(StemMix.formatPan(-0.004) == "C")   // rounds to center
        #expect(StemMix.formatPan(2) == "R100")     // clamped
        #expect(StemMix.formatPan(-2) == "L100")    // clamped
    }

    @Test("meter fraction maps linear amplitude onto the −60…0 dBFS axis")
    func meterFraction() {
        #expect(StemMix.meterFraction(fromLinear: 0) == 0)
        #expect(StemMix.meterFraction(fromLinear: 1.0) == 1.0)          // 0 dBFS
        #expect(StemMix.meterFraction(fromLinear: 2.0) == 1.0)          // clipping pins to 1
        // −6 dB → 54/60 of the axis.
        let minus6 = Float(pow(10.0, -6.0 / 20.0))
        #expect(abs(StemMix.meterFraction(fromLinear: minus6) - 0.9) < 0.001)
        // −60 dB floor → 0; below floor clamps.
        #expect(abs(StemMix.meterFraction(fromLinear: 0.001)) < 0.001)
        #expect(StemMix.meterFraction(fromLinear: 0.0001) == 0)
    }
}
