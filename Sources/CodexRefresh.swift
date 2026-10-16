import Foundation
import Darwin

enum RefreshError: LocalizedError {
    case missing, unavailable, timeout, rejected
    var errorDescription: String? {
        switch self {
        case .missing: return "Codex CLI was not found. Local log reading still works."
        case .unavailable: return "Could not connect to Codex. Open Codex and try again."
        case .timeout: return "Codex did not respond within 15 seconds. Previous data is preserved."
        case .rejected: return "Codex did not return limits. Check your sign-in in Codex."
        }
    }
}

func refreshErrorMessage(_ error: Error) -> String {
    if let known = error as? RefreshError, let message = known.errorDescription { return message }
    let detail = error as NSError
    return "Could not refresh through Codex (\(detail.domain), code \(detail.code))."
}

enum CodexRefresh {
    static func read() throws -> AccountUsage {
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw RefreshError.missing }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server", "--stdio"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 0, "method": "initialize", "params": ["clientInfo": ["name": "dose", "version": "0.1.0"]]])
        let deadline = Date().addingTimeInterval(15)
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 65536)
        while Date() < deadline {
            var fd = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            if poll(&fd, 1, 200) <= 0 { continue }
            let count = Darwin.read(fd.fd, &bytes, bytes.count)
            if count <= 0 { throw RefreshError.unavailable }
            buffer.append(contentsOf: bytes.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer = Data(buffer[(newline + 1)...])
                guard let x = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = x["id"] as? Int else { continue }
                if x["error"] != nil { throw RefreshError.rejected }
                if id == 0 {
                    try send(["method": "initialized", "params": [:]])
                    try send(["id": 1, "method": "account/rateLimits/read"])
                } else if id == 1, let result = x["result"] as? [String: Any] {
                    let now = Date()
                    let limits: [Limit]
                    if let all = result["rateLimitsByLimitId"] as? [String: [String: Any]], !all.isEmpty {
                        limits = all.flatMap { key, value -> [Limit] in
                            var v = value; if v["limitId"] == nil { v["limitId"] = key }; return parseLimits(v, at: now)
                        }
                    } else if let rate = result["rateLimits"] as? [String: Any] { limits = parseLimits(rate, at: now) }
                    else { throw RefreshError.rejected }
                    guard !limits.isEmpty else { throw RefreshError.rejected }
                    return AccountUsage(limits: limits, resetCredits: parseResetCredits(result["rateLimitResetCredits"], at: now), checkedAt: now)
                }
            }
            if buffer.count > 2 * 1024 * 1024 { throw RefreshError.unavailable }
        }
        throw RefreshError.timeout
    }
}
