import SwiftUI

extension WeatherCondition {
    /// A pair of tints keyed to the condition and time of day. Shared by the
    /// app's window background and the widget's card so the same sky reads the
    /// same way in both places.
    ///
    /// Kept to two stops and applied at low opacity by callers, so text stays
    /// legible in light and dark appearances.
    func accentColors(isDaytime: Bool) -> [Color] {
        guard isDaytime else { return [.indigo, .purple] }

        switch self {
        case .clear, .mainlyClear:
            return [.blue, .cyan]
        case .partlyCloudy:
            return [.teal, .blue]
        case .overcast, .fog, .unknown:
            return [.gray, .teal]
        case .drizzle, .rain, .showers, .freezingDrizzle, .freezingRain:
            return [.blue, .indigo]
        case .snow, .snowGrains, .snowShowers:
            return [.cyan, .mint]
        case .thunderstorm, .thunderstormWithHail:
            return [.purple, .indigo]
        }
    }

    /// A top-to-bottom gradient of `accentColors(isDaytime:)` at the given opacity.
    func gradient(isDaytime: Bool, opacity: Double) -> LinearGradient {
        LinearGradient(
            colors: accentColors(isDaytime: isDaytime).map { $0.opacity(opacity) },
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
