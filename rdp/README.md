# remote/rdp

RDP client: TCP → X.224 → TLS 1.2 → CredSSP/NTLMv2 (NLA) → MCS/GCC → licensing → capabilities → an active session that decodes the desktop into a framebuffer and sends keyboard and mouse input.

```vertex
import "remote/rdp"
```

## Types

- **`Config`** (struct): Config configures an RDP connection.
- **`ConnectionInfo`** (struct): ConnectionInfo records what the connection sequence negotiated.
- **`RdpError`** (enum): RdpError is any failure in the RDP connection or session.
- **`PointerFlags`** (struct): Pointer flags for mouse events ([MS-RDPBCGR] 2.2.8.1.1.3.1.1.3).
- **`MouseButton`** (enum): MouseButton names the buttons Input.Button takes.
- **`Scancode`** (struct): Scancode is a key's scan code set 1 make code, with the E0 prefix folded in as Extended.
- **`Input`** (struct): Input sends keyboard and mouse events.
- **`ClientData`** (struct): ClientData holds the parameters carried in the GCC client blocks.
- **`ServerChannels`** (struct): ServerChannels holds the channel IDs parsed from the Connect Response.
- **`DemandActive`** (struct): DemandActive holds what we need from the server's Demand Active PDU: the share id and the desktop size from its Bitmap capability set.
- and 6 more

## Functions

- `func Connect(_ address: string, config: Config) async throws -> Session`: Connect dials a Windows host, authenticates with NLA, and runs the connection sequence; the returned Session then streams the desktop.
- `func ConnectTraced(_ address: string, config: Config) async throws -> Session`: ConnectTraced is Connect with the connection sequence printed.
- `func ConnectForTest(_ address: string, config: Config, trace: bool) async throws -> (Transport, ConnectionInfo)`: ConnectForTest exposes the pre-graphics connection sequence for tests.
- `func ScancodeForCode(_ code: string) -> Scancode?`: ScancodeForCode maps a W3C KeyboardEvent.code name ("KeyA", "Enter", "ArrowLeft", "NumpadEnter", …) to its scan code, or nil for a code with none.
- `func ParseFile(_ bytes: [uint8]) -> File`: ParseFile reads an .rdp file's bytes: UTF-8, or UTF-16LE with a byte order mark as mstsc writes them.
- `func describeErrorInfo(_ code: uint32) -> string`: describeErrorInfo names a Set Error Info code ([MS-RDPBCGR] 2.2.5.1.1).

Part of the [`remote`](https://github.com/vertex-language/remote) repository.
