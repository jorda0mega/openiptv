import SwiftUI
import UIKit

struct TappedFilm: Identifiable {
    enum Start {
        case asking(Task<EmbyPlayback, Error>)
        case planned(EmbyPlayback)
        case backFromPictureInPicture(EmbyPlayback)

        var playback: EmbyPlayback? {
            switch self {
            case .asking: nil
            case let .planned(playback), let .backFromPictureInPicture(playback): playback
            }
        }
    }

    let id = UUID()
    let itemId: String
    let kind: String?
    let title: String
    let held: FirstPicture
    let picture: UIImage?
    let tappedAt: Date
    let start: Start

    static func planned(_ playback: EmbyPlayback, held: FirstPicture) -> TappedFilm {
        TappedFilm(itemId: playback.itemId, kind: nil, title: playback.title, held: held, picture: nil, tappedAt: Date(),
                   start: .planned(playback))
    }

    static func backFromPictureInPicture(_ playback: EmbyPlayback) -> TappedFilm {
        TappedFilm(itemId: playback.itemId, kind: nil, title: playback.title, held: .backdrop, picture: nil, tappedAt: Date(),
                   start: .backFromPictureInPicture(playback))
    }
}

struct FilmHost: View {
    @State var tapped: TappedFilm

    var body: some View {
        FilmScreen(tapped: tapped) { tapped = $0 }
            .id(tapped.id)
    }
}

private struct FilmScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closePlayer) private var closePlayer

    let tapped: TappedFilm
    let switchTo: (TappedFilm) -> Void
    @State private var loading: FilmLoading
    @State private var playback: EmbyPlayback?
    @State private var asking: Task<Void, Never>?
    @State private var tryAgainAsked = 0
    @State private var closeAsked = 0
    #if DEBUG
    @State private var looks: [String] = []
    #endif

    init(tapped: TappedFilm, switchTo: @escaping (TappedFilm) -> Void) {
        self.tapped = tapped
        self.switchTo = switchTo
        let loading: FilmLoading = if case .backFromPictureInPicture = tapped.start {
            .moving(at: tapped.tappedAt, patience: Self.patience)
        } else {
            FilmLoading(tappedAt: tapped.tappedAt, held: tapped.held, patience: Self.patience)
        }
        _loading = State(initialValue: loading)
        _playback = State(initialValue: tapped.start.playback)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let playback {
                MoviePlayerView(playback: playback, held: tapped.held, loading: $loading, tryAgainAsked: tryAgainAsked,
                                closeAsked: closeAsked, switchTo: switchTo)
            }
            #if os(tvOS)
            if playback == nil {
                TVRemoteSurface { input in
                    switch input {
                    case .select: if loading.look.failure != nil { tryAgain() }
                    case .menu: close()
                    default: break
                    }
                }
                .ignoresSafeArea()
            }
            #endif
            FilmLoadingSurface(look: loading.look, title: tapped.title, picture: tapped.picture, tryAgain: tryAgain, close: close)
            #if DEBUG
            Text(looks.joined(separator: ", "))
                .font(.caption2)
                .frame(width: 1, height: 1)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityLabel(looks.joined(separator: ", "))
                .accessibilityIdentifier("debug-film-loading")
            Text(String(FilmLoadingProbe.heldShown))
                .font(.caption2)
                .frame(width: 1, height: 1)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityLabel(String(FilmLoadingProbe.heldShown))
                .accessibilityIdentifier("debug-film-held")
            #endif
        }
        #if os(tvOS)
        .onExitCommand { if playback == nil { close() } }
        #endif
        .task {
            guard case let .asking(plan) = tapped.start else { return }
            await ask(plan)
        }
        .task(id: loading.nextChange) {
            guard let next = loading.nextChange else { return }
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            loading.send(.clock, at: Date())
        }
        .task(id: loading.waiting) {
            var last: Int64?
            while loading.waiting, !Task.isCancelled {
                let count = StreamRelay.shared.arrived.value
                if count != last { loading.send(.bytes(count), at: Date()) }
                last = count
                try? await Task.sleep(for: .seconds(FilmLoading.readEvery))
            }
        }
        .onChange(of: NetworkStatus.shared.online, initial: true) { _, online in loading.send(.online(online), at: Date()) }
        .onChange(of: loading.look.failure) { _, failure in
            guard failure != nil, playback == nil else { return }
            asking?.cancel()
            if case let .asking(plan) = tapped.start { plan.cancel() }
        }
        #if DEBUG
        .onChange(of: loading.look.kind, initial: true) { _, kind in looks.append(kind.rawValue) }
        #endif
        .onDisappear {
            asking?.cancel()
            if case let .asking(plan) = tapped.start { plan.cancel() }
        }
    }

    private static var patience: FilmLoading.Patience {
        #if DEBUG
        if StartPatience.off { return .unbounded }
        let limit = UserDefaults.standard.double(forKey: "filmLoadingLimit")
        if limit > 0 { return FilmLoading.Patience(stillFor: limit, atMost: limit) }
        #endif
        return .current
    }

    private func ask(_ plan: Task<EmbyPlayback, Error>) async {
        let ask = loading.nextAsk()
        do {
            let answer = try await plan.value
            guard !Task.isCancelled else { return }
            loading.send(.planAnswered(ask: ask), at: Date())
            if ask == loading.ask, loading.waiting { playback = answer }
        } catch {
            guard !Task.isCancelled else { return }
            loading.send(.planRefused(SourceError.wrap(error).localizedDescription, ask: ask), at: Date())
        }
    }

    private func tryAgain() {
        guard playback == nil else { return tryAgainAsked += 1 }
        loading.send(.tryAgain, at: Date())
        asking?.cancel()
        let plan = Task { [model, tapped] in try await model.playback(itemId: tapped.itemId, kind: tapped.kind) }
        asking = Task { await ask(plan) }
    }

    private func close() {
        guard playback == nil else { return closeAsked += 1 }
        loading.send(.close, at: Date())
        if let closePlayer { closePlayer() } else { dismiss() }
    }
}

struct FilmLoadingSurface: View {
    let look: FilmLoading.Look
    let title: String
    let picture: UIImage?
    let tryAgain: () -> Void
    let close: () -> Void

    #if os(tvOS)
    private let ringSize: CGFloat = 60, headlineFont: CGFloat = 38, causeFont: CGFloat = 29, gap: CGFloat = 22, width: CGFloat = 1100
    #else
    private let ringSize: CGFloat = 34, headlineFont: CGFloat = 17, causeFont: CGFloat = 15, gap: CGFloat = 12, width: CGFloat = 330
    #endif

    var body: some View {
        ZStack(alignment: .topLeading) {
            if look.under == .held(.backdrop) {
                HeldPicture(picture: picture)
                    .transition(.opacity.animation(.easeOut(duration: 0.25)))
            }
            ZStack {
                switch look.over {
                case .nothing:
                    EmptyView()
                case let .ring(steps, lit):
                    FilmRing(steps: steps, lit: lit, size: ringSize)
                        .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.3)),
                                                removal: .opacity.animation(.easeOut(duration: 0.25))))
                case let .failure(failure):
                    words(failure)
                        .transition(.opacity.animation(.easeOut(duration: 0.2)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            #if os(iOS)
            if look.closes {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Close")
                .padding(.horizontal, 16)
                .transition(.opacity.animation(.easeOut(duration: 0.25)))
            }
            #endif
        }
    }

    private func words(_ failure: FilmLoading.Failure) -> some View {
        VStack(spacing: gap * 0.6) {
            Text(look.headline(title) ?? "")
                .font(.system(size: headlineFont, weight: .semibold))
                .foregroundStyle(.white)
            Text(failure.cause)
                .font(.system(size: causeFont))
                .foregroundStyle(.white.opacity(0.78))
            tryAgainButton
                .padding(.top, gap * 0.4)
        }
        .multilineTextAlignment(.center)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .shadow(color: .black.opacity(0.55), radius: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("film-failure")
    }

    @ViewBuilder private var tryAgainButton: some View {
        #if os(tvOS)
        Text("Try again")
            .font(.system(size: 29, weight: .semibold))
            .fixedSize()
            .foregroundStyle(.black)
            .padding(.horizontal, 36)
            .frame(height: 66)
            .background(.white, in: .capsule)
            .scaleEffect(1.06)
            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
            .accessibilityElement()
            .accessibilityLabel("Try again")
            .accessibilityAddTraits([.isButton, .isSelected])
        #else
        Button(action: tryAgain) {
            Text("Try again")
                .font(.system(size: 15, weight: .semibold))
                .fixedSize()
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        #endif
    }
}

private struct HeldPicture: View {
    let picture: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let picture {
                Image(uiImage: picture)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
            }
            Color.black.opacity(0.35)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityIdentifier("film-held-picture")
        #if DEBUG
        .onAppear { FilmLoadingProbe.heldShown += 1 }
        #endif
    }
}

private struct FilmRing: View {
    let steps: Int
    let lit: Bool
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let width = size / 10
        ZStack {
            Circle().stroke(.white.opacity(lit ? 0.2 : 0.12), lineWidth: width)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(.white.opacity(lit ? 1 : 0.35), style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90 + Double(steps) * 72))
                .animation(reduceMotion ? nil : .linear(duration: FilmLoading.readEvery), value: steps)
        }
        .animation(.easeOut(duration: 0.2), value: lit)
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.45), radius: 6)
        .accessibilityElement()
        .accessibilityLabel("Loading")
        .accessibilityIdentifier("film-loading")
    }
}

#if DEBUG
@MainActor
enum FilmLoadingProbe {
    static var heldShown = 0
}
#endif
