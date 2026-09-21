// The active session ([MS-RDPBCGR] 1.3.1.2 onward): after the connection
// sequence, the server streams fast-path updates that this file turns into
// framebuffer damage and pointer events, while slow-path Data PDUs carry
// control traffic (Set Error Info, Deactivate All, Save Session Info).
package rdp

import "encoding/binary"
import "remote/rdp/x224"
import "remote/rdp/gfx"
import "remote/rdp/fastpath"
import "remote/rdp/codec/interleaved"
import "remote/rdp/codec/planar"

/// Event is what a Session reports to its consumer.
public enum Event {
    /// Pixels changed inside damage; read them with the Framebuffer.
    case frame(gfx.Rect)
    /// The pointer's shape changed (a new shape, or one from the cache).
    case pointer(PointerShape)
    case pointerHidden
    case pointerDefault
    case pointerPosition(int, int)
    /// The user is logged on (Save Session Info PDU).
    case logonComplete
    /// The server sent Deactivate All; it will follow with a new Demand
    /// Active (for example after a resize). The session handles the
    /// reactivation itself and reports the new desktop size here.
    case resized(int, int)
    /// The connection ended; the string is the reason.
    case disconnected(string)
}

/// PointerShape is a decoded pointer: premultiplied RGBA, top row first.
public struct PointerShape {
    public var Width: int
    public var Height: int
    public var HotX: int
    public var HotY: int
    public var Pixels: [uint8]
    public init(width: int, height: int, hotX: int, hotY: int, pixels: [uint8]) {
        Width = width; Height = height; HotX = hotX; HotY = hotY; Pixels = pixels
    }
}

/// Session is a connected RDP session. Call NextEvent in a loop on one
/// task; the Framebuffer holds the desktop as of the last .frame event,
/// and Input sends keys and pointer events from any task.
public final class Session {
    var transport: Transport
    public var Info: ConnectionInfo
    public var Framebuffer: gfx.Framebuffer
    var reassembler: fastpath.Reassembler
    var palette: [uint8]
    // Pointer shapes by the server's cache index (Pointer capability:
    // 25 entries at most); a Width of 0 is an empty slot.
    var pointerCache: [PointerShape] = []
    var pending: [Event] = []
    var closed: bool = false
    var config: Config
    /// Trace prints each PDU as it is handled.
    public var Trace: bool = false

    init(transport: Transport, info: ConnectionInfo, config: Config) {
        self.transport = transport
        self.Info = info
        self.config = config
        self.Framebuffer = gfx.Framebuffer(width: int(info.Width), height: int(info.Height))
        self.reassembler = fastpath.Reassembler()
        self.palette = [uint8](repeating: 0, count: 256 * 3)
    }

    /// Input sends keyboard and mouse events to the server.
    public var Input: Input { return inputFor(transport.Out) }

    /// NextEvent waits for the next event; nil once the session has ended.
    public func NextEvent() async throws -> Event? {
        while true {
            if pending.count > 0 {
                let e = pending[0]
                pending.remove(at: 0)
                return e
            }
            if closed { return nil }
            var frame: x224.Frame
            do {
                frame = try await transport.NextFrame()
            } catch {
                closed = true
                return .disconnected("connection closed: \(error)")
            }
            switch frame {
            case .fastPath(let bytes):
                try handleFastPath(bytes)
            case .slowPath(let bytes):
                try await handleSlowPath(bytes)
            }
        }
    }

    /// Close ends the session and shuts the connection.
    public func Close() {
        closed = true
        transport.Out.Close()
    }

    // --- fast-path ---

    func handleFastPath(_ bytes: [uint8]) throws {
        let updates = try reassembler.Feed(bytes)
        var damage = gfx.Rect(x: 0, y: 0, width: 0, height: 0)
        for u in updates {
            switch u.Code {
            case fastpath.UpdateCode.Bitmap:
                let rects = try fastpath.ParseBitmapUpdate(u.Data)
                for b in rects {
                    let r = applyBitmap(b)
                    damage = damage.Union(r)
                }
            case fastpath.UpdateCode.Palette:
                palette = try fastpath.ParsePaletteUpdate(u.Data)
            case fastpath.UpdateCode.PointerNull:
                pending.append(.pointerHidden)
            case fastpath.UpdateCode.PointerDefault:
                pending.append(.pointerDefault)
            case fastpath.UpdateCode.PointerPosition:
                let (x, y) = try fastpath.ParsePointerPosition(u.Data)
                pending.append(.pointerPosition(x, y))
            case fastpath.UpdateCode.PointerCached:
                let index = try fastpath.ParseCachedPointer(u.Data)
                if index >= 0 && index < pointerCache.count && pointerCache[index].Width > 0 {
                    pending.append(.pointer(pointerCache[index]))
                }
            case fastpath.UpdateCode.PointerColor:
                let img = try fastpath.ParseColorPointer(u.Data)
                pushPointer(img)
            case fastpath.UpdateCode.PointerNew:
                let img = try fastpath.ParseNewPointer(u.Data)
                pushPointer(img)
            case fastpath.UpdateCode.PointerLarge:
                let img = try fastpath.ParseLargePointer(u.Data)
                pushPointer(img)
            default:
                if Trace { print("  fast-path update code \(u.Code) (\(u.Data.count) bytes) ignored") }
            }
        }
        if !damage.IsEmpty {
            pending.append(.frame(damage))
        }
    }

    func pushPointer(_ img: fastpath.PointerImage) {
        let cursor = decodePointer(img)
        if img.CacheIndex >= 0 && img.CacheIndex < 64 {
            while pointerCache.count <= img.CacheIndex {
                pointerCache.append(PointerShape(width: 0, height: 0, hotX: 0, hotY: 0, pixels: []))
            }
            pointerCache[img.CacheIndex] = cursor
        }
        let e: Event = .pointer(cursor)
        pending.append(e)
    }

    // applyBitmap decodes one bitmap rectangle into the framebuffer and
    // returns the damaged area.
    func applyBitmap(_ b: fastpath.BitmapData) -> gfx.Rect {
        let dst = gfx.Rect(x: b.Left, y: b.Top, width: b.Right - b.Left + 1, height: b.Bottom - b.Top + 1)
        if b.Compressed {
            if b.BitsPerPixel == 32 {
                do {
                    let rgb = try planar.Decode(b.Data, width: b.Width, height: b.Height)
                    return Framebuffer.BlitRGB24(rgb, srcWidth: b.Width, into: dst, bottomUp: true)
                } catch {
                    if Trace { print("  planar decode failed: \(error)") }
                    return gfx.Rect(x: 0, y: 0, width: 0, height: 0)
                }
            }
            do {
                let raw = try interleaved.Decode(b.Data, width: b.Width, height: b.Height, bpp: b.BitsPerPixel)
                return blitRaw(raw, b, dst)
            } catch {
                if Trace { print("  interleaved decode failed: \(error)") }
                return gfx.Rect(x: 0, y: 0, width: 0, height: 0)
            }
        }
        // Uncompressed: rows padded to 4 bytes.
        let bytesPerPixel = (b.BitsPerPixel + 7) / 8
        let rowBytes = b.Width * bytesPerPixel
        let padded = (rowBytes + 3) & ~3
        if padded == rowBytes {
            return blitRaw(b.Data, b, dst)
        }
        var packed = [uint8](repeating: 0, count: rowBytes * b.Height)
        var row = 0
        while row < b.Height && (row + 1) * padded <= b.Data.count {
            var i = 0
            while i < rowBytes { packed[row * rowBytes + i] = b.Data[row * padded + i]; i += 1 }
            row += 1
        }
        return blitRaw(packed, b, dst)
    }

    func blitRaw(_ raw: [uint8], _ b: fastpath.BitmapData, _ dst: gfx.Rect) -> gfx.Rect {
        switch b.BitsPerPixel {
        case 8: return Framebuffer.BlitPalette8(raw, srcWidth: b.Width, palette: palette, into: dst, bottomUp: true)
        case 15: return Framebuffer.Blit15(raw, srcWidth: b.Width, into: dst, bottomUp: true)
        case 16: return Framebuffer.Blit16(raw, srcWidth: b.Width, into: dst, bottomUp: true)
        case 24: return Framebuffer.BlitBGR24(raw, srcWidth: b.Width, into: dst, bottomUp: true)
        case 32: return Framebuffer.BlitBGRX32(raw, srcWidth: b.Width, into: dst, bottomUp: true)
        default:
            if Trace { print("  bitmap at \(b.BitsPerPixel) bpp ignored") }
            return gfx.Rect(x: 0, y: 0, width: 0, height: 0)
        }
    }

    // --- slow-path ---

    func handleSlowPath(_ bytes: [uint8]) async throws {
        let payload = try x224.UnwrapData(bytes)
        // Anything that isn't an MCS Send Data Indication (e.g. a Disconnect
        // Provider Ultimatum) ends the session.
        if payload.count > 0 && (payload[0] >> 2) == 8 {   // DPum
            closed = true
            pending.append(.disconnected("server disconnected (MCS DPum)"))
            return
        }
        let sdi = try parseSendDataIndication(payload)
        var r = binary.Reader(sdi.payload)
        do {
            let _ = try r.U16LE()                 // totalLength
            let pduType = try r.U16LE() & 0x0F
            let _ = try r.U16LE()                 // pduSource
            switch pduType {
            case pduTypeData:
                let _ = try r.U32LE()             // shareId
                let _ = try r.U8()                // pad
                let _ = try r.U8()                // streamId
                let _ = try r.U16LE()             // uncompressedLength
                let pduType2 = try r.U8()
                let _ = try r.U8()                // compressedType
                let _ = try r.U16LE()             // compressedLength
                try handleDataPDU(pduType2, &r)
            case pduTypeDeactivateAll:
                if Trace { print("  Deactivate All") }
                try await reactivate()
            case pduTypeDemandActive:
                // A Demand Active outside reactivation: treat like a resize.
                try await reactivate(demandActive: sdi.payload)
            default:
                if Trace { print("  slow-path share PDU type \(pduType) ignored") }
            }
        } catch let e as RdpError {
            throw e
        } catch {
            throw RdpError.protocolError("truncated share PDU: \(error)")
        }
    }

    func handleDataPDU(_ pduType2: uint8, _ r: inout binary.Reader) throws {
        switch pduType2 {
        case pduType2ErrorInfo:
            let code = try r.U32LE()
            // ERRINFO_NONE: Windows sends it early in a session; ignore it.
            if code != 0 {
                closed = true
                pending.append(.disconnected(describeErrorInfo(code)))
            }
        case pduType2SaveSessionInfo:
            let infoType = try r.U32LE()
            if Trace { print("  Save Session Info type \(infoType)") }
            // INFOTYPE_LOGON (0), LOGON_LONG (1), LOGON_PLAINNOTIFY (2) all
            // mean the shell is up; LOGON_EXTENDED (3) may carry more.
            if infoType <= 2 { pending.append(.logonComplete) }
        case pduType2Synchronize, pduType2Control, pduType2FontMap:
            if Trace { print("  finalization reply pduType2=\(pduType2)") }
        case pduType2Update:
            // Slow-path graphics: the server only uses these when fast-path
            // output is off, which we never negotiate.
            if Trace { print("  slow-path update ignored") }
        case pduType2Pointer:
            if Trace { print("  slow-path pointer ignored") }
        default:
            if Trace { print("  data PDU type2 \(pduType2) ignored") }
        }
    }

    // reactivate runs the capability exchange and finalization again after a
    // Deactivate All, then resizes the framebuffer to the new desktop.
    func reactivate(demandActive: [uint8] = []) async throws {
        var da: [uint8] = demandActive
        if da.count == 0 {
            var attempts = 0
            while attempts < 8 {
                let p = try await transport.NextX224Payload()
                let sdi = try parseSendDataIndication(p)
                if looksLikeDemandActive(sdi.payload) { da = sdi.payload; break }
                attempts += 1
            }
            if da.count == 0 { throw RdpError.protocolError("no Demand Active after Deactivate All") }
        }
        let parsed = try parseDemandActive(da)
        Info.ShareId = parsed.ShareId
        if parsed.DesktopWidth > 0 && parsed.DesktopHeight > 0 {
            Info.Width = parsed.DesktopWidth
            Info.Height = parsed.DesktopHeight
        }
        try await activate(&transport, &Info, config, trace: Trace)
        if Framebuffer.Width != int(Info.Width) || Framebuffer.Height != int(Info.Height) {
            Framebuffer.Resize(width: int(Info.Width), height: int(Info.Height))
        }
        pending.append(.resized(int(Info.Width), int(Info.Height)))
    }

    // decodePointer converts a wire pointer (XOR colour mask + AND
    // transparency mask, bottom-up, rows padded to 2 bytes) into RGBA.
    func decodePointer(_ p: fastpath.PointerImage) -> PointerShape {
        let w = p.Width
        let h = p.Height
        var px = [uint8](repeating: 0, count: w * h * 4)
        if w <= 0 || h <= 0 { return PointerShape(width: 0, height: 0, hotX: 0, hotY: 0, pixels: px) }
        let xorRow = ((w * p.XorBpp + 7) / 8 + 1) & ~1
        let andRow = ((w + 7) / 8 + 1) & ~1
        var y = 0
        while y < h {
            let srcY = h - 1 - y
            var x = 0
            while x < w {
                var r: uint32 = 0
                var g: uint32 = 0
                var b: uint32 = 0
                var xa: uint32 = 255
                let xo = srcY * xorRow
                switch p.XorBpp {
                case 32:
                    let o = xo + x * 4
                    if o + 3 < p.XorMask.count {
                        b = uint32(p.XorMask[o]); g = uint32(p.XorMask[o + 1]); r = uint32(p.XorMask[o + 2]); xa = uint32(p.XorMask[o + 3])
                    }
                case 24:
                    let o = xo + x * 3
                    if o + 2 < p.XorMask.count {
                        b = uint32(p.XorMask[o]); g = uint32(p.XorMask[o + 1]); r = uint32(p.XorMask[o + 2])
                    }
                case 16:
                    let o = xo + x * 2
                    if o + 1 < p.XorMask.count {
                        let v = uint32(p.XorMask[o]) | (uint32(p.XorMask[o + 1]) << 8)
                        let r5 = (v >> 11) & 0x1f; let g6 = (v >> 5) & 0x3f; let b5 = v & 0x1f
                        r = (r5 << 3) | (r5 >> 2); g = (g6 << 2) | (g6 >> 4); b = (b5 << 3) | (b5 >> 2)
                    }
                default:   // 1 bpp: monochrome XOR
                    let o = xo + x / 8
                    if o < p.XorMask.count {
                        let bit = (p.XorMask[o] >> uint8(truncatingIfNeeded: 7 - (x % 8))) & 1
                        let v: uint32 = bit != 0 ? 255 : 0
                        r = v; g = v; b = v
                    }
                }
                var andBit: uint8 = 0
                let ao = srcY * andRow + x / 8
                if ao < p.AndMask.count {
                    andBit = (p.AndMask[ao] >> uint8(truncatingIfNeeded: 7 - (x % 8))) & 1
                }
                // AND=1, XOR=0 -> transparent; AND=1, XOR!=0 -> invert
                // (we approximate as opaque XOR colour); AND=0 -> opaque.
                var a: uint32 = 255
                if p.XorBpp == 32 {
                    a = xa
                    if andBit != 0 && a == 0 { a = 0 }
                } else if andBit != 0 {
                    if r == 0 && g == 0 && b == 0 { a = 0 }
                }
                let d = (y * w + x) * 4
                px[d] = uint8(truncatingIfNeeded: r * a / 255)
                px[d + 1] = uint8(truncatingIfNeeded: g * a / 255)
                px[d + 2] = uint8(truncatingIfNeeded: b * a / 255)
                px[d + 3] = uint8(truncatingIfNeeded: a)
                x += 1
            }
            y += 1
        }
        return PointerShape(width: w, height: h, hotX: p.HotX, hotY: p.HotY, pixels: px)
    }
}

/// describeErrorInfo names a Set Error Info code ([MS-RDPBCGR] 2.2.5.1.1).
public func describeErrorInfo(_ code: uint32) -> string {
    switch code {
    case 0x0001: return "disconnected by server (RPC initiated)"
    case 0x0002: return "disconnected by another user (RPC initiated)"
    case 0x0003: return "the session was logged off (idle timeout)"
    case 0x0004: return "the session was logged off (logon timeout)"
    case 0x0005: return "another user connected to the session"
    case 0x0006: return "the server ran out of memory"
    case 0x0007: return "the server denied the connection"
    case 0x0009: return "the user cannot connect because of insufficient access privileges"
    case 0x000A: return "the server does not accept saved credentials"
    case 0x000B: return "disconnected by server (RPC initiated, user logged off)"
    case 0x000C: return "logoff by user"
    case 0x10EA: return "the server rejected our capabilities (BAD_CAPABILITIES)"
    default: return "server error 0x\(hex32(code))"
    }
}

func hex32(_ v: uint32) -> string {
    let digits: [string] = ["0","1","2","3","4","5","6","7","8","9","A","B","C","D","E","F"]
    var s = ""
    var shift: uint32 = 28
    var started = false
    while true {
        let d = int((v >> shift) & 0xF)
        if d != 0 || started || shift == 0 { s += digits[d]; started = true }
        if shift == 0 { break }
        shift -= 4
    }
    return s
}
