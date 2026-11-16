#!/usr/bin/env bash
# =============================================================================
#  Logical backup of the CouchDB data volume.
#
#  This is the FAST-ROLLBACK layer, not your only backup.
#  Your primary protection is a nightly Proxmox `vzdump` of the whole LXC,
#  which captures /var/lib/docker (data volume), compose.yaml, config and .env
#  in one consistent image. See README "Backup" section.
#
#  Installed by systemd/livesync-backup.timer -> /usr/local/bin/livesync-backup.sh
#
#  Retention is 7 days, not more, on purpose: these archives live on the
#  container's own 8 GB disk. Each one is a full copy of the database, so
#  keeping 14 would nearly double the disk used by the vault. Your long-term
#  history is the Proxmox vzdump on separate storage, not this.
# =============================================================================
set -euo pipefail

STACK_DIR="${STACK_DIR:-/opt/obsidian-livesync}"
DEST="${DEST:-/var/backups/livesync}"
KEEP="${KEEP:-7}"

cd "$STACK_DIR"
VOLUME="obsidian-livesync_couchdb-data"

mkdir -p "$DEST"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$DEST/couchdb-$STAMP.tar.gz"

# Consistency: stop CouchDB, snapshot the volume, start it again.
# Downtime is typically 3-15s for a homelab-sized vault.
docker compose stop couchdb >/dev/null

docker run --rm --network none \
  -v "${VOLUME}:/data:ro" \
  -v "${DEST}:/backup" \
  alpine:3.22 tar czf "/backup/couchdb-${STAMP}.tar.gz" -C /data .

docker compose start couchdb >/dev/null

# Sanity: the archive must contain CouchDB shards, not an empty tree.
if tar tzf "$OUT" 2>/dev/null | grep -q '^\./'; then
  echo "$(date -Is) OK ${OUT} ($(du -h "$OUT" | cut -f1))"
else
  echo "$(date -Is) FAILED: archive empty or unreadable" >&2
  exit 1
fi

# Retention
find "$DEST" -name 'couchdb-*.tar.gz' -type f -mtime "+${KEEP}" -delete
