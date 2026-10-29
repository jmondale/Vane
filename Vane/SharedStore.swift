import Foundation

/// The App Group the app and the widget extension both belong to, declared in
/// each target's entitlements. The `group.` prefix is required on iOS and
/// recommended on macOS, so one identifier covers every platform this app
/// builds for.
nonisolated let vaneAppGroupIdentifier = "group.com.jayemondale.Vane"

extension UserDefaults {
    /// The defaults suite shared with the widget extension.
    ///
    /// `UserDefaults` is thread-safe, so one instance is fine to share across
    /// isolation domains. If the suite can't be opened — a missing or
    /// unprovisioned App Group entitlement — this falls back to `.standard`
    /// rather than trapping: the app keeps working and only the widget's view
    /// of the app's state is lost.
    nonisolated(unsafe) static let vaneShared: UserDefaults =
        UserDefaults(suiteName: vaneAppGroupIdentifier) ?? .standard
}

/// A weather report kept on disk so a failed refresh doesn't blank the widget.
nonisolated struct CachedReport: Codable, Sendable {
    let place: Place
    let report: WeatherReport
    let fetchedAt: Date
}

/// The state the app and its widget both read.
///
/// The app owns the selected place and the unit preference; the widget reads
/// them so a newly added widget starts on the city you're already looking at,
/// in the units you picked.
///
/// The place directory exists because the geocoding API has no lookup-by-id
/// endpoint. An `AppEntity` id is a durable reference the system hands back
/// later, so every place the app or widget resolves by name gets recorded
/// here — that's what lets `PlaceEntityQuery` turn a stored id back into
/// coordinates without searching again.
///
/// `@unchecked` because `UserDefaults` isn't marked `Sendable` even though it's
/// documented as thread-safe; this type adds no mutable state of its own.
nonisolated struct SharedStore: @unchecked Sendable {
    private enum Key {
        static let selectedPlace = "selectedPlace"
        static let units = "unitPreference"
        static let knownPlaces = "knownPlaces"
        static let savedPlaces = "savedPlaces"
        static let usesCurrentLocation = "usesCurrentLocation"

        /// Suffixed with the place id, so each configured widget keeps its own
        /// fallback copy instead of fighting over one slot.
        static func cachedReport(_ id: Place.ID) -> String { "cachedReport.\(id)" }
    }

    /// Enough to cover the cities someone actually switches between without
    /// letting the directory grow without bound.
    private static let knownPlaceLimit = 50

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .vaneShared) {
        self.defaults = defaults
    }

    // MARK: - Current location

    /// Whether the app was last showing the weather where the device is,
    /// so it can find the device again on the next launch rather than
    /// reopening on wherever that was.
    var usesCurrentLocation: Bool {
        get { defaults.bool(forKey: Key.usesCurrentLocation) }
        nonmutating set { defaults.set(newValue, forKey: Key.usesCurrentLocation) }
    }

    // MARK: - Unit preference

    var unitPreference: UnitPreference {
        get {
            defaults.string(forKey: Key.units)
                .flatMap(UnitPreference.init(rawValue:)) ?? .metric
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Key.units)
        }
    }

    // MARK: - Selected place

    /// The place the app is currently showing, used as the widget's default
    /// when its own configuration is empty.
    var selectedPlace: Place? {
        get { decode(Place.self, forKey: Key.selectedPlace) }
        nonmutating set {
            encode(newValue, forKey: Key.selectedPlace)
            if let newValue { remember([newValue]) }
        }
    }

    // MARK: - Saved places

    /// The cities someone has starred, in the order they're shown. The widget
    /// offers them first when picking a city.
    ///
    /// Before anything has been saved, this starts with the city already
    /// open, so updating doesn't greet people with an empty list. Once set,
    /// even to empty, it's left as set.
    var savedPlaces: [Place] {
        get {
            if let saved = decode([Place].self, forKey: Key.savedPlaces) { return saved }
            return selectedPlace.map { [$0] } ?? []
        }
        nonmutating set {
            encode(newValue, forKey: Key.savedPlaces)
            remember(newValue)
        }
    }

    // MARK: - Place directory

    /// Every place resolved so far, most recently seen first.
    var knownPlaces: [Place] {
        decode([Place].self, forKey: Key.knownPlaces) ?? []
    }

    /// Records places so they can later be resolved by id. Re-recording a
    /// place moves it to the front, which is what makes `knownPlaces` usable
    /// as a most-recent list for widget suggestions.
    func remember(_ places: [Place]) {
        guard !places.isEmpty else { return }

        var seenIDs = Set<Place.ID>()
        let merged = (places + knownPlaces)
            .filter { seenIDs.insert($0.id).inserted }
            .prefix(Self.knownPlaceLimit)

        encode(Array(merged), forKey: Key.knownPlaces)
    }

    /// Resolves ids in one pass. Ids with no recorded place are omitted, which
    /// is what `EntityQuery.entities(for:)` expects for entities that have gone
    /// away.
    func places(for ids: [Place.ID]) -> [Place] {
        let wanted = Set(ids)
        return knownPlaces.filter { wanted.contains($0.id) }
    }

    // MARK: - Report cache

    func cachedReport(for id: Place.ID) -> CachedReport? {
        decode(CachedReport.self, forKey: Key.cachedReport(id))
    }

    func cache(_ report: WeatherReport, for place: Place, at date: Date = .now) {
        encode(
            CachedReport(place: place, report: report, fetchedAt: date),
            forKey: Key.cachedReport(place.id)
        )
    }

    // MARK: - Coding

    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode<T: Encodable>(_ value: T?, forKey key: String) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}
