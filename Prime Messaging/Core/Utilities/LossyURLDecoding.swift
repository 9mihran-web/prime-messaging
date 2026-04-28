import Foundation

extension KeyedDecodingContainer {
    nonisolated func decodeLossyURLIfPresent(forKey key: Key) -> URL? {
        if let decodedURL = try? decodeIfPresent(URL.self, forKey: key) {
            return decodedURL
        }

        guard let rawValue = try? decodeIfPresent(String.self, forKey: key) else {
            return nil
        }

        guard rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }

        return URL(string: rawValue)
    }
}
