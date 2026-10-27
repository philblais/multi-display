import AppKit
import ColorSync
import CoreGraphics
import Foundation

enum DisplayInventory {
    static func scan(profileOverrides: [String: String] = [:]) -> [ManagedDisplay] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        let screenNames = NSScreen.screens.reduce(into: [CGDirectDisplayID: String]()) { names, screen in
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                names[id] = screen.localizedName
            }
        }

        return ids.prefix(Int(count)).filter { CGDisplayIsActive($0) != 0 }.map { id in
            let available = (CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] ?? [])
                .filter { $0.isUsableForDesktopGUI() }
                .map(DisplayModeOption.init)
                .sorted { left, right in
                    if left.signature.width != right.signature.width { return left.signature.width < right.signature.width }
                    if left.signature.height != right.signature.height { return left.signature.height < right.signature.height }
                    return left.signature.refreshRate > right.signature.refreshRate
                }
            let current = CGDisplayCopyDisplayMode(id).map(ModeSignature.init)
            let persistentID = persistentID(for: id)
            return ManagedDisplay(
                id: id,
                persistentID: persistentID,
                reportedName: name(for: id, screenNames: screenNames),
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                isMirrored: CGDisplayIsInMirrorSet(id) != 0 || CGDisplayIsInHWMirrorSet(id) != 0,
                profile: profileOverrides[persistentID].flatMap(DisplayProfile.init(rawValue:)) ?? .automatic,
                rotation: Int(CGDisplayRotation(id).rounded()),
                modes: available,
                currentMode: current,
                brightness: nil,
                brightnessError: nil
            )
        }
    }

    static func persistentID(for id: CGDirectDisplayID) -> String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
           let value = CFUUIDCreateString(kCFAllocatorDefault, uuid) as String? {
            return value
        }
        // Without a UUID, prefer a connection-specific identity over colliding IDs
        // for identical monitors with no serial number. This fallback can change on reconnect.
        return "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))-display-\(id)"
    }

    private static func name(for id: CGDirectDisplayID, screenNames: [CGDirectDisplayID: String]) -> String {
        if let name = screenNames[id] { return name }
        if CGDisplayIsBuiltin(id) != 0 { return "MacBook display" }
        return "Display \(CGDisplayModelNumber(id))"
    }
}
