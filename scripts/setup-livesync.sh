#!/usr/bin/env bash
# =============================================================================
#  Self-hosted LiveSync — SELF-CONTAINED installer for Proxmox CT 226
#
#  Everything is embedded in this one file: compose.yaml, the CouchDB config,
#  and the init script. There is nothing to copy alongside it and no SSH needed.
#
#  HOW TO RUN (from the Proxmox host):
#      pct push 226 setup-livesync.sh /root/setup-livesync.sh
#      pct exec 226 -- bash /root/setup-livesync.sh
#
#  Or paste this whole file into CT 226's web-UI shell and press Enter.
#
#  Options:
#      --files-only   only write the configuration files, then exit
#      --yes          do not ask questions (assumes "yes" to the vfs warning)
#
#  Idempotent: re-running will not regenerate an existing CouchDB password.
# =============================================================================
set -euo pipefail

STACK_DIR="${STACK_DIR:-/opt/obsidian-livesync}"
CRED_FILE="${CRED_FILE:-/root/livesync-credentials.txt}"
FILES_ONLY=0
ASSUME_YES=0
DO_TS=0
for a in "$@"; do
  case "$a" in
    --files-only) FILES_ONLY=1 ;;
    --yes)        ASSUME_YES=1 ;;
    --tailscale)  DO_TS=1 ;;
  esac
done

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m  WARN  %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32mok\033[0m  %s\n' "$1"; }
die()  { printf '\033[1;31m  FAIL  %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- write files
say "Writing configuration files to $STACK_DIR"
mkdir -p "$STACK_DIR/config" "$STACK_DIR/scripts"
cd "$STACK_DIR"

cat > compose.yaml <<'LIVESYNC_COMPOSE_EOF'
# =============================================================================
#  Self-hosted LiveSync — CouchDB for Obsidian
#  Adapted from: github.com/vrtmrz/obsidian-livesync @ 0e458e5e2062 (docker/)
#
#  Deliberate changes vs. upstream:
#   1. CouchDB pinned to 3.5.3 instead of :latest  (reproducible restarts)
#   2. Host port bound to 127.0.0.1 only           (only Tailscale can reach it)
#   3. json-file log limits                         (log volume cannot fill disk)
#
#  Access model:  phone/desktop -> HTTPS (Tailscale Serve) -> 127.0.0.1:5984
# =============================================================================

name: obsidian-livesync

services:

  # ---------------------------------------------------------------------------
  # CouchDB — the only long-running service
  # ---------------------------------------------------------------------------
  couchdb:
    image: couchdb:3.5.3
    container_name: livesync-couchdb
    restart: unless-stopped
    # NOT setting `user:` on purpose. The CouchDB entrypoint starts as root to
    # generate docker.ini from the env vars, then drops to uid 5984 itself.
    environment:
      COUCHDB_USER: ${COUCHDB_USER:?Set COUCHDB_USER in .env}
      COUCHDB_PASSWORD: ${COUCHDB_PASSWORD:?Set COUCHDB_PASSWORD in .env}
    volumes:
      - couchdb-data:/opt/couchdb/data
      # Mount to local.ini (NOT into local.d/) and NOT :ro — the entrypoint
      # runs chmod on this file at startup and aborts on EPERM.
      - ./config/livesync.ini:/opt/couchdb/etc/local.ini
    ports:
      # Loopback-only. Tailscale Serve runs on this LXC and proxies to it.
      # Nothing on your LAN, and nothing on the tailnet, can hit 5984 directly.
      - "${COUCHDB_BIND:-127.0.0.1}:${COUCHDB_PORT:-5984}:5984"
    healthcheck:
      # Uses admin credentials: proves CouchDB is up AND auth is initialised.
      test:
        - "CMD-SHELL"
        - >-
          curl -fSs --max-time 4 --user "$${COUCHDB_USER}:$${COUCHDB_PASSWORD}"
          http://127.0.0.1:5984/_session | grep -q "_admin"
      interval: 5s
      timeout: 5s
      retries: 24
      start_period: 20s
    stop_grace_period: 30s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks:
      - livesync-net

  # ---------------------------------------------------------------------------
  # One-shot init: single-node setup, auth required, CORS, limits, DB creation.
  # Idempotent — safe to re-run with `docker compose up -d --force-recreate`.
  # ---------------------------------------------------------------------------
  couchdb-init:
    image: curlimages/curl:latest
    container_name: livesync-init
    restart: on-failure
    depends_on:
      couchdb:
        condition: service_healthy
    environment:
      COUCHDB_INTERNAL_URL: http://couchdb:5984
      COUCHDB_USER: ${COUCHDB_USER}
      COUCHDB_PASSWORD: ${COUCHDB_PASSWORD}
      COUCHDB_DATABASE: ${COUCHDB_DATABASE:-obsidiannotes}
    volumes:
      - ./scripts/couchdb-init.sh:/couchdb-init.sh:ro
    entrypoint: ["sh", "/couchdb-init.sh"]
    networks:
      - livesync-net

volumes:
  couchdb-data:
    driver: local

networks:
  livesync-net:
    driver: bridge
LIVESYNC_COMPOSE_EOF

cat > config/livesync.ini <<'LIVESYNC_INI_EOF'
; CouchDB configuration for Self-hosted LiveSync
; Mounted at /opt/couchdb/etc/local.ini
;
; The couchdb-init container applies require_valid_user, enable_cors and the
; CORS origin list through the REST API on first boot. This file handles the
; static limits that must be in place before the first request is served.
;
; Vendored from vrtmrz/obsidian-livesync @ 0e458e5e2062 (docker/config/livesync.ini)

[couchdb]
; 50 MB per document — headroom for binary attachments.
max_document_size = 50000000

[chttpd]
; Must stay 0.0.0.0: Docker's port publishing targets the container's eth0,
; not its loopback interface.
bind_address = 0.0.0.0
port = 5984
; 4 GB request ceiling — large initial vault uploads.
max_http_request_size = 4294967296

[httpd]
WWW-Authenticate = Basic realm="couchdb"

[cors]
; The exact origins the Obsidian clients use.
;   app://obsidian.md      -> desktop (Electron)
;   capacitor://localhost  -> Android + iOS
;   http://localhost       -> local testing
; Tailscale does not require this list to include the ts.net hostname:
; CORS is evaluated against the *client* origin, not the server URL.
credentials = true
origins = app://obsidian.md,capacitor://localhost,http://localhost

[log]
; Keep Docker logs readable. Set to "debug" only while troubleshooting.
level = warning
LIVESYNC_INI_EOF

cat > scripts/couchdb-init.sh <<'LIVESYNC_INIT_EOF'
#!/bin/sh
# Self-hosted LiveSync — CouchDB Initialization Script
# Runs once on first startup via the couchdb-init service.
# Configures single-node cluster, auth, CORS, and size limits.

set -e

hostname="${COUCHDB_INTERNAL_URL:-http://couchdb:5984}"
username="${COUCHDB_USER:?COUCHDB_USER is required}"
password="${COUCHDB_PASSWORD:?COUCHDB_PASSWORD is required}"
node="${COUCHDB_NODE:-_local}"

echo "==> Waiting for CouchDB at ${hostname} ..."
# _up is publicly accessible (no auth required) — safe pre-auth wait
until curl -sf "${hostname}/_up" 2>/dev/null | grep -q '"status":"ok"'; do
    printf '.'
    sleep 2
done
echo ""
echo "==> CouchDB is up. Initializing..."

# 1. Enable single-node cluster
curl -sf -X POST "${hostname}/_cluster_setup" \
    -H "Content-Type: application/json" \
    -d "{\"action\":\"enable_single_node\",\"username\":\"${username}\",\"password\":\"${password}\",\"bind_address\":\"0.0.0.0\",\"port\":5984,\"singlenode\":true}" \
    --user "${username}:${password}" && echo "[OK] cluster_setup"

# 2. Require valid user on both http interfaces
curl -sf -X PUT "${hostname}/_node/${node}/_config/chttpd/require_valid_user" \
    -H "Content-Type: application/json" -d '"true"' --user "${username}:${password}" && echo "[OK] chttpd/require_valid_user"

curl -sf -X PUT "${hostname}/_node/${node}/_config/chttpd_auth/require_valid_user" \
    -H "Content-Type: application/json" -d '"true"' --user "${username}:${password}" && echo "[OK] chttpd_auth/require_valid_user"

# 3. HTTP auth challenge header
curl -sf -X PUT "${hostname}/_node/${node}/_config/httpd/WWW-Authenticate" \
    -H "Content-Type: application/json" -d '"Basic realm=\"couchdb\""' --user "${username}:${password}" && echo "[OK] httpd/WWW-Authenticate"

# 4. Enable CORS on both http listeners
curl -sf -X PUT "${hostname}/_node/${node}/_config/httpd/enable_cors" \
    -H "Content-Type: application/json" -d '"true"' --user "${username}:${password}" && echo "[OK] httpd/enable_cors"

curl -sf -X PUT "${hostname}/_node/${node}/_config/chttpd/enable_cors" \
    -H "Content-Type: application/json" -d '"true"' --user "${username}:${password}" && echo "[OK] chttpd/enable_cors"

# 5. Increase size limits for large vaults
curl -sf -X PUT "${hostname}/_node/${node}/_config/chttpd/max_http_request_size" \
    -H "Content-Type: application/json" -d '"4294967296"' --user "${username}:${password}" && echo "[OK] chttpd/max_http_request_size"

curl -sf -X PUT "${hostname}/_node/${node}/_config/couchdb/max_document_size" \
    -H "Content-Type: application/json" -d '"50000000"' --user "${username}:${password}" && echo "[OK] couchdb/max_document_size"

# 6. CORS configuration — allow Obsidian app origins
curl -sf -X PUT "${hostname}/_node/${node}/_config/cors/credentials" \
    -H "Content-Type: application/json" -d '"true"' --user "${username}:${password}" && echo "[OK] cors/credentials"

curl -sf -X PUT "${hostname}/_node/${node}/_config/cors/origins" \
    -H "Content-Type: application/json" \
    -d '"app://obsidian.md,capacitor://localhost,http://localhost"' \
    --user "${username}:${password}" && echo "[OK] cors/origins"

# 7. Create the vault database if it doesn't exist
db="${COUCHDB_DATABASE:-obsidiannotes}"
set +e
status=$(curl -sf -o /dev/null -w "%{http_code}" --user "${username}:${password}" "${hostname}/${db}" 2>/dev/null)
curl_exit=$?
set -e

if [ "$status" = "200" ]; then
    echo "[OK] database '${db}' already exists"
else
    curl -sf -X PUT "${hostname}/${db}" --user "${username}:${password}" && echo "[OK] database '${db}' created" || echo "[WARN] database creation returned non-200 — may already exist"
fi

echo ""
echo "==> CouchDB initialization complete!"
echo "    URL      : ${hostname}"
echo "    Database : ${db}"
echo "    Username : ${username}"
LIVESYNC_INIT_EOF
chmod +x scripts/couchdb-init.sh

cat > .env.example <<'LIVESYNC_ENV_EOF'
# =============================================================================
#  Self-hosted LiveSync — environment
#  cp .env.example .env  &&  chmod 600 .env
# =============================================================================

# --- CouchDB administrator -----------------------------------------------
# Generate the password with:  openssl rand -base64 24
COUCHDB_USER=livesync
COUCHDB_PASSWORD=CHANGE_ME_use_openssl_rand_base64_24

# Database the plugin will use. One vault = one database.
# Multiple vaults later: give each its own name (vault-work, vault-home, ...).
COUCHDB_DATABASE=obsidiannotes

# --- Network binding ------------------------------------------------------
# Bind to loopback only. Tailscale Serve on this LXC proxies to it.
# Do NOT change to 0.0.0.0: that would expose CouchDB on your LAN unencrypted.
COUCHDB_BIND=127.0.0.1
COUCHDB_PORT=5984

# --- Tailscale (host install, not a container) ----------------------------
# Kept here as a note only; the Tailscale binary reads neither of these.
# TS_HOSTNAME=obsidian-sync      -> becomes obsidian-sync.<tailnet>.ts.net
# TS_AUTHKEY=tskey-auth-...      -> used once, in `tailscale up`
LIVESYNC_ENV_EOF

ok "compose.yaml, config/livesync.ini, scripts/couchdb-init.sh, .env.example"

if [ "$FILES_ONLY" = "1" ]; then
  say "Files written (--files-only). Stopping here."
  exit 0
fi

# ------------------------------------------------------------------- preflight
[ "$(id -u)" -eq 0 ] || die "run as root inside CT 226"

say "Checking the TUN device (Tailscale needs it in Phase 4)"
[ -e /dev/net/tun ] || die "/dev/net/tun missing — apply proxmox/lxc-extra.conf on the host, then restart CT 226"
ok "/dev/net/tun present"

say "Installing Docker"
if command -v docker >/dev/null 2>&1; then
  ok "already installed: $(docker --version)"
else
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates gnupg >/dev/null
  curl -fsSL https://get.docker.com | sh >/dev/null
  ok "installed: $(docker --version)"
fi
systemctl enable --now docker >/dev/null 2>&1 || true
docker compose version >/dev/null 2>&1 || die "docker compose v2 missing"

say "Checking the Docker storage driver"
DRIVER=$(docker info --format '{{.Driver}}')

# Valid drivers, across Docker versions:
#   overlayfs      - Docker 29+ containerd image store (default on fresh install)
#   overlay2       - Docker <=28 classic graphdriver. Same thing underneath.
#   fuse-overlayfs - ONLY valid when /dev/fuse exists. A stock Proxmox LXC has
#                    no /dev/fuse, so docker info reports it happily but every
#                    container start then fails with "fuse: device not found".
#   vfs            - slow fallback, copies whole dirs per layer.
enable_containerd_store() {
  local why="$1"
  warn "$why"
  warn "Fix: enable the containerd image store (gives the 'overlayfs' driver)."
  warn "NOTE: this resets /var/lib/docker, so it deletes all Docker images."
  IMGCOUNT=$(docker image ls -q 2>/dev/null | wc -l)
  if [ "$IMGCOUNT" != "0" ]; then
    die "there are already ${IMGCOUNT} image(s); refusing to wipe them. Ask for help first."
  fi
  if [ "$ASSUME_YES" = "1" ]; then
    warn "no images present - proceeding automatically (--yes)"
  else
    printf '  No images present, so this is safe. Enable the containerd store now? [Y/n] '
    read -r ans </dev/tty || ans=y
    case "$ans" in [nN]*) die "aborted - see README section 'What is the vfs thing?'" ;; esac
  fi
  systemctl stop docker
  rm -f /etc/docker/daemon.json /etc/docker/daemon.json.bak.*
  mkdir -p /etc/docker
  printf '{\n  "features": {\n    "containerd-snapshotter": true\n  }\n}\n' \
    > /etc/docker/daemon.json
  rm -rf /var/lib/docker/*
  systemctl start docker
  DRIVER=$(docker info --format '{{.Driver}}')
  case "$DRIVER" in
    overlayfs|overlay2) ok "now using $DRIVER" ;;
    *) die "still '$DRIVER' - see README Troubleshooting" ;;
  esac
}

case "$DRIVER" in
  overlayfs|overlay2)
    ok "$DRIVER - native overlay, the fast one. Nothing to do."
    ;;
  fuse-overlayfs)
    if [ -e /dev/fuse ]; then
      ok "fuse-overlayfs - /dev/fuse present, fine. Nothing to do."
    else
      # This is the trap: docker info looks healthy, container start fails.
      enable_containerd_store "driver is 'fuse-overlayfs' but this container has no /dev/fuse."
    fi
    ;;
  vfs)
    enable_containerd_store "driver is 'vfs', the slow fallback."
    ;;
  *)
    warn "unrecognised storage driver '$DRIVER'. Continuing anyway."
    ;;
esac

# Smoke test: proves containers can actually START, which the driver name alone
# does not. This is what would have caught the fuse-overlayfs trap immediately.
say "Smoke test: can a container actually start?"
if docker run --rm alpine:3.22 true >/dev/null 2>&1; then
  ok "container started and exited cleanly"
else
  docker run --rm alpine:3.22 true 2>&1 | tail -5
  die "a container cannot start - see the error above (storage driver / mount problem)"
fi

# ----------------------------------------------------------------------- .env
if [ -f .env ] && ! grep -q '^COUCHDB_PASSWORD=CHANGE_ME' .env; then
  say "Keeping the existing .env (your password is untouched)"
else
  say "Generating .env with a strong password"
  PW=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-28)
  cp .env.example .env
  sed -i "s|^COUCHDB_PASSWORD=.*|COUCHDB_PASSWORD=${PW}|" .env
  chmod 600 .env
  ok ".env created, mode 600"
fi
# shellcheck disable=SC1091
set -a; . ./.env; set +a

# ---------------------------------------------------------------------- start
say "Starting CouchDB"
docker compose up -d
echo

say "Waiting for CouchDB to report healthy (up to 120s)"
for i in $(seq 1 60); do
  if [ "$(docker inspect -f '{{.State.Health.Status}}' livesync-couchdb 2>/dev/null)" = "healthy" ]; then
    ok "healthy after about $((i * 2))s"
    break
  fi
  sleep 2
  if [ "$i" -eq 60 ]; then
    docker compose logs couchdb --tail 40
    die "CouchDB never became healthy — see the log above"
  fi
done

say "Waiting for the one-shot init container"
for _ in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Running}}' livesync-init 2>/dev/null)" = "false" ] && break
  sleep 2
done
INIT_EXIT=$(docker inspect -f '{{.State.ExitCode}}' livesync-init 2>/dev/null || echo unknown)
[ "$INIT_EXIT" = "0" ] || { docker logs livesync-init --tail 40; die "init exited ${INIT_EXIT}"; }
ok "init exited 0 — database provisioned and CORS configured"

# ------------------------------------------------------------------ tailscale
if [ "$DO_TS" = "1" ]; then
  say "Installing Tailscale"
  if command -v tailscale >/dev/null 2>&1; then
    ok "already installed: $(tailscale version | head -1)"
  else
    curl -fsSL https://tailscale.com/install.sh | sh >/dev/null
    ok "installed: $(tailscale version | head -1)"
  fi
  systemctl enable --now tailscaled >/dev/null 2>&1

  say "Resetting any previous Tailscale identity"
  tailscale logout >/dev/null 2>&1 || true
  ok "logged out (safe even if it was already logged out)"

  say "Authenticating this node"
  if [ -n "${TS_AUTHKEY:-}" ]; then
    TSKEY="$TS_AUTHKEY"
    ok "using the auth key supplied by the installer"
  else
    echo "  Create a key at: https://login.tailscale.com/admin/settings/keys"
    echo "  Settings: Reusable = No, Ephemeral = No, Expiry = 90 days"
    echo
    printf '  Paste the auth key (input is hidden): '
    read -rs TSKEY </dev/tty || TSKEY=""
    echo
    [ -n "$TSKEY" ] || die "no key entered"
  fi
  tailscale up --authkey="$TSKEY" --hostname=obsidian-sync --accept-dns=false \
    || die "tailscale up failed - is the key valid and unused?"
  unset TSKEY
  ok "authenticated"

  say "Publishing CouchDB over tailnet HTTPS"
  tailscale serve reset >/dev/null 2>&1 || true
  tailscale serve --bg --https=443 http://127.0.0.1:5984 \
    || die "serve failed - is HTTPS Certificates enabled in the admin console?"
  URL=$(tailscale serve status 2>/dev/null | head -1 | awk '{print $1}')
  NODE=$(tailscale status 2>/dev/null | awk 'NR==1{print $2}')
  ok "serve configured"

  echo
  echo "  ---------------- COPY THIS INTO OBSIDIAN ----------------"
  echo "  URL      : ${URL}"
  echo "  Username : ${COUCHDB_USER}"
  echo "  Password : ${COUCHDB_PASSWORD}"
  echo "  Database : ${COUCHDB_DATABASE}"
  echo "  ---------------------------------------------------------"
  echo

  case "$NODE" in
    obsidian-sync) : ;;
    *) warn "this node is named '$NODE', not 'obsidian-sync'."
       warn "A stale device owns the plain name. In the admin console:"
       warn "  Machines -> delete the old 'obsidian-sync' -> rename '$NODE'."
       warn "The URL above works right now; the rename only makes it tidy." ;;
  esac

  say "Verifying end to end"
  if curl -fsS -u "${COUCHDB_USER}:${COUCHDB_PASSWORD}" "${URL}/_up" 2>/dev/null \
       | grep -q '"status":"ok"'; then
    ok "HTTPS -> CouchDB works: ${URL}"
  else
    warn "local HTTPS check failed. From your laptop run:"
    warn "  curl -u ${COUCHDB_USER}:PASSWORD ${URL}/"
  fi
fi

# --------------------------------------------------------------------- report
umask 077
{
  echo "Obsidian LiveSync — CouchDB credentials"
  echo "generated: $(date -Is) on $(hostname)"
  echo
  echo "Username : ${COUCHDB_USER}"
  echo "Password : ${COUCHDB_PASSWORD}"
  echo "Database : ${COUCHDB_DATABASE}"
  echo "Local URL: http://127.0.0.1:${COUCHDB_PORT}/"
  echo
  echo "Client URL once Phase 5 is done:"
  echo "  https://obsidian-sync.<your-tailnet>.ts.net"
  echo
  echo "The vault end-to-end passphrase is set later inside Obsidian and is"
  echo "NOT recoverable. Store it separately from this file."
} > "$CRED_FILE"
chmod 600 "$CRED_FILE"

say "Done — stack is running"
cat "$CRED_FILE"

say "Run the checks now"
echo "  cd $STACK_DIR && ./scripts/verify.sh"
echo "  (sections 6-7 fail until Tailscale is installed — that is expected)"
