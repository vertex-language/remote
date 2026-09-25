package main

import "fs"
import "crypto/sha256"
import "remote/hub"

// Live: against huggingface.co, into a cache in a temporary directory.
// stories260K.gguf (1.2 MB) is the file; model/testdata has the same one.

var failures = 0

func check(_ ok: bool, _ msg: string) {
    if ok {
        print("ok    \(msg)")
    } else {
        print("FAIL  \(msg)")
        failures += 1
    }
}

let file = "tinyllamas/stories260K.gguf"
let sha = "270cba1bd5109f42d03350f60406024560464db173c0e387d91f0426d3bd256d"
let size: int64 = 1185376

func exists(_ p: fs.Path) -> bool {
    do {
        _ = try fs.Metadata(p, followSymlinks: false)
        return true
    } catch {
        return false
    }
}

func contentHash(_ p: fs.Path) -> string {
    do {
        return sha256.ToHex(sha256.Sum256(try fs.ReadFile(p)))
    } catch {
        return "unreadable: \(error)"
    }
}

func main() async -> int32 {
    var root = fs.Path("")
    do {
        root = try fs.TempDir(prefix: "hublive_")
        var h = hub.Hub()
        h.Cache = hub.Cache(root: root)
        let ref = try hub.Ref.Parse("hf.co/ggml-org/models-moved/\(file)")

        let snap = try await h.Resolve(ref)
        check(snap.Commit.utf8.count == 40, "resolve pins a commit: \(snap.Commit)")
        check(snap.Files.count == 1 && snap.Files[0].Path == file, "resolve lists the one file")
        check(snap.Files[0].Size == size && snap.Files[0].Sha256 == sha, "its size and sha256")
        check(!exists(snap.Path(file)), "resolve transfers nothing")

        var reports = 0
        h.OnProgress = { p in
            reports += 1
        }
        let got = try await h.Download(ref)
        check(contentHash(got.Path(file)) == sha, "downloaded, and its hash is right")
        check(reports >= 1, "progress was reported")
        check(h.Cache.Commit(hub.RepoKind.model, "ggml-org/models-moved", "main") == got.Commit, "refs/main records the commit")
        let blob = h.Cache.BlobPath(hub.RepoKind.model, "ggml-org/models-moved", sha)
        check(try fs.ReadLink(got.Path(file)).String() == "../../../blobs/\(sha)", "the snapshot links to the blob")

        // Again: the cache has it.
        let again = try await h.Download(ref)
        check(again.Commit == got.Commit && contentHash(again.Path(file)) == sha, "a second download is the cached one")

        // Resume: half the file left as an earlier run would leave it.
        let whole = try fs.ReadFile(blob)
        let part = fs.Path(blob.String() + ".incomplete")
        try fs.Remove(blob)
        try fs.WriteFile(part, Array(whole[0..<500000]))
        _ = try await h.Download(ref)
        check(contentHash(blob) == sha, "a half-done download resumes to the right file")
        check(!exists(part), "and its .incomplete is gone")

        // A damaged partial file is caught by the hash, and dropped.
        try fs.Remove(blob)
        try fs.WriteFile(part, [uint8](repeating: 0x55, count: 500000))
        do {
            _ = try await h.Download(ref)
            check(false, "a damaged resume is caught")
        } catch {
            check("\(error)".contains("corrupt"), "a damaged resume is caught: \(error)")
        }
        check(!exists(part), "and the damaged part is removed")
        _ = try await h.Download(ref)
        check(contentHash(blob) == sha, "the next run fetches it whole")

        // A small file, kept in git: checked by its blob id.
        let attrs = try await h.Download(try hub.Ref.Parse("hf.co/ggml-org/models-moved/.gitattributes"))
        check(attrs.Files.count == 1 && attrs.Files[0].Sha256.isEmpty && attrs.Files[0].BlobId.utf8.count == 40, "a small file has a git blob id")
        check(exists(attrs.Path(".gitattributes")), "and downloads")

        // Offline, the cache answers.
        var off = h
        off.Offline = true
        let cached = try await off.Resolve(ref)
        check(cached.Commit == got.Commit && cached.Files.count == 1 && cached.Files[0].Size == size, "offline resolve from the cache")

        // A GGUF repository and a quant, resolved only.
        let q = try await h.Resolve(try hub.Ref.Parse("hf.co/unsloth/Qwen3-0.6B-GGUF:Q8_0"))
        check(q.Files.count == 1 && q.Files[0].Path == "Qwen3-0.6B-Q8_0.gguf", "a quant tag picks its file")
        let dflt = try await h.Resolve(try hub.Ref.Parse("hf.co/unsloth/Qwen3-0.6B-GGUF"))
        check(dflt.Files.count == 1 && dflt.Files[0].Path.contains("Q4_K_M"), "no tag: Q4_K_M")
        let ds = try await h.Resolve(try hub.Ref.Parse("hf.co/datasets/roneneldan/TinyStories/README.md"))
        check(ds.Files.count == 1, "a dataset's file resolves")

        // Errors say what is wrong.
        do {
            _ = try await h.Resolve(try hub.Ref.Parse("hf.co/vertex-language/no-such-repo-\(size)"))
            check(false, "a missing repository throws")
        } catch {
            check("\(error)".contains("not found"), "a missing repository: \(error)")
        }
        do {
            _ = try await h.Resolve(try hub.Ref.Parse("hf.co/ggml-org/models-moved@no-such-branch"))
            check(false, "a missing revision throws")
        } catch {
            check("\(error)".contains("no revision"), "a missing revision: \(error)")
        }
        do {
            _ = try await h.Resolve(try hub.Ref.Parse("hf.co/ggml-org/models-moved/no/such/file.gguf"))
            check(false, "a missing file throws")
        } catch {
            check("\(error)".contains("no file"), "a missing file: \(error)")
        }
    } catch {
        check(false, "unexpected: \(error)")
    }
    try? fs.RemoveAll(root)

    if failures == 0 {
        print("\n=== all remote/hub live checks passed ===")
        return 0
    }
    print("\n\(failures) failed")
    return 1
}
