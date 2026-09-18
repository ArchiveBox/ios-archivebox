import SwiftUI
import ArchiveBoxCore

struct AddURLsView: View {
    @Bindable var model: SettingsModel
    let pages: WebPages
    var reloadID: UUID?
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let server = model.verifiedServer {
                        ServerWebView(url: server.appending(path: "add/"), title: "Add URLs", session: pages.page(for: "add-\(server)", baseURL: model.displayedBaseURL,
                            server: model.verifiedServer, token: model.verifiedToken), reloadID: reloadID)
                            .id(server).frame(maxWidth: .infinity).frame(height: geometry.size.height * 0.8)
                    } else {
                        ContentUnavailableView("Connect your server", systemImage: "network", description: Text("Set up Connection Settings to use the embedded Add URLs form."))
                    }
                    VStack(alignment: .leading, spacing: 24) {
                    Text("More ways to add").font(.title2.bold())
                    Text("There are several ways you can add new URLs to archive.")
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("In any app, open Share → ArchiveBox (under More if needed). The link is sent immediately; add tags, wait for confirmation, then tap Done.")
                            Image("ShareSheetGuide").resizable().scaledToFit().frame(maxHeight: 320)
                                .accessibilityLabel("iPhone share sheet with ArchiveBox available in the Apps list")
                            Picker(
                                "Default persona",
                                selection: Binding(
                                    get: { model.persona },
                                    set: {
                                        model.persona = $0
                                        model.save()
                                    })
                            ) {
                                Text("Server default").tag("")
                                ForEach(model.personas) { persona in Text(persona.name).tag(persona.name) }
                                if !model.persona.isEmpty && !model.personas.contains(where: { $0.name == model.persona }) {
                                    Text(model.personasLoaded ? "\(model.persona) (not found on server)" : model.persona).tag(model.persona)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("defaultPersona")
                            .disabled(model.verifiedToken == nil || model.busy)
                            Button("Refresh personas", systemImage: "arrow.clockwise") {
                                Task { await model.refreshPersonas() }
                            }
                            .disabled(model.verifiedToken == nil || model.busy)
                            if let message = model.personaError {
                                Text("Couldn’t refresh personas: \(message) Your saved persona has not changed.").foregroundStyle(.red)
                            }

                            Text("Default Persona applies to native share-sheet saves. Browser extensions and the web form have their own persona controls.").font(.footnote)
                                .foregroundStyle(.secondary)
                            if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("Share Sheet", systemImage: "square.and.arrow.up")
                    }
                    BrowserExtensionSetup()
                    GroupBox("And more…") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(
                                [
                                    ("REST API", "https://github.com/ArchiveBox/ArchiveBox/issues/496#issuecomment-2080174235"),
                                    ("Command-line interface", "https://github.com/ArchiveBox/ArchiveBox/wiki/Usage#cli-usage"),
                                    ("SQLite / SQL shell", "https://github.com/ArchiveBox/ArchiveBox/wiki/Usage#sql-shell-usage"),
                                    ("Supported sources", "https://github.com/ArchiveBox/ArchiveBox/wiki/Quickstart#2-get-your-list-of-urls-to-archive"),
                                ], id: \.0
                            ) { title, address in
                                Link(title, destination: URL(string: address)!)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    }.padding(20).frame(maxWidth: 1000)
                }.frame(maxWidth: .infinity)
            }
        }
    }
}
