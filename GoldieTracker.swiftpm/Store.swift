import SwiftUI

struct BuildError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

extension Date {
    /// The time of day, e.g. "3:05 PM".
    var timeText: String {
        formatted(date: .omitted, time: .shortened)
    }
}

struct Screenshot {
    let url: URL
    let date: Date
    let bytes: Int64
}

struct Day: Identifiable {
    let id: String  // "2026-09-29", also used as the animation file name
    let date: Date
    let screenshots: [Screenshot]  // empty once they've been removed to save space; the animation stays

    var title: String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    var fullDate: String {
        date.formatted(date: .complete, time: .omitted)
    }

    var timeRange: String {
        guard let first = screenshots.first?.date, let last = screenshots.last?.date else { return "" }
        return "\(first.timeText) – \(last.timeText)"
    }
}

@MainActor
final class Store: ObservableObject {
    @Published private(set) var folderURL: URL?
    @Published private(set) var days: [Day] = []
    /// Days whose animation is being built, and how far along each build is (0...1).
    @Published private(set) var buildProgress: [String: Double] = [:]
    @Published var errorMessage: String?
    /// What Goldie's map marker looks like, picked once by the user and reused for every heat map.
    @Published private(set) var markerTemplate: MarkerTemplate?
    /// The most recent heat map, so reopening it is instant. Only one is kept because each holds a full-size screenshot.
    var lastHeatmap: (key: String, heatmap: Heatmap)?
    /// When each day's automatic build last failed. Builds often fail just because the app went to the
    /// background (the shortcut brings Find My to the front every 5 minutes), so the daily build quietly
    /// retries after a short wait instead of showing an error every minute. Build Now always tries at once.
    private var autoBuildFailures: [String: Date] = [:]
    private let autoBuildRetryDelay: TimeInterval = 15 * 60

    /// Bytes used by Goldie's screenshots and animations, and the iPad's free space.
    @Published private(set) var storageUsed: Int64 = 0
    @Published private(set) var availableSpace: Int64?
    /// Goldie's files are kept under this many GB. Changing it cleans up right away.
    @Published var storageLimitGB = StorageGuard.defaultLimitGB {
        didSet {
            UserDefaults.standard.set(storageLimitGB, forKey: storageLimitKey)
            enforceStorageLimit()
        }
    }
    private var videoBytes: [String: Int64] = [:]  // animation file sizes, by day id
    /// Whether access to `folderURL` had to be started (and so must be stopped). Folders outside the app
    /// need it; folders the app can already read don't, and starting access on them just returns false.
    private var folderAccessStarted = false

    private let bookmarkKey = "screenshotFolderBookmark"
    private let storageLimitKey = "storageLimitGB"
    private let animationsFolder = URL.documentsDirectory.appending(path: "Animations")
    private let markerTemplateURL = URL.documentsDirectory.appending(path: "MarkerTemplate.json")

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init() {
        if let data = try? Data(contentsOf: markerTemplateURL) {
            markerTemplate = try? JSONDecoder().decode(MarkerTemplate.self, from: data)
        }
        let savedLimit = UserDefaults.standard.integer(forKey: storageLimitKey)
        if savedLimit > 0 {
            storageLimitGB = savedLimit
        }

        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var isStale = false
        if let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale) {
            folderAccessStarted = url.startAccessingSecurityScopedResource()
            folderURL = url
            // Only replace the saved bookmark if a fresh one was made; saving nil would erase the folder.
            if isStale, let freshBookmark = try? url.bookmarkData() {
                UserDefaults.standard.set(freshBookmark, forKey: bookmarkKey)
            }
            refresh()  // load the days now so the first screen isn't the setup checklist
        }
    }

    func setFolder(_ url: URL) {
        // False here only means the folder needs no special access; if it truly can't be read, refresh() says so.
        let accessStarted = url.startAccessingSecurityScopedResource()
        do {
            UserDefaults.standard.set(try url.bookmarkData(), forKey: bookmarkKey)
        } catch {
            errorMessage = "Couldn't remember that folder: \(error.localizedDescription)"
            if accessStarted {
                url.stopAccessingSecurityScopedResource()
            }
            return
        }
        releaseFolderAccess()  // access is counted, so this is right even when the same folder is picked again
        folderURL = url
        folderAccessStarted = accessStarted
        refresh()
    }

    /// Access to folders outside the app is limited, so let go of one that's no longer used.
    private func releaseFolderAccess() {
        if folderAccessStarted {
            folderURL?.stopAccessingSecurityScopedResource()
        }
        folderAccessStarted = false
    }

    /// Re-scans the screenshot and animation folders, groups everything by day (newest first) and totals the storage.
    func refresh() {
        guard let folderURL else { return }
        let keys: Set<URLResourceKey> = [.creationDateKey, .isRegularFileKey, .fileSizeKey]
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: Array(keys),
                options: .skipsHiddenFiles
            )
        } catch {
            // The folder was deleted, renamed or can't be opened. Forget it and show setup,
            // instead of failing (and showing this alert) again every minute.
            releaseFolderAccess()
            self.folderURL = nil
            days = []
            errorMessage = "Can't open the Goldie folder anymore (\(error.localizedDescription)). Please choose it again in Setup."
            return
        }

        let screenshots = files.compactMap { url -> Screenshot? in
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true, let date = values?.creationDate else { return nil }
            return Screenshot(url: url, date: date, bytes: Int64(values?.fileSize ?? 0))
        }

        // The Animations folder doesn't exist until the first build, so a failed listing just means none yet.
        let videos = (try? FileManager.default.contentsOfDirectory(at: animationsFolder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        videoBytes = [:]
        for video in videos where video.pathExtension == "mp4" {
            let size = (try? video.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            videoBytes[video.deletingPathExtension().lastPathComponent] = Int64(size)
        }

        let calendar = Calendar.current
        var allDays = Dictionary(grouping: screenshots) { calendar.startOfDay(for: $0.date) }
            .map { date, screenshots in
                Day(
                    id: dayID(for: date),
                    date: date,
                    screenshots: screenshots.sorted { $0.date < $1.date }
                )
            }
        // Days whose screenshots were removed to save space still have their animation.
        let screenshotDayIDs = Set(allDays.map(\.id))
        for id in videoBytes.keys where !screenshotDayIDs.contains(id) {
            if let date = date(forDayID: id) {
                allDays.append(Day(id: id, date: date, screenshots: []))
            }
        }
        days = allDays.sorted { $0.date > $1.date }

        storageUsed = screenshots.reduce(0) { $0 + $1.bytes } + videoBytes.values.reduce(0, +)
        availableSpace = StorageGuard.availableBytes()
    }

    func dayID(for date: Date) -> String {
        Self.dayFormatter.string(from: date)
    }

    func date(forDayID id: String) -> Date? {
        Self.dayFormatter.date(from: id)
    }

    var lastScreenshotDate: Date? {
        days.lazy.compactMap { $0.screenshots.last?.date }.first
    }

    func videoURL(for day: Day) -> URL {
        animationsFolder.appending(path: "\(day.id).mp4")
    }

    /// When the day's animation was last built, or nil if it hasn't been built.
    func videoDate(for day: Day) -> Date? {
        try? videoURL(for: day).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    func saveMarkerTemplate(_ template: MarkerTemplate) {
        markerTemplate = template
        lastHeatmap = nil
        do {
            try JSONEncoder().encode(template).write(to: markerTemplateURL)
        } catch {
            errorMessage = "Couldn't save Goldie's marker: \(error.localizedDescription)"
        }
    }

    func isBuilding(_ day: Day) -> Bool {
        buildProgress[day.id] != nil
    }

    /// Builds the day's animation. It's written to a temporary file and only swapped in once complete,
    /// so an interrupted build never leaves a half-written video behind or loses the previous one.
    func build(_ day: Day, showErrors: Bool = true) async {
        guard !isBuilding(day), !day.screenshots.isEmpty else { return }  // nothing to build from
        buildProgress[day.id] = 0
        let partialURL = FileManager.default.temporaryDirectory.appending(path: "\(day.id).mp4")
        do {
            try await VideoBuilder.makeVideo(from: day.screenshots, to: partialURL) { progress in
                self.buildProgress[day.id] = progress
            }
            try FileManager.default.createDirectory(at: animationsFolder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: videoURL(for: day).path) {
                try FileManager.default.removeItem(at: videoURL(for: day))
            }
            try FileManager.default.moveItem(at: partialURL, to: videoURL(for: day))
            autoBuildFailures[day.id] = nil
        } catch {
            try? FileManager.default.removeItem(at: partialURL)  // may not exist
            autoBuildFailures[day.id] = .now
            if showErrors {
                errorMessage = "Couldn't build the animation for \(day.title): \(error.localizedDescription) If you switched away from the app while it was building, tap Build Now again."
            }
        }
        buildProgress[day.id] = nil
        refresh()  // pick up the new animation's size for the storage total
    }

    /// True when the day has no animation, or its animation was built before the day's last screenshot
    /// (for example, Build Now was tapped mid-afternoon).
    func needsAnimation(_ day: Day) -> Bool {
        guard let lastScreenshot = day.screenshots.last?.date else { return false }
        guard let videoDate = videoDate(for: day) else { return true }
        return videoDate < lastScreenshot
    }

    /// Picks up the newest screenshots, then builds the day's animation.
    func buildNow(_ dayID: String) async {
        refresh()
        guard let day = days.first(where: { $0.id == dayID }) else { return }
        await build(day)
    }

    /// The daily build: every finished day (before today) gets a complete animation.
    func buildMissingAnimations() async {
        let today = Calendar.current.startOfDay(for: .now)
        for day in days where day.date < today && needsAnimation(day) {
            if let failed = autoBuildFailures[day.id], Date.now.timeIntervalSince(failed) < autoBuildRetryDelay {
                continue  // failed a moment ago; try again later
            }
            await build(day, showErrors: false)
        }
    }

    /// Keeps Goldie's files under the storage limit and leaves the iPad some free room, removing the oldest first:
    /// a finished day's screenshots (only once its animation is up to date), then, as a last resort, animations.
    /// Today, and any day still waiting for its animation, is never touched.
    func enforceStorageLimit() {
        let today = Calendar.current.startOfDay(for: .now)
        let finishedOldestFirst = days.reversed().filter { day in
            // A day being rebuilt still needs its screenshots, even though its current animation is complete.
            day.date < today && videoDate(for: day) != nil && !needsAnimation(day) && !isBuilding(day)
        }
        let screenshotBatches = finishedOldestFirst.filter { !$0.screenshots.isEmpty }.map { day in
            StorageGuard.Batch(urls: day.screenshots.map(\.url), bytes: day.screenshots.reduce(0) { $0 + $1.bytes })
        }
        let animationBatches = finishedOldestFirst.map { day in
            StorageGuard.Batch(urls: [videoURL(for: day)], bytes: videoBytes[day.id] ?? 0)
        }
        // Every screenshot batch comes before any animation, so an animation is only removed once its own
        // day's screenshots are gone too. It can never be rebuilt and removed over and over.
        let bytesToFree = StorageGuard.bytesToFree(
            used: storageUsed,
            limit: Int64(storageLimitGB) * 1_000_000_000,
            available: availableSpace
        )
        let batches = StorageGuard.pick(screenshotBatches + animationBatches, toFree: bytesToFree)
        guard !batches.isEmpty else { return }
        for url in batches.flatMap(\.urls) {
            try? FileManager.default.removeItem(at: url)  // already gone is fine
        }
        refresh()
    }
}
