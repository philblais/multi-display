import AppKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject private var store: DisplayStore
    @State private var setupName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Multi Display").font(.title3.bold())
                    Text("Your screens, one place").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh displays")
            }

            if !NSRunningApplication.runningApplications(withBundleIdentifier: "pro.betterdisplay.BetterDisplay").isEmpty {
                Label("BetterDisplay is running. It may override brightness or display changes during testing.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let pending = store.pendingChange {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(pending).font(.caption).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("Keep") { store.confirmChange() }
                                    .buttonStyle(.borderedProminent)
                                Button("Revert") { store.revertChange() }
                            }
                        }
                        .padding(10)
                        .background(.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                    }

                    if let notice = store.notice {
                        Label(notice, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .onTapGesture { store.notice = nil }
                    }

                    if store.displays.isEmpty {
                        ContentUnavailableView("No displays found", systemImage: "display.2", description: Text("Open this app in your desktop session, then refresh."))
                            .frame(height: 180)
                    } else {
                        sharedBrightness
                        keyboardBrightness
                        VStack(spacing: 10) {
                            ForEach(store.displays) { display in
                                DisplayCard(display: display)
                            }
                        }
                        savedSetups
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Reveal screens") { store.revealDimmedScreens() }
                    .buttonStyle(.borderless)
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .frame(width: menuSize.width, height: menuSize.height)
    }

    private var menuSize: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 900)
        return CGSize(
            width: min(680, max(360, screen.width - 64)),
            height: min(860, max(360, screen.height - 80))
        )
    }

    private var sharedBrightness: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("All screens", systemImage: "sun.max")
                Spacer()
                Text("\(Int(store.sharedBrightness * 100))%")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $store.sharedBrightness, in: 0...1, onEditingChanged: { editing in
                if !editing { store.commitSharedBrightness() }
            })
            .disabled(!store.displays.contains { $0.brightness != nil })
        }
    }

    private var keyboardBrightness: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Use brightness keys for one display", isOn: Binding(
                get: { store.keyboardControlEnabled },
                set: { store.setKeyboardControlEnabled($0) }
            ))
            if store.keyboardControlEnabled {
                Picker("Target screen", selection: Binding(
                    get: { store.keyboardTarget },
                    set: { store.setKeyboardTarget($0) }
                )) {
                    ForEach(KeyboardDisplayTarget.allCases) { target in
                        Text(target.title).tag(target)
                    }
                }
                .pickerStyle(.menu)
                Text("F1/F2 changes only the selected screen. Mirrored screens use macOS controls.")
                    .font(.caption2).foregroundStyle(.secondary)
                if let status = store.keyboardStatus {
                    Text(status).font(.caption).foregroundStyle(.orange)
                    Button("Retry") { store.retryKeyboardControl() }
                }
            }
        }
    }

    private var savedSetups: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved setups").font(.headline)
            HStack {
                TextField("Name this setup", text: $setupName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save") { save() }
                    .disabled(setupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(store.setups) { setup in
                HStack {
                    Text(setup.name).lineLimit(1)
                    Spacer()
                    Button("Apply") { store.applySetup(setup) }
                    Button { store.deleteSetup(setup) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete setup")
                }
            }
        }
    }

    private func save() {
        store.saveSetup(name: setupName)
        setupName = ""
    }
}

private struct DisplayCard: View {
    @EnvironmentObject private var store: DisplayStore
    let display: ManagedDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : display.model == .automatic ? "display" : "tv")
                Text(display.name).font(.headline)
                Spacer()
                Text(display.isBuiltIn ? "Built in" : display.model == .automatic ? "External" : "TV")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if !display.isBuiltIn {
                Picker("Display model", selection: Binding(
                    get: { display.profile },
                    set: { store.setDisplayProfile(displayID: display.id, profile: $0) }
                )) {
                    ForEach(DisplayProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .pickerStyle(.menu)
                .font(.caption)
            }

            HStack {
                Text(display.brightnessControl == .software ? "Software dimming" : "Brightness")
                Spacer()
                if let value = display.brightness {
                    Text("\(Int(value * 100))%")
                        .monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text("Unavailable").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            Slider(value: Binding(
                get: { store.displays.first(where: { $0.id == display.id })?.brightness ?? 0.5 },
                set: { store.editBrightness(displayID: display.id, value: $0) }
            ), in: 0...1, onEditingChanged: { editing in
                if !editing { store.commitBrightness(displayID: display.id) }
            })
            .disabled(display.brightness == nil)
            if display.brightnessControl == .software {
                Text("Dims the Mac image; adjust the TV's backlight with its remote. Reveal screens clears dimming.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = display.brightnessError {
                Text(error).font(.caption2).foregroundStyle(.secondary)
            }

            HStack {
                Text("Resolution").font(.caption)
                Spacer()
                Menu {
                    ForEach(display.modes) { option in
                        Button(option.title) { store.setMode(displayID: display.id, optionID: option.id) }
                    }
                } label: {
                    Text(currentModeTitle).lineLimit(1)
                }
                .disabled(display.modes.isEmpty)
            }

            HStack {
                Text("Rotation").font(.caption)
                Spacer()
                Menu {
                    ForEach([0, 90, 180, 270], id: \.self) { value in
                        Button("\(value)°") { store.setRotation(displayID: display.id, degrees: value) }
                    }
                } label: {
                    Text("\(display.rotation)°")
                }
                .disabled(display.isBuiltIn)
            }

            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 3) {
                    if let modelCode = display.model.modelCode {
                        Text("Model code: \(modelCode)")
                    }
                    Text("macOS name: \(display.reportedName)")
                    Text("Brightness control: \(display.brightnessControl.title)")
                    Text("Display ID: \(display.id)")
                    Text("Persistent ID: \(display.persistentID)")
                    Text("Mode: \(currentModeTitle)")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            .font(.caption2)
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private var currentModeTitle: String {
        guard let signature = display.currentMode else { return "Unavailable" }
        return display.modes.first(where: { signature.matches($0.mode) })?.title
            ?? "\(signature.width) × \(signature.height)"
    }
}
