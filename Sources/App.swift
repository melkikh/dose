import AppKit
import SwiftUI
import ServiceManagement

@MainActor final class DoseModel: ObservableObject {
    static let shared = DoseModel()
    @Published var snapshot = Snapshot()
    @Published var now = Date()
    @Published var loading = true
    @Published var refreshing = false
    @Published var error: String?
    @Published var resetCredits: ResetCredits?
    @Published var resetCheckedAt: Date?
    @Published var period = 1 { didSet { onUpdate?() } }
    private let store = LocalStore()
    private let queue = DispatchQueue(label: "dose.journals", qos: .utility)
    private var scanning = false
    private var manual = [Limit]()
    var onUpdate: (() -> Void)?
    var limits: [Limit] {
        var merged = Dictionary(uniqueKeysWithValues: snapshot.limits.map { ($0.id, $0) })
        for limit in manual where merged[limit.id].map({ $0.observed < limit.observed }) ?? true { merged[limit.id] = limit }
        return merged.values.sorted { $0.minutes == $1.minutes ? $0.id < $1.id : $0.minutes > $1.minutes }
    }
    var selected: Limit? { preferredLimit(limits) }
    var sessions: [SessionUsage] { period == 1 ? snapshot.day : snapshot.week }
    func scan() {
        guard !scanning else { return }; scanning = true
        let store = self.store
        queue.async {
            let snapshot = store.scan()
            DispatchQueue.main.async {
                self.snapshot = snapshot; self.loading = false; self.scanning = false
                self.now = Date(); self.onUpdate?()
            }
        }
    }
    func tick() { now = Date(); onUpdate?() }
    func applyRefresh(_ account: AccountUsage) {
        manual = account.limits
        resetCredits = account.resetCredits
        resetCheckedAt = account.checkedAt
        now = Date(); onUpdate?()
    }
    func refreshCodex() {
        guard !refreshing else { return }; refreshing = true; error = nil
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try CodexRefresh.read() }
            DispatchQueue.main.async {
                self.refreshing = false
                switch result {
                case .success(let account): self.applyRefresh(account)
                case .failure(let error): self.error = refreshErrorMessage(error); self.onUpdate?()
                }
            }
        }
    }
}

func windowName(_ minutes: Double) -> String {
    if minutes >= 10080 { return "Weekly" }
    if minutes >= 1440 { return "\(Int(minutes / 1440))d" }
    if minutes >= 60 { return "\(Int(minutes / 60))h" }
    return minutes > 0 ? "\(Int(minutes)) min" : "Limit"
}

struct Ring: View {
    let limit: Limit?
    let now: Date
    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.1), lineWidth: 5)
            if let limit, !limit.expired(now) {
                Circle().trim(from: 0, to: limit.remaining / 100)
                    .stroke(limit.remaining <= 10 ? Color.orange : Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(limit?.countdown(now) ?? "—").font(.system(size: 20, weight: .semibold, design: .rounded))
        }.frame(width: 64, height: 64)
    }
}

@MainActor final class LoginSettings: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var busy = false
    @Published var error: String?
    var requested: Bool { status == .enabled || status == .requiresApproval }
    func refresh() { status = SMAppService.mainApp.status }
    func setEnabled(_ enabled: Bool) {
        guard !busy else { return }
        busy = true; error = nil
        Task { @MainActor in
            defer { refresh(); busy = false }
            do {
                if enabled {
                    if SMAppService.mainApp.status == .notRegistered || SMAppService.mainApp.status == .notFound {
                        try SMAppService.mainApp.register()
                    }
                } else if SMAppService.mainApp.status != .notRegistered {
                    try await SMAppService.mainApp.unregister()
                }
            } catch {
                self.error = "Could not change launch at login (\((error as NSError).domain), code \((error as NSError).code))."
            }
        }
    }
}

struct LoginSettingsView: View {
    @StateObject private var settings = LoginSettings()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Launch at login", isOn: Binding(get: { settings.requested }, set: { settings.setEnabled($0) }))
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                .disabled(settings.busy)
            if settings.status == .requiresApproval {
                Text("Approval is required in System Settings.").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    .font(.system(size: 11))
            }
            if let error = settings.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
        .onAppear { settings.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in settings.refresh() }
    }
}

struct ResetCreditsView: View {
    @ObservedObject var model: DoseModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise").foregroundStyle(.secondary)
                Text("Usage limit resets")
                Spacer()
                if let count = model.resetCredits?.availableCount {
                    if model.resetCredits?.isStale(now: model.now) == true {
                        Circle().fill(.orange).frame(width: 5, height: 5)
                    }
                    Text("\(count)").monospacedDigit().fontWeight(.semibold)
                } else {
                    Button(model.refreshing ? "Checking…" : (model.resetCheckedAt == nil ? "Check" : "Unavailable ↻")) { model.refreshCodex() }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor).disabled(model.refreshing)
                }
            }.font(.system(size: 11))
            if let expires = model.resetCredits?.nextExpiry(now: model.now) {
                Text("Next expiry: \(expires.formatted(.dateTime.locale(Locale(identifier: "en_GB")).day().month(.abbreviated).hour().minute()))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.help(details)
    }
    var details: String {
        guard let resets = model.resetCredits else {
            return model.resetCheckedAt == nil
                ? "Click to check available resets through Codex."
                : "Codex did not provide reset information. The available count is unknown."
        }
        var lines = [freshnessLabel(observed: resets.observed, now: model.now)]
        if resets.isStale(now: model.now) { lines.append("This snapshot may be outdated. Refresh through Codex.") }
        if let credits = resets.credits, !credits.isEmpty {
            for credit in credits where credit.status == "available" {
                let expiry = credit.expiresAt.map { "expires " + $0.formatted(.dateTime.locale(Locale(identifier: "en_GB")).day().month(.abbreviated).hour().minute()) } ?? "expiry not provided"
                lines.append("\(credit.title) · \(expiry)")
            }
        } else if (resets.availableCount ?? 0) > 0 { lines.append("Individual reset details were not provided.") }
        return lines.joined(separator: "\n")
    }
}

struct Panel: View {
    @ObservedObject var model: DoseModel
    @State private var showingSettings = false
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("dose").font(.system(size: 16, weight: .bold, design: .rounded))
                Spacer()
                Text("CODEX").font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
                Button { showingSettings.toggle() } label: { Image(systemName: "gearshape").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(showingSettings ? Color.accentColor : Color.secondary)
                    .help("Settings").accessibilityLabel("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Quit Dose")
            }
            if showingSettings {
                LoginSettingsView()
                Divider()
            }
            if let limit = model.selected {
                HStack(spacing: 18) {
                    Ring(limit: limit, now: model.now)
                    VStack(alignment: .leading, spacing: 3) {
                        if limit.expired(model.now) {
                            Text("Refresh needed").font(.headline)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text("\(Int(limit.remaining.rounded(.down)))%").font(.system(size: 32, weight: .semibold, design: .rounded))
                                Text("remaining").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                        if let reset = limit.reset {
                            Text("Resets \(reset.formatted(.dateTime.locale(Locale(identifier: "en_GB")).day().month(.abbreviated).hour().minute()))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Text("\(windowName(limit.minutes)) · \(limit.name)").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                if model.limits.count > 1 {
                    ForEach(model.limits.filter { $0.id != limit.id }) { other in
                        HStack {
                            Text("\(other.name) · \(windowName(other.minutes))")
                            Spacer()
                            Text(other.expired(model.now) ? "Refresh" : "\(Int(other.remaining))% · \(other.countdown(model.now))")
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    Ring(limit: nil, now: model.now)
                    Text(model.loading ? "Reading local usage…" : "No limits in local logs yet").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            ResetCreditsView(model: model)
            Divider()
            HStack {
                Text("Usage by chat").font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("Period", selection: $model.period) {
                    Text("24h").tag(1); Text("7d").tag(7)
                }.pickerStyle(.segmented).frame(width: 106).labelsHidden()
            }
            if model.loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else if model.sessions.isEmpty {
                Text("No local usage records for this period.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    ForEach(Array(model.sessions.prefix(5).enumerated()), id: \.element.id) { index, session in
                        Button {
                            if let url = URL(string: "codex://threads/\(session.id)") { NSWorkspace.shared.open(url) }
                        } label: {
                            HStack(spacing: 8) {
                                Text("\(index + 1)").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 12)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(session.name).font(.system(size: 12)).lineLimit(1)
                                        Spacer(minLength: 6)
                                        Text(compactNumber(session.usage.total)).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                                    }
                                    GeometryReader { geo in
                                        Capsule().fill(Color.primary.opacity(0.06))
                                        Capsule().fill(Color.accentColor.opacity(0.55)).frame(width: max(2, geo.size.width * Double(session.usage.total) / Double(max(1, model.sessions.first?.usage.total ?? 1))))
                                    }.frame(height: 3)
                                }
                            }
                        }.buttonStyle(.plain).help("\(session.name)\nInput: \(session.usage.input), cached: \(session.usage.cached), output: \(session.usage.output)\nOpen chat in Codex")
                    }
                }
                Text("\(compactNumber(model.sessions.reduce(0) { $0 + $1.usage.total })) tokens · \(model.sessions.count) chats")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text("Input and output tokens, including cache. Not quota percentages.")
                .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                if let limit = model.selected {
                    HStack(spacing: 5) {
                        Circle().fill(limit.stale(model.now) ? Color.orange : Color.green).frame(width: 5, height: 5)
                        Text(freshnessLabel(observed: limit.observed, now: model.now))
                            .help("Time of the latest limit snapshot. Local logs are checked every 15 seconds.")
                        Spacer()
                        Text("logs every 15s")
                    }.font(.system(size: 9)).foregroundStyle(.secondary)
                }
                if let error = model.error { Text(error).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                if model.snapshot.errors > 0 {
                    Text("Unreadable or damaged local logs: \(model.snapshot.errors). Usage may be incomplete.").font(.system(size: 10)).foregroundStyle(.orange)
                }
                Button { model.refreshCodex() } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text(model.refreshing ? "Checking through Codex…" : "Refresh through Codex")
                        Spacer()
                    }.font(.system(size: 11))
                }.buttonStyle(.plain).disabled(model.refreshing)
                    .help("Codex checks limits online using its existing sign-in. Dose does not read or store access tokens.")
            }
        }.padding(20).frame(width: 344).background(.regularMaterial)
    }
}

@MainActor func statusImage(limit: Limit?, now: Date) -> NSImage {
    let image = NSImage(size: NSSize(width: 26, height: 22), flipped: false) { rect in
        let center = NSPoint(x: 13, y: 11)
        NSColor.black.withAlphaComponent(0.2).setStroke()
        let track = NSBezierPath(ovalIn: NSRect(x: 3.25, y: 1.25, width: 19.5, height: 19.5))
        track.lineWidth = 1.75; track.stroke()
        if let limit, !limit.expired(now), limit.remaining > 0 {
            NSColor.black.setStroke()
            let arc = NSBezierPath(); arc.lineWidth = 1.75; arc.lineCapStyle = .round
            arc.appendArc(withCenter: center, radius: 9.75, startAngle: 90, endAngle: 90 - 360 * limit.remaining / 100, clockwise: true); arc.stroke()
        }
        let text = limit?.countdown(now) ?? "—"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: text.count > 2 ? 7.5 : 9, weight: .semibold), .foregroundColor: NSColor.black]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attrs)
        if limit?.stale(now) == true {
            NSColor.black.setFill(); NSBezierPath(ovalIn: NSRect(x: 23, y: 2, width: 2.5, height: 2.5)).fill()
        }
        return true
    }
    image.isTemplate = true
    return image
}

// Native SwiftUI owns the menu extra's window and focus.
@MainActor struct DoseApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = DoseModel.shared
    var body: some Scene {
        MenuBarExtra {
            ScrollView {
                Panel(model: model)
            }
            .frame(width: 344, height: min(520, (NSScreen.main?.visibleFrame.height ?? 800) - 48))
        } label: {
            Image(nsImage: statusImage(limit: model.selected, now: model.now))
                .accessibilityLabel("Dose: \(model.selected.map { "\(Int($0.remaining))% remaining, \($0.countdown(model.now)) until reset" } ?? "no data")")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = DoseModel.shared
    var timers = [Timer]()
    private var escapeMonitor: Any?
    var diagnosticPath: String? {
        guard let i = CommandLine.arguments.firstIndex(of: "--ui-diagnostics"), CommandLine.arguments.count > i + 1 else { return nil }
        return CommandLine.arguments[i + 1]
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only handle events delivered to Dose's focused window.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard event.keyCode == 53, modifiers.isEmpty,
                  let window = event.window, window.isKeyWindow,
                  let button = self?.statusButton() else { return event }
            self?.writeDiagnostics(stage: "escape-received")
            button.performClick(nil)
            return nil
        }
        model.scan()
        timers.append(Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in DispatchQueue.main.async { self?.model.scan() } })
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in DispatchQueue.main.async { self?.model.tick() } })
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        if diagnosticPath != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                self.writeDiagnostics(stage: "launched")
                if CommandLine.arguments.contains("--exercise-menu") {
                    // In-process synthetic events bypass WindowServer's click
                    // activation, so activate first for this test harness only.
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.exerciseMenu() }
                }
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }
    @objc func wake() { model.tick(); model.scan() }

    // Use the native toggle action so SwiftUI keeps its presentation state in sync.
    func statusButton() -> NSStatusBarButton? {
        func find(_ view: NSView) -> NSStatusBarButton? {
            if let button = view as? NSStatusBarButton { return button }
            for child in view.subviews { if let button = find(child) { return button } }
            return nil
        }
        for window in NSApp.windows { if let view = window.contentView, let button = find(view) { return button } }
        return nil
    }
    func writeDiagnostics(stage: String) {
        guard let path = diagnosticPath else { return }
        let button = statusButton()
        let windows = NSApp.windows.filter { $0.isVisible && $0 != button?.window }
        let info: [String: Any] = [
            "stage": stage,
            "statusButtonFound": button != nil,
            "statusFrame": button?.window.map { NSStringFromRect($0.frame) } ?? "nil",
            "windows": windows.map { w in [
                "frame": NSStringFromRect(w.frame),
                "key": w.isKeyWindow,
                "fitsScreen": w.screen?.visibleFrame.contains(w.frame) ?? false,
                "belowMenuBar": w.frame.maxY <= (w.screen?.visibleFrame.maxY ?? 0)
            ] },
            "statusPreferences": UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("NSStatusItem") }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
            try? data.write(to: URL(fileURLWithPath: path + "." + stage + ".json"))
        }
    }
    func exerciseMenu() {
        guard let button = statusButton() else { writeDiagnostics(stage: "button-missing"); return }
        // The same action used by a physical menu-bar click, spaced to catch
        // windows that immediately disappear when activation completes.
        NSApp.activate(ignoringOtherApps: true)
        button.performClick(nil)
        self.writeDiagnostics(stage: "clicked")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.writeDiagnostics(stage: "first-open")
            if CommandLine.arguments.contains("--exercise-escape") {
                guard let window = NSApp.keyWindow,
                      let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                          windowNumber: window.windowNumber, context: nil,
                          characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                          isARepeat: false, keyCode: 53) else {
                    self.writeDiagnostics(stage: "escape-event-missing"); return
                }
                NSApp.sendEvent(event)
            } else {
                button.performClick(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.writeDiagnostics(stage: "closed")
                // Closing a menu returns activation to the previous app. A real
                // menu-bar click reactivates through WindowServer; performClick
                // only sends the control action, so reproduce that prerequisite.
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    NSApp.activate(ignoringOtherApps: true)
                    button.performClick(nil)
                    self.writeDiagnostics(stage: "reopen-clicked")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.writeDiagnostics(stage: "reopened")
                    }
                }
            }
        }
    }
}

@main struct Dose {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains("--check-login-item") {
            let service = SMAppService.mainApp
            let before = service.status
            guard before == .notRegistered || before == .notFound else {
                print("SKIP: preserving existing login-item setting (\(before.rawValue))"); return
            }
            do {
                try service.register()
                let registered = service.status
                try service.unregister()
                let restored = service.status
                print("login-item register=\(registered.rawValue) restored=\(restored.rawValue)")
                guard registered == .enabled, restored == .notRegistered || restored == .notFound else { exit(1) }
            } catch {
                let failure = error
                if service.status == .enabled || service.status == .requiresApproval {
                    do { try service.unregister() }
                    catch { fputs("Could not restore login setting: \(error)\n", stderr); exit(2) }
                }
                fputs("Login item check failed: \(failure)\n", stderr); exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--login-status") {
            print("loginItemStatus=\(SMAppService.mainApp.status.rawValue)")
            return
        }
        if CommandLine.arguments.contains("--diagnose") {
            let start = Date(); let store = LocalStore(); let s = store.scan()
            print("journals=\(s.fileCount) errors=\(s.errors) chats24h=\(s.day.count) chats7d=\(s.week.count) scanSeconds=\(Date().timeIntervalSince(start))")
            if let l = preferredLimit(s.limits) { print("remaining=\(l.remaining) countdown=\(l.countdown(Date()))") }
            let second = Date(); let again = store.scan(); print("incrementalSeconds=\(Date().timeIntervalSince(second)) stable=\(s.week.reduce(0) { $0 + $1.usage.total } == again.week.reduce(0) { $0 + $1.usage.total })")
            return
        }
        if CommandLine.arguments.contains("--refresh") {
            do {
                let account = try CodexRefresh.read()
                for limit in account.limits { print("\(limit.id): remaining=\(limit.remaining), countdown=\(limit.countdown(Date()))") }
                print("availableResets=\(account.resetCredits?.availableCount.map(String.init) ?? "unknown")")
            }
            catch { fputs("\(refreshErrorMessage(error))\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if let i = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > i + 1 {
            let model = DoseModel(); model.snapshot = LocalStore().scan(); model.loading = false
            if CommandLine.arguments.contains("--preview-refresh") {
                do { model.applyRefresh(try CodexRefresh.read()) }
                catch { model.error = refreshErrorMessage(error) }
            }
            let view = NSHostingView(rootView: Panel(model: model))
            let size = view.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view; view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) }
            }
            let icon = statusImage(limit: model.selected, now: Date())
            icon.isTemplate = false
            if let tiff = icon.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1] + ".icon.png"))
            }
            return
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: "local.melkikh.dose").count > 1 { return }
        // One-time migration of this app's saved menu position to AppKit's
        // verified automatic name for the single SwiftUI status item.
        let nativePosition = "NSStatusItem Preferred Position Item-0"
        if UserDefaults.standard.object(forKey: nativePosition) == nil,
           let previous = UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position DoseStatusItem") {
            UserDefaults.standard.set(previous, forKey: nativePosition)
        }
        DoseApplication.main()
    }
}
