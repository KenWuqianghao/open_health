import CoreBluetooth
import Foundation

// One GATT link to a ring: service discovery, notify subscriptions, sequential
// writes, and the merged inbound frame stream Rust drains. The iOS counterpart to
// `oura-link::ble` (btleplug), conforming to the same shape as the Rust `Transport`
// trait. The auth handshake + sync drain stay in Rust (oura-link `OuraClient`).
//
// Scanning, connecting, and the app-wide ownership of the link live in
// `RingCentral` (the ONE CBCentralManager). A transport is created by
// `RingCentral.claim` for a peripheral that is already connected, and handed back
// with `RingCentral.release`.

enum RingUUID {
    static let service = CBUUID(string: "98ED0001-A541-11E4-B6A0-0002A5D5C51B")
    static let chargingCaseService = CBUUID(string: "8BC5888F-C577-4F5D-857F-377354093F13")
    static let write = CBUUID(string: "98ED0002-A541-11E4-B6A0-0002A5D5C51B")
    // notify/indicate chars: gen-4 uses …0003; Ring 5 adds …0004/0005/0006.
    static let notify: Set<String> = [
        "98ED0003-A541-11E4-B6A0-0002A5D5C51B",
        "98ED0004-A541-11E4-B6A0-0002A5D5C51B",
        "98ED0005-A541-11E4-B6A0-0002A5D5C51B",
        "98ED0006-A541-11E4-B6A0-0002A5D5C51B",
    ]
}

/// The contract Rust drives over FFI: write a frame; observe inbound frames.
protocol RingTransport: AnyObject {
    func write(_ data: Data) async throws
    /// Every notify/indicate characteristic merged into one stream of raw frames.
    var notifications: AsyncStream<Data> { get }
}

enum BLEError: Error, CustomStringConvertible {
    case poweredOff, notFound, noWriteCharacteristic, disconnected, busy, notConnected
    /// carries the stage the attempt was in, so "timed out" says *what* never happened.
    case timedOut(stage: String)

    var description: String {
        switch self {
        case .poweredOff: return "Bluetooth is off or not authorized"
        case .notFound: return "ring service/characteristics not found"
        case .noWriteCharacteristic: return "no write characteristic (98ED0002)"
        case .disconnected: return "ring disconnected"
        case .busy: return "another BLE operation is in flight"
        case .notConnected: return "the ring is not connected"
        case .timedOut(let stage): return "timed out while \(stage)"
        }
    }
}

// @unchecked Sendable: continuations are taken/resumed under `lock`, and the rest of
// the mutable CB state is only touched on the central's serial callback queue.
final class BLETransport: NSObject, RingTransport, CBPeripheralDelegate, @unchecked Sendable {
    let peripheral: CBPeripheral
    private weak var central: RingCentral?
    private var writeChar: CBCharacteristic?

    private var notifyContinuation: AsyncStream<Data>.Continuation?
    // recreated per prepare() so a reused link gets a fresh, live stream.
    private(set) var notifications: AsyncStream<Data> = AsyncStream { _ in }

    // Ring 5 history arrives as thousands of tiny CoreBluetooth notifications. Passing
    // every one through AsyncStream + UniFFI separately (and hex-logging it) costs more
    // than parsing it. Coalesce only history payload packets; command replies and the
    // terminal batch summary remain immediate. Rust's Packet::parse_many already
    // accepts concatenated packets, so this does not change protocol semantics.
    private var historyBuffer = Data()
    private var historyFrames = 0
    private var historyBytes = 0
    private static let historyFlushBytes = 32 * 1024

    private var prepareCont: CheckedContinuation<Void, Error>?
    private var prepareTimer: DispatchWorkItem?
    private var writeCont: CheckedContinuation<Void, Error>?
    private var pendingNotify = 0
    private var stage = "discovering services/characteristics"
    private let lock = NSLock()

    init(central: RingCentral, peripheral: CBPeripheral) {
        self.central = central
        self.peripheral = peripheral
        super.init()
    }

    /// True when a previous session already discovered the service and subscribed
    /// every notify characteristic (a parked link).
    private var alreadySubscribed: Bool {
        guard let svc = peripheral.services?.first(where: { $0.uuid == RingUUID.service }),
              let chars = svc.characteristics else { return false }
        let notify = chars.filter { RingUUID.notify.contains($0.uuid.uuidString.uppercased()) }
        guard let w = chars.first(where: { $0.uuid == RingUUID.write }), !notify.isEmpty,
              notify.allSatisfy(\.isNotifying) else { return false }
        writeChar = w
        return true
    }

    /// Discover the Oura service and subscribe to every notify characteristic. The
    /// peripheral must already be connected. Resolves once the write characteristic
    /// is ready and every subscription is confirmed.
    func prepare(timeout: TimeInterval = 15) async throws {
        guard peripheral.state == .connected else { throw BLEError.notConnected }
        peripheral.delegate = self
        historyBuffer.removeAll(keepingCapacity: true)
        historyFrames = 0
        historyBytes = 0
        notifications = AsyncStream { self.notifyContinuation = $0 }
        if alreadySubscribed {
            dlog("ble", "link reused — service + subscriptions already in place")
            return
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            if prepareCont != nil {
                lock.unlock()
                c.resume(throwing: BLEError.busy)
                return
            }
            prepareCont = c
            stage = "discovering services/characteristics"
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock(); let at = self.stage; self.lock.unlock()
                dlog("ble", "TIMEOUT while \(at)")
                self.finishPrepare(.failure(BLEError.timedOut(stage: at)))
            }
            prepareTimer = work
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
            dlog("ble", "discovering the Oura service")
            peripheral.discoverServices([RingUUID.service])
        }
    }

    /// Finish the inbound frame stream so a Rust drain blocked on `recv` returns at once
    /// (instead of waiting out the quiet-window) — used when a write fails so the sync
    /// surfaces the error promptly rather than proceeding as if the frame was sent.
    func abort() { notifyContinuation?.finish() }

    /// The central took the link back: stop listening, finish the stream.
    func detach() {
        notifyContinuation?.finish()
        finishWrite(.failure(BLEError.disconnected))
        finishPrepare(.failure(BLEError.disconnected))
        if peripheral.delegate === self { peripheral.delegate = nil }
    }

    /// Called by `RingCentral` when the physical link dropped.
    func linkDidDrop(error: Error?) {
        dlog("ble", "link dropped: \(error.map { String(describing: $0) } ?? "clean")")
        notifyContinuation?.finish()
        finishWrite(.failure(BLEError.disconnected))
        finishPrepare(.failure(BLEError.disconnected))
    }

    /// Write a request frame and await the ring's GATT acknowledgement, so the caller
    /// (Rust `OuraClient`, which drives requests sequentially) knows the frame landed
    /// before sending the next. Resolved in `didWriteValueFor`.
    func write(_ data: Data) async throws {
        guard peripheral.state == .connected else { throw BLEError.disconnected }
        guard let wc = writeChar else { throw BLEError.noWriteCharacteristic }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            if writeCont != nil {
                lock.unlock()
                c.resume(throwing: BLEError.busy)
                return
            }
            writeCont = c
            lock.unlock()
            dlog("send", "\(data.count)B \(data.hexString)")
            peripheral.writeValue(data, for: wc, type: .withResponse)
        }
    }

    // ── CBPeripheralDelegate ──

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            dlog("ble", "service discovery FAILED: \(error)")
            return finishPrepare(.failure(error))
        }
        let found = (peripheral.services ?? []).map(\.uuid.uuidString).joined(separator: ",")
        dlog("ble", "services: [\(found)]")
        guard let svc = peripheral.services?.first(where: { $0.uuid == RingUUID.service }) else {
            dlog("ble", "Oura service 98ED0001 NOT among them — wrong device?")
            return finishPrepare(.failure(BLEError.notFound))
        }
        peripheral.discoverCharacteristics(nil, for: svc)
    }

    private static func props(_ c: CBCharacteristic) -> String {
        var p: [String] = []
        if c.properties.contains(.read) { p.append("read") }
        if c.properties.contains(.write) { p.append("write") }
        if c.properties.contains(.writeWithoutResponse) { p.append("writeNR") }
        if c.properties.contains(.notify) { p.append("notify") }
        if c.properties.contains(.indicate) { p.append("indicate") }
        return p.joined(separator: "+")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            dlog("ble", "characteristic discovery FAILED: \(error)")
            return finishPrepare(.failure(error))
        }
        var notifyChars: [CBCharacteristic] = []
        for c in service.characteristics ?? [] {
            dlog("ble", "char …\(c.uuid.uuidString.suffix(4).lowercased()) [\(Self.props(c))]")
            if c.uuid == RingUUID.write { writeChar = c }
            if RingUUID.notify.contains(c.uuid.uuidString.uppercased()) { notifyChars.append(c) }
        }
        dlog("ble", "characteristics discovered — write=\(writeChar != nil), notify=\(notifyChars.count)")
        guard writeChar != nil else {
            dlog("ble", "no write characteristic (98ED0002) — wrong device?")
            return finishPrepare(.failure(BLEError.noWriteCharacteristic))
        }
        guard !notifyChars.isEmpty else {
            dlog("ble", "no notify characteristics (98ED0003..0006)")
            return finishPrepare(.failure(BLEError.notFound))
        }
        // don't report "ready" until every notify subscription is confirmed —
        // otherwise Rust can start before inbound frames flow and miss early responses.
        lock.lock()
        pendingNotify = notifyChars.count
        stage = "subscribing to notify characteristics"
        lock.unlock()
        for c in notifyChars { peripheral.setNotifyValue(true, for: c) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            // a pairing/encryption demand surfaces here (e.g. "Authentication is
            // insufficient") — the single most diagnostic error on a keyed ring.
            dlog("ble", "subscribe FAILED on …\(characteristic.uuid.uuidString.suffix(4).lowercased()): \(error)")
            return finishPrepare(.failure(error))
        }
        dlog("ble", "subscribed …\(characteristic.uuid.uuidString.suffix(4).lowercased())")
        lock.lock(); pendingNotify -= 1; let ready = pendingNotify <= 0; lock.unlock()
        if ready {
            dlog("ble", "all notify subscriptions confirmed — BLE link ready, handing to Rust")
            finishPrepare(.success(()))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // drop the callback on a read/notify error — a stale payload must not be fed
        // into the frame stream Rust drains as protocol responses.
        guard error == nil, let v = characteristic.value else {
            if let error { dlog("ble", "notify ERROR on \(characteristic.uuid): \(error)") }
            return
        }
        if Self.isHistoryPayload(v) {
            historyBuffer.append(v)
            historyFrames += 1
            historyBytes += v.count
            if historyBuffer.count >= Self.historyFlushBytes {
                flushHistoryPayload()
            }
            return
        }
        // A command response / 0x42 batch summary terminates the preceding history
        // burst. Deliver buffered packets first to preserve byte order, then retain one
        // compact diagnostic line instead of tens of thousands of raw payload lines.
        flushHistoryPayload()
        if historyFrames > 0 {
            dlog("recv", "history payload omitted — \(historyFrames) BLE frames, \(historyBytes)B")
            historyFrames = 0
            historyBytes = 0
        }
        dlog("recv", "\(v.count)B [\(characteristic.uuid.uuidString.suffix(4).lowercased())] \(v.hexString)")
        notifyContinuation?.yield(v)
    }

    /// Extended history data is `0x2f … 0x43`; legacy history packets use event
    /// tags >= 0x41. Walk every length-prefixed packet because one BLE notification
    /// can contain several packets. If even one is a summary/control packet, deliver
    /// the notification immediately so a trailing terminator can never sit buffered.
    private static func isHistoryPayload(_ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            guard offset + 2 <= data.count else { return false }
            let tag = data[offset]
            let length = Int(data[offset + 1])
            let end = offset + 2 + length
            guard end <= data.count else { return false }
            let isHistory = tag >= 0x41
                || (tag == 0x2f && length >= 1 && data[offset + 2] == 0x43)
            guard isHistory else { return false }
            offset = end
        }
        return offset > 0
    }

    private func flushHistoryPayload() {
        guard !historyBuffer.isEmpty else { return }
        let payload = historyBuffer
        historyBuffer.removeAll(keepingCapacity: true)
        notifyContinuation?.yield(payload)
    }

    /// GATT write-with-response acknowledgement (or error) for the in-flight `write`.
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { dlog("ble", "write NAK: \(error)") }
        finishWrite(error.map { .failure($0) } ?? .success(()))
    }

    private func finishPrepare(_ result: Result<Void, Error>) {
        lock.lock()
        let c = prepareCont; prepareCont = nil
        let timer = prepareTimer; prepareTimer = nil
        if case .failure = result { pendingNotify = 0 }
        lock.unlock()
        timer?.cancel()
        c?.resume(with: result)
    }

    private func finishWrite(_ result: Result<Void, Error>) {
        lock.lock(); let c = writeCont; writeCont = nil; lock.unlock()
        c?.resume(with: result)
    }
}
