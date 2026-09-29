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
    @State private var pendingLimitGB: Int?  // a lower limit waiting for the user to confirm

    /// Raising the limit applies at once. Lowering it below what's already used removes files, so it asks first.
    private var storageLimit: Binding<Int> {
        Binding(
            get: { store.storageLimitGB },
            set: { newLimit in
                if Int64(newLimit) * 1_000_000_000 < store.storageUsed {
                    pendingLimitGB = newLimit
                } else {
                    store.storageLimitGB = newLimit
                }
            }
        )
    }

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
                Picker("Storage Limit", selection: storageLimit) {
                    ForEach(StorageGuard.limitOptionsGB, id: \.self) { gigabytes in
                        Text("\(gigabytes) GB").tag(gigabytes)
                    }
                }
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
        .confirmationDialog(
            "Lower the Storage Limit?",
            isPresented: Binding(get: { pendingLimitGB != nil }, set: { if !$0 { pendingLimitGB = nil } }),
            titleVisibility: .visible,
            presenting: pendingLimitGB
        ) { limit in
            Button("Lower to \(limit) GB", role: .destructive) {
                store.storageLimitGB = limit
            }
        } message: { _ in
            Text("Goldie's files are over that limit, so the oldest screenshots (and, if needed, the oldest animations) will be removed now. This can't be undone.")
        }
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
        HStack(spacing: 12) {
            Image(systemName: isTracking ? "location.fill" : "exclamationmark.triangle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(isTracking ? Color.green : Color.red, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)  // the text next to it says the same

            VStack(alignment: .leading, spacing: 2) {
                Text(isTracking ? "Tracking" : "Tracking Stopped")
                    .font(.headline)
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

            Spacer()

            if !isTracking {
                Link("Restart", destination: runGoldieSnapURL)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
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
            HStack {
                Label("Goldie Files", systemImage: "internaldrive")
                Spacer()
                Text("\(used.formatted(.byteCount(style: .file))) of \(limit.formatted(.byteCount(style: .file)))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(min(used, limit)), total: Double(limit))
                .tint(isFull ? Color.red : Color.accentColor)
            Group {
                if isFull {
                    Text("Storage is full and nothing more can be removed yet. Raise the limit or free up space on the iPad.")
                        .foregroundStyle(.red)
                } else {
                    Text("When full, the oldest screenshots are removed first (their animations are kept), then the oldest animations.")
                        .foregroundStyle(.secondary)
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
                    Text(day.timeRange)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(day.screenshots.count) screenshots")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if store.isBuilding(day) {
                ProgressView()
            } else if store.videoDate(for: day) != nil {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
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
                guard let url, let full = UIImage(contentsOfFile: url.path), full.size.width > 0, full.size.height > 0 else {
                    image = nil
                    return
                }
                // byPreparingThumbnail stretches to the exact size it's given, so keep the screenshot's
                // shape and just make it big enough to fill the 72×54 frame at 3x.
                let scale = max(216 / full.size.width, 162 / full.size.height)
                image = await full.byPreparingThumbnail(ofSize: CGSize(width: full.size.width * scale, height: full.size.height * scale))
            }
    }
}
