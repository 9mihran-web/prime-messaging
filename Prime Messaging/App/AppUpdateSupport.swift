import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct AppVersionPolicy: Decodable, Equatable {
    let latestVersion: String
    let minimumSupportedVersion: String?
    let appStoreURL: String?
    let title: String?
    let message: String?
    let requiredTitle: String?
    let requiredMessage: String?
}

struct AppUpdatePresentation: Equatable {
    let policy: AppVersionPolicy
    let currentVersion: String
    let updateAvailable: Bool
    let requiresUpdate: Bool

    var title: String {
        if requiresUpdate {
            return policy.requiredTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "Update Required"
        }
        return policy.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "Update Available"
    }

    var message: String {
        if requiresUpdate {
            return policy.requiredMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "Prime Messaging needs to be updated before you can continue."
        }
        return policy.message?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "A newer version of Prime Messaging is available."
    }

    var latestVersion: String {
        policy.latestVersion
    }

    var appStoreURL: URL? {
        let raw = policy.appStoreURL?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? AppUpdateService.defaultAppStoreURL
        return URL(string: raw)
    }
}

enum AppUpdateService {
    static let defaultAppStoreURL = "https://apps.apple.com/am/app/prime-messaging/id6761887670"
    private static let dismissedVersionDefaultsKey = "app_update.dismissed_optional_version"

    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            ?? "0"
    }

    static func fetchVersionPolicy() async throws -> AppVersionPolicy {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            throw URLError(.badURL)
        }

        var components = URLComponents(
            url: baseURL.appending(path: "/app/version-policy"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "platform", value: platformValue),
            URLQueryItem(name: "version", value: currentVersion),
        ]

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(platformValue, forHTTPHeaderField: "X-Prime-Platform")
        request.setValue(currentVersion, forHTTPHeaderField: "X-Prime-App-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard 200 ..< 300 ~= httpResponse.statusCode else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(AppVersionPolicy.self, from: data)
    }

    static func makePresentation(from policy: AppVersionPolicy) -> AppUpdatePresentation? {
        let currentVersion = currentVersion
        let updateAvailable = AppVersionComparator.compare(currentVersion, policy.latestVersion) == .orderedAscending
        let requiresUpdate: Bool = {
            guard let minimumVersion = policy.minimumSupportedVersion?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
                return false
            }
            return AppVersionComparator.compare(currentVersion, minimumVersion) == .orderedAscending
        }()

        guard updateAvailable || requiresUpdate else {
            clearDismissedOptionalVersion()
            return nil
        }

        if requiresUpdate == false, dismissedOptionalVersion() == policy.latestVersion {
            return nil
        }

        return AppUpdatePresentation(
            policy: policy,
            currentVersion: currentVersion,
            updateAvailable: updateAvailable,
            requiresUpdate: requiresUpdate
        )
    }

    static func dismissedOptionalVersion(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: dismissedVersionDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    static func dismissOptionalVersion(_ version: String, defaults: UserDefaults = .standard) {
        defaults.set(version, forKey: dismissedVersionDefaultsKey)
    }

    static func clearDismissedOptionalVersion(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: dismissedVersionDefaultsKey)
    }

    private static var platformValue: String {
        #if os(iOS)
        return "ios"
        #elseif os(watchOS)
        return "watchos"
        #elseif os(macOS)
        return "macos"
        #else
        return "unknown"
        #endif
    }
}

enum AppVersionComparator {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = versionParts(lhs)
        let rhsParts = versionParts(rhs)
        let maxCount = max(lhsParts.count, rhsParts.count)

        for index in 0 ..< maxCount {
            let lhsValue = index < lhsParts.count ? lhsParts[index] : 0
            let rhsValue = index < rhsParts.count ? rhsParts[index] : 0
            if lhsValue < rhsValue {
                return .orderedAscending
            }
            if lhsValue > rhsValue {
                return .orderedDescending
            }
        }

        return .orderedSame
    }

    private static func versionParts(_ version: String) -> [Int] {
        version
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }
}

struct OptionalAppUpdateBanner: View {
    let presentation: AppUpdatePresentation
    let onUpdate: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(PrimeTheme.Colors.accent)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(presentation.title) \(presentation.latestVersion)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                Text(presentation.message)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button("Later", action: onDismiss)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PrimeTheme.Colors.textSecondary)

            Button("Update", action: onUpdate)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(PrimeTheme.Colors.accent, in: Capsule())
        }
        .padding(14)
        .background(PrimeTheme.Colors.elevated, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(PrimeTheme.Colors.separator.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
    }
}

struct RequiredAppUpdateOverlay: View {
    let presentation: AppUpdatePresentation
    let onUpdate: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image("SplashIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)

                VStack(spacing: 8) {
                    Text(presentation.title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                        .multilineTextAlignment(.center)

                    Text(presentation.message)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }

                Button(action: onUpdate) {
                    Text("Update Now")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(PrimeTheme.Colors.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(.white)
                }
            }
            .padding(24)
            .frame(maxWidth: 360)
            .background(PrimeTheme.Colors.elevated, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(PrimeTheme.Colors.separator.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.24), radius: 24, y: 10)
            .padding(.horizontal, 24)
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
