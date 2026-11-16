#!/usr/bin/env bash
# =============================================================================
#  Post-deploy verification for the LiveSync stack.
#  Run INSIDE the LXC, from the directory holding compose.yaml.
#  Usage:  ./scripts/verify.sh [tailnet-hostname]
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
TS_HOST="${1:-obsidian-sync}"
PASS=0; FAIL=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
head() { printf '\n\033[1m%s\033[0m\n' "$1"; }

[ -f .env ] || { echo "No .env in $(pwd) — aborting."; exit 1; }
set -a; . ./.env; set +a
U="${COUCHDB_USER}"; P="${COUCHDB_PASSWORD}"; DB="${COUCHDB_DATABASE:-obsidiannotes}"

head "1. Containers"
if [ "$(docker inspect -f '{{.State.Health.Status}}' livesync-couchdb 2>/dev/null)" = "healthy" ]; then
  ok "livesync-couchdb is healthy"
else
  bad "livesync-couchdb is not healthy — docker logs livesync-couchdb --tail 50"
fi
EXIT=$(docker inspect -f '{{.State.ExitCode}}' livesync-init 2>/dev/null)
if [ "${EXIT:-1}" = "0" ]; then ok "livesync-init exited 0 (provisioning ran)"
else bad "livesync-init exit code ${EXIT:-unknown} — docker logs livesync-init"; fi

head "2. CouchDB over loopback"
if curl -fsS -u "$U:$P" http://127.0.0.1:5984/_up 2>/dev/null | grep -q '"status":"ok"'; then
  ok "_up returns ok"
else
  bad "_up failed"
fi
if curl -fsS -u "$U:$P" "http://127.0.0.1:5984/$DB" 2>/dev/null | grep -q '"db_name"'; then
  ok "database '$DB' exists"
else
  bad "database '$DB' missing"
fi

head "3. Auth is actually enforced"
CODE=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5984/_all_dbs)
[ "$CODE" = "401" ] && ok "anonymous request -> 401" || bad "anonymous request -> $CODE (expected 401)"

head "4. CORS (this is what breaks mobile/desktop silently)"
HDRS=$(curl -s -D - -o /dev/null -u "$U:$P" -H 'Origin: app://obsidian.md' http://127.0.0.1:5984/)
echo "$HDRS" | grep -qi 'access-control-allow-origin' \
  && ok "desktop origin app://obsidian.md allowed" || bad "no ACAO header for app://obsidian.md"
HDRS=$(curl -s -D - -o /dev/null -u "$U:$P" -H 'Origin: capacitor://localhost' http://127.0.0.1:5984/)
echo "$HDRS" | grep -qi 'access-control-allow-origin' \
  && ok "mobile origin capacitor://localhost allowed" || bad "no ACAO header for capacitor://localhost"

head "5. Port is NOT reachable off-loopback"
if ss -ltnp 2>/dev/null | grep -q "0.0.0.0:${COUCHDB_PORT:-5984}"; then
  bad "5984 is listening on all interfaces — check COUCHDB_BIND"
else
  ok "5984 is bound to loopback only"
fi

head "6. Tailscale"
if command -v tailscale >/dev/null 2>&1 && tailscale status --json 2>/dev/null | grep -q '"BackendState":"Running"'; then
  ok "tailscaled running ($(tailscale ip -4 2>/dev/null | head -1))"
  FQDN=$(tailscale status --json | grep -o '"DNSName":"[^"]*"' | head -1 | cut -d'"' -f4)
  echo "        DNS name: ${FQDN:-unknown}"
  tailscale serve status 2>/dev/null | grep -q 5984 \
    && ok "serve is proxying to 5984" || bad "no serve rule for 5984 — see 'tailscale serve status'"
  if curl -fsS -u "$U:$P" "https://${FQDN:-$TS_HOST}/_up" 2>/dev/null | grep -q '"status":"ok"'; then
    ok "HTTPS via Tailscale Serve works: https://${FQDN:-$TS_HOST}"
  else
    bad "HTTPS check failed — cert not issued yet, or HTTPS not enabled in admin console"
  fi
else
  bad "tailscale not running"
fi

head "7. Docker storage driver"
DRV=$(docker info --format '{{.Driver}}' 2>/dev/null)
[ "$DRV" = "overlay2" ] && ok "overlay2" || echo "  WARN  driver is '$DRV' (vfs is slow — see README troubleshooting)"

printf '\n\033[1m%d passed, %d failed\033[0m\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
