import Foundation

// MARK: - Reading the routing graph off the real engine (E5-ui)
//
// `RealStudioEngine.buildSnapshot` maps the engine's project JSON onto
// `StudioProjectSnapshot`, which is the timeline + mixer read and deliberately
// does not carry a routing graph. Rather than widen that 30 Hz payload with a
// graph nothing on it looks at, the routing surface reads what it needs
// directly, off the SAME engine handle and the SAME project JSON.
//
// It works because the engine's project JSON is `serde_json::to_value(Project)`
// — the whole model, verbatim — so `routing`, every track's `fx`, and the master
// bus's `fx` are already in the payload the moment E5-model landed them; the
// GRAPH read needed no engine-side change. The bus METERS did need one, made in
// the E5-ui-truth pass: `MeterBank`'s node slots existed render-side with no
// reader, so the host's meters read now exposes them (`host.rs meters()` ->
// `"nodes"`, via `LiveAudio::node_meters`), and `parseNodeMeters` below is the
// Swift half of that contract.
//
// This lives in `Sources/Studio` (E5-ui's own area) rather than in
// `Sources/Engine`, and is compiled only in a real-engine build.

#if REAL_ENGINE

extension RealStudioEngine {

    /// Forward to the id map the engine already keeps — the SAME one the
    /// arrangement and the piano roll translate through, so a track means the
    /// same object in all three surfaces.
    func routingTrackID(_ id: UUID) async -> String? { engineTrackID(id) }

    /// The routing DAG plus every insert chain, parsed from the engine's project
    /// JSON. Returns nil only when the engine could not be read at all — an
    /// EMPTY graph comes back as an empty state, because "no buses" and "I
    /// cannot tell you" are different answers.
    func routingState() async -> StudioRoutingState? {
        guard let root = try? noteClient.snapshot(sinceSeq: nil),
              let project = root.dict("project") else { return nil }
        return StudioRoutingJSON.parseProject(EngineJSON(project))
    }
}

/// The parser. Separated from the actor so it is a pure function of JSON and
/// can be exercised without an engine handle.
enum StudioRoutingJSON {

    static func parseProject(_ project: EngineJSON) -> StudioRoutingState {
        var state = StudioRoutingState()

        // `routing` is omitted entirely when empty (`skip_serializing_if =
        // "Routing::is_empty"`), which is the v1 topology and is NOT an error.
        if let routing = project.dict("routing") {
            let rj = EngineJSON(routing)
            state.nodes = rj.array("nodes").compactMap(parseNode)
            state.edges = rj.array("edges").compactMap(parseEdge)
        }

        for t in project.array("tracks") {
            let tj = EngineJSON(t)
            guard let id = tj.string("id", "trackId") else { continue }
            let chain = tj.array("fx").compactMap(parseFx)
            if !chain.isEmpty { state.trackFx[id] = chain }
        }

        if let master = project.dict("master") {
            state.masterFx = EngineJSON(master).array("fx").compactMap(parseFx)
        }
        return state
    }

    static func parseNode(_ raw: [String: Any]) -> StudioRouteNode? {
        let j = EngineJSON(raw)
        guard let id = j.string("id"),
              let kind = j.string("kind").flatMap(StudioRouteNodeKind.init(rawValue:))
        else { return nil }
        return StudioRouteNode(
            id: id, kind: kind, name: j.string("name") ?? id,
            // `gain_db` is omitted from serde while it is the default 0 dB
            // (`RouteNode::gain_db`, skip_serializing_if), so absence IS 0 —
            // an unset fader, not a parse failure.
            gainDB: j.double("gain_db", "gainDb") ?? 0,
            fx: j.array("fx").compactMap(parseFx))
    }

    static func parseEdge(_ raw: [String: Any]) -> StudioRouteEdge? {
        let j = EngineJSON(raw)
        guard let id = j.string("id"),
              let from = j.string("from").flatMap(StudioNodeRef.parse),
              let to = j.string("to").flatMap(StudioNodeRef.parse),
              let tap = j.string("tap").flatMap(StudioTap.init(rawValue:))
        else { return nil }
        return StudioRouteEdge(id: id, from: from, to: to,
                               level: j.double("level") ?? 1.0, tap: tap)
    }

    /// The meters read's `nodes` array (`host.rs meters()`) -> node id keyed
    /// dBFS readings. E5 §8: these are MEASURED — `MeterBank`'s node slots,
    /// flushed once per block by the render walk — and the entry order is
    /// `routing.nodes` order, though this map deliberately does not care.
    ///
    /// nil / absent-key both parse to [:], which downstream means "this engine
    /// publishes no node meters" and draws NOTHING — never a silent bar. An
    /// entry missing either dB field is dropped rather than defaulted: half a
    /// reading is not a reading.
    static func parseNodeMeters(_ meters: EngineJSON?) -> [String: StudioChannelMeter] {
        guard let meters else { return [:] }
        var out: [String: StudioChannelMeter] = [:]
        for m in meters.array("nodes") {
            let mj = EngineJSON(m)
            guard let id = mj.string("nodeId"),
                  let peak = mj.double("peakDb"),
                  let rms = mj.double("rmsDb") else { continue }
            out[id] = StudioChannelMeter(peakDB: peak, rmsDB: rms)
        }
        return out
    }

    static func parseFx(_ raw: [String: Any]) -> StudioFx? {
        let j = EngineJSON(raw)
        guard let id = j.string("id"),
              let kind = j.string("kind").flatMap(StudioFxKind.init(rawValue:))
        else { return nil }
        // `params` is omitted when empty (sparsity is the contract), so an
        // absent map is a correctly-configured effect on its defaults, not a
        // parse failure.
        var params: [String: Double] = [:]
        for (k, v) in (raw["params"] as? [String: Any]) ?? [:] {
            if let n = v as? NSNumber { params[k] = n.doubleValue }
        }
        return StudioFx(
            id: id, kind: kind, params: params,
            sidechain: j.string("sidechain").flatMap(StudioNodeRef.parse))
    }
}

#endif
