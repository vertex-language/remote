// Package x224 is RDP's transport framing: the TPKT envelope (RFC 1006),
// the X.224/T.123 connection PDUs, and the RDP security negotiation that
// rides in the Connection Request and Confirm ([MS-RDPBCGR] 2.2.1.1,
// 2.2.1.2). It does no I/O: it turns structures into bytes and bytes into
// structures, so it can be tested and fuzzed on its own.
//
// After the connection is confirmed, RDP data travels either as TPKT
// "slow-path" PDUs (first byte 0x03) or as "fast-path" updates (first byte
// low two bits zero). `FrameSplitter` tells them apart and hands whole
// frames to the caller.
package x224

import "encoding/binary"

/// The well-known RDP TCP port.
public let DefaultPort: uint16 = 3389

// --- Security protocols requested and selected (RDP_NEG_REQ/RSP). ---

/// SecurityProtocol is a bit in requestedProtocols / a value in
/// selectedProtocol ([MS-RDPBCGR] 2.2.1.1.1).
public struct SecurityProtocol {
    /// Standard RDP Security only (RC4, no server authentication).
    public static let RDP: uint32 = 0x00000000
    /// TLS 1.0/1.1/1.2.
    public static let SSL: uint32 = 0x00000001
    /// CredSSP (NLA): TLS then SPNEGO/NTLM or Kerberos.
    public static let Hybrid: uint32 = 0x00000002
    /// RDSTLS.
    public static let RDSTLS: uint32 = 0x00000004
    /// CredSSP plus the Early User Authorization Result PDU.
    public static let HybridEx: uint32 = 0x00000008
    /// RDS Entra ID (AAD) authentication.
    public static let RDSAAD: uint32 = 0x00000010
}

/// Flags in the RDP_NEG_REQ ([MS-RDPBCGR] 2.2.1.1.1).
public struct NegotiationRequestFlag {
    public static let RestrictedAdminModeRequired: uint8 = 0x01
    public static let RedirectedAuthenticationModeRequired: uint8 = 0x02
    public static let CorrelationInfoPresent: uint8 = 0x08
}

/// Flags in the RDP_NEG_RSP ([MS-RDPBCGR] 2.2.1.1.2).
public struct NegotiationResponseFlag {
    public static let ExtendedClientDataSupported: uint8 = 0x01
    public static let DynVCGFXProtocolSupported: uint8 = 0x02
    public static let RestrictedAdminModeSupported: uint8 = 0x08
    public static let RedirectedAuthenticationModeSupported: uint8 = 0x10
}

/// Reasons a server rejects the requested protocols (RDP_NEG_FAILURE,
/// [MS-RDPBCGR] 2.2.1.1.3).
public enum NegotiationFailureCode: uint32 {
    case sslRequiredByServer = 1
    case sslNotAllowedByServer = 2
    case sslCertNotOnServer = 3
    case inconsistentFlags = 4
    case hybridRequiredByServer = 5
    case sslWithUserAuthRequiredByServer = 6

    public var Message: string {
        switch self {
        case .sslRequiredByServer: return "the server requires TLS"
        case .sslNotAllowedByServer: return "the server does not allow TLS"
        case .sslCertNotOnServer: return "the server has no certificate"
        case .inconsistentFlags: return "inconsistent negotiation flags"
        case .hybridRequiredByServer: return "the server requires CredSSP (NLA)"
        case .sslWithUserAuthRequiredByServer: return "the server requires TLS with user authentication"
        }
    }
}

public enum X224Error: Error {
    case malformed(string)
    case negotiationFailed(NegotiationFailureCode)
    case unexpected(string)

    public var Message: string {
        switch self {
        case .malformed(let s): return "x224: malformed PDU: \(s)"
        case .negotiationFailed(let c): return "x224: negotiation rejected: \(c.Message)"
        case .unexpected(let s): return "x224: \(s)"
        }
    }
}

// --- TPKT (RFC 1006 / T.123). ---

/// TPKTHeader is the 4-byte envelope: version 3, a reserved byte, and the
/// total length (header included) as a big-endian uint16.
public let tpktVersion: uint8 = 0x03

/// The X.224 TPDU type codes used by RDP.
let tpduConnectionRequest: uint8 = 0xE0
let tpduConnectionConfirm: uint8 = 0xD0
let tpduData: uint8 = 0xF0
let tpduDisconnectRequest: uint8 = 0x80

// --- Connection Request ([MS-RDPBCGR] 2.2.1.1). ---

/// ConnectionRequest is the client's first PDU. It carries an optional
/// routing cookie (used by RD load balancers and to prefill the username)
/// and the RDP negotiation request.
public struct ConnectionRequest {
    /// The "mstshash=<user>" cookie, or "" to send none.
    public var Cookie: string = ""
    public var RequestedProtocols: uint32 = 0
    public var Flags: uint8 = 0

    public init(cookie: string = "", requestedProtocols: uint32 = 0, flags: uint8 = 0) {
        self.Cookie = cookie
        self.RequestedProtocols = requestedProtocols
        self.Flags = flags
    }

    /// Encode returns the full TPKT+X.224 Connection Request PDU.
    public func Encode() -> [uint8] {
        var body = binary.Writer()
        if Cookie.count > 0 {
            // "Cookie: mstshash=IDENTIFIER\r\n"
            let line = "Cookie: mstshash=\(Cookie)\r\n"
            for b in line.utf8 {
                body.U8(b)
            }
        }
        // RDP_NEG_REQ: type(1)=0x01, flags(1), length(2 LE)=0x0008, protocols(4 LE).
        body.U8(0x01)
        body.U8(Flags)
        body.U16LE(8)
        body.U32LE(RequestedProtocols)

        // X.224 Connection Request: LI, CR|CDT, DST-REF(2), SRC-REF(2), CLASS(1),
        // then the variable part. LI counts every byte after itself.
        let variable = body.Bytes
        let li = 6 + variable.count
        var x = binary.Writer()
        x.U8(uint8(truncatingIfNeeded: li))
        x.U8(tpduConnectionRequest)
        x.U16BE(0)          // DST-REF
        x.U16BE(0)          // SRC-REF
        x.U8(0)             // CLASS 0
        x.Append(variable)

        return wrapTPKT(x.Bytes)
    }
}

/// ConnectionConfirm is the server's reply: the negotiation response, or a
/// failure ([MS-RDPBCGR] 2.2.1.2).
public struct ConnectionConfirm {
    public var SelectedProtocol: uint32 = 0
    public var Flags: uint8 = 0
    /// Present when the server rejected the request instead of confirming.
    public var Failure: NegotiationFailureCode? = nil

    public init() {}

    /// Parse reads a full TPKT+X.224 Connection Confirm PDU.
    public static func Parse(_ pdu: [uint8]) throws -> ConnectionConfirm {
        var r = binary.Reader(pdu)
        try parseTPKT(&r)
        // X.224 header: LI, code|CDT, DST-REF(2), SRC-REF(2), CLASS(1).
        let li: int
        do {
            li = int(try r.U8())
        } catch {
            throw X224Error.malformed("truncated X.224 header")
        }
        var xr: binary.Reader
        do {
            let code = try r.U8()
            if code != tpduConnectionConfirm {
                throw X224Error.unexpected("expected Connection Confirm (0xD0), got \(code)")
            }
            try r.Skip(5)   // DST-REF, SRC-REF, CLASS
            // The negotiation structure is the rest of the X.224 PDU: li counts
            // the 6 header bytes after the LI byte, so 6 fewer remain.
            xr = try r.Sub(li - 6)
        } catch let e as X224Error {
            throw e
        } catch {
            throw X224Error.malformed("truncated X.224 Connection Confirm")
        }

        var cc = ConnectionConfirm()
        if xr.Remaining == 0 {
            // A server may confirm with no negotiation structure (old servers,
            // or when Standard RDP Security was requested).
            return cc
        }
        do {
            let type = try xr.U8()
            cc.Flags = try xr.U8()
            let _ = try xr.U16LE()          // length, always 8
            let value = try xr.U32LE()
            if type == 0x02 {               // TYPE_RDP_NEG_RSP
                cc.SelectedProtocol = value
            } else if type == 0x03 {        // TYPE_RDP_NEG_FAILURE
                let code = NegotiationFailureCode(rawValue: value) ?? .inconsistentFlags
                cc.Failure = code
                throw X224Error.negotiationFailed(code)
            } else {
                throw X224Error.malformed("unknown negotiation type \(type)")
            }
        } catch let e as X224Error {
            throw e
        } catch {
            throw X224Error.malformed("truncated negotiation response")
        }
        return cc
    }
}

// --- Data PDUs and the frame splitter. ---

/// WrapData wraps a payload in an X.224 Data PDU inside a TPKT. This is the
/// "slow path": MCS and share-control PDUs travel this way.
public func WrapData(_ payload: [uint8]) -> [uint8] {
    var x = binary.Writer()
    x.U8(0x02)              // LI: 2 bytes follow
    x.U8(tpduData)          // TPDU code: Data
    x.U8(0x80)              // EOT
    x.Append(payload)
    return wrapTPKT(x.Bytes)
}

/// UnwrapData returns the payload of an X.224 Data PDU (the caller has
/// already read a whole TPKT frame, e.g. from FrameSplitter).
public func UnwrapData(_ frame: [uint8]) throws -> [uint8] {
    var r = binary.Reader(frame)
    try parseTPKT(&r)
    do {
        let li = int(try r.U8())
        try r.Skip(li)          // Data PDU header after LI: code + EOT (2 bytes)
        return r.Rest()
    } catch {
        throw X224Error.malformed("truncated X.224 Data PDU")
    }
}

/// A frame taken off the wire: either a slow-path TPKT PDU or a fast-path
/// update ([MS-RDPBCGR] 2.2.9.1).
public enum Frame {
    /// A whole TPKT PDU, including its 4-byte header.
    case slowPath([uint8])
    /// A whole fast-path update, including its 1-3 byte header.
    case fastPath([uint8])
}

/// FrameSplitter turns a byte stream into whole frames. Feed it what the
/// socket read; call Next until it returns nil, then read more. It never
/// copies a partial frame out, and it distinguishes TPKT (first byte 0x03)
/// from fast-path (first byte's low two bits zero).
public struct FrameSplitter {
    var buffer: [uint8] = []

    public init() {}

    public mutating func Feed(_ data: [uint8]) {
        buffer.append(contentsOf: data)
    }

    public var Buffered: int { return buffer.count }

    /// Next returns the next whole frame, or nil if more bytes are needed.
    public mutating func Next() throws -> Frame? {
        if buffer.count < 1 {
            return nil
        }
        if buffer[0] == tpktVersion {
            if buffer.count < 4 {
                return nil
            }
            let length = (int(buffer[2]) << 8) | int(buffer[3])
            if length < 4 {
                throw X224Error.malformed("TPKT length \(length) too small")
            }
            if buffer.count < length {
                return nil
            }
            let frame = take(length)
            return .slowPath(frame)
        }
        // Fast-path: byte0 bits 0-1 = action (0), bit 7 = length has 2 bytes.
        // byte1 is a 1-byte length, or with bit 7 set, byte1&0x7f<<8 | byte2.
        if buffer.count < 2 {
            return nil
        }
        var length: int
        if (buffer[1] & 0x80) != 0 {
            if buffer.count < 3 {
                return nil
            }
            length = (int(buffer[1] & 0x7f) << 8) | int(buffer[2])
        } else {
            length = int(buffer[1])
        }
        if length < 2 {
            throw X224Error.malformed("fast-path length \(length) too small")
        }
        if buffer.count < length {
            return nil
        }
        let frame = take(length)
        return .fastPath(frame)
    }

    mutating func take(_ n: int) -> [uint8] {
        var out = [uint8](repeating: 0, count: n)
        var i = 0
        while i < n {
            out[i] = buffer[i]
            i += 1
        }
        var rest: [uint8] = []
        var j = n
        while j < buffer.count {
            rest.append(buffer[j])
            j += 1
        }
        buffer = rest
        return out
    }
}

// --- helpers ---

func wrapTPKT(_ payload: [uint8]) -> [uint8] {
    let total = payload.count + 4
    var w = binary.Writer()
    w.U8(tpktVersion)
    w.U8(0)
    w.U16BE(uint16(truncatingIfNeeded: total))
    w.Append(payload)
    return w.Bytes
}

func parseTPKT(_ r: inout binary.Reader) throws {
    do {
        let version = try r.U8()
        if version != tpktVersion {
            throw X224Error.malformed("expected TPKT version 3, got \(version)")
        }
        let _ = try r.U8()
        let _ = try r.U16BE()   // total length, already known from framing
    } catch let e as X224Error {
        throw e
    } catch {
        throw X224Error.malformed("truncated TPKT header")
    }
}
