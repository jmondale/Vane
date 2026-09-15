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
}

/// A weather condition, mapped from the WMO code that Open-Meteo reports.
nonisolated enum WeatherCondition: Hashable, Sendable {
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
nonisolated struct CurrentWeather: Sendable {
    let temperatureCelsius: Double
    let apparentTemperatureCelsius: Double
    let relativeHumidity: Int
    let windSpeedKPH: Double
    let condition: WeatherCondition
    let isDaytime: Bool
}

/// A single day in the forecast. `weekday` and `isToday` are resolved in the
/// location's own time zone, not the viewer's.
nonisolated struct DailyForecast: Identifiable, Sendable {
    let date: Date
    let weekday: String
    let isToday: Bool
    let condition: WeatherCondition
    let highCelsius: Double
    let lowCelsius: Double

    var id: Date { date }
}

/// Everything one fetch produces for a place.
nonisolated struct WeatherReport: Sendable {
    let current: CurrentWeather
    let daily: [DailyForecast]
}

extension Double {
    /// Formats a Celsius value using whichever unit the viewer's locale uses
    /// for weather. Used where no explicit preference is available — the widget
    /// can't read the app's setting, since that would need an App Group.
    var localeTemperatureText: String {
        Measurement(value: self, unit: UnitTemperature.celsius)
            .formatted(
                .measurement(
                    width: .narrow,
                    usage: .weather,
                    numberFormatStyle: .number.precision(.fractionLength(0))
                )
            )
    }

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
