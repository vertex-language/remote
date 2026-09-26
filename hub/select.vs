package hub

/// RepoFile is one file of a repository at a commit.
public struct RepoFile: Equatable {
    /// Its path in the repository: "tinyllamas/stories260K.gguf".
    public var Path: string
    public var Size: int64
    /// The sha256 of its content, for a file stored in LFS or Xet (all
    /// large ones); "" for a small file kept in git.
    public var Sha256: string = ""
    /// Its git blob id (a sha1), which names a small file in the cache.
    public var BlobId: string = ""

    public init(path: string, size: int64, sha256: string = "", blobId: string = "") {
        self.Path = path
        self.Size = size
        self.Sha256 = sha256
        self.BlobId = blobId
    }

    /// The name of its blob in the cache: what the Hub gives as its
    /// ETag -- the sha256 of a large file, the blob id of a small one.
    public var Etag: string {
        return self.Sha256.isEmpty ? self.BlobId : self.Sha256
    }
}

/// The quant a GGUF repository gives when no tag is asked for, as
/// llama.cpp's and Ollama's pulls do.
public let DefaultTag = "Q4_K_M"

/// Select is the files of a repository that a reference asks for: one
/// file (or the files under a directory) by its File; a quant's GGUF
/// files by its Tag; else those that match one of the patterns, or all
/// of them when there are no patterns.
///
/// A GGUF-only repository with neither a tag nor patterns gives the
/// DefaultTag quant when it has one, else its first GGUF file: such a
/// repository is a shelf of quants, and one is wanted, not all.
public func Select(_ files: [RepoFile], ref: Ref, include: [string] = []) throws -> [RepoFile] {
    if !ref.File.isEmpty {
        var out: [RepoFile] = []
        for f in files {
            if f.Path == ref.File || f.Path.hasPrefix(ref.File + "/") {
                out.append(f)
            }
        }
        if out.isEmpty {
            throw HubError.fileNotFound(ref.Repo, ref.File)
        }
        return out
    }
    if !ref.Tag.isEmpty {
        let out = ggufQuant(files, ref.Tag)
        if out.isEmpty {
            throw HubError.fileNotFound(ref.Repo, "a GGUF file of quant \(ref.Tag)")
        }
        return out
    }
    if !include.isEmpty {
        var out: [RepoFile] = []
        for f in files {
            for p in include {
                if Match(p, f.Path) {
                    out.append(f)
                    break
                }
            }
        }
        return out
    }
    var ggufs: [RepoFile] = []
    var weights = 0
    for f in files {
        let lower = f.Path.lowercased()
        if lower.hasSuffix(".gguf") {
            ggufs.append(f)
        } else if lower.hasSuffix(".safetensors") || lower.hasSuffix(".bin") || lower.hasSuffix(".pt") || lower.hasSuffix(".onnx") {
            weights += 1
        }
    }
    if ggufs.count > 1 && weights == 0 {
        let preferred = ggufQuant(files, DefaultTag)
        if !preferred.isEmpty {
            return preferred
        }
        let first = ggufs.sorted { $0.Path < $1.Path }[0]
        // Its other shards, if it is split.
        if let stem = splitStem(first.Path) {
            return ggufs.filter { splitStem($0.Path) == stem }
        }
        return [first]
    }
    return files
}

// ggufQuant is the GGUF files whose name carries the quant as a word of
// its own -- "Qwen3-8B-Q4_K_M.gguf", "Q4_K_M/x-00001-of-00002.gguf" --
// compared without case. "Q4_K" does not take "Q4_K_M".
func ggufQuant(_ files: [RepoFile], _ tag: string) -> [RepoFile] {
    let want = [uint8](tag.lowercased().utf8)
    var out: [RepoFile] = []
    for f in files {
        let lower = f.Path.lowercased()
        if !lower.hasSuffix(".gguf") {
            continue
        }
        // mmproj files are a vision projector, not the quant itself.
        if lower.contains("mmproj") {
            continue
        }
        let b = [uint8](lower.utf8)
        var i = 0
        var found = false
        while i + want.count <= b.count && !found {
            var same = true
            var j = 0
            while j < want.count {
                if b[i + j] != want[j] {
                    same = false
                    break
                }
                j += 1
            }
            if same {
                let before = i == 0 || isSeparator(b[i - 1])
                let end = i + want.count
                // '_' may come before a tag but not after it: that is
                // a longer quant's name, Q4_K_M after Q4_K.
                let after = end == b.count || (isSeparator(b[end]) && b[end] != 0x5F)
                found = before && after
            }
            i += 1
        }
        if found {
            out.append(f)
        }
    }
    return out
}

func isSeparator(_ c: uint8) -> bool {
    return c == 0x2D || c == 0x2E || c == 0x5F || c == 0x2F // - . _ /
}

// splitStem is the name of a split GGUF with its "-00001-of-00003" taken
// off, or nil for a file that is not one of a split.
func splitStem(_ path: string) -> string? {
    let b = [uint8](path.utf8)
    // ...-NNNNN-of-NNNNN.gguf
    let tail = 5 + 4 + 5 + 5 // "-00001" "-of-" "00003" ".gguf"
    if b.count < tail + 1 {
        return nil
    }
    let at = b.count - tail
    if b[at] != 0x2D || b[at + 6] != 0x2D || b[at + 7] != 0x6F || b[at + 8] != 0x66 || b[at + 9] != 0x2D {
        return nil
    }
    return String(decoding: b[0..<at], as: UTF8.self)
}

/// Match reports whether path matches a glob pattern: '*' is any run of
/// characters but '/', "**" any run including '/', '?' any one
/// character. A pattern with no '/' is matched against the file's name
/// alone, so "*.json" finds JSON files in any directory; one starting
/// with '/' is anchored at the repository's root, as in .gitignore, so
/// "/*.json" finds only those at the top.
public func Match(_ pattern: string, _ path: string) -> bool {
    var p = [uint8](pattern.utf8)
    var s = [uint8](path.utf8)
    if p.first == 0x2F {
        p.removeFirst()
        return globMatch(p, 0, s, 0)
    }
    if !p.contains(0x2F) {
        if let slash = s.lastIndex(of: 0x2F) {
            s = Array(s[(slash + 1)..<s.count])
        }
    }
    return globMatch(p, 0, s, 0)
}

func globMatch(_ p: [uint8], _ pi: int, _ s: [uint8], _ si: int) -> bool {
    var i = pi
    var j = si
    while i < p.count {
        let c = p[i]
        if c == 0x2A { // *
            let deep = i + 1 < p.count && p[i + 1] == 0x2A
            let next = deep ? i + 2 : i + 1
            // "**/" also matches no directory at all.
            if deep && next < p.count && p[next] == 0x2F && globMatch(p, next + 1, s, j) {
                return true
            }
            if next == p.count {
                if deep {
                    return true
                }
                while j < s.count {
                    if s[j] == 0x2F { return false }
                    j += 1
                }
                return true
            }
            var k = j
            while k <= s.count {
                if globMatch(p, next, s, k) {
                    return true
                }
                if k < s.count && s[k] == 0x2F && !deep {
                    return false
                }
                k += 1
            }
            return false
        }
        if j >= s.count {
            return false
        }
        if c == 0x3F { // ?
            if s[j] == 0x2F {
                return false
            }
        } else if c != s[j] {
            return false
        }
        i += 1
        j += 1
    }
    return j == s.count
}
