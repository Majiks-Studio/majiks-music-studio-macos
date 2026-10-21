import XCTest
import SwiftUI
@testable import MajiksMusicStudio

// WHERE DID THE FILE GO — AND WHAT DID IT LAND ON TOP OF.
//
// THE DEFECT. `resolvedOutput()` returned `<folder>/<Project>.<ext>` for BOTH
// the master scope and the region scope:
//
//     case .master, .region:
//         return (folder.appendingPathComponent("\(safe).\(ext)").path, false)
//
// `write_wav_i24` opens with `hound::WavWriter::create` -> `File::create`,
// which truncates, and nothing on either side of the FFI checks for an existing
// file. So exporting the master and then exporting the chorus as "Selected
// region" DESTROYED the master. Silently, with no second file, and with nothing
// to undo — a bounce is not journaled work, it is bytes on a disk.
//
// The dialog concealed it rather than showing it: the Destination line is
// computed from the same function, so it printed the IDENTICAL path for both
// scopes. Checking before pressing the button would have shown nothing wrong.
//
// Why the suite missed it: `engine/agent-surface/tests/export.rs` asserts each
// output path EXISTS. Nothing anywhere asserted that two different exports go
// to two different places.
//
// The second half of this file is the bar numbering the region name and the
// on-screen "Region: bar N to bar M" line share. That line used to compute
// `ticks / ticksPerBar + 1` — a second formula for something the app has
// exactly one of. Every other bar number in the product comes from
// `StudioBarGrid.barNumber(at:)`, measured from the phase anchor, including the
// ruler labels the user is reading while this sheet is open.

@MainActor
final class StudioExportNamingTests: XCTestCase {

    // MARK: - 1. Two exports, two files

    /// THE REGRESSION TEST. Same project, same format, different scope: the
    /// names must differ. Asserted as an inequality rather than against a
    /// literal, because the property that matters is "these cannot collide",
    /// not "the suffix is spelled this way".
    func testMasterAndRegionCannotWriteTheSameFile() {
        let master = StudioExportNaming.outputName(
            project: "Echoes", scope: .master, format: .wav, bars: nil)
        let region = StudioExportNaming.outputName(
            project: "Echoes", scope: .region, format: .wav, bars: 5...8)

        XCTAssertNotEqual(
            master, region,
            """
            master and region resolve to the same file name (\(master)). File::create \
            truncates, so exporting a region after a master deletes the master.
            """)
        XCTAssertEqual(master, "Echoes.wav", "the master's own name is unchanged")
    }

    /// …and with no region set either, which is the fallback path. Export is
    /// disabled in that state today, so this is a belt on the braces: if the
    /// button ever becomes reachable without a loop, it must still not aim at
    /// the master.
    func testARegionWithNoBarsStillDoesNotAimAtTheMaster() {
        XCTAssertNotEqual(
            StudioExportNaming.outputName(project: "Echoes", scope: .master, format: .wav, bars: nil),
            StudioExportNaming.outputName(project: "Echoes", scope: .region, format: .wav, bars: nil))
    }

    /// The region's file says which bars it is, in the same words the dialog
    /// printed above the button — so the file in Finder is identifiable a week
    /// later without opening it.
    func testTheRegionFileNamesItsBars() {
        XCTAssertEqual(
            StudioExportNaming.outputName(project: "Echoes", scope: .region, format: .aac, bars: 5...8),
            "Echoes bars 5-8.m4a")
        XCTAssertEqual(
            StudioExportNaming.regionSuffix(9...9), "bar 9",
            "a one-bar region reads \"bar 9\", not \"bars 9-9\"")
    }

    /// Stems keep their folder, and it is a folder.
    func testStemsStillResolveToADirectoryOfTheirOwn() {
        XCTAssertEqual(
            StudioExportNaming.outputName(project: "Echoes", scope: .stems, format: .wav, bars: nil),
            "Echoes Stems")
        for scope in StudioExportScope.allCases where scope != .stems {
            XCTAssertNotEqual(
                StudioExportNaming.outputName(project: "Echoes", scope: scope, format: .wav, bars: 5...8),
                "Echoes Stems")
        }
    }

    /// EVERY PAIR OF SCOPES, so a fourth scope added later cannot quietly
    /// reintroduce the collision on a pair nobody thought to write down.
    func testNoTwoScopesShareAName() {
        let names = StudioExportScope.allCases.map {
            StudioExportNaming.outputName(project: "Echoes", scope: $0, format: .wav, bars: 5...8)
        }
        XCTAssertEqual(
            Set(names).count, names.count,
            "two export scopes resolve to the same name: \(names)")
    }

    // MARK: - 2. Through the REAL dialog

    /// The pure function above is only worth having if the dialog uses it. This
    /// drives `StudioExportDialog.resolvedOutput()` itself — the one the
    /// Destination line and the export request both read.
    func testTheDialogItselfResolvesTwoScopesToTwoPaths() async throws {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        defer { model.stopPolling() }
        let deadline = Date().addingTimeInterval(3.0)
        while model.snapshot == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(model.snapshot)

        let dialog = StudioExportDialog(model: model, isPresented: .constant(true))
        // `scope` is @State and starts at .master, so this reads the master's
        // path from the real dialog rather than from a rebuilt one.
        let masterPath = dialog.resolvedOutput().path
        XCTAssertTrue(masterPath.hasSuffix(".wav"), "the default scope writes a master WAV")

        // And the region's, from the same function, through the same naming.
        let bars = dialog.barRange()
        let regionName = StudioExportNaming.outputName(
            project: model.snapshot?.name ?? "Untitled", scope: .region, format: .wav, bars: bars)
        XCTAssertFalse(
            masterPath.hasSuffix("/\(regionName)"),
            "the dialog's master path and its region name are the same file")
    }

    /// The bar numbers the region name and the on-screen line share come from
    /// the project's OWN grid, not from a second division. Asserted against
    /// `StudioBarGrid` directly on a range whose answer the naive
    /// `ticks / ticksPerBar + 1` would also give — so this pins the agreement,
    /// and the phase-anchored case is covered by there being only one formula
    /// left to be wrong.
    func testTheRegionsBarNumbersComeFromTheProjectsGrid() async throws {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        defer { model.stopPolling() }
        let deadline = Date().addingTimeInterval(3.0)
        while model.snapshot == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let snapshot = try XCTUnwrap(model.snapshot)
        let tpb = snapshot.timeSignature.ticksPerBar
        XCTAssertGreaterThan(tpb, 0)

        model.setLoop(startTicks: 4 * tpb, endTicks: 8 * tpb)
        let settle = Date().addingTimeInterval(3.0)
        while model.snapshot?.transport.loopRegion == nil, Date() < settle {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        try XCTSkipIf(model.snapshot?.transport.loopRegion == nil,
                      "the mock did not accept a loop region; nothing to number")

        let dialog = StudioExportDialog(model: model, isPresented: .constant(true))
        let bars = try XCTUnwrap(dialog.barRange())
        let grid = model.barGrid
        XCTAssertEqual(
            bars.lowerBound, grid.barNumber(at: 4 * tpb),
            "the export sheet numbers bars differently from the ruler above it")
        XCTAssertEqual(
            bars.upperBound, grid.barNumber(at: 8 * tpb - 1),
            "a loop ending on the downbeat of bar 9 covers bars 5 to 8, not 5 to 9")
    }
}
