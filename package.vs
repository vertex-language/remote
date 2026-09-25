// The 'remote' package: remote services and protocols -- the Hugging Face
// Hub (hub), and remote access to an interactive desktop, terminal or
// device (rdp; vnc and ssh belong here too).
import PackageDescription

let package = Package(
    name: "remote",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "remote/hub", targets: ["hub"]),
        .library(name: "remote/rdp", targets: ["rdp"]),
        .library(name: "remote/rdp/x224", targets: ["rdp_x224"]),
        .library(name: "remote/rdp/wire", targets: ["rdp_wire"]),
        .library(name: "remote/rdp/gfx", targets: ["rdp_gfx"]),
        .library(name: "remote/rdp/fastpath", targets: ["rdp_fastpath"]),
        .library(name: "remote/rdp/codec/interleaved", targets: ["rdp_codec_interleaved"]),
        .library(name: "remote/rdp/codec/planar", targets: ["rdp_codec_planar"]),
        .executable(name: "hub", targets: ["hub_tool"]),
        .executable(name: "rdpviewer", targets: ["rdpviewer"]),
        .executable(name: "rdp-test", targets: ["rdp_test"]),
        .executable(name: "rdp-codec-test", targets: ["rdp_codec_test"]),
        .executable(name: "rdp-screenshot", targets: ["rdp_screenshot"]),
        .executable(name: "rdp-input", targets: ["rdp_input"]),
        .executable(name: "rdp-run", targets: ["rdp_run"]),
        .executable(name: "hub-test", targets: ["hub_test"]),
        .executable(name: "hub-live-test", targets: ["hub_live_test"]),
    ],
    targets: [
        // The Hugging Face Hub: references, resolving them to a commit,
        // and downloads into Hugging Face's own cache.
        .target(
            name: "hub",
            path: "hub"
        ),
        // The command line: resolve, download, list the cache.
        .executableTarget(
            name: "hub_tool",
            dependencies: ["hub"],
            path: "hubtool"
        ),
        // References, selection, globs and the cache, offline.
        .executableTarget(
            name: "hub_test",
            dependencies: ["hub"],
            path: "tests/hub"
        ),
        // Live: resolve and download from huggingface.co.
        .executableTarget(
            name: "hub_live_test",
            dependencies: ["hub"],
            path: "tests/hub_live"
        ),
        // RDP transport framing: TPKT, X.224, security negotiation, and the
        // TPKT/fast-path frame splitter ([MS-RDPBCGR] 2.2.1).
        .target(
            name: "rdp_x224",
            path: "rdp/x224"
        ),
        // PER/BER primitives for MCS and GCC.
        .target(
            name: "rdp_wire",
            path: "rdp/wire"
        ),
        // The framebuffer and rectangles the codecs decode into.
        .target(
            name: "rdp_gfx",
            path: "rdp/gfx"
        ),
        // Fast-path update parsing and fragment reassembly.
        .target(
            name: "rdp_fastpath",
            path: "rdp/fastpath"
        ),
        // Bitmap codecs: interleaved RLE (<= 24 bpp) and RDP 6.0 planar (32 bpp).
        .target(
            name: "rdp_codec_interleaved",
            path: "rdp/codec/interleaved"
        ),
        .target(
            name: "rdp_codec_planar",
            path: "rdp/codec/planar"
        ),
        // The client (package rdp): connection sequence, session, input.
        // The only rdp package that does I/O.
        .target(
            name: "rdp",
            dependencies: ["rdp_x224", "rdp_wire", "rdp_gfx", "rdp_fastpath",
                           "rdp_codec_interleaved", "rdp_codec_planar"],
            path: "rdp",
            exclude: ["x224", "wire", "gfx", "fastpath", "codec"]
        ),
        // A remote desktop in a window: remote/rdp over ui/window.
        .executableTarget(
            name: "rdpviewer",
            dependencies: ["rdp"],
            path: "rdpviewer"
        ),
        // x224 PDUs checked against bytes from the spec.
        .executableTarget(
            name: "rdp_test",
            dependencies: ["rdp_x224"],
            path: "tests/rdp"
        ),
        // Codecs and fast-path parsing checked against captured updates.
        .executableTarget(
            name: "rdp_codec_test",
            dependencies: ["rdp_codec_interleaved", "rdp_codec_planar", "rdp_fastpath", "rdp_gfx"],
            path: "tests/rdp_codec"
        ),
        // Live: connect, let the desktop draw, write it to a PNG.
        .executableTarget(
            name: "rdp_screenshot",
            dependencies: ["rdp", "rdp_gfx"],
            path: "tests/rdp_screenshot"
        ),
        // Live: keyboard and mouse input from one task while another pumps.
        .executableTarget(
            name: "rdp_input",
            dependencies: ["rdp"],
            path: "tests/rdp_input"
        ),
        // Live: run a command through Win+R and screenshot it.
        .executableTarget(
            name: "rdp_run",
            dependencies: ["rdp"],
            path: "tests/rdp_run"
        ),
    ]
)
