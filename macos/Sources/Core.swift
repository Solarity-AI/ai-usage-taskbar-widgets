// Claude usage menu-bar widget for macOS: reading, parsing and pace model (no AppKit here).
// Ported from claude-usage-widget/claude-usage.ps1 (collector) and the pace code in claude-usage-widget.ps1.

import CryptoKit
import Foundation

let appVersion = "1.5.2"
let weekSeconds: Double = 604_800
let sessionSeconds: Double = 18_000
let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
let usagePageURL = URL(string: "https://claude.ai/settings/usage")!

// MARK: - Model

struct LimitWindow: Codable, Equatable {
    var id: String          // API key: seven_day, five_hour, seven_day_opus, ...
    var name: String        // row title
    var kind: String        // weekly | session | other
    var used: Double        // percent used
    var windowSeconds: Double
    var resetsAt: Date?
    var left: Double { min(100, max(0, 100 - used)) }
}

struct ExtraUsage: Codable, Equatable {
    var enabled: Bool?
    var utilization: Double?
    var usedCredits: Double?
    var monthlyLimit: Double?
}

struct Reading: Codable {
    var weekly: LimitWindow?
    var session: LimitWindow?
    var scoped: [LimitWindow] = []
    var extra: ExtraUsage?
    var fetchedAt: Date
}

enum UsageError: Error, Equatable {
    case authMissing(String)
    case authExpired
    case http(Int, retryAfter: Double?)
    case redirect(Int)
    case badResponse
    case network
    case offline

    var message: String {
        switch self {
        case .authMissing(let why): return "Sign-in needed: \(why)"
        case .authExpired: return "Sign-in needed: the Claude Code sign-in on this Mac expired. Run \"claude\" in Terminal to renew it."
        case .http(let s, _) where s == 401 || s == 403: return "Sign-in needed: Claude refused the sign-in (HTTP \(s)). Run \"claude\" in Terminal and sign in."
        case .http(429, _): return "Not up to date: the usage service is rate limiting (HTTP 429). It retries by itself."
        case .http(let s, _): return "Not up to date: the usage service returned HTTP \(s)."
        case .redirect(let s): return "The usage service redirected the request (HTTP \(s)); not followed."
        case .badResponse: return "The usage service returned an unexpected response."
        case .network: return "Could not reach the Claude usage service (network, TLS or timeout)."
        case .offline: return "Offline: could not reach the Claude usage service."
        }
    }
    var needsSignIn: Bool {
        switch self {
        case .authMissing, .authExpired: return true
        case .http(let s, _): return s == 401 || s == 403
        default: return false
        }
    }
}

// MARK: - Dates and numbers

func parseNumber(_ v: Any?) -> Double? {
    if v is Bool { return nil }
    if let n = v as? NSNumber {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }
    if let s = v as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite { return d }
    return nil
}

/// The date, or nil after 9999-12-31T23:59:59Z: later dates can't be formatted or encoded as ISO 8601.
func bounded(_ d: Date) -> Date? { d.timeIntervalSince1970 < 253_402_300_800 ? d : nil }

/// ISO 8601 with any number of fraction digits and any offset, or Unix seconds / milliseconds.
/// Dates after the year 9999 count as missing.
func parseDate(_ v: Any?) -> Date? {
    if let n = parseNumber(v) {
        if n <= 0 { return nil }
        return bounded(Date(timeIntervalSince1970: n > 100_000_000_000 ? n / 1000 : n))
    }
    guard var s = (v as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
    var fraction = 0.0
    if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
        fraction = Double("0" + s[r]) ?? 0
        s.removeSubrange(r)
    }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    if let d = f.date(from: s) { return bounded(d.addingTimeInterval(fraction)) }
    if !s.contains("Z") && !s.contains("+") && s.filter({ $0 == "-" }).count == 2, let d = f.date(from: s + "Z") {
        return bounded(d.addingTimeInterval(fraction))   // no offset: assume UTC, as the collector does
    }
    return nil
}

// MARK: - Parsing (ConvertFrom-LiveUsage)

let scopedNames = ["seven_day_opus": "Opus", "seven_day_sonnet": "Sonnet",
                   "seven_day_oauth_apps": "OAuth apps", "seven_day_claude_code": "Claude Code"]

func keyWindowSeconds(_ key: String) -> Double? {
    if key.hasPrefix("seven_day") { return weekSeconds }
    if key.hasPrefix("five_hour") { return sessionSeconds }
    return nil
}

func scopedName(_ key: String) -> String {
    if let n = scopedNames[key] { return n }
    var t = key.replacingOccurrences(of: #"^(seven_day|five_hour)_?"#, with: "", options: .regularExpression)
    if t.isEmpty { t = key }
    return t.replacingOccurrences(of: "_", with: " ").capitalized
}

func windowKind(_ secs: Double) -> String {
    secs == weekSeconds ? "weekly" : (secs == sessionSeconds ? "session" : "other")
}

/// Parses the usage response body. nil when it is not the expected shape (the collector's "bad_response").
func parseUsage(_ data: Data, now: Date = Date()) -> Reading? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    guard obj.keys.contains("seven_day") || obj.keys.contains("five_hour") else { return nil }
    var r = Reading(fetchedAt: now)
    for key in obj.keys.sorted() {
        guard let v = obj[key] as? [String: Any], v.keys.contains("utilization"), key != "extra_usage" else { continue }
        guard let secs = keyWindowSeconds(key), let used = parseNumber(v["utilization"]) else { continue }
        let isMain = key == "seven_day" || key == "five_hour"
        let w = LimitWindow(id: key, name: isMain ? "" : scopedName(key), kind: windowKind(secs),
                            used: used, windowSeconds: secs, resetsAt: parseDate(v["resets_at"]))
        if key == "seven_day" { r.weekly = w } else if key == "five_hour" { r.session = w } else { r.scoped.append(w) }
    }
    if let ex = obj["extra_usage"] as? [String: Any] {
        r.extra = ExtraUsage(enabled: ex["is_enabled"] as? Bool, utilization: parseNumber(ex["utilization"]),
                             usedCredits: parseNumber(ex["used_credits"]), monthlyLimit: parseNumber(ex["monthly_limit"]))
    }
    return r
}

/// The limit that runs out first: the 5-hour session when less of it is left (and it hasn't reset), else weekly.
func bindingLimit(_ r: Reading, now: Date = Date()) -> LimitWindow? {
    if let s = r.session, let reset = s.resetsAt, reset > now {
        if r.weekly == nil || s.left < r.weekly!.left { return s }
    }
    return r.weekly
}

func windowLabel(_ w: LimitWindow) -> String {
    if !w.name.isEmpty {
        switch w.kind { case "weekly": return "Weekly · \(w.name)"; case "session": return "Session · \(w.name)"; default: return w.name }
    }
    return w.kind == "session" ? "Current session · 5 hours" : "Weekly · all models"
}

// MARK: - Sign-in (Read-AuthContext)

struct AuthContext { var access: String; var plan: String?; var expiresAt: Date? }

func claudeHome() -> URL {
    if let c = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !c.trimmingCharacters(in: .whitespaces).isEmpty {
        return URL(fileURLWithPath: (c as NSString).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
}

/// Keychain service names Claude Code may use on macOS. With CLAUDE_CONFIG_DIR set, Claude Code adds a short
/// hash of the folder to the name; both forms are tried.
func keychainServices() -> [String] {
    var names = ["Claude Code-credentials"]
    if let c = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !c.isEmpty {
        names.insert("Claude Code-credentials-" + String(sha256Hex(claudeHome().path).prefix(8)), at: 0)
    }
    return names
}

func sha256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Reads one Keychain item's secret through /usr/bin/security. The secret comes back on stdout, never in argv,
/// and macOS asks once whether "security" may read it ("Always Allow" survives rebuilds of this app).
func readKeychain(service: String) -> Data? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", service, "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return data
}

func authFromJSON(_ data: Data) -> AuthContext? {
    guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let o = j["claudeAiOauth"] as? [String: Any],
          let access = o["accessToken"] as? String, access.count >= 8 else { return nil }
    return AuthContext(access: access, plan: o["subscriptionType"] as? String, expiresAt: parseDate(o["expiresAt"]))
}

/// The Claude Code sign-in: Keychain first (where Claude Code keeps it on macOS), then .credentials.json.
func readAuth(credentialsFile: URL? = nil) -> Result<AuthContext, UsageError> {
    if let f = credentialsFile {
        guard let d = try? Data(contentsOf: f), let a = authFromJSON(d) else { return .failure(.authMissing("test credentials unreadable.")) }
        return .success(a)
    }
    for s in keychainServices() {
        if let d = readKeychain(service: s), let a = authFromJSON(d) { return .success(a) }
    }
    let file = claudeHome().appendingPathComponent(".credentials.json")
    if let d = try? Data(contentsOf: file), let a = authFromJSON(d) { return .success(a) }
    return .failure(.authMissing("Claude Code is not signed in on this Mac. Install Claude Code, run \"claude\" in Terminal and sign in with your Claude account."))
}

// MARK: - Request (Invoke-UsageRequest)

final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

func retryAfterSeconds(_ v: String?) -> Double? {
    guard let v = v?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
    if let n = Double(v) { return max(0, n) }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    if let d = f.date(from: v) { return max(0, d.timeIntervalSinceNow) }
    return nil
}

/// One usage reading. Retries 5xx and network errors briefly (0, 1.5 s, 4 s); 4xx stops at once.
func fetchUsage(auth: AuthContext, url: URL = usageURL) -> Result<Reading, UsageError> {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 12
    cfg.urlCache = nil
    let session = URLSession(configuration: cfg, delegate: NoRedirect(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    var last: UsageError = .network
    for (i, delay) in [0.0, 1.5, 4.0].enumerated() {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("claude-usage-widget/\(appVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        req.setValue("Bearer " + auth.access, forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let sem = DispatchSemaphore(value: 0)
        var body: Data?, resp: HTTPURLResponse?, err: Error?
        session.dataTask(with: req) { d, r, e in body = d; resp = r as? HTTPURLResponse; err = e; sem.signal() }.resume()
        sem.wait()
        if let e = err as? URLError {
            if [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(e.code) { return .failure(.offline) }
            last = .network
            continue
        }
        guard let r = resp else { last = .network; continue }
        let status = r.statusCode
        if (200..<300).contains(status) {
            guard let d = body, let reading = parseUsage(d) else { return .failure(.badResponse) }
            return .success(reading)
        }
        if (300..<400).contains(status) { return .failure(.redirect(status)) }
        last = .http(status, retryAfter: retryAfterSeconds(r.value(forHTTPHeaderField: "Retry-After")))
        if status < 500 || i == 2 { return .failure(last) }
    }
    return .failure(last)
}

// MARK: - Claude Code CLI (renewal only)

func findClaudeCLI() -> URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                      "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
}

/// Lets Claude Code renew ITS OWN sign-in by running its local /usage command (no AI request). Output discarded.
@discardableResult
func runCLIRenewal(timeout: TimeInterval = 40) -> Bool {
    guard let cli = findClaudeCLI() else { return false }
    let p = Process()
    p.executableURL = cli
    p.arguments = ["-p", "/usage"]
    var env = ProcessInfo.processInfo.environment
    for k in env.keys where k.hasPrefix("ANTHROPIC_") || k == "CLAUDECODE" || k.hasPrefix("CLAUDE_CODE_") { env.removeValue(forKey: k) }
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    p.environment = env
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
    if p.isRunning { p.terminate(); return false }
    return p.terminationStatus == 0
}

// MARK: - History and pace (Get-PaceInfo / Get-PaceSummary)

struct Sample: Codable { var t: Double; var u: Double; var r: Double }   // Unix s, % used, reset Unix s

struct Pace {
    var used, left, windowH, remainingH, elapsedH: Double
    var reset: Date
    var rate: Double?
    var speedPct: Double?
    var limited: Bool
    var runsOut = false
    var runOutAt: Date?
    var leftAtReset: Double?
}

func paceInfo(_ w: LimitWindow?, samples: [Sample], now: Date = Date()) -> Pace? {
    guard let w = w, let reset = w.resetsAt, w.windowSeconds > 0 else { return nil }
    let left = w.left, used = 100 - left
    let remS = reset.timeIntervalSince(now)
    if remS <= 0 { return nil }
    let winH = w.windowSeconds / 3600, remH = min(winH, remS / 3600), elH = winH - remH
    let evenRate = 100 / winH
    let avgRate: Double? = elH >= 0.25 ? used / elH : nil
    let long = winH > 24
    let (minSpan, maxSpan) = long ? (2.0, 6.0) : (0.5, 2.0)
    let nowU = now.timeIntervalSince1970, resetU = reset.timeIntervalSince1970
    var best: Sample?
    for s in samples where abs(s.r - resetU) <= 3600 {
        let age = (nowU - s.t) / 3600
        if age < minSpan || age > maxSpan { continue }
        if best == nil || s.t < best!.t { best = s }
    }
    var recentRate: Double?
    if let b = best { recentRate = max(0, used - b.u) / ((nowU - b.t) / 3600) }
    let rate = recentRate ?? avgRate
    var speed: Double?
    if let r = rate, elH >= min(1.0, winH * 0.05) { speed = (r / evenRate - 1) * 100 }
    var p = Pace(used: used, left: left, windowH: winH, remainingH: remH, elapsedH: elH, reset: reset,
                 rate: rate, speedPct: speed, limited: left <= 0)
    if left > 0, let r = rate {
        if r > 0.0001 && left / r < remH {
            p.runsOut = true
            p.runOutAt = now.addingTimeInterval(left / r * 3600)
        } else {
            p.leftAtReset = max(0, left - r * remH)
        }
    }
    return p
}

/// One reading per window at most every 5 minutes (and at every reset); older than 15 days dropped.
/// Same rule as Add-WindowSample in claude-usage-widget.ps1.
func addSample(_ list: [Sample], t: Double, window w: LimitWindow) -> [Sample] {
    guard let reset = w.resetsAt?.timeIntervalSince1970 else { return list }
    if let last = list.last {
        if t <= last.t { return list }
        if abs(last.r - reset) <= 3600 && t - last.t < 300 { return list }
    }
    return (list + [Sample(t: t, u: 100 - w.left, r: reset)]).filter { t - $0.t <= 15 * 86400 }
}

enum PaceLevel { case green, amber, red, gray }
struct PaceSummary { var status: String; var level: PaceLevel; var text: String }

/// Row title for a pace summary: "Pace this week" or "Pace this 5-hour session".
func paceTitle(_ p: Pace) -> String { p.windowH > 24 ? "Pace this week" : "Pace this \(Int(p.windowH.rounded()))-hour session" }

/// A share or span the app can show and act on: finite and of a plausible size. Int() would trap on anything else.
func plausible(_ v: Double) -> Bool { v.isFinite && abs(v) < 1e9 }

/// "45m", "2h 5m", "2d 3h". A span that isn't plausible shows as "—".
func formatSpan(hours h: Double) -> String {
    guard plausible(h) else { return "—" }
    let mins = Int((h * 60).rounded())
    if mins < 60 { return "\(max(0, mins))m" }
    let hrs = mins / 60
    if hrs < 24 { return mins % 60 == 0 ? "\(hrs)h" : "\(hrs)h \(mins % 60)m" }
    return hrs % 24 == 0 ? "\(hrs / 24)d" : "\(hrs / 24)d \(hrs % 24)h"
}

func formatDayTime(_ d: Date, now: Date = Date()) -> String {
    let cal = Calendar.current
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm"
    let t = f.string(from: d)
    if cal.isDate(d, inSameDayAs: now) { return "today \(t)" }
    if let tm = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: tm) { return "tomorrow \(t)" }
    f.dateFormat = d.timeIntervalSince(now) < 6 * 86400 ? "EEE HH:mm" : "EEE d MMM, HH:mm"
    return f.string(from: d)
}

/// "61%", or "105%" over the limit. A share that isn't plausible shows as "—".
func formatPct(_ v: Double) -> String {
    guard plausible(v) else { return "—" }
    return "\(Int(v.rounded()))%"
}

func paceSummary(_ p: Pace?, now: Date = Date()) -> PaceSummary? {
    guard let p = p else { return nil }
    let gone = formatPct(100 * p.elapsedH / p.windowH)
    let period = p.windowH > 24 ? "the week" : "the session"
    let plain = "\(formatPct(p.used)) used · \(gone) of \(period) gone"
    if p.limited { return PaceSummary(status: "Limit reached", level: .red, text: "Resets \(formatDayTime(p.reset, now: now)) · in \(formatSpan(hours: p.remainingH))") }
    if p.speedPct == nil { return PaceSummary(status: "Too early to tell", level: .gray, text: plain) }
    if p.runsOut, let at = p.runOutAt {
        return PaceSummary(status: "Too fast", level: .red, text: "At this rate it runs out \(formatDayTime(at, now: now)) · \(plain)")
    }
    var s = PaceSummary(status: "On pace", level: .green, text: plain)
    if let l = p.leftAtReset, l < 5 { s.status = "Cutting close"; s.level = .amber }
    if let r = p.rate, r > 0.0001 {
        s.text = "At this rate it runs out \(formatDayTime(now.addingTimeInterval(p.left / r * 3600), now: now)), after the reset · \(plain)"
    } else {
        s.text = "No use lately, so it lasts until the reset · \(plain)"
    }
    return s
}

// MARK: - Alerts (Check-Alerts)

/// The weekly alerts already shown, and the reset they belong to (alerts.json).
struct AlertState: Codable { var reset: Double = 0; var fired: [String] = [] }

/// Which weekly alert to show for this reading, if any, and the alert state to keep. nil without a reset time, and
/// for a share the menu shows as "—": an alert about a number nobody can see would only confuse.
/// Thresholds are shares left (25 and 10 = 75% and 90% used); one that isn't above 0 and up to 100 is ignored.
/// A threshold, the limit and a too-fast pace each alert once per week; a reset more than an hour away starts a new week.
func weeklyAlert(_ w: LimitWindow, thresholds: [Double], state: AlertState, samples: [Sample],
                 now: Date = Date()) -> (state: AlertState, alert: (title: String, body: String)?)? {
    guard let reset = w.resetsAt, plausible(w.used) else { return nil }
    var st = state
    if abs(st.reset - reset.timeIntervalSince1970) > 3600 { st = AlertState(reset: reset.timeIntervalSince1970, fired: []) }
    let marks = thresholds.filter { $0.isFinite && $0 > 0 && $0 <= 100 }
    var send: (title: String, body: String)?
    let resetText = "Resets \(formatDayTime(reset, now: now)) · in \(formatSpan(hours: reset.timeIntervalSince(now) / 3600))"
    if w.left <= 0 {
        if !st.fired.contains("limit") { st.fired.append("limit"); send = ("Claude: weekly limit reached", resetText) }
    } else {
        for t in marks.sorted() where w.left <= t {
            let k = "\(Int(t))"
            if !st.fired.contains(k) { st.fired.append(contentsOf: marks.filter { $0 >= t }.map { "\(Int($0))" }); send = ("Claude: \(formatPct(w.used)) of the week used", resetText) }
            break
        }
        if let p = paceSummary(paceInfo(w, samples: samples, now: now), now: now), p.status == "Too fast", !st.fired.contains("pace") {
            st.fired.append("pace")
            send = send ?? ("Claude: on track to run out before the reset", p.text)
        }
    }
    return (st, send)
}

// MARK: - Local files

let dataDir: URL = {
    let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClaudeUsageWidget")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}()

func loadJSON<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
    guard let d = try? Data(contentsOf: dataDir.appendingPathComponent(name)) else { return nil }
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
    return try? dec.decode(T.self, from: d)
}

func saveJSON<T: Encodable>(_ value: T, _ name: String) {
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
    guard let d = try? enc.encode(value) else { return }
    try? d.write(to: dataDir.appendingPathComponent(name), options: .atomic)
}

func log(_ line: String) {
    let f = dataDir.appendingPathComponent("widget.log")
    let stamp = ISO8601DateFormatter().string(from: Date())
    let text = "\(stamp) \(line)\n"
    if let h = try? FileHandle(forWritingTo: f) {
        h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); try? h.close()
        if let size = try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int, size > 512_000 {
            try? FileManager.default.removeItem(at: f)
        }
    } else {
        try? text.write(to: f, atomically: true, encoding: .utf8)
    }
}
