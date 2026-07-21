# Flashbyte — App Architecture Guide

## Overview

Flashbyte is a cross-platform (Android/desktop) local peer-to-peer file sharing app. Devices discover each other on the same LAN via a custom UDP broadcast protocol, then transfer files over TCP (optionally wrapped in TLS). All heavy I/O runs in a background Dart isolate so the UI stays responsive.

---

## 1. Device Discovery (`DeviceDiscoveryService`)

**File:** `lib/services/discovery/device_discovery_service.dart`
**Protocol:** Custom JSON-over-UDP broadcast on port 8050 (shared with TCP).
**Identifier:** `flashbyte-discovery-v1`

### Broadcast flow
Every **2 seconds**, each device sends a UDP broadcast packet (`255.255.255.255` + per-interface subnet broadcasts) containing:
```json
{
  "protocol": "flashbyte-discovery-v1",
  "action": "hello",
  "instanceId": "<microsecond-timestamp>",
  "id": "<UUID>",
  "name": "<adjective-noun>",
  "port": 8050,
  "tls": true/false,
  "certFingerprint": "<sha256>",
  "cert": "<PEM>",
  "deviceType": "phone|laptop"
}
```

### Packet types
| Action | Type | Purpose |
|---|---|---|
| `hello` | Broadcast | Periodic advertisement every 2s |
| `probe` | Broadcast | Request all peers to respond |
| `probe response` | Unicast | Reply to a probe |
| `goodbye` | Broadcast | Sent on shutdown (with retries) |

### Lifecycle
1. **`startAdvertising()`** — sends an initial burst (immediate + 180ms + 650ms), then every 2s. Starts the TCP server host.
2. **`startDiscovery()`** — binds a receive socket, sets up a 20s peer-expiry cleanup timer.
3. **`requestRefresh()`** — sends a probe burst + re-advertises.
4. **`_devices`** map keyed by device ID; exposed via `devicesStream`.

### Interface filtering
Enumerates all non-loopback IPv4 interfaces. Filters out docker, veth, br-, virbr, rmnet, ccmni, wwan. Skips link-local addresses (`169.254.x.x`).

---

## 2. File Transfer Protocol

**Isolate:** `lib/services/transfer/file_transfer_isolate.dart` (background isolate)
**UI bridge:** `lib/services/transfer/socket_service.dart`

### Frame format (binary over TCP)

Every message is a length-prefixed frame:

```
[4 bytes: metadata length (big-endian)]
[4 bytes: payload length (big-endian)]
[metadata bytes (JSON-encoded Map)]
[payload bytes (binary data, optional)]
```

Control frames have `payload length = 0` and carry commands in `metadata`.

### Connection lifecycle

```
Sender                           Receiver
  |                                |
  |--- TCP connect (or TLS) ------>|
  |<-- peer_info (name, type) -----|
  |--- peer_info ----------------->|
  |                                |
```

1. **Host** binds `ServerSocket` (or `SecureServerSocket`) on `0.0.0.0:port`.
2. **Client** connects via `Socket.connect()` (plus optional `SecureSocket.secure()` for TLS).
3. Non-TLS: client sends `{"type": "probe", "tls": false}`, host responds `{"ok": true}`.
4. TLS: negotiation at socket layer; on success host sends `client_connected`.
5. Both sides exchange `peer_info` frames.

### File transfer sequence

```
Sender                           Receiver
  |                                |
  |--- file_offer (uuid,name,size) |  (receiver shows approval UI)
  |<-- file_transfer_accept -------|
  |--- file_start ---------------->|  (receiver opens output file)
  |--- file_chunk (uuid, bytes) -->|  (repeated 64KB windows)
  |--- file_chunk (uuid, bytes) -->|
  |--- file_end (fileId) --------->|
  |<-- file_received_ack ----------|
```

### Chunking
- **Window size:** 65,536 bytes (64 KB) via `windowed_file_reader` package.
- Files are read in windows, sub-sliced into chunks, and sent sequentially.

### Transfer control
- Pause/resume sent as control frames between peers.
- Sender polls every 120ms if paused to check for resume signal.
- Cancel discards the partial output file.

---

## 3. File Reception & Storage

### Non-Android
Files are written directly to the configured download directory.

### Android (SAF — Storage Access Framework via `saf` package)
1. Files are written **directly** to the selected SAF tree URI using `Saf().writeFileStream()`.
2. The streaming API receives chunks via a `StreamController` fed by the TCP read buffer.
3. No temp file or post-copy is needed — the file lands in the chosen directory.
4. Directory is picked via `Saf().pickDirectory()` on the settings page.

---

## 4. UI Flow

### Send
1. Tap **"Send"** → `FileSelectionPage(initialTabIndex: 0)`
2. Pick files via `FastFilePicker` or drag-and-drop.
3. Tap a discovered device → `SocketService.connectToHost()`
4. `OutgoingTransferOfferPage` shows "Waiting for approval".
5. Receiver accepts → `TcpChatPage` opens, transfers begin.

### Receive
1. Tap **"Receive"** → `FileSelectionPage(initialTabIndex: 1)`
2. `SocketService.startHost()` binds the server, discovery advertising begins.
3. "Visible to nearby devices" indicator shown.
4. When a `file_offer` arrives → `IncomingTransferOfferPage` with Accept/Decline.
5. On accept → `TcpChatPage` opens, files arrive.

### Active session (`TcpChatPage`)
- Lists `TransferWidget` cards (one per file) with progress bar, pause/resume, cancel.
- Desktop: peer info panel on the right.
- "Pick File" button to send additional files mid-session.
- Handles all states: pending, in-progress, paused, completed, cancelled, error.

---

## 5. TLS Security

**File:** `lib/services/security/tls_identity_service.dart`

- Self-signed RSA certificates generated on first use (CN: `"Flashbyte Device"`, 10-year validity).
- SHA-256 fingerprint of DER certificate body.
- Peer certs stored as `trusted_<peerId>.crt`.
- `onBadCertificate` callback compares expected fingerprint to actual.

---

## 6. Key Files Reference

| File | Role |
|---|---|
| `lib/main.dart` | Entry point, theme setup, startup effects |
| `lib/services/discovery/device_discovery_service.dart` | UDP broadcast discovery |
| `lib/services/transfer/socket_service.dart` | UI-isolate bridge to transfer isolate |
| `lib/services/transfer/file_transfer_isolate.dart` | Background isolate: all TCP I/O |
| `lib/services/security/tls_identity_service.dart` | TLS cert generation & verification |
| `lib/services/platform/android_saf_service.dart` | Android SAF picker + path formatting via `saf` package |
| `lib/services/platform/android_connection_notification_service.dart` | Foreground + progress notifications |
| `lib/features/transfers/pages/file_selection_page.dart` | Main send/receive hub |
| `lib/features/transfers/pages/outgoing_transfer_offer_page.dart` | Sender's pre-transfer screen |
| `lib/features/transfers/pages/incoming_transfer_offer_page.dart` | Receiver's approval screen |
| `lib/features/transfers/pages/tcp_chat_page.dart` | Active transfer session UI |
| `lib/features/transfers/widgets/transfer_widget.dart` | Per-file transfer card |
| `lib/models/discovered_device.dart` | Device model |
| `lib/app/app_settings.dart` | SharedPreferences wrapper |
| `android/app/src/main/kotlin/com/flashbyte/MainActivity.kt` | Hotspot detection channel |

---

## 7. Architecture Diagram (Text)

```
┌──────────────────────────────────────────────────────────────┐
│                     UI ISOLATE                               │
│                                                              │
│  FileSelectionPage ── SocketService ── DeviceDiscoveryService│
│       │                    │                    │            │
│  TcpChatPage         SendPort/              UDP sockets      │
│  TransferWidget     ReceivePort              broadcast       │
│       │                    │                                 │
└───────┼────────────────────┼─────────────────────────────────┘
        │  Isolate spawn     │  Commands via SendPort
        ▼                    ▼
┌───────────────────────────────────────────────────────────────┐
│                  BACKGROUND ISOLATE                           │
│                                                               │
│    fileReceiverIsolate()                                      │
│         │                                                     │
│    processCommandQueue()                                      │
│         │                                                     │
│    ┌────┴────┐                                                │
│    │  TCP    │  ServerSocket / SecureServerSocket             │
│    │  I/O    │  _SocketReadBuffer (queue-based byte buffer)   │
│    └─────────┘                                                │
│                                                               │
│    File reading: DefaultWindowedFileReader (64KB windows)     │
│    File writing: IOSink (regular) / Saf().writeFileStream (Android SAF)     │
└──────────────────────────────────────────────────────────────┘
```
