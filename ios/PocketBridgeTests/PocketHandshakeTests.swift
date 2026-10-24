import Foundation
import XCTest
@testable import PocketBridge

final class PocketHandshakeTests: XCTestCase {
    private let key = "0123456789ABCDEF"

    @MainActor
    func testFreshPairingUsesReplyOnlyThenClosesAndReauthenticates() async throws {
        var events: [String] = []
        var keys: [String] = []
        try await PocketHandshake.establish(
            key: key, pairing: true,
            open: { events.append("reply notifications ready") },
            authenticate: { key in events.append("SK"); keys.append(key); return true },
            close: { events.append("close") },
            pause: { events.append("settle") }
        )
        XCTAssertEqual(events, ["reply notifications ready", "SK", "close", "settle", "reply notifications ready", "SK"])
        XCTAssertEqual(keys, [key, key])
    }

    @MainActor
    func testReconnectCanRecoverWithoutChangingTheSavedKey() async throws {
        var opens = 0
        var closes = 0
        var pauses = 0
        var keys: [String] = []
        try await PocketHandshake.establish(
            key: key, pairing: true,
            open: { opens += 1; if opens == 2 { throw URLError(.cannotConnectToHost) } },
            authenticate: { key in keys.append(key); return true },
            close: { closes += 1 },
            pause: { pauses += 1 }
        )
        XCTAssertEqual(opens, 3)
        XCTAssertEqual(closes, 2)
        XCTAssertEqual(pauses, 2)
        XCTAssertEqual(keys, [key, key])
    }

    @MainActor
    func testARejectedSavedKeyDoesNotTriggerMoreAuthentication() async throws {
        var attempts = 0
        do {
            try await PocketHandshake.establish(
                key: key, pairing: true,
                open: {},
                authenticate: { _ in attempts += 1; return attempts == 1 },
                close: {}, pause: {}
            )
            XCTFail("A rejected reconnect key must stop pairing")
        } catch is PocketHandshake.Failure { }
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testCancellationDuringSettleStopsBeforeAnotherBluetoothWrite() async throws {
        var attempts = 0
        do {
            try await PocketHandshake.establish(
                key: key, pairing: true, open: {},
                authenticate: { _ in attempts += 1; return true },
                close: {}, pause: { throw CancellationError() }
            )
            XCTFail("Cancellation must stop pairing")
        } catch is CancellationError { }
        XCTAssertEqual(attempts, 1)
    }

    @MainActor
    func testExistingKeyConnectionAuthenticatesOnce() async throws {
        var events: [String] = []
        try await PocketHandshake.establish(
            key: key, pairing: false,
            open: { events.append("replies") }, authenticate: { _ in events.append("SK"); return true },
            close: { XCTFail("An existing-key connection does not need a first-pair restart") },
            pause: { XCTFail("No first-pair delay is needed") }
        )
        XCTAssertEqual(events, ["replies", "SK"])
    }

    @MainActor
    func testInitialAuthenticationTimeoutDoesNotStartReconnect() async throws {
        do {
            try await PocketHandshake.establish(
                key: key, pairing: true, open: {},
                authenticate: { _ in throw URLError(.timedOut) },
                close: { XCTFail("No accepted first pairing yet") },
                pause: { XCTFail("No accepted first pairing yet") }
            )
            XCTFail("Authentication must complete")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
    }

    @MainActor
    func testReconnectStopsAfterThreeAttempts() async throws {
        var opens = 0
        var keys: [String] = []
        do {
            try await PocketHandshake.establish(
                key: key, pairing: true,
                open: { opens += 1; if opens > 1 { throw URLError(.cannotConnectToHost) } },
                authenticate: { key in keys.append(key); return true },
                close: {}, pause: {}
            )
            XCTFail("A failed reconnect must remain a failure")
        } catch { XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost) }
        XCTAssertEqual(opens, 4)
        XCTAssertEqual(keys, [key])
    }

    func testCommandSelectionRequiresWritablePropertiesAndSupportsCapturedA3Route() {
        XCTAssertEqual(PocketProtocol.commandUUID(writes: [PocketProtocol.command], writesWithoutResponse: [PocketProtocol.reply]), PocketProtocol.command)
        XCTAssertEqual(PocketProtocol.commandUUID(writes: [], writesWithoutResponse: [PocketProtocol.reply]), PocketProtocol.reply)
        XCTAssertEqual(PocketProtocol.commandUUID(writes: [], writesWithoutResponse: [PocketProtocol.command]), PocketProtocol.command)
        XCTAssertEqual(PocketProtocol.commandUUID(writes: [PocketProtocol.reply], writesWithoutResponse: []), PocketProtocol.reply)
        XCTAssertNil(PocketProtocol.commandUUID(writes: [], writesWithoutResponse: []))
    }

    func testPendingCancelMustFinishBeforeAnotherConnectionStarts() throws {
        var link = PocketLinkLifecycle()
        try link.beginConnection()
        XCTAssertTrue(link.beginClosing())
        XCTAssertFalse(link.beginClosing())
        XCTAssertTrue(link.isPending)
        XCTAssertFalse(link.isConnected)
        XCTAssertThrowsError(try link.beginConnection())
        XCTAssertTrue(link.didFailToConnect())
        XCTAssertFalse(link.isPending)
        XCTAssertNoThrow(try link.beginConnection())
    }

    func testConnectDuringCancelStillNeedsItsDisconnectCallback() throws {
        var link = PocketLinkLifecycle()
        try link.beginConnection()
        XCTAssertTrue(link.beginClosing())
        XCTAssertFalse(link.didConnect())
        XCTAssertTrue(link.isClosing)
        XCTAssertFalse(link.didFailToConnect())
        XCTAssertThrowsError(try link.beginConnection())
        XCTAssertTrue(link.didDisconnect())
        XCTAssertFalse(link.didDisconnect())
        XCTAssertNoThrow(try link.beginConnection())
    }

    func testCancelledPendingConnectionCanEndWithDisconnect() throws {
        var link = PocketLinkLifecycle()
        try link.beginConnection()
        XCTAssertTrue(link.beginClosing())
        XCTAssertTrue(link.didDisconnect())
        XCTAssertFalse(link.isPending)
        XCTAssertNoThrow(try link.beginConnection())
    }

    func testOldFailedConnectCannotCloseAnEstablishedLink() throws {
        var link = PocketLinkLifecycle()
        try link.beginConnection()
        XCTAssertTrue(link.didConnect())
        XCTAssertFalse(link.didFailToConnect())
        XCTAssertTrue(link.isConnected)
        XCTAssertTrue(link.beginClosing())
        XCTAssertFalse(link.isConnected)
        XCTAssertFalse(link.didFailToConnect())
        XCTAssertTrue(link.isPending)
        XCTAssertTrue(link.didDisconnect())
        XCTAssertFalse(link.isPending)
    }

    @MainActor
    func testAcceptedSessionDropReconnectsWithTheCapturedKey() async throws {
        var accepted = false
        try await PocketHandshake.establish(
            key: key, pairing: false, open: {}, authenticate: { $0 == key }, close: {}, pause: {}
        )
        accepted = true
        var drops = 0
        var attempts: [(String, Bool)] = []
        do {
            try await PocketReconnectLoop.run(
                key: key,
                isBluetoothOn: { true },
                waitForSessionEnd: {
                    drops += 1
                    if drops > 1 { throw CancellationError() }
                },
                waitForBluetoothOn: {}, waitForLinkDrain: {}, closeLink: {},
                connect: { key, pairing in attempts.append((key, pairing)) },
                pause: { _ in }
            )
            XCTFail("The monitor should keep running until it is cancelled")
        } catch is CancellationError { }
        XCTAssertTrue(accepted)
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts.first?.0, key)
        XCTAssertEqual(attempts.first?.1, false)
    }

    @MainActor
    func testRejectedReconnectStopsWithoutChangingTheSavedKey() async throws {
        var attempts = 0
        let savedKey = key
        do {
            try await PocketReconnectLoop.run(
                key: key,
                isBluetoothOn: { true }, waitForSessionEnd: {},
                waitForBluetoothOn: {}, waitForLinkDrain: {},
                closeLink: { XCTFail("A rejected key must stop the retry loop") },
                connect: { _, _ in attempts += 1; throw PocketHandshake.Failure.rejected },
                pause: { _ in }
            )
            XCTFail("A rejected key must stop reconnecting")
        } catch PocketHandshake.Failure.rejected { }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(savedKey, key)
    }

    @MainActor
    func testFailedFirstAuthenticationNeverStartsTheMonitor() async throws {
        var monitorStarted = false
        do {
            try await PocketHandshake.establish(
                key: key, pairing: false, open: {},
                authenticate: { _ in false }, close: {}, pause: {}
            )
            monitorStarted = true
            try await PocketReconnectLoop.run(
                key: key, isBluetoothOn: { true }, waitForSessionEnd: {},
                waitForBluetoothOn: {}, waitForLinkDrain: {}, closeLink: {},
                connect: { _, _ in }, pause: { _ in }
            )
        } catch PocketHandshake.Failure.rejected { }
        XCTAssertFalse(monitorStarted)
    }

    @MainActor
    func testCancellationDuringBackoffPreventsAReconnect() async throws {
        var connects = 0
        do {
            try await PocketReconnectLoop.run(
                key: key, isBluetoothOn: { true }, waitForSessionEnd: {},
                waitForBluetoothOn: {}, waitForLinkDrain: {}, closeLink: {},
                connect: { _, _ in connects += 1 },
                pause: { _ in throw CancellationError() }
            )
            XCTFail("Cancellation must stop before the next connection")
        } catch is CancellationError { }
        XCTAssertEqual(connects, 0)
    }

    @MainActor
    func testBluetoothMustReturnAndOldLinkMustDrainBeforeReconnect() async throws {
        var bluetoothOn = false
        var drops = 0
        var events: [String] = []
        do {
            try await PocketReconnectLoop.run(
                key: key,
                isBluetoothOn: { bluetoothOn },
                waitForSessionEnd: {
                    events.append("link lost")
                    drops += 1
                    if drops > 1 { throw CancellationError() }
                },
                waitForBluetoothOn: { events.append("Bluetooth on"); bluetoothOn = true },
                waitForLinkDrain: { events.append("old link drained") },
                closeLink: {},
                connect: { _, pairing in
                    XCTAssertFalse(pairing)
                    events.append("connect")
                },
                pause: { _ in events.append("backoff") }
            )
            XCTFail("The monitor should wait for another link drop")
        } catch is CancellationError { }
        XCTAssertEqual(events, ["link lost", "Bluetooth on", "old link drained", "backoff", "connect", "link lost"])
    }

    @MainActor
    func testExpectedPairingCloseHappensBeforeTheMonitorStarts() async throws {
        var monitorStarts = 0
        try await PocketHandshake.establish(
            key: key, pairing: true, open: {}, authenticate: { _ in true },
            close: { XCTAssertEqual(monitorStarts, 0) }, pause: {}
        )
        XCTAssertEqual(monitorStarts, 0)
        do {
            try await PocketReconnectLoop.run(
                key: key, isBluetoothOn: { true },
                waitForSessionEnd: { monitorStarts += 1; throw CancellationError() },
                waitForBluetoothOn: {}, waitForLinkDrain: {}, closeLink: {},
                connect: { _, _ in }, pause: { _ in }
            )
        } catch is CancellationError { }
        XCTAssertEqual(monitorStarts, 1)
    }

    @MainActor
    func testStoppingTransferDoesNotCancelTheConnectionMonitor() async throws {
        let monitor = Task {
            try await PocketReconnectLoop.run(
                key: key, isBluetoothOn: { true },
                waitForSessionEnd: { try await Task.sleep(for: .seconds(30)) },
                waitForBluetoothOn: {}, waitForLinkDrain: {}, closeLink: {},
                connect: { _, _ in }, pause: { _ in }
            )
        }
        await Task.yield()
        let transfer = Task<Void, Never> {
            do { try await Task.sleep(for: .seconds(30)) } catch { }
        }
        PocketSessionTaskControl.stopTransfer(transfer) { }
        await transfer.value
        XCTAssertFalse(monitor.isCancelled)
        monitor.cancel()
        do { try await monitor.value } catch is CancellationError { }
    }

    @MainActor
    func testRepeatedDropsDuringSetupIncreaseRetryDelay() async throws {
        var attempts = 0
        var delays: [Duration] = []
        do {
            try await PocketReconnectLoop.run(
                key: key, isBluetoothOn: { true }, waitForSessionEnd: {},
                waitForBluetoothOn: {}, waitForLinkDrain: {}, closeLink: {},
                connect: { _, _ in
                    attempts += 1
                    if attempts == 4 { throw CancellationError() }
                    throw PocketError.message("Link lost during information reads")
                },
                pause: { delays.append($0) }
            )
        } catch is CancellationError { }
        XCTAssertEqual(delays, [.seconds(1), .seconds(2), .seconds(4), .seconds(8)])
    }

    @MainActor
    func testReconnectBackoffIsCapped() {
        XCTAssertEqual(PocketReconnectLoop.backoff(attempt: 0), .seconds(1))
        XCTAssertEqual(PocketReconnectLoop.backoff(attempt: 5), .seconds(30))
        XCTAssertEqual(PocketReconnectLoop.backoff(attempt: 50), .seconds(30))
    }
}
