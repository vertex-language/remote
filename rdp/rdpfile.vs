// .rdp files: the "name:type:value" lines mstsc and cloud consoles hand
// out. Only the settings a client needs to connect are read; passwords in
// them are DPAPI-encrypted and not supported.
package rdp

/// File is what an .rdp file says about a connection.
public struct File {
    /// "host" or "host:port".
    public var Address: string = ""
    public var Username: string = ""
    public var Domain: string = ""
    /// 0 when the file doesn't say.
    public var DesktopWidth: int = 0
    public var DesktopHeight: int = 0
    public init() {}
}

/// ParseFile reads an .rdp file's bytes: UTF-8, or UTF-16LE with a byte
/// order mark as mstsc writes them.
public func ParseFile(_ bytes: [uint8]) -> File {
    var text: [uint8] = []
    if bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE {
        // UTF-16LE: the settings are ASCII, so keep the low bytes of units
        // below 0x80 and drop the rest.
        var i = 2
        while i + 1 < bytes.count {
            if bytes[i + 1] == 0 && bytes[i] < 0x80 { text.append(bytes[i]) }
            i += 2
        }
    } else {
        var i = 0
        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF { i = 3 }
        while i < bytes.count { text.append(bytes[i]); i += 1 }
    }
    var f = File()
    var start = 0
    while start < text.count {
        var end = start
        while end < text.count && text[end] != 10 { end += 1 }
        var lineEnd = end
        if lineEnd > start && text[lineEnd - 1] == 13 { lineEnd -= 1 }
        applySetting(&f, text, start, lineEnd)
        start = end + 1
    }
    return f
}

func applySetting(_ f: inout File, _ t: [uint8], _ start: int, _ end: int) {
    // name:type:value -- the name may not contain ':'.
    var c1 = start
    while c1 < end && t[c1] != 58 { c1 += 1 }
    if c1 + 2 >= end || t[c1 + 2] != 58 { return }
    let name = lower(bytesToString(t, start, c1))
    let value = bytesToString(t, c1 + 3, end)
    switch name {
    case "full address": f.Address = value
    case "username":
        // DOMAIN\user splits; user@domain stays whole (a UPN).
        let vb = [uint8](value.utf8)
        var slash = -1
        var i = 0
        while i < vb.count { if vb[i] == 92 { slash = i; break }; i += 1 }
        if slash > 0 {
            f.Domain = bytesToString(vb, 0, slash)
            f.Username = bytesToString(vb, slash + 1, vb.count)
        } else {
            f.Username = value
        }
    case "domain": f.Domain = value
    case "desktopwidth": f.DesktopWidth = parseInt(value)
    case "desktopheight": f.DesktopHeight = parseInt(value)
    default: break
    }
}

func lower(_ s: string) -> string {
    var b = [uint8](s.utf8)
    var i = 0
    while i < b.count {
        if b[i] >= 65 && b[i] <= 90 { b[i] += 32 }
        i += 1
    }
    return bytesToString(b, 0, b.count)
}

func parseInt(_ s: string) -> int {
    var v = 0
    for c in s.utf8 {
        if c < 48 || c > 57 { break }
        v = v * 10 + int(c - 48)
    }
    return v
}
