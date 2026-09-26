// rdp-screenshot connects to a Windows host, lets the desktop settle, and
// writes it to desktop.png. It is the headless end-to-end check for the
// bitmap graphics path.
//
//     rdp-screenshot <host[:port]> <user> <password> [out.png] [WxH] [scale%]
package main

import (
    "fs"
    "image"
    "image/png"
    "remote/rdp"
    "time"
)

func main() async -> int32 {
    let args = CommandLine.arguments
    if args.count < 4 {
        print("usage: rdp-screenshot <host[:port]> <user> <password> [out.png] [WxH] [scale%]")
        return 2
    }
    let out = args.count > 4 ? args[4] : "desktop.png"
    var w = 1024
    var h = 768
    if args.count > 5 {
        var seenX = false
        w = 0; h = 0
        for c in args[5].utf8 {
            if c == 120 { seenX = true } else if seenX { h = h * 10 + int(c - 48) } else { w = w * 10 + int(c - 48) }
        }
    }
    var config = rdp.Config(username: args[2], password: [uint8](args[3].utf8), width: uint16(w), height: uint16(h))
    if args.count > 6 {
        var scale: uint32 = 0
        for c in args[6].utf8 { scale = scale * 10 + uint32(c - 48) }
        config.DesktopScale = scale
    }
    do {
        var session = try await rdp.ConnectTraced(args[1], config: config)
        print("connected: desktop \(session.Framebuffer.Width)x\(session.Framebuffer.Height)")
        var frames = 0
        var pointers = 0
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
                if pointers < 4 && c.Width > 0 {
                    // Beside the screenshot, for checking the pointer decoder.
                    try? fs.WriteFile(fs.Path(out + ".pointer\(pointers).png"),
                                      png.Encode(image.RGBA(width: c.Width, height: c.Height, pixels: c.Pixels)))
                    pointers += 1
                }
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
