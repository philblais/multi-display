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
    let reportedName: String
    let isBuiltIn: Bool
    let isMirrored: Bool
    let profile: DisplayProfile
    let rotation: Int
    let modes: [DisplayModeOption]
    let currentMode: ModeSignature?
    var brightness: Double?
    var brightnessError: String?
    var brightnessControl: BrightnessControl = .unavailable

    var model: DisplayProfile { profile.resolved(reportedName: reportedName, isBuiltIn: isBuiltIn) }
    var name: String { model == .automatic ? reportedName : model.title }
    var supportsSoftwareDimming: Bool { model == .samsungHG50U701FNF && !isMirrored }
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
