import Foundation

// EngineClient - a thin Swift facade over the generated UniFFI `MajiksEngine`
// object (scalars in, JSON out). It owns the engine handle, does the JSON
// encode/decode, and surfaces typed results. The heavier translation to L5's
// StudioProjectSnapshot lives in RealStudioEngine.
//
// This whole `Engine/` directory is EXCLUDED from the default app build (see
// Package.swift `exclude` / project.yml) because it links MajiksEngine.xcframework
// and the generated FFI module. It is switched on at integration checkpoint I1;
// the Studio tab keeps using StudioMockEngine until then.

/// A JSON result from the engine, navigated defensively (the raw model serde is
/// snake_case; the read tools are camelCase - this reads whichever is present).
struct EngineJSON {
    let raw: [String: Any]

    init(_ raw: [String: Any]) { self.raw = raw }

    static func parse(_ text: String) -> EngineJSON {
        let data = Data(text.utf8)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return EngineJSON(obj ?? [:])
    }

    subscript(_ key: String) -> Any? { raw[key] }

    func dict(_ key: String) -> [String: Any]? { raw[key] as? [String: Any] }
    func array(_ key: String) -> [[String: Any]] {
        (raw[key] as? [[String: Any]]) ?? []
    }
    func string(_ keys: String...) -> String? {
        for k in keys { if let v = raw[k] as? String { return v } }
        return nil
    }
    func int64(_ keys: String...) -> Int64? {
        for k in keys {
            if let n = raw[k] as? NSNumber { return n.int64Value }
            if let d = raw[k] as? Int { return Int64(d) }
        }
        return nil
    }
    func double(_ keys: String...) -> Double? {
        for k in keys { if let n = raw[k] as? NSNumber { return n.doubleValue } }
        return nil
    }
    func bool(_ keys: String...) -> Bool? {
        for k in keys { if let b = raw[k] as? Bool { return b } }
        return nil
    }
}

/// The facade. Every call is synchronous (the UniFFI object is internally
/// thread-safe: `Arc<Mutex<StudioHost>>`); RealStudioEngine calls these from an
/// actor so the app never blocks the main thread.
final class EngineClient: @unchecked Sendable {
    let engine: MajiksEngine

    /// Open (or create) the `.mstudio` package at `dataDir`.
    init(dataDir: String) throws {
        self.engine = try MajiksEngine.initialize(dataDir: dataDir)
    }

    /// Submit a `{name, params}` envelope through the command bus.
    @discardableResult
    func submit(name: String, params: [String: Any]) throws -> EngineJSON {
        let envelope: [String: Any] = ["name": name, "params": params]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let out = try engine.command(envelopeJson: String(decoding: data, as: UTF8.self))
        return EngineJSON.parse(out)
    }

    /// Call a registry tool by name (the copilot path).
    @discardableResult
    func tool(name: String, args: [String: Any]) throws -> EngineJSON {
        let data = try JSONSerialization.data(withJSONObject: args)
        let out = try engine.tool(name: name, argsJson: String(decoding: data, as: UTF8.self))
        return EngineJSON.parse(out)
    }

    func snapshot(sinceSeq: UInt64?) throws -> EngineJSON {
        EngineJSON.parse(try engine.snapshot(sinceSeq: sinceSeq))
    }

    func transport(action: String, positionTicks: UInt64?) throws -> EngineJSON {
        EngineJSON.parse(try engine.transport(action: action, positionTicks: positionTicks))
    }

    func meters() throws -> EngineJSON { EngineJSON.parse(try engine.meters()) }

    func engineStats() throws -> EngineJSON { EngineJSON.parse(try engine.engineStats()) }

    /// What the engine had to do to rebuild this package when it opened it.
    /// Describes an event at open time, not live state, so it is read ONCE at
    /// init rather than polled.
    func openRecovery() throws -> EngineJSON { EngineJSON.parse(try engine.openRecovery()) }

    /// Enable AUDIBLE live output (the GUI app calls this once at launch). The
    /// device stays silent until this is set; the CLI/tests never call it, so
    /// the automated-blast safety holds. Takes effect on the next `startLive`.
    func setAudibleOutput(_ audible: Bool) throws {
        try engine.setAudibleOutput(audible: audible)
    }

    /// Open a live audio session (silence-gated device unless audible output was
    /// enabled; primes the current project + transport). Idempotent. Returns the
    /// stream info JSON.
    @discardableResult
    func startLive() throws -> EngineJSON { EngineJSON.parse(try engine.startLive()) }

    /// Close the live audio session (releases the device). Returns whether one
    /// was running.
    @discardableResult
    func stopLive() throws -> Bool { try engine.stopLive() }

    func liveRunning() throws -> Bool { try engine.liveRunning() }

    func tiles(clipId: String, zoom: UInt32, startBin: UInt64, maxBins: UInt32) throws -> EngineJSON {
        EngineJSON.parse(try engine.tiles(clipId: clipId, zoom: zoom, startBin: startBin, maxBins: maxBins))
    }

    @discardableResult
    func bounceMaster(outputPath: String) throws -> EngineJSON {
        EngineJSON.parse(try engine.bounceMaster(outputPath: outputPath))
    }

    /// Load sounds into a sampler / drum rack (creating the instrument if it
    /// does not exist), as one journaled transaction. See `StudioHost::
    /// bind_samples` for why this is a host method rather than a catalog
    /// command: the asset ingest that mints a `sourceId` cannot be done from
    /// here, and the transaction it needs cannot be nested inside the one
    /// `import.audio` opens.
    @discardableResult
    func bindSamples(args: [String: Any]) throws -> EngineJSON {
        let data = try JSONSerialization.data(withJSONObject: args)
        return EngineJSON.parse(try engine.bindSamples(argsJson: String(decoding: data, as: UTF8.self)))
    }

    @discardableResult func undo() throws -> Bool { try engine.undo() }
    @discardableResult func redo() throws -> Bool { try engine.redo() }
    func save() throws { try engine.save() }
    func seq() throws -> UInt64 { try engine.seq() }
    func toolsManifest() -> String { engine.toolsManifest() }

    // Sterling, the in-app copilot: job-style send/poll/cancel. Config (endpoint
    // + model) and the key are passed per send; nothing persists in the engine.
    @discardableResult
    func copilotSend(text: String, endpoint: String, model: String, apiKey: String?, systemPromptOverride: String?) throws -> UInt64 {
        try engine.copilotSend(
            text: text,
            endpoint: endpoint,
            model: model,
            apiKey: apiKey,
            systemPromptOverride: systemPromptOverride
        )
    }
    func copilotPoll(turnId: UInt64) throws -> String { try engine.copilotPoll(turnId: turnId) }
    func copilotCancel(turnId: UInt64) throws { try engine.copilotCancel(turnId: turnId) }
    func copilotClearHistory() throws { try engine.copilotClearHistory() }
    func copilotTools() -> String { engine.copilotTools() }

    /// Start the in-process MCP server sharing this engine (PAT from Keychain).
    @discardableResult
    func mcpStart(port: UInt16, pat: String, enabled: Bool) throws -> String {
        try engine.mcpStart(port: port, pat: pat, enabled: enabled)
    }

    func mcpStop() { engine.mcpStop() }
    func mcpRunning() -> Bool { engine.mcpRunning() }
}
