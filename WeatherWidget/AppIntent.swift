import AppIntents
import WidgetKit

/// A city a widget can be pointed at.
///
/// The id comes from the place's coordinate (see `Place.id(latitude:longitude:)`),
/// so it means the same thing on every device and in every later search, and a
/// widget configured today still resolves months from now. Widgets set up
/// with earlier builds hold Open-Meteo GeoNames ids, which still resolve
/// through the shared place directory. The full `Place` rides along so the timeline provider
/// can request a forecast by coordinate instead of geocoding the name again on
/// every refresh.
struct PlaceEntity: AppEntity {
    static let defaultQuery = PlaceEntityQuery()

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "City")
    }

    /// The resolved record. A plain property: it feeds the forecast request and
    /// the display representation, and isn't something the system filters on.
    let place: Place

    var id: Place.ID { place.id }

    @Property(title: "City")
    var name: String

    @Property(title: "Region")
    var region: String

    init(place: Place) {
        self.place = place
        self.name = place.name
        self.region = place.region
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: region.isEmpty ? nil : "\(region)"
        )
    }
}

struct PlaceEntityQuery: EntityStringQuery {
    private let service = WeatherService()
    private let shared = SharedStore()

    /// Resolves ids the system already holds, in one batch.
    ///
    /// The geocoding API has no lookup-by-id endpoint, so this reads the shared
    /// place directory that every earlier search wrote to. Ids with no record
    /// are omitted rather than throwing — that's what the framework expects for
    /// an entity that has gone away.
    func entities(for identifiers: [Place.ID]) async throws -> [PlaceEntity] {
        shared.places(for: identifiers).map(PlaceEntity.init(place:))
    }

    /// Backs free-text search in the widget's settings. Nothing filters this
    /// for us — the geocoder does the matching. Results are recorded so
    /// `entities(for:)` can later resolve whichever one gets picked.
    func entities(matching string: String) async throws -> [PlaceEntity] {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let matches = try await service.places(matching: trimmed)
        shared.remember(matches)

        // The geocoder occasionally repeats an id, which would give the picker
        // two indistinguishable rows.
        var seenIDs = Set<Place.ID>()
        return matches
            .filter { seenIDs.insert($0.id).inserted }
            .map(PlaceEntity.init(place:))
    }

    /// The list the picker opens on: the cities saved in the app, then other
    /// places seen recently, so the ones someone cares about come first.
    func suggestedEntities() async throws -> [PlaceEntity] {
        let saved = shared.savedPlaces
        let savedIDs = Set(saved.map(\.id))
        let recent = shared.knownPlaces.filter { !savedIDs.contains($0.id) }
        return (saved + recent).prefix(12).map(PlaceEntity.init(place:))
    }
}

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Choose a City" }
    static var description: IntentDescription {
        IntentDescription("Pick which city's weather this widget shows.")
    }

    /// Optional on purpose: left empty, the widget follows whichever city the
    /// app is showing, so a freshly added widget has something to display
    /// before anyone opens its settings.
    @Parameter(title: "City")
    var place: PlaceEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Show weather for \(\.$place)")
    }
}
