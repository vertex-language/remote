package rdp

import "crypto/tls"
import "remote/rdp/x224"

/// Transport moves RDP PDUs over the authenticated TLS 1.2 channel. Slow-
/// path PDUs are wrapped in X.224 Data + TPKT; it also buffers and splits
/// incoming TPKT/fast-path frames.
public struct Transport {
    public var conn: tls.Conn12
    var splitter: x224.FrameSplitter

    public init(conn: tls.Conn12) {
        self.conn = conn
        self.splitter = x224.FrameSplitter()
    }

    /// SendX224 wraps a payload in an X.224 Data PDU and sends it.
    public mutating func SendX224(_ payload: [uint8]) async throws {
        try await conn.Write(x224.WrapData(payload))
    }

    /// NextFrame returns the next whole frame from the server, reading more
    /// TLS data as needed.
    public mutating func NextFrame() async throws -> x224.Frame {
        while true {
            if let f = try splitter.Next() {
                return f
            }
            var buf = [uint8](repeating: 0, count: 16384)
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
