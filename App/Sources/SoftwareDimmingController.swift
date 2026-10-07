import AppKit
import CoreGraphics

protocol SoftwareBrightnessControlling: AnyObject {
    func read(display: ManagedDisplay) -> Double?
    func set(_ value: Double, display: ManagedDisplay) -> Bool
    func reset(persistentID: String)
    func suspend()
    func retainOnly(_ persistentIDs: Set<String>)
}

final class SoftwareDimmingController: SoftwareBrightnessControlling {
    private var levels: [String: Double] = [:]
    private var panels: [String: NSPanel] = [:]

    func read(display: ManagedDisplay) -> Double? {
        let value = levels[display.persistentID] ?? 1
        return set(value, display: display) ? value : nil
    }

    func set(_ value: Double, display: ManagedDisplay) -> Bool {
        guard display.supportsSoftwareDimming,
              CGDisplayIsInMirrorSet(display.id) == 0,
              CGDisplayIsInHWMirrorSet(display.id) == 0,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.id
              }) else { return false }
        let level = min(1, max(0, value))
        levels[display.persistentID] = level
        guard level < 1 else {
            dismissPanel(persistentID: display.persistentID)
            return true
        }
        let panel = panels[display.persistentID] ?? makePanel()
        panels[display.persistentID] = panel
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 1 - level
        panel.orderFrontRegardless()
        return true
    }

    func reset(persistentID: String) {
        levels.removeValue(forKey: persistentID)
        dismissPanel(persistentID: persistentID)
    }

    // Clear overlays immediately during a screen rearrangement, then restore
    // their levels against the new screen frames when the inventory refreshes.
    func suspend() {
        for persistentID in Array(panels.keys) { dismissPanel(persistentID: persistentID) }
    }

    func retainOnly(_ persistentIDs: Set<String>) {
        for persistentID in Set(levels.keys).union(panels.keys).subtracting(persistentIDs) {
            reset(persistentID: persistentID)
        }
    }

    deinit { suspend() }

    private func dismissPanel(persistentID: String) {
        guard let panel = panels.removeValue(forKey: persistentID) else { return }
        panel.alphaValue = 0
        panel.orderOut(nil)
        panel.close()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}
