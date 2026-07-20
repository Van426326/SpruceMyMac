// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

enum SpruceTheme {
    static let accent = Color(red: 0.10, green: 0.45, blue: 0.32)
    static let accentSoft = Color(red: 0.88, green: 0.94, blue: 0.91)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
}
struct CardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .background(SpruceTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.primary.opacity(0.06), lineWidth: 1)
            }
    }
}

extension View {
    func cardSurface() -> some View {
        modifier(CardSurface())
    }
}
