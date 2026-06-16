import CRDaemonCore
import Foundation

func runSupervisorTests() {
    suite.test("singleInstanceLock") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crlock-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lock = dir.appendingPathComponent("daemon.lock")

        let fd1 = Supervisor.acquireSingleInstanceLock(at: lock)
        suite.expect(fd1 != nil, "first instance acquires the lock")
        let fd2 = Supervisor.acquireSingleInstanceLock(at: lock)
        suite.expect(fd2 == nil, "second instance is blocked while first holds it")
        if let fd1 { close(fd1) }

        let fd3 = Supervisor.acquireSingleInstanceLock(at: lock)
        suite.expect(fd3 != nil, "lock is re-acquirable after release")
        if let fd3 { close(fd3) }
    }

    suite.test("crashLoopDetection") {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crash-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var now = Date(timeIntervalSince1970: 1000)
        for _ in 0..<4 {
            _ = Supervisor.recordStartupAndDetectCrashLoop(
                at: url, now: now, windowSeconds: 180, threshold: 4)
            now = now.addingTimeInterval(10)
        }
        suite.expect(
            Supervisor.recordStartupAndDetectCrashLoop(
                at: url, now: now, windowSeconds: 180, threshold: 4),
            "a 5th startup within the window trips safe mode")
        suite.expect(
            !Supervisor.recordStartupAndDetectCrashLoop(
                at: url, now: now.addingTimeInterval(10000), windowSeconds: 180, threshold: 4),
            "old startups outside the window expire")
    }

    suite.test("isPidAlive") {
        suite.expect(
            Supervisor.isPidAlive(Int32(ProcessInfo.processInfo.processIdentifier)),
            "our own pid is alive")
        suite.expect(!Supervisor.isPidAlive(999_999), "a bogus pid is not alive")
    }
}
