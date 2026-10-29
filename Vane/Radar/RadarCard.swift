import MapKit
import SwiftUI

/// Recent radar around a place: a map with the radar on top, a scrubber to
/// step through the past couple of hours, and the provider's credit.
struct RadarCard: View {
    let place: Place

    /// When set, the card is this tall and the map takes whatever the header
    /// and controls leave, so a radar with a column to itself can fill the
    /// screen. Otherwise the map is a fixed height within a scrolling page.
    var height: CGFloat?

    @State private var store = RadarStore()

    /// Bumped by the recenter button; see `RadarMapView.recenterRequest`.
    @State private var recenterRequest = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            map
            if isCovered {
                controls
            }
            credit
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .glassEffect(in: .rect(cornerRadius: 20))
        .task { await store.keepFresh() }
        .task(id: store.isPlaying) { await store.play() }
    }

    // MARK: - Parts

    private var header: some View {
        HStack {
            Label("Radar", systemImage: "dot.radiowaves.left.and.right")
                .font(.headline)
            Spacer()
            if isCovered, let frame = store.currentFrame {
                // Relative rather than a clock time: the viewer's time zone
                // and the place's can differ, but "20 min ago" means the
                // same thing in both.
                Text(frame.time, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(store.isShowingLatest ? .primary : .secondary)
                    .contentTransition(.numericText())
            }
        }
    }

    private var map: some View {
        RadarMapView(
            center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
            // No frames outside the provider's coverage, so the map doesn't
            // ask the service for tiles that can only be empty.
            frames: isCovered ? store.frames : [],
            currentFrame: store.currentFrame,
            provider: store.provider,
            recenterRequest: recenterRequest
        )
        // Top right: MapKit puts its scale top left and its zoom buttons
        // bottom right, and the middle is the place's pin.
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 8) {
                recenterButton
                statusOverlay
            }
            .padding(10)
        }
        .frame(height: height == nil ? 300 : nil)
        .clipShape(.rect(cornerRadius: 12))
    }

    /// Back to the starting view around the place, after zooming or panning.
    private var recenterButton: some View {
        Button {
            recenterRequest += 1
        } label: {
            Image(systemName: "scope")
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .help("Center on \(place.name)")
        .accessibilityLabel("Center radar on \(place.name)")
    }

    private var isCovered: Bool {
        store.provider.covers(latitude: place.latitude, longitude: place.longitude)
    }

    @ViewBuilder private var statusOverlay: some View {
        if !isCovered {
            Label("Radar covers the US and Canada", systemImage: "info.circle.fill")
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(in: .rect(cornerRadius: 12))
        } else {
            statusMessage
        }
    }

    @ViewBuilder private var statusMessage: some View {
        switch store.status {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .padding(8)
                .glassEffect(in: .circle)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(in: .rect(cornerRadius: 12))
        case .ready:
            EmptyView()
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                store.isPlaying.toggle()
            } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glass)
            .disabled(store.frames.count < 2)
            .accessibilityLabel(store.isPlaying ? "Pause radar" : "Play radar")

            Slider(value: frameIndex, in: 0...Double(max(store.frames.count - 1, 1)), step: 1)
                .disabled(store.frames.count < 2)
                .accessibilityLabel("Radar time")
                .accessibilityValue(timeDescription)
        }
    }

    /// Required by the provider's licence: visible credit, linked. On a line
    /// of its own, since a full agency name would squeeze the slider.
    private var credit: some View {
        Link(store.provider.attribution.text, destination: store.provider.attribution.url)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Helpers

    /// The slider's view of the playback position. Dragging it pauses
    /// playback, so the frame stays where it was put.
    private var frameIndex: Binding<Double> {
        Binding(
            get: { Double(store.currentIndex) },
            set: { newValue in
                store.isPlaying = false
                store.currentIndex = Int(newValue.rounded())
            }
        )
    }

    private var timeDescription: String {
        guard let frame = store.currentFrame else { return "No radar" }
        return frame.time.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }
}

// Live data: this fetches real frames and tiles, so it needs a network
// connection, and shows whatever weather is around right now.
#Preview(traits: .sizeThatFitsLayout) {
    RadarCard(
        place: Place(
            id: 5_780_026,
            name: "Cedar Hills",
            latitude: 40.4119,
            longitude: -111.7527,
            country: "United States",
            admin1: "Utah"
        )
    )
    .padding(20)
    .frame(width: 480)
}
