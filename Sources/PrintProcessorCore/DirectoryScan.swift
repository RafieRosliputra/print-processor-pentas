import Foundation

/// Recursive, symlink-loop-safe directory walk used by photo import. Directories
/// are tracked by their resolved (symlink-free) path so a symlink cycle cannot
/// recurse forever; matching files are de-duplicated by standardised path.
public enum DirectoryScan {
    public static func collectFiles(from urls: [URL], isIncluded: (URL) -> Bool) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        var visitedDirs = Set<String>()
        for url in urls {
            walk(url, into: &result, seen: &seen, visitedDirs: &visitedDirs, isIncluded: isIncluded)
        }
        return result
    }

    private static func walk(
        _ url: URL,
        into result: inout [URL],
        seen: inout Set<String>,
        visitedDirs: inout Set<String>,
        isIncluded: (URL) -> Bool
    ) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            // Guard against symlink loops with the resolved path, not the
            // (possibly aliased) path the caller handed us.
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard visitedDirs.insert(resolved).inserted else { return }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            for child in children {
                walk(child, into: &result, seen: &seen, visitedDirs: &visitedDirs, isIncluded: isIncluded)
            }
        } else if isIncluded(url) {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted {
                result.append(url)
            }
        }
    }
}
