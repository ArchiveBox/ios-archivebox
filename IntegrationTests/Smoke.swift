import ArchiveBoxCore
import Foundation

@main
struct IntegrationChecks {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["ARCHIVEBOX_TEST_SERVER"], let token = env["ARCHIVEBOX_TEST_TOKEN"],
              let expected = env["ARCHIVEBOX_EXPECTED_SERVER"] else {
            fatalError("Set ARCHIVEBOX_TEST_SERVER, ARCHIVEBOX_EXPECTED_SERVER, and ARCHIVEBOX_TEST_TOKEN for a disposable real server.")
        }
        let client = ArchiveBoxClient()
        let server = try await client.discoverServer(address)
        guard server.absoluteString == expected else { fatalError("Wrong discovered host: \(server)") }
        print("PASS: discovered \(server)")
        var rejected = false
        do { try await client.testToken(server: server, token: "invalid-integration-key") }
        catch { rejected = true }
        guard rejected else { fatalError("An invalid API key was accepted") }
        print("PASS: invalid key rejected")
        try await client.testToken(server: server, token: token)
        print("PASS: real API key validated")
        let session = try await client.browserSession(server: server, token: token)
        guard !session.cookie.value.isEmpty, session.cookie.expires > Date().timeIntervalSince1970 else {
            fatalError("Server returned an invalid browser session")
        }
        let admin = try ServerAddress.normalize(session.admin_url.absoluteString)
        _ = try await client.sidebarProgress(server: admin, cookie: "\(session.cookie.name)=\(session.cookie.value)")
        print("PASS: API key exchanged for a working admin session and collection activity")
        let personas = try await client.personas(server: server, token: token)
        let selectedPersona = env["ARCHIVEBOX_TEST_PERSONA"]
        if let selectedPersona {
            guard personas.contains(where: { $0.name == selectedPersona }) else { fatalError("Requested test persona missing from server") }
        }
        print("PASS: fetched \(personas.count) server personas")
        let url = URL(string: "https://example.com/?archivebox-ios-integration=\(UUID().uuidString)")!
        let result = try await client.submit(urls: [url], configuration: .init(server: server, token: token, persona: selectedPersona))
        guard let crawlID = result.crawlID else { fatalError("No crawl ID returned") }
        print("PASS: accepted \(url) as crawl \(crawlID)")
        // Verify the durable server-side crawl independently of the submission response.
        var request = URLRequest(url: server.appending(path: "api/v1/crawls/crawl/" + crawlID))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let crawl = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (crawl["urls"] as? String)?.split(whereSeparator: \.isNewline).contains(Substring(url.absoluteString)) == true else {
            fatalError("Crawl API did not return the submitted URL")
        }
        print("PASS: saved URL verified through crawl API")
    }
}
