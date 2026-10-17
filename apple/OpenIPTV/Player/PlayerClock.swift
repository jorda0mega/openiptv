import SwiftUI

/// The play position and the point being chosen on the bar, drawn only by
/// the views that show them (the bar and its times, Skip Intro, the still
/// while choosing): the clock's four ticks a second redraw those, not the
/// whole player. Regression: they redrew the whole player, with every
/// view in it (20 times in 5 s of playing).
@Observable
@MainActor
final class PlayerClock {
    var position: Double = 0
    /// The point being chosen on the bar (nil: none).
    var scrubbing: Double?
    #if DEBUG
    /// UI tests: "72.4 playing".
    var readout = ""
    /// UI tests: the stream's own second (its clock, before `offset`).
    var streamReadout = ""
    #endif

    /// In the marked intro, until a second before its end, and not while
    /// a point is being chosen: Skip Intro shows.
    static func inIntro(_ position: Double, scrubbing: Double?, intro: ClosedRange<Double>?) -> Bool {
        guard let intro, scrubbing == nil else { return false }
        return position >= intro.lowerBound && position < intro.upperBound - 1
    }

    /// "07:48" under an hour, "1:52:07" over, as Apple's player writes it.
    nonisolated static func tvTime(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// iPhone, as the Apple TV app writes it: "0:00:03" when the film runs
    /// an hour or more, "4:05" otherwise.
    nonisolated static func phoneTime(_ seconds: Double, total: Double) -> String {
        let s = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Its content while the clock is in the marked intro (Skip Intro); the
/// player says when else it may show (`allowed`).
struct DuringIntro<Content: View>: View {
    let clock: PlayerClock
    let intro: ClosedRange<Double>?
    let allowed: Bool
    @ViewBuilder var content: Content

    var body: some View {
        if allowed, PlayerClock.inIntro(clock.position, scrubbing: clock.scrubbing, intro: intro) { content }
    }
}

/// Choosing where to jump: the still for that moment, full-screen, until
/// the player has the frame itself.
struct StillWhileChoosing: View {
    let clock: PlayerClock
    let thumbnails: PreviewThumbnails?
    /// The second the player's own picture shows (with `offset`).
    let previewShown: Double?
    let offset: Double

    var body: some View {
        if let still {
            Image(uiImage: still)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
    }

    private var still: UIImage? {
        guard let target = clock.scrubbing, let thumbnails else { return nil }
        if let shown = previewShown, abs(shown - (target - offset)) < 2 { return nil }
        return thumbnails.image(near: target)
    }
}

#if os(iOS)
/// The iPhone bar: the times either side and the scrubber.
struct PhoneClockBar: View {
    let clock: PlayerClock
    let total: Double
    @Binding var speedLabel: String?
    let onChanged: (Double) -> Void
    let onCommit: (Double) -> Void

    var body: some View {
        let at = clock.scrubbing ?? clock.position
        TimeBar(leading: PlayerClock.phoneTime(at, total: total),
                trailing: speedLabel ?? "−" + PlayerClock.phoneTime(max(0, total - at), total: total)) {
            Scrubber(position: clock.position, total: max(total, 1),
                     scrubbing: Binding(get: { clock.scrubbing }, set: { clock.scrubbing = $0 }),
                     speedLabel: $speedLabel, onChanged: onChanged, onCommit: onCommit)
        }
    }
}
#endif

#if os(tvOS)
/// The Apple TV bar, from the clock.
struct TVClockedBar: View {
    let clock: PlayerClock
    let total: Double
    /// Holding left or right: which way it skims.
    let holdDirection: Double?
    let paused: Bool

    var body: some View {
        let at = clock.scrubbing ?? clock.position
        let state: TVTransportBar.State = if let holdDirection {
            holdDirection > 0 ? .forward : .backward
        } else if paused, clock.scrubbing == nil {
            .paused
        } else {
            .playing
        }
        TVTransportBar(fraction: at / max(total, 1), time: PlayerClock.tvTime(at),
                       remaining: "-" + PlayerClock.tvTime(max(0, total - at)), state: state)
    }
}
#endif

#if DEBUG
/// UI tests: the player's second and whether it plays ("72.4 playing").
struct ClockReadout: View {
    let clock: PlayerClock

    var body: some View {
        Text(clock.readout)
            .font(.caption2)
            .lineLimit(1)
            .frame(width: 1, height: 1)
            .opacity(0.02)
            .accessibilityLabel(clock.readout)
            .accessibilityIdentifier("debug-position")
        Text(clock.streamReadout)
            .font(.caption2)
            .frame(width: 1, height: 1)
            .opacity(0.02)
            .accessibilityLabel(clock.streamReadout)
            .accessibilityIdentifier("debug-stream-time")
    }
}
#endif
