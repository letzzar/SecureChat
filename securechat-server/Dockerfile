# Multi-stage build for the SecureChat Go server.
# Uses CGO because the SQLite driver (mattn/go-sqlite3) needs it.

FROM golang:1.26-alpine AS build
RUN apk add --no-cache build-base
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=1 go build -ldflags="-s -w" -o /out/securechat-server ./main.go

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata
# Config and the SQLite DB live in /data — mount a volume there.
# Everything can also be supplied via SECURECHAT_* env vars (no config file
# needed). A config.toml at /data/config.toml is used if present.
ENV SECURECHAT_DB_PATH=/data/data.db \
    SECURECHAT_HOST=0.0.0.0 \
    SECURECHAT_PORT=8443
WORKDIR /data
COPY --from=build /out/securechat-server /usr/local/bin/securechat-server
EXPOSE 8443
ENTRYPOINT ["securechat-server"]
CMD ["--config", "/data/config.toml"]
