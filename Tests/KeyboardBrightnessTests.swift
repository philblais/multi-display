import AppKit
import CoreGraphics
import XCTest

final class KeyboardBrightnessTests: XCTestCase {
    func testFreshPressRetargetsAfterMissingKeyUp() throws {
        var selected: CGDirectDisplayID = 42
        let controller = KeyboardBrightnessController(displaySelector: { _ in selected })
        controller.canControl = { _ in true }
        let adjusted = expectation(description: "Both fresh presses are delivered")
        adjusted.expectedFulfillmentCount = 2
        var targets: [CGDirectDisplayID] = []
        controller.adjust = { id, _, _ in targets.append(id); adjusted.fulfill() }

        XCTAssertNil(controller.handle(type: mediaEventType, event: try keyEvent()))
        selected = 84
        XCTAssertNil(controller.handle(type: mediaEventType, event: try keyEvent()))

        wait(for: [adjusted], timeout: 2)
        XCTAssertEqual(targets, [42, 84])
    }

    func testRepeatStaysOnOriginalScreenUntilRelease() throws {
        var selected: CGDirectDisplayID = 42
        let controller = KeyboardBrightnessController(displaySelector: { _ in selected })
        controller.canControl = { _ in true }
        let adjusted = expectation(description: "Repeat and next press are delivered")
        adjusted.expectedFulfillmentCount = 3
        var targets: [CGDirectDisplayID] = []
        controller.adjust = { id, _, _ in targets.append(id); adjusted.fulfill() }

        XCTAssertNil(controller.handle(type: mediaEventType, event: try keyEvent()))
        selected = 84
        XCTAssertNil(controller.handle(type: mediaEventType, event: try keyEvent(repeated: true)))
        XCTAssertNil(controller.handle(type: mediaEventType, event: try keyEvent(state: 0xB)))
        XCTAssertNil(controller.handle(type: mediaEventType, event: try keyEvent()))

        wait(for: [adjusted], timeout: 2)
        XCTAssertEqual(targets, [42, 42, 84])
    }

    func testDisabledTapClearsCaptureBeforeResumingRepeats() throws {
        for type in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            var selected: CGDirectDisplayID = 42
            let controller = KeyboardBrightnessController(displaySelector: { _ in selected })
            controller.canControl = { _ in true }
            let adjusted = expectation(description: "Disabled tap resets its target")
            adjusted.expectedFulfillmentCount = 2
            var targets: [CGDirectDisplayID] = []
            controller.adjust = { id, _, _ in targets.append(id); adjusted.fulfill() }

            XCTAssertNil(controller.handle(type: mediaEventType, event: try keyEvent()))
            let notification = try XCTUnwrap(CGEvent(source: nil))
            XCTAssertNotNil(controller.handle(type: type, event: notification))
            selected = 84
            XCTAssertNil(controller.handle(type: mediaEventType, event: try keyEvent(repeated: true)))

            wait(for: [adjusted], timeout: 2)
            XCTAssertEqual(targets, [42, 84])
        }
    }

    func testFreshOptionShortcutPassesThroughAfterMissingKeyUp() throws {
        let controller = KeyboardBrightnessController(displaySelector: { _ in 42 })
        controller.canControl = { _ in true }
        let adjusted = expectation(description: "Initial brightness press is delivered")
        controller.adjust = { _, _, _ in adjusted.fulfill() }

        XCTAssertNil(controller.handle(type: mediaEventType, event: try keyEvent()))
        XCTAssertNotNil(controller.handle(type: mediaEventType, event: try keyEvent(modifiers: [.option])))
        XCTAssertNotNil(controller.handle(type: mediaEventType, event: try keyEvent(state: 0xB, modifiers: [.option])))

        wait(for: [adjusted], timeout: 2)
    }

    private var mediaEventType: CGEventType { CGEventType(rawValue: 14)! }

    // Constructing events does not post them or require an active event tap.
    private func keyEvent(state: Int = 0xA, repeated: Bool = false,
                          modifiers: NSEvent.ModifierFlags = []) throws -> CGEvent {
        let event = NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
            data1: (2 << 16) | (state << 8) | (repeated ? 1 : 0), data2: -1
        )
        return try XCTUnwrap(event?.cgEvent)
    }
}
