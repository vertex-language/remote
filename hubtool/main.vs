// hub: resolve and download from the Hugging Face Hub into its cache.
//
//     hub resolve  hf.co/unsloth/Qwen3-8B-GGUF:Q4_K_M
//     hub download hf.co/Qwen/Qwen3-8B --include '*.json' --include '*.safetensors'
//     hub download hf.co/ggml-org/models-moved/tinyllamas/stories260K.gguf
package main

import "remote/hub"

func usage() -> int32 {
    print("usage: hub resolve  <ref> [--include GLOB]... [--offline]")
    print("       hub download <ref> [--include GLOB]... [--offline] [--quiet]")
    print("")
    print("ref:   hf.co/org/name[@revision][:QUANT][/path/in/repo]")
    print("       hf.co/datasets/org/name, a huggingface.co file URL")
    print("env:   HF_TOKEN, HF_ENDPOINT, HF_HOME, HF_HUB_CACHE, HF_HUB_OFFLINE")
    return 2
}

func size(_ n: int64) -> string {
    if n < 0 {
        return "?"
    }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = float64(n)
    var u = 0
    while v >= 1000 && u < units.count - 1 {
        v /= 1000
        u += 1
    }
    if u == 0 {
        return "\(n) B"
    }
    let tenths = int64(v * 10 + 0.5)
    return "\(tenths / 10).\(tenths % 10) \(units[u])"
}

func main() async -> int32 {
    let args = CommandLine.arguments
    if args.count < 3 {
        return usage()
    }
    let command = args[1]
    var h = hub.Hub()
    var refText = ""
    var quiet = false
    var i = 2
    while i < args.count {
        let a = args[i]
        if a == "--include" && i + 1 < args.count {
            h.Include.append(args[i + 1])
            i += 1
        } else if a == "--offline" {
            h.Offline = true
        } else if a == "--quiet" {
            quiet = true
        } else if refText.isEmpty && !a.hasPrefix("-") {
            refText = a
        } else {
            return usage()
        }
        i += 1
    }
    if refText.isEmpty {
        return usage()
    }
    do {
        let ref = try hub.Ref.Parse(refText)
        switch command {
        case "resolve":
            let snap = try await h.Resolve(ref)
            print("\(ref) @ \(snap.Commit)")
            for f in snap.Files {
                print("  \(f.Path)  \(size(f.Size))  \(f.Etag)")
            }
            print("\(snap.Files.count) files, \(size(snap.Size))")
        case "download":
            if !quiet {
                h.OnProgress = { p in
                    if p.Done == p.Size {
                        print("  \(p.File)  \(size(p.Size))")
                    } else {
                        let pct = p.Total > 0 ? p.TotalDone * 100 / p.Total : 0
                        print("  \(p.File)  \(size(p.Done)) / \(size(p.Size))  (\(pct)%)")
                    }
                }
            }
            let snap = try await h.Download(ref)
            print(snap.Dir.String())
        default:
            return usage()
        }
    } catch {
        print("\(error)")
        return 1
    }
    return 0
}
