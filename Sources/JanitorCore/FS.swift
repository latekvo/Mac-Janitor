import Foundation

public enum FS {
    static func lstatInfo(_ path: String) -> stat? {
        var st = stat()
        return lstat(path, &st) == 0 ? st : nil
    }

    static func mtime(_ st: stat) -> Date {
        Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    public static func exists(_ path: String) -> Bool { lstatInfo(path) != nil }

    /// Symlink-free absolute spelling, so paths from git and from directory
    /// listings compare equal (`/var` vs `/private/var`). Unchanged if missing.
    public static func canonical(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }

    public static func isSymlink(_ path: String) -> Bool {
        guard let st = lstatInfo(path) else { return false }
        return st.st_mode & S_IFMT == S_IFLNK
    }

    public static func isDirectory(_ path: String) -> Bool {
        guard let st = lstatInfo(path) else { return false }
        return st.st_mode & S_IFMT == S_IFDIR
    }

    /// Depth-first walk that never follows symlinks. `visit` returns false to
    /// skip a directory's contents; `stop` set to true ends the walk.
    static func walk(_ root: String, _ visit: (_ path: String, _ name: String, _ st: stat, _ stop: inout Bool) -> Bool) {
        var stack = [root]
        var stop = false
        while let dir = stack.popLast(), !stop {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for name in names {
                let path = dir + "/" + name
                guard let st = lstatInfo(path) else { continue }
                let descend = visit(path, name, st, &stop)
                if stop { return }
                if descend && st.st_mode & S_IFMT == S_IFDIR { stack.append(path) }
            }
        }
    }

    /// Newest modification time of `root` and everything under it, ignoring
    /// directories named in `skipping`. With `newerThan`, returns as soon as one
    /// entry beats it, which is all a threshold check needs.
    public static func newestMTime(_ root: String, skipping: Set<String> = [], newerThan cutoff: Date? = nil) -> Date? {
        guard let rootSt = lstatInfo(root) else { return nil }
        var newest = mtime(rootSt)
        if let cutoff, newest > cutoff { return newest }
        walk(root) { _, name, st, stop in
            if skipping.contains(name) && st.st_mode & S_IFMT == S_IFDIR { return false }
            let m = mtime(st)
            if m > newest { newest = m }
            if let cutoff, m > cutoff { stop = true }
            return true
        }
        return newest
    }

    /// Allocated bytes under `root`, counting each hard-linked inode once.
    public static func allocatedSize(_ root: String) -> Int64 {
        guard let rootSt = lstatInfo(root) else { return 0 }
        var total = Int64(rootSt.st_blocks) * 512
        if rootSt.st_mode & S_IFMT != S_IFDIR { return total }
        var seen = Set<UInt64>()
        walk(root) { _, _, st, _ in
            if st.st_nlink > 1 && st.st_mode & S_IFMT != S_IFDIR {
                if !seen.insert(st.st_ino).inserted { return true }
            }
            total += Int64(st.st_blocks) * 512
            return true
        }
        return total
    }

    /// Resolves `.` and `..` without touching the disk. Unlike
    /// `NSString.standardizingPath` it keeps `/private`, which that strips from `/private/tmp`.
    public static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for c in path.split(separator: "/") {
            if c == "." { continue }
            if c == ".." { _ = parts.popLast(); continue }
            parts.append(c)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Absolute target of a symlink, one hop: a relative target is resolved against
    /// the link's canonical directory, but a link to a link is not followed.
    public static func linkTarget(_ path: String) -> String? {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
        let abs = dest.hasPrefix("/") ? dest : canonical((path as NSString).deletingLastPathComponent) + "/" + dest
        let target = normalize(abs)
        return canonical((target as NSString).deletingLastPathComponent) + "/" + (target as NSString).lastPathComponent
    }

    /// Removes a file, symlink (not its target) or directory tree.
    public static func remove(_ path: String) throws {
        try Safety.check(path)
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            // Read-only entries (some package caches) defeat removeItem; rm copes.
            let r = Shell.run(["/bin/rm", "-rf", "--", path], timeout: 1800)
            if !r.ok || exists(path) { throw JanitorError("could not remove \(path): \(r.stderr)") }
        }
    }
}

public struct JanitorError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// Last line of defence: refuses paths whose removal could be catastrophic,
/// whatever rule produced them.
public enum Safety {
    public static var protectedPaths: [String] = []

    public static func check(_ raw: String) throws {
        let path = FS.normalize(raw)
        let home = Paths.home.path
        guard path.hasPrefix("/"), path.split(separator: "/").count >= 3 else {
            throw JanitorError("refusing to remove shallow path \(path)")
        }
        for p in [home, home + "/dev", home + "/dev/engineering", "/private/tmp", "/tmp"] + protectedPaths {
            if path == p || p.hasPrefix(path + "/") {
                throw JanitorError("refusing to remove \(path): it is or contains \(p)")
            }
        }
    }
}
