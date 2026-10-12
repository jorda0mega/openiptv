import SwiftUI

#if os(iOS)
/// A seek bar that works like the iPhone's own players: drag along it at
/// full speed, slide the finger down for half, quarter and fine speed
/// (second by second even on a two-hour film), or tap to jump. Reports
/// every move so the picture can follow, and the final position on release.
struct Scrubber: View {
    let position: Double
    let total: Double
    @Binding var scrubbing: Double?
    /// "Half-speed scrubbing" etc. while the finger is below the bar.
    @Binding var speedLabel: String?
    var onChanged: (Double) -> Void
    var onCommit: (Double) -> Void

    @State private var value: Double = 0
    @State private var lastX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let shown = scrubbing ?? position
            let fraction = total > 0 ? min(max(shown / total, 0), 1) : 0
            let active = scrubbing != nil
            // The Apple TV app's: a thick capsule with no knob, the part
            // played in white; it grows while a finger is on it.
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.35))
                Rectangle().fill(.white.opacity(0.92)).frame(width: width * fraction)
            }
            .frame(height: active ? 14 : 8)
            .clipShape(Capsule())
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: active)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if lastX == nil {
                            // Touching away from where it's at jumps there first.
                            let thumbX = width * fraction
                            value = abs(drag.startLocation.x - thumbX) < 30
                                ? shown
                                : min(max(Double(drag.startLocation.x / width) * total, 0), total)
                            lastX = drag.startLocation.x
                        }
                        // The further below the bar, the finer the control.
                        let below = abs(drag.location.y - drag.startLocation.y)
                        let rate: Double = below < 60 ? 1 : below < 130 ? 0.5 : below < 200 ? 0.25 : 0.1
                        speedLabel = switch rate {
                        case 1: nil
                        case 0.5: "Half-speed scrubbing"
                        case 0.25: "Quarter-speed scrubbing"
                        default: "Fine scrubbing"
                        }
                        // Step from the last point so changing speed never jumps.
                        let dx = drag.location.x - (lastX ?? drag.location.x)
                        value = min(max(value + Double(dx / width) * total * rate, 0), total)
                        lastX = drag.location.x
                        scrubbing = value
                        onChanged(value)
                    }
                    .onEnded { _ in
                        lastX = nil
                        speedLabel = nil
                        onCommit(value)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue(Text(Duration.seconds(shown).formatted(.time(pattern: .hourMinuteSecond))))
            .accessibilityAdjustableAction { direction in
                let step: Double = direction == .increment ? 10 : -10
                onCommit(min(max(position + step, 0), total))
            }
        }
        .frame(height: 30)
    }
}
#endif
