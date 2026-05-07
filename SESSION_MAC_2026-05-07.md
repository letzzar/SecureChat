# SecureChat — Sesión Mac 2026-05-07

> Log de sesión. El estado canónico y actualizado está en `SESSION_HANDOFF.md`.

## Objetivo de esta sesión
Compilar el cliente Flutter para macOS y hacer pruebas de envío Mac ↔ PC Windows.

## Ubicación del proyecto
```
/Users/Letzzar/Mi Software/SecureChat/
  securechat-app/       ← cliente Flutter (aquí debes estar para compilar)
  securechat-server/    ← servidor Go (corre en el PC Windows)
```

## Comando de compilación
```bash
cd "/Users/Letzzar/Mi Software/SecureChat/securechat-app"
flutter pub get
flutter build macos --release
```

El binario queda en:
```
build/macos/Build/Products/Release/securechat.app
```

## Servidor
El servidor corre en el **PC Windows** en `http://<ip-del-pc>:8080`.  
Apunta la app del Mac a esa IP (no a localhost).

Binario del servidor: `D:\SecureChat\securechat-server\securechat-server-windows-amd64.exe`  
Config: `D:\SecureChat\securechat-server\config.toml` → `mode = "private"`

## Cambios recientes en el servidor (esta sesión)
1. **Modo público/privado** — `config.toml`: `mode = "private"` | `"public"`
   - Privado: registro requiere invite code
   - Público: registro libre
2. **Transferencia de archivos por WebSocket** (relay E2E cifrado)
   - Solo funciona si ambos usuarios están online
   - Mensajes nuevos: `file_offer`, `file_accept`, `file_reject`, `file_cancel`, `file_chunk`, `file_done`, `file_error`
   - El cliente Flutter aún no implementa esto — pendiente

## Estado de la BD (PC Windows)
- 3 usuarios registrados
- Invites válidos hasta 04/06/2026:
  - `8b82d0ae4758b7e833db59d46dff2bf0`
  - `0b24f93c56f802ff6de8319daf08ce39`

## Si flutter build falla en Mac
Cosas a revisar:
```bash
flutter doctor          # ver qué falta
xcode-select --install  # si pide Xcode CLI tools
```

Si hay error de firma (signing):
- Abre Xcode → abre `securechat-app/macos/Runner.xcworkspace`
- Signing & Capabilities → selecciona tu Team

Si hay error de pods:
```bash
cd macos
pod install
cd ..
flutter build macos --release
```

## Próximos pasos pendientes
- [ ] Implementar UI de transferencia de archivos en el cliente Flutter
- [ ] Pruebas Mac ↔ PC con servidor en Windows
- [ ] TLS / HTTPS para producción
