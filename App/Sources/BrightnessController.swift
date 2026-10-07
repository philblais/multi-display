import AppleSiliconDDC
import CoreGraphics
import Darwin
import Foundation

final class BrightnessController {
    private let queue = DispatchQueue(label: "personal.phib.MultiDisplayManagement.brightness")
    private let native = NativeBrightness()
    private let software: SoftwareBrightnessControlling
    private let ddcRead: (CGDirectDisplayID) -> Double?
    private let ddcSet: (Double, CGDirectDisplayID) -> Bool
    private var softwareDisplayIDs: Set<String> = []
    private var generations: [String: UInt64] = [:]

    init(software: SoftwareBrightnessControlling = SoftwareDimmingController(),
         ddcRead: @escaping (CGDirectDisplayID) -> Double? = { AppleSiliconDDC.brightness(displayID: $0) },
         ddcSet: @escaping (Double, CGDirectDisplayID) -> Bool = { AppleSiliconDDC.setBrightness($0, displayID: $1) }) {
        self.software = software
        self.ddcRead = ddcRead
        self.ddcSet = ddcSet
    }

    func read(display: ManagedDisplay, completion: @escaping (Double?, BrightnessControl, String?) -> Void) {
        let generation = generations[display.persistentID, default: 0]
        if display.supportsSoftwareDimming && softwareDisplayIDs.contains(display.persistentID) {
            let value = software.read(display: display)
            DispatchQueue.main.async {
                guard self.generations[display.persistentID, default: 0] == generation else { return }
                completion(value, value == nil ? .unavailable : .software,
                           value == nil ? "Software dimming is unavailable on this screen." : nil)
            }
            return
        }
        queue.async {
            let value = display.isBuiltIn
                ? self.native.read(displayID: display.id)
                : self.ddcRead(display.id)
            DispatchQueue.main.async {
                guard self.generations[display.persistentID, default: 0] == generation else { return }
                if let value {
                    completion(value, display.isBuiltIn ? .native : .ddc, nil)
                } else if display.supportsSoftwareDimming, let level = self.software.read(display: display) {
                    self.softwareDisplayIDs.insert(display.persistentID)
                    completion(level, .software, nil)
                } else {
                    completion(nil, .unavailable, "Brightness control is unavailable on this connection.")
                }
            }
        }
    }

    func set(_ value: Double, display: ManagedDisplay, completion: @escaping (Bool) -> Void) {
        if display.supportsSoftwareDimming &&
            (display.brightnessControl == .software || softwareDisplayIDs.contains(display.persistentID)) {
            let success = software.set(value, display: display)
            DispatchQueue.main.async { completion(success) }
            return
        }
        queue.async {
            let success = display.isBuiltIn
                ? self.native.set(value, displayID: display.id)
                : self.ddcSet(value, display.id)
            DispatchQueue.main.async { completion(success) }
        }
    }

    func resetSoftwareDimming(persistentID: String) {
        generations[persistentID, default: 0] &+= 1
        softwareDisplayIDs.remove(persistentID)
        software.reset(persistentID: persistentID)
    }

    func suspendSoftwareDimming() { software.suspend() }

    func retainSoftwareDimming(for displays: [ManagedDisplay]) {
        let eligible = Set(displays.filter(\.supportsSoftwareDimming).map(\.persistentID))
        for persistentID in softwareDisplayIDs.subtracting(eligible) {
            resetSoftwareDimming(persistentID: persistentID)
        }
        software.retainOnly(eligible)
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
