// Entry point. With no arguments it runs the menu-bar app. Test modes:
//   --self-test                         parsing and pace checks, no network, no sign-in
//   --parse <file>                      parse a saved usage response and print the reading
//   --once [--url <http://127.0.0.1:…>] [--credentials-file <file>]
//                                       one live reading, printed as JSON (the token is never printed)

import AppKit

func printJSON<T: Encodable>(_ v: T) {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    e.dateEncodingStrategy = .iso8601
    print(String(data: try! e.encode(v), encoding: .utf8)!)
}

func argValue(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

func selfTest() -> Int32 {
    var failed = 0, passed = 0
    func check(_ name: String, _ ok: Bool) {
        if ok { passed += 1; print("✅ \(name)") } else { failed += 1; print("❌ \(name)") }
    }
    let now = parseDate("2026-11-17T12:00:00Z")!
    let body = """
    {"five_hour":{"utilization":22.5,"resets_at":"2026-11-17T13:59:59.912345+00:00"},
     "seven_day":{"utilization":61,"resets_at":"2026-11-19T02:59:41.5+00:00"},
     "seven_day_oauth_apps":null,
     "seven_day_opus":{"utilization":80,"resets_at":"2026-11-19T02:59:41+00:00"},
     "seven_day_sonnet":{"utilization":null,"resets_at":null},
     "seven_day_new_model":{"utilization":"5","resets_at":1795143581},
     "extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1250,"utilization":25.0}}
    """
    let r = parseUsage(body.data(using: .utf8)!, now: now)
    check("parses the full response", r != nil)
    check("seven_day -> weekly, 39% left", r?.weekly?.left == 39 && r?.weekly?.windowSeconds == weekSeconds)
    check("five_hour -> session, 77.5% left", r?.session?.left == 77.5 && r?.session?.kind == "session")
    check("6-digit fraction and offset in resets_at", r?.session?.resetsAt.map { abs($0.timeIntervalSince1970 - 1_794_923_999.912345) < 0.001 } == true)
    check("Opus kept as a scoped weekly limit", r?.scoped.contains { $0.name == "Opus" && $0.left == 20 } == true)
    check("null utilization (Sonnet) and null slot skipped", r?.scoped.contains { $0.id == "seven_day_sonnet" || $0.id == "seven_day_oauth_apps" } == false)
    check("unknown seven_day_* key kept with its own name", r?.scoped.contains { $0.name == "New Model" && $0.used == 5 } == true)
    check("Unix-seconds reset parsed", r?.scoped.first { $0.id == "seven_day_new_model" }?.resetsAt?.timeIntervalSince1970 == 1_795_143_581)
    check("extra usage read", r?.extra?.enabled == true && r?.extra?.utilization == 25)
    check("unexpected shape rejected", parseUsage(#"{"error":"x"}"#.data(using: .utf8)!) == nil)
    check("non-JSON rejected", parseUsage("<html>".data(using: .utf8)!) == nil)
    check("milliseconds date", parseDate(4_102_444_800_000)?.timeIntervalSince1970 == 4_102_444_800)
    check("boolean is not a number", parseNumber(true) == nil)

    // Binding limit: session when less of it is left and it has not reset.
    var b = Reading(fetchedAt: now)
    b.weekly = LimitWindow(id: "seven_day", name: "", kind: "weekly", used: 40, windowSeconds: weekSeconds, resetsAt: now.addingTimeInterval(86400))
    b.session = LimitWindow(id: "five_hour", name: "", kind: "session", used: 90, windowSeconds: sessionSeconds, resetsAt: now.addingTimeInterval(3600))
    check("binding limit is the 5-hour session when it has less left", bindingLimit(b, now: now)?.kind == "session")
    b.session?.resetsAt = now.addingTimeInterval(-60)
    check("binding limit is weekly once the session has reset", bindingLimit(b, now: now)?.kind == "weekly")

    // Pace: 3.5 days gone of the week.
    let reset = now.addingTimeInterval(3.5 * 86400)
    var w = LimitWindow(id: "seven_day", name: "", kind: "weekly", used: 50, windowSeconds: weekSeconds, resetsAt: reset)
    w.used = 40
    let even = paceSummary(paceInfo(w, samples: [], now: now), now: now)
    check("slower than even use is On pace (\(even?.status ?? "nil"))", even?.status == "On pace")
    w.used = 90
    let fast = paceSummary(paceInfo(w, samples: [], now: now), now: now)
    check("90% used half way is Too fast (\(fast?.status ?? "nil"))", fast?.status == "Too fast")
    w.used = 30
    let recent = [Sample(t: now.timeIntervalSince1970 - 3 * 3600, u: 15, r: reset.timeIntervalSince1970)]
    let burst = paceInfo(w, samples: recent, now: now)
    check("recent 2–6 h rate wins over the average (5%/h)", burst.map { abs(($0.rate ?? 0) - 5) < 0.001 } == true && burst?.runsOut == true)
    w.used = 100
    check("100% used is Limit reached", paceSummary(paceInfo(w, samples: [], now: now), now: now)?.status == "Limit reached")
    w.resetsAt = now.addingTimeInterval(weekSeconds - 600)
    w.used = 1
    check("first hour of the week is Too early to tell", paceSummary(paceInfo(w, samples: [], now: now), now: now)?.status == "Too early to tell")

    // History: 3 h of 2-minute readings keep one sample per 5 minutes, enough for a recent rate.
    var hist: [Sample] = []
    var hw = LimitWindow(id: "seven_day", name: "", kind: "weekly", used: 20, windowSeconds: weekSeconds, resetsAt: reset)
    for i in 0...90 {
        hw.used = 20 + Double(i) * 0.1
        hist = addSample(hist, t: now.timeIntervalSince1970 - Double(90 - i) * 120, window: hw)
    }
    check("2-minute readings thinned to 5-minute samples (\(hist.count))", hist.count >= 30 && hist.count <= 40)
    check("history gives a recent rate", paceInfo(hw, samples: hist, now: now).map { $0.rate != nil && abs($0.rate! - 3) < 0.5 } == true)
    check("older readings never added", addSample(hist, t: now.timeIntervalSince1970 - 99999, window: hw).count == hist.count)

    check("span 2d 3h", formatSpan(hours: 51) == "2d 3h")
    check("span 45m", formatSpan(hours: 0.75) == "45m")
    check("Retry-After seconds", retryAfterSeconds("120") == 120)
    check("keychain service default name", keychainServices().last == "Claude Code-credentials")
    check("sha256", sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

    print("\n\(passed) passed, \(failed) failed")
    return failed == 0 ? 0 : 1
}

func once() -> Int32 {
    var url = usageURL
    if let u = argValue("--url") {
        // Test override: only a local mock may receive a token other than the real usage endpoint.
        guard let parsed = URL(string: u), parsed.scheme == "http", parsed.host == "127.0.0.1" else {
            FileHandle.standardError.write("--url must be http://127.0.0.1:<port>/…\n".data(using: .utf8)!)
            return 2
        }
        url = parsed
    }
    let credFile = argValue("--credentials-file").map { URL(fileURLWithPath: $0) }
    let auth: AuthContext
    switch readAuth(credentialsFile: credFile) {
    case .success(let a): auth = a
    case .failure(let e): print("{\"ok\":false,\"error\":\(String(reflecting: e.message))}"); return 1
    }
    switch fetchUsage(auth: auth, url: url) {
    case .success(let r): printJSON(r); return 0
    case .failure(let e): print("{\"ok\":false,\"error\":\(String(reflecting: e.message))}"); return 1
    }
}

let args = CommandLine.arguments
if args.contains("--self-test") { exit(selfTest()) }
if let f = argValue("--parse") {
    guard let d = FileManager.default.contents(atPath: f), let r = parseUsage(d) else { print("unexpected response"); exit(1) }
    printJSON(r); exit(0)
}
if args.contains("--once") { exit(once()) }
if let png = argValue("--render-preview"), let f = argValue("--from") {
    // Draws the menu's rows for a saved usage response into a PNG (layout check, no menu bar needed).
    guard let d = FileManager.default.contents(atPath: f), let r = parseUsage(d) else { print("unexpected response"); exit(1) }
    _ = NSApplication.shared
    let del = AppDelegate()
    del.reading = r; del.plan = "max"; del.history = [:]
    let menu = NSMenu()
    del.menuNeedsUpdate(menu)
    var views: [NSView] = []
    for i in menu.items {
        if let v = i.view { views.append(v) }
        else if i.isSeparatorItem { views.append(NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 9))) }
        else { let t = label("   " + i.title + (i.submenu != nil ? "  ▸" : "") + (i.state == .on ? "  ✓" : "")); t.frame = NSRect(x: 0, y: 2, width: 320, height: 18)
               let v = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 22)); v.addSubview(t); views.append(v) }
    }
    let h = views.reduce(0) { $0 + $1.frame.height }
    // Each row is drawn on its own (as NSMenu hosts it), then stacked into one image.
    let scale: CGFloat = 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(320 * scale), pixelsHigh: Int(h * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 320, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: 320, height: h).fill()
        var y = h
        for v in views {
            y -= v.frame.height
            v.appearance = NSAppearance(named: .aqua)
            let r = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: r)
            r.draw(in: NSRect(x: 0, y: y, width: 320, height: v.frame.height))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: png))
    print("wrote \(png) (\(Int(h)) pt tall)")
    exit(0)
}
if args.contains("--version") { print(appVersion); exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
