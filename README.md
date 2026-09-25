# remote

[![package: vs-package](https://img.shields.io/badge/package-vs--package-f4f4f5?style=flat-square&labelColor=e4e4e7&color=18181b)](https://github.com/vertex-language)
[![protocols: rdp](https://img.shields.io/badge/protocols-rdp-f4f4f5?style=flat-square&labelColor=e4e4e7&color=18181b)](https://github.com/vertex-language/remote)

Protocols for remote desktop, terminal, and device access: interactive screen framebuffers, input handling, and session negotiation.

---

## Quick Start

Run any entry point with:

```bash
vsc run main.vs
```

---

## Packages

| Package | What it is |
| :--- | :--- |
| **`remote/rdp`** | RDP client: TCP → X.224 → TLS 1.2 → CredSSP/NTLMv2 (NLA) → MCS/GCC → licensing → capabilities → an active session that decodes the desktop into a framebuffer and sends keyboard and mouse input. |
| `remote/rdp/x224` | TPKT, X.224, security negotiation, the TPKT/fast-path frame splitter. |
| `remote/rdp/wire` | The PER/BER subsets MCS and GCC use. |
| `remote/rdp/fastpath` | Fast-path update parsing and fragment reassembly. |
| `remote/rdp/gfx` | The RGBA framebuffer and damage rectangles. |
| `remote/rdp/codec/interleaved` | Interleaved RLE bitmaps (8–24 bpp). |
| `remote/rdp/codec/planar` | RDP 6.0 planar bitmaps (32 bpp). |

| **`rdpviewer`** | The app: a remote desktop in a window (`ui/window`) — display, keyboard, mouse, wheel, the remote pointer, sharp text on Retina. |

Authentication and TLS live in `crypto/` (`tls`, `credssp`, `ntlm`, `x509`, …).

---

## rdpviewer

```bash
RDP_PASSWORD=… vsc run rdpviewer -- connection.rdp        # or: host[:port] user
```

Options: `--size WxH` (points), `--cmd-as-win` (Command is the Windows key rather than Control), `--no-hidpi`. The password is asked for when `RDP_PASSWORD` isn't set.

---

## Tests

```bash
vsc run rdp-test          # x224 against spec bytes
vsc run rdp-codec-test    # codecs and fast-path
```

---

## License

[MIT](LICENSE)
