import Foundation

/// Keeps Goldie's screenshots and animations from filling up the iPad.
enum StorageGuard {
    static let limitOptionsGB = [2, 5, 10, 20]
    static let defaultLimitGB = 5
    static let minimumFreeBytes: Int64 = 2_000_000_000  // always leave the iPad at least this much room

    /// Files that are removed together, e.g. all of one day's screenshots.
    struct Batch {
        let urls: [URL]
        let bytes: Int64
    }

    /// How much has to go to get under the limit and leave the minimum free space.
    static func bytesToFree(used: Int64, limit: Int64, available: Int64?) -> Int64 {
        let overLimit = used - limit
        let shortOfFreeSpace = available.map { minimumFreeBytes - $0 } ?? 0
        return max(0, overLimit, shortOfFreeSpace)
    }

    /// The first batches, in the order given, that together free at least `bytes`.
    static func pick(_ batches: [Batch], toFree bytes: Int64) -> [Batch] {
        var freed: Int64 = 0
        var picked: [Batch] = []
        for batch in batches where freed < bytes {
            picked.append(batch)
            freed += batch.bytes
        }
        return picked
    }

    /// Free space on the iPad, counting space iOS can reclaim from caches, or plain free space if that isn't available.
    /// Read from the app's home folder: it always exists (Documents may not yet) and is on the same drive as Goldie's files.
    static func availableBytes() -> Int64? {
        let values = try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
    }
}
