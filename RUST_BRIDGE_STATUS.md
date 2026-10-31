# Rust Bridge Transfer — Current Status & Next Steps

> **Branch:** `rust-bridge-transfer`
> **Last updated:** 2026-10-31
> **Status:** In progress — handshake bugs fixed, needs real-device testing

---

## What This Branch Does

Replaces the old Dart isolate TCP transfer backend with a Rust engine via `flutter_rust_bridge`. The Flutter frontend becomes UI-only; all connection establishment, framing, file I/O, and transfer control run in Rust.

**Public API (unchanged from Dart perspective):** `SocketService` keeps its exact public interface — 8 consumer files were never modified.

**Rust public functions:** `startHost`, `connectToHost`, `sendFile`, `sendFiles`, `pauseTransfer`, `resumeTransfer`, `cancelTransfer`, `acceptTransfer`, `declineTransfer`, `cancelOutgoingOffer`, `setDownloadDirectory`, `disconnect`, `isRunning`, `isHosting`, `hasEstablishedConnection`

---

## Architecture

```
UI Isolate (Dart)
  │
  │  SocketService (rewritten to consume Stream<TransferMessage>)
  │    ├── rust_transfer.startHost()       → returns Dart Stream
  │    ├── rust_transfer.connectToHost()   → returns Dart Stream
  │    └── rust_transfer.sendFile() etc.   → fire-and-forget commands
  │
  ▼
flutter_rust_bridge FFI boundary
  │
  ▼
Rust engine (static ENGINE: OnceLock<Mutex<Option<EngineState>>>)
  ├── Command loop thread  (rx.recv() → handles SendFile, Pause, Accept, Disconnect, etc.)
  ├── Connection thread    (run_host / run_client → handle_connection read loop)
  ├── SharedWriter         (Arc<Mutex<Option<Arc<Mutex<TcpStream>>>>>)
  └── TransferRegistry     (pending offers, accepted/declined, pause/cancel state, Condvar)
```

**Frame format:** `[4B meta len][4B payload len][JSON metadata][payload]`
- Control frames: `payload_len = 0`, metadata has `type` or `ok` key
- File frames: metadata has `uuid`/`name`/`size`, payload = full file bytes (1MB buffer)

---

## Bugs Found & Fixed

### 1. Partial frame-header reads across timeouts (commit `a875b85`)
- **Problem:** `read_exact` with 500ms socket read timeout could read 3 of 8 header bytes, time out, then the next iteration used a fresh `frame_header` array — the 3 bytes were lost. Stream corruption → Rust panic → StreamSink dropped → "Fail to post message to Dart".
- **Fix:** Persistent `frame_header[8]` + `header_offset` across loop iterations. New `read_exact_resumable()` helper for metadata reads that preserves offset across timeouts and checks `stop_requested`.

### 2. Handshake consumes wrong frame (commit `8ebe7e7`)
- **Problem:** Receiver sends `peer_info` *before* entering `handle_connection`. On the sender, that `peer_info` was the first control frame — it went to `handle_probe_frame` (which silently ignores non-probe frames) but set `probe_handled = true`. The actual probe response `{"ok": true}` then hit `handle_control_frame` which has no matching type — silently dropped. Sender never got `connected_to_host`. Handshake stalled, connection died, receiver went offline.
- **Fix:** Only consume the probe slot when `type == "probe"` or `ok` field is present. All other control frames go to `handle_control_frame` immediately.

---

## Known Limitations / Remaining Work

### TLS not supported in Rust backend
- `SocketService._startRustTransfer` emits an error if `useTLS: true`
- `isSecureHosting => false`
- The old Dart isolate had full TLS via `TlsIdentityService`. This needs to be ported to Rust (`rustls` crate) or the feature needs to be explicitly deferred.

### Global ENGINE is process-wide (single-connection limitation)
- `static ENGINE: OnceLock<Mutex<Option<EngineState>>>` — only one engine per process
- If sender + receiver run on the **same device** (same Flutter process), `connect_to_host` calls `disconnect()` first which kills the host engine. This is fine for real cross-device use but breaks same-device testing.
- The old Dart isolate had the same limitation (one isolate per role).

### Host accepts only one connection then exits
- `run_host` accepts one TCP connection, processes it via `handle_connection`, then returns. It does not go back to `accept()`.
- This is acceptable for 1:1 file sharing (matching the original design) but would need a loop if multi-connection hosting is desired.

### Android SAF (Storage Access Framework) not wired up in Rust
- The Dart isolate used `Saf().writeFileStream()` for Android downloads
- Rust currently writes to a plain filesystem path (`create_output_target` + `File::create`)
- On Android this will fail unless a SAF bridge is added (e.g., pass the tree URI + file descriptor to Rust, or keep Android reception on the Dart side temporarily)

### No progress streaming during file send
- `send_file_over_socket` reads the whole file in 1MB chunks and writes them, but the progress emission logic needs verification — check that `send_progress` messages are actually emitted and throttled to `PROGRESS_INTERVAL` (400ms)

### Pause/resume during active transfer
- Pause is implemented as a flag check between chunks on the sender side (polls every 120ms)
- Receiver pause uses `remotely_paused` registry
- Needs real-device testing to verify no deadlocks with the Condvar

### `frb(sync)` functions block the UI isolate
- `isRunning`, `isHosting`, `hasEstablishedConnection` are `#[frb(sync)]` — they lock the `ENGINE` mutex synchronously from the Dart UI thread
- Low risk since the lock is held briefly, but worth monitoring under load

---

## How to Build & Test

### Prerequisites
```bash
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cargo install cargo-ndk
```

### Development
```bash
flutter run          # cargokit auto-compiles Rust
```

### Regenerating bindings (only if public Rust API changes)
```bash
flutter_rust_bridge_codegen generate
```

### Verification
```bash
dart analyze lib/                    # must be clean
dart format lib/                     # must be clean
cd packages/flashbyte_core && dart test   # 50 tests
cd rust && cargo check               # must be clean
```

### Harness
```bash
./tool/harness.sh check    # full suite
./tool/harness.sh unit     # unit/widget tests
```

---

## Commits on This Branch

| Commit | Description |
|--------|-------------|
| `38a8184` | Rust bridge scaffold — rust/ crate, rust_builder cargokit, generated bindings, rewritten socket_service.dart, RustLib.init() |
| `686a941` | Add 500ms read timeout, ConnectionReset/UnexpectedEof as clean disconnect, stream shutdown on Disconnect |
| `a875b85` | Fix partial frame-header reads across timeouts (persistent buffer + offset) |
| `8ebe7e7` | Fix handshake consuming peer_info instead of probe response |

---

## Next Steps (Priority Order)

1. **Real-device testing** — flash to Android phone + Linux desktop, verify:
   - Receiver stays online when sender connects
   - Handshake completes (`client_connected` / `connected_to_host` emitted)
   - File offer → accept → transfer completes
   - Progress updates stream correctly
   - Disconnect cleans up both sides

2. **Port TLS to Rust** (or explicitly disable and document) — use `rustls` for self-signed cert handling, port `TlsIdentityService` fingerprint verification

3. **Android SAF bridge** — either:
   - Pass SAF file descriptor to Rust for writing, or
   - Keep Android reception on Dart side temporarily (hybrid approach)

4. **Verify pause/resume/cancel** on real transfers with large files

5. **Consider multi-connection host** if needed (currently 1:1 only)

6. **Merge to main** once stable
