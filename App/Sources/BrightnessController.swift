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
    private var revisions: [String: UInt64] = [:]
    private var connections: [String: BrightnessConnection] = [:]
    private var leases: [String: BrightnessConnectionLease] = [:]

    init(software: SoftwareBrightnessControlling = SoftwareDimmingController(),
         ddcRead: @escaping (CGDirectDisplayID) -> Double? = { AppleSiliconDDC.brightness(displayID: $0) },
         ddcSet: @escaping (Double, CGDirectDisplayID) -> Bool = { AppleSiliconDDC.setBrightness($0, displayID: $1) }) {
        self.software = software
        self.ddcRead = ddcRead
        self.ddcSet = ddcSet
    }

    func read(display: ManagedDisplay, completion: @escaping (Double?, BrightnessControl, String?) -> Void) {
        let (revision, lease) = beginRequest(display: display)
        if display.supportsSoftwareDimming && softwareDisplayIDs.contains(display.persistentID) {
            let value = Self.normalized(software.read(display: display))
            DispatchQueue.main.async {
                guard lease.isValid, self.isCurrent(display: display, revision: revision) else { return }
                completion(value, value == nil ? .unavailable : .software,
                           value == nil ? "Software dimming is unavailable on this screen." : nil)
            }
            return
        }
        queue.async {
            guard lease.isValid else { return }
            let value = display.isBuiltIn
                ? self.native.read(displayID: display.id)
                : self.ddcRead(display.id)
            DispatchQueue.main.async {
                guard lease.isValid, self.isCurrent(display: display, revision: revision) else { return }
                if let value = Self.normalized(value) {
                    completion(value, display.isBuiltIn ? .native : .ddc, nil)
                } else if display.supportsSoftwareDimming,
                          let level = Self.normalized(self.software.read(display: display)) {
                    self.softwareDisplayIDs.insert(display.persistentID)
                    completion(level, .software, nil)
                } else {
                    completion(nil, .unavailable, "Brightness control is unavailable on this connection.")
                }
            }
        }
    }

    func set(_ value: Double, display: ManagedDisplay, completion: @escaping (Bool) -> Void) {
        let (_, lease) = beginRequest(display: display)
        guard let value = Self.normalized(value) else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        if display.supportsSoftwareDimming && softwareDisplayIDs.contains(display.persistentID) {
            let success = software.set(value, display: display)
            DispatchQueue.main.async { completion(success && lease.isValid) }
            return
        }
        queue.async {
            guard lease.isValid else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let success = display.isBuiltIn
                ? self.native.set(value, displayID: display.id)
                : self.ddcSet(value, display.id)
            DispatchQueue.main.async { completion(success && lease.isValid) }
        }
    }

    func resetSoftwareDimming(persistentID: String) {
        leases.removeValue(forKey: persistentID)?.invalidate()
        revisions[persistentID, default: 0] &+= 1
        softwareDisplayIDs.remove(persistentID)
        software.reset(persistentID: persistentID)
    }

    func suspendSoftwareDimming() { software.suspend() }

    func retainSoftwareDimming(for displays: [ManagedDisplay]) {
        let current = Dictionary(displays.map { ($0.persistentID, BrightnessConnection($0)) },
                                 uniquingKeysWith: { _, latest in latest })
        for (persistentID, connection) in connections where current[persistentID] != connection {
            resetSoftwareDimming(persistentID: persistentID)
        }
        connections = current
        let eligible = Set(displays.filter(\.supportsSoftwareDimming).map(\.persistentID))
        for persistentID in softwareDisplayIDs.subtracting(eligible) {
            resetSoftwareDimming(persistentID: persistentID)
        }
        software.retainOnly(eligible)
    }

    private func beginRequest(display: ManagedDisplay) -> (UInt64, BrightnessConnectionLease) {
        let connection = BrightnessConnection(display)
        if let previous = connections[display.persistentID], previous != connection {
            resetSoftwareDimming(persistentID: display.persistentID)
        }
        connections[display.persistentID] = connection
        let lease = leases[display.persistentID] ?? BrightnessConnectionLease()
        leases[display.persistentID] = lease
        revisions[display.persistentID, default: 0] &+= 1
        return (revisions[display.persistentID, default: 0], lease)
    }

    private func isCurrent(display: ManagedDisplay, revision: UInt64) -> Bool {
        revisions[display.persistentID, default: 0] == revision &&
            connections[display.persistentID] == BrightnessConnection(display)
    }

    private static func normalized(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(1, max(0, value))
    }
}

private final class BrightnessConnectionLease {
    private let lock = NSLock()
    private var valid = true

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        valid = false
    }
}

private struct BrightnessConnection: Equatable {
    let displayID: CGDirectDisplayID
    let isBuiltIn: Bool
    let isMirrored: Bool
    let profile: DisplayProfile
    let model: DisplayProfile
    let reportedName: String

    init(_ display: ManagedDisplay) {
        displayID = display.id
        isBuiltIn = display.isBuiltIn
        isMirrored = display.isMirrored
        profile = display.profile
        model = display.model
        reportedName = display.reportedName
    }
}

private final class NativeBrightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private let libraryHandle: UnsafeMutableRawPointer?
    private let getter: Get?
    private let setter: Set?

    init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_NOW) else {
            libraryHandle = nil
            getter = nil
            setter = nil
            return
        }
        libraryHandle = handle
        getter = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Get.self) }
        setter = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Set.self) }
    }

    deinit {
        if let libraryHandle { dlclose(libraryHandle) }
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
