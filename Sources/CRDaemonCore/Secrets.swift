import Foundation

/// Reads the watcher's GitHub token from the login Keychain.
///
/// We deliberately shell out to `/usr/bin/security` rather than calling
/// SecItemCopyMatching directly: the Keychain item is created by `security`
/// (during setup), so `security` is the trusted application in the item's ACL
/// and reads never prompt. An ad-hoc-signed app's code signature changes on
/// every rebuild, which would otherwise re-trigger a Keychain access prompt on
/// each upgrade.
public enum Secrets {
    public static let service = "cr-daemon"

    /// Read a generic-password value, or nil if absent/unreadable.
    public static func genericPassword(service: String, account: String) -> String? {
        let result = Subprocess.run(
            "/usr/bin/security",
            ["find-generic-password", "-s", service, "-a", account, "-w"],
            timeout: 10)
        guard result.succeeded else { return nil }
        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// The piekstra-dev (or configured reviewer) token used by the watcher.
    public static func reviewerToken(account: String) -> String? {
        genericPassword(service: service, account: account)
    }
}
