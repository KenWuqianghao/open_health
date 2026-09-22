import SwiftUI

/// On-device pairing. Four screens: what to do first, the scan list, the probe / pair
/// result, and the first sync. Shown when no ring is paired, and from Settings.
struct PairingView: View {
    let onPaired: (SyncReport) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pairing = RingPairing()
    @ObservedObject private var ring = RingSync.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Obs.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        content
                    }
                    .padding(24)
                }
            }
            .navigationTitle("pair").navigationBarTitleDisplayMode(.inline)
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
        .onChange(of: ring.lastReport?.nextCursor) { _, _ in
            if case .paired = pairing.step, let report = ring.lastReport {
                onPaired(report)
            }
        }
    }

    private var canDismiss: Bool {
        switch pairing.step {
        case .instructions, .choose, .needsReset, .failed, .paired: return true
        default: return false
        }
    }

    @ViewBuilder private var content: some View {
        switch pairing.step {
        case .instructions:
            Text("Pair your ring").font(Obs.serif(24)).foregroundStyle(Obs.ink)
            para("A ring accepts a new key only while it is factory-reset. This app makes its own key on this iPhone and keeps it in the Keychain.")
            step(1, "Factory-reset the ring. In the official Oura app, remove the ring, then fully close that app. Or use the charger reset described in the docs.")
            step(2, "Put the ring on its charger next to this iPhone. A reset ring may show no name, or “Oura” plus its serial — both are normal.")
            step(3, "Turn off Bluetooth on any other phone that has the official Oura app. The ring holds one link at a time.")
            step(4, "On Ring 3, iOS may show a Bluetooth pairing request. Accept it.")
            primary("Scan for rings") { Task { await pairing.startScan() } }
        case .scanning, .choose:
            Text("Rings in range").font(Obs.serif(24)).foregroundStyle(Obs.ink)
            if case .scanning = pairing.step {
                HStack(spacing: 8) { ProgressView().tint(Obs.ink); Text(pairing.status).font(Obs.mono(12)).foregroundStyle(Obs.ink2) }
            } else if !pairing.status.isEmpty {
                Text(pairing.status).font(Obs.mono(12)).foregroundStyle(Obs.ink2).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(pairing.candidates) { cand in
                Button { Task { await pairing.choose(cand) } } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(cand.displayName).font(Obs.mono(13, .medium)).foregroundStyle(Obs.ink)
                            Text("id …\(cand.id.uuidString.suffix(8))\(cand.serviceMatched ? " · Oura service" : "")")
                                .font(Obs.mono(10)).foregroundStyle(Obs.ink2)
                        }
                        Spacer()
                        Text("\(cand.rssi) dBm").font(Obs.mono(11)).foregroundStyle(Obs.ink2)
                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Obs.trace)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .obsCard()
            }
            if case .choose = pairing.step {
                secondary("Scan again") { Task { await pairing.startScan() } }
            }
        case .probing(let cand):
            Text(cand.displayName).font(Obs.serif(24)).foregroundStyle(Obs.ink)
            HStack(spacing: 8) { ProgressView().tint(Obs.ink); Text(pairing.status).font(Obs.mono(12)).foregroundStyle(Obs.ink2) }
        case .needsReset(let why):
            Text("Reset needed").font(Obs.serif(24)).foregroundStyle(Obs.ink)
            para(why)
            primary("Scan again") { Task { await pairing.startScan() } }
        case .ready(let serial, let generation):
            Text("Ready to pair").font(Obs.serif(24)).foregroundStyle(Obs.ink)
            VStack(spacing: 12) {
                ObsStat(label: "serial", value: serial)
                ObsStat(label: "model", value: generation)
                ObsStat(label: "state", value: "factory reset")
            }
            .obsCard()
            para("Pairing installs a new key made on this iPhone, sets the ring clock, and turns on heart-rate and blood-oxygen measurement.")
            primary("Pair") { Task { await pairing.pair() } }
        case .pairing:
            Text("Pairing…").font(Obs.serif(24)).foregroundStyle(Obs.ink)
            HStack(spacing: 8) { ProgressView().tint(Obs.ink); Text(pairing.status).font(Obs.mono(12)).foregroundStyle(Obs.ink2) }
        case .paired(let serial, let battery, let features):
            Text("Paired").font(Obs.serif(24)).foregroundStyle(Obs.ink)
            VStack(spacing: 12) {
                ObsStat(label: "serial", value: serial)
                ObsStat(label: "battery", value: battery)
                ObsStat(label: "features", value: features.isEmpty ? "—" : features)
            }
            .obsCard()
            para("The first sync pulls the ring's whole history and can take a while. Keep the app open; if the link drops it reconnects and resumes.")
            if ring.busy {
                HStack(spacing: 8) { ProgressView().tint(Obs.ink); Text(ring.status).font(Obs.mono(12)).foregroundStyle(Obs.ink2) }
            } else if !ring.status.isEmpty {
                Text(ring.status).font(Obs.mono(12)).foregroundStyle(ring.lastReport != nil ? Obs.good : Obs.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !ring.busy {
                primary("Done") { dismiss() }
            }
        case .failed(let why):
            Text("Pairing failed").font(Obs.serif(24)).foregroundStyle(Obs.ink)
            para(why)
            primary("Try again") { Task { await pairing.startScan() } }
        }
    }

    private func para(_ t: String) -> some View {
        Text(t).font(Obs.mono(12)).foregroundStyle(Obs.ink2).fixedSize(horizontal: false, vertical: true)
    }

    private func step(_ n: Int, _ t: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(Obs.mono(12, .bold)).foregroundStyle(Obs.ink)
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(Obs.trace, lineWidth: 0.8))
            Text(t).font(Obs.mono(12)).foregroundStyle(Obs.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Obs.mono(13, .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Obs.ink).foregroundStyle(Obs.paper)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Obs.mono(12, .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Obs.trace, lineWidth: 0.8))
        }
        .foregroundStyle(Obs.ink)
    }
}
