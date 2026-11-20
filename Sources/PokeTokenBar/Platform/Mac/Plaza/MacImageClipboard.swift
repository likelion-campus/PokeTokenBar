import AppKit

/// The photo clipboard on the Mac: the general pasteboard gets the PNG alone (cleared first), as the plaza has always done.
struct MacImageClipboard: ImageClipboarding {
    func writePNG(_ data: Data) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setData(data, forType: .png)
    }
}
