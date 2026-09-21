// Keyboard and mouse input, sent as fast-path input events ([MS-RDPBCGR]
// 2.2.8.1.2). We advertise INPUT_FLAG_FASTPATH_INPUT2, which every server
// since Windows Server 2008 honours, so slow-path Input Event PDUs are
// never needed.
package rdp

import "encoding/binary"

// Fast-path input event codes (the top three bits of the event header).
let fpEventScancode: uint8 = 0
let fpEventMouse: uint8 = 1
let fpEventMouseX: uint8 = 2
let fpEventSync: uint8 = 3
let fpEventUnicode: uint8 = 4

let kbdFlagsRelease: uint8 = 0x01
let kbdFlagsExtended: uint8 = 0x02

/// Pointer flags for mouse events ([MS-RDPBCGR] 2.2.8.1.1.3.1.1.3).
public struct PointerFlags {
    public static let Move: uint16 = 0x0800
    public static let Down: uint16 = 0x8000
    public static let Button1: uint16 = 0x1000    // left
    public static let Button2: uint16 = 0x2000    // right
    public static let Button3: uint16 = 0x4000    // middle
    public static let Wheel: uint16 = 0x0200
    public static let HWheel: uint16 = 0x0400
    public static let WheelNegative: uint16 = 0x0100
}

/// MouseButton names the buttons Input.Button takes.
public enum MouseButton {
    case left
    case right
    case middle
    case back
    case forward
}

/// Scancode is a key's scan code set 1 make code, with the E0 prefix
/// folded in as Extended.
public struct Scancode {
    // Low byte: the make code; 0x100: extended. One word, not a code and
    // a bool, so that Scancode? lowers (vsc gap: optionals of structs
    // with spare bits).
    var value: uint16

    public init(_ code: uint8, extended: bool = false) {
        self.value = uint16(code) | (extended ? 0x100 : 0)
    }

    public var Code: uint8 { return uint8(truncatingIfNeeded: value) }
    public var Extended: bool { return value & 0x100 != 0 }
}

/// Input sends keyboard and mouse events. It is a small value around the
/// connection's Sender, safe to copy to and use from another task than
/// the one reading the session.
public struct Input {
    var out: Sender

    init(out: Sender) {
        self.out = out
    }

    /// Key presses or releases a key by scan code.
    public func Key(_ key: Scancode, down: bool) async throws {
        var flags: uint8 = down ? 0 : kbdFlagsRelease
        if key.Extended { flags |= kbdFlagsExtended }
        try await send([eventHeader(fpEventScancode, flags), key.Code])
    }

    /// Unicode types a UTF-16 code unit the keyboard layout can't reach.
    public func Unicode(_ unit: uint16, down: bool) async throws {
        try await send([eventHeader(fpEventUnicode, down ? 0 : kbdFlagsRelease),
                        uint8(truncatingIfNeeded: unit), uint8(truncatingIfNeeded: unit >> 8)])
    }

    /// Text types a string as Unicode key presses.
    public func Text(_ text: string) async throws {
        let le = binary.EncodeUTF16LE(text)
        var i = 0
        while i + 1 < le.count {
            let unit = uint16(le[i]) | (uint16(le[i + 1]) << 8)
            try await Unicode(unit, down: true)
            try await Unicode(unit, down: false)
            i += 2
        }
    }

    /// Move puts the pointer at desktop pixel (x, y).
    public func Move(x: int, y: int) async throws {
        try await mouse(PointerFlags.Move, x, y)
    }

    /// Button presses or releases a mouse button at (x, y).
    public func Button(_ b: MouseButton, down: bool, x: int, y: int) async throws {
        switch b {
        case .left: try await mouse(PointerFlags.Button1 | (down ? PointerFlags.Down : 0), x, y)
        case .right: try await mouse(PointerFlags.Button2 | (down ? PointerFlags.Down : 0), x, y)
        case .middle: try await mouse(PointerFlags.Button3 | (down ? PointerFlags.Down : 0), x, y)
        case .back, .forward:
            // Extended mouse event: PTRXFLAGS_BUTTON1/2 (0x0001/0x0002), DOWN 0x8000.
            var flags: uint16 = b == .back ? 0x0001 : 0x0002
            if down { flags |= 0x8000 }
            var ev: [uint8] = [eventHeader(fpEventMouseX, 0)]
            appendU16(&ev, flags)
            appendU16(&ev, clampCoord(x))
            appendU16(&ev, clampCoord(y))
            try await send(ev)
        }
    }

    /// Wheel scrolls by rotation units (120 per notch; positive is up or
    /// right). Large values go out as several events.
    public func Wheel(vertical: int, horizontal: int, x: int, y: int) async throws {
        var v = vertical
        while v != 0 {
            let step = v > 255 ? 255 : (v < -255 ? -255 : v)
            try await wheelEvent(PointerFlags.Wheel, step, x, y)
            v -= step
        }
        var h = horizontal
        while h != 0 {
            let step = h > 255 ? 255 : (h < -255 ? -255 : h)
            // Windows' horizontal wheel is positive to the right.
            try await wheelEvent(PointerFlags.HWheel, step, x, y)
            h -= step
        }
    }

    /// Sync tells the server which toggle keys are on, as on focus gain.
    public func Sync(capsLock: bool, numLock: bool, scrollLock: bool) async throws {
        var flags: uint8 = 0
        if scrollLock { flags |= 0x01 }
        if numLock { flags |= 0x02 }
        if capsLock { flags |= 0x04 }
        try await send([eventHeader(fpEventSync, flags)])
    }

    func wheelEvent(_ kind: uint16, _ amount: int, _ x: int, _ y: int) async throws {
        // A 9-bit two's complement rotation: the negative flag is bit 8.
        var flags = kind
        if amount < 0 {
            flags |= PointerFlags.WheelNegative | uint16(truncatingIfNeeded: (256 + amount) & 0xFF)
        } else {
            flags |= uint16(truncatingIfNeeded: amount & 0xFF)
        }
        try await mouse(flags, x, y)
    }

    func mouse(_ flags: uint16, _ x: int, _ y: int) async throws {
        var ev: [uint8] = [eventHeader(fpEventMouse, 0)]
        appendU16(&ev, flags)
        appendU16(&ev, clampCoord(x))
        appendU16(&ev, clampCoord(y))
        try await send(ev)
    }

    // send wraps events in a fast-path input PDU: header (action 0,
    // event count in bits 2-5, no encryption flags), then the length.
    func send(_ events: [uint8]) async throws {
        try await out.Send(fastPathInputPDU(events, count: 1))
    }
}

func eventHeader(_ code: uint8, _ flags: uint8) -> uint8 {
    return (code << 5) | (flags & 0x1F)
}

func clampCoord(_ v: int) -> uint16 {
    if v < 0 { return 0 }
    if v > 0x7FFF { return 0x7FFF }
    return uint16(v)
}

func appendU16(_ b: inout [uint8], _ v: uint16) {
    b.append(uint8(truncatingIfNeeded: v))
    b.append(uint8(truncatingIfNeeded: v >> 8))
}

/// fastPathInputPDU frames count events (at most 15) as one PDU.
func fastPathInputPDU(_ events: [uint8], count: int) -> [uint8] {
    var out: [uint8] = [uint8(truncatingIfNeeded: (count & 0x0F) << 2)]
    // Length includes the header and the length field itself: one byte
    // below 0x80, else two with the top bit set.
    let short = 2 + events.count
    if short < 0x80 {
        out.append(uint8(short))
    } else {
        let long = 3 + events.count
        out.append(uint8(0x80 | ((long >> 8) & 0x7F)))
        out.append(uint8(long & 0xFF))
    }
    out.append(contentsOf: events)
    return out
}

/// ScancodeForCode maps a W3C KeyboardEvent.code name ("KeyA", "Enter",
/// "ArrowLeft", "NumpadEnter", …) to its scan code, or nil for a code
/// with none.
public func ScancodeForCode(_ code: string) -> Scancode? {
    switch code {
    case "Escape": return Scancode(0x01)
    case "Digit1": return Scancode(0x02)
    case "Digit2": return Scancode(0x03)
    case "Digit3": return Scancode(0x04)
    case "Digit4": return Scancode(0x05)
    case "Digit5": return Scancode(0x06)
    case "Digit6": return Scancode(0x07)
    case "Digit7": return Scancode(0x08)
    case "Digit8": return Scancode(0x09)
    case "Digit9": return Scancode(0x0A)
    case "Digit0": return Scancode(0x0B)
    case "Minus": return Scancode(0x0C)
    case "Equal": return Scancode(0x0D)
    case "Backspace": return Scancode(0x0E)
    case "Tab": return Scancode(0x0F)
    case "KeyQ": return Scancode(0x10)
    case "KeyW": return Scancode(0x11)
    case "KeyE": return Scancode(0x12)
    case "KeyR": return Scancode(0x13)
    case "KeyT": return Scancode(0x14)
    case "KeyY": return Scancode(0x15)
    case "KeyU": return Scancode(0x16)
    case "KeyI": return Scancode(0x17)
    case "KeyO": return Scancode(0x18)
    case "KeyP": return Scancode(0x19)
    case "BracketLeft": return Scancode(0x1A)
    case "BracketRight": return Scancode(0x1B)
    case "Enter": return Scancode(0x1C)
    case "ControlLeft": return Scancode(0x1D)
    case "KeyA": return Scancode(0x1E)
    case "KeyS": return Scancode(0x1F)
    case "KeyD": return Scancode(0x20)
    case "KeyF": return Scancode(0x21)
    case "KeyG": return Scancode(0x22)
    case "KeyH": return Scancode(0x23)
    case "KeyJ": return Scancode(0x24)
    case "KeyK": return Scancode(0x25)
    case "KeyL": return Scancode(0x26)
    case "Semicolon": return Scancode(0x27)
    case "Quote": return Scancode(0x28)
    case "Backquote": return Scancode(0x29)
    case "ShiftLeft": return Scancode(0x2A)
    case "Backslash": return Scancode(0x2B)
    case "KeyZ": return Scancode(0x2C)
    case "KeyX": return Scancode(0x2D)
    case "KeyC": return Scancode(0x2E)
    case "KeyV": return Scancode(0x2F)
    case "KeyB": return Scancode(0x30)
    case "KeyN": return Scancode(0x31)
    case "KeyM": return Scancode(0x32)
    case "Comma": return Scancode(0x33)
    case "Period": return Scancode(0x34)
    case "Slash": return Scancode(0x35)
    case "ShiftRight": return Scancode(0x36)
    case "NumpadMultiply": return Scancode(0x37)
    case "AltLeft": return Scancode(0x38)
    case "Space": return Scancode(0x39)
    case "CapsLock": return Scancode(0x3A)
    case "F1": return Scancode(0x3B)
    case "F2": return Scancode(0x3C)
    case "F3": return Scancode(0x3D)
    case "F4": return Scancode(0x3E)
    case "F5": return Scancode(0x3F)
    case "F6": return Scancode(0x40)
    case "F7": return Scancode(0x41)
    case "F8": return Scancode(0x42)
    case "F9": return Scancode(0x43)
    case "F10": return Scancode(0x44)
    case "NumLock": return Scancode(0x45)
    case "ScrollLock": return Scancode(0x46)
    case "Numpad7": return Scancode(0x47)
    case "Numpad8": return Scancode(0x48)
    case "Numpad9": return Scancode(0x49)
    case "NumpadSubtract": return Scancode(0x4A)
    case "Numpad4": return Scancode(0x4B)
    case "Numpad5": return Scancode(0x4C)
    case "Numpad6": return Scancode(0x4D)
    case "NumpadAdd": return Scancode(0x4E)
    case "Numpad1": return Scancode(0x4F)
    case "Numpad2": return Scancode(0x50)
    case "Numpad3": return Scancode(0x51)
    case "Numpad0": return Scancode(0x52)
    case "NumpadDecimal": return Scancode(0x53)
    case "IntlBackslash": return Scancode(0x56)
    case "F11": return Scancode(0x57)
    case "F12": return Scancode(0x58)
    case "IntlRo": return Scancode(0x73)
    case "IntlYen": return Scancode(0x7D)
    case "NumpadEnter": return Scancode(0x1C, extended: true)
    case "ControlRight": return Scancode(0x1D, extended: true)
    case "NumpadDivide": return Scancode(0x35, extended: true)
    case "PrintScreen": return Scancode(0x37, extended: true)
    case "AltRight": return Scancode(0x38, extended: true)
    case "Home": return Scancode(0x47, extended: true)
    case "ArrowUp": return Scancode(0x48, extended: true)
    case "PageUp": return Scancode(0x49, extended: true)
    case "ArrowLeft": return Scancode(0x4B, extended: true)
    case "ArrowRight": return Scancode(0x4D, extended: true)
    case "End": return Scancode(0x4F, extended: true)
    case "ArrowDown": return Scancode(0x50, extended: true)
    case "PageDown": return Scancode(0x51, extended: true)
    case "Insert": return Scancode(0x52, extended: true)
    case "Delete": return Scancode(0x53, extended: true)
    case "MetaLeft": return Scancode(0x5B, extended: true)
    case "MetaRight": return Scancode(0x5C, extended: true)
    case "ContextMenu": return Scancode(0x5D, extended: true)
    default: return nil
    }
}

// inputFor exists because inside Session the property Input hides the type.
func inputFor(_ out: Sender) -> Input {
    return Input(out: out)
}
