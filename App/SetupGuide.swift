import SwiftUI
import ArchiveBoxCore

/// Shared, optional introduction. Installation stays with the existing companion
/// flow or the server's published instructions; this view never changes credentials.
struct SetupGuide: View {
    let connect: () -> Void
    let chooseServer: (URL) -> Void
    @State private var networkGuide = false
    @State private var discovery = false
    let useMac: () -> Void
    @State private var page: Page = .welcome

    private enum Page { case welcome, choices, mac, hosting, docker, python }
    private let quickstart = URL(string: "https://github.com/ArchiveBox/ArchiveBox#quickstart")!

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        switch page {
                        case .welcome: welcome
                        case .choices: choices
                        case .mac: mac
                        case .hosting: hosting
                        case .docker: docker
                        case .python: python
                        }
                    }
                    .frame(maxWidth: 620, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
                .id(page) // Each guide opens at the top, including after Back.
                .accessibilityIdentifier("setup.content")
                Divider()
                VStack(spacing: 8) {
                    if page == .welcome {
                        Button("Choose where to keep my archive") { page = .choices }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("setup.choose")
                    } else if page != .choices {
                        Button("My server is ready — connect") { connect() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("setup.connect")
                    }
                    if page == .welcome || page == .choices {
                        Button("I already have a server") { connect() }
                            .accessibilityIdentifier("setup.skip")
                    }
                    Text("Skip the guide · You can reopen it in Connection Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .controlSize(.large)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.background)
            }
            .navigationTitle("Get started")
            .sheet(isPresented: $networkGuide) { TailscaleGuide(role: .client, connect: chooseServer) }
            .sheet(isPresented: $discovery) { ServerDiscoveryView(select: chooseServer) }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if page != .welcome {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Back", systemImage: "chevron.left") {
                            page = page == .choices ? .welcome : .choices
                        }
                        .accessibilityIdentifier("setup.back")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    private var welcome: some View {
        Group {
            Image("BrandLogo")
                .resizable().scaledToFit().frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityHidden(true)
            heading("Keep the web that matters to you.",
                    "ArchiveBox saves copies of web pages so you can revisit them after the originals change or disappear.")
            Text("Your archive needs a home. A **server** is the computer that saves and stores your pages. It can be your Mac, another computer you manage, or a paid hosting service.")
            archiveDiagram
            Button("Find my family’s archive", systemImage: "network") { discovery = true }
                .buttonStyle(.bordered).accessibilityIdentifier("setup.discover")
            Text("This app connects to your server to save links and browse your archive from your devices. You choose where the files live and who can access them.")
                .foregroundStyle(.secondary)
        }
    }

    private var choices: some View {
        Group {
            heading("Choose a home for your archive",
                    "ArchiveBox is free and open source. You can use a computer you own or pay a company to host it.")
            #if os(iOS)
            choice("Use a Mac", subtitle: "Keep the files on a Mac you own. Connecting this device also needs network setup.",
                   icon: "desktopcomputer", page: .mac, id: "mac")
            #else
            choice("Use a Mac", subtitle: "Keep the files on your Mac. Set up with the server app, without terminal commands.",
                   icon: "desktopcomputer", page: .mac, id: "mac")
            #endif
            choice("Use a hosting service", subtitle: "Keep your archive online without leaving a computer on at home. Paid separately.",
                   icon: "cloud", page: .hosting, id: "hosting")
            Text("Install it yourself").font(.headline)
            choice("Docker Compose", subtitle: "For a computer, NAS, or cloud server you manage. Includes archiving tools.",
                   icon: "shippingbox", page: .docker, id: "docker")
            choice("Python / uv / pip", subtitle: "For terminal users who want to manage the installation and dependencies.",
                   icon: "terminal", page: .python, id: "python")
            Text("Someone setting this up for you? Ask them for your ArchiveBox server address and an API key, then choose “I already have a server”.")
                .foregroundStyle(.secondary)
        }
    }

    private var mac: some View {
        Group {
            heading("Keep your archive on a Mac",
                    "ArchiveBox Server.app does the saving and stores the files. ArchiveBox.app is how you use the archive.")
            Text("Requires an Apple Silicon Mac with macOS 26 or later. No Docker or terminal setup needed.")
                .font(.subheadline).foregroundStyle(.secondary)
            detail("1. Install the server app", icon: "arrow.down.app",
                   "On the Mac that will store your archive, download ArchiveBox Server.app, move it to Applications, and open it.")
            detail("2. Create your account", icon: "person.crop.circle",
                   "Open the server’s Settings from its menu-bar icon and create an administrator account.")
            detail("3. Connect this app", icon: "link",
                   "Return to Connection Settings. Connect to the server, choose Get Key, and paste the API key here. The key lets this app access your archive.")
            #if os(macOS)
            Button("Set up on this Mac", systemImage: "desktopcomputer") { useMac() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .accessibilityIdentifier("setup.local")
            Text("This opens Run Server Locally in Connection Settings, where you can download or start the companion.")
                .font(.caption).foregroundStyle(.secondary)
            #else
            ShareLink("Send the Mac setup guide", item: URL(string: "https://app.archivebox.io/#your-server-your-choice")!)
            Text("iPhone and iPad connect to a server; they don’t run one. Open the guide on your Mac to install the companion.")
                .foregroundStyle(.secondary)
            #endif
            detail("Using an iPhone, iPad, or another Mac?", icon: "network",
                   "In ArchiveBox Server’s Settings, choose Connect my devices. Then keep Tailscale connected on your iPhone and choose Find a server here. On the same Wi-Fi, the server’s private address appears automatically. You can also scan the code shown on the Mac.")
            Button("Find my server", systemImage: "magnifyingglass") { discovery = true }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("setup.findMac")
            networkAdvice
            Link("Mac server setup guide", destination: URL(string: "https://app.archivebox.io/#your-server-your-choice")!)
        }
    }

    private var hosting: some View {
        Group {
            heading("Let a hosting service run it",
                    "Your archive lives on the provider’s computers, so your home computer can be off. You pay the provider for hosting and storage.")
            detail("1. Choose a provider", icon: "cloud",
                   "Look for an ArchiveBox installation with support for version 0.9 or later and API keys, which this app requires. Confirm compatibility before paying.")
            VStack(alignment: .leading, spacing: 16) {
                Text("Providers listed in the ArchiveBox README").font(.headline)
                Link("Elestio ↗", destination: URL(string: "https://elest.io/open-source/archivebox")!)
                Link("PikaPods ↗", destination: URL(string: "https://www.pikapods.com/pods?run=archivebox")!)
                Link("Stellar Hosted ↗", destination: URL(string: "https://www.stellarhosted.com/archivebox/")!)
                Text("Compare current prices, storage, backups, and help with setup on their sites. These are independent services; hosting is separate from this free app.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            detail("2. Set up ArchiveBox with them", icon: "person.crop.circle",
                   "Follow the provider’s setup instructions and sign in to your new ArchiveBox website. Keep its web address and your account details.")
            detail("3. Come back and connect", icon: "link",
                   "Enter that web address in Connection Settings. Choose Get Key to create an API key on your server, then paste it into this app.")
            Text("Renting an empty cloud computer (a VPS) is another option, but you’ll need to install and maintain ArchiveBox yourself. Use the Docker guide for that route.")
                .foregroundStyle(.secondary)
        }
    }

    private var docker: some View {
        Group {
            heading("Install with Docker Compose",
                    "Run these commands in Terminal on the computer that will store your archive. Docker Compose is the README’s recommended container installation and includes the archiving tools.")
            Link("1. Install Docker first ↗", destination: URL(string: "https://docs.docker.com/get-docker/")!)
            Text("2. Create a collection and start the server").font(.headline)
            commands("""
            mkdir -p ~/archivebox/data && cd ~/archivebox
            curl -fsSL 'https://docker-compose.archivebox.io' > docker-compose.yml
            docker compose pull
            docker compose up -d --wait
            """)
            Text("First startup creates the collection automatically. Keep the data folder: it holds your archive.")
                .foregroundStyle(.secondary)
            finishInstallation
            Link("Full README: Docker, NAS, and other install options ↗", destination: quickstart)
        }
    }

    private var python: some View {
        Group {
            heading("Install the Python package",
                    "Use Terminal on a Mac or Linux computer you manage. The README recommends uv to install the package in its own environment; runtime tools are installed separately.")
            Link("1. Install uv first ↗", destination: URL(string: "https://docs.astral.sh/uv/getting-started/installation/")!)
            Text("2. Install ArchiveBox and start the server").font(.headline)
            commands("""
            uv tool install --python 3.13 --prerelease explicit --upgrade 'archivebox>=0.9.0rc0,<0.10'
            mkdir -p ~/archivebox/data && cd ~/archivebox/data
            archivebox init
            archivebox install
            archivebox server 0.0.0.0:5797
            """)
            Text("Already use pip? ArchiveBox is also a Python package on PyPI. Follow the installation guide for supported Python versions and dependencies. Homebrew and Debian options are in the README too.")
                .foregroundStyle(.secondary)
            finishInstallation
            Link("Full README: Python and package managers ↗", destination: quickstart)
        }
    }

    private var finishInstallation: some View {
        Group {
            detail("3. Create your account in the browser", icon: "person.crop.circle",
                   "On that computer, open http://admin.archivebox.localhost:5797/admin/ and follow the web setup to create your first administrator.")
            detail("4. Connect this app", icon: "link",
                   "Use the server address that opens from this device. In Connection Settings, choose Get Key, sign in, create an API key, and paste it into the app.")
            networkAdvice
        }
    }

    private var networkAdvice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Connecting from another device", systemImage: "wifi").font(.headline)
            Text("Keep the server computer awake and reachable. A localhost address only works on the computer running the server. On your iPhone or another computer, use its network or VPN address instead; network setup may be needed first.")
            Button("Tailscale & network guide", systemImage: "network.badge.shield.half.filled") { networkGuide = true }
                .accessibilityIdentifier("network.guide")
        }
        .font(.subheadline)
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var archiveDiagram: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                diagramNode("Link", caption: "Share", icon: "link", color: .blue)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                diagramNode("Server", caption: "Save a copy", icon: "externaldrive.fill", color: .orange)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                diagramNode("Archive", caption: "Read", icon: "books.vertical.fill", color: .teal)
            }
            VStack(spacing: 12) {
                diagramNode("Link", caption: "Share", icon: "link", color: .blue)
                Image(systemName: "arrow.down").foregroundStyle(.secondary)
                diagramNode("Server", caption: "Save a copy", icon: "externaldrive.fill", color: .orange)
                Image(systemName: "arrow.down").foregroundStyle(.secondary)
                diagramNode("Archive", caption: "Read", icon: "books.vertical.fill", color: .teal)
            }
        }
        .padding(20).frame(maxWidth: .infinity)
        .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("How it works: share a link, your server saves a copy, then open your archive in this app.")
    }

    private func diagramNode(_ title: String, caption: String, icon: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2)
                .foregroundStyle(color).frame(width: 52, height: 52)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            Text(title).font(.subheadline.bold())
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func heading(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text(description).font(.body).foregroundStyle(.secondary)
        }
    }

    private func detail(_ title: String, icon: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(Color.accentColor)
                .frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(description).foregroundStyle(.secondary)
            }
        }
    }

    private func choice(_ title: String, subtitle: String, icon: String, page: Page, id: String) -> some View {
        Button { self.page = page } label: {
            HStack(alignment: .center, spacing: 12) {
                detail(title, icon: icon, subtitle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.15)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("setup.\(id)")
    }

    private func commands(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal) {
                Text(text).font(.callout.monospaced()).textSelection(.enabled).fixedSize()
            }
            Button("Copy commands", systemImage: "doc.on.doc") {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                #else
                UIPasteboard.general.string = text
                #endif
            }
        }
        .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
