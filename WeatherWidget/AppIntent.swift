import WidgetKit
import AppIntents

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Choose a City" }
    static var description: IntentDescription {
        IntentDescription("Pick which city's weather this widget shows.")
    }

    /// A free-text city name. Open-Meteo resolves region qualifiers itself,
    /// so "Moab, UT" works as well as "Moab".
    @Parameter(title: "City", default: "Cupertino")
    var city: String

    static var parameterSummary: some ParameterSummary {
        Summary("Show weather for \(\.$city)")
    }
}
