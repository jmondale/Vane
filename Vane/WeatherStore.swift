import Foundation
import Observation

/// Owns the app's weather state: the selected place, its latest report, and
/// the unit preference. The selected place and units persist between launches.
@Observable final class WeatherStore {
    enum Status: Equatable {
        case idle
        case loading
        case ready
        case failed(message: String)
    }

    private enum DefaultsKey {
        static let place = "selectedPlace"
        static let units = "unitPreference"
    }

    /// Below this length a query matches too much of the world to be useful.
    private static let minimumSuggestionLength = 2

    /// How many completions the dropdown shows at once.
    private static let maximumSuggestions = 6

    var query: String = ""

    /// Written through to `UserDefaults` on every change, so the manual
    /// observation accessors are used instead of a tracked stored property.
    var unitPreference: UnitPreference {
        get {
            access(keyPath: \.unitPreference)
            return storedUnitPreference
        }
        set {
            withMutation(keyPath: \.unitPreference) {
                storedUnitPreference = newValue
                defaults.set(newValue.rawValue, forKey: DefaultsKey.units)
            }
        }
    }

    @ObservationIgnored private var storedUnitPreference: UnitPreference

    private(set) var place: Place?
    private(set) var report: WeatherReport?

    /// Live geocoding matches for the current query, shown as a completion list.
    private(set) var suggestions: [Place] = []
    private(set) var status: Status = .idle

    /// The query text that produced the current selection. Suggestions stay
    /// closed while the field still holds it, so choosing a place doesn't
    /// immediately reopen the list.
    private var committedQuery: String?

    private let service = WeatherService()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedUnits = defaults.string(forKey: DefaultsKey.units)
        self.storedUnitPreference = storedUnits.flatMap(UnitPreference.init(rawValue:)) ?? .metric
    }

    var isLoading: Bool { status == .loading }

    var errorMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    /// Reloads the place chosen in a previous launch, if there was one.
    func restoreSelectedPlace() async {
        guard place == nil,
              let data = defaults.data(forKey: DefaultsKey.place),
              let saved = try? JSONDecoder().decode(Place.self, from: data)
        else { return }

        await select(saved)
    }

    /// Refreshes the completion list for the current query.
    ///
    /// The view restarts this from a `task(id:)` on every keystroke, so the
    /// sleep below debounces the network: only the last keystroke of a burst
    /// survives cancellation long enough to issue a request.
    func updateSuggestions() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.count >= Self.minimumSuggestionLength, trimmed != committedQuery else {
            suggestions = []
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(250))
        } catch {
            return
        }

        // A partial word matching nothing is normal here, so failures leave
        // the list empty rather than raising an error the user didn't ask for.
        let matches = (try? await service.places(matching: trimmed)) ?? []
        guard !Task.isCancelled else { return }

        // The geocoder occasionally repeats an id, which would break ForEach.
        var seenIDs = Set<Place.ID>()
        suggestions = matches
            .filter { seenIDs.insert($0.id).inserted }
            .prefix(Self.maximumSuggestions)
            .map { $0 }
    }

    func dismissSuggestions() {
        suggestions = []
    }

    /// Geocodes `query` and loads the best match. Used when the field is
    /// submitted without picking a specific suggestion.
    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        status = .loading
        suggestions = []

        do {
            let matches = try await service.places(matching: trimmed)
            guard let best = matches.first else {
                status = .failed(message: "No place named \u{201C}\(trimmed)\u{201D} was found.")
                return
            }
            await select(best)
        } catch is CancellationError {
            status = report == nil ? .idle : .ready
        } catch {
            status = .failed(message: error.localizedDescription)
        }
    }

    /// Loads the forecast for a specific place and remembers it for next launch.
    func select(_ place: Place) async {
        self.place = place
        status = .loading
        suggestions = []
        query = place.name
        committedQuery = place.name

        do {
            report = try await service.report(for: place)
            status = .ready
            if let data = try? JSONEncoder().encode(place) {
                defaults.set(data, forKey: DefaultsKey.place)
            }
        } catch is CancellationError {
            status = report == nil ? .idle : .ready
        } catch {
            status = .failed(message: error.localizedDescription)
        }
    }

    func refresh() async {
        guard let place else { return }
        await select(place)
    }
}
