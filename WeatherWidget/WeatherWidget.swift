import WidgetKit
import SwiftUI

/// One resolved place and its forecast — everything a widget refresh renders.
struct WidgetSnapshot: Sendable {
    let place: Place
    let report: WeatherReport

    /// Read from the shared defaults, so the widget shows degrees in whichever
    /// unit was picked in the app.
    let units: UnitPreference

    /// When the report was fetched, if this is a cached copy served because the
    /// network failed. `nil` means it came from this refresh.
    let staleSince: Date?
}

struct WeatherEntry: TimelineEntry {
    let date: Date
    let configuration: ConfigurationAppIntent
    let snapshot: WidgetSnapshot?
    let errorMessage: String?

    /// True when this entry carries a report fetched during this refresh.
    var isFresh: Bool {
        guard let snapshot else { return false }
        return snapshot.staleSince == nil
    }
}

struct Provider: AppIntentTimelineProvider {
    private enum LoaderError: LocalizedError {
        case noCity

        var errorDescription: String? {
            "Choose a city in this widget's settings, or pick one in Vane."
        }
    }

    /// The large layout shows a full week and the smaller ones slice it down,
    /// so a single request serves every family.
    private static let forecastDays = 7

    /// Conditions move slowly and WidgetKit budgets refreshes anyway, so half
    /// an hour is plenty in steady state. A failure is worth retrying sooner.
    private static let refreshInterval: TimeInterval = 30 * 60
    private static let retryInterval: TimeInterval = 10 * 60

    private let service = WeatherService()
    private let shared = SharedStore()

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
        let interval = entry.isFresh ? Self.refreshInterval : Self.retryInterval
        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(interval)))
    }

    private func loadEntry(for configuration: ConfigurationAppIntent) async -> WeatherEntry {
        let units = shared.unitPreference

        // An unconfigured widget follows the app's current city, so it shows
        // something useful before anyone opens its settings.
        guard let place = configuration.place?.place ?? shared.selectedPlace else {
            return WeatherEntry(
                date: .now,
                configuration: configuration,
                snapshot: nil,
                errorMessage: LoaderError.noCity.localizedDescription
            )
        }

        do {
            let report = try await service.report(for: place, forecastDays: Self.forecastDays)
            shared.cache(report, for: place)
            return WeatherEntry(
                date: .now,
                configuration: configuration,
                snapshot: WidgetSnapshot(place: place, report: report, units: units, staleSince: nil),
                errorMessage: nil
            )
        } catch {
            // One dropped request shouldn't blank the widget for half an hour.
            // Serve the last good report and label how old it is, rather than
            // replacing real data with an error.
            if let cached = shared.cachedReport(for: place.id) {
                return WeatherEntry(
                    date: .now,
                    configuration: configuration,
                    snapshot: WidgetSnapshot(
                        place: cached.place,
                        report: cached.report,
                        units: units,
                        staleSince: cached.fetchedAt
                    ),
                    errorMessage: nil
                )
            }
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
        content
            // One widgetURL for the whole hierarchy — more than one is
            // undefined behaviour — so a click anywhere opens this city.
            .widgetURL(entry.snapshot.flatMap { PlaceLink.url(for: $0.place.id) })
            .containerBackground(for: .widget) { background }
    }

    @ViewBuilder private var content: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .systemSmall:
                SmallWeatherView(snapshot: snapshot)
            case .systemLarge:
                LargeWeatherView(snapshot: snapshot)
            default:
                MediumWeatherView(snapshot: snapshot)
            }
        } else {
            UnavailableView(message: entry.errorMessage ?? "Weather is unavailable.")
        }
    }

    /// The condition's own tints, over the system's widget fill. Uses the same
    /// mapping as the app window, so a given sky reads the same in both.
    @ViewBuilder private var background: some View {
        if let current = entry.snapshot?.report.current {
            current.condition
                .gradient(isDaytime: current.isDaytime, opacity: 0.45)
                .background(.fill.tertiary)
        } else {
            Color.clear.background(.fill.tertiary)
        }
    }
}

// MARK: - Layouts

private struct SmallWeatherView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        let current = snapshot.report.current

        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.place.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(current.temperatureCelsius.temperatureText(in: snapshot.units))
                    .font(.system(size: 44, weight: .light))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Image(systemName: current.condition.symbolName(isDaytime: current.isDaytime))
                    .font(.title3)
                    .symbolRenderingMode(.multicolor)
            }

            Text(current.condition.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if let today = snapshot.report.daily.first {
                HighLowLabel(day: today, units: snapshot.units)
            }

            StaleFooter(staleSince: snapshot.staleSince, compact: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(snapshot.place.name), \(current.temperatureCelsius.temperatureText(in: snapshot.units)), \(current.condition.description)"
        )
    }
}

private struct MediumWeatherView: View {
    let snapshot: WidgetSnapshot

    /// Four days is what fits beside the current conditions without crowding.
    private static let dayCount = 4

    var body: some View {
        let current = snapshot.report.current

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.place.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(current.temperatureCelsius.temperatureText(in: snapshot.units))
                            .font(.system(size: 44, weight: .light))
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
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
                    ForEach(snapshot.report.daily.prefix(Self.dayCount)) { day in
                        DayColumn(day: day, units: snapshot.units)
                    }
                }
            }

            Spacer(minLength: 0)

            StaleFooter(staleSince: snapshot.staleSince, compact: false)
        }
    }
}

private struct LargeWeatherView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        let current = snapshot.report.current

        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.place.name)
                    .font(.headline)
                    .lineLimit(1)
                if !snapshot.place.region.isEmpty {
                    Text(snapshot.place.region)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(alignment: .center, spacing: 14) {
                Image(systemName: current.condition.symbolName(isDaytime: current.isDaytime))
                    .font(.system(size: 40))
                    .symbolRenderingMode(.multicolor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 0) {
                    Text(current.temperatureCelsius.temperatureText(in: snapshot.units))
                        .font(.system(size: 48, weight: .light))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Text(current.condition.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(current.temperatureCelsius.temperatureText(in: snapshot.units)), \(current.condition.description)"
            )

            HStack(spacing: 8) {
                DetailChip(
                    symbol: "thermometer.medium",
                    label: "Feels",
                    value: current.apparentTemperatureCelsius.temperatureText(in: snapshot.units)
                )
                DetailChip(
                    symbol: "humidity.fill",
                    label: "Humidity",
                    value: current.relativeHumidity.formatted(.percent)
                )
                DetailChip(
                    symbol: "wind",
                    label: "Wind",
                    value: current.windSpeedKPH.windSpeedText(in: snapshot.units)
                )
            }

            Divider()

            VStack(spacing: 2) {
                ForEach(snapshot.report.daily) { day in
                    DayRow(day: day, units: snapshot.units)
                }
            }

            Spacer(minLength: 0)

            StaleFooter(staleSince: snapshot.staleSince, compact: false)
        }
    }
}

// MARK: - Pieces

private struct DayColumn: View {
    let day: DailyForecast
    let units: UnitPreference

    var body: some View {
        VStack(spacing: 3) {
            Text(day.isToday ? "Today" : day.weekday)
                .font(.caption2.weight(day.isToday ? .semibold : .regular))
                .foregroundStyle(day.isToday ? .primary : .secondary)
                .lineLimit(1)
            Image(systemName: day.condition.symbolName(isDaytime: true))
                .font(.caption)
                .symbolRenderingMode(.multicolor)
            Text(day.highCelsius.temperatureText(in: units))
                .font(.caption2.weight(.medium))
            Text(day.lowCelsius.temperatureText(in: units))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(day.accessibilityLabel(units: units))
    }
}

private struct DayRow: View {
    let day: DailyForecast
    let units: UnitPreference

    var body: some View {
        HStack(spacing: 10) {
            Text(day.isToday ? "Today" : day.weekday)
                .font(.subheadline.weight(day.isToday ? .semibold : .regular))
                .foregroundStyle(day.isToday ? .primary : .secondary)
                .frame(width: 52, alignment: .leading)
                .lineLimit(1)

            Image(systemName: day.condition.symbolName(isDaytime: true))
                .font(.footnote)
                .symbolRenderingMode(.multicolor)
                .frame(width: 20)

            Spacer(minLength: 0)

            Text(day.lowCelsius.temperatureText(in: units))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(day.highCelsius.temperatureText(in: units))
                .font(.subheadline.weight(.medium))
                .frame(minWidth: 40, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(day.accessibilityLabel(units: units))
    }
}

private struct HighLowLabel: View {
    let day: DailyForecast
    let units: UnitPreference

    var body: some View {
        HStack(spacing: 6) {
            Text("H:\(day.highCelsius.temperatureText(in: units))")
            Text("L:\(day.lowCelsius.temperatureText(in: units))")
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
        .lineLimit(1)
    }
}

private struct DetailChip: View {
    let symbol: String
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 1) {
            Label(label, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Marks a report that's being shown because the last refresh failed, so an
/// old forecast never passes for a current one.
private struct StaleFooter: View {
    let staleSince: Date?
    let compact: Bool

    var body: some View {
        if let staleSince {
            let time = staleSince.formatted(date: .omitted, time: .shortened)
            Label(
                compact ? time : "As of \(time)",
                systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityLabel("Last updated \(time)")
        }
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

private extension DailyForecast {
    func accessibilityLabel(units: UnitPreference) -> String {
        let name = isToday ? "Today" : weekday
        let high = highCelsius.temperatureText(in: units)
        let low = lowCelsius.temperatureText(in: units)
        return "\(name), \(condition.description), high \(high), low \(low)"
    }
}

struct WeatherWidget: Widget {
    let kind: String = "WeatherWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ConfigurationAppIntent.self, provider: Provider()) { entry in
            WeatherWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Weather")
        .description("Current conditions and a short forecast for a city you choose.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Sample data

extension Place {
    /// Stand-in place for the widget gallery and previews.
    static let sample = Place(
        id: 5_341_145,
        name: "Cupertino",
        latitude: 37.32298,
        longitude: -122.03219,
        country: "United States",
        admin1: "California"
    )
}

extension WidgetSnapshot {
    /// Stand-in data for the widget gallery and previews, where a network
    /// round trip isn't appropriate.
    static let placeholder: WidgetSnapshot = {
        let start = Date(timeIntervalSince1970: 1_789_000_000)

        // Labelled rather than positional: there are enough columns now that
        // entry.0 through entry.4 would say nothing about what they hold.
        let conditions: [(
            condition: WeatherCondition,
            high: Double,
            low: Double,
            chance: Int,
            millimetres: Double
        )] = [
            (.mainlyClear, 24, 13, 0, 0),
            (.partlyCloudy, 23, 12, 10, 0.2),
            (.overcast, 21, 12, 25, 0.6),
            (.rain, 19, 11, 80, 6.4),
            (.showers, 18, 11, 65, 3.1),
            (.partlyCloudy, 20, 12, 15, 0.4),
            (.clear, 23, 13, 0, 0)
        ]

        let weekdayStyle = Date.FormatStyle().weekday(.abbreviated)
        let days = conditions.enumerated().map { index, entry in
            let date = start.addingTimeInterval(Double(index) * 86_400)
            return DailyForecast(
                date: date,
                weekday: date.formatted(weekdayStyle),
                isToday: index == 0,
                condition: entry.condition,
                highCelsius: entry.high,
                lowCelsius: entry.low,
                precipitationProbability: entry.chance,
                precipitationMillimeters: entry.millimetres
            )
        }

        return WidgetSnapshot(
            place: .sample,
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
            ),
            units: .metric,
            staleSince: nil
        )
    }()
}

private extension ConfigurationAppIntent {
    static var cupertino: ConfigurationAppIntent {
        let intent = ConfigurationAppIntent()
        intent.place = PlaceEntity(place: .sample)
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

#Preview(as: .systemLarge) {
    WeatherWidget()
} timeline: {
    WeatherEntry(date: .now, configuration: .cupertino, snapshot: .placeholder, errorMessage: nil)
}
