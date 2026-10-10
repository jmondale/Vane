import SwiftUI

struct ContentView: View {
    @State private var store = WeatherStore()

    /// The suggestion the arrow keys have moved to, if any. `nil` means the
    /// typed text itself is what Return will submit.
    @State private var highlightedSuggestion: Place.ID?

    var body: some View {
        VStack(spacing: 16) {
            searchBar

            // The suggestion list overlays the forecast rather than pushing it
            // down, so the layout doesn't jump while typing.
            ZStack(alignment: .topLeading) {
                VStack(spacing: 16) {
                    errorBanner
                    content
                    Spacer(minLength: 0)
                }

                if !store.suggestions.isEmpty {
                    SuggestionList(
                        places: store.suggestions,
                        highlighted: highlightedSuggestion,
                        onSelect: select
                    )
                    .frame(maxWidth: 380, alignment: .leading)
                }
            }
            .animation(.easeOut(duration: 0.15), value: store.suggestions)
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 540)
        .background(conditionBackground)
        .task { await store.restoreSelectedPlace() }
        .task(id: store.query) { await store.updateSuggestions() }
        .onChange(of: store.suggestions) { _, _ in highlightedSuggestion = nil }
        .onOpenURL { url in
            guard let id = PlaceLink.placeID(from: url) else { return }
            Task { await store.selectPlace(id: id) }
        }
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search for a city", text: $store.query)
                    .textFieldStyle(.plain)
                    .onSubmit(submit)
                    .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                    .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                    .onKeyPress(.escape) {
                        guard !store.suggestions.isEmpty else { return .ignored }
                        store.dismissSuggestions()
                        return .handled
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect()

            Picker("Units", selection: $store.unitPreference) {
                ForEach(UnitPreference.allCases) { preference in
                    Text(preference.label).tag(preference)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 96)

            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.glass)
            .disabled(store.place == nil || store.isLoading)
            .accessibilityLabel("Refresh forecast")
        }
    }

    private func select(_ place: Place) {
        Task { await store.select(place) }
    }

    /// Return picks the highlighted suggestion, or falls back to searching the
    /// typed text and loading its best match.
    private func submit() {
        if let id = highlightedSuggestion,
           let place = store.suggestions.first(where: { $0.id == id }) {
            select(place)
        } else {
            Task { await store.search() }
        }
    }

    private func moveHighlight(by offset: Int) -> KeyPress.Result {
        let places = store.suggestions
        guard !places.isEmpty else { return .ignored }

        guard let current = highlightedSuggestion,
              let index = places.firstIndex(where: { $0.id == current })
        else {
            highlightedSuggestion = offset > 0 ? places.first?.id : places.last?.id
            return .handled
        }

        // Stepping off either end returns focus to the typed text.
        let next = index + offset
        highlightedSuggestion = places.indices.contains(next) ? places[next].id : nil
        return .handled
    }

    // MARK: - Content

    @ViewBuilder private var errorBanner: some View {
        // Shown as a banner only when there is still a previous forecast on
        // screen; otherwise the failure takes over the whole content area.
        if let message = store.errorMessage, store.report != nil {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(in: .rect(cornerRadius: 12))
        }
    }

    @ViewBuilder private var content: some View {
        if let report = store.report, let place = store.place {
            GlassEffectContainer(spacing: 16) {
                VStack(spacing: 16) {
                    CurrentConditionsCard(
                        place: place,
                        current: report.current,
                        today: report.today,
                        units: store.unitPreference
                    )
                    ForecastCard(report: report, units: store.unitPreference)
                }
            }
            .opacity(store.isLoading ? 0.5 : 1)
            .animation(.easeInOut(duration: 0.2), value: store.isLoading)
        } else if store.isLoading {
            ProgressView("Loading forecast\u{2026}")
                .padding(32)
                .frame(maxWidth: .infinity)
        } else if let message = store.errorMessage {
            MessageView(
                symbol: "exclamationmark.triangle.fill",
                title: "Couldn't load weather",
                message: message
            )
        } else {
            MessageView(
                symbol: "cloud.sun.fill",
                title: "Search for a city",
                message: "Start typing a city name and pick it from the list."
            )
        }
    }

    private var conditionBackground: some View {
        let condition = store.report?.current.condition ?? .clear
        let isDaytime = store.report?.current.isDaytime ?? true
        return condition.gradient(isDaytime: isDaytime, opacity: 0.3)
            .background(.background)
            .ignoresSafeArea()
    }
}

// MARK: - Completion list

private struct SuggestionList: View {
    let places: [Place]
    let highlighted: Place.ID?
    let onSelect: (Place) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(places) { place in
                SuggestionRow(
                    place: place,
                    isHighlighted: place.id == highlighted,
                    onSelect: { onSelect(place) }
                )
                if place.id != places.last?.id {
                    Divider().padding(.leading, 12)
                }
            }
        }
        .padding(.vertical, 6)
        .glassEffect(in: .rect(cornerRadius: 14))
        .shadow(radius: 12, y: 4)
    }
}

private struct SuggestionRow: View {
    let place: Place
    let isHighlighted: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 1) {
                Text(place.name)
                if !place.region.isEmpty {
                    Text(place.region)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background {
            if isHighlighted || isHovered {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(isHighlighted ? 0.28 : 0.14))
                    .padding(.horizontal, 6)
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel(place.fullName)
    }
}

// MARK: - Cards

private struct CurrentConditionsCard: View {
    let place: Place
    let current: CurrentWeather

    /// Today's forecast, for the precipitation total. Open-Meteo's *current*
    /// precipitation is only the last hour, which reads as 0 most of the time
    /// and says nothing useful about the day ahead.
    let today: DailyForecast?

    let units: UnitPreference

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .font(.title2.weight(.semibold))
                if !place.region.isEmpty {
                    Text(place.region)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .center, spacing: 20) {
                Image(systemName: current.condition.symbolName(isDaytime: current.isDaytime))
                    .font(.system(size: 52))
                    .symbolRenderingMode(.multicolor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(current.temperatureCelsius.temperatureText(in: units))
                        .font(.system(size: 52, weight: .light))
                        .contentTransition(.numericText())
                    Text(current.condition.description)
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    // The day's full range, in the same "H:… L:…" shorthand the
                    // widget uses, so both surfaces read the same way.
                    if let today {
                        HStack(spacing: 8) {
                            Text("H:\(today.highCelsius.temperatureText(in: units))")
                            Text("L:\(today.lowCelsius.temperatureText(in: units))")
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline.weight(.medium))
                        .contentTransition(.numericText())
                        .padding(.top, 2)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            // Spelled out, because "H:" and "L:" are read aloud as letters.
            .accessibilityLabel(temperatureAccessibilityLabel)

            HStack(spacing: 12) {
                DetailTile(
                    symbol: "thermometer.medium",
                    label: "Feels like",
                    value: current.apparentTemperatureCelsius.temperatureText(in: units)
                )
                DetailTile(
                    symbol: "humidity.fill",
                    label: "Humidity",
                    value: current.relativeHumidity.formatted(.percent)
                )
                DetailTile(
                    symbol: "wind",
                    label: "Wind",
                    value: current.windSpeedKPH.windSpeedText(in: units)
                )
                DetailTile(
                    symbol: "drop.fill",
                    label: "Rain",
                    value: today?.precipitationMillimeters.precipitationText(in: units) ?? "—"
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: .rect(cornerRadius: 20))
    }

    private var temperatureAccessibilityLabel: String {
        var label = current.temperatureCelsius.temperatureText(in: units)
        label += ", \(current.condition.description)"
        if let today {
            label += ", high \(today.highCelsius.temperatureText(in: units))"
            label += ", low \(today.lowCelsius.temperatureText(in: units))"
        }
        return label
    }
}

private struct DetailTile: View {
    let symbol: String
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Label(label, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.medium))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The seven-day row. Clicking a day opens its hourly breakdown underneath;
/// clicking it again, or another day, closes or switches it.
private struct ForecastCard: View {
    let report: WeatherReport
    let units: UnitPreference

    /// The day whose hours are showing, if any.
    @State private var expandedDay: DailyForecast.ID?

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 4) {
                ForEach(report.daily) { day in
                    DayColumn(
                        day: day,
                        units: units,
                        isExpanded: day.id == expandedDay,
                        isExpandable: !report.hours(for: day).isEmpty,
                        onToggle: { toggle(day) }
                    )
                }
            }

            if let day = report.daily.first(where: { $0.id == expandedDay }) {
                Divider()
                HourlyStrip(hours: upcomingHours(for: day), units: units)
                    // A fresh strip per day, so switching days starts scrolled
                    // to the first hour instead of keeping the old offset.
                    .id(day.id)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .glassEffect(in: .rect(cornerRadius: 20))
    }

    private func toggle(_ day: DailyForecast) {
        withAnimation(.snappy(duration: 0.25)) {
            expandedDay = expandedDay == day.id ? nil : day.id
        }
    }

    /// The day's hours, minus any that have already ended. Only today has
    /// those, and they're forecasts for the past, so they aren't worth showing.
    private func upcomingHours(for day: DailyForecast) -> [HourlyForecast] {
        let hours = report.hours(for: day)
        let now = Date.now
        let upcoming = hours.filter { $0.date.addingTimeInterval(3_600) > now }
        // A report fetched yesterday may have nothing left for the day it
        // calls today; showing the stale hours beats an empty strip.
        return upcoming.isEmpty ? hours : upcoming
    }
}

private struct DayColumn: View {
    let day: DailyForecast
    let units: UnitPreference
    let isExpanded: Bool

    /// False when the report carries no hours for this day, such as one
    /// restored from the widget's cache, so there's nothing to open.
    let isExpandable: Bool

    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onToggle) {
            VStack(spacing: 8) {
                Text(day.isToday ? "Today" : day.weekday)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(day.isToday || isExpanded ? .primary : .secondary)
                Image(systemName: day.condition.symbolName(isDaytime: true))
                    .font(.title3)
                    .symbolRenderingMode(.multicolor)
                    // These symbols differ in intrinsic height — cloud.fill
                    // is much shorter than cloud.sun.fill — so without a
                    // fixed height every row below sits at a different
                    // level from one column to the next.
                    .frame(height: 24)
                    .accessibilityHidden(true)
                Text(day.highCelsius.temperatureText(in: units))
                    .font(.callout.weight(.medium))
                Text(day.lowCelsius.temperatureText(in: units))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                PrecipitationChance(text: day.precipitationChanceText)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isExpandable)
        .background {
            if isExpanded || isHovered {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(isExpanded ? 0.22 : 0.1))
            }
        }
        .onHover { isHovered = isExpandable && $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isExpanded ? "Hides the hourly forecast" : "Shows the hourly forecast")
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
    }

    private var accessibilityLabel: String {
        let name = day.isToday ? "Today" : day.weekday
        let high = day.highCelsius.temperatureText(in: units)
        let low = day.lowCelsius.temperatureText(in: units)
        var label = "\(name), \(day.condition.description), high \(high), low \(low)"

        // Spoken in full, unlike the abbreviated column, and only when there's
        // something to report.
        if let chance = day.precipitationChanceText {
            let amount = day.precipitationMillimeters.precipitationText(in: units)
            label += ", \(chance) chance of precipitation, \(amount) expected"
        }
        return label
    }
}

/// One day's hours, scrolled sideways. Columns match the daily row's layout so
/// the two read as one card.
private struct HourlyStrip: View {
    let hours: [HourlyForecast]
    let units: UnitPreference

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 4) {
                ForEach(hours) { hour in
                    let isNow = Self.isCurrent(hour)
                    VStack(spacing: 8) {
                        Text(isNow ? "Now" : hour.hourLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(isNow ? .primary : .secondary)
                        Image(systemName: hour.condition.symbolName(isDaytime: hour.isDaytime))
                            .font(.title3)
                            .symbolRenderingMode(.multicolor)
                            .frame(height: 24)
                            .accessibilityHidden(true)
                        Text(hour.temperatureCelsius.temperatureText(in: units))
                            .font(.callout.weight(.medium))
                        PrecipitationChance(text: hour.precipitationChanceText)
                    }
                    .frame(width: 48)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilityLabel(for: hour, isNow: isNow))
                }
            }
            .padding(.bottom, 4)
        }
    }

    private static func isCurrent(_ hour: HourlyForecast) -> Bool {
        let now = Date.now
        return hour.date <= now && now < hour.date.addingTimeInterval(3_600)
    }

    private func accessibilityLabel(for hour: HourlyForecast, isNow: Bool) -> String {
        let name = isNow ? "Now" : hour.hourLabel
        let temperature = hour.temperatureCelsius.temperatureText(in: units)
        var label = "\(name), \(hour.condition.description), \(temperature)"
        if let chance = hour.precipitationChanceText {
            label += ", \(chance) chance of precipitation"
        }
        return label
    }
}

/// The droplet and percentage for a wet day or hour. The row is reserved even
/// when there's no chance worth showing, so a mix of wet and dry columns
/// doesn't leave them at different heights.
private struct PrecipitationChance: View {
    let text: String?

    var body: some View {
        HStack(spacing: 2) {
            if let text {
                Image(systemName: "drop.fill")
                    .font(.system(size: 8))
                Text(text)
                    .font(.caption2)
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.secondary)
        .frame(height: 12)
    }
}

private struct MessageView: View {
    let symbol: String
    let title: String
    let message: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    ContentView()
}

// MARK: - Card previews
//
// The live `ContentView` preview above restores a saved place and fetches, so a
// snapshot of it almost always catches the loading spinner. These render the
// cards from fixed data instead, at the window's 480pt minimum width, which is
// the tight case for the detail tile row.

private extension Place {
    static let preview = Place(
        id: 5_780_026,
        name: "Cedar Hills",
        latitude: 40.4119,
        longitude: -111.7527,
        country: "United States",
        admin1: "Utah"
    )
}

private extension CurrentWeather {
    static let preview = CurrentWeather(
        temperatureCelsius: 18,
        apparentTemperatureCelsius: 17,
        relativeHumidity: 46,
        windSpeedKPH: 11,
        condition: .partlyCloudy,
        isDaytime: true
    )
}

private extension DailyForecast {
    /// A wet day, so the precipitation chance is above the display threshold.
    static let preview = DailyForecast(
        date: Date(timeIntervalSince1970: 1_789_000_000),
        weekday: "Tue",
        isToday: true,
        condition: .partlyCloudy,
        highCelsius: 24,
        lowCelsius: 11,
        precipitationProbability: 50,
        precipitationMillimeters: 1.4
    )

    /// Seven days mixing wet and dry, to check that the reserved chance row
    /// keeps the columns aligned.
    static let previewWeek: [DailyForecast] = {
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        let days: [(WeatherCondition, Double, Double, Int, Double)] = [
            (.partlyCloudy, 24, 11, 50, 1.4),
            (.mainlyClear, 26, 12, 8, 0),
            (.clear, 27, 13, 0, 0),
            (.rain, 19, 11, 80, 6.4),
            (.showers, 18, 10, 65, 3.1),
            (.overcast, 21, 12, 26, 0),
            (.clear, 23, 13, 3, 0)
        ]
        let weekdayStyle = Date.FormatStyle().weekday(.abbreviated)
        return days.enumerated().map { index, day in
            let date = start.addingTimeInterval(Double(index) * 86_400)
            return DailyForecast(
                date: date,
                weekday: date.formatted(weekdayStyle),
                isToday: index == 0,
                condition: day.0,
                highCelsius: day.1,
                lowCelsius: day.2,
                precipitationProbability: day.3,
                precipitationMillimeters: day.4
            )
        }
    }()
}

private extension WeatherReport {
    /// The preview week with a full day of hours behind each entry, warming
    /// through the afternoon and turning wet in the evening on rainy days.
    static let preview: WeatherReport = {
        let hourly = DailyForecast.previewWeek.flatMap { day in
            (0..<24).map { hour in
                let date = day.date.addingTimeInterval(Double(hour) * 3_600)
                // Coldest at 5am, warmest at 3pm.
                let warmth = (1 - cos(Double(hour - 5) / 10 * .pi)) / 2
                let isWetHour = day.precipitationProbability >= 50 && hour >= 15
                return HourlyForecast(
                    date: date,
                    hourLabel: date.formatted(Date.FormatStyle().hour()),
                    condition: isWetHour ? day.condition : .mainlyClear,
                    isDaytime: (7..<19).contains(hour),
                    temperatureCelsius: day.lowCelsius + (day.highCelsius - day.lowCelsius) * warmth,
                    precipitationProbability: isWetHour ? day.precipitationProbability : 0
                )
            }
        }
        return WeatherReport(current: .preview, daily: DailyForecast.previewWeek, hourly: hourly)
    }()
}

#Preview("Cards", traits: .sizeThatFitsLayout) {
    VStack(spacing: 16) {
        CurrentConditionsCard(
            place: .preview,
            current: .preview,
            today: .preview,
            units: .metric
        )
        ForecastCard(report: .preview, units: .metric)
    }
    .padding(20)
    .frame(width: 480)
    .background(WeatherCondition.partlyCloudy.gradient(isDaytime: true, opacity: 0.3))
}
