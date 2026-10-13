import MapKit
import os

/// The radar's place on the map. It claims the whole world, so MapKit always
/// asks the renderer to draw, and the renderer draws only where its current
/// image is.
final class RadarImageOverlay: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
}

/// Draws the current radar image, cross-fading from the previous one.
///
/// MapKit draws overlays on background threads, several at once, so the
/// images and fade progress live behind a lock and the class is `nonisolated`.
nonisolated final class RadarImageRenderer: MKOverlayRenderer, @unchecked Sendable {
    private struct State {
        var current: RadarImage?
        var previous: RadarImage?

        /// 0 shows only `previous`, 1 only `current`.
        var progress: CGFloat = 1
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The frame on screen, or fading in.
    var currentFrameID: RadarFrame.ID? {
        state.withLock { $0.current?.frameID }
    }

    /// Starts a fade to `image` from whatever is showing now. The caller then
    /// steps `progress` to 1.
    func begin(_ image: RadarImage) {
        state.withLock { state in
            state.previous = state.current
            state.current = image
            state.progress = state.previous == nil ? 1 : 0
        }
        setNeedsDisplay()
    }

    /// Swaps in a sharper image of the frame already showing, after the map
    /// moved, without fading.
    func replace(_ image: RadarImage) {
        state.withLock { state in
            state.current = image
            state.previous = nil
            state.progress = 1
        }
        setNeedsDisplay()
    }

    func setProgress(_ progress: CGFloat) {
        state.withLock { $0.progress = min(max(progress, 0), 1) }
        setNeedsDisplay()
    }

    override func canDraw(_ mapRect: MKMapRect, zoomScale: MKZoomScale) -> Bool {
        let snapshot = state.withLock { $0 }
        return [snapshot.current, snapshot.previous].contains { $0?.mapRect.intersects(mapRect) == true }
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let snapshot = state.withLock { $0 }

        if let previous = snapshot.previous, snapshot.progress < 1 {
            draw(previous, alpha: 1 - snapshot.progress, in: context)
        }
        if let current = snapshot.current {
            draw(current, alpha: snapshot.progress, in: context)
        }
    }

    private func draw(_ radar: RadarImage, alpha: CGFloat, in context: CGContext) {
        guard alpha > 0 else { return }
        let target = rect(for: radar.mapRect)

        context.saveGState()
        context.setAlpha(alpha)
        context.interpolationQuality = .high
        // MapKit's drawing context is flipped, y growing downward as map
        // points do, while `CGContext.draw` assumes y grows upward — so flip
        // it back within the image's rectangle, or the radar draws upside down.
        context.translateBy(x: target.minX, y: target.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(radar.image, in: CGRect(origin: .zero, size: target.size))
        context.restoreGState()
    }
}
