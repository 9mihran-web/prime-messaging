import Foundation

enum BackendConfiguration {
    nonisolated static let defaultURLString = ""
    nonisolated private static let infoPlistKey = "PrimeMessagingServerURL"

    nonisolated static var currentURLString: String {
        let bundledURL = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String
        let trimmedURL = bundledURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedURL.isEmpty ? defaultURLString : trimmedURL
    }

    nonisolated static var currentBaseURL: URL? {
        let trimmedURL = currentURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return nil }
        return URL(string: trimmedURL)
    }
}
