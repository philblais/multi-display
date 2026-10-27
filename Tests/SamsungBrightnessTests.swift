import CoreGraphics
import XCTest

final class SamsungBrightnessTests: XCTestCase {
    func testRecognizesLabelIdentifiersWithoutGuessingFromBrand() {
        for name in ["HG50U701FNF", "Samsung HG50U701FNFXZA", "hg50u701f"] {
            XCTAssertEqual(makeDisplay(name: name, profile: .automatic).model, .samsungHG50U701FNF)
        }
        for name in ["SAMSUNG", "Samsung HG55U701FNF", "LG 27UD68", "HG50U701FNFXZA2"] {
            XCTAssertEqual(makeDisplay(name: name, profile: .automatic).model, .automatic)
        }
        XCTAssertEqual(makeDisplay(isBuiltIn: true).model, .automatic)
        XCTAssertEqual(makeDisplay(name: "SAMSUNG").name, "Samsung HG50U701FNF")
    }

    func testSamsungUsesDDCWhenAvailable() {
        let software = FakeSoftwareBrightness()
        var written: Double?
        let controller = BrightnessController(software: software, ddcRead: { _ in 0.7 }, ddcSet: { value, _ in
            written = value
            return true
        })
        var display = makeDisplay()
        let reading = read(controller, display)
        XCTAssertEqual(reading.value, 0.7)
        XCTAssertEqual(reading.control, .ddc)
        display.brightnessControl = reading.control
        set(controller, 0.4, display)
        XCTAssertEqual(written, 0.4)
        XCTAssertTrue(software.levels.isEmpty)
    }

    func testSoftwareFallbackPreservesLevelAcrossRefreshAndUsesNoDDCWrites() {
        let software = FakeSoftwareBrightness()
        var reads = 0
        var writes = 0
        let controller = BrightnessController(software: software, ddcRead: { _ in
            reads += 1
            return nil
        }, ddcSet: { _, _ in writes += 1; return false })
        var display = makeDisplay(name: "SAMSUNG")
        let initial = read(controller, display)
        XCTAssertEqual(initial.control, .software)
        XCTAssertEqual(initial.value, 1)
        display.brightnessControl = initial.control
        set(controller, 0.4, display)
        controller.suspendSoftwareDimming()
        XCTAssertEqual(read(controller, display).value, 0.4)
        set(controller, 0, display)
        XCTAssertEqual(read(controller, display).value, 0)
        set(controller, 1, display)
        XCTAssertEqual(read(controller, display).value, 1)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(software.suspensions, 1)
    }

    func testFallbackDoesNotEnableUnknownOrMirroredDisplays() {
        for display in [makeDisplay(name: "SAMSUNG", profile: .automatic), makeDisplay(isMirrored: true)] {
            let software = FakeSoftwareBrightness()
            let controller = BrightnessController(software: software, ddcRead: { _ in nil })
            let reading = read(controller, display)
            XCTAssertNil(reading.value)
            XCTAssertEqual(reading.control, .unavailable)
            XCTAssertNotNil(reading.error)
            XCTAssertTrue(software.levels.isEmpty)
        }
    }

    func testDisconnectClearsSoftwareLevelAndReconnectRetriesDDC() {
        let software = FakeSoftwareBrightness()
        var hardwareValue: Double?
        let controller = BrightnessController(software: software, ddcRead: { _ in hardwareValue })
        var display = makeDisplay()
        display.brightnessControl = read(controller, display).control
        set(controller, 0.2, display)
        controller.retainSoftwareDimming(for: [])
        XCTAssertTrue(software.levels.isEmpty)
        hardwareValue = 0.8
        let reconnected = read(controller, makeDisplay())
        XCTAssertEqual(reconnected.control, .ddc)
        XCTAssertEqual(reconnected.value, 0.8)
    }

    func testChangingProfileCancelsPendingFallback() {
        let software = FakeSoftwareBrightness()
        let requested = expectation(description: "DDC read started")
        let release = DispatchSemaphore(value: 0)
        let controller = BrightnessController(software: software, ddcRead: { _ in
            requested.fulfill()
            release.wait()
            return nil
        })
        let callback = expectation(description: "Stale read must be discarded")
        callback.isInverted = true
        let display = makeDisplay()
        controller.read(display: display) { _, _, _ in callback.fulfill() }
        wait(for: [requested], timeout: 2)
        controller.resetSoftwareDimming(persistentID: display.persistentID)
        release.signal()
        wait(for: [callback], timeout: 0.2)
        XCTAssertTrue(software.levels.isEmpty)
    }

    func testDisconnectCancelsPendingInitialReadAndReconnectRetriesDDC() {
        let software = FakeSoftwareBrightness()
        let requested = expectation(description: "Initial DDC read started")
        let release = DispatchSemaphore(value: 0)
        var reads = 0
        let controller = BrightnessController(software: software, ddcRead: { _ in
            reads += 1
            if reads == 1 {
                requested.fulfill()
                release.wait()
                return nil
            }
            return 0.8
        })
        let display = makeDisplay()
        var staleDelivered = false
        controller.read(display: display) { _, _, _ in staleDelivered = true }
        wait(for: [requested], timeout: 2)

        controller.retainSoftwareDimming(for: [])
        controller.retainSoftwareDimming(for: [display])
        release.signal()
        let reconnected = read(controller, display)

        XCTAssertFalse(staleDelivered)
        XCTAssertEqual(reconnected.value, 0.8)
        XCTAssertEqual(reconnected.control, .ddc)
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(software.levels.isEmpty)
    }

    func testConnectionIdentityChangesCancelPendingFallback() {
        let replacements = [
            makeDisplay(id: 84),
            makeDisplay(isMirrored: true),
            makeDisplay(profile: .automatic),
            makeDisplay(name: "Different reported display name")
        ]
        for replacement in replacements {
            let software = FakeSoftwareBrightness()
            let requested = expectation(description: "Old connection read started")
            let release = DispatchSemaphore(value: 0)
            var reads = 0
            let controller = BrightnessController(software: software, ddcRead: { _ in
                reads += 1
                if reads == 1 {
                    requested.fulfill()
                    release.wait()
                    return nil
                }
                return 0.6
            })
            var staleDelivered = false
            controller.read(display: makeDisplay()) { _, _, _ in staleDelivered = true }
            wait(for: [requested], timeout: 2)

            controller.retainSoftwareDimming(for: [replacement])
            release.signal()
            let updated = read(controller, replacement)

            XCTAssertFalse(staleDelivered)
            XCTAssertEqual(updated.value, 0.6)
            XCTAssertEqual(updated.control, .ddc)
            XCTAssertTrue(software.levels.isEmpty)
        }
    }

    func testSoftwareReadQueuedBeforeWriteCannotOverwriteNewLevel() {
        let software = FakeSoftwareBrightness()
        let controller = BrightnessController(software: software, ddcRead: { _ in nil })
        let display = makeDisplay()
        XCTAssertEqual(read(controller, display).control, .software)
        var staleDelivered = false

        controller.read(display: display) { _, _, _ in staleDelivered = true }
        set(controller, 0.2, display)

        XCTAssertFalse(staleDelivered)
        XCTAssertEqual(software.levels[display.persistentID], 0.2)
        XCTAssertEqual(read(controller, display).value, 0.2)
    }

    func testWriteCancelsPendingReadBeforeItCreatesSoftwareFallback() {
        let software = FakeSoftwareBrightness()
        let requested = expectation(description: "DDC read started")
        let release = DispatchSemaphore(value: 0)
        var written: Double?
        let controller = BrightnessController(software: software, ddcRead: { _ in
            requested.fulfill()
            release.wait()
            return nil
        }, ddcSet: { value, _ in written = value; return true })
        let display = makeDisplay()
        var staleDelivered = false
        controller.read(display: display) { _, _, _ in staleDelivered = true }
        wait(for: [requested], timeout: 2)

        let completed = expectation(description: "New write finished")
        controller.set(0.3, display: display) { success in
            XCTAssertTrue(success)
            completed.fulfill()
        }
        release.signal()
        wait(for: [completed], timeout: 2)

        XCTAssertFalse(staleDelivered)
        XCTAssertEqual(written, 0.3)
        XCTAssertTrue(software.levels.isEmpty)
    }

    func testBrightnessReadsRejectNonFiniteAndClampOutOfRangeValues() {
        let unknown = makeDisplay(name: "Unknown", profile: .automatic)
        for value in [Double.nan, .infinity, -.infinity] {
            let controller = BrightnessController(ddcRead: { _ in value })
            let reading = read(controller, unknown)
            XCTAssertNil(reading.value)
            XCTAssertEqual(reading.control, .unavailable)
        }
        for (transport, expected) in [(-0.5, 0.0), (1.5, 1.0)] {
            let controller = BrightnessController(ddcRead: { _ in transport })
            XCTAssertEqual(read(controller, unknown).value, expected)
        }
    }

    func testDisconnectCancelsQueuedHardwareWriteBeforeReusedDisplayIDIsTouched() {
        let software = FakeSoftwareBrightness()
        let requested = expectation(description: "Read blocks the hardware queue")
        let release = DispatchSemaphore(value: 0)
        var writes: [Double] = []
        let controller = BrightnessController(software: software, ddcRead: { _ in
            requested.fulfill()
            release.wait()
            return nil
        }, ddcSet: { value, _ in writes.append(value); return true })
        let display = makeDisplay()
        var staleReadDelivered = false
        controller.read(display: display) { _, _, _ in staleReadDelivered = true }
        wait(for: [requested], timeout: 2)
        let canceled = expectation(description: "Canceled queued write still completes")
        controller.set(0.3, display: display) { success in
            XCTAssertFalse(success)
            canceled.fulfill()
        }

        controller.retainSoftwareDimming(for: [])
        controller.retainSoftwareDimming(for: [display])
        release.signal()
        wait(for: [canceled], timeout: 2)

        XCTAssertTrue(writes.isEmpty)
        XCTAssertFalse(staleReadDelivered)
        XCTAssertTrue(software.levels.isEmpty)
        set(controller, 0.7, display)
        XCTAssertEqual(writes, [0.7])
    }

    func testNewerWriteOnSameConnectionDoesNotCancelEarlierQueuedWrite() {
        let requested = expectation(description: "Read blocks the hardware queue")
        let release = DispatchSemaphore(value: 0)
        var writes: [Double] = []
        let controller = BrightnessController(ddcRead: { _ in
            requested.fulfill()
            release.wait()
            return nil
        }, ddcSet: { value, _ in writes.append(value); return true })
        let display = makeDisplay()
        controller.read(display: display) { _, _, _ in XCTFail("The read precedes newer writes") }
        wait(for: [requested], timeout: 2)
        let written = expectation(description: "Both queued writes complete")
        written.expectedFulfillmentCount = 2
        for value in [0.3, 0.7] {
            controller.set(value, display: display) { success in
                XCTAssertTrue(success)
                written.fulfill()
            }
        }
        release.signal()
        wait(for: [written], timeout: 2)

        XCTAssertEqual(writes, [0.3, 0.7])
    }

    func testLaterReadDoesNotDropPendingWriteCompletion() {
        let requested = expectation(description: "DDC write started")
        let release = DispatchSemaphore(value: 0)
        let controller = BrightnessController(ddcRead: { _ in 0.7 }, ddcSet: { _, _ in
            requested.fulfill()
            release.wait()
            return true
        })
        let display = makeDisplay()
        let written = expectation(description: "Pending write still completes")
        controller.set(0.7, display: display) { success in
            XCTAssertTrue(success)
            written.fulfill()
        }
        wait(for: [requested], timeout: 2)
        let refreshed = expectation(description: "Later read completes")
        controller.read(display: display) { value, _, _ in
            XCTAssertEqual(value, 0.7)
            refreshed.fulfill()
        }
        release.signal()
        wait(for: [written, refreshed], timeout: 2)
    }

    func testConnectionChangeDoesNotReuseStaleSoftwareControlSnapshot() {
        let software = FakeSoftwareBrightness()
        var written: Double?
        let controller = BrightnessController(software: software, ddcRead: { _ in nil }, ddcSet: { value, _ in
            written = value
            return true
        })
        XCTAssertEqual(read(controller, makeDisplay()).control, .software)
        var replacement = makeDisplay(id: 84)
        replacement.brightnessControl = .software

        controller.retainSoftwareDimming(for: [replacement])
        set(controller, 0.7, replacement)

        XCTAssertEqual(written, 0.7)
        XCTAssertTrue(software.levels.isEmpty)
    }

    func testBrightnessWriteRejectsNonFiniteValueWithoutCallingTransport() {
        var writes = 0
        let controller = BrightnessController(ddcSet: { _, _ in writes += 1; return true })
        let completed = expectation(description: "Invalid write rejected")
        controller.set(.nan, display: makeDisplay()) { success in
            XCTAssertFalse(success)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(writes, 0)
    }

    func testLegacySavedSetupStillDecodes() throws {
        let json = """
        [{"id":"907EB13C-0B31-4A2B-AB34-F7F4F3EAA844","name":"Desk","displays":[{"persistentID":"lg","name":"LG","brightness":0.5,"rotation":90}]}]
        """
        let setup = try JSONDecoder().decode([SavedSetup].self, from: Data(json.utf8)).first
        XCTAssertEqual(setup?.displays.first?.brightness, 0.5)
        XCTAssertEqual(setup?.displays.first?.rotation, 90)
    }

    private func makeDisplay(id: CGDirectDisplayID = 42, name: String = "HG50U701FNF", profile: DisplayProfile = .samsungHG50U701FNF,
                             isBuiltIn: Bool = false, isMirrored: Bool = false) -> ManagedDisplay {
        ManagedDisplay(id: id, persistentID: "test-samsung", reportedName: name, isBuiltIn: isBuiltIn,
                       isMirrored: isMirrored, profile: profile, rotation: 0, modes: [], currentMode: nil,
                       brightness: nil, brightnessError: nil)
    }

    private func read(_ controller: BrightnessController, _ display: ManagedDisplay)
        -> (value: Double?, control: BrightnessControl, error: String?) {
        let finished = expectation(description: "Brightness read")
        var result: (Double?, BrightnessControl, String?) = (nil, .unavailable, nil)
        controller.read(display: display) { value, control, error in
            result = (value, control, error)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        return result
    }

    private func set(_ controller: BrightnessController, _ value: Double, _ display: ManagedDisplay) {
        let finished = expectation(description: "Brightness write")
        controller.set(value, display: display) { success in
            XCTAssertTrue(success)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }
}

private final class FakeSoftwareBrightness: SoftwareBrightnessControlling {
    var levels: [String: Double] = [:]
    var suspensions = 0

    func read(display: ManagedDisplay) -> Double? {
        let value = levels[display.persistentID] ?? 1
        levels[display.persistentID] = value
        return value
    }

    func set(_ value: Double, display: ManagedDisplay) -> Bool {
        levels[display.persistentID] = value
        return true
    }

    func reset(persistentID: String) { levels.removeValue(forKey: persistentID) }
    func suspend() { suspensions += 1 }
    func retainOnly(_ persistentIDs: Set<String>) { levels = levels.filter { persistentIDs.contains($0.key) } }
}
