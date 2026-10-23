# Paxby — two radios: BLE + Wi-Fi Direct

> **Status: partly built.** Phase 0 (`MultiTransport`, Dart only) is
> implemented and unit-tested — see `lib/transport/multi_transport.dart` and
> `test/multi_transport_test.dart`. Everything from Phase 1 on is still a
> proposal: nothing BLE-related is built, and none of it is claimed to work. This
> document exists so the work is reviewed *before* it starts, and so the project
> never ships a claim it hasn't tested on real phones.

## 1. The goal

Today Paxby has exactly one transport: **Wi-Fi Direct** on Android. It is fast
and it carries PNGs, but it has real weaknesses:

- some phones/OEMs expose it badly or not at all;
- it needs a peer that supports Wi-Fi Direct;
- it stops working while the phone is sharing a **hotspot**;
- it is comparatively power-hungry.

**Bluetooth Low Energy (BLE)** is the complement: it is on virtually every
phone, it sips power, and it reaches places Wi-Fi Direct does not — at the cost
of bandwidth and range.

The goal is **one protocol, two radios**:

```
        ┌──────────────── MultiTransport ────────────────┐
        │  prefer Wi-Fi Direct for size / speed          │
        │  fall back to BLE for reach / power            │
        └───────┬─────────────────────────────┬──────────┘
                │                             │
   PlatformTransport (Wi-Fi Direct)     BleTransport (BLE GATT)
        │  shipped & hardware-verified       │  new
        └── MethodChannel("findit/transport")└── MethodChannel("findit/ble")
```

Everything above the transport is **already** transport-agnostic: the routing
engine moves opaque, end-to-end-encrypted **bundles**, and never asks which link
carried one. That is why this is an addition, not a rewrite.

## 2. What "both radios" must actually do

Testable acceptance criteria, in order:

1. **Discover** the same peer on either radio.
2. **Connect** on either radio, independently.
3. **One peer = one session.** If a peer is reachable on both radios, the app
   must still show them once. *(Already shipped: the routing engine collapses two
   sockets that handshake to the same identity.)*
4. **Same bundles, either link** — a message is an encrypted bundle, so it is
   carried identically over Wi-Fi Direct or BLE, and may hop between them.
5. **A preference policy** — Wi-Fi Direct for throughput (PNGs), BLE for reach.

## 3. The finding that shapes the work

The current native contract is **TCP-shaped**: native establishes connectivity
and returns the peer's `host`/`port`; then Dart opens a `Socket` and runs the
framing over it (`lib/transport/platform_transport.dart` binds a `ServerSocket`
and dials `Socket.connect`).

**BLE has no IP and no sockets.** So one of these has to happen:

- **(A) Native BLE→TCP bridge.** Native pipes GATT bytes into a loopback TCP
  socket, so Dart's existing code is unchanged. Minimal Dart work, but it hides a
  serial link behind a TCP shim and doubles buffering.
- **(B) A separate `BleTransport`.** Implement the existing `Transport` seam
  (already the right shape) over a new native BLE channel, framing bytes itself.
  More code, but it keeps `PlatformTransport` — which is verified and working —
  **completely untouched**.

**Recommendation: (B).** The seam exists precisely for this. The public
`TransportConnection` API is frame-oriented (`bundles`, `summaries`,
`handshake`), so BLE does not need to pretend to be a socket. However, the
current `FrameStream` implementation takes a Dart `Socket` directly; it cannot
be reused by a GATT connection as-is. Extract a socket-independent framing
codec/channel or implement equivalent BLE framing and keep the wire format
compatible before claiming that all transports carry identical frames.

## 3a. Decisions required before native BLE work

The phases below describe the work, but these protocol and lifecycle choices
need to be settled as part of Phase 1 so the Dart/native contract is testable:

- **GATT roles and arbitration:** define which peer is the GATT central and
  which is the peripheral when both advertise and scan. Reuse the per-transport
  rotating handles for deterministic arbitration, and specify recovery when
  either side's preferred role cannot be established.
- **GATT characteristics:** specify service UUID and the direction/properties
  of the data characteristics (for example, writes toward the server and
  notifications back). A single bidirectional characteristic needs explicit
  handling for Android's write and notification semantics.
- **Chunk protocol and flow control:** define frame chunk headers, ordering,
  acknowledgements, retry/timeout behavior, MTU changes, disconnect during a
  frame, and limits on queued/in-flight bytes. GATT writes are not a TCP byte
  stream, and a method-channel event should not carry an unbounded bundle.
- **Payload policy:** choose how BLE handles large bundles and PNGs. Either
  transfer them with bounded chunks and backpressure, or document/enforce a
  size threshold and let routing wait for Wi-Fi Direct. The current acceptance
  list asks for PNG transfer over either link, so that requirement needs to be
  reconciled with the low BLE throughput before implementation.
- **Lifecycle and resource limits:** define behavior for permission revocation,
  Bluetooth/radio toggles, app backgrounding, reconnect, and the maximum number
  of simultaneous GATT links. Keep the existing networking consent switch as
  the master on/off gate.
- **Testable contract:** spell out how `connectionId`, peer handle, MTU, and
  frame events are correlated, and how disconnect/lost events release pending
  Dart futures and native GATT resources.

## 4. Phase 0 — `MultiTransport` (Dart only, no hardware) — **built**

The safe, fully-testable first step. Nothing about it depends on BLE existing.

**Built:** `lib/transport/multi_transport.dart`

- `implements Transport`, wrapping an ordered `List<Transport>` (preference order:
  Wi-Fi Direct first, BLE second).
- **Handle ownership:** discovery from every child is merged, and a
  `handle → child` map remembers which child a handle belongs to.
- `connect(peerId)` routes to the owning child.
- `updateAdvertisement` fans out to every child.
- `discoveredPeers` / `lostPeers` / `incomingConnections` are merged (broadcast,
  re-broadcast safely).
- `errors`: fan-in.
- `localId`: the first child's. `localIdFor(peerId)`: the owning child's, so the
  routing engine's dial tie-break compares matching handles when several radios
  are on at once.
- `capabilities`: union (so the UI can say "two links").

**Current scope:** this composition layer is implemented and tested in
isolation, but production `AppBootstrap` still constructs `PlatformTransport`
directly. Wiring it into the app is still Phase 3 work; the class is not yet a
production two-radio setup.

**Tests:** `test/multi_transport_test.dart`, with two fake transports:

- a handle routes to the child that owns it;
- `connect` falls back through the children in preference order;
- `localIdFor` answers per link and falls back to the preferred child;
- `start`/`stop`/`dispose` fan out, and a partial start failure is reported
  without taking the other radio down;
- discovery and loss events merge.

## 5. Phase 1 — BLE contract + Dart `BleTransport`

**New native channel** `findit/ble` (mirrors the structure of
`platform_transport_contract.dart`, `TransportContract.kt`):

- methods: `start`, `stop`, `updateAdvertisement`, `connect`, `disconnect`,
  `sendFrame`, `close`;
- events: `discovered`, `lost`, `accepted`, `frameIn`, `errors`;
- `connect` answers with a socket-free connection id and the peer's MTU.
- Define native events and method-channel payload limits alongside the framing
  and backpressure decisions above; GATT callbacks and Flutter channel delivery
  must not accumulate unbounded frame data.

**New:** `lib/transport/ble_transport.dart`

- `implements Transport`;
- `connect()` returns a `BleConnection implements TransportConnection` that
  carries frames over the event channel, using the socket-independent framing
  channel extracted in Phase 1 (or an equivalent tested BLE codec);
- simulated in tests with a fake gateway (same approach as
  `test/platform_transport_test.dart`).

**Permissions (native):** `BLUETOOTH_SCAN` (`neverForLocation`),
`BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE` on API 31+; the legacy
`BLUETOOTH`/`BLUETOOTH_ADMIN` pair below 31.

## 6. Phase 2 — `BleEngine.kt` (Android)

The largest and least deterministic part. **Not** the Bluetooth SIG "Mesh"
profile — that is for sensors; Paxby's own routing already does the
store-carry-forward part.

- **GATT server + client** with one service and one framed characteristic.
- **Advertisement** carries a service UUID plus the **rotating** handle (same
  rotation rule as Wi-Fi Direct today); the permanent identity id still never
  leaves the device.
- **Scan** filtered by the service UUID.
- **Framing:** request MTU (~517), chunk each frame to `MTU − 3`, and apply
  simple flow control (one un-acknowledged write, queued).
- **Background survival:** the existing `NetworkingService` foreground service is
  the right host; it will need a `foregroundServiceType` that permits
  connected-device work.

## 7. Phase 3 — Wiring & UX

- `AppBootstrap` composes a `MultiTransport`.
- `AppServices` keeps working (`platformTransport` getter must still find the
  Wi-Fi Direct child for notifications, hotspot and permission helpers).
- Nearby: show the link a peer is using (optional, and only if it can be stated
  truthfully).
- Preference: attempt Wi-Fi Direct first; only settle on BLE when no Wi-Fi Direct
  peer is available.

## 8. Testing and acceptance

- **Unit (Dart):** Phases 0 and 1 with fake gateways — must pass in CI.
- **JVM:** `BleEngine` chunking / queue logic where it can be isolated.
- **Hardware:** a manual matrix on the Moto Edge 60 Pro + Samsung SM-G990E
  (and ideally a third phone): discover, connect, text, the agreed PNG/size
  policy, app background/foreground, permission and radio changes, and hand-off
  when the other radio appears.
- **Release rule:** the README may only claim BLE once the two-phone test passes.
  Until then it stays "planned".

## 9. Risks

| Risk | Mitigation |
| --- | --- |
| Android throttles background BLE scans | Foreground service (`connectedDevice`), connected-first design |
| PNGs are slow over BLE (~0.1–1 Mbps) | Prefer Wi-Fi Direct; use BLE for text/presence |
| OEM GATT quirks (Samsung, Motorola) | Test on both phones first |
| GATT server connection limits | Cap concurrent links, prefer newest |
| Permission model differs ≤ API 30 | Keep the existing permission helper and add the BLE set |
| Wi-Fi Direct and BLE share an antenna | Accept time-slicing; test both active |
| Battery | BLE only on demand; keep the scan window short |

## 10. Suggested order

1. **Phase 0 — `MultiTransport`.** *Done and unit-tested.*
2. **Phase 1 — contract + `BleTransport` (Dart).** Testable on loopback.
3. **Phase 2 — `BleEngine.kt`.** Needs the two phones; the long pole.
4. **Phase 3 — wiring + preference**, then honest docs.

Phase 1 is ordinary Flutter work and can be done here. Phase 2 needs your phones
and a real testing session.

## 11. Non-goals

- The Bluetooth SIG **Mesh profile**. (We would reuse Paxby's routing instead.)
- iOS BLE. (The Dart side would port, but the iOS native transport isn't built.)
- Any internet or server relay. There still isn't one.
