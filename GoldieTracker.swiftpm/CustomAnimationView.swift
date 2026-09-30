import SwiftUI

/// Builds an animation from any stretch of time, across days if needed, and plays it.
/// It's kept only while it's being watched, so it doesn't count toward Goldie's storage.
@MainActor  // keeps build() and its state updates on the main thread
struct CustomAnimationView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date
    @State private var buildRequest: BuildRequest?
    @State private var progress: Double?
    @State private var buildingCount = 0
    @State private var video: BuiltVideo?
    @State private var errorMessage: String?

    /// A tap on Build. Every tap is a new value, so each one restarts the work in `.task(id:)`.
    private struct BuildRequest: Equatable {
        let id = UUID()
        let start: Date
        let end: Date
    }

    /// A finished animation. A new id for every build gives the player a fresh start.
    private struct BuiltVideo {
        let id = UUID()
        let url: URL
    }

    private static let videoURL = FileManager.default.temporaryDirectory.appending(path: "Custom Animation.mp4")

    init(start: Date, end: Date) {
        _start = State(initialValue: start)
        _end = State(initialValue: end)
    }

    /// From the oldest screenshot still saved up to now. min() keeps the range valid if a clock change put one in the future.
    private var bounds: ClosedRange<Date> {
        min(store.firstScreenshotDate ?? .now, .now)...Date.now
    }

    private var matchingCount: Int {
        store.screenshots(from: start, to: end).count
    }

    private var summary: String {
        guard matchingCount > 0 else { return "No screenshots in this range." }
        let seconds = Double(matchingCount) / Double(VideoBuilder.framesPerSecond)
        let length = Duration.seconds(max(1, seconds.rounded())).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
        return "\(matchingCount) screenshots. Plays for about \(length) at normal speed."
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    DatePicker("From", selection: $start, in: bounds)
                    // Capped at now, so the range can never run backwards (which would crash).
                    DatePicker("To", selection: $end, in: min(max(start, bounds.lowerBound), bounds.upperBound)...bounds.upperBound)
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .card()

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding()
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Custom Animation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        buildRequest = BuildRequest(start: start, end: end)
                    } label: {
                        Label("Build", systemImage: "wand.and.stars")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(matchingCount == 0 || progress != nil)
                }
            }
        }
        .onChange(of: start) { _, newStart in
            if end < newStart {
                end = newStart  // keep the range the right way round
            }
        }
        // The build runs here, so SwiftUI cancels it when the screen closes.
        .task(id: buildRequest) {
            await build()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let progress {
            BuildProgressView(title: "Building Animation", progress: progress, screenshotCount: buildingCount)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
        } else if let video {
            PlayerView(url: video.url)
                .id(video.id)
        } else if let errorMessage {
            ContentUnavailableView {
                Label("Couldn't Build the Animation", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .card()
        } else {
            ContentUnavailableView {
                Label("Choose a Time Range", systemImage: "clock")
            } description: {
                Text("Set where the animation starts and stops, then tap Build. The range can cross days.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .card()
        }
    }

    private func build() async {
        guard let buildRequest else { return }
        let screenshots = store.screenshots(from: buildRequest.start, to: buildRequest.end)
        guard !screenshots.isEmpty else { return }
        let spansDays = !Calendar.current.isDate(buildRequest.start, inSameDayAs: buildRequest.end)

        video = nil  // let go of the previous animation before its file is replaced
        errorMessage = nil
        buildingCount = screenshots.count
        progress = 0
        do {
            try await VideoBuilder.makeVideo(from: screenshots, to: Self.videoURL, showsDate: spansDays) { value in
                progress = value
            }
            video = BuiltVideo(url: Self.videoURL)
        } catch is CancellationError {
            // The screen was closed; nothing to show.
        } catch {
            errorMessage = "\(error.localizedDescription) If you switched away from the app while it was building, tap Build again."
        }
        progress = nil
    }
}
