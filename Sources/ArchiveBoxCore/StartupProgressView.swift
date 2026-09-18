import SwiftUI

/// Measured progress when available; elapsed-time feedback otherwise.
public struct StartupProgressView: View {
    private let progress: Double?
    @State private var started = Date()

    public init(progress: Double? = nil) { self.progress = progress }

    public var body: some View {
        TimelineView(.periodic(from: started, by: 0.25)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(started))
            // Inspired by pirate/c89b7d42be148e9180d8c7cf81e734c8:
            // reach 50% at the expected duration, then approach completion
            // without a fixed ceiling that would freeze during a long wait.
            let estimate = min(Double(1).nextDown, elapsed / (elapsed + 30))
            ProgressView(value: progress ?? estimate)
                .progressViewStyle(.linear)
                .accessibilityLabel(progress == nil ? "Estimated progress" : "Download progress")
        }
    }
}
