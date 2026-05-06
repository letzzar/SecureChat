# SecureChat — Handoff de Sesión

**Fecha:** 2026-05-06 (sesión Windows — tarde)
**Plataforma:** Windows 11 Pro 10.0.26200
**Para retomar:** di "continua sesion" o "lee el SESSION_HANDOFF.md"

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
| 4b | Portado a macOS desktop + Windows desktop (archivos) | ✅ Completo |

### Completado en esta sesión

- [x] Flutter 3.41.9 instalado en `D:\flutter` (ZIP descargado y extraído)
- [x] `D:\flutter\bin` añadido al PATH de usuario permanentemente
- [x] Android toolchain: cmdline-tools 14742923 instalados en `C:\Users\letzz\AppData\Local\Android\Sdk\cmdline-tools\latest`
- [x] `ANDROID_HOME` = `C:\Users\letzz\AppData\Local\Android\Sdk` (variable de entorno de usuario)
- [x] Licencias Android aceptadas (todas)
- [x] `AndroidManifest.xml` actualizado con permisos: `RECORD_AUDIO`, `CAMERA`, `INTERNET`, `MODIFY_AUDIO_SETTINGS`
- [x] Proyecto copiado a `D:\SecureChat` (unidad local NTFS — necesario, Y: es NAS y no permite symlinks)

### Pendiente inmediato — PRÓXIMO PASO AL REINICIAR

- [ ] **Build Windows**: ejecutar desde `D:\SecureChat\securechat-app` una vez que Visual Studio Community 2026 + ATL esté instalado
- [ ] Fase 5: pulido y seguridad (no iniciada)

---

## CONTEXTO CRÍTICO — POR QUÉ D:\SecureChat

`Y:\` es una unidad de red (NAS, label: "Software"). Windows **no permite crear symlinks en unidades de red**, y Flutter los necesita para los plugins. Por eso **todos los builds deben hacerse desde `D:\SecureChat\securechat-app`**, no desde `Y:`.

`Y:\Mi software\SecureChat` se conserva como **backup en el NAS**. Para sincronizar cambios de D: al NAS usar:
```powershell
robocopy "D:\SecureChat" "Y:\Mi software\SecureChat" /E /XD ".dart_tool" "build" /NFL /NDL
```

---

## Por qué falló el build Windows y qué se hizo

El `flutter build windows` fallaba por falta de `atlstr.h` (cabecera ATL de Visual Studio).
El usuario está instalando **Visual Studio Community 2026 con el componente "ATL de C++"**.

Una vez instalado y reiniciado, el build debería completarse con:
```powershell
cd D:\SecureChat\securechat-app
D:\flutter\bin\flutter.bat build windows --release
```

Resultado esperado: `D:\SecureChat\securechat-app\build\windows\x64\runner\Release\securechat.exe`

---

## Entorno Windows configurado

| Herramienta | Ubicación |
|---|---|
| Flutter SDK | `D:\flutter` |
| Flutter bin | `D:\flutter\bin` (en PATH usuario) |
| Android SDK | `C:\Users\letzz\AppData\Local\Android\Sdk` |
| Android cmdline-tools | `...\Sdk\cmdline-tools\latest\bin` (en PATH usuario) |
| Visual Studio Community 2026 | En instalación (con ATL de C++) |
| Visual Studio Build Tools 2026 | `C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools` |
| Visual Studio 2022 Community | `C:\Program Files\Microsoft Visual Studio\2022\Community` |
| Proyecto (trabajo) | `D:\SecureChat\securechat-app` |
| Proyecto (backup NAS) | `Y:\Mi software\SecureChat` |

---

## Estructura del proyecto

```
D:\SecureChat\               ← directorio de trabajo en Windows
├── SECURECHAT_DESIGN.md
├── SESSION_HANDOFF.md
├── CLAUDE.md
├── securechat-server/        # Servidor Go
│   ├── main.go
│   ├── config.toml
│   ├── securechat-server-windows-amd64.exe
│   ├── api/ ws/ sfu/ db/ crypto/
└── securechat-app/           # Flutter app
    ├── pubspec.yaml
    ├── android/app/src/main/AndroidManifest.xml  ← permisos añadidos
    └── lib/ ios/ android/ macos/ windows/
```

---

## API REST / WebSocket — sin cambios

Ver SECURECHAT_DESIGN.md para el protocolo completo.

---

## Fase 5 — Pendiente (aún no iniciada)

```
24. Rate limiting en servidor
25. Expiración de salas efímeras
26. Exportación/importación de identidad (BIP39)
27. Notificaciones push (FCM / APNs)
28. Tests de integración end-to-end
29. Indicador persistente en HomeScreen cuando se está en canal de voz
30. Icono de la app (LogoSecureChat.png en carpeta icons/)
```

---

## Dinámica de trabajo

- Rol usuario: **Director del Proyecto**
- Rol asistente: **Desarrollador Senior**
- Diseño de referencia: `SECURECHAT_DESIGN.md`
- Iteraciones cortas: una feature o fix a la vez
