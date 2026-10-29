import Foundation
import Observation
import WidgetKit

/// Owns the app's weather state: the selected place, its latest report, and
/// the unit preference. The selected place and units persist between launches.
@Observable final class WeatherStore {
    enum Status: Equatable {
        case idle
        case loading
        case ready
        case failed(message: String)
    }

    /// Below this length a query matches too much of the world to be useful.
    private static let minimumSuggestionLength = 2

    /// How many completions the dropdown shows at once.
    private static let maximumSuggestions = 6

    var query: String = ""

    /// Written through to the shared defaults on every change, so the manual
    /// observation accessors are used instead of a tracked stored property.
    /// The widget reads the same value, so a change has to reload its timelines.
    var unitPreference: UnitPreference {
        get {
            access(keyPath: \.unitPreference)
            return storedUnitPreference
        }
        set {
            withMutation(keyPath: \.unitPreference) {
                storedUnitPreference = newValue
                shared.unitPreference = newValue
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    @ObservationIgnored private var storedUnitPreference: UnitPreference

    private(set) var place: Place?
    private(set) var report: WeatherReport?

    /// When `report` was fetched, so a forecast left open for hours can be
    /// noticed and refreshed.
    private(set) var fetchedAt: Date?

    /// The place `report` belongs to. It differs from `place` while a newly
    /// chosen city loads, and must never be shown under that city's name.
    private var reportPlaceID: Place.ID?

    /// Older than this, a forecast is refreshed when the app comes back to
    /// the front. WeatherKit's current conditions move about this often.
    private static let staleAfter: TimeInterval = 15 * 60

    /// The starred cities, in order. Written through to the shared store.
    private(set) var savedPlaces: [Place]

    /// Enough for every city someone actually checks, without the row of
    /// chips becoming a list to scroll through.
    private static let savedPlaceLimit = 12

    /// Live geocoding matches for the current query, shown as a completion list.
    private(set) var suggestions: [Place] = []
    private(set) var status: Status = .idle

    /// The query text that produced the current selection. Suggestions stay
    /// closed while the field still holds it, so choosing a place doesn't
    /// immediately reopen the list.
    private var committedQuery: String?

    private let service = WeatherService()
    private let shared: SharedStore

    /// Made on first use, so launching never touches Core Location for
    /// someone who has never tapped My Location.
    @ObservationIgnored private lazy var location = LocationProvider()

    /// True while the place showing is where the device is, found through
    /// My Location rather than chosen.
    private(set) var isShowingCurrentLocation = false

    init(shared: SharedStore = SharedStore()) {
        self.shared = shared
        self.storedUnitPreference = shared.unitPreference
        self.savedPlaces = shared.savedPlaces
    }

    // MARK: - Saved places

    func isSaved(_ place: Place) -> Bool {
        savedPlaces.contains { $0.id == place.id }
    }

    /// Stars or unstars a place. A new one goes at the end of the row.
    func toggleSaved(_ place: Place) {
        if isSaved(place) {
            savedPlaces.removeAll { $0.id == place.id }
        } else {
            guard savedPlaces.count < Self.savedPlaceLimit else { return }
            savedPlaces.append(place)
        }
        shared.savedPlaces = savedPlaces
    }

    var canSaveMorePlaces: Bool {
        savedPlaces.count < Self.savedPlaceLimit
    }

    /// The saved place `offset` steps from the one showing, wrapping round.
    /// From a place that isn't saved, forward starts at the first.
    func selectSavedPlace(offsetBy offset: Int) async {
        guard !savedPlaces.isEmpty else { return }
        let next: Int
        if let index = savedPlaces.firstIndex(where: { $0.id == place?.id }) {
            next = (index + offset + savedPlaces.count) % savedPlaces.count
        } else {
            next = offset > 0 ? 0 : savedPlaces.count - 1
        }
        await select(savedPlaces[next])
    }

    var isLoading: Bool { status == .loading }

    var errorMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    /// Reloads the place chosen in a previous launch, if there was one.
    func restoreSelectedPlace() async {
        guard place == nil, let saved = shared.selectedPlace else { return }
        // The last forecast goes up at once, labelled with its age, and is
        // replaced when the fresh one arrives. Offline, it's all there is.
        place = saved
        showCachedReport(for: saved)

        // Reopened soon after the last fetch: that forecast is current
        // enough, and fetching again would spend a WeatherKit call on the
        // same numbers. It must have hourly detail, which the widget's
        // saved forecasts leave out.
        // Last shown as My Location: find the device again, as long as that
        // needs no permission prompt. Launch is no time to ask.
        if shared.usesCurrentLocation && location.isAuthorized {
            // Finding the device costs no WeatherKit call; the saved
            // forecast is reused only if it's still the same city.
            await selectCurrentLocation(reusingRecentForecast: true)
            return
        }
        if hasRecentForecast(for: saved) {
            query = saved.name
            committedQuery = saved.name
            status = .ready
            return
        }
        await select(saved)
    }

    /// Whether the forecast showing is for `place` and new enough to show
    /// again without fetching, with the hourly detail the widget's saved
    /// forecasts leave out.
    private func hasRecentForecast(for place: Place) -> Bool {
        guard reportPlaceID == place.id, let fetchedAt, report?.hourly.isEmpty == false else { return false }
        return Date.now.timeIntervalSince(fetchedAt) < Self.reuseOnLaunch
    }

    /// Shows the weather where the device is, asking for location permission
    /// the first time. A failure leaves whatever was showing in place, under
    /// a message saying why.
    func selectCurrentLocation(reusingRecentForecast: Bool = false) async {
        status = .loading
        suggestions = []
        do {
            let here = try await location.currentLocation()
            let found = try await service.place(at: here)
            if reusingRecentForecast, hasRecentForecast(for: found) {
                place = found
                isShowingCurrentLocation = true
                query = found.name
                committedQuery = found.name
                status = .ready
                return
            }
            await select(found, isCurrentLocation: true)
        } catch is CancellationError {
            status = report == nil ? .idle : .ready
        } catch let error as LocationError {
            // With access off, the city showing is no longer "where you
            // are"; it stays up as an ordinary city, under the message.
            if case .denied = error {
                isShowingCurrentLocation = false
                shared.usesCurrentLocation = false
            }
            status = .failed(message: error.localizedDescription)
        } catch {
            status = .failed(message: WeatherService.message(for: error))
        }
    }

    /// See `restoreSelectedPlace()`.
    private static let reuseOnLaunch: TimeInterval = 10 * 60

    /// Selects the place a widget's deep link points at. The id resolves
    /// against the shared directory, which holds every place the app or a
    /// widget has looked up, so no geocoding round trip is needed.
    func selectPlace(id: Place.ID) async {
        guard place?.id != id, let match = shared.places(for: [id]).first else { return }
        await select(match)
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
            status = .failed(message: WeatherService.message(for: error))
        }
    }

    /// Loads the forecast for a specific place and remembers it for next launch.
    func select(_ place: Place, isCurrentLocation: Bool = false) async {
        self.place = place
        isShowingCurrentLocation = isCurrentLocation
        shared.usesCurrentLocation = isCurrentLocation
        fallBack(to: place)
        status = .loading
        suggestions = []
        query = place.name
        committedQuery = place.name

        do {
            let fetched = try await service.report(for: place, includeHourly: true)
            report = fetched
            fetchedAt = .now
            reportPlaceID = place.id
            status = .ready

            // The widget reads both of these: the selection, so a newly added
            // widget starts on this city, and the cache, so it can render
            // immediately instead of waiting on its own first fetch.
            shared.selectedPlace = place
            shared.cache(fetched, for: place)
            WidgetCenter.shared.reloadAllTimelines()
        } catch is CancellationError {
            fallBack(to: place)
            status = report == nil ? .idle : .ready
        } catch {
            fallBack(to: place)
            status = .failed(message: WeatherService.message(for: error))
        }
    }

    /// After a failed load, keeps showing this place's forecast if there is
    /// one, on screen or saved, rather than another city's under its name.
    /// With a report left, the error shows as a banner above it.
    private func fallBack(to place: Place) {
        guard reportPlaceID != place.id, !showCachedReport(for: place) else { return }
        report = nil
        fetchedAt = nil
        reportPlaceID = nil
    }

    /// Shows the forecast last saved for `place`, if any. It's the one the
    /// widget falls back on too, so it may lack hourly detail when the
    /// widget saved it last.
    @discardableResult
    private func showCachedReport(for place: Place) -> Bool {
        guard let cached = shared.cachedReport(for: place.id) else { return false }
        report = cached.report
        fetchedAt = cached.fetchedAt
        reportPlaceID = place.id
        return true
    }

    /// Fetches the forecast again. For My Location, finds the device again
    /// first, since it may have moved.
    func refresh() async {
        if isShowingCurrentLocation {
            await selectCurrentLocation()
            return
        }
        guard let place else { return }
        await select(place)
    }

    /// Refreshes only if the forecast on screen is old. Called whenever the
    /// app becomes active, which on iPhone can be hours after it last ran.
    func refreshIfStale() async {
        guard !isLoading, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) > Self.staleAfter else { return }
        await refresh()
    }
}
