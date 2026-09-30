import Foundation

/// Fetches place lookups and forecasts from Open-Meteo, which is free and
/// needs no API key. Forecast values always arrive in metric units and are
/// converted for display, so changing units never triggers a refetch.
nonisolated struct WeatherService: Sendable {
    enum ServiceError: LocalizedError {
        case invalidURL
        case requestFailed(status: Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                "Couldn't build the request URL."
            case .requestFailed(let status):
                "The weather service responded with status \(status)."
            }
        }
    }

    private static let geocodingHost = "geocoding-api.open-meteo.com"
    private static let forecastHost = "api.open-meteo.com"

    private let session: URLSession = .shared

    /// Looks up places matching a free-text query, best match first. The query
    /// may include a region qualifier, e.g. "Moab, UT". Returns an empty array
    /// when nothing matches, which is normal for a partially typed name.
    func places(matching query: String) async throws -> [Place] {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let url = try Self.makeURL(
            host: Self.geocodingHost,
            path: "/v1/search",
            queryItems: [
                URLQueryItem(name: "name", value: query),
                URLQueryItem(name: "count", value: "8"),
                URLQueryItem(name: "language", value: language),
                URLQueryItem(name: "format", value: "json")
            ]
        )

        let response = try await fetch(GeocodingResponse.self, from: url)
        return response.results ?? []
    }

    /// Fetches current conditions plus a daily forecast for a place. The widget
    /// asks for fewer days than the app so it doesn't pull data it won't show.
    func report(for place: Place, forecastDays: Int = 7) async throws -> WeatherReport {
        let url = try Self.makeURL(
            host: Self.forecastHost,
            path: "/v1/forecast",
            queryItems: [
                URLQueryItem(name: "latitude", value: String(place.latitude)),
                URLQueryItem(name: "longitude", value: String(place.longitude)),
                URLQueryItem(
                    name: "current",
                    value: "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,is_day"
                ),
                URLQueryItem(
                    name: "daily",
                    value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum"
                ),
                URLQueryItem(name: "timezone", value: "auto"),
                URLQueryItem(name: "forecast_days", value: String(forecastDays))
            ]
        )

        let response = try await fetch(ForecastResponse.self, from: url)
        return WeatherReport(
            current: CurrentWeather(
                temperatureCelsius: response.current.temperature,
                apparentTemperatureCelsius: response.current.apparentTemperature,
                relativeHumidity: response.current.relativeHumidity,
                windSpeedKPH: response.current.windSpeed,
                condition: WeatherCondition(wmoCode: response.current.weatherCode),
                isDaytime: response.current.isDay == 1
            ),
            daily: Self.dailyForecasts(from: response.daily, timeZoneIdentifier: response.timezone)
        )
    }

    // MARK: - Networking

    private func fetch<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ServiceError.requestFailed(status: http.statusCode)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func makeURL(host: String, path: String, queryItems: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else { throw ServiceError.invalidURL }
        return url
    }

    // MARK: - Parsing

    private static func dailyForecasts(
        from daily: ForecastResponse.Daily,
        timeZoneIdentifier: String?
    ) -> [DailyForecast] {
        let timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current

        // Open-Meteo returns plain "yyyy-MM-dd" day keys in the location's zone.
        let dayParser = DateFormatter()
        dayParser.locale = Locale(identifier: "en_US_POSIX")
        dayParser.timeZone = timeZone
        dayParser.dateFormat = "yyyy-MM-dd"

        let weekdayStyle = Date.FormatStyle(timeZone: timeZone).weekday(.abbreviated)

        var calendar = Calendar.current
        calendar.timeZone = timeZone

        let count = min(
            daily.time.count,
            daily.weatherCode.count,
            min(daily.temperatureMax.count, daily.temperatureMin.count)
        )

        return (0..<count).compactMap { index in
            guard let date = dayParser.date(from: daily.time[index]) else { return nil }
            return DailyForecast(
                date: date,
                weekday: date.formatted(weekdayStyle),
                isToday: calendar.isDateInToday(date),
                condition: WeatherCondition(wmoCode: daily.weatherCode[index]),
                highCelsius: daily.temperatureMax[index],
                lowCelsius: daily.temperatureMin[index],
                precipitationProbability: value(daily.precipitationProbabilityMax, at: index, default: 0),
                precipitationMillimeters: value(daily.precipitationSum, at: index, default: 0)
            )
        }
    }

    /// Reads one element of an optional array of optionals, falling back when
    /// the key was absent, the array is shorter than the forecast, or the entry
    /// itself is null. A missing precipitation value means "none reported", so
    /// it must not drop the whole day from the forecast.
    private static func value<T>(_ array: [T?]?, at index: Int, default fallback: T) -> T {
        guard let array, array.indices.contains(index), let value = array[index] else {
            return fallback
        }
        return value
    }
}

// MARK: - Wire format

private nonisolated struct GeocodingResponse: Decodable {
    let results: [Place]?
}

private nonisolated struct ForecastResponse: Decodable {
    let timezone: String?
    let current: Current
    let daily: Daily

    struct Current: Decodable {
        let temperature: Double
        let apparentTemperature: Double
        let relativeHumidity: Int
        let weatherCode: Int
        let windSpeed: Double
        let isDay: Int

        enum CodingKeys: String, CodingKey {
            case temperature = "temperature_2m"
            case apparentTemperature = "apparent_temperature"
            case relativeHumidity = "relative_humidity_2m"
            case weatherCode = "weather_code"
            case windSpeed = "wind_speed_10m"
            case isDay = "is_day"
        }
    }

    struct Daily: Decodable {
        let time: [String]
        let weatherCode: [Int]
        let temperatureMax: [Double]
        let temperatureMin: [Double]

        /// Doubly optional on purpose. Open-Meteo omits these keys entirely if
        /// the model doesn't supply them, and returns `null` entries past the
        /// probability horizon, which is shorter than the forecast itself.
        let precipitationProbabilityMax: [Int?]?
        let precipitationSum: [Double?]?

        enum CodingKeys: String, CodingKey {
            case time
            case weatherCode = "weather_code"
            case temperatureMax = "temperature_2m_max"
            case temperatureMin = "temperature_2m_min"
            case precipitationProbabilityMax = "precipitation_probability_max"
            case precipitationSum = "precipitation_sum"
        }
    }
}
