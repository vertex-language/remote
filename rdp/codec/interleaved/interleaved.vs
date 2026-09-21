// Package interleaved decodes the Interleaved RLE bitmap codec
// ([MS-RDPBCGR] 2.2.9.1.1.3.1.2.4 and the pseudo-code in 3.1.9), which
// Windows uses for compressed bitmap updates at 8, 15, 16 and 24 bpp. The
// output is the raw pixel rows in the source's own format, bottom-up,
// exactly as the uncompressed form of the bitmap would be: 1, 2 or 3 bytes
// per pixel, little-endian, no row padding.
package interleaved

/// InterleavedError is a malformed or unsupported RLE stream.
public enum InterleavedError: Error {
    case badOrder(uint8)
    case truncated
    case overflow
    case badDepth(int)
    case empty

    public var Message: string {
        switch self {
        case .badOrder(let c): return "interleaved: bad order code \(c)"
        case .truncated: return "interleaved: stream ended inside an order"
        case .overflow: return "interleaved: order runs past the bitmap"
        case .badDepth(let d): return "interleaved: unsupported depth \(d) bpp"
        case .empty: return "interleaved: empty bitmap"
        }
    }
}

// Order codes after decoding the header byte ([MS-RDPBCGR] 2.2.9.1.1.3.1.2.4).
let regularBgRun: uint8 = 0x00
let regularFgRun: uint8 = 0x01
let regularFgBgImage: uint8 = 0x02
let regularColorRun: uint8 = 0x03
let regularColorImage: uint8 = 0x04
let liteSetFgFgRun: uint8 = 0x0C
let liteSetFgFgBgImage: uint8 = 0x0D
let liteDitheredRun: uint8 = 0x0E
let megaBgRun: uint8 = 0xF0
let megaFgRun: uint8 = 0xF1
let megaFgBgImage: uint8 = 0xF2
let megaColorRun: uint8 = 0xF3
let megaColorImage: uint8 = 0xF4
let megaSetFgFgRun: uint8 = 0xF6
let megaSetFgFgBgImage: uint8 = 0xF7
let megaDitheredRun: uint8 = 0xF8
let specialFgBg1: uint8 = 0xF9
let specialFgBg2: uint8 = 0xFA
let specialWhite: uint8 = 0xFD
let specialBlack: uint8 = 0xFE

/// Decode expands an RLE stream into width * height pixels of bpp bits
/// each (8, 15, 16 or 24). Rows come out bottom-up, as encoded.
public func Decode(_ src: [uint8], width: int, height: int, bpp: int) throws -> [uint8] {
    if width <= 0 || height <= 0 { throw InterleavedError.empty }
    var bytesPerPixel = 0
    var white: uint32 = 0
    switch bpp {
    case 8: bytesPerPixel = 1; white = 0xFF
    case 15: bytesPerPixel = 2; white = 0x7FFF
    case 16: bytesPerPixel = 2; white = 0xFFFF
    case 24: bytesPerPixel = 3; white = 0xFFFFFF
    default: throw InterleavedError.badDepth(bpp)
    }
    let rowDelta = width * bytesPerPixel
    var d = Decoder(src: src, dstCount: rowDelta * height, rowDelta: rowDelta, bytesPerPixel: bytesPerPixel, white: white)
    try d.run()
    return d.dst
}

struct Decoder {
    var src: [uint8]
    var pos: int = 0
    var dst: [uint8]
    var out: int = 0
    let rowDelta: int
    let bytesPerPixel: int
    let white: uint32
    var fg: uint32
    var insertFg: bool = false
    var firstLine: bool = true

    init(src: [uint8], dstCount: int, rowDelta: int, bytesPerPixel: int, white: uint32) {
        self.src = src
        self.dst = [uint8](repeating: 0, count: dstCount)
        self.rowDelta = rowDelta
        self.bytesPerPixel = bytesPerPixel
        self.white = white
        self.fg = white
    }

    mutating func readU8() throws -> uint8 {
        if pos >= src.count { throw InterleavedError.truncated }
        let b = src[pos]
        pos += 1
        return b
    }

    mutating func readPixel() throws -> uint32 {
        if pos + bytesPerPixel > src.count { throw InterleavedError.truncated }
        var v = uint32(src[pos])
        if bytesPerPixel >= 2 { v |= uint32(src[pos + 1]) << 8 }
        if bytesPerPixel >= 3 { v |= uint32(src[pos + 2]) << 16 }
        pos += bytesPerPixel
        return v
    }

    mutating func writePixel(_ v: uint32) {
        dst[out] = uint8(truncatingIfNeeded: v)
        if bytesPerPixel >= 2 { dst[out + 1] = uint8(truncatingIfNeeded: v >> 8) }
        if bytesPerPixel >= 3 { dst[out + 2] = uint8(truncatingIfNeeded: v >> 16) }
        out += bytesPerPixel
    }

    func pixelAbove() -> uint32 {
        let p = out - rowDelta
        var v = uint32(dst[p])
        if bytesPerPixel >= 2 { v |= uint32(dst[p + 1]) << 8 }
        if bytesPerPixel >= 3 { v |= uint32(dst[p + 2]) << 16 }
        return v
    }

    func ensureOut(_ pixels: int) throws {
        if out + pixels * bytesPerPixel > dst.count { throw InterleavedError.overflow }
    }

    // runLength decodes the order's run length, reading extension bytes.
    mutating func runLength(_ code: uint8, header: uint8) throws -> int {
        switch code {
        case regularFgBgImage:
            let n = int(header & 0x1F)
            if n == 0 { return int(try readU8()) + 1 }
            return n * 8
        case liteSetFgFgBgImage:
            let n = int(header & 0x0F)
            if n == 0 { return int(try readU8()) + 1 }
            return n * 8
        case regularBgRun, regularFgRun, regularColorRun, regularColorImage:
            let n = int(header & 0x1F)
            if n == 0 { return int(try readU8()) + 32 }
            return n
        case liteSetFgFgRun, liteDitheredRun:
            let n = int(header & 0x0F)
            if n == 0 { return int(try readU8()) + 16 }
            return n
        case megaBgRun, megaFgRun, megaFgBgImage, megaColorRun, megaColorImage,
             megaSetFgFgRun, megaSetFgFgBgImage, megaDitheredRun:
            let lo = try readU8()
            let hi = try readU8()
            return int(lo) | (int(hi) << 8)
        default:
            return 0
        }
    }

    mutating func fgBgImage(_ mask: uint8, bits: int) throws {
        try ensureOut(bits)
        var m: uint8 = 1
        var n = bits
        while n > 0 {
            if firstLine {
                writePixel((mask & m) != 0 ? fg : 0)
            } else {
                let above = pixelAbove()
                writePixel((mask & m) != 0 ? (above ^ fg) : above)
            }
            m = m << 1
            n -= 1
        }
    }

    mutating func run() throws {
        while pos < src.count {
            if firstLine && out >= rowDelta {
                firstLine = false
                insertFg = false
            }
            let header = try readU8()
            var code: uint8
            if (header & 0xC0) != 0xC0 {
                code = header >> 5
            } else if (header & 0xF0) == 0xF0 {
                code = header
            } else {
                code = header >> 4
            }
            let length = try runLength(code, header: header)

            if code == regularBgRun || code == megaBgRun {
                try ensureOut(length)
                var n = length
                if firstLine {
                    if insertFg && n > 0 { writePixel(fg); n -= 1 }
                    while n > 0 { writePixel(0); n -= 1 }
                } else {
                    if insertFg && n > 0 { writePixel(pixelAbove() ^ fg); n -= 1 }
                    while n > 0 { writePixel(pixelAbove()); n -= 1 }
                }
                insertFg = true
                continue
            }
            insertFg = false

            switch code {
            case regularFgRun, megaFgRun, liteSetFgFgRun, megaSetFgFgRun:
                if code == liteSetFgFgRun || code == megaSetFgFgRun { fg = try readPixel() }
                try ensureOut(length)
                var n = length
                if firstLine {
                    while n > 0 { writePixel(fg); n -= 1 }
                } else {
                    while n > 0 { writePixel(pixelAbove() ^ fg); n -= 1 }
                }
            case liteDitheredRun, megaDitheredRun:
                let a = try readPixel()
                let b = try readPixel()
                try ensureOut(length * 2)
                var n = length
                while n > 0 { writePixel(a); writePixel(b); n -= 1 }
            case regularColorRun, megaColorRun:
                let p = try readPixel()
                try ensureOut(length)
                var n = length
                while n > 0 { writePixel(p); n -= 1 }
            case regularFgBgImage, megaFgBgImage, liteSetFgFgBgImage, megaSetFgFgBgImage:
                if code == liteSetFgFgBgImage || code == megaSetFgFgBgImage { fg = try readPixel() }
                var left = length
                while left > 0 {
                    let bits = left < 8 ? left : 8
                    let mask = try readU8()
                    try fgBgImage(mask, bits: bits)
                    left -= bits
                }
            case regularColorImage, megaColorImage:
                let bytes = length * bytesPerPixel
                if pos + bytes > src.count { throw InterleavedError.truncated }
                try ensureOut(length)
                var i = 0
                while i < bytes { dst[out + i] = src[pos + i]; i += 1 }
                pos += bytes
                out += bytes
            case specialFgBg1:
                try fgBgImage(0x03, bits: 8)
            case specialFgBg2:
                try fgBgImage(0x05, bits: 8)
            case specialWhite:
                try ensureOut(1)
                writePixel(white)
            case specialBlack:
                try ensureOut(1)
                writePixel(0)
            default:
                throw InterleavedError.badOrder(header)
            }
        }
    }
}
