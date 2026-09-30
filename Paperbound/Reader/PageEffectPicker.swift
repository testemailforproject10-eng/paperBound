import SwiftUI

struct PageEffectPicker: View {
    @Binding var selection: PageEffect

    var body: some View {
        ForEach(PageEffect.allCases) { effect in
            Button {
                selection = effect
            } label: {
                HStack(spacing: 12) {
                    Group {
                        if effect == .none {
                            Image(systemName: "nosign").foregroundStyle(.secondary)
                        } else if effect == .footsteps {
                            Image("FootstepLeftDark").resizable().scaledToFit()
                        } else {
                            Image("EffectThumb-\(effect.rawValue)").resizable().scaledToFit()
                        }
                    }
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(effect.title).foregroundStyle(.primary)
                        Text(effect.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if selection == effect {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("page-effect-\(effect.rawValue)")
            .accessibilityAddTraits(selection == effect ? .isSelected : [])
        }
    }
}
