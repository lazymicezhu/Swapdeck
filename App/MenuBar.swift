import AppKit
import Observation

/// One menu bar item: Claude, then Codex, each its service's logo followed by what is left on the line in use —
/// a subscription as two rings (outer: this week, inner: 5 hours), a balance as yuan. Clicking it opens 切号.
/// Drawn as a single image so the order and the spacing stay put (separate items are placed by macOS).
@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private enum Reading: Equatable {
        case rings(week: Double?, five: Double?, weekOut: Bool, fiveOut: Bool)
        case money(String)
        case unknown

        var alarm: Bool {
            guard case let .rings(week, five, weekOut, fiveOut) = self else { return false }
            return weekOut || fiveOut || (week ?? 100) < 10 || (five ?? 100) < 10
        }
    }

    private struct Segment { var logo: NSImage; var logoSide: CGFloat; var reading: Reading }

    private var item: NSStatusItem?
    private var timer: Timer?
    private lazy var claudeLogo = Self.trimmed(Bundle.main.image(forResource: "ClaudeTemplate"))
    private lazy var codexLogo = Self.trimmed(Bundle.main.image(forResource: "CodexTemplate"))

    func start() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(open)
        item.button?.imagePosition = .imageOnly
        item.isVisible = false
        self.item = item
        update()
        // Windows reset on their own; redraw so a used-up ring comes back without waiting for a refresh.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { MenuBarController.shared.render() }
        }
    }

    @objc private func open() {
        NSApp.activate(ignoringOtherApps: true)
        WindowManager.shared.showMain()
    }

    /// Re-renders whenever anything it read from the stores changes.
    private func update() {
        withObservationTracking { render() } onChange: {
            Task { @MainActor in MenuBarController.shared.update() }
        }
    }

    private func render() {
        let claude = ClaudeStore.shared, codex = CodexStore.shared
        var segments: [Segment] = []
        var names: [String] = []

        if let provider = claude.providers.first(where: { $0.id == claude.activeID }), let logo = claudeLogo {
            let reading: Reading
            if let quota = claude.quotas[provider.id], quota.week != nil || quota.fiveHour != nil {
                reading = Self.rings(week: quota.week, five: quota.fiveHour)
            } else if let balance = claude.balances[provider.id] {
                reading = .money(Fmt.yuanDown(balance.credit * provider.cnyPerUnit, 2))
            } else {
                reading = .unknown
            }
            segments.append(Segment(logo: logo, logoSide: 13.5, reading: reading))
            names.append("Claude · \(provider.displayName)")
        }

        if let profile = codex.active, let logo = codexLogo {
            let reading: Reading
            if profile.kind == .official, let quota = codex.quotas[profile.id], quota.week != nil || quota.fiveHour != nil {
                reading = Self.rings(week: quota.week, five: quota.fiveHour)
            } else if profile.kind == .relay, let balance = codex.balances[profile.id] {
                reading = .money(Fmt.yuanDown(balance.credit * profile.cnyPerUnit, 2))
            } else {
                reading = .unknown
            }
            segments.append(Segment(logo: logo, logoSide: 13, reading: reading))
            names.append("Codex · \(profile.displayName)")
        }

        guard let item, let button = item.button else { return }
        guard !segments.isEmpty else { item.isVisible = false; return }
        button.image = Self.image(segments)
        button.setAccessibilityLabel(names.joined(separator: "，"))
        item.isVisible = true
    }

    private static func rings(week: CodexWindow?, five: CodexWindow?) -> Reading {
        // A window whose reset time has passed is full again, whatever the last reading said.
        func left(_ w: CodexWindow?) -> Double? { w.map { $0.resetAt <= Date() ? 100 : $0.remaining } }
        return .rings(week: left(week), five: left(five), weekOut: week?.exhausted ?? false, fiveOut: five?.exhausted ?? false)
    }

    // MARK: Drawing

    private static let height: CGFloat = 16
    private static let ringSide: CGFloat = 16
    /// Logo to what follows it: close, so they read as one.
    private static let gap: CGFloat = 2.5
    /// Between Claude's group and Codex's: wider, so the two groups stand apart.
    private static let groupGap: CGFloat = 10

    private static func moneyText(_ text: String, ink: NSColor) -> NSAttributedString {
        let size = NSFont.menuBarFont(ofSize: 0).pointSize
        let amount = text.hasPrefix("¥") ? String(text.dropFirst()) : text
        let out = NSMutableAttributedString(string: "¥", attributes: [
            .font: NSFont.systemFont(ofSize: size * 0.8, weight: .medium),
            .foregroundColor: ink.withAlphaComponent(0.55),
            .kern: 0.5,
        ])
        out.append(NSAttributedString(string: amount, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: ink,
        ]))
        return out
    }

    private static func dashText(ink: NSColor) -> NSAttributedString {
        NSAttributedString(string: "—", attributes: [.font: NSFont.menuBarFont(ofSize: 0), .foregroundColor: ink.withAlphaComponent(0.55)])
    }

    private static func width(_ segment: Segment) -> CGFloat {
        let rest: CGFloat
        switch segment.reading {
        case .rings: rest = ringSide
        case .money(let text): rest = ceil(moneyText(text, ink: .black).size().width)
        case .unknown: rest = ceil(dashText(ink: .black).size().width)
        }
        return segment.logoSide + gap + rest
    }

    /// All one colour (a template image, so the menu bar tints it) unless a window is low or used up: then it is
    /// drawn in label colour with that ring in red.
    private static func image(_ segments: [Segment]) -> NSImage {
        let alarm = segments.contains { $0.reading.alarm }
        let widths = segments.map(width)
        let total = widths.reduce(0, +) + groupGap * CGFloat(segments.count - 1)
        let image = NSImage(size: NSSize(width: total, height: height), flipped: false) { _ in
            let ink: NSColor = alarm ? .labelColor : .black
            var x: CGFloat = 0
            for (segment, width) in zip(segments, widths) {
                let logoRect = NSRect(x: x, y: (height - segment.logoSide) / 2, width: segment.logoSide, height: segment.logoSide)
                if alarm, let tinted = tint(segment.logo, ink, size: logoRect.size) { tinted.draw(in: logoRect) } else { segment.logo.draw(in: logoRect) }
                let restX = x + segment.logoSide + gap
                switch segment.reading {
                case let .rings(week, five, weekOut, fiveOut):
                    let center = NSPoint(x: restX + ringSide / 2, y: height / 2)
                    ring(center: center, radius: 6.6, left: week, out: weekOut, ink: ink)
                    ring(center: center, radius: 3.5, left: five, out: fiveOut, ink: ink)
                case .money(let text):
                    drawText(moneyText(text, ink: ink), at: restX)
                case .unknown:
                    drawText(dashText(ink: ink), at: restX)
                }
                x += width + groupGap
            }
            return true
        }
        image.isTemplate = !alarm
        return image
    }

    private static func drawText(_ text: NSAttributedString, at x: CGFloat) {
        let size = text.size()
        text.draw(at: NSPoint(x: x, y: (height - size.height) / 2))
    }

    private static func ring(center: NSPoint, radius: CGFloat, left: Double?, out: Bool, ink: NSColor) {
        guard let left else { return }
        let width: CGFloat = 1.6
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = width
        (out ? NSColor.systemRed.withAlphaComponent(0.4) : ink.withAlphaComponent(0.22)).setStroke()
        track.stroke()
        guard !out, left > 0 else { return }
        let fill = NSBezierPath()
        // From twelve o'clock, clockwise.
        fill.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(min(left, 100)) / 100, clockwise: true)
        fill.lineWidth = width
        fill.lineCapStyle = .round
        (left < 10 ? NSColor.systemRed : ink).setStroke()
        fill.stroke()
    }

    /// The logo cut to its drawn part: the two apps' tray icons come with different empty margins.
    private static func trimmed(_ image: NSImage?) -> NSImage? {
        guard let image,
              let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).max(by: { $0.pixelsWide < $1.pixelsWide })
        else { return image }
        var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }
        // Pixel rows run top-down; image points bottom-up.
        let sx = image.size.width / CGFloat(rep.pixelsWide), sy = image.size.height / CGFloat(rep.pixelsHigh)
        let source = NSRect(x: CGFloat(minX) * sx, y: CGFloat(rep.pixelsHigh - 1 - maxY) * sy,
                            width: CGFloat(maxX - minX + 1) * sx, height: CGFloat(maxY - minY + 1) * sy)
        let out = NSImage(size: source.size, flipped: false) { rect in
            image.draw(in: rect, from: source, operation: .sourceOver, fraction: 1)
            return true
        }
        out.isTemplate = true
        return out
    }

    private static func tint(_ image: NSImage, _ color: NSColor, size: NSSize) -> NSImage? {
        NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
