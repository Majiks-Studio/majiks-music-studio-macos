import Foundation

final class JSONRPCClient: @unchecked Sendable {
    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private var buffer = Data()
    private var pending: [String: CheckedContinuation<RPCResponse, Error>] = [:]
    private let queue = DispatchQueue(label: "majik.rpc.client")
    private let stateLock = NSLock()
    private var _isRunning = false

    // Progress notification handler
    var progressHandler: ((GenerationProgress) -> Void)?

    /// Called when the process terminates (exit code passed as argument)
    var terminationHandler: ((Int32) -> Void)?

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isRunning
    }

    private func setIsRunning(_ newValue: Bool) {
        stateLock.lock()
        _isRunning = newValue
        stateLock.unlock()
    }

    init(pythonPath: String, scriptPath: String, environment: [String: String] = [:]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath]
        if !environment.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                merged[key] = value
            }
            process.environment = merged
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading

        // Always log backend stderr in all builds so release issues are diagnosable.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                AppLog.error("[Backend stderr] \(str)")
            }
        }
    }

    // New initializer for running Python modules (python -m module.name)
    init(pythonPath: String, scriptPath: String, moduleName: String, environment: [String: String] = [:]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath, moduleName]

        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            merged[key] = value
        }
        // Never let Python write .pyc into the signed app bundle — breaks the signature seal.
        merged["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = merged

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading

        // Always log backend stderr in all builds so release issues are diagnosable.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                AppLog.error("[Backend stderr] \(str)")
            }
        }
    }

    func start() throws {
        guard !isRunning else { return }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.setIsRunning(false)
            self.failAllPendingRequests(error: RPCClientError.processNotRunning)
            self.terminationHandler?(proc.terminationStatus)
        }

        try process.run()
        setIsRunning(true)
        listen()
    }

    func stop() {
        guard isRunning else { return }
        process.terminate()
        setIsRunning(false)
        failAllPendingRequests(error: RPCClientError.processNotRunning)
    }

    private func failAllPendingRequests(error: Error) {
        queue.async {
            let pendingCopy = self.pending
            self.pending.removeAll()
            for (_, continuation) in pendingCopy {
                continuation.resume(throwing: error)
            }
        }
    }

    private func cancelPendingRequest(id requestId: String, error: Error = CancellationError()) {
        queue.async {
            guard let continuation = self.pending.removeValue(forKey: requestId) else { return }
            continuation.resume(throwing: error)
        }
    }

    @MainActor
    func send(method: String, params: JSONValue? = nil, timeout: TimeInterval = 120) async throws -> RPCResponse {
        guard isRunning else { throw RPCClientError.processNotRunning }

        let requestId = UUID().uuidString
        let request = RPCRequest(id: requestId, method: method, params: params)
        let encoded = try JSONEncoder().encode(request)
        var payload = encoded
        payload.append(0x0A)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Capture payload before entering closure to satisfy Sendable requirements
                let payloadCopy = payload
                queue.async {
                    self.pending[requestId] = continuation

                    // Add error handling for pipe write to prevent broken pipe crashes
                    do {
                        try self.stdinHandle.write(contentsOf: payloadCopy)
                    } catch {
                        // Write failed - backend may have crashed or pipe closed
                        if let pending = self.pending.removeValue(forKey: requestId) {
                            pending.resume(throwing: RPCClientError.pipeWriteFailure(error))
                        }
                        return
                    }

                    self.queue.asyncAfter(deadline: .now() + timeout) {
                        if let pending = self.pending.removeValue(forKey: requestId) {
                            pending.resume(throwing: RPCClientError.timeout)
                        }
                    }
                }
            }
        } onCancel: {
            self.cancelPendingRequest(id: requestId)
        }
    }

    private func listen() {
        stdoutHandle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                // EOF - backend has died or closed stdout
                AppLog.error("[RPCClient] Backend stdout closed (EOF). Process may have crashed.")
                self.setIsRunning(false)
                self.failAllPendingRequests(error: RPCClientError.processNotRunning)
                return
            }
            self.queue.async {
                self.buffer.append(data)
                self.drainBuffer()
            }
        }
    }

    private func drainBuffer() {
        let newline = Data([0x0A])
        while let range = buffer.range(of: newline) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)

            guard !lineData.isEmpty else { continue }
            do {
                // Try to decode as progress notification first
                if let progressNotification = try? JSONDecoder().decode(ProgressNotification.self, from: lineData),
                   progressNotification.method == "progress" {
                    // Handle progress notification
                    if let handler = progressHandler, let params = progressNotification.params {
                        DispatchQueue.main.async {
                            handler(params)
                        }
                    }
                    continue
                }

                // Otherwise, decode as regular response
                let response = try JSONDecoder().decode(RPCResponse.self, from: lineData)
                if let id = response.id, let continuation = pending.removeValue(forKey: id) {
                    if let error = response.error {
                        continuation.resume(throwing: RPCClientError.serverError(error))
                    } else {
                        continuation.resume(returning: response)
                    }
                }
            } catch {
                let rawLine = String(data: lineData, encoding: .utf8) ?? "<non-utf8 data>"
                AppLog.error("[RPCClient] Failed to decode response line: \(error)")
                AppLog.debug("[RPCClient] Raw line: \(rawLine)")
            }
        }
    }
}
