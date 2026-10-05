import Foundation
import SwiftUI
import Charts

// The journal: tags on a day, period days and rest mode, and what the tags show.
// Every change goes through the shared brain (`journalApply` over FFI), so the file
// next to the database has one writer.

enum JournalStore {
    /// Apply one journal operation. Returns the new journal, or nil on an error.
    @discardableResult
    static func apply(_ op: [String: Any]) -> JournalData? {
        guard let data = try? JSONSerialization.data(withJSONObject: op),
              let text = String(data: data, encoding: .utf8) else { return nil }
        do {
            let json = try journalApply(dbPath: DB.url.path, opJson: text)
            return try JSONDecoder().decode(JournalData.self, from: Data(json.utf8))
        } catch {
            dlog("journal", "operation failed: \(error)")
            return nil
        }
    }

    static func load() -> JournalData {
        let json = journalJson(dbPath: DB.url.path)
        return (try? JSONDecoder().decode(JournalData.self, from: Data(json.utf8))) ?? JournalData()
    }
}

/// The tags the app offers. The wearer can add others.
enum TagCatalog {
    static let common: [(tag: String, icon: String)] = [
        ("alcohol", "wineglass"), ("caffeine", "cup.and.saucer"), ("late meal", "fork.knife"),
        ("stress", "bolt"), ("sick", "facemask"), ("travel", "airplane"),
        ("sauna", "flame"), ("meditation", "figure.mind.and.body"), ("breathing", "wind"),
        ("nap", "bed.double"), ("late screen", "iphone"), ("medication", "pills"),
    ]
    static func icon(_ tag: String) -> String {
        common.first { $0.tag == tag }?.icon ?? "tag"
    }
    static func title(_ tag: String) -> String {
        tag.prefix(1).uppercased() + tag.dropFirst()
    }
}

/// The row of tags under a day's title, with the button to change them.
struct DayTagsRow: View {
    let s: Summary
    let day: String
    var body: some View {
        let tags = s.journal?.value?.tags(on: day) ?? []
        NavigationLink(value: Route.tags(day)) {
            HStack(spacing: 8) {
                if tags.isEmpty {
                    Label("Add Tags", systemImage: "tag")
                        .font(.subheadline.weight(.medium))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(tags) { TagChip(tag: $0.tag) }
                        }
                    }
                    .allowsHitTesting(false)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .card(padding: 12)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(tags.isEmpty ? "Add tags" : "Tags: \(tags.map(\.tag).joined(separator: ", "))")
        .accessibilityHint("Opens the tags of this day")
    }
}

struct TagChip: View {
    let tag: String
    var selected = true
    var body: some View {
        Label(TagCatalog.title(tag), systemImage: TagCatalog.icon(tag))
            .font(.footnote.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(selected ? Theme.journal : .secondary)
            .background((selected ? Theme.journal : Color.secondary).opacity(0.14), in: Capsule())
    }
}

/// Add and remove the tags of one day.
struct TagsView: View {
    let day: String
    let onChanged: () -> Void
    @State private var journal = JournalStore.load()
    @State private var custom = ""
    @FocusState private var typing: Bool

    private var mine: [JournalTag] { journal.tags(on: day) }
    /// The common tags first, then the wearer's own tags from other days.
    private var choices: [String] {
        let known = TagCatalog.common.map(\.tag)
        let own = Set(journal.tags.map(\.tag)).subtracting(known).sorted()
        return known + own
    }

    var body: some View {
        List {
            Section {
                FlowLayout(spacing: 8) {
                    ForEach(choices, id: \.self) { tag in
                        let on = mine.contains { $0.tag == tag }
                        Button { toggle(tag) } label: { TagChip(tag: tag, selected: on) }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text(Fmt.dayTitle(day))
            } footer: {
                Text("A tag belongs to the day. The app compares the night after a tagged day with your other nights.")
            }
            Section("Your own tag") {
                HStack {
                    TextField("For example: cold shower", text: $custom)
                        .textInputAutocapitalization(.never)
                        .focused($typing)
                        .submitLabel(.done)
                        .onSubmit(addCustom)
                    Button("Add", action: addCustom)
                        .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: mine.count)
    }

    private func toggle(_ tag: String) {
        let op: [String: Any]
        if let existing = mine.first(where: { $0.tag == tag }) {
            op = ["op": "remove_tag", "id": existing.id]
        } else {
            op = ["op": "add_tag", "day": day, "tag": tag]
        }
        if let next = JournalStore.apply(op) {
            withAnimation(Motion.snappy) { journal = next }
            onChanged()
        }
    }

    private func addCustom() {
        let tag = custom.trimmingCharacters(in: .whitespaces).lowercased()
        guard !tag.isEmpty else { return }
        if !mine.contains(where: { $0.tag == tag }) { toggle(tag) }
        custom = ""
        typing = false
    }
}

/// Lines of chips that wrap.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                                           proposal: ProposedViewSize(item.size))
            }
        }
    }

    private struct Row {
        var y: CGFloat
        var height: CGFloat = 0
        var width: CGFloat = 0
        var items: [(index: Int, x: CGFloat, size: CGSize)] = []
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row(y: 0)]
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                rows.append(Row(y: row.y + row.height + spacing))
                row = rows[rows.count - 1]
            }
            let x = row.items.isEmpty ? 0 : row.width + spacing
            row.items.append((index, x, size))
            row.width = x + size.width
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// What the tags show: for each tag, the night after it against the other nights.
struct TagInsightsView: View {
    let s: Summary
    var body: some View {
        let insights = (s.correlations?.value?.tags ?? []).sorted { $0.nights > $1.nights }
        let need = s.correlations?.value?.min_nights ?? 3
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if insights.isEmpty {
                    ContentUnavailableView("No Tags Yet", systemImage: "tag",
                                           description: Text("Add tags to your days. After \(need) nights with the same tag, the app shows what changes in the night after it."))
                        .padding(.top, 40)
                }
                ForEach(insights) { insight in
                    VStack(alignment: .leading, spacing: 12) {
                        CardHeader(title: TagCatalog.title(insight.tag), icon: TagCatalog.icon(insight.tag),
                                   tint: Theme.journal, detail: "\(insight.nights) night\(insight.nights == 1 ? "" : "s")")
                        if !insight.ready {
                            Text("\(need - insight.nights) more night\(need - insight.nights == 1 ? "" : "s") with this tag for a first result.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else if insight.found.isEmpty {
                            Text("No clear difference in the nights after this tag.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(insight.found.enumerated()), id: \.element.id) { i, effect in
                                if i > 0 { Divider() }
                                EffectRow(effect: effect)
                            }
                        }
                    }
                    .card()
                }
                if !insights.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("How to read this").font(.headline)
                        Text("Each row compares the nights after a day with the tag against all your other nights. A result shows only when the difference is larger than the usual change from night to night. It shows that two things occur together. It does not show the cause.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .card()
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Tags and Insights")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct EffectRow: View {
    let effect: TagEffect
    private func text(_ v: Double) -> String {
        if effect.unit == "min" { return Fmt.minutesText(abs(v)) }
        let shown = effect.metric == "temp_dev" ? Units.current.temperatureDelta(v) : v
        let unit = effect.metric == "temp_dev" ? Units.current.temperatureUnit : effect.unit
        let decimals = abs(shown) < 10 && shown != shown.rounded() ? 1 : 0
        return "\(Fmt.number(shown, decimals: decimals))\(unit.isEmpty ? "" : " \(unit)")"
    }
    var body: some View {
        let good = (effect.delta > 0) == effect.goodWhenPositive
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(effect.name).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(effect.delta > 0 ? "+" : "−")\(text(abs(effect.delta)))")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(good ? Theme.good : Theme.alert)
            }
            Text("\(text(effect.with)) after the tag, \(text(effect.without)) on other nights"
                 + (effect.strength == "weak" ? " · small difference" : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The cycle estimate and the list of period days.
struct CycleView: View {
    let s: Summary
    let onChanged: () -> Void
    @State private var journal = JournalStore.load()
    @State private var newDay = Date()

    var body: some View {
        List {
            if let c = s.cycle?.value {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(c.phaseTitle).font(.title3.weight(.semibold))
                        Text("Day \(c.cycle_day) of about \(Int(c.mean_cycle_days.rounded()))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    LabeledContent("Next period", value: "\(Fmt.monthDay(c.next_period)), \(Fmt.relativeDays(c.days_to_next_period))")
                    LabeledContent("Fertile days", value: "\(Fmt.monthDay(c.fertile_start)) – \(Fmt.monthDay(c.fertile_end))")
                    LabeledContent(c.ovulation_confirmed ? "Ovulation (from temperature)" : "Ovulation (estimate)",
                                   value: Fmt.monthDay(c.ovulation))
                } header: {
                    Text("This cycle")
                } footer: {
                    Text(c.cycles_used > 0
                         ? "From your last \(c.cycles_used) cycle\(c.cycles_used == 1 ? "" : "s") and your night temperature. This is an estimate. Do not use it for contraception."
                         : "From a cycle of 28 days until you log more periods. This is an estimate. Do not use it for contraception.")
                }
            }
            Section {
                DatePicker("First day", selection: $newDay, in: ...Date(), displayedComponents: .date)
                Button("Add Period") {
                    change(["op": "add_period", "day": NotificationRules.localDay(newDay)])
                }
            } header: {
                Text("Log a period")
            }
            if !journal.periods.isEmpty {
                Section("Logged periods") {
                    ForEach(journal.periods.sorted(by: >), id: \.self) { day in
                        Text(Fmt.dayTitle(day))
                    }
                    .onDelete { offsets in
                        let sorted = journal.periods.sorted(by: >)
                        for i in offsets { change(["op": "remove_period", "day": sorted[i]]) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Cycle")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func change(_ op: [String: Any]) {
        if let next = JournalStore.apply(op) {
            journal = next
            onChanged()
        }
    }
}
