# SecureChat — Handoff de Sesión

**Última actualización:** 2026-05-07 (sesión Mac — tarde → pasa a Windows)
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
| 4 | Voz WebRTC (SFU en Go + flutter_webrtc en Flutter) | ✅ Completo |
| 4b | Portado a macOS desktop + Windows desktop | ✅ Completo |
| 4c | Modo público/privado + transferencia de archivos (relay WS) | ✅ Servidor — cliente pendiente |

### Completado en sesión Mac 2026-05-07

- [x] Modo público/privado: `config.toml` → `mode = "private"` | `"public"`
  - Privado: registro requiere invite code; Público: registro libre
- [x] Transferencia de archivos por WebSocket (relay E2E cifrado, solo usuarios online)
  - Mensajes: `file_offer`, `file_accept`, `file_reject`, `file_cancel`, `file_chunk`, `file_done`, `file_error`
  - Servidor implementado — UI en cliente Flutter **pendiente**
- [x] **Build macOS funcional** — resueltos dos bugs de compilación/runtime:
  1. **BOM UTF-8** en archivos generados desde Windows (`project.pbxproj`, `AppInfo.xcconfig`, `Runner.rc`) → eliminados con Python (3 bytes `EF BB BF` al inicio de cada archivo)
  2. **Error Keychain -34018** (`errSecMissingEntitlement`) → causa raíz: el plugin `flutter_secure_storage_macos` 3.1.3 usa `kSecUseDataProtectionKeychain = true` por defecto, lo que requiere el entitlement `keychain-access-groups` incluso sin sandbox. Fix: añadir `MacOsOptions(useDataProtectionKeyChain: false)` en los tres sitios donde se instancia `FlutterSecureStorage`:
     - `lib/crypto/identity.dart`
     - `lib/crypto/noise_handshake.dart`
     - `lib/crypto/signatures.dart`
  - Sandbox también eliminado de `DebugProfile.entitlements` y `Release.entitlements` (innecesario para app privada fuera del App Store)

### Completado en sesión Windows 2026-05-06

- [x] Flutter 3.41.9 instalado en `D:\flutter`, bin en PATH
- [x] Android SDK configurado (`ANDROID_HOME`, licencias aceptadas)
- [x] `AndroidManifest.xml` con permisos de audio, cámara, internet
- [x] Proyecto copiado a `D:\SecureChat` (unidad NTFS local)

### Pendiente inmediato — PRÓXIMOS PASOS

- [ ] **Build Windows**: desde `D:\SecureChat\securechat-app` con VS 2026 + ATL instalado — **aplicar los mismos cambios Dart del fix de Keychain** (ya están en el NAS, sincronizar con robocopy antes de compilar)
- [ ] **Pruebas Mac ↔ PC**: servidor corriendo en Windows, Mac apuntando a IP del PC
- [ ] **UI transferencia de archivos** en cliente Flutter
- [ ] Fase 5: pulido y seguridad (ver abajo)

> **Nota para Windows:** antes de compilar, sincronizar desde NAS:
> ```powershell
> robocopy "Y:\Mi software\SecureChat" "D:\SecureChat" /E /XD ".dart_tool" "build" /NFL /NDL
> ```

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
| Flutter SDK | `D:\flutter` (bin en PATH usuario) |
| Android SDK | `C:\Users\letzz\AppData\Local\Android\Sdk` |
| Visual Studio Community 2026 | Instalado con componente ATL de C++ |
| Visual Studio 2022 Community | `C:\Program Files\Microsoft Visual Studio\2022\Community` |
| Proyecto (trabajo) | `D:\SecureChat\securechat-app` |
| Proyecto (backup NAS) | `Y:\Mi software\SecureChat` |

**Por qué D:\SecureChat en Windows:** `Y:\` es NAS — Windows no permite symlinks en red y Flutter los necesita. Todos los builds en Windows deben hacerse desde `D:\SecureChat`.

Sincronizar de D: al NAS tras cambios:
```powershell
robocopy "D:\SecureChat" "Y:\Mi software\SecureChat" /E /XD ".dart_tool" "build" /NFL /NDL
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
├── securechat-server/        # Servidor Go
│   ├── main.go
│   ├── config.toml
│   ├── securechat-server-windows-amd64.exe
│   └── api/ ws/ sfu/ db/ crypto/
└── securechat-app/           # Flutter app
    ├── pubspec.yaml
    └── lib/ ios/ android/ macos/ windows/
```

---

## Comandos de build

```bash
# macOS (desde Mac)
cd "/Users/Letzzar/Mi Software/SecureChat/securechat-app"
flutter build macos --release
# → build/macos/Build/Products/Release/securechat.app

# Windows (desde PC)
cd D:\SecureChat\securechat-app
D:\flutter\bin\flutter.bat build windows --release
# → build\windows\x64\runner\Release\securechat.exe

# Android (desde cualquier máquina con Android SDK)
flutter build apk --release
```

Si `flutter build macos` falla:
```bash
flutter doctor          # diagnosticar
xcode-select --install  # si faltan Xcode CLI tools
cd macos && pod install && cd .. && flutter build macos --release  # si falla pods
```

---

## Fase 5 — Pendiente (no iniciada)

```
24. Rate limiting en servidor
25. Expiración de salas efímeras
26. Exportación/importación de identidad (BIP39)
27. Notificaciones push (FCM / APNs)
28. Tests de integración end-to-end
29. Indicador persistente en HomeScreen cuando se está en canal de voz
30. Icono de la app (LogoSecureChat.png en carpeta icons/)
31. UI de transferencia de archivos en cliente Flutter
32. TLS / HTTPS para producción
```

---

## Dinámica de trabajo

- Rol usuario: **Director del Proyecto**
- Rol asistente: **Desarrollador Senior**
- Diseño de referencia: `SECURECHAT_DESIGN.md`
- Iteraciones cortas: una feature o fix a la vez
