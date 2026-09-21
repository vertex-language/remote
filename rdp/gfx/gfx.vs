// Package gfx holds the client-side picture of the remote desktop: a
// premultiplied RGBA framebuffer (alpha 255, red first, top row first --
// the layout ui/window's Surface.Present takes) and the rectangles the
// codecs and the session use to describe damage. Codecs decode into raw
// pixel rows; the Blit* functions here convert those rows into the
// framebuffer. Legacy bitmap updates ([MS-RDPBCGR] 2.2.9.1.1.3.1.2) are
// bottom-up, so every blit takes the source's row order as a flag.
package gfx

/// Rect is a rectangle in framebuffer pixels: X/Y is its top-left corner,
/// the far edges are exclusive.
public struct Rect {
    public var X: int
    public var Y: int
    public var Width: int
    public var Height: int

    public init(x: int, y: int, width: int, height: int) {
        self.X = x
        self.Y = y
        self.Width = width
        self.Height = height
    }

    public var Right: int { return X + Width }
    public var Bottom: int { return Y + Height }
    public var IsEmpty: bool { return Width <= 0 || Height <= 0 }

    /// Intersect clips the rectangle to another.
    public func Intersect(_ o: Rect) -> Rect {
        let x0 = X > o.X ? X : o.X
        let y0 = Y > o.Y ? Y : o.Y
        let x1 = Right < o.Right ? Right : o.Right
        let y1 = Bottom < o.Bottom ? Bottom : o.Bottom
        if x1 <= x0 || y1 <= y0 { return Rect(x: 0, y: 0, width: 0, height: 0) }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Union is the smallest rectangle containing both.
    public func Union(_ o: Rect) -> Rect {
        if IsEmpty { return o }
        if o.IsEmpty { return self }
        let x0 = X < o.X ? X : o.X
        let y0 = Y < o.Y ? Y : o.Y
        let x1 = Right > o.Right ? Right : o.Right
        let y1 = Bottom > o.Bottom ? Bottom : o.Bottom
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// Framebuffer is the remote desktop's pixels: Width * Height * 4 bytes of
/// premultiplied RGBA, top row first.
public struct Framebuffer {
    public var Width: int
    public var Height: int
    public var Pixels: [uint8]

    public init(width: int, height: int) {
        self.Width = width
        self.Height = height
        self.Pixels = [uint8](repeating: 0, count: width * height * 4)
        // Opaque black, so alpha is right before the first update lands.
        var i = 3
        let n = width * height * 4
        while i < n { Pixels[i] = 255; i += 4 }
    }

    public var Bounds: Rect { return Rect(x: 0, y: 0, width: Width, height: Height) }

    /// Resize replaces the pixels with an opaque black buffer of a new size.
    public mutating func Resize(width: int, height: int) {
        self = Framebuffer(width: width, height: height)
    }

    /// Blit16 writes 16bpp RGB565 rows (2 bytes per pixel, little-endian,
    /// srcWidth pixels per row) into dst. Rows are bottom-up when bottomUp.
    public mutating func Blit16(_ src: [uint8], srcWidth: int, into dst: Rect, bottomUp: bool) -> Rect {
        return blit(src, srcWidth: srcWidth, bytesPerPixel: 2, format: formatRGB565, palette: [], into: dst, bottomUp: bottomUp)
    }

    /// Blit15 writes 15bpp RGB555 rows.
    public mutating func Blit15(_ src: [uint8], srcWidth: int, into dst: Rect, bottomUp: bool) -> Rect {
        return blit(src, srcWidth: srcWidth, bytesPerPixel: 2, format: formatRGB555, palette: [], into: dst, bottomUp: bottomUp)
    }

    /// BlitBGR24 writes 24bpp rows whose bytes are blue, green, red (the
    /// order Windows uses for uncompressed and interleaved bitmaps).
    public mutating func BlitBGR24(_ src: [uint8], srcWidth: int, into dst: Rect, bottomUp: bool) -> Rect {
        return blit(src, srcWidth: srcWidth, bytesPerPixel: 3, format: formatBGR24, palette: [], into: dst, bottomUp: bottomUp)
    }

    /// BlitRGB24 writes 24bpp rows whose bytes are red, green, blue (what
    /// the planar codec produces).
    public mutating func BlitRGB24(_ src: [uint8], srcWidth: int, into dst: Rect, bottomUp: bool) -> Rect {
        return blit(src, srcWidth: srcWidth, bytesPerPixel: 3, format: formatRGB24, palette: [], into: dst, bottomUp: bottomUp)
    }

    /// BlitBGRX32 writes 32bpp rows whose bytes are blue, green, red, pad
    /// (uncompressed 32bpp bitmap data).
    public mutating func BlitBGRX32(_ src: [uint8], srcWidth: int, into dst: Rect, bottomUp: bool) -> Rect {
        return blit(src, srcWidth: srcWidth, bytesPerPixel: 4, format: formatBGRX32, palette: [], into: dst, bottomUp: bottomUp)
    }

    /// BlitPalette8 writes 8bpp indexed rows through a 256-entry RGB palette
    /// (3 bytes per entry, red first).
    public mutating func BlitPalette8(_ src: [uint8], srcWidth: int, palette: [uint8], into dst: Rect, bottomUp: bool) -> Rect {
        var pal = palette
        while pal.count < 768 { pal.append(0) }
        return blit(src, srcWidth: srcWidth, bytesPerPixel: 1, format: formatPalette8, palette: pal, into: dst, bottomUp: bottomUp)
    }

    // blit converts the rows of src that land inside the framebuffer.
    mutating func blit(_ src: [uint8], srcWidth: int, bytesPerPixel: int, format: int, palette: [uint8],
                       into dst: Rect, bottomUp: bool) -> Rect {
        let target = dst.Intersect(Bounds)
        if target.IsEmpty || srcWidth <= 0 { return target }
        let rowBytes = srcWidth * bytesPerPixel
        let srcRows = src.count / rowBytes
        let width = Width
        convertRows(&Pixels, src, palette, target, dst, width, rowBytes, srcRows, bytesPerPixel, format, bottomUp)
        return target
    }

    /// Fill paints a rectangle a solid opaque color.
    public mutating func Fill(_ rect: Rect, r: uint8, g: uint8, b: uint8) -> Rect {
        let target = rect.Intersect(Bounds)
        if target.IsEmpty { return target }
        var row = 0
        while row < target.Height {
            var d = ((target.Y + row) * Width + target.X) * 4
            var n = target.Width
            while n > 0 {
                Pixels[d] = r; Pixels[d + 1] = g; Pixels[d + 2] = b; Pixels[d + 3] = 255
                d += 4; n -= 1
            }
            row += 1
        }
        return target
    }
}

let formatRGB565 = 0
let formatRGB555 = 1
let formatBGR24 = 2
let formatRGB24 = 3
let formatBGRX32 = 4
let formatPalette8 = 5

// convertRows writes the part of an update inside target into the pixels,
// converting each source pixel to opaque RGBA. It runs on raw pointers:
// this is every pixel of every bitmap update.
func convertRows(_ pixels: inout [uint8], _ src: [uint8], _ palette: [uint8], _ target: Rect, _ dst: Rect,
                 _ width: int, _ rowBytes: int, _ srcRows: int, _ bpp: int, _ format: int, _ bottomUp: bool) {
    pixels.withUnsafeMutableBufferPointer { pb in
        src.withUnsafeBufferPointer { sb in
            palette.withUnsafeBufferPointer { palb in
                let out = pb.baseAddress!
                let inp = sb.baseAddress!
                let pal = palb.baseAddress
                var row = 0
                while row < target.Height {
                    let srcRow = sourceRow(row + (target.Y - dst.Y), height: dst.Height, bottomUp: bottomUp)
                    if srcRow >= srcRows { break }
                    var s = inp + (srcRow * rowBytes + (target.X - dst.X) * bpp)
                    var d = out + ((target.Y + row) * width + target.X) * 4
                    var n = target.Width
                    switch format {
                    case formatRGB565:
                        while n > 0 {
                            let v = uint32(s.pointee) | (uint32((s + 1).pointee) << 8)
                            let r = (v >> 11) & 0x1f
                            let g = (v >> 5) & 0x3f
                            let b = v & 0x1f
                            d.pointee = uint8(truncatingIfNeeded: (r << 3) | (r >> 2))
                            (d + 1).pointee = uint8(truncatingIfNeeded: (g << 2) | (g >> 4))
                            (d + 2).pointee = uint8(truncatingIfNeeded: (b << 3) | (b >> 2))
                            (d + 3).pointee = 255
                            s = s + 2; d = d + 4; n -= 1
                        }
                    case formatRGB555:
                        while n > 0 {
                            let v = uint32(s.pointee) | (uint32((s + 1).pointee) << 8)
                            let r = (v >> 10) & 0x1f
                            let g = (v >> 5) & 0x1f
                            let b = v & 0x1f
                            d.pointee = uint8(truncatingIfNeeded: (r << 3) | (r >> 2))
                            (d + 1).pointee = uint8(truncatingIfNeeded: (g << 3) | (g >> 2))
                            (d + 2).pointee = uint8(truncatingIfNeeded: (b << 3) | (b >> 2))
                            (d + 3).pointee = 255
                            s = s + 2; d = d + 4; n -= 1
                        }
                    case formatBGR24:
                        while n > 0 {
                            d.pointee = (s + 2).pointee; (d + 1).pointee = (s + 1).pointee
                            (d + 2).pointee = s.pointee; (d + 3).pointee = 255
                            s = s + 3; d = d + 4; n -= 1
                        }
                    case formatRGB24:
                        while n > 0 {
                            d.pointee = s.pointee; (d + 1).pointee = (s + 1).pointee
                            (d + 2).pointee = (s + 2).pointee; (d + 3).pointee = 255
                            s = s + 3; d = d + 4; n -= 1
                        }
                    case formatBGRX32:
                        while n > 0 {
                            d.pointee = (s + 2).pointee; (d + 1).pointee = (s + 1).pointee
                            (d + 2).pointee = s.pointee; (d + 3).pointee = 255
                            s = s + 4; d = d + 4; n -= 1
                        }
                    default:
                        while n > 0 {
                            let p = int(s.pointee) * 3
                            d.pointee = (pal! + p).pointee; (d + 1).pointee = (pal! + p + 1).pointee
                            (d + 2).pointee = (pal! + p + 2).pointee; (d + 3).pointee = 255
                            s = s + 1; d = d + 4; n -= 1
                        }
                    }
                    row += 1
                }
            }
        }
    }
}

// sourceRow maps a destination row (0 = top of the update) to the row
// index inside the source data.
func sourceRow(_ row: int, height: int, bottomUp: bool) -> int {
    return bottomUp ? (height - 1 - row) : row
}
