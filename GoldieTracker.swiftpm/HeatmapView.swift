import SwiftUI

@MainActor  // keeps build(with:) and its state updates on the main thread
struct HeatmapView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let day: Day

    private enum Phase {
        case pickingMarker
        case building(Double)
        case done(Heatmap)
        case failed(String)
    }

    /// A tap on Goldie's marker. Every tap is a new value, so each one restarts the work in `.task(id:)`.
    private struct MarkerTap: Equatable {
        let id = UUID()
        let point: CGPoint
    }

    @State private var phase: Phase?  // nil until the first step is decided, so nothing flashes
    @State private var referenceImage: UIImage?
    @State private var markerTap: MarkerTap?

    private var isDone: Bool {
        if case .done? = phase { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case nil:
                    Color.clear
                case .pickingMarker?:
                    MarkerPicker(image: referenceImage) { point in markerTap = MarkerTap(point: point) }
                case .building(let progress)?:
                    BuildProgressView(title: "Finding Goldie", progress: progress, screenshotCount: day.screenshots.count)
                case .done(let heatmap)?:
                    HeatmapResultView(heatmap: heatmap)
                        .transition(.opacity)
                case .failed(let message)?:
                    ContentUnavailableView {
                        Label("Couldn't Make a Heat Map", systemImage: "flame")
                    } description: {
                        Text(message)
                    } actions: {
                        if referenceImage != nil {  // nothing to pick on if no screenshot opens
                            Button("Pick Marker Again") { phase = .pickingMarker }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("\(day.title) Heat Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if isDone {
                        Button("Pick Marker Again", systemImage: "scope") { phase = .pickingMarker }
                    }
                }
            }
        }
        // All the work runs here, so SwiftUI cancels it when the screen closes.
        .task(id: markerTap) {
            if referenceImage == nil {
                referenceImage = HeatmapBuilder.lastReadableImage(in: day.screenshots)
            }
            guard let referenceImage else {
                phase = .failed("No readable screenshots for this day.")
                return
            }
            if let markerTap {
                phase = .building(0)
                do {
                    let template = try await HeatmapBuilder.makeTemplate(from: referenceImage, tappedAt: markerTap.point)
                    store.saveMarkerTemplate(template)
                } catch {
                    phase = .failed(error.localizedDescription)
                    return
                }
            }
            if let template = store.markerTemplate {
                await build(with: template)
            } else {
                phase = .pickingMarker
            }
        }
    }

    private func build(with template: MarkerTemplate) async {
        let cacheKey = "\(day.id)-\(day.screenshots.count)"
        if let last = store.lastHeatmap, last.key == cacheKey {
            phase = .done(last.heatmap)
            return
        }
        do {
            let heatmap = try await HeatmapBuilder.build(from: day.screenshots, template: template) { progress in
                phase = .building(progress)
            }
            store.lastHeatmap = (cacheKey, heatmap)
            withAnimation(.easeOut(duration: 0.5)) {
                phase = .done(heatmap)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// One-time step: the user taps Goldie's marker so the app knows what to look for.
struct MarkerPicker: View {
    let image: UIImage?
    let onPick: (CGPoint) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tap the center of Goldie's marker on the map")
                        .font(.headline)
                    Text("You only need to do this once. The app then finds her in every screenshot.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "hand.tap.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .card()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .overlay {
                        GeometryReader { geometry in
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { location in
                                    onPick(CGPoint(
                                        x: location.x / geometry.size.width,
                                        y: location.y / geometry.size.height
                                    ))
                                }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
            }
            Spacer(minLength: 0)
        }
        .padding()
    }
}

struct HeatmapResultView: View {
    let heatmap: Heatmap

    private var legendGradient: Gradient {
        Gradient(stops: HeatmapBuilder.colorStops.map {
            Gradient.Stop(
                color: Color(red: Double($0.red), green: Double($0.green), blue: Double($0.blue)),
                location: CGFloat($0.position)
            )
        })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ZStack {
                    // Fade the map so the heat stands out.
                    Image(uiImage: heatmap.base)
                        .resizable()
                        .scaledToFit()
                        .saturation(0.2)
                        .brightness(-0.08)
                    Image(uiImage: heatmap.overlay)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                }
                .overlay {
                    GeometryReader { geometry in
                        BusiestSpotMarker(labelBelow: heatmap.busiestSpot.y < 0.12)
                            .position(
                                x: heatmap.busiestSpot.x * geometry.size.width,
                                y: heatmap.busiestSpot.y * geometry.size.height
                            )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.15), radius: 18, y: 8)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Time Spent")
                        .font(.headline)
                    Capsule()
                        .fill(LinearGradient(gradient: legendGradient, startPoint: .leading, endPoint: .trailing))
                        .frame(height: 12)
                    HStack {
                        Text("Passing through")
                        Spacer()
                        Text("Most time")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding()
                .card()

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    StatTile(title: "Found Goldie", value: "\(heatmap.found) of \(heatmap.total)", systemImage: "scope")
                    StatTile(title: "Time Tracked", value: duration(minutes: heatmap.found * HeatmapBuilder.minutesPerScreenshot), systemImage: "clock")
                    StatTile(title: "Busiest Spot", value: duration(minutes: heatmap.busiestSpotMinutes), systemImage: "flame.fill")
                }

                Text("The heat shows where Goldie's marker appeared on the Find My map. For accurate results, don't pan or zoom the map during the day.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
    }

    private func duration(minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

/// A white ring with a soft pulse, marking where Goldie spent the most time.
struct BusiestSpotMarker: View {
    var labelBelow = false  // near the top edge the label would be cut off, so it goes underneath
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.8), lineWidth: 2)
                .scaleEffect(pulsing ? 1.8 : 1)
                .opacity(pulsing ? 0 : 1)
            Circle()
                .strokeBorder(.white, lineWidth: 3)
                .shadow(color: .black.opacity(0.5), radius: 4)
        }
        .frame(width: 34, height: 34)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Busiest spot")
        .overlay(alignment: labelBelow ? .bottom : .top) {
            Text("Busiest")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.65), in: Capsule())
                .fixedSize()
                .offset(y: labelBelow ? 24 : -24)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }
}
