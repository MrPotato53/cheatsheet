import Foundation
import Network

/// Serves one HTML page on 127.0.0.1, so web page tests don't need the
/// internet. Every request gets the same page.
final class LocalWebServer {
    private let listener: NWListener
    let port: UInt16

    var address: String { "http://127.0.0.1:\(port)/" }

    private static let portRange: ClosedRange<UInt16> = 49_152...65_000
    private static let attempts = 10

    /// Listens on an explicit ephemeral port (a loopback-bound listener
    /// can't pick its own), retrying if it's taken.
    init(html: String) throws {
        let body = Data(html.utf8)
        for _ in 0..<Self.attempts {
            let port = UInt16.random(in: Self.portRange)
            if let listener = Self.startListener(on: port, body: body) {
                self.listener = listener
                self.port = port
                return
            }
        }
        throw URLError(.cannotConnectToHost)
    }

    private static func startListener(on port: UInt16, body: Data) -> NWListener? {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        // Loopback only: listening on every interface needs Local Network
        // permission, which the test runner may not have (or be asked for).
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                    + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        let ready = DispatchSemaphore(value: 0)
        let isReady = LockedFlag()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                isReady.set()
                ready.signal()
            case .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
        guard isReady.value else {
            listener.cancel()
            return nil
        }
        return listener
    }

    /// A `.webloc` file's contents pointing at this server.
    var weblocContents: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>URL</key><string>\(address)</string></dict></plist>
        """
    }

    deinit {
        listener.cancel()
    }
}

/// Set from the listener's queue, read after the semaphore wait.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    var value: Bool { lock.withLock { isSet } }

    func set() { lock.withLock { isSet = true } }
}
