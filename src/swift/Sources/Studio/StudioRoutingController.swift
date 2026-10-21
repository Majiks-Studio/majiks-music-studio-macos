import SwiftUI

// MARK: - Routing + fx controller (E5-ui)
//
// Holds the routing/insert-chain state, resolves addressing, and turns each
// finished interaction into exactly ONE journaled command on the SAME command
// bus everything else in the Studio uses (`StudioEngineProtocol.send`). There is
// no direct model poke anywhere in this surface: undo puts every one of these
// back, and one user gesture is one undo step.
//
// The gesture routing lives HERE, not in the view, for the reason the piano
// roll's controller does: press / drag / release / commit are ordinary method
// calls, so an interaction can be driven end to end in a unit test and asserted
// against the engine's journal. "This gesture emitted exactly one journaled
// command, and undo reversed it" is then a proven property rather than a claim.
//
// What a test still cannot tell you is whether the chain FEELS like a chain —
// see the lane report.

@MainActor
final class StudioRoutingController: ObservableObject {

    // MARK: Engine truth

    let engine: any StudioEngineProtocol

    @Published private(set) var state = StudioRoutingState()

    /// Engine track ids in project order, with their display names. The wire
    /// addresses tracks by the ENGINE's id (`track.t1`); the rest of the Studio
    /// speaks UUIDs. This is the one translation, and it is asked of the engine
    /// rather than reconstructed here — a second id map that disagrees is two
    /// surfaces talking about different objects while looking identical.
    @Published private(set) var tracks: [StudioRoutingTrack] = []

    /// False when the engine has not published its track ids, so `track.<id>`
    /// cannot be addressed. Reported rather than guessed: sending a fabricated
    /// id would produce a refusal the user cannot act on.
    @Published private(set) var tracksAddressable = false

    /// False when the engine answered "I do not publish a routing graph" — a
    /// DIFFERENT statement from "the routing graph is empty", and collapsing the
    /// two would present a blank surface as if it were the project's truth.
    @Published private(set) var routingReadable = false

    /// Measured bus/group levels, keyed by node ref, read off the SAME project
    /// snapshot `reload()` already fetches (which carries the engine's meters
    /// read — `MeterBank` node slots, one read-and-reset consumer total).
    /// A node the engine did not report is ABSENT here, and the pane draws no
    /// meter for it: absence and silence are different statements, and a
    /// fabricated bar pinned at the floor is the defect this pane refuses.
    @Published private(set) var nodeMeters: [StudioNodeRef: StudioChannelMeter] = [:]

    // MARK: Selection / view state

    /// The chain host being edited. Master is the honest default: it is the one
    /// host that always exists.
    @Published var focus: StudioNodeRef = .master
    @Published var selectedFxID: String?
    /// Live reorder drag over the chain (index the slot would land at), or nil.
    @Published private(set) var chainDrag: StudioFxChainDrag?

    /// The engine's refusal text for the last command, cleared on the next one.
    /// Surfaced verbatim: the engine's message names the cap, the cycle path or
    /// the missing id, and paraphrasing it loses the thing the user needs.
    @Published private(set) var lastRefusal: String?

    private var pollTask: Task<Void, Never>?
    private var pendingDispatch: Task<Void, Never>?
    private var lastRevision: UInt64 = 0

    /// Ids handed out but not yet visible in `state`.
    ///
    /// Dispatch is asynchronous, so two fast gestures both mint from the SAME
    /// stale state and collide — and a colliding id is refused by the engine, so
    /// the second gesture would silently do nothing. Reservations are dropped
    /// once the id shows up in a reloaded state.
    private var reservedNodeIDs: Set<String> = []
    private var reservedEdgeIDs: Set<String> = []
    private var reservedFxIDs: [StudioNodeRef: Set<String>] = [:]

    init(engine: any StudioEngineProtocol) {
        self.engine = engine
    }

    // MARK: Lifecycle

    /// Adopt current engine state NOW, without starting the poll loop. This is
    /// the entry point the interaction tests drive: a background poll would make
    /// every assertion a race, and a test that races is a test that lies.
    func attach() async {
        await reload()
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reload()
                // 10 Hz. The graph changes at gesture rate; the bus meters ride
                // the same poll and stay honest at it, because the engine's
                // node peak slots are read-AND-RESET — each read is the true
                // peak over the whole 100 ms window, not a 10 Hz sample of an
                // instantaneous value, so a transient cannot fall between
                // polls. RMS is the latest block's, which a 100 ms cadence
                // shows as ballistics, not as loss.
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Wait for the last dispatched command (and its reload) to land.
    func settle() async {
        await pendingDispatch?.value
    }

    /// Re-read routing + chains + track addressing from the engine.
    func reload() async {
        if let snapshot = await engine.snapshot(ifNewerThan: nil) {
            lastRevision = snapshot.revision
            var resolved: [StudioRoutingTrack] = []
            var anyAddressable = false
            for t in snapshot.tracks {
                let engineID = await engine.routingTrackID(t.id)
                if engineID != nil { anyAddressable = true }
                resolved.append(StudioRoutingTrack(uuid: t.id, engineID: engineID,
                                                   name: t.name, kind: t.kind))
            }
            tracks = resolved
            tracksAddressable = anyAddressable
            // Bus meters ride the snapshot's meters read (one read-and-reset
            // consumer). Adopted verbatim, id -> ref; nothing is invented for
            // ids the engine did not report.
            nodeMeters = Dictionary(uniqueKeysWithValues:
                snapshot.nodeMeters.map { (StudioNodeRef.bus($0.key), $0.value) })
        }
        let read = await engine.routingState()
        routingReadable = read != nil
        state = read ?? StudioRoutingState()
        // Release the reservations the engine has now confirmed.
        reservedNodeIDs.subtract(state.nodes.map(\.id))
        reservedEdgeIDs.subtract(state.edges.map(\.id))
        for host in reservedFxIDs.keys {
            reservedFxIDs[host]?.subtract(state.chain(for: host).map(\.id))
            if reservedFxIDs[host]?.isEmpty == true { reservedFxIDs[host] = nil }
        }
        // A focused host can disappear (bus removed, track deleted). Fall back
        // to master rather than editing a chain that is not there.
        if !hostExists(focus) {
            focus = .master
            selectedFxID = nil
        }
        if let id = selectedFxID, state.fx(on: focus, id: id) == nil {
            selectedFxID = nil
        }
    }

    /// A bus that has been dispatched but not yet reloaded counts as existing:
    /// dispatch is serialized, so a chain added straight after creating the bus
    /// lands in the right order, and refusing it here would make a legal gesture
    /// fail for a reason the user cannot see.
    func hostExists(_ ref: StudioNodeRef) -> Bool {
        switch ref {
        case .master: return true
        case .bus(let id): return state.node(id) != nil || reservedNodeIDs.contains(id)
        case .track(let id): return tracks.contains { $0.engineID == id }
        }
    }

    // MARK: Display helpers

    /// Every addressable node, in the order the surface lists them.
    var hosts: [StudioNodeRef] {
        var out: [StudioNodeRef] = [.master]
        out.append(contentsOf: state.nodes.map { $0.ref })
        out.append(contentsOf: tracks.compactMap { $0.engineID.map { StudioNodeRef.track($0) } })
        return out
    }

    func displayName(_ ref: StudioNodeRef) -> String {
        switch ref {
        case .master: return "Master"
        case .bus(let id): return state.node(id)?.name ?? id
        case .track(let id): return tracks.first { $0.engineID == id }?.name ?? id
        }
    }

    /// The plain-language consequence of a node's current outgoing edges. This
    /// is the implicit-master-feed rule made visible: connecting a track to a
    /// group with a POST tap moves it, it does not copy it, and a user who does
    /// not know that will file "my track disappeared".
    func routingSummary(for ref: StudioNodeRef) -> String {
        if ref.isMaster { return "The mix bus. Everything ends up here." }
        let out = state.outgoing(from: ref)
        if out.isEmpty { return "Straight to master." }
        let posts = out.filter { $0.tap == .post }
        let pres = out.filter { $0.tap == .pre }
        var parts: [String] = []
        if posts.isEmpty {
            parts.append("Straight to master")
        } else {
            parts.append("Into " + posts.map { displayName($0.to) }.joined(separator: ", ")
                         + " (no direct master path)")
        }
        if !pres.isEmpty {
            parts.append("plus \(pres.count) pre-fader send\(pres.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ") + "."
    }

    // MARK: - Legality, mirrored so the surface can refuse before it sends
    //
    // The ENGINE is the authority (`validate_new_edge` / `validate_new_link`),
    // and every one of these commands is still validated there. These checks
    // exist so the UI can grey out an illegal move and say why, instead of
    // offering it and reporting a failure afterwards.

    /// nil when the connection is legal; otherwise the reason, in the user's
    /// terms. Mirrors DESIGN-E5 section 5.2's table.
    func connectionRefusal(from: StudioNodeRef, to: StudioNodeRef) -> String? {
        if from.isMaster { return "Master is the mix bus. Nothing routes out of it." }
        if from == to { return "A node cannot feed itself." }
        guard hostExists(from) else { return "\(displayName(from)) is not in this project." }
        guard hostExists(to) else { return "\(displayName(to)) is not in this project." }
        let edgeCount = state.edges.count + reservedEdgeIDs.count
        if edgeCount >= StudioRoutingCaps.maxEdges {
            return "This project already has \(edgeCount) connections (the limit is \(StudioRoutingCaps.maxEdges))."
        }
        if let path = cyclePath(adding: from, to) {
            return "That would make a loop: " + path.map { displayName($0) }.joined(separator: " -> ") + "."
        }
        return nil
    }

    /// nil when `source` may key an fx on `host`. Mirrors DESIGN-E5 section 18.3.
    func sidechainRefusal(source: StudioNodeRef, host: StudioNodeRef) -> String? {
        if source.isMaster { return "Master is the mix bus and can never be a key source." }
        if source == host { return "That is the effect's own input — clear the sidechain instead." }
        guard hostExists(source) else { return "\(displayName(source)) is not in this project." }
        if let path = cyclePath(adding: source, host) {
            return "That key would make a loop: " + path.map { displayName($0) }.joined(separator: " -> ") + "."
        }
        return nil
    }

    /// The cycle a new `from -> to` link would close, or nil. Walks BOTH audio
    /// edges and sidechain links, because a sidechain is an ordering constraint
    /// and participates in cycle detection exactly like an edge even though it
    /// carries no audio.
    func cyclePath(adding from: StudioNodeRef, _ to: StudioNodeRef) -> [StudioNodeRef]? {
        if from == to { return [from, to] }
        var adjacency: [StudioNodeRef: [StudioNodeRef]] = [:]
        for e in state.edges { adjacency[e.from, default: []].append(e.to) }
        for (src, host) in state.sidechainLinks { adjacency[src, default: []].append(host) }
        // A cycle appears iff `to` can already reach `from`.
        var stack: [[StudioNodeRef]] = [[to]]
        var seen: Set<StudioNodeRef> = [to]
        while let path = stack.popLast() {
            guard let tail = path.last else { continue }
            for next in adjacency[tail] ?? [] {
                if next == from { return path + [from] }
                if seen.insert(next).inserted { stack.append(path + [next]) }
            }
        }
        return nil
    }

    // MARK: - Mutations. Every one is exactly ONE journaled command.

    /// Create a bus or group. Returns the id it minted, or nil when refused.
    ///
    /// The name is set HERE and only here: the catalog has no rename command,
    /// and synthesizing one out of remove + add would destroy the node's whole
    /// insert chain and cost two undo steps for one gesture. See the lane report.
    @discardableResult
    func addBus(kind: StudioRouteNodeKind, name: String) -> String? {
        let nodeCount = state.nodes.count + reservedNodeIDs.count
        guard nodeCount < StudioRoutingCaps.maxNodes else {
            lastRefusal = "This project already has \(nodeCount) buses (the limit is \(StudioRoutingCaps.maxNodes))."
            return nil
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let display = trimmed.isEmpty ? (kind == .bus ? "Bus" : "Group") : trimmed
        let id = mintNodeID(from: display)
        dispatch(.nodeAdd(nodeID: id, kind: kind, name: display))
        return id
    }

    func removeBus(_ id: String) {
        guard state.node(id) != nil else { return }
        dispatch(.nodeRemove(nodeID: id))
    }

    /// The bus/group fader: one `route.node.set`, dB, clamped to the command's
    /// own schema range so the knob cannot travel to a value the engine will
    /// refuse. Self-inverse engine-side — one gesture, one undo step back to
    /// the prior gain. (A `bus.<id>.gain` automation lane, when present,
    /// takes precedence over this static value; the fader row says so.)
    func setNodeGain(_ nodeID: String, gainDB: Double) {
        guard state.node(nodeID) != nil else { return }
        dispatch(.nodeSet(nodeID: nodeID, gainDB: Self.clampNodeGainDB(gainDB)))
    }

    static func clampNodeGainDB(_ db: Double) -> Double {
        min(StudioRoutingCaps.nodeGainMaxDB, max(StudioRoutingCaps.nodeGainMinDB, db))
    }

    /// Connect `from` into `to`. Returns the minted edge id, or nil when refused.
    @discardableResult
    func connect(from: StudioNodeRef, to: StudioNodeRef,
                 level: Double = 1.0, tap: StudioTap = .post) -> String? {
        if let why = connectionRefusal(from: from, to: to) {
            lastRefusal = why
            return nil
        }
        let id = mintEdgeID()
        dispatch(.connect(edgeID: id, from: from, to: to,
                          level: Self.clampLevel(level), tap: tap))
        return id
    }

    func disconnect(_ edgeID: String) {
        guard state.edges.contains(where: { $0.id == edgeID }) else { return }
        dispatch(.disconnect(edgeID: edgeID))
    }

    /// One `route.edge.set`: level AND tap together, because the command carries
    /// both and splitting it would make one gesture two undo steps.
    func setEdge(_ edgeID: String, level: Double, tap: StudioTap) {
        guard state.edges.contains(where: { $0.id == edgeID }) else { return }
        dispatch(.edgeSet(edgeID: edgeID, level: Self.clampLevel(level), tap: tap))
    }

    func setEdgeLevel(_ edgeID: String, level: Double) {
        guard let e = state.edges.first(where: { $0.id == edgeID }) else { return }
        setEdge(edgeID, level: level, tap: e.tap)
    }

    func setEdgeTap(_ edgeID: String, tap: StudioTap) {
        guard let e = state.edges.first(where: { $0.id == edgeID }) else { return }
        setEdge(edgeID, level: e.level, tap: tap)
    }

    /// Append an effect to a chain. Returns the minted fx id, or nil.
    @discardableResult
    func addFx(to host: StudioNodeRef, kind: StudioFxKind) -> String? {
        let chainCount = pendingChainCount(host)
        guard chainCount < StudioRoutingCaps.maxFxPerChain else {
            lastRefusal = "This chain already has \(chainCount) effects (the limit is \(StudioRoutingCaps.maxFxPerChain))."
            return nil
        }
        guard pendingTotalFxCount < StudioRoutingCaps.maxFxTotal else {
            lastRefusal = "This project already has \(pendingTotalFxCount) effects (the limit is \(StudioRoutingCaps.maxFxTotal))."
            return nil
        }
        guard hostExists(host) else {
            lastRefusal = "\(displayName(host)) is not in this project."
            return nil
        }
        let id = mintFxID(kind: kind, on: host)
        dispatch(.fxAdd(target: host, fxID: id, kind: kind))
        selectedFxID = id
        return id
    }

    func removeFx(from host: StudioNodeRef, id: String) {
        guard state.fx(on: host, id: id) != nil else { return }
        dispatch(.fxRemove(target: host, fxID: id))
        if selectedFxID == id { selectedFxID = nil }
    }

    /// Reorder within the chain. Chain order IS signal order, so this changes
    /// the sound; it is one self-inverse command.
    func moveFx(on host: StudioNodeRef, id: String, toIndex index: Int) {
        let chain = state.chain(for: host)
        guard let current = chain.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(0, min(chain.count - 1, index))
        guard clamped != current else { return }   // a no-op undo step is worse than no step
        dispatch(.fxMove(target: host, fxID: id, index: clamped))
    }

    /// Set one effect parameter. Never used for `bypass` — see `setFxBypass`.
    func setFxParam(on host: StudioNodeRef, id: String, key: String, value: Double) {
        // A visible refusal rather than an `assertionFailure`: a trap would be a
        // crash in a debug build for something a test should be able to prove,
        // and this is the guard that keeps `bypass` from acquiring a second,
        // desyncing spelling.
        guard key != studioFxBypassKey else {
            lastRefusal = "Bypass is not a parameter — it has its own control."
            return
        }
        guard let fx = state.fx(on: host, id: id) else { return }
        // The second half of the same guard, and the one that also catches a key
        // the kind simply does not have: no kind lists `bypass`, by construction
        // (`testBypassIsNeverOfferedAsAParameter` pins that), so bypass is
        // refused twice over. Deliberate belt and braces — the explicit check
        // above states the intent, this one enforces it against the tables.
        guard let spec = fx.kind.spec(for: key) else {
            lastRefusal = "\(fx.kind.label) has no \(key) parameter."
            return
        }
        dispatch(.fxParamSet(target: host, fxID: id, key: key, value: spec.clamp(value)))
    }

    /// Return a parameter to the DSP default by making it ABSENT again, which is
    /// what sparsity means. Writing the default value instead would look
    /// identical and be a different fact.
    func clearFxParam(on host: StudioNodeRef, id: String, key: String) {
        guard let fx = state.fx(on: host, id: id), fx.isSet(key) else { return }
        dispatch(.fxParamClear(target: host, fxID: id, key: key))
    }

    /// The ONLY writer of the bypass key in this surface.
    ///
    /// Bypass occupies no render-side parameter slot: `EngineParams::fx_bypassed`
    /// is the only read path, and the wire spelling `fx.param.set {key:
    /// "bypass"}` is the only spelling the catalog has. Keeping it off the
    /// parameter grid and behind this one method is what stops it becoming a
    /// second, desynced way to say the same thing.
    func setFxBypass(on host: StudioNodeRef, id: String, bypassed: Bool) {
        guard state.fx(on: host, id: id) != nil else { return }
        dispatch(.fxParamSet(target: host, fxID: id,
                             key: studioFxBypassKey, value: bypassed ? 1 : 0))
    }

    func setSidechain(on host: StudioNodeRef, id: String, source: StudioNodeRef) {
        guard let fx = state.fx(on: host, id: id) else { return }
        guard fx.kind.acceptsSidechain else {
            lastRefusal = "\(fx.kind.label) has no keyable detector, so a sidechain would do nothing."
            return
        }
        if let why = sidechainRefusal(source: source, host: host) {
            lastRefusal = why
            return
        }
        dispatch(.sidechainSet(target: host, fxID: id, source: source))
    }

    func clearSidechain(on host: StudioNodeRef, id: String) {
        guard let fx = state.fx(on: host, id: id), fx.sidechain != nil else { return }
        dispatch(.sidechainClear(target: host, fxID: id))
    }

    // MARK: Chain reorder drag (the interaction, drivable from a test)

    func beginChainDrag(fxID: String, at point: CGPoint, layout: StudioFxChainLayout) {
        guard state.chain(for: focus).contains(where: { $0.id == fxID }) else { return }
        chainDrag = StudioFxChainDrag(fxID: fxID, dropIndex: layout.dropIndex(forX: point.x))
    }

    func updateChainDrag(to point: CGPoint, layout: StudioFxChainLayout) {
        guard var drag = chainDrag else { return }
        drag.dropIndex = layout.dropIndex(forX: point.x)
        chainDrag = drag
    }

    /// Commit the reorder: exactly one `fx.move`, or nothing at all when the
    /// slot did not change.
    func endChainDrag() {
        guard let drag = chainDrag else { return }
        chainDrag = nil
        moveFx(on: focus, id: drag.fxID, toIndex: drag.dropIndex)
    }

    func cancelChainDrag() { chainDrag = nil }

    // MARK: Dispatch

    /// One command, in order, then a reload. Serialized behind the previous
    /// dispatch so two fast gestures cannot land out of order.
    private func dispatch(_ command: StudioRoutingCommand) {
        lastRefusal = nil
        let previous = pendingDispatch
        pendingDispatch = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let result = await self.engine.send(command.engineCommand)
            if !result.ok { self.lastRefusal = result.message }
            await self.reload()
        }
    }

    // MARK: Id minting
    //
    // Deterministic and readable (`revBus`, `e1`, `comp2`) rather than a UUID:
    // these ids appear verbatim in the journal, in `project.json`, and inside
    // every ParamRef path (`bus.<nodeId>.fx.<fxId>.<paramKey>`), so a human
    // reading a journal should be able to tell what they are looking at.

    private func mintNodeID(from name: String) -> String {
        let base = Self.slug(name, fallback: "bus")
        let id = Self.unique(base, taken: Set(state.nodes.map(\.id)).union(reservedNodeIDs))
        reservedNodeIDs.insert(id)
        return id
    }

    private func mintEdgeID() -> String {
        let id = Self.unique("e", taken: Set(state.edges.map(\.id)).union(reservedEdgeIDs))
        reservedEdgeIDs.insert(id)
        return id
    }

    private func mintFxID(kind: StudioFxKind, on host: StudioNodeRef) -> String {
        let taken = Set(state.chain(for: host).map(\.id))
            .union(reservedFxIDs[host] ?? [])
        let id = Self.unique(kind.rawValue, taken: taken)
        reservedFxIDs[host, default: []].insert(id)
        return id
    }

    /// Chain length INCLUDING ids already dispatched but not yet reloaded, so a
    /// burst of clicks cannot walk past the cap.
    private func pendingChainCount(_ host: StudioNodeRef) -> Int {
        state.chain(for: host).count + (reservedFxIDs[host]?.count ?? 0)
    }

    private var pendingTotalFxCount: Int {
        state.totalFxCount + reservedFxIDs.values.reduce(0) { $0 + $1.count }
    }

    /// `^[A-Za-z0-9_-]+$` — the charset every id in this family shares.
    static func slug(_ s: String, fallback: String) -> String {
        let cleaned = String(s.map { c in
            (c.isASCII && (c.isLetter || c.isNumber)) ? c : "-"
        }).split(separator: "-").joined(separator: "-")
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(24))
    }

    static func unique(_ base: String, taken: Set<String>) -> String {
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)\(n)") { n += 1 }
        return "\(base)\(n)"
    }

    static func clampLevel(_ v: Double) -> Double { min(4, max(0, v)) }
}

/// One track, as the routing surface needs it: the UI's UUID, the ENGINE's id
/// (nil when the engine has not published one), and its display name.
struct StudioRoutingTrack: Identifiable, Hashable, Sendable {
    var uuid: UUID
    var engineID: String?
    var name: String
    var kind: StudioStemKind

    var id: UUID { uuid }
    var ref: StudioNodeRef? { engineID.map { .track($0) } }
}

struct StudioFxChainDrag: Equatable, Sendable {
    var fxID: String
    var dropIndex: Int
}

// MARK: - The wire shapes
//
// ONE place that knows how a routing/fx gesture is spelled on the bus. Pure and
// testable: `wire` is asserted directly against the catalog's params, so a typo
// is a failing test rather than a runtime refusal nobody sees.
//
// These ride the generic catalog envelope (`StudioEngineCommand.catalog`), the
// same path the midi.* config verbs use, because they carry ready wire params
// and are addressed by NodeRef rather than by any UI geometry.

enum StudioRoutingCommand: Equatable, Sendable {
    case nodeAdd(nodeID: String, kind: StudioRouteNodeKind, name: String)
    case nodeRemove(nodeID: String)
    /// The bus/group fader (`route.node.set`, catalog v2 #113). dB on the
    /// wire, self-inverse engine-side (undo carries the prior gain).
    case nodeSet(nodeID: String, gainDB: Double)
    case connect(edgeID: String, from: StudioNodeRef, to: StudioNodeRef, level: Double, tap: StudioTap)
    case disconnect(edgeID: String)
    case edgeSet(edgeID: String, level: Double, tap: StudioTap)
    case fxAdd(target: StudioNodeRef, fxID: String, kind: StudioFxKind)
    case fxRemove(target: StudioNodeRef, fxID: String)
    case fxMove(target: StudioNodeRef, fxID: String, index: Int)
    case fxParamSet(target: StudioNodeRef, fxID: String, key: String, value: Double)
    case fxParamClear(target: StudioNodeRef, fxID: String, key: String)
    case sidechainSet(target: StudioNodeRef, fxID: String, source: StudioNodeRef)
    case sidechainClear(target: StudioNodeRef, fxID: String)

    var wire: (name: String, params: [String: AnyHashable]) {
        switch self {
        case .nodeAdd(let id, let kind, let name):
            return ("route.node.add", ["nodeId": id, "kind": kind.rawValue, "name": name])
        case .nodeRemove(let id):
            return ("route.node.remove", ["nodeId": id])
        case .nodeSet(let id, let gainDB):
            return ("route.node.set", ["nodeId": id, "gainDb": gainDB])
        case .connect(let id, let from, let to, let level, let tap):
            return ("route.connect", ["edgeId": id, "from": from.wireName, "to": to.wireName,
                                      "level": level, "tap": tap.rawValue])
        case .disconnect(let id):
            return ("route.disconnect", ["edgeId": id])
        case .edgeSet(let id, let level, let tap):
            return ("route.edge.set", ["edgeId": id, "level": level, "tap": tap.rawValue])
        case .fxAdd(let target, let fxID, let kind):
            return ("fx.add", ["target": target.wireName, "fxId": fxID, "kind": kind.rawValue])
        case .fxRemove(let target, let fxID):
            return ("fx.remove", ["target": target.wireName, "fxId": fxID])
        case .fxMove(let target, let fxID, let index):
            return ("fx.move", ["target": target.wireName, "fxId": fxID, "index": index])
        case .fxParamSet(let target, let fxID, let key, let value):
            return ("fx.param.set", ["target": target.wireName, "fxId": fxID,
                                     "key": key, "value": value])
        case .fxParamClear(let target, let fxID, let key):
            return ("fx.param.clear", ["target": target.wireName, "fxId": fxID, "key": key])
        case .sidechainSet(let target, let fxID, let source):
            return ("fx.sidechain.set", ["target": target.wireName, "fxId": fxID,
                                         "source": source.wireName])
        case .sidechainClear(let target, let fxID):
            return ("fx.sidechain.clear", ["target": target.wireName, "fxId": fxID])
        }
    }

    var engineCommand: StudioEngineCommand {
        let w = wire
        return .catalog(name: w.name, params: w.params)
    }
}

// MARK: - Chain layout (pure math, so the interaction is testable)
//
// Slot geometry for the effect chain. Kept out of the view for the same reason
// the piano roll keeps its layout out of the view: a drag is then a method call
// on numbers, and "the drag emitted one fx.move to index 2" is assertable.

struct StudioFxChainLayout: Equatable, Sendable {
    var slotWidth: CGFloat = 86
    var slotSpacing: CGFloat = 6
    var slotHeight: CGFloat = 46
    var count: Int = 0
    /// Horizontal offset applied to the whole row when the chain is wider than
    /// the viewport. An EXPLICIT transform, deliberately not a horizontal
    /// ScrollView: on macOS a horizontal ScrollView claims the mouse-down as a
    /// possible pan and silently eats Button presses and zero-distance drags —
    /// which is exactly the gesture a chain slot needs.
    var scrollX: CGFloat = 0

    var pitch: CGFloat { slotWidth + slotSpacing }

    /// Content width of `count` slots plus the trailing "+" slot.
    var contentWidth: CGFloat {
        CGFloat(count + 1) * pitch - slotSpacing
    }

    func rect(at index: Int) -> CGRect {
        CGRect(x: CGFloat(index) * pitch - scrollX, y: 0,
               width: slotWidth, height: slotHeight)
    }

    /// The trailing "add an effect" slot.
    var addRect: CGRect { rect(at: count) }

    /// Which slot a point is over, or nil (including the add slot, which is
    /// `count`).
    func slotIndex(at point: CGPoint) -> Int? {
        guard point.y >= 0, point.y <= slotHeight else { return nil }
        let x = point.x + scrollX
        guard x >= 0 else { return nil }
        let index = Int(x / pitch)
        guard index >= 0, index <= count else { return nil }
        // Reject the gap between slots so a click there does nothing rather
        // than landing on whichever neighbour is nearer.
        let within = x - CGFloat(index) * pitch
        return within <= slotWidth ? index : nil
    }

    /// Where a reorder drag would drop, clamped to the chain.
    func dropIndex(forX x: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        let shifted = x + scrollX
        let raw = Int(((shifted + slotWidth / 2) / pitch).rounded(.down))
        return max(0, min(count - 1, raw))
    }

    /// Scroll offset that keeps `index` visible in `viewportWidth`. Explicit,
    /// clamped, and the only thing that ever moves the row.
    func scrollOffset(toShow index: Int, viewportWidth: CGFloat) -> CGFloat {
        let maxScroll = max(0, contentWidth - viewportWidth)
        let slotX = CGFloat(index) * pitch
        if slotX < scrollX { return min(maxScroll, max(0, slotX)) }
        let slotEnd = slotX + slotWidth
        if slotEnd > scrollX + viewportWidth {
            return min(maxScroll, max(0, slotEnd - viewportWidth))
        }
        return min(maxScroll, max(0, scrollX))
    }
}

// MARK: - Send level taper
//
// `route.connect` / `route.edge.set` carry a LINEAR level, 0...4 (unity 1.0,
// +12 dB at 4). Faders in this app are calibrated in dB, so the surface shows
// dB and converts once, here.

enum StudioSendTaper {
    static let minDB = -60.0
    /// 20*log10(4) rounded down to the tick the fader can actually reach.
    static let maxDB = 12.0

    static func levelToDB(_ level: Double) -> Double {
        level <= 0 ? minDB : max(minDB, min(maxDB, 20 * log10(level)))
    }

    static func dbToLevel(_ db: Double) -> Double {
        db <= minDB ? 0 : min(4, pow(10, db / 20))
    }
}
