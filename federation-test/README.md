# Federación de prueba (3 nodos) — SecureChat

Malla de 3 servidores SecureChat para probar la federación de extremo a extremo.
Topología:

```
  Bob   ──▶  Nodo 1  (http://<HOST>:8451)  ┐
             Nodo 2  (http://<HOST>:8452)  ├─ malla completa (S2S interno)
  Alice ──▶  Nodo 3  (http://<HOST>:8453)  ┘
```

Los 3 contenedores se ven entre sí por su nombre DNS interno de Docker
(`securechat-1/2/3`) en la red de Compose. Ese nombre es el `federation.public_url`
de cada nodo y con el que se enlazan como peers. Los clientes (o el tester) se
conectan **desde fuera** por los puertos publicados `8451/8452/8453`.

Usa la imagen publicada `ghcr.io/letzzar/securechat-server:v0.7.1` (no compila
nada en el NAS). Modo `mesh_public`: federación activa + registro abierto (sin
invitación), pensado para pruebas. **No usar tal cual en producción** (sin TLS,
secretos de ejemplo en los `configs/*.toml`).

## Arranque local (con Docker)

```bash
docker compose up -d
./smoke.sh          # los 3 responden health
./wire-mesh.sh      # enlaza la malla (6 peers, idempotente)
```

Validación funcional completa (necesita Go):

```bash
cd tester && go run .
```

Comprueba, contra los servidores reales:
- **F1** — descubrimiento de usuarios cross-server (Bob@1 encuentra a Alice@3).
- **F2** — descubrimiento de salas públicas remotas + relay de mensajes.
- **F4** — sala **privada** alojada en el Nodo 1 y usada por Alice desde el
  Nodo 3, verificando la **privacidad de metadatos**: el `from` externo llega
  vacío al otro extremo (el anfitrión solo ve `room_id` + payload opaco).

Parar y limpiar (borra también los volúmenes de datos):

```bash
docker compose down -v
```

## En Synology DSM (Container Manager)

1. Copia esta carpeta `federation-test/` a una ruta del NAS, p. ej.
   `/volume1/docker/securechat-fed/`.
2. **Container Manager → Proyecto → Crear** → ruta = esa carpeta → usa el
   `docker-compose.yml` existente. (O `Registro → Descargar` la imagen y crear
   el proyecto.) Arranca el proyecto.
3. Enlaza la malla: abre una terminal (SSH al NAS) en la carpeta y ejecuta
   `bash wire-mesh.sh`. Si no tienes SSH, registra los 6 peers a mano con estos
   `curl` (uno por enlace) desde cualquier máquina que alcance el NAS —
   sustituye `NAS` por la IP del Synology:

   ```bash
   # Nodo 1 aprende a 2 y 3
   curl -X POST http://NAS:8451/api/v1/admin/federation/peers \
     -H "X-Admin-Token: d1bbadd26323394f50fbfd74a3cc4406" -H "Content-Type: application/json" \
     -d '{"url":"http://securechat-2:8443","name":"Nodo 2","secret":"2f8441b48c69b566e2e28f9db0511ace"}'
   # …repite para las 6 combinaciones (ver wire-mesh.sh).
   ```

4. Conecta los clientes:
   - **Bob** → servidor `http://NAS:8451` (HTTPS off, puerto 8451).
   - **Alice** → servidor `http://NAS:8453`.
   Regístralos (registro abierto) y prueba: buscar el uno al otro (F1), salas
   públicas remotas (F2) y crear/unirse a una sala privada donde el invitado
   está en el otro servidor (F4).

> **Puertos:** el `docker-compose.yml` publica `8451/8452/8453`. Cámbialos ahí si
> chocan con otros servicios del NAS. **TLS:** para uso real, pon `tls = true` en
> los `configs/*.toml`, monta `fullchain.pem` + clave bajo `/data` y usa `https`.
> **Cifrado en reposo:** añade `SECURECHAT_DB_KEY` en `environment:` de cada nodo
> para cifrar su BD (SQLCipher); guárdala fuera del NAS (perderla = BD ilegible).

## Ficheros

| Fichero | Qué es |
|---|---|
| `docker-compose.yml` | los 3 nodos (imagen v0.7.1, puertos, volúmenes) |
| `configs/serverN.toml` | config de cada nodo (mesh_public, secretos, `public_url`) |
| `wire-mesh.sh` | registra los 6 enlaces de peer (malla completa) |
| `smoke.sh` | comprobación rápida solo-curl (health de los 3) |
| `tester/` | tester Go: valida F1 + F2 + F4 con privacidad |
