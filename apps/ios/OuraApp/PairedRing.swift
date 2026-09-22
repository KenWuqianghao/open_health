import Foundation

/// The ring this app is paired with. `peripheralID` is CoreBluetooth's per-phone
/// identifier for the ring's `CBPeripheral` — stable across launches on this phone,
/// meaningless on any other. The 16-byte auth key lives in the Keychain, never here.
struct PairedRing: Codable, Equatable, Sendable {
    var peripheralID: UUID
    var serial: String
    var hardwareId: String?
    var firmware: String?
    var pairedAt: Date
}

enum PairedRingStore {
    private static let key = "ring.paired"

    static func load() -> PairedRing? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PairedRing.self, from: data)
    }

    static func save(_ ring: PairedRing) {
        if let data = try? JSONEncoder().encode(ring) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// The ring rotates its Bluetooth address while unbonded, so its CoreBluetooth
    /// identifier changes now and then. Keep the record, swap the identifier.
    static func updatePeripheralID(_ id: UUID) {
        guard var ring = load(), ring.peripheralID != id else { return }
        ring.peripheralID = id
        save(ring)
    }
}

/// What to do with the GATT link once a sync is over.
enum LinkPolicy: String, CaseIterable, Sendable {
    /// Keep the link and go quiet. iOS suspends the app with the link alive, so the
    /// next background refresh needs no connect phase, and a notification from the
    /// ring can wake the app. This is what the official app does.
    case park
    /// Disconnect and re-arm a pending connect. For people who also sync the same
    /// ring from the desktop `oura` client: the ring has ONE link.
    case release

    var title: String {
        switch self {
        case .park: return "Keep the ring connected"
        case .release: return "Release the ring after each sync"
        }
    }
}

enum SyncSettings {
    private static let linkPolicyKey = "ring.link-policy"
    private static let summaryCostKey = "ring.summary-build-seconds"

    static var linkPolicy: LinkPolicy {
        get {
            LinkPolicy(rawValue: UserDefaults.standard.string(forKey: linkPolicyKey) ?? "") ?? .park
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: linkPolicyKey) }
    }

    /// Measured cost of the last `Core.base()` call, so a background run can decide
    /// whether refreshing the summary fits its budget.
    static var lastSummaryBuildSeconds: Double {
        get { UserDefaults.standard.double(forKey: summaryCostKey) }
        set { UserDefaults.standard.set(newValue, forKey: summaryCostKey) }
    }
}
