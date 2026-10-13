import Foundation

/// Radar imagery from RainViewer's free public API, which needs no key.
///
/// The free tier's limits, as observed in October 2026: the past two hours
/// only, in ten-minute frames (no forecast frames); zoom levels up to 7, with
/// deeper requests returning a placeholder image; and only color scheme 2.
/// It's licensed for personal and small-scale use, with visible credit to
/// RainViewer required. See https://www.rainviewer.com/api.html.
nonisolated struct RainViewerProvider: RadarProvider {
    enum ProviderError: LocalizedError {
        case invalidURL
        case requestFailed(status: Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                "Couldn't build the radar request URL."
            case .requestFailed(let status):
                "The radar service responded with status \(status)."
            }
        }
    }

    private static let indexURLString = "https://api.rainviewer.com/public/weather-maps.json"

    /// "Universal Blue", the one scheme the free tier serves.
    private static let colorScheme = 2

    /// Smoothed edges, and snow drawn in its own colors.
    private static let renderOptions = "1_1"

    private let session: URLSession = .shared

    var maximumZoom: Int { 7 }

    var attribution: RadarAttribution {
        RadarAttribution(text: "Weather data by RainViewer", url: Self.homepage)
    }

    private static let homepage: URL = {
        guard let url = URL(string: "https://www.rainviewer.com") else {
            preconditionFailure("The RainViewer homepage URL literal is malformed.")
        }
        return url
    }()

    func frames() async throws -> [RadarFrame] {
        guard let url = URL(string: Self.indexURLString) else { throw ProviderError.invalidURL }

        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError.requestFailed(status: http.statusCode)
        }

        let index = try JSONDecoder().decode(WeatherMapsIndex.self, from: data)

        // The key carries the host as well as the path, so a frame stays
        // valid even if a later index moves tiles to another host.
        return index.radar.past
            .map { RadarFrame(time: Date(timeIntervalSince1970: $0.time), key: index.host + $0.path) }
            .sorted { $0.time < $1.time }
    }

    func tileURL(for frame: RadarFrame, x: Int, y: Int, zoom: Int, pixelSize: Int) -> URL? {
        URL(string: "\(frame.key)/\(pixelSize)/\(zoom)/\(x)/\(y)/\(Self.colorScheme)/\(Self.renderOptions).png")
    }
}

// MARK: - Wire format

private nonisolated struct WeatherMapsIndex: Decodable {
    let host: String
    let radar: Radar

    struct Radar: Decodable {
        let past: [Frame]
    }

    struct Frame: Decodable {
        let time: TimeInterval
        let path: String
    }
}
