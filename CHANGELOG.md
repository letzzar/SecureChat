# Changelog

All notable changes to SecureChat are documented here.
Dates in ISO 8601 (YYYY-MM-DD). Entries ordered newest first.

---

## [Unreleased]

---

## 2026-07-08 — Encrypted local history + multi-server

### Added
- **Encrypted local persistence.** DM and room message history, room keys, known
  peers, accepted/blocked contacts and contact requests now survive app restarts.
  - `store/local_store.dart`: serialized to JSON, encrypted at rest with
    ChaCha20-Poly1305 using a per-device key kept in the OS secure store, written
    to the app support directory.
  - `store/persistence.dart`: hydrates on startup before the UI, saves debounced
    on every change. Namespaced per account (`user_id`).
  - Noise DM session keys are intentionally **not** persisted (forward secrecy);
    only the decrypted history is.
  - `toJson`/`fromJson` on `ChatMessage`, `RoomMessage`, `JoinedRoom`
    (+ round-trip tests).
- **Multi-server support — one identity per server, switch the active one.**
  - `crypto/identity.dart`: each server is a full separate account (own
    keypair / `user_id` / JWT), stored namespaced in secure storage. The active
    slot (read by Noise / signatures) is rewritten on switch. Existing
    single-identity installs are migrated into an accounts index automatically.
  - New `listAccounts` / `switchAccount` / `removeAccount`; `generateAndSaveIdentity`
    now adds and activates a new account.
  - Profile → **Servers**: list of saved servers (active one marked), tap to
    switch, **Add server** (reuses onboarding with a back button).
  - Switching swaps the encrypted local history and clears Noise sessions / room
    keys for the new account; the WebSocket and API providers reconnect
    automatically.
  - **Log out** now removes only the active server (switches to another if
    present, otherwise returns to the setup screen) — no more full logout just to
    change servers.

---

## 2026-07-08 — Docker image (multi-arch) + auto-publish

### Added
- **Server Docker image.** `securechat-server/Dockerfile` — multi-stage Go build
  (CGO + SQLite) on Alpine. `.dockerignore` keeps secrets, the DB and prebuilt
  binaries out of the image.
- **Config via environment variables** (`config/config.go`): `SECURECHAT_*`
  overrides (`JWT_SECRET`, `DB_PATH`, `HOST`, `PORT`, `MODE`, `TLS`,
  `TLS_CERT`, `TLS_KEY`) so the server runs from `docker run` with no config
  file — just `SECURECHAT_JWT_SECRET`. A mounted `/data/config.toml` is still
  used as a base if present.
- **Compose files** — `docker-compose.yml` (builds from source) and
  `docker-compose.pull.yml` (uses the published image), plus `.env.example`.
- **Auto-publish workflow** — `.github/workflows/docker-publish.yml` builds and
  pushes a **multi-arch image (linux/amd64 + linux/arm64)** on every push to
  `main` touching `securechat-server/**` and on `v*` tags:
  - **GHCR** always → `ghcr.io/letzzar/securechat-server`.
  - **Docker Hub** → `letzzar/securechat-server` when `DOCKERHUB_USERNAME` /
    `DOCKERHUB_TOKEN` secrets are set.
- **DOCKER.md** — bilingual guide: quick start, compose (build / pull), env
  config reference, TLS behind a reverse proxy, publishing, persistence/backup.

---

## 2026-07-07 — Security hardening, forward secrecy, E2E voice, CI, dependency modernization

Security audit of the design (`SECURECHAT_DESIGN.md` §13) against the code, then
closed every gap found. All changes verified: server `go build`/`go test`,
Flutter `analyze` + handshake unit tests, and a full green CI matrix.

### Security
- **Ed25519 signatures are now actually verified.** Previously the field was
  present but never checked, so the anti-spam / anti-impersonation guarantee was
  a no-op end to end.
  - Server (`crypto/verify.go`, `ws/client.go`): caches the sender's
    `sign_public` at connect and verifies the signature over
    `"<type>:<to>:<nonce>:<payload>"` (`:<seq>` for `dm`) before relaying or
    queuing — invalid signatures are rejected (`invalid_sig`).
  - Client (`store/messages_store.dart` `_onDM`): verifies the sender's
    signature before showing a DM; drops unauthenticated/tampered messages.
- **Forward secrecy in the Noise handshake** (`crypto/noise_handshake.dart`).
  The responder now contributes an ephemeral key, so the session key is
  `BLAKE2s(es‖ss‖ee‖se)`. A later compromise of either static key no longer
  reveals past sessions. Pure `computeSessionKey()` core with unit tests
  (`test/noise_handshake_test.dart`). Trade-off: the first DM is queued and sent
  after the handshake round-trips (`_pendingSends`), so a message to an offline
  peer waits locally until the handshake completes.
- **End-to-end encrypted voice** (`voice/voice_client.dart`). Audio frames are
  encrypted with the room key via WebRTC insertable streams (`FrameCryptor`,
  AES-GCM, shared key + fixed salt) before SRTP, so the SFU forwards opaque
  frames and cannot hear the audio. `voice_store.dart` fails closed if the room
  key is missing.
- **TLS 1.3 enforced** (`main.go`): `http.Server` with
  `MinVersion: tls.VersionTLS13`; warns when started without TLS.
- **Rate limiting** (`ws/client.go`): 100 messages/minute per connection.
- **Identity binding** (`api/handlers/users.go`): `/register` now rejects a
  `user_id` that is not `BLAKE2s(public_key)`.
- **Room authorization** (`ws/client.go`): `room_msg` and `voice_join` require
  the room to exist. Server-side password-of-room verification remains a design
  limitation (the server never sees `room_key`).
- **WebSocket origin check** (`ws/client.go`): `CheckOrigin` accepts native
  clients (no Origin) and same-host web origins instead of allowing any origin.
- **JWT secret guard** (`main.go`): the server refuses to start if `jwt.secret`
  is empty or the placeholder `change_me_in_production`.

### Changed
- **Re-join rooms on reconnect** (`network/ws_client.dart`,
  `store/rooms_store.dart`): a new `onConnected` hook re-sends `room_join` for
  every joined room after each (re)connect. Also fixes a pre-existing bug where
  room chat went silent after any WebSocket reconnect.
- **Dependencies modernized** so the Android APK builds on current Flutter:
  - `emoji_picker_flutter` 2.2.0 → 4.x (unblocks `web ^1.0.0`, which had capped
    `flutter_webrtc`).
  - `flutter_webrtc` 0.9.48 → 1.5.2 (drops the v1 Android embedding removed in
    Flutter 3.29+; FrameCryptor API unchanged).
  - `file_picker` 6.1.1 → 8.x.
  - Android `minSdk` raised to 23 (required by flutter_webrtc 1.x).
  - Removed the stale committed `ios/macos` `Podfile.lock` (pinned
    flutter_webrtc 0.9.36 / WebRTC-SDK 114.5735.08); CI regenerates them.

### Added
- **CI — GitHub Actions.** `.github/workflows/server.yml` builds the Go server
  natively (CGO/sqlite) for Linux, macOS and Windows. `.github/workflows/app.yml`
  builds the Flutter app for Android (APK), iOS (unsigned), macOS and Windows.
  Both upload artifacts and run on push / PR / manual dispatch.

### Notes
- The whole hardening was rebased onto the canonical GitHub `main`; the working
  copy at `/Volumes/...` (NAS backup) had lagged behind and was resynced.
- Voice E2E and the big `flutter_webrtc` version jump compile and analyze
  cleanly but still need on-device verification (audio decrypts with matching
  room keys; DM calls; emoji picker).

---

## 2026-05-08 — Federation mesh, emoji picker, server guide

### Added
- **Federated server mesh** — Servers can now form a mesh network (`mode = "mesh_public"` or `"mesh_private"`).
  - New `[federation]` config section: `name`, `public_url`, `secret`, `admin_token`.
  - S2S API: `/api/v1/s2s/message` relays DMs between nodes; `/api/v1/s2s/search` fans out user search.
  - Admin API: `POST/DELETE /api/v1/admin/federation/peers` to manage peer list.
  - Public API: `GET /api/v1/federation` returns node info and peer list to clients.
  - `federation/client.go`: concurrent fan-out search, sequential peer lookup, message relay with `X-Federation-Secret` auth.
  - Client auto-fetches peer list on connect and shows federated users with a server badge in search results.
  - `FederationServer` in `app_state.dart` with priority score (recency × failure decay) for future failover.
- **4 server modes** — `public` (open registration), `private` (invite-only), `mesh_public`, `mesh_private`. `IsPublicReg()` / `IsMesh()` helpers in `config.go`.
- **Emoji picker** — Dedicated emoji panel in all chat inputs (DM and group rooms).
  - New shared `EmojiInputBar` widget replaces the private `_InputBar` in both chat screens.
  - Emoji button toggles between system keyboard and the `emoji_picker_flutter` panel (256 px, animated collapse).
  - Tapping the text field while the emoji panel is open automatically switches back to the keyboard.
- **SERVER.md** — Bilingual (English / Spanish) server administration guide covering: Quick Start, full `config.toml` reference, server modes table, TLS setup (native cert, nginx reverse proxy, Let's Encrypt, self-signed), federation mesh with step-by-step curl commands, TURN server, Linux production deployment (systemd), Windows deployment (NSSM), security checklist, API endpoint reference, and troubleshooting.

### Changed
- `auth/jwt.go` new package extracts `IssueJWT` / `ValidateJWT` / `Claims` from `api/handlers` to break the `ws ↔ api/handlers` import cycle introduced by federation.
- `db/db.go`: `migrate()` now creates the `federation_peers` table.
- `api/handlers/users.go`: `SearchUsers` fans out to mesh peers in mesh mode; response includes `server_url` for remote users.
- `ws/client.go`: `handleDM` routes to remote peer via federation relay when recipient is not local and mode is mesh.

---

## 2026-05-08

### Added
- **DM voice calls (P2P WebRTC)** — Users can now call each other directly from any 1-1 chat.
  - New `dm_voice_store.dart` manages the full call lifecycle: idle → calling → ringing → inCall.
  - Call button appears in the ChatScreen AppBar when no call is active.
  - `_DmCallBar` widget shows call status with Accept / Reject / Mute / End buttons.
  - Audio signaling (offer/answer/ICE) is relayed through the server; audio itself is P2P.
  - Server auto-rejects incoming call if user is already busy.

### Fixed
- **Message delivered tick** — Outgoing messages now show a clock icon (⏰) while in flight and a single tick (✓) once the server confirms receipt (`delivered_seq` ack). Previously the tick never appeared.
- **Display name in conversation list** — Opening a chat from search results now stores the full user record (including `display_name`) in `knownPeers`. Previously the list showed a truncated user ID.
- **Display name not overwritten** — `sendDM` no longer replaces an existing peer record with a partial `{user_id, public_key}` object, which was erasing the `display_name`.

### Server
- Added relay for new DM call signal types: `dm_call_offer`, `dm_call_answer`, `dm_call_reject`, `dm_call_end`, `dm_ice_candidate`.
- Suppressed spurious error log on normal client disconnect (WebSocket close code 1006 / abnormal closure is now treated as expected).

---

## 2026-05-07 — Evening

### Added
- **Contact request flow** — The first message from an unknown user is now held in a "Contact Requests" section instead of going straight into a conversation. The recipient can Accept (opens the chat with buffered messages) or Block.
- **Block / Unblock users** — Blocked users' messages are silently dropped. Blocked list is visible in the Profile tab with an Unblock button.
- **Conversation context menu** — Right-click or long-press a conversation to Delete it or Block the user.
- **Display names in conversation list** — The chat list now shows the contact's display name when known.

### Fixed
- **Critical: serial message queue stall** — A failed message handler (e.g. a malformed Noise handshake payload) was permanently stalling the queue and silently dropping all subsequent messages, including DMs. Each queue link now has `.catchError((_) {})`.
- **`processNoiseInit` crash guard** — Handshake failures are now caught and the message is skipped instead of propagating an exception into the queue.
- **DM conversation navigation** — Tapping a conversation whose peer was not in the local `knownPeers` cache silently failed. The app now fetches the peer from the server on demand before navigating.

---

## 2026-05-07 — Afternoon (room file transfer)

### Added
- **File transfer in group rooms** — Files can now be sent and received inside group rooms. Metadata and content are E2E encrypted with the room key. Progress bar shown during transfer.
- **Display names in room chat** — Message bubbles now show the sender's display name instead of their user ID hash.
- Attach button in the room chat input bar.

### Changed
- Room file chunks use a 20 KB chunk size (vs 32 KB for DMs) to stay within the server WebSocket frame limit after base64 double-encoding.

---

## 2026-05-07 — Afternoon (DM file transfer)

### Added
- **File transfer in DMs** — Send and receive E2E encrypted files in 1-1 chats.
  - Sender picks a file; recipient gets an offer with file name and size (metadata encrypted).
  - Recipient can Accept or Reject. On accept, file chunks are streamed and reassembled.
  - Progress bar and status labels (Offering / Transferring / Done / Rejected / Cancelled / Error).
  - Saved files are written to the platform downloads directory.
- **Room member list** — Tap the people icon in a room's AppBar to see who is in the room.
- Added `file_picker` and `path_provider` dependencies.

### Changed
- `ChatMessage` now has a `MessageKind` (text / file) and optional `fileId`, `fileName`, `fileSize` fields.
- Message bubbles delegate to a `_FileBubble` when the kind is `file`.

---

## 2026-05-07 — Morning

### Fixed
- **WebSocket listener lifecycle** — The WS message listener was owned by `HomeScreen` and was destroyed on navigation. Moved to the root `SecureChatApp` widget so it survives all route changes.
- **Serial message queue** — Noise handshake (`noise_init`) and the DM that follows must be processed in order. The root widget now chains handlers with `.then()` to guarantee serial execution.
- **WebRTC Windows build** — `flutter_webrtc` symbols now imported with a `webrtc.` alias to resolve naming conflicts on Windows desktop.

---

## 2026-05-07 — macOS storage fix

### Changed
- **macOS key storage** — Replaced `FlutterSecureStorage` with a custom `secure_kv.dart` that stores keys in a JSON file under Application Support on macOS. This eliminates the repeated system keychain password prompts that appeared because the app is ad-hoc signed and the ACL changes between builds. Other platforms (iOS, Android, Windows) continue using `FlutterSecureStorage` unchanged.

---

## 2026-05-07 — macOS build fixes

### Fixed
- **UTF-8 BOM in Xcode project files** — Files generated on Windows (`project.pbxproj`, `AppInfo.xcconfig`, `Runner.rc`) had a BOM prefix that broke Xcode parsing. Stripped with a Python one-liner.
- **Keychain error -34018 (`errSecMissingEntitlement`)** — `flutter_secure_storage_macos` 3.1.3 defaults to `useDataProtectionKeyChain = true`, requiring the `keychain-access-groups` entitlement even outside the sandbox. Fixed by passing `MacOsOptions(useDataProtectionKeyChain: false)` at all three storage instantiation sites.
- Removed App Sandbox from macOS entitlements (not required for private / ad-hoc distribution).

---

## 2026-05-07 — Server: public/private mode + file relay

### Added
- **Public / private server mode** — `config.toml` now has `mode = "public" | "private"`. In private mode, registration requires a valid invite code. In public mode, anyone can register.
- **File transfer relay (server-side)** — New WebSocket message types: `file_offer`, `file_accept`, `file_reject`, `file_cancel`, `file_chunk`, `file_done`, `file_error`. The server relays these messages opaquely; content is E2E encrypted by the clients.

---

## 2026-05-06 — Initial release

### Added
- **End-to-end encrypted direct messages** using a WireGuard-inspired crypto stack:
  - X25519 key exchange via Noise_IK handshake
  - ChaCha20-Poly1305 symmetric encryption
  - Ed25519 message signatures
  - BLAKE2s for key derivation
- **Group rooms** with Argon2id-derived room keys (passphrase-based).
- **Group voice** via a Go SFU (Selective Forwarding Unit) and `flutter_webrtc`.
- **Invite system** — Bootstrap token for first admin; admin can generate time-limited invite codes for new users.
- **Offline message delivery** — DMs sent while the recipient is offline are stored server-side (72-hour TTL) and delivered on next connection.
- **Flutter client** — Supports Android, iOS, macOS desktop, Windows desktop.
- **Go server** — Single binary, SQLite database, WebSocket hub, configurable via `config.toml`.
