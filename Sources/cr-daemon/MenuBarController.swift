import AppKit
import CRDaemonCore

/// Owns the NSStatusItem and builds the dropdown menu from Coordinator state.
/// The menu is rebuilt on open (NSMenuDelegate) so countdowns/queue are always
/// fresh; the icon updates on every state change.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let coordinator: Coordinator

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon(coordinator.runtimeState)
    }

    // MARK: - Icon

    func updateIcon(_ state: RuntimeState) {
        guard let button = statusItem.button else { return }
        let (symbol, desc) = Self.symbol(for: state)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: desc) {
            img.isTemplate = true
            button.image = img
            button.title = ""
        } else {
            button.image = nil
            button.title = "cr"
        }
        button.toolTip = "cr-daemon — \(desc)"
    }

    static func symbol(for state: RuntimeState) -> (String, String) {
        switch state {
        case .starting: return ("hourglass", "starting")
        case .active: return ("eye", "watching")
        case .reviewing: return ("arrow.triangle.2.circlepath", "reviewing")
        case .paused: return ("pause.circle", "paused")
        case .offline: return ("wifi.slash", "offline")
        case .rateLimited: return ("tortoise", "rate-limited")
        case .backingOff: return ("clock", "backing off")
        case .safeMode: return ("exclamationmark.triangle", "safe mode")
        case .error: return ("xmark.octagon", "error")
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    // MARK: - Build

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let c = coordinator

        if c.identityOK {
            menu.addItem(disabled("Watching as \(c.config.reviewerLogin)"))
        } else {
            menu.addItem(disabled("⚠︎ cr identity: \(c.identityResolved ?? "unresolved")"))
            menu.addItem(disabled("   expected \(c.config.reviewerLogin) — reviews paused"))
        }
        menu.addItem(disabled(statusLine(c)))
        menu.addItem(disabled(rateLine(c)))
        menu.addItem(.separator())

        let active = c.store.active()
        menu.addItem(disabled("Assigned (\(active.count))"))
        if active.isEmpty {
            menu.addItem(disabled("   none"))
        } else {
            for a in active.prefix(15) { menu.addItem(queueItem(a)) }
        }
        menu.addItem(.separator())

        let recent = c.store.recent(limit: 5)
        if !recent.isEmpty {
            menu.addItem(disabled("Recent"))
            for a in recent {
                let item = actionItem(
                    "   \(outcomeGlyph(a)) \(a.key)" + titleSuffix(a),
                    #selector(openItem(_:)))
                item.representedObject = a.url
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        menu.addItem(
            actionItem(
                c.config.paused ? "Resume watching" : "Pause watching",
                #selector(togglePause)))
        menu.addItem(actionItem("Poll now", #selector(pollNow)))
        menu.addItem(.separator())
        menu.addItem(actionItem("Edit config…", #selector(editConfig)))
        menu.addItem(actionItem("Reload config", #selector(reloadConfig)))
        menu.addItem(actionItem("Open logs", #selector(openLogs)))
        menu.addItem(actionItem("Open data folder", #selector(openData)))
        menu.addItem(.separator())
        if c.upgrading {
            menu.addItem(disabled("Upgrading cr…"))
        } else {
            menu.addItem(actionItem("Upgrade cr…", #selector(upgradeCR)))
        }
        menu.addItem(.separator())
        menu.addItem(disabled("cr-daemon \(crDaemonVersion)"))
        menu.addItem(disabled("cr \(c.crVersionString ?? "?")"))
        if let update = c.crUpdateAvailable {
            menu.addItem(disabled("  ↑ cr \(update) available"))
        }
        let quit = actionItem("Quit", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func queueItem(_ a: Assignment) -> NSMenuItem {
        let item = NSMenuItem(
            title: "\(stateGlyph(a)) \(a.key)" + titleSuffix(a), action: nil, keyEquivalent: "")
        let sub = NSMenu()

        let open = actionItem("Open in browser", #selector(openItem(_:)))
        open.representedObject = a.url
        sub.addItem(open)

        if a.awaitingConfirm == true {
            let post = actionItem("Approve & post (live)", #selector(reviewNow(_:)))
            post.representedObject = a.key
            sub.addItem(post)
            if let s = a.lastSummary, !s.isEmpty {
                sub.addItem(.separator())
                sub.addItem(disabled("Plan:"))
                for line in s.split(separator: "\n").prefix(10) {
                    sub.addItem(disabled("   " + String(line.prefix(80))))
                }
            }
        } else {
            let now = actionItem("Review now", #selector(reviewNow(_:)))
            now.representedObject = a.key
            sub.addItem(now)
        }

        let skip = actionItem("Skip", #selector(skipItem(_:)))
        skip.representedObject = a.key
        sub.addItem(skip)

        if let err = a.lastError, !err.isEmpty {
            sub.addItem(.separator())
            sub.addItem(disabled("last: " + String(err.prefix(80))))
        }
        item.submenu = sub
        return item
    }

    // MARK: - Text helpers

    private func statusLine(_ c: Coordinator) -> String {
        switch c.runtimeState {
        case .starting: return "Starting…"
        case .active: return "Watching"
        case .reviewing(let k): return "Reviewing \(k)"
        case .paused: return "Paused"
        case .offline: return "Offline — waiting for network"
        case .rateLimited(let until): return "Rate-limited until \(Self.timeFmt.string(from: until))"
        case .backingOff(let until): return "Backing off until \(Self.timeFmt.string(from: until))"
        case .safeMode(let r): return "Safe mode: \(r)"
        case .error(let m): return "Error: " + String(m.prefix(80))
        }
    }

    private func rateLine(_ c: Coordinator) -> String {
        func fmt(_ r: RateBudget?) -> String {
            guard let r else { return "—" }
            return "\(r.remaining)/\(r.limit)"
        }
        return "Rate · core \(fmt(c.rateCore)) · search \(fmt(c.rateSearch))"
    }

    private func titleSuffix(_ a: Assignment) -> String {
        guard let t = a.title, !t.isEmpty else { return "" }
        return " — " + String(t.prefix(48))
    }

    private func stateGlyph(_ a: Assignment) -> String {
        if a.awaitingConfirm == true { return "✋" }
        switch a.state {
        case .pending: return "•"
        case .reviewing: return "⟳"
        default: return "•"
        }
    }

    private func outcomeGlyph(_ a: Assignment) -> String {
        switch a.lastOutcome {
        case .approved: return "✅"
        case .commented: return "💬"
        case .changesRequested: return "⚠️"
        case .failed: return "❌"
        default: return a.state == .skipped ? "⏭" : "•"
        }
    }

    // MARK: - Item factories

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func openItem(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func reviewNow(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? PRKey { coordinator.reviewNow(key) }
    }

    @objc private func skipItem(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? PRKey { coordinator.skip(key) }
    }

    @objc private func togglePause() {
        coordinator.config.paused ? coordinator.resume() : coordinator.pause()
    }

    @objc private func pollNow() { coordinator.pollNow() }

    @objc private func editConfig() { NSWorkspace.shared.open(Paths.configFile) }

    @objc private func reloadConfig() { coordinator.reloadConfig() }

    @objc private func upgradeCR() { coordinator.upgradeCR() }

    @objc private func openLogs() { NSWorkspace.shared.open(Paths.logsDir) }

    @objc private func openData() { NSWorkspace.shared.open(Paths.appSupportDir) }

    @objc private func quit() { NSApp.terminate(nil) }
}
