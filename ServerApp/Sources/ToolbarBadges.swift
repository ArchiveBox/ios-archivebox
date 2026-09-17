import AppKit
import SwiftUI

struct ServerToolbarBrand: View {
    var body: some View {
        HStack(spacing: 6) {
            if let url = Bundle.main.url(forResource: "ArchiveBox", withExtension: "icns"),
               let logo = NSImage(contentsOf: url) {
                Image(nsImage: logo).resizable().scaledToFit().frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
            }
            Text("ArchiveBox Server").font(.system(size: 15, weight: .semibold))
        }.fixedSize()
    }
}

struct ServerToolbarStatus: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Circle().fill(model.restarting ? .orange : model.ready ? .green : .red)
            .frame(width: 8, height: 8)
            .accessibilityLabel(model.restarting ? "Restarting" : model.ready ? "Running" : "Stopped")
            .help(model.restarting ? "Restarting server" : model.ready ? "Server running" : model.detail)
    }
}

struct ServerToolbarURL: View {
    @ObservedObject var model: SettingsModel
    @State private var copied = false
    var body: some View {
        Button {
            guard let url = model.serverDetails?.base.absoluteString else { return }
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(url, forType: .string)
        } label: {
            HStack(spacing: 6) {
                Text(model.serverDetails?.base.absoluteString ?? "Server unavailable")
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }.font(.system(size: 12))
        }
        .buttonStyle(.glass)
        .disabled(model.serverDetails == nil)
        .help("Copy BASE_URL")
        .accessibilityLabel("Copy server URL")
        .accessibilityValue(model.serverDetails?.base.absoluteString ?? "Unavailable")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
        .frame(maxWidth: 240)
    }
}

struct ServerToolbarMetrics: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        // Fixed value widths prevent toolbar movement as digit counts change.
        // Explicit image/text pairs keep values visible in an icon-only toolbar.
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(model.ready ? model.cpu : "—")
                    .frame(width: 38, alignment: .trailing)
            }.accessibilityElement(children: .ignore)
                .accessibilityLabel("Container CPU")
                .accessibilityValue(model.ready ? model.cpu : "Unavailable")
                .help("Container CPU; 100% is one core. Available after two samples.")
            HStack(spacing: 4) {
                Image(systemName: "memorychip")
                Text(model.ready ? model.ram : "—")
                    .frame(width: 64, alignment: .trailing)
            }.accessibilityElement(children: .ignore)
                .accessibilityLabel("Container memory")
                .accessibilityValue(model.ready ? model.ram : "Unavailable")
                .help("Container memory usage")
        }
        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
    }
}

extension AppDelegate {
    func updateTabBadges(_ details: ServerDetails) {
        for (index, screen) in screens.enumerated() {
            let count: Int? = screen == .activity ? details.activeSnapshots :
                screen == .users ? details.users.filter(\.is_superuser).count : nil
            guard let count else { tabs.setImage(nil, forSegment: index); tabs.setToolTip(nil, forSegment: index); continue }
            let text = NSAttributedString(string: String(count), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ])
            let size = NSSize(width: max(20, ceil(text.size().width) + 10), height: 17)
            // Keep the native segmented control's hit targets/selection drawing;
            // its image slot provides an inline pill without a custom tab widget.
            let badge = NSImage(size: size, flipped: false) { rect in
                NSColor.labelColor.withAlphaComponent(0.10).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
                text.draw(at: NSPoint(x: (size.width - text.size().width) / 2, y: (size.height - text.size().height) / 2))
                return true
            }
            badge.accessibilityDescription = "\(count) \(screen == .activity ? "active snapshots" : "superusers")"
            tabs.setImage(badge, forSegment: index)
            tabs.setToolTip(badge.accessibilityDescription, forSegment: index)
        }
        tabs.sizeToFit()
    }
}
