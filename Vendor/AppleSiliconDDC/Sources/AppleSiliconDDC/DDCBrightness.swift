import CoreGraphics
import Foundation

// A narrow public wrapper around the upstream matching and VCP transport.
// VCP 0x10 is the standard monitor luminance control.
public extension AppleSiliconDDC {
    static func brightness(displayID: CGDirectDisplayID) -> Double? {
        guard let service = brightnessService(displayID: displayID)?.service,
              let reading = read(service: service, command: 0x10),
              reading.max > 0 else { return nil }
        return min(1, max(0, Double(reading.current) / Double(reading.max)))
    }

    static func setBrightness(_ fraction: Double, displayID: CGDirectDisplayID) -> Bool {
        guard fraction.isFinite,
              let service = brightnessService(displayID: displayID)?.service,
              let reading = read(service: service, command: 0x10),
              reading.max > 0 else { return false }
        let value = UInt16((min(1, max(0, fraction)) * Double(reading.max)).rounded())
        return write(service: service, command: 0x10, value: value)
    }
}

private extension AppleSiliconDDC {
    static func brightnessService(displayID: CGDirectDisplayID) -> Arm64Service? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displayIDs, &count) == .success else { return nil }
        displayIDs = Array(displayIDs.prefix(Int(count)))
        guard displayIDs.contains(displayID) else { return nil }
        return getServiceMatches(displayIDs: displayIDs).first { $0.displayID == displayID }
    }
}
