import SwiftUI
import AppKit

enum SwitcherTab: String, CaseIterable, Identifiable {
    case claude = "Claude", codex = "Codex"
    var id: Self { self }
}

/// The card case: every account or relay is a card. The one in use sits in front, fully open;
/// the rest are stacked under it showing one edge. 切换 brings a card to the front.
struct SwitcherView: View {
    // Read once, then kept in view state: a launch argument (-switcher.tab, used for screenshots) outranks saved
    // defaults, so reading it on every redraw would pin the tab and make the switch unclickable.
    @State private var tab = UserDefaults.standard.string(forKey: "switcher.tab") ?? SwitcherTab.claude.rawValue
    @State private var showSettings = false
    private var claude = ClaudeStore.shared
    private var codex = CodexStore.shared

    private var isCodex: Bool { tab == SwitcherTab.codex.rawValue }
    private var refreshing: Bool { isCodex ? codex.refreshing : claude.refreshing }
    private var refreshedAt: Date? { isCodex ? codex.refreshedAt : claude.refreshedAt }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Group {
                if isCodex { CodexCase() } else { ClaudeCase() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) { Toast(message: isCodex ? codex.message : claude.message) }
        .frame(minWidth: 320, minHeight: 440)
        .background(Palette.window)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .onChange(of: tab) { _, value in UserDefaults.standard.set(value, forKey: "switcher.tab") }
    }

    /// Sits in the transparent title bar, clear of the window buttons; the switch stays centred.
    private var titleBar: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 64, height: 1)
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                ForEach(SwitcherTab.allCases) { item in
                    let on = item.rawValue == tab
                    Button { withAnimation(.snappy(duration: 0.22)) { tab = item.rawValue } } label: {
                        Text(item.rawValue)
                            .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Palette.inkText : Color.secondary)
                            .padding(.horizontal, 14).padding(.vertical, 5)
                            .background(Capsule().fill(on ? Palette.ink : Color.clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                ToolButton(symbol: "arrow.clockwise", help: refreshedAt.map { "刷新（上次 \(Fmt.time($0))）" } ?? "刷新", busy: refreshing) {
                    Task { if isCodex { await codex.refreshAll() } else { await claude.refreshAll() } }
                }
                ToolButton(symbol: "gearshape", help: "设置") { showSettings = true }
            }
            .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }
}

/// Window grey, an ink front card (inverted in dark mode) and plain back cards.
enum Palette {
    static let window = Color(light: 0xECECEE, dark: 0x1B1B1D)
    static let ink = Color(light: 0x0E0F12, dark: 0xF2F2F4)
    static let inkText = Color(light: 0xF3F4F6, dark: 0x111214)
    static let inkMuted = Color(light: 0x9BA0AA, dark: 0x6E727A)
    static let back = Color(light: 0xFFFFFF, dark: 0x2A2A2D)
    static let backDeep = Color(light: 0xF6F6F7, dark: 0x242427)
    static let link = Color(light: 0x2F6BFF, dark: 0x5B8CFF)
    static let warn = Color(light: 0xF08A24, dark: 0xF5A04A)
    static let alarm = Color(light: 0xE5484D, dark: 0xFF6A5C)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }
}

private struct ToolButton: View {
    let symbol: String
    let help: String
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().controlSize(.small) } else { Image(systemName: symbol).font(.system(size: 13)) }
            }
            .frame(width: 26, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(busy)
        .help(help)
    }
}

// MARK: Cards

/// What a card shows, independent of whether it is in front or stacked.
private struct CardModel: Identifiable {
    enum Body {
        case quota(plan: String?, five: CodexWindow?, week: CodexWindow?, credits: String?)
        case balance(host: String, amount: String?)
    }
    let id: UUID
    let kind: String          // ChatGPT, 中转
    let title: String
    let body: Body
    let note: String?         // error or "读取中"
    /// Last 30 days: yuan for a relay, tokens for a ChatGPT account. Shown on the front card only.
    var usage: UsageSeries? = nil
}

/// The front card: fully open, ink coloured.
private struct FrontCard: View {
    let card: CardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(card.kind)  使用中").font(.system(size: 11)).foregroundStyle(Palette.inkMuted)
                    Text(card.title).font(.system(size: 16, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if case .quota(let plan, let five, let week, let credits) = card.body {
                    // A used-up window takes the plan's place with the time it comes back.
                    if let back = [five, week].compactMap({ $0 }).filter(\.exhausted).map(\.resetAt).min() {
                        Text("\(ResetText.moment(back)) 恢复").font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(Palette.alarm)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(Capsule().fill(Palette.alarm.opacity(0.16)))
                            .help(ResetText.detail(back))
                    } else if let plan {
                        Text(plan).font(.system(size: 11))
                            .padding(.horizontal, 9).padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(Palette.inkText.opacity(0.28)))
                            .help(credits.map { "Credits：\($0)" } ?? "")
                    }
                }
            }
            switch card.body {
            case .quota(_, let five, let week, let credits):
                Meter(label: "5 小时", window: five).padding(.top, 20)
                Meter(label: "7 天", window: week).padding(.top, 14)
                if card.usage == nil, let credits {
                    HStack {
                        Text("Credits").foregroundStyle(Palette.inkMuted)
                        Spacer()
                        Text(credits).fontWeight(.semibold).monospacedDigit()
                    }
                    .font(.system(size: 11.5))
                    .padding(.top, 18)
                }
            case .balance(_, let amount):
                HStack(alignment: .lastTextBaseline) {
                    Spacer(minLength: 0)
                    // The amount always stays on one line; a long one shrinks a little before anything wraps.
                    Text(amount ?? "—").font(.system(size: 30, weight: .semibold)).monospacedDigit().kerning(-0.5)
                        .lineLimit(1).minimumScaleFactor(0.6).layoutPriority(1)
                }
                .padding(.top, 26)
            }
            if let usage = card.usage {
                UsageBars(series: usage).padding(.top, 18)
            }
            if let note = card.note {
                Text(note).font(.system(size: 11)).foregroundStyle(Palette.warn).padding(.top, 10)
            }
        }
        .foregroundStyle(Palette.inkText)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.ink))
        .shadow(color: .black.opacity(0.22), radius: 15, y: 8)
    }
}

/// When a rate-limit window comes back, in the words the cards use.
enum ResetText {
    /// 20:10 today, 11月20日 otherwise.
    static func moment(_ date: Date) -> String {
        date.timeIntervalSinceNow < 86400 ? date.formatted(.dateTime.hour().minute()) : date.formatted(.dateTime.month().day())
    }
    /// 21:35 today, 11/18 otherwise: for the narrow stacked cards.
    static func short(_ date: Date) -> String {
        date.timeIntervalSinceNow < 86400 ? date.formatted(.dateTime.hour().minute()) : date.formatted(.dateTime.month(.defaultDigits).day()).replacingOccurrences(of: "月", with: "/").replacingOccurrences(of: "日", with: "")
    }
    static func countdown(to date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let hours = seconds / 3600, minutes = seconds % 3600 / 60
        if hours >= 24 { return "\(hours / 24) 天 \(hours % 24) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(max(minutes, 1)) 分钟"
    }
    static func detail(_ date: Date) -> String {
        "\(countdown(to: date))后恢复（\(date.formatted(.dateTime.month().day().hour().minute()))）"
    }
}

extension CodexWindow {
    /// Used up: nothing left until it resets.
    var exhausted: Bool { remaining < 0.5 && resetAt > Date() }
}

/// One rate-limit window as 20 cells; neutral until it runs low. Used up, it becomes a countdown instead.
private struct Meter: View {
    let label: String
    let window: CodexWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(Palette.inkMuted)
                Spacer()
                Text(window.map { "\(Int($0.remaining.rounded()))%" } ?? "—")
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(tint ?? Palette.inkText)
            }
            .font(.system(size: 11.5))
            if let window, window.exhausted {
                // Refreshes itself so the countdown never goes stale while the window is open.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: 8) {
                        Text("已用完，\(ResetText.countdown(to: window.resetAt, now: context.date))后恢复")
                            .font(.system(size: 11.5)).monospacedDigit()
                            .fixedSize()
                        Rectangle().fill(Palette.alarm.opacity(0.4)).frame(minWidth: 0, maxWidth: .infinity).frame(height: 1)
                    }
                    .foregroundStyle(Palette.alarm)
                    .frame(height: 14)
                }
            } else {
                HStack(spacing: 3) {
                    ForEach(0..<20, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(index < lit ? (tint ?? Palette.inkText) : Palette.inkText.opacity(0.1))
                            .frame(height: 14)
                    }
                }
                .help(window.map { ResetText.detail($0.resetAt) } ?? "")
            }
        }
    }

    private var lit: Int { Int(((window?.remaining ?? 0) / 5).rounded()) }

    private var tint: Color? {
        guard let remaining = window?.remaining else { return nil }
        return remaining < 10 ? Palette.alarm : remaining < 30 ? Palette.warn : nil
    }

}

/// The last 30 days as thin bars: today brightest, the six days before it a step dimmer, the rest dim. Moving the
/// pointer over the bars picks out one day and the line underneath shows that day's amount; leaving restores the totals.
private struct UsageBars: View {
    let series: UsageSeries
    @State private var hovered: Int?

    var body: some View {
        let peak = max(series.days.max() ?? 0, 0.000001)
        VStack(spacing: 8) {
            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(series.days.enumerated()), id: \.offset) { index, value in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Palette.inkText.opacity(opacity(index)))
                            .frame(maxWidth: .infinity)
                            .frame(height: max(2, 38 * value / peak))
                    }
                }
                .frame(width: geo.size.width, height: 38, alignment: .bottom)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        hovered = min(29, max(0, Int(point.x / max(geo.size.width, 1) * 30)))
                    case .ended:
                        hovered = nil
                    }
                }
            }
            .frame(height: 38)
            Group {
                if let hovered {
                    HStack(spacing: 8) {
                        Text(label(hovered)).foregroundStyle(Palette.inkMuted)
                        Text(series.text(series.days[hovered])).fontWeight(.semibold).monospacedDigit()
                        Spacer(minLength: 0)
                    }
                } else {
                    HStack {
                        total("今日", series.today)
                        Spacer()
                        total("7 天", series.week)
                        Spacer()
                        total("30 天", series.month)
                    }
                }
            }
            .font(.system(size: 11))
            .frame(height: 14)
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private func opacity(_ index: Int) -> Double {
        if let hovered { return index == hovered ? 1 : 0.16 }
        return index == 29 ? 1 : index >= 23 ? 0.55 : 0.22
    }

    private func total(_ label: String, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(Palette.inkMuted)
            Text(series.text(value)).fontWeight(.semibold).monospacedDigit()
        }
    }

    private func label(_ index: Int) -> String {
        if index == 29 { return "今天" }
        if index == 28 { return "昨天" }
        let day = Calendar.current.date(byAdding: .day, value: index - 29, to: Date())!
        return day.formatted(.dateTime.month().day().weekday(.abbreviated))
    }
}

/// One window on a stacked card, as wide as the card: 20 cells, neutral until it runs low. Used up, the row becomes a
/// red line ending in the time it comes back, still the width of the cells so its right edge meets the last cell.
private struct MiniRow: View {
    let window: CodexWindow?
    /// Only the 5-hour row names its reset time; a used-up 7-day row is just the line.
    let showsReset: Bool

    var body: some View {
        Group {
            if let window, window.exhausted {
                HStack(spacing: 8) {
                    Rectangle().fill(Palette.alarm.opacity(0.45)).frame(minWidth: 0, maxWidth: .infinity).frame(height: 1)
                    if showsReset {
                        Text("\(ResetText.short(window.resetAt)) 恢复").font(.system(size: 10.5)).monospacedDigit()
                            .foregroundStyle(Palette.alarm).fixedSize()
                    }
                }
            } else {
                let remaining = window?.remaining ?? 0
                let lit = Int((remaining / 5).rounded())
                let tint: Color = window == nil ? .primary : remaining < 10 ? Palette.alarm : remaining < 30 ? Palette.warn : .primary
                HStack(spacing: 2.5) {
                    ForEach(0..<20, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(index < lit ? tint.opacity(0.85) : Color.primary.opacity(0.1))
                            .frame(maxWidth: .infinity).frame(height: 7)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 10)
    }
}

/// A stacked card: its top edge tucks under the card above.
private struct BackCard: View {
    let card: CardModel
    let deep: Bool
    let onSwitch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.kind).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(card.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    if !isQuota {
                        Text(summary).font(.system(size: summaryIsNote ? 11.5 : 16, weight: summaryIsNote ? .regular : .semibold))
                            .monospacedDigit().foregroundStyle(summaryIsNote ? Color.secondary : Color.primary)
                            .lineLimit(1).fixedSize()
                    }
                    Button("切换", action: onSwitch)
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Palette.link)
                        .fixedSize()
                }
            }
            if case .quota(_, let five, let week, _) = card.body {
                if let week {
                    // Same order as the front card: 5 hours above 7 days. Exact numbers on hover.
                    VStack(spacing: 5) {
                        MiniRow(window: five, showsReset: true)
                        MiniRow(window: week, showsReset: false)
                    }
                    .help(quotaHelp(five: five, week: week))
                } else {
                    Text(card.note ?? "读取中").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(deep ? Palette.backDeep : Palette.back))
        .shadow(color: .black.opacity(0.07), radius: 8, y: 4)
    }

    private var isQuota: Bool { if case .quota = card.body { return true } else { return false } }

    private func quotaHelp(five: CodexWindow?, week: CodexWindow) -> String {
        let fiveText = five.map { "5 小时剩余 \(Int($0.remaining.rounded()))%，\(ResetText.detail($0.resetAt))" } ?? "5 小时 —"
        return "\(fiveText)\n7 天剩余 \(Int(week.remaining.rounded()))%，\(ResetText.detail(week.resetAt))"
    }

    private var summaryIsNote: Bool {
        if case .balance(_, let amount) = card.body { return amount == nil }
        return true
    }

    private var summary: String {
        if case .balance(_, let amount) = card.body { return amount ?? card.note ?? "—" }
        return ""
    }
}

/// The front card and the stack, in one list so a switch animates the cards into their new places.
private struct CardCase<Menu: View>: View {
    let cards: [CardModel]
    let activeID: UUID?
    let switchTo: (UUID) -> Void
    @ViewBuilder let menu: (UUID) -> Menu

    var body: some View {
        let ordered = cards.filter { $0.id == activeID } + cards.filter { $0.id != activeID }
        VStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, card in
                Group {
                    if card.id == activeID {
                        FrontCard(card: card)
                    } else {
                        BackCard(card: card, deep: index % 2 == 0) { switchTo(card.id) }
                            .padding(.top, index == 0 ? 0 : -10)
                    }
                }
                .zIndex(Double(ordered.count - index))
                .contextMenu { menu(card.id) }
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: ordered.map(\.id))
    }
}

/// The dashed slot at the bottom of the case.
private struct AddSlot<Label: View>: View {
    @ViewBuilder let label: Label

    var body: some View {
        label
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
            .contentShape(Rectangle())
    }
}

/// The result of the last action, shown briefly at the bottom.
private struct Toast: View {
    let message: String?
    @State private var shown: String?

    var body: some View {
        Group {
            if let shown {
                Text(shown)
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    .padding(.horizontal, 16).padding(.bottom, 80)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { self.shown = nil } }
            }
        }
        .task(id: message) {
            guard let message else { return }
            withAnimation(.easeOut(duration: 0.2)) { shown = message }
            try? await Task.sleep(for: .seconds(6))
            withAnimation(.easeIn(duration: 0.25)) { if shown == message { shown = nil } }
        }
    }
}

private struct CaseLayout<Cards: View, Footer: View>: View {
    @ViewBuilder let cards: Cards
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                cards
                    .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 24)
            }
            .scrollIndicators(.never)
            footer
                .padding(.horizontal, 16).padding(.bottom, 16).padding(.top, 4)
        }
    }
}

// MARK: Claude

private struct ClaudeCase: View {
    @Bindable var store = ClaudeStore.shared
    @State private var editing: ClaudeProvider?
    @State private var deleting: ClaudeProvider?

    private var cards: [CardModel] {
        store.providers.map { provider in
            let amount = store.balances[provider.id].map { Fmt.yuanDown($0.credit * provider.cnyPerUnit, 2) }
            return CardModel(id: provider.id, kind: "中转", title: provider.displayName,
                             body: .balance(host: provider.root?.host ?? "地址无效", amount: amount),
                             note: amount == nil ? store.errors[provider.id] : nil,
                             usage: UsageStore.shared.series(relay: provider.id, ratio: provider.cnyPerUnit))
        }
    }

    var body: some View {
        CaseLayout {
            if store.providers.isEmpty {
                Text("还没有中转。添加一个 Anthropic 兼容的地址和 Key。")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 80)
            } else {
                CardCase(cards: cards, activeID: store.activeID, switchTo: { store.switchTo($0) }) { id in
                    menu(id)
                }
            }
        } footer: {
            Button { editing = ClaudeProvider() } label: { AddSlot { Text("＋ 添加中转") } }.buttonStyle(.plain)
        }
        .sheet(item: $editing) { ClaudeProviderEditor(provider: $0) }
        .confirmationDialog("删除「\(deleting?.displayName ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除", role: .destructive) { if let deleting { store.delete(deleting.id) } }
        } message: { Text("只删除保存的地址和 Key，聊天记录不受影响。") }
    }

    @ViewBuilder private func menu(_ id: UUID) -> some View {
        if let provider = store.providers.first(where: { $0.id == id }) {
            let inUse = id == store.activeID
            if !inUse { Button("切换") { store.switchTo(id) } }
            Button("编辑…") { editing = provider }
            Button("刷新余额") { Task { await store.refresh(provider) } }
            Divider()
            Button("删除…", role: .destructive) { deleting = provider }.disabled(inUse)
        }
    }
}

// MARK: Codex

private struct CodexCase: View {
    @Bindable var store = CodexStore.shared
    @State private var editing: CodexProfile?
    @State private var renaming: CodexProfile?
    @State private var newName = ""
    @State private var deleting: CodexProfile?

    private var cards: [CardModel] {
        store.profiles.map { profile in
            switch profile.kind {
            case .official:
                let quota = store.quotas[profile.id]
                let credits = quota.flatMap { q -> String? in
                    if q.unlimitedCredits { return "无限" }
                    guard let c = q.credits, c > 0 else { return nil }
                    return c.formatted(.number.precision(.fractionLength(0)))
                }
                return CardModel(id: profile.id, kind: "ChatGPT", title: profile.displayName,
                                 body: .quota(plan: (quota?.plan ?? profile.plan)?.capitalized, five: quota?.fiveHour, week: quota?.week, credits: credits),
                                 note: store.errors[profile.id] ?? (quota == nil ? "读取中" : nil),
                                 usage: UsageStore.shared.series(account: profile.accountID))
            case .relay:
                let amount = store.balances[profile.id].map { Fmt.yuanDown($0.credit * profile.cnyPerUnit, 2) }
                return CardModel(id: profile.id, kind: "中转", title: profile.displayName,
                                 body: .balance(host: profile.root?.host ?? "地址无效", amount: amount),
                                 note: amount == nil ? store.errors[profile.id] : nil,
                                 usage: UsageStore.shared.series(relay: profile.id, ratio: profile.cnyPerUnit))
            }
        }
    }

    var body: some View {
        CaseLayout {
            VStack(spacing: 14) {
                if store.pendingLogin {
                    HStack {
                        Text("在 Codex 里登录另一个账号，完成后会出现在这里。").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("取消") { store.cancelLogin() }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.link)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.back))
                }
                if store.profiles.isEmpty && !store.pendingLogin {
                    Text("在 Codex 里登录 ChatGPT 账号后，它会自动出现在这里。")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    CardCase(cards: cards, activeID: store.activeID, switchTo: { store.switchTo($0) }) { id in
                        menu(id)
                    }
                }
            }
        } footer: {
            Menu {
                Button("登录另一个 ChatGPT 账号") { store.beginLogin() }.disabled(store.pendingLogin)
                Button("添加中转…") { editing = CodexProfile(kind: .relay) }
            } label: {
                AddSlot { Text("＋ 添加账号或中转") }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
        .sheet(item: $editing) { CodexRelayEditor(profile: $0) }
        .alert("重命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $newName)
            Button("保存") { if let renaming { store.rename(renaming.id, to: newName) } }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除「\(deleting?.displayName ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除", role: .destructive) { if let deleting { store.delete(deleting.id) } }
        } message: { Text("只删除保存的登录信息或 Key，聊天记录不受影响。") }
    }

    @ViewBuilder private func menu(_ id: UUID) -> some View {
        if let profile = store.profiles.first(where: { $0.id == id }) {
            let inUse = id == store.activeID
            if !inUse { Button("切换") { store.switchTo(id) } }
            if profile.kind == .relay { Button("编辑…") { editing = profile } }
            Button("重命名…") { newName = profile.name; renaming = profile }
            Button(profile.kind == .relay ? "刷新余额" : "刷新额度") { Task { await store.refresh(profile) } }
            Divider()
            Button("删除…", role: .destructive) { deleting = profile }.disabled(inUse)
        }
    }
}

// MARK: Settings

private struct SettingsSheet: View {
    @Bindable var prefs = Prefs.shared
    @Bindable var claude = ClaudeStore.shared
    @Bindable var codex = CodexStore.shared
    @State private var autoCheck = Updates.shared.updater.automaticallyChecksForUpdates
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "—")（\(info?["CFBundleVersion"] as? String ?? "—")）"
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("窗口始终置顶", isOn: $prefs.onTop)
                    Toggle("登录时打开", isOn: $prefs.launchAtLogin)
                } footer: {
                    Text("Codex 使用中转时经本应用转发，保持它运行。").font(.caption).foregroundStyle(.secondary)
                }
                Section("Claude") {
                    Toggle("切换后重启 Claude", isOn: $claude.restartClaude)
                    Toggle("同时用于命令行", isOn: $claude.syncCLI)
                        .help("写入 ~/.claude/settings.json，命令行里新开的会话也走这条线路。")
                }
                Section("Codex") {
                    Toggle("切换后重启 Codex", isOn: $codex.restartCodex)
                }
                Section("更新") {
                    Toggle("自动检查更新", isOn: $autoCheck)
                        .onChange(of: autoCheck) { _, on in Updates.shared.updater.automaticallyChecksForUpdates = on }
                    LabeledContent("当前版本") {
                        HStack {
                            Text(version).foregroundStyle(.secondary).monospacedDigit()
                            Button("检查更新") { Updates.shared.checkForUpdates(nil) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
                .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .frame(width: 380, height: 460)
    }
}

// MARK: Editors

/// Shared layout for the two relay editors.
private struct RelayForm: View {
    let title: String
    @Binding var name: String
    @Binding var baseURL: String
    @Binding var key: String
    @Binding var accessToken: String
    @Binding var ratio: Double
    let keySaved: Bool
    let accessSaved: Bool
    let valid: Bool
    let canSave: Bool
    let failed: Bool
    let save: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("名称", text: $name, prompt: Text("可选"))
                    TextField("地址", text: $baseURL, prompt: Text("https://example.com"))
                    SecureField("Key", text: $key, prompt: Text(keySaved ? "已保存，输入新的以替换" : "粘贴 API Key"))
                    SecureField("访问令牌", text: $accessToken, prompt: Text(accessSaved ? "已保存，输入新的以替换" : "可选"))
                        .help("new-api 中转（如 corecode）的系统访问令牌，在网站「个人设置 → 安全设置」生成。填了能显示近 30 天每天的花费；不填就从切号开始记录的那天起，按余额变化估算。")
                    LabeledContent("充值比例") {
                        HStack(spacing: 4) {
                            Text("¥").foregroundStyle(.secondary)
                            TextField("", value: $ratio, format: .number.precision(.fractionLength(0...4)))
                                .labelsHidden().frame(width: 56).multilineTextAlignment(.trailing)
                            Text("换 1 额度").foregroundStyle(.secondary)
                        }
                    }
                    .help("充多少人民币得到 1 个额度，用来把余额换算成人民币。")
                } header: { Text(title) } footer: {
                    if !baseURL.isEmpty && !valid {
                        Text("地址需要以 https:// 开头。").font(.caption).foregroundStyle(.red)
                    } else if failed {
                        Text("没能保存，检查一下本机文件权限。").font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .frame(width: 400, height: 350)
    }
}

struct ClaudeProviderEditor: View {
    @State var provider: ClaudeProvider
    @State private var key = ""
    @State private var accessToken = ""
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss
    private let store = ClaudeStore.shared

    private var isNew: Bool { !store.providers.contains { $0.id == provider.id } }
    private var keySaved: Bool { !isNew && store.hasKey(provider) }

    var body: some View {
        RelayForm(title: isNew ? "添加 Claude 中转" : "编辑 Claude 中转",
                  name: $provider.name, baseURL: $provider.baseURL, key: $key, accessToken: $accessToken, ratio: $provider.cnyPerUnit,
                  keySaved: keySaved, accessSaved: !isNew && Secrets.get(provider.accessAccount) != nil, valid: provider.root != nil,
                  canSave: provider.root != nil && provider.cnyPerUnit > 0 && (keySaved || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                  failed: failed) {
            if store.save(provider, key: key, accessToken: accessToken) { dismiss() } else { failed = true }
        }
    }
}

struct CodexRelayEditor: View {
    @State var profile: CodexProfile
    @State private var key = ""
    @State private var accessToken = ""
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss
    private let store = CodexStore.shared

    private var isNew: Bool { !store.profiles.contains { $0.id == profile.id } }
    private var keySaved: Bool { !isNew && store.storedKey(profile) }

    var body: some View {
        RelayForm(title: isNew ? "添加 Codex 中转" : "编辑 Codex 中转",
                  name: $profile.name, baseURL: $profile.baseURL, key: $key, accessToken: $accessToken, ratio: $profile.cnyPerUnit,
                  keySaved: keySaved, accessSaved: !isNew && Secrets.get(profile.accessAccount) != nil, valid: profile.root != nil,
                  canSave: profile.root != nil && profile.cnyPerUnit > 0 && (keySaved || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                  failed: failed) {
            if store.saveRelay(profile, key: key, accessToken: accessToken) { dismiss() } else { failed = true }
        }
    }
}
