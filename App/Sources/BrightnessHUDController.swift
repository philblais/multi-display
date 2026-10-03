import AppKit
import Combine
import CoreGraphics
import SwiftUI

final class BrightnessHUDController {
    private let model = BrightnessHUDModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(displayID: CGDirectDisplayID, name: String, level: Double) {
        guard let screen = screen(for: displayID) else { return }
        model.displayName = name
        model.level = level
        model.isUnavailable = false
        present(on: screen)
    }

    func showUnavailable(displayID: CGDirectDisplayID, name: String) {
        guard let screen = screen(for: displayID) else { return }
        model.displayName = name
        model.isUnavailable = true
        present(on: screen)
    }

    private func present(on screen: NSScreen) {
        let panel = panel ?? makePanel()
        self.panel = panel
        let size = panel.frame.size
        let frame = screen.frame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + max(90, frame.height * 0.17)
        ))
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 112),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: BrightnessHUDView(model: model))
        return panel
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }
}

private final class BrightnessHUDModel: ObservableObject {
    @Published var displayName = ""
    @Published var level = 0.5
    @Published var isUnavailable = false
}

private struct BrightnessHUDView: View {
    @ObservedObject var model: BrightnessHUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: model.isUnavailable ? "exclamationmark.triangle" : "sun.max.fill")
                    .font(.title3)
                Text(model.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !model.isUnavailable {
                    Text("\(Int((model.level * 100).rounded()))%")
                        .font(.subheadline.monospacedDigit())
                }
            }
            if model.isUnavailable {
                Text("Brightness unavailable")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            } else {
                ProgressView(value: model.level, total: 1)
                    .tint(.white)
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(width: 280, height: 112)
        .background(RoundedRectangle(cornerRadius: 18).fill(.black.opacity(0.82)))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}
