import CoreGraphics
import Foundation

// A narrow public wrapper around the upstream matching and VCP transport.
// VCP 0x10 is the standard monitor luminance control.
public extension AppleSiliconDDC {
    static func brightness(displayID: CGDirectDisplayID) -> Double? {
        guard let service = getServiceMatches(displayIDs: [displayID]).first?.service,
              let reading = read(service: service, command: 0x10),
              reading.max > 0 else { return nil }
        return min(1, max(0, Double(reading.current) / Double(reading.max)))
    }

    static func setBrightness(_ fraction: Double, displayID: CGDirectDisplayID) -> Bool {
        guard let service = getServiceMatches(displayIDs: [displayID]).first?.service,
              let reading = read(service: service, command: 0x10),
              reading.max > 0 else { return false }
        let value = UInt16((min(1, max(0, fraction)) * Double(reading.max)).rounded())
        return write(service: service, command: 0x10, value: value)
    }
}
