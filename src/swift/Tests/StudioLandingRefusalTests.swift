import Testing
import Foundation
@testable import MajiksMusicStudio

// When "Open in Studio" cannot separate, the user has to be TOLD.
//
// The engine now refuses honestly instead of substituting a test fixture whose
// stems screech when soloed, and its refusal carries the fix ("... -m pip
// install demucs"). That refusal was reaching `StudioViewModel.landingError`
// and stopping there: NOTHING in the app read the property, so a failed landing
// looked exactly like a landing that never started -- the progress overlay
// vanished and the arrangement was unchanged. An honest refusal nobody can see
// is still silent degradation, which is why `StudioRootView` now presents it.
//
// These assert the model half: the engine's own words survive to the property
// the view presents, unedited, and a stale one never outlives its attempt.
@MainActor
@Suite("Open in Studio refusals reach the user")
struct StudioLandingRefusalTests {

    /// The preview engine's own refusal, spelled out here rather than read back
    /// from the engine, so a reworded engine message has to be reckoned with
    /// instead of silently agreeing with itself.
    private static let previewRefusal =
        "Open in Studio runs on the on-device engine (this is the preview engine)."

    private func request() -> StudioLandingRequest {
        StudioLandingRequest(
            sourceAudioPath: "/tmp/no-such-song.wav",
            prompt: "a song",
            declaredBPM: nil,
            key: nil,
            sectionTags: [],
            seed: nil,
            genModel: nil,
            projectName: "Refused"
        )
    }

    @Test("a refused landing reaches landingError with the engine's own words")
    func refusalReachesTheModelVerbatim() async {
        let model = StudioViewModel(engine: StudioMockEngine())
        #expect(model.landingError == nil, "nothing to report before a landing")

        await model.land(request())

        #expect(model.landing == false, "the progress state must clear")
        #expect(
            model.landingError == Self.previewRefusal,
            "the refusal must arrive unedited (got: \(model.landingError ?? "nil"))"
        )
    }

    @Test("a refused landing never leaves the user with nothing")
    func refusalIsAlwaysNonEmpty() async {
        let model = StudioViewModel(engine: StudioMockEngine())
        await model.land(request())
        let shown = model.landingError ?? ""
        #expect(shown.count > 20, "a one-word failure is not an explanation: '\(shown)'")
    }

    @Test("a stale refusal does not outlive the attempt that produced it")
    func staleRefusalIsCleared() async {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.landingError = "a refusal left over from an earlier attempt"

        await model.land(request())

        #expect(
            model.landingError == Self.previewRefusal,
            "each landing reports its own outcome, not the previous one's"
        )
    }
}
