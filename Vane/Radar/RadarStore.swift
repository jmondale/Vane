import Foundation
import Observation

/// The radar frames on hand and the playback position through them. Knows
/// nothing about any one radar service beyond the `RadarProvider` it's given.
@Observable final class RadarStore {
    enum Status: Equatable {
        case loading
        case ready
        case failed(message: String)
    }

    /// How long each frame shows during playback.
    private static let frameDuration: Duration = .milliseconds(500)

    /// How long the newest frame holds before the loop starts over, so the
    /// latest picture is the one that registers.
    private static let loopPause: Duration = .milliseconds(1_500)

    /// Radar services add a scan every five to ten minutes; checking this
    /// often keeps the newest one from falling far behind.
    private static let refreshInterval: Duration = .seconds(300)

    let provider: any RadarProvider

    private(set) var frames: [RadarFrame] = []
    private(set) var status: Status = .loading

    /// Index into `frames` of the one on screen.
    var currentIndex = 0

    var isPlaying = false

    init(provider: any RadarProvider = EnvironmentCanadaProvider()) {
        self.provider = provider
    }

    var currentFrame: RadarFrame? {
        frames.indices.contains(currentIndex) ? frames[currentIndex] : nil
    }

    var isShowingLatest: Bool {
        currentIndex == frames.count - 1
    }

    /// Fetches the frame list now, then again every few minutes until the
    /// calling task is cancelled.
    func keepFresh() async {
        while !Task.isCancelled {
            await load()
            do {
                try await Task.sleep(for: Self.refreshInterval)
            } catch {
                return
            }
        }
    }

    /// Steps through the frames for as long as `isPlaying` stays set. The
    /// view restarts this whenever `isPlaying` changes.
    func play() async {
        guard isPlaying, frames.count > 1 else { return }

        // Pressing play on the newest frame replays from the oldest.
        if isShowingLatest {
            currentIndex = 0
        }

        while isPlaying {
            do {
                try await Task.sleep(for: isShowingLatest ? Self.loopPause : Self.frameDuration)
            } catch {
                return
            }
            currentIndex = isShowingLatest ? 0 : currentIndex + 1
        }
    }

    private func load() async {
        do {
            let fetched = try await provider.frames()
            guard !fetched.isEmpty else {
                if frames.isEmpty {
                    status = .failed(message: "No radar imagery is available right now.")
                }
                return
            }

            // Someone watching the newest frame keeps watching the newest
            // one; someone parked on an older frame stays on it while it's
            // still in the list.
            let wasShowingLatest = frames.isEmpty || isShowingLatest
            let shownID = currentFrame?.id
            frames = fetched
            if !wasShowingLatest, let shownID, let index = fetched.firstIndex(where: { $0.id == shownID }) {
                currentIndex = index
            } else {
                currentIndex = fetched.count - 1
            }
            status = .ready
        } catch is CancellationError {
            return
        } catch {
            // A failed refresh leaves the frames already on screen alone.
            if frames.isEmpty {
                let isOffline = (error as NSError).domain == NSURLErrorDomain
                    && (error as NSError).code == NSURLErrorNotConnectedToInternet
                status = .failed(message: isOffline ? "Radar needs a connection." : "Radar is unavailable right now.")
            }
        }
    }
}
