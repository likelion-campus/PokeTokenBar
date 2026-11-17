#if os(Windows)
import Foundation
import WinSDK

// MARK: Task 20 — the Collection tab (owned by the Collection task; stage 7 Task 19 only registers it)
//
// `WinTabPages.content(for: .collection, host:)` builds `WinCollectionPage(host:)`. The page adds its sections to
// `host.stack` in `build()` and gives everything back in `destroy()` (see `WinTabContent` in WinTabs.swift). Until the Collection
// task builds it, the tab is empty.
@MainActor final class WinCollectionPage: WinTabContent {
    let host: WinTabHost

    init(host: WinTabHost) {
        self.host = host
    }

    func build() {}

    func destroy() {}
}
// MARK: end Task 20
#endif
