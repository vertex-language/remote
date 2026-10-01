# remote/hub

Gets models, datasets and spaces from the Hugging Face Hub: it resolves a reference to a pinned commit and its files, and downloads them into the Hugging Face cache, in Hugging Face's own layout, so what Python tools already fetched is found and nothing is fetched twice.

```vertex
import "remote/hub"
```

## Types

- **`Cache`** (struct): Cache is the Hugging Face hub cache, in Hugging Face's layout, shared with huggingface_hub and everything built on it: <root>/models--org--name/ blobs/<etag> each file's content, by its etag snapshots/<commit>/<path> a symlink to ../../blobs/<etag> refs/<revision> the commit a branch or tag was at
- **`Snapshot`** (struct): Snapshot is a repository pinned to a commit, and the files a reference asked for.
- **`Progress`** (struct): Progress is how a download is going: the file being fetched, the bytes of it done and its size, and the same over all the files.
- **`Hub`** (struct): Hub talks to a Hugging Face hub and keeps what it fetches in a Cache.
- **`RepoKind`** (enum): RepoKind is what a repository holds; each lives under its own path.
- **`Ref`** (struct): Ref is a reference to a repository, or to files in one: hf.co/Qwen/Qwen3-8B the default branch hf.co/Qwen/Qwen3-8B@a1b2c3d a revision: a branch, tag or commit hf.co/unsloth/Qwen3-8B-GGUF:Q4_K_M the GGUF file(s) of a quant hf.co/datasets/HuggingFaceFW/fineweb a dataset (spaces/ for a space) hf.co/org/name/sub/file.gguf one file in the repository https://huggingface.co/org/name/resolve/main/file.gguf a file URL "hf.co/" may be written "huggingface.co/", with or without https://, or left out ("Qwen/Qwen3-8B").
- **`HubError`** (enum): HubError is what went wrong talking to the Hub or with its cache.
- **`RepoFile`** (struct): RepoFile is one file of a repository at a commit.

## Functions

- `func Resolve(_ ref: string) async throws -> Snapshot`: Resolve pins a reference ("hf.co/org/name@rev:TAG") with the default Hub.
- `func Download(_ ref: string) async throws -> Snapshot`: Download fetches what a reference asks for into the cache with the default Hub, and returns the snapshot it is in.
- `func Select(_ files: [RepoFile], ref: Ref, include: [string] = []) throws -> [RepoFile]`: Select is the files of a repository that a reference asks for: one file (or the files under a directory) by its File; a quant's GGUF files by its Tag; else those that match one of the patterns, or all of them when there are no patterns.
- `func Match(_ pattern: string, _ path: string) -> bool`: Match reports whether path matches a glob pattern: '*' is any run of characters but '/', "**" any run including '/', '?' any one character.

Part of the [`remote`](https://github.com/vertex-language/remote) repository.
