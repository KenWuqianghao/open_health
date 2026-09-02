import SwiftUI
import HealthKit

private struct EditableProfile {
    var sex: String
    var age: Double
    var heightCm: Double
    var weightKg: Double
    var ringSize: Double

    init(_ profile: Profile?) {
        sex = profile?.sex ?? "M"
        age = profile?.age ?? 30
        heightCm = (profile?.height_m ?? 1.78) * 100
        weightKg = profile?.weight_kg ?? 75
        ringSize = profile?.ring_size ?? 10
    }
}

private enum ProfileStore {
    static var url: URL { DB.url.deletingLastPathComponent().appendingPathComponent("profile.json") }

    static func save(_ p: EditableProfile) throws {
        let object: [String: Any] = [
            "sex": p.sex, "age": p.age, "height_m": p.heightCm / 100,
            "weight_kg": p.weightKg, "ring_size": p.ringSize,
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
    @State private var showPairing = false
    @State private var revealKey = false
    @State private var confirmForget = false
    @State private var confirmRemove = false
    @State private var removeMessage: String?
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
        if let e = health.status.lastError { parts.append("error: \(e)") }
        return parts.joined(separator: " · ")
    }

    private func forgetRing() {
        Keychain.deleteKey()
        PairedRingStore.clear()
        RingCentral.shared.disarm()
        dlog("pair", "ring forgotten")
    }

    init(profile: Profile?, onSaved: @escaping () -> Void) {
        _profile = State(initialValue: EditableProfile(profile))
        self.onSaved = onSaved
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
                    TextField("Age", value: $profile.age, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                    TextField("Height (cm)", value: $profile.heightCm, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                    TextField("Weight (kg)", value: $profile.weightKg, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                    TextField("Ring size", value: $profile.ringSize, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                } header: {
                    Text("Your data")
                } footer: {
                    Text("Stored only on this iPhone and used by the cardiovascular and activity calculations.")
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
                    if let message { Text(message).font(.footnote).foregroundStyle(Obs.ink2) }
                }

                Section {
                    if let paired = PairedRingStore.load() {
                        LabeledContent("Serial", value: paired.serial)
                        LabeledContent("Model", value: paired.hardwareId ?? "—")
                        LabeledContent("Firmware", value: paired.firmware ?? "—")
                        LabeledContent("Last sync", value: ring.lastSuccessfulSyncAt.map { Self.when.string(from: $0) } ?? "—")
                        Button("Pair a different ring") { showPairing = true }
                        Button {
                            revealKey.toggle()
                        } label: {
                            Label(revealKey ? "Hide auth key" : "Show auth key", systemImage: "key")
                        }
                        if revealKey, let key = Keychain.loadKey() {
                            Text(key).font(Obs.mono(12)).textSelection(.enabled)
                            Button("Copy key") { UIPasteboard.general.string = key }
                        }
                        Button("Forget ring", role: .destructive) { confirmForget = true }
                            .confirmationDialog("Forget this ring?", isPresented: $confirmForget) {
                                Button("Forget ring", role: .destructive) { forgetRing() }
                            } message: {
                                Text("The key is deleted from this iPhone. Pairing again needs a factory reset of the ring. Synced data and Apple Health samples are kept.")
                            }
                    } else {
                        Button("Pair a ring") { showPairing = true }
                    }
                } header: {
                    Text("Ring")
                } footer: {
                    Text("The auth key was made on this iPhone at pairing time. Copy it to use the same ring with the desktop client (oura --key-file). Losing it means a factory reset.")
                }

                Section {
                    Toggle("Write ring data to Apple Health", isOn: Binding(
                        get: { health.enabled },
                        set: { on in Task { await health.setEnabled(on) } }
                    ))
                    if health.enabled {
                        Toggle("Include resting energy (estimate)", isOn: $health.includeBasal)
                        DisclosureGroup("What is exported") {
                            Text("Sleep: in-bed time, and sleep stages when the on-device models are available.\nHeart rate every minute, resting heart rate, and HRV (SDNN, only when measured).\nBreathing rate and blood oxygen during sleep.\nSteps (estimated from movement), active energy, and resting energy if you turn it on.\nWorkouts when the on-device models detect them.\n\nNot exported: readiness, sleep and activity scores, skin temperature, distance. If the official Oura app also writes to Health, turn one of the two off to avoid duplicates.")
                                .font(.footnote).foregroundStyle(Obs.ink2)
                        }
                        HStack {
                            Text(health.status.running ? (health.status.progress.isEmpty ? "exporting…" : health.status.progress) : "Export now")
                            Spacer()
                            if health.status.running { ProgressView() }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { if !health.status.running { health.schedule(.manual(full: false)) } }
                        Button("Export everything again") { health.schedule(.manual(full: true)) }
                            .disabled(health.status.running)
                        Text(healthStatusLine).font(.footnote).foregroundStyle(health.status.lastError == nil ? Obs.ink2 : Obs.bad)
                        Button("Remove Open Oura data from Health", role: .destructive) { confirmRemove = true }
                            .confirmationDialog("Remove all Open Oura samples from Apple Health?", isPresented: $confirmRemove) {
                                Button("Remove", role: .destructive) {
                                    Task { removeMessage = await health.removeAllExportedData() }
                                }
                            }
                        if let removeMessage { Text(removeMessage).font(.footnote).foregroundStyle(Obs.ink2) }
                    }
                } header: {
                    Text("Apple Health")
                } footer: {
                    Text("Only measured data is written, never scores. Every day is rewritten in place, so re-running never duplicates. Data stays on this iPhone.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Obs.canvas.ignoresSafeArea())
            .fullScreenCover(isPresented: $showPairing) { PairingView(onPaired: { _ in }) }
            .navigationTitle("profile")
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
