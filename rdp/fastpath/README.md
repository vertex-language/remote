# remote/rdp/fastpath

Parses server fast-path update PDUs ([MS-RDPBCGR] 2.2.9.1.2): the outer PDU into its updates, fragmented updates back into whole ones, and the bitmap and pointer update bodies into values the session can act on.

```vertex
import "remote/rdp/fastpath"
```

## Types

- **`FastPathError`** (enum): FastPathError is a malformed fast-path PDU.
- **`UpdateCode`** (struct): Update codes (updateCode in the TS_FP_UPDATE header).
- **`Update`** (struct): Update is one whole (reassembled) fast-path update.
- **`Reassembler`** (struct): Reassembler splits fast-path PDUs into updates and joins fragmented updates. Feed it whole frames from the transport; it returns the updates that completed.
- **`BitmapFlags`** (struct): BitmapFlags values in TS_BITMAP_DATA.flags.
- **`BitmapData`** (struct): BitmapData is one TS_BITMAP_DATA rectangle. Data is the bitmap stream with any TS_CD_HEADER already stripped.
- **`PointerImage`** (struct): PointerImage is the wire form of a colour pointer: an XOR mask in XorBpp bits per pixel and a 1-bit AND mask, both bottom-up and with each scan-line padded to 2 bytes.

## Functions

- `func ParseBitmapUpdate(_ data: [uint8]) throws -> [BitmapData]`: ParseBitmapUpdate decodes a TS_UPDATE_BITMAP_DATA body.
- `func ParsePaletteUpdate(_ data: [uint8]) throws -> [uint8]`: ParsePaletteUpdate returns the palette as 256 RGB triples (red first).
- `func ParsePointerPosition(_ data: [uint8]) throws -> (int, int)`: ParsePointerPosition decodes TS_POINTERPOSATTRIBUTE.
- `func ParseCachedPointer(_ data: [uint8]) throws -> int`: ParseCachedPointer decodes TS_CACHEDPOINTERATTRIBUTE.
- `func ParseColorPointer(_ data: [uint8]) throws -> PointerImage`: ParseColorPointer decodes TS_COLORPOINTERATTRIBUTE (24bpp XOR mask).
- `func ParseNewPointer(_ data: [uint8]) throws -> PointerImage`: ParseNewPointer decodes TS_FP_POINTERATTRIBUTE (xorBpp then a colour pointer).
- `func ParseLargePointer(_ data: [uint8]) throws -> PointerImage`: ParseLargePointer decodes TS_FP_LARGEPOINTERATTRIBUTE.

Part of the [`remote`](https://github.com/vertex-language/remote) repository.
