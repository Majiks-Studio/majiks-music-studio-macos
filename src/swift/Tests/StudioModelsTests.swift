import Testing
import Foundation
@testable import MajiksMusicStudio

// MARK: - MusicParameters Tests

@Suite("MusicParameters")
struct MusicParametersTests {

    // MARK: - Default Initialization

    @Test("default init provides expected defaults")
    func defaultInit() {
        let params = MusicParameters()

        #expect(params.bpm == 88)
        #expect(params.key == "E\u{266D} minor")
        #expect(params.duration == 60)
        #expect(params.style == "Aggressive battle rap")
        #expect(params.variantCount == 1)
        #expect(params.model == "acestep-v15-turbo")
        #expect(params.lmModel == LMModel.defaultRawValueForCurrentMac)
        #expect(params.guidanceScale == 4.5)
        #expect(params.lyrics == "")
        #expect(params.artist == "")
        #expect(params.album == "")
    }

    @Test("custom init stores all values")
    func customInit() {
        let params = MusicParameters(
            bpm: 140,
            key: "A major",
            duration: 120,
            style: "Lo-fi chill",
            variantCount: 3,
            model: "acestep-v15-turbo",
            lmModel: "acestep-5Hz-lm-4B",
            guidanceScale: 7.0,
            lyrics: "Hello world",
            artist: "Test Artist",
            album: "Test Album"
        )

        #expect(params.bpm == 140)
        #expect(params.key == "A major")
        #expect(params.duration == 120)
        #expect(params.style == "Lo-fi chill")
        #expect(params.variantCount == 3)
        #expect(params.guidanceScale == 7.0)
        #expect(params.lyrics == "Hello world")
        #expect(params.artist == "Test Artist")
        #expect(params.album == "Test Album")
    }

    // MARK: - Duration Formatting

    @Test("durationFormatted formats seconds correctly")
    func durationFormatted() {
        var params = MusicParameters(duration: 65)
        #expect(params.durationFormatted == "1:05")

        params.duration = 0
        #expect(params.durationFormatted == "0:00")

        params.duration = 59
        #expect(params.durationFormatted == "0:59")

        params.duration = 120
        #expect(params.durationFormatted == "2:00")

        params.duration = 301
        #expect(params.durationFormatted == "5:01")
    }

    // MARK: - Codable (Encoding/Decoding)

    @Test("round-trip encoding and decoding preserves all fields")
    func codableRoundTrip() throws {
        let original = MusicParameters(
            bpm: 120,
            key: "C major",
            duration: 90,
            style: "Jazz fusion",
            variantCount: 2,
            model: "acestep-v15-turbo",
            lmModel: "acestep-5Hz-lm-4B",
            guidanceScale: 6.0,
            lyrics: "Some lyrics here",
            artist: "Jazz Artist",
            album: "Jazz Album"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MusicParameters.self, from: data)

        #expect(decoded == original)
    }

    @Test("decoding missing fields uses defaults")
    func decodingMissingFields() throws {
        // Simulate old session file with only a few fields
        let json = """
        {
            "bpm": 100,
            "key": "G minor",
            "duration": 45,
            "style": "Trap beat"
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(MusicParameters.self, from: data)

        #expect(decoded.bpm == 100)
        #expect(decoded.key == "G minor")
        #expect(decoded.duration == 45)
        #expect(decoded.style == "Trap beat")
        // New fields should have defaults
        #expect(decoded.variantCount == 1)
        #expect(decoded.model == "acestep-v15-turbo")
        #expect(decoded.lmModel == LMModel.defaultRawValueForCurrentMac)
        #expect(decoded.guidanceScale == 4.5)
        #expect(decoded.lyrics == "")
        #expect(decoded.artist == "")
        #expect(decoded.album == "")
    }

    @Test("decoding empty JSON uses all defaults")
    func decodingEmptyJSON() throws {
        let json = "{}"
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(MusicParameters.self, from: data)

        #expect(decoded == MusicParameters())
    }

    // MARK: - Equatable

    @Test("identical parameters are equal")
    func equatable() {
        let a = MusicParameters(bpm: 120, key: "C major")
        let b = MusicParameters(bpm: 120, key: "C major")
        #expect(a == b)
    }

    @Test("different parameters are not equal")
    func notEqual() {
        let a = MusicParameters(bpm: 120)
        let b = MusicParameters(bpm: 140)
        #expect(a != b)
    }

    // MARK: - Create-tab mode validation (Lego / Extract / Repaint / Auto)

    @Test("empty style is rejected in every mode")
    func emptyStyleRejected() {
        var params = MusicParameters(style: "   ")
        params.generationMode = .lego
        params.sourceAudioPath = "/tmp/track.wav"
        params.legoInstruction = "bass"
        #expect(params.generationValidationError() == "Please enter a style description before generating.")
    }

    @Test("lego without source audio is rejected")
    func legoMissingSource() {
        var params = MusicParameters()
        params.generationMode = .lego
        params.legoInstruction = "bass"
        #expect(params.generationValidationError()?.contains("source audio") == true)
    }

    @Test("lego without stem instruction is rejected even when source is set")
    func legoMissingInstruction() {
        var params = MusicParameters()
        params.generationMode = .lego
        params.sourceAudioPath = "/tmp/track.wav"
        params.legoInstruction = "  "
        #expect(params.generationValidationError()?.contains("what stem") == true)
    }

    @Test("lego with source and instruction is ready")
    func legoReady() {
        var params = MusicParameters()
        params.generationMode = .lego
        params.sourceAudioPath = "/tmp/track.wav"
        params.legoInstruction = "warm analog bass"
        #expect(params.generationValidationError() == nil)
    }

    @Test("extract without stems is rejected")
    func extractMissingStems() {
        var params = MusicParameters()
        params.generationMode = .extract
        params.sourceAudioPath = "/tmp/track.wav"
        #expect(params.generationValidationError()?.contains("stem") == true)
    }

    @Test("extract with source and a stem is ready")
    func extractReady() {
        var params = MusicParameters()
        params.generationMode = .extract
        params.sourceAudioPath = "/tmp/track.wav"
        params.extractStems = ["vocals"]
        #expect(params.generationValidationError() == nil)
    }

    @Test("extract does not require a style description")
    func extractSkipsStyle() {
        var params = MusicParameters(style: "")
        params.generationMode = .extract
        params.sourceAudioPath = "/tmp/track.wav"
        params.extractStems = ["drums"]
        #expect(params.generationValidationError() == nil)
    }

    @Test("repaint without source is rejected")
    func repaintMissingSource() {
        var params = MusicParameters()
        params.generationMode = .repaint
        #expect(params.generationValidationError()?.contains("source audio") == true)
    }

    @Test("repaint end at or before start is rejected")
    func repaintInvertedRange() {
        var params = MusicParameters()
        params.generationMode = .repaint
        params.sourceAudioPath = "/tmp/track.wav"
        params.repaintStart = 12
        params.repaintEnd = 12
        #expect(params.generationValidationError()?.contains("end") == true)
    }

    @Test("repaint to end of track with -1 is ready")
    func repaintToEndReady() {
        var params = MusicParameters()
        params.generationMode = .repaint
        params.sourceAudioPath = "/tmp/track.wav"
        params.repaintStart = 8
        params.repaintEnd = -1
        #expect(params.generationValidationError() == nil)
    }

    @Test("auto-complete without source is rejected")
    func autoCompleteMissingSource() {
        var params = MusicParameters()
        params.generationMode = .autoComplete
        #expect(params.generationValidationError()?.contains("source audio") == true)
    }

    @Test("continue still requires source audio")
    func continuationMissingSource() {
        var params = MusicParameters()
        params.generationMode = .continuation
        #expect(params.generationValidationError() == "Please select a source audio file for continuation mode.")
    }

    @Test("lego requires source audio")
    func legoRequiresSourceAudioFlag() {
        #expect(StudioGenerationMode.lego.requiresSourceAudio)
        #expect(StudioGenerationMode.extract.requiresSourceAudio)
        #expect(StudioGenerationMode.repaint.requiresSourceAudio)
        #expect(StudioGenerationMode.autoComplete.requiresSourceAudio)
        #expect(!StudioGenerationMode.textToMusic.requiresSourceAudio)
    }
}

// MARK: - VariantStatus Tests

@Suite("VariantStatus")
struct VariantStatusTests {

    @Test("isGenerating returns true only when generating")
    func isGenerating() {
        #expect(VariantStatus.generating(progress: 0.5).isGenerating)
        #expect(!VariantStatus.ready.isGenerating)
        #expect(!VariantStatus.queued.isGenerating)
        #expect(!VariantStatus.failed(message: "err").isGenerating)
    }

    @Test("isQueued returns true only when queued")
    func isQueued() {
        #expect(VariantStatus.queued.isQueued)
        #expect(!VariantStatus.ready.isQueued)
        #expect(!VariantStatus.generating(progress: 0.0).isQueued)
        #expect(!VariantStatus.failed(message: "err").isQueued)
    }

    @Test("isFailed returns true only when failed")
    func isFailed() {
        #expect(VariantStatus.failed(message: "err").isFailed)
        #expect(!VariantStatus.ready.isFailed)
        #expect(!VariantStatus.queued.isFailed)
        #expect(!VariantStatus.generating(progress: 0.0).isFailed)
    }
}

// MARK: - GenerationJobStatus Tests

@Suite("GenerationJobStatus")
struct GenerationJobStatusTests {

    @Test("equality for simple cases")
    func equalitySimple() {
        #expect(GenerationJobStatus.queued == .queued)
        #expect(GenerationJobStatus.completed == .completed)
        #expect(GenerationJobStatus.cancelled == .cancelled)
    }

    @Test("equality for cases with associated values")
    func equalityAssociatedValues() {
        #expect(GenerationJobStatus.generating(progress: 0.5) == .generating(progress: 0.5))
        #expect(GenerationJobStatus.generating(progress: 0.5) != .generating(progress: 0.8))
        #expect(GenerationJobStatus.failed(message: "a") == .failed(message: "a"))
        #expect(GenerationJobStatus.failed(message: "a") != .failed(message: "b"))
    }

    @Test("different cases are not equal")
    func differentCases() {
        #expect(GenerationJobStatus.queued != .completed)
        #expect(GenerationJobStatus.queued != .cancelled)
        #expect(GenerationJobStatus.generating(progress: 1.0) != .completed)
    }
}

// MARK: - ACEStepModel Tests

@Suite("ACEStepModel")
struct ACEStepModelTests {

    @Test("turbo model has correct raw value")
    func turboRawValue() {
        #expect(ACEStepModel.turbo.rawValue == "acestep-v15-turbo")
    }

    @Test("all cases are iterable")
    func allCases() {
        #expect(ACEStepModel.allCases.count >= 1)
        #expect(ACEStepModel.allCases.contains(.turbo))
    }

    @Test("display name is non-empty")
    func displayName() {
        for model in ACEStepModel.allCases {
            #expect(!model.displayName.isEmpty)
        }
    }
}

// MARK: - LMModel Tests

@Suite("LMModel")
struct LMModelTests {

    @Test("raw values match expected model identifiers")
    func rawValues() {
        #expect(LMModel.tiny.rawValue == "acestep-5Hz-lm-0.6B")
        #expect(LMModel.base.rawValue == "acestep-5Hz-lm-1.7B")
        #expect(LMModel.large.rawValue == "acestep-5Hz-lm-4B")
    }

    @Test("all three sizes are available")
    func allCases() {
        #expect(LMModel.allCases.count == 3)
    }

    @Test("display names and descriptions are non-empty")
    func descriptions() {
        for model in LMModel.allCases {
            #expect(!model.displayName.isEmpty)
            #expect(!model.description.isEmpty)
            #expect(!model.minimumRAMLabel.isEmpty)
        }
    }

    @Test("minimum RAM matches backend preflight floors")
    func minimumRAM() {
        #expect(LMModel.tiny.minimumRAMGB == 16)
        #expect(LMModel.base.minimumRAMGB == 24)
        #expect(LMModel.large.minimumRAMGB == 32)
        #expect(LMModel.tiny.minimumRAMLabel == "needs 16 GB")
        #expect(LMModel.base.minimumRAMLabel == "needs 24 GB")
        #expect(LMModel.large.minimumRAMLabel == "needs 32 GB")
    }

    @Test("recommendation follows every physical RAM boundary")
    func recommendationBoundaries() {
        let cases: [(ramGB: Int, model: LMModel)] = [
            (8, .tiny),
            (15, .tiny),
            (16, .tiny),
            (23, .tiny),
            (24, .base),
            (31, .base),
            (32, .base),
            (64, .base)
        ]

        for testCase in cases {
            #expect(
                LMModel.recommended(forPhysicalMemoryGB: testCase.ramGB) == testCase.model,
                "Expected \(testCase.model.rawValue) at \(testCase.ramGB) GB"
            )
        }
    }

    @Test("stored LM values survive decoding")
    func storedLMIsPreserved() throws {
        let json = "{\"lmModel\":\"acestep-5Hz-lm-4B\"}"
        let decoded = try JSONDecoder().decode(MusicParameters.self, from: Data(json.utf8))

        #expect(decoded.lmModel == LMModel.large.rawValue)
    }

    @Test("local chat default uses Granite below 24 GB and Qwen at 24 GB")
    func localChatRecommendationBoundaries() {
        #expect(
            LLMProvider.defaultMLXModel(forPhysicalMemoryGB: 16)
                == LLMProvider.lowMemoryMLXModel
        )
        #expect(
            LLMProvider.defaultMLXModel(forPhysicalMemoryGB: 23)
                == LLMProvider.lowMemoryMLXModel
        )
        #expect(
            LLMProvider.defaultMLXModel(forPhysicalMemoryGB: 24)
                == LLMProvider.fullMemoryMLXModel
        )
        #expect(
            LLMProvider.defaultMLXModel(forPhysicalMemoryGB: 64)
                == LLMProvider.fullMemoryMLXModel
        )
    }
}

// MARK: - StudioSession Tests

@Suite("StudioSession")
struct StudioSessionTests {

    @Test("session round-trip encoding")
    func codableRoundTrip() throws {
        let session = StudioSession(
            id: UUID(),
            name: "Test Session",
            stagingTracks: [],
            parameters: MusicParameters(),
            conversationId: nil,
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 2000)
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(StudioSession.self, from: data)

        #expect(decoded.id == session.id)
        #expect(decoded.name == session.name)
        #expect(decoded.parameters == session.parameters)
        #expect(decoded.stagingTracks.count == 0)
    }
}

// MARK: - GenerationProgress Tests

@Suite("GenerationProgress")
struct GenerationProgressTests {

    @Test("round-trip encoding")
    func codableRoundTrip() throws {
        let progress = GenerationProgress(
            id: "test-id",
            stage: "Generating",
            percent: 0.75,
            message: "Step 75/100"
        )

        let data = try JSONEncoder().encode(progress)
        let decoded = try JSONDecoder().decode(GenerationProgress.self, from: data)

        #expect(decoded.id == progress.id)
        #expect(decoded.stage == progress.stage)
        #expect(decoded.percent == progress.percent)
        #expect(decoded.message == progress.message)
    }
}
