# remote/rdp/codec/planar

Decodes the RDP 6.0 Bitmap Compressed Stream ([MS-RDPEGDI] 2.2.2.5.1, 3.1.9), which Windows uses for compressed bitmap updates at 32 bpp.

```vertex
import "remote/rdp/codec/planar"
```

## Types

- **`PlanarError`** (enum): PlanarError is a malformed planar stream.

## Functions

- `func Decode(_ src: [uint8], width: int, height: int) throws -> [uint8]`: Decode expands a planar stream for a width * height bitmap into width * height * 3 bytes of RGB.

Part of the [`remote`](https://github.com/vertex-language/remote) repository.
