import SwiftUI

/// On-device pairing. Four screens: what to do first, the scan list, the probe / pair
/// result, and the first sync. Shown when no ring is paired, and from Settings.
/// Laid out as a short onboarding flow: one idea per screen, a symbol, a title, a
/// line of copy, and the one primary action at the bottom.
struct PairingView: View {
    let onPaired: (SyncReport) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pairing = RingPairing()
    @ObservedObject private var ring = RingSync.shared
    @ScaledMetric(relativeTo: .subheadline) private var stepSize: CGFloat = 26

    var body: some View {
        NavigationStack {
            content
                .animation(Motion.settle, value: pairing.step)
                .animation(Motion.snappy, value: pairing.candidates.map(\.id))
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Pair Ring")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(canDismiss ? "Close" : "Cancel") {
                            if !canDismiss { pairing.cancel() }
                            dismiss()
                        }
                    }
                }
        }
        .interactiveDismissDisabled(!canDismiss)
        .sensoryFeedback(.success, trigger: isPaired)
        .onChange(of: ring.lastReport?.nextCursor) { _, _ in
            if case .paired = pairing.step, let report = ring.lastReport {
                onPaired(report)
            }
        }
    }

    private var isPaired: Bool { if case .paired = pairing.step { return true } else { return false } }

    private var canDismiss: Bool {
        switch pairing.step {
        case .instructions, .choose, .needsReset, .failed, .paired: return true
        default: return false
        }
    }

    @ViewBuilder private var content: some View {
        switch pairing.step {
        case .instructions:
            page {
                hero("circle.circle", tint: Theme.sleep,
                     title: "Pair your ring",
                     text: "A ring accepts a new key only while it is factory-reset. This app makes its own key on this iPhone and keeps it in the Keychain.")
                VStack(alignment: .leading, spacing: 14) {
                    step(1, "Factory-reset the ring. In the official Oura app, remove the ring, then fully close that app. Or use the charger reset described in the docs.")
                    step(2, "Put the ring on its charger next to this iPhone. A reset ring may show no name, or “Oura” plus its serial — both are normal.")
                    step(3, "Turn off Bluetooth on any other phone that has the official Oura app. The ring holds one link at a time.")
                    step(4, "On Ring 3, iOS may show a Bluetooth pairing request. Accept it.")
                }
                .card()
            } footer: {
                PrimaryButton(title: "Scan for Rings", systemImage: "dot.radiowaves.left.and.right") {
                    Task { await pairing.startScan() }
                }
            }

        case .scanning, .choose:
            List {
                Section {
                    if pairing.candidates.isEmpty {
                        if case .scanning = pairing.step {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text(pairing.status.isEmpty ? "Looking for rings…" : pairing.status)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            ContentUnavailableView {
                                Label("No Ring Found", systemImage: "circle.dashed")
                            } description: {
                                Text(pairing.status.isEmpty ? "Is the ring on its charger, and is Bluetooth on?" : pairing.status)
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                    ForEach(pairing.candidates) { cand in
                        Button { Task { await pairing.choose(cand) } } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "circle.circle")
                                    .font(.title2)
                                    .foregroundStyle(Theme.sleep)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(cand.displayName).font(.body.weight(.medium)).foregroundStyle(.primary)
                                    Text("ID …\(cand.id.uuidString.suffix(8))\(cand.serviceMatched ? " · Oura service" : "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                SignalBars(rssi: cand.rssi)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(minHeight: 44)
                        }
                        .accessibilityHint("Connects to this ring")
                    }
                } header: {
                    HStack {
                        Text("Rings in range")
                        if case .scanning = pairing.step, !pairing.candidates.isEmpty {
                            ProgressView().controlSize(.mini)
                        }
                    }
                } footer: {
                    if case .choose = pairing.step, !pairing.candidates.isEmpty, !pairing.status.isEmpty {
                        Text(pairing.status)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .safeAreaInset(edge: .bottom) {
                if case .choose = pairing.step {
                    SecondaryButton(title: "Scan Again", systemImage: "arrow.clockwise") {
                        Task { await pairing.startScan() }
                    }
                    .padding(Theme.gutter)
                    .background(.bar)
                }
            }

        case .probing(let cand):
            busy(title: cand.displayName, status: pairing.status.isEmpty ? "Connecting…" : pairing.status)

        case .needsReset(let why):
            page {
                hero("exclamationmark.arrow.trianglehead.2.clockwise.rotate.90", tint: Theme.caution,
                     title: "Ring needs a reset", text: why)
            } footer: {
                PrimaryButton(title: "Scan Again", systemImage: "arrow.clockwise") {
                    Task { await pairing.startScan() }
                }
            }

        case .ready(let serial, let generation):
            page {
                hero("checkmark.circle", tint: Theme.good,
                     title: "Ready to pair",
                     text: "Pairing installs a new key made on this iPhone, sets the ring clock, and turns on heart-rate and blood-oxygen measurement.")
                VStack(spacing: 10) {
                    StatRow(label: "Serial", value: serial)
                    Divider()
                    StatRow(label: "Model", value: generation)
                    Divider()
                    StatRow(label: "State", value: "Factory reset")
                }
                .card()
            } footer: {
                PrimaryButton(title: "Pair", systemImage: "link") { Task { await pairing.pair() } }
            }

        case .pairing:
            busy(title: "Pairing…", status: pairing.status)

        case .paired(let serial, let battery, let features):
            page {
                hero("checkmark.seal.fill", tint: Theme.good,
                     title: "Paired",
                     text: "The first sync pulls the ring's whole history and can take a while. Keep the app open; if the link drops it reconnects and resumes.")
                VStack(spacing: 10) {
                    StatRow(label: "Serial", value: serial)
                    Divider()
                    StatRow(label: "Battery", value: battery)
                    Divider()
                    StatRow(label: "Features", value: features.isEmpty ? "—" : features)
                }
                .card()
                if ring.busy {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(ring.status.isEmpty ? "Syncing…" : ring.status)
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .card()
                } else if !ring.status.isEmpty {
                    Label(ring.status, systemImage: ring.lastReport != nil ? "checkmark.circle.fill" : "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(ring.lastReport != nil ? Theme.good : .secondary)
                        .card()
                }
            } footer: {
                if !ring.busy {
                    PrimaryButton(title: "Done") { dismiss() }
                }
            }

        case .failed(let why):
            page {
                hero("xmark.octagon.fill", tint: Theme.alert, title: "Pairing failed", text: why)
            } footer: {
                PrimaryButton(title: "Try Again", systemImage: "arrow.clockwise") {
                    Task { await pairing.startScan() }
                }
            }
        }
    }

    // ── building blocks ──────────────────────────────────────────────────────
    private func page<Content: View, Footer: View>(@ViewBuilder _ content: () -> Content,
                                                   @ViewBuilder footer: () -> Footer) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content() }
                .padding(Theme.gutter)
        }
        .safeAreaInset(edge: .bottom) {
            footer()
                .padding(Theme.gutter)
                .background(.bar)
        }
    }

    private func hero(_ symbol: String, tint: Color, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.bounce, value: symbol)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .accessibilityHidden(true)
            Text(title).font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text(text).font(.body).foregroundStyle(.secondary)
        }
    }

    private func busy(title: String, status: String) -> some View {
        VStack(spacing: 16) {
            // radio waves pulsing outward: the phone is talking to the ring
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(Theme.sleep)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing, options: .repeating)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text(title).font(.title2.bold())
            Text(status).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .animation(Motion.snappy, value: status)
        }
        .padding(Theme.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func step(_ n: Int, _ t: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: stepSize, height: stepSize)
                .background(Theme.sleep, in: Circle())
                .accessibilityHidden(true)
            Text(t).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(n). \(t)")
    }
}

/// Signal strength as three bars, like the Wi-Fi glyph in Settings.
private struct SignalBars: View {
    let rssi: Int
    private var level: Int { rssi > -60 ? 3 : (rssi > -75 ? 2 : 1) }
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= level ? Color.primary : Color(.tertiarySystemFill))
                    .frame(width: 4, height: CGFloat(4 + i * 4))
            }
        }
        .accessibilityLabel("Signal \(rssi) dBm")
    }
}
