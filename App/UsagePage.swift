import AppKit
import SwiftUI

/// 用量: what every line cost over today / 7 / 30 days, which models it went to and how the tokens split.
/// Double-clicking 30 天 turns it into 全部 (everything on record, weekly bars); a click goes back.
/// Money is in yuan throughout: relays by their own top-up ratio, Codex accounts' API-price estimate 1:1.
/// Models and tokens come from the local logs (Claude Code's session records, Codex's rollouts); a model's
/// amount is its share at list price of what the lines actually charged in that range.
struct UsagePage: View {
    enum Scope: String, CaseIterable, Identifiable { case all = "全部", claude = "Claude", codex = "Codex"; var id: Self { self } }
    enum Range: Int, CaseIterable, Identifiable {
        case all = 0, today = 1, week = 7, month = 30
        var id: Self { self }
        var label: String { self == .all ? "全部" : self == .today ? "今日" : "\(rawValue) 天" }
    }

    @State private var scope = Scope.all
    @State private var range = Range.today
    private let claude = ClaudeStore.shared
    private let codex = CodexStore.shared
    private let usage = UsageStore.shared

    /// One relay or account: its colour, yuan per day for every day on record, and the last 30 of them (oldest first).
    struct Line: Identifiable {
        let id: UUID
        let name: String
        let note: String
        let isCodex: Bool
        let all: [String: Double]
        let days: [Double]
        let color: Color

        func total(_ range: Range) -> Double {
            range == .all ? all.values.reduce(0, +) : days.suffix(range.rawValue).reduce(0, +)
        }
    }

    private var lines: [Line] {
        var out: [(UUID, String, String, Bool, [String: Double])] = []
        for provider in claude.providers {
            out.append((provider.id, provider.displayName, claude.quotas[provider.id] != nil ? "订阅" : "中转", false,
                        usage.daily(relay: provider.id, ratio: provider.cnyPerUnit)))
        }
        for profile in codex.profiles {
            switch profile.kind {
            case .official:
                out.append((profile.id, profile.displayName, "订阅", true, usage.daily(account: profile.accountID)))
            case .relay:
                out.append((profile.id, profile.displayName, "中转", true, usage.daily(relay: profile.id, ratio: profile.cnyPerUnit)))
            }
        }
        let today = Calendar.current.startOfDay(for: Date())
        let last30 = (0..<30).map { UsageStore.dayKey(Calendar.current.date(byAdding: .day, value: $0 - 29, to: today)!) }
        return out.enumerated().map { index, line in
            Line(id: line.0, name: line.1, note: line.2, isCodex: line.3, all: line.4,
                 days: last30.map { line.4[$0] ?? 0 }, color: UsageColors.line(index))
        }
    }

    /// "2026-05-13" → that local day.
    static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private var scoped: [Line] {
        lines.filter { scope == .all || (scope == .codex) == $0.isCodex }
    }

    /// The day keys in range, newest first (nil: every day).
    private var dayKeys: [String]? {
        guard range != .all else { return nil }
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<range.rawValue).map { UsageStore.dayKey(Calendar.current.date(byAdding: .day, value: -$0, to: today)!) }
    }

    private func total(_ line: Line) -> Double { line.total(range) }

    var body: some View {
        let lines = scoped
        ScrollView {
            VStack(spacing: 12) {
                // Every card keeps one height whatever the data, scope or range, so nothing on the page moves.
                SpendCard(lines: lines, range: range)
                // Under the card, each half of the row, every segment the same width: they never shift as the labels change.
                HStack(spacing: 10) {
                    Segments(items: Scope.allCases, selection: $scope) { $0.rawValue }
                    // 全部 lives in 30 天's place, so the switch stays three wide.
                    Segments(items: [Range.today, .week, .month],
                             selection: Binding(get: { range == .all ? .month : range }, set: { range = $0 }),
                             title: { $0 == .month && range == .all ? Range.all.label : $0.label },
                             hint: { $0 == .month ? (range == .all ? "单击回到 30 天" : "双击查看全部") : nil },
                             doubleClick: { if $0 == .month { withAnimation(.snappy(duration: 0.2)) { range = .all } } })
                }
                ModelCard(rows: modelRows(lines), range: range.label)
                TokenCard(tokens: tokens, range: range.label)
            }
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 20)
        }
        .scrollIndicators(.never)
        .task {
            await usage.refreshClaudeCode()
            await usage.refreshAccounts()
        }
    }

    // MARK: Models and tokens

    private func sum(_ days: ModelDays) -> [String: TokenDay] {
        var out: [String: TokenDay] = [:]
        for key in dayKeys ?? Array(days.keys) { for (model, t) in days[key] ?? [:] { out[model, default: TokenDay()] += t } }
        return out
    }

    private var claudeTokens: [String: TokenDay] { scope == .codex ? [:] : sum(usage.claudeModels) }

    private var codexTokens: [String: TokenDay] {
        guard scope != .claude else { return [:] }
        var out: [String: TokenDay] = [:]
        for days in usage.codexModels.values { for (model, t) in sum(days) { out[model, default: TokenDay()] += t } }
        return out
    }

    private var tokens: TokenDay { (Array(claudeTokens.values) + Array(codexTokens.values)).reduce(TokenDay(), +) }

    /// Each side's spend split over its models by their list-price share.
    private func modelRows(_ lines: [Line]) -> [(String, Double)] {
        func split(_ models: [String: TokenDay], spend: Double) -> [(String, Double)] {
            let listed = models.values.reduce(0) { $0 + $1.usd }
            guard listed > 0, spend > 0 else { return [] }
            return models.filter { $0.value.usd > 0 }.map { ($0.key, $0.value.usd / listed * spend) }
        }
        let claudeSpend = lines.filter { !$0.isCodex }.reduce(0) { $0 + total($1) }
        let codexSpend = lines.filter(\.isCodex).reduce(0) { $0 + total($1) }
        return (split(claudeTokens, spend: claudeSpend) + split(codexTokens, spend: codexSpend)).sorted { $0.1 > $1.1 }
    }
}

// MARK: Pieces

enum UsageColors {
    private static let all: [Color] = [
        Color(light: 0x2F6BFF, dark: 0x5B8CFF), Color(light: 0xE8915B, dark: 0xF0A06A), Color(light: 0x46A07A, dark: 0x5BBE90),
        Color(light: 0x9B7BE0, dark: 0xB095F0), Color(light: 0xD9608F, dark: 0xE97AA5), Color(light: 0x2E9FB0, dark: 0x4EC0CF),
    ]
    static func line(_ index: Int) -> Color { all[index % all.count] }
}

enum TokenFmt {
    static func count(_ n: Double) -> String {
        if n >= 100_000_000 { return String(format: "%.2f 亿", n / 100_000_000) }
        if n >= 10_000 { return (n / 10_000).formatted(.number.precision(.fractionLength(0)).grouping(.automatic)) + " 万" }
        return n.formatted(.number.precision(.fractionLength(0)))
    }
}

/// A small capsule switch, in the window's own greys.
private struct Segments<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String
    var hint: (Item) -> String? = { _ in nil }
    var doubleClick: ((Item) -> Void)?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let on = item == selection
                Button {
                    // A Button swallows a double-tap gesture laid over it; the click's own count tells instead, so a
                    // single click is never held back waiting for a second.
                    if let doubleClick, (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                        doubleClick(item)
                    } else {
                        withAnimation(.snappy(duration: 0.2)) { selection = item }
                    }
                } label: {
                    Text(title(item))
                        .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(on ? Palette.back : Color.clear).shadow(color: .black.opacity(on ? 0.08 : 0), radius: 1, y: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(hint(item) ?? "")
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

/// Ring of parts, each a fraction of the whole, with a small gap between them.
private struct Ring: View {
    let parts: [(Double, Color)]
    var width: CGFloat = 11

    var body: some View {
        let total = max(parts.reduce(0) { $0 + $1.0 }, 0.000001)
        let gap = parts.filter { $0.0 > 0 }.count > 1 ? 0.006 : 0
        ZStack {
            Circle().stroke(Color.primary.opacity(0.06), lineWidth: width)
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                let start = parts[..<index].reduce(0) { $0 + $1.0 } / total
                let end = start + part.0 / total
                if part.0 > 0 {
                    Circle()
                        .trim(from: start, to: max(start + 0.002, end - gap))
                        .stroke(part.1, style: StrokeStyle(lineWidth: width, lineCap: .butt))
                }
            }
        }
        .rotationEffect(.degrees(-90))
        .padding(width / 2)
    }
}

/// Ink card: the range's total, a ring and legend by line, and bars stacked by line — 30 days, or for 全部 every
/// week on record (every month past 60 weeks). Pointing at a bar turns the top of the card into that day or week:
/// its total, Claude and Codex apart, and the ring and legend for it.
private struct SpendCard: View {
    let lines: [UsagePage.Line]
    let range: UsagePage.Range
    @State private var hovered: Int?

    /// The legend always has room for this many rows; more lines fold their tail into one 其他 row.
    static let legendRows = 5

    struct Bucket {
        /// For the title when pointed at.
        let label: String
        /// For the axis.
        let short: String
        /// Per line, in the lines' order.
        let values: [Double]
        let inRange: Bool
    }

    /// The first day any line spent something on.
    private var firstDay: Date? {
        lines.flatMap { $0.all.filter { $0.value > 0 }.keys }.min().flatMap(UsagePage.date)
    }

    private var monthly: Bool {
        guard range == .all, let first = firstDay else { return false }
        return (Calendar.current.dateComponents([.day], from: first, to: Date()).day ?? 0) > 60 * 7
    }

    private var buckets: [Bucket] {
        let cal = Calendar.current
        guard range == .all else {
            return (0..<30).map { day in
                Bucket(label: Self.dayLabel(day), short: Self.dayLabel(day), values: lines.map { $0.days[day] },
                       inRange: day >= 30 - range.rawValue)
            }
        }
        let today = cal.startOfDay(for: Date())
        let unit: Calendar.Component = monthly ? .month : .weekOfYear
        func next(_ d: Date) -> Date { monthly ? cal.date(byAdding: .month, value: 1, to: d)! : cal.date(byAdding: .day, value: 7, to: d)! }
        var start = cal.dateInterval(of: unit, for: firstDay ?? today)!.start
        var out: [Bucket] = []
        while start <= today {
            let end = next(start)
            let lo = UsageStore.dayKey(start), hi = UsageStore.dayKey(end)
            let values = lines.map { line in line.all.reduce(0) { $1.key >= lo && $1.key < hi ? $0 + $1.value : $0 } }
            let current = end > today
            let label: String
            if monthly {
                label = current ? "本月" : start.formatted(.dateTime.year().month())
            } else if current {
                label = "本周"
            } else {
                let last = cal.date(byAdding: .day, value: -1, to: end)!
                let sameMonth = cal.component(.month, from: start) == cal.component(.month, from: last)
                label = start.formatted(.dateTime.month().day()) + "–" + (sameMonth ? "\(cal.component(.day, from: last))日" : last.formatted(.dateTime.month().day()))
            }
            out.append(Bucket(label: label, short: current ? label : start.formatted(monthly ? .dateTime.month() : .dateTime.month().day()),
                              values: values, inRange: true))
            start = end
        }
        return out
    }

    private var title: String {
        switch range {
        case .today: "今日花费"
        case .all: firstDay.map { "累计花费 · \($0.formatted(.dateTime.year().month().day())) 起" } ?? "累计花费"
        default: "\(range.rawValue) 天花费"
        }
    }

    var body: some View {
        let buckets = buckets
        let picked = hovered.flatMap { $0 < buckets.count ? $0 : nil }
        // Only lines that spent something in what is shown (the range, or the pointed-at bar).
        let shown = lines.enumerated().map { index, line in
            (line, picked.map { buckets[$0].values[index] } ?? line.total(range))
        }.filter { $0.1 > 0 }
        let total = shown.reduce(0) { $0 + $1.1 }
        // The ring and legend keep one height: if the card grew or shrank under the pointer, the bars would move away
        // from it and back, over and over; and the switches under the card would move away from a click.
        let rows = Self.legendRows
        let legendHeight = CGFloat(rows) * 16 + CGFloat(rows - 1) * 7
        let legend: [(name: String, note: String, color: Color, value: Double, id: String)] = {
            let all = shown.map { (name: $0.0.name, note: $0.0.note, color: $0.0.color, value: $0.1, id: $0.0.id.uuidString) }
            guard all.count > rows else { return all }
            let rest = all.dropFirst(rows - 1)
            return Array(all.prefix(rows - 1)) + [(name: "其他 \(rest.count) 个", note: "", color: Palette.inkMuted,
                                                    value: rest.reduce(0) { $0 + $1.value }, id: "rest")]
        }()
        VStack(alignment: .leading, spacing: 0) {
            Text(picked.map { "\(buckets[$0].label) 花费" } ?? title)
                .font(.system(size: 11)).foregroundStyle(Palette.inkMuted)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("¥").font(.system(size: 16, weight: .medium)).foregroundStyle(Palette.inkMuted)
                Text(total.formatted(.number.precision(.fractionLength(2)).grouping(.automatic)))
                    .font(.system(size: 30, weight: .semibold)).kerning(-0.6).monospacedDigit()
            }
            .padding(.top, 2)
            Text(subline(shown: shown).isEmpty ? " " : subline(shown: shown))
                .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Palette.inkMuted).padding(.top, 2)
            HStack(spacing: 16) {
                Ring(parts: shown.map { ($0.1, $0.0.color) }).frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 7) {
                    if shown.isEmpty {
                        Text(picked == nil ? "这段时间没有花费" : range != .all ? "这天没有花费" : monthly ? "这个月没有花费" : "这周没有花费")
                            .font(.system(size: 12)).foregroundStyle(Palette.inkMuted)
                    }
                    ForEach(legend, id: \.id) { row in
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 2).fill(row.color).frame(width: 7, height: 7)
                            Text(row.name).lineLimit(1).truncationMode(.middle)
                            Text(row.note).font(.system(size: 10.5)).foregroundStyle(Palette.inkMuted).fixedSize()
                            Spacer(minLength: 4)
                            Text(Fmt.yuan(row.value, 2)).fontWeight(.semibold).monospacedDigit().fixedSize()
                        }
                        .frame(height: 16)
                    }
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, minHeight: legendHeight, maxHeight: legendHeight, alignment: .leading)
                .clipped()
            }
            .padding(.top, 14)
            bars(buckets, picked: picked)
        }
        .foregroundStyle(Palette.inkText)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.ink))
        .onChange(of: range) { hovered = nil }
    }

    private func bars(_ buckets: [Bucket], picked: Int?) -> some View {
        let sums = buckets.map { $0.values.reduce(0, +) }
        let peak = max(sums.max() ?? 0, 0.000001)
        let count = buckets.count
        return VStack(spacing: 7) {
            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: count > 45 ? 1.5 : 2.5) {
                    ForEach(0..<count, id: \.self) { index in
                        VStack(spacing: 0) {
                            ForEach(Array(lines.enumerated()).reversed(), id: \.element.id) { line, item in
                                let value = buckets[index].values[line]
                                if value > 0 {
                                    Rectangle().fill(item.color).frame(height: max(0.5, 60 * value / peak))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 2, alignment: .bottom)
                        .background(sums[index] == 0 ? Palette.inkText.opacity(0.12) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
                        .opacity(picked.map { $0 == index ? 1 : 0.3 } ?? (buckets[index].inRange ? 1 : 0.35))
                    }
                }
                .frame(width: geo.size.width, height: 60, alignment: .bottom)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hovered = min(count - 1, max(0, Int(point.x / max(geo.size.width, 1) * CGFloat(count))))
                    case .ended: hovered = nil
                    }
                }
            }
            .frame(height: 60)
            HStack {
                if count >= 3 {
                    Text(buckets[0].short); Spacer(); Text(buckets[count / 2].short); Spacer()
                } else {
                    Spacer()
                }
                Text(range == .all ? buckets[count - 1].short : "今天")
            }
            .font(.system(size: 10.5)).foregroundStyle(Palette.inkMuted)
        }
        .padding(.top, 16)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    /// Claude and Codex apart (the sides in view), for the range or the pointed-at bar.
    private func subline(shown: [(UsagePage.Line, Double)]) -> String {
        let claude = shown.filter { !$0.0.isCodex }.reduce(0) { $0 + $1.1 }
        let codex = shown.filter { $0.0.isCodex }.reduce(0) { $0 + $1.1 }
        let sides = [(lines.contains { !$0.isCodex }, "Claude \(Fmt.yuan(claude, 2))"),
                     (lines.contains { $0.isCodex }, "Codex \(Fmt.yuan(codex, 2))")]
        return sides.filter(\.0).map(\.1).joined(separator: " · ")
    }

    private static func dayLabel(_ day: Int) -> String {
        if day == 29 { return "今天" }
        if day == 28 { return "昨天" }
        let date = Calendar.current.date(byAdding: .day, value: day - 29, to: Date())!
        return date.formatted(.dateTime.month().day().weekday(.abbreviated))
    }
}

private struct PlainCard<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)
            content
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.back))
    }
}

/// Top three models by amount, the rest folded into one row. Always four rows tall: missing rows keep their space
/// and an empty range says so in the middle, so the card never changes height.
private struct ModelCard: View {
    let rows: [(String, Double)]
    let range: String
    static let slots = 4

    static func percent(_ share: Double) -> String {
        share > 0 && share < 0.005 ? "<1%" : "\(Int((share * 100).rounded()))%"
    }

    var body: some View {
        let total = max(rows.reduce(0) { $0 + $1.1 }, 0.000001)
        let shown: [(String, Double)] = rows.count > Self.slots
            ? Array(rows.prefix(Self.slots - 1)) + [("其他 \(rows.count - Self.slots + 1) 个", rows.dropFirst(Self.slots - 1).reduce(0) { $0 + $1.1 })]
            : rows
        PlainCard(title: "模型", detail: range) {
            VStack(spacing: 0) {
                ForEach(0..<Self.slots, id: \.self) { index in
                    let row = index < shown.count ? shown[index] : ("—", 0)
                    let present = index < shown.count
                    if index > 0 { Divider().opacity(present ? 0.6 : 0) }
                    VStack(spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.0).font(.system(size: 12.5)).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(Fmt.yuan(row.1, 2)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                            Text(Self.percent(row.1 / total)).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                                .frame(minWidth: 30, alignment: .trailing)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.07))
                                Capsule().fill(Color.primary.opacity(0.8)).frame(width: geo.size.width * row.1 / total)
                            }
                        }
                        .frame(height: 4)
                    }
                    .padding(.vertical, 7)
                    .opacity(present ? 1 : 0)
                }
            }
            .overlay {
                if shown.isEmpty {
                    Text("没有记录").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Ring of the four kinds of tokens, the cache hit rate in the middle.
private struct TokenCard: View {
    let tokens: TokenDay
    let range: String

    var body: some View {
        let kinds: [(String, Double, Color)] = [
            ("缓存读取", tokens.cacheRead, UsageColors.line(0)), ("缓存写入", tokens.cacheWrite, UsageColors.line(1)),
            ("输出", tokens.output, UsageColors.line(2)), ("输入", tokens.input, UsageColors.line(3)),
        ]
        let all = kinds.reduce(0) { $0 + $1.1 }
        let prompt = tokens.cacheRead + tokens.cacheWrite + tokens.input
        PlainCard(title: "Token", detail: all > 0 ? "\(range) · \(TokenFmt.count(all))" : range) {
            // With nothing on record the ring stays, empty, so the card keeps its height.
            HStack(spacing: 16) {
                ZStack {
                    Ring(parts: kinds.map { ($0.1, $0.2) }, width: 10)
                    VStack(spacing: 1) {
                        Text(prompt > 0 && all > 0 ? "\(Int((tokens.cacheRead / prompt * 100).rounded()))%" : "—")
                            .font(.system(size: 18, weight: .semibold)).monospacedDigit()
                        Text("缓存命中").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(kinds, id: \.0) { kind in
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 2).fill(kind.2).frame(width: 7, height: 7)
                            Text(kind.0)
                            Spacer(minLength: 4)
                            Text(TokenFmt.count(kind.1)).fontWeight(.semibold).monospacedDigit()
                        }
                    }
                }
                .font(.system(size: 12))
            }
            .padding(.top, 6)
        }
    }
}
