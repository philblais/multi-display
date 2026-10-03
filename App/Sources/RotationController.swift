import Foundation

final class RotationController {
    private let queue = DispatchQueue(label: "personal.phib.MultiDisplayManagement.rotation")

    var isAvailable: Bool { executableURL != nil }

    func set(_ degrees: Int, persistentID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            let result = self.run(arguments: ["id:\(persistentID) degree:\(degrees)"])
            DispatchQueue.main.async { completion(result.map { _ in () }) }
        }
    }

    private var executableURL: URL? {
        ["/opt/homebrew/bin/displayplacer", "/usr/local/bin/displayplacer"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }

    private func run(arguments: [String]) -> Result<String, Error> {
        guard let executableURL else { return .failure(RotationError.missingHelper) }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return process.terminationStatus == 0 ? .success(text) : .failure(RotationError.commandFailed(text))
        } catch {
            return .failure(error)
        }
    }
}

private enum RotationError: LocalizedError {
    case missingHelper
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingHelper: return "displayplacer is not installed. Rotation is unavailable."
        case .commandFailed(let detail): return detail.isEmpty ? "Rotation failed." : detail
        }
    }
}
