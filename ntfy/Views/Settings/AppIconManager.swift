import SwiftUI
import UIKit

/// Tracks the currently active app icon and publishes changes so the rest of the app (accent
/// color, `AppIconPickerView`) can react immediately when the user picks a new one, without
/// needing to relaunch. `UIApplication.alternateIconName` is itself the durable, OS-level source
/// of truth — this class just makes it observable.
@MainActor
final class AppIconManager: ObservableObject {
    @Published private(set) var current: AppIconOption = AppIconOption.current()

    func setIcon(_ option: AppIconOption, completion: ((Error?) -> Void)? = nil) {
        guard option != current else {
            completion?(nil)
            return
        }
        UIApplication.shared.setAlternateIconName(option.iconName) { [weak self] error in
            Task { @MainActor in
                if error == nil {
                    self?.current = option
                }
                completion?(error)
            }
        }
    }
}
