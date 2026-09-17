import Foundation

/// The `vane://place/<id>` links that connect a widget to the app.
///
/// The widget builds one so clicking it opens the app on the city the widget
/// shows; the app resolves it back to a place id. Keep the format stable — a
/// URL baked into an installed widget outlives the build that made it.
nonisolated enum PlaceLink {
    static let scheme = "vane"
    private static let host = "place"

    static func url(for id: Place.ID) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/\(id)"
        return components.url
    }

    /// The place id carried by a link, or `nil` if the URL isn't one of ours.
    static func placeID(from url: URL) -> Place.ID? {
        guard url.scheme == scheme, url.host == host else { return nil }
        return Place.ID(url.lastPathComponent)
    }
}
