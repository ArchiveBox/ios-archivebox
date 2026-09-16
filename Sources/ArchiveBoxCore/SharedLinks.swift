import Foundation

public enum SharedLinks {
    public static func isWebURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
            && url.user == nil && url.password == nil
    }

    public static func extract(from text: String) -> [URL] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains(where: { $0.isWhitespace }), let url = URL(string: trimmed), isWebURL(url) {
            return [url]
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return unique(detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap(\.url).filter(isWebURL))
    }

    public static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }
}
