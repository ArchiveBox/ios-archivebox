import SwiftUI

/// The same networking explanation is available on the server and every client.
public struct TailscaleGuide: View {
    public enum Role { case client, server }
    private enum Audience: String, CaseIterable { case tailnet = "My tailnet", lan = "My home network", internet = "The internet" }
    private let role: Role
    private let sharingAvailable: Bool
    private let prepareSettings: ((String, String) -> Void)?
    private let connect: ((URL) -> Void)?
    private let enableSharing: ((Bool) -> Void)?
    @State private var confirmPublic = false
    @Environment(\.dismiss) private var dismiss
    @State private var audience: Audience = .tailnet
    @State private var fullReplay = false
    @State private var serverInstructions = false
    @State private var discovery = false
    @State private var hostname = ""
    @State private var tailnetName = "my-mac.my-tailnet.ts.net"
    @State private var tailnetIP = "100.x.y.z"
    @State private var status = ""
    @State private var port = "5797"
    @State private var verifyURL = ""
    @State private var verification: String?
    @State private var verifying = false

    public init(role: Role, sharingAvailable: Bool = true, prepareSettings: ((String, String) -> Void)? = nil, enableSharing: ((Bool) -> Void)? = nil, connect: ((URL) -> Void)? = nil) {
        self.role = role; self.prepareSettings = prepareSettings; self.connect = connect; self.enableSharing = enableSharing
        self.sharingAvailable = sharingAvailable
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Label("Your archive, within reach", systemImage: "network.badge.shield.half.filled")
                        .font(.largeTitle.bold())
                    Text(role == .server ? "Choose who can reach this server. ArchiveBox accounts still control who can manage it." : "Connect your devices to the computer that keeps your archive. Tailscale makes a private network, called a tailnet, even when you’re away from home.")
                        .foregroundStyle(.secondary)
                    diagram
                    if role == .client { clientSteps }
                    if role == .server || serverInstructions { serverSteps }
                    if role == .client {
                        Button(serverInstructions ? "Hide server setup" : "I’m setting up the server too", systemImage: "desktopcomputer") {
                            serverInstructions.toggle()
                        }.accessibilityIdentifier("network.serverSteps")
                    }
                    DisclosureGroup("Connection troubleshooting") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Keep the server awake. For a private tailnet address, check that both devices show Connected in Tailscale and belong to the same tailnet (or that the server has been shared with you).")
                            Text("Use the server’s complete address, including http:// or https:// and any port. localhost always means the device you’re using. A 100.x address alone cannot provide wildcard subdomains.")
                            Text("If discovery finds nothing, allow Local Network access in system settings, check firewalls and Tailscale access rules, then paste the server address. Discovery cannot enumerate every custom domain or port.")
                            Text("For wildcard setups, test api., admin., web. and a snap-… name. Each must resolve to the server and use the same port and scheme. A certificate error usually means the certificate doesn’t cover that name.")
                        }.padding(.top, 8)
                    }
                    Link("Tailscale Serve documentation ↗", destination: URL(string: "https://tailscale.com/docs/reference/tailscale-cli/serve")!)
                    Link("Tailscale Funnel documentation ↗", destination: URL(string: "https://tailscale.com/docs/features/tailscale-funnel")!)
                }.frame(maxWidth: 640, alignment: .leading).padding(24).frame(maxWidth: .infinity)
            }
            .confirmationDialog("Make this archive reachable on the internet?", isPresented: $confirmPublic) {
                Button("Enable public access with Funnel", role: .destructive) { enableSharing?(true); dismiss() }
                    .disabled(!sharingAvailable)
            } message: {
                Text("Anyone can reach this address. ArchiveBox’s public index and public snapshots may be visible without signing in. Funnel does not add authentication. Review your archive visibility before continuing.")
            }
            .navigationTitle("Tailscale & network access")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $discovery) {
                ServerDiscoveryView { url in discovery = false; dismiss(); connect?(url) }
            }
            .task {
                #if os(macOS)
                do {
                    let network = try await TailscaleNetwork.read()
                    if let name = network.Self?.hostname { tailnetName = name }
                    if let ip = network.Self?.TailscaleIPs?.first { tailnetIP = ip }
                    status = "Tailscale connected on this Mac."
                } catch { status = error.localizedDescription }
                #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 700, minHeight: 640, idealHeight: 800)
        #endif
    }

    private var clientSteps: some View {
        VStack(alignment: .leading, spacing: 18) {
            step(1, "Join the server’s network", "For a private server, install Tailscale on this device, sign in to the server’s tailnet, and turn on the connection. Accept the VPN permission when asked. A public HTTPS server does not need Tailscale on your device.", icon: "person.2")
            tailscaleLinks
            Text("The Mac server app can connect directly at its Tailscale IP and port. An http:// address is fine here: Tailscale encrypts the connection. HTTPS is optional.").font(.subheadline).foregroundStyle(.secondary)
            step(2, "Find your archive", "Search nearby computers, or paste the address from ArchiveBox Server’s Connection settings. Stay connected to Tailscale when using a private tailnet address.", icon: "magnifyingglass")
            Button("Find ArchiveBox servers", systemImage: "network") { discovery = true }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("network.discover")
            step(3, "Sign in once", "Select your server, choose Get Key, and sign in to ArchiveBox. Create an API key and paste it into Connection Settings. Tailscale connects the devices; your ArchiveBox key gives you access to the archive.", icon: "key")
        }
    }

    private var serverSteps: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Who should be able to reach it?").font(.title2.bold())
            ForEach(Audience.allCases, id: \.self) { option in
                Button { audience = option; verification = nil } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: audience == option ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(audience == option ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.rawValue).font(.headline)
                            Text(audienceDescription(option)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.padding().background(.quaternary.opacity(audience == option ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain).accessibilityIdentifier("network.audience.\(option)")
            }
            if audience != .lan {
                Toggle("Full replay with isolated subdomains", isOn: $fullReplay)
                    .accessibilityIdentifier("network.fullReplay")
                Text(fullReplay ? "Use a domain you control and wildcard DNS so archived pages run on separate origins from your account. This takes more setup." : "The default direct tailnet connection needs no HTTPS setup. These advanced Serve/Funnel options add an HTTPS address. Without isolated subdomains, ArchiveBox keeps archived JavaScript disabled safely.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if audience != .lan {
                step(1, "Connect Tailscale on the server", "Install and open Tailscale on the computer running ArchiveBox. Sign in and confirm it says Connected. Keep that computer awake.", icon: "network")
                tailscaleLinks
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            if audience == .lan || fullReplay { wildcardSteps } else { simpleSteps }
            Divider()
            Text("Check it from another device").font(.headline)
            Text("Open the address on your phone or another computer. Try signing in, saving a link, and opening an archived page. For public access, also test with Tailscale off and Wi-Fi off. A test on the server itself doesn’t prove remote access.")
            TextField("Server address to check", text: $verifyURL, prompt: Text("https://your-server"))
                .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never).keyboardType(.URL)
                #endif
            Button(verifying ? "Checking…" : "Check ArchiveBox API from this device", systemImage: "checkmark.shield") {
                verifying = true; verification = nil
                Task {
                    defer { verifying = false }
                    do { verification = "ArchiveBox API found at \(try await ArchiveBoxClient().discoverServer(verifyURL)). Next, test sign-in and replay from another device." }
                    catch { verification = error.localizedDescription }
                }
            }.disabled(verifying || verifyURL.isEmpty)
            if let verification { Text(verification).font(.callout).textSelection(.enabled) }
        }
    }

    private var simpleSteps: some View {
        VStack(alignment: .leading, spacing: 16) {
            step(2, audience == .internet ? "Publish with Funnel" : "Share privately with Serve",
                 audience == .internet ? "Funnel makes this service reachable from the internet. Review ArchiveBox’s public index and snapshot visibility before publishing. It does not make the archive private or add a login requirement." : "Serve gives your server an HTTPS address reachable only by devices permitted on your tailnet. It handles the certificate for you.", icon: audience == .internet ? "globe" : "lock.shield")
            if let enableSharing {
                Text("ArchiveBox Server will run Tailscale, configure its own address and safe replay mode, restart if necessary, and verify HTTPS and the ArchiveBox API. Your existing accounts and archive files are kept.")
                Button(audience == .internet ? "Set up public access with Funnel" : "Connect my devices with Tailscale", systemImage: audience == .internet ? "globe" : "lock.shield") {
                    if audience == .internet { confirmPublic = true }
                    else { enableSharing(false); dismiss() }
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("network.automaticSharing")
                    .disabled(!sharingAvailable)
                Text("If Tailscale needs approval, we’ll show a link to its approval page. No Terminal commands or manual ArchiveBox configuration are needed.").font(.caption).foregroundStyle(.secondary)
            } else {
            Text("Run on the server computer in Terminal. If Tailscale gives you an approval link, open it and follow its instructions, then run the command again.")
            backendPort
            command("\(cli) \(audience == .internet ? "funnel" : "serve") --bg --https=443 http://127.0.0.1:\(port)")
            Text("Check existing services first with tailscale serve status. Serve and Funnel cannot share the same port; switching it changes who can reach that service.")
                .font(.caption).foregroundStyle(.secondary)
            step(3, "Tell ArchiveBox its new address", "Copy the HTTPS address printed by Tailscale. In the server’s HTTP, TLS, and DNS settings, use that BASE_URL and safe-onedomain-nojsreplay. Apply & Restart, then use that address in the client.", icon: "link")
            configuration(base: "https://\(tailnetName)", mode: "safe-onedomain-nojsreplay")
            }
            Text("Tailscale’s certificate covers the device’s .ts.net name only. Adding a wildcard CNAME to it does not add wildcard HTTPS or isolated replay.")
                .font(.subheadline).foregroundStyle(.secondary)
            DisclosureGroup("Turn this sharing off") {
                command("\(cli) \(audience == .internet ? "funnel" : "serve") --https=443 off")
                Text("This removes the listener on port 443. Restore ArchiveBox’s previous BASE_URL and mode if you return to local access.").font(.caption)
            }
        }
    }

    private var wildcardSteps: some View {
        VStack(alignment: .leading, spacing: 16) {
            step(audience == .lan ? 1 : 2, "Give your archive a domain", "Choose a base name, such as archive.example.com. DNS needs both that name and *.archive.example.com; the wildcard covers admin, API, web and individual archived pages.", icon: "textformat.abc")
            TextField("Your archive domain", text: $hostname, prompt: Text("archive.example.com"))
                .accessibilityIdentifier("network.wildcardDomain")
                .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never).keyboardType(.URL)
                #endif
            dnsDiagram
            if audience == .internet {
                Text("At your DNS provider, point the base and wildcard A records to your public proxy’s IP. Only add AAAA records if IPv6 reaches that proxy too. Forward HTTPS port 443 to it, or use a public server. A home connection behind CGNAT needs a tunnel or public proxy.")
                Text("Use a reverse proxy such as Caddy with your DNS provider’s DNS-01 plugin to obtain a certificate for BOTH the base name and wildcard. Keep DNS credentials on the server. Funnel’s built-in certificate cannot do this custom-domain job.")
                Link("Caddy wildcard HTTPS setup ↗", destination: URL(string: "https://caddyserver.com/docs/automatic-https#dns-challenge")!)
                Text("Example Caddyfile · replace the names and configure your DNS provider module:").font(.caption)
                command("""
                \(domain), *.\(domain) {
                    tls {
                        dns YOUR_DNS_PROVIDER
                    }
                    reverse_proxy 127.0.0.1:\(port)
                }
                """)
            } else {
                Text(audience == .tailnet ? "Point both DNS records to the server’s Tailscale IPv4 address (\(tailnetIP)). Use your own DNS provider, or a private DNS server with a Tailscale split-DNS rule. MagicDNS alone cannot create these wildcard records." : "Use your router or local DNS server to point both names to the server’s fixed LAN address. For a home-only name, archive.home.arpa is suitable. All client devices must use that DNS server; Bonjour .local names do not provide wildcard DNS.")
                if audience == .tailnet {
                    Link("Tailscale DNS settings ↗", destination: URL(string: "https://login.tailscale.com/admin/dns")!)
                    Text("Forward HTTP on the tailnet, preserving the requested hostname:")
                    command("\(cli) serve --bg --tcp=18081 tcp://127.0.0.1:\(port)")
                    Text("Use port 18081 in every ArchiveBox address. Tailscale encrypts this HTTP traffic between peers. To stop: tailscale serve --tcp=18081 off.").font(.caption)
                } else {
                    Text("The Mac companion listens only on 127.0.0.1. Run a reverse proxy bound to your LAN address; keep router port forwarding off. For example, install Caddy, replace 192.168.1.10 with the server’s fixed LAN IP, and run this Caddyfile:")
                    command("""
                    http://\(domain):18081, http://*.\(domain):18081 {
                        bind 192.168.1.10
                        reverse_proxy 127.0.0.1:\(port)
                    }
                    """)
                    Link("Install Caddy ↗", destination: URL(string: "https://caddyserver.com/docs/install")!)
                    Text("HTTP on a LAN is not encrypted: use it only on a network you trust. HTTPS with a certificate for your own domain is also an option.").font(.caption)
                }
            }
            backendPort
            step(audience == .lan ? 2 : 3, "Keep replay on separate subdomains", "Set the base address below in ArchiveBox’s HTTP, TLS, and DNS settings. Choose safe-subdomains-fullreplay, then Apply & Restart. Keep the original Host header in the proxy; don’t rewrite every request to one host.", icon: "square.stack.3d.up")
            configuration(base: "\(audience == .internet ? "https" : "http")://\(domain)\(audience == .internet ? "" : ":18081")", mode: "safe-subdomains-fullreplay")
            Text("For LAN and tailnet access with the same names, use split DNS: LAN clients resolve to the LAN proxy, tailnet clients to the tailnet proxy. Both proxies must accept the same port.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var domain: String { hostname.isEmpty ? "archive.example.com" : hostname.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cli: String {
        #if os(macOS)
        if let executable = TailscaleNetwork.executable { return "\"\(executable.path)\"" }
        #endif
        return "tailscale"
    }
    private var backendPort: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Local ArchiveBox port", text: $port).textFieldStyle(.roundedBorder)
            Text("5797 for ArchiveBox Server.app, Docker, or Python. Commands run on the server computer. On a Mac, if tailscale isn’t in PATH, use /Applications/Tailscale.app/Contents/MacOS/Tailscale.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var tailscaleLinks: some View {
        ViewThatFits(in: .horizontal) {
            HStack { Link("Install Tailscale ↗", destination: URL(string: "https://tailscale.com/download")!); Spacer(); openTailscale }
            VStack(alignment: .leading) { Link("Install Tailscale ↗", destination: URL(string: "https://tailscale.com/download")!); openTailscale }
        }
    }
    private var openTailscale: some View {
        Link("Open Tailscale", destination: URL(string: "tailscale://")!)
    }
    private func audienceDescription(_ value: Audience) -> String {
        switch value {
        case .tailnet: "Private access at home or away. Install Tailscale on each device."
        case .lan: "Devices on the same trusted home network. No Tailscale required."
        case .internet: "Reachable worldwide. HTTPS and a review of public archive visibility."
        }
    }
    private func step(_ number: Int, _ title: String, _ text: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(number). \(title)", systemImage: icon).font(.headline)
            Text(text).foregroundStyle(.secondary)
        }
    }
    private func command(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Button("Copy", systemImage: "doc.on.doc") {
                #if os(macOS)
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                #else
                UIPasteboard.general.string = text
                #endif
            }.buttonStyle(.borderless)
        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
    private func configuration(base: String, mode: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            command("BASE_URL=\(base)\nSERVER_SECURITY_MODE=\(mode)")
            if let prepareSettings {
                Button("Review these settings in the server app", systemImage: "slider.horizontal.3") {
                    prepareSettings(base, mode); dismiss()
                }.disabled((audience == .lan || fullReplay) && (hostname.isEmpty || (try? ServerAddress.normalize(base)) == nil))
                Text("Fills the settings for review. Apply & Restart saves them; DNS and proxies must be configured separately.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("For Docker/Python, run archivebox config --set with these values in your collection, then restart your server.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var diagram: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { node("Your devices", "iphone.and.arrow.forward", .blue); Image(systemName: "arrow.right"); node("Private network", "lock.shield", .teal); Image(systemName: "arrow.right"); node("Your archive", "externaldrive.fill", .orange) }
            VStack(spacing: 12) { node("Your devices", "iphone.and.arrow.forward", .blue); Image(systemName: "arrow.down"); node("Private network", "lock.shield", .teal); Image(systemName: "arrow.down"); node("Your archive", "externaldrive.fill", .orange) }
        }.frame(maxWidth: .infinity).padding().background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))
    }
    private func node(_ title: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 8) { Image(systemName: icon).font(.largeTitle).foregroundStyle(color); Text(title).font(.caption.bold()) }
    }
    private var dnsDiagram: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(domain, systemImage: "house").foregroundStyle(.primary)
            Label("admin. · api. · web.", systemImage: "person.badge.shield.checkmark").foregroundStyle(.blue)
            Label("snap-….\(domain)", systemImage: "doc.richtext").foregroundStyle(.orange)
            Text("One server · separate origins for your account and archived pages").font(.caption).foregroundStyle(.secondary)
        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

public struct ServerDiscoveryView: View {
    @State private var model = ServerDiscovery()
    @State private var extraHosts = ""
    @Environment(\.dismiss) private var dismiss
    private let select: (URL) -> Void
    public init(select: @escaping (URL) -> Void) { self.select = select }
    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Find your archive", systemImage: "network").font(.title2.bold())
                    Text("Search this device, nearby computers and available Tailscale devices. We check the ArchiveBox API without sending your API key.")
                    HStack {
                        Button(model.running ? "Stop search" : "Search again", systemImage: model.running ? "stop.circle" : "arrow.clockwise") {
                            if model.running { model.stop() } else { model.start(extraHosts: extraHosts) }
                        }.accessibilityIdentifier("discovery.search")
                        if model.running { ProgressView().controlSize(.small) }
                    }
                    Text("\(model.completed) of \(model.total) addresses checked · \(model.results.count) found").font(.caption).accessibilityIdentifier("discovery.progress")
                }
                Section("ArchiveBox servers") {
                    ForEach(model.results) { found in
                        Button { model.stop(); select(found.url); dismiss() } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Label(found.url.absoluteString, systemImage: "externaldrive.badge.checkmark").foregroundStyle(.primary)
                                Text(found.source).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }.accessibilityIdentifier("discovery.result")
                    }
                    if model.results.isEmpty { Text(model.running ? "Looking for servers…" : "No servers found. Enter an address below, or check the network guide.").foregroundStyle(.secondary) }
                }
                Section("Check specific devices or addresses") {
                    TextField("Names, URLs, or Tailscale status JSON", text: $extraHosts, axis: .vertical)
                        .lineLimit(3...6).autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .accessibilityIdentifier("discovery.hosts")
                    Text("Copy device DNS names from Tailscale (one per line), or paste tailscale status --json from a Mac. Include the full URL for a custom domain or port. Your list stays on this device and is not saved.").font(.caption)
                    Button("Search these and nearby devices") { model.start(extraHosts: extraHosts) }
                }
                Section("Search coverage") {
                    ForEach(model.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Find a server")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { model.start() }.onDisappear { model.stop() }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 650, minHeight: 560)
        #endif
    }
}
