// MCS (T.125) and GCC (T.124) for the RDP connection sequence: the client
// GCC data blocks, the MCS Connect Initial that carries them, and the
// domain PDUs (Erect Domain, Attach User, Channel Join, Send Data) that
// follow. Pure encode/decode over encoding/binary; the driver in this
// package moves the bytes over the authenticated channel.
package rdp

import (
    "encoding/binary"
    "remote/rdp/wire"
)

let gccObjectID: [uint8] = [0, 0, 20, 124, 0, 1]
let h221ClientToServer: [uint8] = [0x44, 0x75, 0x63, 0x61]   // "Duca"

// Client GCC data block types.
let csCore: uint16 = 0xC001
let csSecurity: uint16 = 0xC002
let csNet: uint16 = 0xC003
let csCluster: uint16 = 0xC004

// Server GCC data block types.
let scCore: uint16 = 0x0C01
let scSecurity: uint16 = 0x0C02
let scNet: uint16 = 0x0C03

/// ClientData holds the parameters carried in the GCC client blocks.
public struct ClientData {
    public var DesktopWidth: uint16
    public var DesktopHeight: uint16
    public var ClientName: string
    public var KeyboardLayout: uint32
    public var SelectedProtocol: uint32
    public var Channels: [string]
    /// Percent the server scales its UI by (100...500), and the device
    /// scale (100, 140 or 180).
    public var DesktopScale: uint32 = 100
    public var DeviceScale: uint32 = 100

    public init(width: uint16, height: uint16, clientName: string,
                keyboardLayout: uint32, selectedProtocol: uint32, channels: [string] = []) {
        self.DesktopWidth = width
        self.DesktopHeight = height
        self.ClientName = clientName
        self.KeyboardLayout = keyboardLayout
        self.SelectedProtocol = selectedProtocol
        self.Channels = channels
    }
}

// buildClientCoreData (CS_CORE, [MS-RDPBCGR] 2.2.1.3.2).
func buildClientCoreData(_ d: ClientData) -> [uint8] {
    var w = binary.Writer()
    w.U32LE(0x00080004)                 // version RDP 5.0+
    w.U16LE(d.DesktopWidth)
    w.U16LE(d.DesktopHeight)
    w.U16LE(0xCA01)                     // colorDepth 8bpp (superseded by highColorDepth)
    w.U16LE(0xAA03)                     // SASSequence
    w.U32LE(d.KeyboardLayout)
    w.U32LE(2600)                       // clientBuild
    // clientName: 32 bytes UTF-16LE, NUL-padded (15 chars + NUL max).
    var name = binary.EncodeUTF16LE(d.ClientName)
    while name.count < 32 { name.append(0) }
    var i = 0
    while i < 32 { w.U8(name[i]); i += 1 }
    w.U32LE(4)                          // keyboardType
    w.U32LE(0)                          // keyboardSubType
    w.U32LE(12)                         // keyboardFunctionKey
    var j = 0
    while j < 64 { w.U8(0); j += 1 }    // imeFileName
    w.U16LE(0xCA01)                     // postBeta2ColorDepth
    w.U16LE(1)                          // clientProductId
    w.U32LE(0)                          // serialNumber
    w.U16LE(24)                         // highColorDepth (24bpp)
    w.U16LE(0x000F)                     // supportedColorDepths (24/16/15/32)
    // earlyCapabilityFlags: SUPPORT_ERRINFO_PDU, WANT_32BPP_SESSION,
    // VALID_CONNECTION_TYPE (connectionType below is LAN).
    w.U16LE(0x0001 | 0x0002 | 0x0020)
    var k = 0
    while k < 64 { w.U8(0); k += 1 }    // clientDigProductId
    w.U8(6)                             // connectionType: CONNECTION_TYPE_LAN
    w.U8(0)                             // pad1octet
    w.U32LE(d.SelectedProtocol)         // serverSelectedProtocol (echo the nego result)
    // The display's physical size (mm; 0 = unknown), orientation, and the
    // scale factors ([MS-RDPBCGR] 2.2.1.3.2): Windows 8.1 and later scale
    // their UI by desktopScaleFactor, so a HiDPI client gets sharp text.
    w.U32LE(0)                          // desktopPhysicalWidth
    w.U32LE(0)                          // desktopPhysicalHeight
    w.U16LE(0)                          // desktopOrientation: landscape
    w.U32LE(d.DesktopScale)
    w.U32LE(d.DeviceScale)
    return block(csCore, w.Bytes)
}

func buildClientSecurityData() -> [uint8] {
    var w = binary.Writer()
    w.U32LE(0)   // encryptionMethods = 0 (TLS/NLA carries security)
    w.U32LE(0)   // extEncryptionMethods
    return block(csSecurity, w.Bytes)
}

func buildClientNetworkData(_ channels: [string]) -> [uint8] {
    var w = binary.Writer()
    w.U32LE(uint32(truncatingIfNeeded: channels.count))
    for name in channels {
        var nb = [uint8](name.utf8)
        while nb.count < 8 { nb.append(0) }
        var i = 0
        while i < 8 { w.U8(nb[i]); i += 1 }
        w.U32LE(0)   // options (set per channel later if needed)
    }
    return block(csNet, w.Bytes)
}

func buildClientClusterData() -> [uint8] {
    var w = binary.Writer()
    // flags: REDIRECTION_SUPPORTED (0x01) | redirectionVersion 4 (<<2 = 0x0C)
    w.U32LE(0x0D)
    w.U32LE(0)   // RedirectedSessionID
    return block(csCluster, w.Bytes)
}

func block(_ type: uint16, _ data: [uint8]) -> [uint8] {
    var w = binary.Writer()
    w.U16LE(type)
    w.U16LE(uint16(truncatingIfNeeded: data.count + 4))
    w.Append(data)
    return w.Bytes
}

// buildGCCBlocks concatenates the client data blocks.
func buildGCCBlocks(_ d: ClientData) -> [uint8] {
    var out: [uint8] = []
    out.append(contentsOf: buildClientCoreData(d))
    out.append(contentsOf: buildClientSecurityData())
    out.append(contentsOf: buildClientNetworkData(d.Channels))
    out.append(contentsOf: buildClientClusterData())
    return out
}

// buildConferenceCreateRequest wraps the GCC blocks (T.124).
func buildConferenceCreateRequest(_ gccBlocks: [uint8]) -> [uint8] {
    var w = binary.Writer()
    wire.PERWriteChoice(&w, 0)                       // ConnectData::Key = object id
    wire.PERWriteObjectID(&w, gccObjectID)
    wire.PERWriteLength(&w, gccBlocks.count + 14)    // connectPDU length (CCR overhead 14)
    wire.PERWriteChoice(&w, 0)                       // ConferenceCreateRequest
    wire.PERWriteSelection(&w, 0x08)                 // userData present
    let confName: [uint8] = [0x31]                   // "1"
    wire.PERWriteNumericString(&w, confName, 1)
    w.U8(0)                                           // padding
    wire.PERWriteNumberOfSets(&w, 1)
    wire.PERWriteChoice(&w, 0xC0)                     // h221NonStandard
    wire.PERWriteOctetString(&w, h221ClientToServer, 4)
    wire.PERWriteLength(&w, gccBlocks.count)
    w.Append(gccBlocks)
    return w.Bytes
}

/// buildConnectInitial builds the MCS Connect Initial PDU (T.125) carrying
/// the GCC conference create request.
func buildConnectInitial(_ d: ClientData) -> [uint8] {
    let gcc = buildGCCBlocks(d)
    let ccr = buildConferenceCreateRequest(gcc)

    // Body: callingDomain, calledDomain, upwardFlag, 3 x DomainParameters,
    // userData (octet string tag + CCR).
    var body = binary.Writer()
    wire.BERWriteOctetString(&body, [0x01])   // callingDomainSelector
    wire.BERWriteOctetString(&body, [0x01])   // calledDomainSelector
    wire.BERWriteBool(&body, true)            // upwardFlag
    writeDomainParameters(&body, 34, 2, 0, 65535)      // target
    writeDomainParameters(&body, 1, 1, 1, 1056)        // min
    writeDomainParameters(&body, 65535, 64535, 65535, 65535)  // max
    wire.BERWriteOctetStringTag(&body, ccr.count)
    body.Append(ccr)

    var w = binary.Writer()
    wire.BERWriteApplicationTag(&w, 0x65, body.Bytes.count)   // Connect-Initial
    w.Append(body.Bytes)
    return w.Bytes
}

func writeDomainParameters(_ w: inout binary.Writer, _ maxChannels: uint32, _ maxUsers: uint32,
                           _ maxTokens: uint32, _ maxPduSize: uint32) {
    var p = binary.Writer()
    wire.BERWriteInteger(&p, maxChannels)
    wire.BERWriteInteger(&p, maxUsers)
    wire.BERWriteInteger(&p, maxTokens)
    wire.BERWriteInteger(&p, 1)          // numPriorities
    wire.BERWriteInteger(&p, 0)          // minThroughput
    wire.BERWriteInteger(&p, 1)          // maxHeight
    wire.BERWriteInteger(&p, maxPduSize)
    wire.BERWriteInteger(&p, 2)          // protocolVersion
    // SEQUENCE tag (universal 16, constructed).
    w.U8(0x30)
    wire.BERWriteLength(&w, p.Bytes.count)
    w.Append(p.Bytes)
}

/// ServerChannels holds the channel IDs parsed from the Connect Response.
public struct ServerChannels {
    public var IOChannelId: uint16 = 0
    public var ChannelIds: [uint16] = []
    public init() {}
}

/// parseConnectResponse parses the MCS Connect Response and returns the
/// server's I/O channel and any virtual channel IDs (SC_NET).
func parseConnectResponse(_ pdu: [uint8]) throws -> ServerChannels {
    var r = binary.Reader(pdu)
    let _ = try wire.BERReadApplicationTag(&r, 0x66)   // Connect-Response
    let _ = try wire.BERReadEnumerated(&r)             // result
    let _ = try wire.BERReadInteger(&r)                // calledConnectId
    // DomainParameters SEQUENCE
    let seqId = try r.U8()
    if seqId != 0x30 { throw RdpError.protocolError("expected DomainParameters SEQUENCE") }
    let dpLen = try wire.BERReadLength(&r)
    try r.Skip(dpLen)
    // userData OCTET STRING (GCC conference create response)
    let gcc = try wire.BERReadOctetString(&r)
    return try parseConferenceCreateResponse(gcc)
}

// parseConferenceCreateResponse extracts the server data blocks.
func parseConferenceCreateResponse(_ gcc: [uint8]) throws -> ServerChannels {
    var r = binary.Reader(gcc)
    // Skip the T.124 header up to the user data blocks.
    let _ = try wire.PERReadLength(&r)   // choice/key is 2 bytes; handle leniently below
    // The response header is fixed-ish; scan for the SC_NET block by walking
    // from a known offset is fragile, so re-scan the whole buffer for blocks.
    return scanServerBlocks(gcc)
}

// scanServerBlocks finds SC_NET in the GCC response by scanning for the
// server data block headers (type LE + length LE).
func scanServerBlocks(_ gcc: [uint8]) -> ServerChannels {
    var sc = ServerChannels()
    // The user data blocks begin after the GCC ConferenceCreateResponse
    // header. Find the first plausible SC_CORE (0x0C01) header and parse
    // sequentially from there.
    var start = 0
    var i = 0
    while i + 1 < gcc.count {
        let t = uint16(gcc[i]) | (uint16(gcc[i+1]) << 8)
        if t == scCore {
            start = i
            break
        }
        i += 1
    }
    var off = start
    while off + 4 <= gcc.count {
        let t = uint16(gcc[off]) | (uint16(gcc[off+1]) << 8)
        let len = int(gcc[off+2]) | (int(gcc[off+3]) << 8)
        if len < 4 || off + len > gcc.count { break }
        if t == scNet {
            // SC_NET: MCSChannelId (2), channelCount (2), then IDs (2 each).
            let base = off + 4
            if base + 4 <= gcc.count {
                sc.IOChannelId = uint16(gcc[base]) | (uint16(gcc[base+1]) << 8)
                let count = int(gcc[base+2]) | (int(gcc[base+3]) << 8)
                var c = 0
                var p = base + 4
                while c < count && p + 1 < gcc.count {
                    sc.ChannelIds.append(uint16(gcc[p]) | (uint16(gcc[p+1]) << 8))
                    p += 2
                    c += 1
                }
            }
        }
        off += len
    }
    return sc
}

// --- MCS domain PDUs (PER-encoded, sent in X.224 data) ---

/// mcsErectDomainRequest ([MS-RDPBCGR] 2.2.1.5): subHeight=0, subInterval=0.
func mcsErectDomainRequest() -> [uint8] {
    var w = binary.Writer()
    w.U8(0x04)          // MCS ErectDomainRequest (choice 1 << 2)
    // subHeight and subInterval as PER integers (length-prefixed).
    w.U8(0x01); w.U8(0x00)   // subHeight = 0
    w.U8(0x01); w.U8(0x00)   // subInterval = 0
    return w.Bytes
}

/// mcsAttachUserRequest ([MS-RDPBCGR] 2.2.1.6).
func mcsAttachUserRequest() -> [uint8] {
    return [0x28]       // AttachUserRequest (choice 10 << 2)
}

/// parseAttachUserConfirm returns the granted user channel id.
func parseAttachUserConfirm(_ data: [uint8]) throws -> uint16 {
    var r = binary.Reader(data)
    let tag = try r.U8()
    if (tag >> 2) != 11 { throw RdpError.protocolError("expected AttachUserConfirm") }
    let result = try wire.PERReadEnum(&r)
    if result != 0 { throw RdpError.protocolError("attach user rejected (\(result))") }
    return try wire.PERReadU16(&r, min: 1001)   // granted user channel
}

/// mcsChannelJoinRequest ([MS-RDPBCGR] 2.2.1.8): initiator + channelId.
func mcsChannelJoinRequest(userChannel: uint16, channel: uint16) -> [uint8] {
    var w = binary.Writer()
    w.U8(0x38)   // ChannelJoinRequest (choice 14 << 2)
    w.U16BE(userChannel &- 1001)
    w.U16BE(channel)
    return w.Bytes
}

/// parseChannelJoinConfirm returns the joined channel id (or throws).
func parseChannelJoinConfirm(_ data: [uint8]) throws -> uint16 {
    var r = binary.Reader(data)
    let tag = try r.U8()
    if (tag >> 2) != 15 { throw RdpError.protocolError("expected ChannelJoinConfirm") }
    let result = try wire.PERReadEnum(&r)
    if result != 0 { throw RdpError.protocolError("channel join rejected (\(result))") }
    let _ = try wire.PERReadU16(&r, min: 1001)   // initiator
    let _ = try wire.PERReadU16(&r, min: 0)      // requested
    let channel = try wire.PERReadU16(&r, min: 0)  // joined channelId
    return channel
}

/// mcsSendDataRequest wraps user data for a channel ([MS-RDPBCGR] 2.2.1.x).
func mcsSendDataRequest(userChannel: uint16, channel: uint16, data: [uint8]) -> [uint8] {
    var w = binary.Writer()
    w.U8(0x64)   // SendDataRequest (choice 25 << 2)
    w.U16BE(userChannel &- 1001)   // initiator
    w.U16BE(channel)               // channelId
    w.U8(0x70)                     // dataPriority + segmentation (high, complete)
    // per length (may be 2 bytes with high bit)
    wire.PERWriteLength(&w, data.count)
    w.Append(data)
    return w.Bytes
}

/// parseSendDataIndication returns the channel id and the user payload.
func parseSendDataIndication(_ data: [uint8]) throws -> (channel: uint16, payload: [uint8]) {
    var r = binary.Reader(data)
    let tag = try r.U8()
    if (tag >> 2) != 26 { throw RdpError.protocolError("expected SendDataIndication, tag \(tag)") }
    let _ = try r.U16BE()             // initiator
    let channel = try r.U16BE()       // channelId
    let _ = try r.U8()                // dataPriority/segmentation
    let len = try wire.PERReadLength(&r)
    let payload = try r.Bytes(len)
    return (channel: channel, payload: payload)
}
