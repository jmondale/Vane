import MapKit
import SwiftUI

/// The map under the radar: Apple Maps, muted so the radar stands out, with
/// the radar drawn on top.
///
/// SwiftUI's `Map` can't draw custom imagery, so this wraps `MKMapView`.
/// Rather than let MapKit fetch radar tiles itself — it picks coarse tiles
/// and loads each frame only when it's shown, which made playback soft and
/// jerky — the coordinator stitches every frame into an image ahead of time
/// at the zoom that's sharp on screen, and the renderer cross-fades between
/// them.
struct RadarMapView {
    let center: CLLocationCoordinate2D
    let frames: [RadarFrame]
    let currentFrame: RadarFrame?
    let provider: any RadarProvider

    /// Bumped to send the map back to its starting view around `center`.
    /// A counter rather than a flag, so every press registers once.
    var recenterRequest = 0

    /// How much ground the map shows around the place, edge to edge, when a
    /// place is first shown — about the size of a region, which is where
    /// radar is most useful and within the provider's sharpest zoom.
    fileprivate static let initialSpan: CLLocationDistance = 600_000

    /// Partly transparent, so roads and borders stay visible under rain.
    fileprivate static let radarOpacity: CGFloat = 0.75

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    fileprivate func makeMapView(coordinator: Coordinator) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = coordinator

        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        mapView.preferredConfiguration = configuration

        // Radar is a flat, north-up picture; tilting or turning it only
        // makes the frames harder to compare.
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false

        // Close enough to see a storm's edge, far enough to see what's
        // coming. Zooming in past the provider's deepest tiles can only
        // enlarge them, so the near limit stops a little beyond that, before
        // the radar turns soft.
        mapView.cameraZoomRange = MKMapView.CameraZoomRange(
            minCenterCoordinateDistance: 100_000,
            maxCenterCoordinateDistance: 6_000_000
        )

        // The scale shows how far in you are; it fades out when the map is
        // still. Zoom buttons are a macOS control — elsewhere, pinch zooms.
        mapView.showsScale = true
        #if os(macOS)
        mapView.showsZoomControls = true
        #endif

        // Above roads but below labels, so place names stay legible.
        mapView.addOverlay(coordinator.overlay, level: .aboveRoads)

        update(mapView, coordinator: coordinator, reduceMotion: false)
        return mapView
    }

    fileprivate func update(_ mapView: MKMapView, coordinator: Coordinator, reduceMotion: Bool) {
        coordinator.provider = provider
        coordinator.reduceMotion = reduceMotion
        coordinator.recenter(on: center, in: mapView, request: recenterRequest)
        coordinator.sync(frames: frames, in: mapView)
        coordinator.show(currentFrame)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        /// How long a cross-fade between frames takes, and in how many steps.
        private static let fadeDuration: Duration = .milliseconds(240)
        private static let fadeSteps = 8

        /// How long the map must sit still after a pan or zoom before the
        /// frames are rebuilt for the new view.
        private static let settleDelay: Duration = .milliseconds(300)

        let overlay = RadarImageOverlay()
        var provider: (any RadarProvider)?
        var reduceMotion = false

        private let renderer: RadarImageRenderer
        private let pin = MKPointAnnotation()
        private var center: CLLocationCoordinate2D?
        private var frames: [RadarFrame] = []

        /// Stitched images by frame. Each carries its own map rectangle, so
        /// an image built for an earlier view still draws in the right place
        /// while its replacement loads.
        private var images: [RadarFrame.ID: RadarImage] = [:]

        /// The view the images in `images` were last fully built for.
        private var builtViewport: RadarViewport?

        private var wantedFrameID: RadarFrame.ID?
        private var buildTask: Task<Void, Never>?
        private var fadeTask: Task<Void, Never>?
        private var settleTask: Task<Void, Never>?
        private weak var mapView: MKMapView?

        override init() {
            renderer = RadarImageRenderer(overlay: overlay)
            renderer.alpha = RadarMapView.radarOpacity
            super.init()
        }

        /// The last recenter request acted on.
        private var handledRecenterRequest = 0

        /// Moves to a new place, or back to the starting view when `request`
        /// has changed, but leaves the map alone otherwise, so panning and
        /// zooming survive every frame change.
        func recenter(on newCenter: CLLocationCoordinate2D, in mapView: MKMapView, request: Int) {
            self.mapView = mapView
            let isNewRequest = request != handledRecenterRequest
            handledRecenterRequest = request
            if !isNewRequest, let center, center.latitude == newCenter.latitude, center.longitude == newCenter.longitude {
                return
            }
            let isFirstPlace = center == nil
            center = newCenter

            pin.coordinate = newCenter
            if isFirstPlace {
                mapView.addAnnotation(pin)
            }

            let region = MKCoordinateRegion(
                center: newCenter,
                latitudinalMeters: RadarMapView.initialSpan,
                longitudinalMeters: RadarMapView.initialSpan
            )
            mapView.setRegion(region, animated: !isFirstPlace)
        }

        /// Takes a new frame list, rebuilding images if it changed.
        func sync(frames newFrames: [RadarFrame], in mapView: MKMapView) {
            guard newFrames.map(\.id) != frames.map(\.id) else { return }
            frames = newFrames
            let wanted = Set(newFrames.map(\.id))
            images = images.filter { wanted.contains($0.key) }
            rebuild(force: true)
        }

        /// Puts `frame` on screen as soon as its image is ready. Until then
        /// the previous frame stays up, which reads as a pause, not a blank.
        func show(_ frame: RadarFrame?) {
            wantedFrameID = frame?.id
            guard let id = frame?.id, id != renderer.currentFrameID, let image = images[id] else { return }
            fade(to: image)
        }

        // MARK: Building images

        /// Builds an image of every frame for the current view of the map,
        /// the one on screen first. Skips the work when the view still needs
        /// the same tiles as last time, unless `force` is set.
        private func rebuild(force: Bool = false) {
            guard let mapView, let provider, !frames.isEmpty else { return }

            let pixelsWide = Double(mapView.bounds.width) * Self.backingScale(of: mapView)
            let visible = mapView.visibleMapRect
            guard pixelsWide > 0, visible.width > 0 else { return }

            let viewport = RadarViewport(
                covering: visible,
                pixelWidth: pixelsWide,
                tilePixels: RadarCompositor.tilePixels,
                maximumZoom: provider.maximumZoom
            )
            guard force || viewport != builtViewport else { return }

            let density = pixelsWide / visible.width

            // The frame being watched first, then newest to oldest, which is
            // the order playback reaches them from the newest frame.
            let order = frames.filter { $0.id == wantedFrameID } + frames.reversed().filter { $0.id != wantedFrameID }

            buildTask?.cancel()
            buildTask = Task { [weak self] in
                for frame in order {
                    guard let image = await RadarCompositor.image(
                        for: frame,
                        in: viewport,
                        pixelsPerMapPoint: density,
                        provider: provider
                    ) else { continue }
                    guard !Task.isCancelled, let self else { return }
                    self.store(image)
                }
                guard !Task.isCancelled else { return }
                self?.builtViewport = viewport
            }
        }

        private func store(_ image: RadarImage) {
            images[image.frameID] = image
            guard image.frameID == wantedFrameID else { return }
            if renderer.currentFrameID == image.frameID {
                // The same frame, rebuilt for a new view: swap it in place.
                renderer.replace(image)
            } else {
                fade(to: image)
            }
        }

        private func fade(to image: RadarImage) {
            fadeTask?.cancel()
            renderer.begin(image)
            guard !reduceMotion else {
                renderer.setProgress(1)
                return
            }
            let step = Self.fadeDuration / Self.fadeSteps
            fadeTask = Task { [renderer] in
                for index in 1...Self.fadeSteps {
                    do {
                        try await Task.sleep(for: step)
                    } catch {
                        return
                    }
                    renderer.setProgress(CGFloat(index) / CGFloat(Self.fadeSteps))
                }
            }
        }

        private static func backingScale(of mapView: MKMapView) -> Double {
            #if os(macOS)
            Double(mapView.window?.backingScaleFactor ?? 2)
            #else
            Double(mapView.traitCollection.displayScale)
            #endif
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            overlay === self.overlay ? renderer : MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Wait for the map to settle, so a long drag rebuilds once at
            // the end rather than at every step along the way.
            settleTask?.cancel()
            settleTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: Self.settleDelay)
                } catch {
                    return
                }
                self?.rebuild()
            }
        }
    }
}

// The app also builds for iOS and visionOS, where MapKit hosts its view
// through UIKit rather than AppKit; the map setup itself is shared.
#if os(macOS)
extension RadarMapView: NSViewRepresentable {
    func makeNSView(context: Context) -> MKMapView {
        makeMapView(coordinator: context.coordinator)
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        update(
            mapView,
            coordinator: context.coordinator,
            reduceMotion: context.environment.accessibilityReduceMotion
        )
    }
}
#else
extension RadarMapView: UIViewRepresentable {
    func makeUIView(context: Context) -> MKMapView {
        makeMapView(coordinator: context.coordinator)
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        update(
            mapView,
            coordinator: context.coordinator,
            reduceMotion: context.environment.accessibilityReduceMotion
        )
    }
}
#endif
