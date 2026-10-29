import SwiftUI
import WeatherKit

/// The credit WeatherKit's terms require wherever its data is shown: the
/// Apple Weather mark, and a link to the page listing Apple's data sources.
/// Both come from WeatherKit at run time, so they stay current without an
/// app update.
struct WeatherAttributionView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var attribution: WeatherAttribution?

    var body: some View {
        HStack(spacing: 12) {
            if let attribution {
                AsyncImage(
                    url: colorScheme == .dark ? attribution.combinedMarkDarkURL : attribution.combinedMarkLightURL
                ) { image in
                    image
                        .resizable()
                        .scaledToFit()
                } placeholder: {
                    Text(attribution.serviceName)
                }
                .frame(height: 14)
                .accessibilityLabel(attribution.serviceName)

                Link("Other data sources", destination: attribution.legalPageURL)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .task {
            // A failure leaves the line empty until the next launch; the
            // forecast itself loaded, or this view wouldn't be on screen.
            attribution = try? await WeatherService().attribution()
        }
    }
}
