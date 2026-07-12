# SecureChat — Handoff de Sesión

**Última actualización:** 2026-07-10 (release **v0.7.0**: federación de salas F1–F4, salas públicas + moderación, cifrado en reposo SQLCipher, rename de apps a "SecureChat")
**Para retomar:** di "continua sesion" o "lee el SESSION_HANDOFF.md"

> Este archivo es el nexo común Mac ↔ Windows. Actualizarlo al final de cada sesión.

---

## Estado actual del proyecto

### Fases completadas

| Fase | Descripción | Estado |
|------|-------------|--------|
| 1 | Identidad criptográfica, registro, login | ✅ Completo |
| 2 | Mensajería directa E2E (Noise_IK + ChaCha20) | ✅ Completo |
| 3 | Salas de chat grupales (Argon2id + room_key) | ✅ Completo |
| 3b | Sistema de invitaciones (bootstrap token + user invites) | ✅ Completo |
| 4 | Voz WebRTC — salas (SFU en Go + flutter_webrtc) | ✅ Completo |
| 4b | Portado a macOS desktop + Windows desktop | ✅ Completo |
| 4c | Transferencia de archivos (DM + salas, relay WS E2E) | ✅ Completo |
| 4d | Solicitudes de contacto, bloqueo, menú contextual chats | ✅ Completo |
| 4e | Llamadas de voz 1-1 (P2P WebRTC, señalización vía servidor) | ✅ Completo |
| 4f | Tick de confirmación servidor, nombre en lista de chats | ✅ Completo |
| 4g | Emoji picker en todos los chats | ✅ Completo |
| 4h | Federación de servidores (4 modos: public/private/mesh_public/mesh_private) | ✅ Completo |
| 5 | Endurecimiento de seguridad (auditoría §13) + CI + modernización deps | ✅ Completo |
| 6 | Persistencia local cifrada (DMs + salas) + multi-servidor (identidad por servidor) | ✅ Completo |
| 7 | Salas públicas (tipo Telegram) + moderación (kick/ban/admins) | ✅ Completo |
| 8 | Federación de salas: F1 descubrimiento + F2 participación + F3 moderación remota + F4 salas privadas cross-server | ✅ Completo |
| 9 | Cifrado en reposo del servidor (SQLCipher AES-256, `SECURECHAT_DB_KEY`) | ✅ Completo |

### Completado en sesión 2026-07-10

- **Salas públicas** (server-visible, tipo Telegram) + privadas E2E como estaban. Moderación: owner + admins pueden kick, ban (1h/1d/7d/permanente) y nombrar admins; solo el owner degrada. Servidor: `is_public`, `room_admins`, `room_bans` + endpoints; cliente: pestañas Public/Private, browse/crear/unir, lista de miembros con acciones.
- **Federación de salas F1 (descubrimiento):** el browser hace fan-out a peers; solo públicas se anuncian (privadas nunca). `/s2s/rooms/public`.
- **Federación de salas F2 (participación remota):** origen autoritativo + fan-out; registro de peers-suscritos **solo en RAM**; relay **opaco** (ciphertext en privadas, texto en públicas), nada se almacena/replica. `/s2s/room/{subscribe,unsubscribe,message}`; cliente `JoinedRoom.homeUrl` + `home` en room_join.
- **Cifrado en reposo del servidor:** `SECURECHAT_DB_KEY` → SQLCipher AES-256; migración automática de DB plana (deja `.plaintext.bak`, **hay que borrarlo**). Driver mattn→mutecomm/go-sqlcipher; Docker pasó a **Debian (glibc)** (musl no compila go-sqlcipher). Verificado: fichero sin cabecera SQLite, `sqlite3` plano no lo abre. **Perder la clave = DB irrecuperable.**
- Cliente: editar servidor (http→https), toggle "Specify port" (8443 por defecto, https por defecto), toggle privacidad "Block unknown".
- **Federación de salas F4 (salas privadas cross-server):** una sala privada E2E alojada en un peer se une desde otro servidor. La invitación lleva `server_url` (el anfitrión); el cliente enruta la unión por el relay S2S del servidor activo y la `room_key` nunca sale del dispositivo. **Privacidad de metadatos:** el remitente viaja **dentro del ciphertext** y el `from` externo se elimina al cruzar la frontera de federación → el anfitrión solo ve `room_id` + payload opaco (nunca quién está ni quién habla); subscribe/unsubscribe a sala privada remota son anónimos. La ruta de envío remota entrega ya a los suscriptores locales y etiqueta `Origin` para evitar auto-eco duplicado. Servidor: `IncomingMessage.Private`, `hub.remotePrivate`, strip de `from` en `client.go`. Cliente: `joinRoom(homeUrl)`, payload privado `{v,from,text}`.
- **Rename:** nombre visible de las apps unificado a **"SecureChat"** en todas las plataformas (Android `android:label`, iOS `CFBundleDisplayName`, macOS `PRODUCT_NAME`, títulos de ventana Linux/Windows + version-info Windows). Identificadores de build (package/bundle id, nombres de binario e icono) sin cambios.
- **Release v0.7.0:** `pubspec` bumped a `0.7.0+3`; tag `v0.7.0` empujado → workflow `release.yml` construye y publica la GitHub Release.
- **FIX CRÍTICO cifrado en reposo (post-v0.7.0, en `[Unreleased]`):** la clave SQLCipher se aplicaba con un ConnectHook de `database/sql` (`PRAGMA key`), que cifra al crear pero produce un fichero **que no se puede reabrir** → cada reinicio fallaba con `file is not a database` (el bucle de crash en Docker del Director). Arreglado aplicando la clave por el **DSN `_pragma_key`** (se fija a nivel C antes de leer la primera página). Además: `TrimSpace` de la clave (newline de env/secret/.env ya no la altera), logs claros de migración y error de clave incorrecta accionable (apunta a `.plaintext.bak`). Verificado end-to-end entre procesos: create nuevo, migración de texto plano y reapertura, con datos intactos. Commit `4ad7fec`. **Pendiente: cortar v0.7.1 con este fix.**
- **Recuperación de la BD del Director en Docker:** su `data.db` quedó cifrado con la clave, pero el server no podía reabrirlo (bug de arriba). Con v0.7.1 el mismo `data.db` + misma clave abrirá directamente. Si hubiera dudas, el texto plano original está en `data.db.plaintext.bak`.
- **Federación F3 (moderación remota):** los handlers de moderación proxean al origen por S2S (member list + kick/ban/unban/promote/demote); el origen propaga la desconexión a los peers y descarta mensajes de baneados. Cliente sin cambios. `/s2s/room/{id}/members`, `/s2s/room/{moderate,kicked}`.
- **Pendiente:** F4 (salas privadas remotas: cablear el join privado por el `server_url` de la invitación; la infra de relay opaco ya lo soporta).

### Completado en sesión 2026-07-07 (seguridad + CI + deps)

Auditoría del diseño (§13) contra el código y cierre de todos los huecos. Detalle en `CHANGELOG.md` (2026-07-07).

**Servidor (Go):**
- [x] `crypto/verify.go` (+test) y `ws/client.go` — verificación real de firma Ed25519 en DMs antes de reenviar/relayar
- [x] `main.go` — TLS 1.3 obligatorio (`MinVersion`) + arranque abortado si `jwt.secret` es placeholder
- [x] `ws/client.go` — rate limiting 100 msg/min por conexión; `CheckOrigin` same-host; `room_msg`/`voice_join` exigen sala existente
- [x] `api/handlers/users.go` — binding de identidad `user_id == BLAKE2s(public_key)`

**Cliente (Flutter):**
- [x] `crypto/noise_handshake.dart` — forward secrecy (efímero del respondedor, `ee`/`se`) + `test/noise_handshake_test.dart`
- [x] `store/messages_store.dart` — verificación de firma en recepción de DM + envío diferido tras handshake
- [x] `voice/voice_client.dart` + `store/voice_store.dart` — voz E2E con FrameCryptor (room_key, AES-GCM); fail-closed sin clave
- [x] `network/ws_client.dart` + `store/rooms_store.dart` — re-join de salas al reconectar (`onConnected`)

**CI (GitHub Actions):**
- [x] `.github/workflows/server.yml` — build nativo Linux/macOS/Windows (CGO/sqlite)
- [x] `.github/workflows/app.yml` — build Android/iOS/macOS/Windows
- [x] **Matriz 7/7 en verde**

**Modernización de dependencias (para que Android compile):**
- [x] `emoji_picker_flutter` 2.2.0→4.x, `flutter_webrtc` 0.9.48→1.5.2, `file_picker` 6.1.1→8.x
- [x] `android/app/build.gradle.kts` — `minSdk` 23; borrados los `Podfile.lock` obsoletos; `pod repo update` en CI iOS/macOS

**Pendiente de validar en dispositivo:** voz E2E (prueba positiva/negativa del `_ratchetSalt`), llamadas DM y emoji picker tras el salto de `flutter_webrtc` 0.9→1.5.

**Distribución (Releases):**
- [x] **Release `v0.5.0` publicada** con los 7 binarios: https://github.com/letzzar/SecureChat/releases/tag/v0.5.0
  (Android APK, iOS sin firmar, macOS/Windows zip, servidor Linux/macOS/Windows)
- [x] `.github/workflows/release.yml` — al hacer push de un tag `v*` compila las 7 plataformas y publica la Release automáticamente. Uso: `git tag v0.6.0 && git push origin v0.6.0`. Tags con guion (`v1.0.0-rc1`) → prerelease. **El job `publish` aún no se ha ejecutado end-to-end** (los pasos de build sí están probados en verde).
- Los binarios de la CI normal viven como *artifacts* de cada run (pestaña Actions), no en Releases; caducan a 90 días.

**Persistencia cifrada + multi-servidor — sesión 2026-07-08:**
- [x] `store/local_store.dart` — historial serializado a JSON y **cifrado en reposo** (ChaCha20-Poly1305 con clave de dispositivo en el almacén seguro), en la carpeta privada de la app.
- [x] `store/persistence.dart` — hidrata al arrancar, guarda con debounce; datos por cuenta (`user_id`). Persiste DMs, mensajes de sala, **claves de sala**, peers, contactos aceptados/bloqueados y solicitudes. Las sesiones Noise NO se persisten (forward secrecy).
- [x] `toJson`/`fromJson` en `ChatMessage`/`RoomMessage`/`JoinedRoom` (+ `test/serialization_test.dart`).
- [x] **Multi-servidor (una identidad por servidor, cambio de activo):** `crypto/identity.dart` reescrito con modelo de cuentas (`listAccounts`/`switchAccount`/`removeAccount`, slot activo reescrito al cambiar, **migración automática** de instalaciones existentes).
- [x] UI: Perfil → **Servers** (lista, tocar para cambiar, "Add server" reusa onboarding con back). "Log out" quita solo el servidor activo (cambia a otro o vuelve a setup).
- [x] Al cambiar de servidor: intercambia historial cifrado, limpia sesiones/claves; WS/API reconectan solos.
- **Verificado:** analyze limpio, 6 tests, **CI build 4/4 verde** (Android/iOS/macOS/Windows).
- **Pendiente de validar en dispositivo:** (1) enviar DM + msg de sala, cerrar, reabrir → persisten (sala sin re-pedir contraseña); (2) Add server → cambiar entre servidores sin logout, cada uno su historial; (3) migración: tu identidad actual sigue como primera cuenta tras actualizar.

**Docker (servidor) — sesión 2026-07-08:**
- [x] `securechat-server/Dockerfile` — multi-stage Go + CGO/sqlite sobre Alpine; `.dockerignore` evita meter secreto/DB/binarios.
- [x] `config/config.go` — overrides por entorno `SECURECHAT_*` (JWT_SECRET, DB_PATH, HOST, PORT, MODE, TLS, TLS_CERT/KEY) → el server arranca desde `docker run` sin fichero de config.
- [x] `docker-compose.yml` (build) + `docker-compose.pull.yml` (imagen publicada) + `.env.example`.
- [x] `.github/workflows/docker-publish.yml` — publica imagen **multi-arch (amd64+arm64)** en push a `main` que toque `securechat-server/**` y en tags `v*`. **GHCR siempre** (`ghcr.io/letzzar/securechat-server`), **Docker Hub** (`letzzar/securechat-server`) si están los secrets `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN`. Ya publicado en verde.
- [x] `DOCKER.md` — guía bilingüe (arranque, compose con YAML de ejemplo, tabla de variables, TLS, publicación, backup).
- **Pendiente (solo lo puede hacer el Director):** el repo es privado → la imagen GHCR nace **privada**. Para `docker pull` sin login: GitHub → perfil → Packages → `securechat-server` → Package settings → Change visibility → Public. (O `docker login ghcr.io` en el servidor). Para Docker Hub, añadir los 2 secrets.
- Uso rápido: `docker run -d -e SECURECHAT_JWT_SECRET="$(openssl rand -hex 32)" -p 8443:8443 -v "$PWD/data:/data" ghcr.io/letzzar/securechat-server:latest` (el log muestra el código de invitación bootstrap).

**Nota de sincronización:** la copia en `/Volumes/...` es backup del NAS; se había quedado atrás respecto al `main` de GitHub y se resincronizó. Trabajar siempre desde `origin/main`. HEAD al cerrar: `5905795` (multi-servidor) + docs encima.

### Completado en sesión 2026-05-07/08

**Servidor (`ws/client.go`):**
- [x] Relay de señales de llamada DM: `dm_call_offer/answer/reject/end/dm_ice_candidate`
- [x] Suprimido error log 1006 (cierre normal del cliente)
- [x] Recompilado: `securechat-server-windows-amd64.exe`

**Cliente Flutter:**
- [x] `lib/store/dm_voice_store.dart` — nuevo: gestión completa de llamadas P2P 1-1
- [x] `lib/screens/chat/chat_screen.dart` — botón de llamada en AppBar, barra `_DmCallBar` (estados: llamando/sonando/en llamada), tick simple (✓) al confirmar el servidor
- [x] `lib/store/messages_store.dart` — tracking de `_pendingSeqs`, ack `delivered_seq` funcional, dispatch `dm_call_*`
- [x] `lib/screens/home/home_screen.dart` — `_openChat` guarda datos completos del usuario en `knownPeers` (fix nombre en lista)
- [x] `sendDM` ya no sobreescribe `display_name` en `knownPeers`

**Sesión 2026-05-08 (federación + emoji + docs):**

*Servidor:*
- [x] `auth/jwt.go` — nuevo paquete para romper ciclo de imports `ws ↔ api/handlers`
- [x] `config/config.go` — `[federation]` config + `IsMesh()` / `IsPublicReg()` + 4 modos
- [x] `db/federation.go` — CRUD `federation_peers` en SQLite
- [x] `federation/client.go` — fan-out search, lookup, relay S2S
- [x] `api/handlers/federation.go` — endpoints públicos, admin y S2S
- [x] `api/handlers/users.go` — `SearchUsers` fan-out en modo mesh, `server_url` en respuesta
- [x] `ws/client.go` — `handleDM` enruta a peers remotos vía relay federation
- [x] `api/router.go` — registra todas las rutas federation + S2S

*Cliente:*
- [x] `lib/widgets/emoji_input_bar.dart` — widget compartido con emoji picker (toggle teclado ↔ emojis)
- [x] `lib/screens/chat/chat_screen.dart` — usa `EmojiInputBar`
- [x] `lib/screens/rooms/room_chat_screen.dart` — usa `EmojiInputBar`
- [x] `lib/store/app_state.dart` — `FederationServer` + `federatedServersProvider`
- [x] `lib/app.dart` — fetches peer list en connect, almacena en `federatedServersProvider`
- [x] `lib/network/api_client.dart` — `getFederation()`
- [x] `lib/screens/home/home_screen.dart` — badge servidor en resultados, sección "Federated Servers" en perfil

*Docs:*
- [x] `SERVER.md` — guía bilingüe (EN/ES) de administración del servidor
- [x] `CHANGELOG.md` — actualizado con emoji, federación y SERVER.md

### Pendiente inmediato — PRÓXIMOS PASOS

- [ ] **Pruebas Mac ↔ PC**: servidor en Windows, Mac apuntando a IP del PC — validar llamadas DM end-to-end
- [ ] **Prueba federación**: dos instancias del servidor con `mode = "mesh_private"`, peering vía curl, buscar y mensajear entre nodos
- [ ] Indicador persistente en HomeScreen mientras se está en un canal de voz de sala
- [ ] Fase 5: ver tabla abajo

---

## Entorno dual — Mac + Windows

### Mac (MacBook)

| Elemento | Valor |
|---|---|
| Proyecto | `/Users/Letzzar/Mi Software/SecureChat/` |
| Flutter app | `/Users/Letzzar/Mi Software/SecureChat/securechat-app` |
| Servidor Go | `/Users/Letzzar/Mi Software/SecureChat/securechat-server` |
| Compilar macOS | `flutter build macos --release` |
| Binario macOS | `build/macos/Build/Products/Release/securechat.app` |

### Windows (PC)

| Herramienta | Ubicación |
|---|---|
| Flutter SDK | `D:\Program Files\flutter\bin` |
| Go binary | `D:\Program Files\Go\bin\go.exe` (¡no en C:\!) |
| GCC (CGO) | `C:\Users\letzz\mingw64\bin\` |
| Android SDK | `C:\Users\letzz\AppData\Local\Android\Sdk` |
| Visual Studio 2022 | `C:\Program Files\Microsoft Visual Studio\2022\Community` |
| Proyecto (trabajo) | `D:\SecureChat\` |
| Proyecto (backup NAS) | `Y:\Mi software\SecureChat` |

**Por qué D:\SecureChat:** `Y:\` es NAS — no soporta symlinks. Flutter los requiere.

### Comandos de build

```powershell
# Flutter Windows
cd D:\SecureChat\securechat-app
$env:PATH = "D:\Program Files\flutter\bin;$env:PATH"
flutter build windows --release

# Servidor Go (CGO obligatorio para sqlite3)
cd D:\SecureChat\securechat-server
$env:CGO_ENABLED = "1"
$env:PATH = "C:\Users\letzz\mingw64\bin;D:\Program Files\Go\bin;$env:PATH"
& "D:\Program Files\Go\bin\go.exe" build -o securechat-server-windows-amd64.exe .
```

```bash
# macOS
cd "/Users/Letzzar/Mi Software/SecureChat/securechat-app"
flutter build macos --release
```

### Sync NAS ↔ local

```powershell
# D: → NAS (tras cambios en PC)
robocopy "D:\SecureChat" "Y:\Mi software\SecureChat" /E /XD ".dart_tool" "build" /NFL /NDL
# NAS → D: (al retomar en PC desde Mac)
robocopy "Y:\Mi software\SecureChat" "D:\SecureChat" /E /XD ".dart_tool" "build" /NFL /NDL
```

---

## Servidor

- Binario Windows: `D:\SecureChat\securechat-server\securechat-server-windows-amd64.exe`
- Config: `D:\SecureChat\securechat-server\config.toml` → `mode = "private"`
- El Mac se conecta al servidor del PC: `http://<ip-del-pc>:8080`
- BD actual: 3 usuarios. Invites válidos hasta 04/06/2026:
  - `8b82d0ae4758b7e833db59d46dff2bf0`
  - `0b24f93c56f802ff6de8319daf08ce39`

---

## Estructura del proyecto

```
SecureChat/
├── SECURECHAT_DESIGN.md
├── SESSION_HANDOFF.md       ← nexo Mac ↔ Windows (este archivo)
├── CLAUDE.md
├── CHANGELOG.md
├── SERVER.md                 ← guía bilingüe de administración del servidor
├── securechat-server/        # Servidor Go
│   ├── main.go
│   ├── config.toml           # mode puede ser: public/private/mesh_public/mesh_private
│   ├── securechat-server-windows-amd64.exe
│   └── api/ ws/ sfu/ db/ crypto/ auth/ federation/
└── securechat-app/           # Flutter app
    ├── pubspec.yaml
    └── lib/
        ├── store/
        │   ├── app_state.dart        # session, knownPeers, contacts, blocked, federation
        │   ├── messages_store.dart   # conversación, sendDM, dispatchIncoming
        │   ├── rooms_store.dart      # salas
        │   ├── voice_store.dart      # voz en salas (SFU)
        │   ├── dm_voice_store.dart   # llamadas DM P2P
        │   └── file_transfer_store.dart
        ├── screens/
        │   ├── chat/chat_screen.dart
        │   ├── home/home_screen.dart
        │   └── rooms/
        ├── widgets/
        │   └── emoji_input_bar.dart  # input bar compartido con emoji picker
        ├── crypto/
        │   ├── secure_kv.dart        # wrapper storage (macOS: file, otros: secure_storage)
        │   ├── identity.dart
        │   ├── noise_handshake.dart
        │   └── signatures.dart
        └── voice/voice_client.dart   # WebRTC para salas
```

---

## Fase 5 — Pendiente (no iniciada)

```
24. Rate limiting en servidor
25. Expiración de salas efímeras
26. Exportación/importación de identidad (BIP39)
27. Notificaciones push (FCM / APNs)
28. Tests de integración end-to-end
29. Indicador persistente en HomeScreen cuando se está en canal de voz de sala
30. Icono de la app (LogoSecureChat.png en carpeta icons/)
31. TLS / HTTPS para producción (documentado en SERVER.md)
32. Failover automático del cliente a servidor federado de backup
```

---

## Dinámica de trabajo

- Rol usuario: **Director del Proyecto**
- Rol asistente: **Desarrollador Senior**
- Diseño de referencia: `SECURECHAT_DESIGN.md`
- Iteraciones cortas: una feature o fix a la vez
