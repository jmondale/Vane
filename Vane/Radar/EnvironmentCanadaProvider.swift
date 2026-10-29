import Foundation

/// Radar imagery from Environment and Climate Change Canada's MSC GeoMet
/// service: the North American radar composite, which merges Canadian and
/// US (NEXRAD) radars at 1 km. It covers Canada and the United States only.
///
/// Served as a WMS, so tiles are requested by bounding box rather than by
/// tile index.
///
/// Licensed for any use, commercial included, under ECCC's Data Server
/// End-use Licence, which asks for visible credit and no suggestion that
/// ECCC endorses the app. The usage policy asks for a meaningful User-Agent
/// and no bulk tile downloading. See
/// https://eccc-msc.github.io/open-data/licence/readme_en/ and
/// https://eccc-msc.github.io/open-data/usage-policy/readme_en/.
nonisolated struct EnvironmentCanadaProvider: RadarProvider {
    enum ProviderError: LocalizedError {
        case invalidURL
        case requestFailed(status: Int)
        case noTimes

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                "Couldn't build the radar request URL."
            case .requestFailed(let status):
                "The radar service responded with status \(status)."
            case .noTimes:
                "The radar service didn't list any recent scans."
            }
        }
    }

    private static let endpoint = "https://geo.weather.gc.ca/geomet"

    /// Precipitation rate, on the rain scale. The service's snow layer
    /// (`RADAR_1KM_RSNO`) is the same echoes on a snow scale rather than
    /// only where it's snowing, so it would cover the rain, not add to it.
    private static let layer = "RADAR_1KM_RRAI"

    /// The service keeps three hours of scans, six minutes apart. Showing
    /// the last two hours at twelve-minute steps keeps playback about as
    /// long as before while asking the service for half the tiles.
    private static let history: TimeInterval = 2 * 60 * 60
    private static let step: TimeInterval = 12 * 60

    /// The composite's extent, from the layer's capabilities. Anywhere
    /// outside it the radar is always empty.
    private static let latitudes = 16.93...67.19
    private static let longitudes = -170.32 ... -50.0

    let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: configuration)
    }()

    /// Who's asking, as the usage policy requests: the app, its version, and
    /// where to reach its developer.
    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Vane/\(version) (+https://jmondale.github.io/vane-site/support.html)"
    }()

    /// The 1 km data is already finer than the screen at this depth.
    var maximumZoom: Int { 8 }

    var attribution: RadarAttribution {
        RadarAttribution(text: "Radar data: Environment and Climate Change Canada", url: Self.licence)
    }

    /// The layer's default style, sampled from its legend (GetLegendGraphic),
    /// which runs from 0.1 to 200 mm/h on an uneven scale.
    var legend: RadarLegend {
        RadarLegend(colors: [
            0x98CBFE, 0x069BFE, 0x00F179, 0x00D615, 0x00A700, 0x007900,
            0x8AB800, 0xFEE700, 0xFEB800, 0xFE8A00, 0xFE5000, 0xFE0013,
            0xFA049B, 0x9833CB, 0x6A049D, 0x3B0059,
        ])
    }

    private static let licence: URL = {
        guard let url = URL(string: "https://eccc-msc.github.io/open-data/licence/readme_en/") else {
            preconditionFailure("The ECCC licence URL literal is malformed.")
        }
        return url
    }()

    func covers(latitude: Double, longitude: Double) -> Bool {
        Self.latitudes.contains(latitude) && Self.longitudes.contains(longitude)
    }

    func frames() async throws -> [RadarFrame] {
        // The layer-specific capabilities document is a few kilobytes,
        // rather than the whole service's.
        var components = URLComponents(string: Self.endpoint)
        components?.queryItems = [
            URLQueryItem(name: "SERVICE", value: "WMS"),
            URLQueryItem(name: "VERSION", value: "1.3.0"),
            URLQueryItem(name: "REQUEST", value: "GetCapabilities"),
            URLQueryItem(name: "LAYER", value: Self.layer),
        ]
        guard let url = components?.url else { throw ProviderError.invalidURL }

        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError.requestFailed(status: http.statusCode)
        }

        guard let latest = Self.latestTime(in: String(decoding: data, as: UTF8.self)) else {
            throw ProviderError.noTimes
        }

        // Counted back from the newest scan, so every frame lands on one
        // the service has.
        let count = Int(Self.history / Self.step)
        return (0...count).reversed().map { index in
            let time = latest.addingTimeInterval(-Double(index) * Self.step)
            return RadarFrame(time: time, key: time.formatted(.iso8601))
        }
    }

    func tileURLs(for frame: RadarFrame, x: Int, y: Int, zoom: Int, pixelSize: Int) -> [URL] {
        // The tile's corners in spherical Mercator meters, which is the
        // square XYZ tiles divide up.
        let half = 20_037_508.342789244
        let side = 2 * half / Double(1 << zoom)
        let minX = -half + Double(x) * side
        let maxY = half - Double(y) * side
        let bbox = [minX, maxY - side, minX + side, maxY].map { String(format: "%.2f", $0) }.joined(separator: ",")

        var components = URLComponents(string: Self.endpoint)
        components?.queryItems = [
            URLQueryItem(name: "SERVICE", value: "WMS"),
            URLQueryItem(name: "VERSION", value: "1.3.0"),
            URLQueryItem(name: "REQUEST", value: "GetMap"),
            URLQueryItem(name: "LAYERS", value: Self.layer),
            URLQueryItem(name: "STYLES", value: ""),
            URLQueryItem(name: "CRS", value: "EPSG:3857"),
            URLQueryItem(name: "BBOX", value: bbox),
            URLQueryItem(name: "WIDTH", value: String(pixelSize)),
            URLQueryItem(name: "HEIGHT", value: String(pixelSize)),
            URLQueryItem(name: "FORMAT", value: "image/png"),
            URLQueryItem(name: "TRANSPARENT", value: "TRUE"),
            URLQueryItem(name: "TIME", value: frame.key),
        ]
        return components?.url.map { [$0] } ?? []
    }

    /// The newest scan time, from the time dimension's
    /// `start/end/interval` extent, such as
    /// `2026-10-29T12:06:00Z/2026-10-29T15:06:00Z/PT6M`.
    private static func latestTime(in capabilities: String) -> Date? {
        let pattern = /<Dimension name="time"[^>]*>[^\/<]+\/([^\/<]+)\//
        guard let match = capabilities.firstMatch(of: pattern) else { return nil }
        return try? Date(String(match.1), strategy: .iso8601)
    }
}
