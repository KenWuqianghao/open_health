import UIKit

/// The launch hooks SwiftUI's `App` cannot express: the restore-identified BLE
/// central must exist before `didFinishLaunching` returns (that is how iOS hands back
/// a restored session), background tasks must be registered before launch ends, and
/// a Bluetooth relaunch is announced in `launchOptions`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let restored = launchOptions?[.bluetoothCentrals] as? [String] ?? []
        DiagStore.shared.noteLaunch(state: application.applicationState, bluetoothCentrals: restored)
        if application.isProtectedDataAvailable {
            Keychain.migrateAccessibilityIfNeeded()
        }
        let central = RingCentral.shared
        central.onUnsolicitedConnect = { peripheral in
            Task { await SyncCoordinator.shared.handleUnsolicitedConnect(peripheral) }
        }
        AppHooks.install()
        // Must run before launch finishes: iOS refuses later registrations.
        BGSync.register()
        return true
    }
}
