import Foundation

@main struct Tests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        count += 1
        if !condition() { fputs("FAIL: \(name)\n", stderr); exit(1) }
    }
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func limit(_ seconds: Double) -> Limit { Limit(id: "codex:primary", name: "codex", used: 92, minutes: 10080, reset: now.addingTimeInterval(seconds), observed: now) }
        check(limit(6 * 86400 + 4000).countdown(now) == "6d", "days")
        check(limit(13 * 3600).countdown(now) == "13h", "hours")
        check(limit(3599).countdown(now) == "<1h", "under one hour")
        check(limit(0).countdown(now) == "?", "expired does not imply refill")
        check(limit(0).stale(now), "expired is stale")
        check(limit(9999).stale(now.addingTimeInterval(3601)), "old snapshot is stale")
        check(parseLimits(["primary": ["usedPercent": 130.0]], at: now).first?.remaining == 0, "clamped remaining")
        check(parseLimits(["primary": ["resetsAt": 123]], at: now).isEmpty, "missing used is unknown")
        let weekly = limit(99999)
        let short = Limit(id: "codex:secondary", name: "codex", used: 0, minutes: 300, reset: now, observed: now)
        check(preferredLimit([short, weekly])?.minutes == 10080, "weekly preferred")
        check(parseResetCredits(nil, at: now) == nil, "missing reset information is unknown")
        check(parseResetCredits(NSNull(), at: now) == nil, "null reset information is unknown")
        let countOnly = parseResetCredits(["availableCount": 3, "credits": NSNull()], at: now)!
        check(countOnly.availableCount == 3 && countOnly.credits == nil, "count-only response keeps unknown details")
        let zero = parseResetCredits(["availableCount": 0, "credits": []], at: now)!
        check(zero.availableCount == 0 && zero.credits?.isEmpty == true, "zero available is distinct from unknown")
        let capped = parseResetCredits(["availableCount": 8, "credits": [
            ["status": "available", "title": "Full reset", "expiresAt": now.addingTimeInterval(100).timeIntervalSince1970],
            ["status": "consumed", "expiresAt": now.addingTimeInterval(10).timeIntervalSince1970]
        ]], at: now)!
        check(capped.availableCount == 8, "authoritative count does not depend on capped detail rows")
        check(capped.nextExpiry(now: now) == now.addingTimeInterval(100), "consumed credits do not affect next expiry")
        check(capped.isStale(now: now.addingTimeInterval(101)), "expired available detail marks snapshot stale")
        check(capped.availableCount == 8, "expiry does not invent a new server count")
        check(parseResetCredits(["credits": []], at: now)?.availableCount == nil, "empty details do not imply zero count")
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/test-fixture-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("sessions/2027/01/01")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = dir.appendingPathComponent("rollout.jsonl")
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func line(_ type: String, _ payload: [String: Any], at: Date = Date(timeIntervalSince1970: 1_800_000_000)) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": iso.string(from: at), "payload": payload], options: [.sortedKeys]); data.append(10); return data
        }
        func usage(_ input: Int, _ output: Int) -> [String: Any] { ["input_tokens": input, "output_tokens": output, "cached_input_tokens": 50, "reasoning_output_tokens": output] }
        var content = try line("session_meta", ["id": "s1"])
        content.append(try line("event_msg", ["type": "token_count", "info": ["total_token_usage": usage(100, 20)], "rate_limits": ["limit_id": "codex", "primary": ["used_percent": 92.0, "window_minutes": 10080, "resets_at": now.addingTimeInterval(86400).timeIntervalSince1970]]]))
        let record = try line("token_usage_record", ["response_id": "r1", "session_id": "s1", "usage": usage(100, 20)])
        content.append(record); content.append(record)
        try content.write(to: f)
        try line("ignored", [:]).write(to: root.appendingPathComponent("session_index.jsonl"))
        let store = LocalStore(home: root)
        let first = store.scan(now: now)
        check(first.day.first?.usage.total == 120, "modern replaces legacy, dedup response, reasoning not added twice")
        check(first.limits.first?.remaining == 8, "snake case limits")
        check(first.day.first?.usage.cached == 50, "cache is subset of input")
        check(store.scan(now: now).day.first?.usage.total == 120, "repeated scan stable")
        let append = try FileHandle(forWritingTo: f); try append.seekToEnd()
        let second = try line("token_usage_record", ["response_id": "r2", "session_id": "s1", "usage": usage(200, 30)])
        try append.write(contentsOf: second.dropLast())
        check(store.scan(now: now).day.first?.usage.total == 120, "partial final line held")
        try append.write(contentsOf: Data([10])); try append.close()
        check(store.scan(now: now).day.first?.usage.total == 350, "partial line completed once")
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: f.path)
        check(store.scan(now: now.addingTimeInterval(86401)).day.isEmpty, "rolling day expires without new records")
        let legacy = Journal(id: "old")
        for (i, o) in [(100, 20), (100, 20), (150, 30)] {
            let data = try line("event_msg", ["type": "token_count", "info": ["total_token_usage": usage(i, o)]])
            legacy.consume(data.dropLast(), cutoff: now.addingTimeInterval(-10))
        }
        check(legacy.legacy.reduce(0) { $0 + $1.usage.total } == 180, "legacy counters use deltas")
        let historical = try line("event_msg", ["type": "token_count", "info": ["total_token_usage": usage(1000, 100)]], at: now.addingTimeInterval(-8 * 86400))
        let recent = try line("event_msg", ["type": "token_count", "info": ["total_token_usage": usage(1200, 120)]])
        let baseline = Journal(id: "baseline")
        baseline.consume(historical.dropLast(), cutoff: now.addingTimeInterval(-7 * 86400)); baseline.consume(recent.dropLast(), cutoff: now.addingTimeInterval(-7 * 86400))
        check(baseline.legacy.reduce(0) { $0 + $1.usage.total } == 220, "old baseline excluded from recent cost")
        try Data().write(to: f)
        check(store.scan(now: now).day.isEmpty, "truncated file resets cache")
        print("PASS: \(count) checks")
    }
}
