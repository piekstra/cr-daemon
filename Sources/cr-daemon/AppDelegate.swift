import AppKit
import CRDaemonCore
import UserNotifications

/// Wires up the app: single-instance lock, crash-loop safe-mode, builds the
/// Coordinator with real dependencies, and connects it to the menu bar +
/// notifications.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var lockFD: Int32 = -1
    private var coordinator: Coordinator!
    private var menu: MenuBarController!
    private var notifier: Notifier!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.ensureDirectories()
        notifier = Notifier()

        // Single-instance: if another cr-daemon already holds the lock, exit
        // cleanly (e.g. launched a second time from Spotlight). exit(0) so launchd
        // (KeepAlive only on crash) doesn't relaunch us.
        guard let fd = Supervisor.acquireSingleInstanceLock() else {
            Logger.shared.warn("daemon.already_running", [:])
            exit(0)
        }
        lockFD = fd  // hold for process lifetime

        let safeMode = Supervisor.recordStartupAndDetectCrashLoop()

        let config = Config.loadOrCreateDefault()
        let account = config.reviewerKeychainAccount

        let client = GitHubClient(
            tokenProvider: { Secrets.reviewerToken(account: account) },
            coreFloor: config.coreRateFloor,
            searchFloor: config.searchRateFloor)
        let store = QueueStore()
        let runner = ReviewRunner(
            profile: config.crProfile,
            timeout: TimeInterval(config.reviewTimeoutSeconds))
        let monitor = PowerNetworkMonitor()

        coordinator = Coordinator(
            config: config, client: client, store: store, runner: runner, monitor: monitor)
        menu = MenuBarController(coordinator: coordinator)

        coordinator.onStateChange = { [weak self] state in self?.menu.updateIcon(state) }
        coordinator.onChange = { [weak self] in self?.menu.updateIcon(self?.coordinator.runtimeState ?? .active) }
        coordinator.onNotify = { [weak self] title, body in self?.notifier.post(title, body) }

        notifier.setup()
        coordinator.start(safeMode: safeMode)
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }
}

/// Thin UserNotifications wrapper. No-ops when not running inside a real app
/// bundle (e.g. `swift run`), where UNUserNotificationCenter is unavailable.
@MainActor
final class Notifier {
    private var enabled = false

    func setup() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            granted, _ in
            DispatchQueue.main.async { self.enabled = granted }
        }
    }

    func post(_ title: String, _ body: String) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
