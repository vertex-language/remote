// rdp-screenshot connects to a Windows host, lets the desktop settle, and
// writes it to desktop.png. It is the headless end-to-end check for the
// bitmap graphics path.
//
//     rdp-screenshot <host[:port]> <user> <password> [out.png]
package main

import "remote/rdp"
import "image"
import "image/png"
import "fs"
import "time"

func main() async -> int32 {
    let args = CommandLine.arguments
    if args.count < 4 {
        print("usage: rdp-screenshot <host[:port]> <user> <password> [out.png]")
        return 2
    }
    let out = args.count > 4 ? args[4] : "desktop.png"
    let config = rdp.Config(username: args[2], password: [uint8](args[3].utf8), width: 1024, height: 768)
    do {
        var session = try await rdp.ConnectTraced(args[1], config: config)
        print("connected: desktop \(session.Framebuffer.Width)x\(session.Framebuffer.Height)")
        var frames = 0
        var logon = false
        let start = time.Instant.Now()
        var logonAt = start
        while let event = try await session.NextEvent() {
            switch event {
            case .frame(let damage):
                frames += 1
                if frames <= 5 || frames % 50 == 0 {
                    print("frame \(frames): damage (\(damage.X),\(damage.Y)) \(damage.Width)x\(damage.Height)")
                }
            case .logonComplete:
                print("logon complete")
                logon = true
                logonAt = time.Instant.Now()
            case .pointer(let c):
                print("pointer \(c.Width)x\(c.Height) hot (\(c.HotX),\(c.HotY))")
            case .pointerCached(let i):
                print("pointer cached \(i)")
            case .pointerHidden:
                print("pointer hidden")
            case .pointerDefault:
                print("pointer default")
            case .pointerPosition(let x, let y):
                print("pointer at \(x),\(y)")
            case .resized(let w, let h):
                print("resized to \(w)x\(h)")
            case .disconnected(let reason):
                print("disconnected: \(reason)")
            }
            // Stop after the desktop has had a chance to draw: a while after
            // logon is reported, or a hard cap.
            if logon && logonAt.Elapsed() > time.Duration.Seconds(25) { break }
            if start.Elapsed() > time.Duration.Seconds(90) { break }
        }
        let fb = session.Framebuffer
        let encoded = png.Encode(image.RGBA(width: fb.Width, height: fb.Height, pixels: fb.Pixels))
        try fs.WriteFile(fs.Path(out), encoded)
        print("wrote \(out) (\(encoded.count) bytes) after \(frames) frames")
        return 0
    } catch {
        print("FAIL: \(error)")
        return 1
    }
}
