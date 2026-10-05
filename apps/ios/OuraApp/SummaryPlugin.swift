import Foundation

/// An optional add-on that adds slow, on-device results to the summary: sleep
/// stages, workouts, an illness check, cardiovascular age. This app has none. A
/// build that adds a class named `OpenHealthSummaryPlugin` to the target gets it
/// loaded at launch; the public sources never refer to that class.
protocol SummaryPlugin {
    /// Add the plugin's results to `base`. Slow: call it off the main thread.
    /// `previous` is the last published summary, for a result that fails this time.
    func enrich(_ base: Summary, previous: Summary?,
                progress: @escaping @Sendable (String) -> Void) -> Summary
    /// Drop every cached result (the user reset the data).
    func clearCache()
}

enum Plugins {
    static let summary: SummaryPlugin? = (NSClassFromString("OpenHealthSummaryPlugin") as? NSObject.Type)
        .flatMap { $0.init() as? SummaryPlugin }
}
