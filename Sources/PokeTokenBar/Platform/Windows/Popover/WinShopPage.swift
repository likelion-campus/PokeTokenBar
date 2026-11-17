#if os(Windows)
import Foundation
import WinSDK

/// The Shop tab (stage 7 Task 19; the Mac's `ShopView`).
@MainActor final class WinShopPage: WinTabContent {
    let host: WinTabHost

    init(host: WinTabHost) {
        self.host = host
    }

    func build() {}

    func destroy() {}
}
#endif
