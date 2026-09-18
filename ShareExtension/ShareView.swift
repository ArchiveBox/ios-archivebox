import ArchiveBoxCore
import SwiftUI

struct ShareView: View {
    @Bindable var model: ShareModel
    let finish: () -> Void
    @State private var confirmingRemoval = false
    @FocusState private var editingTags: Bool

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .loading:
                    ProgressView("Reading shared link…")
                case .removed:
                    ContentUnavailableView {
                        Label("Removed from server", systemImage: "trash.circle")
                    } description: {
                        Text("This share was cancelled and removed. Previous captures were kept.")
                    } actions: {
                        Button("Done", action: finish).buttonStyle(.glassProminent)
                    }
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn’t save link", systemImage: "exclamationmark.circle")
                    } description: { Text(message) } actions: {
                        Button("Close", action: finish).buttonStyle(.glass).keyboardShortcut(.cancelAction)
                    }
                case .ready, .sending, .sent:
                    // A Form turns a single chip into a full-row accessibility target,
                    // leaving its reported hit area outside the chip. Cards keep each
                    // tag's visible and accessible button bounds together.
                    GeometryReader { geometry in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                VStack(alignment: .leading, spacing: 12) {
                                    if model.isRemoving {
                                        ProgressView("Cancelling and removing from server…")
                                    } else if case .sent = model.state {
                                        Label("Submitted to ArchiveBox Server", systemImage: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .accessibilityIdentifier("shareAccepted")
                                    } else {
                                        ProgressView("Submitting to ArchiveBox Server…")
                                    }
                                    ForEach(model.urls, id: \.absoluteString) { url in
                                        HStack(alignment: .top) {
                                            // Send only the hostname to the favicon service, never
                                            // the shared URL's path, query, or server credentials.
                                            let favicon = ArchiveTags.domainTag(for: url) == nil ? nil :
                                                URL(string: "https://www.google.com/s2/favicons")?.appending(queryItems: [
                                                    URLQueryItem(name: "domain", value: url.host()),
                                                    URLQueryItem(name: "sz", value: "32"),
                                                ])
                                            AsyncImage(url: favicon) { image in
                                                image.resizable().scaledToFit()
                                            } placeholder: { Image(systemName: "globe") }
                                                .frame(width: 20, height: 20).accessibilityHidden(true)
                                            Text("URL: \(url.absoluteString)").lineLimit(3).textSelection(.enabled)
                                        }
                                    }
                                    Label("Server: \(model.configuration?.server.absoluteString ?? "ArchiveBox")", systemImage: "server.rack")
                                        .textSelection(.enabled)
                                    Label("Persona: \(model.configuration?.persona ?? "Server default")", systemImage: "person.crop.circle")
                                }
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if let error = model.removalError {
                                    Label("Removal wasn’t confirmed", systemImage: "exclamationmark.triangle")
                                        .foregroundStyle(.orange)
                                    Text(error).font(.caption)
                                    Button("Retry removal", role: .destructive) { confirmingRemoval = true }
                                }
                                Spacer(minLength: 0)
                                Divider()
                                GroupBox {
                                    VStack(alignment: .leading, spacing: 12) {
                                        // Adaptive columns keep long tags and large Dynamic Type
                                        // inside the sheet on both iPhone and Mac.
                                        if !model.tags.isEmpty {
                                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading) {
                                                ForEach(model.tags, id: \.self) { tag in
                                                    Button { model.removeTag(tag) } label: {
                                                        HStack {
                                                            Text(tag).lineLimit(2)
                                                            Image(systemName: "xmark").font(.caption)
                                                        }
                                                        .padding(8).background(.quaternary, in: Capsule())
                                                    }
                                                    .buttonStyle(.plain)
                                                    .accessibilityLabel("Remove tag \(tag)")
                                                }
                                            }
                                        }
                                        HStack {
                                            TextField("Add tags, separated by commas", text: $model.tagDraft)
                                                .focused($editingTags)
                                                .onSubmit { model.addTags(); editingTags = false }
                                                .accessibilityIdentifier("shareTagInput")
                                            #if os(iOS)
                                                .textInputAutocapitalization(.never)
                                            #endif
                                                .autocorrectionDisabled()
                                            Button { model.addTags(); editingTags = false } label: {
                                                Image(systemName: "plus")
                                            }
                                            .buttonStyle(.glass)
                                            .accessibilityLabel("Add tags")
                                            .disabled(ArchiveTags.normalize([model.tagDraft]).isEmpty)
                                        }
                                        let suggested = model.suggestedTags
                                        if !suggested.isEmpty {
                                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)], alignment: .leading) {
                                                ForEach(suggested, id: \.self) { tag in
                                                    Button { model.addTags(suggestion: tag); editingTags = false } label: {
                                                        Label(tag, systemImage: "plus").lineLimit(2)
                                                            .padding(8).background(.quaternary, in: Capsule())
                                                    }
                                                    .buttonStyle(.plain)
                                                    .accessibilityLabel("Add suggested tag \(tag)")
                                                }
                                            }
                                        }
                                        if model.isSavingTags {
                                            ProgressView("Saving tags…")
                                        } else if let error = model.tagError {
                                            Label("Link saved; tags weren’t saved.", systemImage: "exclamationmark.triangle")
                                                .foregroundStyle(.orange)
                                            Text(error).font(.caption)
                                            Button("Retry tags") { model.saveTags() }
                                            Button("Close without saving tags", action: finish)
                                        } else if case .sent = model.state, !model.tags.isEmpty {
                                            Label("Tags saved", systemImage: "checkmark")
                                                .font(.caption).foregroundStyle(.secondary)
                                                .accessibilityIdentifier("shareTagsSaved")
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                } label: {
                                    Label("Add Tags", systemImage: "tag")
                                }
                                .disabled(model.isRemoving)
                            }
                            .padding()
                            // Fill short sheets so tagging stays near the thumb; longer
                            // content and the keyboard still get a normal scroll view.
                            .frame(minHeight: geometry.size.height, alignment: .top)
                        }
                        .scrollDismissesKeyboard(.interactively)
                    }
                }
            }
            .navigationTitle("ArchiveBox")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                switch model.state {
                case .loading:
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: finish) }
                case .ready, .sending, .sent:
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .destructive) { confirmingRemoval = true } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .accessibilityLabel("Remove from server")
                        .disabled(model.isRemoving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { Task { if await model.finish() { finish() } } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.state == .sending || model.isSavingTags || model.isRemoving)
                    }
                default: ToolbarItem(placement: .confirmationAction) { EmptyView() }
                }
            }
            .confirmationDialog("Remove this share from your server?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                Button("Remove from server", role: .destructive) { Task { await model.removeSubmission() } }
                // Popovers omit role.cancel actions; keep an explicit choice on iPad
                // and in extension hosts that present this dialog as a popover.
                Button("Keep it") { confirmingRemoval = false }
            } message: {
                Text("Stops this crawl and removes the links submitted by this share. Previous captures of the same URLs are kept.")
            }
            .interactiveDismissDisabled(model.state == .sending || model.isSavingTags || model.isRemoving || !model.tagDraft.isEmpty || model.tagError != nil)
        }
        .tint(Color("AccentColor"))
    }
}
