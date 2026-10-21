import Foundation

// MARK: - Gen Protocol client (lane L4)
//
// A thin front that presents the ten Gen Protocol ops over one shape,
// regardless of which engine route runs them. It:
//
// 1. Proxies EXECUTION to the Python backend's gen.submit / gen.status /
//    gen.cancel / gen.capabilities RPC methods (the ones this lane added,
//    additively, to rpc_server.py). Python is the single executor of record
//    for every route, which is deliberate: the terminal artifact hashes are
//    blake3 (gen-protocol.schemas.json assetHash pattern), and Python owns
//    the one blake3 implementation in this program (gen_protocol.py). Its
//    remote-ace executor (ace_generator.RemoteACEStepGenerator) speaks the
//    exact same POST /api/v1/studio/generate protocol as the Swift
//    RemoteGenerationService, so routing remote-ace execution through Python
//    changes no remote wire behavior; it just keeps lineage hashing in one
//    place. (A future lane could add a direct-Swift remote fast-path for
//    live progress once a Swift blake3 or a hash-registration RPC exists;
//    noted in docs/evidence/l4-gen-protocol.md, not built here.)
//
// 2. WRAPS the existing Swift ServerPool + RemoteGenerationService (without
//    editing either) for the CAPABILITY side: ServerPool is the Swift-side
//    authority on the remote-ace route (its configured servers, Keychain
//    keys, health, slot capacity), and RemoteGenerationService.listModels()
//    supplies each server's advertised models. capabilities() merges that
//    Swift truth over Python's gen.capabilities for the remote-ace endpoint
//    (see GenProtocolCapabilityMerge).
//
// The request/response types are in GenProtocolTypes.swift; the merge is in
// GenProtocolCapabilityMerge.swift.

// MARK: - Dependencies (protocols so the client is unit-testable)

/// Sends a single Gen Protocol RPC to the Python backend and returns its
/// `result`. The real implementation wraps the existing JSONRPCClient.
protocol GenProtocolRPCSending: Sendable {
    func sendGenProtocol(method: String, params: JSONValue?) async throws -> JSONValue
}

/// Probes the Swift ServerPool for the remote-ace route's real availability.
/// The real implementation reads a ServerPoolManager; tests inject a stub.
protocol GenProtocolRemoteAceProbing: Sendable {
    func probe() async -> RemoteAceAvailability
}

// MARK: - Analyze result (analyze is synchronous per its own contract shape)

struct GenProtocolAnalyzeResult: Codable, Sendable, Equatable {
    let bpm: Double?
    let key: String?
    let duration: Double?
    let downbeats: [Double]?
    let loudnessLufs: Double?
    let caption: String?
    let lyrics: String?
    let language: String?
    let timeSig: String?
    let genre: String?
    let style: String?
}

// MARK: - Client

final class GenProtocolClient: Sendable {
    private let sender: GenProtocolRPCSending
    private let remoteAceProbe: GenProtocolRemoteAceProbing?

    init(sender: GenProtocolRPCSending, remoteAceProbe: GenProtocolRemoteAceProbing? = nil) {
        self.sender = sender
        self.remoteAceProbe = remoteAceProbe
    }

    // MARK: capabilities

    /// Merged capability matrix: Python's gen.capabilities for local-mlx /
    /// gen-node / uc-cloud, with the remote-ace endpoint refined by the
    /// Swift ServerPool (its rightful authority). See
    /// GenProtocolCapabilityMerge.
    func capabilities() async throws -> GenProtocolCapabilities {
        let result = try await sender.sendGenProtocol(method: "gen.capabilities", params: nil)
        let python = try GenProtocolCodec.decode(GenProtocolCapabilities.self, from: result)
        let remoteAce = await remoteAceProbe?.probe() ?? .none
        return GenProtocolCapabilityMerge.merge(python: python, remoteAce: remoteAce)
    }

    // MARK: submit / status / cancel

    /// Submit a job-shaped op (everything except analyze). Returns the jobId,
    /// which equals the request's requestId (minted here if the request did
    /// not already carry one). Poll with `status(jobId:)`.
    @discardableResult
    func submit(op: GenProtocolOp, request: GenProtocolRequest) async throws -> String {
        guard op != .analyze else {
            throw GenProtocolClientError.invalidResponse(
                "analyze is synchronous; call analyze(request:) instead of submit(op: .analyze, ...)")
        }
        let requestObject = request.withRequestId()
        let params = JSONValue.object([
            "op": .string(op.rawValue),
            "request": requestObject.jsonValue,
        ])
        let result = try await sender.sendGenProtocol(method: "gen.submit", params: params)
        guard let jobId = result.objectValue?["jobId"]?.stringValue else {
            throw GenProtocolClientError.invalidResponse("gen.submit returned no jobId")
        }
        return jobId
    }

    /// Current state of a job. queued/running are non-terminal; done/failed/
    /// cancelled are terminal (see GenProtocolJobStatus.isTerminal).
    func status(jobId: String) async throws -> GenProtocolJobStatus {
        let params = JSONValue.object(["jobId": .string(jobId)])
        let result = try await sender.sendGenProtocol(method: "gen.status", params: params)
        return try GenProtocolJobStatus.decode(from: result)
    }

    /// Request cancellation of an in-flight job. Best effort per the contract
    /// ("Cancellation requested"); poll status to observe the cancelled
    /// terminal state.
    func cancel(jobId: String) async throws {
        let params = JSONValue.object(["jobId": .string(jobId)])
        _ = try await sender.sendGenProtocol(method: "gen.cancel", params: params)
    }

    /// Poll `status(jobId:)` until the job reaches a terminal state, or the
    /// deadline passes. `onProgress` is called with each non-terminal poll.
    /// (Live progress notifications also arrive out-of-band on the RPC
    /// progress channel; this polling loop is the contract's polling-parity
    /// path, usable by any caller that does not wire the notification
    /// handler.)
    func awaitTerminal(
        jobId: String,
        pollInterval: TimeInterval = 1.0,
        timeout: TimeInterval = 600,
        onProgress: (@Sendable (GenProtocolJobStatus) -> Void)? = nil
    ) async throws -> GenProtocolJobStatus {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = try await status(jobId: jobId)
            if state.isTerminal {
                return state
            }
            onProgress?(state)
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw GenProtocolClientError.invalidResponse("job \(jobId) did not reach a terminal state before timeout")
    }

    // MARK: analyze (synchronous)

    /// analyze returns its analyzeResponse inline (contract: 200, not a 202
    /// job); see gen-protocol.v1.yaml /gen/analyze. This is the one op that
    /// is not job-shaped.
    func analyze(request: GenProtocolRequest) async throws -> GenProtocolAnalyzeResult {
        let requestObject = request.withRequestId()
        let params = JSONValue.object([
            "op": .string(GenProtocolOp.analyze.rawValue),
            "request": requestObject.jsonValue,
        ])
        let result = try await sender.sendGenProtocol(method: "gen.submit", params: params)
        return try GenProtocolCodec.decode(GenProtocolAnalyzeResult.self, from: result)
    }
}

// MARK: - Request builder
//
// A thin wrapper over a JSONValue.object so callers can pass any of the ten
// request shapes without ten Swift structs, while still getting requestId
// minting and a couple of ergonomic typed builders for the ops the app
// calls first. Field names match gen-protocol.schemas.json exactly.

struct GenProtocolRequest: Sendable {
    private(set) var fields: [String: JSONValue]

    init(_ fields: [String: JSONValue] = [:]) {
        self.fields = fields
    }

    var jsonValue: JSONValue { .object(fields) }

    /// Return a copy with a minted requestId (ULID) if one is not already
    /// present. jobId == requestId (mapping.md), so the caller can read the
    /// id back off the returned request when it needs to correlate.
    func withRequestId() -> GenProtocolRequest {
        if case .string(let existing)? = fields["requestId"], !existing.isEmpty {
            return self
        }
        var copy = fields
        copy["requestId"] = .string(ULID.generate())
        return GenProtocolRequest(copy)
    }

    var requestId: String? {
        if case .string(let id)? = fields["requestId"] { return id }
        return nil
    }

    mutating func set(_ key: String, _ value: JSONValue) {
        fields[key] = value
    }

    // Ergonomic typed builders for the two ops the live smoke exercises.

    static func generate(
        caption: String,
        durationSeconds: Double? = nil,
        bpm: Int? = nil,
        key: String? = nil,
        seed: Int? = nil,
        model: String? = nil,
        steps: Int? = nil,
        nVariants: Int? = nil,
        route: GenProtocolRoute? = nil,
        requestId: String? = nil
    ) -> GenProtocolRequest {
        var f: [String: JSONValue] = ["caption": .string(caption)]
        if let requestId { f["requestId"] = .string(requestId) }
        if let durationSeconds { f["durationSeconds"] = .number(durationSeconds) }
        if let bpm { f["bpm"] = .number(Double(bpm)) }
        if let key { f["key"] = .string(key) }
        if let seed { f["seed"] = .number(Double(seed)) }
        if let model { f["model"] = .string(model) }
        if let steps { f["steps"] = .number(Double(steps)) }
        if let nVariants { f["nVariants"] = .number(Double(nVariants)) }
        if let route { f["route"] = .string(route.rawValue) }
        return GenProtocolRequest(f)
    }

    static func revise(
        sourceAudioRef: String,
        regionStartSeconds: Double,
        regionEndSeconds: Double,
        instruction: String,
        scope: GenProtocolStemScope? = nil,
        seed: Int? = nil,
        variants: Int? = nil,
        route: GenProtocolRoute? = nil,
        requestId: String? = nil
    ) -> GenProtocolRequest {
        var f: [String: JSONValue] = [
            "sourceAudioRef": .string(sourceAudioRef),
            "regionStartSeconds": .number(regionStartSeconds),
            "regionEndSeconds": .number(regionEndSeconds),
            "instruction": .string(instruction),
        ]
        if let requestId { f["requestId"] = .string(requestId) }
        if let scope { f["scope"] = .string(scope.rawValue) }
        if let seed { f["seed"] = .number(Double(seed)) }
        if let variants { f["variants"] = .number(Double(variants)) }
        if let route { f["route"] = .string(route.rawValue) }
        return GenProtocolRequest(f)
    }

    static func analyze(
        sourceAudioRef: String,
        mode: String? = nil,
        requestId: String? = nil
    ) -> GenProtocolRequest {
        var f: [String: JSONValue] = ["sourceAudioRef": .string(sourceAudioRef)]
        if let requestId { f["requestId"] = .string(requestId) }
        if let mode { f["mode"] = .string(mode) }
        return GenProtocolRequest(f)
    }
}

// MARK: - Real dependency implementations
//
// These do the actual wrapping of existing app types. They are excluded from
// the unit tests (which inject stubs), so they can freely reference
// JSONRPCClient / ServerPoolManager / RemoteGenerationService without
// dragging a live backend into the test target.

/// Wraps the existing JSONRPCClient. JSONRPCClient.send already throws
/// RPCClientError.serverError on an error response, so this only needs to
/// unwrap the successful result.
final class JSONRPCGenProtocolSender: GenProtocolRPCSending {
    private let client: JSONRPCClient

    init(client: JSONRPCClient) {
        self.client = client
    }

    func sendGenProtocol(method: String, params: JSONValue?) async throws -> JSONValue {
        let response = try await client.send(method: method, params: params, timeout: 600)
        guard let result = response.result else {
            throw GenProtocolClientError.invalidResponse("\(method) returned no result")
        }
        return result
    }
}

/// Reads the Swift ServerPool for remote-ace availability, and (best effort)
/// unions each healthy server's advertised models via the existing
/// RemoteGenerationService.listModels(). Wraps both without editing either.
@MainActor
final class ServerPoolRemoteAceProbe: GenProtocolRemoteAceProbing {
    private let serverPool: ServerPoolManager

    init(serverPool: ServerPoolManager) {
        self.serverPool = serverPool
    }

    nonisolated func probe() async -> RemoteAceAvailability {
        await MainActor.run { self.probeOnMain() }
    }

    private func probeOnMain() -> RemoteAceAvailability {
        let healthy = serverPool.enabledServers.filter { $0.healthStatus != .unhealthy }
        guard !healthy.isEmpty else { return .none }
        let slots = healthy.reduce(0) { $0 + max(0, $1.maxConcurrentJobs) }
        // Models are populated opportunistically by whoever last ran a
        // health/model sweep; a synchronous probe here does not block on
        // network. Report empty models rather than stall (graceful unknown).
        return RemoteAceAvailability(concurrentSlots: slots, models: [])
    }
}
