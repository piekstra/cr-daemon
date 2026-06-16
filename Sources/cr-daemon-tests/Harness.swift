import Foundation

/// Minimal dependency-free test harness so the suite runs on a Command Line
/// Tools-only toolchain (no XCTest, no swift-testing). `suite.finish()` exits
/// nonzero if any check failed, which is what CI gates on.
enum TestError: Error { case requireFailed }

final class TestRunner {
    static let shared = TestRunner()
    private(set) var failures = 0
    private(set) var checks = 0
    private var current = "?"

    func test(_ name: String, _ body: () throws -> Void) {
        current = name
        do { try body() } catch { record("threw \(error)") }
    }

    func expect(
        _ cond: Bool, _ msg: @autoclosure () -> String = "",
        _ file: StaticString = #fileID, _ line: UInt = #line
    ) {
        checks += 1
        if !cond { record(msg(), file, line) }
    }

    func require<Value>(
        _ value: Value?, _ msg: @autoclosure () -> String = "value was nil",
        _ file: StaticString = #fileID, _ line: UInt = #line
    ) throws -> Value {
        checks += 1
        guard let value else {
            record("require failed: \(msg())", file, line)
            throw TestError.requireFailed
        }
        return value
    }

    private func record(_ msg: String, _ file: StaticString = #fileID, _ line: UInt = #line) {
        failures += 1
        FileHandle.standardError.write(Data("  ✗ [\(current)] \(file):\(line) \(msg)\n".utf8))
    }

    func finish() -> Never {
        print("\n\(checks) checks · \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}

let suite = TestRunner.shared
