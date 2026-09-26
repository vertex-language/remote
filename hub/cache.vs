package hub

import (
    "fs"
    "os/env"
    "os/user"
)

/// Cache is the Hugging Face hub cache, in Hugging Face's layout, shared
/// with huggingface_hub and everything built on it:
///
///     <root>/models--org--name/
///         blobs/<etag>                      each file's content, by its etag
///         snapshots/<commit>/<path>         a symlink to ../../blobs/<etag>
///         refs/<revision>                   the commit a branch or tag was at
public struct Cache {
    /// The directory holding the repositories.
    public var Root: fs.Path

    public init(root: fs.Path) {
        self.Root = root
    }

    /// The cache huggingface_hub uses: $HF_HUB_CACHE, else $HF_HOME/hub,
    /// else $XDG_CACHE_HOME/huggingface/hub, else ~/.cache/huggingface/hub.
    public static func Default() -> Cache {
        if let dir = env.Get("HF_HUB_CACHE"), !dir.isEmpty {
            return Cache(root: fs.Path(expandHome(dir)))
        }
        return Cache(root: fs.Path(hfHome()) / "hub")
    }

    /// The directory of a repository: models--org--name.
    public func RepoDir(_ kind: RepoKind, _ repo: string) -> fs.Path {
        let flat = repo.split(separator: "/").map { String($0) }.joined(separator: "--")
        return self.Root / "\(kind.Plural)--\(flat)"
    }

    /// Where a blob is kept.
    public func BlobPath(_ kind: RepoKind, _ repo: string, _ etag: string) -> fs.Path {
        return self.RepoDir(kind, repo) / "blobs" / etag
    }

    /// The directory of a snapshot: the repository at a commit.
    public func SnapshotDir(_ kind: RepoKind, _ repo: string, _ commit: string) -> fs.Path {
        return self.RepoDir(kind, repo) / "snapshots" / commit
    }

    /// The commit a revision was at when it was last resolved; a commit
    /// is itself.
    public func Commit(_ kind: RepoKind, _ repo: string, _ revision: string) -> string? {
        if isCommit(revision) {
            return revision
        }
        let p = self.RepoDir(kind, repo) / "refs" / revision
        do {
            let text = try fs.ReadText(p)
            let commit = trimmed(text)
            return isCommit(commit) ? commit : nil
        } catch {
            return nil
        }
    }

    /// Records the commit a branch or tag is at.
    public func SetCommit(_ kind: RepoKind, _ repo: string, _ revision: string, _ commit: string) throws {
        if revision == commit {
            return
        }
        let p = self.RepoDir(kind, repo) / "refs" / revision
        if let parent = p.Parent() {
            try fs.CreateDir(parent, all: true)
        }
        try fs.WriteText(p, commit, atomic: true)
    }

    /// Whether a blob is there, whole: its size is the one expected.
    public func HasBlob(_ kind: RepoKind, _ repo: string, _ file: RepoFile) -> bool {
        do {
            let m = try fs.Metadata(self.BlobPath(kind, repo, file.Etag))
            return m.IsFile() && m.Size == file.Size
        } catch {
            return false
        }
    }

    /// Links a snapshot's path to its blob, as huggingface_hub does: a
    /// symlink relative to where it is, so the cache can move.
    public func Link(_ kind: RepoKind, _ repo: string, _ commit: string, _ file: RepoFile) throws {
        let link = self.SnapshotDir(kind, repo, commit) / file.Path
        if let parent = link.Parent() {
            try fs.CreateDir(parent, all: true)
        }
        // From snapshots/<commit>/<dirs...>/ up to the repository.
        var up = "../../"
        for c in file.Path.utf8 where c == 0x2F {
            up += "../"
        }
        let target = fs.Path(up + "blobs/" + file.Etag)
        do {
            if try fs.ReadLink(link) == target {
                return
            }
            try fs.Remove(link)
        } catch {
        }
        try fs.Symlink(target, at: link)
    }

    /// The files of a snapshot already in the cache, found by walking
    /// its directory: sizes are the blobs', etags the link targets'.
    public func Files(_ kind: RepoKind, _ repo: string, _ commit: string) throws -> [RepoFile] {
        let dir = self.SnapshotDir(kind, repo, commit)
        var out: [RepoFile] = []
        try fs.Walk(dir) { entry in
            if entry.Kind == fs.FileKind.directory {
                return fs.WalkAction.continue
            }
            guard let rel = entry.Path.Relative(to: dir) else {
                return fs.WalkAction.continue
            }
            let m = try fs.Metadata(entry.Path)
            var etag = ""
            if let target = try? fs.ReadLink(entry.Path), let name = target.Name() {
                etag = name
            }
            // A 64-hex etag is a sha256; a 40-hex one a git blob id.
            if etag.utf8.count == 64 {
                out.append(RepoFile(path: rel.String(), size: m.Size, sha256: etag))
            } else {
                out.append(RepoFile(path: rel.String(), size: m.Size, blobId: etag))
            }
            return fs.WalkAction.continue
        }
        return out.sorted { $0.Path < $1.Path }
    }
}

// hfHome is $HF_HOME, else $XDG_CACHE_HOME/huggingface, else
// ~/.cache/huggingface -- on every platform, as huggingface_hub has it.
func hfHome() -> string {
    if let home = env.Get("HF_HOME"), !home.isEmpty {
        return expandHome(home)
    }
    if let xdg = env.Get("XDG_CACHE_HOME"), !xdg.isEmpty {
        return expandHome(xdg) + "/huggingface"
    }
    return (user.Home() ?? ".") + "/.cache/huggingface"
}

func expandHome(_ p: string) -> string {
    if p == "~" || p.hasPrefix("~/") {
        return (user.Home() ?? ".") + String(p.dropFirst(1))
    }
    return p
}

func trimmed(_ s: string) -> string {
    var b = [uint8](s.utf8)
    while let last = b.last, last == 0x0A || last == 0x0D || last == 0x20 || last == 0x09 {
        b.removeLast()
    }
    var i = 0
    while i < b.count && (b[i] == 0x20 || b[i] == 0x09) {
        i += 1
    }
    return String(decoding: b[i..<b.count], as: UTF8.self)
}
