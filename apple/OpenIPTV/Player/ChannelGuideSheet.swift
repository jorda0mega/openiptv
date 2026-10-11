import SwiftUI

#if os(iOS)
/// One channel's schedule over the player: earlier shows the provider
/// recorded play from their start, the one on now can be watched live or
/// started over, and what's next is listed. Opens at what's on now.
struct ChannelGuideSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let channel: LiveChannel
    /// The recording playing now, if any (marked in the list).
    let playing: Programme?
    let onWatch: (Programme) -> Void
    let onLive: () -> Void

    @State private var programmes: [Programme]?

    private var now: Int64 { Int64(Date().timeIntervalSince1970) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(days, id: \.day) { day in
                        Section(Self.title(of: day.day)) {
                            ForEach(day.programmes, id: \.start) { programme in
                                row(programme).id(programme.start)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .task(id: programmes?.count) {
                    guard let current = programmes?.first(where: { $0.stop > now }) else { return }
                    try? await Task.sleep(for: .milliseconds(60))
                    // A little of what came before shows above it.
                    proxy.scrollTo(current.start, anchor: UnitPoint(x: 0.5, y: 0.2))
                }
            }
            .overlay {
                if programmes == nil {
                    ProgressView()
                } else if programmes?.isEmpty == true {
                    ContentUnavailableView("No guide for this channel", systemImage: "calendar.badge.exclamationmark",
                                           description: Text("The provider doesn't list its programmes."))
                }
            }
            .navigationTitle(channel.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        let all = await model.schedule(for: channel)
        // Earlier shows only as far back as they can be watched (or a few
        // hours, for context, when nothing is recorded).
        let from = now - Int64(channel.archiveDays.map { $0 * 86400 } ?? 3 * 3600)
        var seen = Set<Int64>()
        programmes = all.filter { $0.stop > from && seen.insert($0.start).inserted }
    }

    private var days: [(day: Date, programmes: [Programme])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: programmes ?? []) {
            calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0.start)))
        }
        return groups.keys.sorted().map { ($0, groups[$0] ?? []) }
    }

    /// Recorded and still kept by the provider.
    private func canWatch(_ programme: Programme) -> Bool {
        guard let days = channel.archiveDays, programme.start < now else { return false }
        if let archived = programme.archived { return archived || programme.stop > now }
        return programme.start >= now - Int64(days) * 86400
    }

    @ViewBuilder private func row(_ programme: Programme) -> some View {
        let airing = programme.start <= now && now < programme.stop
        let past = programme.stop <= now
        let watchable = canWatch(programme)
        let isPlaying = playing == programme
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(programme.start.clock)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                Text(programme.title)
                    .font(.body.weight(airing ? .semibold : .regular))
                    .foregroundStyle(past && !watchable ? .secondary : .primary)
                    .lineLimit(2)
                if airing {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 7, height: 7)
                        Text("On now · until \(programme.stop.clock)").font(.caption).foregroundStyle(.secondary)
                    }
                    ProgressView(value: programme.progress()).tint(.red)
                } else if isPlaying {
                    Text("Playing").font(.caption).foregroundStyle(.tint)
                }
            }
            Spacer(minLength: 0)
            if airing, watchable {
                Button("Start over") { pick(programme) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if past, watchable {
                Image(systemName: isPlaying ? "play.circle" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if airing { live() } else if past, watchable { pick(programme) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(airing || (past && watchable) ? .isButton : [])
        .accessibilityHint(airing ? "Watches live" : past && watchable ? "Plays from the start" : "")
        .accessibilityAction(named: "Start over") {
            if watchable { pick(programme) }
        }
    }

    private func pick(_ programme: Programme) {
        dismiss()
        onWatch(programme)
    }

    private func live() {
        dismiss()
        if playing != nil { onLive() }
    }

    private static func title(of day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }
}
#endif
