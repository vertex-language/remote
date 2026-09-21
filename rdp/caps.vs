// Capability sets and the Confirm Active PDU ([MS-RDPBCGR] 2.2.1.13.2,
// 2.2.7). We advertise 32bpp bitmap updates with drawing orders disabled,
// so a modern Windows server streams bitmap surface updates that we can
// decode without implementing the GDI order set.
package rdp

import "encoding/binary"

let capGeneral: uint16 = 1
let capBitmap: uint16 = 2
let capOrder: uint16 = 3
let capBitmapCache: uint16 = 4
let capPointer: uint16 = 8
let capSound: uint16 = 12
let capInput: uint16 = 13
let capBrush: uint16 = 15
let capGlyphCache: uint16 = 16
let capOffscreen: uint16 = 17
let capVirtualChannel: uint16 = 20
let capMultifragmentUpdate: uint16 = 26
let capLargePointer: uint16 = 27

func capSet(_ type: uint16, _ data: [uint8]) -> [uint8] {
    var w = binary.Writer()
    w.U16LE(type)
    w.U16LE(uint16(truncatingIfNeeded: data.count + 4))
    w.Append(data)
    return w.Bytes
}

func capGeneralData() -> [uint8] {
    var w = binary.Writer()
    w.U16LE(1)          // osMajorType WINDOWS
    w.U16LE(3)          // osMinorType WINDOWS_NT
    w.U16LE(0x0200)     // protocolVersion
    w.U16LE(0)          // pad
    w.U16LE(0)          // generalCompressionTypes
    w.U16LE(0x0001 | 0x0004 | 0x0400)  // extraFlags: FASTPATH_OUTPUT_SUPPORTED|LONG_CREDENTIALS_SUPPORTED|NO_BITMAP_COMPRESSION_HDR
    w.U16LE(0)          // updateCapabilityFlag
    w.U16LE(0)          // remoteUnshareFlag
    w.U16LE(0)          // generalCompressionLevel
    w.U8(0)             // refreshRectSupport
    w.U8(0)             // suppressOutputSupport
    return w.Bytes
}

func capBitmapData(width: uint16, height: uint16) -> [uint8] {
    var w = binary.Writer()
    w.U16LE(32)         // preferredBitsPerPixel
    w.U16LE(1)          // receive1BitPerPixel
    w.U16LE(1)          // receive4BitsPerPixel
    w.U16LE(1)          // receive8BitsPerPixel
    w.U16LE(width)      // desktopWidth
    w.U16LE(height)     // desktopHeight
    w.U16LE(0)          // pad
    w.U16LE(1)          // desktopResizeFlag
    w.U16LE(1)          // bitmapCompressionFlag
    w.U8(0)             // highColorFlags
    w.U8(0)             // drawingFlags
    w.U16LE(1)          // multipleRectangleSupport
    w.U16LE(0)          // pad
    return w.Bytes
}

func capOrderData() -> [uint8] {
    var w = binary.Writer()
    var t = 0
    while t < 16 { w.U8(0); t += 1 }   // terminalDescriptor
    w.U32LE(0)          // pad
    w.U16LE(1)          // desktopSaveXGranularity
    w.U16LE(20)         // desktopSaveYGranularity
    w.U16LE(0)          // pad
    w.U16LE(1)          // maximumOrderLevel
    w.U16LE(0)          // numberFonts
    w.U16LE(0x0002 | 0x0008)  // orderFlags: NEGOTIATEORDERSUPPORT | ZEROBOUNDSDELTASSUPPORT (both required)
    var o = 0
    while o < 32 { w.U8(0); o += 1 }   // orderSupport (all disabled -> bitmap updates)
    w.U16LE(0)          // textFlags
    w.U16LE(0)          // orderSupportExFlags
    w.U32LE(0)          // pad
    w.U32LE(0)          // desktopSaveSize
    w.U16LE(0)          // pad
    w.U16LE(0)          // pad
    w.U16LE(0)          // textANSICodePage
    w.U16LE(0)          // pad
    return w.Bytes
}

func capBitmapCacheData() -> [uint8] {
    // Rev1 with no caches (36 bytes of pad/zero entries).
    return [uint8](repeating: 0, count: 36)
}

func capPointerData() -> [uint8] {
    var w = binary.Writer()
    w.U16LE(1)          // colorPointerFlag
    w.U16LE(20)         // colorPointerCacheSize
    w.U16LE(21)         // pointerCacheSize
    return w.Bytes
}

func capInputData(keyboardLayout: uint32) -> [uint8] {
    var w = binary.Writer()
    w.U16LE(0x0001 | 0x0004 | 0x0008 | 0x0010 | 0x0020)  // SCANCODES|MOUSEX|FASTPATH_INPUT|UNICODE|FASTPATH_INPUT2
    w.U16LE(0)          // pad
    w.U32LE(keyboardLayout)
    w.U32LE(4)          // keyboardType
    w.U32LE(0)          // keyboardSubType
    w.U32LE(12)         // keyboardFunctionKey
    var i = 0
    while i < 64 { w.U8(0); i += 1 }   // imeFileName
    return w.Bytes
}

func capBrushData() -> [uint8] {
    var w = binary.Writer()
    w.U32LE(0)          // brushSupportLevel BRUSH_DEFAULT
    return w.Bytes
}

func capGlyphCacheData() -> [uint8] {
    var w = binary.Writer()
    // 10 glyph cache entries (CacheEntries u16, CacheMaximumCellSize u16).
    let sizes: [uint16] = [4, 4, 8, 8, 16, 32, 64, 128, 256, 256]
    for s in sizes {
        w.U16LE(254)    // CacheEntries
        w.U16LE(s)
    }
    w.U32LE(0)          // FragCache
    w.U16LE(0)          // GlyphSupportLevel GLYPH_SUPPORT_NONE
    w.U16LE(0)          // pad
    return w.Bytes
}

func capOffscreenData() -> [uint8] {
    var w = binary.Writer()
    w.U32LE(0)          // offscreenSupportLevel
    w.U16LE(0)          // offscreenCacheSize
    w.U16LE(0)          // offscreenCacheEntries
    return w.Bytes
}

func capVirtualChannelData() -> [uint8] {
    var w = binary.Writer()
    w.U32LE(0)          // flags VCCAPS_NO_COMPR
    w.U32LE(0)          // VCChunkSize
    return w.Bytes
}

func capSoundData() -> [uint8] {
    var w = binary.Writer()
    w.U16LE(0)          // soundFlags
    w.U16LE(0)          // pad
    return w.Bytes
}

func capMultifragmentUpdateData() -> [uint8] {
    var w = binary.Writer()
    w.U32LE(8 * 1024 * 1024)   // MaxRequestSize: largest fast-path update we reassemble
    return w.Bytes
}

func capLargePointerData() -> [uint8] {
    var w = binary.Writer()
    w.U16LE(0x0001 | 0x0002)   // LARGE_POINTER_FLAG_96x96 | LARGE_POINTER_FLAG_384x384
    return w.Bytes
}

/// buildConfirmActive builds the Confirm Active PDU.
func buildConfirmActive(shareId: uint32, source: uint16, width: uint16, height: uint16, keyboardLayout: uint32) -> [uint8] {
    var caps = binary.Writer()
    var count = 0
    func add(_ b: [uint8]) { caps.Append(b); count += 1 }
    add(capSet(capGeneral, capGeneralData()))
    add(capSet(capBitmap, capBitmapData(width: width, height: height)))
    add(capSet(capOrder, capOrderData()))
    add(capSet(capBitmapCache, capBitmapCacheData()))
    add(capSet(capPointer, capPointerData()))
    add(capSet(capInput, capInputData(keyboardLayout: keyboardLayout)))
    add(capSet(capBrush, capBrushData()))
    add(capSet(capGlyphCache, capGlyphCacheData()))
    add(capSet(capOffscreen, capOffscreenData()))
    add(capSet(capVirtualChannel, capVirtualChannelData()))
    add(capSet(capSound, capSoundData()))
    add(capSet(capMultifragmentUpdate, capMultifragmentUpdateData()))
    add(capSet(capLargePointer, capLargePointerData()))

    let source6: [uint8] = [0x4d, 0x53, 0x54, 0x53, 0x43, 0x00]   // "MSTSC\0"

    var body = binary.Writer()
    body.U32LE(shareId)
    body.U16LE(0x03EA)                                  // originatorId (server channel 1002)
    body.U16LE(uint16(truncatingIfNeeded: source6.count))    // lengthSourceDescriptor
    body.U16LE(uint16(truncatingIfNeeded: caps.Bytes.count + 4))  // lengthCombinedCapabilities
    body.Append(source6)
    body.U16LE(uint16(truncatingIfNeeded: count))       // numberCapabilities
    body.U16LE(0)                                        // pad2octets
    body.Append(caps.Bytes)

    return shareControlHeader(pduTypeConfirmActive, source: source, body: body.Bytes)
}
