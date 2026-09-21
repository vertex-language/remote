// rdp-run runs a command on the remote desktop through Win+R and writes a
// screenshot a few seconds later: a way to look at the server from here.
//
//     rdp-run <host[:port]> <user> <password> <command> [out.png] [seconds]
package main

import "remote/rdp"
import "image"
import "image/png"
import "fs"
import "time"

final class Pump {
    let session: rdp.Session
    var logon: bool = false
    var ended: string = ""
    init(_ session: rdp.Session) { self.session = session }
    func run() async {
        while true {
            do {
                guard let e = try await session.NextEvent() else { ended = "ended"; return }
                switch e {
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

func main() async -> int32 {
    let args = CommandLine.arguments
    if args.count < 5 {
        print("usage: rdp-run <host[:port]> <user> <password> <command> [out.png] [seconds]")
        return 2
    }
    let out = args.count > 5 ? args[5] : "run.png"
    var wait: int64 = 4
    if args.count > 6 {
        wait = 0
        for c in args[6].utf8 { if c >= 48 && c <= 57 { wait = wait * 10 + int64(c - 48) } }
    }
    let config = rdp.Config(username: args[2], password: [uint8](args[3].utf8), width: 1024, height: 768)
    do {
        let session = try await rdp.Connect(args[1], config: config)
        let pump = Pump(session)
        let _ = Task { await pump.run() }
        let input = session.Input
        var waited = 0
        while !pump.logon && waited < 150 && pump.ended.isEmpty { await pause(100); waited += 1 }
        await pause(2500)
        let win = rdp.ScancodeForCode("MetaLeft")!
        let r = rdp.ScancodeForCode("KeyR")!
        try await input.Key(win, down: true)
        try await input.Key(r, down: true)
        try await input.Key(r, down: false)
        try await input.Key(win, down: false)
        await pause(1500)
        try await input.Text(args[4])
        let enter = rdp.ScancodeForCode("Enter")!
        try await input.Key(enter, down: true)
        try await input.Key(enter, down: false)
        await pause(wait * 1000)
        if !pump.ended.isEmpty { print("session ended: \(pump.ended)") }
        let fb = session.Framebuffer
        try fs.WriteFile(fs.Path(out), png.Encode(image.RGBA(width: fb.Width, height: fb.Height, pixels: fb.Pixels)))
        print("wrote \(out)")
        session.Close()
        return 0
    } catch {
        print("FAIL: \(error)")
        return 1
    }
}
