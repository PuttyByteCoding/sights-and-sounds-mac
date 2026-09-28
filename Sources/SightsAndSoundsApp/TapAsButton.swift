import SwiftUI

extension View {
    /// A tap that VoiceOver also knows about. A bare `.onTapGesture` row
    /// has no role and no action: VoiceOver reads it as text and cannot
    /// press it, and keyboard users with Full Keyboard Access cannot
    /// reach it. This gives the row the button trait and the same action
    /// as its default one.
    func onTapAsButton(perform action: @escaping () -> Void) -> some View {
        onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }
}
