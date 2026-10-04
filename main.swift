import Cocoa

// ─────────────────────────────── Modèle ───────────────────────────────

struct Metric {
    var pct: Double
    var resetsAt: Date?
    var label: String
    var window: TimeInterval     // durée de la fenêtre de quota, pour calculer le rythme

    static let sessionWindow: TimeInterval = 5 * 3600
    static let weekWindow: TimeInterval = 7 * 86400
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
                    u.session = Metric(pct: pct, resetsAt: reset, label: "Session", window: Metric.sessionWindow)
                case "weekly_all":
                    u.weekly = Metric(pct: pct, resetsAt: reset, label: "Semaine", window: Metric.weekWindow)
                case "weekly_scoped":
                    var name = "Modèle"
                    if let scope = l["scope"] as? [String: Any],
                       let m = scope["model"] as? [String: Any],
                       let dn = m["display_name"] as? String { name = dn }
                    let cand = Metric(pct: pct, resetsAt: reset, label: name, window: Metric.weekWindow)
                    if u.scoped == nil || pct > u.scoped!.pct { u.scoped = cand }
                default: break
                }
            }
        }

        // Repli sur l'ancienne forme.
        func legacy(_ key: String, _ label: String, _ window: TimeInterval) -> Metric? {
            guard let d = json[key] as? [String: Any],
                  let util = (d["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return Metric(pct: util, resetsAt: parseDate(d["resets_at"] as? String), label: label, window: window)
        }
        if u.session == nil { u.session = legacy("five_hour", "Session", Metric.sessionWindow) }
        if u.weekly == nil { u.weekly = legacy("seven_day", "Semaine", Metric.weekWindow) }

        return u
    }
}

// ─────────────────────────────── Rendu ───────────────────────────────

enum Palette {
    static let bg      = NSColor(srgbRed: 0.094, green: 0.094, blue: 0.106, alpha: 0.94)
    static let bgCrit  = NSColor(srgbRed: 0.157, green: 0.078, blue: 0.078, alpha: 0.94)
    static let stroke  = NSColor(white: 1.0, alpha: 0.12)
    static let track   = NSColor(white: 1.0, alpha: 0.13)
    static let rule    = NSColor(white: 1.0, alpha: 0.08)
    static let text    = NSColor(white: 0.96, alpha: 1.0)
    static let soft    = NSColor(white: 0.84, alpha: 1.0)
    static let dim     = NSColor(white: 1.0, alpha: 0.62)
    static let faint   = NSColor(white: 1.0, alpha: 0.50)
    static let muted   = NSColor(white: 0.45, alpha: 1.0)
    static let ok      = NSColor(srgbRed: 0.42, green: 0.82, blue: 0.55, alpha: 1)
    static let warn    = NSColor(srgbRed: 0.97, green: 0.70, blue: 0.31, alpha: 1)
    static let crit    = NSColor(srgbRed: 0.94, green: 0.38, blue: 0.35, alpha: 1)

    static func level(_ pct: Double) -> NSColor {
        if pct >= 90 { return crit }
        if pct >= 70 { return warn }
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

func resetPhrase(_ date: Date?) -> String? {
    guard date != nil else { return nil }
    let c = humanCountdown(date)
    return c == "maintenant" ? "reset imminent" : "reset dans \(c)"
}

func agePhrase(_ date: Date?) -> String {
    guard let date = date else { return "Pas encore actualisé" }
    let s = Int(-date.timeIntervalSinceNow)
    if s < 60 { return "Actualisé à l'instant" }
    if s < 3600 { return "Actualisé il y a \(s / 60) min" }
    return "Actualisé il y a \(s / 3600) h"
}

/// Où la jauge « devrait » être si la consommation était parfaitement régulière
/// jusqu'au reset : la part de la fenêtre déjà écoulée, en %.
func expectedPct(_ m: Metric) -> Double? {
    guard let r = m.resetsAt else { return nil }
    let left = r.timeIntervalSinceNow
    guard left > 0, left <= m.window else { return nil }
    return (1 - left / m.window) * 100
}

extension Int {
    var formattedTwo: String { self < 10 ? "0\(self)" : "\(self)" }
}

final class WidgetView: NSView {

    var usage: Usage?
    var plan: String?
    var offline = false      // aucune donnée fraîche affichable
    var limited = false      // la cause est un HTTP 429, pas une panne réseau
    var lastUpdate: Date?
    var expanded = false     // taille visée : panneau déplié (survol ou épinglé)
    var pinned = false

    static let bubbleSize: CGFloat = 56
    static let expandedWidth: CGFloat = 296
    private static let pad: CGFloat = 16
    private static let headerH: CGFloat = 56
    private static let rowH: CGFloat = 62
    private static let badgeCenter = NSPoint(x: 46, y: 10)

    // Coordonnées depuis le haut : la pastille reste ancrée en haut à gauche
    // pendant que le panneau se déplie vers le bas.
    override var isFlipped: Bool { true }

    private var rows: [Metric] {
        [usage?.session, usage?.weekly, usage?.scoped].compactMap { $0 }
    }

    /// Hauteur du panneau déplié selon le nombre de lignes affichées.
    func expandedHeight() -> CGFloat {
        let body = rows.isEmpty ? 40 : CGFloat(rows.count) * Self.rowH
        return Self.headerH + 14 + body + 14 + 14
    }

    /// Chiffre de la pastille : la session, à défaut la semaine.
    private var headline: Double? { usage?.session?.pct ?? usage?.weekly?.pct }
    private var critical: Bool { !offline && (headline ?? 0) >= 90 }

    /// 0 = pastille, 1 = panneau complet. Suit la taille réelle de la fenêtre,
    /// si bien que le contenu se dévoile au fil de l'animation.
    private var progress: CGFloat {
        let p = (bounds.width - Self.bubbleSize) / (Self.expandedWidth - Self.bubbleSize)
        return max(0, min(1, p))
    }

    // MARK: dessin

    override func draw(_ dirtyRect: NSRect) {
        let t = progress
        let radius = min(min(bounds.width, bounds.height) / 2, 28 - 10 * t)
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        (critical ? Palette.bgCrit : Palette.bg).setFill()
        card.fill()
        (critical ? Palette.crit.withAlphaComponent(0.6) : Palette.stroke).setStroke()
        card.lineWidth = 1
        card.stroke()

        drawPastille()

        guard t > 0.01, let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        card.addClip()
        ctx.cgContext.setAlpha(t * t)
        drawHeader()
        drawBody()
        ctx.restoreGraphicsState()
    }

    private func drawPastille() {
        let c = NSPoint(x: 28, y: 28)

        if offline && !limited {
            let ring = NSBezierPath()
            ring.appendArc(withCenter: c, radius: 20, startAngle: 0, endAngle: 360)
            ring.lineWidth = 4
            ring.setLineDash([3, 4], count: 2, phase: 0)
            NSColor(white: 1, alpha: 0.22).setStroke()
            ring.stroke()
            drawCentered("—", .systemFont(ofSize: 15, weight: .bold), Palette.faint, at: c)
            drawBadge(Palette.crit, radius: 6)
            return
        }

        guard let pct = headline else {
            drawRing(center: c, pct: 25, color: Palette.dim)
            drawCentered("…", .systemFont(ofSize: 14, weight: .bold), Palette.dim, at: c)
            return
        }

        // Bridé : on garde la dernière valeur connue, mais grisée.
        let color = limited ? Palette.muted : Palette.level(pct)
        drawRing(center: c, pct: pct, color: color)
        drawCentered("\(Int(pct.rounded()))",
                     .monospacedDigitSystemFont(ofSize: 14, weight: .bold),
                     limited ? Palette.dim : (pct >= 70 ? color : Palette.text), at: c)
        if limited { drawClockBadge() }
    }

    private func drawRing(center c: NSPoint, pct: Double, color: NSColor) {
        let track = NSBezierPath()
        track.appendArc(withCenter: c, radius: 20, startAngle: 0, endAngle: 360)
        track.lineWidth = 4
        Palette.track.setStroke()
        track.stroke()

        let v = max(0, min(100, pct))
        guard v > 0 else { return }
        // Vue retournée : angles croissants = sens horaire à l'écran, -90° = midi.
        let arc = NSBezierPath()
        arc.appendArc(withCenter: c, radius: 20,
                      startAngle: -90, endAngle: -90 + 360 * CGFloat(v / 100), clockwise: false)
        arc.lineWidth = 4
        color.setStroke()
        arc.stroke()
    }

    private func drawBadge(_ color: NSColor, radius r: CGFloat) {
        let c = Self.badgeCenter
        let dot = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        color.setFill()
        dot.fill()
        dot.lineWidth = 2
        Palette.bg.withAlphaComponent(1).setStroke()
        dot.stroke()
    }

    private func drawClockBadge() {
        drawBadge(Palette.warn, radius: 8)
        let c = Self.badgeCenter
        let face = NSBezierPath(ovalIn: NSRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
        face.lineWidth = 1.3
        let hands = NSBezierPath()
        hands.move(to: NSPoint(x: c.x, y: c.y - 2.5))
        hands.line(to: c)
        hands.line(to: NSPoint(x: c.x + 2, y: c.y + 1))
        hands.lineWidth = 1.3
        hands.lineCapStyle = .round
        hands.lineJoinStyle = .round
        Palette.bg.withAlphaComponent(1).setStroke()
        face.stroke()
        hands.stroke()
    }

    private func headerLine() -> (String, NSColor) {
        if limited { return ("Bridé — nouvel essai plus tard", Palette.warn) }
        if offline { return ("Hors ligne", Palette.crit) }
        if let s = usage?.session {
            return (["Session", resetPhrase(s.resetsAt)].compactMap { $0 }.joined(separator: " · "), Palette.soft)
        }
        return ("Chargement…", Palette.dim)
    }

    private func drawHeader() {
        let x: CGFloat = 62
        let title = "CLAUDE" + (plan.map { " · " + $0.uppercased() } ?? "")
        drawText(title, .systemFont(ofSize: 10, weight: .bold), Palette.dim, at: NSPoint(x: x, y: 11), kern: 1.2)
        let (line, color) = headerLine()
        drawText(line, .systemFont(ofSize: 12, weight: .regular), color, at: NSPoint(x: x, y: 27))
    }

    private func drawBody() {
        let pad = Self.pad, right = Self.expandedWidth - pad
        Palette.rule.setFill()
        NSBezierPath(rect: NSRect(x: pad, y: Self.headerH, width: right - pad, height: 1)).fill()

        var y = Self.headerH + 14
        if rows.isEmpty {
            let msg = limited ? "Quota d'API bridé" : (offline ? "Pas de données" : "Chargement…")
            drawCentered(msg, .systemFont(ofSize: 12, weight: .regular), Palette.dim,
                         at: NSPoint(x: Self.expandedWidth / 2, y: y + 20))
            y += 40
        } else {
            for m in rows {
                drawRow(m, top: y)
                y += Self.rowH
            }
        }

        // Pied : fraîcheur des données.
        (limited ? Palette.warn : (offline ? Palette.crit : Palette.ok)).setFill()
        NSBezierPath(ovalIn: NSRect(x: pad, y: y + 4, width: 6, height: 6)).fill()
        let small = NSFont.systemFont(ofSize: 11, weight: .regular)
        drawText(agePhrase(lastUpdate), small, Palette.faint, at: NSPoint(x: pad + 12, y: y))
        drawTextRight(pinned ? "épinglé" : "clic droit : menu", small, Palette.faint, rightX: right, y: y)
    }

    private func drawRow(_ m: Metric, top y: CGFloat) {
        let pad = Self.pad, right = Self.expandedWidth - pad, w = right - pad
        let color = limited ? Palette.muted : Palette.level(m.pct)

        // Ligne de texte
        let label = drawText(m.label, .systemFont(ofSize: 13, weight: .semibold), Palette.text,
                             at: NSPoint(x: pad, y: y))
        if let r = resetPhrase(m.resetsAt) {
            drawText(r, .monospacedDigitSystemFont(ofSize: 11, weight: .regular), Palette.dim,
                     at: NSPoint(x: pad + label.width + 8, y: y + 2))
        }
        drawTextRight("\(Int(m.pct.rounded())) %", .monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                      m.pct >= 70 && !limited ? color : Palette.text, rightX: right, y: y)

        // Barre, et le trait blanc du rythme régulier
        let barY = y + 22, barH: CGFloat = 6
        Palette.track.setFill()
        NSBezierPath(roundedRect: NSRect(x: pad, y: barY, width: w, height: barH), xRadius: 3, yRadius: 3).fill()
        let v = CGFloat(max(0, min(100, m.pct)) / 100)
        if v > 0 {
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: pad, y: barY, width: max(barH, w * v), height: barH),
                         xRadius: 3, yRadius: 3).fill()
        }
        let expected = expectedPct(m)
        if let e = expected {
            Palette.text.setFill()
            let tx = pad + w * CGFloat(e / 100) - 1
            NSBezierPath(roundedRect: NSRect(x: tx, y: barY - 3, width: 2, height: barH + 6),
                         xRadius: 1, yRadius: 1).fill()
        }

        // Verdict : marge ou avance sur le rythme
        var verdict: (String, NSColor)?
        if m.pct >= 90 {
            verdict = ("Presque à sec — pause café ?", Palette.crit)
        } else if let e = expected {
            let d = Int((e - m.pct).rounded())
            if abs(d) <= 2 { verdict = ("Pile dans le rythme", Palette.ok) }
            else if d > 0 { verdict = ("\(d) pts de marge sur le rythme", Palette.ok) }
            else { verdict = ("\(-d) pts d'avance — lève le pied", Palette.warn) }
        }
        if let v = verdict {
            drawText(v.0, .systemFont(ofSize: 11, weight: .regular), limited ? Palette.dim : v.1,
                     at: NSPoint(x: pad, y: y + 34))
        }
    }

    @discardableResult
    private func drawText(_ s: String, _ font: NSFont, _ color: NSColor, at p: NSPoint, kern: CGFloat = 0) -> NSSize {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if kern != 0 { attrs[.kern] = kern }
        let a = NSAttributedString(string: s, attributes: attrs)
        a.draw(at: p)
        return a.size()
    }

    private func drawTextRight(_ s: String, _ font: NSFont, _ color: NSColor, rightX: CGFloat, y: CGFloat) {
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        a.draw(at: NSPoint(x: rightX - a.size().width, y: y))
    }

    private func drawCentered(_ s: String, _ font: NSFont, _ color: NSColor, at c: NSPoint) {
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        let size = a.size()
        a.draw(at: NSPoint(x: c.x - size.width / 2, y: c.y - size.height / 2))
    }

    // MARK: interactions

    private var tracking: NSTrackingArea?
    private var controller: AppDelegate? { NSApp.delegate as? AppDelegate }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { controller?.hoverChanged() }

    override func mouseExited(with event: NSEvent) {
        if dragOrigin == nil { controller?.hoverChanged() }
    }

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
            controller?.savePosition()
            controller?.hoverChanged()
        } else {
            controller?.togglePinned()
        }
        dragOrigin = nil
        windowOrigin = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showMenu(event: event, in: self)
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

        view = WidgetView(frame: NSRect(x: 0, y: 0, width: WidgetView.bubbleSize, height: WidgetView.bubbleSize))

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
                self.view.lastUpdate = Date()
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

    // MARK: survol

    private var pinned = false       // clic : le panneau reste déplié sans survol
    private var hovering = false
    private var hoverTimer: Timer?

    private var isMouseInside: Bool { NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) }

    /// Appelé à chaque entrée/sortie de la souris. On relit la position réelle du
    /// curseur après un court délai : un passage éclair ne déplie rien, et un
    /// aller-retour rapide ne fait pas clignoter le panneau.
    func hoverChanged() {
        hoverTimer?.invalidate()
        let inside = isMouseInside
        guard inside != hovering else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: inside ? 0.12 : 0.35, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            let now = self.isMouseInside
            guard now != self.hovering else { return }
            self.hovering = now
            self.updateExpanded()
        }
    }

    func togglePinned() {
        pinned.toggle()
        updateExpanded()
        savePosition()
    }

    private func updateExpanded() {
        view.pinned = pinned
        view.needsDisplay = true
        let want = hovering || pinned
        guard want != view.expanded else { return }
        view.expanded = want
        applyGeometry(animated: true)
    }

    private func applyGeometry(animated: Bool) {
        let size = view.expanded
            ? NSSize(width: WidgetView.expandedWidth, height: view.expandedHeight())
            : NSSize(width: WidgetView.bubbleSize, height: WidgetView.bubbleSize)

        let anchor = savedTopRight ?? defaultTopRight()
        let frame = NSRect(x: anchor.x - size.width, y: anchor.y - size.height,
                           width: size.width, height: size.height)
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                self?.panel.invalidateShadow()
            })
        } else {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
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
            "pinned": pinned
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
        pinned = (d["pinned"] as? NSNumber)?.boolValue ?? false
        view.pinned = pinned
        view.expanded = pinned
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
        let pin = menu.addItem(withTitle: "Garder ouvert", action: #selector(menuTogglePin), keyEquivalent: "")
        pin.target = self
        pin.state = pinned ? .on : .off
        menu.addItem(withTitle: "Replacer en haut à droite", action: #selector(resetPosition), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        let auto = menu.addItem(withTitle: "Lancer au démarrage", action: #selector(toggleAutostart), keyEquivalent: "")
        auto.target = self
        auto.state = FileManager.default.fileExists(atPath: agentPlist.path) ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quitter", action: #selector(quit), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        // Le menu est modal : la souris a pu quitter le widget pendant qu'il était ouvert.
        hoverChanged()
    }

    @objc private func menuTogglePin() { togglePinned() }

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
