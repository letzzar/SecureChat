# SecureChat — Documento de Diseño del Proyecto

**Versión:** 1.2  
**Fecha:** Mayo 2026  
**Estado:** En implementación  
**Cambio v1.1:** Voz grupal en salas promovida a feature core de v1. Arquitectura SFU integrada en servidor Go.  
**Cambio v1.2:** App portada a escritorio (macOS, Windows x64, Linux). Servidor disponible para Windows, Linux y macOS — no móvil.

---

## 1. Visión General

SecureChat es una aplicación de comunicaciones cifradas de extremo a extremo compuesta por:

- Una **app Flutter multiplataforma** (Android, iOS, macOS, Windows y Linux) con interfaz idéntica en todas las plataformas
- Un **servidor central en Go** que actúa como enrutador ciego — nunca puede leer el contenido — disponible para Windows, Linux y macOS

El usuario configura la app introduciendo la dirección del servidor al primer arranque. A partir de ahí, toda la comunicación fluye cifrada entre dispositivos. El servidor almacena el mínimo absoluto de datos para funcionar.

### Filosofía de diseño

- **Privacy by default**: el servidor no puede leer nada, ni con acceso directo a la base de datos
- **Pila criptográfica mínima**: inspirada en WireGuard — solo 5 primitivas, sin negociación de algoritmos
- **Sin metadatos innecesarios**: el servidor no sabe quién habla con quién dentro de una sala
- **Autocontenido**: cualquier persona puede levantar su propio servidor en minutos

---

## 2. Objetivos

### Objetivos primarios

1. **Voz grupal en tiempo real** dentro de cualquier sala (WebRTC + SFU + SRTP) — feature core de v1
2. Salas de chat grupales protegidas por contraseña, cifrado E2E, con canal de voz siempre disponible
3. Mensajería de texto entre usuarios, cifrado E2E
4. Identidad basada en criptografía — no en usuario/contraseña tradicional
5. El servidor almacena únicamente: IDs derivados, blobs cifrados, metadatos mínimos de enrutamiento

### Objetivos secundarios

1. Fácil despliegue del servidor (binario único en Go, sin dependencias externas pesadas) en Windows, Linux y macOS
2. Interfaz idéntica en Android, iOS, macOS, Windows y Linux
3. Funcionamiento detrás de NAT mediante TURN/STUN
4. Resistencia a ataques de fuerza bruta en contraseñas de sala (Argon2id)
5. Llamadas directas 1 a 1 entre usuarios (DM con voz, derivado del mismo stack SFU)

### No objetivos (fuera de alcance en v1)

- Videollamada (se puede añadir en v2, WebRTC ya lo soporta nativamente)
- Federación entre servidores
- Servidor en móvil (iOS/Android) — no tiene sentido como nodo servidor
- Grabación de llamadas (incompatible con el modelo E2E)

---

## 3. Arquitectura General

```
┌─────────────────────┐           ┌─────────────────────┐
│    App Flutter      │           │    App Flutter      │
│ Android/iOS/macOS/  │           │ Android/iOS/macOS/  │
│   Windows/Linux     │           │   Windows/Linux     │
│                     │           │                     │
│  ┌───────────────┐  │           │  ┌───────────────┐  │
│  │  Noise_IK     │  │           │  │  Noise_IK     │  │
│  │  Handshake    │  │           │  │  Handshake    │  │
│  ├───────────────┤  │           │  ├───────────────┤  │
│  │  ChaCha20-    │  │           │  │  ChaCha20-    │  │
│  │  Poly1305     │  │           │  │  Poly1305     │  │
│  ├───────────────┤  │           │  ├───────────────┤  │
│  │  WebRTC       │  │           │  │  WebRTC       │  │
│  │  (SRTP audio) │  │           │  │  (SRTP audio) │  │
│  └───────────────┘  │           │  └───────────────┘  │
└──────────┬──────────┘           └──────────┬──────────┘
           │                                  │
           │   WebSocket TLS 1.3 + SRTP/UDP  │
           └──────────────┬───────────────────┘
                          │
               ┌──────────▼──────────┐
               │   Servidor Go       │
               │                     │
               │  ┌───────────────┐  │
               │  │  Signaling    │  │  ← WebSocket handler
               │  │  WebSocket    │  │
               │  ├───────────────┤  │
               │  │  SFU          │  │  ← Selective Forwarding Unit
               │  │  (audio grupal│  │    reenvía SRTP cifrado
               │  │   por sala)   │  │    sin descifrar
               │  ├───────────────┤  │
               │  │  REST API     │  │  ← Registro, claves públicas
               │  ├───────────────┤  │
               │  │  STUN/TURN    │  │  ← Traversal NAT
               │  ├───────────────┤  │
               │  │  SQLite       │  │  ← Mínimo de datos
               │  └───────────────┘  │
               └─────────────────────┘
```

### Flujo de datos — principio fundamental

```
App A  ──[cifrado E2E]──►  Servidor  ──[cifrado E2E]──►  App B
                              │
                        Solo reenvía
                        bytes opacos
                        No puede leer nada
```

---

## 4. Pila Criptográfica (inspirada en WireGuard)

Solo se usan estas 5 primitivas — sin negociación, sin agilidad criptográfica:

| Primitiva | Uso | Biblioteca Go | Biblioteca Flutter |
|---|---|---|---|
| **X25519** | Intercambio de claves ECDH | `golang.org/x/crypto/curve25519` | `cryptography` (dart) |
| **ChaCha20-Poly1305** | Cifrado simétrico autenticado | `golang.org/x/crypto/chacha20poly1305` | `cryptography` (dart) |
| **BLAKE2s** | Hash de identidades y room_id | `golang.org/x/crypto/blake2s` | `cryptography` (dart) |
| **Ed25519** | Firma digital de mensajes | `crypto/ed25519` (stdlib Go) | `cryptography` (dart) |
| **Argon2id** | Derivación de claves desde contraseña | `golang.org/x/crypto/argon2` | `argon2` (dart) |

El **Noise Protocol Framework** (patrón `Noise_IK`) orquesta el handshake entre dispositivos usando X25519 y ChaCha20-Poly1305.

### Por qué esta pila

- **Auditabilidad**: menos de 500 líneas de código criptográfico total
- **Sin negociación**: no hay downgrade attacks posibles
- **Rendimiento móvil**: ChaCha20 es más rápido que AES en CPUs móviles sin AES-NI
- **Probada**: es exactamente la pila de WireGuard, auditada mundialmente

---

## 5. Identidad de Usuario

### Generación de identidad (solo en el dispositivo)

```
Al primer arranque de la app:

1. Generar par de claves X25519:
   private_key  → almacenado solo en el dispositivo (Secure Enclave / Keystore)
   public_key   → se registra en el servidor

2. Generar par de claves Ed25519:
   sign_private → almacenado solo en el dispositivo
   sign_public  → se registra en el servidor

3. Calcular user_id:
   user_id = BLAKE2s(public_key_X25519)  ← es el identificador público

4. Elegir nombre de usuario (display name)
   → se sube al servidor en texto plano (es público intencionalmente)
```

### Lo que el servidor almacena de cada usuario

```sql
-- Tabla: users
user_id        TEXT PRIMARY KEY   -- BLAKE2s(public_key), no nombre real
display_name   TEXT               -- nombre elegido por el usuario
public_key     BLOB               -- clave X25519 pública (32 bytes)
sign_public    BLOB               -- clave Ed25519 pública (32 bytes)
registered_at  INTEGER            -- timestamp Unix
last_seen      INTEGER            -- timestamp Unix (actualizado en conexión)

-- NO se almacena: contraseña, email, teléfono, IP, geolocalización
```

### Protección de la clave privada en el dispositivo

- **Android**: Android Keystore (hardware-backed si disponible)
- **iOS**: Secure Enclave vía `flutter_secure_storage`
- La clave privada **nunca sale del dispositivo**, ni cifrada

---

## 6. Primer Arranque — Configuración del Servidor

Al abrir la app por primera vez, se muestra una pantalla de configuración:

```
┌─────────────────────────────────┐
│                                 │
│  SecureChat                     │
│                                 │
│  Dirección del servidor:        │
│  ┌─────────────────────────┐    │
│  │ https://mi.servidor.com │    │
│  └─────────────────────────┘    │
│                                 │
│  Nombre de usuario:             │
│  ┌─────────────────────────┐    │
│  │ satoshi                 │    │
│  └─────────────────────────┘    │
│                                 │
│  [ Conectar y crear identidad ] │
│                                 │
└─────────────────────────────────┘
```

### Proceso de onboarding

```
1. Usuario introduce URL del servidor (ej: https://chat.ejemplo.com)
2. App verifica conectividad: GET /api/v1/health
3. App genera par de claves X25519 + Ed25519 localmente
4. App registra user_id + display_name + claves públicas: POST /api/v1/register
5. Servidor responde con token JWT firmado
6. App almacena: server_url, user_id, JWT, claves privadas (Keystore)
7. App redirige a pantalla principal

Si el usuario ya tiene identidad (reinstalación):
→ Opción de importar identidad mediante QR o frase de recuperación (24 palabras BIP39)
```

---

## 7. Mensajería Directa (1 a 1)

### Cifrado de mensajes directos

```
Para enviar mensaje de A a B:

1. A obtiene public_key de B del servidor (GET /api/v1/users/{user_id})
2. A realiza Noise_IK handshake con B (a través del servidor de señalización)
3. Canal Noise establecido — clave de sesión derivada
4. Mensaje cifrado con ChaCha20-Poly1305 usando clave de sesión
5. Mensaje firmado con Ed25519 de A
6. Servidor recibe: { to: user_id_B, payload: <opaco>, sig: <firma> }
7. Servidor verifica firma Ed25519 (anti-spam), reenvía a B
8. B descifra con su clave privada
```

### Estructura del mensaje en tránsito

```json
{
  "type": "dm",
  "from": "BLAKE2s(public_key_A)",
  "to":   "BLAKE2s(public_key_B)",
  "nonce": "<96 bits aleatorios, base64>",
  "seq": 1234,
  "payload": "<ChaCha20-Poly1305 cifrado, base64>",
  "sig": "<Ed25519 sobre {from,to,nonce,seq,payload}, base64>",
  "ts": 1714900000
}
```

### Lo que el servidor almacena de mensajes directos

```
NADA en v1 — los mensajes solo se entregan en tiempo real.

Si el destinatario está offline:
→ El servidor almacena el mensaje cifrado hasta 72 horas
→ Estructura almacenada: {from, to, payload, sig, ts, nonce}
→ El servidor nunca puede leer payload
→ Tras entrega confirmada, se borra
→ Tras 72h sin entrega, se borra igualmente
```

---

## 8. Salas de Chat Grupal

### Concepto fundamental

La contraseña de la sala **nunca llega al servidor**. El servidor solo conoce un `room_id` que es el hash de la clave derivada de la contraseña. No puede verificar si alguien tiene la contraseña correcta directamente — solo confirma que el `room_id` existe.

### Derivación de clave de sala

```
Inputs del usuario:
  - Nombre de sala: "equipo-alfa"  (público, legible)
  - Contraseña:     "clave_secreta_123"  (nunca sale del dispositivo)
  - Salt:           16 bytes aleatorios generados al crear la sala (público, en servidor)

Proceso (solo en la app):
  room_key = Argon2id(
    password   = "clave_secreta_123",
    salt       = <salt del servidor>,
    memory     = 65536,   // 64 MB
    iterations = 3,
    threads    = 4,
    keyLen     = 32
  )

  room_id = BLAKE2s(room_key)  // esto sí va al servidor
```

### Parámetros Argon2id

```
memory:     64 MB   → Cada intento de fuerza bruta requiere 64 MB de RAM
iterations: 3       → ~300ms en un móvil moderno (aceptable para el usuario)
threads:    4       → Paralelo, más costoso para atacantes con GPUs
output:     32 bytes → room_key final
```

Esto significa que un atacante con 1000 GPUs necesitaría años para forzar una contraseña de 12+ caracteres.

### Doble capa de cifrado en mensajes de sala

```
Mensaje original: "Hola a todos"
        │
        ▼
Capa 1 — Firma de identidad:
  signed_content = Ed25519_sign(mensaje + metadata, sign_private_key)

        │
        ▼
Capa 2 — Cifrado de sala:
  payload = ChaCha20-Poly1305(
    plaintext = {sender_id, signed_content, seq, ts},
    key       = room_key,
    nonce     = random 96 bits
  )

        │
        ▼
Enviado al servidor: { room_id, nonce, payload, ts }
El servidor NO puede leer payload.
```

### Creación de sala

```
1. Usuario elige nombre y contraseña en la app
2. App genera salt (16 bytes aleatorios)
3. App calcula room_key = Argon2id(contraseña, salt)
4. App calcula room_id  = BLAKE2s(room_key)
5. App envía al servidor: POST /api/v1/rooms
   Body: { room_id, room_name, salt, created_by: user_id, max_members: N }
6. Servidor crea la sala — almacena room_id, room_name, salt, created_by, ts
7. App muestra código de invitación: QR o texto con {server_url, room_id, salt, room_name}
   (NO incluye la contraseña — el invitado debe saber la contraseña por otro canal)
```

### Unirse a una sala

```
1. Usuario recibe invitación (QR o enlace): contiene room_id + salt + room_name
2. App muestra: "Sala: equipo-alfa — Introduce la contraseña"
3. Usuario introduce contraseña
4. App calcula room_key = Argon2id(contraseña, salt_de_la_invitación)
5. App calcula room_id_local = BLAKE2s(room_key)
6. App compara room_id_local con room_id_de_la_invitación
   - Si coinciden → contraseña correcta, enviar JOIN al servidor
   - Si no coinciden → "Contraseña incorrecta" (sin consultar el servidor)
7. Si correcto: WebSocket JOIN room_id
8. Servidor verifica que room_id existe → autoriza suscripción
```

### Lo que el servidor almacena de salas

```sql
-- Tabla: rooms
room_id      TEXT PRIMARY KEY  -- BLAKE2s(room_key), opaco
room_name    TEXT              -- nombre legible (público)
salt         BLOB              -- 16 bytes, necesario para que otros deriven room_key
created_by   TEXT              -- user_id del creador
created_at   INTEGER           -- timestamp
max_members  INTEGER           -- límite de miembros (0 = sin límite)
expires_at   INTEGER           -- opcional: sala efímera

-- Tabla: room_messages (solo para historial offline, opcional)
id           INTEGER PRIMARY KEY
room_id      TEXT
payload      BLOB              -- ChaCha20-Poly1305 cifrado, opaco
nonce        BLOB              -- 12 bytes
ts           INTEGER
-- NO se almacena: sender_id en claro, contenido descifrable
```

### Tipos de sala

```
EFÍMERA:     Sin historial. Mensajes solo en RAM. Al reiniciar el servidor, se pierden.
PERSISTENTE: Historial cifrado en SQLite. Límite configurable (ej: últimos 1000 mensajes).
TEMPORAL:    Con fecha de expiración. El servidor borra sala y mensajes automáticamente.
```

---

## 9. Voz Grupal en Salas (WebRTC + SFU)

### Por qué SFU y no P2P para grupos

Con P2P puro, cada participante necesitaría abrir N-1 conexiones simultáneas (una con cada miembro de la sala). Con 5 personas serían 10 streams de audio simultáneos por dispositivo — inviable en móvil. Un SFU (Selective Forwarding Unit) centraliza el reenvío: cada dispositivo sube un único stream al servidor, y el servidor lo distribuye a los demás sin descifrarlo.

```
P2P (no escalable):              SFU en servidor Go (v1):

A ←──────────────► B            A ──► Servidor ──► B
A ←──────────────► C                      │──────── C
A ←──────────────► D                      │──────── D
B ←──────────────► C                      │──────── E
... (N*(N-1)/2 conexiones)       (N conexiones, 1 por cliente)
```

### Principio de privacidad del SFU

El SFU reenvía paquetes SRTP **sin descifrarlos**. El cifrado DTLS-SRTP ocurre entre cada cliente y el servidor, pero las claves de medios se negocian de forma que el servidor solo puede reenviar, nunca descifrar el contenido de audio. Esto se logra mediante **SRTP con claves E2E** derivadas del Noise_IK handshake entre los propios participantes, pasando la clave de medios por el canal cifrado de señalización — el servidor nunca las ve.

```
Flujo de audio en la sala:

App A ──[SRTP cifrado E2E]──► SFU Go ──[mismo SRTP]──► App B
                                  └──────[mismo SRTP]──► App C
                                  └──────[mismo SRTP]──► App D

El SFU reenvía bytes opacos. No puede oír nada.
```

### Modelo de canal de voz en sala

Cada sala tiene un **canal de voz persistente y abierto**. No hay "iniciar llamada" — el canal existe mientras existe la sala. Los miembros entran y salen del canal de voz libremente, igual que en Discord.

```
Estados de un miembro en una sala:
  SOLO_TEXTO    → está en la sala, solo ve/envía mensajes de texto
  EN_VOZ        → está en el canal de voz, transmite y recibe audio
  SILENCIADO    → en voz pero con micrófono apagado (sigue recibiendo)
  SORDO         → en voz pero sin recibir audio (raro, pero posible)
```

### Codec y parámetros de audio

```
Codec:          Opus (estándar WebRTC, óptimo para voz)
Sample rate:    48 kHz
Bitrate:        ~32 kbps por stream (voz VOIP)
Frame size:     20 ms  → latencia extremo a extremo < 80 ms típico
VAD:            Activado — no se transmite silencio (ahorro de ancho de banda)
Cifrado:        DTLS-SRTP (nativo WebRTC, obligatorio)
Claves medios:  Derivadas de Noise_IK entre participantes, no visibles al servidor
```

### Arquitectura SFU en el servidor Go

```
securechat-server/
└── sfu/
    ├── sfu.go          ← Núcleo: gestión de rooms de voz y tracks
    ├── room.go         ← Room de voz: participantes activos, tracks
    ├── participant.go  ← Un participante: su PeerConnection WebRTC
    └── forwarder.go    ← Reenvío de paquetes SRTP entre participantes
```

El SFU se implementa sobre **Pion WebRTC** (`github.com/pion/webrtc/v3`), la implementación nativa de WebRTC en Go. No requiere dependencias externas como mediasoup (Node.js) ni Janus.

```go
// Dependencia clave en go.mod
github.com/pion/webrtc/v3     // WebRTC completo en Go puro
github.com/pion/interceptor   // NACK, RTCP, estadísticas
github.com/pion/rtcp          // paquetes RTCP
```

### Flujo: entrar al canal de voz de una sala

```
1. Usuario pulsa "Entrar a voz" en la sala
2. App crea PeerConnection WebRTC local
3. App añade track de audio local (micrófono)
4. App genera SDP offer → envía por WebSocket al servidor:
   { type: "voice_join", room_id, sdp_offer: <base64> }

5. Servidor SFU recibe offer:
   a. Crea PeerConnection para este participante
   b. Registra tracks remotos existentes (otros miembros en voz)
   c. Genera SDP answer incluyendo todos los tracks activos
   d. Responde: { type: "voice_joined", sdp_answer, participants: [...] }

6. Intercambio ICE candidates por WebSocket (trickle ICE)
7. Conexión DTLS-SRTP establecida entre App y SFU
8. App empieza a recibir audio de otros participantes
9. Servidor notifica a los demás:
   { type: "voice_participant_joined", room_id, user_id, display_name }
10. El SFU empieza a reenviar el track de A a B, C, D...
```

### Flujo: salir del canal de voz

```
1. Usuario pulsa "Salir de voz" o cierra la app
2. App envía: { type: "voice_leave", room_id }
3. SFU elimina PeerConnection del participante
4. SFU retira el track del participante del reenvío a los demás
5. SFU notifica a los restantes: { type: "voice_participant_left", user_id }
6. Los demás dejan de recibir el track de quien salió
```

### Gestión de múltiples salas simultáneas en el SFU

```
SFU (en memoria, sin persistencia):

rooms_voice: Map<room_id, VoiceRoom>

VoiceRoom {
  room_id:      string
  participants: Map<user_id, Participant>
  created_at:   time.Time
}

Participant {
  user_id:        string
  peer_conn:      *webrtc.PeerConnection
  audio_track:    *webrtc.TrackLocalStaticRTP
  muted:          bool
  joined_at:      time.Time
}
```

El estado de voz es **100% en memoria**. Si el servidor reinicia, los clientes reconectan automáticamente al canal de voz (la app detecta la desconexión y reintenta).

### Mensajes WebSocket relacionados con voz (añadidos)

```
CLIENTE → SERVIDOR:

{ "type": "voice_join",
  "room_id": "<room_id>",
  "sdp_offer": "<base64>" }

{ "type": "voice_leave",
  "room_id": "<room_id>" }

{ "type": "voice_ice",
  "room_id": "<room_id>",
  "candidate": "<ICE candidate JSON base64>" }

{ "type": "voice_mute",
  "room_id": "<room_id>",
  "muted": true }

SERVIDOR → CLIENTE:

{ "type": "voice_joined",
  "room_id": "<room_id>",
  "sdp_answer": "<base64>",
  "participants": [
    { "user_id": "...", "display_name": "...", "muted": false },
    ...
  ]}

{ "type": "voice_ice",
  "room_id": "<room_id>",
  "candidate": "<base64>" }

{ "type": "voice_participant_joined",
  "room_id": "<room_id>",
  "user_id": "...",
  "display_name": "..." }

{ "type": "voice_participant_left",
  "room_id": "<room_id>",
  "user_id": "..." }

{ "type": "voice_participant_muted",
  "room_id": "<room_id>",
  "user_id": "...",
  "muted": true }

{ "type": "voice_speaking",
  "room_id": "<room_id>",
  "user_id": "...",
  "speaking": true }   ← VAD detection en el cliente, notificado al SFU
```

### STUN/TURN para atravesar NAT

```
STUN (integrado en servidor Go con Pion):
  → El propio servidor Go expone endpoint STUN en UDP :3478
  → Los clientes lo usan para descubrir su IP pública
  → Sin dependencia externa

TURN (relay de último recurso):
  → Coturn externo recomendado para producción
  → El servidor Go expone credenciales HMAC-TURN vía API
  → Solo se usa cuando P2P (cliente ↔ servidor SFU) falla por NAT simétrico estricto
  → En la mayoría de casos no es necesario (cliente → servidor es más fácil que P2P)
```

### Llamadas directas 1 a 1 (DM con voz)

Las llamadas directas entre dos usuarios usan **el mismo stack SFU**, con una sala de voz efímera creada automáticamente para la duración de la llamada. No hay arquitectura separada para 1 a 1.

```
1. A pulsa "Llamar" en chat DM con B
2. App A crea sala de voz efímera: room_id_call = BLAKE2s(user_id_A + user_id_B + timestamp)
3. App A envía notificación cifrada a B: { type: "dm_call_invite", room_id: room_id_call }
4. B acepta → ambos hacen voice_join a room_id_call
5. SFU crea VoiceRoom efímera para esa room_id
6. Al colgar → voice_leave → SFU destruye la VoiceRoom
```

### Requisitos de servidor para SFU

```
Con voz grupal activa, los requisitos aumentan vs. solo texto:

Usuarios de voz simultáneos    RAM adicional    Ancho de banda servidor
────────────────────────────────────────────────────────────────────────
10 usuarios (2 salas)          ~50 MB           ~3 Mbps
50 usuarios (10 salas)         ~200 MB          ~15 Mbps
100 usuarios (20 salas)        ~400 MB          ~30 Mbps

CPU: Pion WebRTC es eficiente. 2 cores aguantan ~100 usuarios de voz.
El cuello de botella suele ser el ancho de banda de red, no la CPU.
```

---

## 10. Servidor Go — Diseño Detallado

### Filosofía del servidor

> "El servidor es un cartero ciego que entrega sobres sellados. No sabe qué hay dentro. No guarda copias. Solo sabe a quién entregar."

### Estructura de directorios

```
securechat-server/
├── main.go
├── config/
│   └── config.go          ← Lee config desde archivo o variables de entorno
├── api/
│   ├── router.go          ← Rutas HTTP REST
│   ├── handlers/
│   │   ├── health.go      ← GET /api/v1/health
│   │   ├── users.go       ← Registro y lookup de usuarios
│   │   ├── rooms.go       ← Crear/listar salas
│   │   └── auth.go        ← Validación JWT
├── ws/
│   ├── hub.go             ← Gestor de conexiones WebSocket activas
│   ├── client.go          ← Una conexión WebSocket = un cliente
│   └── messages.go        ← Tipos de mensajes WebSocket
├── sfu/
│   ├── sfu.go             ← Núcleo SFU: gestión de rooms de voz
│   ├── room.go            ← VoiceRoom: participantes y tracks activos
│   ├── participant.go     ← PeerConnection WebRTC de un participante
│   └── forwarder.go       ← Reenvío de paquetes SRTP entre participantes
├── db/
│   ├── db.go              ← Conexión SQLite
│   ├── users.go           ← Operaciones CRUD usuarios
│   ├── rooms.go           ← Operaciones CRUD salas
│   └── messages.go        ← Mensajes offline
├── crypto/
│   └── verify.go          ← Verificación de firmas Ed25519 entrantes
├── stun/
│   └── stun.go            ← Servidor STUN integrado (Pion)
└── Makefile
```

### Endpoints REST

```
GET  /api/v1/health
     → { status: "ok", version: "1.0" }
     → Usado por la app para verificar conectividad al configurar el servidor

POST /api/v1/register
     Body: { user_id, display_name, public_key, sign_public }
     → Crea usuario. Devuelve JWT.
     → Idempotente: si user_id ya existe y claves coinciden, renueva JWT.

GET  /api/v1/users/{user_id}
     Auth: JWT
     → { user_id, display_name, public_key, sign_public }
     → Para que A obtenga la clave pública de B antes del handshake

GET  /api/v1/users/search?q=nombre
     Auth: JWT
     → Lista de usuarios cuyo display_name contiene q
     → Máximo 20 resultados

POST /api/v1/rooms
     Auth: JWT
     Body: { room_id, room_name, salt, max_members, expires_at }
     → Crea sala. El servidor NO sabe la contraseña.

GET  /api/v1/rooms/{room_id}
     Auth: JWT
     → { room_id, room_name, salt, created_at, member_count }
     → La app necesita el salt para derivar room_key

GET  /api/v1/rooms
     Auth: JWT, Query: ?q=nombre
     → Lista de salas públicas (por nombre)

GET  /api/v1/stun
     → Configuración STUN/TURN para WebRTC
     → { stun_url, turn_url, turn_credential }

GET  /api/v1/rooms/{room_id}/voice
     Auth: JWT
     → { active: true, participant_count: 3, participants: [{user_id, display_name, muted}] }
     → Consultar quién está en el canal de voz antes de entrar
```

### Mensajes WebSocket

Una vez conectado por WebSocket con JWT válido, el cliente puede enviar/recibir:

```
CLIENTE → SERVIDOR:

{ "type": "dm",           → Mensaje directo a otro usuario
  "to": "<user_id>",
  "nonce": "<base64>",
  "payload": "<base64>",
  "sig": "<base64>",
  "seq": 1234,
  "ts": 1714900000 }

{ "type": "room_msg",     → Mensaje a sala
  "room_id": "<room_id>",
  "nonce": "<base64>",
  "payload": "<base64>",
  "ts": 1714900000 }

{ "type": "room_join",    → Unirse a sala
  "room_id": "<room_id>" }

{ "type": "room_leave",   → Salir de sala
  "room_id": "<room_id>" }

{ "type": "call_offer",   → Iniciar llamada directa DM (sala efímera)
  "to": "<user_id>",
  "room_id": "<room_id_efimero>" }

{ "type": "call_end",     → Colgar llamada directa DM
  "to": "<user_id>" }

{ "type": "voice_join",   → Entrar al canal de voz de una sala
  "room_id": "<room_id>",
  "sdp_offer": "<base64>" }

{ "type": "voice_leave",  → Salir del canal de voz
  "room_id": "<room_id>" }

{ "type": "voice_ice",    → ICE candidate para SFU
  "room_id": "<room_id>",
  "candidate": "<base64>" }

{ "type": "voice_mute",   → Silenciar/activar micrófono
  "room_id": "<room_id>",
  "muted": true }

{ "type": "voice_speaking", → VAD: indicar que se está hablando
  "room_id": "<room_id>",
  "speaking": true }

{ "type": "ping" }        → Keepalive

SERVIDOR → CLIENTE:

{ "type": "dm", "from": "<user_id>", ...mismo formato... }
{ "type": "room_msg", "from": "<user_id>", "room_id": "...", ...}
{ "type": "call_offer", "from": "<user_id>", "room_id": "..." }
{ "type": "call_end", "from": "<user_id>" }
{ "type": "delivered", "seq": 1234 }
{ "type": "voice_joined",
  "room_id": "...",
  "sdp_answer": "<base64>",
  "participants": [{ "user_id": "...", "display_name": "...", "muted": false }] }
{ "type": "voice_ice", "room_id": "...", "candidate": "<base64>" }
{ "type": "voice_participant_joined", "room_id": "...", "user_id": "...", "display_name": "..." }
{ "type": "voice_participant_left", "room_id": "...", "user_id": "..." }
{ "type": "voice_participant_muted", "room_id": "...", "user_id": "...", "muted": true }
{ "type": "voice_speaking", "room_id": "...", "user_id": "...", "speaking": true }
{ "type": "pong" }
{ "type": "error", "code": "...", "msg": "..." }
```

### Base de datos SQLite — esquema completo

```sql
-- Solo estas 4 tablas. Nada más.

CREATE TABLE users (
  user_id       TEXT PRIMARY KEY,   -- BLAKE2s(public_key), hex
  display_name  TEXT NOT NULL,
  public_key    BLOB NOT NULL,      -- X25519 public key, 32 bytes
  sign_public   BLOB NOT NULL,      -- Ed25519 public key, 32 bytes
  registered_at INTEGER NOT NULL,
  last_seen     INTEGER
);

CREATE TABLE rooms (
  room_id      TEXT PRIMARY KEY,    -- BLAKE2s(room_key), hex
  room_name    TEXT NOT NULL,       -- nombre legible
  salt         BLOB NOT NULL,       -- 16 bytes, para derivar room_key
  created_by   TEXT NOT NULL,
  created_at   INTEGER NOT NULL,
  max_members  INTEGER DEFAULT 0,
  expires_at   INTEGER              -- NULL = no expira
);

CREATE TABLE offline_messages (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  recipient_id TEXT NOT NULL,       -- user_id del destinatario
  room_id      TEXT,                -- NULL si es DM
  payload      BLOB NOT NULL,       -- cifrado, opaco
  nonce        BLOB NOT NULL,
  sig          BLOB,                -- firma Ed25519 del emisor
  created_at   INTEGER NOT NULL,
  expires_at   INTEGER NOT NULL     -- 72 horas desde created_at
);

CREATE TABLE room_members (
  room_id   TEXT NOT NULL,
  user_id   TEXT NOT NULL,
  joined_at INTEGER NOT NULL,
  PRIMARY KEY (room_id, user_id)
);

-- Índices
CREATE INDEX idx_offline_recipient ON offline_messages(recipient_id);
CREATE INDEX idx_offline_expires ON offline_messages(expires_at);
CREATE INDEX idx_room_members_room ON room_members(room_id);
```

### Configuración del servidor

```toml
# config.toml

[server]
host    = "0.0.0.0"
port    = 8443
tls     = true
cert    = "/etc/securechat/cert.pem"
key     = "/etc/securechat/key.pem"

[database]
path    = "/var/lib/securechat/data.db"

[limits]
max_message_size    = 65536    # bytes, 64 KB
max_rooms_per_user  = 50
offline_ttl_hours   = 72
max_offline_messages = 500

[turn]
enabled  = false               # true si se configura coturn
url      = "turn:mi.servidor.com:3478"
secret   = "secreto_turn"      # para credenciales HMAC-TURN

[jwt]
secret   = "secreto_jwt_256_bits"
ttl_days = 30
```

### Seguridad del servidor

```
Verificaciones que SÍ hace el servidor:
  ✓ JWT válido en cada request/conexión WebSocket
  ✓ Firma Ed25519 en mensajes directos (anti-spam, anti-suplantación)
  ✓ room_id existe antes de autorizar room_join
  ✓ Rate limiting: 100 mensajes/minuto por conexión
  ✓ Tamaño máximo de payload: 64 KB
  ✓ TLS 1.3 obligatorio (no TLS 1.2)

Lo que el servidor NO hace:
  ✗ No descifra ningún payload
  ✗ No almacena IPs de usuarios
  ✗ No correlaciona quién habla con quién en salas
  ✗ No tiene contraseñas de usuarios
```

---

## 11. App Flutter — Diseño Detallado

### Estructura de directorios

```
securechat-app/
├── lib/
│   ├── main.dart
│   ├── app.dart                   ← MaterialApp, router
│   ├── config/
│   │   └── server_config.dart     ← URL servidor, persistencia local
│   ├── crypto/
│   │   ├── identity.dart          ← Generación y almacenamiento de claves
│   │   ├── noise_handshake.dart   ← Protocolo Noise_IK
│   │   ├── message_crypto.dart    ← ChaCha20-Poly1305 encrypt/decrypt
│   │   ├── room_crypto.dart       ← Argon2id + room_key derivation
│   │   └── signatures.dart        ← Ed25519 sign/verify
│   ├── network/
│   │   ├── api_client.dart        ← HTTP REST client
│   │   ├── ws_client.dart         ← WebSocket manager
│   │   └── sfu_client.dart        ← WebRTC + SFU: voz grupal y llamadas DM
│   ├── models/
│   │   ├── user.dart
│   │   ├── room.dart
│   │   ├── message.dart
│   │   └── voice_participant.dart ← Estado de participante en canal de voz
│   ├── store/
│   │   ├── app_state.dart         ← Estado global (Riverpod)
│   │   ├── messages_store.dart    ← Mensajes en memoria
│   │   ├── rooms_store.dart       ← Salas activas
│   │   └── voice_store.dart       ← Estado canal de voz por sala
│   ├── screens/
│   │   ├── setup/
│   │   │   └── server_setup_screen.dart
│   │   ├── home/
│   │   │   └── home_screen.dart
│   │   ├── chat/
│   │   │   └── chat_screen.dart   ← Chat texto + barra de voz integrada
│   │   ├── rooms/
│   │   │   ├── create_room_screen.dart
│   │   │   └── join_room_screen.dart
│   │   ├── voice/
│   │   │   └── voice_channel_screen.dart  ← Vista expandida del canal de voz
│   │   └── profile/
│   │       └── profile_screen.dart
│   └── widgets/
│       ├── message_bubble.dart
│       ├── voice_bar.dart          ← Barra inferior: participantes en voz + entrar/salir
│       ├── voice_participant_tile.dart ← Avatar + indicador VAD por participante
│       └── qr_scanner.dart
├── android/
├── ios/
├── macos/
├── windows/
├── linux/
└── pubspec.yaml
```

### Dependencias Flutter (pubspec.yaml)

```yaml
dependencies:
  flutter:
    sdk: flutter

  # Criptografía
  cryptography: ^2.7.0          # X25519, ChaCha20-Poly1305, BLAKE2s, Ed25519
  cryptography_flutter: ^2.3.0  # Aceleración nativa (iOS/Android)
  argon2_flutter: ^1.0.0        # Argon2id nativo
  flutter_secure_storage: ^9.0.0 # Almacenamiento seguro de claves

  # Red
  web_socket_channel: ^2.4.0   # WebSocket
  http: ^1.2.0                  # REST API
  flutter_webrtc: ^0.9.47       # WebRTC — audio grupal vía SFU

  # QR
  qr_flutter: ^4.1.0            # Generar QR de invitación
  mobile_scanner: ^3.5.0        # Escanear QR

  # Estado y persistencia
  riverpod: ^2.5.0              # State management
  hive_flutter: ^1.1.0          # DB local (mensajes en caché)

  # UI
  go_router: ^13.0.0            # Navegación declarativa
  intl: ^0.19.0                 # Formateo de fechas/horas
```

### Pantallas principales

#### Pantalla de configuración inicial

```
Condición: No hay server_url almacenado.

Campos:
  - URL del servidor (texto + validación ping)
  - Nombre de usuario deseado
  - Botón: "Crear identidad y conectar"

Proceso interno:
  1. Ping /api/v1/health
  2. Generar claves X25519 + Ed25519
  3. POST /api/v1/register
  4. Guardar JWT + server_url + user_id + claves en SecureStorage
  5. Navegar a HomeScreen

Opción secundaria:
  - "Tengo una identidad exportada" → importar desde QR o frase BIP39
```

#### HomeScreen

```
Tab 1: Chats directos
  → Lista de conversaciones recientes
  → Indicador de mensajes no leídos
  → Buscar usuario por nombre → nueva conversación

Tab 2: Salas
  → Lista de salas unidas
  → Botón: Crear sala / Unirse (QR o manual)
  → Indicador de mensajes no leídos por sala

Tab 3: Perfil
  → Mostrar user_id (BLAKE2s, como QR para compartir)
  → Exportar identidad
  → Configuración del servidor
```

#### ChatScreen (DM o sala)

```
- Lista de mensajes (burbuja propio / ajeno)
- Cada mensaje muestra: display_name, hora, ✓ entregado / ✓✓ visto
- Input de texto + botón enviar
- BARRA DE VOZ (parte superior, siempre visible en salas):
    → Muestra avatares de quién está en el canal de voz ahora
    → Indicador visual VAD: el avatar "pulsa" cuando alguien habla
    → Botón "Entrar a voz" / "Salir de voz"
    → Si estás en voz: botón silenciar micrófono
    → Tapping en la barra expande VoiceChannelScreen
- Si es DM: barra de voz simplificada → botón "Llamar" (sala efímera)
- Los mensajes se cifran/descifran automáticamente en background
```

#### VoiceChannelScreen (canal de voz de sala)

```
- Grid de participantes activos en voz
- Cada participante: avatar grande + nombre + indicador VAD animado
- Indicador visual claro de quién está hablando en cada momento
- Botones propios: silenciar micrófono, salir del canal
- Indicador de calidad: latencia y si se usa TURN relay
- Accesible desde la barra de voz del ChatScreen (modal o pantalla completa)
- Mientras se está en voz, indicador persistente en HomeScreen (como Discord)
```

### Gestión del estado de red

```
La app mantiene una conexión WebSocket persistente mientras está activa.

Estados de conexión:
  DISCONNECTED → CONNECTING → CONNECTED → AUTHENTICATED
  
Reconexión automática:
  - Backoff exponencial: 1s, 2s, 4s, 8s, 30s, 30s, 30s...
  - Al reconectar: reenviar mensajes pendientes (cola local en Hive)
  
Background (app en segundo plano):
  - iOS: conexión suspendida → push notification para despertar
  - Android: servicio foreground para mantener WebSocket
```

---

## 12. Flujos Críticos Detallados

### Flujo: Noise_IK Handshake entre A y B

```
Estado previo: A conoce public_key de B (la obtuvo del servidor)

MENSAJE 1 (A → B, via servidor):
  e = ephemeral_keypair()          // nuevo par efímero
  ne = DH(e.private, B.public)    // DH con clave pública de B
  ns = DH(A.static_private, B.public) // DH con claves estáticas
  payload cifrado con ChaCha20(BLAKE2s(ne || ns))
  
  Enviado: { e.public, encrypt(A.public), encrypt(handshake_payload) }

MENSAJE 2 (B → A, via servidor):
  B deriva las mismas claves usando sus claves privadas
  Responde: { e2.public, encrypt(handshake_payload_B) }

RESULTADO:
  Ambos tienen session_key_AB = BLAKE2s(ne || ns || ...)
  Esta clave se usa para ChaCha20-Poly1305 de los mensajes
  El servidor solo vio bytes cifrados opacos
```

### Flujo: Mensaje de sala con doble capa

```
Usuario A envía "Hola" a sala con room_key derivada de contraseña:

CAPA INTERNA (autenticidad):
  inner = {
    text: "Hola",
    sender_id: user_id_A,
    seq: 42,
    ts: 1714900000
  }
  sig = Ed25519_sign(inner, A.sign_private)
  signed_inner = inner + sig

CAPA EXTERNA (confidencialidad de sala):
  nonce = random(12 bytes)
  payload = ChaCha20_Poly1305_encrypt(
    plaintext = signed_inner,
    key       = room_key,
    nonce     = nonce
  )

ENVIADO AL SERVIDOR:
  { type: "room_msg", room_id, nonce, payload, ts }
  → El servidor no puede leer nada

RECIBIDO POR B:
  1. Descifra payload con room_key → obtiene signed_inner
  2. Verifica firma Ed25519 con sign_public de A → autenticidad
  3. Muestra mensaje en UI
```

---

## 13. Seguridad — Análisis de Amenazas

| Amenaza | Mitigación |
|---|---|
| Servidor comprometido | Solo almacena blobs cifrados. Sin clave privada de usuarios, nada es legible |
| MITM en registro | TLS 1.3 + app valida certificado del servidor al configurarlo |
| Replay de mensajes | Nonce único + seq incrementable + timestamp en cada mensaje |
| Fuerza bruta de contraseña de sala | Argon2id con 64MB RAM, ~300ms por intento |
| Suplantación de identidad | Cada mensaje firmado con Ed25519 del emisor |
| Spam / flood | Rate limiting en servidor + firma Ed25519 requerida |
| Pérdida del dispositivo | Clave privada en Secure Enclave / Keystore, no extraíble |
| Recuperación de identidad | Exportación de clave privada cifrada (AES-256 con passphrase) vía BIP39 |
| Enumeración de salas | room_id = BLAKE2s(room_key) — sin contraseña no se puede vincular al nombre |
| Correlación de usuarios en sala | El servidor solo ve room_id + payload cifrado, sin sender_id en claro |
| Escucha de audio por el servidor | SFU reenvía SRTP opaco. Las claves de medios se acuerdan entre clientes por canal Noise. El servidor no puede descifrar el audio |
| Participante no autorizado en voz | Solo quien conoce la contraseña de sala puede derivar room_key y hacer voice_join |
| Denegación de servicio en SFU | Rate limiting de conexiones WebRTC por IP + autenticación JWT requerida antes de voice_join |

---

## 14. Despliegue del Servidor

### Requisitos mínimos

```
CPU:  2 cores (recomendado para SFU con usuarios de voz)
RAM:  512 MB (256 MB mínimo sin voz activa, más por sala de voz activa)
Disk: 1 GB (para SQLite + logs)
OS:   Linux (Ubuntu 22.04+), Windows 10/Server 2019+ (x64), macOS 12+
      NO soportado en móvil (iOS/Android)
Red:  Puerto TCP 8443 (HTTPS/WSS) abierto
      Puerto UDP 3478 (STUN integrado Pion)
      Puerto UDP/TCP 3478 (TURN coturn, opcional)
      Ancho de banda: ~300 kbps por usuario en voz activa
```

### Instalación en Linux

```bash
# Descargar binario compilado
wget https://releases.securechat.example/server-linux-amd64

# O compilar desde fuente
git clone https://github.com/ejemplo/securechat-server
cd securechat-server
go build -o securechat-server ./main.go

# Configurar
cp config.example.toml /etc/securechat/config.toml
# Editar: cert, key, jwt_secret

# Ejecutar
./securechat-server --config /etc/securechat/config.toml

# Como servicio systemd
cp securechat.service /etc/systemd/system/
systemctl enable --now securechat
```

### Certificado TLS

```bash
# Con Let's Encrypt (dominio público)
certbot certonly --standalone -d mi.servidor.com

# Autofirmado (red local / intranet)
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes
# La app deberá confiar en este cert (modo "servidor privado")
```

### Docker (opcional)

```dockerfile
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY . .
RUN go build -o securechat-server ./main.go

FROM alpine:3.19
COPY --from=builder /app/securechat-server /usr/local/bin/
EXPOSE 8443
CMD ["securechat-server", "--config", "/config/config.toml"]
```

---

## 15. Orden de Implementación

### Fase 1 — Base (servidor + identidad)

```
1. Servidor Go: health endpoint + SQLite + registro de usuarios
2. App Flutter: pantalla de configuración + generación de claves X25519/Ed25519
3. App Flutter: registro en servidor + almacenamiento seguro de claves
4. Servidor Go: JWT auth + endpoint de búsqueda de usuarios
```

### Fase 2 — Mensajería de texto

```
5. Servidor Go: WebSocket hub (conexión, autenticación, enrutamiento DM)
6. App Flutter: WebSocket client + Noise_IK handshake
7. App Flutter: ChaCha20-Poly1305 encrypt/decrypt de mensajes DM
8. App Flutter: ChatScreen UI (sin barra de voz aún)
9. Servidor Go: cola offline de mensajes (72h TTL)
```

### Fase 3 — Salas de texto

```
10. Servidor Go: endpoints CRUD de salas
11. App Flutter: Argon2id derivación de room_key
12. App Flutter: CreateRoomScreen + JoinRoomScreen (QR)
13. App Flutter: cifrado de mensajes de sala (doble capa)
14. Servidor Go: WebSocket room_join / room_msg / room_leave
```

### Fase 4 — Voz grupal (core v1, no opcional)

```
15. Servidor Go: módulo SFU con Pion WebRTC (pion/webrtc/v3)
16. Servidor Go: VoiceRoom en memoria + reenvío SRTP por sala
17. Servidor Go: mensajes WebSocket voice_join / voice_leave / voice_ice
18. Servidor Go: STUN integrado con Pion
19. App Flutter: sfu_client.dart — PeerConnection contra el SFU
20. App Flutter: VoiceBar widget en ChatScreen
21. App Flutter: VoiceChannelScreen (grid de participantes + VAD)
22. App Flutter: llamada DM (sala efímera sobre el mismo SFU)
23. Integración coturn como TURN externo para NAT simétrico
```

### Fase 4b — Clientes de escritorio ✅

```
24b. Flutter: habilitar macOS desktop — build y despliegue funcional
25b. Flutter: habilitar Windows x64 desktop — archivos generados (build en Windows)
26b. Flutter: habilitar Linux desktop — archivos generados (build en Linux)
     Permisos de micrófono añadidos en entitlements macOS
     Servidor: binarios para Windows x64, Linux x64 y macOS ARM64
```

### Fase 5 — Pulido y seguridad

```
24. Rate limiting en servidor (mensajes y conexiones WebRTC)
25. Expiración de salas efímeras (cron job en servidor)
26. Exportación/importación de identidad (BIP39)
27. Notificaciones push (FCM / APNs) para mensajes offline
28. Tests de integración end-to-end
29. Indicador persistente en HomeScreen cuando se está en canal de voz
30. Icono de la app carpeta icons, archivo a utilziar en iOS y Android LogoSecureChat.png, debes adaptarlo a cada plataforma.
```

---

## 16. Glosario

| Término | Definición |
|---|---|
| **E2E** | End-to-End Encryption — el servidor nunca puede leer el contenido |
| **Noise_IK** | Patrón del Noise Protocol Framework con identidades conocidas previamente |
| **X25519** | Algoritmo Diffie-Hellman sobre Curve25519 para intercambio de claves |
| **ChaCha20-Poly1305** | AEAD — cifrado simétrico + autenticación en una sola operación |
| **BLAKE2s** | Función hash criptográfica rápida, variante de 256 bits |
| **Ed25519** | Firma digital de alta velocidad sobre Curve25519 |
| **Argon2id** | Función de derivación de claves resistente a GPU/ASIC |
| **SRTP** | Secure Real-time Transport Protocol — cifrado de audio en WebRTC |
| **DTLS** | Datagram TLS — handshake de seguridad en WebRTC |
| **SFU** | Selective Forwarding Unit — servidor que reenvía streams SRTP sin descifrarlos |
| **Pion** | Implementación nativa de WebRTC en Go (`github.com/pion/webrtc`) |
| **VAD** | Voice Activity Detection — detecta cuándo alguien está hablando |
| **ICE** | Interactive Connectivity Establishment — descubrimiento de ruta P2P |
| **STUN** | Session Traversal Utilities for NAT — descubre IP pública |
| **TURN** | Traversal Using Relays around NAT — relay de último recurso |
| **room_key** | Clave simétrica de sala derivada con Argon2id de la contraseña |
| **room_id** | BLAKE2s(room_key) — identificador público opaco de la sala |
| **user_id** | BLAKE2s(public_key) — identificador público opaco del usuario |
| **JWT** | JSON Web Token — token de sesión firmado por el servidor |
| **SDP** | Session Description Protocol — describe capacidades de llamada WebRTC |
| **VoiceRoom** | Sala de voz en memoria en el SFU — desaparece al reiniciar el servidor |
