import Combine
import CoreGraphics
import Foundation

final class DisplayStore: ObservableObject {
    @Published private(set) var displays: [ManagedDisplay] = []
    @Published private(set) var setups: [SavedSetup] = []
    @Published var sharedBrightness: Double = 0.5
    @Published var notice: String?
    @Published private var configuration: ConfigurationState = .idle
    var pendingChange: String? {
        switch configuration {
        case .awaitingChange(let change): return "Keep the new setting for \(change.name)? It will revert in 15 seconds."
        case .awaitingSetup: return "Keep this setup? It will revert in 35 seconds."
        default: return nil
        }
    }
    var isApplyingConfiguration: Bool {
        switch configuration {
        case .applying, .reverting: return true
        default: return false
        }
    }
    @Published private(set) var keyboardControlEnabled: Bool
    @Published private(set) var keyboardTarget: KeyboardDisplayTarget
    @Published private(set) var keyboardStatus: String?
    @Published private(set) var hasBlackout = false

    private let brightness: BrightnessController
    private let blackout = DisplayBlackoutController()
    private let brightnessHUD = BrightnessHUDController()
    private let keyboard = KeyboardBrightnessController()
    private let rotation: DisplayRotating
    private let storage: SetupStorage
    private let defaults: UserDefaults
    private let scan: ([String: String]) -> [ManagedDisplay]
    private let systemMonitoring: Bool
    private let configurationSettleDelay: TimeInterval
    private var refreshGeneration: UInt64 = 0
    private var skipSetupBrightness = false
    private var pending: PendingChange? {
        if case .awaitingChange(let value) = configuration { return value }
        return nil
    }
    private var pendingProfile: PendingProfile? {
        if case .awaitingSetup(let value) = configuration { return value }
        return nil
    }
    private var activeApplyToken: UUID? {
        switch configuration {
        case .applying(let token), .reverting(let token): return token
        default: return nil
        }
    }
    private let recoveryCheck: (() -> Bool)?
    private let mirrorCheck: (ManagedDisplay) -> Bool
    private var refreshWork: DispatchWorkItem?
    private var keyboardDesiredValues: [CGDirectDisplayID: Double] = [:]
    private var keyboardInFlight: Set<CGDirectDisplayID> = []
    private var keyboardBlockedIDs: Set<CGDirectDisplayID> = []
    private var brightnessRevision: [CGDirectDisplayID: UInt64] = [:]
    private var brightnessEdits: Set<CGDirectDisplayID> = []
    private var isEditingSharedBrightness = false
    private var savedBlackoutIDs: Set<String>
    private var activeBlackoutIDs: Set<String> = []
    private var blackoutSafetyTimer: Timer?

    init(brightness: BrightnessController = BrightnessController(),
         rotation: DisplayRotating = RotationController(), defaults: UserDefaults = .standard,
         scan: @escaping ([String: String]) -> [ManagedDisplay] = { DisplayInventory.scan(profileOverrides: $0) },
         systemMonitoring: Bool = true, configurationSettleDelay: TimeInterval = 0.8,
         recoveryCheck: (() -> Bool)? = nil,
         mirrorCheck: @escaping (ManagedDisplay) -> Bool = {
             $0.isMirrored || CGDisplayIsInMirrorSet($0.id) != 0 || CGDisplayIsInHWMirrorSet($0.id) != 0
         }) {
        self.brightness = brightness
        self.rotation = rotation
        self.defaults = defaults
        self.scan = scan
        self.systemMonitoring = systemMonitoring
        self.recoveryCheck = recoveryCheck
        self.mirrorCheck = mirrorCheck
        self.configurationSettleDelay = configurationSettleDelay
        storage = SetupStorage(defaults: defaults)
        keyboardControlEnabled = defaults.object(forKey: "keyboardBrightnessEnabled") as? Bool ?? true
        keyboardTarget = KeyboardDisplayTarget(rawValue: defaults.string(forKey: "keyboardBrightnessTarget") ?? "") ?? .pointer
        savedBlackoutIDs = Set(defaults.stringArray(forKey: "blackoutDisplayIDs") ?? [])
        setups = storage.load()
        keyboard.target = keyboardTarget
        keyboard.canControl = { [weak self] displayID in self?.canControlWithKeyboard(displayID) == true }
        keyboard.adjust = { [weak self] displayID, direction, fineStep in
            self?.adjustKeyboardBrightness(displayID: displayID, direction: direction, fineStep: fineStep)
        }
        if systemMonitoring {
            if keyboardControlEnabled { startKeyboardControl(promptForPermission: false) }
            let context = Unmanaged.passUnretained(self).toOpaque()
            CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, context)
            blackoutSafetyTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.checkBlackoutSafety()
            }
        }
        refresh()
    }

    deinit {
        blackoutSafetyTimer?.invalidate()
        blackout.hideAll()
        keyboard.stop()
        if systemMonitoring {
            CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    func scheduleRefresh() {
        brightnessEdits.removeAll()
        blackout.hideAll()
        brightness.suspendSoftwareDimming()
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func refresh() {
        refreshWork?.cancel()
        refreshWork = nil
        refreshGeneration &+= 1
        let generation = refreshGeneration
        keyboardBlockedIDs.removeAll()
        let previous = Dictionary(displays.map { ($0.persistentID, $0) }, uniquingKeysWith: { first, _ in first })
        let overrides = defaults.dictionary(forKey: "displayProfileOverrides") as? [String: String] ?? [:]
        displays = scan(overrides).map { display in
            var copy = display
            copy.brightness = activeBlackoutIDs.contains(display.persistentID) ? 0 : previous[display.persistentID]?.brightness
            copy.brightnessControl = previous[display.persistentID]?.brightnessControl ?? .unavailable
            return copy
        }
        brightnessEdits = brightnessEdits.filter { id in
            guard let current = displays.first(where: { $0.id == id }),
                  let old = previous[current.persistentID] else { return false }
            return old.id == current.id && old.profile == current.profile && old.isMirrored == current.isMirrored
        }
        brightness.retainSoftwareDimming(for: displays)
        reconcileBlackouts()
        for display in displays {
            refreshBrightness(display: display, generation: generation)
        }
    }

    private func refreshBrightness(display: ManagedDisplay, generation: UInt64? = nil) {
        guard !brightnessEdits.contains(display.id) else { return }
        let revision = brightnessRevision[display.id, default: 0]
        brightness.read(display: display) { [weak self] value, control, error in
            guard let self, let index = self.index(for: display.id) else { return }
            if let generation, self.refreshGeneration != generation { return }
            guard self.displays[index].persistentID == display.persistentID,
                  self.displays[index].profile == display.profile,
                  self.displays[index].isMirrored == display.isMirrored,
                  self.brightnessRevision[display.id, default: 0] == revision,
                  !self.keyboardInFlight.contains(display.id),
                  !self.brightnessEdits.contains(display.id) else { return }
            self.displays[index].brightness = self.activeBlackoutIDs.contains(display.persistentID) ? 0 : value
            self.displays[index].brightnessError = error
            self.displays[index].brightnessControl = control
            self.updateSharedBrightness()
        }
    }

    func setDisplayProfile(displayID: CGDirectDisplayID, profile: DisplayProfile) {
        guard !configurationLocked else {
            notice = "Keep or revert the current change first."
            return
        }
        guard let index = index(for: displayID), !displays[index].isBuiltIn else { return }
        let display = displays[index]
        guard display.profile != profile else { return }
        brightnessEdits.remove(displayID)
        brightnessRevision[displayID, default: 0] &+= 1
        keyboardDesiredValues.removeValue(forKey: displayID)
        updateBlackout(display: display, value: 1)
        brightness.resetSoftwareDimming(persistentID: display.persistentID)
        displays[index].brightness = nil
        displays[index].brightnessControl = .unavailable
        var overrides = defaults.dictionary(forKey: "displayProfileOverrides") as? [String: String] ?? [:]
        if profile == .automatic {
            overrides.removeValue(forKey: display.persistentID)
        } else {
            overrides[display.persistentID] = profile.rawValue
        }
        defaults.set(overrides, forKey: "displayProfileOverrides")
        refresh()
    }

    func editBrightness(displayID: CGDirectDisplayID, value: Double) {
        guard !configurationLocked, value.isFinite else { return }
        guard let index = index(for: displayID) else { return }
        brightnessEdits.insert(displayID)
        brightnessRevision[displayID, default: 0] &+= 1
        displays[index].brightness = min(1, max(0, value))
    }

    func commitBrightness(displayID: CGDirectDisplayID) {
        guard !configurationLocked else { return }
        guard let display = displays.first(where: { $0.id == displayID }), let requested = display.brightness else { return }
        let value = safeBrightness(requested, display: display)
        brightnessEdits.remove(displayID)
        let revision = brightnessRevision[displayID, default: 0]
        if let index = index(for: displayID) { displays[index].brightness = value }
        keyboardDesiredValues.removeValue(forKey: displayID)
        updateBlackout(display: display, value: value)
        brightness.set(value, display: display) { [weak self] success in
            guard let self, let current = self.displays.first(where: { $0.id == displayID }),
                  current.persistentID == display.persistentID,
                  self.brightnessRevision[displayID, default: 0] == revision else { return }
            if !success { self.notice = "Could not change the brightness of \(display.name)." }
            self.refreshBrightness(display: current)
        }
    }

    func setSharedBrightnessEditing(_ editing: Bool) { isEditingSharedBrightness = editing }

    func commitSharedBrightness() {
        guard !configurationLocked, sharedBrightness.isFinite else { return }
        let requested = sharedBrightness
        let controllable = displays.filter { $0.brightness != nil }
        for display in controllable {
            let value = safeBrightness(requested, display: display)
            keyboardDesiredValues.removeValue(forKey: display.id)
            editBrightness(displayID: display.id, value: value)
            brightnessEdits.remove(display.id)
            let revision = brightnessRevision[display.id, default: 0]
            updateBlackout(display: display, value: value)
            brightness.set(value, display: display) { [weak self] success in
                guard let self, let current = self.displays.first(where: { $0.id == display.id }),
                      current.persistentID == display.persistentID,
                      self.brightnessRevision[display.id, default: 0] == revision else { return }
                if !success { self.notice = "Could not change the brightness of \(display.name)." }
                self.refreshBrightness(display: current)
            }
        }
        updateSharedBrightness()
    }

    func setKeyboardControlEnabled(_ enabled: Bool) {
        keyboardControlEnabled = enabled
        defaults.set(enabled, forKey: "keyboardBrightnessEnabled")
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
        defaults.set(target.rawValue, forKey: "keyboardBrightnessTarget")
    }

    private func startKeyboardControl(promptForPermission: Bool) {
        keyboardStatus = keyboard.start(promptForPermission: promptForPermission) ? nil
            : "Allow Multi Display in System Settings → Privacy & Security → Accessibility, then choose Retry."
        if keyboardStatus == nil { reconcileBlackouts() }
    }

    func revealDimmedScreens() {
        // An emergency reveal must also stop later items in an applying setup
        // from putting a black layer back over a recovered screen.
        skipSetupBrightness = true
        brightnessEdits.removeAll()
        let affected = displays.filter {
            activeBlackoutIDs.contains($0.persistentID) || $0.brightnessControl == .software ||
                (!$0.isBuiltIn && ($0.brightness ?? 1) < 1.0 / 16.0)
        }
        activeBlackoutIDs.removeAll()
        savedBlackoutIDs.removeAll()
        defaults.removeObject(forKey: "blackoutDisplayIDs")
        blackout.hideAll()
        hasBlackout = false
        for display in affected {
            guard let index = index(for: display.id) else { continue }
            let recoveryLevel = display.brightnessControl == .software ? 1 : 1.0 / 16.0
            brightnessRevision[display.id, default: 0] &+= 1
            displays[index].brightness = recoveryLevel
            keyboardDesiredValues.removeValue(forKey: display.id)
            brightness.set(recoveryLevel, display: display) { [weak self] success in
                if !success { self?.notice = "The black screen was cleared, but brightness could not be raised for \(display.name)." }
                self?.refresh()
            }
        }
        updateSharedBrightness()
    }

    func checkBlackoutSafety() {
        if blackout.hasVisiblePanels && !hasBlackout {
            blackout.hideAll()
            notice = "A lingering black screen was cleared."
        }
        blackout.retainOnly(activeBlackoutIDs.intersection(Set(displays.map(\.persistentID))))
        let nearBlack = displays.contains { !$0.isBuiltIn && ($0.brightness ?? 1) < 1.0 / 16.0 }
        if (!activeBlackoutIDs.isEmpty || !savedBlackoutIDs.isEmpty || nearBlack) && !keyboardRecoveryAvailable {
            revealDimmedScreens()
            notice = "Dimmed screens were revealed because keyboard recovery is unavailable."
        }
    }

    private func updateBlackout(display: ManagedDisplay, value: Double) {
        guard !display.isBuiltIn else { return }
        if value <= 0 && !isMirrored(display) && keyboardRecoveryAvailable {
            activeBlackoutIDs.insert(display.persistentID)
            savedBlackoutIDs.insert(display.persistentID)
            blackout.setBlackout(true, display: display)
        } else {
            activeBlackoutIDs.remove(display.persistentID)
            savedBlackoutIDs.remove(display.persistentID)
            blackout.setBlackout(false, display: display)
        }
        defaults.set(Array(savedBlackoutIDs), forKey: "blackoutDisplayIDs")
        hasBlackout = !activeBlackoutIDs.isEmpty
    }

    private func reconcileBlackouts() {
        let connected = Set(displays.map(\.persistentID))
        activeBlackoutIDs.formIntersection(connected)
        guard keyboardRecoveryAvailable else {
            if !activeBlackoutIDs.isEmpty || !savedBlackoutIDs.isEmpty { revealDimmedScreens() }
            blackout.hideAll()
            hasBlackout = false
            return
        }
        activeBlackoutIDs.formUnion(savedBlackoutIDs.intersection(connected))
        let mirrored = Set(displays.filter {
            $0.isBuiltIn || $0.isMirrored
        }.map(\.persistentID))
        activeBlackoutIDs.subtract(mirrored)
        savedBlackoutIDs.subtract(mirrored)
        defaults.set(Array(savedBlackoutIDs), forKey: "blackoutDisplayIDs")

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

    func adjustKeyboardBrightness(displayID: CGDirectDisplayID, direction: Int, fineStep: Bool) {
        guard keyboardControlEnabled, canControlWithKeyboard(displayID), let index = index(for: displayID) else { return }
        if configurationLocked {
            guard direction > 0, activeBlackoutIDs.contains(displays[index].persistentID) ||
                    (displays[index].brightness ?? 1) < 1.0 / 16.0 else { return }
            skipSetupBrightness = true
        }
        let displayName = displays[index].name
        let current = keyboardDesiredValues[displayID] ?? displays[index].brightness ?? 0.5
        let step = fineStep ? 1.0 / 64.0 : 1.0 / 16.0
        let desired = safeBrightness(current + Double(direction) * step, display: displays[index])
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
            guard let current = self.displays.first(where: { $0.id == displayID }),
                  current.persistentID == display.persistentID,
                  current.profile == display.profile else {
                self.keyboardInFlight.remove(displayID)
                self.keyboardDesiredValues.removeValue(forKey: displayID)
                return
            }
            if !success {
                self.keyboardInFlight.remove(displayID)
                self.keyboardDesiredValues.removeValue(forKey: displayID)
                self.keyboardBlockedIDs.insert(displayID)
                self.notice = "Could not change brightness for \(display.name). Keyboard control for this screen is paused until Refresh."
                self.brightnessHUD.showUnavailable(displayID: displayID, name: display.name)
                let revision = self.brightnessRevision[displayID, default: 0]
                self.brightness.read(display: display) { [weak self] actual, control, error in
                    guard let self, let index = self.index(for: displayID) else { return }
                    guard self.displays[index].persistentID == display.persistentID,
                          self.displays[index].profile == display.profile else { return }
                    guard self.brightnessRevision[displayID, default: 0] == revision else { return }
                    self.displays[index].brightness = actual
                    self.displays[index].brightnessError = error
                    self.displays[index].brightnessControl = control
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
        guard !configurationLocked else {
            notice = "Keep or revert the current change first."
            return
        }
        refresh()
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
        guard !configurationLocked else {
            notice = "Keep or revert the current change first."
            return
        }
        refresh()
        guard rotation.isAvailable else {
            notice = "Rotation needs displayplacer installed on this Mac."
            return
        }
        guard let display = displays.first(where: { $0.id == displayID }), !display.isBuiltIn else { return }
        guard [0, 90, 180, 270].contains(degrees), degrees != display.rotation else { return }
        let oldMode = CGDisplayCopyDisplayMode(displayID)
        let token = UUID()
        configuration = .applying(token)
        keyboardDesiredValues.removeAll()
        rotation.set(degrees, persistentID: display.persistentID) { [weak self] result in
            guard let self, self.activeApplyToken == token else { return }
            switch result {
            case .success:
                self.beginConfirmation(display: display, previousMode: oldMode, previousRotation: display.rotation)
                self.scheduleRefresh()
            case .failure(let error):
                self.configuration = .idle
                self.notice = error.localizedDescription
                self.scheduleRefresh()
            }
        }
    }

    func confirmChange() {
        guard !isApplyingConfiguration else { return }
        clearConfirmation()
    }

    private func clearConfirmation() {
        configuration = .idle
    }

    func revertChange() {
        guard !isApplyingConfiguration else { return }
        if let pendingProfile {
            let token = UUID()
            configuration = .reverting(token)
            refresh()
            skipSetupBrightness = false
            let matched = pendingProfile.snapshot.displays.compactMap { saved -> (SavedDisplay, ManagedDisplay)? in
                guard let display = displays.first(where: { $0.persistentID == saved.persistentID }) else { return nil }
                return (saved, display)
            }
            applySetupItems(matched, at: 0, token: token)
            return
        }
        guard let pending else { return }
        let token = UUID()
        configuration = .reverting(token)
        refresh()
        if let current = displays.first(where: { $0.persistentID == pending.persistentID }), current.rotation != pending.previousRotation {
            rotation.set(pending.previousRotation, persistentID: pending.persistentID) { [weak self] result in
                guard let self, self.activeApplyToken == token else { return }
                if case .failure(let error) = result { self.notice = error.localizedDescription }
                DispatchQueue.main.asyncAfter(deadline: .now() + self.configurationSettleDelay) { [weak self] in
                    self?.restoreMode(pending, token: token)
                }
            }
        } else {
            restoreMode(pending, token: token)
        }
    }

    func saveSetup(name: String) {
        guard !configurationLocked else { return }
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
        guard !configurationLocked else {
            notice = "Confirm or revert the current display change first."
            return
        }
        refresh()
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
        let token = UUID()
        configuration = .applying(token)
        skipSetupBrightness = false
        keyboardDesiredValues.removeAll()
        applySetupItems(matched, at: 0, token: token, snapshot: snapshot)
    }

    private func applySetupItems(_ items: [(SavedDisplay, ManagedDisplay)], at index: Int, token: UUID, snapshot: SavedSetup? = nil) {
        guard activeApplyToken == token else { return }
        guard index < items.count else {
            configuration = .idle
            refresh()
            if let snapshot { beginProfileConfirmation(snapshot: snapshot) }
            return
        }
        let (saved, _) = items[index]
        guard let original = displays.first(where: { $0.persistentID == saved.persistentID }) else {
            applySetupItems(items, at: index + 1, token: token, snapshot: snapshot)
            return
        }
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            guard self.activeApplyToken == token else { return }
            self.refresh()
            guard let updated = self.displays.first(where: { $0.persistentID == saved.persistentID }) else {
                self.applySetupItems(items, at: index + 1, token: token, snapshot: snapshot)
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
            if !self.skipSetupBrightness, let requested = saved.brightness, requested.isFinite {
                if let snapshot, snapshot.displays.first(where: { $0.persistentID == saved.persistentID })?.brightness == nil {
                    self.notice = "The previous brightness of \(updated.name) is unavailable, so this setup left its brightness unchanged. Try again after Refresh."
                    self.applySetupItems(items, at: index + 1, token: token, snapshot: snapshot)
                    return
                }
                let value = self.safeBrightness(requested, display: updated)
                self.brightnessRevision[updated.id, default: 0] &+= 1
                self.keyboardDesiredValues.removeValue(forKey: updated.id)
                if let displayIndex = self.index(for: updated.id) { self.displays[displayIndex].brightness = value }
                self.updateBlackout(display: updated, value: value)
                self.brightness.set(value, display: updated) { [weak self] success in
                    guard self?.activeApplyToken == token else { return }
                    if !success { self?.notice = "Could not restore brightness for \(updated.name)." }
                    self?.applySetupItems(items, at: index + 1, token: token, snapshot: snapshot)
                }
            } else {
                self.applySetupItems(items, at: index + 1, token: token, snapshot: snapshot)
            }
        }
        if !original.isBuiltIn && original.rotation != saved.rotation {
            rotation.set(saved.rotation, persistentID: original.persistentID) { [weak self] result in
                guard self?.activeApplyToken == token else { return }
                if case .failure(let error) = result { self?.notice = error.localizedDescription }
                self?.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + (self?.configurationSettleDelay ?? 0), execute: finish)
            }
        } else {
            finish()
        }
    }

    private func beginConfirmation(display: ManagedDisplay, previousMode: CGDisplayMode?, previousRotation: Int) {
        let value = PendingChange(persistentID: display.persistentID, name: display.name,
                                  previousMode: previousMode.map(ModeSignature.init),
                                  previousRotation: previousRotation)
        configuration = .awaitingChange(value)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard self?.pending?.token == value.token else { return }
            self?.revertChange()
        }
    }

    private func beginProfileConfirmation(snapshot: SavedSetup) {
        let value = PendingProfile(snapshot: snapshot)
        configuration = .awaitingSetup(value)
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in
            guard self?.pendingProfile?.token == value.token else { return }
            self?.revertChange()
        }
    }

    private func restoreMode(_ value: PendingChange, token: UUID) {
        guard activeApplyToken == token else { return }
        if let signature = value.previousMode {
            if let current = scan([:]).first(where: { $0.persistentID == value.persistentID }),
               let option = current.modes.first(where: { signature.matches($0.mode) }) {
                if CGDisplaySetDisplayMode(current.id, option.mode, nil) != .success {
                    notice = "Could not restore the previous resolution of \(current.name)."
                }
            } else {
                notice = "The previous resolution of \(value.name) is unavailable or the display disconnected."
            }
        }
        configuration = .idle
        scheduleRefresh()
    }

    var configurationLocked: Bool {
        if case .idle = configuration { return false }
        return true
    }

    private var keyboardRecoveryAvailable: Bool {
        keyboardControlEnabled && (recoveryCheck?() ?? keyboard.canRecover)
    }

    private func safeBrightness(_ requested: Double, display: ManagedDisplay) -> Double {
        let value = min(1, max(0, requested))
        if value < 1.0 / 16.0 && !display.isBuiltIn && (isMirrored(display) || !keyboardRecoveryAvailable) {
            notice = "External brightness below 6% needs working brightness keys and an extended display. Brightness was kept at 6%."
            return 1.0 / 16.0
        }
        return value
    }

    private func isMirrored(_ display: ManagedDisplay) -> Bool {
        mirrorCheck(display)
    }

    private func updateSharedBrightness() {
        guard !isEditingSharedBrightness else { return }
        let values = displays.compactMap(\.brightness)
        if !values.isEmpty { sharedBrightness = values.reduce(0, +) / Double(values.count) }
    }

    private func index(for id: CGDirectDisplayID) -> Int? { displays.firstIndex { $0.id == id } }
}

private enum ConfigurationState {
    case idle
    case applying(UUID)
    case reverting(UUID)
    case awaitingChange(PendingChange)
    case awaitingSetup(PendingProfile)
}

private struct PendingChange {
    let token = UUID()
    let persistentID: String
    let name: String
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
