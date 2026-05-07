# SecureChat

**English** | [Español](#español)

---

A self-hosted, end-to-end encrypted messaging platform with group voice — built on a WireGuard-inspired cryptographic stack.

## Overview

SecureChat consists of two components:

- **Flutter client** — identical UI on Android, iOS, macOS, Windows, and Linux
- **Go server** — a blind router that never reads content; deployable on Linux, Windows, or macOS as a single binary

The server URL is configured at first launch. From that point, all communication flows encrypted between devices. The server stores the bare minimum required to function.

## Features

- End-to-end encrypted text messaging (1-to-1 and group rooms)
- Group voice calls in real time (WebRTC + SFU + SRTP)
- Password-protected rooms with Argon2id key derivation
- Cryptographic identity — no email, phone, or password required
- Offline message queue (up to 72 h)
- Import/export identity via QR code or 24-word BIP39 phrase
- Self-hostable in minutes — single Go binary, no heavy dependencies

## Cryptographic Stack

Inspired by WireGuard — 5 primitives, no algorithm negotiation, no downgrade attacks possible.

| Primitive | Purpose |
|---|---|
| **X25519** | ECDH key exchange |
| **ChaCha20-Poly1305** | Authenticated symmetric encryption |
| **BLAKE2s** | Identity and room ID hashing |
| **Ed25519** | Message digital signatures |
| **Argon2id** | Password-based key derivation |

The **Noise Protocol Framework** (`Noise_IK` pattern) orchestrates the device-to-device handshake.

## Architecture

```
Flutter App                              Flutter App
(Android/iOS/macOS/Windows/Linux)        (Android/iOS/macOS/Windows/Linux)
        │                                        │
        │      WebSocket TLS 1.3 + SRTP/UDP     │
        └──────────────┬─────────────────────────┘
                       │
              ┌────────▼────────┐
              │   Go Server     │
              │                 │
              │  Signaling WS   │  ← WebSocket handler
              │  SFU            │  ← Forwards SRTP without decrypting
              │  REST API       │  ← Registration, public keys
              │  SQLite         │  ← Minimal metadata only
              └─────────────────┘
```

The server only sees encrypted blobs. Even with direct database access, message content is unreadable.

## Getting Started

### Server

```bash
# Copy and edit the config
cp config.toml.example config.toml

# Run
./securechat-server          # Linux
securechat-server.exe        # Windows
```

The server listens on port `8080` by default. Set `tls = true` and provide cert/key paths for production.

**Generate a JWT secret:**
```bash
openssl rand -hex 32
```

### Client

```bash
cd securechat-app
flutter pub get
flutter run
```

On first launch, enter the server URL and choose a display name. The app generates your cryptographic identity locally — private keys never leave the device.

## Project Structure

```
SecureChat/
├── securechat-app/     # Flutter client (Android, iOS, macOS, Windows, Linux)
├── securechat-server/  # Go server
│   ├── api/            # REST handlers
│   ├── ws/             # WebSocket signaling
│   ├── sfu/            # Selective Forwarding Unit (group voice)
│   ├── db/             # SQLite layer
│   ├── crypto/         # Cryptographic primitives
│   └── config.toml.example
└── icons/              # App icons and assets
```

## Requirements

| Component | Requirement |
|---|---|
| Flutter client | Flutter 3.x, Dart 3.x |
| Go server | Go 1.21+ |
| Server OS | Linux, Windows, or macOS (x64) |

---

# Español

Una plataforma de mensajería cifrada de extremo a extremo con voz grupal, autoalojable, construida sobre una pila criptográfica inspirada en WireGuard.

## Descripción General

SecureChat se compone de dos elementos:

- **Cliente Flutter** — interfaz idéntica en Android, iOS, macOS, Windows y Linux
- **Servidor Go** — enrutador ciego que nunca lee el contenido; desplegable en Linux, Windows o macOS como binario único

La URL del servidor se configura en el primer arranque. A partir de ahí, toda la comunicación fluye cifrada entre dispositivos. El servidor almacena el mínimo absoluto para funcionar.

## Características

- Mensajería de texto cifrada de extremo a extremo (1 a 1 y salas grupales)
- Voz grupal en tiempo real (WebRTC + SFU + SRTP)
- Salas protegidas por contraseña con derivación de claves Argon2id
- Identidad basada en criptografía — sin email, teléfono ni contraseña tradicional
- Cola de mensajes offline (hasta 72 h)
- Importación/exportación de identidad por código QR o frase de 24 palabras BIP39
- Autoalojable en minutos — binario único en Go, sin dependencias externas pesadas

## Pila Criptográfica

Inspirada en WireGuard — 5 primitivas, sin negociación de algoritmos, sin posibilidad de ataques de downgrade.

| Primitiva | Uso |
|---|---|
| **X25519** | Intercambio de claves ECDH |
| **ChaCha20-Poly1305** | Cifrado simétrico autenticado |
| **BLAKE2s** | Hash de identidades e IDs de sala |
| **Ed25519** | Firma digital de mensajes |
| **Argon2id** | Derivación de claves desde contraseña |

El **Noise Protocol Framework** (patrón `Noise_IK`) orquesta el handshake entre dispositivos.

## Inicio Rápido

### Servidor

```bash
# Copiar y editar la configuración
cp config.toml.example config.toml

# Ejecutar
./securechat-server          # Linux
securechat-server.exe        # Windows
```

Escucha en el puerto `8080` por defecto. Activa `tls = true` y proporciona rutas de cert/clave para producción.

**Generar un JWT secret:**
```bash
openssl rand -hex 32
```

### Cliente

```bash
cd securechat-app
flutter pub get
flutter run
```

En el primer arranque, introduce la URL del servidor y elige un nombre de usuario. La app genera tu identidad criptográfica localmente — las claves privadas nunca abandonan el dispositivo.

## Estructura del Proyecto

```
SecureChat/
├── securechat-app/     # Cliente Flutter (Android, iOS, macOS, Windows, Linux)
├── securechat-server/  # Servidor Go
│   ├── api/            # Handlers REST
│   ├── ws/             # Signaling WebSocket
│   ├── sfu/            # Selective Forwarding Unit (voz grupal)
│   ├── db/             # Capa SQLite
│   ├── crypto/         # Primitivas criptográficas
│   └── config.toml.example
└── icons/              # Iconos y assets de la app
```

## Requisitos

| Componente | Requisito |
|---|---|
| Cliente Flutter | Flutter 3.x, Dart 3.x |
| Servidor Go | Go 1.21+ |
| SO del servidor | Linux, Windows o macOS (x64) |

## Filosofía de Privacidad

- **Privacy by default**: el servidor no puede leer nada, ni con acceso directo a la base de datos
- **Sin metadatos innecesarios**: el servidor no sabe quién habla con quién dentro de una sala
- **Pila mínima y auditable**: menos de 500 líneas de código criptográfico total
- **Autocontenido**: cualquier persona puede levantar su propio servidor en minutos

---

*Estado: En implementación activa — v1*
