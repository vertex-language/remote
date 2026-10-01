# remote/rdp/x224

RDP's transport framing: the TPKT envelope (RFC 1006), the X.224/T.123 connection PDUs, and the RDP security negotiation that rides in the Connection Request and Confirm ([MS-RDPBCGR] 2.2.1.1, 2.2.1.2).

```vertex
import "remote/rdp/x224"
```

## Types

- **`SecurityProtocol`** (struct): SecurityProtocol is a bit in requestedProtocols / a value in selectedProtocol ([MS-RDPBCGR] 2.2.1.1.1).
- **`NegotiationRequestFlag`** (struct): Flags in the RDP_NEG_REQ ([MS-RDPBCGR] 2.2.1.1.1).
- **`NegotiationResponseFlag`** (struct): Flags in the RDP_NEG_RSP ([MS-RDPBCGR] 2.2.1.1.2).
- **`NegotiationFailureCode`** (enum): Reasons a server rejects the requested protocols (RDP_NEG_FAILURE, [MS-RDPBCGR] 2.2.1.1.3).
- **`X224Error`** (enum)
- **`ConnectionRequest`** (struct): ConnectionRequest is the client's first PDU.
- **`ConnectionConfirm`** (struct): ConnectionConfirm is the server's reply: the negotiation response, or a failure ([MS-RDPBCGR] 2.2.1.2).
- **`Frame`** (enum): A frame taken off the wire: either a slow-path TPKT PDU or a fast-path update ([MS-RDPBCGR] 2.2.9.1).
- **`FrameSplitter`** (struct): FrameSplitter turns a byte stream into whole frames. Feed it what the socket read; call Next until it returns nil, then read more.

## Functions

- `func WrapData(_ payload: [uint8]) -> [uint8]`: WrapData wraps a payload in an X.224 Data PDU inside a TPKT. This is the "slow path": MCS and share-control PDUs travel this way.
- `func UnwrapData(_ frame: [uint8]) throws -> [uint8]`: UnwrapData returns the payload of an X.224 Data PDU (the caller has already read a whole TPKT frame, e.g.

Part of the [`remote`](https://github.com/vertex-language/remote) repository.
