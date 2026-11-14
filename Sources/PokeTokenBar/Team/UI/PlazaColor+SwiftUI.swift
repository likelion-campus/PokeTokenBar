import SwiftUI

extension Color {
    /// The same colour the views built with `Color(cgColor:)` from the plaza's `CGColor`s.
    init(plaza color: PlazaColor) { self.init(cgColor: color.cgColor) }
}
