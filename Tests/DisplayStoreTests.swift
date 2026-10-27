import AppKit
import Combine
import CoreGraphics
import XCTest

final class DisplayStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        suite = "MultiDisplayManagementTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "keyboardBrightnessEnabled")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testRotationStaysExclusiveThroughApplyAndConfirmation() {
        let inventory = InventoryFixture()
        let rotation = FakeRotation()
        let store = makeStore(inventory, rotation: rotation)
        store.setRotation(displayID: 42, degrees: 90)
        XCTAssertTrue(store.isApplyingConfiguration)
        XCTAssertNil(store.pendingChange)

        store.confirmChange()
        store.setRotation(displayID: 42, degrees: 180)
        store.applySetup(setup(rotation: 180))
        XCTAssertEqual(rotation.requests.count, 1)

        inventory.displays = [display(rotation: 90)]
        rotation.complete(0)
        XCTAssertFalse(store.isApplyingConfiguration)
        XCTAssertNotNil(store.pendingChange)
        store.setRotation(displayID: 42, degrees: 180)
        XCTAssertEqual(rotation.requests.count, 1)

        store.confirmChange()
        store.refresh()
        store.setRotation(displayID: 42, degrees: 180)
        XCTAssertEqual(rotation.requests.count, 2)
        rotation.complete(0) // Duplicate completion from the old operation must be ignored.
        XCTAssertTrue(store.isApplyingConfiguration)
        rotation.complete(1)
        XCTAssertNotNil(store.pendingChange)
    }

    func testSetupConfirmsAfterCompletionAndRollbackScansFreshConnection() {
        let inventory = InventoryFixture()
        let rotation = FakeRotation()
        let store = makeStore(inventory, rotation: rotation)
        store.applySetup(setup(rotation: 90))
        XCTAssertTrue(store.isApplyingConfiguration)
        XCTAssertNil(store.pendingChange)
        store.confirmChange()
        XCTAssertTrue(store.configurationLocked)

        inventory.displays = [display(rotation: 90)]
        rotation.complete(0)
        waitUntil { store.pendingChange != nil }

        // Revert before the debounced inventory refresh, after macOS has changed the ID.
        inventory.displays = [display(id: 84, rotation: 90)]
        store.revertChange()
        XCTAssertTrue(store.isApplyingConfiguration)
        XCTAssertEqual(rotation.requests.last?.degrees, 0)
        XCTAssertEqual(rotation.requests.last?.persistentID, "test-display")
        XCTAssertEqual(store.displays.first?.id, 84)
        inventory.displays = [display(id: 84)]
        rotation.complete(1)
        waitUntil { !store.configurationLocked }
        XCTAssertNil(store.pendingChange)
    }

    func testUnsafeZeroIsNormalizedForSliderSharedSliderAndSetup() {
        let inventory = InventoryFixture()
        let transport = BrightnessFixture()
        let store = makeStore(inventory, transport: transport)
        waitUntil { store.displays.first?.brightness != nil }

        store.editBrightness(displayID: 42, value: 0)
        store.commitBrightness(displayID: 42)
        waitUntil { transport.values.count == 1 }
        XCTAssertEqual(transport.values[0], 1.0 / 16.0)
        XCTAssertFalse(store.hasBlackout)

        store.sharedBrightness = 0
        store.commitSharedBrightness()
        waitUntil { transport.values.count == 2 }
        XCTAssertEqual(transport.values[1], 1.0 / 16.0)

        store.applySetup(setup(brightness: 0))
        waitUntil { store.pendingChange != nil }
        XCTAssertEqual(transport.values.last, 1.0 / 16.0)
        XCTAssertFalse(store.hasBlackout)
        XCTAssertTrue((defaults.stringArray(forKey: "blackoutDisplayIDs") ?? []).isEmpty)
    }

    func testMirroredDisplayCannotBecomeBlackEvenWithRecovery() {
        let inventory = InventoryFixture()
        inventory.displays = [display(isMirrored: true)]
        let transport = BrightnessFixture()
        defaults.set(true, forKey: "keyboardBrightnessEnabled")
        let store = makeStore(inventory, transport: transport, recoveryCheck: { true })
        waitUntil { store.displays.first?.brightness != nil }
        store.editBrightness(displayID: 42, value: 0)
        store.commitBrightness(displayID: 42)
        waitUntil { !transport.values.isEmpty }
        XCTAssertEqual(transport.values.last, 1.0 / 16.0)
        XCTAssertFalse(store.hasBlackout)
    }

    func testNearZeroIsNormalizedForEveryBrightnessEntryPoint() {
        let inventory = InventoryFixture()
        let transport = BrightnessFixture()
        let store = makeStore(inventory, transport: transport)
        waitUntil { store.displays.first?.brightness != nil }
        store.editBrightness(displayID: 42, value: 0.001)
        store.commitBrightness(displayID: 42)
        waitUntil { transport.values.count == 1 }
        store.sharedBrightness = 0.001
        store.commitSharedBrightness()
        waitUntil { transport.values.count == 2 }
        store.applySetup(setup(brightness: 0.001))
        waitUntil { store.pendingChange != nil }
        XCTAssertEqual(transport.values, [1.0 / 16.0, 1.0 / 16.0, 1.0 / 16.0])
        XCTAssertFalse(store.hasBlackout)
    }

    func testLostRecoveryRevealsNearZeroSoftwareDimming() {
        defaults.set(true, forKey: "keyboardBrightnessEnabled")
        let software = SoftwareFixture()
        var canRecover = true
        let samsung = ManagedDisplay(id: .max, persistentID: "software-display", reportedName: "HG50U701FNF",
                                     isBuiltIn: false, isMirrored: false, profile: .samsungHG50U701FNF,
                                     rotation: 0, modes: [], currentMode: nil, brightness: nil, brightnessError: nil)
        let brightness = BrightnessController(software: software, ddcRead: { _ in nil })
        let store = DisplayStore(brightness: brightness, defaults: defaults, scan: { _ in [samsung] },
                                 systemMonitoring: false, recoveryCheck: { canRecover }, mirrorCheck: { $0.isMirrored })
        waitUntil { store.displays.first?.brightnessControl == .software }
        store.editBrightness(displayID: .max, value: 0.001)
        store.commitBrightness(displayID: .max)
        XCTAssertEqual(software.level, 0.001)
        canRecover = false
        store.checkBlackoutSafety()
        XCTAssertEqual(software.level, 1)
        XCTAssertEqual(store.displays.first?.brightness, 1)
        XCTAssertFalse(store.hasBlackout)
    }

    func testBrightnessUpCanRecoverBlackoutWhileSetupAwaitsConfirmation() {
        defaults.set(true, forKey: "keyboardBrightnessEnabled")
        let inventory = InventoryFixture()
        inventory.displays = [display(id: .max)]
        let transport = BrightnessFixture()
        let store = makeStore(inventory, transport: transport, recoveryCheck: { true })
        waitUntil { store.displays.first?.brightness != nil }
        store.applySetup(setup(brightness: 0))
        waitUntil { store.pendingChange != nil }
        XCTAssertTrue(store.hasBlackout)
        XCTAssertEqual(transport.values.last, 0)
        store.adjustKeyboardBrightness(displayID: .max, direction: 1, fineStep: false)
        waitUntil { transport.values.last == 1.0 / 16.0 }
        XCTAssertFalse(store.hasBlackout)
        XCTAssertNotNil(store.pendingChange)
    }

    func testSetupDoesNotWriteBrightnessWhenRollbackBaselineIsUnknown() {
        let inventory = InventoryFixture()
        let transport = BrightnessFixture()
        let store = makeStore(inventory, transport: transport)
        XCTAssertNil(store.displays.first?.brightness)
        store.applySetup(setup(brightness: 0.2))
        waitUntil { store.pendingChange != nil }
        XCTAssertTrue(transport.values.isEmpty)
        XCTAssertTrue(store.notice?.contains("left its brightness unchanged") == true)
    }

    func testRotationCapturesFreshBaselineBeforeChange() {
        let inventory = InventoryFixture()
        let rotation = FakeRotation()
        let store = makeStore(inventory, rotation: rotation)
        inventory.displays = [display(rotation: 90)] // External change before the debounce refresh.
        store.setRotation(displayID: 42, degrees: 180)
        inventory.displays = [display(rotation: 180)]
        rotation.complete(0)
        store.revertChange()
        XCTAssertEqual(rotation.requests.last?.degrees, 90)
        inventory.displays = [display(rotation: 90)]
        rotation.complete(1)
        waitUntil { !store.configurationLocked }
    }

    func testMissingRecoveryClearsSavedBlackoutForDisconnectedDisplay() {
        defaults.set(["disconnected"], forKey: "blackoutDisplayIDs")
        let inventory = InventoryFixture()
        inventory.displays = []
        let store = makeStore(inventory)
        XCTAssertFalse(store.hasBlackout)
        XCTAssertNil(defaults.object(forKey: "blackoutDisplayIDs"))
    }

    func testRevealDuringSetupPreventsLaterBlackoutWrites() {
        let inventory = InventoryFixture()
        let transport = BrightnessFixture()
        let rotation = FakeRotation()
        let store = makeStore(inventory, rotation: rotation, transport: transport)
        store.applySetup(setup(rotation: 90, brightness: 0))
        store.revealDimmedScreens()
        inventory.displays = [display(rotation: 90)]
        rotation.complete(0)
        waitUntil { store.pendingChange != nil }
        XCTAssertTrue(transport.values.isEmpty)
        XCTAssertFalse(store.hasBlackout)
    }

    func testBrightnessCommitDoesNotRescanDisplayModesAndRefreshPreservesDrag() {
        let inventory = InventoryFixture()
        let transport = BrightnessFixture()
        let store = makeStore(inventory, transport: transport)
        waitUntil { store.displays.first?.brightness != nil }
        XCTAssertEqual(inventory.scans, 1)
        store.editBrightness(displayID: 42, value: 0.4)
        store.commitBrightness(displayID: 42)
        waitUntil { store.displays.first?.brightness == 0.4 && transport.values.count == 1 }
        XCTAssertEqual(inventory.scans, 1)

        store.editBrightness(displayID: 42, value: 0.7)
        store.refresh()
        XCTAssertEqual(store.displays.first?.brightness, 0.7)
        // Drain pending brightness callbacks while the slider is still being edited.
        let drained = expectation(description: "Main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(store.displays.first?.brightness, 0.7)
    }

    func testDisconnectDuringDragDoesNotLeaveReconnectedSliderUnavailable() {
        let inventory = InventoryFixture()
        let store = makeStore(inventory)
        waitUntil { store.displays.first?.brightness != nil }
        store.editBrightness(displayID: 42, value: 0.7)
        inventory.displays = []
        store.refresh()
        inventory.displays = [display()]
        store.refresh()
        waitUntil { store.displays.first?.brightness == 0.5 }
    }

    private func makeStore(_ inventory: InventoryFixture, rotation: FakeRotation = FakeRotation(),
                           transport: BrightnessFixture = BrightnessFixture(),
                           recoveryCheck: (() -> Bool)? = nil) -> DisplayStore {
        let brightness = BrightnessController(ddcRead: { transport.read($0) }, ddcSet: { transport.write($0, id: $1) })
        return DisplayStore(brightness: brightness, rotation: rotation, defaults: defaults, scan: { _ in
            inventory.scans += 1
            return inventory.displays
        }, systemMonitoring: false, configurationSettleDelay: 0, recoveryCheck: recoveryCheck, mirrorCheck: { $0.isMirrored })
    }

    private func setup(rotation: Int = 0, brightness: Double? = nil) -> SavedSetup {
        SavedSetup(id: UUID(), name: "Test", displays: [
            SavedDisplay(persistentID: "test-display", name: "Test", brightness: brightness, mode: nil, rotation: rotation)
        ])
    }

    private func waitUntil(_ predicate: @escaping () -> Bool) {
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        wait(for: [finished], timeout: 3)
    }
}

private func display(id: CGDirectDisplayID = 42, rotation: Int = 0, isMirrored: Bool = false) -> ManagedDisplay {
    ManagedDisplay(id: id, persistentID: "test-display", reportedName: "Test display", isBuiltIn: false,
                   isMirrored: isMirrored, profile: .automatic, rotation: rotation, modes: [], currentMode: nil,
                   brightness: nil, brightnessError: nil)
}

private final class InventoryFixture {
    var displays = [display()]
    var scans = 0
}

private final class FakeRotation: DisplayRotating {
    struct Request {
        let degrees: Int
        let persistentID: String
        let completion: (Result<Void, Error>) -> Void
    }
    var isAvailable = true
    var requests: [Request] = []
    func set(_ degrees: Int, persistentID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        requests.append(Request(degrees: degrees, persistentID: persistentID, completion: completion))
    }
    func complete(_ index: Int) { requests[index].completion(.success(())) }
}

private final class BrightnessFixture {
    private let lock = NSLock()
    private var recorded: [Double] = []
    private var level = 0.5
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return recorded }
    func read(_ id: CGDirectDisplayID) -> Double? { lock.lock(); defer { lock.unlock() }; return level }
    func write(_ value: Double, id: CGDirectDisplayID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        recorded.append(value)
        level = value
        return true
    }
}

private final class SoftwareFixture: SoftwareBrightnessControlling {
    var level: Double = 1
    func read(display: ManagedDisplay) -> Double? { level }
    func set(_ value: Double, display: ManagedDisplay) -> Bool { level = value; return true }
    func reset(persistentID: String) { level = 1 }
    func suspend() {}
    func retainOnly(_ persistentIDs: Set<String>) {}
}
