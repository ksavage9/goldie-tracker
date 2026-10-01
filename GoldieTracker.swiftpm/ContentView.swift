import SwiftUI

let openShortcutsURL = URL(string: "shortcuts://")!
let runGoldieSnapURL = URL(string: "shortcuts://run-shortcut?name=Goldie%20Snap")!

struct ContentView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedDayID: String?
    @State private var showingSetup = false

    var body: some View {
        Group {
            if store.folderURL == nil || store.days.isEmpty {
                NavigationStack {
                    SetupView()
                }
            } else {
                NavigationSplitView {
                    DayList(selectedDayID: $selectedDayID, showingSetup: $showingSetup)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 300)  // leave the map as much room as possible
                } detail: {
                    if let day = store.days.first(where: { $0.id == selectedDayID }) {
                        DayDetailView(day: day)
                    } else if let selectedDayID, let date = store.date(forDayID: selectedDayID) {
                        ContentUnavailableView(
                            "Nothing Saved",
                            systemImage: "calendar.badge.exclamationmark",
                            description: Text("There are no screenshots or animation for \(date.formatted(date: .complete, time: .omitted)).")
                        )
                    } else {
                        ContentUnavailableView("Select a Day", systemImage: "pawprint")
                    }
                }
            }
        }
        .sheet(isPresented: $showingSetup) {
            NavigationStack {
                SetupView()
                    .toolbar {
                        Button("Done") { showingSetup = false }
                            .fontWeight(.semibold)
                    }
            }
        }
        .alert("Something Went Wrong", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .onChange(of: store.days.first?.id, initial: true) { _, newestDayID in
            if selectedDayID == nil {
                selectedDayID = newestDayID
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.refresh()
            }
        }
        .task {
            // While the app is open: pick up new screenshots every minute, build any finished day
            // whose animation is missing or out of date, then make sure storage stays under the limit.
            while !Task.isCancelled {
                store.refresh()
                await store.buildMissingAnimations()
                store.enforceStorageLimit()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}

struct DayList: View {
    @EnvironmentObject private var store: Store
    @Binding var selectedDayID: String?
    @Binding var showingSetup: Bool

    /// The date picker shows the selected day, and picking a date selects that day.
    private var jumpDate: Binding<Date> {
        Binding(
            get: { selectedDayID.flatMap { store.date(forDayID: $0) } ?? .now },
            set: { selectedDayID = store.dayID(for: $0) }
        )
    }

    var body: some View {
        List(selection: $selectedDayID) {
            Section {
                TrackingStatusRow(lastScreenshot: store.lastScreenshotDate)
            }

            Section {
                DatePicker(
                    selection: jumpDate,
                    // min() so a screenshot dated in the future (clock change) can't make an invalid range and crash.
                    in: min(store.days.last?.date ?? .now, .now)...Date.now,
                    displayedComponents: .date
                ) {
                    Label("Jump to Date", systemImage: "calendar")
                }
            }

            Section("Storage") {
                StorageRow(used: store.storageUsed, limitGB: store.storageLimitGB, available: store.availableSpace)
            }

            Section("History") {
                ForEach(store.days) { day in
                    DayRow(day: day)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Goldie")
        .refreshable { store.refresh() }
        .toolbar {
            Button("Setup", systemImage: "gearshape") { showingSetup = true }
        }
    }
}

struct TrackingStatusRow: View {
    let lastScreenshot: Date?  // nil when no screenshots are left, e.g. tracking stopped days ago

    private var isTracking: Bool {
        guard let lastScreenshot else { return false }
        return lastScreenshot > Date.now.addingTimeInterval(-15 * 60)
    }

    var body: some View {
        // Stacked rather than side by side: the sidebar is too narrow for the title, text and button in one row.
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isTracking ? "location.fill" : "exclamationmark.triangle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(isTracking ? Color.green : Color.red, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)  // the text next to it says the same

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isTracking ? "Tracking" : "Tracking Stopped")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Group {
                        if let lastScreenshot {
                            Text("Last screenshot \(lastScreenshot, style: .relative) ago")
                        } else {
                            Text("No screenshots saved")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if !isTracking {
                    Link("Restart", destination: runGoldieSnapURL)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct StorageRow: View {
    let used: Int64
    let limitGB: Int
    let available: Int64?

    private var limit: Int64 { Int64(limitGB) * 1_000_000_000 }

    /// Still over after cleaning up: only today's screenshots and days still waiting for an animation are left.
    private var isFull: Bool {
        used > limit || (available ?? .max) < StorageGuard.minimumFreeBytes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Name and numbers on separate lines: side by side they don't fit the sidebar.
            Label("Goldie Files", systemImage: "internaldrive")
            Text("\(used.formatted(.byteCount(style: .file))) of \(limit.formatted(.byteCount(style: .file))) used")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            ProgressView(value: Double(min(used, limit)), total: Double(limit))
                .tint(isFull ? Color.red : Color.accentColor)
            Group {
                if isFull {
                    Text("Storage is full and nothing more can be removed yet. Raise the limit in Setup, or free up space on the iPad.")
                        .foregroundStyle(.red)
                }
                if let available {
                    Text("iPad: \(available.formatted(.byteCount(style: .file))) free")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }
}

struct DayRow: View {
    @EnvironmentObject private var store: Store
    let day: Day

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(url: day.screenshots.last?.url)

            VStack(alignment: .leading, spacing: 3) {
                Text(day.title)
                    .font(.headline)
                if day.screenshots.isEmpty {
                    Text("Screenshots removed to save space")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    // Faded primary rather than .secondary: it turns white on the selected row's orange
                    // highlight (like the title), where .secondary is too faint to read.
                    Text(day.timeRange)
                        .font(.subheadline)
                        .foregroundStyle(.primary.opacity(0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)  // "7:00 AM – 7:55 AM" stays on one line in the sidebar
                    Text("\(day.screenshots.count) screenshots")
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.6))
                }
            }

            Spacer()

            if store.isBuilding(day) {
                ProgressView()
            }
        }
        .padding(.vertical, 4)
    }
}

/// A small, rounded preview of a screenshot, loaded off the main thread. Without one, it shows a film icon.
struct ThumbnailView: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if url == nil {
                    Image(systemName: "film")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)  // decorative; the row's text says which day it is
            .task(id: url) {
                // The old thumbnail stays up until the new one is ready, so today's row doesn't flicker every 5 minutes.
                guard let url else {
                    image = nil
                    return
                }
                image = await Self.thumbnail(of: url)
            }
    }

    /// Reads a small version straight from the file, keeping the screenshot's shape. Opening the full screenshot
    /// first (2732 × 2048, about 22 MB in memory) for every row at once could use enough memory to get the app shut down.
    nonisolated private static func thumbnail(of url: URL) async -> UIImage? {
        ImageFile.downsampled(url, maxPixelSize: 288).map { UIImage(cgImage: $0) }  // fills the 72×54 frame at 3x
    }
}
