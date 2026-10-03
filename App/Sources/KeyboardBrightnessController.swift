import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum KeyboardDisplayTarget: String, CaseIterable, Identifiable {
    case pointer
    case keyboardFocus

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pointer: return "Display under pointer"
        case .keyboardFocus: return "Display with keyboard focus"
        }
    }
}

final class KeyboardBrightnessController {
    var target: KeyboardDisplayTarget = .pointer
    var canControl: ((CGDirectDisplayID) -> Bool)?
    var adjust: ((CGDirectDisplayID, Int, Bool) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var targetsByKey: [Int: CGDirectDisplayID] = [:]

    var isRunning: Bool { tap.map(CGEvent.tapIsEnabled(tap:)) ?? false }
    var canRecover: Bool { isRunning && AXIsProcessTrusted() }

    func start(promptForPermission: Bool) -> Bool {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return CGEvent.tapIsEnabled(tap: tap)
        }
        let trusted: Bool
        if promptForPermission {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(options)
        } else {
            trusted = AXIsProcessTrusted()
        }
        guard trusted else { return false }

        // NX_SYSDEFINED is 14. Only media-key events enter this active filter.
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << 14),
            callback: keyboardBrightnessEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            return false
        }
        tap = port
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return CGEvent.tapIsEnabled(tap: port)
    }

    func stop() {
        targetsByKey.removeAll()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    deinit { stop() }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14,
              let mediaEvent = NSEvent(cgEvent: event),
              mediaEvent.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }

        let data = mediaEvent.data1
        let key = (data >> 16) & 0xFFFF
        guard key == 2 || key == 3 else { return Unmanaged.passUnretained(event) }
        let state = (data >> 8) & 0xFF
        if state == 0xB {
            return targetsByKey.removeValue(forKey: key) == nil ? Unmanaged.passUnretained(event) : nil
        }
        guard state == 0xA else { return Unmanaged.passUnretained(event) }

        let modifiers = mediaEvent.modifierFlags
        let direction = key == 2 ? 1 : -1
        let fineStep = modifiers.contains(.option) && modifiers.contains(.shift)
        if let latchedDisplayID = targetsByKey[key] {
            if canControl?(latchedDisplayID) == true {
                DispatchQueue.main.async { [weak self] in self?.adjust?(latchedDisplayID, direction, fineStep) }
            }
            return nil
        }
        if modifiers.contains(.option) && !modifiers.contains(.shift) {
            return Unmanaged.passUnretained(event)
        }
        let displayID = selectedDisplayID()
        guard let displayID, canControl?(displayID) == true else {
            return Unmanaged.passUnretained(event)
        }
        targetsByKey[key] = displayID
        DispatchQueue.main.async { [weak self] in self?.adjust?(displayID, direction, fineStep) }
        return nil
    }

    private func selectedDisplayID() -> CGDirectDisplayID? {
        let screen: NSScreen?
        switch target {
        case .pointer:
            screen = screenUnderPointer()
        case .keyboardFocus:
            screen = NSScreen.main ?? screenUnderPointer()
        }
        return screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}

private let keyboardBrightnessEventCallback: CGEventTapCallBack = { _, type, event, context in
    guard let context else { return Unmanaged.passUnretained(event) }
    return Unmanaged<KeyboardBrightnessController>.fromOpaque(context).takeUnretainedValue()
        .handle(type: type, event: event)
}
