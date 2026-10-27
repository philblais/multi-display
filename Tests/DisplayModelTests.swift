import Foundation
import XCTest

final class DisplayModelTests: XCTestCase {
    func testFractionalRefreshRatesStayDistinctFromWholeRates() throws {
        XCTAssertFalse(try signature(refreshRate: 59.94).matches(signature(refreshRate: 60)))
        XCTAssertFalse(try signature(refreshRate: 119.88).matches(signature(refreshRate: 120)))
    }

    func testSmallRefreshReportingDifferencesStillMatch() throws {
        XCTAssertTrue(try signature(refreshRate: 59.94).matches(signature(refreshRate: 59.9401)))
        XCTAssertTrue(try signature(refreshRate: 0).matches(signature(refreshRate: 0)))
    }

    func testModeMatchingRequiresLogicalAndPixelDimensions() throws {
        let expected = try signature(refreshRate: 60)
        XCTAssertFalse(try expected.matches(signature(refreshRate: 60, width: 1280)))
        XCTAssertFalse(try expected.matches(signature(refreshRate: 60, height: 720)))
        XCTAssertFalse(try expected.matches(signature(refreshRate: 60, pixelWidth: 1920)))
        XCTAssertFalse(try expected.matches(signature(refreshRate: 60, pixelHeight: 1080)))
    }

    func testLegacyModeSignatureRetainsItsSavedRefreshRate() throws {
        let saved = try signature(refreshRate: 59.94)
        let decoded = try JSONDecoder().decode(ModeSignature.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded, saved)
        XCTAssertTrue(decoded.matches(saved))
    }

    private func signature(refreshRate: Double, width: Int = 1920, height: Int = 1080,
                           pixelWidth: Int = 3840, pixelHeight: Int = 2160) throws -> ModeSignature {
        let json = """
        {"width":\(width),"height":\(height),"pixelWidth":\(pixelWidth),"pixelHeight":\(pixelHeight),"refreshRate":\(refreshRate)}
        """
        return try JSONDecoder().decode(ModeSignature.self, from: Data(json.utf8))
    }
}
