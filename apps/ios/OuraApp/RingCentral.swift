import CoreBluetooth
import Foundation

// The ONE CBCentralManager of the app, created at launch with a restore identifier.
//
// Every BLE path — the foreground sync, the pairing scan, the background "arm" that
// makes iOS relaunch the app when the ring reconnects, and the restore wake itself —
// goes through this object. Two centrals connecting the same ring would each hold
// a CBPeripheral for one physical link and fight over it; one central and one
// ownership state machine (`free → armed → owned → parked`) cannot.
//
// The per-link GATT work (service discovery, subscriptions, writes, the inbound
// frame stream) lives in `BLETransport`, which this central hands out via `claim`.

struct RingCandidate: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String?
    var rssi: Int
    var serviceMatched: Bool
    let firstSeen: Date

    /// A factory-reset ring advertises no local name. Say so instead of hiding it.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return "Oura ring (no name)"
    }
}

/// How to look for the ring.
enum ScanMode {
    /// Unfiltered scan with duplicate reports: counts other devices as proof the
    /// radio works, and catches a worn ring's lazy scan-response name.
    case foreground
    /// Service-filtered scan. iOS ignores nil-service scans in the background.
    case background
}

final class RingCentral: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    static let shared = RingCentral()
    static let restoreIdentifier = "md.thomas.openoura.ring-central"

    /// CoreBluetooth needs a SERIAL queue for delegate callbacks.
    let queue = DispatchQueue(label: "md.thomas.openoura.ble", qos: .userInitiated)
    private var central: CBCentralManager!
    private let lock = NSLock()

    enum Ownership {
        case free
        /// A pending `connect` with no timeout: iOS wakes the app on connection.
        case armed(CBPeripheral)
        /// A sync holds the link.
        case owned(SyncTrigger, BLETransport)
        /// The link is kept after a sync (`LinkPolicy.park`); nobody drives it.
        case parked(CBPeripheral)
    }
    private(set) var ownership: Ownership = .free

    private var connectCont: CheckedContinuation<CBPeripheral, Error>?
    private var connectTarget: UUID?
    private var connectTimer: DispatchWorkItem?
    private var scanCont: CheckedContinuation<CBPeripheral, Error>?
    private var scanTimer: DispatchWorkItem?
    private var scanStage = ""
    private var discoverHandler: ((RingCandidate) -> Void)?
    private var discoverTimer: DispatchWorkItem?
    private var candidates: [UUID: RingCandidate] = [:]
    private var loggedAds = Set<String>()
    private var otherDevices = Set<UUID>()
    private var powerWaiters: [CheckedContinuation<Void, Error>] = []
    private var holdOffUntil = Date.distantPast
    private var parkedWakeTimer: DispatchWorkItem?

    /// Set by the sync coordinator: a connection that nobody asked for right now
    /// (the armed connect fired, a restored session, a parked ring spoke).
    var onUnsolicitedConnect: ((CBPeripheral) -> Void)?
    var onStateChange: ((CBManagerState) -> Void)?

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue, options: [
            CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
            CBCentralManagerOptionShowPowerAlertKey: false,
        ])
    }

    var state: CBManagerState { central.state }

    var ownsLink: Bool {
        lock.lock(); defer { lock.unlock() }
        if case .owned = ownership { return true }
        return false
    }

    var parkedPeripheral: CBPeripheral? {
        lock.lock(); defer { lock.unlock() }
        if case .parked(let p) = ownership { return p }
        return nil
    }

    static func name(of state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "poweredOn"
        case .poweredOff: return "poweredOff"
        case .unauthorized: return "unauthorized (check Settings > Privacy > Bluetooth)"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        case .unknown: return "unknown (still initializing)"
        @unknown default: return "state \(state.rawValue)"
        }
    }

    // ── power ──

    func waitPoweredOn(timeout: TimeInterval = 5) async throws {
        switch central.state {
        case .poweredOn: return
        case .poweredOff, .unauthorized, .unsupported: throw BLEError.poweredOff
        default: break
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            powerWaiters.append(c)
            lock.unlock()
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let waiters = self.powerWaiters
                self.powerWaiters.removeAll()
                self.lock.unlock()
                for w in waiters { w.resume(throwing: BLEError.timedOut(stage: "waiting for Bluetooth to power on")) }
            }
        }
    }

    // ── lookups ──

    /// The paired ring's CBPeripheral, if iOS still knows it.
    func pairedPeripheral() -> CBPeripheral? {
        guard let id = PairedRingStore.load()?.peripheralID, central.state == .poweredOn else { return nil }
        return central.retrievePeripherals(withIdentifiers: [id]).first
    }

    /// Any peripheral iOS knows by identifier (a discovered candidate, the paired ring).
    func retrievePeripheral(_ id: UUID) -> CBPeripheral? {
        guard central.state == .poweredOn else { return nil }
        return central.retrievePeripherals(withIdentifiers: [id]).first
    }

    /// A ring some OTHER app on this phone is connected to right now.
    func systemConnectedRing() -> CBPeripheral? {
        guard central.state == .poweredOn else { return nil }
        let ours = pairedPeripheral()?.identifier
        return central.retrieveConnectedPeripherals(withServices: [RingUUID.service])
            .first { $0.identifier != ours || !ownsLink }
    }

    // ── discovery (pairing list) ──

    /// Scan for every ring in range and report each one (updated as RSSI/name arrive).
    /// Never connects. Returns after `timeout` or `stopDiscovery()`.
    func discoverRings(timeout: TimeInterval, onCandidate: @escaping @Sendable (RingCandidate) -> Void) async {
        do { try await waitPoweredOn() } catch {
            dlog("scan", "discovery skipped: \(error)")
            return
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            lock.lock()
            candidates = [:]
            loggedAds = []
            otherDevices = []
            discoverHandler = onCandidate
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.central.stopScan()
                self.lock.lock()
                self.discoverHandler = nil
                self.discoverTimer = nil
                self.lock.unlock()
                dlog("scan", "discovery finished — \(self.candidates.count) ring(s) seen")
                done.resume()
            }
            discoverTimer = work
            lock.unlock()
            dlog("scan", "discovering rings for \(Int(timeout)) s (unfiltered, allow duplicates)")
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            queue.asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    func stopDiscovery() {
        lock.lock()
        let timer = discoverTimer
        lock.unlock()
        if let timer {
            queue.async { timer.perform() }
            timer.cancel()
        }
    }

    // ── scan for the first ring ──

    /// Scan until the first ring appears and hand back its peripheral (not yet
    /// connected). `mode` decides the scan shape; background scans MUST filter.
    func scanForRing(timeout: TimeInterval, mode: ScanMode) async throws -> CBPeripheral {
        try await waitPoweredOn()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<CBPeripheral, Error>) in
            lock.lock()
            if scanCont != nil {
                lock.unlock()
                c.resume(throwing: BLEError.busy)
                return
            }
            scanCont = c
            scanStage = "scanning — no ring advertisement seen yet"
            loggedAds = []
            otherDevices = []
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.central.stopScan()
                self.lock.lock()
                var at = self.scanStage
                let others = self.otherDevices.count
                self.lock.unlock()
                if mode == .foreground {
                    at = others > 0
                        ? "scanning — saw \(others) other BLE device(s) but no Oura ring: "
                            + "the ring is connected to another device (phone with the "
                            + "official app? Mac?), off its charger and asleep, or out of battery"
                        : "scanning — saw NO BLE advertisements at all: Bluetooth may be "
                            + "off, restricted, or the permission was revoked"
                } else {
                    at = "scanning (background, service-filtered) — the ring did not advertise"
                }
                dlog("ble", "TIMEOUT while \(at)")
                self.finishScan(.failure(BLEError.timedOut(stage: at)))
            }
            scanTimer = work
            lock.unlock()
            switch mode {
            case .foreground:
                dlog("ble", "scanning (unfiltered, allow duplicates) — matching service \(RingUUID.service)")
                central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            case .background:
                dlog("ble", "scanning (service-filtered) for \(RingUUID.service)")
                central.scanForPeripherals(withServices: [RingUUID.service], options: nil)
            }
            queue.asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    private func finishScan(_ result: Result<CBPeripheral, Error>) {
        lock.lock()
        let c = scanCont; scanCont = nil
        let timer = scanTimer; scanTimer = nil
        lock.unlock()
        timer?.cancel()
        c?.resume(with: result)
    }

    // ── connect ──

    /// GATT-connect `peripheral`. `timeout == nil` means a pending connect that never
    /// expires (the "arm"); the continuation resolves whenever iOS connects, even
    /// after a background relaunch. An already-connected peripheral returns at once.
    func connect(_ peripheral: CBPeripheral, timeout: TimeInterval?) async throws {
        try await waitPoweredOn()
        if peripheral.state == .connected { return }
        _ = try await withCheckedThrowingContinuation { (c: CheckedContinuation<CBPeripheral, Error>) in
            lock.lock()
            if connectCont != nil {
                lock.unlock()
                c.resume(throwing: BLEError.busy)
                return
            }
            connectCont = c
            connectTarget = peripheral.identifier
            if let timeout {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    dlog("ble", "TIMEOUT while GATT-connecting")
                    self.central.cancelPeripheralConnection(peripheral)
                    self.finishConnect(peripheral, .failure(BLEError.timedOut(stage: "GATT-connecting to the ring")))
                }
                connectTimer = work
                queue.asyncAfter(deadline: .now() + timeout, execute: work)
            }
            lock.unlock()
            dlog("ble", "GATT connect… id=\(peripheral.identifier.uuidString.suffix(12)) state=\(peripheral.state.rawValue)")
            central.connect(peripheral, options: nil)
        }
    }

    /// Fail whatever connect or scan is in flight (deadline / user cancel).
    func cancelInFlight() {
        lock.lock()
        let target = connectTarget
        lock.unlock()
        if let target, let p = central.retrievePeripherals(withIdentifiers: [target]).first {
            central.cancelPeripheralConnection(p)
            finishConnect(p, .failure(BLEError.disconnected))
        }
        central.stopScan()
        finishScan(.failure(BLEError.disconnected))
    }

    private func finishConnect(_ peripheral: CBPeripheral, _ result: Result<CBPeripheral, Error>) {
        lock.lock()
        guard connectTarget == peripheral.identifier else { lock.unlock(); return }
        let c = connectCont; connectCont = nil
        connectTarget = nil
        let timer = connectTimer; connectTimer = nil
        lock.unlock()
        timer?.cancel()
        c?.resume(with: result)
    }

    // ── ownership ──

    /// Hold a pending connect to the paired ring so iOS relaunches the app when the
    /// ring comes back. No-op unless the app is idle, paired, and powered on.
    func arm() {
        guard central.state == .poweredOn, let p = pairedPeripheral() else { return }
        lock.lock()
        guard case .free = ownership else { lock.unlock(); return }
        if Date() < holdOffUntil {
            lock.unlock()
            dlog("ble", "arm skipped — reconnect hold-off until \(holdOffUntil)")
            return
        }
        ownership = .armed(p)
        lock.unlock()
        p.delegate = self
        if p.state == .connected {
            dlog("ble", "arm: ring already connected — parking it")
            park(p)
            return
        }
        dlog("ble", "armed — pending connect to \(p.identifier.uuidString.suffix(12)) (iOS wakes us when it connects)")
        central.connect(p, options: nil)
    }

    func disarm() {
        lock.lock()
        let peripheral: CBPeripheral?
        switch ownership {
        case .armed(let p), .parked(let p): peripheral = p
        default: peripheral = nil
        }
        if peripheral != nil { ownership = .free }
        lock.unlock()
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
            dlog("ble", "disarmed")
        }
    }

    /// Take the link for a sync. The peripheral must be connected (or connecting via
    /// a pending arm that just fired).
    func claim(_ peripheral: CBPeripheral, for trigger: SyncTrigger) -> BLETransport {
        let t = BLETransport(central: self, peripheral: peripheral)
        lock.lock()
        ownership = .owned(trigger, t)
        parkedWakeTimer?.cancel(); parkedWakeTimer = nil
        lock.unlock()
        peripheral.delegate = t
        return t
    }

    /// Give the link back after a sync, then arm (or park) for the next wake.
    /// `holdOff` blocks a re-arm for a while: a ring on its charger reconnects the
    /// moment we drop it, and a wake that found nothing must not loop.
    func release(_ transport: BLETransport, policy: LinkPolicy, holdOff: TimeInterval = 0) {
        let p = transport.peripheral
        lock.lock()
        if case .owned(_, let t) = ownership, t === transport { ownership = .free }
        holdOffUntil = holdOff > 0 ? Date().addingTimeInterval(holdOff) : .distantPast
        lock.unlock()
        transport.detach()
        switch policy {
        case .park where p.state == .connected:
            park(p)
        default:
            central.cancelPeripheralConnection(p)
            dlog("ble", "disconnected — ring link released (\(policy.rawValue))")
            arm()
        }
    }

    private func park(_ p: CBPeripheral) {
        lock.lock()
        ownership = .parked(p)
        lock.unlock()
        p.delegate = self
        dlog("ble", "parked — link kept, nothing pending")
    }

    // ── CBCentralManagerDelegate ──

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        dlog("ble", "central state → \(Self.name(of: central.state))")
        onStateChange?(central.state)
        switch central.state {
        case .poweredOn:
            lock.lock()
            let waiters = powerWaiters; powerWaiters.removeAll()
            lock.unlock()
            for w in waiters { w.resume() }
            arm()
        case .poweredOff, .unauthorized, .unsupported:
            lock.lock()
            let waiters = powerWaiters; powerWaiters.removeAll()
            let owned: BLETransport?
            if case .owned(_, let t) = ownership { owned = t } else { owned = nil }
            // Peripheral objects are invalid after a Bluetooth reset.
            ownership = .free
            lock.unlock()
            for w in waiters { w.resume(throwing: BLEError.poweredOff) }
            owned?.linkDidDrop(error: BLEError.poweredOff)
            finishScan(.failure(BLEError.poweredOff))
            lock.lock(); let target = connectTarget; lock.unlock()
            if let target, let p = central.retrievePeripherals(withIdentifiers: [target]).first {
                finishConnect(p, .failure(BLEError.poweredOff))
            }
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        dlog("ble", "willRestoreState — \(peripherals.count) peripheral(s)")
        for p in peripherals {
            p.delegate = self
            switch p.state {
            case .connected:
                dlog("ble", "restored CONNECTED \(p.identifier.uuidString.suffix(12)) — waking the sync")
                lock.lock(); ownership = .parked(p); lock.unlock()
                onUnsolicitedConnect?(p)
            case .connecting:
                dlog("ble", "restored pending connect \(p.identifier.uuidString.suffix(12))")
                lock.lock(); ownership = .armed(p); lock.unlock()
            default:
                dlog("ble", "restored peripheral in state \(p.state.rawValue)")
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        var advServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        advServices += advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        let lowerName = advName.lowercased()
        let isChargingCase = lowerName.contains("charging case") || advServices.contains(RingUUID.chargingCaseService)
        if isChargingCase {
            if loggedAds.insert("\(peripheral.identifier.uuidString)|case").inserted {
                dlog("scan", "saw charging case '\(advName.isEmpty ? "<no name>" : advName)' rssi=\(RSSI) — waiting for the ring")
            }
            return
        }
        // A ring advertises the Oura service UUID; a factory-reset ring has NO name.
        let serviceMatched = advServices.contains(RingUUID.service)
        let isRing = serviceMatched || lowerName.contains("oura")
        lock.lock()
        let handler = discoverHandler
        let waitingForFirst = scanCont != nil
        lock.unlock()
        if !isRing {
            lock.lock()
            let inserted = otherDevices.insert(peripheral.identifier).inserted
            let count = otherDevices.count
            lock.unlock()
            if inserted && count <= 5 && (handler != nil || waitingForFirst) {
                dlog("scan", "other device '\(advName.isEmpty ? "<no name>" : advName)' rssi=\(RSSI) — not a ring (\(count) distinct so far)")
            }
            return
        }
        if loggedAds.insert("\(peripheral.identifier.uuidString)|\(advName)").inserted {
            let svc = advServices.map(\.uuidString).joined(separator: ",")
            let mfr = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.hexString ?? "—"
            dlog("scan", "saw '\(advName.isEmpty ? "<no name>" : advName)' id=\(peripheral.identifier.uuidString.suffix(12)) rssi=\(RSSI) services=[\(svc)] mfr=\(mfr)")
        }
        if let handler {
            lock.lock()
            var cand = candidates[peripheral.identifier] ?? RingCandidate(
                id: peripheral.identifier, name: nil, rssi: RSSI.intValue, serviceMatched: false, firstSeen: Date())
            if !advName.isEmpty { cand.name = advName }
            cand.rssi = RSSI.intValue
            cand.serviceMatched = cand.serviceMatched || serviceMatched
            candidates[peripheral.identifier] = cand
            lock.unlock()
            handler(cand)
        }
        if waitingForFirst {
            central.stopScan()
            dlog("ble", "matched '\(advName.isEmpty ? "<no name>" : advName)' rssi=\(RSSI)")
            finishScan(.success(peripheral))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let mtu = peripheral.maximumWriteValueLength(for: .withResponse)
        dlog("ble", "GATT connected \(peripheral.identifier.uuidString.suffix(12)) (maxWrite=\(mtu)B)")
        lock.lock()
        let awaited = connectTarget == peripheral.identifier
        let armed: Bool
        if case .armed(let p) = ownership, p.identifier == peripheral.identifier { armed = true } else { armed = false }
        lock.unlock()
        if awaited {
            finishConnect(peripheral, .success(peripheral))
            return
        }
        if armed {
            dlog("ble", "armed connect fired — waking the sync")
            lock.lock(); ownership = .parked(peripheral); lock.unlock()
            onUnsolicitedConnect?(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        dlog("ble", "GATT connect FAILED: \(error.map { String(describing: $0) } ?? "no error info")")
        finishConnect(peripheral, .failure(error ?? BLEError.notFound))
        lock.lock()
        if case .armed(let p) = ownership, p.identifier == peripheral.identifier { ownership = .free }
        lock.unlock()
        // An armed connect that fails is re-armed by the next state change / sync.
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        dlog("ble", "peripheral disconnected: \(error.map { String(describing: $0) } ?? "clean")\(isReconnecting ? " (iOS reconnecting)" : "")")
        lock.lock()
        var owned: BLETransport?
        switch ownership {
        case .owned(_, let t) where t.peripheral.identifier == peripheral.identifier:
            owned = t
            ownership = .free
        case .parked(let p) where p.identifier == peripheral.identifier:
            ownership = .free
        default:
            break
        }
        lock.unlock()
        owned?.linkDidDrop(error: error ?? BLEError.disconnected)
        finishConnect(peripheral, .failure(BLEError.disconnected))
        if !isReconnecting { arm() }
    }

    // ── CBPeripheralDelegate while parked / armed (nobody else listens) ──

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // A parked ring spoke (an event subscription pushed data): treat it as a
        // connection event, debounced, so a chatty ring does not start a sync per frame.
        lock.lock()
        guard case .parked = ownership, parkedWakeTimer == nil else { lock.unlock(); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.parkedWakeTimer = nil; self.lock.unlock()
            dlog("ble", "parked ring sent data — waking the sync")
            self.onUnsolicitedConnect?(peripheral)
        }
        parkedWakeTimer = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 30, execute: work)
    }
}
