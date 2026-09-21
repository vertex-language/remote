# remote

[![package: stdlib](https://img.shields.io/badge/package-stdlib-f4f4f5?style=flat-square&labelColor=e4e4e7&color=18181b)](https://github.com/vertex-language)

Protocols for remote access to an interactive desktop, terminal or device.
`net/` moves bytes; the packages here interpret them as a screen, a keyboard
and a mouse. RDP is the first; VNC and SSH belong here too.

---

## Packages

| Package | What it is |
| :--- | :--- |
| **`remote/rdp`** | RDP client for stock Windows: TCP → X.224 → TLS 1.2 → CredSSP/NTLMv2 (NLA) → MCS/GCC → licensing → capabilities → an active session that decodes the desktop into a framebuffer and sends keyboard and mouse input. The only rdp package that does I/O. |
| `remote/rdp/x224` | TPKT, X.224, security negotiation, the TPKT/fast-path frame splitter. |
| `remote/rdp/wire` | The PER/BER subsets MCS and GCC use. |
| `remote/rdp/fastpath` | Fast-path update parsing and fragment reassembly. |
| `remote/rdp/gfx` | The RGBA framebuffer and damage rectangles. |
| `remote/rdp/codec/interleaved` | Interleaved RLE bitmaps (8–24 bpp). |
| `remote/rdp/codec/planar` | RDP 6.0 planar bitmaps (32 bpp). |

Authentication and TLS live in `crypto/` (`tls`, `credssp`, `ntlm`, `x509`, …).

## Tests

```bash
vsc build
./.build/vsc/debug/rdp-test          # x224 against spec bytes
./.build/vsc/debug/rdp-codec-test    # codecs and fast-path
./.build/vsc/debug/rdp-screenshot <host[:port]> <user> <password> desktop.png   # live
```
