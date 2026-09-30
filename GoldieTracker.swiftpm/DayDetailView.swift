import AVKit
import SwiftUI

struct DayDetailView: View {
    @EnvironmentObject private var store: Store
    let day: Day
    @State private var showingHeatmap = false
    @State private var showingCustomRange = false
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(day.fullDate)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        .background(Color(.systemGroupedBackground))
        .navigationTitle(day.title)
        .toolbar {
            Button {
                showingHeatmap = true
            } label: {
                Label("Heat Map", systemImage: "flame.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .disabled(day.screenshots.isEmpty)  // heat maps and builds need the screenshots

            Button {
                showingCustomRange = true
            } label: {
                Label("Time Range", systemImage: "clock")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .disabled(day.screenshots.isEmpty)

            Button(action: buildNow) {
                Label(store.videoDate(for: day) == nil ? "Build Now" : "Rebuild", systemImage: "wand.and.stars")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isBuilding(day) || day.screenshots.isEmpty)

            if store.videoDate(for: day) != nil {
                Menu {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete Animation", systemImage: "trash")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .disabled(store.isBuilding(day))
            }
        }
        .confirmationDialog("Delete This Animation?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Animation", role: .destructive) {
                store.deleteAnimation(for: day)
            }
        } message: {
            if day.screenshots.isEmpty {
                Text("Its screenshots were already removed to save space, so it can't be rebuilt, and the day will disappear from the list.")
            } else {
                Text("The screenshots stay, so you can rebuild it anytime with Build Now. It won't be rebuilt automatically.")
            }
        }
        .fullScreenCover(isPresented: $showingHeatmap) {
            HeatmapView(day: day)
                .environmentObject(store)
        }
        .fullScreenCover(isPresented: $showingCustomRange) {
            CustomAnimationView(
                start: day.screenshots.first?.date ?? day.date,
                end: day.screenshots.last?.date ?? day.date
            )
            .environmentObject(store)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let progress = store.buildProgress[day.id] {
            BuildProgressView(title: "Building Animation", progress: progress, screenshotCount: day.screenshots.count)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
        } else if let videoDate = store.videoDate(for: day) {
            PlayerView(url: store.videoURL(for: day))
                .id("\(day.id) \(videoDate)")  // new player whenever the day or its video changes
        } else {
            ContentUnavailableView {
                Label("No Animation Yet", systemImage: "film.stack")
            } description: {
                Text("Build one from the \(day.screenshots.count) screenshots taken so far.")
            } actions: {
                Button("Build Animation Now", action: buildNow)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .card()
        }
    }

    private func buildNow() {
        Task { await store.buildNow(day.id) }
    }
}

extension View {
    /// The rounded panel on the grouped background used for the app's cards and tiles.
    func card(cornerRadius: CGFloat = 16) -> some View {
        background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .card(cornerRadius: 12)
    }
}

/// Progress for a build that works through a day's screenshots, e.g. "42% of 285 screenshots".
struct BuildProgressView: View {
    let title: String
    let progress: Double
    let screenshotCount: Int

    var body: some View {
        ProgressView(value: progress) {
            Text(title)
                .font(.headline)
        } currentValueLabel: {
            Text("\(Int(progress * 100))% of \(screenshotCount) screenshots")
        }
        .frame(maxWidth: 360)
    }
}

struct PlayerView: View {
    let url: URL
    @State private var player: AVPlayer?  // created once in onAppear, not on every redraw
    @AppStorage("playbackSpeed") private var speed = 1.0  // remembered across days and launches

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: player)
                .background(.black)

            HStack(spacing: 12) {
                // One frame is one screenshot, 5 minutes apart.
                Button {
                    step(by: -1)
                } label: {
                    Image(systemName: "backward.frame.fill")
                }
                .accessibilityLabel("Previous frame")
                Button {
                    step(by: 1)
                } label: {
                    Image(systemName: "forward.frame.fill")
                }
                .accessibilityLabel("Next frame")
                Divider()
                    .frame(height: 22)
                Image(systemName: "tortoise.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(value: $speed, in: 0.25...4, step: 0.25) {
                    Text("Playback Speed")
                }
                .accessibilityValue(String(format: "%.2f times", speed))
                Image(systemName: "hare.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Button {
                    speed = 1  // tap the speed to reset to normal
                } label: {
                    Text(String(format: "%.2f×", speed))
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityLabel("Playback speed \(String(format: "%.2f", speed)) times")
                .accessibilityHint("Resets to normal speed")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .onAppear {
            guard player == nil else { return }  // coming back (e.g. from the heat map) keeps its place
            let player = AVPlayer(url: url)
            // defaultRate is the speed the player's own play button uses.
            player.defaultRate = Float(speed)
            player.play()
            self.player = player
        }
        .onChange(of: speed) { _, newSpeed in
            guard let player else { return }
            player.defaultRate = Float(newSpeed)
            if player.rate != 0 {
                player.rate = Float(newSpeed)
            }
        }
        .onDisappear { player?.pause() }
    }

    /// Pauses and moves exactly one frame back or forward. It seeks to the frame's own time rather than using
    /// AVPlayerItem.step, which counts from the video's end time: one frame past the last screenshot, so the
    /// first step back from the end landed on the frame already showing.
    private func step(by frames: Int) {
        guard let player, let duration = player.currentItem?.duration, duration.isNumeric else { return }
        player.pause()
        let fps = Double(VideoBuilder.framesPerSecond)
        let lastFrame = max(0, Int((duration.seconds * fps).rounded()) - 1)
        let current = min(Int((player.currentTime().seconds * fps + 0.001).rounded(.down)), lastFrame)
        let target = min(max(current + frames, 0), lastFrame)
        player.seek(
            to: CMTime(value: CMTimeValue(target), timescale: VideoBuilder.framesPerSecond),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }
}
