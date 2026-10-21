import XCTest
@testable import MajiksMusicStudio

// Lane E5-ui: the real-engine READ path.
//
// The routing surface reads the graph and every insert chain straight off the
// engine's project JSON, which is `serde_json::to_value(Project)` — the model
// verbatim. That means the field names here are a CONTRACT with `timeline-core`,
// and a mismatch is silent: the parser would return an empty graph and the pane
// would show a blank surface as if the project had no buses in it.
//
// So this pins the shape, key by key, against the model's serde form:
//
//   Routing   -> {nodes: [...], edges: [...]}      (OMITTED entirely when empty)
//   RouteNode -> {id, kind: "bus"|"group", name, fx: [...]}
//   RouteEdge -> {id, from, to, level, tap: "pre"|"post"}   from/to are NodeRef strings
//   Fx        -> {id, kind: <lowercase>, params: {...}, sidechain: <NodeRef string>}
//               (params and sidechain OMITTED when empty/none — sparsity is the contract)
//
// ⚠️ This compiles ONLY in a real-engine build, because `EngineJSON` lives in
// `Sources/Engine`, which a mock build excludes. A mock `swift test` therefore
// runs ZERO of these and says so cheerfully — the exact false green
// `Package.swift` warns about. Run `MAJIKS_ENGINE=real swift test` for it.

#if REAL_ENGINE

final class StudioRoutingRealEngineTests: XCTestCase {

    private func parse(_ project: [String: Any]) -> StudioRoutingState {
        StudioRoutingJSON.parseProject(EngineJSON(project))
    }

    func testParsesTheFullGraphOffTheProjectJSON() throws {
        let state = parse([
            "routing": [
                "nodes": [
                    ["id": "grp", "kind": "group", "name": "Drums",
                     "fx": [["id": "c1", "kind": "compressor",
                             "params": ["ratio": 6.0, "threshold": -18.0],
                             "sidechain": "track.t1"]]],
                    ["id": "rev", "kind": "bus", "name": "Reverb"],
                ],
                "edges": [
                    ["id": "e1", "from": "track.t1", "to": "bus.grp", "level": 1.0, "tap": "post"],
                    ["id": "e2", "from": "track.t1", "to": "bus.rev", "level": 0.35, "tap": "pre"],
                ],
            ],
            "tracks": [
                ["id": "t1", "fx": [["id": "eq1", "kind": "eq"]]],
                ["id": "t2"],
            ],
            "master": ["fx": [["id": "lim", "kind": "limiter", "params": ["ceiling": -0.3]]]],
        ])

        XCTAssertEqual(state.nodes.map(\.id), ["grp", "rev"])
        XCTAssertEqual(state.node("grp")?.kind, .group)
        XCTAssertEqual(state.node("rev")?.kind, .bus)
        XCTAssertEqual(state.node("grp")?.name, "Drums")

        let comp = try XCTUnwrap(state.fx(on: .bus("grp"), id: "c1"))
        XCTAssertEqual(comp.kind, .compressor)
        XCTAssertEqual(comp.params["ratio"], 6)
        XCTAssertEqual(comp.sidechain, .track("t1"), "sidechain is a NodeRef WIRE STRING")

        XCTAssertEqual(state.edges.map(\.id), ["e1", "e2"])
        let send = try XCTUnwrap(state.edges.first { $0.id == "e2" })
        XCTAssertEqual(send.from, .track("t1"))
        XCTAssertEqual(send.to, .bus("rev"))
        XCTAssertEqual(send.tap, .pre)
        XCTAssertEqual(send.level, 0.35, accuracy: 1e-9)

        XCTAssertEqual(state.trackFx["t1"]?.map(\.kind), [.eq])
        XCTAssertNil(state.trackFx["t2"], "a track with no chain contributes no entry")
        XCTAssertEqual(state.masterFx.map(\.id), ["lim"])
        XCTAssertEqual(state.masterFx.first?.params["ceiling"], -0.3)
    }

    /// `Routing` is `skip_serializing_if = "Routing::is_empty"`, so a v1 project
    /// has no `routing` key at all. That is the v1 topology, NOT a parse failure.
    func testAnAbsentRoutingKeyIsTheV1TopologyNotAnError() {
        let state = parse(["tracks": [["id": "t1"]], "master": [:]])
        XCTAssertTrue(state.isEmpty)
        XCTAssertTrue(state.hasImplicitMasterFeed(.track("t1")),
                      "with no routing at all, every track feeds master")
    }

    /// Sparsity: `params` and `sidechain` are omitted when empty, and an fx with
    /// neither is a correctly-configured effect sitting on its defaults.
    func testAnFxWithNoStoredParamsReadsAsItsDefaults() throws {
        let state = parse(["master": ["fx": [["id": "c1", "kind": "compressor"]]]])
        let fx = try XCTUnwrap(state.fx(on: .master, id: "c1"))
        XCTAssertTrue(fx.params.isEmpty)
        XCTAssertFalse(fx.isSet("ratio"))
        XCTAssertEqual(fx.value(for: "ratio"), 4, accuracy: 1e-9)
        XCTAssertNil(fx.sidechain)
        XCTAssertFalse(fx.bypassed)
    }

    /// A malformed entry is DROPPED rather than crashing the pane. The engine
    /// fails the package OPEN loudly on a malformed graph (design section 10), so
    /// anything that reaches here and does not parse is a version skew, not a
    /// corrupt project — and a surface that renders what it understood beats one
    /// that renders nothing.
    func testUnparseableEntriesAreDroppedNotFatal() {
        let state = parse([
            "routing": [
                "nodes": [["id": "ok", "kind": "bus", "name": "OK"],
                          ["id": "bad", "kind": "wormhole", "name": "Bad"]],
                "edges": [["id": "e1", "from": "track.t1", "to": "bus.ok", "level": 1.0, "tap": "post"],
                          ["id": "e2", "from": "nowhere", "to": "bus.ok", "level": 1.0, "tap": "post"]],
            ],
        ])
        XCTAssertEqual(state.nodes.map(\.id), ["ok"])
        XCTAssertEqual(state.edges.map(\.id), ["e1"])
    }

    /// The node fader (`RouteNode::gain_db`, set by route.node.set). Omitted
    /// from serde while it is the default 0 dB, so ABSENCE parses to an unset
    /// fader at 0 — not a failure, and never a fabricated value.
    func testParsesTheNodeFaderGainAndItsOmittedDefault() throws {
        let state = parse([
            "routing": [
                "nodes": [
                    ["id": "hot", "kind": "bus", "name": "Hot", "gain_db": -4.25],
                    ["id": "flat", "kind": "group", "name": "Flat"],
                ],
                "edges": [],
            ],
        ])
        XCTAssertEqual(try XCTUnwrap(state.node("hot")).gainDB, -4.25, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(state.node("flat")).gainDB, 0, accuracy: 1e-9)
    }

    // MARK: Node meters (E5-ui-truth): the meters-read half of the contract
    //
    // `host.rs meters()` -> {"nodes": [{nodeId, peakDb, rmsDb}, ...]}, one entry
    // per routing node in `routing.nodes` order (meter-bank slot i IS
    // routing.nodes[i]). `buildSnapshot` adopts this through
    // `StudioRoutingJSON.parseNodeMeters`, so this pin IS the shape the pane's
    // bus meters live on.

    /// Distinct per-node values must survive the parse — a constant fake, a
    /// value copied across nodes, or swapped peak/rms fields all fail here.
    func testParsesNodeMetersOffTheMetersRead() throws {
        let parsed = StudioRoutingJSON.parseNodeMeters(EngineJSON([
            "live": true,
            "tracks": [],
            "nodes": [
                ["nodeId": "revBus", "peakDb": -7.5, "rmsDb": -13.25],
                ["nodeId": "drums", "peakDb": -120.0, "rmsDb": -120.0],
            ],
        ]))
        XCTAssertEqual(parsed.count, 2)
        let rev = try XCTUnwrap(parsed["revBus"])
        XCTAssertEqual(rev.peakDB, -7.5, accuracy: 1e-9)
        XCTAssertEqual(rev.rmsDB, -13.25, accuracy: 1e-9)
        let drums = try XCTUnwrap(parsed["drums"])
        XCTAssertEqual(drums.peakDB, -120.0, accuracy: 1e-9,
                       "per-node values, verbatim — a meter is a measurement, not a decoration")
    }

    /// Absence semantics: no meters read at all, or a meters read without the
    /// `nodes` key (an older engine), parse to EMPTY — the pane then draws no
    /// bus meter, which is a different statement from drawing a silent one.
    func testAbsentNodeMetersParseToAbsenceNotSilence() {
        XCTAssertTrue(StudioRoutingJSON.parseNodeMeters(nil).isEmpty)
        XCTAssertTrue(StudioRoutingJSON.parseNodeMeters(EngineJSON(["live": false, "tracks": []])).isEmpty)
        // Half a reading is not a reading: an entry missing a dB field drops.
        let broken = StudioRoutingJSON.parseNodeMeters(EngineJSON([
            "nodes": [["nodeId": "x", "peakDb": -3.0]],
        ]))
        XCTAssertTrue(broken.isEmpty)
    }
}

#endif
