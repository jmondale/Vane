import SwiftUI

struct ContentView: View {
    @State private var store = WeatherStore()

    /// The suggestion the arrow keys have moved to, if any. `nil` means the
    /// typed text itself is what Return will submit.
    @State private var highlightedSuggestion: Place.ID?

    @FocusState private var isSearchFocused: Bool

    @Environment(\.scenePhase) private var scenePhase

    /// Size of the area the cards lay out in, for choosing between one and
    /// two columns and for how tall a radar column can be. Measured rather
    /// than read from the screen or size class, so a Mac window, an iPad
    /// split and both iPhone Duo displays all get the layout their actual
    /// space suits.
    @State private var contentSize: CGSize = .zero

    /// A radar column never shrinks below this, so a short window scrolls
    /// rather than squashing the map.
    private static let minimumRadarColumnHeight: CGFloat = 520

    /// The conditions card needs about this much to keep the temperature
    /// and wind dial side by side; past the upper bound it just spreads out.
    private static let cardColumnWidth: ClosedRange<CGFloat> = 380...480

    /// Below this, a radar beside the cards would be too narrow to read.
    private static let minimumRadarColumnWidth: CGFloat = 280

    private var usesTwoColumns: Bool {
        contentSize.width >= Self.cardColumnWidth.lowerBound + 16 + Self.minimumRadarColumnWidth
    }

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
        // A floor for the Mac window only; on iPhone it would push the
        // layout wider than the screen.
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 540)
        #endif
        .background(conditionBackground)
        .task { await store.restoreSelectedPlace() }
        .task(id: store.query) { await store.updateSuggestions() }
        .onChange(of: store.suggestions) { _, _ in highlightedSuggestion = nil }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await store.refreshIfStale() }
        }
        .onOpenURL { url in
            guard let id = PlaceLink.placeID(from: url) else { return }
            Task { await store.selectPlace(id: id) }
        }
        // For the Weather menu's shortcuts. Refresh is withheld when the
        // refresh button would be disabled.
        .focusedSceneValue(\.focusSearch, MenuAction(name: "search") { isSearchFocused = true })
        .focusedSceneValue(\.refreshForecast, store.place == nil || store.isLoading ? nil : MenuAction(name: "refresh") {
            Task { await store.refresh() }
        })
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search for a city", text: $store.query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
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
        dismissKeyboard()
        Task { await store.select(place) }
    }

    /// On iPhone the keyboard would otherwise stay up over the forecast once
    /// a city is chosen. The Mac keeps focus in the field.
    private func dismissKeyboard() {
        #if os(iOS)
        isSearchFocused = false
        #endif
    }

    /// Return picks the highlighted suggestion, or falls back to searching the
    /// typed text and loading its best match.
    private func submit() {
        dismissKeyboard()
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
            // Scrolls once the radar is added: the three cards together are
            // taller than many windows, and an expanded hourly strip adds
            // more. Scrolling over the map moves the map, not the page.
            //
            // With room for both, the radar sits beside the other two cards
            // instead of below them. Switching layouts rather than views keeps
            // the radar's identity, so rotating doesn't reload it.
            let layout = usesTwoColumns
                ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                : AnyLayout(VStackLayout(spacing: 16))
            ScrollView {
                VStack(spacing: 16) {
                    GlassEffectContainer(spacing: 16) {
                        layout {
                            VStack(spacing: 16) {
                                CurrentConditionsCard(
                                    place: place,
                                    current: report.current,
                                    today: report.today,
                                    units: store.unitPreference,
                                    fetchedAt: store.fetchedAt
                                )
                                // Only when there's something to say about
                                // the next hour; a dry one adds no card.
                                if let nextHour = report.nextHour, nextHour.summary(at: .now) != nil {
                                    NextHourCard(forecast: nextHour)
                                }
                                ForecastCard(report: report, units: store.unitPreference)
                                // Beside the radar, the details fill the left
                                // column; in one column they wait below it, so
                                // the radar stays near the top of the page.
                                if usesTwoColumns {
                                    DetailsCard(report: report, units: store.unitPreference)
                                }
                            }
                            .frame(
                                minWidth: usesTwoColumns ? Self.cardColumnWidth.lowerBound : nil,
                                maxWidth: usesTwoColumns ? Self.cardColumnWidth.upperBound : .infinity
                            )
                            // Beside the cards, the radar runs the full height of
                            // the page so large screens aren't left half empty.
                            RadarCard(
                                place: place,
                                height: usesTwoColumns
                                    ? max(contentSize.height, Self.minimumRadarColumnHeight)
                                    : nil
                            )
                            if !usesTwoColumns {
                                DetailsCard(report: report, units: store.unitPreference)
                            }
                        }
                    }
                    .opacity(store.isLoading ? 0.5 : 1)
                    .animation(.easeInOut(duration: 0.2), value: store.isLoading)

                    // Required by WeatherKit's terms. Below everything, so in
                    // the two-column layout it's a short scroll past the radar.
                    WeatherAttributionView()
                }
            }
            .scrollIndicators(.automatic)
            .scrollDismissesKeyboard(.immediately)
            // Pull to refresh on iPhone and iPad; the Mac has the button.
            .refreshable { await store.refresh() }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { contentSize = $0 }
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

    /// Today's forecast, for the precipitation total. A *current*
    /// precipitation figure covers only the last hour, which reads as 0 most
    /// of the time and says nothing useful about the day ahead.
    let today: DailyForecast?

    let units: UnitPreference

    /// When the forecast was fetched, shown so an old one reads as old.
    var fetchedAt: Date?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// "Updated just now", then "Updated 5 min. ago", "Updated 2 hr. ago".
    private static func updatedText(_ fetchedAt: Date, now: Date) -> String {
        guard now.timeIntervalSince(fetchedAt) >= 60 else { return "Updated just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Updated \(formatter.localizedString(for: fetchedAt, relativeTo: now))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Beside the name normally; under it at the accessibility sizes,
            // where side by side squeezes both onto several lines.
            let headerLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
            headerLayout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                        .font(.title2.weight(.semibold))
                    if !place.region.isEmpty {
                        Text(place.region)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: 8)
                }
                if let fetchedAt {
                    // Ticks over by itself, so "Updated 2 hr. ago" stays true
                    // while the app sits open. Formatted against the
                    // timeline's own date: a relative format alone is worked
                    // out once and then never redrawn.
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(Self.updatedText(fetchedAt, now: context.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Side by side where they fit; on narrower spaces, such as iPhone
            // Duo's outer display, the dial drops below the temperature
            // rather than squeezing it onto two lines.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 0) {
                    Spacer(minLength: 0)

                    temperature

                    // Spare width is split evenly across the outer edges and the
                    // middle, so a wider window doesn't open one big gap between
                    // the two. Equal halves read better in principle, but at the
                    // minimum width half is too narrow for the temperature.
                    Spacer(minLength: 20)

                    // Wind lives here rather than in the tile row below, so it
                    // isn't shown twice.
                    WindVane(current: current, units: units)

                    Spacer(minLength: 0)
                }

                VStack(spacing: 16) {
                    temperature
                    WindVane(current: current, units: units)
                }
                .frame(maxWidth: .infinity)
            }

            // Stacked at the accessibility text sizes, where three across
            // leaves room for only a few letters per line.
            let tileLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 12))
                : AnyLayout(HStackLayout(spacing: 12))
            tileLayout {
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

    private var temperature: some View {
        HStack(alignment: .center, spacing: 20) {
            Image(systemName: current.condition.symbolName(isDaytime: current.isDaytime))
                .font(.system(size: 52))
                .symbolRenderingMode(.multicolor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(current.temperatureCelsius.temperatureText(in: units))
                    .font(.system(size: 52, weight: .light))
                    .lineLimit(1)
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
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .padding(.top, 2)
                }
            }
        }
        .accessibilityElement(children: .combine)
        // Spelled out, because "H:" and "L:" are read aloud as letters.
        .accessibilityLabel(temperatureAccessibilityLabel)
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

    /// A word or two under the value, such as a UV index's category.
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 4) {
            Label(label, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.medium))
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Rain (or snow) over the next hour: a headline that counts down while the
/// app is open, over a bar for every minute.
private struct NextHourCard: View {
    let forecast: NextHourForecast

    /// Bars are scaled against at least this, so drizzle looks like drizzle
    /// rather than filling the chart. It's where "moderate" rain begins.
    private static let fullScaleIntensity = 2.5

    @ScaledMetric(relativeTo: .caption) private var chartHeight: CGFloat = 44

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let offset = max(0, Int(context.date.timeIntervalSince(forecast.start) / 60))
            let chances = Array(forecast.chances.dropFirst(offset).prefix(60))
            let intensities = Array(forecast.intensities.dropFirst(offset).prefix(60))
            let scale = max(intensities.max() ?? 0, Self.fullScaleIntensity)

            VStack(alignment: .leading, spacing: 10) {
                Label(forecast.summary(at: context.date) ?? "No \(forecast.kind.lowercased()) this hour", systemImage: "umbrella.fill")
                    .font(.subheadline.weight(.semibold))

                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(intensities.indices, id: \.self) { minute in
                        Capsule()
                            .fill(Color.blue.opacity(chances[minute] >= NextHourForecast.wetChance ? 0.85 : 0.25))
                            // A sliver even when dry, so the hour reads as a
                            // continuous line rather than gaps.
                            .frame(height: max(2, chartHeight * min(1, intensities[minute] / scale)))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: chartHeight, alignment: .bottom)
                .accessibilityHidden(true)

                HStack {
                    Text("Now")
                    Spacer()
                    Text("30 min")
                    Spacer()
                    Text("60 min")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}

/// The readings that don't need a place of their own: UV, the sun, pressure,
/// visibility and dew point. A reading the report lacks, such as one from a
/// forecast cached by an older version, is left out rather than shown blank.
private struct DetailsCard: View {
    let report: WeatherReport
    let units: UnitPreference

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let tiles = self.tiles
        if !tiles.isEmpty {
            // Three across everywhere, so six readings make two even rows
            // whatever the card's width; two at the accessibility sizes.
            let count = dynamicTypeSize.isAccessibilitySize ? 2 : 3
            let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: count)
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(tiles, id: \.label) { tile in
                    tile
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .glassEffect(in: .rect(cornerRadius: 20))
        }
    }

    private var tiles: [DetailTile] {
        let current = report.current
        var tiles: [DetailTile] = []

        if let uv = current.uvIndex {
            tiles.append(DetailTile(symbol: "sun.max.fill", label: "UV index", value: "\(uv)", detail: current.uvCategory))
        }
        if let sunrise = report.today?.sunriseLabel {
            tiles.append(DetailTile(symbol: "sunrise.fill", label: "Sunrise", value: sunrise))
        }
        if let sunset = report.today?.sunsetLabel {
            tiles.append(DetailTile(symbol: "sunset.fill", label: "Sunset", value: sunset))
        }
        if let pressure = current.pressureHectopascals {
            tiles.append(DetailTile(
                symbol: "gauge.with.dots.needle.50percent",
                label: "Pressure",
                value: pressure.pressureText(in: units),
                detail: current.pressureTrend?.rawValue.capitalized
            ))
        }
        if let visibility = current.visibilityKilometers {
            tiles.append(DetailTile(symbol: "eye.fill", label: "Visibility", value: visibility.distanceText(in: units)))
        }
        if let dewPoint = current.dewPointCelsius {
            tiles.append(DetailTile(symbol: "drop.degreesign.fill", label: "Dew point", value: dewPoint.temperatureText(in: units)))
        }
        return tiles
    }
}

/// A compass dial with an arrow pointing the way the wind is blowing, the
/// speed in the middle, and where it's coming from and its gusts underneath.
private struct WindVane: View {
    let current: CurrentWeather
    let units: UnitPreference

    private static let dialSize: CGFloat = 116

    @Environment(\.colorScheme) private var colorScheme

    /// The arrow's rotation, kept continuous rather than wrapped to 0–360°,
    /// so a shift from 350° to 10° swings 20° forward instead of 340° back.
    /// `nil` hides the arrow: calm air, or a report with no direction.
    @State private var arrowAngle: Double?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                CompassDial(size: Self.dialSize)
                if let arrowAngle {
                    VaneArrow()
                        // An explicit color rather than `.primary`: on glass,
                        // the semantic styles render shapes noticeably
                        // washed out, while text in the same style stays crisp.
                        .fill(colorScheme == .dark ? Color.white : Color.black)
                        .rotationEffect(.degrees(arrowAngle))
                        .transition(.opacity)
                }
                speedReadout
                    // The dial is a fixed-size graphic; past this the speed
                    // runs into the arrow. The caption below still grows.
                    .dynamicTypeSize(...DynamicTypeSize.xLarge)
            }
            .frame(width: Self.dialSize, height: Self.dialSize)

            caption
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(minHeight: 14)
        }
        // Center the row on the dial alone, not the dial plus caption, so the
        // dial lines up with the temperature beside it.
        .alignmentGuide(VerticalAlignment.center) { _ in Self.dialSize / 2 }
        .onAppear { arrowAngle = targetAngle }
        .onChange(of: targetAngle) { _, newTarget in
            // A little bounce, so a change of direction swings like a vane.
            withAnimation(.spring(duration: 0.9, bounce: 0.35)) {
                arrowAngle = Self.continuing(from: arrowAngle, to: newTarget)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Where the arrow should point: downwind, opposite the bearing the wind
    /// comes from.
    private var targetAngle: Double? {
        guard !current.isCalm, let from = current.windDirectionDegrees else { return nil }
        return from + 180
    }

    /// The angle equivalent to `target` that's the shortest turn from `angle`.
    private static func continuing(from angle: Double?, to target: Double?) -> Double? {
        guard let target else { return nil }
        guard let angle else { return target }
        var delta = (target - angle).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return angle + delta
    }

    @ViewBuilder private var speedReadout: some View {
        if current.isCalm {
            Text("Calm")
                .font(.callout.weight(.medium))
        } else {
            VStack(spacing: -2) {
                Text(speedNumber(current.windSpeedKPH))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(units.speedUnit.symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var caption: some View {
        let parts = [current.windCompassPoint, gustText.map { "Gusts \($0)" }].compactMap { $0 }
        Text(parts.joined(separator: " · "))
    }

    /// Gusts, when they're actually stronger than the steady wind as shown.
    private var gustText: String? {
        guard let gust = current.windGustKPH,
              speedNumber(gust) != speedNumber(current.windSpeedKPH),
              gust > current.windSpeedKPH
        else { return nil }
        return gust.windSpeedText(in: units)
    }

    /// The speed as a bare whole number, since the unit sits on its own line.
    private func speedNumber(_ kph: Double) -> String {
        Measurement(value: kph, unit: UnitSpeed.kilometersPerHour)
            .converted(to: units.speedUnit)
            .value
            .formatted(.number.precision(.fractionLength(0)))
    }

    private var accessibilityLabel: String {
        guard !current.isCalm else { return "Wind calm" }
        var label = "Wind"
        if let name = current.windCompassName {
            label += " from the \(name)"
        }
        label += " at \(current.windSpeedKPH.windSpeedText(in: units))"
        if let gustText {
            label += ", gusts up to \(gustText)"
        }
        return label
    }
}

/// The ring, tick marks, and cardinal letters behind the vane's arrow.
private struct CompassDial: View {
    let size: CGFloat

    private static let cardinals: [(letter: String, degrees: Double)] = [
        ("N", 0), ("E", 90), ("S", 180), ("W", 270)
    ]

    var body: some View {
        let radius = size / 2

        ZStack {
            Circle()
                .strokeBorder(.secondary.opacity(0.3), lineWidth: 1)

            // A tick every 10°, longer every 30°, and boldest at the four
            // cardinal points.
            ForEach(0..<36, id: \.self) { tick in
                let isCardinal = tick.isMultiple(of: 9)
                Capsule()
                    .fill(.secondary.opacity(isCardinal ? 0.9 : 0.4))
                    .frame(width: isCardinal ? 2 : 1, height: tick.isMultiple(of: 3) ? 6 : 3)
                    .offset(y: -(radius - 6))
                    .rotationEffect(.degrees(Double(tick) * 10))
            }

            // Placed by offset rather than rotation, so the letters stay upright.
            ForEach(Self.cardinals, id: \.letter) { cardinal in
                let radians = cardinal.degrees * .pi / 180
                Text(cardinal.letter)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(cardinal.letter == "N" ? .primary : .secondary)
                    .offset(
                        x: sin(radians) * (radius - 18),
                        y: -cos(radians) * (radius - 18)
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A weather vane's pointer, drawn pointing straight up: an arrowhead, a
/// round counterweight for a tail, and a gap in the middle for the speed
/// readout. The tail is deliberately unlike the head, so there's no doubt
/// which end points downwind.
private struct VaneArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let midX = rect.midX
        let midY = rect.midY
        let unit = min(rect.width, rect.height)

        // Fractions of the dial, measured from its top edge. The readout
        // clears the middle 34%, so the head and its shaft must both fit
        // between the ring and 0.33, or the shaft runs backwards.
        let top = rect.minY + unit * 0.1
        let headBase = rect.minY + unit * 0.24
        let bottom = rect.maxY - unit * 0.15
        let gap = unit * 0.17
        let shaft = unit * 0.04
        let headWidth = unit * 0.17
        let tailRadius = unit * 0.045

        var path = Path()

        // Arrowhead, then the shaft from its base in to the readout.
        path.move(to: CGPoint(x: midX, y: top))
        path.addLine(to: CGPoint(x: midX + headWidth / 2, y: headBase))
        path.addLine(to: CGPoint(x: midX - headWidth / 2, y: headBase))
        path.closeSubpath()
        path.addRect(CGRect(x: midX - shaft / 2, y: headBase, width: shaft, height: midY - gap - headBase))

        // Shaft from the readout out to the counterweight.
        path.addRect(CGRect(x: midX - shaft / 2, y: midY + gap, width: shaft, height: bottom - midY - gap))
        path.addEllipse(in: CGRect(
            x: midX - tailRadius,
            y: bottom - tailRadius,
            width: tailRadius * 2,
            height: tailRadius * 2
        ))

        return path
    }
}

/// The seven-day row. Clicking a day opens its hourly breakdown underneath;
/// clicking it again, or another day, closes or switches it.
private struct ForecastCard: View {
    let report: WeatherReport
    let units: UnitPreference

    /// The day whose hours are showing, if any.
    @State private var expandedDay: DailyForecast.ID?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Seven columns don't fit at the accessibility text sizes; there the
        // days become rows, each laid out across the card.
        let dayLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 4))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 4))

        VStack(spacing: 12) {
            dayLayout {
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Tall enough for any condition symbol at the current text size.
    @ScaledMetric(relativeTo: .title3) private var symbolHeight: CGFloat = 24

    var body: some View {
        Button(action: onToggle) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    row
                } else {
                    column
                }
            }
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

    private var name: String {
        day.isToday ? "Today" : day.weekday
    }

    private var nameText: some View {
        Text(name)
            .font(.caption.weight(.medium))
            .foregroundStyle(day.isToday || isExpanded ? .primary : .secondary)
            .lineLimit(1)
    }

    private var symbol: some View {
        Image(systemName: day.condition.symbolName(isDaytime: true))
            .font(.title3)
            .symbolRenderingMode(.multicolor)
            // These symbols differ in intrinsic height — cloud.fill is much
            // shorter than cloud.sun.fill — so without a fixed height every
            // row below sits at a different level from one column to the next.
            .frame(height: symbolHeight)
            .accessibilityHidden(true)
    }

    private var highText: some View {
        Text(day.highCelsius.temperatureText(in: units))
            .font(.callout.weight(.medium))
            .lineLimit(1)
    }

    private var lowText: some View {
        Text(day.lowCelsius.temperatureText(in: units))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// The usual layout: one narrow column of seven across the card.
    private var column: some View {
        VStack(spacing: 8) {
            nameText
            symbol
            highText
            lowText
            PrecipitationChance(text: day.precipitationChanceText)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }

    /// The accessibility-size layout: the day and its chance of rain on the
    /// left, the sky in the middle, the high over the low on the right.
    private var row: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                nameText
                PrecipitationChance(text: day.precipitationChanceText)
            }
            Spacer(minLength: 8)
            symbol
            VStack(alignment: .trailing, spacing: 2) {
                highText
                lowText
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
    }

    private var accessibilityLabel: String {
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

    @ScaledMetric(relativeTo: .title3) private var symbolHeight: CGFloat = 24

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 4) {
                ForEach(hours) { hour in
                    let isNow = Self.isCurrent(hour)
                    VStack(spacing: 8) {
                        Text(isNow ? "Now" : hour.hourLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(isNow ? .primary : .secondary)
                            .lineLimit(1)
                        Image(systemName: hour.condition.symbolName(isDaytime: hour.isDaytime))
                            .font(.title3)
                            .symbolRenderingMode(.multicolor)
                            .frame(height: symbolHeight)
                            .accessibilityHidden(true)
                        Text(hour.temperatureCelsius.temperatureText(in: units))
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        PrecipitationChance(text: hour.precipitationChanceText)
                    }
                    // At least as wide as a day column; wider when larger
                    // text needs it, since the strip scrolls anyway.
                    .frame(minWidth: 48)
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

    /// Both scale with the text, so larger sizes aren't cut off at the
    /// default size's height.
    @ScaledMetric(relativeTo: .caption2) private var dropSize: CGFloat = 8
    @ScaledMetric(relativeTo: .caption2) private var rowHeight: CGFloat = 12

    var body: some View {
        HStack(spacing: 2) {
            if let text {
                Image(systemName: "drop.fill")
                    .font(.system(size: dropSize))
                Text(text)
                    .font(.caption2)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.secondary)
        .frame(height: rowHeight)
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
        isDaytime: true,
        windDirectionDegrees: 315,
        windGustKPH: 24
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
