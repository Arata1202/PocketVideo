import SwiftUI

enum AppTextColor {
    static let supporting = Color(uiColor: UIColor { traits in
        if traits.accessibilityContrast == .high {
            return UIColor.label.resolvedColor(with: traits)
        }
        return traits.userInterfaceStyle == .dark ? .lightGray : .darkGray
    })

    static let red = Color(uiColor: UIColor { traits in
        UIColor.systemRed.resolvedColor(with: traits.modifyingTraits { $0.accessibilityContrast = .high })
    })
}
