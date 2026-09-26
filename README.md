# remote

[![package: vs-package](https://img.shields.io/badge/package-vs--package-f4f4f5?style=flat-square&labelColor=e4e4e7&color=18181b)](https://github.com/vertex-language)
[![services: hub | rdp](https://img.shields.io/badge/services-hub%20%7C%20rdp-f4f4f5?style=flat-square&labelColor=e4e4e7&color=18181b)](https://github.com/vertex-language/remote)

Remote services and protocols: the Hugging Face Hub, and remote desktop, terminal, and device access.

---

## Quick Start

Run tools and services in `cmd/` directly with `vsc run`:

```bash
# Resolve and download from Hugging Face Hub
vsc run hub -- resolve hf.co/unsloth/Qwen3-0.6B-GGUF
vsc run hub -- download hf.co/Qwen/Qwen3-0.6B --include '*.json'

# Launch the RDP viewer
RDP_PASSWORD=… vsc run rdpviewer -- connection.rdp

# Run test suites
vsc run hub-test
vsc run rdp-test
```

---

## Packages

| Package | What it is |
| :--- | :--- |
| **`remote/hub`** | The Hugging Face Hub: a reference (`hf.co/org/name@rev:Q4_K_M`) resolved to a commit and its files, downloaded into Hugging Face's own cache (`~/.cache/huggingface/hub`), resumable and hash-checked. |
| **`remote/rdp`** | RDP client: TCP → X.224 → TLS 1.2 → CredSSP/NTLMv2 (NLA) → MCS/GCC → licensing → capabilities → an active session that decodes the desktop into a framebuffer and sends keyboard and mouse input. |
| `remote/rdp/x224` | TPKT, X.224, security negotiation, the TPKT/fast-path frame splitter. |
| `remote/rdp/wire` | The PER/BER subsets MCS and GCC use. |
| `remote/rdp/fastpath` | Fast-path update parsing and fragment reassembly. |
| `remote/rdp/gfx` | The RGBA framebuffer and damage rectangles. |
| `remote/rdp/codec/interleaved` | Interleaved RLE bitmaps (8–24 bpp). |
| `remote/rdp/codec/planar` | RDP 6.0 planar bitmaps (32 bpp). |

| **`hub`** | The command line: `hub resolve`, `hub download`. |
| **`rdpviewer`** | The app: a remote desktop in a window (`ui/window`) — display, keyboard, mouse, wheel, the remote pointer, sharp text on Retina. |

Authentication and TLS live in `crypto/` (`tls`, `credssp`, `ntlm`, `x509`, …).

---

## hub

```vertex
import "remote/hub"

let snap = try await hub.Download("hf.co/unsloth/Qwen3-0.6B-GGUF:Q8_0")
let weights = snap.Path(snap.Files[0].Path)      // …/snapshots/<commit>/Qwen3-0.6B-Q8_0.gguf
```

| Reference | Means |
| :--- | :--- |
| `hf.co/Qwen/Qwen3-8B` | the whole repository at `main` |
| `hf.co/Qwen/Qwen3-8B@a1b2c3d` | at a branch, tag or commit |
| `hf.co/unsloth/Qwen3-8B-GGUF:Q4_K_M` | a quant's GGUF file(s); with no tag a GGUF repository gives `Q4_K_M` |
| `hf.co/org/name/path/in/repo` | one file, or what is under a directory |
| `hf.co/datasets/org/name`, `hf.co/spaces/org/name` | a dataset, a space |
| `https://huggingface.co/org/name/resolve/main/file` | a file URL as the Hub writes it |

`Hub.Resolve` pins a reference to a commit and lists its files (sizes, sha256) without fetching them; `Hub.Download` fetches what the cache lacks. Files land in the cache huggingface_hub uses — `blobs/<sha256>`, `snapshots/<commit>/<path>` as relative symlinks, `refs/<branch>` — so what Python already fetched is found. A download goes to `<blob>.incomplete`, resumes with a range request, and is renamed into place only once its sha256 (or git blob id, for small files) is right. `Hub.Include` takes globs (`*.json`, `**/*.safetensors`); `Hub.OnProgress` reports.

It reads the environment huggingface_hub does: `HF_TOKEN` (or the token `hf auth login` saved), `HF_ENDPOINT`, `HF_HOME` / `HF_HUB_CACHE`, `HF_HUB_OFFLINE`. The token goes only to the endpoint, never to the CDN it redirects to. Offline, or when the Hub cannot be reached, the cache answers.

```bash
vsc run hub -- resolve hf.co/unsloth/Qwen3-0.6B-GGUF
vsc run hub -- download hf.co/Qwen/Qwen3-0.6B --include '*.json' --include '*.safetensors'
```

---

## rdpviewer

```bash
RDP_PASSWORD=… vsc run rdpviewer -- connection.rdp        # or: host[:port] user
```

Options: `--size WxH` (points), `--cmd-as-win` (Command is the Windows key rather than Control), `--no-hidpi`. The password is asked for when `RDP_PASSWORD` isn't set.

---

## Tests

```bash
vsc run hub-test          # references, file selection, globs, the cache (offline)
vsc run hub-live-test     # resolve and download from huggingface.co
vsc run rdp-test          # x224 against spec bytes
vsc run rdp-codec-test    # codecs and fast-path
```

---

## License

[MIT](LICENSE)
