#if os(Windows)
import Foundation
import WinSDK

/// The Bag tab (stage 7 Task 19; the Mac's `BagView`).
@MainActor final class WinBagPage: WinTabContent {
    let host: WinTabHost

    init(host: WinTabHost) {
        self.host = host
    }

    func build() {}

    func destroy() {}
}
#endif
