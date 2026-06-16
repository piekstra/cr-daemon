import AppKit
import CRDaemonCore

// Entry point. cr-daemon is a menu-bar-only (LSUIElement) AppKit app: no Dock
// icon, no main window — just an NSStatusItem driven by AppDelegate. The
// reviewing/watching logic lives in CRDaemonCore so it stays unit-testable.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
