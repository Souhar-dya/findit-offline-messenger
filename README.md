# FindIt

A privacy-focused, **decentralized, offline-first** messenger for Android/iOS that
exchanges **text** and **PNG** messages. There is no backend, no cloud, no account
and no mandatory internet or Bluetooth. Messages travel between peers with
**store-carry-forward routing** over a **replaceable peer-to-peer transport**.

> GitHub-style status: this is a working **MVP**. The full protocol stack
> (identity, mutual friend discovery, encrypted messaging, PNG transfer,
> routing/relaying) is implemented and covered by an automated test suite that
> runs end-to-end over the built-in *simulated* transport, and the new
> **platform transport seam** (Dart `PlatformTransport` + native Wi-Fi
> Direct/Aware/local-network) is fully tested in Dart over real loopback TCP
> sockets. The **Android Wi-Fi Direct fabric is now implemented** (peer
> discovery, service advertisement, group formation) and is compile-, lint- and
> JVM-unit-test-verified, but its **radio path is not yet verified on hardware**
> (that needs two physical devices). Wi-Fi Aware is still a stub and the
> iOS/Swift side is unverified. See
> [Transport & connectivity](#transport--connectivity).

---

## Download & install (Android)

The easiest way to try FindIt is to side-load the APK. Every tagged release is
built and published automatically by GitHub Actions.

1. On your Android phone, open the [latest release](../../releases/latest).
2. Download the `findit-*.apk` asset.
3. Allow installing from this source when Android asks
   (**Settings → Apps → Special app access → Install unknown apps** → your
   browser or file manager).
4. Open the downloaded file to install.
5. On first launch: accept the terms, then turn **the one switch** on to start.

The APK is built from source by
[`.github/workflows/android-release.yml`](.github/workflows/android-release.yml),
which runs the analyzer and the full test suite before building. It is signed
with the Android **debug** key for now, so Play Protect may warn about an
unknown developer — expected for a side-loaded prototype. To ship further,
replace the debug signing in `android/app/build.gradle.kts` with a real keystore
supplied through CI secrets.

**iOS is not offered as a download** — it needs an Apple Developer account and
TestFlight/App Store review. Desktop and web builds are possible, but the real
transport is Android Wi-Fi Direct, so they only exercise the *simulated*
network.

### Cutting a release

```sh
# keep the tag in step with `version:` in pubspec.yaml
git tag v0.1.0
git push origin v0.1.0
```

---

## What works today

| Area | Status |
| --- | --- |
| Terms & consent gate | ✅ versioned terms shown before any networking; no data moves until the user explicitly agrees |
| Onboarding + local identity creation | ✅ create, persist (secure storage + SQLite), load across restarts |
| Identity QR (public info only) | ✅ display and scan; QR carries only the signed identity record |
| Mutual friend protocol | ✅ request / accept / confirm / decline, 7-day expiry, duplicate-safe, simultaneous-request reconciliation, block |
| Encrypted messaging | ✅ text messages, authenticated ECIES encryption, sender signature, signed delivery receipts |
| PNG messaging | ✅ lossless PNG send/receive, integrity hash, validation, storage quotas |
| Store-carry-forward routing | ✅ no hop limit, 24h TTL, relay through intermediate peers, replication budget, dedup, receipts stop forwarding |
| Single master switch (radio silent) | ✅ **off by default**; while off the app is radio silent and shows **only the switch** — discovery never starts and nothing is sent or received (not even your own messages). Switching it on starts discovery and send/receive, and lets the device carry encrypted bundles for others; switching it off again stops everything and deletes stored third-party bundles |
| Message de-duplication | ✅ every message has a unique 128-bit id used as the primary key and bundle id; duplicates are stored once and still acknowledged |
| Persistence | ✅ SQLite schema + migrations, survives restarts, corrupt-DB quarantine, lazy expiry |
| Replaceable transport abstraction | ✅ simulated transport + `PlatformTransport` (tested over real loopback TCP) + `UnsupportedWifiTransport` that honestly refuses to fake connectivity |
| Native transport seam | ✅ Dart↔native channel contract, tested in Dart over real loopback TCP; ✅ Android **Wi-Fi Direct fabric implemented** (compiles, passes Android lint, 16 JVM unit tests green; advertises the Dart-supplied handle so the dial tie-break is symmetric) but its **radio path is not yet hardware-verified**; 🚧 Wi-Fi Aware stub; 🚧 Swift channel/NWListener/Bonjour skeleton (unverified, no macOS) |
| Automated tests | ✅ full suite green (114 Dart tests), `flutter analyze` clean |

---

## Architecture

The app is split into layers under `lib/`:

```
lib/
  presentation/   Flutter UI: screens, controllers (ChangeNotifier), widgets
  domain/         Entities + repository interfaces (no Flutter/no transport)
  data/           SQLite repositories, schema + migrations (sqflite)
  crypto/         Ed25519/X25519/AES-GCM/HKDF, identity service, secure storage
  messaging/      Message + receipt + bundle-outbox services
  friends/        Friend-request protocol state machine
  routing/        Store-carry-forward engine (transport-independent)
  transport/      Transport abstraction + simulated/unsupported implementations + the
                  FrameStream/TCP peer wire + PlatformTransport (Dart side of the
                  platform-channel bridge)
  core/           App config, DI graphs, clock, errors, versioned legal/terms
                  text, and the local (non-secret) settings service (consent +
                  the single master networking switch)
  demo/           In-process simulated demo peer (second full FindIt instance)
```

The **dependency direction** points inward: presentation → services →
repositories; routing uses only the `Transport` interface and never imports a
transport implementation.

### Identity

- Local identity = **Ed25519 signing key** + **X25519 agreement key**.
- `identityId = fid_ + hex(sha256(signingPublicKey)[0:16])`, bound to the public
  keys by a self-signature over a canonical CBOR record (`{v, kv, id, ik, ak, name}`).
- Private keys live only in platform secure storage and are **never exported**.
- The identity QR contains **public information only** (the signed record).
- Contacts are classified **discovered** vs **verified**; you are never
  auto-friended just by appearing on the network.

### Wire format

- Compact **canonical CBOR** envelopes (`cbor` package), signed over the exact
  encoded fields.
- Envelope header is mutable only in routing-safe fields (bundle id, type,
  recipient, expiry); content is inside the authenticated encryption layer.
- Payload encryption: ECIES (ephemeral-static X25519) → HKDF-SHA256 →
  AES-256-GCM, with the signed record as AAD. Sender authentication is a
  separate Ed25519 signature, so relays can verify authenticity without being
  able to read content.
- Envelope types: `msg`, `receipt`, `friend_request`, `friend_accept`,
  `friend_confirm`, `friend_decline`.

### Messages & PNG

- 24h TTL measured from original creation; **never reset on relay**; expired
  bundles are rejected and lazily cleaned up with bounded tombstones.
- Delivery shows **“Delivery unconfirmed”** until a verified signed receipt
  arrives; read receipts are a separate, optional concept.
- PNG is the only image format: no silent resize, no re-compression, no JPEG.
  Images are validated (signature/integrity via content hash, dimensions and
  pixel budget against decompression bombs) and stored losslessly. Messages are
  deduplicated by message id with atomic SQLite inserts.
- **Every message has a unique id**: a fresh 128-bit random identifier (the same
  size as a UUID) generated at creation. It is also the bundle id, so a relayed
  or retried copy presented twice is stored exactly once (`INSERT OR IGNORE`
  keyed by the primary key) and still acknowledged idempotently.

### Friend protocol

- `FRIEND_REQUEST` → `ACCEPT` → `CONFIRM`, plus `DECLINE`; unique request IDs;
  7-day request expiry independent of the message TTL; retries reuse the same
  logical request and bundle id (idempotent); simultaneous requests reconcile
  into one friendship.

### Routing

- Transport-independent store-carry-forward: no central server, no fixed hop
  limit; bounded by remaining TTL and configurable replication/storage budgets.
- **One master switch, off by default, and while off the device is radio
  silent.** The transport is never started, so nothing is discovered; the engine
  drops everything, so nothing is sent or received — not even your own messages —
  and no bundles are stored for anyone. Switching it on starts discovery and lets
  the device send/receive your own messages and carry encrypted bundles for
  others (relaying). Switching it off again stops everything immediately and
  deletes any third-party bundles it was holding (your own queued messages are
  kept). While the switch is off the app shows **only the switch**.
- Queued bundles are forwarded opportunistically on connection/summary, with
  per-peer dedup; a **failed connection is never recorded as a successful
  forward** and the bundle stays queued.
- Delivery receipts travel on any route and **stop further forwarding** once the
  sender knows delivery is confirmed.

### Storage

- SQLite schema (v2) with `identities`, `friends`, `friend_requests`,
  `conversations`, `messages`, `delivery_receipts`, `message_tombstones`,
  `bundles`, `bundle_forwards`, `pending_transfers`, `blocked_identities`,
  `rate_limits`, with foreign keys (`ON DELETE RESTRICT`) so referenced
  identities are never deleted out from under friends/messages. v2 adds a
  `settings` key/value table for local, non-secret preferences (the accepted
  terms version and the master networking switch); "reset local data" clears it,
  so consent is re-prompted and networking reverts to off.
- Migrations are incremental; a corrupt database is quarantined and recreated
  rather than crashing on launch.

---

## Setup

Prerequisites: **Flutter 3.29+** (developed against 3.47.7 / Dart 3.13.5).

```sh
flutter pub get
```

`sqflite` (Android/iOS) is used by the app; tests run on the host using
`sqflite_common_ffi`, which works on Windows without installing any extra
native SQLite DLL.

## Run

```sh
flutter run
```

On first launch you must **accept the terms of use** before anything else; the
terms are versioned and re-shown if they change. Only then do you create your
identity and can display/scan the identity QR. Until a physical transport
exists, the app runs on the **simulated in-process network**. From
**Profile/Settings** you can start the **demo peer** — a second, fully
independent FindIt instance on the same simulated network that accepts your
friend request and answers messages. Everything exchanged with the demo peer is
end-to-end encrypted with the same production code paths; the UI always labels
the peer and transport as **simulated**. The demo peer has networking switched
on (it stands in for a remote device); **turn your own switch on** (below) before
sending, or your side will hold the message.

Right after you accept the terms you see a single switch, and nothing else. While
it is **off** the app is **radio silent**: discovery never starts and nothing is
sent or received (not even your own messages). Turn it on to start FindIt —
onboarding if needed, then the tabs. You can turn it off again at any time from
**Profile/Settings**: that stops everything immediately, deletes any third-party
bundles the device was holding, and returns you to that switch.

The native transport is **opt-in and off by default**: pass a `PlatformTransport`
(a real `Transport` over the platform channel) into
`AppBootstrap.create(transport: ...)` to try it. On Android it now drives the
**Wi-Fi Direct fabric**; if Wi-Fi Direct is unavailable it reports
`unavailable`/`unsupported_feature` and it never fakes connectivity (see
[Transport & connectivity](#transport--connectivity)).

## Test

```sh
flutter analyze
flutter test
```

The suite covers:

The suite covers:

- identity generation/persistence, export/import shape, signature verification
  and tampered records,
- canonical CBOR round-trip and codec rejection of tampered ciphertext / bad
  signatures / wrong recipients,
- friend request → accept → confirm → decline, duplicates, simultaneous
  requests, expiry, blocking, fingerprint mismatch,
- message delivery + signed receipts, duplicate delivery, TTL boundaries,
  relayed-but-unconfirmed status,
- PNG integrity and lossless preservation,
- persistence: schema, foreign keys, corrupt-DB quarantine, restart recovery,
  expiry + tombstone bounds, receipt pruning, pending transfers, and that a
  message id can only be stored once,
- **consent and the master switch**: terms are accepted/versioned and persisted
  across restarts, networking defaults to off, `startNetworking` stays radio
  silent until both consent and the switch are on, a device with the switch off
  transfers nothing (not even its own messages) and never stores third-party
  bundles, a switched-on device sends/receives its own messages and relays
  others', and switching it off stops the engine and deletes stored third-party
  bundles while keeping your own,
- a widget test for the gate: consent → **only the single switch** → turn it on →
  onboarding,
- routing/transport: advertisement privacy (rotating handle, no permanent id),
  handshake, offline refusal, failed hand-off retry, 3-node relay (relay
  switched on), replication budget, and the unsupported transport refusing to fake
  connectivity,
- the transport wire: `FrameStream` TCP framing (reassembly in arbitrary byte
  chunks, oversized-frame rejection, send-after-close) and the full
  `PlatformTransport` seam over **real loopback TCP sockets** — discovery via
  native events, identity handshake, friend request → accept → confirm →
  message → signed receipt → `delivered`,
- widget smoke tests: the consent gate blocks the app until agreed, and
  onboarding validates an empty display name. The whole suite is **114 Dart tests**, all green.

## Build

```sh
flutter build apk --debug        # Android debug APK (verified on this host)
flutter build ios --no-codesign  # iOS simulator build (macOS only)
```

The Android debug APK builds successfully here (Android SDK 36 + build-tools
36.0.0 + JDK 21) and `./gradlew :app:lintDebug` is clean. The iOS build still
requires macOS/Xcode.

---

## Transport & connectivity

The `Transport` interface (`start/stop`, discovery, connect, identity +
capabilities handshake, peer summaries, bundle transfer, error reporting) is the
replaceable seam. It is implemented three ways:

1. **`SimulatedTransport`** — in-process loopback bus. Default. Exercises the
   full protocol stack and the demo peer.
2. **`PlatformTransport`** — the Dart side of a **platform-channel bridge** to
   native code (Android: Wi-Fi Direct / Wi-Fi Aware; iOS: local network over
   NWListener + Bonjour). The seam is complete and **tested in Dart over real
   loopback TCP sockets** (identity handshake, friend protocol, messages,
   receipts). All protocol remains in Dart on plain TCP framed by `FrameStream`,
   so it is testable without hardware.
3. **`UnsupportedWifiTransport`** — honestly **throws** instead of faking a
   radio (used when the platform channel is absent).

### Native radio status (honest)

The **Wi-Fi Direct fabric (`WifiP2pEngine`) is implemented**: it discovers peers
over Wi-Fi Direct DNS-SD, advertises **the rotating handle Dart supplies**
(`start(handle = localId)`, so both peers compare the same pair for the dial
tie-break) + Dart `dataPort` + display hint, forms a group on `connect(handle)`
(asking to be a client so the peer's IPv4 is the group-owner address) and returns
the peer's real endpoint. Peers are reported under the handle **they** advertised
— never a locally generated one. `connect()` never returns a synthetic endpoint:
an unknown handle, a missing advertised port, an unresolvable group or a
torn-down group all fail with a precise code.

The pure request/response logic lives in `TransportBridge.kt` (no Android/Flutter
types) so it is **unit tested on the JVM** — see `android/app/src/test/kotlin`
(16 tests covering fabric/device-name reporting, the honest `unsupported_feature`
failure, advertisement caching + discoverability, the Dart-supplied handle (and
its native fallback), connect success/failure mapping, capabilities and event
forwarding).

**What is verified here:** the Android code **compiles**, **passes Android
lint**, and its transport logic **passes 16 JVM unit tests**; the Dart seam is
tested over real loopback TCP. **What is not yet verified:** the **radio path** —
Wi-Fi Direct discovery/group formation/advertised service can only be exercised
with **two physical devices in range** (the Android emulator does not emulate the
P2P radio). **Wi-Fi Aware (`WifiAwareEngine`) is still a stub** (its `start()`
returns `unsupported_feature`), and the **iOS/Swift side is unverified** (this
host has no macOS). Treat the on-device Wi-Fi Direct behavior as untested until
it is run on hardware.

Run the native transport tests with:

```sh
cd android
./gradlew :app:testDebugUnitTest
```

### Contract

Canonical names live in `lib/transport/platform_transport_contract.dart` and are
mirrored exactly by `PlatformTransportChannel.kt` and
`PlatformTransportChannel.swift`:

- Method channel `findit/transport`: `start`, `stop`, `updateAdvertisement`,
  `connect`, `getCapabilities`, `dispose`.
- Event channel `findit/transport/events`, event type under key `event`:
  `peerFound`, `peerLost`, `error`.
- Error codes: `unavailable`, `unsupported_feature`, `permission_denied`,
  `connect_failed`, `transport_error`. Fabrics: `wifi-p2p`, `wifi-aware`,
  `local-network`.

### Privacy posture

- **The permanent identity id never crosses the channel.** Native code receives
  only a rotating, ephemeral handle, an optional display name hint and the TCP
  `dataPort`; native advertisements carry only the rotating handle, an optional
  display hint and the `dataPort` (never the id). Discovery is **opt-in**.
- Android permissions are minimal and documented in `AndroidManifest.xml`:
  `INTERNET` (required for *any* socket use, even local-only), Wi-Fi state
  permissions, `NEARBY_WIFI_DEVICES` with `neverForLocation` (Android 13+) and
  `ACCESS_FINE_LOCATION` only up to API 32 pending on-device validation.
- iOS `Info.plist` adds `NSLocalNetworkUsageDescription` and
  `NSBonjourServices = [_findit._tcp]`. The local-network prompt is shown to the
  user on first use.
- **Bluetooth is intentionally not used** as a fallback.
- The **Nearby** screen reflects real reachability: when nothing is reachable it
  shows an explanation and the transport name, not fake discovered devices.

## Honest limitations

- **The radio path is unverified** — two real phones have not yet exchanged data.
  The Dart side of the platform transport is tested over host loopback TCP; the
  **Android Wi-Fi Direct fabric is implemented and passes compile, Android lint
  and 16 JVM unit tests** on this host (SDK 36 + JDK 21), but Wi-Fi Direct
  discovery/group formation can only be exercised with **two physical devices**
  and has not been run there yet. **Wi-Fi Aware is still a stub** and the
  **iOS/Swift side is unverified** (no macOS here). Native code is not checked by
  `flutter analyze` (android/ and ios/ are excluded).
- **Native-path dial tie-break is now symmetric** (but still hardware-unverified).
  `RoutingEngine` picks who initiates by comparing its own ephemeral `localId`
  against the discovered peer id. The simulated transport's peer id already *is*
  the peer's `localId`; for the platform transport, Dart now passes its `localId`
  to native `start`, and the Wi-Fi Direct fabric advertises exactly that handle
  and reports each peer under the handle *it* advertised. Both devices therefore
  compare the same pair (A/`B.localId` vs B/`A.localId`) and agree. This is
  covered by the JVM and Dart loopback tests, but it has **not** been run on two
  physical devices.
- No **delivery guarantees**: store-carry-forward is best-effort; “Delivery
  unconfirmed” is the default state until a verified receipt arrives. Because
  the **master switch is off by default**, a message only moves once the sender
  (and, for multi-hop delivery, every carrier) has switched networking on. Even
  then it reaches its recipient only when the two devices are directly connected
  at the same time, or through an intermediary that has switched it on; FindIt
  does not promise a relay will exist.
- **Consent is a one-time terms acceptance**, stored locally next to the data it
  governs (not in secure storage). "Reset local data" clears it and re-prompts.
  It is a transparent gate, not a defence against a hostile OS or a rooted
  device.
- Background app restrictions are stated plainly: Android/iOS may kill the app;
  an offline-first messenger does not promise always-on networking.
- Relays can observe **metadata** (approximate time, size, hop path) even though
  they cannot read content.
- Rate limits and storage quotas are enforced defensively; a hostile peer could
  still attempt spam, which is bounded but not eliminated.
- Private keys never leave secure storage, but **FindIt is not audited** — treat
  it as a protocol/UX prototype, not a vetted security product.

## License / scope

This is a working prototype built to the specification in the project notes
(Milestone 1: identity + mutual friend protocol + persistence; then encrypted
messaging, PNG, routing and the transport seam). Device-required features (real
transport, QR scanning on device, image picking) are implemented but can only be
fully exercised on physical devices/emulators.