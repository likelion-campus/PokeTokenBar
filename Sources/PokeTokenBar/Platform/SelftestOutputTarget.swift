import Foundation

/// `--selftest-out <path>`: the run clears the previous result before it writes. Only a regular file is ever removed; a folder
/// (`--selftest-out C:\Temp`, `.`, `..`) or anything else that is not a file is refused, because `removeItem` would delete a
/// folder with everything in it.
enum SelftestOutputTarget {
    /// The result file's progress sibling (`<file>.lines`).
    static func progressURL(_ url: URL) -> URL { url.appendingPathExtension("lines") }

    /// Why the run must not use `url` (or its `.lines` sibling), or nil when both are absent or regular files.
    static func refusal(for url: URL, fileManager: FileManager = .default) -> String? {
        for target in [url, progressURL(url)] {
            guard let type = type(of: target, fileManager) else { continue }
            if type != .typeRegular {
                return "--selftest-out needs a file path, but \(target.path) is not a regular file (\(type.rawValue)); nothing was changed"
            }
        }
        return nil
    }

    /// Removes the earlier result and progress files, and only if they are regular files.
    static func removeStale(_ url: URL, fileManager: FileManager = .default) {
        for target in [progressURL(url), url] where type(of: target, fileManager) == .typeRegular {
            try? fileManager.removeItem(at: target)
        }
    }

    private static func type(of url: URL, _ fileManager: FileManager) -> FileAttributeType? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }
}
