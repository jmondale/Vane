import SwiftUI

/// A menu command a window offers. Compared by name only, so SwiftUI doesn't
/// treat every redraw of the window, which builds a new closure, as a change.
struct MenuAction: Equatable {
    let name: String
    let perform: () -> Void

    func callAsFunction() { perform() }

    static func == (lhs: MenuAction, rhs: MenuAction) -> Bool { lhs.name == rhs.name }
}

extension FocusedValues {
    /// Reloads the forecast in the frontmost window. `nil` when there's no
    /// place to refresh, which disables the menu item.
    @Entry var refreshForecast: MenuAction?

    /// Moves focus to the frontmost window's search field.
    @Entry var focusSearch: MenuAction?

    /// Step through the saved cities, wrapping round.
    @Entry var nextSavedPlace: MenuAction?
    @Entry var previousSavedPlace: MenuAction?
}

/// A Weather menu with keyboard shortcuts for what people do most. On the
/// Mac it's in the menu bar; on iPad it shows when holding Command.
struct VaneCommands: Commands {
    @FocusedValue(\.refreshForecast) private var refreshForecast
    @FocusedValue(\.focusSearch) private var focusSearch
    @FocusedValue(\.nextSavedPlace) private var nextSavedPlace
    @FocusedValue(\.previousSavedPlace) private var previousSavedPlace

    var body: some Commands {
        CommandMenu("Weather") {
            Button("Search for a City") { focusSearch?() }
                .keyboardShortcut("f")
                .disabled(focusSearch == nil)

            Button("Refresh") { refreshForecast?() }
                .keyboardShortcut("r")
                .disabled(refreshForecast == nil)

            Divider()

            Button("Next Saved City") { nextSavedPlace?() }
                .keyboardShortcut("]")
                .disabled(nextSavedPlace == nil)

            Button("Previous Saved City") { previousSavedPlace?() }
                .keyboardShortcut("[")
                .disabled(previousSavedPlace == nil)
        }
    }
}
