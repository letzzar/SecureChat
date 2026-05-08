# SecureChat — Client App

> **English** · [Español](#cliente-securechat--español)

---

## What is SecureChat?

SecureChat is an end-to-end encrypted messaging app built with Flutter. It supports direct messages, group rooms, voice calls (1-1 and multi-party), and file transfers. All message content is encrypted on the device before it reaches the server — the server never sees plaintext.

---

## How it works

### Crypto stack

| Layer | Algorithm | Purpose |
|-------|-----------|---------|
| Key exchange | **Noise\_IK** (X25519) | DM handshake — authenticates both parties and derives a shared secret |
| Symmetric encryption | **ChaCha20-Poly1305** | Encrypts every message payload |
| Message authentication | **Ed25519** signatures | Proves the sender's identity |
| Key derivation | **BLAKE2s** | Derives sub-keys from the shared secret |
| Room keys | **Argon2id** (passphrase-based) | Group rooms use a key derived from the room passphrase |

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Flutter App                                                    │
│                                                                 │
│  Screens ──► Riverpod providers ──► Stores                      │
│                │                       │                        │
│                │              messages_store  (DM E2E)          │
│                │              rooms_store     (group E2E)       │
│                │              file_transfer_store               │
│                │              dm_voice_store  (P2P WebRTC)      │
│                │              voice_store     (SFU rooms)       │
│                │                                                │
│                └──► WsClient (WebSocket) ──► Server             │
│                └──► ApiClient (REST)     ──► Server             │
└─────────────────────────────────────────────────────────────────┘
```

- **State management**: Riverpod (`NotifierProvider`, `StateProvider`)
- **Navigation**: `go_router` — routes: `/` (splash), `/setup`, `/home`
- **WebSocket**: single persistent connection; all real-time events (messages, call signals, delivery acks) flow through it
- **Key storage**: `flutter_secure_storage` on Android/iOS/Windows; custom file-based store on macOS (avoids keychain prompts on ad-hoc builds)

### Message flow (DM)

1. First message: sender performs a **Noise\_IK handshake** (`noise_init` WS message), embedding the first ciphertext
2. Receiver completes the handshake; both sides hold a shared ChaCha20 key
3. Subsequent messages are encrypted directly with that key and sent as `dm` WS messages
4. Server stores messages for offline recipients (72 h TTL by default) and delivers them on reconnect
5. Server sends a `delivered` ack with the original sequence number; the client shows a single tick (✓)

### Voice (DM)

Peer-to-peer WebRTC. Offer/answer/ICE signals are relayed through the server (`dm_call_*` WS messages); audio never touches the server.

### Voice (group rooms)

Server-side SFU (Selective Forwarding Unit) in Go. Audio packets from each participant are forwarded to all others.

---

## Prerequisites

| Tool | Version | Required for |
|------|---------|-------------|
| [Flutter SDK](https://docs.flutter.dev/get-started/install) | ≥ 3.19 (Dart ≥ 3.3) | All platforms |
| Android SDK + Java 17 | API level 21+ | Android |
| [Xcode](https://developer.apple.com/xcode/) 15+ | — | iOS and macOS |
| [CocoaPods](https://cocoapods.org/) | ≥ 1.14 | iOS and macOS |
| Visual Studio 2022 | "Desktop development with C++" workload | Windows desktop |

Check your environment:

```bash
flutter doctor -v
```

---

## Getting the code

```bash
git clone https://github.com/letzzar/SecureChat.git
cd SecureChat/securechat-app
flutter pub get
```

---

## Building

### Android

```bash
# Debug (for testing on a connected device or emulator)
flutter run

# Release APK (side-loading)
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk

# Release App Bundle (Google Play)
flutter build appbundle --release
```

### iOS (requires macOS + Xcode)

```bash
flutter build ios --release
```

Open `ios/Runner.xcworkspace` in Xcode to sign and archive for distribution.

### macOS desktop

```bash
flutter build macos --release
# Output: build/macos/Build/Products/Release/securechat.app
```

### Windows desktop

```powershell
flutter build windows --release
# Output: build\windows\x64\runner\Release\
```

> **Note**: The Release folder is self-contained. Copy it to distribute — no installer needed.

---

## Running the server

The client needs a running SecureChat server. See [`../securechat-server/README.md`](../securechat-server/README.md) or [`../SERVER.md`](../SERVER.md) for full setup instructions.

Quick start (pre-built binary):

```bash
# Linux / macOS
./securechat-server

# Windows
.\securechat-server-windows-amd64.exe
```

The app will ask for the server URL on first launch (e.g. `http://192.168.1.10:8080`).

---

## Project structure

```
lib/
├── main.dart                      # Entry point
├── app.dart                       # Root widget, WS listener, router
├── network/
│   ├── api_client.dart            # REST client (register, login, search, …)
│   └── ws_client.dart             # WebSocket client (send / receive)
├── crypto/
│   ├── identity.dart              # Key generation, persistence, JWT
│   ├── noise_handshake.dart       # Noise_IK implementation
│   ├── message_crypto.dart        # ChaCha20-Poly1305 encrypt/decrypt
│   ├── room_crypto.dart           # Room key derivation (Argon2id)
│   ├── signatures.dart            # Ed25519 sign / verify
│   └── secure_kv.dart             # Key-value storage (platform-aware)
├── models/
│   ├── message.dart               # ChatMessage, MessageKind, MessageStatus
│   ├── room.dart                  # Room model
│   └── user.dart                  # User model
├── store/
│   ├── app_state.dart             # Session, knownPeers, contacts, federation
│   ├── messages_store.dart        # DM conversation state + send/receive
│   ├── rooms_store.dart           # Room state
│   ├── file_transfer_store.dart   # File send/receive state machine
│   ├── dm_voice_store.dart        # 1-1 voice call lifecycle (WebRTC)
│   └── voice_store.dart           # Group room voice (SFU)
├── screens/
│   ├── setup/server_setup_screen.dart
│   ├── home/home_screen.dart      # Chats, rooms, contacts, profile tabs
│   ├── chat/chat_screen.dart      # 1-1 DM screen
│   └── rooms/                     # Room list, create, join, chat screens
├── widgets/
│   └── emoji_input_bar.dart       # Shared input bar with emoji picker
└── voice/
    └── voice_client.dart          # WebRTC helpers for group rooms
```

---

## Key dependencies

| Package | Use |
|---------|-----|
| `flutter_riverpod` | State management |
| `go_router` | Navigation |
| `cryptography` | ChaCha20-Poly1305, Ed25519, BLAKE2s |
| `flutter_secure_storage` | Key storage (Android, iOS, Windows) |
| `web_socket_channel` | WebSocket transport |
| `flutter_webrtc` | P2P and SFU voice |
| `emoji_picker_flutter` | Emoji picker panel |
| `file_picker` + `path_provider` | File transfer |
| `qr_flutter` | QR code display for invite codes |

---

---

# Cliente SecureChat — Español

> [English](#securechat--client-app) · **Español**

---

## ¿Qué es SecureChat?

SecureChat es una aplicación de mensajería cifrada de extremo a extremo construida con Flutter. Soporta mensajes directos, salas de grupo, llamadas de voz (1-1 y multi-participante) y transferencia de archivos. Todo el contenido se cifra en el dispositivo antes de llegar al servidor — el servidor nunca ve texto plano.

---

## Cómo funciona

### Stack criptográfico

| Capa | Algoritmo | Propósito |
|------|-----------|-----------|
| Intercambio de claves | **Noise\_IK** (X25519) | Handshake DM — autentica ambas partes y deriva un secreto compartido |
| Cifrado simétrico | **ChaCha20-Poly1305** | Cifra cada payload de mensaje |
| Autenticación | Firmas **Ed25519** | Prueba la identidad del remitente |
| Derivación de claves | **BLAKE2s** | Deriva sub-claves del secreto compartido |
| Claves de sala | **Argon2id** (basado en passphrase) | Las salas de grupo usan una clave derivada de la contraseña de sala |

### Arquitectura

```
┌─────────────────────────────────────────────────────────────────┐
│  App Flutter                                                    │
│                                                                 │
│  Pantallas ──► Providers Riverpod ──► Stores                    │
│                  │                       │                      │
│                  │              messages_store  (DM E2E)        │
│                  │              rooms_store     (grupo E2E)     │
│                  │              file_transfer_store             │
│                  │              dm_voice_store  (P2P WebRTC)    │
│                  │              voice_store     (SFU salas)     │
│                  │                                              │
│                  └──► WsClient (WebSocket) ──► Servidor         │
│                  └──► ApiClient (REST)     ──► Servidor         │
└─────────────────────────────────────────────────────────────────┘
```

- **Gestión de estado**: Riverpod (`NotifierProvider`, `StateProvider`)
- **Navegación**: `go_router` — rutas: `/` (splash), `/setup`, `/home`
- **WebSocket**: conexión persistente única; todos los eventos en tiempo real (mensajes, señales de llamada, acks) pasan por ella
- **Almacenamiento de claves**: `flutter_secure_storage` en Android/iOS/Windows; almacenamiento en archivo propio en macOS (evita los prompts de contraseña de keychain en builds ad-hoc)

### Flujo de un mensaje (DM)

1. Primer mensaje: el remitente realiza un **handshake Noise\_IK** (mensaje WS `noise_init`), incorporando el primer texto cifrado
2. El receptor completa el handshake; ambos extremos tienen una clave ChaCha20 compartida
3. Los mensajes siguientes se cifran directamente con esa clave y se envían como mensajes WS `dm`
4. El servidor almacena los mensajes para destinatarios offline (TTL 72 h por defecto) y los entrega al reconectar
5. El servidor envía un ack `delivered` con el número de secuencia original; el cliente muestra un tick simple (✓)

### Voz (DM)

WebRTC peer-to-peer. Las señales offer/answer/ICE se retransmiten a través del servidor (mensajes WS `dm_call_*`); el audio nunca toca el servidor.

### Voz (salas de grupo)

SFU (Selective Forwarding Unit) en el servidor Go. Los paquetes de audio de cada participante se reenvían a todos los demás.

---

## Requisitos previos

| Herramienta | Versión | Necesario para |
|-------------|---------|---------------|
| [Flutter SDK](https://docs.flutter.dev/get-started/install) | ≥ 3.19 (Dart ≥ 3.3) | Todas las plataformas |
| Android SDK + Java 17 | API level 21+ | Android |
| [Xcode](https://developer.apple.com/xcode/) 15+ | — | iOS y macOS |
| [CocoaPods](https://cocoapods.org/) | ≥ 1.14 | iOS y macOS |
| Visual Studio 2022 | Carga "Desktop development with C++" | Windows desktop |

Verifica tu entorno:

```bash
flutter doctor -v
```

---

## Obtener el código

```bash
git clone https://github.com/letzzar/SecureChat.git
cd SecureChat/securechat-app
flutter pub get
```

---

## Compilación

### Android

```bash
# Debug (para probar en dispositivo o emulador)
flutter run

# APK de release (distribución directa)
flutter build apk --release
# Salida: build/app/outputs/flutter-apk/app-release.apk

# App Bundle (Google Play)
flutter build appbundle --release
```

### iOS (requiere macOS + Xcode)

```bash
flutter build ios --release
```

Abre `ios/Runner.xcworkspace` en Xcode para firmar y archivar para distribución.

### macOS desktop

```bash
flutter build macos --release
# Salida: build/macos/Build/Products/Release/securechat.app
```

### Windows desktop

```powershell
flutter build windows --release
# Salida: build\windows\x64\runner\Release\
```

> **Nota**: La carpeta Release es autocontenida. Cópiala para distribuir — no necesita instalador.

---

## Ejecutar el servidor

El cliente necesita un servidor SecureChat en funcionamiento. Consulta [`../securechat-server/README.md`](../securechat-server/README.md) o [`../SERVER.md`](../SERVER.md) para instrucciones completas.

Inicio rápido (binario precompilado):

```bash
# Linux / macOS
./securechat-server

# Windows
.\securechat-server-windows-amd64.exe
```

La app pedirá la URL del servidor en el primer arranque (p. ej. `http://192.168.1.10:8080`).

---

## Estructura del proyecto

```
lib/
├── main.dart                      # Punto de entrada
├── app.dart                       # Widget raíz, listener WS, router
├── network/
│   ├── api_client.dart            # Cliente REST (registro, login, búsqueda…)
│   └── ws_client.dart             # Cliente WebSocket (enviar/recibir)
├── crypto/
│   ├── identity.dart              # Generación de claves, persistencia, JWT
│   ├── noise_handshake.dart       # Implementación Noise_IK
│   ├── message_crypto.dart        # Cifrado/descifrado ChaCha20-Poly1305
│   ├── room_crypto.dart           # Derivación de clave de sala (Argon2id)
│   ├── signatures.dart            # Firma/verificación Ed25519
│   └── secure_kv.dart             # Almacenamiento clave-valor (por plataforma)
├── models/
│   ├── message.dart               # ChatMessage, MessageKind, MessageStatus
│   ├── room.dart                  # Modelo de sala
│   └── user.dart                  # Modelo de usuario
├── store/
│   ├── app_state.dart             # Sesión, knownPeers, contactos, federación
│   ├── messages_store.dart        # Estado de conversación DM + envío/recepción
│   ├── rooms_store.dart           # Estado de salas
│   ├── file_transfer_store.dart   # Máquina de estados de transferencia de archivos
│   ├── dm_voice_store.dart        # Ciclo de vida llamada 1-1 (WebRTC)
│   └── voice_store.dart           # Voz en salas de grupo (SFU)
├── screens/
│   ├── setup/server_setup_screen.dart
│   ├── home/home_screen.dart      # Tabs: Chats, Salas, Contactos, Perfil
│   ├── chat/chat_screen.dart      # Pantalla de chat DM
│   └── rooms/                     # Lista, crear, unirse, chat de sala
├── widgets/
│   └── emoji_input_bar.dart       # Barra de entrada compartida con selector de emojis
└── voice/
    └── voice_client.dart          # Helpers WebRTC para salas de grupo
```

---

## Dependencias principales

| Paquete | Uso |
|---------|-----|
| `flutter_riverpod` | Gestión de estado |
| `go_router` | Navegación |
| `cryptography` | ChaCha20-Poly1305, Ed25519, BLAKE2s |
| `flutter_secure_storage` | Almacenamiento de claves (Android, iOS, Windows) |
| `web_socket_channel` | Transporte WebSocket |
| `flutter_webrtc` | Voz P2P y SFU |
| `emoji_picker_flutter` | Panel de selección de emojis |
| `file_picker` + `path_provider` | Transferencia de archivos |
| `qr_flutter` | Mostrar QR de códigos de invitación |
