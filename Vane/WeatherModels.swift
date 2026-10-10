import Foundation

/// A geocoded location returned by the Open-Meteo geocoding API.
nonisolated struct Place: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double
    let country: String?
    let admin1: String?

    /// The administrative region and country, e.g. "California, United States".
    var region: String {
        [admin1, country].compactMap { $0 }.joined(separator: ", ")
    }

    var fullName: String {
        region.isEmpty ? name : "\(name), \(region)"
    }
}

/// Whether measurements are displayed in metric or imperial units.
nonisolated enum UnitPreference: String, CaseIterable, Identifiable, Sendable {
    case metric
    case imperial

    var id: Self { self }

    var label: String {
        switch self {
        case .metric: "°C"
        case .imperial: "°F"
        }
    }

    var temperatureUnit: UnitTemperature {
        switch self {
        case .metric: .celsius
        case .imperial: .fahrenheit
        }
    }

    var speedUnit: UnitSpeed {
        switch self {
        case .metric: .kilometersPerHour
        case .imperial: .milesPerHour
        }
    }

    var precipitationUnit: UnitLength {
        switch self {
        case .metric: .millimeters
        case .imperial: .inches
        }
    }
}

/// A weather condition, mapped from the WMO code that Open-Meteo reports.
///
/// The raw values are persisted in the widget's report cache, so treat them as
/// a storage contract: add cases freely, but don't rename an existing one.
nonisolated enum WeatherCondition: String, Codable, Hashable, Sendable {
    case clear
    case mainlyClear
    case partlyCloudy
    case overcast
    case fog
    case drizzle
    case freezingDrizzle
    case rain
    case freezingRain
    case snow
    case snowGrains
    case showers
    case snowShowers
    case thunderstorm
    case thunderstormWithHail
    case unknown

    /// WMO 4677 weather interpretation codes, as documented by Open-Meteo.
    init(wmoCode code: Int) {
        switch code {
        case 0: self = .clear
        case 1: self = .mainlyClear
        case 2: self = .partlyCloudy
        case 3: self = .overcast
        case 45, 48: self = .fog
        case 51, 53, 55: self = .drizzle
        case 56, 57: self = .freezingDrizzle
        case 61, 63, 65: self = .rain
        case 66, 67: self = .freezingRain
        case 71, 73, 75: self = .snow
        case 77: self = .snowGrains
        case 80, 81, 82: self = .showers
        case 85, 86: self = .snowShowers
        case 95: self = .thunderstorm
        case 96, 99: self = .thunderstormWithHail
        default: self = .unknown
        }
    }

    var description: String {
        switch self {
        case .clear: "Clear"
        case .mainlyClear: "Mainly clear"
        case .partlyCloudy: "Partly cloudy"
        case .overcast: "Overcast"
        case .fog: "Fog"
        case .drizzle: "Drizzle"
        case .freezingDrizzle: "Freezing drizzle"
        case .rain: "Rain"
        case .freezingRain: "Freezing rain"
        case .snow: "Snow"
        case .snowGrains: "Snow grains"
        case .showers: "Rain showers"
        case .snowShowers: "Snow showers"
        case .thunderstorm: "Thunderstorm"
        case .thunderstormWithHail: "Thunderstorm with hail"
        case .unknown: "Unknown"
        }
    }

    func symbolName(isDaytime: Bool) -> String {
        switch self {
        case .clear: isDaytime ? "sun.max.fill" : "moon.stars.fill"
        case .mainlyClear: isDaytime ? "sun.min.fill" : "moon.fill"
        case .partlyCloudy: isDaytime ? "cloud.sun.fill" : "cloud.moon.fill"
        case .overcast: "cloud.fill"
        case .fog: "cloud.fog.fill"
        case .drizzle: "cloud.drizzle.fill"
        case .freezingDrizzle: "cloud.sleet.fill"
        case .rain: "cloud.rain.fill"
        case .freezingRain: "cloud.sleet.fill"
        case .snow: "cloud.snow.fill"
        case .snowGrains: "cloud.snow.fill"
        case .showers: "cloud.heavyrain.fill"
        case .snowShowers: "cloud.snow.fill"
        case .thunderstorm: "cloud.bolt.rain.fill"
        case .thunderstormWithHail: "cloud.bolt.rain.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }
}

/// Conditions at the location right now.
nonisolated struct CurrentWeather: Codable, Sendable {
    let temperatureCelsius: Double
    let apparentTemperatureCelsius: Double
    let relativeHumidity: Int
    let windSpeedKPH: Double
    let condition: WeatherCondition
    let isDaytime: Bool
}

/// A single day in the forecast. `weekday` and `isToday` are resolved in the
/// location's own time zone, not the viewer's, and are fixed at fetch time —
/// a cached report served the next morning will still say "Today" for
/// yesterday, which is why stale renders are labelled with their fetch time.
///
/// This type is persisted in the widget's report cache. Adding a property is
/// safe but not free: reports cached before the property existed can no longer
/// be decoded, and `SharedStore.cachedReport(for:)` drops them. The widget
/// loses its stale-data fallback once and refetches.
nonisolated struct DailyForecast: Codable, Identifiable, Sendable {
    /// Below this, a chance isn't worth the visual noise in a seven-day row.
    static let chanceDisplayThreshold = 10

    let date: Date
    let weekday: String
    let isToday: Bool
    let condition: WeatherCondition
    let highCelsius: Double
    let lowCelsius: Double

    /// Chance of measurable precipitation, 0–100. Open-Meteo reports no single
    /// daily figure, so this is the day's maximum hourly probability.
    let precipitationProbability: Int

    /// Total expected precipitation, as liquid water equivalent — snow is
    /// included here rather than reported separately.
    let precipitationMillimeters: Double

    var id: Date { date }

    /// The chance of precipitation, or `nil` when it's low enough to omit.
    var precipitationChanceText: String? {
        guard precipitationProbability >= Self.chanceDisplayThreshold else { return nil }
        return precipitationProbability.formatted(.percent)
    }
}

/// A single hour in the forecast. Like `DailyForecast.weekday`, `hourLabel` is
/// formatted in the location's own time zone at fetch time.
nonisolated struct HourlyForecast: Codable, Identifiable, Sendable {
    let date: Date
    let hourLabel: String
    let condition: WeatherCondition
    let isDaytime: Bool
    let temperatureCelsius: Double

    /// Chance of measurable precipitation in this hour, 0–100.
    let precipitationProbability: Int

    var id: Date { date }

    /// The chance of precipitation, or `nil` when it's low enough to omit.
    var precipitationChanceText: String? {
        guard precipitationProbability >= DailyForecast.chanceDisplayThreshold else { return nil }
        return precipitationProbability.formatted(.percent)
    }
}

/// Everything one fetch produces for a place.
nonisolated struct WeatherReport: Codable, Sendable {
    let current: CurrentWeather
    let daily: [DailyForecast]

    /// Hour-by-hour detail across every day in `daily`. Only the app asks for
    /// it; the widget's reports leave it empty.
    let hourly: [HourlyForecast]

    init(current: CurrentWeather, daily: [DailyForecast], hourly: [HourlyForecast] = []) {
        self.current = current
        self.daily = daily
        self.hourly = hourly
    }

    /// Reports cached before `hourly` existed have no such key. Decoding it as
    /// empty keeps those caches usable instead of dropping them.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        current = try container.decode(CurrentWeather.self, forKey: .current)
        daily = try container.decode([DailyForecast].self, forKey: .daily)
        hourly = try container.decodeIfPresent([HourlyForecast].self, forKey: .hourly) ?? []
    }

    /// Today's entry, falling back to the first day available. A report cached
    /// overnight has no day flagged as today, and its first entry is the
    /// closest thing to one.
    var today: DailyForecast? {
        daily.first { $0.isToday } ?? daily.first
    }

    /// The hours that fall on `day`. Each day's `date` is local midnight, so a
    /// day runs until the next one starts, which also handles 23- and 25-hour
    /// days at daylight-saving changes.
    func hours(for day: DailyForecast) -> [HourlyForecast] {
        let end = daily.first { $0.date > day.date }?.date ?? day.date.addingTimeInterval(86_400)
        return hourly.filter { $0.date >= day.date && $0.date < end }
    }
}

extension Double {
    /// Formats a Celsius value as whole degrees in the preferred unit.
    func temperatureText(in preference: UnitPreference) -> String {
        Measurement(value: self, unit: UnitTemperature.celsius)
            .converted(to: preference.temperatureUnit)
            .formatted(
                .measurement(
                    width: .abbreviated,
                    usage: .asProvided,
                    numberFormatStyle: .number.precision(.fractionLength(0))
                )
            )
    }

    /// Formats a millimetre value in the preferred unit.
    ///
    /// At most two fraction digits, and no trailing zeroes. That reads well in
    /// both units across the whole range — 0.2 mm and 18 mm, 0.01 in and
    /// 0.71 in. Significant digits instead would render a light shower as
    /// "0.0079 in", which is four digits of precision the forecast doesn't
    /// have.
    func precipitationText(in preference: UnitPreference) -> String {
        Measurement(value: self, unit: UnitLength.millimeters)
            .converted(to: preference.precipitationUnit)
            .formatted(
                .measurement(
                    width: .abbreviated,
                    usage: .asProvided,
                    numberFormatStyle: .number.precision(.fractionLength(0...2))
                )
            )
    }

    /// Formats a km/h value in the preferred unit.
    func windSpeedText(in preference: UnitPreference) -> String {
        Measurement(value: self, unit: UnitSpeed.kilometersPerHour)
            .converted(to: preference.speedUnit)
            .formatted(
                .measurement(
                    width: .abbreviated,
                    usage: .asProvided,
                    numberFormatStyle: .number.precision(.fractionLength(0))
                )
            )
    }
}
