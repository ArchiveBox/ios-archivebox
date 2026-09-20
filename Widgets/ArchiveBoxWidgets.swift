import AppIntents
import ArchiveBoxCore
import SwiftUI
import WidgetKit

@main
struct ArchiveBoxWidgets: WidgetBundle {
    var body: some Widget {
        ArchiveQuickActionsWidget()
        ArchiveSearchControl()
        ArchiveAddControl()
    }
}

private struct ArchiveEntry: TimelineEntry { let date: Date }
private struct ArchiveTimeline: TimelineProvider {
    func placeholder(in context: Context) -> ArchiveEntry { ArchiveEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (ArchiveEntry) -> Void) { completion(ArchiveEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ArchiveEntry>) -> Void) {
        completion(Timeline(entries: [ArchiveEntry(date: .now)], policy: .never))
    }
}

struct ArchiveQuickActionsWidget: Widget {
    let kind = "io.archivebox.quickActions"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ArchiveTimeline()) { _ in
            VStack(alignment: .leading, spacing: 14) {
                Label("ArchiveBox", systemImage: "archivebox.fill").font(.headline)
                Link(destination: ArchiveRoute.search("").url) { Label("Search Archive", systemImage: "magnifyingglass") }
                Link(destination: ArchiveRoute.add.url) { Label("Add URLs", systemImage: "plus") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("ArchiveBox")
        .description("Find a saved page or add links to your archive.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ArchiveSearchControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.archivebox.search") {
            ControlWidgetButton(action: OpenArchiveDestinationIntent(.search)) {
                Label("Search Archive", systemImage: "magnifyingglass")
            }
        }
        .displayName("Search ArchiveBox")
        .description("Open native archive search.")
    }
}

struct ArchiveAddControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.archivebox.add") {
            ControlWidgetButton(action: OpenArchiveDestinationIntent(.add)) {
                Label("Add URLs", systemImage: "plus")
            }
        }
        .displayName("Add to ArchiveBox")
        .description("Open the form to add links to your archive.")
    }
}
