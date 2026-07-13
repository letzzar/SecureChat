#!/usr/bin/env bash
# Smoke test portable (solo curl): comprueba que los 3 nodos responden y que la
# malla está enlazada. No necesita Go — ideal para ejecutar en el propio DSM.
# Para la validación funcional completa (F1/F2/F4 + privacidad) usa ./tester (Go).
set -uo pipefail

HOST="${HOST:-localhost}"
for p in "${P1:-8451}" "${P2:-8452}" "${P3:-8453}"; do
  s=$(curl -s "http://${HOST}:${p}/api/v1/health" 2>/dev/null)
  if echo "$s" | grep -q '"status":"ok"'; then
    echo "OK   nodo :${p} -> ${s}"
  else
    echo "FALLO nodo :${p} no responde health"; exit 1
  fi
done
echo "Los 3 nodos responden. Ejecuta ./wire-mesh.sh para enlazar la malla si no lo has hecho."
