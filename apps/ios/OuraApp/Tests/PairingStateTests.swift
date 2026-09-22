import XCTest
@testable import OuraApp

final class PairingStateTests: XCTestCase {
    func testKeyGenMakes32LowercaseHexChars() {
        let a = KeyGen.random16Hex()
        let b = KeyGen.random16Hex()
        XCTAssertEqual(a.count, 32)
        XCTAssertTrue(a.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertNotEqual(a, b)
    }

    func testPairedRingRoundTrips() {
        let ring = PairedRing(peripheralID: UUID(), serial: "ABC123", hardwareId: "COR_05", firmware: "2.1.3", pairedAt: Date())
        PairedRingStore.save(ring)
        XCTAssertEqual(PairedRingStore.load()?.serial, "ABC123")
        XCTAssertEqual(PairedRingStore.load()?.peripheralID, ring.peripheralID)
        PairedRingStore.clear()
        XCTAssertNil(PairedRingStore.load())
    }

    func testKeyIsKeptOnceTheRingMayHoldIt() {
        // Before the install stage a failure means the ring never saw the key.
        XCTAssertFalse(RingPairing.keyMayBeOnRing(afterStage: ""))
        XCTAssertFalse(RingPairing.keyMayBeOnRing(afterStage: "identify"))
        XCTAssertFalse(RingPairing.keyMayBeOnRing(afterStage: "probe"))
        // From the install stage on, the ring may already hold the key: keep it.
        for stage in ["install_key", "verify", "time", "battery", "features", "done"] {
            XCTAssertTrue(RingPairing.keyMayBeOnRing(afterStage: stage), stage)
        }
    }

    func testAuthKeyFrameIsRedactedInTheTranscript() {
        var frame = Data([0x24, 0x10]); frame.append(Data(repeating: 0xab, count: 16))
        XCTAssertEqual(BLETransport.loggable(frame), "2410 <auth key redacted>")
        XCTAssertEqual(BLETransport.loggable(Data([0x2f, 0x01, 0x2b])), "2f012b")
    }

    func testLinkPolicyDefaultsToPark() {
        UserDefaults.standard.removeObject(forKey: "ring.link-policy")
        XCTAssertEqual(SyncSettings.linkPolicy, .park)
        SyncSettings.linkPolicy = .release
        XCTAssertEqual(SyncSettings.linkPolicy, .release)
        SyncSettings.linkPolicy = .park
    }

    func testSyncPolicyBudgetsAreBoundedInTheBackground() {
        let refresh = SyncPolicy.policy(for: .bgRefresh)
        XCTAssertEqual(refresh.attempts, 1)
        XCTAssertLessThanOrEqual(refresh.deadline ?? 0, 25)
        XCTAssertEqual(refresh.batchEvents, 512)
        XCTAssertFalse(refresh.runModels)
        let manual = SyncPolicy.policy(for: .manual)
        XCTAssertNil(manual.deadline)
        XCTAssertTrue(manual.idleLock)
    }
}
