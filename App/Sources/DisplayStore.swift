import Combine
import CoreGraphics
import Foundation

final class DisplayStore: ObservableObject {
    @Published private(set) var displays: [ManagedDisplay] = []
    @Published private(set) var setups: [SavedSetup] = []
    @Published var sharedBrightness: Double = 0.5
    @Published var notice: String?
    @Published private(set) var pendingChange: String?
    @Published private(set) var keyboardControlEnabled = UserDefaults.standard.bool(forKey: "keyboardBrightnessEnabled")
    @Published private(set) var keyboardTarget = KeyboardDisplayTarget(rawValue: UserDefaults.standard.string(forKey: "keyboardBrightnessTarget") ?? "") ?? .pointer
    @Published private(set) var keyboardStatus: String?
    @Published private(set) var hasBlackout = false

    private let brightness = BrightnessController()
    private let blackout = DisplayBlackoutController()
    private let brightnessHUD = BrightnessHUDController()
    private let keyboard = KeyboardBrightnessController()
    private let rotation = RotationController()
    private let storage = SetupStorage()
    private var pending: PendingChange?
    private var pendingProfile: PendingProfile?
    private var activeApplyToken: UUID?
    private var refreshWork: DispatchWorkItem?
    private var keyboardDesiredValues: [CGDirectDisplayID: Double] = [:]
    private var keyboardInFlight: Set<CGDirectDisplayID> = []
    private var keyboardBlockedIDs: Set<CGDirectDisplayID> = []
    private var brightnessRevision: [CGDirectDisplayID: UInt64] = [:]
    private var savedBlackoutIDs = Set(UserDefaults.standard.stringArray(forKey: "blackoutDisplayIDs") ?? [])
    private var activeBlackoutIDs: Set<String> = []
    private var blackoutSafetyTimer: Timer?

    init() {
        setups = storage.load()
        keyboard.target = keyboardTarget
        keyboard.canControl = { [weak self] displayID in self?.canControlWithKeyboard(displayID) == true }
        keyboard.adjust = { [weak self] displayID, direction, fineStep in
            self?.adjustKeyboardBrightness(displayID: displayID, direction: direction, fineStep: fineStep)
        }
        if keyboardControlEnabled { startKeyboardControl(promptForPermission: false) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, context)
        blackoutSafetyTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.blackout.hasVisiblePanels && !self.hasBlackout {
                self.blackout.hideAll()
                self.notice = "A lingering black screen was cleared."
            }
            self.blackout.retainOnly(self.activeBlackoutIDs.intersection(Set(self.displays.map(\.persistentID))))
            if self.hasBlackout && self.keyboardControlEnabled && !self.keyboard.canRecover {
                self.revealDimmedScreens()
                self.notice = "The black screen was cleared because keyboard recovery is unavailable."
            }
        }
        refresh()
    }

    deinit {
        blackoutSafetyTimer?.invalidate()
        blackout.hideAll()
        keyboard.stop()
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    func scheduleRefresh() {
        blackout.hideAll()
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func refresh() {
        keyboardBlockedIDs.removeAll()
        let previous = Dictionary(uniqueKeysWithValues: displays.map { ($0.persistentID, $0) })
        displays = DisplayInventory.scan().map { display in
            var copy = display
            copy.brightness = activeBlackoutIDs.contains(display.persistentID) ? 0 : previous[display.persistentID]?.brightness
            return copy
        }
        reconcileBlackouts()
        for display in displays {
            let revision = brightnessRevision[display.id, default: 0]
            brightness.read(display: display) { [weak self] value, error in
                guard let self, let index = self.index(for: display.id) else { return }
                guard self.brightnessRevision[display.id, default: 0] == revision else { return }
                guard !self.keyboardInFlight.contains(display.id) else { return }
                self.displays[index].brightness = self.activeBlackoutIDs.contains(display.persistentID) ? 0 : value
                self.displays[index].brightnessError = error
                self.updateSharedBrightness()
            }
        }
    }

    func editBrightness(displayID: CGDirectDisplayID, value: Double) {
        guard let index = index(for: displayID) else { return }
        brightnessRevision[displayID, default: 0] &+= 1
        displays[index].brightness = value
    }

    func commitBrightness(displayID: CGDirectDisplayID) {
        guard let display = displays.first(where: { $0.id == displayID }), let value = display.brightness else { return }
        keyboardDesiredValues.removeValue(forKey: displayID)
        updateBlackout(display: display, value: value)
        brightness.set(value, display: display) { [weak self] success in
            if !success { self?.notice = "Could not change the brightness of \(display.name)." }
            self?.refresh()
        }
    }

    func commitSharedBrightness() {
        let value = sharedBrightness
        let controllable = displays.filter { $0.brightness != nil }
        var remaining = controllable.count
        for display in controllable {
            keyboardDesiredValues.removeValue(forKey: display.id)
            editBrightness(displayID: display.id, value: value)
            updateBlackout(display: display, value: value)
            brightness.set(value, display: display) { [weak self] success in
                if !success { self?.notice = "Could not change the brightness of \(display.name)." }
                remaining -= 1
                if remaining == 0 { self?.refresh() }
            }
        }
    }

    func setKeyboardControlEnabled(_ enabled: Bool) {
        keyboardControlEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "keyboardBrightnessEnabled")
        if enabled {
            keyboardBlockedIDs.removeAll()
            startKeyboardControl(promptForPermission: true)
        } else {
            if hasBlackout || blackout.hasVisiblePanels || !savedBlackoutIDs.isEmpty { revealDimmedScreens() }
            keyboard.stop()
            keyboardDesiredValues.removeAll()
            keyboardStatus = nil
        }
    }

    func retryKeyboardControl() {
        guard keyboardControlEnabled else { return }
        startKeyboardControl(promptForPermission: true)
    }

    func setKeyboardTarget(_ target: KeyboardDisplayTarget) {
        keyboardTarget = target
        keyboard.target = target
        UserDefaults.standard.set(target.rawValue, forKey: "keyboardBrightnessTarget")
    }

    private func startKeyboardControl(promptForPermission: Bool) {
        keyboardStatus = keyboard.start(promptForPermission: promptForPermission) ? nil
            : "Allow Multi Display in System Settings → Privacy & Security → Accessibility, then choose Retry."
        if keyboardStatus == nil { reconcileBlackouts() }
    }

    func revealDimmedScreens() {
        let affected = displays.filter { activeBlackoutIDs.contains($0.persistentID) }
        activeBlackoutIDs.removeAll()
        savedBlackoutIDs.removeAll()
        UserDefaults.standard.removeObject(forKey: "blackoutDisplayIDs")
        blackout.hideAll()
        hasBlackout = false
        for display in affected {
            guard let index = index(for: display.id) else { continue }
            let recoveryLevel = 1.0 / 16.0
            brightnessRevision[display.id, default: 0] &+= 1
            displays[index].brightness = recoveryLevel
            keyboardDesiredValues.removeValue(forKey: display.id)
            brightness.set(recoveryLevel, display: display) { [weak self] success in
                if !success { self?.notice = "The black screen was cleared, but hardware brightness could not be raised for \(display.name)." }
                self?.refresh()
            }
        }
        updateSharedBrightness()
    }

    private func updateBlackout(display: ManagedDisplay, value: Double) {
        guard !display.isBuiltIn else { return }
        if value <= 0 {
            activeBlackoutIDs.insert(display.persistentID)
            savedBlackoutIDs.insert(display.persistentID)
            blackout.setBlackout(true, display: display)
        } else {
            activeBlackoutIDs.remove(display.persistentID)
            savedBlackoutIDs.remove(display.persistentID)
            blackout.setBlackout(false, display: display)
        }
        UserDefaults.standard.set(Array(savedBlackoutIDs), forKey: "blackoutDisplayIDs")
        hasBlackout = !activeBlackoutIDs.isEmpty
    }

    private func reconcileBlackouts() {
        let connected = Set(displays.map(\.persistentID))
        if keyboardControlEnabled && keyboard.isRunning {
            activeBlackoutIDs.formUnion(savedBlackoutIDs)
        } else {
            activeBlackoutIDs.formIntersection(connected)
        }
        let mirrored = Set(displays.filter {
            CGDisplayIsInMirrorSet($0.id) != 0 || CGDisplayIsInHWMirrorSet($0.id) != 0
        }.map(\.persistentID))
        activeBlackoutIDs.subtract(mirrored)
        savedBlackoutIDs.subtract(mirrored)
        UserDefaults.standard.set(Array(savedBlackoutIDs), forKey: "blackoutDisplayIDs")

        blackout.retainOnly(activeBlackoutIDs.intersection(connected))
        for index in displays.indices where activeBlackoutIDs.contains(displays[index].persistentID) {
            displays[index].brightness = 0
            blackout.setBlackout(true, display: displays[index])
        }
        hasBlackout = !activeBlackoutIDs.isDisjoint(with: connected)
    }

    private func canControlWithKeyboard(_ displayID: CGDirectDisplayID) -> Bool {
        if blackout.hasVisiblePanel(on: displayID) { return true }
        if let display = displays.first(where: { $0.id == displayID }),
           activeBlackoutIDs.contains(display.persistentID) { return true }
        guard !keyboardBlockedIDs.contains(displayID),
              let display = displays.first(where: { $0.id == displayID }),
              display.brightness != nil else { return false }
        return CGDisplayIsInMirrorSet(displayID) == 0 && CGDisplayIsInHWMirrorSet(displayID) == 0
    }

    private func adjustKeyboardBrightness(displayID: CGDirectDisplayID, direction: Int, fineStep: Bool) {
        guard keyboardControlEnabled, canControlWithKeyboard(displayID), let index = index(for: displayID) else { return }
        let displayName = displays[index].name
        let current = keyboardDesiredValues[displayID] ?? displays[index].brightness ?? 0.5
        let step = fineStep ? 1.0 / 64.0 : 1.0 / 16.0
        let desired = min(1, max(0, current + Double(direction) * step))
        brightnessHUD.show(displayID: displayID, name: displayName, level: desired)
        guard desired != current else { return }
        let display = displays[index]
        updateBlackout(display: display, value: desired)
        brightnessRevision[displayID, default: 0] &+= 1
        keyboardDesiredValues[displayID] = desired
        displays[index].brightness = desired
        updateSharedBrightness()
        sendKeyboardBrightnessIfNeeded(displayID: displayID)
    }

    private func sendKeyboardBrightnessIfNeeded(displayID: CGDirectDisplayID) {
        guard !keyboardInFlight.contains(displayID),
              let value = keyboardDesiredValues[displayID],
              let display = displays.first(where: { $0.id == displayID }) else { return }
        keyboardInFlight.insert(displayID)
        brightness.set(value, display: display) { [weak self] success in
            guard let self else { return }
            if !success {
                self.keyboardInFlight.remove(displayID)
                self.keyboardDesiredValues.removeValue(forKey: displayID)
                self.keyboardBlockedIDs.insert(displayID)
                self.notice = "Could not change brightness for \(display.name). Keyboard control for this screen is paused until Refresh."
                self.brightnessHUD.showUnavailable(displayID: displayID, name: display.name)
                let revision = self.brightnessRevision[displayID, default: 0]
                self.brightness.read(display: display) { [weak self] actual, error in
                    guard let self, let index = self.index(for: displayID) else { return }
                    guard self.brightnessRevision[displayID, default: 0] == revision else { return }
                    self.displays[index].brightness = actual
                    self.displays[index].brightnessError = error
                    self.updateSharedBrightness()
                }
                return
            }
            guard let latest = self.keyboardDesiredValues[displayID], latest != value else {
                self.keyboardInFlight.remove(displayID)
                self.keyboardDesiredValues.removeValue(forKey: displayID)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.keyboardInFlight.remove(displayID)
                self?.sendKeyboardBrightnessIfNeeded(displayID: displayID)
            }
        }
    }

    func setMode(displayID: CGDirectDisplayID, optionID: String) {
        guard pending == nil, pendingProfile == nil else {
            notice = "Keep or revert the current change first."
            return
        }
        guard let display = displays.first(where: { $0.id == displayID }),
              let option = display.modes.first(where: { $0.id == optionID }) else { return }
        let oldMode = CGDisplayCopyDisplayMode(displayID)
        let result = CGDisplaySetDisplayMode(displayID, option.mode, nil)
        guard result == .success else {
            notice = "macOS could not set that resolution for \(display.name)."
            return
        }
        beginConfirmation(display: display, previousMode: oldMode, previousRotation: display.rotation)
        scheduleRefresh()
    }

    func setRotation(displayID: CGDirectDisplayID, degrees: Int) {
        guard pending == nil, pendingProfile == nil else {
            notice = "Keep or revert the current change first."
            return
        }
        guard rotation.isAvailable else {
            notice = "Rotation needs displayplacer installed on this Mac."
            return
        }
        guard let display = displays.first(where: { $0.id == displayID }), !display.isBuiltIn else { return }
        let oldMode = CGDisplayCopyDisplayMode(displayID)
        rotation.set(degrees, persistentID: display.persistentID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.beginConfirmation(display: display, previousMode: oldMode, previousRotation: display.rotation)
                self.scheduleRefresh()
            case .failure(let error):
                self.notice = error.localizedDescription
            }
        }
    }

    func confirmChange() {
        pending = nil
        pendingProfile = nil
        pendingChange = nil
    }

    func revertChange() {
        if let pendingProfile {
            confirmChange()
            let token = UUID()
            activeApplyToken = token
            let matched = pendingProfile.snapshot.displays.compactMap { saved -> (SavedDisplay, ManagedDisplay)? in
                guard let display = displays.first(where: { $0.persistentID == saved.persistentID }) else { return nil }
                return (saved, display)
            }
            applySetupItems(matched, at: 0, token: token)
            return
        }
        guard let pending else { return }
        confirmChange()
        if let current = displays.first(where: { $0.persistentID == pending.persistentID }), current.rotation != pending.previousRotation {
            rotation.set(pending.previousRotation, persistentID: pending.persistentID) { [weak self] result in
                if case .failure(let error) = result { self?.notice = error.localizedDescription }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.restoreMode(pending) }
            }
        } else {
            restoreMode(pending)
        }
    }

    func saveSetup(name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !displays.isEmpty else { return }
        let values = displays.map {
            SavedDisplay(persistentID: $0.persistentID, name: $0.name,
                         brightness: $0.brightness, mode: $0.currentMode, rotation: $0.rotation)
        }
        setups.append(SavedSetup(id: UUID(), name: cleanName, displays: values))
        storage.save(setups)
    }

    func deleteSetup(_ setup: SavedSetup) {
        setups.removeAll { $0.id == setup.id }
        storage.save(setups)
    }

    func applySetup(_ setup: SavedSetup) {
        guard pending == nil, pendingProfile == nil else {
            notice = "Confirm or revert the current display change first."
            return
        }
        let matched = setup.displays.compactMap { saved -> (SavedDisplay, ManagedDisplay)? in
            guard let display = displays.first(where: { $0.persistentID == saved.persistentID }) else { return nil }
            return (saved, display)
        }
        guard !matched.isEmpty else {
            notice = "None of the screens in this setup are connected."
            return
        }
        let snapshot = SavedSetup(id: UUID(), name: "Previous settings", displays: displays.map {
            SavedDisplay(persistentID: $0.persistentID, name: $0.name,
                         brightness: $0.brightness, mode: $0.currentMode, rotation: $0.rotation)
        })
        beginProfileConfirmation(snapshot: snapshot)
        let token = UUID()
        activeApplyToken = token
        applySetupItems(matched, at: 0, token: token)
    }

    private func applySetupItems(_ items: [(SavedDisplay, ManagedDisplay)], at index: Int, token: UUID) {
        guard activeApplyToken == token else { return }
        guard index < items.count else { activeApplyToken = nil; refresh(); return }
        let (saved, original) = items[index]
        guard displays.contains(where: { $0.persistentID == saved.persistentID }) else {
            applySetupItems(items, at: index + 1, token: token)
            return
        }
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            guard self.activeApplyToken == token else { return }
            self.refresh()
            guard let updated = self.displays.first(where: { $0.persistentID == saved.persistentID }) else {
                self.applySetupItems(items, at: index + 1, token: token)
                return
            }
            if let signature = saved.mode {
                if let option = updated.modes.first(where: { signature.matches($0.mode) }) {
                    if CGDisplaySetDisplayMode(updated.id, option.mode, nil) != .success {
                        self.notice = "Could not restore the resolution of \(updated.name)."
                    }
                } else {
                    self.notice = "The saved resolution is unavailable for \(updated.name)."
                }
            }
            if let value = saved.brightness {
                self.updateBlackout(display: updated, value: value)
                self.brightness.set(value, display: updated) { [weak self] success in
                    guard self?.activeApplyToken == token else { return }
                    if !success { self?.notice = "Could not restore brightness for \(updated.name)." }
                    self?.applySetupItems(items, at: index + 1, token: token)
                }
            } else {
                self.applySetupItems(items, at: index + 1, token: token)
            }
        }
        if !original.isBuiltIn && original.rotation != saved.rotation {
            rotation.set(saved.rotation, persistentID: original.persistentID) { [weak self] result in
                guard self?.activeApplyToken == token else { return }
                if case .failure(let error) = result { self?.notice = error.localizedDescription }
                self?.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: finish)
            }
        } else {
            finish()
        }
    }

    private func beginConfirmation(display: ManagedDisplay, previousMode: CGDisplayMode?, previousRotation: Int) {
        let value = PendingChange(persistentID: display.persistentID,
                                  previousMode: previousMode.map(ModeSignature.init),
                                  previousRotation: previousRotation)
        pending = value
        pendingChange = "Keep the new setting for \(display.name)? It will revert in 15 seconds."
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard self?.pending?.token == value.token else { return }
            self?.revertChange()
        }
    }

    private func beginProfileConfirmation(snapshot: SavedSetup) {
        let value = PendingProfile(snapshot: snapshot)
        pendingProfile = value
        pendingChange = "Keep this setup? It will revert in 35 seconds."
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in
            guard self?.pendingProfile?.token == value.token else { return }
            self?.revertChange()
        }
    }

    private func restoreMode(_ value: PendingChange) {
        if let signature = value.previousMode,
           let current = DisplayInventory.scan().first(where: { $0.persistentID == value.persistentID }),
           let option = current.modes.first(where: { signature.matches($0.mode) }) {
            if CGDisplaySetDisplayMode(current.id, option.mode, nil) != .success {
                notice = "Could not restore the previous resolution of \(current.name)."
            }
        }
        scheduleRefresh()
    }

    private func updateSharedBrightness() {
        let values = displays.compactMap(\.brightness)
        if !values.isEmpty { sharedBrightness = values.reduce(0, +) / Double(values.count) }
    }

    private func index(for id: CGDirectDisplayID) -> Int? { displays.firstIndex { $0.id == id } }
}

private struct PendingChange {
    let token = UUID()
    let persistentID: String
    let previousMode: ModeSignature?
    let previousRotation: Int
}

private struct PendingProfile {
    let token = UUID()
    let snapshot: SavedSetup
}

private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, _, context in
    guard let context else { return }
    let store = Unmanaged<DisplayStore>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { store.scheduleRefresh() }
}
