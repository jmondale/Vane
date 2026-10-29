import CoreLocation
import Foundation
import MapKit
import WeatherKit

/// Finds places with MapKit search and fetches their forecasts from Apple's
/// WeatherKit. Forecast values are stored in metric units and converted for
/// display, so changing units never triggers a refetch.
///
/// WeatherKit's types share names with this app's own (`WeatherService`,
/// `CurrentWeather`, `WeatherCondition`), so its types are always written
/// with the `WeatherKit.` prefix here.
nonisolated struct WeatherService: Sendable {
    /// How many search results to offer. The completion list shows six.
    private static let maximumPlaces = 8

    /// Looks up places matching a free-text query, best match first. The query
    /// may include a region qualifier, e.g. "Moab, UT". Returns an empty array
    /// when nothing matches, which is normal for a partially typed name.
    func places(matching query: String) async throws -> [Place] {
        try await Self.search(query)
    }

    /// A plain `MKLocalSearch` answers with its single best match, so
    /// "Portland" would never offer Maine. The completer behind Maps'
    /// suggestion list returns every likely city; each is then looked up for
    /// its coordinate, all at once. MapKit's search classes expect the main
    /// thread.
    @MainActor private static func search(_ query: String) async throws -> [Place] {
        let completions = try await CityCompleter().completions(for: query)
            .prefix(maximumPlaces)

        let found = await withTaskGroup(of: (Int, Place?).self) { group in
            for (rank, completion) in completions.enumerated() {
                let request = MKLocalSearch.Request(completion: completion)
                request.resultTypes = .address
                request.addressFilter = MKAddressFilter(including: .locality)
                group.addTask { @MainActor in
                    let item = try? await MKLocalSearch(request: request).start().mapItems.first
                    return (rank, item.flatMap(place(from:)))
                }
            }
            var found: [(Int, Place?)] = []
            for await result in group {
                found.append(result)
            }
            return found
        }

        // Back in the completer's order, keeping the first of any two that
        // land on the same spot.
        var seenIDs = Set<Place.ID>()
        return found
            .sorted { $0.0 < $1.0 }
            .compactMap(\.1)
            .filter { seenIDs.insert($0.id).inserted }
    }

    /// Fetches current conditions plus a daily forecast for a place, and an
    /// hourly one when `includeHourly` is set. The widget leaves hourly off and
    /// may ask for fewer days, so it doesn't pull data it won't show.
    func report(
        for place: Place,
        forecastDays: Int = 7,
        includeHourly: Bool = false
    ) async throws -> WeatherReport {
        let location = CLLocation(latitude: place.latitude, longitude: place.longitude)
        let timeZone = await Self.timeZone(for: place, at: location)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: .now)
        let end = calendar.date(byAdding: .day, value: forecastDays, to: today) ?? today.addingTimeInterval(Double(forecastDays) * 86_400)

        let service = WeatherKit.WeatherService.shared
        let current: WeatherKit.CurrentWeather
        let days: WeatherKit.Forecast<DayWeather>
        var hours: WeatherKit.Forecast<HourWeather>?
        var minutes: WeatherKit.Forecast<MinuteWeather>?
        var alerts: [WeatherKit.WeatherAlert]?
        if includeHourly {
            // One request for all of it: WeatherKit counts calls, not data
            // sets, so the next hour and alerts cost nothing extra.
            (current, days, hours, minutes, alerts) = try await service.weather(
                for: location,
                including: .current,
                .daily(startDate: today, endDate: end),
                .hourly(startDate: today, endDate: end),
                .minute,
                .alerts
            )
        } else {
            (current, days) = try await service.weather(
                for: location,
                including: .current,
                .daily(startDate: today, endDate: end)
            )
        }

        return WeatherReport(
            current: CurrentWeather(
                temperatureCelsius: current.temperature.converted(to: .celsius).value,
                apparentTemperatureCelsius: current.apparentTemperature.converted(to: .celsius).value,
                relativeHumidity: Int((current.humidity * 100).rounded()),
                windSpeedKPH: current.wind.speed.converted(to: .kilometersPerHour).value,
                condition: WeatherCondition(current.condition),
                isDaytime: current.isDaylight,
                windDirectionDegrees: current.wind.direction.converted(to: .degrees).value,
                windGustKPH: current.wind.gust?.converted(to: .kilometersPerHour).value,
                uvIndex: current.uvIndex.value,
                pressureHectopascals: current.pressure.converted(to: .hectopascals).value,
                pressureTrend: CurrentWeather.PressureTrend(current.pressureTrend),
                visibilityKilometers: current.visibility.converted(to: .kilometers).value,
                dewPointCelsius: current.dewPoint.converted(to: .celsius).value
            ),
            daily: Self.dailyForecasts(from: days, calendar: calendar),
            hourly: hours.map { Self.hourlyForecasts(from: $0, timeZone: timeZone) } ?? [],
            nextHour: minutes.flatMap(Self.nextHour(from:)),
            alerts: (alerts ?? [])
                .map { alert in
                    WeatherAlert(
                        summary: alert.summary,
                        source: alert.source,
                        region: alert.region,
                        severity: WeatherAlert.Severity(alert.severity),
                        detailsURL: alert.detailsURL
                    )
                }
                .sorted { $0.severity > $1.severity }
                // Agencies often issue one watch as several alerts, one per
                // forecast zone; on a single place's page they'd read as
                // duplicates. The most severe of each stays, with its link.
                .reduce(into: [WeatherAlert]()) { kept, alert in
                    if !kept.contains(where: { $0.summary == alert.summary && $0.source == alert.source && $0.region == alert.region }) {
                        kept.append(alert)
                    }
                }
        )
    }

    private static func nextHour(from forecast: WeatherKit.Forecast<MinuteWeather>) -> NextHourForecast? {
        // WeatherKit returns a little over an hour; the card shows an hour,
        // plus the minute in progress.
        let minutes = Array(forecast.prefix(61))
        guard let first = minutes.first else { return nil }
        let wettest = minutes.max { $0.precipitationIntensity.value < $1.precipitationIntensity.value }
        let kind: String = switch wettest?.precipitation {
        case .snow: "Snow"
        case .sleet: "Sleet"
        case .hail: "Hail"
        case .mixed: "Precipitation"
        default: "Rain"
        }
        return NextHourForecast(
            start: first.date,
            kind: kind,
            chances: minutes.map(\.precipitationChance),
            // Foundation has no millimetres-per-hour unit; a kilometre an
            // hour is a million of them.
            intensities: minutes.map { $0.precipitationIntensity.converted(to: .kilometersPerHour).value * 1_000_000 }
        )
    }

    /// The credit WeatherKit's terms require wherever its data is shown: the
    /// Apple Weather mark and a link to the legal attribution page.
    func attribution() async throws -> WeatherKit.WeatherAttribution {
        try await WeatherKit.WeatherService.shared.attribution
    }

    /// A sentence to show someone when a lookup fails. The errors themselves
    /// are written for developers ("WeatherDaemon…Errors error 2"), so only
    /// their kind is used: no connection, a slow one, or the service itself.
    static func message(for error: any Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                 NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
                return "You're offline. Check your connection and try again."
            case NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                return "The weather service didn't respond. Try again in a moment."
            default:
                break
            }
        }
        if error is MKError {
            return "Couldn't search for places right now. Try again in a moment."
        }
        return "Couldn't load the forecast from Apple Weather. Try again in a moment."
    }

    // MARK: - Places

    /// The city a coordinate is in, for showing the weather where someone
    /// is. Its id comes from the city's own coordinate, not the device's, so
    /// moving around town keeps it the same place.
    func place(at location: CLLocation) async throws -> Place {
        guard let request = MKReverseGeocodingRequest(location: location) else {
            throw LocationError.unavailable
        }
        guard let item = try await request.mapItems.first, let nearby = Self.place(from: item) else {
            throw LocationError.unavailable
        }
        // The reverse lookup is pinned to the device's own coordinate. Looking
        // the city up by name gives its center instead, and with it the same
        // id as when it's searched for, so a starred city stays starred.
        let query = [nearby.name, nearby.admin1, nearby.country].compactMap { $0 }.joined(separator: ", ")
        let city = try? await Self.search(query).first { $0.name == nearby.name }
        return city ?? nearby
    }

    /// A search result as a `Place`, or `nil` for one with no usable name.
    private static func place(from item: MKMapItem) -> Place? {
        let coordinate = item.location.coordinate
        let representations = item.addressRepresentations
        guard let name = representations?.cityName ?? item.name else { return nil }

        return Place(
            id: Place.id(latitude: coordinate.latitude, longitude: coordinate.longitude),
            name: name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            country: representations?.regionName,
            admin1: region(of: representations, city: name),
            timeZoneIdentifier: item.timeZone?.identifier
        )
    }

    /// The state or province, which MapKit only offers inside the city's
    /// "with context" form: "Seattle, WA" gives "WA". `nil` when there's no
    /// context beyond the city and country.
    private static func region(of representations: MKAddressRepresentations?, city: String) -> String? {
        guard let context = representations?.cityWithContext(.full) else { return nil }
        let country = representations?.regionName ?? ""
        return context
            .split(separator: ",")
            .map { part in
                // Some results run the country into the region
                // ("CA United States"), and it's shown separately.
                var part = part.trimmingCharacters(in: .whitespaces)
                if !country.isEmpty, part.hasSuffix(country) {
                    part = String(part.dropLast(country.count)).trimmingCharacters(in: .whitespaces)
                }
                // Canadian results can lead with the city again ("Grand
                // Forks BC"); it's already the place's name.
                if part.hasPrefix(city + " ") {
                    part = String(part.dropFirst(city.count + 1))
                }
                return part
            }
            .first { !$0.isEmpty && $0 != city && $0 != country }
    }

    /// The place's time zone, looked up from its coordinate when it was saved
    /// without one. Falls back to the device's zone if that fails too.
    private static func timeZone(for place: Place, at location: CLLocation) async -> TimeZone {
        if let identifier = place.timeZoneIdentifier, let zone = TimeZone(identifier: identifier) {
            return zone
        }
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first,
              let zone = item.timeZone
        else { return .current }
        return zone
    }

    // MARK: - Forecasts

    private static func dailyForecasts(
        from days: WeatherKit.Forecast<DayWeather>,
        calendar: Calendar
    ) -> [DailyForecast] {
        let weekdayStyle = Date.FormatStyle(timeZone: calendar.timeZone).weekday(.abbreviated)
        let timeStyle = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone)

        return days.map { day in
            // WeatherKit marks each day by its start in the place's own zone.
            let date = calendar.startOfDay(for: day.date)
            return DailyForecast(
                date: date,
                weekday: date.formatted(weekdayStyle),
                isToday: calendar.isDate(date, inSameDayAs: .now),
                condition: WeatherCondition(day.condition),
                highCelsius: day.highTemperature.converted(to: .celsius).value,
                lowCelsius: day.lowTemperature.converted(to: .celsius).value,
                precipitationProbability: Int((day.precipitationChance * 100).rounded()),
                // All types together, snow as its liquid equivalent.
                precipitationMillimeters: day.precipitationAmountByType.precipitation.converted(to: .millimeters).value,
                sunriseLabel: day.sun.sunrise?.formatted(timeStyle),
                sunsetLabel: day.sun.sunset?.formatted(timeStyle)
            )
        }
    }

    private static func hourlyForecasts(
        from hours: WeatherKit.Forecast<HourWeather>,
        timeZone: TimeZone
    ) -> [HourlyForecast] {
        let hourStyle = Date.FormatStyle(timeZone: timeZone).hour()

        return hours.map { hour in
            HourlyForecast(
                date: hour.date,
                hourLabel: hour.date.formatted(hourStyle),
                condition: WeatherCondition(hour.condition),
                isDaytime: hour.isDaylight,
                temperatureCelsius: hour.temperature.converted(to: .celsius).value,
                precipitationProbability: Int((hour.precipitationChance * 100).rounded())
            )
        }
    }
}

/// One query's worth of `MKLocalSearchCompleter` results, awaited instead of
/// delegated. Single use: the completer reports through its delegate, and a
/// fresh one per query means no answer can arrive for the wrong question.
@MainActor private final class CityCompleter: NSObject, MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()
    private var continuation: CheckedContinuation<[MKLocalSearchCompletion], any Error>?

    func completions(for query: String) async throws -> [MKLocalSearchCompletion] {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            completer.delegate = self
            completer.resultTypes = .address
            // Cities only. Without this, streets named after the city
            // ("Seattle St" in Modesto) crowd out the cities themselves.
            completer.addressFilter = MKAddressFilter(including: .locality)
            completer.queryFragment = query
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            continuation?.resume(returning: completer.results)
            continuation = nil
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            // No match is an ordinary answer for a half-typed name.
            if let error = error as? MKError, error.code == .placemarkNotFound {
                continuation?.resume(returning: [])
            } else {
                continuation?.resume(throwing: error)
            }
            continuation = nil
        }
    }
}

/// Why the weather where someone is couldn't be shown. Shared with the
/// widget target, which compiles this file but not the location code.
nonisolated enum LocationError: LocalizedError {
    case denied
    case unavailable

    var errorDescription: String? {
        switch self {
        case .denied:
            #if os(macOS)
            "Location access is off for Vane. Turn it on in System Settings > Privacy & Security > Location Services."
            #else
            "Location access is off for Vane. Turn it on in Settings > Apps > Vane > Location."
            #endif
        case .unavailable:
            "Couldn't find your location right now. Try again in a moment."
        }
    }
}

extension WeatherAlert.Severity {
    nonisolated init(_ severity: WeatherKit.WeatherSeverity) {
        switch severity {
        case .minor: self = .minor
        case .moderate: self = .moderate
        case .severe: self = .severe
        case .extreme: self = .extreme
        default: self = .unknown
        }
    }
}

extension CurrentWeather.PressureTrend {
    nonisolated init?(_ trend: WeatherKit.PressureTrend) {
        switch trend {
        case .rising: self = .rising
        case .falling: self = .falling
        case .steady: self = .steady
        @unknown default: return nil
        }
    }
}

extension WeatherCondition {
    /// Folds WeatherKit's conditions into this app's smaller set. Conditions
    /// that describe temperature rather than sky, such as hot or frigid, read
    /// as clear, which is what they almost always come with.
    nonisolated init(_ condition: WeatherKit.WeatherCondition) {
        switch condition {
        case .clear, .hot, .frigid: self = .clear
        case .mostlyClear: self = .mainlyClear
        case .partlyCloudy: self = .partlyCloudy
        case .mostlyCloudy, .cloudy: self = .overcast
        case .foggy: self = .fog
        case .haze, .smoky, .blowingDust: self = .haze
        case .breezy, .windy: self = .windy
        case .drizzle: self = .drizzle
        case .freezingDrizzle: self = .freezingDrizzle
        case .rain, .heavyRain: self = .rain
        case .sunShowers: self = .showers
        case .freezingRain, .sleet, .wintryMix: self = .freezingRain
        case .hail: self = .hail
        case .snow, .heavySnow, .blizzard, .blowingSnow: self = .snow
        case .flurries, .sunFlurries: self = .snowShowers
        case .isolatedThunderstorms, .scatteredThunderstorms, .thunderstorms, .strongStorms,
             .tropicalStorm, .hurricane:
            self = .thunderstorm
        @unknown default: self = .unknown
        }
    }
}
