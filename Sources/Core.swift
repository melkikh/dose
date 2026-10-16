import Foundation
import Darwin
import SQLite3

struct Limit: Identifiable {
    let id: String
    let name: String
    let used: Double
    let minutes: Double
    let reset: Date?
    let observed: Date
    var remaining: Double { max(0, min(100, 100 - used)) }
    func expired(_ now: Date) -> Bool { reset.map { $0 <= now } ?? false }
    func stale(_ now: Date) -> Bool { now.timeIntervalSince(observed) > 3600 || expired(now) }
    func countdown(_ now: Date) -> String {
        guard let reset else { return "?" }
        let seconds = reset.timeIntervalSince(now)
        if seconds <= 0 { return "?" }
        if seconds >= 86400 { return "\(Int(seconds / 86400))d" }
        if seconds >= 3600 { return "\(Int(seconds / 3600))h" }
        return "<1h"
    }
}

func parseLimits(_ object: [String: Any], at date: Date) -> [Limit] {
    let id = object["limit_id"] as? String ?? object["limitId"] as? String ?? "codex"
    let name = object["limit_name"] as? String ?? object["limitName"] as? String ?? id
    return ["primary", "secondary"].compactMap { slot in
        guard let w = object[slot] as? [String: Any],
              let used = (w["used_percent"] ?? w["usedPercent"]) as? Double,
              used.isFinite else { return nil }
        let minutes = (w["window_minutes"] ?? w["windowDurationMins"]) as? Double ?? 0
        let timestamp = (w["resets_at"] ?? w["resetsAt"]) as? Double
        return Limit(id: id + ":" + slot, name: name, used: used, minutes: minutes,
                     reset: timestamp.map(Date.init(timeIntervalSince1970:)), observed: date)
    }
}

struct ResetCredit {
    let title: String
    let status: String
    let expiresAt: Date?
}

struct ResetCredits {
    let availableCount: Int?
    let credits: [ResetCredit]?
    let observed: Date
    func nextExpiry(now: Date) -> Date? {
        guard let count = availableCount, count > 0 else { return nil }
        return credits?.filter { $0.status == "available" }
            .compactMap(\.expiresAt).filter { $0 > now }.min()
    }
    func isStale(now: Date) -> Bool {
        now.timeIntervalSince(observed) > 3600 ||
        (credits?.contains { $0.status == "available" && $0.expiresAt.map { $0 <= now } == true } ?? false)
    }
}

func parseResetCredits(_ value: Any?, at observed: Date) -> ResetCredits? {
    guard let value = value as? [String: Any] else { return nil }
    let count = value["availableCount"] as? Int
    let rows = value["credits"] as? [[String: Any]]
    return ResetCredits(
        availableCount: count.flatMap { $0 >= 0 ? $0 : nil },
        credits: rows.map { rows in rows.map { row in
            ResetCredit(title: row["title"] as? String ?? "Usage limit reset",
                        status: row["status"] as? String ?? "unknown",
                        expiresAt: (row["expiresAt"] as? Double).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil })
        } }, observed: observed)
}

struct AccountUsage {
    let limits: [Limit]
    let resetCredits: ResetCredits?
    let checkedAt: Date
}

struct Usage {
    var input: Int64 = 0
    var cached: Int64 = 0
    var output: Int64 = 0
    var total: Int64 { input + output }
    init(_ dict: [String: Any] = [:]) {
        input = max(0, (dict["input_tokens"] as? NSNumber)?.int64Value ?? 0)
        cached = min(input, max(0, (dict["cached_input_tokens"] as? NSNumber)?.int64Value ?? 0))
        output = max(0, (dict["output_tokens"] as? NSNumber)?.int64Value ?? 0)
    }
    static func + (a: Usage, b: Usage) -> Usage {
        var r = Usage(); r.input = a.input + b.input; r.cached = a.cached + b.cached; r.output = a.output + b.output; return r
    }
    func delta(from old: Usage) -> Usage {
        // A counter decrease starts a new cumulative segment.
        if input < old.input || output < old.output { return self }
        var r = Usage(); r.input = input - old.input; r.cached = max(0, cached - old.cached); r.output = output - old.output; return r
    }
}
struct UsageEvent {
    let key: String
    let session: String
    let date: Date
    let usage: Usage
}
struct SessionUsage: Identifiable {
    let id: String
    let name: String
    let usage: Usage
}
struct Snapshot {
    var limits: [Limit] = []
    var day: [SessionUsage] = []
    var week: [SessionUsage] = []
    var fileCount = 0
    var errors = 0
    var scannedAt = Date()
}

final class Journal {
    var offset: UInt64 = 0
    var pending = Data()
    var session: String
    var modern = [UsageEvent]()
    var legacy = [UsageEvent]()
    var hasModern = false
    var previous = Usage()
    var limits = [String: Limit]()
    var malformed = 0
    private let fractional = ISO8601DateFormatter()
    private let plain = ISO8601DateFormatter()
    init(id: String) {
        session = id
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }
    func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }
    private static let needles = ["\"token_count\"", "\"token_usage_record\"", "\"session_meta\""].map { Data($0.utf8) }
    func consume(_ line: Data, cutoff: Date) {
        // Skip transcript bodies before JSON parsing; retain numeric telemetry only.
        guard Self.needles.contains(where: { candidate in line.withUnsafeBytes { bytes in candidate.withUnsafeBytes { needle in
            guard let base = bytes.baseAddress, let target = needle.baseAddress else { return false }
            return memmem(base, bytes.count, target, needle.count) != nil
        } } }) else { return }
        guard let x = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { malformed += 1; return }
        guard let p = x["payload"] as? [String: Any] else { return }
        let kind = x["type"] as? String
        if kind == "session_meta" { session = p["id"] as? String ?? session; return }
        guard let at = date(x["timestamp"]) else { return }
        if kind == "token_usage_record" {
            hasModern = true
            guard at >= cutoff, let u = p["usage"] as? [String: Any] else { return }
            let response = p["response_id"] as? String
            let key = response ?? "\(session):\(x["ordinal"] ?? 0):\(x["timestamp"] ?? "")"
            modern.append(UsageEvent(key: key, session: p["session_id"] as? String ?? session, date: at, usage: Usage(u)))
        } else if kind == "event_msg", p["type"] as? String == "token_count" {
            if let rate = p["rate_limits"] as? [String: Any] {
                for limit in parseLimits(rate, at: at) where limits[limit.id].map({ $0.observed <= at }) ?? true { limits[limit.id] = limit }
            }
            guard let info = p["info"] as? [String: Any], let total = info["total_token_usage"] as? [String: Any] else { return }
            let cumulative = Usage(total)
            let delta = cumulative.delta(from: previous)
            previous = cumulative
            if at >= cutoff && delta.total > 0 {
                legacy.append(UsageEvent(key: "\(session):\(x["timestamp"] ?? ""):\(cumulative.total)", session: session, date: at, usage: delta))
            }
        }
    }
    func read(_ url: URL, cutoff: Date) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            offset += UInt64(chunk.count)
            let previouslyBuffered = pending.count
            pending.append(chunk)
            var start = pending.startIndex
            let ends: [Int] = pending.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return [] }
                var offset = previouslyBuffered
                var positions = [Int]()
                while offset < bytes.count, let newline = memchr(base.advanced(by: offset), 10, bytes.count - offset) {
                    let index = base.distance(to: newline)
                    positions.append(pending.startIndex + index)
                    offset = index + 1
                }
                return positions
            }
            for end in ends {
                consume(pending[start..<end], cutoff: cutoff)
                start = end + 1
            }
            if start > pending.startIndex { pending = Data(pending[start...]) }
            // An incomplete oversized transcript line is not telemetry.
            if pending.count > 32 * 1024 * 1024 { throw NSError(domain: "Dose", code: 1) }
        }
        modern.removeAll { $0.date < cutoff }; legacy.removeAll { $0.date < cutoff }
    }
}

// Mutable parser state is protected by scanLock; scans never overlap.
final class LocalStore: @unchecked Sendable {
    private let scanLock = NSLock()
    let home: URL
    private var journals = [String: Journal]()
    private var signatures = [String: String]()
    private var inodes = [String: String]()
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) { self.home = home }
    func scan(now: Date = Date()) -> Snapshot {
        scanLock.lock(); defer { scanLock.unlock() }
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-7 * 86400)
        var result = Snapshot()
        var files = [(URL, Date, Int, String)]()
        for name in ["sessions", "archived_sessions"] {
            let root = home.appendingPathComponent(name)
            guard fm.fileExists(atPath: root.path) else { if name == "sessions" { result.errors += 1 }; continue }
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .fileResourceIdentifierKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in result.errors += 1; return true }) else { result.errors += 1; continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .fileResourceIdentifierKey]), v.isRegularFile == true else { continue }
                files.append((url, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0, String(describing: v.fileResourceIdentifier)))
            }
        }
        let newest = files.max { $0.1 < $1.1 }?.0.path
        let eligible = files.filter { $0.1 >= cutoff || $0.0.path == newest }
        let paths = Set(eligible.map { $0.0.path })
        journals = journals.filter { paths.contains($0.key) }
        for (url, modified, size, inode) in eligible {
            let path = url.path
            let signature = "\(modified.timeIntervalSince1970):\(size):\(inode)"
            if let old = signatures[path], old != signature, let j = journals[path], (UInt64(size) <= j.offset || inodes[path] != inode) { journals.removeValue(forKey: path) }
            if signatures[path] != signature || journals[path] == nil {
                let journal = journals[path] ?? Journal(id: url.deletingPathExtension().lastPathComponent)
                do { try journal.read(url, cutoff: cutoff); journals[path] = journal; signatures[path] = signature; inodes[path] = inode }
                catch { result.errors += 1 }
            }
        }
        var limits = [String: Limit]()
        var seen = Set<String>()
        var events = [UsageEvent]()
        for journal in journals.values {
            for limit in journal.limits.values where limits[limit.id].map({ $0.observed < limit.observed }) ?? true { limits[limit.id] = limit }
            result.errors += journal.malformed
            for event in journal.hasModern ? journal.modern : journal.legacy where event.date >= cutoff && seen.insert(event.key).inserted { events.append(event) }
        }
        var names = [String: String]()
        if let data = try? Data(contentsOf: home.appendingPathComponent("session_index.jsonl")) {
            for line in data.split(separator: 10) {
                if let x = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], let id = x["id"] as? String, let name = x["thread_name"] as? String { names[id] = name }
            }
        }
        // SQLite is opened read-only and only the chat id/title columns are selected.
        if let entries = try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil) {
            let databases = entries.filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            if let dbURL = databases.first {
                var db: OpaquePointer?
                if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK {
                    sqlite3_busy_timeout(db, 100)
                    var statement: OpaquePointer?
                    let queries = ["SELECT id, COALESCE(NULLIF(name, ''), title) FROM threads", "SELECT id, title FROM threads"]
                    for query in queries {
                        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK { break }
                        sqlite3_finalize(statement); statement = nil
                    }
                    if let statement {
                        while sqlite3_step(statement) == SQLITE_ROW {
                            if let id = sqlite3_column_text(statement, 0), let title = sqlite3_column_text(statement, 1) {
                                let value = String(cString: title)
                                if !value.isEmpty { names[String(cString: id)] = String(value.prefix(200)) }
                            }
                        }
                        sqlite3_finalize(statement)
                    }
                }
                if let db { sqlite3_close(db) }
            }
        }
        func ranked(since: Date) -> [SessionUsage] {
            var totals = [String: Usage]()
            for e in events where e.date >= since && e.date <= now { totals[e.session] = (totals[e.session] ?? Usage()) + e.usage }
            return totals.map { SessionUsage(id: $0.key, name: names[$0.key] ?? "Chat \($0.key.prefix(8))", usage: $0.value) }.sorted { $0.usage.total == $1.usage.total ? $0.id < $1.id : $0.usage.total > $1.usage.total }
        }
        result.limits = Array(limits.values).sorted { $0.id < $1.id }
        result.day = ranked(since: now.addingTimeInterval(-86400)); result.week = ranked(since: cutoff)
        result.fileCount = journals.count; result.scannedAt = now
        return result
    }
}

func preferredLimit(_ limits: [Limit]) -> Limit? {
    let codex = limits.filter { $0.id.hasPrefix("codex:") }
    return (codex.isEmpty ? limits : codex).max { $0.minutes < $1.minutes }
}
func compactNumber(_ number: Int64) -> String {
    if number >= 1_000_000 { return String(format: "%.1fM", Double(number) / 1_000_000) }
    if number >= 1_000 { return String(format: "%.0fK", Double(number) / 1_000) }
    return String(number)
}

// Snapshot timestamps may be a little ahead of this machine's clock. Always
// describe the age of the snapshot, never a countdown to a future update.
func freshnessLabel(observed: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(observed))
    if seconds < 60 { return "Updated just now" }
    if seconds < 3600 { return "Updated \(Int(seconds / 60))m ago" }
    if seconds < 86400 { return "Updated \(Int(seconds / 3600))h ago" }
    return "Updated \(Int(seconds / 86400))d ago"
}
