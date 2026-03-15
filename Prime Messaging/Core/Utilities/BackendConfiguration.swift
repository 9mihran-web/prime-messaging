import Foundation

enum BackendConfiguration {
    static let defaultURLString = ""
    private static let infoPlistKey = "PrimeMessagingServerURL"

    static var currentURLString: String {
        let bundledURL = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String
        let trimmedURL = bundledURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedURL.isEmpty ? defaultURLString : trimmedURL
    }

    static var currentBaseURL: URL? {
        let trimmedURL = currentURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return nil }
        return URL(string: trimmedURL)
    }
}
