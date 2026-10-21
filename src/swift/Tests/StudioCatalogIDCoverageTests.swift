import XCTest
@testable import MajiksMusicStudio

/// EVERY ID-NAMING PARAMETER IN THE CATALOG IS EITHER TRANSLATED OR EXEMPTED,
/// WITH A REASON — and the catalog, not a person, decides what "every" means.
///
/// # Why this exists
///
/// `RealStudioEngine.resolvingUIIDs` turns the UI's surrogate `UUID` into the
/// engine's own id for the `.catalog` escape hatch. It walks a list of param
/// NAMES, and that list started as `["trackId", "clipId"]` — which was already
/// wrong on the day it was written. A concurrent lane routed `import.audio`
/// through `.catalog` using `targetTrackId`, which is the contract's own key
/// and a perfectly correct call site, and it was refused on the real engine
/// because the resolver had never heard of it. A sweep found four such keys
/// naming existing objects (`targetTrackId`, `targetClipId`, `contextClipId`,
/// `referenceClipId`, plus `clipIdA` / `clipIdB` on `clip.crossfade.set`), and
/// one that must NEVER be translated (`newClipId`).
///
/// A hand-maintained list is exactly how that went stale, so this test derives
/// the population from `command-catalog.v2.json` and requires every member of
/// it to be classified. A new id-carrying parameter added to the catalog
/// tomorrow fails HERE, by name, rather than being silently refused at runtime
/// by an engine nobody is watching.
///
/// # What it can and cannot distinguish
///
/// This runs under `MAJIKS_ENGINE=mock`, and the mock is the thing that hid the
/// original bug — so it is worth being precise. This test does not ask the mock
/// anything. It compares two things neither of which the mock can influence:
/// the parameter names in the contract file, and the classification declared in
/// `StudioEngineIDParam`. What it CANNOT prove is that the resolver translates
/// correctly at runtime; that is
/// `StudioInstrumentRealEngineTests` / `StudioCatalogParamsRealEngineTests`,
/// under gate 7.
final class StudioCatalogIDCoverageTests: XCTestCase {

    /// A parameter that names an id. The suffix is the catalog's own convention
    /// (`trackId`, `clipIdA`, `noteIds`) and is applied to the DERIVED census
    /// rather than to a list, so it selects the population instead of asserting
    /// membership in one.
    private func namesAnID(_ parameter: String) -> Bool {
        parameter.hasSuffix("Id") || parameter.hasSuffix("Ids")
            || (parameter.hasPrefix("clipId") && parameter.count == "clipIdA".count)
    }

    private var censusOfIDParams: Set<String> {
        Set(StudioCatalogSchema.allParameterNames().filter(namesAnID))
    }

    /// The census actually walks. `noteId` exists ONLY inside `note.add`'s and
    /// `note.timing.set`'s `notes[]` array items — never as a top-level
    /// property — so a traversal that stopped at the top level cannot see it.
    ///
    /// Asserted here rather than trusted, and asserted through the SAME
    /// `allParameterNames` the coverage check below uses. `catalog_descriptions.rs`
    /// shipped a coverage assertion that counted with its own duplicate of the
    /// walk it policed, and deleting the real walk's array descent left both
    /// tests green.
    func testTheCensusDescendsIntoArrayItems() {
        let census = censusOfIDParams
        XCTAssertTrue(census.contains("noteId"),
                      "the census missed noteId, which lives only inside notes[] - "
                      + "the walk is not descending into array items")
        XCTAssertTrue(census.contains("trackId"), "the census missed a top-level id param")
        XCTAssertGreaterThan(census.count, 20,
                             "the census found almost nothing, so it is not walking the catalog")
    }

    /// THE GUARD. Every id-naming parameter the catalog declares is classified.
    func testEveryIDParamInTheCatalogIsTranslatedOrExemptedWithAReason() {
        let classified = Set(StudioEngineIDParam.trackKeys)
            .union(StudioEngineIDParam.clipKeys)
            .union(StudioEngineIDParam.notTranslated.keys)

        let unclassified = censusOfIDParams.subtracting(classified)
        XCTAssertTrue(
            unclassified.isEmpty,
            """
            these parameters name an id and `StudioEngineIDParam` says nothing about them, \
            so `RealStudioEngine.resolvingUIIDs` will forward whatever the call site put \
            there and the engine will refuse it: \(unclassified.sorted()). \
            Put each one in `trackKeys`, `clipKeys`, or `notTranslated` with a reason.
            """)

        // …and nothing is classified that the catalog does not have. A stale
        // entry is harmless at runtime but it is a claim about the contract
        // that stopped being true, which is how the original list rotted.
        let phantom = classified.subtracting(censusOfIDParams)
        XCTAssertTrue(phantom.isEmpty,
                      "these are classified but no catalog command declares them: \(phantom.sorted())")
    }

    /// A key cannot be in two classes at once — the resolver would look it up
    /// in whichever list it walked first.
    func testNoKeyIsClassifiedTwice() {
        let track = Set(StudioEngineIDParam.trackKeys)
        let clip = Set(StudioEngineIDParam.clipKeys)
        let exempt = Set(StudioEngineIDParam.notTranslated.keys)
        XCTAssertTrue(track.isDisjoint(with: clip), "\(track.intersection(clip)) is both")
        XCTAssertTrue(track.isDisjoint(with: exempt), "\(track.intersection(exempt)) is both")
        XCTAssertTrue(clip.isDisjoint(with: exempt), "\(clip.intersection(exempt)) is both")
        XCTAssertEqual(StudioEngineIDParam.uiMinted.count,
                       StudioEngineIDParam.trackKeys.count + StudioEngineIDParam.clipKeys.count,
                       "uiMinted is not the two translated lists")
    }

    /// An exemption has to SAY something. "" or "n/a" is not a reason, and an
    /// exemption nobody justified is how `newClipId` would be "completed" into
    /// the translated list by someone tidying up.
    func testEveryExemptionCarriesARealReason() {
        for (key, reason) in StudioEngineIDParam.notTranslated {
            XCTAssertGreaterThanOrEqual(
                reason.count, 30,
                "\(key)'s exemption reason is too short to explain anything: \"\(reason)\"")
            XCTAssertFalse(reason.lowercased().contains(key.lowercased()) && reason.count < 45,
                           "\(key)'s reason mostly restates its own name: \"\(reason)\"")
        }
    }

    /// ⚠️ The asymmetry, pinned. `newClipId` is UI-MINTED for a clip that does
    /// not exist yet, so there is nothing to resolve; translating it would make
    /// `clip.duplicate` and `clip.split` throw "that clip is no longer in the
    /// project" and both gestures would stop working. It looks exactly like the
    /// keys around it, which is why it needs a test and not only a comment.
    func testNewClipIDIsDeliberatelyNotTranslated() {
        XCTAssertFalse(StudioEngineIDParam.uiMinted.contains("newClipId"),
                       "newClipId was added to the translated list - clip.duplicate and "
                       + "clip.split mint it for a clip the engine has never seen, so there "
                       + "is nothing to look up and both gestures break")
        XCTAssertNotNil(StudioEngineIDParam.notTranslated["newClipId"],
                        "newClipId lost its exemption reason")
    }

    /// The four keys the original two-name list missed, named individually so a
    /// regression says which one came back.
    func testTheKeysTheOriginalListMissedAreTranslated() {
        for key in ["targetTrackId"] {
            XCTAssertTrue(StudioEngineIDParam.trackKeys.contains(key),
                          "\(key) names an existing TRACK and is not resolved through uuidTrack")
        }
        for key in ["targetClipId", "contextClipId", "referenceClipId", "clipIdA", "clipIdB"] {
            XCTAssertTrue(StudioEngineIDParam.clipKeys.contains(key),
                          "\(key) names an existing CLIP and is not resolved through uuidClip")
        }
    }
}
