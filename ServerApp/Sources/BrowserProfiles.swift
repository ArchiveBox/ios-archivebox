import ArchiveBoxCore
import CommonCrypto
import CryptoKit
import Foundation
import Security
import SQLite3

// Decrypt on macOS, where the browser's Keychain item lives. Only portable
// cookies/settings cross into Linux; no browser password is saved or logged.
struct HostBrowserProfile {
    let browser: String
    let label: String
    let keychainAccount: String
    let root: URL
    let directory: String
    var name: String { "\(label) - \(directory)" }
    var identifier: String { "\(browser)/\(directory)" }

    static func discover() throws -> [Self] {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let browsers = [
            ("chrome", "Google Chrome", "Chrome", "Google/Chrome"),
            ("chrome-beta", "Google Chrome Beta", "Chrome", "Google/Chrome Beta"),
            ("chromium", "Chromium", "Chromium", "Chromium"),
            ("brave", "Brave", "Brave", "BraveSoftware/Brave-Browser"),
        ]
        return try browsers.flatMap { browser, label, account, path -> [Self] in
            let root = support.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: root.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(atPath: root.path).sorted().compactMap { directory in
                guard directory == "Default" || directory.hasPrefix("Profile ") || directory.hasPrefix("Guest Profile") else { return nil }
                let values = try root.appendingPathComponent(directory).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
                return Self(browser: browser, label: label, keychainAccount: account, root: root, directory: directory)
            }
        }
    }

    func export(to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let profile = destination.appendingPathComponent("chrome_profile/Default")
        try fm.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Browser caches, extensions, saved passwords and history are not needed
        // for a persona. Copy preferences and portable cookies, never the live DB.
        for file in ["Preferences", "Secure Preferences"] {
            let source = root.appendingPathComponent(directory + "/" + file)
            if fm.fileExists(atPath: source.path) {
                try Data(contentsOf: source).write(to: profile.appendingPathComponent(file), options: .atomic)
            }
        }
        let stateFile = root.appendingPathComponent("Local State")
        if fm.fileExists(atPath: stateFile.path),
           var state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateFile)) as? [String: Any] {
            let info = ((state["profile"] as? [String: Any])?["info_cache"] as? [String: Any])?[directory]
            state["profile"] = ["last_used": "Default", "last_active_profiles": ["Default"], "info_cache": info.map { ["Default": $0] } ?? [:]]
            try JSONSerialization.data(withJSONObject: state).write(to: destination.appendingPathComponent("chrome_profile/Local State"), options: .atomic)
        }
        let cookies = try readCookies()
        let auth: [String: Any] = ["TYPE": "auth", "cookies": cookies, "localStorage": [:], "sessionStorage": [:]]
        try JSONSerialization.data(withJSONObject: auth).write(to: destination.appendingPathComponent("auth.json"), options: .atomic)
        var lines = ["# Netscape HTTP Cookie File"]
        for cookie in cookies {
            let domain = cookie["domain"] as! String
            let fields = [
                ((cookie["httpOnly"] as? Bool == true) ? "#HttpOnly_" : "") + domain,
                domain.hasPrefix(".") ? "TRUE" : "FALSE", cookie["path"] as! String,
                cookie["secure"] as? Bool == true ? "TRUE" : "FALSE",
                String(cookie["expires"] as? Int64 ?? 0), cookie["name"] as! String, cookie["value"] as! String,
            ]
            guard !fields.contains(where: { $0.contains("\n") || $0.contains("\r") || $0.contains("\t") }) else {
                throw ArchiveBoxError.message("\(name) contains a cookie that cannot be exported as a Netscape cookie file.")
            }
            lines.append(fields.joined(separator: "\t"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: destination.appendingPathComponent("cookies.txt"), atomically: true, encoding: .utf8)
        for file in ["auth.json", "cookies.txt"] {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.appendingPathComponent(file).path)
        }
    }

    private func key() throws -> [UInt8] {
        var result: CFTypeRef?
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainAccount + " Safe Storage", kSecAttrAccount: keychainAccount,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let password = result as? Data else {
            throw ArchiveBoxError.message("Allow ArchiveBox Server to read \(keychainAccount) Safe Storage in your macOS Keychain to import \(name). \(SecCopyErrorMessageString(status, nil) as String? ?? "Keychain access failed")")
        }
        var derived = [UInt8](repeating: 0, count: 16)
        let salt = Array("saltysalt".utf8)
        let statusKDF = password.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes.bindMemory(to: Int8.self).baseAddress, password.count,
                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &derived, derived.count)
        }
        guard statusKDF == kCCSuccess else { throw ArchiveBoxError.message("Could not derive the cookie key for \(name).") }
        return derived
    }

    private func decrypt(_ encrypted: Data, key: [UInt8], domain: String, version: Int) throws -> String {
        guard encrypted.starts(with: Data("v10".utf8)) else {
            throw ArchiveBoxError.message("Unsupported cookie encryption in \(name). Use the ArchiveBox browser extension to sync this profile.")
        }
        let ciphertext = Array(encrypted.dropFirst(3))
        var plaintext = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var count = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
            key, key.count, [UInt8](repeating: 32, count: 16), ciphertext, ciphertext.count, &plaintext, plaintext.count, &count)
        guard status == kCCSuccess else { throw ArchiveBoxError.message("Could not decrypt cookies for \(name). The Keychain item does not match this profile.") }
        var bytes = Data(plaintext.prefix(count))
        if version >= 24 {
            guard bytes.starts(with: Data(SHA256.hash(data: Data(domain.utf8)))) else {
                throw ArchiveBoxError.message("Cookie integrity check failed for \(name).")
            }
            bytes = bytes.dropFirst(32)
        }
        guard let value = String(data: bytes, encoding: .utf8) else { throw ArchiveBoxError.message("Invalid cookie text in \(name).") }
        return value
    }

    private func readCookies() throws -> [[String: Any]] {
        let paths = ["Network/Cookies", "Cookies"].map { root.appendingPathComponent(directory + "/" + $0) }
        guard let file = paths.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw ArchiveBoxError.message("Could not read the cookie database for \(name).")
        }
        defer { sqlite3_close(db) }
        // One read transaction includes committed WAL data without changing the
        // source or requiring the user's browser to close.
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw ArchiveBoxError.message("Could not read \(name).") }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        func prepare(_ sql: String) throws -> OpaquePointer {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw ArchiveBoxError.message("Unsupported cookie database in \(name).")
            }
            return statement
        }
        let metadata = try prepare("SELECT value FROM meta WHERE key='version'")
        let version = sqlite3_step(metadata) == SQLITE_ROW ? Int(sqlite3_column_int(metadata, 0)) : 0
        sqlite3_finalize(metadata)
        let columns = try prepare("PRAGMA table_info(cookies)")
        var names = Set<String>()
        while sqlite3_step(columns) == SQLITE_ROW { names.insert(String(cString: sqlite3_column_text(columns, 1))) }
        sqlite3_finalize(columns)
        let partition = names.contains("top_frame_site_key") ? "top_frame_site_key" : "''"
        let ancestor = names.contains("has_cross_site_ancestor") ? "has_cross_site_ancestor" : "0"
        let statement = try prepare("SELECT host_key, path, name, value, encrypted_value, expires_utc, is_secure, is_httponly, samesite, \(partition), \(ancestor) FROM cookies")
        defer { sqlite3_finalize(statement) }
        func string(_ index: Int32) -> String { sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "" }
        var cookies = [[String: Any]]()
        var encryptionKey: [UInt8]?
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            let expires = sqlite3_column_int64(statement, 5)
            let unixExpiry = expires / 1_000_000 - 11_644_473_600
            if expires == 0 || unixExpiry > Int64(Date().timeIntervalSince1970) {
                let domain = string(0)
                var value = string(3)
                if value.isEmpty, let pointer = sqlite3_column_blob(statement, 4), sqlite3_column_bytes(statement, 4) > 0 {
                    if encryptionKey == nil { encryptionKey = try key() }
                    value = try decrypt(Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 4))), key: encryptionKey!, domain: domain, version: version)
                }
                var cookie: [String: Any] = ["domain": domain, "path": string(1), "name": string(2), "value": value,
                    "secure": sqlite3_column_int(statement, 6) != 0, "httpOnly": sqlite3_column_int(statement, 7) != 0]
                if expires != 0 { cookie["expires"] = unixExpiry }
                if let sameSite = [0: "None", 1: "Lax", 2: "Strict"][Int(sqlite3_column_int(statement, 8))] { cookie["sameSite"] = sameSite }
                if !string(9).isEmpty { cookie["partitionKey"] = ["topLevelSite": string(9), "hasCrossSiteAncestor": sqlite3_column_int(statement, 10) != 0] }
                cookies.append(cookie)
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw ArchiveBoxError.message("Could not finish reading cookies for \(name).") }
        return cookies
    }
}

extension Runtime {
    // The server owns all collection DB writes. macOS only creates portable input
    // files: opening a live virtiofs SQLite database on both OSes breaks locking.
    func seedBrowserPersonas(progress: @Sendable (String) -> Void = { _ in }) throws {
        let fm = FileManager.default
        let marker = collectionDirectory.appendingPathComponent(".host-browser-personas.json")
        // Keep completed entries even when their Persona row is deleted or
        // renamed. Reconciling this ledger against live rows would undo deletion.
        var imported = fm.fileExists(atPath: marker.path)
            ? try JSONDecoder().decode([String: String].self, from: Data(contentsOf: marker)) : [:]
        let output = try command(["exec", "--workdir", "/data", name, "/app/bin/docker_entrypoint.sh", "archivebox", "persona", "list"], logOutput: false)
        var existing = Set(output.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["name"] as? String
        })
        var failures = [String]()
        for profile in try HostBrowserProfile.discover() where imported[profile.identifier] == nil {
            do {
                progress("Importing \(profile.name)… Allow browser access if macOS asks.")
                var personaName = profile.name
                var suffix = 2
                while existing.contains(personaName) { personaName = "\(profile.name) (\(suffix))"; suffix += 1 }
                let staging = collectionDirectory.appendingPathComponent(".browser-import-" + UUID().uuidString)
                defer { try? fm.removeItem(at: staging) }
                try profile.export(to: staging)
                let exports = collectionDirectory.appendingPathComponent(".host-browser-profiles")
                try fm.createDirectory(at: exports, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let exported = exports.appendingPathComponent(profile.name)
                // An interrupted attempt can have an export but no completed seed.
                if fm.fileExists(atPath: exported.path) { try fm.removeItem(at: exported) }
                try fm.moveItem(at: staging, to: exported)
                _ = try command(["exec", "--workdir", "/data", name, "/app/bin/docker_entrypoint.sh", "archivebox", "persona", "create",
                    "--permissions=private", "--import=/data/.host-browser-profiles/" + profile.name, personaName])
                imported[profile.identifier] = personaName
                existing.insert(personaName)
                try JSONEncoder().encode(imported).write(to: marker, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            } catch {
                failures.append("\(profile.name): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            throw ArchiveBoxError.message("Some profiles could not be imported. Other profiles were saved successfully.\n" + failures.joined(separator: "\n"))
        }
    }
}
