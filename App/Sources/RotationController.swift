import Foundation
import Darwin

protocol DisplayRotating {
    var isAvailable: Bool { get }
    func set(_ degrees: Int, persistentID: String, completion: @escaping (Result<Void, Error>) -> Void)
}

final class RotationController: DisplayRotating {
    private let queue = DispatchQueue(label: "personal.phib.MultiDisplayManagement.rotation")

    var isAvailable: Bool { executableURL != nil }

    func set(_ degrees: Int, persistentID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            let result: Result<String, Error>
            if let executableURL = self.executableURL {
                result = Self.run(executableURL: executableURL, arguments: ["id:\(persistentID) degree:\(degrees)"])
            } else {
                result = .failure(RotationError.missingHelper)
            }
            DispatchQueue.main.async { completion(result.map { _ in () }) }
        }
    }

    private var executableURL: URL? {
        ["/opt/homebrew/bin/displayplacer", "/usr/local/bin/displayplacer"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }

    static func run(executableURL: URL, arguments: [String], timeout: TimeInterval = 8) -> Result<String, Error> {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        // A file cannot fill a pipe buffer and deadlock the helper before it exits.
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputURL) else {
            return .failure(RotationError.commandFailed("Could not capture displayplacer output."))
        }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.standardOutput = output
        process.standardError = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
            if finished.wait(timeout: .now() + timeout) == .timedOut {
                if process.isRunning { process.terminate() }
                if finished.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = finished.wait(timeout: .now() + 1)
                }
                return .failure(RotationError.timedOut)
            }
            let reader = try FileHandle(forReadingFrom: outputURL)
            defer { try? reader.close() }
            let text = String(data: try reader.read(upToCount: 16_384) ?? Data(), encoding: .utf8) ?? ""
            return process.terminationStatus == 0 ? .success(text) : .failure(RotationError.commandFailed(text))
        } catch {
            return .failure(error)
        }
    }
}

private enum RotationError: LocalizedError {
    case missingHelper
    case commandFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .missingHelper: return "displayplacer is not installed. Rotation is unavailable."
        case .commandFailed(let detail): return detail.isEmpty ? "Rotation failed." : detail
        case .timedOut: return "displayplacer did not finish. Rotation was stopped; check your screen settings."
        }
    }
}
