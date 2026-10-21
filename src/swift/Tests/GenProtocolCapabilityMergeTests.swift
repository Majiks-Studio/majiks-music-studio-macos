import Testing
import Foundation
@testable import MajiksMusicStudio

// Lane L4: the Swift-side capability merge (brief scope item 4: "a Swift unit
// test for capability merging"), plus the client's capabilities() path over a
// stub sender, ULID shape, and JSONValue round-trip. No live backend, no live
// ServerPool.

// MARK: - Fixtures

private func pythonCapabilities(
    localOps: [String] = GenProtocolOp.allCases.map(\.rawValue),
    localSlots: Int = 1,
    remoteAceOps: [String] = ["generate"],
    remoteAceSlots: Int = 0,
    genNodeOps: [String] = [],
    genNodeSlots: Int = 0
) -> GenProtocolCapabilities {
    GenProtocolCapabilities(endpoints: [
        GenProtocolCapabilityEndpoint(route: .localMLX, ops: localOps,
                                      models: ["acestep-v15-turbo", "acestep-v15-base"], concurrentSlots: localSlots),
        GenProtocolCapabilityEndpoint(route: .remoteAce, ops: remoteAceOps,
                                      models: ["acestep-v15-turbo"], concurrentSlots: remoteAceSlots),
        GenProtocolCapabilityEndpoint(route: .genNode, ops: genNodeOps, models: [], concurrentSlots: genNodeSlots),
        GenProtocolCapabilityEndpoint(route: .ucCloud, ops: [], models: [], concurrentSlots: 0),
    ])
}

// MARK: - Merge

@Suite("GenProtocol capability merge")
struct GenProtocolCapabilityMergeTests {

    @Test("remote-ace availability from ServerPool overrides Python's guess")
    func remoteAceOverridden() {
        let python = pythonCapabilities(remoteAceSlots: 0)
        let availability = RemoteAceAvailability(concurrentSlots: 4, models: ["acestep-v15-turbo"])
        let merged = GenProtocolCapabilityMerge.merge(python: python, remoteAce: availability)

        let remote = merged.endpoint(for: .remoteAce)
        #expect(remote?.concurrentSlots == 4)
        #expect(remote?.models == ["acestep-v15-turbo"])
    }

    @Test("remote-ace is generate-only: revise-class ops are local-only there")
    func remoteAceIsGenerateOnly() {
        let python = pythonCapabilities()
        let availability = RemoteAceAvailability(concurrentSlots: 2, models: [])
        let merged = GenProtocolCapabilityMerge.merge(python: python, remoteAce: availability)

        let remote = merged.endpoint(for: .remoteAce)
        #expect(remote?.ops == ["generate"])
        // Every op that rewrites existing audio (and every non-text2music op)
        // must NOT be listed on remote-ace: the ServerPool bridge protocol
        // (POST /api/v1/studio/generate) is text2music only.
        for op in [GenProtocolOp.revise, .extend, .layer, .retake, .autocomplete, .cover, .separate, .analyze, .finalize] {
            #expect(remote?.supports(op) == false, "remote-ace must not advertise \(op.rawValue)")
        }
        #expect(remote?.supports(.generate) == true)
    }

    @Test("no healthy servers -> remote-ace advertises zero slots and no ops")
    func noHealthyServers() {
        let python = pythonCapabilities(remoteAceSlots: 2)
        let merged = GenProtocolCapabilityMerge.merge(python: python, remoteAce: .none)

        let remote = merged.endpoint(for: .remoteAce)
        #expect(remote?.concurrentSlots == 0)
        #expect(remote?.ops.isEmpty == true)
    }

    @Test("local-mlx, gen-node, uc-cloud pass through from Python untouched")
    func nonRemoteRoutesPassThrough() {
        let python = pythonCapabilities(
            localOps: GenProtocolOp.allCases.map(\.rawValue),
            genNodeOps: ["generate", "revise", "extend"],
            genNodeSlots: 1
        )
        let merged = GenProtocolCapabilityMerge.merge(python: python, remoteAce: .none)

        #expect(merged.endpoint(for: .localMLX)?.ops.count == GenProtocolOp.allCases.count)
        #expect(merged.endpoint(for: .genNode)?.ops == ["generate", "revise", "extend"])
        #expect(merged.endpoint(for: .genNode)?.concurrentSlots == 1)
        #expect(merged.endpoint(for: .ucCloud)?.ops.isEmpty == true)
    }

    @Test("remote-ace synthesized even if Python omitted it")
    func remoteAceSynthesizedWhenAbsent() {
        let python = GenProtocolCapabilities(endpoints: [
            GenProtocolCapabilityEndpoint(route: .localMLX, ops: ["generate"], models: [], concurrentSlots: 1),
        ])
        let availability = RemoteAceAvailability(concurrentSlots: 3, models: ["m"])
        let merged = GenProtocolCapabilityMerge.merge(python: python, remoteAce: availability)

        #expect(merged.endpoint(for: .remoteAce) != nil)
        #expect(merged.endpoint(for: .remoteAce)?.concurrentSlots == 3)
        #expect(merged.endpoints.count == 2)
    }

    @Test("routes(supporting:) only lists routes with capacity")
    func routesSupportingRequireCapacity() {
        let python = pythonCapabilities(localSlots: 1, remoteAceSlots: 0)
        let merged = GenProtocolCapabilityMerge.merge(python: python, remoteAce: .none)

        // generate is supported by local (slots=1) and remote-ace (slots=0);
        // only local has capacity.
        let generateRoutes = merged.routes(supporting: .generate)
        #expect(generateRoutes.contains(.localMLX))
        #expect(!generateRoutes.contains(.remoteAce))

        // revise is local-only regardless.
        #expect(merged.routes(supporting: .revise) == [.localMLX])
    }

    @Test("isRunnable reflects capacity")
    func isRunnable() {
        let merged = GenProtocolCapabilityMerge.merge(
            python: pythonCapabilities(localSlots: 1), remoteAce: .none)
        #expect(GenProtocolCapabilityMerge.isRunnable(.revise, in: merged))
        #expect(GenProtocolCapabilityMerge.isRunnable(.generate, in: merged))
    }
}

// MARK: - Stubs for the client path

private struct StubSender: GenProtocolRPCSending {
    let responses: [String: JSONValue]
    func sendGenProtocol(method: String, params: JSONValue?) async throws -> JSONValue {
        guard let r = responses[method] else {
            throw GenProtocolClientError.invalidResponse("no stub for \(method)")
        }
        return r
    }
}

private struct StubRemoteAceProbe: GenProtocolRemoteAceProbing {
    let availability: RemoteAceAvailability
    func probe() async -> RemoteAceAvailability { availability }
}

@Suite("GenProtocolClient over a stub backend")
struct GenProtocolClientTests {

    private func capabilitiesJSON() -> JSONValue {
        .object([
            "endpoints": .array([
                .object([
                    "route": .string("local-mlx"),
                    "ops": .array(GenProtocolOp.allCases.map { .string($0.rawValue) }),
                    "models": .array([.string("acestep-v15-turbo")]),
                    "concurrentSlots": .number(1),
                ]),
                .object([
                    "route": .string("remote-ace"),
                    "ops": .array([.string("generate")]),
                    "models": .array([.string("acestep-v15-turbo")]),
                    "concurrentSlots": .number(0),
                ]),
                .object([
                    "route": .string("gen-node"),
                    "ops": .array([]),
                    "models": .array([]),
                    "concurrentSlots": .number(0),
                ]),
                .object([
                    "route": .string("uc-cloud"),
                    "ops": .array([]),
                    "models": .array([]),
                    "concurrentSlots": .number(0),
                ]),
            ]),
        ])
    }

    @Test("capabilities() decodes Python result and applies ServerPool merge")
    func capabilitiesMerged() async throws {
        let sender = StubSender(responses: ["gen.capabilities": capabilitiesJSON()])
        let probe = StubRemoteAceProbe(availability: RemoteAceAvailability(concurrentSlots: 2, models: ["acestep-v15-turbo"]))
        let client = GenProtocolClient(sender: sender, remoteAceProbe: probe)

        let caps = try await client.capabilities()
        #expect(caps.endpoint(for: .localMLX)?.ops.count == GenProtocolOp.allCases.count)
        // ServerPool truth (2 slots) replaced Python's 0.
        #expect(caps.endpoint(for: .remoteAce)?.concurrentSlots == 2)
        #expect(caps.endpoint(for: .remoteAce)?.ops == ["generate"])
    }

    @Test("submit returns the jobId from gen.submit")
    func submitReturnsJobId() async throws {
        let sender = StubSender(responses: [
            "gen.submit": .object(["jobId": .string("01ARZ3NDEKTSV4RRFFQ69G5FAV")]),
        ])
        let client = GenProtocolClient(sender: sender)
        let req = GenProtocolRequest.generate(caption: "x", requestId: "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        let jobId = try await client.submit(op: .generate, request: req)
        #expect(jobId == "01ARZ3NDEKTSV4RRFFQ69G5FAV")
    }

    @Test("submit rejects analyze (analyze is synchronous)")
    func submitRejectsAnalyze() async {
        let sender = StubSender(responses: [:])
        let client = GenProtocolClient(sender: sender)
        await #expect(throws: GenProtocolClientError.self) {
            _ = try await client.submit(op: .analyze, request: GenProtocolRequest.analyze(sourceAudioRef: "x"))
        }
    }

    @Test("status decodes a done terminal state with artifacts + identity")
    func statusDone() async throws {
        let done: JSONValue = .object([
            "state": .string("done"),
            "jobId": .string("01ARZ3NDEKTSV4RRFFQ69G5FAV"),
            "artifacts": .array([
                .object([
                    "kind": .string("mix"),
                    "path": .string("/tmp/mix.wav"),
                    "contentHash": .string(String(repeating: "a", count: 64)),
                ]),
            ]),
            "engineIdentity": .object([
                "model": .string("acestep-v15-turbo"),
                "device": .string("cpu"),
                "steps": .number(8),
                "seed": .number(42),
            ]),
            "latencySeconds": .number(3.5),
        ])
        let sender = StubSender(responses: ["gen.status": done])
        let client = GenProtocolClient(sender: sender)
        let state = try await client.status(jobId: "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        guard case let .done(jobId, artifacts, identity, latency) = state else {
            Issue.record("expected .done, got \(state)")
            return
        }
        #expect(jobId == "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        #expect(artifacts.first?.kind == "mix")
        #expect(identity.model == "acestep-v15-turbo")
        #expect(latency == 3.5)
        #expect(state.isTerminal)
    }

    @Test("status decodes a failed terminal state with a structured error")
    func statusFailed() async throws {
        let failed: JSONValue = .object([
            "state": .string("failed"),
            "jobId": .string("01ARZ3NDEKTSV4RRFFQ69G5FAV"),
            "error": .object([
                "code": .string("FILE_NOT_FOUND"),
                "message": .string("Source audio not found"),
                "fix": .string("Select a valid file"),
            ]),
        ])
        let sender = StubSender(responses: ["gen.status": failed])
        let client = GenProtocolClient(sender: sender)
        let state = try await client.status(jobId: "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        guard case let .failed(_, error) = state else {
            Issue.record("expected .failed, got \(state)")
            return
        }
        #expect(error.code == "FILE_NOT_FOUND")
        #expect(state.isTerminal)
    }

    @Test("running is non-terminal")
    func statusRunning() async throws {
        let running: JSONValue = .object(["state": .string("running"), "jobId": .string("01ARZ3NDEKTSV4RRFFQ69G5FAV")])
        let sender = StubSender(responses: ["gen.status": running])
        let client = GenProtocolClient(sender: sender)
        let state = try await client.status(jobId: "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        #expect(!state.isTerminal)
    }

    @Test("analyze decodes the inline analyzeResponse (nulls preserved)")
    func analyzeInline() async throws {
        let resp: JSONValue = .object([
            "bpm": .number(120),
            "key": .string("C major"),
            "duration": .number(112.0),
            "downbeats": .null,
            "loudnessLufs": .null,
            "caption": .string("indie rock"),
        ])
        let sender = StubSender(responses: ["gen.submit": resp])
        let client = GenProtocolClient(sender: sender)
        let result = try await client.analyze(request: GenProtocolRequest.analyze(sourceAudioRef: "/tmp/x.wav"))
        #expect(result.bpm == 120)
        #expect(result.key == "C major")
        #expect(result.downbeats == nil)   // not produced by the Python backend today
        #expect(result.loudnessLufs == nil) // planned for the Rust engine's media crate
    }
}

// MARK: - ULID + request builder

@Suite("GenProtocol ULID + request")
struct GenProtocolULIDTests {

    @Test("ULID matches the schema pattern")
    func ulidShape() {
        // gen-protocol.schemas.json #/$defs/ulid: ^[0-7][0-9A-HJKMNP-TV-Z]{25}$
        let pattern = try! NSRegularExpression(pattern: "^[0-7][0-9A-HJKMNP-TV-Z]{25}$")
        for _ in 0..<200 {
            let id = ULID.generate()
            #expect(id.count == 26)
            let range = NSRange(id.startIndex..., in: id)
            #expect(pattern.firstMatch(in: id, range: range) != nil, "invalid ULID: \(id)")
        }
    }

    @Test("ULID is time-ordered for the same millisecond bucketing")
    func ulidTimeOrdered() {
        let early = ULID.generate(now: Date(timeIntervalSince1970: 1000))
        let late = ULID.generate(now: Date(timeIntervalSince1970: 2_000_000_000))
        // The 10-char timestamp prefix is monotonic with time.
        #expect(String(early.prefix(10)) < String(late.prefix(10)))
    }

    @Test("withRequestId mints a ULID only when absent")
    func withRequestId() {
        let minted = GenProtocolRequest.generate(caption: "x").withRequestId()
        #expect(minted.requestId != nil)
        #expect(minted.requestId?.count == 26)

        let explicit = GenProtocolRequest.generate(caption: "x", requestId: "01ARZ3NDEKTSV4RRFFQ69G5FAV").withRequestId()
        #expect(explicit.requestId == "01ARZ3NDEKTSV4RRFFQ69G5FAV")
    }

    @Test("generate builder maps fields to the contract names")
    func generateBuilder() {
        let req = GenProtocolRequest.generate(caption: "warm lofi", durationSeconds: 120, bpm: 84,
                                              key: "D minor", seed: 42, nVariants: 2, route: .localMLX)
        let obj = req.jsonValue.objectValue!
        #expect(obj["caption"]?.stringValue == "warm lofi")
        #expect(obj["durationSeconds"]?.doubleValue == 120)
        #expect(obj["bpm"]?.intValue == 84)
        #expect(obj["nVariants"]?.intValue == 2)
        #expect(obj["route"]?.stringValue == "local-mlx")
    }

    @Test("revise builder maps region + scope")
    func reviseBuilder() {
        let req = GenProtocolRequest.revise(sourceAudioRef: "clip_1", regionStartSeconds: 4, regionEndSeconds: 8,
                                            instruction: "bigger drums", scope: .drums, seed: 7)
        let obj = req.jsonValue.objectValue!
        #expect(obj["sourceAudioRef"]?.stringValue == "clip_1")
        #expect(obj["regionStartSeconds"]?.doubleValue == 4)
        #expect(obj["regionEndSeconds"]?.doubleValue == 8)
        #expect(obj["scope"]?.stringValue == "drums")
    }
}
