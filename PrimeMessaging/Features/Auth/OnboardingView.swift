import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: PrimeTheme.Spacing.xLarge) {
            Spacer()

            Text("app.title".localized)
                .font(.system(size: 36, weight: .bold, design: .rounded))
            Text("onboarding.subtitle".localized)
                .font(.title3)
                .foregroundStyle(PrimeTheme.Colors.textSecondary)

            VStack(spacing: PrimeTheme.Spacing.medium) {
                FeatureHighlight(title: "onboarding.online".localized, subtitle: "onboarding.online.subtitle".localized)
                FeatureHighlight(title: "onboarding.offline".localized, subtitle: "onboarding.offline.subtitle".localized)
            }

            Spacer()

            Button("onboarding.continue".localized) {
                appState.hasCompletedOnboarding = true
            }
            .buttonStyle(.borderedProminent)
            .tint(PrimeTheme.Colors.accent)
        }
        .padding(PrimeTheme.Spacing.xLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(PrimeTheme.Colors.background)
    }
}

struct FeatureHighlight: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: PrimeTheme.Spacing.small) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(PrimeTheme.Colors.textSecondary)
        }
        .padding(PrimeTheme.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PrimeTheme.Colors.elevated)
        .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))
    }
}
