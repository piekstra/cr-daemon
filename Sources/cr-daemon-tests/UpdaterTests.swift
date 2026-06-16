import CRDaemonCore
import Foundation

func runUpdaterTests() {
    suite.test("parseSemverFromVersionString") {
        suite.expect(
            Updater.parseSemver("cr 0.4.161 (abc1234, 2026-06-01)") == "0.4.161",
            "extracts semver from a cr version string")
        suite.expect(Updater.parseSemver("v0.3.153") == "0.3.153", "strips a leading v on a tag")
        suite.expect(Updater.parseSemver("0.2.0") == "0.2.0", "bare semver")
    }

    suite.test("parseSemverGarbageIsNil") {
        suite.expect(Updater.parseSemver("not a version") == nil)
        suite.expect(Updater.parseSemver("") == nil)
        suite.expect(Updater.parseSemver("123") == nil, "needs a dotted form")
    }

    suite.test("isNewerNumericCompare") {
        suite.expect(Updater.isNewer("0.4.161", than: "0.3.153"), "minor bump is newer")
        suite.expect(Updater.isNewer("0.4.10", than: "0.4.9"), "patch compared numerically, not lexically")
        suite.expect(!Updater.isNewer("0.4.161", than: "0.4.161"), "equal is not newer")
        suite.expect(!Updater.isNewer("0.3.153", than: "0.4.161"), "older is not newer")
        suite.expect(Updater.isNewer("0.4.1", than: "0.4"), "longer-but-greater is newer")
    }
}
