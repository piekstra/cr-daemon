// swift-tools-version: 6.0
import PackageDescription

// cr-daemon is a menu-bar app + watcher that reviews assigned PRs via the
// public `cr` CLI. Logic lives in the CRDaemonCore library so it can be unit
// tested without the AppKit shell; the `cr-daemon` executable is a thin UI.
//
// We build against the Command Line Tools toolchain (no full Xcode required):
// `swift build -c release` produces a bare binary that Scripts/make-app.sh
// wraps into an .app bundle. Swift 5 language mode keeps v1 concurrency
// pragmatic; tighten to v6 incrementally.
let package = Package(
    name: "cr-daemon",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "cr-daemon", targets: ["cr-daemon"]),
        .library(name: "CRDaemonCore", targets: ["CRDaemonCore"]),
    ],
    targets: [
        .target(
            name: "CRDaemonCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "cr-daemon",
            dependencies: ["CRDaemonCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Tests are a plain executable (run: `swift run cr-daemon-tests`) with a
        // tiny built-in assertion harness, so they need neither XCTest nor
        // swift-testing — both of which are absent from a Command Line Tools-only
        // toolchain. Same command works in CI on a full-Xcode runner.
        .executableTarget(
            name: "cr-daemon-tests",
            dependencies: ["CRDaemonCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
