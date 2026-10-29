import Foundation

/// One moment of radar imagery that a provider can serve as map tiles.
nonisolated struct RadarFrame: Identifiable, Hashable, Sendable {
    /// When the radar scan was taken.
    let time: Date

    /// An opaque, provider-specific handle that the provider turns back into
    /// tile URLs. Nothing outside the provider should try to read it.
    let key: String

    var id: String { key }
}

/// The credit a provider requires to be shown alongside its imagery.
nonisolated struct RadarAttribution: Sendable {
    let text: String
    let url: URL
}

/// A source of radar imagery.
///
/// Everything specific to one radar service lives behind this protocol, so
/// moving to another provider means writing one new conformance and changing
/// the line that picks it — the map, the tile loading, and the playback
/// controls don't change.
nonisolated protocol RadarProvider: Sendable {
    /// The deepest tile zoom level the provider serves. The map stays usable
    /// past it: deeper tiles are cut from this level and scaled up.
    var maximumZoom: Int { get }

    var attribution: RadarAttribution { get }

    /// The session tile and frame requests go through, carrying whatever
    /// headers the provider's terms ask for.
    var session: URLSession { get }

    /// Whether the provider has radar for a place at all. Outside its
    /// coverage the map would only ever be empty.
    func covers(latitude: Double, longitude: Double) -> Bool

    /// The frames available right now, oldest first.
    func frames() async throws -> [RadarFrame]

    /// The image URLs for one tile of `frame`, in standard web-map (XYZ)
    /// tile coordinates, as layers to draw bottom to top. `pixelSize` is
    /// 256, or 512 for Retina displays.
    func tileURLs(for frame: RadarFrame, x: Int, y: Int, zoom: Int, pixelSize: Int) -> [URL]
}
