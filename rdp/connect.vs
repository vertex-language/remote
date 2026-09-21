package rdp

import "net/tcp"
import "crypto/tls"
import "crypto/credssp"
import "remote/rdp/x224"

/// Config configures an RDP connection.
public struct Config {
    public var Username: string
    public var Password: [uint8]
    public var Domain: string
    public var Width: uint16
    public var Height: uint16
    public var KeyboardLayout: uint32
    public var ClientName: string

    public init(username: string, password: [uint8], domain: string = "",
                width: uint16 = 1024, height: uint16 = 768,
                keyboardLayout: uint32 = 0x0409, clientName: string = "vertex") {
        self.Username = username
        self.Password = password
        self.Domain = domain
        self.Width = width
        self.Height = height
        self.KeyboardLayout = keyboardLayout
        self.ClientName = clientName
    }
}

/// ConnectionInfo records what the connection sequence negotiated.
public struct ConnectionInfo {
    public var SelectedProtocol: uint32 = 0
    public var UserChannel: uint16 = 0
    public var IOChannel: uint16 = 0
    public var ShareId: uint32 = 0
    public var Width: uint16 = 0
    public var Height: uint16 = 0
    public init() {}
}

// connectTransport performs everything up to and including channel joins,
// returning a ready Transport and the negotiated ConnectionInfo.
func connectTransport(_ address: string, config: Config, trace: bool) async throws -> (Transport, ConnectionInfo) {
    let (dial, host) = splitAddress(address)
    var info = ConnectionInfo()
    info.Width = config.Width
    info.Height = config.Height

    // 1. TCP + X.224 negotiation.
    var stream = try await tcp.Connect(dial, timeoutMs: 8000)
    let req = x224.ConnectionRequest(
        cookie: config.Username,
        requestedProtocols: x224.SecurityProtocol.SSL | x224.SecurityProtocol.Hybrid | x224.SecurityProtocol.HybridEx)
    try await stream.Write(req.Encode())
    var negResp = [uint8](repeating: 0, count: 64)
    let nn = try await stream.Read(into: &negResp)
    var negBytes = [uint8](repeating: 0, count: nn)
    var bi = 0
    while bi < nn { negBytes[bi] = negResp[bi]; bi += 1 }
    let cc = try x224.ConnectionConfirm.Parse(negBytes)
    info.SelectedProtocol = cc.SelectedProtocol
    if trace { print("  x224: selected protocol \(cc.SelectedProtocol)") }

    // 2. TLS 1.2.
    var tlsConn = tls.Conn12(stream: stream, config: tls.Config(serverName: host, insecureSkipVerify: false))
    try await tlsConn.Handshake()
    if trace { print("  tls: up, server cert \(tlsConn.PeerCertificate.Subject)") }

    // 3. CredSSP / NLA.
    let creds = credssp.Credentials(domain: config.Domain, user: config.Username, password: config.Password,
                                    host: host, subjectPublicKey: tlsConn.PeerCertificate.RawSubjectPublicKey)
    try await credssp.Authenticate(conn: &tlsConn, creds: creds)
    if trace { print("  credssp: authenticated") }

    // 3a. HYBRID_EX: Early User Authorization Result PDU (4-byte LE).
    if cc.SelectedProtocol == x224.SecurityProtocol.HybridEx {
        var four = [uint8](repeating: 0, count: 4)
        let m = try await tlsConn.Read(into: &four)
        if m >= 4 {
            let result = uint32(four[0]) | (uint32(four[1]) << 8) | (uint32(four[2]) << 16) | (uint32(four[3]) << 24)
            if trace { print("  early user auth result: \(result)") }
            if result != 0 { throw RdpError.negotiationRejected("early user authorization denied (\(result))") }
        }
    }

    var t = Transport(conn: tlsConn)

    // 4. Basic settings exchange: MCS Connect Initial -> Connect Response.
    let clientData = ClientData(width: config.Width, height: config.Height, clientName: config.ClientName,
                                keyboardLayout: config.KeyboardLayout, selectedProtocol: cc.SelectedProtocol)
    try await t.SendX224(buildConnectInitial(clientData))
    let connResp = try await t.NextX224Payload()
    let channels = try parseConnectResponse(connResp)
    info.IOChannel = channels.IOChannelId
    if trace { print("  mcs: connect response, I/O channel \(channels.IOChannelId)") }

    // 5. Channel connection.
    try await t.SendX224(mcsErectDomainRequest())
    try await t.SendX224(mcsAttachUserRequest())
    let auConfirm = try await t.NextX224Payload()
    let userChannel = try parseAttachUserConfirm(auConfirm)
    info.UserChannel = userChannel
    if trace { print("  mcs: attach user, user channel \(userChannel)") }

    // Join the user channel and the I/O channel (and any virtual channels).
    var toJoin: [uint16] = [userChannel, channels.IOChannelId]
    for c in channels.ChannelIds { toJoin.append(c) }
    for ch in toJoin {
        try await t.SendX224(mcsChannelJoinRequest(userChannel: userChannel, channel: ch))
        let confirm = try await t.NextX224Payload()
        let joined = try parseChannelJoinConfirm(confirm)
        if trace { print("  mcs: joined channel \(joined)") }
    }

    return (t, info)
}

// finishConnection runs the secure settings exchange, licensing, capability
// exchange and finalization. After it returns, the server begins sending
// graphics.
func finishConnection(_ t: inout Transport, _ info: inout ConnectionInfo, _ config: Config, trace: bool) async throws {
    let user = info.UserChannel
    let io = info.IOChannel

    // 5. Secure settings: Client Info PDU.
    try await t.SendX224(mcsSendDataRequest(userChannel: user, channel: io, data: buildClientInfo(config)))
    if trace { print("  sent Client Info") }

    // 6. Licensing: read until we get the license result.
    let lic = try await t.NextX224Payload()
    let licSDI = try parseSendDataIndication(lic)
    let _ = try parseLicensing(licSDI.payload)
    if trace { print("  licensing: valid client") }

    // 7. Capabilities: read PDUs until Demand Active.
    var demand: [uint8] = []
    var attempts = 0
    while attempts < 8 {
        let p = try await t.NextX224Payload()
        let sdi = try parseSendDataIndication(p)
        // Skip server messages that aren't Demand Active (e.g. Monitor Layout).
        if looksLikeDemandActive(sdi.payload) { demand = sdi.payload; break }
        attempts += 1
    }
    if demand.count == 0 { throw RdpError.protocolError("no Demand Active received") }
    let da = try parseDemandActive(demand)
    info.ShareId = da.ShareId
    if da.DesktopWidth > 0 && da.DesktopHeight > 0 {
        info.Width = da.DesktopWidth
        info.Height = da.DesktopHeight
    }
    if trace { print("  Demand Active, shareId \(da.ShareId), desktop \(info.Width)x\(info.Height) at \(da.BitsPerPixel) bpp") }

    try await activate(&t, &info, config, trace: trace)
}

// activate answers a Demand Active: Confirm Active with our capabilities,
// then the client-to-server finalization batch. It runs at connection and
// again after every Deactivate All.
func activate(_ t: inout Transport, _ info: inout ConnectionInfo, _ config: Config, trace: bool) async throws {
    let user = info.UserChannel
    let io = info.IOChannel
    let shareId = info.ShareId

    // 8. Confirm Active with our capabilities.
    let confirm = buildConfirmActive(shareId: shareId, source: user, width: info.Width,
                                     height: info.Height, keyboardLayout: config.KeyboardLayout)
    try await t.SendX224(mcsSendDataRequest(userChannel: user, channel: io, data: confirm))
    if trace { print("  sent Confirm Active") }

    // 9. Finalization (client-to-server batch).
    try await t.SendX224(mcsSendDataRequest(userChannel: user, channel: io,
        data: buildSynchronize(shareId: shareId, source: user)))
    try await t.SendX224(mcsSendDataRequest(userChannel: user, channel: io,
        data: buildControl(action: ctrlActionCooperate, shareId: shareId, source: user)))
    try await t.SendX224(mcsSendDataRequest(userChannel: user, channel: io,
        data: buildControl(action: ctrlActionRequestControl, shareId: shareId, source: user)))
    try await t.SendX224(mcsSendDataRequest(userChannel: user, channel: io,
        data: buildFontList(shareId: shareId, source: user)))
    if trace { print("  sent finalization (sync, control, font list)") }
}

// looksLikeDemandActive checks whether a share PDU is a Demand Active,
// trying both a 0- and 4-byte security-header offset.
func looksLikeDemandActive(_ payload: [uint8]) -> bool {
    if payload.count >= 4 {
        let pt = uint16(payload[2]) | (uint16(payload[3]) << 8)
        if (pt & 0x0F) == pduTypeDemandActive { return true }
    }
    if payload.count >= 8 {
        let pt = uint16(payload[6]) | (uint16(payload[7]) << 8)
        if (pt & 0x0F) == pduTypeDemandActive { return true }
    }
    return false
}

/// Connect dials a Windows host, authenticates with NLA, and runs the
/// connection sequence; the returned Session then streams the desktop.
/// address is "host" or "host:port" (3389 when no port is given).
public func Connect(_ address: string, config: Config) async throws -> Session {
    var (t, info) = try await connectTransport(address, config: config, trace: false)
    try await finishConnection(&t, &info, config, trace: false)
    return Session(transport: t, info: info, config: config)
}

/// ConnectTraced is Connect with the connection sequence printed.
public func ConnectTraced(_ address: string, config: Config) async throws -> Session {
    var (t, info) = try await connectTransport(address, config: config, trace: true)
    try await finishConnection(&t, &info, config, trace: true)
    var s = Session(transport: t, info: info, config: config)
    s.Trace = true
    return s
}

/// ConnectForTest exposes the pre-graphics connection sequence for tests.
public func ConnectForTest(_ address: string, config: Config, trace: bool) async throws -> (Transport, ConnectionInfo) {
    var (t, info) = try await connectTransport(address, config: config, trace: trace)
    try await finishConnection(&t, &info, config, trace: trace)
    return (t, info)
}

// splitAddress turns "host", "host:port" or "[v6]:port" into the address
// to dial (with 3389 filled in) and the bare host name TLS and NTLM use.
func splitAddress(_ address: string) -> (string, string) {
    let b = [uint8](address.utf8)
    var start = 0
    var end = b.count
    var hasPort = false
    if b.count > 0 && b[0] == 91 {                      // '['
        var i = 1
        while i < b.count && b[i] != 93 { i += 1 }     // ']'
        start = 1
        end = i
        hasPort = i + 1 < b.count && b[i + 1] == 58
    } else {
        var colons = 0
        var last = -1
        var i = 0
        while i < b.count {
            if b[i] == 58 { colons += 1; last = i }
            i += 1
        }
        if colons == 1 {
            end = last
            hasPort = true
        }
    }
    let host = bytesToString(b, start, end)
    if hasPort { return (address, host) }
    if start == 1 { return (address + ":3389", host) }
    if end == b.count && b.contains(58) { return ("[" + address + "]:3389", host) }
    return (address + ":3389", host)
}

@_silgen_name("vertex_string_from_utf8")
func stringFromUtf8(_ ptr: UnsafeRawPointer, _ count: int64) -> string

func bytesToString(_ bytes: [uint8], _ start: int, _ end: int) -> string {
    if start >= end { return "" }
    return bytes.withUnsafeBytes { bp in
        stringFromUtf8(bp.baseAddress! + start, int64(end - start))
    }
}
