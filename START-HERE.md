# Obsidian LiveSync — start here

A private Obsidian sync server for your Proxmox homelab. No subscription, no open ports, no domain, no data leaving your own machines.

```
Obsidian on your laptop / phone
   │   HTTPS, real Let's Encrypt certificate
   ▼
obsidian-sync.<your-tailnet>.ts.net      ← works only on your Tailscale network
   │
   ▼
CouchDB inside Docker, in its own LXC container
```

---

## What you need before starting

| Thing | How to check |
|---|---|
| Proxmox VE host, root access | You already have this |
| ~1 GiB RAM and 8 GiB disk free | `free -m`, `pvesm status` |
| Tailscale account, MagicDNS + HTTPS Certificates enabled | <https://login.tailscale.com/admin/dns> |
| A Tailscale auth key | <https://login.tailscale.com/admin/settings/keys> |

**Enable HTTPS Certificates first.** Admin console → DNS → **HTTPS Certificates → Enable**. Do this before running the script; the script cannot work around it.

Create the auth key with: **Reusable: No**, **Ephemeral: No**, **Expiry: 90 days**. You only need it once.

---

## Step 1 — Copy the installer to the Proxmox host

Download `livesync-install.sh` from this folder to your PC. Then, in PowerShell or a terminal **on your PC** (not the Proxmox web UI):

```powershell
scp .\livesync-install.sh root@pve:/root/
```

If `pve` does not resolve, use your host's IP: `root@192.168.1.50:/root/`.

> No `scp` on Windows? Use **WinSCP** (drag and drop) instead. Or skip this step entirely — see *Alternative* at the bottom.

---

## Step 2 — Run it

Open the Proxmox host shell: web UI → click your node → **`>_ Shell`**. Then:

```bash
bash /root/livesync-install.sh
```

It takes about 5 minutes and does everything:

1. Creates a Debian 13 container (ID 226, 1 vCPU, 1 GiB RAM, 8 GiB disk)
2. Gives it the `/dev/net/tun` device Tailscale needs
3. Fixes DNS inside the container
4. Installs Docker and checks the storage driver is healthy
5. Deploys CouchDB with the correct CORS and auth settings
6. Installs Tailscale and publishes CouchDB as an HTTPS site on your tailnet
7. Schedules a nightly backup of the database

**What it asks you:**

- `Type DESTROY` — only if container 226 already exists. On a fresh install it does not ask.
- `Auth key:` — paste the key from Step 0. Input is hidden and the key is not stored.

When it finishes you'll see:

```
  ============================================================
   INSTALL COMPLETE
  ============================================================
Username : livesync
Password : xxxxxxxxxxxxxxxxxxxxxxxxxxxx
Database : obsidiannotes
```

**Copy that password.** It is also saved inside the container at `/root/livesync-credentials.txt`.

---

## Step 3 — Check it works

From your **laptop** (Tailscale must be running):

```bash
curl -u 'livesync:YOUR_PASSWORD' https://obsidian-sync.<your-tailnet>.ts.net/
```

You want:

```json
{"couchdb":"Welcome","version":"3.5.3","vendor":{"name":"The Apache Software Foundation"}}
```

The exact URL was printed at the end of the install. If you lost it:

```bash
pct exec 226 -- tailscale serve status
```

> **Don't skip this step.** If the server isn't answering here, the plugin cannot possibly work, and you'll waste an hour blaming the plugin.

---

## Step 4 — Connect Obsidian on your laptop

**Before you start:** back up your vault. Turn off Obsidian Sync, iCloud, OneDrive, Dropbox, Syncthing or anything else writing to that folder. Two sync tools on one vault will corrupt it.

1. Obsidian → Settings → **Community plugins** → Browse → **Self-hosted LiveSync** → Install → **Enable**
2. Click the `Welcome to Self-hosted LiveSync` notice
3. **`I am setting this up for the first time`** → confirm
4. **`Configure a remote manually`** → `Proceed with manual configuration`
5. **`End-to-End Encryption`** → enable it, set a strong **vault passphrase**, write it down somewhere separate from the CouchDB password
6. Remote Type **CouchDB**, then fill in:

   | Field | Value |
   |---|---|
   | URI | `https://obsidian-sync.<your-tailnet>.ts.net` |
   | Username | `livesync` |
   | Password | from Step 2 |
   | Database name | `obsidiannotes` |

   No `:5984`, no trailing slash.

7. If asked **`ID generation`**, choose **`Keep current configuration`**.

   That derives IDs from your E2EE passphrase, so any device with the same passphrase computes identical IDs. `Generate a random ID key` also works, but the key must then reach every device — and a device configured without it silently creates a second, invisible copy of your vault.

8. **`Create or connect to database and continue`** — the test must pass
9. **`Restart and Initialise Server`**
10. If `No Synchronisation Settings Found` appears → **`Use this device's settings`**
11. Acknowledge `All optional features are disabled` — leave them off for now
12. **Keep Obsidian open** until the progress indicators clear
13. **Select the LiveSync preset.** Settings → **Self-hosted LiveSync** → **Sync Settings** → **Synchronisation Preset** → **LiveSync**

    This is easy to miss. A fresh install is **not** in real-time mode, so without this step the connection tests pass, files may sit still, and it looks broken. The preset sets Sync Mode to `LIVESYNC`.

**Verify:** create a note called `_sync-test.md`, then on the Proxmox host:

```bash
pct exec 226 -- bash -c 'set -a; . /opt/obsidian-livesync/.env; set +a; curl -s -u "$COUCHDB_USER:$COUCHDB_PASSWORD" "http://127.0.0.1:5984/obsidiannotes"'
```

`doc_count` must rise above 0.

---

## Step 5 — Add more devices (phone, tablet, second laptop)

Every additional device follows this exact sequence. There is no per-device server configuration — one Setup URI covers all of them.

### The four rules

| Rule | Why |
|---|---|
| **Tailscale must be ON** | The server is tailnet-only. With Tailscale off, the device cannot even resolve the URL. Nothing will warn you — it just fails. |
| **Use a NEW EMPTY vault** | A vault that already has notes will mix them into the shared database. Start empty and let it download. |
| **Always import a Setup URI** | Never type the URL and password by hand on a second device. Manual re-entry is how two devices both become "first device" and cause conflict storms. |
| **Set the LiveSync preset on every device** | The Setup URI carries the remote and encryption settings, **not** the sync mode. A device without the preset connects fine and syncs nothing. |

### ⚠️ Before adding any device: unlock the database

**`Overwrite Server Data with This Device's Files` locks the remote.** It stays locked until every device is marked *resolved*. While it is locked, any other device is **locked out** and will sync nothing, with no obvious error — this is the single most common reason a phone appears to sync but receives nothing.

On the device that ran the rebuild, open **Hatch → Maintenance**. A red warning reads:

> *"…the remote database has been locked for synchronisation. (This device is marked as 'resolved'.)…"*

Press **`I am ready, unlock the database`**. Only then add devices.

### Steps

**On a device that already works** (your laptop):

1. `Ctrl+P` → **`Self-hosted LiveSync: Copy settings as a new Setup URI`**
2. Set a passphrase to protect this URI. **This is a third, separate secret** — not the CouchDB password and not the vault passphrase. It only encrypts the URI text. Reusing the vault passphrase works but is not recommended.
3. Choose **`Time-bound`** if you are adding the device now (default, expires at the end of the current 7-day UTC window) or **`Compatible (no time limit)`** only if you need it reusable
4. Copy the `obsidian://setuplivesync?settings=...` string

**On the new device:**

4. Install **Tailscale**, sign in, **turn it ON**
5. Install **Obsidian**, create a **new empty vault**
6. Install and enable **Self-hosted LiveSync**
7. Welcome notice → **`I am adding a device to an existing synchronisation setup`** → confirm
8. `Device Setup Method` → **`Use a Setup URI`** → paste URI + passphrase → `Test Settings and Continue`
9. **`Restart and Fetch Data`**
10. Empty vault → **`Overwrite all with remote files`**
11. Extra local files → **`Keep local files even if not on remote`**
12. Keep Obsidian in the foreground until the indicators clear
13. If a dialog says **"Your settings differed slightly from the server's. The plug-in has supplemented the incompatible parts with the server settings!"** → tap **`OK`**.

    That is current, sane behaviour: the plugin reconciles the difference itself instead of pausing. Older versions instead showed a blocking mismatch dialogue here, which had to be answered with `Apply settings to this device` and never dismissed.

14. ⚠️ **Settings → Self-hosted LiveSync → Sync Settings → Synchronisation Preset → `LiveSync`**

Step 14 is the one people forget. Do it before you conclude anything is broken.

### Verify

Create a note on the new device. Within a few seconds it should appear on your laptop, and `doc_count` should rise:

```bash
pct exec 226 -- bash -c 'set -a; . /opt/obsidian-livesync/.env; set +a; curl -s -u "$COUCHDB_USER:$COUCHDB_PASSWORD" "http://127.0.0.1:5984/obsidiannotes"'
```

### Per-platform notes

| Device | Extra step |
|---|---|
| **Android** | Optional but recommended: Settings → Apps → Obsidian → Battery → **Unrestricted**, so sync isn't killed in the background |
| **iOS / iPadOS** | Nothing to configure. iOS suspends background work, so LiveSync only syncs while Obsidian is open — that is expected, not a fault |
| **Second Windows/Mac/Linux** | Nothing extra. Just remember the **new empty vault** rule |

### Adding a device later, once you've forgotten all this

Open `START-HERE.md` → Step 5. That's it. The server needs no changes, no restart, and no new credentials — the Setup URI contains everything.

---

## Step 6 — Protect it

Two things are unrecoverable. Store them **outside** the Proxmox host:

1. **The vault end-to-end passphrase** (Step 4.5) — without it a restored database is meaningless ciphertext
2. **`/root/livesync-credentials.txt`** from the container

Then set up Proxmox image backups. The container already backs up the database nightly, but only to its own disk:

> Web UI → **Datacenter → Backup → Add** → select **CT 226** → daily → keep-last 7

---

## When something goes wrong

Check these in order. Each one rules out a whole layer.

| Symptom | Most likely cause | Fix |
|---|---|---|
| Browser/curl can't reach the URL | Tailscale off on that device, or HTTPS not enabled | Turn on Tailscale; enable HTTPS Certificates in admin console |
| Red lock warning will not go away when clicked | The remote may not actually be locked — the warning is a **local reminder** that clears only after replication confirms the device. Clicking is a no-op when `locked` is already `false` | Check the truth: `curl … /obsidiannotes/_local/obsydian_livesync_milestone` and look for `"locked":false`. If false, ignore the box and continue — do **not** reset anything |
| **New folders don't appear** on the other device until a file is added | LiveSync stores **files**, not folders — the directory is just part of the filename. No files means no documents to replicate. `Keep empty folder` (`doNotDeleteFolder`) only controls whether an empty folder is *pruned*, not whether it is *created* elsewhere | Expected behaviour, no setting fixes it. Put one tiny visible note in the folder (e.g. `_keep.md`). A `.gitkeep` will not work — Obsidian does not index dotfiles |
| Other devices sync nothing, no errors anywhere, log repeats `Replication paused` | **The remote database is locked** — typically a side effect of `Overwrite Server Data with This Device's Files`, which locks the remote by design. `Replication paused` on its own is normal idle behaviour, not an error | Hatch → Maintenance → **`I am ready, unlock the database`**. If it refuses: `Remote Configuration → Joined devices → Review devices` → `Forget device` on stale entries, then unlock |
| `502 Bad Gateway` | The URL points at a different, offline tailnet device | `pct exec 226 -- tailscale serve status` — use the hostname it prints |
| `401 Unauthorized` | Correct behaviour, wrong password | Re-read `/root/livesync-credentials.txt` |
| Plugin: connection failed | Wrong URI | No `:5984`, no trailing slash |
| Plugin: **"SCRAM detected, all operations suspended"** | Plugin's own safety freeze, not a server fault | Settings → LiveSync → **Hatch → Scram Switches**: turn both off, restart. Check the vault root for stray `redflag.md` / `flag_*.md` files and delete them. If it loops: close Obsidian, `Ctrl+Shift+I` → Console → `indexedDB.deleteDatabase('obsidian-livesync')`, reopen, redo the wizard |
| **Notes look missing on the phone** | First rule this out: `Creating chunks Done: N of N files` in the desktop log is the **true** file count. `doc_count` on the server is *not* a file count — each note adds one metadata doc plus several chunk docs | Count real notes, then expand the folders on the phone. `BRAIN/Notes/...` style nested paths are normal |
| **Empty folders don't appear** on the other device | LiveSync creates folders as files arrive | Expected — empty folders are not transferred |
| Sync connects but **files never move** | Sync Mode is not `LIVESYNC` — a fresh install is not real-time by default | Settings → Self-hosted LiveSync → **Sync Settings → Synchronisation Preset → LiveSync**. Must be done on **every** device |
| Phone can't sync, laptop fine | Tailscale off on the phone, or preset not set | Enable Tailscale; check the synchronisation preset. Android: also exclude Obsidian from battery optimisation |
| `fuse: device not found` / `lazytime` | Wrong Docker storage driver | Should not happen — the installer verifies this. If it does, see README |

**Command to check every layer at once:**

```bash
pct exec 226 -- bash /opt/obsidian-livesync/scripts/verify.sh
```

---

## Reference

Deeper material lives in **`README.md`**: architecture rationale, resource sizing, upgrades, backup/restore, multi-vault layout, Tailscale ACLs.

### The short version of what this costs you

| Resource | Usage |
|---|---|
| RAM | ~450 MB of your 8 GB |
| Disk | ~3.5 GB of 8 GB |
| CPU | idle almost always |

### One vault = one database

For a second vault later, give it its own database name (`vault-work`, `vault-home`) and create a **new LXC** or a second database on the same server. Never point two vaults at one database — LiveSync will merge them into a mess.

---

## Why the clean slate works (and stale state doesn't)

If a setup has been through several failed attempts, these accumulate and each one blocks sync in its own way:

| Stale state | File / location | Effect |
|---|---|---|
| Flag files | `redflag.md`, `flag_fetch.md`, `flag_rebuild.md` in the vault root | Suspends sync on every start, even after reinstalling the plugin |
| Local plugin database | `.obsidian/plugins/obsidian-livesync/` | Survives plugin reinstall; keeps old IDs, checkpoints and suspensions |
| Remote lock | `locked: true` in `_local/obsydian_livesync_milestone` | Other devices are **locked out** and silently receive nothing |
| Old device records | `accepted_nodes` in the same document | A stale device can prevent the remote from ever reporting "all resolved" |
| Stale revisions | documents in the database | Old ID schemes and half-uploaded files confuse rebuilds |

A clean start clears all five. That is why it worked after a week of targeted fixes: the previous failures were not one bug, they were residue.

**Order that works** (each step verified before the next):

1. Delete the server database → confirm only `["_replicator","_users"]` remain
2. New vault folder (never reuse the old one) → copy notes in → confirm Obsidian lists them
3. Onboard as first device → `ID generation` → **`Keep current configuration`**
4. Let the normal initial upload run. **Do not** use `Overwrite Server Data with This Device's Files`
5. Confirm `doc_count` grew, and `"locked":false`
6. Set the preset → `LiveSync`
7. Setup URI (**Time-bound**) → new empty vault on the device → fetch
8. Tap **`OK`** on the "settings differed slightly" dialog
9. Set the preset on that device too
10. Test both directions with a throwaway note

---

## Nuclear option — start over cleanly (15 minutes)

Use this when you have accumulated stale state: redflag files, a locked remote, cancelled mismatch dialogues, several half-configured devices. It is faster than untangling it, and safer.

**Order matters. Do not skip ahead, and do not configure two devices at once.**

**1. Desktop — capture your vault**
Back up the vault folder. Confirm Obsidian shows every file you expect.

**2. Desktop — wipe plugin state**
Settings → Self-hosted LiveSync → **Hatch → Reset → `Back to non-configured`**.
Then disable the plugin, re-enable it. If you want a completely clean local cache, close Obsidian and delete the vault's `.obsidian/plugins/obsidian-livesync/` folder before re-enabling.

**2b. (Optional but decisive) wipe the server database**

Deleting the database removes every document *and* every local document, so the obsolete **lock**, joined-device records, stale revisions and old encryption metadata all disappear. This is what clears a stuck `Locked out` state.

```bash
# delete it
pct exec 226 -- bash -c 'set -a; . /opt/obsidian-livesync/.env; set +a; curl -s -X DELETE -u "$COUCHDB_USER:$COUCHDB_PASSWORD" http://127.0.0.1:5984/obsidiannotes'

# gate: must now show only ["_replicator","_users"]
pct exec 226 -- bash -c 'set -a; . /opt/obsidian-livesync/.env; set +a; curl -s -u "$COUCHDB_USER:$COUCHDB_PASSWORD" http://127.0.0.1:5984/_all_dbs'
```

For zero filesystem residue as well:

```bash
pct exec 226 -- bash -c 'cd /opt/obsidian-livesync && docker compose down'
pct exec 226 -- docker volume rm obsidian-livesync_couchdb-data
pct exec 226 -- bash -c 'cd /opt/obsidian-livesync && docker compose up -d'
```

The `.env` and password are not affected; the init container recreates the empty database on start.

**3. Desktop — use a NEW database name**
During onboarding use e.g. `obsidiannotes3` instead of the old name. A fresh database has no lock, no flags and no stale revision history. The server creates it automatically. (Leaving the old database in place is harmless; delete it later with `curl -X DELETE …/obsidiannotes` if you like.)

**4. Desktop — let the first upload complete**
Let the **normal initial upload** run. Do **not** use `Overwrite Server Data with This Device's Files` here.

> ⚠️ **That operation LOCKS the remote database.** It exists to rebuild a corrupted remote, not to finish first-time setup. While the remote is locked, every other device is locked out and silently syncs nothing. If you have already used it, you must press **`I am ready, unlock the database`** in Hatch → Maintenance before adding any device.

**5. Desktop — verify before moving on**
```bash
pct exec 226 -- bash -c 'set -a; . /opt/obsidian-livesync/.env; set +a; curl -s -u "$COUCHDB_USER:$COUCHDB_PASSWORD" "http://127.0.0.1:5984/obsidiannotes3/_all_docs" > /tmp/i.json; echo -n "files: "; grep -o "\"id\":\"f:" /tmp/i.json | wc -l'
```
The `files:` count must match your real note count. **Do not continue until it does.**

> If this shows `0` right after onboarding, it is usually just **too early** — the initial upload only starts once the preset is set and a sync runs. Apply the preset, run `Sync now`, then check again. A quick alternative that is harder to misread — `doc_count` grows as files upload (each note ≈ 2+ documents):
> ```bash
> pct exec 226 -- bash -c 'set -a; . /opt/obsidian-livesync/.env; set +a; curl -s -u "$COUCHDB_USER:$COUCHDB_PASSWORD" http://127.0.0.1:5984/obsidiannotes | grep -o "\"doc_count\":[0-9]*"'
> ```

**6. Desktop — confirm the database is UNLOCKED**
Hatch → Maintenance → **`I am ready, unlock the database`**.

**7. Desktop — generate a Setup URI**
Command palette → `Copy settings as a new Setup URI`.

**8. Phone — start clean**
Uninstall the plugin (or delete the vault entirely and make a new empty one). A leftover local LiveSync database is exactly what keeps old failures alive.

**9. Phone — join with the Setup URI**
New empty vault → install plugin → `I am adding a device…` → `Use a Setup URI` → paste.
If a configuration mismatch dialogue appears, choose **`Apply settings to this device`** — never dismiss it.

**10. Verify both directions**
Edit a note on each device; confirm it lands on the other within seconds.

---

## Alternative: no scp

If transferring the file is awkward, open **CT 226 → Shell** in the Proxmox web UI and paste the entire contents of `livesync-install.sh` — but note it is written to run on the **host**, not inside the container. The `scp`route is genuinely simpler.

If you cannot use `scp` at all: create the container manually by following `README.md` Phase 1, then paste `scripts/setup-livesync.sh` into the container's web shell and run it, then run it again with `--tailscale`.
