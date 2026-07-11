import Foundation

/// Result of running a child process to completion.
public struct SubprocessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

/// Minimal, deadlock-safe synchronous process runner. Reads stdout/stderr on
/// background queues (so a child that fills a pipe buffer can't hang us) and
/// supports an optional wall-clock timeout (SIGTERM, then SIGKILL after a grace
/// period). Use this for short-lived commands (`security`, `cr me`, `cr config`).
/// Long-running reviews are managed directly by ReviewRunner so they can be
/// cancelled externally (e.g. on sleep).
public enum Subprocess {
    public static func run(
        _ launchPath: String,
        _ args: [String],
        stdin: String? = nil,
        timeout: TimeInterval? = nil,
        environment: [String: String]? = nil,
        currentDirectory: String? = nil,
        onLaunch: ((Process) -> Void)? = nil
    ) -> SubprocessResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        if let environment { proc.environment = environment }
        if let currentDirectory {
            proc.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = inPipe

        var outData = Data()
        var errData = Data()
        let ioGroup = DispatchGroup()
        ioGroup.enter()
        DispatchQueue.global().async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            ioGroup.leave()
        }
        ioGroup.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            ioGroup.leave()
        }

        do {
            try proc.run()
        } catch {
            return SubprocessResult(
                exitCode: -1, stdout: "", stderr: "failed to launch \(launchPath): \(error)",
                timedOut: false)
        }
        onLaunch?(proc)

        if let stdin {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        }
        try? inPipe.fileHandleForWriting.close()

        var timedOut = false
        if let timeout {
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                proc.waitUntilExit()
                sem.signal()
            }
            if sem.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                // Kill the whole tree, not just the child: `cr` fans out
                // specialist LLM subprocesses that outlive a plain terminate()
                // and keep consuming provider capacity — enough leaked children
                // and every later review crawls into its own timeout.
                Self.killTree(proc.processIdentifier, signal: SIGTERM)
                if sem.wait(timeout: .now() + 5) == .timedOut {
                    Self.killTree(proc.processIdentifier, signal: SIGKILL)
                    sem.wait()
                }
            }
        } else {
            proc.waitUntilExit()
        }

        ioGroup.wait()
        return SubprocessResult(
            exitCode: proc.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            timedOut: timedOut)
    }

    /// Signal a process and all of its descendants, deepest first (children
    /// are enumerated before the parent dies, since orphans reparent and
    /// become unreachable via the parent chain).
    public static func killTree(_ pid: Int32, signal: Int32 = SIGTERM) {
        for child in childPids(of: pid) {
            killTree(child, signal: signal)
        }
        kill(pid, signal)
    }

    private static func childPids(of pid: Int32) -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) } ?? []
    }
}
