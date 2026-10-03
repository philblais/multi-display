import AppleSiliconDDC
import CoreGraphics
import Darwin
import Foundation

final class BrightnessController {
    private let queue = DispatchQueue(label: "personal.phib.MultiDisplayManagement.brightness")
    private let native = NativeBrightness()

    func read(display: ManagedDisplay, completion: @escaping (Double?, String?) -> Void) {
        queue.async {
            let value = display.isBuiltIn
                ? self.native.read(displayID: display.id)
                : AppleSiliconDDC.brightness(displayID: display.id)
            DispatchQueue.main.async {
                completion(value, value == nil ? "Brightness control is unavailable on this connection." : nil)
            }
        }
    }

    func set(_ value: Double, display: ManagedDisplay, completion: @escaping (Bool) -> Void) {
        queue.async {
            let success = display.isBuiltIn
                ? self.native.set(value, displayID: display.id)
                : AppleSiliconDDC.setBrightness(value, displayID: display.id)
            DispatchQueue.main.async { completion(success) }
        }
    }
}

private final class NativeBrightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private let getter: Get?
    private let setter: Set?

    init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_NOW) else {
            getter = nil
            setter = nil
            return
        }
        getter = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Get.self) }
        setter = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Set.self) }
    }

    func read(displayID: CGDirectDisplayID) -> Double? {
        guard let getter else { return nil }
        var value: Float = 0
        guard getter(displayID, &value) == 0 else { return nil }
        return Double(value)
    }

    func set(_ value: Double, displayID: CGDirectDisplayID) -> Bool {
        guard let setter else { return false }
        return setter(displayID, Float(min(1, max(0, value)))) == 0
    }
}
