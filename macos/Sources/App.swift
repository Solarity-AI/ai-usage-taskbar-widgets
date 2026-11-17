// Claude usage menu-bar widget for macOS: the menu-bar item, its menu, alerts and start at login.

import AppKit
import UserNotifications

struct Settings: Codable {
    var refreshMinutes: Double = 2
    var alertsOn: Bool = true
    var alertAt: [Double] = [25, 10]
}

struct AlertState: Codable { var reset: Double = 0; var fired: [String] = [] }

let launchAgentLabel = "ai.solarity.claude-usage-widget"
var launchAgentURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
}

func writeLaunchAgent() {
    guard let exe = Bundle.main.executablePath else { return }
    let plist: [String: Any] = [
        "Label": launchAgentLabel,
        "ProgramArguments": [exe],
        "RunAtLoad": true,
        "KeepAlive": ["SuccessfulExit": false],   // restart after a crash, never after Quit
        "ProcessType": "Interactive",
        "LimitLoadToSessionType": "Aqua",
    ]
    try? FileManager.default.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let d = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
        try? d.write(to: launchAgentURL, options: .atomic)
    }
}

// MARK: - Menu views

func colorFor(left: Double) -> NSColor {
    left <= 10 ? .systemRed : (left <= 25 ? .systemOrange : .systemGreen)
}

func colorFor(_ level: PaceLevel) -> NSColor {
    switch level { case .green: return .systemGreen; case .amber: return .systemOrange; case .red: return .systemRed; case .gray: return .secondaryLabelColor }
}

final class BarView: NSView {
    var fill: Double = 0, marker: Double? = nil, color: NSColor = .systemGreen
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0, dy: 0.5)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        let w = r.width * CGFloat(min(1, max(0, fill)))
        if w > 0 {
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: max(w, r.height), height: r.height), xRadius: r.height / 2, yRadius: r.height / 2).fill()
        }
        if let m = marker {
            NSColor.labelColor.setFill()
            NSRect(x: r.minX + r.width * CGFloat(min(1, max(0, m))) - 1, y: bounds.minY, width: 2, height: bounds.height).fill()
        }
    }
}

func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let t = NSTextField(labelWithString: s)
    t.font = .systemFont(ofSize: size, weight: weight)
    t.textColor = color
    t.lineBreakMode = .byWordWrapping
    t.maximumNumberOfLines = 3
    t.preferredMaxLayoutWidth = 288
    return t
}

/// A non-clickable menu row: title + value, a bar, and a small line under it.
func rowItem(title: String, value: String, fill: Double, color: NSColor, note: String?, marker: Double? = nil) -> NSMenuItem {
    let width: CGFloat = 320
    let v = NSView()
    let t = label(title, weight: .medium)
    let val = label(value, weight: .semibold, color: color == .systemGreen ? .labelColor : color)
    val.alignment = .right
    let bar = BarView(); bar.fill = fill; bar.color = color; bar.marker = marker
    let n = note.map { label($0, size: 11, color: .secondaryLabelColor) }
    var y: CGFloat = 6
    if let n = n {
        let h = n.sizeThatFits(NSSize(width: width - 32, height: 100)).height
        n.frame = NSRect(x: 16, y: y, width: width - 32, height: h); v.addSubview(n); y += h + 3
    }
    bar.frame = NSRect(x: 16, y: y, width: width - 32, height: 6); v.addSubview(bar); y += 6 + 4
    t.frame = NSRect(x: 16, y: y, width: 160, height: 17); v.addSubview(t)
    val.frame = NSRect(x: width - 16 - 128, y: y, width: 128, height: 17); v.addSubview(val); y += 17 + 4
    v.frame = NSRect(x: 0, y: 0, width: width, height: y)
    let item = NSMenuItem()
    item.view = v
    return item
}

func textItem(_ s: String, size: CGFloat = 11, color: NSColor = .secondaryLabelColor, weight: NSFont.Weight = .regular) -> NSMenuItem {
    let width: CGFloat = 320
    let t = label(s, size: size, weight: weight, color: color)
    let h = t.sizeThatFits(NSSize(width: width - 32, height: 200)).height
    t.frame = NSRect(x: 16, y: 3, width: width - 32, height: h)
    let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: h + 6))
    v.addSubview(t)
    let item = NSMenuItem()
    item.view = v
    return item
}

/// Ring icon for the menu bar: share used of the binding limit, coloured by the share left.
func ringImage(used: Double?, stale: Bool) -> NSImage {
    let size = NSSize(width: 16, height: 16)
    let img = NSImage(size: size, flipped: false) { rect in
        let c = NSPoint(x: rect.midX, y: rect.midY), radius: CGFloat = 6.25
        let track = NSBezierPath(); track.appendArc(withCenter: c, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 2.5
        NSColor.tertiaryLabelColor.setStroke(); track.stroke()
        if let u = used, u > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: radius, startAngle: 90, endAngle: 90 - CGFloat(360 * min(100, u) / 100), clockwise: true)
            arc.lineWidth = 2.5
            arc.lineCapStyle = .round
            (stale ? NSColor.secondaryLabelColor : colorFor(left: 100 - u)).setStroke(); arc.stroke()
        }
        return true
    }
    img.isTemplate = false
    return img
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    var settings = loadJSON(Settings.self, "settings.json") ?? Settings()
    var reading: Reading? = loadJSON(Reading.self, "reading.json")
    var history: [String: [Sample]] = loadJSON([String: [Sample]].self, "history.json") ?? [:]
    var alerts: [String: AlertState] = loadJSON([String: AlertState].self, "alerts.json") ?? [:]
    var plan: String?
    var lastError: UsageError?
    var nextAllowed = Date.distantPast
    var backoffMinutes: Double = 0
    var lastRenewal = Date.distantPast
    var timer: Timer?
    var busy = false
    var nativeNotifications = false

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, err in
            DispatchQueue.main.async { self.nativeNotifications = ok }
            log("notifications \(ok ? "allowed" : "not allowed, using osascript instead")\(err.map { ": \($0.localizedDescription)" } ?? "")")
        }
        log("started v\(appVersion)")
        render()
        refresh(force: true)
        scheduleTimer()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh(force: true)
        }
    }

    func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
    }

    func tick() {
        let due = (reading?.fetchedAt ?? .distantPast).addingTimeInterval(settings.refreshMinutes * 60)
        if Date() >= due { refresh(force: false) } else { render() }
    }

    func refresh(force: Bool) {
        if busy { return }
        if !force && Date() < nextAllowed { render(); return }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            let result = self.collect()
            DispatchQueue.main.async {
                self.busy = false
                self.apply(result)
            }
        }
    }

    /// One reading, with Claude Code renewing its own sign-in when it expired (at most every 10 minutes).
    func collect() -> Result<Reading, UsageError> {
        var auth: AuthContext
        switch readAuth() { case .success(let a): auth = a; case .failure(let e): return .failure(e) }
        DispatchQueue.main.async { self.plan = auth.plan }
        func renewAndReread() -> AuthContext? {
            guard Date().timeIntervalSince(lastRenewal) > 600, findClaudeCLI() != nil else { return nil }
            lastRenewal = Date()
            log("sign-in expired or refused; asking Claude Code to renew it")
            runCLIRenewal()
            if case .success(let a) = readAuth(), a.access != auth.access { return a }
            return nil
        }
        if let exp = auth.expiresAt, exp <= Date().addingTimeInterval(30) {
            guard let a = renewAndReread() else { return .failure(.authExpired) }
            auth = a
        }
        let r = fetchUsage(auth: auth)
        if case .failure(let e) = r, case .http(let s, _) = e, s == 401 || s == 403, let a = renewAndReread() {
            return fetchUsage(auth: a)
        }
        return r
    }

    func apply(_ result: Result<Reading, UsageError>) {
        switch result {
        case .success(let r):
            reading = r
            lastError = nil
            backoffMinutes = 0
            nextAllowed = .distantPast
            saveJSON(r, "reading.json")
            record(r)
            checkAlerts(r)
        case .failure(let e):
            lastError = e
            if case .http(let s, let ra) = e, s == 429 || s >= 500 {
                backoffMinutes = min(30, max(2, backoffMinutes * 2))
                nextAllowed = Date().addingTimeInterval(max(ra ?? 0, backoffMinutes * 60))
            } else if e == .network || e == .offline {
                backoffMinutes = min(30, max(2, backoffMinutes * 2))
                nextAllowed = Date().addingTimeInterval(backoffMinutes * 60)
            } else {
                nextAllowed = Date().addingTimeInterval(settings.refreshMinutes * 60)
            }
            log("reading failed: \(e)")
        }
        render()
    }

    /// 15 days of readings per limit; they drive the pace forecast.
    func record(_ r: Reading) {
        let t = r.fetchedAt.timeIntervalSince1970
        for w in [r.weekly, r.session].compactMap({ $0 }) + r.scoped {
            history[w.id] = addSample(history[w.id] ?? [], t: t, window: w)
        }
        saveJSON(history, "history.json")
    }

    func checkAlerts(_ r: Reading) {
        guard settings.alertsOn, let w = r.weekly, let reset = w.resetsAt else { return }
        let key = "weekly"
        var st = alerts[key] ?? AlertState()
        if abs(st.reset - reset.timeIntervalSince1970) > 3600 { st = AlertState(reset: reset.timeIntervalSince1970, fired: []) }
        var send: (String, String)?
        let resetText = "Resets \(formatDayTime(reset)) · in \(formatSpan(hours: reset.timeIntervalSinceNow / 3600))"
        if w.left <= 0 {
            if !st.fired.contains("limit") { st.fired.append("limit"); send = ("Claude: weekly limit reached", resetText) }
        } else {
            for t in settings.alertAt.sorted() where w.left <= t {
                let k = "\(Int(t))"
                if !st.fired.contains(k) { st.fired.append(contentsOf: settings.alertAt.filter { $0 >= t }.map { "\(Int($0))" }); send = ("Claude: \(formatPct(w.used)) of the week used", resetText) }
                break
            }
            if let p = paceSummary(paceInfo(w, samples: history[w.id] ?? [])), p.status == "Too fast", !st.fired.contains("pace") {
                st.fired.append("pace")
                send = send ?? ("Claude: on track to run out before the reset", p.text)
            }
        }
        alerts[key] = st
        saveJSON(alerts, "alerts.json")
        if let (title, body) = send { notify(title, body) }
    }

    func notify(_ title: String, _ body: String) {
        if !nativeNotifications {
            // An ad-hoc signed app may not post through UserNotifications; macOS's own "display notification" can.
            // Title and body go in as argv, never into the script text.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)", "-e", "end run", title, body]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            do { try p.run(); log("alert (osascript): \(title)") } catch { log("alert not shown: \(error.localizedDescription)") }
            return
        }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { err in
            log("alert: \(title)" + (err.map { " (not shown: \($0.localizedDescription))" } ?? ""))
        }
    }

    // MARK: Rendering

    var isStale: Bool {
        guard let r = reading else { return true }
        return lastError != nil || Date().timeIntervalSince(r.fetchedAt) > max(600, settings.refreshMinutes * 60 * 3)
    }

    func render() {
        guard let button = item.button else { return }
        if let r = reading, let b = bindingLimit(r) {
            let tag = b.kind == "session" ? "5h" : "wk"
            var title = " \(formatPct(b.used)) \(tag)"
            if let reset = b.resetsAt, reset > Date() { title += " · \(formatSpan(hours: reset.timeIntervalSinceNow / 3600))" }
            if isStale { title += " ⚠" }
            button.image = ringImage(used: b.used, stale: isStale)
            button.title = title
        } else {
            button.image = ringImage(used: nil, stale: true)
            button.title = lastError?.needsSignIn == true ? " Sign in" : " …"
        }
        button.toolTip = lastError?.message ?? "Claude usage"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let e = lastError { menu.addItem(textItem((e.needsSignIn ? "⚠ " : "⚠ ") + e.message, size: 12, color: .systemOrange)) }
        if let r = reading {
            if let w = r.weekly {
                menu.addItem(textItem("\(formatPct(w.used)) used this week" + (plan.map { " · \($0.capitalized) plan" } ?? ""), size: 15, color: .labelColor, weight: .semibold))
                if let p = paceInfo(w, samples: history[w.id] ?? []), let s = paceSummary(p) {
                    menu.addItem(rowItem(title: "Pace this week", value: s.status, fill: p.used / 100, color: colorFor(s.level),
                                         note: s.text, marker: p.elapsedH / p.windowH))
                }
            }
            menu.addItem(.separator())
            for w in [r.weekly, r.session].compactMap({ $0 }) + r.scoped {
                var note: String?
                if let reset = w.resetsAt, reset > Date() { note = "Resets \(formatDayTime(reset)) · in \(formatSpan(hours: reset.timeIntervalSinceNow / 3600))" }
                menu.addItem(rowItem(title: windowLabel(w), value: "\(formatPct(w.used)) used", fill: w.used / 100, color: colorFor(left: w.left), note: note))
            }
            if let ex = r.extra, ex.enabled == true, let u = ex.utilization {
                menu.addItem(rowItem(title: "Extra usage", value: "\(formatPct(u)) used", fill: u / 100, color: colorFor(left: 100 - u),
                                     note: "\(formatPct(u)) of the monthly limit used"))
            }
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            menu.addItem(textItem("Updated \(f.string(from: r.fetchedAt))" + (isStale ? " · not up to date" : "")))
        } else if lastError == nil {
            menu.addItem(textItem("Reading Claude usage…", size: 12))
        }
        menu.addItem(.separator())
        menu.addItem(action("Refresh now", #selector(refreshNow)))
        menu.addItem(action("Open usage page", #selector(openUsage)))
        if lastError?.needsSignIn == true {
            menu.addItem(action(findClaudeCLI() == nil ? "Install Claude Code…" : "Sign in again…", #selector(signIn)))
        }
        let every = NSMenuItem(title: "Refresh every", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for m in [1.0, 2, 5, 10] {
            let i = action("\(Int(m)) min", #selector(setRefresh(_:)))
            i.tag = Int(m); i.state = settings.refreshMinutes == m ? .on : .off
            sub.addItem(i)
        }
        every.submenu = sub
        menu.addItem(every)
        let al = action("Alerts at 75% and 90% used", #selector(toggleAlerts)); al.state = settings.alertsOn ? .on : .off
        menu.addItem(al)
        let login = action("Start at login", #selector(toggleLogin)); login.state = FileManager.default.fileExists(atPath: launchAgentURL.path) ? .on : .off
        menu.addItem(login)
        menu.addItem(action("Open data folder", #selector(openData)))
        menu.addItem(.separator())
        menu.addItem(textItem("Claude usage widget \(appVersion) for macOS"))
        menu.addItem(action("Quit", #selector(quit)))
    }

    func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")   // no keyboard shortcuts, by design
        i.target = self
        return i
    }

    @objc func refreshNow() { refresh(force: true) }
    @objc func openUsage() { NSWorkspace.shared.open(usagePageURL) }
    @objc func openData() { NSWorkspace.shared.open(dataDir) }
    @objc func setRefresh(_ s: NSMenuItem) { settings.refreshMinutes = Double(s.tag); saveJSON(settings, "settings.json"); tick() }
    @objc func toggleAlerts() { settings.alertsOn.toggle(); saveJSON(settings, "settings.json") }
    @objc func toggleLogin() {
        if FileManager.default.fileExists(atPath: launchAgentURL.path) { try? FileManager.default.removeItem(at: launchAgentURL) } else { writeLaunchAgent() }
    }
    @objc func signIn() {
        // Claude Code's own sign-in renews the Keychain item; the widget never signs in itself. A .command file
        // opens in Terminal without Apple Events permission. With no CLI installed, the install page opens instead.
        guard let cli = findClaudeCLI() else {
            log("sign in: Claude Code CLI not found; opening the install page")
            NSWorkspace.shared.open(URL(string: "https://docs.anthropic.com/en/docs/claude-code/setup")!)
            return
        }
        let f = dataDir.appendingPathComponent("sign-in.command")
        let quoted = "'" + cli.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "#!/bin/bash\necho 'Sign in to Claude Code with your Claude account (type /login if it does not ask), then close this window.'\n\(quoted)\n"
        do {
            try script.write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.path)
            let ok = NSWorkspace.shared.open(f)
            log("sign in: opened Terminal with Claude Code (\(ok ? "ok" : "failed"))")
        } catch {
            log("sign in: could not write sign-in.command: \(error.localizedDescription)")
        }
        lastRenewal = .distantPast
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.refresh(force: true) }
    }
    @objc func quit() { log("quit"); exit(0) }
}
