// Package planar decodes the RDP 6.0 Bitmap Compressed Stream
// ([MS-RDPEGDI] 2.2.2.5.1, 3.1.9), which Windows uses for compressed
// bitmap updates at 32 bpp. The stream carries a format header, then one
// 8-bit plane per channel -- optionally alpha, then R/Y, G/Co, B/Cg --
// each either raw or run-length coded with a per-scanline delta
// transform, and optionally in the YCoCg colour space with colour-loss
// reduction. Decode returns RGB24 rows (red first) in the stream's own
// row order, which for bitmap updates is bottom-up.
package planar

/// PlanarError is a malformed planar stream.
public enum PlanarError: Error {
    case truncated
    case badSegment
    case badScanline
    case empty

    public var Message: string {
        switch self {
        case .truncated: return "planar: stream ended early"
        case .badSegment: return "planar: zero control byte in RLE segment"
        case .badScanline: return "planar: RLE segment runs past the scanline"
        case .empty: return "planar: empty bitmap"
        }
    }
}

/// Decode expands a planar stream for a width * height bitmap into
/// width * height * 3 bytes of RGB.
public func Decode(_ src: [uint8], width: int, height: int) throws -> [uint8] {
    if width <= 0 || height <= 0 { throw PlanarError.empty }
    if src.count < 1 { throw PlanarError.truncated }
    let header = src[0]
    let cll = int(header & 0x07)
    let subsampled = (header & 0x08) != 0 && cll != 0
    let rle = (header & 0x10) != 0
    let hasAlpha = (header & 0x20) == 0

    let planeSize = width * height
    var chromaWidth = width
    var chromaHeight = height
    if subsampled {
        chromaWidth = (width + 1) / 2
        chromaHeight = (height + 1) / 2
    }
    let chromaSize = chromaWidth * chromaHeight

    var p0 = [uint8](repeating: 0, count: planeSize)
    var p1 = [uint8](repeating: 0, count: chromaSize)
    var p2 = [uint8](repeating: 0, count: chromaSize)
    var pos = 1
    if rle {
        if hasAlpha {
            var alpha = [uint8](repeating: 0, count: planeSize)   // always 0xFF for desktop bitmaps; discarded
            pos = try decodePlane(src, from: pos, into: &alpha, width: width, height: height)
        }
        pos = try decodePlane(src, from: pos, into: &p0, width: width, height: height)
        pos = try decodePlane(src, from: pos, into: &p1, width: chromaWidth, height: chromaHeight)
        pos = try decodePlane(src, from: pos, into: &p2, width: chromaWidth, height: chromaHeight)
    } else {
        if hasAlpha { pos += planeSize }
        if pos + planeSize + 2 * chromaSize > src.count { throw PlanarError.truncated }
        var i = 0
        while i < planeSize { p0[i] = src[pos + i]; i += 1 }
        pos += planeSize
        i = 0
        while i < chromaSize { p1[i] = src[pos + i]; i += 1 }
        pos += chromaSize
        i = 0
        while i < chromaSize { p2[i] = src[pos + i]; i += 1 }
        // A single pad byte follows the raw planes.
    }

    var out = [uint8](repeating: 0, count: planeSize * 3)
    if cll == 0 {
        // ARGB: the planes are the channels.
        var i = 0
        var o = 0
        while i < planeSize {
            out[o] = p0[i]; out[o + 1] = p1[i]; out[o + 2] = p2[i]
            i += 1; o += 3
        }
        return out
    }

    // AYCoCg with colour-loss level cll: Co/Cg were shifted right by cll
    // bits and offset to unsigned. Shift left by cll - 1 (so the 1/2 in the
    // conversion matrix is folded in) and reinterpret as signed.
    let shift = cll - 1
    var i = 0
    var o = 0
    while i < planeSize {
        var ci = i
        if subsampled {
            let row = (i / width) >> 1
            let col = (i % width) >> 1
            ci = row * chromaWidth + col
        }
        let y = int(p0[i])
        let co = signed8((int(p1[ci]) << shift) & 0xFF)
        let cg = signed8((int(p2[ci]) << shift) & 0xFF)
        let t = y - cg
        let r = clamp(t + co)
        let g = clamp(y + cg)
        let b = clamp(t - co)
        if hasAlpha {
            out[o] = r; out[o + 1] = g; out[o + 2] = b
        } else {
            // 3.1.9.1.2: without an alpha plane the R and B channels are swapped.
            out[o] = b; out[o + 1] = g; out[o + 2] = r
        }
        i += 1; o += 3
    }
    return out
}

// signed8 reinterprets a byte value as two's-complement.
func signed8(_ v: int) -> int {
    return v >= 128 ? v - 256 : v
}

func clamp(_ v: int) -> uint8 {
    if v < 0 { return 0 }
    if v > 255 { return 255 }
    return uint8(truncatingIfNeeded: v)
}

// decodePlane expands one RLE plane ([MS-RDPEGDI] 2.2.2.5.1.1) into dst,
// undoing the scanline delta transform, and returns the position after it.
func decodePlane(_ src: [uint8], from start: int, into dst: inout [uint8], width: int, height: int) throws -> int {
    var pos = start
    var row = 0
    while row < height {
        let rowStart = row * width
        var col = 0
        var last: uint8 = 0
        while col < width {
            if pos >= src.count { throw PlanarError.truncated }
            let control = src[pos]
            pos += 1
            if control == 0 { throw PlanarError.badSegment }
            var run = int(control & 0x0F)
            var raw = int(control >> 4)
            if run == 1 { run = 16 + raw; raw = 0 }
            else if run == 2 { run = 32 + raw; raw = 0 }
            if col + raw + run > width { throw PlanarError.badScanline }
            if pos + raw > src.count { throw PlanarError.truncated }
            var k = 0
            while k < raw {
                last = src[pos + k]
                dst[rowStart + col + k] = last
                k += 1
            }
            pos += raw
            col += raw
            k = 0
            while k < run {
                dst[rowStart + col + k] = last
                k += 1
            }
            col += run
        }
        if row > 0 {
            // Each value is a delta from the pixel above: even deltas are
            // positive (d/2), odd ones negative (-(d+1)/2).
            let above = rowStart - width
            var x = 0
            while x < width {
                let d = dst[rowStart + x]
                var t: uint8
                if (d & 1) != 0 {
                    t = 255 &- ((d &- 1) >> 1)
                } else {
                    t = d >> 1
                }
                dst[rowStart + x] = dst[above + x] &+ t
                x += 1
            }
        }
        row += 1
    }
    return pos
}
