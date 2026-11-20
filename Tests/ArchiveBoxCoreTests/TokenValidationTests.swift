import Foundation
import Testing
@testable import ArchiveBoxCore

@Test func tokenValidationRequiresUnambiguousSemanticRejection() throws {
    try ArchiveBoxClient.validateTokenResponse(Data(#"{"success":true,"user_id":"fixture-user"}"#.utf8))
    for body in [#"{"success":false,"user_id":null}"#, #"{"success":false,"user_id":null,"username":null}"#] {
        #expect(throws: APIKeyValidationError.self) {
            try ArchiveBoxClient.validateTokenResponse(Data(body.utf8))
        }
    }
    for body in [#"{}"#, #"{"success":true}"#, #"{"success":true,"user_id":""}"#,
                 #"{"success":true,"user_id":"  \n\t"}"#,
                 #"{"success":false}"#, #"{"success":false,"username":null}"#,
                 #"{"success":false,"user_id":"fixture-user"}"#, #"{"success":false,"user_id":null,"username":"fixture-user"}"#,
                 #"{"success":"false"}"#, "<html>Bad Gateway</html>"] {
        do {
            try ArchiveBoxClient.validateTokenResponse(Data(body.utf8))
            Issue.record("Incomplete or contradictory validation must fail")
        } catch {
            #expect(!(error is APIKeyValidationError))
        }
    }
}

@Test func splitHostRecoveryNavigationKeepsTrustedBoundary() throws {
    let server = URL(string: "https://api.archive.example")!
    let base = URL(string: "https://archive.example")!
    let login = URL(string: "https://admin.archive.example/admin/login/?next=/admin/api/apitoken/")!
    #expect(BrowserNavigation.belongsToServer(login, baseURL: base))
    #expect(!BrowserAuthentication.isTrustedAdminPage(login, server: server))
    let landed = URL(string: "https://admin.archive.example/admin/api/apitoken/")!
    #expect(BrowserAuthentication.isTrustedAdminPage(landed, server: server))
    for text in ["https://admin.archive.example.attacker.test/admin/", "http://admin.archive.example/admin/", "https://admin.archive.example:444/admin/", "https://snap-123.archive.example/admin/"] {
        #expect(!BrowserAuthentication.isTrustedAdminPage(URL(string: text)!, server: server))
    }
    #expect(URLComponents(url: login, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "/admin/api/apitoken/")
}
