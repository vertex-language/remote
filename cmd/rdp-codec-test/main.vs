// Unit tests for the fast-path parser, the bitmap codecs and the
// framebuffer blits, with hand-assembled vectors from the specs.
package main

import (
    "remote/rdp/codec/interleaved"
    "remote/rdp/codec/planar"
    "remote/rdp/fastpath"
    "remote/rdp/gfx"
)

var failures = 0
func check(_ ok: bool, _ msg: string) {
    if ok { print("ok    \(msg)") } else { print("FAIL  \(msg)"); failures += 1 }
}

func testInterleaved() {
    print("=== interleaved RLE ===")
    // 16bpp, 6x2. Line 1: colour run of 4 (0xF800 red), colour image of 2
    // raw pixels. Line 2: background run of 6 copies the line above.
    let src: [uint8] = [
        0x60 | 4, 0x00, 0xF8,                 // REGULAR_COLOR_RUN x4, pixel 0xF800
        0x80 | 2, 0x1F, 0x00, 0xE0, 0x07,     // REGULAR_COLOR_IMAGE x2: 0x001F, 0x07E0
        0x00 | 6,                             // REGULAR_BG_RUN x6
    ]
    do {
        let out = try interleaved.Decode(src, width: 6, height: 2, bpp: 16)
        check(out.count == 24, "output size 24")
        check(out[0] == 0x00 && out[1] == 0xF8, "run pixel 0")
        check(out[6] == 0x00 && out[7] == 0xF8, "run pixel 3")
        check(out[8] == 0x1F && out[9] == 0x00, "image pixel 4")
        check(out[10] == 0xE0 && out[11] == 0x07, "image pixel 5")
        var same = true
        var i = 0
        while i < 12 { if out[i] != out[12 + i] { same = false }; i += 1 }
        check(same, "second line copies first")
    } catch {
        check(false, "decode threw \(error)")
    }

    // Foreground run on line 2 XORs with the line above; fg set by LITE_SET_FG.
    // 8bpp 4x2: line 1 = colour run 4 of 0x0F; line 2 = LITE_SET_FG_FG_RUN
    // (0xC0 | 4) with fg 0xF0 -> 0x0F ^ 0xF0 = 0xFF.
    let src2: [uint8] = [0x60 | 4, 0x0F, 0xC0 | 4, 0xF0]
    do {
        let out = try interleaved.Decode(src2, width: 4, height: 2, bpp: 8)
        check(out[0] == 0x0F && out[3] == 0x0F, "8bpp colour run")
        check(out[4] == 0xFF && out[7] == 0xFF, "8bpp fg run XORs the row above")
    } catch {
        check(false, "decode threw \(error)")
    }

    // FGBG image on the first line: bits of the mask select fg, else black.
    // 8bpp 8x1: REGULAR_FGBG_IMAGE (0x40 | 1) -> 8 pixels, mask 0xA5; fg defaults to white.
    let src3: [uint8] = [0x40 | 1, 0xA5]
    do {
        let out = try interleaved.Decode(src3, width: 8, height: 1, bpp: 8)
        check(out[0] == 0xFF && out[1] == 0x00 && out[2] == 0xFF && out[5] == 0xFF && out[7] == 0xFF && out[6] == 0x00,
              "fgbg image mask 0xA5")
    } catch {
        check(false, "decode threw \(error)")
    }

    // A MEGA_MEGA colour run with a 16-bit length at 24bpp.
    var src4: [uint8] = [0xF3, 0x00, 0x01, 0x11, 0x22, 0x33]   // 256 pixels of 0x332211
    do {
        let out = try interleaved.Decode(src4, width: 16, height: 16, bpp: 24)
        check(out.count == 768 && out[765] == 0x11 && out[766] == 0x22 && out[767] == 0x33, "mega colour run 24bpp")
    } catch {
        check(false, "decode threw \(error)")
    }
    src4 = []
    var threw = false
    do { let _ = try interleaved.Decode([0x60 | 4, 0x00, 0xF8], width: 2, height: 1, bpp: 16) }
    catch { threw = true }
    check(threw, "run past the bitmap is an error")
}

func testPlanar() {
    print("=== planar ===")
    // Raw ARGB without alpha: header 0x20, planes R, G, B for 2x2, pad byte.
    let raw: [uint8] = [0x20,
        1, 2, 3, 4,        // R
        5, 6, 7, 8,        // G
        9, 10, 11, 12,     // B
        0]
    do {
        let out = try planar.Decode(raw, width: 2, height: 2)
        check(out.count == 12, "raw output size")
        check(out[0] == 1 && out[1] == 5 && out[2] == 9, "raw pixel 0")
        check(out[9] == 4 && out[10] == 8 && out[11] == 12, "raw pixel 3")
    } catch {
        check(false, "raw decode threw \(error)")
    }

    // RLE ARGB without alpha (header 0x30), 2x2. Each plane: row 0 raw 2
    // bytes; row 1 raw 2 deltas: +2 -> 4, -3 -> 5.
    let rle: [uint8] = [0x30,
        0x20, 10, 20, 0x20, 4, 5,       // R: row0 10,20; row1 12,17
        0x20, 0, 0, 0x20, 0, 0,         // G: all 0
        0x20, 100, 100, 0x20, 2, 1]     // B: row0 100,100; row1 101, 99
    do {
        let out = try planar.Decode(rle, width: 2, height: 2)
        check(out[0] == 10 && out[3] == 20, "rle row 0 R")
        check(out[6] == 12 && out[9] == 17, "rle row 1 R deltas (+2, -3)")
        check(out[8] == 101 && out[11] == 99, "rle row 1 B deltas (+1, -1)")
    } catch {
        check(false, "rle decode threw \(error)")
    }

    // A run: control 0x12 = run of 16 + 2 = 18 -> a 18x1 plane of one value.
    let run: [uint8] = [0x30,
        0x10, 7, 0x12,        // R: raw 1 byte (7) then run 18? no: 0x10 = raw 1, run 0; then 0x12 run 18 -> 19 > 18
    ]
    var threw = false
    do { let _ = try planar.Decode(run, width: 18, height: 1) } catch { threw = true }
    check(threw, "segment past the scanline is an error")
    let run2: [uint8] = [0x30,
        0x10, 7, 0x11,        // R: raw 7, then run 16+1 = 17 -> 18 total
        0x10, 8, 0x11,
        0x10, 9, 0x11]
    do {
        let out = try planar.Decode(run2, width: 18, height: 1)
        check(out[0] == 7 && out[1] == 8 && out[2] == 9 && out[51] == 7 && out[52] == 8 && out[53] == 9, "run fills the row")
    } catch {
        check(false, "run decode threw \(error)")
    }

    // YCoCg (cll = 1 -> shift 0), no alpha, raw: Y=128, Co=0, Cg=0 -> grey 128, R/B swapped is harmless.
    let ycocg: [uint8] = [0x21, 128, 0, 0, 0]
    do {
        let out = try planar.Decode(ycocg, width: 1, height: 1)
        check(out[0] == 128 && out[1] == 128 && out[2] == 128, "ycocg grey")
    } catch {
        check(false, "ycocg decode threw \(error)")
    }
}

func testFastPath() {
    print("=== fastpath ===")
    // One PDU: a single pointer-null update, then FIRST+LAST fragments of a
    // bitmap update body [1,2,3,4].
    let pdu: [uint8] = [
        0x00, 14,                       // header, length
        0x05, 0x00, 0x00,               // PTR_NULL, size 0
        0x21, 0x02, 0x00, 1, 2,         // BITMAP, FIRST, size 2
        0x11, 0x02, 0x00, 3, 4,         // BITMAP, LAST, size 2
    ]
    var r = fastpath.Reassembler()
    do {
        let ups = try r.Feed(pdu)
        check(ups.count == 2, "two updates")
        check(ups[0].Code == fastpath.UpdateCode.PointerNull, "first is PTR_NULL")
        check(ups[1].Code == fastpath.UpdateCode.Bitmap && ups[1].Data.count == 4 && ups[1].Data[3] == 4, "reassembled bitmap")
    } catch {
        check(false, "feed threw \(error)")
    }

    // A bitmap update with one 2x1 16bpp uncompressed rect at (10,20).
    let body: [uint8] = [
        0x01, 0x00, 0x01, 0x00,
        10, 0, 20, 0, 11, 0, 20, 0,     // left, top, right, bottom
        2, 0, 1, 0, 16, 0, 0x00, 0x00,  // width, height, bpp, flags
        4, 0, 0xAA, 0xBB, 0xCC, 0xDD]
    do {
        let rects = try fastpath.ParseBitmapUpdate(body)
        check(rects.count == 1 && rects[0].Left == 10 && rects[0].Bottom == 20 && rects[0].Width == 2, "bitmap rect fields")
        check(!rects[0].Compressed && rects[0].Data.count == 4, "bitmap data")
    } catch {
        check(false, "bitmap parse threw \(error)")
    }
}

func testFramebuffer() {
    print("=== framebuffer ===")
    var fb = gfx.Framebuffer(width: 4, height: 3)
    check(fb.Pixels.count == 48 && fb.Pixels[3] == 255, "opaque black start")
    // Two rows, 2 wide, bottom-up: row data [red, green] then [blue, white].
    let src: [uint8] = [0x00, 0xF8, 0xE0, 0x07,    // stored first = bottom row: red, green
                        0x1F, 0x00, 0xFF, 0xFF]    // top row: blue, white
    let dmg = fb.Blit16(src, srcWidth: 2, into: gfx.Rect(x: 1, y: 1, width: 2, height: 2), bottomUp: true)
    check(dmg.X == 1 && dmg.Y == 1 && dmg.Width == 2 && dmg.Height == 2, "damage rect")
    let topLeft = (1 * 4 + 1) * 4
    check(fb.Pixels[topLeft] == 0 && fb.Pixels[topLeft + 1] == 0 && fb.Pixels[topLeft + 2] == 255, "top-left is blue")
    let botLeft = (2 * 4 + 1) * 4
    check(fb.Pixels[botLeft] == 255 && fb.Pixels[botLeft + 1] == 0, "bottom-left is red")
    let botRight = (2 * 4 + 2) * 4
    check(fb.Pixels[botRight + 1] == 255 && fb.Pixels[botRight] == 0, "bottom-right is green")
    // Clipping: an update past the edge only writes what fits.
    let d2 = fb.Blit16(src, srcWidth: 2, into: gfx.Rect(x: 3, y: 2, width: 2, height: 2), bottomUp: true)
    check(d2.Width == 1 && d2.Height == 1, "clipped damage")
}

func main() -> int32 {
    testInterleaved()
    testPlanar()
    testFastPath()
    testFramebuffer()
    if failures > 0 { print("\(failures) FAILED"); return 1 }
    print("all passed")
    return 0
}
