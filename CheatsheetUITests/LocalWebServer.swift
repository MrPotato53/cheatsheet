import Foundation
import Network

/// Serves one HTML page on 127.0.0.1, so web page tests don't need the
/// internet. Every request gets the same page.
final class LocalWebServer {
    private let listener: NWListener
    let port: UInt16

    var address: String { "http://127.0.0.1:\(port)/" }

    init(html: String) throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let body = Data(html.utf8)
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
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
        self.listener = listener
        self.port = port
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
