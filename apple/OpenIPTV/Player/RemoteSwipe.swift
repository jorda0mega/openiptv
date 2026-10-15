import CoreGraphics

/// What a sideways swipe on the Siri Remote's touch surface does in the
/// film player, as in Apple's own player: on the round buttons (subtitles,
/// audio, speed) it moves between them; on the bar it moves through the
/// film only once it's paused (or a point is already being chosen); while
/// it plays, a swipe just shows the controls. A swipe on the way to the
/// buttons, or across them, used to skip the film.
enum RemoteSwipe {
    /// Where the player's focus is.
    enum Place: Equatable {
        case bar
        case buttons
    }

    enum Action: Equatable {
        /// Moves through the film (the picture follows, a click plays there).
        case scrub
        /// Moves along the round buttons by this many (0: not yet).
        case moveFocus(Int)
        /// The controls show; nothing else.
        case showControls
    }

    /// Travel across the touch surface for one button.
    static let pointsPerButton: CGFloat = 300

    /// `distance`: how far across since the swipe began; `stepsTaken`:
    /// buttons already moved by in this swipe.
    static func action(at place: Place, paused: Bool, scrubbing: Bool, distance: CGFloat, stepsTaken: Int = 0) -> Action {
        switch place {
        case .buttons:
            let steps = Int((distance / pointsPerButton).rounded(.towardZero))
            return .moveFocus(steps - stepsTaken)
        case .bar:
            return paused || scrubbing ? .scrub : .showControls
        }
    }
}

extension RemoteSwipe {
    /// A point chosen on the bar is kept: does the film play from it?
    /// `byClick`: kept with a click (the centre, or Play/Pause), not by
    /// letting go of a held button or the finger.
    /// As in Apple's player: a click plays from there, paused before or
    /// not; letting go carries on as it was.
    static func playsAfterChoosing(byClick: Bool, wasPlaying: Bool) -> Bool {
        byClick || wasPlaying
    }
}
