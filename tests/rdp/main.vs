package main

import "encoding/binary"
import "remote/rdp/x224"

var failures = 0
func check(_ ok: bool, _ msg: string) {
    if ok { print("ok    \(msg)") } else { print("FAIL  \(msg)"); failures += 1 }
}

func testEncodeDecode() {
    print("=== x224: encode/decode ===")
    let req = x224.ConnectionRequest(
        cookie: "testuser",
        requestedProtocols: x224.SecurityProtocol.SSL | x224.SecurityProtocol.Hybrid | x224.SecurityProtocol.HybridEx)
    let pdu = req.Encode()
    check(pdu[0] == 0x03 && pdu[1] == 0x00, "TPKT header")
    let total = (int(pdu[2]) << 8) | int(pdu[3])
    check(total == pdu.count, "TPKT length matches")
    check(pdu[5] == 0xE0, "X.224 Connection Request code")

    // Round-trip a synthetic Connection Confirm from a Windows server:
    // the exact 19 bytes our live probe received (HYBRID_EX, flags 0x1f).
    let confirm: [uint8] = [0x03,0x00,0x00,0x13,0x0e,0xd0,0x00,0x00,0x12,0x34,0x00,
                            0x02,0x1f,0x08,0x00,0x08,0x00,0x00,0x00]
    do {
        let cc = try x224.ConnectionConfirm.Parse(confirm)
        check(cc.SelectedProtocol == x224.SecurityProtocol.HybridEx, "selected HYBRID_EX")
        check((cc.Flags & x224.NegotiationResponseFlag.DynVCGFXProtocolSupported) != 0, "GFX flag set")
        check((cc.Flags & x224.NegotiationResponseFlag.RestrictedAdminModeSupported) != 0, "restricted admin flag")
    } catch {
        check(false, "parse confirm threw \(error)")
    }

    // A negotiation failure PDU (HYBRID_REQUIRED_BY_SERVER = 5).
    let failure: [uint8] = [0x03,0x00,0x00,0x13,0x0e,0xd0,0x00,0x00,0x12,0x34,0x00,
                            0x03,0x00,0x08,0x00,0x05,0x00,0x00,0x00]
    var threw = false
    do { let _ = try x224.ConnectionConfirm.Parse(failure) }
    catch let e as x224.X224Error {
        if case .negotiationFailed(let code) = e { threw = code == .hybridRequiredByServer }
    } catch {}
    check(threw, "negotiation failure surfaces the code")
}

func testFrameSplitter() {
    print("=== x224: frame splitter ===")
    var fs = x224.FrameSplitter()
    // Two slow-path frames, delivered split across two feeds.
    let a = x224.WrapData([0xAA, 0xBB])
    let b = x224.WrapData([0xCC])
    var stream: [uint8] = []
    stream.append(contentsOf: a); stream.append(contentsOf: b)
    // Feed 3 bytes first (partial), then the rest.
    fs.Feed([stream[0], stream[1], stream[2]])
    do {
        let none = try fs.Next()
        check(none == nil, "partial frame yields nil")
    } catch { check(false, "partial threw \(error)") }
    var rest: [uint8] = []
    var i = 3
    while i < stream.count { rest.append(stream[i]); i += 1 }
    fs.Feed(rest)
    do {
        if case .slowPath(let f1)? = try fs.Next() {
            let p1 = try x224.UnwrapData(f1)
            check(p1.count == 2 && p1[0] == 0xAA && p1[1] == 0xBB, "first payload")
        } else { check(false, "expected first slow-path frame") }
        if case .slowPath(let f2)? = try fs.Next() {
            let p2 = try x224.UnwrapData(f2)
            check(p2.count == 1 && p2[0] == 0xCC, "second payload")
        } else { check(false, "expected second slow-path frame") }
        check((try fs.Next()) == nil, "no more frames")
    } catch { check(false, "splitter threw \(error)") }

    // A fast-path frame (byte0 low bits 0), 2-byte short length.
    fs.Feed([0x00, 0x05, 0x11, 0x22, 0x33])
    do {
        if case .fastPath(let f)? = try fs.Next() {
            check(f.count == 5, "fast-path length")
        } else { check(false, "expected fast-path frame") }
    } catch { check(false, "fast-path threw \(error)") }
}

func main() -> int32 {
    testEncodeDecode()
    testFrameSplitter()
    if failures > 0 { print("\(failures) FAILURES"); return 1 }
    print("all x224 tests passed")
    return 0
}
