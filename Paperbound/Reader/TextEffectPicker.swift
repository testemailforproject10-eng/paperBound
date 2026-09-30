import SwiftUI

/// Offer effects with a working reader renderer. Legacy saved ink values still
/// decode, but currently render immediately rather than animating.
struct TextEffectPicker: View {
    @Binding var selection: InkBehavior

    var body: some View {
        Picker("Text effect", selection: Binding(
            get: { selection == .enchanted ? InkBehavior.enchanted : .instant },
            set: { selection = $0 }
        )) {
            Text("Instant").tag(InkBehavior.instant)
            Text("Enchanted Ink").tag(InkBehavior.enchanted)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("reader.textEffect")
    }
}
