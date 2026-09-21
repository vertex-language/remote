package rdp

/// RdpError is any failure in the RDP connection or session.
public enum RdpError: Error {
    case protocolError(string)
    case connectionClosed
    case negotiationRejected(string)

    public var Message: string {
        switch self {
        case .protocolError(let s): return "rdp: \(s)"
        case .connectionClosed: return "rdp: connection closed"
        case .negotiationRejected(let s): return "rdp: \(s)"
        }
    }
}
