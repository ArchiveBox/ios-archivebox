import Foundation
import Darwin
import Observation

@MainActor @Observable
public final class ServerDiscovery: NSObject {
    public struct Found: Identifiable, Sendable {
        public let url: URL
        public let source: String
        public var id: String { url.absoluteString }
    }
    public private(set) var results: [Found] = []
    public private(set) var running = false
    public private(set) var completed = 0
    public private(set) var total = 0
    public private(set) var notes: [String] = []
    private var search: Task<Void, Never>?
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var resolving: [Task<Void, Never>] = []
    private let client = ArchiveBoxClient(discoveryTimeout: 2)

    public func stop() {
        search?.cancel(); search = nil
        browser?.stop(); browser = nil
        services.forEach { $0.stop() }; services = []
        resolving.forEach { $0.cancel() }; resolving = []
        running = false
    }

    public func start(extraHosts: String = "") {
        stop(); results = []; completed = 0; total = 0; notes = []; running = true
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.schedule(in: .main, forMode: .common)
        self.browser = browser
        browser.searchForServices(ofType: "_archivebox._tcp.", inDomain: "local.")
        search = Task { [self] in
            var candidates: [(String, String)] = [
                (ServerAddress.localAPI.absoluteString, "This device"),
                ("http://127.0.0.1:5797", "This device")
            ]
            let lan = Self.lanHosts()
            notes.append(lan.note)
            #if !os(macOS)
            notes.append("iOS cannot read Tailscale’s device list. Nearby Bonjour services are checked; for devices elsewhere, paste names or a status JSON from Tailscale below. Bonjour does not cross the tailnet.")
            #endif
            if let network = try? JSONDecoder().decode(TailscaleNetwork.self, from: Data(extraHosts.utf8)) {
                for device in network.devices.prefix(128) {
                    for host in (device.TailscaleIPs ?? []) + [device.hostname].compactMap({ $0 }) {
                        candidates += Self.addresses(host: host, source: "Imported Tailscale device")
                    }
                }
            } else {
                for host in extraHosts.split(whereSeparator: { $0.isWhitespace || $0 == "," }).prefix(128) {
                    if host.contains("://") || host.contains(":") {
                        if let url = try? ServerAddress.normalize(String(host)) { candidates.append((url.absoluteString, "Entered address")) }
                    } else { candidates += Self.addresses(host: String(host), source: "Entered device") }
                }
            }
            // Check the default port across the LAN before less common ports.
            let lanCandidates = lan.hosts.map { Self.addresses(host: $0, source: "Local network") }
            for port in 0..<5 { candidates += lanCandidates.compactMap { $0.indices.contains(port) ? $0[port] : nil } }
            guard !Task.isCancelled else { return }
            // Localhost and Bonjour must not wait for the Tailscale CLI.
            async let nearby: Void = probe(candidates)
            #if os(macOS)
            do {
                let network = try await TailscaleNetwork.read()
                try Task.checkCancellation()
                let devices = network.devices.filter { $0.Online != false }.prefix(128)
                notes.append("Checking \(devices.count) connected Tailscale devices. Tailnet rules still control access.")
                var tailnet: [(String, String)] = []
                for device in devices {
                    for host in (device.TailscaleIPs ?? []) + [device.hostname].compactMap({ $0 }) {
                        tailnet += Self.addresses(host: host, source: "Tailscale")
                    }
                }
                await probe(tailnet)
            } catch { if !Task.isCancelled { notes.append(error.localizedDescription) } }
            #endif
            await nearby
            guard !Task.isCancelled else { return }
            // Continue listening for Bonjour until the view leaves, including
            // servers started later and permission granted during the search.
            running = false
        }
    }

    private func probe(_ addresses: [(String, String)]) async {
        guard !Task.isCancelled else { return }
        var seen = Set<String>()
        let candidates = addresses.filter { seen.insert($0.0).inserted }
        total += candidates.count
        // Each scan has a fixed worker window; cancellation closes its requests.
        await withTaskGroup(of: Found?.self) { group in
            var next = 0
            func enqueue() {
                guard next < candidates.count, !Task.isCancelled else { return }
                let (address, source) = candidates[next]; next += 1
                group.addTask { [client] in
                    guard let url = try? await client.discoverServer(address), !Task.isCancelled else { return nil }
                    return Found(url: url, source: source)
                }
            }
            for _ in 0..<32 { enqueue() }
            while let found = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); return }
                completed += 1
                if let found { add(found) }
                enqueue()
            }
        }
    }

    private func add(_ result: Found) {
        if let index = results.firstIndex(where: { $0.id == result.id }) {
            // Keep the advertised server name even if a port probe won the race.
            if result.source.hasPrefix("Bonjour") { results[index] = result }
            return
        }
        results.append(result)
        results.sort { $0.url.absoluteString < $1.url.absoluteString }
    }

    private static func addresses(host: String, source: String) -> [(String, String)] {
        let host = host.contains(":") ? "[\(host)]" : host
        return ["http://\(host):5797", "http://\(host):18081", "https://\(host)", "http://\(host)"]
            .filter { (try? ServerAddress.normalize($0)) != nil }.map { ($0, source) }
    }

    private static func lanHosts() -> (hosts: [String], note: String) {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return ([], "Local network interfaces are unavailable.") }
        defer { freeifaddrs(interfaces) }
        var current = interfaces
        var addresses = Set<UInt32>()
        var limited = false
        while let item = current {
            defer { current = item.pointee.ifa_next }
            let entry = item.pointee
            guard let address = entry.ifa_addr, let mask = entry.ifa_netmask,
                  address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0,
                  String(cString: entry.ifa_name).hasPrefix("en") else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            guard ip >> 24 == 10 || ip >> 20 == 0xac1 || ip >> 16 == 0xc0a8 else { continue }
            let scanMask = max(netmask, 0xffffff00)
            limited = limited || netmask < scanMask
            let start = ip & scanMask, end = start | ~scanMask
            if end > start + 1 {
                for address in (start + 1)..<end { addresses.insert(address) }
            }
        }
        let hosts = addresses.sorted().prefix(512).map { ip in
            [24, 16, 8, 0].map { String((ip >> $0) & 255) }.joined(separator: ".")
        }
        return (hosts, "Checking Bonjour and \(hosts.count) nearby IPv4 addresses on ports 80, 443, 5797 and 18081. " +
                (limited || addresses.count > 512 ? "Large networks are limited to nearby /24 ranges (512 addresses maximum). " : "") +
                "Custom ports, IPv6-only services without Bonjour, and servers requiring a custom DNS name may need their address entered below.")
    }
}

extension ServerDiscovery: @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard self.browser === browser else { return }
        services.append(service); service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 4)
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard self.browser === browser else { return }
        notes.append("Bonjour is unavailable. Allow Local Network access for ArchiveBox in system settings, then try again.")
    }
    public func netServiceDidResolveAddress(_ sender: NetService) {
        guard browser != nil, services.contains(sender) else { return }
        let data = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        let advertised = data["url"].flatMap { String(data: $0, encoding: .utf8) }
        var addresses = [advertised].compactMap { $0 }
        // Preserve the advertised scheme/port for HTTPS; never downgrade it.
        let scheme = advertised.flatMap(URL.init(string:))?.scheme ?? "http"
        if let host = sender.hostName { addresses.append("\(scheme)://\(host):\(sender.port)") }
        for data in sender.addresses ?? [] {
            let host: String? = data.withUnsafeBytes { bytes in
                guard let address = bytes.baseAddress?.assumingMemoryBound(to: sockaddr.self),
                      bytes.count >= MemoryLayout<sockaddr>.size else { return nil }
                var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, socklen_t(bytes.count), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            if let host {
                let escaped = host.replacingOccurrences(of: "%", with: "%25")
                addresses.append("\(scheme)://\(host.contains(":") ? "[\(escaped)]" : escaped):\(sender.port)")
            }
        }
        let candidates = addresses
        let source = "Bonjour · \(sender.name)"
        resolving.append(Task { [client] in
            for address in candidates {
                guard !Task.isCancelled else { return }
                if let verified = try? await client.discoverServer(address), !Task.isCancelled {
                    add(Found(url: verified, source: source))
                    return
                }
            }
        })
    }
}

/// Advertise each enabled route; mDNS is local-link only, including tailnet URLs.
@MainActor
public final class ArchiveBoxBonjour: NSObject, @preconcurrency NetServiceDelegate {
    private var services: [NetService] = []
    private var advertised: [URL] = []
    public override init() { super.init() }
    public func publish(_ url: URL) { publish([url]) }
    public func publish(_ urls: [URL]) {
        let urls = urls.filter { url in
            guard let host = url.host() else { return false }
            return host != "localhost" && host != "127.0.0.1" && host != "::1" && !host.hasSuffix(".localhost")
        }
        guard advertised != urls else { return }
        services.forEach { $0.stop() }; services = []; advertised = urls
        for url in urls {
            let label = url.host()?.hasPrefix("100.") == true || url.host()?.hasSuffix(".ts.net") == true ? "Tailscale" : "Network"
            let service = NetService(domain: "local.", type: "_archivebox._tcp.", name: "ArchiveBox (\(label))", port: Int32(url.port ?? (url.scheme == "https" ? 443 : 80)))
            service.delegate = self
            service.setTXTRecord(NetService.data(fromTXTRecord: ["url": Data(url.absoluteString.utf8)]))
            service.schedule(in: .main, forMode: .common)
            service.publish(); services.append(service)
        }
    }
    public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        NSLog("ArchiveBox Bonjour registration failed: %@", errorDict)
        advertised = [] // A later refresh may publish after permissions change.
    }
}
