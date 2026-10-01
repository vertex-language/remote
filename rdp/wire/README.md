# remote/rdp/wire

Has the ASN.1 PER (T.124/GCC) and BER (T.125/MCS) encoding primitives the RDP connection sequence needs, over encoding/binary cursors.

```vertex
import "remote/rdp/wire"
```

## Types

- **`WireError`** (enum)

## Functions

- `func PERWriteLength(_ w: inout binary.Writer, _ length: int)`: PERWriteLength writes a PER length determinant (1 or 2 bytes).
- `func PERReadLength(_ r: inout binary.Reader) throws -> int`: PERReadLength reads a PER length determinant.
- `func PERReadU16(_ r: inout binary.Reader, min: uint16) throws -> uint16`: PERReadU16 reads an integer stored as a u16 offset from `min`.
- `func PERReadEnum(_ r: inout binary.Reader) throws -> uint8`: PERReadEnum reads a 1-byte ENUMERATED.
- `func PERWriteChoice(_ w: inout binary.Writer, _ choice: uint8)`
- `func PERWriteSelection(_ w: inout binary.Writer, _ sel: uint8)`
- `func PERWriteNumberOfSets(_ w: inout binary.Writer, _ n: uint8)`
- `func PERWriteEnum(_ w: inout binary.Writer, _ e: uint8)`
- `func PERWriteU16(_ w: inout binary.Writer, _ value: uint16, min: uint16)`: PERWriteU16 writes an integer offset from `min` (INTEGER (min..65535)).
- `func PERWriteObjectID(_ w: inout binary.Writer, _ oid: [uint8])`: PERWriteObjectID writes the GCC object identifier {0 0 20 124 0 1}.
- and 14 more

Part of the [`remote`](https://github.com/vertex-language/remote) repository.
