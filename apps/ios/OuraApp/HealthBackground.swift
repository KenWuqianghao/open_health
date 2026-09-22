import Foundation
import HealthKit
import UIKit

// HealthKit background delivery: iOS wakes the app when a followed type changes
// (the Watch synced, another app wrote), one observer fires per type, and the app
// pushes the changes to the hub. Observers must be registered before the app
// finishes launching, or a background wake finds nobody listening.

/// Coalesces a burst of observer callbacks into one push. Every completion handler
/// is called once the push that covers it has finished, on success or failure. A
/// wake that arrives during a push queues exactly one more push.
actor HealthWake {
    typealias Push = @Sendable (_ reason: String) async -> Void
    private let push: Push
    private let debounce: TimeInterval
    private var pending: [@Sendable () -> Void] = []
    private var kinds: Set<String> = []
    private var running = false
    private var timer: Task<Void, Never>?
    private(set) var pushes = 0

    init(debounce: TimeInterval = 2, push: @escaping Push) {
        self.push = push
        self.debounce = debounce
    }

    func wake(kind: String, completion: @escaping @Sendable () -> Void) {
        pending.append(completion)
        kinds.insert(kind)
        guard !running else { return }   // the loop below picks it up after this push
        timer?.cancel()
        timer = Task { [debounce] in
            try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.drain()
        }
    }

    private func drain() async {
        guard !running else { return }
        running = true
        while !pending.isEmpty {
            let handlers = pending
            let reason = "hk-wake:" + kinds.sorted().joined(separator: ",")
            pending = []
            kinds = []
            pushes += 1
            await push(reason)
            handlers.forEach { $0() }
        }
        running = false
    }
}

/// Installs the observers and the delivery requests.
final class HealthBackground {
    static let shared = HealthBackground()
    /// Wall-clock budget for one wake. iOS gives a HealthKit wake well under a minute.
    static let deadline: TimeInterval = 20

    private var queries: [AnyObject] = []
    private let wake: HealthWake
    private let lock = NSLock()

    init(push: HealthWake.Push? = nil) {
        wake = HealthWake(push: push ?? { reason in
            let task = await MainActor.run { KeepAlive.begin("hk-wake") }
            await HubPusher.shared.pushHealth(reason: reason, deadline: HealthBackground.deadline)
            await MainActor.run { KeepAlive.end(task) }
        })
    }

    /// HealthKit limits the cumulative kinds to one delivery per hour; ask for what it
    /// gives so the request is not refused.
    static func frequency(for kind: String) -> HKUpdateFrequency {
        switch kind {
        case "step_count", "active_energy", "basal_energy", "exercise_time", "stand_time",
             "stand_hour", "distance_walking_running":
            return .hourly
        default:
            return .immediate
        }
    }

    /// At launch. Observers only; the delivery requests persist in HealthKit from
    /// the last `start()`.
    func install() {
        guard HealthReader.shared.enabled else { return }
        startObservers(HealthReader.shared.client)
    }

    /// The switch went on: ask for delivery and start the observers.
    func start() async {
        let client = HealthReader.shared.client
        var failed: [String] = []
        for t in HealthReadTypes.all {
            do { try await client.enableBackgroundDelivery(t.sampleType, frequency: Self.frequency(for: t.kind)) }
            catch { failed.append(t.kind) }
        }
        if !failed.isEmpty { dlog("health-read", "background delivery refused for \(failed.joined(separator: ","))") }
        startObservers(client)
        dlog("health-read", "background delivery on, \(HealthReadTypes.all.count - failed.count) types")
    }

    func stop() async {
        stopObservers()
        do { try await HealthReader.shared.client.disableAllBackgroundDelivery() }
        catch { dlog("health-read", "disable delivery: \(error.localizedDescription)") }
    }

    private func startObservers(_ client: HealthReadClient) {
        lock.lock(); defer { lock.unlock() }
        guard queries.isEmpty else { return }
        let wake = self.wake
        queries = HealthReadTypes.all.map { t in
            client.observe(t.sampleType) { completion in
                Task { await wake.wake(kind: t.kind, completion: completion) }
            }
        }
    }

    private func stopObservers() {
        lock.lock(); defer { lock.unlock() }
        queries = []
    }
}
