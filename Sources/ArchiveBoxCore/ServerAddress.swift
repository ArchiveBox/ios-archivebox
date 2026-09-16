import Foundation

public enum ServerAddress {
    /// Pasted admin/API links are normalized to the server origin, as in the browser extension.
    public static func normalize(_ input: String) throws -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else {
            throw ArchiveBoxError.message("Enter your ArchiveBox server address.")
        }
        let qualified = text.contains("://") ? text : "https://" + text
        guard var parts = URLComponents(string: qualified),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw ArchiveBoxError.message("Use an http:// or https:// server address without a username or password.")
        }
        parts.scheme = scheme
        parts.host = host.lowercased()
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        guard let url = parts.url else { throw ArchiveBoxError.message("That server address is not valid.") }
        return url
    }

    /// Probe only the known ArchiveBox host variants, without ever sending a token.
    public static func candidates(for input: String) throws -> [URL] {
        let original = try normalize(input)
        guard var parts = URLComponents(url: original, resolvingAgainstBaseURL: false), let host = parts.host else {
            return [original]
        }
        if host.contains(":") || host.split(separator: ".").allSatisfy({ UInt8($0) != nil }) || host == "localhost" {
            return [original]
        }
        let prefixes = ["api.", "admin.", "web."]
        let base = prefixes.first(where: { host.hasPrefix($0) }).map { String(host.dropFirst($0.count)) } ?? host
        var result = [original]
        for candidate in ["api." + base, base] {
            parts.host = candidate
            if let url = parts.url, !result.contains(url) { result.append(url) }
        }
        return result
    }
}

public enum ArchiveBoxError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}
