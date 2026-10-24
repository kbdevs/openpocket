import Foundation
import XCTest
@testable import PocketBridge

final class PocketRememberedDeviceTests: XCTestCase {
    func testPairedPocketSurvivesRelaunchUntilForgotten() throws {
        let suite = "PocketRememberedDeviceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(PocketRememberedDevice.load(from: defaults))
        let device = PocketRememberedDevice(id: UUID(), name: "PKT01_BLUE_260617b5")
        device.save(to: defaults)
        XCTAssertEqual(PocketRememberedDevice.load(from: defaults), device)

        PocketRememberedDevice.forget(in: defaults)
        XCTAssertNil(PocketRememberedDevice.load(from: defaults))
    }
}
