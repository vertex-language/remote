// rdp-input drives a live desktop with keyboard and mouse input while
// another task pumps the session, the way rdpviewer does, then writes a
// screenshot to check the result: Notepad open with typed text in it.
//
//     rdp-input <host[:port]> <user> <password> [out.png]
package main

import "remote/rdp"
import "image"
import "image/png"
import "fs"
import "time"

final class Pump {
    let session: rdp.Session
    var frames: int = 0
    var logon: bool = false
    var ended: string = ""

    init(_ session: rdp.Session) {
        self.session = session
    }

    func run() async {
        while true {
            do {
                guard let e = try await session.NextEvent() else { ended = "ended"; return }
                switch e {
                case .frame(_): frames += 1
                case .logonComplete: logon = true
                case .disconnected(let r): ended = r; return
                default: break
                }
            } catch {
                ended = "\(error)"
                return
            }
        }
    }
}

func pause(_ ms: int64) async {
    try? await time.Sleep(time.Duration.Milliseconds(ms))
}

func tap(_ input: rdp.Input, _ code: string) async throws {
    guard let sc = rdp.ScancodeForCode(code) else { return }
    try await input.Key(sc, down: true)
    try await input.Key(sc, down: false)
}

func typeKeys(_ input: rdp.Input, _ codes: [string]) async throws {
    for c in codes {
        try await tap(input, c)
        await pause(30)
    }
}

func main() async -> int32 {
    let args = CommandLine.arguments
    if args.count < 4 {
        print("usage: rdp-input <host[:port]> <user> <password> [out.png]")
        return 2
    }
    let out = args.count > 4 ? args[4] : "input.png"
    let config = rdp.Config(username: args[2], password: [uint8](args[3].utf8), width: 1024, height: 768)
    do {
        let session = try await rdp.Connect(args[1], config: config)
        let pump = Pump(session)
        let _ = Task { await pump.run() }
        let input = session.Input

        // Let the shell come up.
        var waited = 0
        while !pump.logon && waited < 200 && pump.ended.isEmpty { await pause(100); waited += 1 }
        await pause(4000)
        print("logon \(pump.logon), \(pump.frames) frames so far")

        // Win+R, "notepad", Enter.
        let win = rdp.ScancodeForCode("MetaLeft")!
        try await input.Key(win, down: true)
        try await tap(input, "KeyR")
        try await input.Key(win, down: false)
        await pause(1500)
        try await typeKeys(input, ["KeyN", "KeyO", "KeyT", "KeyE", "KeyP", "KeyA", "KeyD", "Enter"])
        await pause(3000)

        // Text through Unicode events, then a line typed with Shift held.
        try await input.Text("Hello from Vertex rdp: é ü ✓")
        try await tap(input, "Enter")
        let shift = rdp.ScancodeForCode("ShiftLeft")!
        try await input.Key(shift, down: true)
        try await typeKeys(input, ["KeyS", "KeyH", "KeyI", "KeyF", "KeyT", "KeyE", "KeyD"])
        try await input.Key(shift, down: false)
        try await tap(input, "Enter")

        // The mouse: move across and right-click the text area, then Escape.
        var x = 100
        while x <= 500 { try await input.Move(x: x, y: 300); x += 50; await pause(20) }
        try await input.Button(.right, down: true, x: 500, y: 300)
        try await input.Button(.right, down: false, x: 500, y: 300)
        await pause(1500)
        let fb0 = session.Framebuffer
        try fs.WriteFile(fs.Path(out + ".right.png"), png.Encode(image.RGBA(width: fb0.Width, height: fb0.Height, pixels: fb0.Pixels)))
        try await tap(input, "Escape")
        await pause(300)
        // Left-click the Format menu (Notepad sits at the same place each run).
        try await input.Move(x: 256, y: 196)
        try await input.Button(.left, down: true, x: 256, y: 196)
        try await input.Button(.left, down: false, x: 256, y: 196)
        await pause(1500)
        let fb1 = session.Framebuffer
        try fs.WriteFile(fs.Path(out + ".menu.png"), png.Encode(image.RGBA(width: fb1.Width, height: fb1.Height, pixels: fb1.Pixels)))
        try await tap(input, "Escape")
        try await input.Wheel(vertical: -240, horizontal: 0, x: 500, y: 300)
        await pause(2000)

        if !pump.ended.isEmpty { print("session ended early: \(pump.ended)") }
        let fb = session.Framebuffer
        try fs.WriteFile(fs.Path(out), png.Encode(image.RGBA(width: fb.Width, height: fb.Height, pixels: fb.Pixels)))
        print("wrote \(out) after \(pump.frames) frames")

        // Close Notepad without saving: Alt+F4, then "Don't save" (N).
        let alt = rdp.ScancodeForCode("AltLeft")!
        try await input.Key(alt, down: true)
        try await tap(input, "F4")
        try await input.Key(alt, down: false)
        await pause(1000)
        try await tap(input, "KeyN")
        await pause(500)
        session.Close()
        return 0
    } catch {
        print("FAIL: \(error)")
        return 1
    }
}
