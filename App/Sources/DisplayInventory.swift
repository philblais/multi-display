import AppKit
import ColorSync
import CoreGraphics
import Foundation

enum DisplayInventory {
    static func scan() -> [ManagedDisplay] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }

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
            return ManagedDisplay(
                id: id,
                persistentID: persistentID(for: id),
                name: name(for: id),
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
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
        return "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }

    private static func name(for id: CGDirectDisplayID) -> String {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
        }
        if let name = screen?.localizedName { return name }
        if CGDisplayIsBuiltin(id) != 0 { return "MacBook display" }
        return "Display \(CGDisplayModelNumber(id))"
    }
}
