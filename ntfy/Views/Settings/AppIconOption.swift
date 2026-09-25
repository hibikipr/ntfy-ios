import Foundation
import SwiftUI
import UIKit

enum AppIconOption: String, CaseIterable, Identifiable, Hashable {
    case classic
    case orange
    case green
    case red
    case redDark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: return "Original"
        case .orange: return "Glass (Orange)"
        case .green: return "Glass (Green)"
        case .red: return "Glass (Red)"
        case .redDark: return "Glass (Red Dark)"
        }
    }

    /// Matches the asset catalog icon set name, and the value UIApplication expects for
    /// setAlternateIconName(_:). nil means the primary icon.
    var iconName: String? {
        switch self {
        case .classic: return nil
        case .orange: return "AppIcon-Orange"
        case .green: return "AppIcon-Green"
        case .red: return "AppIcon-Red"
        case .redDark: return "AppIcon-RedDark"
        }
    }

    var previewImageName: String {
        switch self {
        case .classic: return "AppIconPreview-Default"
        case .orange: return "AppIconPreview-Orange"
        case .green: return "AppIconPreview-Green"
        case .red: return "AppIconPreview-Red"
        case .redDark: return "AppIconPreview-RedDark"
        }
    }

    /// Matches the color sampled from this option's app icon, so the app's highlight color
    /// follows whichever icon is currently selected.
    var accentColor: Color {
        switch self {
        case .classic: return Color("AccentColor")
        case .orange: return Color("AccentColor-Orange")
        case .green: return Color("AccentColor-Green")
        case .red: return Color("AccentColor-Red")
        case .redDark: return Color("AccentColor-Red")
        }
    }

    static func current() -> AppIconOption {
        let name = UIApplication.shared.alternateIconName
        return AppIconOption.allCases.first { $0.iconName == name } ?? .classic
    }
}
