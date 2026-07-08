# SecureChat Server — Docker

**English** | [Español](#español)

Run the SecureChat server as a container. The image is published automatically
by GitHub Actions:

- **GHCR** (always): `ghcr.io/letzzar/securechat-server:latest`
- **Docker Hub** (when the secrets are set): `letzzar/securechat-server:latest`

The image is **multi-arch** (`linux/amd64` + `linux/arm64`) — `docker pull`
picks the right architecture automatically.

---

## Quick start (published image)

```bash
docker run -d --name securechat-server \
  -e SECURECHAT_JWT_SECRET="$(openssl rand -hex 32)" \
  -p 8443:8443 \
  -v "$PWD/data:/data" \
  ghcr.io/letzzar/securechat-server:latest
```

The server **won't start** without a real `SECURECHAT_JWT_SECRET`. The database
lives at `./data/data.db` on the host.

On first start it prints a **bootstrap invite code** in the log (the first user
needs it to register in `private` mode):

```bash
docker logs securechat-server
```

## With docker compose

**Option A — published image** (no build):

```bash
cp .env.example .env       # set a real SECURECHAT_JWT_SECRET
docker compose -f docker-compose.pull.yml up -d
```

**Option B — build from source**:

```bash
cp .env.example .env
docker compose up -d --build
```

### Example YAML (compose)

Using the published image. To build from source instead, replace the `image:`
line with `build: ./securechat-server`.

```yaml
services:
  securechat-server:
    image: ghcr.io/letzzar/securechat-server:latest   # or letzzar/securechat-server:latest (Docker Hub)
    container_name: securechat-server
    restart: unless-stopped
    pull_policy: always
    env_file:
      - .env
    environment:
      TZ: ${TZ:-Europe/Madrid}
    ports:
      - "${SECURECHAT_PORT:-8443}:8443"
    volumes:
      - ${DATA_DIR:-./data}:/data   # data.db + optional config.toml
```

And the `.env` it reads (bare minimum):

```dotenv
# generate one with:  openssl rand -hex 32
SECURECHAT_JWT_SECRET=paste_your_64_hex_secret_here
SECURECHAT_MODE=private
SECURECHAT_PORT=8443
DATA_DIR=./data
TZ=Europe/Madrid
```

## Configuration via environment variables

Everything can be configured without a file (ideal for Docker). If you mount a
`/data/config.toml`, it is used as a base and the variables override it.

| Variable | Default | Description |
|---|---|---|
| `SECURECHAT_JWT_SECRET` | — | **Required.** Secret used to sign JWTs (`openssl rand -hex 32`). |
| `SECURECHAT_MODE` | `private` | `private` \| `public` \| `mesh_private` \| `mesh_public`. |
| `SECURECHAT_PORT` | `8443` | Listen port. |
| `SECURECHAT_HOST` | `0.0.0.0` | Listen interface. |
| `SECURECHAT_DB_PATH` | `/data/data.db` | SQLite database path. |
| `SECURECHAT_TLS` | `false` | `true` for native TLS 1.3 (needs cert/key). |
| `SECURECHAT_TLS_CERT` / `SECURECHAT_TLS_KEY` | — | Certificate and key paths (mount them under `/data`). |

### TLS

Simplest is to keep `SECURECHAT_TLS=false` and put a **reverse proxy** (nginx /
Traefik / Caddy) in front to terminate HTTPS. For native TLS, mount the
certificate and key under `/data` and set `SECURECHAT_TLS=true` with the paths.

## Publishing the image

- **GHCR**: automatic on every push to `main` touching `securechat-server/**`,
  and on every `v*` tag. No secrets required.
- **Docker Hub**: add these repo secrets (Settings → Secrets and variables →
  Actions):
  - `DOCKERHUB_USERNAME` = `letzzar`
  - `DOCKERHUB_TOKEN` = an Access Token (Docker Hub → Account → Security)

  From the next push (or a manual "Run workflow") it is also published to
  `letzzar/securechat-server`.

> **Note:** if the repo is private, the GHCR package is created **private**. To
> `docker pull` without logging in, make the package public: GitHub → your
> profile → **Packages** → `securechat-server` → **Package settings** → **Change
> visibility** → **Public**. Otherwise run `docker login ghcr.io` on the host.

## Persistence and backup

All state lives in the `/data` volume (`data.db` + WAL). To back up, copy that
folder with the container stopped (or use `sqlite3 .backup`).

---

## Español

Levanta el servidor SecureChat como contenedor. La imagen se publica
automáticamente desde GitHub Actions:

- **GHCR** (siempre): `ghcr.io/letzzar/securechat-server:latest`
- **Docker Hub** (si están los secrets): `letzzar/securechat-server:latest`

La imagen es **multi-arquitectura** (`linux/amd64` + `linux/arm64`) — `docker
pull` elige la arquitectura correcta automáticamente.

### Arranque rápido (imagen publicada)

```bash
docker run -d --name securechat-server \
  -e SECURECHAT_JWT_SECRET="$(openssl rand -hex 32)" \
  -p 8443:8443 \
  -v "$PWD/data:/data" \
  ghcr.io/letzzar/securechat-server:latest
```

El servidor **no arranca** sin un `SECURECHAT_JWT_SECRET` real. La base de datos
queda en `./data/data.db` del host.

En el primer arranque imprime en el log un **código de invitación bootstrap**
(el primer usuario lo necesita para registrarse en modo `private`):

```bash
docker logs securechat-server
```

### Con docker compose

**Opción A — imagen publicada** (no compila nada):

```bash
cp .env.example .env       # pon un SECURECHAT_JWT_SECRET real
docker compose -f docker-compose.pull.yml up -d
```

**Opción B — compilar desde el código**:

```bash
cp .env.example .env
docker compose up -d --build
```

#### Ejemplo de YAML (compose)

Usando la imagen ya publicada. Para compilar desde el código, cambia la línea
`image:` por `build: ./securechat-server`.

```yaml
services:
  securechat-server:
    image: ghcr.io/letzzar/securechat-server:latest   # o letzzar/securechat-server:latest (Docker Hub)
    container_name: securechat-server
    restart: unless-stopped
    pull_policy: always
    env_file:
      - .env
    environment:
      TZ: ${TZ:-Europe/Madrid}
    ports:
      - "${SECURECHAT_PORT:-8443}:8443"
    volumes:
      - ${DATA_DIR:-./data}:/data   # data.db + config.toml opcional
```

Y el `.env` que lee (mínimo imprescindible):

```dotenv
# genera uno con:  openssl rand -hex 32
SECURECHAT_JWT_SECRET=pega_aqui_tu_secreto_de_64_hex
SECURECHAT_MODE=private
SECURECHAT_PORT=8443
DATA_DIR=./data
TZ=Europe/Madrid
```

### Configuración por variables de entorno

Todo se puede configurar sin fichero (idóneo para Docker). Si montas un
`/data/config.toml`, se usa como base y las variables lo sobrescriben.

| Variable | Por defecto | Descripción |
|---|---|---|
| `SECURECHAT_JWT_SECRET` | — | **Obligatoria.** Secreto para firmar los JWT (`openssl rand -hex 32`). |
| `SECURECHAT_MODE` | `private` | `private` \| `public` \| `mesh_private` \| `mesh_public`. |
| `SECURECHAT_PORT` | `8443` | Puerto de escucha. |
| `SECURECHAT_HOST` | `0.0.0.0` | Interfaz de escucha. |
| `SECURECHAT_DB_PATH` | `/data/data.db` | Ruta de la base SQLite. |
| `SECURECHAT_TLS` | `false` | `true` para TLS 1.3 nativo (requiere cert/key). |
| `SECURECHAT_TLS_CERT` / `SECURECHAT_TLS_KEY` | — | Rutas del certificado y la clave (móntalos en `/data`). |

#### TLS

Lo más sencillo es dejar `SECURECHAT_TLS=false` y poner un **proxy inverso**
(nginx / Traefik / Caddy) delante que termine HTTPS. Para TLS nativo, monta el
certificado y la clave en `/data` y define `SECURECHAT_TLS=true` con las rutas.

### Publicar la imagen

- **GHCR**: automático en cada push a `main` que toque `securechat-server/**`, y
  en cada tag `v*`. No requiere secrets.
- **Docker Hub**: añade en el repo (Settings → Secrets and variables → Actions):
  - `DOCKERHUB_USERNAME` = `letzzar`
  - `DOCKERHUB_TOKEN` = un Access Token (Docker Hub → Account → Security)

  A partir del siguiente push (o con "Run workflow" manual) se publica también en
  `letzzar/securechat-server`.

> **Nota:** si el repo es privado, el paquete GHCR nace **privado**. Para
> `docker pull` sin login, haz público el paquete: GitHub → tu perfil →
> **Packages** → `securechat-server` → **Package settings** → **Change
> visibility** → **Public**. Si no, usa `docker login ghcr.io` en el servidor.

### Persistencia y backup

Todo el estado vive en el volumen `/data` (`data.db` + WAL). Para backup, copia
esa carpeta con el contenedor parado (o usa `sqlite3 .backup`).
