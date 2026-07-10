# Multi-stage build for the SecureChat Go server.
# Uses CGO for the SQLCipher driver (go-sqlcipher). A glibc base (Debian) is used
# because the vendored SQLite in go-sqlcipher does not compile against musl/Alpine
# (off64_t / pread64).

FROM golang:1.26-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=1 go build -ldflags="-s -w" -o /out/securechat-server ./main.go

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*
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
