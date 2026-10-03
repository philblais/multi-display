import CoreGraphics
import Foundation

struct ModeSignature: Codable, Equatable {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double

    init(_ mode: CGDisplayMode) {
        width = mode.width
        height = mode.height
        pixelWidth = mode.pixelWidth
        pixelHeight = mode.pixelHeight
        refreshRate = mode.refreshRate
    }

    func matches(_ mode: CGDisplayMode) -> Bool {
        width == mode.width && height == mode.height &&
        pixelWidth == mode.pixelWidth && pixelHeight == mode.pixelHeight &&
        abs(refreshRate - mode.refreshRate) < 0.5
    }
}

struct DisplayModeOption: Identifiable {
    let mode: CGDisplayMode
    let signature: ModeSignature
    let id: String
    let title: String

    init(mode: CGDisplayMode) {
        self.mode = mode
        signature = ModeSignature(mode)
        id = "\(mode.width)x\(mode.height)-\(mode.pixelWidth)x\(mode.pixelHeight)-\(mode.refreshRate)-\(mode.ioDisplayModeID)"
        let retina = mode.pixelWidth > mode.width || mode.pixelHeight > mode.height ? " · HiDPI" : ""
        let refresh = mode.refreshRate > 0 ? " · \(Int(mode.refreshRate.rounded())) Hz" : ""
        title = "\(mode.width) × \(mode.height)\(retina)\(refresh)"
    }
}

struct ManagedDisplay: Identifiable {
    let id: CGDirectDisplayID
    let persistentID: String
    let name: String
    let isBuiltIn: Bool
    let rotation: Int
    let modes: [DisplayModeOption]
    let currentMode: ModeSignature?
    var brightness: Double?
    var brightnessError: String?
}

struct SavedDisplay: Codable {
    let persistentID: String
    let name: String
    let brightness: Double?
    let mode: ModeSignature?
    let rotation: Int
}

struct SavedSetup: Codable, Identifiable {
    let id: UUID
    let name: String
    let displays: [SavedDisplay]
}
