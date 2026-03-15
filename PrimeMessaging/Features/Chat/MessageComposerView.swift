import SwiftUI

struct MessageComposerView: View {
    @Binding var draftText: String
    let onSend: (String) async -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: PrimeTheme.Spacing.small) {
            Button(action: { }) {
                Image(systemName: "plus.circle")
                    .font(.title3)
            }
            .buttonStyle(.plain)

            TextField("composer.placeholder".localized, text: $draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, PrimeTheme.Spacing.medium)
                .padding(.vertical, PrimeTheme.Spacing.small)
                .background(PrimeTheme.Colors.elevated)
                .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))

            Button {
                Task {
                    await onSend(draftText)
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(PrimeTheme.Colors.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(PrimeTheme.Spacing.large)
        .background(PrimeTheme.Colors.background)
    }
}
