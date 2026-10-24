import Foundation

// A new link starts only after CoreBluetooth ends the old connect/cancel request.
struct PocketLinkLifecycle {
    enum Phase { case idle, connecting, connected, cancellingConnection, disconnecting }
    private(set) var phase = Phase.idle
    var isPending: Bool { phase != .idle }
    var isConnected: Bool { phase == .connected }
    var isClosing: Bool { phase == .cancellingConnection || phase == .disconnecting }

    mutating func beginConnection() throws {
        guard !isPending else { throw PocketError.message("The previous Pocket connection is still closing.") }
        phase = .connecting
    }

    mutating func beginClosing() -> Bool {
        switch phase {
        case .connecting: phase = .cancellingConnection
        case .connected: phase = .disconnecting
        default: return false
        }
        return true
    }

    mutating func didConnect() -> Bool {
        if phase == .cancellingConnection { phase = .disconnecting; return false }
        guard phase == .connecting else { return false }
        phase = .connected
        return true
    }

    mutating func didFailToConnect() -> Bool {
        guard phase == .connecting || phase == .cancellingConnection else { return false }
        phase = .idle
        return true
    }

    mutating func didDisconnect() -> Bool {
        guard phase == .connected || phase == .disconnecting || phase == .cancellingConnection else { return false }
        phase = .idle
        return true
    }
}

// Sequence used by pocket-libre pair: reply notifications, SK, close, 2 s,
// a fresh connection and the SAME SK. Audio notifications belong to file transfer.
@MainActor
enum PocketHandshake {
    enum Failure: LocalizedError {
        case rejected
        case permanent(String)
        var errorDescription: String? {
            switch self {
            case .rejected:
                return "Pocket rejected the saved pairing key. The key was kept. A recorder still paired with another app needs that app’s key."
            case .permanent(let message): return message
            }
        }
    }

    static func establish(
        key: String,
        pairing: Bool,
        open: () async throws -> Void,
        authenticate: (String) async throws -> Bool,
        close: () async throws -> Void,
        pause: () async throws -> Void
    ) async throws {
        guard PocketProtocol.validKey(key) else { throw PocketError.message("Invalid Pocket pairing key.") }
        try Task.checkCancellation()
        try await open()
        guard try await authenticate(key) else { throw Failure.rejected }
        if pairing {
            try await close()
            for attempt in 0..<3 {
                try Task.checkCancellation()
                try await pause()
                do {
                    try await open()
                    guard try await authenticate(key) else { throw Failure.rejected }
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch let rejection as Failure {
                    throw rejection
                } catch {
                    if attempt == 2 { throw error }
                    try await close()
                }
            }
        }
        try Task.checkCancellation()
    }
}

@MainActor
enum PocketReconnectLoop {
    static func backoff(attempt: Int) -> Duration {
        .seconds(min(30, 1 << min(max(attempt, 0), 5)))
    }

    static func run(
        key: String,
        isBluetoothOn: () -> Bool,
        waitForSessionEnd: () async throws -> Void,
        waitForBluetoothOn: () async throws -> Void,
        waitForLinkDrain: () async throws -> Void,
        closeLink: () async -> Void,
        connect: (String, Bool) async throws -> Void,
        pause: (Duration) async throws -> Void
    ) async throws -> Never {
        var failures = 0
        var needsConnection = false

        while true {
            try Task.checkCancellation()
            if !needsConnection {
                try await waitForSessionEnd()
                needsConnection = true
            }
            if !isBluetoothOn() { try await waitForBluetoothOn() }
            try await waitForLinkDrain()
            try Task.checkCancellation()
            try await pause(backoff(attempt: failures))
            if !isBluetoothOn() { try await waitForBluetoothOn() }

            do {
                try await connect(key, false)
                failures = 0
                needsConnection = false
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as PocketHandshake.Failure {
                throw failure
            } catch {
                await closeLink()
                try await waitForLinkDrain()
                failures += 1
                needsConnection = true
            }
        }
    }
}

@MainActor
enum PocketSessionTaskControl {
    static func stopTransfer(_ operation: Task<Void, Never>?, cancelTransport: () -> Void) {
        operation?.cancel()
        cancelTransport()
    }
}
