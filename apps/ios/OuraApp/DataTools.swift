import Foundation
import SwiftUI

// Export, restore from the hub, and demo data. All three work on the database file
// through the shared brain, so the desktop client gives the same files.

enum ExportFormat: String, CaseIterable, Identifiable {
    case csv, json
    var id: String { rawValue }
    var title: String { self == .csv ? "Daily Table (CSV)" : "Full Summary (JSON)" }
    var detail: String {
        self == .csv ? "One row per day with every score and measurement. Opens in Numbers and Excel."
            : "Everything the app shows, with the series of each night."
    }
}

enum DataExport {
    /// Write the export to a temporary file and return its URL.
    static func file(_ format: ExportFormat) throws -> URL {
        let tz = Int64((Double(TimeZone.current.secondsFromGMT()) / 3600).rounded())
        let text: String
        switch format {
        case .csv: text = try exportDailyCsv(dbPath: DB.readPath(), tzOffset: tz)
        case .json: text = summaryJson(dbPath: DB.readPath(), tzOffset: tz)
        }
        let stamp = NotificationRules.localDay(Date())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-oura-\(stamp).\(format.rawValue)")
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }
}

struct RestoreProgress: Equatable {
    var pages = 0
    var events = 0
    var inserted = 0
    var done = false
    var error: String?
}

/// Copies every raw ring row from the hub back into the database of this iPhone.
/// A row that is here already is skipped, so a restore can run again.
enum HubRestore {
    static func run(base: String, token: String,
                    progress: @escaping @MainActor (RestoreProgress) -> Void) async {
        var state = RestoreProgress()
        var afterEvent: Int64 = 0
        var afterReading: Int64 = 0
        do {
            while true {
                guard var parts = HubSettings.endpoint(base: base, path: "export/events")
                    .flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
                    throw HubError.badURL
                }
                parts.queryItems = [
                    URLQueryItem(name: "after_event_id", value: String(afterEvent)),
                    URLQueryItem(name: "after_reading_id", value: String(afterReading)),
                ]
                guard let url = parts.url else { throw HubError.badURL }
                var request = URLRequest(url: url, timeoutInterval: 60)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    throw NSError(domain: "open_oura", code: code, userInfo: [
                        NSLocalizedDescriptionKey: code == 401 ? "The hub did not accept the token." : "The hub answered with status \(code).",
                    ])
                }
                let json = String(decoding: data, as: UTF8.self)
                let page = try page(json)
                let report = try importBatchJson(dbPath: DB.url.path, batchJson: json)
                state.pages += 1
                state.events += Int(report.eventsSeen)
                state.inserted += Int(report.eventsInserted)
                await progress(state)
                guard page.more, page.nextEvent > afterEvent || page.nextReading > afterReading else { break }
                afterEvent = page.nextEvent
                afterReading = page.nextReading
            }
            state.done = true
        } catch {
            state.error = error.localizedDescription
        }
        await progress(state)
    }

    /// The paging fields of one export page.
    static func page(_ json: String) throws -> (more: Bool, nextEvent: Int64, nextReading: Int64) {
        guard let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw NSError(domain: "open_oura", code: 0, userInfo: [NSLocalizedDescriptionKey: "The hub sent no valid page."])
        }
        if let message = root["error"] as? String {
            throw NSError(domain: "open_oura", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return ((root["more"] as? Bool) ?? false,
                (root["next_event_id"] as? NSNumber)?.int64Value ?? 0,
                (root["next_reading_id"] as? NSNumber)?.int64Value ?? 0)
    }
}

/// Settings → Data: export, restore, demo data.
struct DataToolsSection: View {
    let onChanged: () -> Void
    @ObservedObject private var ring = RingSync.shared
    @State private var exporting: ExportFormat?
    @State private var shared: URL?
    @State private var exportError: String?
    @State private var restore: RestoreProgress?
    @State private var restoring = false
    @State private var confirmRestore = false
    @State private var demoMessage: String?

    private var hasDatabase: Bool { FileManager.default.fileExists(atPath: DB.url.path) }

    var body: some View {
        Section {
            ForEach(ExportFormat.allCases) { format in
                Button {
                    export(format)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(format.title)
                            Text(format.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if exporting == format { ProgressView() } else {
                            Image(systemName: "square.and.arrow.up").foregroundStyle(.tint)
                        }
                    }
                }
                .disabled(exporting != nil)
                .accessibilityIdentifier("export-\(format.rawValue)")
            }
            if let exportError {
                Text(exportError).font(.footnote).foregroundStyle(Theme.alert)
            }
        } header: {
            Text("Export")
        } footer: {
            Text("The file is made on this iPhone. You choose where it goes.")
        }
        .sheet(item: $shared) { url in
            ShareSheet(items: [url])
        }

        Section {
            Button {
                confirmRestore = true
            } label: {
                HStack {
                    Label(restoring ? "Restoring…" : "Restore Ring Data from the Hub", systemImage: "icloud.and.arrow.down")
                    Spacer()
                    if restoring { ProgressView() }
                }
            }
            .disabled(restoring || ring.busy || HubSettings.url.isEmpty || HubSettings.token == nil)
            .confirmationDialog("Restore ring data from your hub?", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("Restore") { startRestore() }
            } message: {
                Text("The app copies every ring record of your hub into the database of this iPhone. Records that are here already are skipped.")
            }
            if let restore {
                if let error = restore.error {
                    Text("Restore stopped: \(error)").font(.footnote).foregroundStyle(Theme.alert)
                } else {
                    Text(restore.done
                         ? "Restore complete: \(restore.inserted) new of \(restore.events) records."
                         : "\(restore.events) records read, \(restore.inserted) new…")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Restore")
        } footer: {
            Text(HubSettings.url.isEmpty || HubSettings.token == nil
                 ? "Connect a health hub first. The hub keeps a copy of all ring data."
                 : "For a new iPhone or after a reset of the local data. Your journal and your profile are not on the hub.")
        }

        if !ring.isPaired && !hasDatabase {
            Section {
                Button {
                    loadDemo()
                } label: {
                    Label("Load Demo Data", systemImage: "wand.and.stars")
                }
                if let demoMessage {
                    Text(demoMessage).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("No ring yet")
            } footer: {
                Text("45 days of made-up data, so you can look at the app before you pair a ring. Reset Local Sync Data (Sync, Advanced) removes it.")
            }
        }
    }

    private func export(_ format: ExportFormat) {
        exporting = format
        exportError = nil
        Task.detached(priority: .userInitiated) {
            let result = Result { try DataExport.file(format) }
            await MainActor.run {
                exporting = nil
                switch result {
                case .success(let url): shared = url
                case .failure(let error): exportError = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func startRestore() {
        guard let token = HubSettings.token else { return }
        restoring = true
        restore = RestoreProgress()
        Task {
            await HubRestore.run(base: HubSettings.url, token: token) { restore = $0 }
            restoring = false
            if restore?.inserted ?? 0 > 0 { onChanged() }
        }
    }

    private func loadDemo() {
        let tz = Int64((Double(TimeZone.current.secondsFromGMT()) / 3600).rounded())
        do {
            try writeDemoDb(dbPath: DB.url.path, days: 45, tzOffset: tz)
            demoMessage = "Demo data loaded."
            onChanged()
        } catch {
            demoMessage = "Demo data was not loaded: \(error.localizedDescription)"
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
