import Foundation

/// The chat field's emoji grid (the 😀 button unfolds it above the field): the Mac's AppKit field (`PlazaChatInput`) and the
/// Windows chat bar (`PlazaChatBarPanel`) show the same 40 emoji in the same order, 10 to a row, each in a 32-point cell.
/// The macOS emoji window does not open in the plaza on some Macs (not even with ⌃⌘Space or 🌐), so the grid is the app's own.
enum PlazaChatEmojis {
    /// Frequently used emoji, row by row.
    static let all = [
        "😀", "😂", "🤣", "😊", "😍", "🥰", "😎", "🤔", "😅", "😭",
        "😢", "😡", "🥺", "😴", "🤯", "🥳", "👍", "👎", "👏", "🙏",
        "🙌", "💪", "👀", "🔥", "✨", "🎉", "❤️", "💯", "✅", "❌",
        "☕", "🍜", "🍕", "🍺", "🎂", "☀️", "🌧️", "💻", "🐛", "🚀",
    ]
    static let columns = 10
    static let cell: CGFloat = 32
}
