// Package wire has the ASN.1 PER (T.124/GCC) and BER (T.125/MCS) encoding
// primitives the RDP connection sequence needs, over encoding/binary
// cursors. These are the aligned-PER and BER subsets RDP uses, not general
// codecs.
package wire

import "encoding/binary"

// --- PER (Packed Encoding Rules, aligned) ---

/// PERWriteLength writes a PER length determinant (1 or 2 bytes).
public func PERWriteLength(_ w: inout binary.Writer, _ length: int) {
    if length > 0x7f {
        w.U16BE(uint16(truncatingIfNeeded: length) | 0x8000)
    } else {
        w.U8(uint8(truncatingIfNeeded: length))
    }
}

/// PERReadLength reads a PER length determinant.
public func PERReadLength(_ r: inout binary.Reader) throws -> int {
    let a = try r.U8()
    if (a & 0x80) != 0 {
        let b = try r.U8()
        return ((int(a) & 0x7f) << 8) | int(b)
    }
    return int(a)
}

/// PERReadU16 reads an integer stored as a u16 offset from `min`.
public func PERReadU16(_ r: inout binary.Reader, min: uint16) throws -> uint16 {
    return (try r.U16BE()) &+ min
}

/// PERReadEnum reads a 1-byte ENUMERATED.
public func PERReadEnum(_ r: inout binary.Reader) throws -> uint8 {
    return try r.U8()
}

public func PERWriteChoice(_ w: inout binary.Writer, _ choice: uint8) { w.U8(choice) }
public func PERWriteSelection(_ w: inout binary.Writer, _ sel: uint8) { w.U8(sel) }
public func PERWriteNumberOfSets(_ w: inout binary.Writer, _ n: uint8) { w.U8(n) }
public func PERWriteEnum(_ w: inout binary.Writer, _ e: uint8) { w.U8(e) }

/// PERWriteU16 writes an integer offset from `min` (INTEGER (min..65535)).
public func PERWriteU16(_ w: inout binary.Writer, _ value: uint16, min: uint16) {
    w.U16BE(value &- min)
}

/// PERWriteObjectID writes the GCC object identifier {0 0 20 124 0 1}.
public func PERWriteObjectID(_ w: inout binary.Writer, _ oid: [uint8]) {
    PERWriteLength(&w, oid.count - 1)
    w.U8(oid[0] * 40 + oid[1])
    var i = 2
    while i < oid.count { w.U8(oid[i]); i += 1 }
}

/// PERWriteOctetString writes an octet string with a length offset by min.
public func PERWriteOctetString(_ w: inout binary.Writer, _ s: [uint8], min: int) {
    PERWriteLength(&w, s.count - min)
    w.Append(s)
}

/// PERWriteNumericString packs a numeric string (2 digits per byte).
public func PERWriteNumericString(_ w: inout binary.Writer, _ s: [uint8], min: int) {
    PERWriteLength(&w, s.count - min)
    var i = 0
    while i < s.count {
        let first = (s[i] - 0x30) % 10
        let second = (i + 1 < s.count) ? (s[i+1] - 0x30) % 10 : 0
        w.U8((first << 4) | second)
        i += 2
    }
}

// --- BER (Basic Encoding Rules) for MCS ---

let berClassApplication: uint8 = 0x40
let berClassUniversal: uint8 = 0x00
let berPcConstruct: uint8 = 0x20
let berPcPrimitive: uint8 = 0x00
let berTagMask: uint8 = 0x1F

let berTagBoolean: uint8 = 1
let berTagInteger: uint8 = 2
let berTagOctetString: uint8 = 4
let berTagEnumerated: uint8 = 10
let berTagSequence: uint8 = 16

/// BERWriteLength writes a BER definite length.
public func BERWriteLength(_ w: inout binary.Writer, _ length: int) {
    if length > 0xff {
        w.U8(0x82)
        w.U16BE(uint16(truncatingIfNeeded: length))
    } else if length > 0x7f {
        w.U8(0x81)
        w.U8(uint8(truncatingIfNeeded: length))
    } else {
        w.U8(uint8(truncatingIfNeeded: length))
    }
}

public func BERReadLength(_ r: inout binary.Reader) throws -> int {
    let first = try r.U8()
    if (first & 0x80) == 0 { return int(first) }
    let n = int(first & 0x7f)
    var len = 0
    var i = 0
    while i < n { len = (len << 8) | int(try r.U8()); i += 1 }
    return len
}

/// BERWriteApplicationTag writes an application-class constructed tag.
public func BERWriteApplicationTag(_ w: inout binary.Writer, _ tag: uint8, _ length: int) {
    if tag > 0x1e {
        w.U8(berClassApplication | berPcConstruct | berTagMask)
        w.U8(tag)
    } else {
        w.U8(berClassApplication | berPcConstruct | (berTagMask & tag))
    }
    BERWriteLength(&w, length)
}

public func BERReadApplicationTag(_ r: inout binary.Reader, _ tag: uint8) throws -> int {
    let id = try r.U8()
    if tag > 0x1e {
        if id != (berClassApplication | berPcConstruct | berTagMask) {
            throw wireError("unexpected BER application tag")
        }
        let _ = try r.U8()
    } else {
        if id != (berClassApplication | berPcConstruct | (berTagMask & tag)) {
            throw wireError("unexpected BER application tag \(id)")
        }
    }
    return try BERReadLength(&r)
}

func berUniversalTag(_ w: inout binary.Writer, _ tag: uint8, _ pc: uint8) {
    w.U8(berClassUniversal | pc | (berTagMask & tag))
}

public func BERWriteInteger(_ w: inout binary.Writer, _ value: uint32) {
    berUniversalTag(&w, berTagInteger, berPcPrimitive)
    if value < 0x80 {
        BERWriteLength(&w, 1); w.U8(uint8(truncatingIfNeeded: value))
    } else if value < 0x8000 {
        BERWriteLength(&w, 2); w.U16BE(uint16(truncatingIfNeeded: value))
    } else if value < 0x800000 {
        BERWriteLength(&w, 3)
        w.U8(uint8(truncatingIfNeeded: value >> 16))
        w.U16BE(uint16(truncatingIfNeeded: value))
    } else {
        BERWriteLength(&w, 4); w.U32BE(value)
    }
}

public func BERReadInteger(_ r: inout binary.Reader) throws -> uint32 {
    let id = try r.U8()
    if id != (berClassUniversal | berPcPrimitive | berTagInteger) {
        throw wireError("expected BER INTEGER")
    }
    let len = try BERReadLength(&r)
    var v: uint32 = 0
    var i = 0
    while i < len { v = (v << 8) | uint32(try r.U8()); i += 1 }
    return v
}

public func BERWriteBool(_ w: inout binary.Writer, _ value: bool) {
    berUniversalTag(&w, berTagBoolean, berPcPrimitive)
    BERWriteLength(&w, 1)
    w.U8(value ? 0xff : 0x00)
}

public func BERWriteEnumerated(_ w: inout binary.Writer, _ value: uint8) {
    berUniversalTag(&w, berTagEnumerated, berPcPrimitive)
    BERWriteLength(&w, 1)
    w.U8(value)
}

public func BERReadEnumerated(_ r: inout binary.Reader) throws -> uint8 {
    let id = try r.U8()
    if id != (berClassUniversal | berPcPrimitive | berTagEnumerated) {
        throw wireError("expected BER ENUMERATED")
    }
    let _ = try BERReadLength(&r)
    return try r.U8()
}

public func BERWriteOctetStringTag(_ w: inout binary.Writer, _ length: int) {
    berUniversalTag(&w, berTagOctetString, berPcPrimitive)
    BERWriteLength(&w, length)
}

public func BERWriteOctetString(_ w: inout binary.Writer, _ s: [uint8]) {
    BERWriteOctetStringTag(&w, s.count)
    w.Append(s)
}

public func BERReadOctetString(_ r: inout binary.Reader) throws -> [uint8] {
    let id = try r.U8()
    if id != (berClassUniversal | berPcPrimitive | berTagOctetString) {
        throw wireError("expected BER OCTET STRING")
    }
    let len = try BERReadLength(&r)
    return try r.Bytes(len)
}

public enum WireError: Error {
    case decode(string)
    public var Message: string {
        switch self {
        case .decode(let s): return "wire: \(s)"
        }
    }
}

func wireError(_ s: string) -> WireError { return WireError.decode(s) }
