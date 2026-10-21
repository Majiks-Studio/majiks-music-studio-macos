import XCTest
import SwiftUI
@testable import MajiksMusicStudio

// Lane E5-ui: the two things about this pane that a build cannot catch.
//
// 1. GEOMETRY. A container shorter than its content clips silently, and the
//    clipped controls are simply never drawn — that is exactly how the mixer
//    dock shipped with un-clickable M / S buttons for months. The chain strip is
//    the fixed-height part here, so it is measured the same way
//    StudioMixerDockTests measures a channel strip (ImageRenderer, deterministic,
//    no window).
//
// 2. HONESTY, in BOTH directions. The surface must not imply audio it is not
//    producing — and must not deny capability it HAS, which became the live
//    risk twice: first when E5-graph landed the renderer under a pane built to
//    over-warn, then again when the fx-param-automation and bus-fader lanes
//    landed under a pane still claiming "no automation, no fader". These pin
//    the current statements: the badge is gone, bus meters are real readings
//    that follow the graph AND the fader (absence when unpublished, never a
//    fabricated bar), the fader is a real journaled control, and the per-KEY
//    automation split mirrors the engine's FxParamRate table exactly — the
//    refusals that remain (EQ bands, attack/release coefficients) stated with
//    their reasons, and NOTHING stated for kinds that simply work.

@MainActor
final class StudioRoutingPaneTests: XCTestCase {

    private func idealSize<V: View>(_ view: V) -> CGSize? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return nil }
        return CGSize(width: cg.width, height: cg.height)
    }

    private func loadedController() async -> StudioRoutingController {
        let c = StudioRoutingController(engine: StudioMockEngine())
        await c.attach()
        for kind in [StudioFxKind.eq, .compressor, .saturator, .limiter] {
            _ = c.addFx(to: .master, kind: kind)
        }
        await c.settle()
        return c
    }

    // MARK: Geometry

    func testTheChainStripFitsItsFrameSoSlotsAreDrawnAndClickable() async throws {
        let c = await loadedController()
        XCTAssertEqual(c.state.masterFx.count, 4)

        let size = try XCTUnwrap(idealSize(
            StudioFxChainStrip(controller: c).frame(width: 640)))
        XCTAssertLessThanOrEqual(
            size.height, StudioFxChainStrip.stripHeight,
            """
            The chain strip needs \(size.height) pt but its frame is \
            \(StudioFxChainStrip.stripHeight) pt. The overflow is CLIPPED, not \
            scrolled: the bottom of every slot (the KEY marker) would be \
            invisible and the slot's hit area would be short. Raise \
            StudioFxChainStrip.stripHeight.
            """)
    }

    /// The pane's fixed rows must leave a positive scroll region, or the part
    /// that grows (the parameter grid) gets zero height and vanishes.
    func testThePaneLeavesRoomForItsScrollingContent() {
        let fixed = StudioRoutingPane.headerHeight
            + 26                                    // focus header
            + StudioFxChainStrip.stripHeight
            + 2                                     // the two hairline separators
        XCTAssertGreaterThan(
            StudioRoutingPane.paneHeight - fixed, 120,
            "the parameter grid and the send list need a usable scroll region")
    }

    /// The whole pane renders. A crash or a nil image here means the surface
    /// never appears at all, which no amount of controller testing would show.
    func testThePaneRenders() async throws {
        let c = await loadedController()
        c.selectedFxID = c.state.masterFx.first?.id
        let size = try XCTUnwrap(idealSize(StudioRoutingPane(controller: c).frame(width: 900)))
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertEqual(size.height, StudioRoutingPane.paneHeight, accuracy: 1)
    }

    // MARK: Honesty about what is audible

    /// ⚠️ This pins a DECLARATION, not a probe. The engine's own predicate for
    /// the same fact (`render::rt::lane_has_reader` / the compiled `node_order`
    /// walk) is not reachable across the FFI.
    ///
    /// HISTORY, on purpose: this test previously pinned `false` — the pane
    /// shipped before the renderer and wore an undismissable "STORED, NOT YET
    /// AUDIBLE" badge, its author accepting that the design "fails by
    /// over-warning after the audio arrives". E5-graph landed the walk (buses,
    /// edges at both taps, insert chains, sidechain-keyed dynamics, PDC,
    /// bit-identical across host block sizes), so the badge came down and this
    /// pin flipped in the SAME pass. This is that conscious update, not a
    /// deletion.
    func testTheSurfaceDeclaresThatProcessingIsAudible() {
        XCTAssertTrue(
            StudioRoutingCapability.processingActive,
            """
            The render side evaluates the routing graph and the fx chains, so \
            the pane must not warn that it does not: over-warning about audio \
            the engine IS producing teaches a user to ignore warnings, which is \
            the inert-control bug mirrored. If the renderer has actually \
            regressed, flip StudioRoutingCapability.processingActive and this \
            assertion together — and bring back an undismissable badge with it.
            """)
    }

    /// Bus meters are REAL readings now: `MeterBank`'s node slots, exposed on
    /// the host's meters read, carried on the snapshot, drawn per bus row.
    /// The behavioural half (a reading that follows the graph, absence when
    /// the engine publishes none) is proven in
    /// `testBusMetersAreRealReadingsThatFollowTheGraph`.
    func testNodeMetersAreDeclaredAvailable() {
        XCTAssertTrue(
            StudioRoutingCapability.nodeMetersAvailable,
            "the node meter path exists end to end; declaring it unavailable would hide real levels")
    }

    /// ⚠️ THE DRIFT PIN, and the conscious update of what was
    /// `testFxParamAutomationIsRefusedAndTheNoteSaysSoPrecisely`: that test
    /// pinned a blanket refusal, which became an over-warning the moment the
    /// fx-param-automation lane landed `FxNode::set_frame_param`. The truth is
    /// per KEY now, and the engine's single source for it —
    /// `render/src/dsp/fx.rs`'s `FxParamRate` rows (`fx_key_class` feeds
    /// `rt::lane_has_reader` from the same table) — is not reachable across
    /// the FFI, so `StudioFxParamSpec.automatable` MIRRORS it. This test is
    /// that mirror's pin, transcribed key by key: a drifted row here is a
    /// failing test, not a quietly lying surface.
    func testFxParamAutomatabilityMirrorsTheEngineSpec() {
        // Transcribed from render/src/dsp/fx.rs: `pb(...)` rows are Block
        // (refused per key); everything else is Frame (per-frame reader).
        let expectedRefused: [StudioFxKind: Set<String>] = [
            .eq: ["band0Freq", "band0Gain", "band0Q",
                  "band1Freq", "band1Gain", "band1Q",
                  "band2Freq", "band2Gain", "band2Q",
                  "band3Freq", "band3Gain", "band3Q"],
            .compressor: ["attack", "release"],
            .gate: ["attack", "release"],
            .limiter: ["release"],
            .delay: [], .reverb: [], .saturator: [], .chorus: [], .utility: [],
        ]
        for kind in StudioFxKind.allCases {
            let refused = Set(kind.params.filter { !$0.automatable }.map(\.key))
            XCTAssertEqual(refused, expectedRefused[kind],
                           "\(kind.label) drifted from the engine's FxParamRate table")
        }
        // The engine's own headline number: 22 distinct Frame keys.
        let automatable = Set(StudioFxKind.allCases
            .flatMap { kind in kind.params.filter(\.automatable).map(\.key) })
        XCTAssertEqual(automatable.count, 22,
                       "the distinct automatable key set must match the engine's 22")
    }

    /// Each kind's note states ITS exceptions, precisely, and kinds with no
    /// exception say nothing — a reassurance banner on a working control is
    /// noise, and noise teaches users to stop reading.
    func testFxAutomationNotesStateEachKindsExceptionsPrecisely() throws {
        let eq = try XCTUnwrap(StudioRoutingCapability.fxAutomationNote(for: .eq))
        XCTAssertTrue(eq.contains("RBJ"), eq)
        XCTAssertTrue(eq.lowercased().contains("refuse"), eq)
        XCTAssertTrue(eq.lowercased().contains("points kept"), eq)

        let comp = try XCTUnwrap(StudioRoutingCapability.fxAutomationNote(for: .compressor))
        XCTAssertTrue(comp.contains("ATK and REL"), comp)
        XCTAssertTrue(comp.lowercased().contains("automates per frame"), comp)
        let gate = try XCTUnwrap(StudioRoutingCapability.fxAutomationNote(for: .gate))
        XCTAssertTrue(gate.contains("ATK and REL"), gate)
        let lim = try XCTUnwrap(StudioRoutingCapability.fxAutomationNote(for: .limiter))
        XCTAssertTrue(lim.contains("REL"), lim)
        XCTAssertFalse(lim.contains("ATK"), "the limiter has no attack knob to warn about")

        // Delay: nothing refused — the note is SEMANTICS, stated plainly: time
        // automation is a crossfaded tap, not tape repitch.
        let delay = try XCTUnwrap(StudioRoutingCapability.fxAutomationNote(for: .delay))
        XCTAssertTrue(delay.lowercased().contains("crossfaded"), delay)
        XCTAssertTrue(delay.lowercased().contains("tape"), delay)
        XCTAssertTrue(delay.lowercased().contains("automate per frame"), delay)

        // Fully-automatable kinds say NOTHING.
        for kind in [StudioFxKind.reverb, .saturator, .chorus, .utility] {
            XCTAssertNil(StudioRoutingCapability.fxAutomationNote(for: kind),
                         "\(kind.label) has no exceptions; a note would be over-warning")
        }
    }

    /// The forbidden phrasing: most fx-parameter automation IS available now,
    /// so no note may ever summarize the split as "automation unavailable".
    func testNoNoteEverSaysAutomationIsUnavailable() {
        for kind in StudioFxKind.allCases {
            if let note = StudioRoutingCapability.fxAutomationNote(for: kind) {
                XCTAssertFalse(note.lowercased().contains("unavailable"), note)
                XCTAssertFalse(note.lowercased().contains("not renderable"), note)
            }
        }
    }

    /// The view is held to the note: an editor for a kind with exceptions
    /// carries its footnote, and an editor for a kind without says nothing.
    /// Hiding the footnote (the property returning nil, or the table claiming
    /// no refusals) is a red test here, not a quiet regression.
    func testTheFxEditorShowsItsNoteExactlyWhereOneExists() async throws {
        let c = await loadedController()   // eq, compressor, saturator, limiter on master
        let eqFx = try XCTUnwrap(c.state.masterFx.first { $0.kind == .eq })
        XCTAssertNotNil(StudioFxEditor(controller: c, fx: eqFx).automationFootnote,
                        "the EQ editor must state that band lanes are refused")
        let sat = try XCTUnwrap(c.state.masterFx.first { $0.kind == .saturator })
        XCTAssertNil(StudioFxEditor(controller: c, fx: sat).automationFootnote,
                     "no exceptions on the saturator — a footnote would be over-warning")
    }

    /// The meter path end to end through the preview engine: a fed bus meters
    /// while playing, the reading FOLLOWS its feed (two buses fed from the
    /// same source at different connection levels differ by exactly the level
    /// ratio — a constant or copied value fails here), and when the engine
    /// publishes no readings the controller reports ABSENCE, not silence.
    func testBusMetersAreRealReadingsThatFollowTheGraph() async throws {
        let engine = StudioMockEngine()
        let c = StudioRoutingController(engine: engine)
        await c.attach()
        let track = try XCTUnwrap(c.tracks.first?.ref, "the preview engine publishes track ids")

        let loud = try XCTUnwrap(c.addBus(kind: .bus, name: "Loud"))
        let quiet = try XCTUnwrap(c.addBus(kind: .bus, name: "Quiet"))
        await c.settle()
        _ = try XCTUnwrap(c.connect(from: track, to: .bus(loud), level: 1.0))
        _ = try XCTUnwrap(c.connect(from: track, to: .bus(quiet), level: 0.25))
        await c.settle()

        // Stopped: the engine publishes no node readings. Absence — the pane
        // draws NO meter — never a fabricated bar at the floor.
        await c.reload()
        XCTAssertNil(c.nodeMeters[.bus(loud)],
                     "no reading published while stopped must mean NO meter, not a silent one")

        _ = await engine.send(.transportPlay)
        await c.reload()

        let loudMeter = try XCTUnwrap(c.nodeMeters[.bus(loud)], "a fed bus meters while playing")
        let quietMeter = try XCTUnwrap(c.nodeMeters[.bus(quiet)])
        // -120 dBFS is the engine's silence floor; a fed bus must be above it.
        XCTAssertGreaterThan(loudMeter.peakDB, -119,
                             "a bus fed at unity from a sounding track is not silent")
        XCTAssertEqual(
            loudMeter.peakDB - quietMeter.peakDB, 20 * log10(4.0), accuracy: 0.1,
            """
            The same source feeds both buses, at connection levels 1.0 and \
            0.25, so the readings must differ by exactly 20*log10(4) dB. A \
            meter that shows a constant, or copies one level to every bus, \
            fails here — which is the point: these bars must be measurements.
            """)

        // The fader shapes the meter: node meters read POST-gain (the real
        // walk applies `x *= g` before accumulating), so pulling the loud
        // bus's brand-new fader down 12 dB must move ITS reading by exactly
        // that, relative to the untouched bus in the same snapshot.
        c.setNodeGain(loud, gainDB: -12)
        await c.settle()
        let fadedLoud = try XCTUnwrap(c.nodeMeters[.bus(loud)])
        let steadyQuiet = try XCTUnwrap(c.nodeMeters[.bus(quiet)])
        XCTAssertEqual(fadedLoud.peakDB - steadyQuiet.peakDB, 20 * log10(4.0) - 12, accuracy: 0.1,
                       "a bus meter that ignores the bus fader is decoration, not measurement")

        // Disconnect the quiet bus's only feed: its reading follows the graph
        // to the floor (an existing, silent bus is a READING of silence).
        let edge = try XCTUnwrap(c.state.outgoing(from: track).first { $0.to == .bus(quiet) })
        c.disconnect(edge.id)
        await c.settle()
        let silenced = try XCTUnwrap(c.nodeMeters[.bus(quiet)])
        XCTAssertEqual(silenced.peakDB, -120, accuracy: 0.01,
                       "an unfed bus reads the -120 dBFS floor while the engine is publishing")
    }

    /// The conscious update of `testTheMissingBusFaderIsStatedRatherThanFaked`:
    /// that test pinned "no command in the catalog writes a bus's gain", which
    /// `route.node.set` (catalog v2 #113) made false. The chip and the note are
    /// gone; the fader is a real journaled control now, proven end to end in
    /// `StudioRoutingInteractionTests.testBusFaderIsOneJournaledCommandAndUndoRestoresThePriorGain`.
    /// What this still pins: the knob's range mirrors the command's own schema
    /// (so it can never travel to a refusal), and the rename gap — which
    /// remains real — stays stated.
    func testTheBusFaderIsRealSoOnlyTheRenameGapRemainsStated() {
        XCTAssertEqual(StudioRoutingCaps.nodeGainMinDB, -60)
        XCTAssertEqual(StudioRoutingCaps.nodeGainMaxDB, 12)
        XCTAssertEqual(StudioRoutingController.clampNodeGainDB(99), 12)
        XCTAssertEqual(StudioRoutingController.clampNodeGainDB(-999), -60)
        XCTAssertTrue(StudioRoutingCapability.noRenameNote.lowercased().contains("rename"),
                      "rename is STILL missing from the catalog; that half stays stated")
    }

    // MARK: The tap semantics are stated, not buried

    /// A pre-fader send here does NOT carry the channel EQ — a deliberate
    /// divergence from what Live and Logic mean by "pre-fader". Shipping that
    /// silently is the exact class of defect this epic exists to stop.
    func testThePreTapNoteSaysItDoesNotCarryTheEq() {
        let note = StudioTap.pre.note
        XCTAssertTrue(note.lowercased().contains("eq"), note)
        XCTAssertTrue(note.lowercased().contains("mute"), note)
        XCTAssertTrue(StudioTap.post.note.lowercased().contains("post-eq"),
                      StudioTap.post.note)
    }
}
