import AppIntents
import ArchiveBoxCore
import Observation

@MainActor @Observable
final class ArchiveNavigation {
    static let shared = ArchiveNavigation()
    var route: ArchiveRoute?
    var requestID = UUID()
    func open(_ route: ArchiveRoute) {
        self.route = route
        requestID = UUID()
    }
}

enum ArchiveDestination: String, AppEnum {
    case search, add
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "ArchiveBox Screen"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .search: "Search Archive", .add: "Add URLs"
    ]
}

// Included in both the app and WidgetKit extension. Foreground execution routes
// in the app process, including when launched from Control Center or the Lock Screen.
struct OpenArchiveDestinationIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open ArchiveBox Screen"
    static let supportedModes: IntentModes = .foreground
    @Parameter(title: "Screen") var target: ArchiveDestination
    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$target) in ArchiveBox") }
    init() {}
    init(_ target: ArchiveDestination) { self.target = target }
    @MainActor func perform() async throws -> some IntentResult {
        ArchiveNavigation.shared.open(target == .search ? .search("") : .add)
        return .result()
    }
}
