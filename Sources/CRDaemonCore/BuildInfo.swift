import Foundation

/// Build provenance for the binary. The default values below ship in source so a
/// plain `swift build` (no git inject) compiles unchanged. `Scripts/make-app.sh`
/// overwrites this file with the real short SHA + ISO date just before a release
/// build, so an installed app reports exactly which commit it was built from.
/// Tracked (not gitignored): the script rewrites it in place and `git checkout`
/// restores this default afterwards.
public enum BuildInfo {
    /// Short git SHA the binary was built from, or "dev" for a plain local build.
    public static let gitSHA = "dev"
    /// ISO-8601 date the binary was built, or "" when not injected.
    public static let date = ""
}
