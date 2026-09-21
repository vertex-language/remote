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
    let size = rowDelta * height
    var dst = [uint8](repeating: 0, count: size)
    if src.isEmpty { throw InterleavedError.truncated }
    // The decoder runs over raw pointers: array subscripts are runtime
    // calls, and this loop touches every pixel of every update.
    var failure: int = 0
    var failedOrder: uint8 = 0
    src.withUnsafeBufferPointer { sb in
        dst.withUnsafeMutableBufferPointer { db in
            var d = Decoder(src: sb.baseAddress!, srcCount: src.count, dst: db.baseAddress!, dstCount: size,
                            rowDelta: rowDelta, bytesPerPixel: bytesPerPixel, white: white)
            d.run()
            failure = d.failure
            failedOrder = d.failedOrder
        }
    }
    switch failure {
    case 0: return dst
    case 1: throw InterleavedError.truncated
    case 2: throw InterleavedError.overflow
    default: throw InterleavedError.badOrder(failedOrder)
    }
}

struct Decoder {
    let src: UnsafePointer<uint8>
    let srcCount: int
    var pos: int = 0
    let dst: UnsafeMutablePointer<uint8>
    let dstCount: int
    var out: int = 0
    let rowDelta: int
    let bytesPerPixel: int
    let white: uint32
    var fg: uint32
    var insertFg: bool = false
    var firstLine: bool = true
    // 0 ok, 1 truncated, 2 overflow, 3 bad order (failedOrder).
    var failure: int = 0
    var failedOrder: uint8 = 0

    init(src: UnsafePointer<uint8>, srcCount: int, dst: UnsafeMutablePointer<uint8>, dstCount: int,
         rowDelta: int, bytesPerPixel: int, white: uint32) {
        self.src = src
        self.srcCount = srcCount
        self.dst = dst
        self.dstCount = dstCount
        self.rowDelta = rowDelta
        self.bytesPerPixel = bytesPerPixel
        self.white = white
        self.fg = white
    }

    mutating func readU8() -> uint8 {
        if pos >= srcCount { failure = 1; return 0 }
        let b = (src + pos).pointee
        pos += 1
        return b
    }

    mutating func readPixel() -> uint32 {
        if pos + bytesPerPixel > srcCount { failure = 1; return 0 }
        let p = src + pos
        var v = uint32(p.pointee)
        if bytesPerPixel >= 2 { v |= uint32((p + 1).pointee) << 8 }
        if bytesPerPixel >= 3 { v |= uint32((p + 2).pointee) << 16 }
        pos += bytesPerPixel
        return v
    }

    mutating func writePixel(_ v: uint32) {
        let p = dst + out
        p.pointee = uint8(truncatingIfNeeded: v)
        if bytesPerPixel >= 2 { (p + 1).pointee = uint8(truncatingIfNeeded: v >> 8) }
        if bytesPerPixel >= 3 { (p + 2).pointee = uint8(truncatingIfNeeded: v >> 16) }
        out += bytesPerPixel
    }

    func pixelAbove() -> uint32 {
        let p = dst + (out - rowDelta)
        var v = uint32(p.pointee)
        if bytesPerPixel >= 2 { v |= uint32((p + 1).pointee) << 8 }
        if bytesPerPixel >= 3 { v |= uint32((p + 2).pointee) << 16 }
        return v
    }

    // room checks that pixels more fit, flagging overflow when not.
    mutating func room(_ pixels: int) -> bool {
        if out + pixels * bytesPerPixel > dstCount {
            failure = 2
            return false
        }
        return true
    }

    // runLength decodes the order's run length, reading extension bytes.
    mutating func runLength(_ code: uint8, header: uint8) -> int {
        switch code {
        case regularFgBgImage:
            let n = int(header & 0x1F)
            if n == 0 { return int(readU8()) + 1 }
            return n * 8
        case liteSetFgFgBgImage:
            let n = int(header & 0x0F)
            if n == 0 { return int(readU8()) + 1 }
            return n * 8
        case regularBgRun, regularFgRun, regularColorRun, regularColorImage:
            let n = int(header & 0x1F)
            if n == 0 { return int(readU8()) + 32 }
            return n
        case liteSetFgFgRun, liteDitheredRun:
            let n = int(header & 0x0F)
            if n == 0 { return int(readU8()) + 16 }
            return n
        case megaBgRun, megaFgRun, megaFgBgImage, megaColorRun, megaColorImage,
             megaSetFgFgRun, megaSetFgFgBgImage, megaDitheredRun:
            let lo = readU8()
            let hi = readU8()
            return int(lo) | (int(hi) << 8)
        default:
            return 0
        }
    }

    mutating func fgBgImage(_ mask: uint8, bits: int) {
        if !room(bits) { return }
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

    mutating func run() {
        while pos < srcCount && failure == 0 {
            if firstLine && out >= rowDelta {
                firstLine = false
                insertFg = false
            }
            let header = readU8()
            var code: uint8
            if (header & 0xC0) != 0xC0 {
                code = header >> 5
            } else if (header & 0xF0) == 0xF0 {
                code = header
            } else {
                code = header >> 4
            }
            let length = runLength(code, header: header)
            if failure != 0 { return }

            if code == regularBgRun || code == megaBgRun {
                if !room(length) { return }
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
                if code == liteSetFgFgRun || code == megaSetFgFgRun { fg = readPixel() }
                if !room(length) { return }
                var n = length
                if firstLine {
                    while n > 0 { writePixel(fg); n -= 1 }
                } else {
                    while n > 0 { writePixel(pixelAbove() ^ fg); n -= 1 }
                }
            case liteDitheredRun, megaDitheredRun:
                let a = readPixel()
                let b = readPixel()
                if !room(length * 2) { return }
                var n = length
                while n > 0 { writePixel(a); writePixel(b); n -= 1 }
            case regularColorRun, megaColorRun:
                let p = readPixel()
                if !room(length) { return }
                var n = length
                while n > 0 { writePixel(p); n -= 1 }
            case regularFgBgImage, megaFgBgImage, liteSetFgFgBgImage, megaSetFgFgBgImage:
                if code == liteSetFgFgBgImage || code == megaSetFgFgBgImage { fg = readPixel() }
                var left = length
                while left > 0 && failure == 0 {
                    let bits = left < 8 ? left : 8
                    let mask = readU8()
                    fgBgImage(mask, bits: bits)
                    left -= bits
                }
            case regularColorImage, megaColorImage:
                let bytes = length * bytesPerPixel
                if pos + bytes > srcCount { failure = 1; return }
                if !room(length) { return }
                var i = 0
                while i < bytes { (dst + out + i).pointee = (src + pos + i).pointee; i += 1 }
                pos += bytes
                out += bytes
            case specialFgBg1:
                fgBgImage(0x03, bits: 8)
            case specialFgBg2:
                fgBgImage(0x05, bits: 8)
            case specialWhite:
                if !room(1) { return }
                writePixel(white)
            case specialBlack:
                if !room(1) { return }
                writePixel(0)
            default:
                failure = 3
                failedOrder = header
            }
        }
    }
}
