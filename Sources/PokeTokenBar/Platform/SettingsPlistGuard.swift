import Foundation

/// Keeps the Windows settings plists from being lost. On Windows CoreFoundation writes a plist in place (no temporary
/// file, no rename: `CFURLWriteDataAndPropertiesToResource`), and when the file does not parse it retries three times and
/// then silently uses an EMPTY dictionary, so the next sync writes back only the changed keys: a kill or power cut during
/// a write can wipe every setting and `team.memberID`. The guard keeps a verified copy (`<plist>.bak`, written with
/// `PlatformCompat.atomicWrite`) and restores it at launch before the first read. Pure file logic, tested on both OSes.
enum SettingsPlistGuard {
    enum Outcome: Equatable {
        case untouched      // the plist parses (an older backup never replaces it)
        case restored       // missing, the backup came back
        case startsClean    // unreadable (does not parse) and no usable backup: CF will start from an empty dictionary
        case nothing        // no plist and no backup: a first run
        case restoreFailed  // a usable backup exists but could not be written back
        case leftAlone      // the plist exists but could not be read (sharing violation, ...): neither trusted nor replaced

        /// Whether this session may keep the backup up to date. When the launch could not establish a good plist (or a good
        /// plist from the backup), a later sync would back up near-empty settings over a good `.bak`.
        var allowsBackups: Bool { self == .untouched || self == .restored || self == .nothing }
    }

    enum BackupResult: Equatable {
        case written
        case invalid                 // the plist does not parse: nothing copied
        case refused(String)         // it would replace the backup's team.memberID: the old backup stays
    }

    static let memberIDKey = "team.memberID"

    static func backupURL(for plist: URL) -> URL { URL(fileURLWithPath: plist.path + ".bak") }

    /// A property list whose root is a dictionary: what CF accepts.
    static func parses(_ data: Data) -> Bool { dictionary(data) != nil }

    private static func dictionary(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty,
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        return root as? [String: Any]
    }

    /// Reads a file that exists, retrying briefly: a scanner or a writer finishing its rename can hold it for a moment.
    private static func readExisting(_ url: URL, attempts: Int = 4) -> Data? {
        for attempt in 0..<attempts {
            if let data = try? Data(contentsOf: url) { return data }
            if attempt < attempts - 1 { Thread.sleep(forTimeInterval: 0.05) }
        }
        return nil
    }

    static func restoreIfNeeded(plist: URL, log: (String) -> Void) -> Outcome {
        let name = plist.lastPathComponent
        let backup = backupURL(for: plist)
        var current: Data?
        let exists = FileManager.default.fileExists(atPath: plist.path)
        if exists {
            guard let data = readExisting(plist) else {
                log("settings plist \(name) exists but cannot be read: left alone, no backups this session")
                return .leftAlone
            }
            if parses(data) { return .untouched }
            current = data
        }
        let saved = FileManager.default.fileExists(atPath: backup.path) ? readExisting(backup) : nil
        if let saved, parses(saved) {
            do {
                try PlatformCompat.atomicWrite(saved, to: plist)
                log("settings plist \(name) was \(current == nil ? "missing" : "unreadable"): restored from its backup")
                return .restored
            } catch {
                log("settings plist \(name): restoring the backup failed: \(error); no backups this session")
                return .restoreFailed
            }
        }
        if current != nil {
            log("settings plist \(name) is unreadable and has no usable backup: starting with empty settings, no backups this session")
            return .startsClean
        }
        return .nothing
    }

    /// Copies the plist to its backup when it parses and does not replace the backup's `team.memberID` (a legitimate
    /// reset does not exist on Windows today, so a different or missing id means the settings were lost, not changed).
    static func backUp(plist: URL) -> BackupResult {
        guard let data = try? Data(contentsOf: plist), let new = dictionary(data) else { return .invalid }
        let backup = backupURL(for: plist)
        if let old = (try? Data(contentsOf: backup)).flatMap(dictionary), let oldID = old[memberIDKey] as? String,
           new[memberIDKey] as? String != oldID {
            return .refused("\(plist.lastPathComponent) has \(new[memberIDKey] == nil ? "no" : "a different") \(memberIDKey); the old backup is kept")
        }
        return (try? PlatformCompat.atomicWrite(data, to: backup)) != nil ? .written : .invalid
    }
}
