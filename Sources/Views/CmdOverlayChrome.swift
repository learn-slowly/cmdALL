import SwiftUI

extension View {
    /// Shared chrome for command-style overlay panels (command palette, omnisearch):
    /// translucent material background, 12pt corner radius, a soft shadow.
    func cmdOverlayChrome() -> some View {
        self
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 10)
    }
}
