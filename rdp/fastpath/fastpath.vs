// Package fastpath parses server fast-path update PDUs ([MS-RDPBCGR]
// 2.2.9.1.2): the outer PDU into its updates, fragmented updates back into
// whole ones, and the bitmap and pointer update bodies into values the
// session can act on. No I/O and no pixels: codecs live in codec/*.
package fastpath

import "encoding/binary"

/// FastPathError is a malformed fast-path PDU.
public enum FastPathError: Error {
    case malformed(string)
    public var Message: string {
        switch self {
        case .malformed(let s): return "fastpath: \(s)"
        }
    }
}

/// Update codes (updateCode in the TS_FP_UPDATE header).
public struct UpdateCode {
    public static let Orders: uint8 = 0
    public static let Bitmap: uint8 = 1
    public static let Palette: uint8 = 2
    public static let Synchronize: uint8 = 3
    public static let SurfaceCommands: uint8 = 4
    public static let PointerNull: uint8 = 5
    public static let PointerDefault: uint8 = 6
    public static let PointerPosition: uint8 = 8
    public static let PointerColor: uint8 = 9
    public static let PointerCached: uint8 = 10
    public static let PointerNew: uint8 = 11
    public static let PointerLarge: uint8 = 12
}

// Fragmentation values (bits 4-5 of the update header).
let fragmentSingle: uint8 = 0
let fragmentLast: uint8 = 1
let fragmentFirst: uint8 = 2
let fragmentNext: uint8 = 3

/// Update is one whole (reassembled) fast-path update.
public struct Update {
    public var Code: uint8
    public var Data: [uint8]
    public init(code: uint8, data: [uint8]) {
        self.Code = code
        self.Data = data
    }
}

/// Reassembler splits fast-path PDUs into updates and joins fragmented
/// updates. Feed it whole frames from the transport; it returns the
/// updates that completed.
public struct Reassembler {
    var partial: [uint8] = []
    var partialCode: uint8 = 0
    var inProgress: bool = false
    /// MaxSize bounds a reassembled update (the MultifragmentUpdate cap).
    public var MaxSize: int = 8 * 1024 * 1024

    public init() {}

    /// Feed parses one fast-path PDU (header included) and returns the
    /// updates it completed.
    public mutating func Feed(_ frame: [uint8]) throws -> [Update] {
        var r = binary.Reader(frame)
        var out: [Update] = []
        do {
            let header = try r.U8()
            let flags = (header >> 6) & 0x03
            let l1 = try r.U8()
            if (l1 & 0x80) != 0 { let _ = try r.U8() }
            if (flags & 0x02) != 0 {
                // FASTPATH_OUTPUT_ENCRYPTED: never set over TLS-only sessions.
                throw FastPathError.malformed("encrypted fast-path PDU not supported")
            }
            while r.Remaining > 0 {
                let uh = try r.U8()
                let code = uh & 0x0F
                let frag = (uh >> 4) & 0x03
                let compression = (uh >> 6) & 0x03
                var compressionFlags: uint8 = 0
                if (compression & 0x02) != 0 { compressionFlags = try r.U8() }
                let size = int(try r.U16LE())
                let data = try r.Bytes(size)
                if (compressionFlags & 0x20) != 0 {
                    // PACKET_COMPRESSED: bulk compression was never negotiated
                    // (no INFO_COMPRESSION), so this would be a server bug.
                    throw FastPathError.malformed("bulk-compressed update without negotiation")
                }
                switch frag {
                case fragmentSingle:
                    out.append(Update(code: code, data: data))
                case fragmentFirst:
                    partial = data
                    partialCode = code
                    inProgress = true
                case fragmentNext:
                    if !inProgress { throw FastPathError.malformed("NEXT fragment without FIRST") }
                    partial.append(contentsOf: data)
                    if partial.count > MaxSize { throw FastPathError.malformed("fragmented update too large") }
                default:   // fragmentLast
                    if !inProgress { throw FastPathError.malformed("LAST fragment without FIRST") }
                    partial.append(contentsOf: data)
                    out.append(Update(code: partialCode, data: partial))
                    partial = []
                    inProgress = false
                }
            }
        } catch let e as FastPathError {
            throw e
        } catch {
            throw FastPathError.malformed("truncated fast-path PDU")
        }
        return out
    }
}

// --- Bitmap updates ([MS-RDPBCGR] 2.2.9.1.1.3.1.2) ---

/// BitmapFlags values in TS_BITMAP_DATA.flags.
public struct BitmapFlags {
    public static let Compression: uint16 = 0x0001
    public static let NoCompressionHeader: uint16 = 0x0400
}

/// BitmapData is one TS_BITMAP_DATA rectangle. Data is the bitmap stream
/// with any TS_CD_HEADER already stripped.
public struct BitmapData {
    public var Left: int
    public var Top: int
    public var Right: int      // inclusive
    public var Bottom: int     // inclusive
    public var Width: int
    public var Height: int
    public var BitsPerPixel: int
    public var Flags: uint16
    public var Data: [uint8]

    public var Compressed: bool { return (Flags & BitmapFlags.Compression) != 0 }

    public init() {
        Left = 0; Top = 0; Right = 0; Bottom = 0; Width = 0; Height = 0; BitsPerPixel = 0; Flags = 0; Data = []
    }
}

/// ParseBitmapUpdate decodes a TS_UPDATE_BITMAP_DATA body.
public func ParseBitmapUpdate(_ data: [uint8]) throws -> [BitmapData] {
    var r = binary.Reader(data)
    var out: [BitmapData] = []
    do {
        let updateType = try r.U16LE()
        if updateType != 0x0001 { throw FastPathError.malformed("bitmap update type \(updateType)") }
        let count = int(try r.U16LE())
        var i = 0
        while i < count {
            var b = BitmapData()
            b.Left = int(try r.U16LE())
            b.Top = int(try r.U16LE())
            b.Right = int(try r.U16LE())
            b.Bottom = int(try r.U16LE())
            b.Width = int(try r.U16LE())
            b.Height = int(try r.U16LE())
            b.BitsPerPixel = int(try r.U16LE())
            b.Flags = try r.U16LE()
            var length = int(try r.U16LE())
            if b.Compressed && (b.Flags & BitmapFlags.NoCompressionHeader) == 0 {
                // TS_CD_HEADER: cbCompFirstRowSize, cbCompMainBodySize,
                // cbScanWidth, cbUncompressedSize. Only the body size matters.
                let _ = try r.U16LE()
                let body = int(try r.U16LE())
                let _ = try r.U16LE()
                let _ = try r.U16LE()
                length = body
            }
            b.Data = try r.Bytes(length)
            out.append(b)
            i += 1
        }
    } catch let e as FastPathError {
        throw e
    } catch {
        throw FastPathError.malformed("truncated bitmap update")
    }
    return out
}

// --- Palette update ([MS-RDPBCGR] 2.2.9.1.1.3.1.1) ---

/// ParsePaletteUpdate returns the palette as 256 RGB triples (red first).
public func ParsePaletteUpdate(_ data: [uint8]) throws -> [uint8] {
    var r = binary.Reader(data)
    var out = [uint8](repeating: 0, count: 256 * 3)
    do {
        let updateType = try r.U16LE()
        if updateType != 0x0002 { throw FastPathError.malformed("palette update type \(updateType)") }
        let _ = try r.U16LE()   // pad
        let n = int(try r.U32LE())
        if n > 256 { throw FastPathError.malformed("palette has \(n) entries") }
        var i = 0
        while i < n {
            out[i * 3] = try r.U8()
            out[i * 3 + 1] = try r.U8()
            out[i * 3 + 2] = try r.U8()
            i += 1
        }
    } catch let e as FastPathError {
        throw e
    } catch {
        throw FastPathError.malformed("truncated palette update")
    }
    return out
}

// --- Pointer updates ([MS-RDPBCGR] 2.2.9.1.1.4, 2.2.9.1.2.1.x) ---

/// PointerImage is the wire form of a colour pointer: an XOR mask in
/// XorBpp bits per pixel and a 1-bit AND mask, both bottom-up and with
/// each scan-line padded to 2 bytes.
public struct PointerImage {
    public var CacheIndex: int
    public var HotX: int
    public var HotY: int
    public var Width: int
    public var Height: int
    public var XorBpp: int
    public var XorMask: [uint8]
    public var AndMask: [uint8]

    public init() {
        CacheIndex = 0; HotX = 0; HotY = 0; Width = 0; Height = 0; XorBpp = 24; XorMask = []; AndMask = []
    }
}

/// ParsePointerPosition decodes TS_POINTERPOSATTRIBUTE.
public func ParsePointerPosition(_ data: [uint8]) throws -> (int, int) {
    var r = binary.Reader(data)
    do {
        let x = int(try r.U16LE())
        let y = int(try r.U16LE())
        return (x, y)
    } catch {
        throw FastPathError.malformed("truncated pointer position")
    }
}

/// ParseCachedPointer decodes TS_CACHEDPOINTERATTRIBUTE.
public func ParseCachedPointer(_ data: [uint8]) throws -> int {
    var r = binary.Reader(data)
    do {
        return int(try r.U16LE())
    } catch {
        throw FastPathError.malformed("truncated cached pointer")
    }
}

/// ParseColorPointer decodes TS_COLORPOINTERATTRIBUTE (24bpp XOR mask).
public func ParseColorPointer(_ data: [uint8]) throws -> PointerImage {
    var r = binary.Reader(data)
    return try parseColorPointerBody(&r, xorBpp: 24)
}

/// ParseNewPointer decodes TS_FP_POINTERATTRIBUTE (xorBpp then a colour
/// pointer).
public func ParseNewPointer(_ data: [uint8]) throws -> PointerImage {
    var r = binary.Reader(data)
    do {
        let bpp = int(try r.U16LE())
        return try parseColorPointerBody(&r, xorBpp: bpp)
    } catch let e as FastPathError {
        throw e
    } catch {
        throw FastPathError.malformed("truncated new pointer")
    }
}

/// ParseLargePointer decodes TS_FP_LARGEPOINTERATTRIBUTE.
public func ParseLargePointer(_ data: [uint8]) throws -> PointerImage {
    var r = binary.Reader(data)
    var p = PointerImage()
    do {
        p.XorBpp = int(try r.U16LE())
        p.CacheIndex = int(try r.U16LE())
        p.HotX = int(try r.U16LE())
        p.HotY = int(try r.U16LE())
        p.Width = int(try r.U16LE())
        p.Height = int(try r.U16LE())
        let andLen = int(try r.U32LE())
        let xorLen = int(try r.U32LE())
        p.XorMask = try r.Bytes(xorLen)
        p.AndMask = try r.Bytes(andLen)
    } catch {
        throw FastPathError.malformed("truncated large pointer")
    }
    return p
}

func parseColorPointerBody(_ r: inout binary.Reader, xorBpp: int) throws -> PointerImage {
    var p = PointerImage()
    p.XorBpp = xorBpp
    do {
        p.CacheIndex = int(try r.U16LE())
        p.HotX = int(try r.U16LE())
        p.HotY = int(try r.U16LE())
        p.Width = int(try r.U16LE())
        p.Height = int(try r.U16LE())
        let andLen = int(try r.U16LE())
        let xorLen = int(try r.U16LE())
        p.XorMask = try r.Bytes(xorLen)
        p.AndMask = try r.Bytes(andLen)
    } catch {
        throw FastPathError.malformed("truncated colour pointer")
    }
    return p
}
