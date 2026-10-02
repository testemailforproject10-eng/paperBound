import SwiftUI

struct PageTurnPicker: View {
    @Binding var selection: PageTurnStyle

    var body: some View {
        ForEach(PageTurnStyle.allCases) { style in
            Button {
                selection = style
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: style.systemImage)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(style.title).foregroundStyle(.primary)
                        Text(style.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if selection == style {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("page-turn-\(style.rawValue)")
            .accessibilityAddTraits(selection == style ? .isSelected : [])
        }
    }
}
