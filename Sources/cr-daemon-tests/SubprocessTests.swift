import CRDaemonCore
import Foundation

func runSubprocessTests() {
    suite.test("descendantCountZeroForLeafProcess") {
        // A bare `sleep` spawns nothing — this is the wedged-review fingerprint.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["10"]
        try? p.run()
        defer { p.terminate() }
        usleep(300_000)
        suite.expect(
            Subprocess.descendantCount(of: p.processIdentifier) == 0,
            "a leaf process has no descendants")
    }

    suite.test("descendantCountSeesChildren") {
        // `sh -c "sleep …&& true"` can't exec-replace, so it forks `sleep` as a
        // child — a stand-in for a review's live LLM specialist subprocess.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 10 && true"]
        try? p.run()
        defer { p.terminate() }
        var count = 0
        for _ in 0..<20 {
            count = Subprocess.descendantCount(of: p.processIdentifier)
            if count >= 1 { break }
            usleep(100_000)
        }
        suite.expect(count >= 1, "a process with a live child has descendants")
    }
}
