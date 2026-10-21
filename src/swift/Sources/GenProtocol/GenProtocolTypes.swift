import Foundation

// MARK: - Gen Protocol v1 wire types (lane L4)
//
// Mirrors engine/contracts/gen-protocol.v1.yaml / gen-protocol.schemas.json.
// This file only defines shapes + JSONValue bridging; GenProtocolClient.swift
// does the actual RPC/HTTP work. Field names match the contract exactly
// (camelCase on the wire, same casing here) so there is one obvious mapping
// to read against gen-protocol-mapping.md.

// MARK: Route / op / state enums

enum GenProtocolRoute: String, Codable, Sendable, CaseIterable {
    case localMLX = "local-mlx"
    case remoteAce = "remote-ace"
    case genNode = "gen-node"
    case ucCloud = "uc-cloud"
}

enum GenProtocolOp: String, Codable, Sendable, CaseIterable {
    case generate, revise, extend, layer, retake, autocomplete, cover, separate, analyze, finalize
}

enum GenProtocolStemScope: String, Codable, Sendable {
    case allStems = "all-stems"
    case vocals, drums, bass, other
}

enum GenProtocolQualityRung: String, Codable, Sendable {
    case draft, standard, full
}

enum GenProtocolJobState: String, Codable, Sendable {
    case queued, running, done, failed, cancelled
}

// MARK: - JSONValue bridging
//
// JSONValue (JSONValue.swift, existing) already round-trips through
// Codable. Re-encoding a JSONValue to Data and decoding that Data as a
// concrete Codable type is a clean way to get strongly-typed responses out
// of RPCResponse.result without hand-walking .object dictionaries
// everywhere. Failure here is a real contract-shape mismatch, so it throws
// rather than silently producing a half-populated struct.
enum GenProtocolCodec {
    static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(type, from: data)
    }

    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        return decoded
    }
}

// JSONValue is a pure value enum (String/Double/Bool/nested value collections/
// null), so it is genuinely Sendable. The existing JSONValue.swift predates
// this lane's need to pass JSONValue across a Sendable protocol boundary
// (GenProtocolRPCSending), so the conformance is added here, in this lane's
// own file, rather than by editing JSONValue.swift (outside this lane's file
// ownership). Sendable is a marker protocol with no runtime effect, so this
// cannot change any existing behavior.
extension JSONValue: @unchecked Sendable {}

extension JSONValue {
    var intValue: Int? {
        if case .number(let n) = self { return Int(n) }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Build a JSONValue.object from a [String: Any] dict, matching the
    /// existing RemoteGenerationParams.toDictionary() -> JSONValue.fromAny
    /// convention used elsewhere in this codebase for RPC/HTTP params.
    static func object(fromAny dict: [String: Any]) -> JSONValue {
        JSONValue.fromAny(dict) ?? .object([:])
    }
}

// MARK: - Response shapes

struct GenProtocolArtifact: Codable, Sendable, Equatable {
    let kind: String
    let path: String
    let contentHash: String
}

struct GenProtocolEngineIdentity: Codable, Sendable, Equatable {
    let model: String
    let device: String
    let steps: Int?
    let seed: Int?
}

struct GenProtocolErrorBody: Codable, Sendable, Equatable, LocalizedError {
    let code: String
    let message: String
    let fix: String?
    let detail: String?
    let step: String?

    var errorDescription: String? {
        var text = "\(code): \(message)"
        if let fix, !fix.isEmpty { text += "\nFix: \(fix)" }
        return text
    }
}

/// terminalState oneOf {done, failed, cancelled} plus the non-terminal
/// {queued, running} shape from GET /gen/jobs/{jobId} - see gen-protocol.v1
/// .yaml's getJob response and gen-protocol.schemas.json's terminalState.
enum GenProtocolJobStatus: Sendable, Equatable {
    case queued(jobId: String)
    case running(jobId: String)
    case done(jobId: String, artifacts: [GenProtocolArtifact], engineIdentity: GenProtocolEngineIdentity, latencySeconds: Double?)
    case failed(jobId: String, error: GenProtocolErrorBody)
    case cancelled(jobId: String)

    var jobId: String {
        switch self {
        case .queued(let id), .running(let id), .done(let id, _, _, _), .failed(let id, _), .cancelled(let id):
            return id
        }
    }

    var isTerminal: Bool {
        switch self {
        case .done, .failed, .cancelled: return true
        case .queued, .running: return false
        }
    }
}

extension GenProtocolJobStatus {
    /// Decode a gen.status RPC result (already a JSONValue.object) into the
    /// oneOf shape above. Throws on an unrecognized "state" rather than
    /// silently defaulting, since a new state value would mean this client
    /// is out of sync with the contract.
    static func decode(from value: JSONValue) throws -> GenProtocolJobStatus {
        guard let obj = value.objectValue, let jobId = obj["jobId"]?.stringValue,
              let state = obj["state"]?.stringValue else {
            throw GenProtocolClientError.invalidResponse("gen.status result missing state/jobId")
        }
        switch state {
        case "queued":
            return .queued(jobId: jobId)
        case "running":
            return .running(jobId: jobId)
        case "cancelled":
            return .cancelled(jobId: jobId)
        case "failed":
            let error = try obj["error"].map { try GenProtocolCodec.decode(GenProtocolErrorBody.self, from: $0) }
                ?? GenProtocolErrorBody(code: "UNKNOWN", message: "failed with no error body", fix: nil, detail: nil, step: nil)
            return .failed(jobId: jobId, error: error)
        case "done":
            guard let artifactsValue = obj["artifacts"], let identityValue = obj["engineIdentity"] else {
                throw GenProtocolClientError.invalidResponse("gen.status done result missing artifacts/engineIdentity")
            }
            let artifacts = try GenProtocolCodec.decode([GenProtocolArtifact].self, from: artifactsValue)
            let identity = try GenProtocolCodec.decode(GenProtocolEngineIdentity.self, from: identityValue)
            let latency = obj["latencySeconds"]?.doubleValue
            return .done(jobId: jobId, artifacts: artifacts, engineIdentity: identity, latencySeconds: latency)
        default:
            throw GenProtocolClientError.invalidResponse("unrecognized gen.status state: \(state)")
        }
    }
}

// MARK: - Capabilities

struct GenProtocolCapabilityEndpoint: Codable, Sendable, Equatable {
    let route: GenProtocolRoute
    let ops: [String]
    let models: [String]
    let concurrentSlots: Int

    func supports(_ op: GenProtocolOp) -> Bool {
        ops.contains(op.rawValue)
    }
}

struct GenProtocolCapabilities: Codable, Sendable, Equatable {
    let endpoints: [GenProtocolCapabilityEndpoint]

    func endpoint(for route: GenProtocolRoute) -> GenProtocolCapabilityEndpoint? {
        endpoints.first { $0.route == route }
    }

    /// Routes that support `op`, in the order they appear (capabilities()
    /// on the Python side and the merge on this side both list local-mlx
    /// first, so this is naturally a reasonable preference order too).
    func routes(supporting op: GenProtocolOp) -> [GenProtocolRoute] {
        endpoints.filter { $0.supports(op) && $0.concurrentSlots > 0 }.map(\.route)
    }
}

// MARK: - Errors

enum GenProtocolClientError: LocalizedError, Sendable {
    case invalidResponse(String)
    case routeOpNotSupported(route: GenProtocolRoute, op: GenProtocolOp, reason: String)
    case remoteRouteNotConfigured(String)
    case backendError(GenProtocolErrorBody)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let detail):
            return "Invalid Gen Protocol response: \(detail)"
        case .routeOpNotSupported(let route, let op, let reason):
            return "\(route.rawValue) does not support \(op.rawValue): \(reason)"
        case .remoteRouteNotConfigured(let detail):
            return "Remote route not configured: \(detail)"
        case .backendError(let body):
            return body.errorDescription
        }
    }
}

// MARK: - ULID
//
// jobId == the caller's requestId always (mapping.md, "Job identity and the
// async model"): the engine mints it, not the server. No ULID generator
// existed anywhere in this codebase (checked majiks-dj too, the donor
// pattern catalog), so this is a small new one: 48-bit millisecond
// timestamp + 80 bits of secure randomness, Crockford base32, matching
// gen-protocol.schemas.json's `^[0-7][0-9A-HJKMNP-TV-Z]{25}$` by
// construction (a 48-bit timestamp needs only 10 base32 digits = 50 bits,
// so the top 2 bits of the first character are always zero).
enum ULID {
    private static let crockford = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func generate(now: Date = Date(), randomBytes: () -> [UInt8] = { (0..<10).map { _ in UInt8.random(in: 0...255) } }) -> String {
        let millis = UInt64(now.timeIntervalSince1970 * 1000)
        var chars = [Character](repeating: "0", count: 26)

        var t = millis
        for i in stride(from: 9, through: 0, by: -1) {
            chars[i] = crockford[Int(t & 0x1F)]
            t >>= 5
        }

        let randomness = randomBytes()
        var bits: UInt64 = 0
        var bitCount = 0
        var randIndex = 0
        var outIndex = 10
        while outIndex < 26 {
            while bitCount < 5, randIndex < randomness.count {
                bits = (bits << 8) | UInt64(randomness[randIndex])
                bitCount += 8
                randIndex += 1
            }
            guard bitCount >= 5 else { break }
            let shift = bitCount - 5
            let idx = Int((bits >> shift) & 0x1F)
            chars[outIndex] = crockford[idx]
            bitCount -= shift == 0 ? bitCount : 5
            bits &= (1 << UInt64(bitCount)) - 1
            outIndex += 1
        }
        // Fill any remainder deterministically if randomBytes() returned
        // fewer than 10 bytes (defensive; the default closure never does).
        while outIndex < 26 {
            chars[outIndex] = crockford[0]
            outIndex += 1
        }
        return String(chars)
    }
}
