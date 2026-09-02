import Cocoa

// ─────────────────────────────── Modèle ───────────────────────────────

struct Metric {
    var pct: Double
    var resetsAt: Date?
    var label: String
}

struct Usage {
    var session: Metric?
    var weekly: Metric?
    var scoped: Metric?
}

// ─────────────────────────────── Réseau ───────────────────────────────

/// Issue d'un appel à /api/oauth/usage. Distinguer les cas est ce qui permet
/// d'afficher « bridé » plutôt que « hors ligne » et de temporiser au bon moment.
enum UsageFetch {
    case ok(Usage)
    case rateLimited(retryAfter: TimeInterval?)
    case failed(code: Int)      // code HTTP, ou 0 si l'appel n'a pas abouti
    case noToken
}

/// Trace horodatée sur stderr → /tmp/claude-usage-widget.err.log (cf. le LaunchAgent).
/// Ne jamais y écrire le token.
func journal(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(ts)] \(msg)\n".utf8))
}

final class UsageFetcher {

    private static func parseDate(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }

    /// Token OAuth relu dans le Keychain à chaque appel (Claude Code le garde rafraîchi).
    /// La valeur n'est jamais loggée ni affichée.
    private func token() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let tok = oauth["accessToken"] as? String, !tok.isEmpty
        else { return nil }
        return tok
    }

    private func request(_ path: String, token: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.anthropic.com" + path)!)
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        r.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        r.timeoutInterval = 20
        return r
    }

    func fetchUsage(_ completion: @escaping (UsageFetch) -> Void) {
        guard let tok = token() else {
            journal("usage: token introuvable dans le Keychain")
            completion(.noToken); return
        }
        URLSession.shared.dataTask(with: request("/api/oauth/usage", token: tok)) { data, resp, err in
            let done: (UsageFetch) -> Void = { r in DispatchQueue.main.async { completion(r) } }

            guard let http = resp as? HTTPURLResponse else {
                journal("usage: échec réseau — \(err?.localizedDescription ?? "inconnu")")
                done(.failed(code: 0)); return
            }
            if http.statusCode == 429 {
                // Retry-After est en secondes, ou absent : l'appelant applique alors son backoff.
                let ra = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
                journal("usage: HTTP 429 bridé — Retry-After=\(ra.map { String(Int($0)) + "s" } ?? "absent")")
                done(.rateLimited(retryAfter: ra)); return
            }
            guard http.statusCode == 200, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                journal("usage: HTTP \(http.statusCode) inexploitable")
                done(.failed(code: http.statusCode)); return
            }
            done(.ok(Self.parse(json)))
        }.resume()
    }

    func fetchPlan(_ completion: @escaping (String?) -> Void) {
        guard let tok = token() else { completion(nil); return }
        URLSession.shared.dataTask(with: request("/api/oauth/profile", token: tok)) { data, resp, _ in
            var plan: String? = nil
            if let data = data,
               let http = resp as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let org = json["organization"] as? [String: Any],
               let tier = org["rate_limit_tier"] as? String {
                plan = Self.prettyPlan(tier)
            }
            DispatchQueue.main.async { completion(plan) }
        }.resume()
    }

    private static func prettyPlan(_ tier: String) -> String {
        var t = tier
        for p in ["default_claude_", "claude_", "default_"] where t.hasPrefix(p) {
            t = String(t.dropFirst(p.count)); break
        }
        let words = t.split(separator: "_").map { w -> String in
            let s = String(w)
            if s.first?.isNumber == true { return s.replacingOccurrences(of: "x", with: "×") }
            return s.prefix(1).uppercased() + s.dropFirst()
        }
        return words.joined(separator: " ")
    }

    private static func parse(_ json: [String: Any]) -> Usage {
        var u = Usage()

        // Forme moderne : tableau `limits`.
        if let limits = json["limits"] as? [[String: Any]] {
            for l in limits {
                let kind = l["kind"] as? String ?? ""
                let pct = (l["percent"] as? NSNumber)?.doubleValue ?? 0
                let reset = parseDate(l["resets_at"] as? String)
                switch kind {
                case "session":
                    u.session = Metric(pct: pct, resetsAt: reset, label: "Session")
                case "weekly_all":
                    u.weekly = Metric(pct: pct, resetsAt: reset, label: "Semaine")
                case "weekly_scoped":
                    var name = "Modèle"
                    if let scope = l["scope"] as? [String: Any],
                       let m = scope["model"] as? [String: Any],
                       let dn = m["display_name"] as? String { name = dn }
                    let cand = Metric(pct: pct, resetsAt: reset, label: name)
                    if u.scoped == nil || pct > u.scoped!.pct { u.scoped = cand }
                default: break
                }
            }
        }

        // Repli sur l'ancienne forme.
        func legacy(_ key: String, _ label: String) -> Metric? {
            guard let d = json[key] as? [String: Any],
                  let util = (d["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return Metric(pct: util, resetsAt: parseDate(d["resets_at"] as? String), label: label)
        }
        if u.session == nil { u.session = legacy("five_hour", "Session") }
        if u.weekly == nil { u.weekly = legacy("seven_day", "Semaine") }

        return u
    }
}

// ─────────────────────────────── Rendu ───────────────────────────────

enum Palette {
    static let bg      = NSColor(srgbRed: 0.086, green: 0.086, blue: 0.098, alpha: 0.94)
    static let stroke  = NSColor(white: 1.0, alpha: 0.14)
    static let track   = NSColor(white: 1.0, alpha: 0.13)
    static let text    = NSColor(white: 0.96, alpha: 1.0)
    static let dim     = NSColor(white: 1.0, alpha: 0.46)
    static let faint   = NSColor(white: 1.0, alpha: 0.30)
    static let ok      = NSColor(srgbRed: 0.42, green: 0.82, blue: 0.55, alpha: 1)
    static let warn    = NSColor(srgbRed: 0.97, green: 0.70, blue: 0.31, alpha: 1)
    static let crit    = NSColor(srgbRed: 0.94, green: 0.38, blue: 0.35, alpha: 1)

    static func level(_ pct: Double) -> NSColor {
        if pct >= 85 { return crit }
        if pct >= 60 { return warn }
        return ok
    }
}

func humanCountdown(_ date: Date?) -> String {
    guard let date = date else { return "—" }
    let s = Int(date.timeIntervalSinceNow)
    if s <= 0 { return "maintenant" }
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "\(d) j \(h) h" }
    if h > 0 { return "\(h) h \(m.formattedTwo)" }
    if m > 0 { return "\(m) min" }
    return "\(s) s"
}

extension Int {
    var formattedTwo: String { self < 10 ? "0\(self)" : "\(self)" }
}

final class WidgetView: NSView {

    var usage: Usage?
    var plan: String?
    var offline = false      // aucune donnée fraîche affichable
    var limited = false      // la cause est un HTTP 429, pas une panne réseau
    var collapsed = false

    static let expandedWidth: CGFloat = 244
    static let bubbleSize: CGFloat = 52

    // Hauteur nécessaire selon le nombre de lignes affichées.
    func expandedHeight() -> CGFloat {
        var rows = 0
        if usage?.session != nil { rows += 1 }
        if usage?.weekly != nil { rows += 1 }
        if usage?.scoped != nil { rows += 1 }
        if rows == 0 { rows = 1 }
        return 14 + 15 + CGFloat(rows) * 33 + 4
    }

    // MARK: dessin

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = collapsed ? bounds.width / 2 : 14
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        Palette.bg.setFill()
        card.fill()
        Palette.stroke.setStroke()
        card.lineWidth = 1
        card.stroke()

        collapsed ? drawBubble() : drawPanel()
    }

    private func drawBubble() {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let s = usage?.session?.pct ?? 0
        let w = usage?.weekly?.pct ?? 0

        if offline {
            drawString("—", font: .systemFont(ofSize: 15, weight: .semibold),
                       color: Palette.faint, centeredIn: bounds, dy: 0)
            return
        }

        drawRing(center: c, radius: 20, width: 3.5, pct: s, color: Palette.level(s))
        drawRing(center: c, radius: 14.5, width: 2.5, pct: w, color: Palette.level(w).withAlphaComponent(0.55))

        drawString("\(Int(s.rounded()))",
                   font: .monospacedDigitSystemFont(ofSize: 14, weight: .semibold),
                   color: Palette.text, centeredIn: bounds, dy: 0)
    }

    private func drawRing(center: NSPoint, radius: CGFloat, width: CGFloat, pct: Double, color: NSColor) {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = width
        Palette.track.setStroke()
        track.stroke()

        let v = max(0, min(100, pct))
        guard v > 0 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius,
                      startAngle: 90, endAngle: 90 - 360 * CGFloat(v / 100), clockwise: true)
        arc.lineWidth = width
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }

    private func drawPanel() {
        let pad: CGFloat = 14
        var y = bounds.height - 14

        // En-tête
        let title = NSAttributedString(string: "CLAUDE", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: Palette.dim,
            .kern: 1.4
        ])
        title.draw(at: NSPoint(x: pad, y: y - 10))

        let right = limited ? "bridé" : (offline ? "hors ligne" : (plan ?? "usage"))
        let rightAttr = NSAttributedString(string: right, attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: limited ? Palette.warn : (offline ? Palette.crit : Palette.faint)
        ])
        rightAttr.draw(at: NSPoint(x: bounds.width - pad - rightAttr.size().width, y: y - 10))

        y -= 15

        var rows: [Metric] = []
        if let m = usage?.session { rows.append(m) }
        if let m = usage?.weekly { rows.append(m) }
        if let m = usage?.scoped { rows.append(m) }

        if rows.isEmpty {
            let vide = limited ? "Quota d'API bridé" : (offline ? "Pas de données" : "Chargement…")
            drawString(vide,
                       font: .systemFont(ofSize: 11, weight: .regular),
                       color: Palette.dim,
                       centeredIn: NSRect(x: 0, y: 0, width: bounds.width, height: y), dy: 0)
            return
        }

        for m in rows {
            drawRow(m, top: y, pad: pad)
            y -= 33
        }
    }

    private func drawRow(_ m: Metric, top: CGFloat, pad: CGFloat) {
        let w = bounds.width - pad * 2
        let color = Palette.level(m.pct)

        // Ligne de texte
        let label = NSAttributedString(string: m.label, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: Palette.text
        ])
        label.draw(at: NSPoint(x: pad, y: top - 13))

        let reset = NSAttributedString(string: humanCountdown(m.resetsAt), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: Palette.faint
        ])
        reset.draw(at: NSPoint(x: pad + label.size().width + 7, y: top - 12.5))

        let pct = NSAttributedString(string: "\(Int(m.pct.rounded())) %", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: color
        ])
        pct.draw(at: NSPoint(x: bounds.width - pad - pct.size().width, y: top - 13.5))

        // Barre
        let barY = top - 22
        let barH: CGFloat = 4.5
        let track = NSBezierPath(roundedRect: NSRect(x: pad, y: barY, width: w, height: barH),
                                 xRadius: barH / 2, yRadius: barH / 2)
        Palette.track.setFill()
        track.fill()

        let v = CGFloat(max(0, min(100, m.pct)) / 100)
        if v > 0 {
            let fw = max(barH, w * v)
            let fill = NSBezierPath(roundedRect: NSRect(x: pad, y: barY, width: fw, height: barH),
                                    xRadius: barH / 2, yRadius: barH / 2)
            color.setFill()
            fill.fill()
        }
    }

    private func drawString(_ s: String, font: NSFont, color: NSColor, centeredIn rect: NSRect, dy: CGFloat) {
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        let size = a.size()
        a.draw(at: NSPoint(x: rect.midX - size.width / 2,
                           y: rect.midY - size.height / 2 + dy))
    }

    // MARK: interactions

    private var dragOrigin: NSPoint?
    private var windowOrigin: NSPoint?
    private var didDrag = false

    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        dragOrigin = NSEvent.mouseLocation
        windowOrigin = win.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = window, let start = dragOrigin, let wo = windowOrigin else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x, dy = now.y - start.y
        if abs(dx) > 3 || abs(dy) > 3 { didDrag = true }
        win.setFrameOrigin(NSPoint(x: wo.x + dx, y: wo.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            (NSApp.delegate as? AppDelegate)?.savePosition()
        } else {
            (NSApp.delegate as? AppDelegate)?.toggleCollapsed()
        }
        dragOrigin = nil
        windowOrigin = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        (NSApp.delegate as? AppDelegate)?.showMenu(event: event, in: self)
    }
}

// ─────────────────────────── Fenêtre flottante ───────────────────────────

final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// ─────────────────────────────── App ───────────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var panel: WidgetPanel!
    private var view: WidgetView!
    private let fetcher = UsageFetcher()
    private var pollTimer: Timer?
    private var tickTimer: Timer?

    private let supportDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClaudeUsageWidget", isDirectory: true)
    private var configURL: URL { supportDir.appendingPathComponent("config.json") }
    private let agentLabel = "com.chloe.claude-usage-widget"
    private var agentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        guard acquireSingleInstanceLock() else { NSApp.terminate(nil); return }

        view = WidgetView(frame: NSRect(x: 0, y: 0, width: WidgetView.expandedWidth, height: 120))

        panel = WidgetPanel(contentRect: view.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false

        loadConfig()
        applyGeometry(animated: false)
        panel.orderFrontRegardless()

        refresh(force: true)
        fetcher.fetchPlan { [weak self] plan in
            self?.view.plan = plan
            self?.view.needsDisplay = true
        }

        // 5 min : le quota bouge lentement, et 60 s finissait par déclencher un 429
        // (≈1 440 appels/jour). Cf. diagnostic du 02/09/2026.
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refresh(force: false)
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.view.needsDisplay = true
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh(force: false) }
    }

    /// Un seul widget à la fois : verrou exclusif tenu pour toute la vie du process.
    private var lockFD: Int32 = -1
    private func acquireSingleInstanceLock() -> Bool {
        let path = supportDir.appendingPathComponent(".lock").path
        lockFD = open(path, O_CREAT | O_RDWR, 0o644)
        guard lockFD >= 0 else { return true }
        if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            close(lockFD)
            return false
        }
        return true
    }

    // MARK: données

    static let pollInterval: TimeInterval = 300      // 5 min
    static let backoffMax: TimeInterval = 3600       // 1 h

    /// Tant que cette date n'est pas passée, les rafraîchissements automatiques
    /// sont sautés — retaper pendant un 429 ne fait qu'entretenir le bridage.
    private var backoffUntil: Date?
    private var backoffStep = 0

    /// Entrée du menu « Rafraîchir » : l'utilisateur force, on ignore le backoff.
    @objc func refreshFromMenu() { refresh(force: true) }

    func refresh(force: Bool) {
        if !force, let until = backoffUntil, Date() < until { return }

        fetcher.fetchUsage { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .ok(let usage):
                self.view.usage = usage
                self.view.offline = false
                self.view.limited = false
                if self.backoffStep > 0 { journal("usage: rétabli, backoff levé") }
                self.backoffStep = 0
                self.backoffUntil = nil

            case .rateLimited(let retryAfter):
                self.backoffStep += 1
                // Retry-After s'il est fourni, sinon 10, 20, 40 min… plafonné à 1 h.
                let delay = retryAfter ?? min(Self.pollInterval * pow(2, Double(self.backoffStep)),
                                              Self.backoffMax)
                self.backoffUntil = Date().addingTimeInterval(delay)
                self.view.limited = true
                self.view.offline = true
                journal("usage: prochain essai dans \(Int(delay / 60)) min (palier \(self.backoffStep))")

            case .failed, .noToken:
                self.view.offline = true
                self.view.limited = false
            }
            self.applyGeometry(animated: false)
            self.view.needsDisplay = true
        }
    }

    // MARK: géométrie

    private var savedTopRight: NSPoint?

    func toggleCollapsed() {
        view.collapsed.toggle()
        applyGeometry(animated: true)
        savePosition()
    }

    private func applyGeometry(animated: Bool) {
        let size = view.collapsed
            ? NSSize(width: WidgetView.bubbleSize, height: WidgetView.bubbleSize)
            : NSSize(width: WidgetView.expandedWidth, height: view.expandedHeight())

        let anchor = savedTopRight ?? defaultTopRight()
        let frame = NSRect(x: anchor.x - size.width, y: anchor.y - size.height,
                           width: size.width, height: size.height)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        view.needsDisplay = true
    }

    private func defaultTopRight() -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let vf = screen.visibleFrame
        return NSPoint(x: vf.maxX - 16, y: vf.maxY - 12)
    }

    func savePosition() {
        savedTopRight = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        let dict: [String: Any] = [
            "x": savedTopRight!.x,
            "y": savedTopRight!.y,
            "collapsed": view.collapsed
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? data.write(to: configURL)
        }
    }

    private func loadConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let x = (d["x"] as? NSNumber)?.doubleValue, let y = (d["y"] as? NSNumber)?.doubleValue {
            let p = NSPoint(x: x, y: y)
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -40, dy: -40).contains(p) }) {
                savedTopRight = p
            }
        }
        view.collapsed = (d["collapsed"] as? NSNumber)?.boolValue ?? false
    }

    @objc func resetPosition() {
        savedTopRight = nil
        applyGeometry(animated: true)
        savePosition()
    }

    // MARK: menu

    func showMenu(event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Rafraîchir", action: #selector(refreshFromMenu), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: self.view.collapsed ? "Agrandir" : "Réduire en bulle",
                     action: #selector(menuToggle), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Replacer en haut à droite", action: #selector(resetPosition), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        let auto = menu.addItem(withTitle: "Lancer au démarrage", action: #selector(toggleAutostart), keyEquivalent: "")
        auto.target = self
        auto.state = FileManager.default.fileExists(atPath: agentPlist.path) ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quitter", action: #selector(quit), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func menuToggle() { toggleCollapsed() }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleAutostart() {
        let fm = FileManager.default
        if fm.fileExists(atPath: agentPlist.path) {
            runLaunchctl(["bootout", "gui/\(getuid())/\(agentLabel)"])
            try? fm.removeItem(at: agentPlist)
            return
        }
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive"
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        else { return }
        try? fm.createDirectory(at: agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: agentPlist)
        runLaunchctl(["bootstrap", "gui/\(getuid())", agentPlist.path])
    }

    private func runLaunchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
