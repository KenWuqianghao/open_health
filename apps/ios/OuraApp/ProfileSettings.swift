import SwiftUI
import HealthKit

private struct EditableProfile {
    var sex: String
    var age: Double
    var heightCm: Double
    var weightKg: Double
    var ringSize: Double
    var activityGoalKcal: Double

    init(_ profile: Profile?) {
        sex = profile?.sex ?? "M"
        age = profile?.age ?? 30
        heightCm = (profile?.height_m ?? 1.78) * 100
        weightKg = profile?.weight_kg ?? 75
        ringSize = profile?.ring_size ?? 10
        activityGoalKcal = profile?.activity_goal_kcal ?? 450
    }
}

private enum ProfileStore {
    static var url: URL { DB.url.deletingLastPathComponent().appendingPathComponent("profile.json") }

    static func save(_ p: EditableProfile) throws {
        let object: [String: Any] = [
            "sex": p.sex, "age": p.age, "height_m": p.heightCm / 100,
            "weight_kg": p.weightKg, "ring_size": p.ringSize,
            "activity_goal_kcal": p.activityGoalKcal,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

private struct HealthProfile {
    var sex: String?
    var age: Double?
    var heightCm: Double?
    var weightKg: Double?
}

private enum HealthProfileImporter {
    static func load(completion: @escaping (Result<HealthProfile, Error>) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(.failure(NSError(domain: "open_oura", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "Apple Health is unavailable on this device."])))
            return
        }
        let store = HKHealthStore()
        let dob = HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!
        let biologicalSex = HKObjectType.characteristicType(forIdentifier: .biologicalSex)!
        let height = HKObjectType.quantityType(forIdentifier: .height)!
        let mass = HKObjectType.quantityType(forIdentifier: .bodyMass)!
        let read: Set<HKObjectType> = [dob, biologicalSex, height, mass]
        store.requestAuthorization(toShare: [], read: read) { granted, error in
            if let error { DispatchQueue.main.async { completion(.failure(error)) }; return }
            guard granted else {
                let e = NSError(domain: "open_oura", code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "Apple Health access was not granted."])
                DispatchQueue.main.async { completion(.failure(e)) }
                return
            }

            var result = HealthProfile()
            if let birth = try? store.dateOfBirthComponents().date {
                result.age = Double(Calendar.current.dateComponents([.year], from: birth, to: Date()).year ?? 0)
            }
            if let value = try? store.biologicalSex().biologicalSex {
                switch value {
                case .female: result.sex = "F"
                case .male: result.sex = "M"
                case .other: result.sex = "O"
                default: break
                }
            }

            let group = DispatchGroup()
            func latest(_ type: HKQuantityType, unit: HKUnit, assign: @escaping (Double) -> Void) {
                group.enter()
                let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
                let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1,
                                          sortDescriptors: [sort]) { _, samples, _ in
                    if let sample = samples?.first as? HKQuantitySample {
                        assign(sample.quantity.doubleValue(for: unit))
                    }
                    group.leave()
                }
                store.execute(query)
            }
            latest(height, unit: .meterUnit(with: .centi)) { result.heightCm = $0 }
            latest(mass, unit: .gramUnit(with: .kilo)) { result.weightKg = $0 }
            group.notify(queue: .main) { completion(.success(result)) }
        }
    }
}

struct ProfileSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile: EditableProfile
    @State private var importing = false
    @State private var message: String?
    @ObservedObject private var health = HealthExporter.shared
    @ObservedObject private var ring = RingSync.shared
    @ObservedObject private var hub = HubPusher.shared
    @ObservedObject private var healthRead = HealthReader.shared
    @State private var hubToken: String = HubSettings.token ?? ""
    @State private var showPairing = false
    @State private var revealKey = false
    @State private var confirmForget = false
    @State private var confirmRemove = false
    @State private var removeMessage: String?
    @State private var units = Units.current
    @State private var restMode: Bool
    @State private var notify: [NotificationKind: Bool] = Dictionary(
        uniqueKeysWithValues: NotificationKind.allCases.map { ($0, NotifierSettings.isOn($0)) })
    @State private var notifyDenied = false
    @ObservedObject private var healthImport = HealthImport.shared
    let summary: Summary?
    let onSaved: () -> Void
    private static let when: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()

    private var healthStatusLine: String {
        var parts: [String] = []
        if let t = health.status.lastSuccessAt { parts.append("last export \(Self.when.string(from: t))") }
        parts.append(health.status.lastCounts)
        if health.status.pendingDays > 0 { parts.append("\(health.status.pendingDays) day(s) pending") }
        if health.status.deferredForUnlock { parts.append("waiting for unlock") }
        if !health.status.typesOff.isEmpty { parts.append("off in Health: \(health.status.typesOff.joined(separator: ", "))") }
        if let e = health.status.lastError { parts.append("error: \(e)") }
        return parts.joined(separator: " · ")
    }

    private var hubStatusLine: String {
        var parts: [String] = []
        if let t = hub.status.lastSummaryAt { parts.append("summary \(Self.when.string(from: t))") }
        if let t = hub.status.lastEventsAt { parts.append("ring rows \(Self.when.string(from: t)), through id \(HubSettings.afterEventId)") }
        if healthRead.enabled, let t = healthRead.status.lastSuccessAt { parts.append("Apple Health \(Self.when.string(from: t)), \(healthRead.status.samplesSent) samples") }
        if healthRead.enabled, let e = healthRead.status.lastError { parts.append("Apple Health error: \(e)") }
        if let e = hub.status.lastError { parts.append("error: \(e)") }
        return parts.isEmpty ? "Nothing sent yet." : parts.joined(separator: " · ")
    }

    private func forgetRing() {
        Keychain.deleteKey()
        PairedRingStore.clear()
        RingCentral.shared.disarm()
        dlog("pair", "ring forgotten")
    }

    /// A labelled numeric row: label leading, the value trailing, like the Settings app.
    private func numberField(_ label: String, value: Binding<Double>, unit: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField(label, value: value, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
            }
        }
    }

    init(profile: Profile?, summary: Summary? = nil, onSaved: @escaping () -> Void) {
        _profile = State(initialValue: EditableProfile(profile))
        _restMode = State(initialValue: summary?.restMode?.value?.on ?? false)
        self.summary = summary
        self.onSaved = onSaved
    }

    /// Height and weight in the chosen units; the profile keeps cm and kg.
    private var heightShown: Binding<Double> {
        Binding(get: { (units.height(cm: profile.heightCm) * 10).rounded() / 10 },
                set: { profile.heightCm = units.centimeters($0) })
    }
    private var weightShown: Binding<Double> {
        Binding(get: { (units.weight(kg: profile.weightKg) * 10).rounded() / 10 },
                set: { profile.weightKg = units.kilograms($0) })
    }

    private func setNotification(_ kind: NotificationKind, _ on: Bool) {
        notify[kind] = on
        Task {
            if on, !(await Notifier.shared.requestPermission()) {
                notify[kind] = false
                notifyDenied = true
                return
            }
            NotifierSettings.set(kind, on)
            Notifier.shared.settingsChanged(summary: summary)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Biological sex", selection: $profile.sex) {
                        Text("Female").tag("F")
                        Text("Male").tag("M")
                        Text("Other").tag("O")
                    }
                    numberField("Age", value: $profile.age, unit: "yr")
                    numberField("Height", value: heightShown, unit: units.heightUnit)
                    numberField("Weight", value: weightShown, unit: units.weightUnit)
                    numberField("Ring size", value: $profile.ringSize, unit: "")
                    Picker("Units", selection: $units) {
                        ForEach(Units.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: units) { _, value in
                        Units.current = value
                        onSaved()
                    }
                } header: {
                    Text("Your data")
                } footer: {
                    Text("Stored only on this iPhone and used by the cardiovascular and activity calculations.")
                }

                Section {
                    numberField("Daily activity goal", value: $profile.activityGoalKcal, unit: "kcal")
                    Toggle("Rest mode", isOn: $restMode)
                        .onChange(of: restMode) { _, on in
                            let op: [String: Any] = ["op": "set_rest_mode", "on": on,
                                                     "day": NotificationRules.localDay(Date())]
                            if JournalStore.apply(op) != nil { onSaved() }
                        }
                } header: {
                    Text("Scores")
                } footer: {
                    Text("The goal is the active calories per day for the Activity score's \"Meet daily goal\". Oura adapts this goal to you; here it is a fixed number. In rest mode, for an illness or an injury, the app gives no Activity score, and activity does not count for your readiness.")
                }

                Section {
                    ForEach(NotificationKind.allCases) { kind in
                        Toggle(isOn: Binding(get: { notify[kind] ?? false },
                                             set: { setNotification(kind, $0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.title)
                                Text(kind.detail).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("notify-\(kind.rawValue)")
                    }
                    if notifyDenied {
                        Button("Allow Notifications in Settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("The app decides each notification on this iPhone. Some arrive only after the next sync, because the app has no server that watches your ring.")
                }

                Section {
                    Button {
                        importing = true; message = nil
                        HealthProfileImporter.load { result in
                            importing = false
                            switch result {
                            case .success(let health):
                                if let v = health.sex { profile.sex = v }
                                if let v = health.age, v > 0 { profile.age = v }
                                if let v = health.heightCm { profile.heightCm = v }
                                if let v = health.weightKg { profile.weightKg = v }
                                message = "Imported available values from Apple Health."
                            case .failure(let error): message = error.localizedDescription
                            }
                        }
                    } label: {
                        HStack {
                            Label("Import from Apple Health", systemImage: "heart.text.square")
                            Spacer()
                            if importing { ProgressView() }
                        }
                    }
                    .disabled(importing)
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }

                Section {
                    if let paired = PairedRingStore.load() {
                        LabeledContent("Serial", value: paired.serial)
                        LabeledContent("Model", value: paired.hardwareId ?? "—")
                        LabeledContent("Firmware", value: paired.firmware ?? "—")
                        LabeledContent("Last sync", value: ring.lastSuccessfulSyncAt.map { Self.when.string(from: $0) } ?? "—")
                        Button { showPairing = true } label: { Label("Pair a Different Ring", systemImage: "plus.circle") }
                        // the pairing key is for using the same ring from the desktop
                        // client; fold it away so it never sits open on the screen
                        DisclosureGroup(isExpanded: $revealKey.animation(Motion.snappy)) {
                            if let key = Keychain.loadKey() {
                                Text(key).font(Theme.mono(.footnote)).textSelection(.enabled)
                                Button { UIPasteboard.general.string = key } label: { Label("Copy Key", systemImage: "doc.on.doc") }
                                Text("Made on this iPhone when you paired. Use it with the desktop client (oura --key-file). Losing it means a factory reset of the ring.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        } label: {
                            Label("Pairing Key", systemImage: "key")
                        }
                        Button("Forget Ring", role: .destructive) { confirmForget = true }
                            .confirmationDialog("Forget this ring?", isPresented: $confirmForget) {
                                Button("Forget Ring", role: .destructive) { forgetRing() }
                            } message: {
                                Text("The key is deleted from this iPhone. Pairing again needs a factory reset of the ring. Synced data and Apple Health samples are kept.")
                            }
                    } else {
                        Button { showPairing = true } label: { Label("Pair a Ring", systemImage: "plus.circle") }
                    }
                } header: {
                    Text("Ring")
                }

                Section {
                    Toggle("Write ring data to Apple Health", isOn: Binding(
                        get: { health.enabled },
                        set: { on in Task { await health.setEnabled(on) } }
                    ))
                    if health.enabled {
                        Toggle("Include resting energy (estimate)", isOn: $health.includeBasal)
                        DisclosureGroup("What is exported") {
                            Text("Sleep: in-bed time and sleep stages.\nHeart rate every minute, resting heart rate, and HRV (SDNN, only when measured).\nBreathing rate and blood oxygen during sleep.\nSteps (estimated from movement), active energy, and resting energy if you turn it on.\nWorkouts that the app finds from your movement.\n\nNot exported: readiness, sleep and activity scores, skin temperature, distance. If the official Oura app also writes to Health, turn one of the two off to avoid duplicates.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button { health.schedule(.manual(full: false)) } label: {
                            HStack {
                                Label(health.status.running ? (health.status.progress.isEmpty ? "Exporting…" : health.status.progress) : "Export Now",
                                      systemImage: "square.and.arrow.up")
                                Spacer()
                                if health.status.running { ProgressView() }
                            }
                        }
                        .disabled(health.status.running)
                        Button { health.schedule(.manual(full: true)) } label: { Label("Export Everything Again", systemImage: "arrow.counterclockwise") }
                            .disabled(health.status.running)
                        Text(healthStatusLine).font(.footnote).foregroundStyle(health.status.lastError == nil ? Color.secondary : Theme.alert)
                        Button("Remove Open Oura Data from Health", role: .destructive) { confirmRemove = true }
                            .confirmationDialog("Remove all Open Oura samples from Apple Health?", isPresented: $confirmRemove) {
                                Button("Remove", role: .destructive) {
                                    Task { removeMessage = await health.removeAllExportedData() }
                                }
                            }
                        if let removeMessage { Text(removeMessage).font(.footnote).foregroundStyle(.secondary) }
                    } else if let e = health.status.lastError {
                        Label(e, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Theme.alert)
                    }
                } header: {
                    Text("Apple Health")
                } footer: {
                    Text("Only measured data is written, never scores. Every day is rewritten in place, so re-running never duplicates. Data stays on this iPhone.")
                }

                Section {
                    Toggle("Use workouts from Apple Health", isOn: Binding(
                        get: { healthImport.enabled },
                        set: { on in Task { await healthImport.setEnabled(on); onSaved() } }
                    ))
                    if healthImport.enabled {
                        if let at = healthImport.status.lastRunAt {
                            Text("\(healthImport.status.workouts) workout(s) of the last \(HealthImport.lookBackDays) days"
                                 + (healthImport.status.vo2max.map { ", VO₂ max \(String(format: "%.1f", $0))" } ?? "")
                                 + " · read \(Self.when.string(from: at))")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if let e = healthImport.status.error {
                        Label(e, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Theme.alert)
                    }
                } header: {
                    Text("Apple Watch and other apps")
                } footer: {
                    Text("Workouts and the measured VO₂ max from your Apple Watch or another app show in the app and count for your activity. What Open Oura wrote to Health itself is left out.")
                }

                Section {
                    Toggle("Send data to my hub", isOn: $hub.enabled)
                    if hub.enabled {
                        TextField("Hub URL (https://…)", text: $hub.url)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Token", text: $hubToken)
                            .onChange(of: hubToken) { _, value in hub.setToken(value) }
                            .onReceive(hub.$hasToken) { _ in hubToken = HubSettings.token ?? "" }
                        Toggle("Include Apple Health data (Watch)", isOn: Binding(
                            get: { healthRead.enabled },
                            set: { on in Task { await healthRead.setEnabled(on) } }
                        ))
                        Button { hub.pushNow() } label: {
                            HStack {
                                Label(hub.status.running ? "Sending…" : "Send Now", systemImage: "icloud.and.arrow.up")
                                Spacer()
                                if hub.status.running { ProgressView() }
                            }
                        }
                        .disabled(hub.status.running || !hub.isConfigured)
                        Button { hub.sendAllRingDataAgain() } label: { Label("Send All Ring Data Again", systemImage: "arrow.counterclockwise") }
                            .disabled(hub.status.running || !hub.isConfigured)
                        Text(hubStatusLine).font(.footnote).foregroundStyle(hub.status.lastError == nil ? Color.secondary : Theme.alert)
                    }
                } header: {
                    Text("Health hub")
                } footer: {
                    Text("To connect, open your hub in a browser, go to Connect, and scan the QR code with the Camera app. After each sync the app sends the summary and every new ring event to your own server (oura-hub). With Apple Health on, it also sends the samples other apps and your Apple Watch wrote (never its own export). An agent can read your status, and the data is backed up, while this iPhone is off. The token is kept in the Keychain.")
                }
                DataToolsSection(onChanged: onSaved)
            }
            .fullScreenCover(isPresented: $showPairing) { PairingView(onPaired: { _ in }) }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try ProfileStore.save(profile)
                            onSaved()
                            dismiss()
                        } catch { message = "Could not save: \(error.localizedDescription)" }
                    }
                }
            }
        }
    }
}

