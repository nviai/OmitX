import Foundation
import Darwin

/// Computes the real on-disk size (like `du -sk`), without following symlinks;
/// hard links are counted once.
enum DiskUsage {
    static func size(of url: URL) -> Int64 {
        size(ofPaths: [url.path])
    }

    static func size(ofPaths paths: [String]) -> Int64 {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) || isSymlink($0) }
        guard !existing.isEmpty else { return 0 }

        var cPaths: [UnsafeMutablePointer<CChar>?] = existing.map { strdup($0) }
        cPaths.append(nil)
        defer { cPaths.forEach { free($0) } }

        guard let fts = fts_open(&cPaths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return 0 }
        defer { fts_close(fts) }

        struct Inode: Hashable { let dev: dev_t; let ino: ino_t }
        var seen = Set<Inode>()
        var total: Int64 = 0

        while let ent = fts_read(fts) {
            let info = Int32(ent.pointee.fts_info)
            switch info {
            case FTS_DP, FTS_DNR, FTS_ERR, FTS_NS:
                continue // DP = leaving a directory (already counted at FTS_D)
            default:
                guard let st = ent.pointee.fts_statp?.pointee else { continue }
                if st.st_nlink > 1 && (st.st_mode & S_IFMT) != S_IFDIR {
                    if !seen.insert(Inode(dev: st.st_dev, ino: st.st_ino)).inserted { continue }
                }
                total += Int64(st.st_blocks) * 512
            }
        }
        return total
    }

    static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// Information about the startup volume.
    static func volumeInfo() -> (total: Int64, available: Int64)? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity,
              let avail = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return (Int64(total), avail)
    }
}

/// Runs many tasks in parallel with a concurrency limit.
func concurrentMap<T: Sendable, R: Sendable>(
    _ items: [T], limit: Int = 6, _ transform: @escaping @Sendable (T) async -> R
) async -> [R] {
    var results = [R?](repeating: nil, count: items.count)
    await withTaskGroup(of: (Int, R).self) { group in
        var next = 0
        func addNext() {
            guard next < items.count else { return }
            let i = next, item = items[i]
            next += 1
            group.addTask { (i, await transform(item)) }
        }
        for _ in 0..<min(limit, items.count) { addNext() }
        for await (i, r) in group {
            results[i] = r
            addNext()
        }
    }
    return results.compactMap { $0 }
}
