import XCTest
@testable import MajiksMusicStudio

// Lane E5-ui: routing + effect-chain INTERACTIONS, driven end to end.
//
// Every test here calls the controller the way a gesture does and then asserts
// against the ENGINE'S JOURNAL — the list of commands the bus actually accepted
// — not against view state. That is what makes "every mutation is one journaled
// command, and undo puts it back" a measured property rather than a convention:
// an edit path that poked the model directly would leave the journal empty and
// these would fail.
//
// Production hops traversed: controller gesture method -> `StudioRoutingCommand`
// wire encoding -> `StudioEngineCommand.catalog` -> `StudioEngineProtocol.send`
// -> the engine's apply + inverse + undo stack -> `routingState()` read back.
// Hops SKIPPED: the FFI boundary and `timeline-core`'s own `apply.rs` (the
// preview engine mirrors it, it is not it), and every pixel — none of this can
// tell you whether the chain FEELS like a chain.

@MainActor
final class StudioRoutingInteractionTests: XCTestCase {

    // MARK: Fixture

    private func makeController() async -> (StudioRoutingController, StudioMockEngine) {
        let engine = StudioMockEngine()
        let controller = StudioRoutingController(engine: engine)
        await controller.attach()
        return (controller, engine)
    }

    private func journal(_ engine: StudioMockEngine) async -> [StudioEngineCommand] {
        await engine.journal
    }

    private func names(_ engine: StudioMockEngine) async -> [String] {
        await engine.journal.map(\.catalogName)
    }

    /// The params of the Nth journaled command, for asserting the wire shape.
    ///
    /// Index-safe on purpose: when a mutation check neuters the behaviour the
    /// journal is SHORTER, and a trap here would abort the test process before
    /// the assertion that was supposed to go red could be recorded.
    private func params(_ engine: StudioMockEngine, at index: Int) async -> [String: AnyHashable] {
        let log = await engine.journal
        guard index >= 0, index < log.count,
              case .catalog(_, let p) = log[index] else { return [:] }
        return p
    }

    private func firstTrackRef(_ c: StudioRoutingController) throws -> StudioNodeRef {
        try XCTUnwrap(c.tracks.first?.ref, "the preview engine publishes track ids")
    }

    // MARK: - One gesture, one journaled command, and undo puts it back

    func testAddBusIsOneJournaledCommandAndUndoRemovesIt() async throws {
        let (c, engine) = await makeController()

        let id = try XCTUnwrap(c.addBus(kind: .bus, name: "Reverb Bus"))
        await c.settle()

        let log1 = await names(engine)
        XCTAssertEqual(log1, ["route.node.add"],
                       "one gesture must be exactly one journaled command")
        let p = await params(engine, at: 0)
        XCTAssertEqual(p["nodeId"] as? String, id)
        XCTAssertEqual(p["kind"] as? String, "bus")
        XCTAssertEqual(p["name"] as? String, "Reverb Bus")
        XCTAssertEqual(c.state.nodes.map(\.id), [id])

        _ = await engine.undo()
        await c.reload()
        XCTAssertTrue(c.state.nodes.isEmpty, "undo must remove the bus")
    }

    /// The bus fader (route.node.set, catalog v2 #113 — the command the pane's
    /// old "NO FADER" chip said did not exist). One knob gesture is one
    /// journaled command; the command is self-inverse, so undo restores the
    /// PRIOR gain; and the UI clamp mirrors the command's own schema range so
    /// the knob can never travel to a value the engine would refuse.
    func testBusFaderIsOneJournaledCommandAndUndoRestoresThePriorGain() async throws {
        let (c, engine) = await makeController()
        let id = try XCTUnwrap(c.addBus(kind: .bus, name: "Drum Bus"))
        await c.settle()

        c.setNodeGain(id, gainDB: -6.5)
        await c.settle()
        let log = await names(engine)
        XCTAssertEqual(log, ["route.node.add", "route.node.set"],
                       "one fader gesture must be exactly one journaled command")
        let p = await params(engine, at: 1)
        XCTAssertEqual(p["nodeId"] as? String, id)
        XCTAssertEqual(p["gainDb"] as? Double ?? .nan, -6.5, accuracy: 1e-9)
        XCTAssertEqual(c.state.node(id)?.gainDB ?? .nan, -6.5, accuracy: 1e-9)

        // Out-of-schema input is clamped BEFORE sending — the engine's range
        // is the knob's range, so there is no refusal to surface.
        c.setNodeGain(id, gainDB: 999)
        await c.settle()
        XCTAssertEqual(c.state.node(id)?.gainDB ?? .nan,
                       StudioRoutingCaps.nodeGainMaxDB, accuracy: 1e-9)
        XCTAssertNil(c.lastRefusal, "a clamped send is a legal send")

        _ = await engine.undo()
        await c.reload()
        XCTAssertEqual(c.state.node(id)?.gainDB ?? .nan, -6.5, accuracy: 1e-9,
                       "self-inverse: undo carries the PRIOR gain, not a default")
        _ = await engine.undo()
        await c.reload()
        XCTAssertEqual(c.state.node(id)?.gainDB ?? .nan, 0, accuracy: 1e-9,
                       "a second undo returns the unset fader (0 dB)")
    }

    func testConnectIsOneCommandAndSuppressesTheImplicitMasterFeed() async throws {
        let (c, engine) = await makeController()
        let track = try firstTrackRef(c)
        let group = try XCTUnwrap(c.addBus(kind: .group, name: "Drums"))
        await c.settle()

        XCTAssertTrue(c.state.hasImplicitMasterFeed(track),
                      "a track with no post edge feeds master directly")

        let edge = try XCTUnwrap(c.connect(from: track, to: .bus(group)))
        await c.settle()

        let log2 = await names(engine)
        XCTAssertEqual(log2, ["route.node.add", "route.connect"])
        let p = await params(engine, at: 1)
        XCTAssertEqual(p["edgeId"] as? String, edge)
        XCTAssertEqual(p["from"] as? String, track.wireName)
        XCTAssertEqual(p["to"] as? String, "bus.\(group)")
        XCTAssertEqual(p["tap"] as? String, "post")
        XCTAssertEqual((p["level"] as? NSNumber)?.doubleValue, 1.0)

        XCTAssertFalse(c.state.hasImplicitMasterFeed(track),
                       "a POST edge replaces the direct master path; the UI must say so")

        _ = await engine.undo()
        await c.reload()
        XCTAssertTrue(c.state.edges.isEmpty)
        XCTAssertTrue(c.state.hasImplicitMasterFeed(track),
                      "disconnecting the last post edge brings the implicit feed back")
    }

    func testPreTapSendKeepsTheDirectMasterPath() async throws {
        let (c, _) = await makeController()
        let track = try firstTrackRef(c)
        let bus = try XCTUnwrap(c.addBus(kind: .bus, name: "Reverb"))
        await c.settle()
        _ = c.connect(from: track, to: .bus(bus), level: 0.5, tap: .pre)
        await c.settle()

        XCTAssertTrue(c.state.hasImplicitMasterFeed(track),
                      "a PRE edge is a send and never suppresses the direct feed")
    }

    func testTapToggleIsOneEdgeSetCarryingLevelAndTap() async throws {
        let (c, engine) = await makeController()
        let track = try firstTrackRef(c)
        let bus = try XCTUnwrap(c.addBus(kind: .bus, name: "Reverb"))
        await c.settle()
        let edge = try XCTUnwrap(c.connect(from: track, to: .bus(bus), level: 0.25, tap: .post))
        await c.settle()

        c.setEdgeTap(edge, tap: .pre)
        await c.settle()

        let log3 = await names(engine)
        XCTAssertEqual(log3, ["route.node.add", "route.connect", "route.edge.set"],
                       "flipping the tap must be ONE command, not a disconnect + reconnect")
        let p = await params(engine, at: 2)
        XCTAssertEqual(p["tap"] as? String, "pre")
        XCTAssertEqual((p["level"] as? NSNumber)?.doubleValue, 0.25,
                       "route.edge.set carries both, so the level must be preserved verbatim")

        _ = await engine.undo()
        await c.reload()
        let restored = try XCTUnwrap(c.state.edges.first)
        XCTAssertEqual(restored.tap, .post)
        XCTAssertEqual(restored.level, 0.25, accuracy: 1e-9)
    }

    // MARK: - Effect chains on all three host kinds

    func testAddFxAddressesMasterBusAndTrack() async throws {
        let (c, engine) = await makeController()
        let track = try firstTrackRef(c)
        let bus = try XCTUnwrap(c.addBus(kind: .bus, name: "Reverb"))
        await c.settle()

        _ = c.addFx(to: .master, kind: .limiter)
        _ = c.addFx(to: .bus(bus), kind: .reverb)
        _ = c.addFx(to: track, kind: .compressor)
        await c.settle()

        let targets = await journal(engine).compactMap { cmd -> String? in
            guard case .catalog(let n, let p) = cmd, n == "fx.add" else { return nil }
            return p["target"] as? String
        }
        XCTAssertEqual(targets, ["master", "bus.\(bus)", track.wireName],
                       "one NodeRef addressing scheme covers master, buses and tracks")
        XCTAssertEqual(c.state.masterFx.map(\.kind), [.limiter])
        XCTAssertEqual(c.state.chain(for: .bus(bus)).map(\.kind), [.reverb])
        XCTAssertEqual(c.state.chain(for: track).map(\.kind), [.compressor])
    }

    /// The sparsity rule, which is the easiest thing in this contract to get
    /// subtly wrong: undoing a FIRST-TIME parameter set must return the key to
    /// ABSENT, not write the DSP default into the project.
    func testUndoOfAFirstTimeParamSetReturnsTheKeyToAbsent() async throws {
        let (c, engine) = await makeController()
        let fx = try XCTUnwrap(c.addFx(to: .master, kind: .compressor))
        await c.settle()

        c.setFxParam(on: .master, id: fx, key: "ratio", value: 8)
        await c.settle()
        let log4 = await names(engine)
        XCTAssertEqual(log4, ["fx.add", "fx.param.set"])
        XCTAssertTrue(try XCTUnwrap(c.state.fx(on: .master, id: fx)).isSet("ratio"))

        _ = await engine.undo()
        await c.reload()
        let after = try XCTUnwrap(c.state.fx(on: .master, id: fx))
        XCTAssertFalse(after.isSet("ratio"),
                       "undo must make the key ABSENT again — writing the default back would look identical and be a different fact")
        XCTAssertEqual(after.value(for: "ratio"), 4.0, accuracy: 1e-9,
                       "an absent key reads as the DSP default")
    }

    func testSecondParamSetUndoesToThePriorValue() async throws {
        let (c, engine) = await makeController()
        let fx = try XCTUnwrap(c.addFx(to: .master, kind: .compressor))
        await c.settle()
        c.setFxParam(on: .master, id: fx, key: "ratio", value: 8)
        await c.settle()
        c.setFxParam(on: .master, id: fx, key: "ratio", value: 2)
        await c.settle()

        _ = await engine.undo()
        await c.reload()
        XCTAssertEqual(try XCTUnwrap(c.state.fx(on: .master, id: fx)).params["ratio"], 8)
    }

    func testParamSetIsClampedToTheKindsDeclaredRange() async throws {
        let (c, engine) = await makeController()
        let fx = try XCTUnwrap(c.addFx(to: .master, kind: .compressor))
        await c.settle()
        c.setFxParam(on: .master, id: fx, key: "ratio", value: 900)
        await c.settle()

        let p = await params(engine, at: 1)
        XCTAssertEqual((p["value"] as? NSNumber)?.doubleValue, 20.0,
                       "a knob must never travel somewhere the DSP will clamp away")
    }

    func testClearParamReturnsToTheDefaultAndUndoesToTheStoredValue() async throws {
        let (c, engine) = await makeController()
        let fx = try XCTUnwrap(c.addFx(to: .master, kind: .delay))
        await c.settle()
        c.setFxParam(on: .master, id: fx, key: "time", value: 500)
        await c.settle()
        c.clearFxParam(on: .master, id: fx, key: "time")
        await c.settle()

        let log5 = await names(engine)
        XCTAssertEqual(log5, ["fx.add", "fx.param.set", "fx.param.clear"])
        XCTAssertFalse(try XCTUnwrap(c.state.fx(on: .master, id: fx)).isSet("time"))

        _ = await engine.undo()
        await c.reload()
        XCTAssertEqual(try XCTUnwrap(c.state.fx(on: .master, id: fx)).params["time"], 500)
    }

    // MARK: - Bypass is not a parameter

    func testBypassIsNeverOfferedAsAParameter() {
        for kind in StudioFxKind.allCases {
            XCTAssertFalse(kind.params.contains { $0.key == studioFxBypassKey },
                           "\(kind.rawValue) must not expose bypass as a parameter slot")
        }
        let fx = StudioFx(id: "c1", kind: .compressor)
        XCTAssertFalse(fx.editableParams.contains { $0.key == studioFxBypassKey },
                       "the parameter grid must never draw a bypass knob")
    }

    /// The guard that stops bypass acquiring a second spelling. Without it the
    /// parameter path and the bypass path would both write the same key, and two
    /// spellings of one fact desync.
    func testSetFxParamRefusesTheBypassKey() async throws {
        let (c, engine) = await makeController()
        let fx = try XCTUnwrap(c.addFx(to: .master, kind: .saturator))
        await c.settle()
        let before = await names(engine)

        c.setFxParam(on: .master, id: fx, key: studioFxBypassKey, value: 1)
        await c.settle()

        let after = await names(engine)
        XCTAssertEqual(after, before,
                       "the parameter path must never write bypass")
        XCTAssertNotNil(c.lastRefusal)
        XCTAssertFalse(try XCTUnwrap(c.state.fx(on: .master, id: fx)).bypassed)
    }

    func testBypassGoesThroughItsOwnPathAndUndoes() async throws {
        let (c, engine) = await makeController()
        let fx = try XCTUnwrap(c.addFx(to: .master, kind: .saturator))
        await c.settle()

        c.setFxBypass(on: .master, id: fx, bypassed: true)
        await c.settle()

        let log6 = await names(engine)
        XCTAssertEqual(log6, ["fx.add", "fx.param.set"])
        let p = await params(engine, at: 1)
        XCTAssertEqual(p["key"] as? String, studioFxBypassKey)
        XCTAssertEqual((p["value"] as? NSNumber)?.doubleValue, 1.0)
        XCTAssertTrue(try XCTUnwrap(c.state.fx(on: .master, id: fx)).bypassed)

        _ = await engine.undo()
        await c.reload()
        XCTAssertFalse(try XCTUnwrap(c.state.fx(on: .master, id: fx)).bypassed)
    }

    // MARK: - Chain reorder, as a drag

    func testChainReorderDragEmitsExactlyOneMoveAndUndoRestoresOrder() async throws {
        let (c, engine) = await makeController()
        _ = c.addFx(to: .master, kind: .saturator)
        _ = c.addFx(to: .master, kind: .eq)
        _ = c.addFx(to: .master, kind: .limiter)
        await c.settle()
        XCTAssertEqual(c.state.masterFx.map(\.kind), [.saturator, .eq, .limiter])

        var layout = StudioFxChainLayout()
        layout.count = 3
        let sat = c.state.masterFx[0].id

        // Grab slot 0 and drag it over slot 2.
        c.beginChainDrag(fxID: sat, at: CGPoint(x: layout.rect(at: 0).midX, y: 10), layout: layout)
        c.updateChainDrag(to: CGPoint(x: layout.rect(at: 2).midX, y: 10), layout: layout)
        XCTAssertEqual(c.chainDrag?.dropIndex, 2)
        c.endChainDrag()
        await c.settle()

        let log7 = await names(engine)
        XCTAssertEqual(log7, ["fx.add", "fx.add", "fx.add", "fx.move"],
                       "a reorder drag is ONE journaled command")
        let p = await params(engine, at: 3)
        XCTAssertEqual(p["fxId"] as? String, sat)
        XCTAssertEqual((p["index"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual(c.state.masterFx.map(\.kind), [.eq, .limiter, .saturator])

        _ = await engine.undo()
        await c.reload()
        XCTAssertEqual(c.state.masterFx.map(\.kind), [.saturator, .eq, .limiter])
    }

    func testAReorderDragThatChangesNothingEmitsNoCommand() async throws {
        let (c, engine) = await makeController()
        _ = c.addFx(to: .master, kind: .eq)
        _ = c.addFx(to: .master, kind: .limiter)
        await c.settle()
        let before = await names(engine)

        var layout = StudioFxChainLayout()
        layout.count = 2
        let eq = c.state.masterFx[0].id
        c.beginChainDrag(fxID: eq, at: CGPoint(x: layout.rect(at: 0).midX, y: 10), layout: layout)
        c.updateChainDrag(to: CGPoint(x: layout.rect(at: 0).midX + 3, y: 10), layout: layout)
        c.endChainDrag()
        await c.settle()

        let log8 = await names(engine)
        XCTAssertEqual(log8, before,
                       "a no-op undo step is worse than no undo step")
    }

    // MARK: - fx.remove restores index, params and the sidechain link

    func testRemovingAConfiguredNonTerminalSidechainedFxUndoesCompletely() async throws {
        let (c, engine) = await makeController()
        let track = try firstTrackRef(c)
        let bus = try XCTUnwrap(c.addBus(kind: .bus, name: "Bass Bus"))
        await c.settle()

        _ = c.addFx(to: .bus(bus), kind: .eq)                       // index 0
        let comp = try XCTUnwrap(c.addFx(to: .bus(bus), kind: .compressor))  // index 1
        _ = c.addFx(to: .bus(bus), kind: .limiter)                  // index 2
        await c.settle()
        c.setFxParam(on: .bus(bus), id: comp, key: "ratio", value: 6)
        c.setFxParam(on: .bus(bus), id: comp, key: "threshold", value: -20)
        c.setSidechain(on: .bus(bus), id: comp, source: track)
        await c.settle()
        XCTAssertNil(c.lastRefusal, "the canonical kick-keys-the-bass-bus graph is legal")

        c.removeFx(from: .bus(bus), id: comp)
        await c.settle()
        XCTAssertEqual(c.state.chain(for: .bus(bus)).count, 2)

        _ = await engine.undo()
        await c.reload()
        let chain = c.state.chain(for: .bus(bus))
        XCTAssertEqual(chain.map(\.kind), [.eq, .compressor, .limiter], "the chain INDEX comes back")
        let restored = try XCTUnwrap(chain.first { $0.id == comp })
        XCTAssertEqual(restored.params["ratio"], 6)
        XCTAssertEqual(restored.params["threshold"], -20)
        XCTAssertEqual(restored.sidechain, track, "the key link comes back too")
    }

    func testRemovingABusUndoesItsChainAndItsConnections() async throws {
        let (c, engine) = await makeController()
        let track = try firstTrackRef(c)
        let bus = try XCTUnwrap(c.addBus(kind: .group, name: "Drums"))
        await c.settle()
        let fx = try XCTUnwrap(c.addFx(to: .bus(bus), kind: .saturator))
        await c.settle()
        c.setFxParam(on: .bus(bus), id: fx, key: "drive", value: 12)
        _ = c.connect(from: track, to: .bus(bus))
        await c.settle()

        c.removeBus(bus)
        await c.settle()
        XCTAssertTrue(c.state.nodes.isEmpty)
        XCTAssertTrue(c.state.edges.isEmpty, "removing a node removes its incident edges")

        _ = await engine.undo()
        await c.reload()
        XCTAssertEqual(c.state.nodes.map(\.name), ["Drums"])
        XCTAssertEqual(c.state.chain(for: .bus(bus)).map(\.kind), [.saturator])
        XCTAssertEqual(c.state.fx(on: .bus(bus), id: fx)?.params["drive"], 12)
        XCTAssertEqual(c.state.edges.map(\.from), [track],
                       "the connection comes back with the bus")
    }

    // MARK: - Legality: refused BEFORE anything is sent

    func testACycleIsRefusedAndNoCommandIsSent() async throws {
        let (c, engine) = await makeController()
        let x = try XCTUnwrap(c.addBus(kind: .bus, name: "X"))
        let y = try XCTUnwrap(c.addBus(kind: .bus, name: "Y"))
        await c.settle()
        _ = c.connect(from: .bus(x), to: .bus(y))
        await c.settle()
        let before = await names(engine)

        let refused = c.connect(from: .bus(y), to: .bus(x))
        await c.settle()

        XCTAssertNil(refused)
        let log9 = await names(engine)
        XCTAssertEqual(log9, before, "an illegal move must not reach the bus")
        let why = try XCTUnwrap(c.lastRefusal)
        XCTAssertTrue(why.contains("loop"), "the refusal names what is wrong: \(why)")
        XCTAssertTrue(why.contains("X") && why.contains("Y"), "and names the path: \(why)")
    }

    func testMasterIsNeverASource() async throws {
        let (c, _) = await makeController()
        let bus = try XCTUnwrap(c.addBus(kind: .bus, name: "Reverb"))
        await c.settle()
        XCTAssertNotNil(c.connectionRefusal(from: .master, to: .bus(bus)))
        XCTAssertNotNil(c.sidechainRefusal(source: .master, host: .bus(bus)))
    }

    func testSelfKeyIsRefused() async throws {
        let (c, _) = await makeController()
        let bus = try XCTUnwrap(c.addBus(kind: .bus, name: "Bass"))
        await c.settle()
        XCTAssertNotNil(c.sidechainRefusal(source: .bus(bus), host: .bus(bus)),
                        "an fx keyed by its own host is sidechain: none, not a link")
    }

    /// A cycle made ONLY of sidechain links, with no audio edge anywhere.
    ///
    /// The earlier version of this test connected Y into X with an audio edge
    /// first, so the refusal came from the EDGE and the test passed even with
    /// link participation switched off — it looked like it proved this and did
    /// not. Two links and no edges is the graph that actually needs them.
    func testASidechainLinkParticipatesInCycleDetection() async throws {
        let (c, _) = await makeController()
        let x = try XCTUnwrap(c.addBus(kind: .bus, name: "X"))
        let y = try XCTUnwrap(c.addBus(kind: .bus, name: "Y"))
        await c.settle()
        let fxOnX = try XCTUnwrap(c.addFx(to: .bus(x), kind: .compressor))
        _ = c.addFx(to: .bus(y), kind: .gate)
        await c.settle()

        // Link 1: an fx on X is keyed by Y, i.e. Y must be scheduled before X.
        c.setSidechain(on: .bus(x), id: fxOnX, source: .bus(y))
        await c.settle()
        XCTAssertNil(c.lastRefusal)
        XCTAssertTrue(c.state.edges.isEmpty, "no audio edge exists in this graph")

        // Link 2 would require X before Y. Only the LINKS close this loop.
        XCTAssertNotNil(c.sidechainRefusal(source: .bus(x), host: .bus(y)),
                        "a key is an ordering constraint and closes cycles like an edge")
    }

    func testSidechainIsOnlyOfferedOnKeyableKinds() async throws {
        let (c, engine) = await makeController()
        let track = try firstTrackRef(c)
        let fx = try XCTUnwrap(c.addFx(to: .master, kind: .reverb))
        await c.settle()
        let before = await names(engine)

        c.setSidechain(on: .master, id: fx, source: track)
        await c.settle()

        let log10 = await names(engine)
        XCTAssertEqual(log10, before,
                       "a reverb has no keyable detector, so a key would be a control that does nothing")
        XCTAssertNotNil(c.lastRefusal)
        XCTAssertTrue(StudioFxKind.compressor.acceptsSidechain)
        XCTAssertTrue(StudioFxKind.gate.acceptsSidechain)
    }

    func testSidechainSetAndClearRoundTripThroughUndo() async throws {
        let (c, engine) = await makeController()
        let track = try firstTrackRef(c)
        let fx = try XCTUnwrap(c.addFx(to: .master, kind: .compressor))
        await c.settle()
        c.setSidechain(on: .master, id: fx, source: track)
        await c.settle()
        XCTAssertEqual(c.state.fx(on: .master, id: fx)?.sidechain, track)

        c.clearSidechain(on: .master, id: fx)
        await c.settle()
        XCTAssertNil(c.state.fx(on: .master, id: fx)?.sidechain)
        let log11 = await names(engine)
        XCTAssertEqual(log11, ["fx.add", "fx.sidechain.set", "fx.sidechain.clear"])

        _ = await engine.undo()
        await c.reload()
        XCTAssertEqual(c.state.fx(on: .master, id: fx)?.sidechain, track)
    }

    // MARK: - Caps refuse without sending

    func testChainCapIsRefusedLocally() async throws {
        let (c, engine) = await makeController()
        for _ in 0..<StudioRoutingCaps.maxFxPerChain {
            _ = c.addFx(to: .master, kind: .utility)
        }
        await c.settle()
        XCTAssertEqual(c.state.masterFx.count, StudioRoutingCaps.maxFxPerChain)
        let before = await names(engine)

        XCTAssertNil(c.addFx(to: .master, kind: .utility))
        await c.settle()
        let log12 = await names(engine)
        XCTAssertEqual(log12, before)
        XCTAssertTrue(try XCTUnwrap(c.lastRefusal).contains("\(StudioRoutingCaps.maxFxPerChain)"),
                      "the refusal names the cap and the count, like the engine's does")
    }
}

// MARK: - The wire shapes, checked against the catalog

@MainActor
final class StudioRoutingWireTests: XCTestCase {

    private func wire(_ c: StudioRoutingCommand) -> (String, [String: AnyHashable]) {
        let w = c.wire
        return (w.name, w.params)
    }

    /// Command name + required params, transcribed from
    /// `contracts/command-catalog.v2.json`. A typo here is a runtime refusal
    /// nobody sees; as a test it is a red build.
    func testEveryCommandCarriesExactlyTheCatalogsRequiredParams() {
        let expected: [(StudioRoutingCommand, String, Set<String>)] = [
            (.nodeAdd(nodeID: "b", kind: .bus, name: "B"), "route.node.add", ["nodeId", "kind", "name"]),
            (.nodeRemove(nodeID: "b"), "route.node.remove", ["nodeId"]),
            (.connect(edgeID: "e", from: .track("t1"), to: .master, level: 1, tap: .post),
             "route.connect", ["edgeId", "from", "to", "level", "tap"]),
            (.disconnect(edgeID: "e"), "route.disconnect", ["edgeId"]),
            (.edgeSet(edgeID: "e", level: 1, tap: .pre), "route.edge.set", ["edgeId", "level", "tap"]),
            (.fxAdd(target: .master, fxID: "f", kind: .eq), "fx.add", ["target", "fxId", "kind"]),
            (.fxRemove(target: .master, fxID: "f"), "fx.remove", ["target", "fxId"]),
            (.fxMove(target: .master, fxID: "f", index: 1), "fx.move", ["target", "fxId", "index"]),
            (.fxParamSet(target: .master, fxID: "f", key: "mix", value: 0.5),
             "fx.param.set", ["target", "fxId", "key", "value"]),
            (.fxParamClear(target: .master, fxID: "f", key: "mix"),
             "fx.param.clear", ["target", "fxId", "key"]),
            (.sidechainSet(target: .master, fxID: "f", source: .track("t1")),
             "fx.sidechain.set", ["target", "fxId", "source"]),
            (.sidechainClear(target: .master, fxID: "f"), "fx.sidechain.clear", ["target", "fxId"]),
        ]
        for (command, name, keys) in expected {
            let (gotName, gotParams) = wire(command)
            XCTAssertEqual(gotName, name)
            XCTAssertEqual(Set(gotParams.keys), keys, "\(name) params")
        }
    }

    func testNodeRefRoundTripsTheWireGrammar() {
        for ref: StudioNodeRef in [.master, .track("t1"), .bus("rev-1")] {
            XCTAssertEqual(StudioNodeRef.parse(ref.wireName), ref)
        }
        XCTAssertNil(StudioNodeRef.parse("track."))
        XCTAssertNil(StudioNodeRef.parse("aux.x"))
        XCTAssertNil(StudioNodeRef.parse("bus.has.dot"))
    }

    func testMintedIdsMatchTheCatalogPattern() {
        for name in ["Reverb Bus", "  ", "Drums // 2", "Ünïcørn"] {
            let id = StudioRoutingController.slug(name, fallback: "bus")
            XCTAssertTrue(StudioNodeRef.isValidID(id), "\(name) -> \(id)")
        }
        XCTAssertEqual(StudioRoutingController.unique("bus", taken: ["bus", "bus2"]), "bus3")
    }

    /// EQ keys are FLAT. A nested spelling would not parse as
    /// `track.fx.<fxId>.<paramKey>` at all, so the whole lane would be inert.
    func testEqParamKeysAreFlat() {
        for spec in StudioFxKind.eq.params {
            XCTAssertFalse(spec.key.contains("."), "\(spec.key) must have no dot")
        }
        XCTAssertTrue(StudioFxKind.eq.params.contains { $0.key == "band0Gain" })
    }

    /// `division` is the one key in the engine's `FX_PARAM_KEYS` that no kind
    /// implements (delay takes absolute `time`; tempo resolution is
    /// control-side). Offering it would be a knob that does nothing.
    func testNoKindOffersTheUnimplementedDivisionKey() {
        for kind in StudioFxKind.allCases {
            XCTAssertFalse(kind.params.contains { $0.key == "division" }, "\(kind.rawValue)")
        }
    }

    func testEachKindsParamKeysAreUniqueAndWithinTheSlotBudget() {
        for kind in StudioFxKind.allCases {
            let keys = kind.params.map(\.key)
            XCTAssertEqual(Set(keys).count, keys.count, "\(kind.rawValue) has a duplicate key")
            // MAX_FX_PARAMS_PER_FX = 32 render-side; a kind past it would alias
            // into the next fx's slots.
            XCTAssertLessThanOrEqual(keys.count, 32, "\(kind.rawValue)")
        }
    }

    func testOnlyTheLimiterReportsLatency() {
        for kind in StudioFxKind.allCases {
            XCTAssertEqual(kind.latencyFrames, kind == .limiter ? 96 : 0, "\(kind.rawValue)")
        }
    }

    func testSendTaperRoundTripsUnityAndSilence() {
        XCTAssertEqual(StudioSendTaper.levelToDB(1.0), 0, accuracy: 1e-9)
        XCTAssertEqual(StudioSendTaper.dbToLevel(0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(StudioSendTaper.dbToLevel(StudioSendTaper.minDB), 0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(StudioSendTaper.dbToLevel(StudioSendTaper.maxDB), 4.0,
                                 "the wire caps level at 4")
    }
}

// MARK: - Chain layout math (the interaction's geometry, without a view)

final class StudioFxChainLayoutTests: XCTestCase {

    private var layout: StudioFxChainLayout {
        var l = StudioFxChainLayout()
        l.count = 4
        return l
    }

    func testSlotIndexHitsSlotsAndTheTrailingAddSlot() {
        let l = layout
        XCTAssertEqual(l.slotIndex(at: CGPoint(x: l.rect(at: 0).midX, y: 10)), 0)
        XCTAssertEqual(l.slotIndex(at: CGPoint(x: l.rect(at: 3).midX, y: 10)), 3)
        XCTAssertEqual(l.slotIndex(at: CGPoint(x: l.addRect.midX, y: 10)), 4)
    }

    func testSlotIndexRejectsTheGapAndOutsideTheStrip() {
        let l = layout
        let gapX = l.rect(at: 0).maxX + l.slotSpacing / 2
        XCTAssertNil(l.slotIndex(at: CGPoint(x: gapX, y: 10)),
                     "a click in the gap must do nothing rather than land on a neighbour")
        XCTAssertNil(l.slotIndex(at: CGPoint(x: 10, y: l.slotHeight + 5)))
        XCTAssertNil(l.slotIndex(at: CGPoint(x: -5, y: 10)))
    }

    func testDropIndexIsClampedToTheChain() {
        let l = layout
        XCTAssertEqual(l.dropIndex(forX: -500), 0)
        XCTAssertEqual(l.dropIndex(forX: 10_000), 3)
        XCTAssertEqual(l.dropIndex(forX: l.rect(at: 2).midX), 2)
    }

    /// The explicit transform that stands in for the horizontal ScrollView this
    /// surface deliberately does not use.
    func testScrollOffsetBringsASlotIntoView() {
        var l = layout
        l.count = 10
        let viewport: CGFloat = 300
        let toRight = l.scrollOffset(toShow: 9, viewportWidth: viewport)
        XCTAssertGreaterThan(toRight, 0)
        l.scrollX = toRight
        XCTAssertLessThanOrEqual(l.rect(at: 9).maxX, viewport + 0.5)
        let back = l.scrollOffset(toShow: 0, viewportWidth: viewport)
        XCTAssertEqual(back, 0, accuracy: 0.5)
    }

    func testScrollingIsHitTestAware() {
        var l = layout
        l.count = 10
        l.scrollX = l.pitch * 2
        XCTAssertEqual(l.slotIndex(at: CGPoint(x: l.slotWidth / 2, y: 10)), 2,
                       "after an explicit shift, the leftmost visible slot is index 2")
    }
}
