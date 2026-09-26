package main

import "fs"
import "remote/hub"

// Offline: references, file selection, globs and the cache's layout.
// cmd/hub-live-test talks to huggingface.co.

var failures = 0

func check(_ ok: bool, _ msg: string) {
    if ok {
        print("ok    \(msg)")
    } else {
        print("FAIL  \(msg)")
        failures += 1
    }
}

func parse(_ s: string) -> hub.Ref? {
    do {
        return try hub.Ref.Parse(s)
    } catch {
        return nil
    }
}

func paths(_ files: [hub.RepoFile]) -> [string] {
    return files.map { $0.Path }
}

func main() async -> int32 {
    // References.
    if let r = parse("hf.co/Qwen/Qwen3-8B") {
        check(r.Repo == "Qwen/Qwen3-8B" && r.Revision == "main" && r.Kind == hub.RepoKind.model && r.Tag == "" && r.File == "", "plain repo")
        check(r.description == "hf.co/Qwen/Qwen3-8B", "plain repo round trip")
    } else { check(false, "plain repo parses") }
    if let r = parse("hf.co/Qwen/Qwen3-8B@a1b2c3d") {
        check(r.Revision == "a1b2c3d", "revision")
    } else { check(false, "revision parses") }
    if let r = parse("huggingface.co/unsloth/Qwen3-8B-GGUF:Q4_K_M") {
        check(r.Repo == "unsloth/Qwen3-8B-GGUF" && r.Tag == "Q4_K_M", "quant tag")
    } else { check(false, "quant tag parses") }
    if let r = parse("unsloth/Qwen3-8B-GGUF@v2:Q8_0") {
        check(r.Revision == "v2" && r.Tag == "Q8_0" && r.description == "hf.co/unsloth/Qwen3-8B-GGUF@v2:Q8_0", "revision and tag, no host")
    } else { check(false, "revision and tag parse") }
    if let r = parse("https://hf.co/datasets/HuggingFaceFW/fineweb") {
        check(r.Kind == hub.RepoKind.dataset && r.Repo == "HuggingFaceFW/fineweb", "dataset")
        check(r.description == "hf.co/datasets/HuggingFaceFW/fineweb", "dataset round trip")
    } else { check(false, "dataset parses") }
    if let r = parse("hf.co/ggml-org/models-moved/tinyllamas/stories260K.gguf") {
        check(r.Repo == "ggml-org/models-moved" && r.File == "tinyllamas/stories260K.gguf", "file in a repo")
    } else { check(false, "file in a repo parses") }
    if let r = parse("https://huggingface.co/org/name/resolve/refs%2Fpr%2F3/dir/a%20b.json") {
        check(r.Revision == "refs/pr/3" && r.File == "dir/a b.json", "resolve URL, escapes undone")
    } else { check(false, "resolve URL parses") }
    if let r = parse("https://huggingface.co/org/name/blob/v1.0/README.md") {
        check(r.Revision == "v1.0" && r.File == "README.md", "blob URL")
    } else { check(false, "blob URL parses") }
    check(parse("hf.co/justone") == nil, "one segment is refused")
    check(parse("hf.co/org/name@") == nil, "empty revision is refused")
    check(parse("hf.co/org/name:") == nil, "empty tag is refused")
    check(parse("hf.co/org/name/../etc/passwd") == nil, "'..' in a file path is refused")

    // Selecting files.
    let gguf = [
        hub.RepoFile(path: "README.md", size: 10, blobId: "a"),
        hub.RepoFile(path: "Qwen3-8B-Q4_K_M.gguf", size: 100, sha256: "b"),
        hub.RepoFile(path: "Qwen3-8B-Q4_K_S.gguf", size: 90, sha256: "c"),
        hub.RepoFile(path: "Qwen3-8B-Q4_K.gguf", size: 95, sha256: "d"),
        hub.RepoFile(path: "Q8_0/Qwen3-8B-Q8_0-00001-of-00002.gguf", size: 200, sha256: "e"),
        hub.RepoFile(path: "Q8_0/Qwen3-8B-Q8_0-00002-of-00002.gguf", size: 200, sha256: "f"),
        hub.RepoFile(path: "mmproj-Q4_K_M.gguf", size: 5, sha256: "g"),
    ]
    do {
        var r = hub.Ref("unsloth/Qwen3-8B-GGUF")
        r.Tag = "q4_k_m"
        check(paths(try hub.Select(gguf, ref: r)) == ["Qwen3-8B-Q4_K_M.gguf"], "tag picks its quant, not mmproj, any case")
        r.Tag = "Q4_K"
        check(paths(try hub.Select(gguf, ref: r)) == ["Qwen3-8B-Q4_K.gguf"], "Q4_K does not take Q4_K_M")
        r.Tag = "Q8_0"
        check(paths(try hub.Select(gguf, ref: r)).count == 2, "a split quant gives all its shards")
        r.Tag = ""
        check(paths(try hub.Select(gguf, ref: r)) == ["Qwen3-8B-Q4_K_M.gguf"], "no tag: the default quant")
        r.File = "Q8_0"
        check(paths(try hub.Select(gguf, ref: r)).count == 2, "a directory gives what is under it")
        r.File = "README.md"
        check(paths(try hub.Select(gguf, ref: r)) == ["README.md"], "one file")
        r.File = ""
        check(paths(try hub.Select(gguf, ref: r, include: ["*.md"])) == ["README.md"], "include patterns")
    } catch {
        check(false, "select: \(error)")
    }
    do {
        var r = hub.Ref("x/y")
        r.Tag = "IQ2_XXS"
        _ = try hub.Select(gguf, ref: r)
        check(false, "a missing quant throws")
    } catch {
        check(true, "a missing quant throws")
    }
    let safetensors = [
        hub.RepoFile(path: "config.json", size: 1, blobId: "a"),
        hub.RepoFile(path: "model-00001-of-00002.safetensors", size: 1, sha256: "b"),
        hub.RepoFile(path: "model-00002-of-00002.safetensors", size: 1, sha256: "c"),
        hub.RepoFile(path: "onnx/model.onnx", size: 1, sha256: "d"),
    ]
    do {
        check(try hub.Select(safetensors, ref: hub.Ref("a/b")).count == 4, "no tag, no GGUF: everything")
        check(paths(try hub.Select(safetensors, ref: hub.Ref("a/b"), include: ["*.json", "*.safetensors"])).count == 3, "patterns pick")
    } catch {
        check(false, "select: \(error)")
    }

    // Globs.
    check(hub.Match("*.json", "config.json"), "*.json")
    check(hub.Match("*.json", "sub/dir/config.json"), "a pattern without '/' matches the name")
    check(!hub.Match("onnx/*", "onnx/sub/model.onnx"), "* stops at '/'")
    check(hub.Match("onnx/**", "onnx/sub/model.onnx"), "** crosses '/'")
    check(hub.Match("**/*.onnx", "model.onnx"), "**/ matches no directory")
    check(hub.Match("model-?????-of-*.safetensors", "model-00001-of-00002.safetensors"), "?")
    check(!hub.Match("*.json", "config.jsonl"), "no partial match")
    check(hub.Match("/*.json", "config.json") && !hub.Match("/*.json", "sub/config.json"), "a leading '/' anchors at the root")

    // The cache: its layout, refs, links and what it lists back.
    do {
        let root = try fs.TempDir(prefix: "hubtest_")
        let cache = hub.Cache(root: root)
        let dir = cache.RepoDir(hub.RepoKind.dataset, "org/name")
        check(dir.String() == root.String() + "/datasets--org--name", "repository directory")
        let commit = "0123456789abcdef0123456789abcdef01234567"
        check(cache.Commit(hub.RepoKind.model, "a/b", "main") == nil, "no ref yet")
        check(cache.Commit(hub.RepoKind.model, "a/b", commit) == commit, "a commit is its own")
        try cache.SetCommit(hub.RepoKind.model, "a/b", "main", commit)
        check(cache.Commit(hub.RepoKind.model, "a/b", "main") == commit, "ref written and read")

        let sha = "270cba1bd5109f42d03350f60406024560464db173c0e387d91f0426d3bd256d"
        let big = hub.RepoFile(path: "sub/w.gguf", size: 3, sha256: sha)
        let small = hub.RepoFile(path: "config.json", size: 2, blobId: "a6344aac8c09253b3b630fb776ae94478aa0275b")
        check(!cache.HasBlob(hub.RepoKind.model, "a/b", big), "no blob yet")
        try fs.CreateDir(cache.BlobPath(hub.RepoKind.model, "a/b", sha).Parent()!, all: true)
        try fs.WriteFile(cache.BlobPath(hub.RepoKind.model, "a/b", sha), [1, 2, 3])
        try fs.WriteFile(cache.BlobPath(hub.RepoKind.model, "a/b", small.Etag), [123, 125])
        check(cache.HasBlob(hub.RepoKind.model, "a/b", big), "blob found")
        try cache.Link(hub.RepoKind.model, "a/b", commit, big)
        try cache.Link(hub.RepoKind.model, "a/b", commit, small)
        try cache.Link(hub.RepoKind.model, "a/b", commit, small)
        let link = cache.SnapshotDir(hub.RepoKind.model, "a/b", commit) / "sub/w.gguf"
        check(try fs.ReadLink(link).String() == "../../../blobs/\(sha)", "link is relative, one more ../ per directory")
        check(try fs.ReadFile(link) == [1, 2, 3], "link reads the blob")
        let listed = try cache.Files(hub.RepoKind.model, "a/b", commit)
        check(listed == [small, big], "the cache lists the snapshot back")

        // Offline, the cache answers.
        var h = hub.Hub()
        h.Cache = cache
        h.Offline = true
        let snap = try await h.Resolve(try hub.Ref.Parse("hf.co/a/b"))
        check(snap.Commit == commit && snap.Files.count == 2 && snap.Size == 5, "offline resolve from the cache")
        check(snap.Path("config.json").String() == cache.SnapshotDir(hub.RepoKind.model, "a/b", commit).String() + "/config.json", "snapshot paths")
        do {
            _ = try await h.Resolve(try hub.Ref.Parse("hf.co/a/missing"))
            check(false, "offline miss throws")
        } catch {
            check("\(error)".contains("not in the cache"), "offline miss throws notCached")
        }
        try fs.RemoveAll(root)
    } catch {
        check(false, "cache: \(error)")
    }

    if failures == 0 {
        print("\n=== all remote/hub checks passed ===")
        return 0
    }
    print("\n\(failures) failed")
    return 1
}
