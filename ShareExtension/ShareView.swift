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
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            GroupBox {
                                VStack(alignment: .leading, spacing: 8) {
                                    if model.isRemoving {
                                        ProgressView("Cancelling and removing from server…")
                                    } else if case .sent(let count) = model.state {
                                        Label("Sent to ArchiveBox", systemImage: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .accessibilityIdentifier("shareAccepted")
                                        Text(count == 1 ? "Your server accepted the link for archiving." : "Your server accepted \(count) links for archiving.")
                                            .font(.callout).foregroundStyle(.secondary)
                                    } else {
                                        ProgressView("Sending to your server…")
                                    }
                                    ForEach(model.urls, id: \.absoluteString) { url in
                                        Text(url.absoluteString).font(.callout).lineLimit(3).textSelection(.enabled)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
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
                                    let suggested = model.suggestions.filter { candidate in
                                        !model.tags.contains { $0.localizedCaseInsensitiveCompare(candidate) == .orderedSame }
                                    }
                                    if !suggested.isEmpty {
                                        Text("Suggested tags").font(.caption).foregroundStyle(.secondary)
                                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading) {
                                            ForEach(Array(suggested.prefix(6)), id: \.self) { tag in
                                                Button { model.addTags(suggestion: tag); editingTags = false } label: {
                                                    Label(tag, systemImage: "plus").lineLimit(2)
                                                        .padding(8).background(.quaternary, in: Capsule())
                                                }
                                                .buttonStyle(.plain)
                                                .accessibilityLabel("Add suggested tag \(tag)")
                                            }
                                        }
                                    } else if let error = model.suggestionError {
                                        Text(error).font(.caption).foregroundStyle(.secondary)
                                        Button("Retry suggestions") { Task { await model.loadSuggestions() } }
                                    } else {
                                        Text("Type a new tag or search your server’s existing tags.")
                                            .font(.caption).foregroundStyle(.secondary)
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
                                    Text("The link is sent immediately. Add or remove tags while this sheet stays open.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                Label("Tags", systemImage: "tag")
                            }
                            .disabled(model.isRemoving)
                            GroupBox("Save to") {
                                VStack(alignment: .leading, spacing: 12) {
                                    Label(model.configuration?.server.absoluteString ?? "ArchiveBox", systemImage: "server.rack")
                                        .font(.callout)
                                        .accessibilityLabel("Server: \(model.configuration?.server.absoluteString ?? "ArchiveBox")")
                                    Label(model.configuration?.persona ?? "Server default", systemImage: "person.crop.circle")
                                        .accessibilityLabel("Persona: \(model.configuration?.persona ?? "Server default")")
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if let error = model.removalError {
                                GroupBox {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Label("Removal wasn’t confirmed", systemImage: "exclamationmark.triangle")
                                            .foregroundStyle(.orange)
                                        Text(error).font(.caption)
                                        Button("Retry removal", role: .destructive) { confirmingRemoval = true }
                                    }
                                }
                            }
                        }.padding()
                    }
                    .scrollDismissesKeyboard(.interactively)
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
            .task(id: "\(model.configuration?.server.absoluteString ?? "")|\(model.tagDraft)") {
                await model.loadSuggestions()
            }
            .interactiveDismissDisabled(model.state == .sending || model.isSavingTags || model.isRemoving || !model.tagDraft.isEmpty || model.tagError != nil)
        }
        .tint(Color("AccentColor"))
    }
}
