import Foundation
import ImageIO
import MapKit

/// One radar frame, stitched from tiles into a single image covering
/// `mapRect`.
///
/// `@unchecked Sendable` because `CGImage` is immutable and safe to share
/// across threads, though not marked `Sendable`.
nonisolated struct RadarImage: @unchecked Sendable {
    let frameID: RadarFrame.ID
    let image: CGImage

    /// Where the image sits, in MapKit's map points.
    let mapRect: MKMapRect
}

/// The block of web-map tiles that covers a view of the map, at the zoom
/// level that's sharp on screen.
///
/// MapKit's map points use the same spherical Mercator square as XYZ tile
/// servers, origin at the top left, so tile indexes come straight from them.
nonisolated struct RadarViewport: Equatable, Sendable {
    let zoom: Int
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int

    /// - Parameters:
    ///   - visibleRect: The part of the map on screen.
    ///   - pixelWidth: The map view's width in device pixels.
    ///   - tilePixels: The width of one tile image in pixels.
    ///   - maximumZoom: The deepest zoom the provider serves.
    init(covering visibleRect: MKMapRect, pixelWidth: Double, tilePixels: Int, maximumZoom: Int) {
        // The shallowest zoom at which one tile pixel spans no more than one
        // screen pixel. Any shallower and the radar is stretched and soft.
        let tilesAcross = pixelWidth / Double(tilePixels)
        let worldFraction = visibleRect.width / MKMapSize.world.width
        let needed = log2(max(tilesAcross / worldFraction, 1)).rounded(.up)
        zoom = min(maximumZoom, max(0, Int(needed)))

        let count = 1 << zoom
        let tileWidth = MKMapSize.world.width / Double(count)
        func index(_ value: Double) -> Int {
            min(count - 1, max(0, Int((value / tileWidth).rounded(.down))))
        }
        minX = index(visibleRect.minX)
        maxX = index(visibleRect.maxX)
        minY = index(visibleRect.minY)
        maxY = index(visibleRect.maxY)
    }

    var tileWidth: Double {
        MKMapSize.world.width / Double(1 << zoom)
    }

    /// The area all the tiles cover together, in map points.
    var mapRect: MKMapRect {
        MKMapRect(
            x: Double(minX) * tileWidth,
            y: Double(minY) * tileWidth,
            width: Double(maxX - minX + 1) * tileWidth,
            height: Double(maxY - minY + 1) * tileWidth
        )
    }
}

/// Fetches a frame's tiles and stitches them into one `RadarImage`.
nonisolated enum RadarCompositor {
    /// Tiles are always fetched at the large size; the composite is then
    /// drawn at screen density, which keeps a dozen frames in memory cheap.
    static let tilePixels = 512

    /// - Parameter pixelsPerMapPoint: Screen density at the current zoom:
    ///   the map view's width in pixels over its visible width in map points.
    static func image(
        for frame: RadarFrame,
        in viewport: RadarViewport,
        pixelsPerMapPoint: Double,
        provider: any RadarProvider
    ) async -> RadarImage? {
        let rect = viewport.mapRect

        // Never denser than the tiles themselves, which would only enlarge
        // the image without adding detail.
        let density = min(pixelsPerMapPoint, Double(tilePixels) / viewport.tileWidth)
        let width = Int((rect.width * density).rounded())
        let height = Int((rect.height * density).rounded())
        guard width > 0, height > 0 else { return nil }

        let tiles = await withTaskGroup(of: (x: Int, y: Int, layer: Int, image: CGImage?).self) { group in
            for x in viewport.minX...viewport.maxX {
                for y in viewport.minY...viewport.maxY {
                    let urls = provider.tileURLs(
                        for: frame,
                        x: x,
                        y: y,
                        zoom: viewport.zoom,
                        pixelSize: tilePixels
                    )
                    for (layer, url) in urls.enumerated() {
                        group.addTask {
                            (x, y, layer, await tile(at: url, session: provider.session))
                        }
                    }
                }
            }
            var tiles: [(x: Int, y: Int, layer: Int, image: CGImage?)] = []
            for await tile in group {
                tiles.append(tile)
            }
            // Layers arrive in whatever order they finish; they're drawn in
            // the order the provider listed them.
            return tiles.sorted { $0.layer < $1.layer }
        }

        guard !Task.isCancelled,
              tiles.contains(where: { $0.image != nil }),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.interpolationQuality = .high
        let side = viewport.tileWidth * density
        for tile in tiles {
            guard let image = tile.image else { continue }
            // Edges snapped to whole pixels, each tile running exactly to
            // where its neighbor starts. At fractional positions the edge
            // pixels blend with the empty background and leave hairline
            // seams between tiles.
            let column = Double(tile.x - viewport.minX)
            let row = Double(tile.y - viewport.minY)
            let left = (column * side).rounded()
            let right = ((column + 1) * side).rounded()
            let top = (row * side).rounded()
            let bottom = ((row + 1) * side).rounded()
            // Tile rows count down from the top, but a bitmap context's
            // origin is its bottom-left corner.
            context.draw(
                image,
                in: CGRect(x: left, y: Double(height) - bottom, width: right - left, height: bottom - top)
            )
        }

        guard let composite = context.makeImage() else { return nil }
        return RadarImage(frameID: frame.id, image: composite, mapRect: rect)
    }

    /// One tile, or `nil` if it's missing or fails to load — a gap in the
    /// radar is better than no radar at all.
    private static func tile(at url: URL, session: URLSession) async -> CGImage? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
