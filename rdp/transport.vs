package rdp

import "crypto/tls"
import "remote/rdp/x224"

/// Sender is the write half of the connection. The session and its Input
/// share one, from different tasks: writes queue up and go out whole and
/// in order, so TLS records never interleave.
public final class Sender {
    var conn: tls.Conn12
    var queue: [[uint8]] = []
    var writing: bool = false
    var failed: string = ""

    init(conn: tls.Conn12) {
        self.conn = conn
    }

    /// Send writes bytes to the server as they are (already framed).
    public func Send(_ bytes: [uint8]) async throws {
        if !failed.isEmpty { throw RdpError.protocolError(failed) }
        queue.append(bytes)
        // Whoever is already writing drains the queue, this one included.
        if writing { return }
        writing = true
        while queue.count > 0 {
            let next = queue[0]
            queue.remove(at: 0)
            do {
                try await conn.Write(next)
            } catch {
                failed = "write failed: \(error)"
                queue = []
                writing = false
                throw RdpError.protocolError(failed)
            }
        }
        writing = false
    }

    /// SendX224 wraps a payload in an X.224 Data PDU and sends it.
    public func SendX224(_ payload: [uint8]) async throws {
        try await Send(x224.WrapData(payload))
    }

    /// Close shuts the socket; a read waiting on the other half ends too.
    public func Close() {
        conn.Close()
    }
}

/// Transport moves RDP PDUs over the authenticated TLS channel. Reads
/// happen here, on one task, splitting the stream into TPKT and fast-path
/// frames; writes go through the shared Sender.
public struct Transport {
    var conn: tls.Conn12
    var splitter: x224.FrameSplitter
    var buf: [uint8]
    public var Out: Sender

    /// Takes over an authenticated connection. The read state stays here
    /// and the write state goes to the Sender: TLS 1.2 keeps the two
    /// directions apart, and nothing on the read path writes.
    public init(conn: tls.Conn12) {
        self.conn = conn
        self.splitter = x224.FrameSplitter()
        self.buf = [uint8](repeating: 0, count: 16384)
        self.Out = Sender(conn: conn)
    }

    /// SendX224 wraps a payload in an X.224 Data PDU and sends it.
    public func SendX224(_ payload: [uint8]) async throws {
        try await Out.SendX224(payload)
    }

    /// NextFrame returns the next whole frame from the server, reading more
    /// TLS data as needed.
    public mutating func NextFrame() async throws -> x224.Frame {
        while true {
            if let f = try splitter.Next() {
                return f
            }
            let n = try await conn.Read(into: &buf)
            if n <= 0 { throw RdpError.connectionClosed }
            var chunk = [uint8](repeating: 0, count: n)
            var i = 0
            while i < n { chunk[i] = buf[i]; i += 1 }
            splitter.Feed(chunk)
        }
    }

    /// NextX224Payload returns the payload of the next slow-path X.224 Data
    /// PDU (skipping any fast-path frames, which do not occur pre-capability).
    public mutating func NextX224Payload() async throws -> [uint8] {
        while true {
            let frame = try await NextFrame()
            switch frame {
            case .slowPath(let bytes):
                return try x224.UnwrapData(bytes)
            case .fastPath(_):
                continue
            }
        }
    }
}
