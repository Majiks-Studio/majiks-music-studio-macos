import Foundation

// MARK: - Routing + effects value types (E5-ui)
//
// The Swift mirror of the E5 contract surface: the routing DAG
// (`route.node.add` / `route.connect` / `route.disconnect` / `route.edge.set`)
// and the separate `Fx` insert registry (`fx.add` / `fx.remove` / `fx.move` /
// `fx.param.set` / `fx.param.clear` / `fx.sidechain.set` / `fx.sidechain.clear`).
//
// Every type here mirrors an engine type ONE FOR ONE and does not invent a
// second spelling of anything:
//
//  - `StudioNodeRef`   <- `timeline_core::routing::NodeRef` (`master` |
//                          `track.<id>` | `bus.<id>`). ONE addressing scheme for
//                          "where does this live", which is what makes a master
//                          effect chain fall out for free (DESIGN-E5 section 16.2).
//  - `StudioFxKind`    <- `timeline_core::model::FxKind`, closed, lowercase wire.
//  - the param tables  <- `render/src/dsp/fx.rs`'s `FxParamSpec` consts. Key,
//                          default, min and max are copied from there so a knob
//                          cannot travel somewhere the DSP will clamp away.
//
// EQ keys are FLAT (`band0Gain`, never `band.0.gain`): the ParamRef grammar
// gives an fx exactly ONE param segment, so a nested spelling would not parse
// as `track.fx.<fxId>.<paramKey>` at all.

// MARK: - Node addressing

/// Where a chain lives, or an edge starts/ends. Serialized as the engine's own
/// wire grammar, so this string goes straight into a command's `target`,
/// `from`, `to` or `source`.
enum StudioNodeRef: Hashable, Sendable {
    case master
    /// The ENGINE's track id (`t1`), not the UI's UUID. `StudioRoutingController`
    /// resolves UUID -> engine id through the engine itself; there is no second
    /// id map here.
    case track(String)
    /// A user-created bus or group. The wire prefix is `bus.` for BOTH kinds
    /// because the prefix names the namespace, not the kind.
    case bus(String)

    var wireName: String {
        switch self {
        case .master: return "master"
        case .track(let id): return "track.\(id)"
        case .bus(let id): return "bus.\(id)"
        }
    }

    static func parse(_ s: String) -> StudioNodeRef? {
        if s == "master" { return .master }
        if let rest = s.stripPrefixIfPresent("track."), isValidID(rest) { return .track(rest) }
        if let rest = s.stripPrefixIfPresent("bus."), isValidID(rest) { return .bus(rest) }
        return nil
    }

    /// `^[A-Za-z0-9_-]+$`, the charset every id in this family shares. A `.` in
    /// an fx id would break `track.fx.<fxId>.<paramKey>` parsing, which is why
    /// the catalog pins the same pattern.
    static func isValidID(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "-")
        }
    }

    var isMaster: Bool { if case .master = self { return true }; return false }
    var busID: String? { if case .bus(let id) = self { return id }; return nil }
    var trackID: String? { if case .track(let id) = self { return id }; return nil }
}

private extension String {
    func stripPrefixIfPresent(_ p: String) -> String? {
        hasPrefix(p) ? String(dropFirst(p.count)) : nil
    }
}

/// Whether an edge taps its source before or after that source's fader.
///
/// `post` is the tap point v1 already had (post-fader, post-pan, post-EQ).
/// `pre` is post-pan, PRE-EQ, pre-fader — a deliberate divergence from what
/// Live and Logic call pre-fader, documented in DESIGN-E5 section 3.2, and it is
/// stated in the UI rather than buried: a pre-fader send does not carry the
/// channel EQ.
enum StudioTap: String, Hashable, Sendable, CaseIterable {
    case pre, post

    var label: String { self == .pre ? "PRE" : "POST" }

    /// The one-line consequence a user needs when they flip this.
    var note: String {
        switch self {
        case .post:
            return "Post-fader, post-pan, post-EQ. Muting or soloing the source silences this send."
        case .pre:
            return "Pre-fader, so pulling the fader down leaves the send up — but PRE-EQ: this send does not carry the channel EQ. Mute and solo still silence it."
        }
    }
}

enum StudioRouteNodeKind: String, Hashable, Sendable, CaseIterable {
    case bus, group

    var label: String { self == .bus ? "Bus" : "Group" }
    var blurb: String {
        self == .bus
            ? "An aux destination fed by sends. Sources keep their direct path to master."
            : "A submix. A track routed into a group with a post tap feeds the group INSTEAD of master."
    }
}

// MARK: - Effect kinds and their parameters

/// Closed, exactly like the engine's `FxKind`: an unknown kind must fail loudly
/// at the contract boundary rather than build a silent no-op node.
enum StudioFxKind: String, Hashable, Sendable, CaseIterable {
    case eq, compressor, gate, delay, reverb, saturator, chorus, utility, limiter

    var label: String {
        switch self {
        case .eq: return "EQ"
        case .compressor: return "Compressor"
        case .gate: return "Gate"
        case .delay: return "Delay"
        case .reverb: return "Reverb"
        case .saturator: return "Saturator"
        case .chorus: return "Chorus"
        case .utility: return "Utility"
        case .limiter: return "Limiter"
        }
    }

    /// Short glyph for the chain slot.
    var badge: String {
        switch self {
        case .eq: return "EQ"
        case .compressor: return "CMP"
        case .gate: return "GATE"
        case .delay: return "DLY"
        case .reverb: return "REV"
        case .saturator: return "SAT"
        case .chorus: return "CHR"
        case .utility: return "UTIL"
        case .limiter: return "LIM"
        }
    }

    /// Frames of latency this kind reports (`FxKindId::latency_frames`). Only
    /// the limiter is non-zero, and it does NOT vary with bypass — a latency
    /// that changed with the switch would make delay compensation wrong exactly
    /// when a user toggles it.
    var latencyFrames: Int {
        self == .limiter ? 96 : 0
    }

    /// Only the compressor and the gate have a keyable detector, so only they
    /// can take a sidechain source. Offering it on the others would be a
    /// control that does nothing.
    var acceptsSidechain: Bool {
        self == .compressor || self == .gate
    }

    /// The parameter block, in the engine's own slot order. Index here IS the
    /// offset from the fx's `base_slot` render-side.
    var params: [StudioFxParamSpec] {
        switch self {
        case .eq: return StudioFxParamSpec.eq
        case .compressor: return StudioFxParamSpec.compressor
        case .gate: return StudioFxParamSpec.gate
        case .delay: return StudioFxParamSpec.delay
        case .reverb: return StudioFxParamSpec.reverb
        case .saturator: return StudioFxParamSpec.saturator
        case .chorus: return StudioFxParamSpec.chorus
        case .utility: return StudioFxParamSpec.utility
        case .limiter: return StudioFxParamSpec.limiter
        }
    }

    func spec(for key: String) -> StudioFxParamSpec? {
        params.first { $0.key == key }
    }
}

/// One effect parameter: the wire key plus the range and default the DSP will
/// actually honour.
///
/// `defaultValue` matters more than it looks: parameters stay SPARSE on the
/// wire, so an absent key means "the DSP default". A knob that showed 0 for an
/// unset `ratio` would be lying about what the effect is doing.
struct StudioFxParamSpec: Hashable, Sendable, Identifiable {
    var key: String
    var label: String
    var unit: String
    var defaultValue: Double
    var minValue: Double
    var maxValue: Double
    /// A two-state parameter (`detector`, `polarity`): drawn as a switch, not a
    /// knob, because a knob implies a continuum that the DSP does not have.
    var isSwitch: Bool = false
    /// Whether an automation LANE on this key has a per-frame reader
    /// (`FxNode::set_frame_param`). Mirrors `render/src/dsp/fx.rs`'s
    /// `FxParamRate` per key: `p(...)` rows there are `Frame` (true here),
    /// `pb(...)` rows are `Block` COEFFICIENTS — attack/release envelope
    /// one-poles and all 12 EQ band keys — which the engine refuses per key,
    /// loudly, with the points kept. The engine's classifier
    /// (`fx_key_class`) is not reachable across the FFI, so this is a
    /// MIRRORED table; `testFxParamAutomatabilityMirrorsTheEngineSpec` pins
    /// every row against a transcription of the engine's, so drift is a
    /// failing test rather than a quiet lie.
    var automatable: Bool = true

    var id: String { key }

    /// The KIND of number this is, for the typed field and its arrows.
    ///
    /// Derived from `unit` rather than listed per key on purpose: `unit` is
    /// already transcribed from `render/src/dsp/fx.rs` alongside the range and
    /// the default, so this mapping covers all 38 `FX_PARAM_KEYS` at once and
    /// a new DSP parameter inherits sensible stepping the moment its row is
    /// added. A per-key table here would be a 38-row copy waiting to drift.
    var paramUnit: StudioParamUnit { StudioParamUnit.forSpecUnit(unit) }

    func clamp(_ v: Double) -> Double { min(maxValue, max(minValue, v)) }

    func format(_ v: Double) -> String {
        if isSwitch { return v >= 0.5 ? switchOnLabel : switchOffLabel }
        let digits = (maxValue - minValue) <= 4 ? 2 : (maxValue <= 100 ? 1 : 0)
        return unit.isEmpty
            ? String(format: "%.\(digits)f", v)
            : String(format: "%.\(digits)f %@", v, unit)
    }

    var switchOnLabel: String { key == "detector" ? "RMS" : "INV" }
    var switchOffLabel: String { key == "detector" ? "PEAK" : "NORM" }

    private static func p(_ key: String, _ label: String, _ unit: String,
                          _ def: Double, _ lo: Double, _ hi: Double,
                          isSwitch: Bool = false) -> StudioFxParamSpec {
        StudioFxParamSpec(key: key, label: label, unit: unit,
                          defaultValue: def, minValue: lo, maxValue: hi,
                          isSwitch: isSwitch)
    }

    /// A `Block`-rate COEFFICIENT row — `pb(...)` in `render/src/dsp/fx.rs`,
    /// the same helper name on purpose so the two tables diff line for line.
    /// An automation lane on such a key is refused per key by the engine.
    private static func pb(_ key: String, _ label: String, _ unit: String,
                           _ def: Double, _ lo: Double, _ hi: Double) -> StudioFxParamSpec {
        StudioFxParamSpec(key: key, label: label, unit: unit,
                          defaultValue: def, minValue: lo, maxValue: hi,
                          automatable: false)
    }

    // The tables below are transcribed from `render/src/dsp/fx.rs`, INCLUDING
    // each row's `p`/`pb` rate. Anything that disagrees with them is either a
    // knob that travels somewhere the DSP clamps away (a dead control), or an
    // automation claim the compile gate will contradict (an over- or
    // under-warning surface). Both directions are pinned by tests.

    /// ALL 12 are `pb`: every band key feeds an RBJ coefficient recompute,
    /// which the engine refuses to drive per frame (`FxParamRate::Block`).
    static let eq: [StudioFxParamSpec] = [
        pb("band0Freq", "LO f", "Hz", 80, 20, 20_000),
        pb("band0Gain", "LO", "dB", 0, -24, 24),
        pb("band0Q", "LO Q", "", 0.707, 0.05, 10),
        pb("band1Freq", "LM f", "Hz", 250, 20, 20_000),
        pb("band1Gain", "LM", "dB", 0, -24, 24),
        pb("band1Q", "LM Q", "", 0.707, 0.05, 10),
        pb("band2Freq", "HM f", "Hz", 2_500, 20, 20_000),
        pb("band2Gain", "HM", "dB", 0, -24, 24),
        pb("band2Q", "HM Q", "", 0.707, 0.05, 10),
        pb("band3Freq", "HI f", "Hz", 8_000, 20, 20_000),
        pb("band3Gain", "HI", "dB", 0, -24, 24),
        pb("band3Q", "HI Q", "", 0.707, 0.05, 10),
    ]

    /// `attack`/`release` are `pb` — they exist only as one-pole envelope
    /// COEFFICIENTS (`coeff_from_ms` is an `exp` per application). Everything
    /// else applies with plain arithmetic or a change-cached dB→lin: `p`.
    static let compressor: [StudioFxParamSpec] = [
        p("threshold", "THRESH", "dB", -12, -60, 0),
        p("ratio", "RATIO", ":1", 4, 1, 20),
        p("knee", "KNEE", "dB", 0, 0, 24),
        pb("attack", "ATK", "ms", 10, 0, 200),
        pb("release", "REL", "ms", 100, 1, 2_000),
        p("makeup", "MAKEUP", "dB", 0, -24, 24),
        p("mix", "MIX", "", 1, 0, 1),
        p("detector", "DET", "", 0, 0, 1, isSwitch: true),
    ]

    /// Same envelope-coefficient split as the compressor. `hold` stays `p`
    /// even though it is a time value: applying it is ms→frames, one multiply
    /// and a cast, not a coefficient.
    static let gate: [StudioFxParamSpec] = [
        p("threshold", "THRESH", "dB", -40, -96, 0),
        pb("attack", "ATK", "ms", 1, 0, 200),
        p("hold", "HOLD", "ms", 10, 0, 2_000),
        pb("release", "REL", "ms", 100, 1, 2_000),
        p("range", "RANGE", "dB", -96, -96, 0),
        p("detector", "DET", "", 0, 0, 1, isSwitch: true),
    ]

    static let delay: [StudioFxParamSpec] = [
        p("time", "TIME", "ms", 375, 1, 2_000),
        p("feedback", "FDBK", "", 0.35, 0, 0.95),
        p("tone", "TONE", "", 0.4, 0, 0.99),
        p("mix", "MIX", "", 0.35, 0, 1),
    ]

    static let reverb: [StudioFxParamSpec] = [
        p("damping", "DAMP", "", 0.35, 0, 0.99),
        p("size", "SIZE", "", 0.84, 0, 0.98),
        p("mix", "MIX", "", 0.3, 0, 1),
    ]

    static let saturator: [StudioFxParamSpec] = [
        p("drive", "DRIVE", "dB", 0, -24, 36),
        p("mix", "MIX", "", 1, 0, 1),
        p("gain", "OUT", "dB", 0, -24, 24),
    ]

    static let chorus: [StudioFxParamSpec] = [
        p("rate", "RATE", "Hz", 0.8, 0.01, 20),
        p("depth", "DEPTH", "ms", 3, 0, 9),
        p("mix", "MIX", "", 0.5, 0, 1),
        p("spread", "SPREAD", "", 0.25, 0, 1),
    ]

    static let utility: [StudioFxParamSpec] = [
        p("gain", "GAIN", "dB", 0, -96, 24),
        p("pan", "PAN", "", 0, -1, 1),
        p("width", "WIDTH", "", 1, 0, 2),
        p("polarity", "POL", "", 0, 0, 1, isSwitch: true),
    ]

    /// `release` is `pb` — the same envelope-coefficient class as the
    /// compressor's. `ceiling` is a dB level behind the change-cached
    /// conversion: `p`.
    static let limiter: [StudioFxParamSpec] = [
        p("ceiling", "CEIL", "dB", -1, -24, 0),
        pb("release", "REL", "ms", 50, 1, 1_000),
    ]
}

/// The wire key for bypass.
///
/// ⚠️ Bypass is NOT an ordinary parameter and this surface never treats it as
/// one. It occupies no render-side parameter slot at all (DESIGN-E5 section
/// 23.5: `EngineParams::fx_bypassed` is the only read path), so it is excluded
/// from every parameter list the UI draws and is written ONLY by
/// `StudioRoutingController.setFxBypass`. Two spellings of one fact desync, and
/// a slot nothing reads is exactly the inert-lane defect this epic began with.
///
/// It is still spelled `fx.param.set {key: "bypass"}` on the wire, because that
/// is the only spelling the catalog has — there is no eighth fx command. See
/// the lane report for that seam note.
let studioFxBypassKey = "bypass"

// MARK: - Model objects

/// An effect in an insert chain. Chain order IS array order.
struct StudioFx: Identifiable, Hashable, Sendable {
    var id: String
    var kind: StudioFxKind
    /// SPARSE, exactly like the engine: a key that is absent means "the DSP
    /// default". Never materialize defaults in here — an undo of a first-time
    /// `fx.param.set` returns the key to ABSENT, not to a written default.
    var params: [String: Double] = [:]
    var sidechain: StudioNodeRef?

    /// What the DSP will actually use for `key`: the stored value if the user
    /// set one, otherwise the kind's default.
    func value(for key: String) -> Double {
        if let v = params[key] { return v }
        return kind.spec(for: key)?.defaultValue ?? 0
    }

    /// True when the user has explicitly written this key (so the UI can show
    /// a clear affordance only where there is something to clear).
    func isSet(_ key: String) -> Bool { params[key] != nil }

    var bypassed: Bool { (params[studioFxBypassKey] ?? 0) >= 0.5 }

    /// The parameter list the UI draws. `bypass` is deliberately absent.
    var editableParams: [StudioFxParamSpec] { kind.params }
}

struct StudioRouteNode: Identifiable, Hashable, Sendable {
    var id: String
    var kind: StudioRouteNodeKind
    var name: String
    /// The node FADER, in dB — `RouteNode::gain_db`, set by `route.node.set`
    /// and read by the render walk through `EngineParams::set_node_gain_db`.
    /// Omitted from the wire while it is the default 0 dB, so absence parses
    /// to 0 here. A `bus.<id>.gain` automation lane, when present, takes
    /// precedence over this static value for the rendered gain.
    var gainDB: Double = 0
    var fx: [StudioFx] = []

    var ref: StudioNodeRef { .bus(id) }
}

struct StudioRouteEdge: Identifiable, Hashable, Sendable {
    var id: String
    var from: StudioNodeRef
    var to: StudioNodeRef
    /// 0...4 on the wire (route.connect / route.edge.set). Unity is 1.0.
    var level: Double
    var tap: StudioTap
}

/// The whole routing + insert-chain picture, as read back from the engine.
struct StudioRoutingState: Hashable, Sendable {
    var nodes: [StudioRouteNode] = []
    var edges: [StudioRouteEdge] = []
    /// Keyed by the ENGINE's track id, because that is what the wire uses.
    var trackFx: [String: [StudioFx]] = [:]
    var masterFx: [StudioFx] = []

    var isEmpty: Bool {
        nodes.isEmpty && edges.isEmpty && trackFx.isEmpty && masterFx.isEmpty
    }

    func node(_ id: String) -> StudioRouteNode? { nodes.first { $0.id == id } }

    func chain(for ref: StudioNodeRef) -> [StudioFx] {
        switch ref {
        case .master: return masterFx
        case .track(let id): return trackFx[id] ?? []
        case .bus(let id): return node(id)?.fx ?? []
        }
    }

    func fx(on ref: StudioNodeRef, id: String) -> StudioFx? {
        chain(for: ref).first { $0.id == id }
    }

    func outgoing(from ref: StudioNodeRef) -> [StudioRouteEdge] {
        edges.filter { $0.from == ref }
    }

    func incoming(to ref: StudioNodeRef) -> [StudioRouteEdge] {
        edges.filter { $0.to == ref }
    }

    /// DESIGN-E5 section 4.2, mirrored so the UI can SAY what a connection did:
    /// a node keeps its implicit unity edge to master if and only if it declares
    /// no POST-tap edge of its own. Pre-tap edges are sends and never suppress
    /// the direct path.
    ///
    /// The engine owns the authoritative predicate
    /// (`Routing::has_implicit_master_feed`); this is the same rule, stated for
    /// display only. It never decides what is sent.
    func hasImplicitMasterFeed(_ ref: StudioNodeRef) -> Bool {
        if ref.isMaster { return false }
        return !edges.contains { $0.from == ref && $0.tap == .post }
    }

    /// Every sidechain link as an ordering constraint `(source, host)`. A link
    /// carries no audio but DOES participate in cycle detection, which is why
    /// the legality check below has to see it.
    var sidechainLinks: [(StudioNodeRef, StudioNodeRef)] {
        var out: [(StudioNodeRef, StudioNodeRef)] = []
        for (trackID, chain) in trackFx.sorted(by: { $0.key < $1.key }) {
            for f in chain where f.sidechain != nil {
                out.append((f.sidechain!, .track(trackID)))
            }
        }
        for n in nodes {
            for f in n.fx where f.sidechain != nil {
                out.append((f.sidechain!, .bus(n.id)))
            }
        }
        for f in masterFx where f.sidechain != nil {
            out.append((f.sidechain!, .master))
        }
        return out
    }

    var totalFxCount: Int {
        masterFx.count
            + nodes.reduce(0) { $0 + $1.fx.count }
            + trackFx.values.reduce(0) { $0 + $1.count }
    }
}

// MARK: - Capacity (DESIGN-E5 sections 4.1 and 16.5)
//
// Mirrored so the UI can refuse BEFORE sending, with the same numbers the
// engine will refuse with. The engine remains the authority; this only stops
// the surface from offering something that is going to be rejected.

enum StudioRoutingCaps {
    static let maxNodes = 32
    static let maxEdges = 512
    static let maxFxPerChain = 16
    static let maxFxTotal = 256
    /// `route.node.set`'s gainDb schema range (catalog v2). The fader clamps
    /// here so it cannot travel to a value the engine will refuse.
    static let nodeGainMinDB = -60.0
    static let nodeGainMaxDB = 12.0
}

// MARK: - What is actually AUDIBLE right now
//
// This exists because this whole epic started with a control that moved while
// nothing was audible. When this surface first shipped, the routing graph and
// every insert chain were journaled, undoable and saved — and the renderer did
// not evaluate them, so the pane carried a permanent "STORED, NOT YET AUDIBLE"
// badge. Its author chose that over a feature flag deliberately, accepting that
// the design "fails by over-warning after the audio arrives".
//
// The audio has arrived. E5-graph landed the `node_order` walk: buses, edges
// at both taps, insert chains, sidechain-keyed dynamics and delay compensation
// are evaluated by the render side, bit-identically across host block sizes.
// So the badge came down — a surface that over-warns about audio it IS
// producing teaches a user to ignore warnings, which is the same defect as a
// control that implies audio it is not producing, mirrored.
//
// The remaining gaps narrowed again when the fx-param-automation and
// bus-fader lanes landed (`FxNode::set_frame_param`; `route.node.set`), and
// this surface narrowed its statements WITH them — a warning that outlives
// its gap is the inert-control bug mirrored:
//
//  1. Fx-parameter automation is now PER KEY. Keys the engine applies with
//     plain arithmetic (`FxParamRate::Frame` — 22 distinct keys) have a
//     per-frame lane reader and automate. Keys that exist only as filter or
//     envelope COEFFICIENTS (`FxParamRate::Block` — attack/release and all 12
//     EQ band keys) are refused per key, loudly, points kept. `bypass` is not
//     a parameter, and `division` is reserved vocabulary no kind implements.
//     The per-key split lives on `StudioFxParamSpec.automatable`;
//     `fxAutomationNote(for:)` states each kind's exceptions in its editor.
//  2. The bus fader is REAL now: `route.node.set {nodeId, gainDb}` —
//     journaled, undoable, self-inverse — so the old "NO FADER" chip and note
//     are gone and the pane draws the fader instead.
enum StudioRoutingCapability {

    /// Whether the render side evaluates the routing graph and the fx chains.
    ///
    /// ⚠️ Flipped to `true` in the E5-ui-truth pass, after E5-graph landed the
    /// readers (the `node_order` walk, DESIGN-E5 sections 6.4 and 16.7). The
    /// engine's own predicate for this fact (`render::rt::lane_has_reader` /
    /// the compiled walk itself) is not reachable across the FFI, so this
    /// remains a DECLARATION rather than a probe, and
    /// `testTheSurfaceDeclaresThatProcessingIsAudible` pins it: un-flipping it
    /// must be a deliberate, reviewed change that names the renderer regression
    /// it is reporting, not a drive-by.
    static let processingActive = true

    /// Whether a bus/group can show a level meter. True: the render side
    /// meters every routing node once per block (`MeterBank::node_meters`,
    /// slot i = `routing.nodes[i]`), and the host exposes them in the meters
    /// read (`host.rs meters()` -> `"nodes"`, keyed by node id). The pane
    /// draws a meter ONLY for a node id the engine actually reported this
    /// poll — an id with no reading draws nothing at all, never a fabricated
    /// bar pinned at silence.
    static let nodeMetersAvailable = true

    /// The one automation statement each fx editor makes, PER KIND, derived
    /// from the same `automatable` rows the drift pin holds against the
    /// engine's `FxParamRate` table — so this note and the table cannot
    /// disagree.
    ///
    /// HISTORY, on purpose: this replaced the booleans
    /// `fxParamAutomationAvailable`/`fxParamAutomationNote` (which said all
    /// fx-param lanes were refused) in the SAME pass that landed
    /// `FxNode::set_frame_param`. A blanket "not renderable" had become the
    /// over-warning the badge once was. The refusals that remain are stated
    /// with their engine reasons (`rt::lane_gap_reason`): coefficients
    /// (RBJ bands, attack/release one-poles) are refused per key, loudly,
    /// points kept. Kinds with nothing to warn about return nil and their
    /// editors say NOTHING — silence is the honest rendering of "it just
    /// works". Never the words "automation unavailable": most of it is
    /// available, and `testNoNoteEverSaysAutomationIsUnavailable` pins the
    /// phrasing.
    static func fxAutomationNote(for kind: StudioFxKind) -> String? {
        let refused = kind.params.filter { !$0.automatable }
        switch kind {
        case .eq:
            return """
                Band knobs are live and undoable, but none of the 12 band keys \
                takes an automation lane: a band change recomputes RBJ filter \
                coefficients, which the engine refuses to drive per frame. A \
                band lane is refused loudly, with its points kept.
                """
        case .delay:
            // Nothing refused — this is a SEMANTICS note, not a warning: time
            // automation moves a crossfaded integer tap (`DelayBus` fades any
            // tap change over the declick window), which sounds like repeats
            // fading between positions, not like tape being pitch-bent.
            return """
                All four parameters automate per frame. TIME automation moves \
                a crossfaded delay tap — repeats fade between positions rather \
                than pitch-sliding the way tape or an analog BBD would.
                """
        default:
            guard !refused.isEmpty else { return nil }
            let names = refused.map(\.label).joined(separator: " and ")
            return """
                Every parameter here automates per frame except \(names): \
                envelope times exist only as one-pole coefficients, which the \
                engine refuses to recompute per frame. A lane on \(refused.count == 1 ? "it" : "them") \
                is refused loudly, points kept. The knob\(refused.count == 1 ? "" : "s") \
                \(refused.count == 1 ? "itself stays" : "themselves stay") live and undoable.
                """
        }
    }

    /// Likewise there is no `route.node.rename`. Synthesizing one from
    /// remove + add would destroy the node's whole insert chain and cost two
    /// undo steps for one gesture, so a bus is named when it is created.
    static let noRenameNote = "A bus is named when it is created; this build has no rename command."
}
