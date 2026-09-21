// The 'remote' package: protocols for remote access to an interactive
// desktop, terminal or device. rdp is the first; vnc and ssh belong here too.
import PackageDescription

let package = Package(
    name: "remote",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "remote/rdp", targets: ["rdp"]),
        .library(name: "remote/rdp/x224", targets: ["rdp_x224"]),
        .library(name: "remote/rdp/wire", targets: ["rdp_wire"]),
        .library(name: "remote/rdp/gfx", targets: ["rdp_gfx"]),
        .library(name: "remote/rdp/fastpath", targets: ["rdp_fastpath"]),
        .library(name: "remote/rdp/codec/interleaved", targets: ["rdp_codec_interleaved"]),
        .library(name: "remote/rdp/codec/planar", targets: ["rdp_codec_planar"]),
        .executable(name: "rdp-test", targets: ["rdp_test"]),
        .executable(name: "rdp-codec-test", targets: ["rdp_codec_test"]),
        .executable(name: "rdp-screenshot", targets: ["rdp_screenshot"]),
    ],
    targets: [
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
    ]
)
