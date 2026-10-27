import Darwin
import Foundation
import XCTest

final class RotationControllerTests: XCTestCase {
    func testLargeStandardOutputAndErrorCompleteWithBoundedCapture() throws {
        let script = """
        printf 'stdout\\n'
        printf 'stderr\\n' >&2
        printf '%100000s' O
        printf '%100000s' E >&2
        """
        let result = try runHelper(arguments: ["-c", script])
        let output = try result.get()

        XCTAssertTrue(output.contains("stdout\n"))
        XCTAssertTrue(output.contains("stderr\n"))
        XCTAssertLessThanOrEqual(output.utf8.count, 16_384)
    }

    func testFailingHelperPreservesErrorText() throws {
        let result = try runHelper(arguments: ["-c", "printf 'rotation helper failed' >&2; exit 7"])

        switch result {
        case .success:
            XCTFail("A failing helper must return an error")
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("rotation helper failed"))
        }
    }

    func testHungHelperTimesOutAndTerminatesItsProcess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let processIDURL = directory.appendingPathComponent("process-id")
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = """
        printf '%s' "$$" > "$1"
        exec /bin/sleep 30
        """
        let result = try runHelper(arguments: ["-c", script, "rotation-timeout-test", processIDURL.path], timeout: 0.2)
        let recordedID = try String(contentsOf: processIDURL, encoding: .utf8)
        let processID = try XCTUnwrap(Int32(recordedID))
        // Clean up our child if a regression leaves it running after returning.
        defer { _ = kill(processID, SIGKILL) }

        switch result {
        case .success:
            XCTFail("A hung helper must return a timeout error")
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("did not finish"))
        }
        errno = 0
        let processStatus = kill(processID, 0)
        let processError = errno
        XCTAssertEqual(processStatus, -1, "The timed-out helper must no longer exist")
        XCTAssertEqual(processError, ESRCH)
    }

    private func runHelper(arguments: [String], timeout: TimeInterval = 2) throws -> Result<String, Error> {
        let completed = expectation(description: "Helper finishes without blocking the main run loop")
        var result: Result<String, Error>?
        DispatchQueue.global(qos: .userInitiated).async {
            result = RotationController.run(executableURL: URL(fileURLWithPath: "/bin/sh"),
                                            arguments: arguments, timeout: timeout)
            completed.fulfill()
        }
        wait(for: [completed], timeout: timeout + 4)
        return try XCTUnwrap(result)
    }
}
