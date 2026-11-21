import Foundation

/// Minimal newline-delimited JSON-RPC client over a child process' stdio
/// (used for `codex app-server`).
final class JSONRPCProcess: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    var onNotification: (@Sendable (String, [String: Any]) -> Void)?

    struct RPCError: LocalizedError {
        var message: String
        var code: Int?
        var errorDescription: String? { message }
    }

    init(exe: String, args: [String], env: [String: String]) {
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.environment = env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    }

    func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            if d.isEmpty { self.failAll(RPCError(message: "Process exited")); return }
            self.consume(d)
        }
        process.terminationHandler = { [weak self] _ in
            self?.failAll(RPCError(message: "Process exited"))
        }
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    func stop() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        failAll(RPCError(message: "Stopped"))
    }

    private func consume(_ d: Data) {
        lock.lock()
        buffer.append(d)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines {
            guard let msg = JSON.object(Data(line)) else { continue }
            if let id = JSON.int(msg["id"]), msg["method"] == nil {
                lock.lock()
                let cont = pending.removeValue(forKey: id)
                lock.unlock()
                if let err = msg["error"] as? [String: Any] {
                    cont?.resume(throwing: RPCError(message: JSON.string(err["message"]) ?? "Request failed",
                                                    code: JSON.int(err["code"])))
                } else {
                    cont?.resume(returning: (msg["result"] as? [String: Any]) ?? [:])
                }
            } else if let method = msg["method"] as? String {
                if msg["id"] != nil {
                    // Server -> client request (approvals etc). We never expect any; decline politely.
                    write(["id": msg["id"]!, "error": ["code": -32601, "message": "Not supported"]])
                } else {
                    onNotification?(method, (msg["params"] as? [String: Any]) ?? [:])
                }
            }
        }
    }

    private func failAll(_ error: Error) {
        lock.lock()
        let all = pending
        pending.removeAll()
        lock.unlock()
        all.values.forEach { $0.resume(throwing: error) }
    }

    private func write(_ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    func notify(_ method: String, _ params: [String: Any]? = nil) {
        var o: [String: Any] = ["method": method]
        if let params { o["params"] = params }
        write(o)
    }

    private func allocateID() -> Int {
        lock.lock(); defer { lock.unlock() }
        nextID += 1
        return nextID - 1
    }

    func request(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 20) async throws -> [String: Any] {
        let id = allocateID()
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            pending[id] = cont
            lock.unlock()
            write(["id": id, "method": method, "params": params])
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let c = self.pending.removeValue(forKey: id)
                self.lock.unlock()
                c?.resume(throwing: RPCError(message: "\(method) timed out"))
            }
        }
    }
}
