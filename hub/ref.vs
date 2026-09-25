// Package hub gets models, datasets and spaces from the Hugging Face Hub:
// it resolves a reference to a pinned commit and its files, and downloads
// them into the Hugging Face cache, in Hugging Face's own layout, so
// what Python tools already fetched is found and nothing is fetched twice.
//
//     let snap = try await hub.Download("hf.co/ggml-org/models-moved/tinyllamas/stories260K.gguf")
//     print(snap.Path("tinyllamas/stories260K.gguf"))
package hub

/// RepoKind is what a repository holds; each lives under its own path.
public enum RepoKind: Equatable {
    case model
    case dataset
    case space

    /// The segment the Hub's API and the cache name it by: "models", ...
    public var Plural: string {
        switch self {
        case .model: return "models"
        case .dataset: return "datasets"
        case .space: return "spaces"
        }
    }
}

/// Ref is a reference to a repository, or to files in one:
///
///     hf.co/Qwen/Qwen3-8B                        the default branch
///     hf.co/Qwen/Qwen3-8B@a1b2c3d                a revision: a branch, tag or commit
///     hf.co/unsloth/Qwen3-8B-GGUF:Q4_K_M         the GGUF file(s) of a quant
///     hf.co/datasets/HuggingFaceFW/fineweb       a dataset (spaces/ for a space)
///     hf.co/org/name/sub/file.gguf               one file in the repository
///     https://huggingface.co/org/name/resolve/main/file.gguf   a file URL
///
/// "hf.co/" may be written "huggingface.co/", with or without https://,
/// or left out ("Qwen/Qwen3-8B").
public struct Ref: Equatable, CustomStringConvertible {
    public var Kind: RepoKind = RepoKind.model
    /// "org/name".
    public var Repo: string
    /// A branch, tag or commit; "main" when none is given.
    public var Revision: string = "main"
    /// A GGUF quant ("Q4_K_M"), or "".
    public var Tag: string = ""
    /// A path inside the repository, or "" for the whole of it.
    public var File: string = ""

    public init(_ repo: string, kind: RepoKind = RepoKind.model, revision: string = "main") {
        self.Repo = repo
        self.Kind = kind
        self.Revision = revision
    }

    /// Parse reads a reference in any of the forms above.
    public static func Parse(_ text: string) throws -> Ref {
        var s = text
        for scheme in ["https://", "http://"] {
            if s.hasPrefix(scheme) {
                s = String(s.dropFirst(scheme.count))
            }
        }
        var segs = s.split(separator: "/", omittingEmptySubsequences: false).map { String($0) }
        if !segs.isEmpty {
            let host = segs[0].lowercased()
            if host == "hf.co" || host == "huggingface.co" || host == "www.huggingface.co" {
                segs.removeFirst()
            }
        }
        var kind = RepoKind.model
        if !segs.isEmpty {
            switch segs[0] {
            case "datasets":
                kind = RepoKind.dataset
                segs.removeFirst()
            case "spaces":
                kind = RepoKind.space
                segs.removeFirst()
            case "models":
                segs.removeFirst()
            default:
                break
            }
        }
        if segs.count < 2 || segs[0].isEmpty || segs[1].isEmpty {
            throw HubError.badReference(text, "want org/name")
        }
        let org = segs[0]
        var name = segs[1]
        var rest = Array(segs[2..<segs.count])

        // name@revision:TAG -- the tag after the revision, as Ollama and
        // llama.cpp write it; a revision never holds ':'.
        var revision = "main"
        var tag = ""
        if let colon = name.lastIndex(of: ":") {
            tag = String(name[name.index(after: colon)..<name.endIndex])
            name = String(name[name.startIndex..<colon])
            if tag.isEmpty {
                throw HubError.badReference(text, "an empty tag after ':'")
            }
        }
        if let at = name.firstIndex(of: "@") {
            revision = String(name[name.index(after: at)..<name.endIndex])
            name = String(name[name.startIndex..<at])
            if revision.isEmpty {
                throw HubError.badReference(text, "an empty revision after '@'")
            }
        }
        if name.isEmpty {
            throw HubError.badReference(text, "want org/name")
        }

        // A file URL: /resolve/<revision>/<path> or /blob/<revision>/<path>.
        if rest.count >= 3 && (rest[0] == "resolve" || rest[0] == "blob") {
            revision = unescape(rest[1])
            rest = Array(rest[2..<rest.count])
        } else if rest.count >= 2 && rest[0] == "tree" {
            revision = unescape(rest[1])
            rest = Array(rest[2..<rest.count])
        }
        var file = ""
        for part in rest {
            if part.isEmpty {
                continue
            }
            if part == "." || part == ".." {
                throw HubError.badReference(text, "'\(part)' in a file path")
            }
            file += (file.isEmpty ? "" : "/") + unescape(part)
        }

        var r = Ref("\(org)/\(name)", kind: kind, revision: revision)
        r.Tag = tag
        r.File = file
        return r
    }

    /// The reference as Parse reads it: "hf.co/org/name@rev:TAG".
    public var description: string {
        var s = "hf.co/"
        if self.Kind != RepoKind.model {
            s += self.Kind.Plural + "/"
        }
        s += self.Repo
        if self.Revision != "main" {
            s += "@" + self.Revision
        }
        if !self.Tag.isEmpty {
            s += ":" + self.Tag
        }
        if !self.File.isEmpty {
            s += "/" + self.File
        }
        return s
    }
}

/// HubError is what went wrong talking to the Hub or with its cache.
public enum HubError: Error, CustomStringConvertible {
    /// The reference could not be read, and why.
    case badReference(string, string)
    /// No such repository -- or a private one, without a token that may see it.
    case repoNotFound(string)
    /// The repository is gated: accept its terms on the Hub, and use a token.
    case gated(string)
    /// No such branch, tag or commit.
    case revisionNotFound(string, string)
    /// No file matches what was asked for.
    case fileNotFound(string, string)
    /// The Hub answered with this status, and said this.
    case status(int32, string)
    /// A downloaded file is not what the Hub said it would be.
    case corrupt(string, string)
    /// Offline, and the cache does not have it.
    case notCached(string)

    public var description: string {
        switch self {
        case .badReference(let r, let why):
            return "hub: bad reference \(r): \(why)"
        case .repoNotFound(let r):
            return "hub: repository \(r) not found (a private one needs HF_TOKEN)"
        case .gated(let r):
            return "hub: \(r) is gated: accept its terms at https://huggingface.co/\(r) and set HF_TOKEN"
        case .revisionNotFound(let r, let rev):
            return "hub: \(r) has no revision \(rev)"
        case .fileNotFound(let r, let f):
            return "hub: \(r) has no file \(f)"
        case .status(let code, let msg):
            return "hub: HTTP \(code): \(msg)"
        case .corrupt(let f, let why):
            return "hub: \(f) is corrupt: \(why)"
        case .notCached(let r):
            return "hub: \(r) is not in the cache, and the hub is offline"
        }
    }
}

let hexDigits: [uint8] = [uint8]("0123456789ABCDEF".utf8)

// escape percent-encodes a path segment, or a path with its slashes kept.
func escape(_ s: string, keepSlash: bool = false) -> string {
    var out: [uint8] = []
    for b in s.utf8 {
        let unreserved = (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) ||
            b == 0x2D || b == 0x2E || b == 0x5F || b == 0x7E
        if unreserved || (keepSlash && b == 0x2F) {
            out.append(b)
        } else {
            out.append(0x25)
            out.append(hexDigits[int(b >> 4)])
            out.append(hexDigits[int(b & 0xF)])
        }
    }
    return String(decoding: out, as: UTF8.self)
}

// unescape decodes %XX; anything malformed is left as it is.
func unescape(_ s: string) -> string {
    let b = [uint8](s.utf8)
    var out: [uint8] = []
    var i = 0
    while i < b.count {
        if b[i] == 0x25 && i + 2 < b.count {
            let hi = hexValue(b[i + 1])
            let lo = hexValue(b[i + 2])
            if hi >= 0 && lo >= 0 {
                out.append(uint8(hi * 16 + lo))
                i += 3
                continue
            }
        }
        out.append(b[i])
        i += 1
    }
    return String(decoding: out, as: UTF8.self)
}

func hexValue(_ c: uint8) -> int {
    if c >= 0x30 && c <= 0x39 { return int(c - 0x30) }
    if c >= 0x61 && c <= 0x66 { return int(c - 0x61 + 10) }
    if c >= 0x41 && c <= 0x46 { return int(c - 0x41 + 10) }
    return -1
}

// isCommit reports whether a revision is a full commit hash.
func isCommit(_ rev: string) -> bool {
    if rev.utf8.count != 40 {
        return false
    }
    for c in rev.utf8 {
        if !((c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66)) {
            return false
        }
    }
    return true
}
