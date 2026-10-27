import XCTest
@testable import AppleSiliconDDC

final class DDCTransportTests: XCTestCase {
    func testRoutesOnlyMutualUniquePositiveMatches() {
        XCTAssertEqual(routes([[12, 2], [3, 11]]), ["0:0", "1:1"])
        XCTAssertEqual(routes([[10, 11], [12, 1]]), ["0:1", "1:0"])
        XCTAssertEqual(routes([[10, 10]]), [], "One display cannot choose between tied services")
        XCTAssertEqual(routes([[10], [10]]), [], "One service cannot choose between tied displays")
        XCTAssertEqual(routes([[nil, 0], [-1, nil]]), [], "Absent and nonpositive candidates cannot route")
        XCTAssertEqual(routes([[nil, 12], [10, nil]]), ["0:1", "1:0"])
        XCTAssertEqual(routes([[12, 11], [10, 9]]), ["0:0"], "Do not assign a weaker remaining candidate after another route wins")
        XCTAssertEqual(routes([[8, 10], [8, 1]]), ["0:1"], "A service-side tie remains ambiguous even when another route is unique")
    }

    func testDecodesValidatedVCPReading() throws {
        let reading = try XCTUnwrap(AppleSiliconDDC.decodeVCPReply(makeReply(current: 0x0123, maximum: 0x0456), command: 0x10))
        XCTAssertEqual(reading.current, 0x0123)
        XCTAssertEqual(reading.max, 0x0456)
    }

    func testRejectsMalformedOrUnrelatedRepliesEvenWithValidChecksums() {
        let valid = makeReply()
        let invalidFields: [(Int, UInt8)] = [(0, 0x6f), (1, 0x80), (2, 0x03), (3, 0x01), (4, 0x12)]
        for (index, value) in invalidFields {
            var reply = valid
            reply[index] = value
            reply[10] = reply.dropLast().reduce(UInt8(0x50), ^)
            XCTAssertNil(AppleSiliconDDC.decodeVCPReply(reply, command: 0x10), "Must reject field \(index)")
        }
        XCTAssertNil(AppleSiliconDDC.decodeVCPReply(Array(valid.dropLast()), command: 0x10))
        XCTAssertNil(AppleSiliconDDC.decodeVCPReply(valid + [0], command: 0x10))
        XCTAssertNil(AppleSiliconDDC.decodeVCPReply([], command: 0x10))
        var damaged = valid
        damaged[8] ^= 1
        XCTAssertNil(AppleSiliconDDC.decodeVCPReply(damaged, command: 0x10))
    }

    func testSuccessfulWriteCannotHideFailedRead() {
        var send: [UInt8] = [0x10]
        var reply = [UInt8](repeating: 0, count: 11)
        var reads = 0
        let result = AppleSiliconDDC.performDDCCommunication(send: &send, reply: &reply, numOfWriteCycles: 1, numOfRetryAttemps: 2, writePacket: { _ in true }, readReply: { buffer in
            reads += 1
            buffer = self.makeReply()
            return false
        }, sleep: { _ in })
        XCTAssertFalse(result)
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(reply, [UInt8](repeating: 0, count: 11))
    }

    func testRetryClearsOldReplyAndWaitsForValidRead() {
        var send: [UInt8] = [0x10]
        var reply = makeReply()
        var reads = 0
        let result = AppleSiliconDDC.performDDCCommunication(send: &send, reply: &reply, numOfWriteCycles: 1, numOfRetryAttemps: 2, writePacket: { _ in true }, readReply: { buffer in
            XCTAssertEqual(buffer, [UInt8](repeating: 0, count: 11))
            reads += 1
            if reads == 1 {
                buffer = self.makeReply()
                return false
            }
            if reads == 2 {
                buffer[0] = 0x6e
                return true
            }
            buffer = self.makeReply(current: 42)
            return true
        }, sleep: { _ in })
        XCTAssertTrue(result)
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(AppleSiliconDDC.decodeVCPReply(reply, command: 0x10)?.current, 42)
    }

    func testMaximumRetryCountDoesNotOverflowAndZeroWriteCyclesStillWrites() {
        var send: [UInt8] = [0x10, 0, 50]
        var reply: [UInt8] = []
        var writes = 0
        let result = AppleSiliconDDC.performDDCCommunication(send: &send, reply: &reply, numOfWriteCycles: 0, numOfRetryAttemps: 255, writePacket: { _ in
            writes += 1
            return false
        }, readReply: { _ in
            XCTFail("A VCP write has no reply")
            return false
        }, sleep: { _ in })
        XCTAssertFalse(result)
        XCTAssertEqual(writes, 256)
    }

    func testFailedWriteDoesNotReadStaleMonitorReply() {
        var send: [UInt8] = [0x10]
        var reply = makeReply()
        let result = AppleSiliconDDC.performDDCCommunication(send: &send, reply: &reply, numOfWriteCycles: 1, numOfRetryAttemps: 0, writePacket: { _ in false }, readReply: { _ in
            XCTFail("No reply is valid when the request write fails")
            return true
        }, sleep: { _ in })
        XCTAssertFalse(result)
        XCTAssertEqual(reply, [UInt8](repeating: 0, count: 11))
    }

    func testInvalidBrightnessIsRejectedBeforeLookingUpHardware() {
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertFalse(AppleSiliconDDC.setBrightness(value, displayID: 0))
        }
    }

    private func makeReply(current: UInt16 = 50, maximum: UInt16 = 100) -> [UInt8] {
        var reply: [UInt8] = [0x6e, 0x88, 0x02, 0, 0x10, 0,
                              UInt8(maximum >> 8), UInt8(maximum & 0xff),
                              UInt8(current >> 8), UInt8(current & 0xff)]
        reply.append(reply.reduce(UInt8(0x50), ^))
        return reply
    }

    private func routes(_ scores: [[Int?]]) -> [String] {
        AppleSiliconDDC.unambiguousMatches(scores: scores).map { "\($0.displayIndex):\($0.serviceIndex)" }
    }
}
