#!/usr/bin/env bash
# Enlaza los 3 nodos en malla completa registrando cada peer en los otros dos,
# vía el endpoint admin (X-Admin-Token). Idempotente: reejecutar no rompe nada.
#
# Los peers se registran con su URL INTERNA de Docker (http://securechat-N:8443),
# que es como se alcanzan entre contenedores y lo que viaja en server_url/home.
# El script habla con el endpoint admin por los puertos publicados en el host.
set -euo pipefail

HOST="${HOST:-localhost}"
P1="${P1:-8451}"; P2="${P2:-8452}"; P3="${P3:-8453}"
ADMIN_TOKEN="${ADMIN_TOKEN:-d1bbadd26323394f50fbfd74a3cc4406}"
FED_SECRET="${FED_SECRET:-2f8441b48c69b566e2e28f9db0511ace}"

U1="http://securechat-1:8443"
U2="http://securechat-2:8443"
U3="http://securechat-3:8443"

add_peer() {   # add_peer <admin_port> <peer_url> <peer_name>
  local port="$1" url="$2" name="$3"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "http://${HOST}:${port}/api/v1/admin/federation/peers" \
    -H "X-Admin-Token: ${ADMIN_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "{\"url\":\"${url}\",\"name\":\"${name}\",\"secret\":\"${FED_SECRET}\"}")
  echo "  :${port} += ${name} (${url}) -> HTTP ${code}"
}

echo "Enlazando malla de 3 nodos..."
echo "Nodo 1 (:${P1}):"; add_peer "$P1" "$U2" "Nodo 2"; add_peer "$P1" "$U3" "Nodo 3"
echo "Nodo 2 (:${P2}):"; add_peer "$P2" "$U1" "Nodo 1"; add_peer "$P2" "$U3" "Nodo 3"
echo "Nodo 3 (:${P3}):"; add_peer "$P3" "$U1" "Nodo 1"; add_peer "$P3" "$U2" "Nodo 2"
echo "Malla enlazada."
