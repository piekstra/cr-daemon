import Foundation
import Network

#if canImport(AppKit)
    import AppKit
#endif

/// Bridges macOS sleep/wake and network reachability into simple callbacks the
/// Coordinator drives its state machine from. All callbacks fire on the main
/// queue.
public final class PowerNetworkMonitor: @unchecked Sendable {
    public private(set) var isOnline: Bool = true

    public var onSleep: (() -> Void)?
    public var onWake: (() -> Void)?
    public var onNetworkChange: ((Bool) -> Void)?

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.piekstra.cr-daemon.nwpath")
    private var started = false

    public init() {}

    public func start() {
        guard !started else { return }
        started = true

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = self.isOnline != online
                self.isOnline = online
                if changed { self.onNetworkChange?(online) }
            }
        }
        pathMonitor.start(queue: pathQueue)

        #if canImport(AppKit)
            let nc = NSWorkspace.shared.notificationCenter
            nc.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.onSleep?()
            }
            nc.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.onWake?()
            }
        #endif
    }

    public func stop() {
        pathMonitor.cancel()
    }
}
