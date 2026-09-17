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
                        units: store.unitPreference
                    )
                    ForecastCard(days: report.daily, units: store.unitPreference)
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
                }
            }
            .accessibilityElement(children: .combine)

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
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: .rect(cornerRadius: 20))
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

private struct ForecastCard: View {
    let days: [DailyForecast]
    let units: UnitPreference

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(days) { day in
                VStack(spacing: 8) {
                    Text(day.isToday ? "Today" : day.weekday)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(day.isToday ? .primary : .secondary)
                    Image(systemName: day.condition.symbolName(isDaytime: true))
                        .font(.title3)
                        .symbolRenderingMode(.multicolor)
                        .accessibilityHidden(true)
                    Text(day.highCelsius.temperatureText(in: units))
                        .font(.callout.weight(.medium))
                    Text(day.lowCelsius.temperatureText(in: units))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel(for: day))
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .glassEffect(in: .rect(cornerRadius: 20))
    }

    private func accessibilityLabel(for day: DailyForecast) -> String {
        let name = day.isToday ? "Today" : day.weekday
        let high = day.highCelsius.temperatureText(in: units)
        let low = day.lowCelsius.temperatureText(in: units)
        return "\(name), \(day.condition.description), high \(high), low \(low)"
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
