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

        let configuration = ServerConfiguration(server: server, token: token, persona: selectedPersona)
        try await client.updateTags(["share-test", "read later"], for: result, configuration: configuration)
        // The share sheet can finish tagging before the runner creates snapshots.
        // Create the real child through REST, then verify inherited and edited tags.
        var snapshotRequest = URLRequest(url: server.appending(path: "api/v1/core/snapshots"))
        snapshotRequest.httpMethod = "POST"
        snapshotRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        snapshotRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        snapshotRequest.httpBody = try JSONSerialization.data(withJSONObject: ["url": url.absoluteString, "crawl_id": crawlID])
        let (snapshotData, snapshotResponse) = try await URLSession.shared.data(for: snapshotRequest)
        guard (snapshotResponse as? HTTPURLResponse)?.statusCode == 200,
              let snapshot = try JSONSerialization.jsonObject(with: snapshotData) as? [String: Any],
              let snapshotID = snapshot["id"] as? String,
              Set(snapshot["tags"] as? [String] ?? []) == Set(["share-test", "read later"]) else {
            fatalError("Snapshot did not inherit tags saved after submission")
        }
        for tags in [["read later", "café"], []] {
            try await client.updateTags(tags, for: result, configuration: configuration)
            var getSnapshot = URLRequest(url: server.appending(path: "api/v1/core/snapshot/" + snapshotID))
            getSnapshot.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (updatedData, updatedResponse) = try await URLSession.shared.data(for: getSnapshot)
            guard (updatedResponse as? HTTPURLResponse)?.statusCode == 200,
                  let updated = try JSONSerialization.jsonObject(with: updatedData) as? [String: Any],
                  Set(updated["tags"] as? [String] ?? []) == Set(tags),
                  updated["url"] as? String == url.absoluteString else {
                fatalError("Tag edit did not propagate to the existing snapshot")
            }
        }
        let matches = try await client.search(query: url.absoluteString, limit: 1, configuration: configuration)
        guard matches.count == 1, matches[0].id == snapshotID, matches[0].url == url else {
            fatalError("Search did not return the newly created snapshot with its original URL")
        }
        let missing = try await client.search(query: UUID().uuidString, configuration: configuration)
        guard missing.isEmpty else { fatalError("Search returned results for an unknown unique query") }
        print("PASS: authenticated snapshot search returns matching records and an empty list for no matches")
        let resolved = try await client.snapshot(id: snapshotID, configuration: configuration)
        guard resolved.id == snapshotID, resolved.url == url else { fatalError("Entity resolution returned a different snapshot") }
        let recent = try await client.snapshots(limit: 1, configuration: configuration)
        guard recent.count == 1 else { fatalError("Recent pages did not respect the requested limit") }
        print("PASS: saved-page identity resolves through the real API and recent pages are bounded")
        print("PASS: tags inherit before snapshot creation and add/remove/clear afterward without resubmitting")
        // Removal must be scoped to this receipt, even if the same URL was shared twice.
        let otherShare = try await client.submit(urls: [url], configuration: configuration)
        try await client.removeSubmission(result, configuration: configuration)
        let (_, removedResponse) = try await URLSession.shared.data(for: request)
        guard (removedResponse as? HTTPURLResponse)?.statusCode == 404 else { fatalError("Removed crawl still exists") }
        request.url = server.appending(path: "api/v1/crawls/crawl/" + otherShare.crawlID!)
        let (_, otherResponse) = try await URLSession.shared.data(for: request)
        guard (otherResponse as? HTTPURLResponse)?.statusCode == 200 else { fatalError("Removal affected another share of the same URL") }
        try await client.removeSubmission(otherShare, configuration: configuration)
        print("PASS: cancellation/removal scoped to the submitted crawl")
    }
}
