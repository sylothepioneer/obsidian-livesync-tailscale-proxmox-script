# Obsidian LiveSync on Proxmox + Tailscale — reference

**New here? Read [`START-HERE.md`](START-HERE.md) instead.** It is a linear walkthrough. This file is the reference: why things are built this way, and how to operate and recover the stack.

---

## What gets deployed

```
Obsidian (desktop / Android / iOS)
   │  HTTPS, publicly-trusted Let's Encrypt certificate
   ▼
obsidian-sync.<tailnet>.ts.net        ← tailnet-only, not on the internet
   │
tailscaled in CT 226  (tailscale serve, port 443)
   │  plain HTTP over loopback
   ▼
127.0.0.1:5984                        ← Docker publish, loopback only
   │
livesync-couchdb (couchdb:3.5.3)      ← named volume obsidian-livesync_couchdb-data
```

Everything is created by `livesync-install.sh` (host-side, one run) which embeds and runs `scripts/setup-livesync.sh` (container-side).

## Why it is built this way

| Decision | Reason |
|---|---|
| Tailscale **on the LXC**, not a Docker sidecar | One machine identity, a normal systemd unit, certificate lifecycle handled by `tailscaled`, survives Docker rebuilds. The sidecar needs the same `/dev/net/tun` passthrough anyway. |
| CouchDB bound to **127.0.0.1** | Port 5984 never appears on the LAN or the tailnet. The only reachable surface is HTTPS/443 on your private tailnet. |
| **HTTPS via Serve**, not plain HTTP | Obsidian on mobile refuses plain HTTP and self-signed certificates. `.ts.net` certificates are publicly trusted, so mobile accepts them with no configuration. |
| Image **pinned** to `couchdb:3.5.3` | `:latest` on a database is an unplanned 3 a.m. outage. |
| No **Deno** anywhere | Upstream's init wrapper requires Deno 2. The Docker path ships an equivalent curl-only init script, and the first device is configured manually. |
| CouchDB config via **`local.ini` + init container** | Static limits (doc size, request size) are in the file; auth, CORS and database creation are applied idempotently through the REST API at every boot. |

## Files

| Path | Purpose |
|---|---|
| `START-HERE.md` | Beginner walkthrough — start here |
| `livesync-install.sh` | Single installer, runs on the Proxmox host |
| `scripts/setup-livesync.sh` | Container-side installer (also embedded in the above) |
| `scripts/verify.sh` | Full end-to-end check, run inside the container |
| `scripts/backup.sh` + `systemd/` | Nightly database backup, installed automatically |
| `compose.yaml`, `config/livesync.ini`, `.env.example` | The stack, for manual deployment or review |
| `scripts/couchdb-init.sh` | Vendored upstream init (unmodified) |

`scripts/setup-livesync.sh` embeds the same compose/ini/init content, so the folder and the installer cannot drift. Regenerate the installer after editing any of them.

---

## Resource sizing

Defaults: **1 vCPU, 1 GiB RAM, 256 MiB swap, 8 GiB disk.**

Measured on a text-only vault:

| Component | RAM | Disk |
|---|---|---|
| Debian 13 base | ~120 MB | ~1.4 GB |
| Docker + containerd | ~100 MB | ~0.5 GB |
| CouchDB (idle) | ~180-250 MB | ~0.5 GB images |
| Vault data + 7 nightly backups | — | 0.3-1.3 GB |
| **Total** | **~450 MB** | **~3.5 GB of 8 GB** |

Grow without rebuilding:

```bash
pct set 226 --memory 1536          # RAM, effective on next start
pct resize 226 rootfs +4G          # disk, online
```

---

## Operations

**Status**
```bash
pct exec 226 -- docker compose -f /opt/obsidian-livesync/compose.yaml ps
pct exec 226 -- tailscale serve status
pct exec 226 -- bash /opt/obsidian-livesync/scripts/verify.sh
```

**Logs**
```bash
pct exec 226 -- docker logs livesync-couchdb --tail 50
pct exec 226 -- docker logs livesync-init --tail 20
```

**Restart / stop**
```bash
pct exec 226 -- bash -c 'cd /opt/obsidian-livesync && docker compose restart'
pct exec 226 -- bash -c 'cd /opt/obsidian-livesync && docker compose down'
```

**Credentials**
```bash
pct exec 226 -- cat /root/livesync-credentials.txt
```

### Upgrades

Pin deliberately. Read the CouchDB release notes, change the tag in `/opt/obsidian-livesync/compose.yaml`, then:

```bash
pct exec 226 -- bash -c 'cd /opt/obsidian-livesync && docker compose pull && docker compose up -d'
pct exec 226 -- bash /opt/obsidian-livesync/scripts/verify.sh
```

A minor-version rollback is instant from a `vzdump`. Test a major version (3.x → 4.x) on a clone first.

### Backup and restore

**Layer 1 — nightly logical dump** (installed automatically): a consistent tar of the data volume at 03:30, 7-day retention, in `/var/backups/livesync/` inside the container. Fast single-file rollback, but it lives on the same disk.

**Layer 2 — Proxmox image** (do this manually, it is the one that survives disk failure):
Datacenter → Backup → Add → CT 226 → daily → keep-last 7, on separate storage.

Restoring layer 1:

```bash
pct exec 226 -- bash -c 'cd /opt/obsidian-livesync && docker compose down'
pct exec 226 -- docker volume rm obsidian-livesync_couchdb-data
pct exec 226 -- docker volume create obsidian-livesync_couchdb-data
# extract the chosen archive into that volume, then:
pct exec 226 -- bash -c 'cd /opt/obsidian-livesync && docker compose up -d'
```

Then on each device: LiveSync → **Reset synchronisation on this device**, since the remote revision history has been rolled back.

**Unrecoverable if lost:** the vault E2E passphrase and the CouchDB password. A restored database without the passphrase is ciphertext.

---

## Multiple vaults

One vault = one CouchDB database. Options, simplest first:

| Approach | When |
|---|---|
| Second database on the same server (`vault-work`) | Same person, separate topic. Create it with `PUT /vault-work` and use the same URL and credentials in a separate Obsidian vault. |
| Second container | Different people, or you want isolation and separate backups. Run `livesync-install.sh --ctid 230 --hostname obsidian-work`. |

**Never point two Obsidian vaults at the same database.** LiveSync will treat them as one vault and merge the contents.

Naming: lowercase letters and digits only (`obsidiannotes`, `vault-work`). Uppercase or punctuation causes failures at replication time, not at setup time.

---

## Hardening (optional)

Default tailnet ACLs already restrict this to your own devices. If your tailnet is shared, tag the node and scope access:

1. ACL: allow your devices to `obsidian-sync:443` only
2. Re-authenticate the node with `--advertise-tags=tag:obsidian`

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `livesync-couchdb` restarts, log shows `permission denied` on `/opt/couchdb/data` | Volume ownership | Fresh install only: `docker compose down`, `docker volume rm obsidian-livesync_couchdb-data`, redeploy |
| `livesync-init` keeps restarting | CouchDB not healthy yet | `docker logs livesync-couchdb --tail 50`; the init retries and usually recovers by itself |
| Container start fails: `fuse: device not found` / `lazytime` | `daemon.json` set to `fuse-overlayfs`, which needs `/dev/fuse` that a stock LXC lacks. Deleting `daemon.json` is **not enough** — Docker caches the driver in `/var/lib/docker` | Inside the CT: `systemctl stop docker`, write `{"features":{"containerd-snapshotter":true}}` to `/etc/docker/daemon.json`, `rm -rf /var/lib/docker/*`, `systemctl start docker`, confirm `docker info --format '{{.Driver}}'` says `overlayfs` |
| `docker info` shows `vfs`, uploads crawl | Overlay mount not permitted | Same as above — enable the containerd store. **Not** `fuse-overlayfs` |
| `open /dev/net/tun: no such file or directory` | TUN not passed through | Add the two `lxc.*` lines to `/etc/pve/lxc/226.conf` with the CT stopped, then start it |
| tailscaled dies after a Proxmox kernel upgrade | Host `tun` module reloaded, bind mount stale | `pct exec 226 -- systemctl restart tailscaled` |
| `tailscale serve` says HTTPS not enabled | Certificate feature off for the tailnet | Admin console → DNS → enable **HTTPS Certificates** |
| `tailscale serve status` empty after reboot | `--bg` omitted when configured | Re-run `tailscale serve --bg --https=443 http://127.0.0.1:5984` |
| Plugin: connection failed / 401 | Wrong URI or password | URI has **no** `:5984`. Test with `curl` from a laptop first |
| Plugin: CORS error | CORS missing server-side | `pct exec 226 -- docker compose -f /opt/obsidian-livesync/compose.yaml up -d --force-recreate couchdb-init` |
| `502 Bad Gateway` | URL resolves to a different, offline tailnet device | Compare `tailscale serve status` hostname with the URL. Delete stale machines, rename the node |
| Plugin: **"SCRAM detected, all operations suspended"** | LiveSync's own emergency freeze (not SCRAM authentication). Suspends file watching and DB reflecting to prevent corruption | Settings → LiveSync → **Hatch → Scram Switches**: resume both, restart. Delete stray `redflag.md` / `flag_*.md` from the vault root. If it loops: close Obsidian, `Ctrl+Shift+I` → Console → `indexedDB.deleteDatabase('obsidian-livesync')`, reopen, redo wizard |
| `doc_count` is much higher than the number of notes | Expected — not a bug. Each note is stored as **one `f:` metadata document plus several `h:` chunk documents**, so 11 notes can produce ~47 documents. `doc_count` is **not** a file count | Count notes, not documents. To see the real file count: `... /_all_docs` then count ids starting `f:` |
| Notes exist on the desktop but not on the phone, and the plugin log says `Creating chunks Done: N of N files` where N is small | The vault genuinely contains N files. `Recreate chunks` scans the actual vault folder, so this is the truth — the missing notes are in a different vault or folder | Check which vault is open (`~/.config/obsidian/obsidian.json` on Linux lists all of them). Point LiveSync at the right vault with a **different** database name |
| New folders don't appear on the other device until a file is placed in them | LiveSync replicates **files**; the folder is only part of the filename. `doNotDeleteFolder` (`Keep empty folder`) controls pruning of empty folders, not their creation elsewhere | Expected. Add a tiny visible note (e.g. `_keep.md`) to any structural folder you want everywhere. `.gitkeep` is invisible to Obsidian and will not sync |
| Empty folders don't appear on the other device | LiveSync creates folders as files arrive; empty folders are not transferred | Expected. Setting `Keep empty folder` (`doNotDeleteFolder`) controls whether empty folders are *retained*, not created |
| Two devices have the same ID key but nothing transfers; log shows `Some mismatches have been detected in the configuration between devices` then `E2EE configuration cancelled` | A configuration-mismatch dialogue was **cancelled**. Synchronisation stays paused until it is answered | Run `Sync now`, then choose **`Apply settings to this device`**. Never dismiss or cancel it |
| Sync connects but files never move | Sync Mode is not `LIVESYNC`. Onboarding does not enable real-time sync | Settings → LiveSync → **Sync Settings → Synchronisation Preset → LiveSync** (sets `syncMode=LIVESYNC`). Required on every device: the Setup URI carries remote and encryption settings, not the sync mode |
| Phone can't sync, desktop fine | Tailscale off on the phone, or cert error | Enable Tailscale. The `.ts.net` cert is publicly trusted, so there is nothing to install |
| Sync stops when phone sleeps | Background execution limits | Expected. Sync on foreground. Android: exempt Obsidian from battery optimisation |
| Initial upload fails on a huge vault | 4 GB request ceiling / RAM | Raise `max_http_request_size` or `pct set 226 --memory 2048` |
| Two devices both treated as "first device" | Manual configuration applied twice | **Reset synchronisation on this device** on one of them, then add devices only via Setup URI |

---

## Why a clean reset is the reliable fix

Failed setups accumulate residue, and each item blocks sync differently. A reset clears all of them at once:

| Residue | Where | Blocks because |
|---|---|---|
| Flag files | `redflag.md`, `flag_fetch.md`, `flag_rebuild.md` at the vault root | Suspends work on every start, even after a plugin reinstall |
| Local plugin database | `.obsidian/plugins/obsidian-livesync/` | Persists across reinstalls; holds old IDs, checkpoints, suspensions |
| Remote lock | `locked: true` in `_local/obsydian_livesync_milestone` | Other devices are locked out and receive nothing, with no error |
| Stale device records | `accepted_nodes` in the same local document | Can prevent the remote from ever reaching "all resolved" |
| Old revisions | documents in the database | Confuses rebuilds and ID comparisons |

Useful diagnostics:

```bash
# is the remote actually locked?
pct exec 226 -- bash -c 'set -a; . /opt/obsidian-livesync/.env; set +a; curl -s -u "$COUCHDB_USER:$COUCHDB_PASSWORD" "http://127.0.0.1:5984/obsidiannotes/_local/obsydian_livesync_milestone" | grep -o "\"locked\":[a-z]*"'

# which devices does the remote know about?
pct exec 226 -- bash -c 'set -a; . /opt/obsidian-livesync/.env; set +a; curl -s -u "$COUCHDB_USER:$COUCHDB_PASSWORD" "http://127.0.0.1:5984/obsidiannotes/_local/obsydian_livesync_milestone" | grep -o "\"accepted_nodes\":[^]]*]"'
```

`"locked":false` means the UI warning can be ignored — the red box in Maintenance is a local reminder that only clears after a replication confirms the device, so clicking it does nothing when the remote is already unlocked.

## Verified facts

| Fact | Source | Date |
|---|---|---|
| Docker stack is upstream-supported; init script is curl-only and idempotent | `vrtmrz/obsidian-livesync` @ `0e458e5e2062`, sha256 `da4987a8…` | 2026-10-31 |
| CouchDB stable is 3.5.3 | Docker Hub `library/couchdb` | 2026-10-28 |
| Docker 29 renamed the storage driver `overlay2` → `overlayfs` (containerd image store) | Docker forums, spring-boot #49251 | 2026 |
| Mobile requires an OS-trusted HTTPS certificate; no plain HTTP, no self-signed | `docs/troubleshooting.md` | 2026-10-31 |
| `serve` needs `http://127.0.0.1` targets and `--bg` for persistence | tailscale.com/docs/reference/tailscale-cli/serve | 2026-01 |
| HTTPS certificates need MagicDNS + the admin console toggle | tailscale.com/docs/how-to/set-up-https-certificates | 2025-12 |
| Unprivileged LXC needs `/dev/net/tun` plus `nesting=1,keyctl=1` | Tailscale LXC docs | 2026 |
