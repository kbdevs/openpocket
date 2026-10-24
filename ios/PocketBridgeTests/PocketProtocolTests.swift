import Foundation
import Security
import XCTest
@testable import PocketBridge

final class PocketProtocolTests: XCTestCase {
    func testMessagesSplitCoalescedReplies() throws {
        let data = Data("MCU&WIFIOMCU&OFF".utf8)
        XCTAssertEqual(PocketProtocol.messages(data), [
            try message("MCU&WIFIO"),
            try message("MCU&OFF")
        ])
    }

    func testDirectoryListNeedsValidDatesAndExactCount() throws {
        let summary = try message("MCU&DIRS_SUM&002")
        let entries = [try message("MCU&DIRS&2026-03-28"), try message("MCU&DIRS&2026-03-27")]
        XCTAssertEqual(PocketProtocol.directoryDates(entries, summary: summary), ["2026-03-28", "2026-03-27"])
        XCTAssertNil(PocketProtocol.directoryDates(entries + [try message("MCU&DIRS&2026-02-31")], summary: summary))
        XCTAssertNil(PocketProtocol.directoryDates(entries, summary: try message("MCU&DIRS_SUM&+2")))
        XCTAssertNil(PocketProtocol.directoryDates(entries, summary: try message("MCU&DIRS_SUM&2&extra")))
        XCTAssertNil(PocketProtocol.directoryDates([entries[0]], summary: summary))
    }

    func testFileListValidatesEveryNameAndCount() throws {
        let summary = try message("MCU&LIST&001")
        let file = try message("MCU&F&2026-03-28&PH261002211958&42")
        let parsed = try XCTUnwrap(PocketProtocol.recordings([file], summary: summary, date: "2026-03-28"))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].name, "PH261002211958")

        XCTAssertEqual(PocketProtocol.recordings([file, file], summary: summary, date: "2026-03-28")?.count, 1)
        XCTAssertNil(PocketProtocol.recordings([try message("MCU&F&2026-03-28&../escape&42")], summary: summary, date: "2026-03-28"))
        XCTAssertNil(PocketProtocol.recordings([try message("MCU&F&2026-03-28&bad/name&42")], summary: summary, date: "2026-03-28"))
        XCTAssertNil(PocketProtocol.recordings([try message("MCU&F&2026-03-28&recording&42")], summary: try message("MCU&LIST&+1"), date: "2026-03-28"))
        XCTAssertNil(PocketProtocol.recordings([file], summary: summary, date: "2026-03-27"))
        XCTAssertNil(PocketProtocol.recordings([file, try message("MCU&F&2026-03-28&PH261002211958&43")], summary: summary, date: "2026-03-28"))
    }

    func testNamesCannotEscapeAPathComponent() {
        XCTAssertTrue(PocketProtocol.safeName("20260328001919"))
        XCTAssertTrue(PocketProtocol.safeName("PH261002211958"))
        XCTAssertFalse(PocketProtocol.safeName("."))
        XCTAssertFalse(PocketProtocol.safeName(".."))
        XCTAssertFalse(PocketProtocol.safeName("../escape"))
        XCTAssertFalse(PocketProtocol.safeName("folder/recording"))
        XCTAssertFalse(PocketProtocol.safeName("folder\\recording"))
        XCTAssertFalse(PocketProtocol.safeName(String(repeating: "a", count: 101)))
    }

    func testFileSizesArePositiveDecimalBytesWithinLimit() throws {
        XCTAssertEqual(PocketProtocol.size(try message("MCU&U&1")), 1)
        XCTAssertEqual(PocketProtocol.size(try message("MCU&U&1073741824")), PocketProtocol.maxFileBytes)
        for value in ["0", "-1", "+1", "1073741825", "1x", "999999999999999999999999"] {
            XCTAssertNil(PocketProtocol.size(try message("MCU&U&\(value)")), value)
        }
        XCTAssertNil(PocketProtocol.size(try message("MCU&U&1&extra")))
        XCTAssertNil(PocketProtocol.size(try message("MCU&LIST&1")))
    }

    func testVendorBatteryReadsTheFirstBoundedDecimalAndKeepsZero() throws {
        XCTAssertEqual(PocketProtocol.vendorBattery(try message("MCU&BAT&0")), 0)
        XCTAssertEqual(PocketProtocol.vendorBattery(try message("MCU&BAT&100")), 100)
        for value in ["-1", "+1", "101", "1x", "999999999999999999999999"] {
            XCTAssertNil(PocketProtocol.vendorBattery(try message("MCU&BAT&\(value)")), value)
        }
        XCTAssertEqual(PocketProtocol.vendorBattery(try message("MCU&BAT&20&1")), 20)
        XCTAssertNil(PocketProtocol.vendorBattery(try message("MCU&FW&20")))
    }

    func testStandardBatteryRequiresOneByteBetweenZeroAndOneHundred() {
        XCTAssertEqual(PocketProtocol.standardBattery(Data([0])), 0)
        XCTAssertEqual(PocketProtocol.standardBattery(Data([100])), 100)
        XCTAssertNil(PocketProtocol.standardBattery(Data()))
        XCTAssertNil(PocketProtocol.standardBattery(Data([101])))
        XCTAssertNil(PocketProtocol.standardBattery(Data([50, 0])))
    }

    func testBatteryReadingsPreferTheVendorReplyLikeTheVendorApp() {
        var readings = PocketBatteryReadings()
        XCTAssertNil(readings.value)
        readings.setStandard(0)
        XCTAssertEqual(readings.value, 0)
        readings.setVendor(36)
        XCTAssertTrue(readings.differ)
        XCTAssertEqual(readings.value, 36)
        readings.setStandard(36)
        XCTAssertFalse(readings.differ)
        XCTAssertEqual(readings.value, 36)
        readings.setVendor(101)
        XCTAssertEqual(readings.vendor, 36)
        readings.reset()
        XCTAssertNil(readings.value)
        XCTAssertNil(readings.vendor)
        XCTAssertNil(readings.standard)
    }

    func testWiFiCredentialsNeedExpectedNetworkAndWPA2PassphraseLength() throws {
        let valid = try message("MCU&WIFI&PKT01-1234&password123")
        XCTAssertEqual(PocketProtocol.wifiCredentials(valid), PocketWiFiCredentials(ssid: "PKT01-1234", password: "password123"))
        XCTAssertNil(PocketProtocol.wifiCredentials(try message("MCU&WIFI&OTHER-1234&password123")))
        XCTAssertNil(PocketProtocol.wifiCredentials(try message("MCU&WIFI&PKT01-1234&short")))
        XCTAssertNil(PocketProtocol.wifiCredentials(try message("MCU&WIFI&PKT01-1234&password123&extra")))
        XCTAssertNil(PocketProtocol.wifiCredentials(try message("MCU&OFF&PKT01-1234&password123")))
    }

    func testWiFiFrameHandlesAFragmentedEndMarker() throws {
        var frame = PocketWiFiFrame(size: 3)
        XCTAssertEqual(frame.consume(Data([1, 2, 3, 0xba, 0x5a])), Data([1, 2, 3]))
        XCTAssertFalse(frame.hasAllBytes)
        XCTAssertEqual(frame.consume(Data(PocketProtocol.wifiEnd.dropFirst(2))), Data())
        XCTAssertTrue(frame.hasAllBytes)
        XCTAssertTrue(frame.markerMatches)
        XCTAssertEqual(frame.received, 3)
    }

    func testWiFiFrameRejectsBadMarkerAndExtraBytes() {
        var badMarker = PocketWiFiFrame(size: 1)
        XCTAssertNotNil(badMarker.consume(Data([1] + Array(repeating: 0xff, count: 10))))
        XCTAssertFalse(badMarker.markerMatches)

        var extraBytes = PocketWiFiFrame(size: 1)
        XCTAssertNil(extraBytes.consume(Data([1] + Array(PocketProtocol.wifiEnd) + [0xff])))
    }

    func testSessionKeyFormat() {
        XCTAssertTrue(PocketProtocol.validKey(PocketProtocol.newSessionKey()))
        XCTAssertFalse(PocketProtocol.validKey(""))
        XCTAssertFalse(PocketProtocol.validKey("short"))
        XCTAssertFalse(PocketProtocol.validKey(String(repeating: "!", count: 16)))
        XCTAssertFalse(PocketProtocol.validKey(String(repeating: "é", count: 16)))
    }

    func testPairingKeyPersistsAndIsReused() throws {
        let service = "app.pocketbridge.tests.pairing.\(UUID().uuidString)"
        defer {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        }
        let store = PocketPairingKeyStore(service: service)
        let deviceID = UUID()
        let otherDeviceID = UUID()
        let first = try store.key(for: deviceID)
        let other = try store.key(for: otherDeviceID)
        let retry = try PocketPairingKeyStore(service: service).key(for: deviceID)

        XCTAssertTrue(PocketProtocol.validKey(first))
        XCTAssertTrue(first == retry)
        XCTAssertFalse(first == other)
        let accepted = PocketProtocol.newSessionKey()
        try store.remember(accepted, for: deviceID)
        XCTAssertTrue(try PocketPairingKeyStore(service: service).key(for: deviceID) == accepted)
    }

    func testOnlyMissingKeyMeansNoSavedKey() throws {
        XCTAssertNil(try PocketPairingKeyStore.storedKey(status: errSecItemNotFound, data: nil))
        XCTAssertThrowsError(try PocketPairingKeyStore.storedKey(status: errSecInteractionNotAllowed, data: nil))
        XCTAssertThrowsError(try PocketPairingKeyStore.storedKey(status: errSecSuccess, data: nil))
        XCTAssertThrowsError(try PocketPairingKeyStore.storedKey(status: errSecSuccess, data: Data([0xff])))
    }

    func testFirstPairingRepliesMayShareOneNotification() throws {
        XCTAssertEqual(PocketProtocol.messages(Data("MCU&SK&OKMCU&WIFIO".utf8)), [
            try message("MCU&SK&OK"), try message("MCU&WIFIO")
        ])
    }

    func testPairingStoreFailurePreventsBluetoothConnection() {
        var started = false
        XCTAssertThrowsError(try PocketPairingKeyStore.startPairing(
            for: UUID(),
            keyFor: { _ in throw PocketError.message("Keychain is unavailable.") },
            startConnection: { _ in started = true }
        ))
        XCTAssertFalse(started)
    }

    func testPocketWiFiRouteMustUseItsSubnet() {
        XCTAssertTrue(PocketProtocol.isPocketAPAddress("192.168.200.2"))
        XCTAssertFalse(PocketProtocol.isPocketAPAddress("192.168.1.2"))
        XCTAssertFalse(PocketProtocol.isPocketAPAddress("192.168.200.255"))
        XCTAssertFalse(PocketProtocol.isPocketAPAddress("not-an-address"))
    }

    private func message(_ text: String) throws -> PocketProtocol.Message {
        try XCTUnwrap(PocketProtocol.Message(text: text))
    }
}
