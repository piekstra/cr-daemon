import Foundation

/// The cr-daemon base version. Mirrors CFBundleShortVersionString in
/// Resources/Info.plist; keep them in sync on release.
public let crDaemonBaseVersion = "0.2.0"

/// Build identifier surfaced in the menu and logs, e.g. `0.2.0 (a1b2c3d)`. The
/// short SHA is injected at build time by Scripts/make-app.sh (see BuildInfo);
/// a plain `swift build` reports `0.2.0 (dev)`.
public let crDaemonVersion = "\(crDaemonBaseVersion) (\(BuildInfo.gitSHA))"
