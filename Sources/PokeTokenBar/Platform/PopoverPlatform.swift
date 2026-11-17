/// Which platform the popover's drawing runs on, for the one place its colours differ (`PopoverLabelOpacity`).
enum PopoverPlatform {
    #if os(Windows)
    static let isWindows = true
    #else
    static let isWindows = false
    #endif
}
