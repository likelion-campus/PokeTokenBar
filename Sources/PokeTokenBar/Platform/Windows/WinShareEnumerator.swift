#if os(Windows)
import Foundation

/// A folder walk under a share (`//server/share/…`) for `PlatformCompat.enumerator` (stage 7 Task 14 review):
/// swift-foundation's URL-based enumerator and `contentsOfDirectory(at:)` return nothing there, while the String-based
/// `contentsOfDirectory(atPath:)` lists it (measured on the runner). Depth first, names sorted, a folder's contents right
/// after it, as Foundation's enumerator yields them; `skipDescendants()` and `level` behave as Foundation's do.
/// `skipsHiddenFiles` skips dot-names (the Mac's rule; the hidden attribute is not read, to keep one call per entry on a
/// slow share). Packages are a Mac notion: `skipsPackageDescendants` has nothing to skip here.
final class WinShareEnumerator: FileManager.DirectoryEnumerator {
    private let fm = FileManager.default
    private let skipsHiddenFiles: Bool
    /// Per open folder, its entries not yet returned (last = next).
    private var stack: [[String]] = []
    /// The folder just returned, opened on the next call unless `skipDescendants()` comes first.
    private var pendingFolder: String?
    private var currentLevel = 0

    init(root: String, skipsHiddenFiles: Bool) {
        self.skipsHiddenFiles = skipsHiddenFiles
        super.init()
        stack = [entries(of: root)]
    }

    private func entries(of folder: String) -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: PlatformCompat.listablePath(folder))) ?? []
        let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return names.filter { !(skipsHiddenFiles && $0.hasPrefix(".")) }.sorted(by: >).map { base + "/" + $0 }
    }

    override func nextObject() -> Any? {
        if let folder = pendingFolder { stack.append(entries(of: folder)) }
        pendingFolder = nil
        while let last = stack.last, last.isEmpty { stack.removeLast() }
        guard !stack.isEmpty else { return nil }
        let path = stack[stack.count - 1].removeLast()
        currentLevel = stack.count
        var isDir: ObjCBool = false
        let folder = fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        if folder { pendingFolder = path }
        return URL(fileURLWithPath: path, isDirectory: folder)
    }

    override func skipDescendants() { pendingFolder = nil }
    override var level: Int { currentLevel }
}
#endif
