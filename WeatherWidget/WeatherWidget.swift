import WidgetKit
import SwiftUI

/// One resolved place and its forecast — everything a widget refresh renders.
nonisolated struct WidgetSnapshot: Sendable {
    let place: Place
    let report: WeatherReport
}

/// Resolves the configured city name and fetches its forecast, reusing the
/// app's `WeatherService`.
nonisolated struct WidgetWeatherLoader: Sendable {
    enum LoaderError: LocalizedError {
        case emptyCity
        case cityNotFound(String)

        var errorDescription: String? {
            switch self {
            case .emptyCity:
                "Choose a city in this widget's settings."
            case .cityNotFound(let city):
                "Couldn't find \u{201C}\(city)\u{201D}."
            }
        }
    }

    /// The medium widget shows four days; no point fetching the app's seven.
    private static let forecastDays = 4

    private let service = WeatherService()

    func load(city: String) async throws -> WidgetSnapshot {
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LoaderError.emptyCity }

        guard let place = try await service.places(matching: trimmed).first else {
            throw LoaderError.cityNotFound(trimmed)
        }

        let report = try await service.report(for: place, forecastDays: Self.forecastDays)
        return WidgetSnapshot(place: place, report: report)
    }
}

struct WeatherEntry: TimelineEntry {
    let date: Date
    let configuration: ConfigurationAppIntent
    let snapshot: WidgetSnapshot?
    let errorMessage: String?
}

struct Provider: AppIntentTimelineProvider {
    private let loader = WidgetWeatherLoader()

    /// How long the system waits before asking for a new timeline. Conditions
    /// move slowly enough that half an hour is plenty, and WidgetKit budgets
    /// refreshes anyway.
    private static let refreshInterval: TimeInterval = 30 * 60

    func placeholder(in context: Context) -> WeatherEntry {
        WeatherEntry(
            date: .now,
            configuration: ConfigurationAppIntent(),
            snapshot: .placeholder,
            errorMessage: nil
        )
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> WeatherEntry {
        // The widget gallery shows the snapshot, so avoid a network round trip
        // there and render the sample instead.
        if context.isPreview {
            return WeatherEntry(
                date: .now,
                configuration: configuration,
                snapshot: .placeholder,
                errorMessage: nil
            )
        }
        return await loadEntry(for: configuration)
    }

    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<WeatherEntry> {
        let entry = await loadEntry(for: configuration)
        let next = Date.now.addingTimeInterval(Self.refreshInterval)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func loadEntry(for configuration: ConfigurationAppIntent) async -> WeatherEntry {
        do {
            let snapshot = try await loader.load(city: configuration.city)
            return WeatherEntry(date: .now, configuration: configuration, snapshot: snapshot, errorMessage: nil)
        } catch {
            return WeatherEntry(
                date: .now,
                configuration: configuration,
                snapshot: nil,
                errorMessage: error.localizedDescription
            )
        }
    }
}

struct WeatherWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family

    var entry: Provider.Entry

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .systemSmall:
                SmallWeatherView(snapshot: snapshot)
            default:
                MediumWeatherView(snapshot: snapshot)
            }
        } else {
            UnavailableView(message: entry.errorMessage ?? "Weather is unavailable.")
        }
    }
}

private struct SmallWeatherView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        let current = snapshot.report.current

        VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.place.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(current.temperatureCelsius.localeTemperatureText)
                    .font(.system(size: 34, weight: .light))
                Image(systemName: current.condition.symbolName(isDaytime: current.isDaytime))
                    .font(.title3)
                    .symbolRenderingMode(.multicolor)
            }

            Text(current.condition.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(snapshot.place.name), \(current.temperatureCelsius.localeTemperatureText), \(current.condition.description)"
        )
    }
}

private struct MediumWeatherView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        let current = snapshot.report.current

        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.place.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(current.temperatureCelsius.localeTemperatureText)
                        .font(.system(size: 36, weight: .light))
                    Image(systemName: current.condition.symbolName(isDaytime: current.isDaytime))
                        .font(.title3)
                        .symbolRenderingMode(.multicolor)
                }

                Text(current.condition.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)

            HStack(alignment: .top, spacing: 10) {
                ForEach(snapshot.report.daily) { day in
                    VStack(spacing: 4) {
                        Text(day.isToday ? "Today" : day.weekday)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: day.condition.symbolName(isDaytime: true))
                            .font(.caption)
                            .symbolRenderingMode(.multicolor)
                        Text(day.highCelsius.localeTemperatureText)
                            .font(.caption2.weight(.medium))
                        Text(day.lowCelsius.localeTemperatureText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilityLabel(for: day))
                }
            }
        }
    }

    private func accessibilityLabel(for day: DailyForecast) -> String {
        let name = day.isToday ? "Today" : day.weekday
        return "\(name), \(day.condition.description), high \(day.highCelsius.localeTemperatureText), low \(day.lowCelsius.localeTemperatureText)"
    }
}

private struct UnavailableView: View {
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "cloud.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WeatherWidget: Widget {
    let kind: String = "WeatherWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ConfigurationAppIntent.self, provider: Provider()) { entry in
            WeatherWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Weather")
        .description("Current conditions and a short forecast for a city you choose.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Sample data

extension WidgetSnapshot {
    /// Stand-in data for the widget gallery and previews, where a network
    /// round trip isn't appropriate.
    static let placeholder: WidgetSnapshot = {
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        let conditions: [(WeatherCondition, Double, Double)] = [
            (.mainlyClear, 24, 13),
            (.partlyCloudy, 23, 12),
            (.overcast, 21, 12),
            (.rain, 19, 11)
        ]

        let weekdayStyle = Date.FormatStyle().weekday(.abbreviated)
        let days = conditions.enumerated().map { index, entry in
            let date = start.addingTimeInterval(Double(index) * 86_400)
            return DailyForecast(
                date: date,
                weekday: date.formatted(weekdayStyle),
                isToday: index == 0,
                condition: entry.0,
                highCelsius: entry.1,
                lowCelsius: entry.2
            )
        }

        return WidgetSnapshot(
            place: Place(
                id: 5_341_145,
                name: "Cupertino",
                latitude: 37.32298,
                longitude: -122.03219,
                country: "United States",
                admin1: "California"
            ),
            report: WeatherReport(
                current: CurrentWeather(
                    temperatureCelsius: 21,
                    apparentTemperatureCelsius: 21,
                    relativeHumidity: 60,
                    windSpeedKPH: 8,
                    condition: .mainlyClear,
                    isDaytime: true
                ),
                daily: days
            )
        )
    }()
}

private extension ConfigurationAppIntent {
    static var cupertino: ConfigurationAppIntent {
        let intent = ConfigurationAppIntent()
        intent.city = "Cupertino"
        return intent
    }
}

#Preview(as: .systemSmall) {
    WeatherWidget()
} timeline: {
    WeatherEntry(date: .now, configuration: .cupertino, snapshot: .placeholder, errorMessage: nil)
}

#Preview(as: .systemMedium) {
    WeatherWidget()
} timeline: {
    WeatherEntry(date: .now, configuration: .cupertino, snapshot: .placeholder, errorMessage: nil)
}
