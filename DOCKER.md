# SecureChat server — Docker

Guía para levantar el servidor SecureChat como contenedor. / How to run the
SecureChat server as a container.

La imagen se publica automáticamente desde GitHub Actions:
- **GHCR** (siempre): `ghcr.io/letzzar/securechat-server:latest`
- **Docker Hub** (si están los secrets): `letzzar/securechat-server:latest`

---

## Arranque rápido (imagen publicada) / Quick start

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

## Con docker compose

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

### Ejemplo de YAML (compose)

`docker-compose.yml` — usando la imagen ya publicada. Si prefieres compilar
desde el código, cambia el bloque `image:` por `build: ./securechat-server`.

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

Arranque: `docker compose -f docker-compose.pull.yml up -d` (o `docker compose up -d --build`).

---

## Configuración por variables de entorno

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

### TLS

Lo más sencillo es dejar `SECURECHAT_TLS=false` y poner un **proxy inverso**
(nginx / Traefik / Caddy) delante que termine HTTPS. Para TLS nativo, monta el
certificado y la clave en `/data` y define `SECURECHAT_TLS=true` con las rutas.

---

## Publicar la imagen

- **GHCR**: automático en cada push a `main` que toque `securechat-server/**`, y
  en cada tag `v*`. No requiere secrets.
- **Docker Hub**: añade en el repo → Settings → Secrets and variables → Actions:
  - `DOCKERHUB_USERNAME` = `letzzar`
  - `DOCKERHUB_TOKEN` = un Access Token (Docker Hub → Account → Security)

  A partir del siguiente push (o con "Run workflow" manual) se publica también en
  `letzzar/securechat-server`.

## Persistencia y backup

Todo el estado vive en el volumen `/data` (`data.db` + WAL). Para backup, copia
esa carpeta con el contenedor parado (o usa `sqlite3 .backup`).
