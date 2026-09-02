import CoreBluetooth
import Foundation
import Security

/// A fresh 16-byte auth key from the platform CSPRNG, as 32 lowercase hex chars.
enum KeyGen {
    static func random16Hex() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// The on-device pairing state machine. A ring accepts a new key only while it is
/// factory-reset, so the flow is: scan → pick → probe (who owns it?) → make a key →
/// save it to the Keychain FIRST → install it on the ring → first sync.
@MainActor
final class RingPairing: ObservableObject {
    enum Step: Equatable {
        case instructions
        case scanning
        case choose
        case probing(RingCandidate)
        case needsReset(String)
        case ready(serial: String, generation: String)
        case pairing
        case paired(serial: String, battery: String, features: String)
        case failed(String)
    }

    @Published private(set) var step: Step = .instructions
    @Published private(set) var candidates: [RingCandidate] = []
    @Published var status = ""

    private var transport: BLETransport?
    private var session: RingSession?
    private var pump: Task<Void, Never>?
    private var chosen: RingCandidate?
    private var probe: ProbeReport?

    func startScan() async {
        step = .scanning
        candidates = []
        status = "looking for rings…"
        await RingCentral.shared.discoverRings(timeout: 25) { [weak self] cand in
            Task { @MainActor in self?.upsert(cand) }
        }
        if step == .scanning {
            step = .choose
            status = candidates.isEmpty ? "no ring found — is it on its charger, and is Bluetooth on?" : ""
        }
    }

    private func upsert(_ cand: RingCandidate) {
        if let i = candidates.firstIndex(where: { $0.id == cand.id }) {
            candidates[i] = cand
        } else {
            candidates.append(cand)
        }
        candidates.sort { $0.rssi > $1.rssi }
        if step == .scanning { step = .choose }
    }

    /// Connect to `cand` and ask the ring who owns it.
    func choose(_ cand: RingCandidate) async {
        RingCentral.shared.stopDiscovery()
        chosen = cand
        step = .probing(cand)
        status = "connecting…"
        let central = RingCentral.shared
        do {
            guard let p = central.pairedPeripheralFor(id: cand.id) else { throw BLEError.notFound }
            try await central.connect(p, timeout: 30)
            let t = central.claim(p, for: .postPair)
            transport = t
            try await t.prepare()
            let s = RingSession(writer: RingWriter(t))
            session = s
            pump = Task { for await frame in t.notifications { s.pushFrame(data: frame) } }
            status = "asking the ring who owns it…"
            let report = try await s.probe(keyHex: Keychain.loadKey())
            probe = report
            let gen = report.generation.map { "Ring \($0)" } ?? "unknown generation"
            dlog("pair", "probe: serial=\(report.serial) hw=\(report.hardwareId ?? "?") ownership=\(report.ownership) state=\(report.authState)")
            switch report.ownership {
            case .factoryReset:
                status = ""
                step = .ready(serial: report.serial, generation: gen)
            case .pairedWithThisKey:
                // The stored key already works (a reinstall): record the ring and sync.
                status = "this ring is already paired with this app"
                finishPairing(serial: report.serial, hardwareId: report.hardwareId, firmware: report.firmware,
                              battery: "—", features: "kept")
            case .ownedElsewhere:
                tearDown()
                step = .needsReset("This ring still holds another key (the official Oura app or another computer). Factory-reset it first: remove the ring in the Oura app and fully close that app, or use the charger reset. Then try again.")
            case .unknown:
                tearDown()
                step = .needsReset("The ring gave an unexpected answer (auth state \(report.authState)). Put it back on the charger and try again; if it keeps happening, factory-reset it.")
            }
        } catch {
            dlog("pair", "probe FAILED: \(error)")
            tearDown()
            step = .failed("Could not talk to the ring: \(error)")
        }
    }

    /// Make a key, save it, install it, enable the core features, start the first sync.
    func pair() async {
        guard let s = session, let t = transport else { return }
        step = .pairing
        let key = KeyGen.random16Hex()
        // The key is saved BEFORE the ring gets it: a crash mid-install must never
        // lose the only copy of a key that is live on the ring.
        Keychain.saveKey(key)
        status = "installing the key…"
        do {
            let progress = SyncProgressBridge { [weak self] stage, _, _ in
                self?.status = Self.stageText(stage)
            }
            let report = try await s.pair(dbPath: DB.url.path, keyHex: key, plan: .core, progress: progress)
            let battery = report.batteryPct.map { "\($0)%" } ?? "—"
            let features = report.features.map { "\($0.feature): \($0.result)" }.joined(separator: ", ")
            dlog("pair", "paired serial=\(report.serial) installed=\(report.keyInstalled) cursorReset=\(report.cursorReset) features=[\(features)]")
            finishPairing(serial: report.serial, hardwareId: report.hardwareId, firmware: report.firmware,
                          battery: battery, features: features)
            _ = t
        } catch {
            dlog("pair", "pair FAILED: \(error)")
            // The key never took: forget it so the next attempt starts clean.
            Keychain.deleteKey()
            tearDown()
            step = .failed("Pairing failed: \(error)")
        }
    }

    private func finishPairing(serial: String, hardwareId: String?, firmware: String?, battery: String, features: String) {
        guard let t = transport else { return }
        PairedRingStore.save(PairedRing(peripheralID: t.peripheral.identifier, serial: serial,
                                        hardwareId: hardwareId, firmware: firmware, pairedAt: Date()))
        pump?.cancel(); pump = nil
        session = nil
        step = .paired(serial: serial, battery: battery, features: features)
        status = "first sync starting…"
        // Hand the live link to the coordinator for the first sync.
        transport = nil
        Task { _ = await SyncCoordinator.shared.sync(trigger: .postPair, reuse: t) }
    }

    func cancel() {
        RingCentral.shared.stopDiscovery()
        tearDown()
        step = .instructions
        status = ""
    }

    private func tearDown() {
        pump?.cancel(); pump = nil
        session = nil
        if let t = transport {
            RingCentral.shared.release(t, policy: .release)
            transport = nil
        }
    }

    private static func stageText(_ stage: String) -> String {
        switch stage {
        case "identify": return "reading the ring's identity…"
        case "probe": return "checking the ring is reset…"
        case "install_key": return "installing the key…"
        case "verify": return "verifying the key…"
        case "time": return "setting the ring clock…"
        case "battery": return "reading the battery…"
        case "features": return "turning on heart rate and blood oxygen…"
        case "store": return "saving…"
        default: return "pairing…"
        }
    }
}

extension RingCentral {
    /// The CBPeripheral for a discovered candidate.
    func pairedPeripheralFor(id: UUID) -> CBPeripheral? {
        retrievePeripheral(id)
    }
}
