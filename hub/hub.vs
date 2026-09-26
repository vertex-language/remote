package hub

import (
    "crypto/sha1"
    "crypto/sha256"
    "encoding/json"
    "fs"
    "net/http"
    "os/env"
)

/// Snapshot is a repository pinned to a commit, and the files a
/// reference asked for.
public struct Snapshot {
    public var Ref: Ref
    /// The commit the revision resolved to.
    public var Commit: string
    /// The files asked for, with their sizes and hashes.
    public var Files: [RepoFile]
    /// Where the snapshot is in the cache. Its files are there once
    /// Download has run.
    public var Dir: fs.Path

    /// The local path of one of its files.
    public func Path(_ file: string) -> fs.Path {
        return self.Dir / file
    }

    /// The bytes of all its files.
    public var Size: int64 {
        var n: int64 = 0
        for f in self.Files {
            n += f.Size
        }
        return n
    }
}

/// Progress is how a download is going: the file being fetched, the
/// bytes of it done and its size, and the same over all the files.
public struct Progress {
    public var File: string
    public var Done: int64
    public var Size: int64
    public var TotalDone: int64
    public var Total: int64
}

/// Hub talks to a Hugging Face hub and keeps what it fetches in a Cache.
/// Its defaults come from the environment huggingface_hub reads:
/// HF_ENDPOINT, HF_TOKEN (or the token `hf auth login` saved),
/// HF_HUB_CACHE / HF_HOME, and HF_HUB_OFFLINE.
public struct Hub {
    /// "https://huggingface.co", or a mirror.
    public var Endpoint: string
    /// Sent to the endpoint, never to where it redirects.
    public var Token: string?
    public var Cache: Cache
    /// Use only the cache; never touch the network.
    public var Offline: bool
    /// Only the files matching one of these globs, when a reference
    /// names no file and no tag (see Select).
    public var Include: [string] = []
    /// Called as a download goes, every few megabytes and at each
    /// file's end.
    public var OnProgress: ((Progress) -> void)? = nil

    public init() {
        var endpoint = env.Get("HF_ENDPOINT") ?? "https://huggingface.co"
        while endpoint.hasSuffix("/") {
            endpoint = String(endpoint.dropLast())
        }
        self.Endpoint = endpoint
        self.Token = defaultToken()
        self.Cache = defaultCache()
        let off = (env.Get("HF_HUB_OFFLINE") ?? "").lowercased()
        self.Offline = off == "1" || off == "true" || off == "yes"
    }

    /// Resolve pins a reference to a commit and lists the files it asks
    /// for, transferring no file. Offline, or when the hub cannot be
    /// reached, the cache answers if it can.
    public func Resolve(_ ref: Ref) async throws -> Snapshot {
        if self.Offline {
            return try self.cached(ref)
        }
        var info: json.Value
        do {
            info = try await self.revisionInfo(ref)
        } catch let e as HubError {
            throw e
        } catch {
            // The network failed: what the cache has will do.
            if let snap = try? self.cached(ref) {
                return snap
            }
            throw error
        }
        guard let commit = info["sha"]?.String, isCommit(commit) else {
            throw HubError.status(200, "the hub gave no commit for \(ref)")
        }
        var files: [RepoFile] = []
        for s in info["siblings"]?.Array ?? [] {
            guard let path = s["rfilename"]?.String else {
                continue
            }
            var f = RepoFile(path: path, size: s["size"]?.Int ?? -1, blobId: s["blobId"]?.String ?? "")
            if let lfs = s["lfs"] {
                f.Sha256 = lfs["sha256"]?.String ?? ""
                if let size = lfs["size"]?.Int {
                    f.Size = size
                }
            }
            files.append(f)
        }
        let chosen = try Select(files, ref: ref, include: self.Include)
        return Snapshot(Ref: ref, Commit: commit, Files: chosen,
                        Dir: self.Cache.SnapshotDir(ref.Kind, ref.Repo, commit))
    }

    /// Download resolves a reference and makes sure its files are in the
    /// cache, fetching what is missing -- resuming what an earlier run
    /// left half done -- and checking each against its hash.
    public func Download(_ ref: Ref) async throws -> Snapshot {
        let snap = try await self.Resolve(ref)
        if self.Offline {
            return snap
        }
        try self.Cache.SetCommit(ref.Kind, ref.Repo, ref.Revision, snap.Commit)
        var totalDone: int64 = 0
        let total = snap.Size
        for f in snap.Files {
            if !self.Cache.HasBlob(ref.Kind, ref.Repo, f) {
                try await self.fetch(ref, snap.Commit, f, totalDone, total)
            }
            try self.Cache.Link(ref.Kind, ref.Repo, snap.Commit, f)
            totalDone += f.Size
            if let report = self.OnProgress {
                report(Progress(File: f.Path, Done: f.Size, Size: f.Size, TotalDone: totalDone, Total: total))
            }
        }
        return snap
    }

    // cached is the snapshot the cache holds for a reference.
    func cached(_ ref: Ref) throws -> Snapshot {
        guard let commit = self.Cache.Commit(ref.Kind, ref.Repo, ref.Revision) else {
            throw HubError.notCached(ref.description)
        }
        var files: [RepoFile]
        do {
            files = try self.Cache.Files(ref.Kind, ref.Repo, commit)
        } catch {
            throw HubError.notCached(ref.description)
        }
        let chosen = try Select(files, ref: ref, include: self.Include)
        if chosen.isEmpty {
            throw HubError.notCached(ref.description)
        }
        return Snapshot(Ref: ref, Commit: commit, Files: chosen,
                        Dir: self.Cache.SnapshotDir(ref.Kind, ref.Repo, commit))
    }

    // revisionInfo asks the API for a repository at a revision, with
    // each file's size and hash.
    func revisionInfo(_ ref: Ref) async throws -> json.Value {
        let url = "\(self.Endpoint)/api/\(ref.Kind.Plural)/\(escape(ref.Repo, keepSlash: true))/revision/\(escape(ref.Revision))?blobs=true"
        var s = try await self.open("GET", url, ref)
        defer { s.Close() }
        var body: [uint8] = []
        var buf = [uint8](repeating: 0, count: 65536)
        while true {
            let n = try await s.Read(into: &buf)
            if n == 0 {
                break
            }
            body.append(contentsOf: buf[0..<n])
            if body.count > 64 * 1024 * 1024 {
                throw HubError.status(200, "the file list of \(ref.Repo) is too long")
            }
        }
        do {
            return try json.Parse(bytes: body)
        } catch {
            throw HubError.status(200, "the hub's answer did not parse: \(error)")
        }
    }

    // open sends a request and follows redirects to a 2xx answer, whose
    // body is left to read. The token goes only to the endpoint's host.
    func open(_ method: string, _ url: string, _ ref: Ref, rangeFrom: int64 = 0) async throws -> http.ResponseStream {
        let client = http.Client(timeoutMs: 30000)
        let home = try http.URL.Parse(self.Endpoint)
        var u = try http.URL.Parse(url)
        var hops = 0
        while true {
            var req = http.Request(method: method, url: u.Path)
            req.Headers.Set("User-Agent", "vertex-hub/0.1")
            if let t = self.Token, u.Host == home.Host && u.Scheme == home.Scheme {
                req.Headers.Set("Authorization", "Bearer \(t)")
            }
            if rangeFrom > 0 {
                req.Headers.Set("Range", "bytes=\(rangeFrom)-")
            }
            var s = try await client.Open(req, url: u)
            let code = s.Response.StatusCode
            if code >= 200 && code < 300 {
                return s
            }
            if code == 301 || code == 302 || code == 303 || code == 307 || code == 308 {
                guard let loc = s.Response.Headers.Get("Location") else {
                    s.Close()
                    throw HubError.status(code, "a redirect with no Location")
                }
                s.Close()
                hops += 1
                if hops > 10 {
                    throw HubError.status(code, "too many redirects")
                }
                if loc.hasPrefix("/") {
                    u = http.URL(scheme: u.Scheme, host: u.Host, port: u.Port, path: loc)
                } else {
                    u = try http.URL.Parse(loc)
                }
                continue
            }
            let errCode = s.Response.Headers.Get("X-Error-Code") ?? ""
            let msg = s.Response.Headers.Get("X-Error-Message") ?? s.Response.Status
            s.Close()
            if errCode == "GatedRepo" || code == 403 && msg.lowercased().contains("gated") {
                throw HubError.gated(ref.Repo)
            }
            if errCode == "RepoNotFound" || (code == 401 && errCode.isEmpty) {
                throw HubError.repoNotFound(ref.Repo)
            }
            if errCode == "RevisionNotFound" {
                throw HubError.revisionNotFound(ref.Repo, ref.Revision)
            }
            if errCode == "EntryNotFound" {
                throw HubError.fileNotFound(ref.Repo, ref.File)
            }
            throw HubError.status(code, msg)
        }
    }

    // fetch downloads one file into its blob: into blob.incomplete,
    // resumed from where an earlier run stopped, hashed as it goes, and
    // renamed into place once its size and hash are right.
    func fetch(_ ref: Ref, _ commit: string, _ f: RepoFile, _ totalDone: int64, _ total: int64) async throws {
        let blob = self.Cache.BlobPath(ref.Kind, ref.Repo, f.Etag)
        let part = fs.Path(blob.String() + ".incomplete")
        if let parent = blob.Parent() {
            try fs.CreateDir(parent, all: true)
        }
        // A large file is checked by its sha256; a small one by its git
        // blob id, the sha1 of "blob <size>\0" and the content.
        let large = !f.Sha256.isEmpty
        var h256 = sha256.New()
        var h1 = sha1.New()
        h1.WriteString("blob \(f.Size)\u{0}")
        var have: int64 = 0
        if large, let m = try? fs.Metadata(part), m.IsFile() && m.Size > 0 && m.Size < f.Size {
            // What an earlier run left is hashed again, so a resumed file
            // is checked whole.
            have = m.Size
            let old = try fs.Open(part)
            var buf = [uint8](repeating: 0, count: 1 << 20)
            var left = have
            while left > 0 {
                let n = try old.Read(into: &buf)
                if n == 0 {
                    break
                }
                h256.Write(Array(buf[0..<n]))
                left -= int64(n)
            }
            try old.Close()
        } else {
            // A small file starts over.
            try? fs.Remove(part)
        }

        let url = "\(self.Endpoint)/\(ref.Kind == RepoKind.model ? "" : ref.Kind.Plural + "/")\(escape(ref.Repo, keepSlash: true))/resolve/\(commit)/\(escape(f.Path, keepSlash: true))"
        var s = try await self.open("GET", url, ref, rangeFrom: have)
        defer { s.Close() }
        if have > 0 && s.Response.StatusCode != 206 {
            // The range was not honoured: the whole file is coming.
            have = 0
            h256 = sha256.New()
            try? fs.Remove(part)
        }
        var opts = fs.OpenOptions.append
        opts.Mode = 0o644
        let out = try fs.Open(part, opts)
        var done = have
        var lastReport: int64 = 0
        var buf = [uint8](repeating: 0, count: 1 << 18)
        do {
            while true {
                let n = try await s.Read(into: &buf)
                if n == 0 {
                    break
                }
                let chunk = Array(buf[0..<n])
                try out.Write(chunk)
                if large { h256.Write(chunk) } else { h1.Write(chunk) }
                done += int64(n)
                if done > f.Size {
                    throw HubError.corrupt(f.Path, "more than its \(f.Size) bytes")
                }
                if let report = self.OnProgress, done - lastReport >= 4 << 20 {
                    lastReport = done
                    report(Progress(File: f.Path, Done: done, Size: f.Size, TotalDone: totalDone + done, Total: total))
                }
            }
        } catch {
            try? out.Close()
            throw error
        }
        try out.Close()
        if done != f.Size {
            throw HubError.corrupt(f.Path, "\(done) bytes of \(f.Size); run again to resume")
        }
        let got = large ? sha256.ToHex(h256.Checksum()) : sha1.ToHex(h1.Checksum())
        if got.lowercased() != f.Etag.lowercased() {
            try? fs.Remove(part)
            throw HubError.corrupt(f.Path, "its hash is \(got), not \(f.Etag)")
        }
        try fs.Rename(part, blob)
    }
}

func defaultCache() -> Cache {
    return Cache.Default()
}

// defaultToken is $HF_TOKEN, else the older $HUGGING_FACE_HUB_TOKEN,
// else the token `hf auth login` wrote to $HF_HOME/token.
func defaultToken() -> string? {
    for name in ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"] {
        if let t = env.Get(name), !trimmed(t).isEmpty {
            return trimmed(t)
        }
    }
    let path = env.Get("HF_TOKEN_PATH") ?? (hfHome() + "/token")
    if let t = try? fs.ReadText(fs.Path(expandHome(path))), !trimmed(t).isEmpty {
        return trimmed(t)
    }
    return nil
}

/// Resolve pins a reference ("hf.co/org/name@rev:TAG") with the default Hub.
public func Resolve(_ ref: string) async throws -> Snapshot {
    return try await Hub().Resolve(try Ref.Parse(ref))
}

/// Download fetches what a reference asks for into the cache with the
/// default Hub, and returns the snapshot it is in.
public func Download(_ ref: string) async throws -> Snapshot {
    return try await Hub().Download(try Ref.Parse(ref))
}
