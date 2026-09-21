// RDP share PDUs ([MS-RDPBCGR] 2.2.1.11 onward): the Client Info PDU, the
// licensing exchange, the capability exchange (Demand/Confirm Active), and
// the finalization PDUs (Synchronize, Control, Font List). These travel as
// MCS Send Data over the I/O channel.
package rdp

import "encoding/binary"

// Security header flags.
let secInfoPkt: uint16 = 0x0040
let secLicensePkt: uint16 = 0x0080

// Share control PDU types (low nibble of pduType; high byte is version 0x10).
let pduTypeDemandActive: uint16 = 1
let pduTypeConfirmActive: uint16 = 3
let pduTypeDeactivateAll: uint16 = 6
let pduTypeData: uint16 = 7
let protocolVersion: uint16 = 0x10

// Share data PDU2 types.
let pduType2Update: uint8 = 2
let pduType2Control: uint8 = 20
let pduType2Pointer: uint8 = 27
let pduType2Input: uint8 = 28
let pduType2Synchronize: uint8 = 31
let pduType2FontList: uint8 = 39
let pduType2SaveSessionInfo: uint8 = 38
let pduType2FontMap: uint8 = 40
let pduType2ErrorInfo: uint8 = 47

// INFO flags for the Client Info PDU.
let infoMouse: uint32 = 0x00000001
let infoDisableCtrlAltDel: uint32 = 0x00000002
let infoAutoLogon: uint32 = 0x00000008
let infoUnicode: uint32 = 0x00000010
let infoMaximizeShell: uint32 = 0x00000020
let infoLogonNotify: uint32 = 0x00000040
let infoEnableWindowsKey: uint32 = 0x00000100
let infoLogonErrors: uint32 = 0x01000000

/// buildClientInfo builds the Client Info PDU body (security header + info
/// packet). Under NLA the password is empty (already delegated by CredSSP).
func buildClientInfo(_ config: Config) -> [uint8] {
    var info = binary.Writer()
    info.U32LE(0)   // CodePage
    let flags = infoMouse | infoDisableCtrlAltDel | infoUnicode | infoMaximizeShell |
                infoEnableWindowsKey | infoLogonNotify | infoLogonErrors | infoAutoLogon
    info.U32LE(flags)

    let domainU = binary.EncodeUTF16LE(config.Domain)
    let userU = binary.EncodeUTF16LE(config.Username)
    let emptyU: [uint8] = []
    // cb* are lengths in bytes excluding the 2-byte null terminator.
    info.U16LE(uint16(truncatingIfNeeded: domainU.count))
    info.U16LE(uint16(truncatingIfNeeded: userU.count))
    info.U16LE(0)   // cbPassword
    info.U16LE(0)   // cbAlternateShell
    info.U16LE(0)   // cbWorkingDir
    info.Append(domainU); info.U16LE(0)
    info.Append(userU); info.U16LE(0)
    info.U16LE(0)   // password + null
    info.U16LE(0)   // alternate shell + null
    info.U16LE(0)   // working dir + null

    // TS_EXTENDED_INFO_PACKET (RDP5+).
    info.U16LE(0x0002)     // clientAddressFamily AF_INET
    info.U16LE(2); info.U16LE(0)              // cbClientAddress + null address
    info.U16LE(2); info.U16LE(0)              // cbClientDir + null dir
    // clientTimeZone (172 bytes): Bias(4) + StandardName(64) + ... zero-filled.
    var tz = 0
    while tz < 172 { info.U8(0); tz += 1 }
    info.U32LE(0)          // clientSessionId
    info.U32LE(0)          // performanceFlags

    var w = binary.Writer()
    w.U16LE(secInfoPkt)    // Basic Security Header flags
    w.U16LE(0)             // flagsHi
    w.Append(info.Bytes)
    return w.Bytes
}

/// parseLicensing reads a licensing PDU and returns true when the server
/// grants the client (STATUS_VALID_CLIENT) so the sequence can continue.
func parseLicensing(_ payload: [uint8]) throws -> bool {
    // The payload begins with a Basic Security Header (flags incl.
    // SEC_LICENSE_PKT). Then a licensing preamble.
    var r = binary.Reader(payload)
    let flags = try r.U16LE()
    let _ = try r.U16LE()   // flagsHi
    if (flags & secLicensePkt) == 0 {
        // Not a licensing PDU -- unexpected here.
        throw RdpError.protocolError("expected licensing PDU (flags \(flags))")
    }
    let msgType = try r.U8()
    // ERROR_ALERT (0xFF) with STATUS_VALID_CLIENT means we can proceed.
    if msgType == 0xFF { return true }
    // Any other license message: for a workstation target we still proceed;
    // a full RDS licensing exchange is a later milestone.
    return true
}

/// DemandActive holds what we need from the server's Demand Active PDU:
/// the share id and the desktop size from its Bitmap capability set.
public struct DemandActive {
    public var ShareId: uint32 = 0
    public var DesktopWidth: uint16 = 0
    public var DesktopHeight: uint16 = 0
    public var ServerFastPathInput: bool = false
    public init() {}
}

/// parseDemandActive reads a Demand Active PDU (with or without a 4-byte
/// security header in front of the share control header).
func parseDemandActive(_ payload: [uint8]) throws -> DemandActive {
    var da = DemandActive()
    var r = binary.Reader(payload)
    let _ = try r.U16LE()          // totalLength
    var pduType = try r.U16LE()
    if (pduType & 0x0F) != pduTypeDemandActive {
        // Some servers prefix a security header (4 bytes). Retry at offset 4.
        r = binary.Reader(payload)
        try r.Skip(4)
        let _ = try r.U16LE()
        pduType = try r.U16LE()
        if (pduType & 0x0F) != pduTypeDemandActive {
            throw RdpError.protocolError("expected Demand Active, pduType \(pduType)")
        }
    }
    let _ = try r.U16LE()          // pduSource
    da.ShareId = try r.U32LE()
    let lenSource = int(try r.U16LE())
    let _ = try r.U16LE()          // lengthCombinedCapabilities
    try r.Skip(lenSource)
    let count = int(try r.U16LE())
    let _ = try r.U16LE()          // pad2Octets
    var i = 0
    while i < count && r.Remaining >= 4 {
        let type = try r.U16LE()
        let length = int(try r.U16LE())
        if length < 4 || length - 4 > r.Remaining { break }
        var body = try r.Sub(length - 4)
        if type == capBitmap && body.Remaining >= 12 {
            let _ = try body.U16LE()   // preferredBitsPerPixel
            let _ = try body.U16LE(); let _ = try body.U16LE(); let _ = try body.U16LE()
            da.DesktopWidth = try body.U16LE()
            da.DesktopHeight = try body.U16LE()
        } else if type == capInput && body.Remaining >= 2 {
            let flags = try body.U16LE()
            da.ServerFastPathInput = (flags & 0x0020) != 0   // INPUT_FLAG_FASTPATH_INPUT2
        }
        i += 1
    }
    return da
}

/// shareControlHeader wraps a body with a Share Control Header.
func shareControlHeader(_ pduType: uint16, source: uint16, body: [uint8]) -> [uint8] {
    var w = binary.Writer()
    w.U16LE(uint16(truncatingIfNeeded: body.count + 6))
    w.U16LE(protocolVersion | pduType)
    w.U16LE(source)
    w.Append(body)
    return w.Bytes
}

/// shareDataHeader wraps a body with Share Control + Share Data headers.
func shareDataHeader(_ pduType2: uint8, shareId: uint32, source: uint16, body: [uint8]) -> [uint8] {
    var d = binary.Writer()
    d.U32LE(shareId)
    d.U8(0)                        // pad1
    d.U8(1)                        // streamId (STREAM_LOW)
    d.U16LE(uint16(truncatingIfNeeded: body.count + 4))   // uncompressedLength (+ this header's tail)
    d.U8(pduType2)
    d.U8(0)                        // compressedType
    d.U16LE(0)                     // compressedLength
    d.Append(body)
    return shareControlHeader(pduTypeData, source: source, body: d.Bytes)
}

// --- Finalization PDUs ---

func buildSynchronize(shareId: uint32, source: uint16) -> [uint8] {
    var b = binary.Writer()
    b.U16LE(1)                     // messageType SYNCMSGTYPE_SYNC
    b.U16LE(1002)                  // targetUser
    return shareDataHeader(pduType2Synchronize, shareId: shareId, source: source, body: b.Bytes)
}

// Control actions.
let ctrlActionRequestControl: uint16 = 1
let ctrlActionGrantedControl: uint16 = 2
let ctrlActionCooperate: uint16 = 4

func buildControl(action: uint16, shareId: uint32, source: uint16) -> [uint8] {
    var b = binary.Writer()
    b.U16LE(action)
    b.U16LE(0)                     // grantId
    b.U32LE(0)                     // controlId
    return shareDataHeader(pduType2Control, shareId: shareId, source: source, body: b.Bytes)
}

func buildFontList(shareId: uint32, source: uint16) -> [uint8] {
    var b = binary.Writer()
    b.U16LE(0)                     // numberFonts
    b.U16LE(0)                     // totalNumFonts
    b.U16LE(0x0003)               // listFlags FIRST|LAST
    b.U16LE(50)                    // entrySize
    return shareDataHeader(pduType2FontList, shareId: shareId, source: source, body: b.Bytes)
}
