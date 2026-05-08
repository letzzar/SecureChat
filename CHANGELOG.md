# Changelog

All notable changes to SecureChat are documented here.
Dates in ISO 8601 (YYYY-MM-DD). Entries ordered newest first.

---

## [Unreleased]

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
