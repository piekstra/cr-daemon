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
        onLaunch: ((Process) -> Void)? = nil
    ) -> SubprocessResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        if let environment { proc.environment = environment }

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
                proc.terminate()
                if sem.wait(timeout: .now() + 5) == .timedOut {
                    kill(proc.processIdentifier, SIGKILL)
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
}
