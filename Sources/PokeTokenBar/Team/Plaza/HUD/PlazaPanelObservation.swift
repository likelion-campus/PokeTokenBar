import Foundation
import Observation

/// Calls `changed` on the main actor after anything `track` read has changed, and keeps watching (re-registers first,
/// then reports, as `PlazaPillsPanel` does). SwiftUI read the models in its bodies; a panel follows the same properties.
/// Watching ends when the observer is released.
@MainActor final class PlazaChangeObserver {
    private let track: @MainActor () -> Void
    private let changed: @MainActor () -> Void

    init(track: @escaping @MainActor () -> Void, changed: @escaping @MainActor () -> Void) {
        self.track = track
        self.changed = changed
        arm()
    }

    private func arm() {
        withObservationTracking { track() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.arm()
                self.changed()
            }
        }
    }
}
