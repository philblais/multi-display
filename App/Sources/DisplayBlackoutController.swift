import AppKit
import CoreGraphics
import os

final class DisplayBlackoutController {
    private let logger = Logger(subsystem: "personal.phib.MultiDisplayManagement", category: "Blackout")
    private let identifierPrefix = "personal.phib.MultiDisplayManagement.blackout."
    private var panels: [String: NSPanel] = [:]
    private var retiringPanels: [NSPanel] = []

    var hasVisiblePanels: Bool {
        NSApp.windows.contains { isBlackoutPanel($0) && $0.isVisible && $0.alphaValue > 0 }
    }

    func hasVisiblePanel(on displayID: CGDirectDisplayID) -> Bool {
        guard let frame = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        })?.frame else { return false }
        return NSApp.windows.contains {
            isBlackoutPanel($0) && $0.isVisible && $0.alphaValue > 0 && $0.frame.intersects(frame)
        }
    }

    func setBlackout(_ active: Bool, display: ManagedDisplay) {
        guard !display.isBuiltIn else { return }
        guard active else {
            dismissPanels(for: display)
            return
        }
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.id
        }) else { return }

        let panel = panels[display.persistentID] ?? makePanel(persistentID: display.persistentID)
        panels[display.persistentID] = panel
        panel.alphaValue = 1
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
    }

    func hideAll() {
        dismissUnique(Array(panels.values) + NSApp.windows.filter(isBlackoutPanel))
        panels.removeAll()
    }

    func retainOnly(_ persistentIDs: Set<String>) {
        let stale = Array(panels.values).filter {
            !persistentIDs.contains(persistentID(for: $0) ?? "")
        }
        let orphaned = NSApp.windows.filter {
            isBlackoutPanel($0) && !persistentIDs.contains(persistentID(for: $0) ?? "")
        }
        dismissUnique(stale + orphaned)
        panels = panels.filter { persistentIDs.contains($0.key) }
    }

    deinit { hideAll() }

    private func dismissPanels(for display: ManagedDisplay) {
        let targetFrame = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.id
        })?.frame
        var candidates = [NSWindow]()
        if let panel = panels[display.persistentID] { candidates.append(panel) }
        candidates += NSApp.windows.filter { panel in
            isBlackoutPanel(panel) &&
            (panel.identifier?.rawValue == identifierPrefix + display.persistentID ||
             (targetFrame.map { panel.frame.intersects($0) } ?? false))
        }
        dismissUnique(candidates)
        panels.removeValue(forKey: display.persistentID)
    }

    private func dismissUnique(_ windows: [NSWindow]) {
        var seen = Set<ObjectIdentifier>()
        for window in windows where seen.insert(ObjectIdentifier(window)).inserted {
            dismiss(window)
        }
    }

    private func dismiss(_ panel: NSWindow) {
        logger.debug("Dismissing blackout window \(panel.windowNumber), visible=\(panel.isVisible)")
        panel.alphaValue = 0
        panel.orderOut(nil)
        panel.close()
        if let panel = panel as? NSPanel {
            guard !retiringPanels.contains(where: { $0 === panel }) else { return }
            retiringPanels.append(panel)
            DispatchQueue.main.async { [weak self, weak panel] in
                guard let self, let panel else { return }
                if panel.isVisible {
                    self.logger.error("Blackout window \(panel.windowNumber) remained visible; forcing it off screen")
                    panel.alphaValue = 0
                    panel.setFrame(.zero, display: false)
                    panel.orderOut(nil)
                    panel.close()
                }
                self.retiringPanels.removeAll { $0 === panel }
            }
        }
    }

    private func isBlackoutPanel(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(identifierPrefix) == true
    }

    private func persistentID(for window: NSWindow) -> String? {
        guard let identifier = window.identifier?.rawValue, identifier.hasPrefix(identifierPrefix) else { return nil }
        return String(identifier.dropFirst(identifierPrefix.count))
    }

    private func makePanel(persistentID: String) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier(identifierPrefix + persistentID)
        panel.animationBehavior = .none
        panel.isOpaque = true
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
