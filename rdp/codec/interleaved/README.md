# remote/rdp/codec/interleaved

Decodes the Interleaved RLE bitmap codec ([MS-RDPBCGR] 2.2.9.1.1.3.1.2.4 and the pseudo-code in 3.1.9), which Windows uses for compressed bitmap updates at 8, 15, 16 and 24 bpp.

```vertex
import "remote/rdp/codec/interleaved"
```

## Types

- **`InterleavedError`** (enum): InterleavedError is a malformed or unsupported RLE stream.

## Functions

- `func Decode(_ src: [uint8], width: int, height: int, bpp: int) throws -> [uint8]`: Decode expands an RLE stream into width * height pixels of bpp bits each (8, 15, 16 or 24). Rows come out bottom-up, as encoded.

Part of the [`remote`](https://github.com/vertex-language/remote) repository.
