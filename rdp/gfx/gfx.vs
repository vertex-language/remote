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
        let target = dst.Intersect(Bounds)
        if target.IsEmpty { return target }
        let rowBytes = srcWidth * 2
        let srcRows = src.count / rowBytes
        var row = 0
        while row < target.Height {
            let srcRow = sourceRow(row + (target.Y - dst.Y), height: dst.Height, bottomUp: bottomUp)
            if srcRow >= srcRows { break }
            var s = srcRow * rowBytes + (target.X - dst.X) * 2
            var d = ((target.Y + row) * Width + target.X) * 4
            var n = target.Width
            while n > 0 {
                let v = uint32(src[s]) | (uint32(src[s + 1]) << 8)
                let r = (v >> 11) & 0x1f
                let g = (v >> 5) & 0x3f
                let b = v & 0x1f
                Pixels[d] = uint8(truncatingIfNeeded: (r << 3) | (r >> 2))
                Pixels[d + 1] = uint8(truncatingIfNeeded: (g << 2) | (g >> 4))
                Pixels[d + 2] = uint8(truncatingIfNeeded: (b << 3) | (b >> 2))
                Pixels[d + 3] = 255
                s += 2; d += 4; n -= 1
            }
            row += 1
        }
        return target
    }

    /// Blit15 writes 15bpp RGB555 rows.
    public mutating func Blit15(_ src: [uint8], srcWidth: int, into dst: Rect, bottomUp: bool) -> Rect {
        let target = dst.Intersect(Bounds)
        if target.IsEmpty { return target }
        let rowBytes = srcWidth * 2
        let srcRows = src.count / rowBytes
        var row = 0
        while row < target.Height {
            let srcRow = sourceRow(row + (target.Y - dst.Y), height: dst.Height, bottomUp: bottomUp)
            if srcRow >= srcRows { break }
            var s = srcRow * rowBytes + (target.X - dst.X) * 2
            var d = ((target.Y + row) * Width + target.X) * 4
            var n = target.Width
            while n > 0 {
                let v = uint32(src[s]) | (uint32(src[s + 1]) << 8)
                let r = (v >> 10) & 0x1f
                let g = (v >> 5) & 0x1f
                let b = v & 0x1f
                Pixels[d] = uint8(truncatingIfNeeded: (r << 3) | (r >> 2))
                Pixels[d + 1] = uint8(truncatingIfNeeded: (g << 3) | (g >> 2))
                Pixels[d + 2] = uint8(truncatingIfNeeded: (b << 3) | (b >> 2))
                Pixels[d + 3] = 255
                s += 2; d += 4; n -= 1
            }
            row += 1
        }
        return target
    }

    /// BlitBGR24 writes 24bpp rows whose bytes are blue, green, red (the
    /// order Windows uses for uncompressed and interleaved bitmaps).
    public mutating func BlitBGR24(_ src: [uint8], srcWidth: int, into dst: Rect, bottomUp: bool) -> Rect {
        return blit24(src, srcWidth: srcWidth, into: dst, bottomUp: bottomUp, redFirst: false)
    }

    /// BlitRGB24 writes 24bpp rows whose bytes are red, green, blue (what
    /// the planar codec produces).
    public mutating func BlitRGB24(_ src: [uint8], srcWidth: int, into dst: Rect, bottomUp: bool) -> Rect {
        return blit24(src, srcWidth: srcWidth, into: dst, bottomUp: bottomUp, redFirst: true)
    }

    mutating func blit24(_ src: [uint8], srcWidth: int, into dst: Rect, bottomUp: bool, redFirst: bool) -> Rect {
        let target = dst.Intersect(Bounds)
        if target.IsEmpty { return target }
        let rowBytes = srcWidth * 3
        let srcRows = src.count / rowBytes
        var row = 0
        while row < target.Height {
            let srcRow = sourceRow(row + (target.Y - dst.Y), height: dst.Height, bottomUp: bottomUp)
            if srcRow >= srcRows { break }
            var s = srcRow * rowBytes + (target.X - dst.X) * 3
            var d = ((target.Y + row) * Width + target.X) * 4
            var n = target.Width
            if redFirst {
                while n > 0 {
                    Pixels[d] = src[s]; Pixels[d + 1] = src[s + 1]; Pixels[d + 2] = src[s + 2]; Pixels[d + 3] = 255
                    s += 3; d += 4; n -= 1
                }
            } else {
                while n > 0 {
                    Pixels[d] = src[s + 2]; Pixels[d + 1] = src[s + 1]; Pixels[d + 2] = src[s]; Pixels[d + 3] = 255
                    s += 3; d += 4; n -= 1
                }
            }
            row += 1
        }
        return target
    }

    /// BlitBGRX32 writes 32bpp rows whose bytes are blue, green, red, pad
    /// (uncompressed 32bpp bitmap data).
    public mutating func BlitBGRX32(_ src: [uint8], srcWidth: int, into dst: Rect, bottomUp: bool) -> Rect {
        let target = dst.Intersect(Bounds)
        if target.IsEmpty { return target }
        let rowBytes = srcWidth * 4
        let srcRows = src.count / rowBytes
        var row = 0
        while row < target.Height {
            let srcRow = sourceRow(row + (target.Y - dst.Y), height: dst.Height, bottomUp: bottomUp)
            if srcRow >= srcRows { break }
            var s = srcRow * rowBytes + (target.X - dst.X) * 4
            var d = ((target.Y + row) * Width + target.X) * 4
            var n = target.Width
            while n > 0 {
                Pixels[d] = src[s + 2]; Pixels[d + 1] = src[s + 1]; Pixels[d + 2] = src[s]; Pixels[d + 3] = 255
                s += 4; d += 4; n -= 1
            }
            row += 1
        }
        return target
    }

    /// BlitPalette8 writes 8bpp indexed rows through a 256-entry RGB palette
    /// (3 bytes per entry, red first).
    public mutating func BlitPalette8(_ src: [uint8], srcWidth: int, palette: [uint8], into dst: Rect, bottomUp: bool) -> Rect {
        let target = dst.Intersect(Bounds)
        if target.IsEmpty { return target }
        let srcRows = src.count / srcWidth
        var row = 0
        while row < target.Height {
            let srcRow = sourceRow(row + (target.Y - dst.Y), height: dst.Height, bottomUp: bottomUp)
            if srcRow >= srcRows { break }
            var s = srcRow * srcWidth + (target.X - dst.X)
            var d = ((target.Y + row) * Width + target.X) * 4
            var n = target.Width
            while n > 0 {
                let p = int(src[s]) * 3
                if p + 2 < palette.count {
                    Pixels[d] = palette[p]; Pixels[d + 1] = palette[p + 1]; Pixels[d + 2] = palette[p + 2]
                }
                Pixels[d + 3] = 255
                s += 1; d += 4; n -= 1
            }
            row += 1
        }
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

// sourceRow maps a destination row (0 = top of the update) to the row
// index inside the source data.
func sourceRow(_ row: int, height: int, bottomUp: bool) -> int {
    return bottomUp ? (height - 1 - row) : row
}
