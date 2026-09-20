import Foundation
import Testing
@testable import ArchiveBoxCore

@Test func webLoginOnlyTrustsTheConfiguredAdminOrigin() {
    let server = URL(string: "https://api.archive.example:8443")!
    for address in ["https://api.archive.example:8443/admin/", "https://admin.archive.example:8443/admin/api/apitoken/"] {
        #expect(BrowserAuthentication.isTrustedAdminPage(URL(string: address)!, server: server))
    }
    for address in [
        "http://admin.archive.example:8443/admin/", "https://admin.archive.example/admin/",
        "https://admin.archive.example:9443/admin/", "https://archive.example.attacker.test:8443/admin/",
        "https://snapshot.admin.archive.example:8443/admin/", "https://web.archive.example:8443/admin/",
        "https://snapshot.archive.example:8443/admin/", "https://admin.archive.example:8443/archive/page.html",
        "https://admin.archive.example:8443/admin/login/", "https://admin.archive.example:8443/admin/logout/",
        "https://user:password@admin.archive.example:8443/admin/", "file:///admin/",
    ] {
        #expect(!BrowserAuthentication.isTrustedAdminPage(URL(string: address)!, server: server))
    }
    for host in ["127.0.0.1", "[::1]", "archive.example"] {
        let origin = URL(string: "http://\(host):5797")!
        #expect(BrowserAuthentication.isTrustedAdminPage(origin.appending(path: "admin/"), server: origin))
        #expect(!BrowserAuthentication.isTrustedAdminPage(URL(string: "http://other.example:5797/admin/")!, server: origin))
    }
}
