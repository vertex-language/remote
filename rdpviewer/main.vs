// rdpviewer: a remote desktop in a window. Connects to a Windows host
// with remote/rdp, shows its desktop, and sends it the keyboard and mouse.
//
//     rdpviewer <file.rdp | host[:port]> [user] [--size WxH] [--cmd-as-win] [--no-hidpi]
//
// --size is in points; on a Retina display the desktop is twice that in
// pixels with Windows' UI at 200%, unless --no-hidpi.
//
// The password comes from $RDP_PASSWORD, or is asked for on the terminal.
// Command is sent as Control (so Cmd-C copies) unless --cmd-as-win makes
// it the Windows key.
package main

import "ui/window"
import "remote/rdp"
import "fs"

@_silgen_name("getpass")
func c_getpass(_ prompt: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("getenv")
func c_getenv(_ name: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

// cBytes copies a NUL-terminated C string's bytes.
func cBytes(_ p: UnsafeMutablePointer<CChar>?) -> [uint8] {
    var out: [uint8] = []
    guard let s = p else { return out }
    var i = 0
    while true {
        let c = (s + i).pointee
        if c == 0 { break }
        out.append(uint8(bitPattern: c))
        i += 1
    }
    return out
}

func readPassword(_ prompt: string) -> [uint8] {
    let env = "RDP_PASSWORD".withCString { k in cBytes(c_getenv(k)) }
    if env.count > 0 { return env }
    return prompt.withCString { p in cBytes(c_getpass(p)) }
}

/// Options is what the command line asked for.
struct Options {
    var address: string = ""
    var user: string = ""
    var domain: string = ""
    var width: int = 1280
    var height: int = 800
    var cmdAsWin: bool = false
    var noScale: bool = false
}

func parseSize(_ s: string, _ o: inout Options) -> bool {
    var w = 0
    var h = 0
    var seenX = false
    for c in s.utf8 {
        if c == 120 || c == 88 { seenX = true; continue }   // 'x' / 'X'
        if c < 48 || c > 57 { return false }
        if seenX { h = h * 10 + int(c - 48) } else { w = w * 10 + int(c - 48) }
    }
    if w < 200 || h < 200 || w > 8192 || h > 8192 { return false }
    o.width = w
    o.height = h
    return true
}

func parseArgs() -> Options? {
    let args = CommandLine.arguments
    var o = Options()
    var positional: [string] = []
    var i = 1
    while i < args.count {
        let a = args[i]
        if a == "--cmd-as-win" {
            o.cmdAsWin = true
        } else if a == "--no-hidpi" {
            o.noScale = true
        } else if a == "--size" && i + 1 < args.count {
            if !parseSize(args[i + 1], &o) { return nil }
            i += 1
        } else {
            positional.append(a)
        }
        i += 1
    }
    if positional.count < 1 { return nil }
    let target = positional[0]
    if target.hasSuffix(".rdp") {
        guard let bytes = try? fs.ReadFile(fs.Path(target)) else {
            print("rdpviewer: cannot read \(target)")
            return nil
        }
        let f = rdp.ParseFile(bytes)
        o.address = f.Address
        o.user = f.Username
        o.domain = f.Domain
        if f.DesktopWidth >= 200 && f.DesktopHeight >= 200 {
            o.width = f.DesktopWidth
            o.height = f.DesktopHeight
        }
    } else {
        o.address = target
    }
    if positional.count > 1 { o.user = positional[1] }
    if o.address.isEmpty || o.user.isEmpty { return nil }
    return o
}

/// Viewer ties one window to one session: a task pumps the session's
/// events into the framebuffer, and the window's events become input.
/// It is @MainActor, as window code must be: unannotated async code runs
/// on the worker pool, and AppKit called from a worker corrupts memory.
@MainActor
final class Viewer {
    let win: window.Window
    let cmdAsWin: bool
    let address: string
    var config: rdp.Config
    // Set once connected; nil while connecting.
    var session: rdp.Session? = nil
    var input: rdp.Input? = nil
    // Device pixels per point: the desktop is this many times the
    // window's size in points, and Windows scales its UI to match.
    let scale: float32

    var dirty: bool = true
    var frameRequested: bool = false
    var ended: string = ""

    // What the server believes is held down.
    var shift: bool = false
    var control: bool = false
    var alt: bool = false
    var meta: bool = false
    var capsLock: bool = false
    var pressed: [window.KeyCode] = []
    var buttons: [rdp.MouseButton] = []

    var pointerX: int = 0
    var pointerY: int = 0
    var wheelY: float32 = 0
    var wheelX: float32 = 0

    init(win: window.Window, address: string, config: rdp.Config, scale: float32, cmdAsWin: bool) {
        self.win = win
        self.address = address
        self.config = config
        self.scale = scale
        self.cmdAsWin = cmdAsWin
    }

    func requestFrame() {
        if frameRequested { return }
        frameRequested = true
        win.RequestFrame()
    }

    /// pump connects, then runs on its own task until the session ends.
    func pump() async {
        let s: rdp.Session
        do {
            s = try await rdp.Connect(address, config: config)
        } catch let e as rdp.RdpError {
            ended = e.Message
            requestFrame()
            return
        } catch {
            ended = "\(error)"
            requestFrame()
            return
        }
        session = s
        input = s.Input
        print("rdpviewer: connected, desktop \(s.Framebuffer.Width)x\(s.Framebuffer.Height)")
        win.SetTitle("\(address) — Remote Desktop")
        while true {
            var event: rdp.Event?
            do {
                event = try await s.NextEvent()
            } catch {
                ended = "\(error)"
                requestFrame()
                return
            }
            guard let e = event else {
                if ended.isEmpty { ended = "session ended" }
                requestFrame()
                return
            }
            switch e {
            case .frame(_):
                dirty = true
                requestFrame()
            case .resized(let w, let h):
                print("rdpviewer: desktop is now \(w)x\(h)")
                dirty = true
                requestFrame()
            case .logonComplete:
                print("rdpviewer: logged on")
            case .pointer(let c):
                if c.Width > 0 && c.Height > 0 {
                    try? win.SetCursorImage(c.Pixels, width: int32(c.Width), height: int32(c.Height),
                                            hotX: int32(c.HotX), hotY: int32(c.HotY), scale: scale)
                }
            case .pointerHidden:
                win.SetCursor(.hidden)
            case .pointerDefault:
                win.SetCursor(.arrow)
            case .disconnected(let reason):
                ended = reason
                requestFrame()
                return
            default:
                break
            }
        }
    }

    func present() {
        guard let s = session else { return }
        let fb = s.Framebuffer
        if fb.Width <= 0 || fb.Height <= 0 { return }
        do {
            try win.Surface().Present(fb.Pixels, size: window.PixelSize(int32(fb.Width), int32(fb.Height)))
        } catch {
            print("rdpviewer: present: \(error)")
        }
    }

    // desktop maps a window point to a desktop pixel. The framebuffer is
    // stretched over the whole content area.
    func desktop(_ p: window.Point) -> (int, int) {
        let size = win.Size()
        guard let s = session else { return (0, 0) }
        let fb = s.Framebuffer
        if size.Width <= 0 || size.Height <= 0 { return (0, 0) }
        var x = int(p.X * float32(fb.Width) / size.Width)
        var y = int(p.Y * float32(fb.Height) / size.Height)
        if x < 0 { x = 0 }
        if y < 0 { y = 0 }
        if x >= fb.Width { x = fb.Width - 1 }
        if y >= fb.Height { y = fb.Height - 1 }
        return (x, y)
    }

    /// handle takes one window event; false once the viewer should close.
    func handle(_ e: window.Event) async -> bool {
        if case .closeRequested = e { return false }
        guard let input = input else {
            // Connecting: only frames matter, to report a failure.
            if case .frame(_) = e {
                frameRequested = false
                if !ended.isEmpty {
                    print("rdpviewer: \(ended)")
                    return false
                }
            }
            return true
        }
        switch e {
        case .closeRequested:
            return false
        case .frame(_):
            frameRequested = false
            if !ended.isEmpty {
                print("rdpviewer: disconnected: \(ended)")
                return false
            }
            if dirty {
                dirty = false
                present()
            }
        case .focusChanged(let focused):
            if focused {
                try? await input.Sync(capsLock: capsLock, numLock: false, scrollLock: false)
            } else {
                await releaseAll()
            }
        case .modifiersChanged(let m):
            await modifiers(m)
        case .keyDown(let k):
            if let sc = scancode(k.Code) {
                if !pressed.contains(k.Code) { pressed.append(k.Code) }
                try? await input.Key(sc, down: true)
            }
        case .keyUp(let k):
            if let sc = scancode(k.Code) {
                var i = 0
                while i < pressed.count { if pressed[i] == k.Code { pressed.remove(at: i) } else { i += 1 } }
                try? await input.Key(sc, down: false)
            }
        case .pointerMoved(let p):
            let (x, y) = desktop(p.Position)
            if x != pointerX || y != pointerY {
                pointerX = x
                pointerY = y
                try? await input.Move(x: x, y: y)
            }
        case .pointerDown(let p, let b):
            let (x, y) = desktop(p.Position)
            pointerX = x
            pointerY = y
            if let mb = mouseButton(b) {
                if !buttons.contains(mb) { buttons.append(mb) }
                try? await input.Button(mb, down: true, x: x, y: y)
            }
        case .pointerUp(let p, let b):
            let (x, y) = desktop(p.Position)
            pointerX = x
            pointerY = y
            if let mb = mouseButton(b) {
                var i = 0
                while i < buttons.count { if buttons[i] == mb { buttons.remove(at: i) } else { i += 1 } }
                try? await input.Button(mb, down: false, x: x, y: y)
            }
        case .scrolled(let s):
            // Windows scrolls 120 units a notch, three lines of it: a line
            // is 40 units, and a trackpad point about 2.
            let unit: float32 = s.Precise ? 2 : 40
            wheelY += s.Delta.Y * unit
            wheelX += s.Delta.X * unit
            let v = int(wheelY)
            let h = -int(wheelX)
            wheelY -= float32(v)
            wheelX += float32(h)
            if v != 0 || h != 0 {
                try? await input.Wheel(vertical: v, horizontal: h, x: pointerX, y: pointerY)
            }
        default:
            break
        }
        return true
    }

    // modifiers brings the server's modifier keys in line with the Mac's.
    func modifiers(_ m: window.Modifiers) async {
        guard let input = input else { return }
        let wantShift = m.Shift
        let wantControl = m.Control || (m.Meta && !cmdAsWin)
        let wantAlt = m.Alt
        let wantMeta = m.Meta && cmdAsWin
        if wantShift != shift {
            shift = wantShift
            try? await input.Key(rdp.Scancode(0x2A), down: shift)
        }
        if wantControl != control {
            control = wantControl
            try? await input.Key(rdp.Scancode(0x1D), down: control)
        }
        if wantAlt != alt {
            alt = wantAlt
            try? await input.Key(rdp.Scancode(0x38), down: alt)
        }
        if wantMeta != meta {
            meta = wantMeta
            try? await input.Key(rdp.Scancode(0x5B, extended: true), down: meta)
        }
        if m.CapsLock != capsLock {
            capsLock = m.CapsLock
            try? await input.Sync(capsLock: capsLock, numLock: false, scrollLock: false)
        }
    }

    // releaseAll lets go of everything, so keys held when the window lost
    // focus (Cmd-Tab) don't stay stuck down on the server.
    func releaseAll() async {
        guard let input = input else { return }
        for k in pressed {
            if let sc = scancode(k) { try? await input.Key(sc, down: false) }
        }
        pressed = []
        for b in buttons {
            try? await input.Button(b, down: false, x: pointerX, y: pointerY)
        }
        buttons = []
        var none = window.Modifiers()
        none.CapsLock = capsLock
        await modifiers(none)
    }
}

func mouseButton(_ b: window.PointerButton) -> rdp.MouseButton? {
    switch b {
    case .primary: return .left
    case .secondary: return .right
    case .middle: return .middle
    default: return nil
    }
}

// scancode maps a key position to its scan code. Modifier keys arrive as
// modifiersChanged and are handled there.
func scancode(_ k: window.KeyCode) -> rdp.Scancode? {
    switch k {
    case .shiftLeft, .shiftRight, .controlLeft, .controlRight, .altLeft, .altRight,
         .metaLeft, .metaRight, .capsLock, .unknown:
        return nil
    default:
        return rdp.ScancodeForCode(codeName(k))
    }
}

// codeName is a KeyCode's W3C KeyboardEvent.code name.
func codeName(_ k: window.KeyCode) -> string {
    switch k {
    case .a: return "KeyA"
    case .b: return "KeyB"
    case .c: return "KeyC"
    case .d: return "KeyD"
    case .e: return "KeyE"
    case .f: return "KeyF"
    case .g: return "KeyG"
    case .h: return "KeyH"
    case .i: return "KeyI"
    case .j: return "KeyJ"
    case .k: return "KeyK"
    case .l: return "KeyL"
    case .m: return "KeyM"
    case .n: return "KeyN"
    case .o: return "KeyO"
    case .p: return "KeyP"
    case .q: return "KeyQ"
    case .r: return "KeyR"
    case .s: return "KeyS"
    case .t: return "KeyT"
    case .u: return "KeyU"
    case .v: return "KeyV"
    case .w: return "KeyW"
    case .x: return "KeyX"
    case .y: return "KeyY"
    case .z: return "KeyZ"
    case .digit0: return "Digit0"
    case .digit1: return "Digit1"
    case .digit2: return "Digit2"
    case .digit3: return "Digit3"
    case .digit4: return "Digit4"
    case .digit5: return "Digit5"
    case .digit6: return "Digit6"
    case .digit7: return "Digit7"
    case .digit8: return "Digit8"
    case .digit9: return "Digit9"
    case .escape: return "Escape"
    case .enter: return "Enter"
    case .tab: return "Tab"
    case .space: return "Space"
    case .backspace: return "Backspace"
    case .delete: return "Delete"
    case .arrowLeft: return "ArrowLeft"
    case .arrowRight: return "ArrowRight"
    case .arrowUp: return "ArrowUp"
    case .arrowDown: return "ArrowDown"
    case .home: return "Home"
    case .end: return "End"
    case .pageUp: return "PageUp"
    case .pageDown: return "PageDown"
    case .f1: return "F1"
    case .f2: return "F2"
    case .f3: return "F3"
    case .f4: return "F4"
    case .f5: return "F5"
    case .f6: return "F6"
    case .f7: return "F7"
    case .f8: return "F8"
    case .f9: return "F9"
    case .f10: return "F10"
    case .f11: return "F11"
    case .f12: return "F12"
    case .minus: return "Minus"
    case .equal: return "Equal"
    case .bracketLeft: return "BracketLeft"
    case .bracketRight: return "BracketRight"
    case .backslash: return "Backslash"
    case .semicolon: return "Semicolon"
    case .quote: return "Quote"
    case .backquote: return "Backquote"
    case .comma: return "Comma"
    case .period: return "Period"
    case .slash: return "Slash"
    default: return ""
    }
}

@MainActor
func main() async -> int32 {
    guard let o = parseArgs() else {
        print("usage: rdpviewer <file.rdp | host[:port]> [user] [--size WxH] [--cmd-as-win] [--no-hidpi]")
        print("       the password comes from $RDP_PASSWORD, or is asked for")
        return 2
    }
    let password = readPassword("Password for \(o.user)@\(o.address): ")

    var options = window.Options()
    options.Resizable = false
    let win: window.Window
    do {
        win = try window.Create(title: "\(o.address) — connecting…",
                                size: window.Size(float32(o.width), float32(o.height)), options: options)
    } catch {
        print("rdpviewer: cannot create a window: \(error)")
        return 1
    }
    // A Retina window gets a desktop in its device pixels, with Windows
    // scaling its UI to match, so text is sharp rather than stretched.
    var scale = win.ScaleFactor()
    if o.noScale || scale < 1 { scale = 1 }
    var config = rdp.Config(username: o.user, password: password, domain: o.domain,
                            width: uint16(float32(o.width) * scale), height: uint16(float32(o.height) * scale))
    config.DesktopScale = uint32(scale * 100)

    print("rdpviewer: connecting to \(o.address) as \(o.user)…")
    let viewer = Viewer(win: win, address: o.address, config: config, scale: scale, cmdAsWin: o.cmdAsWin)
    let _ = Task {
        await viewer.pump()
    }

    while let event = await win.WaitEvent() {
        if !(await viewer.handle(event)) {
            break
        }
    }
    await viewer.releaseAll()
    if let s = viewer.session { s.Close() }
    win.Close()
    return 0
}
