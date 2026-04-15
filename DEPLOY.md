# Deploying coloring-book on an Ubuntu server with existing services

This guide is written for an Ubuntu host that **already runs other apps**.
Every name and port is namespaced with `coloringbook` so nothing collides with
existing units, dirs, users, or DNS.

## Conventions used here

| Resource | Value |
|---|---|
| App user | `coloringbook` (system user, no shell) |
| Repo dir | `/opt/coloring-book` |
| DB / data dir | `/var/lib/coloringbook` |
| Static download dir | `/opt/coloringbook-web` |
| Internal port | `8787` (overridable, see step 2) |
| systemd unit name | `coloringbook.service` |
| Public hosts | `colorbook.adisuresh.me` (landing + DMG download) and `api.colorbook.adisuresh.me` (WSS backend) |

If any of those *would* collide with something already on the host, change them
**here first** before running anything.

---

## Step 0 — Pre-flight (run as your normal user, don't change anything yet)

Verify nothing already owns the names / ports we want.

```sh
# Is port 8787 in use?
sudo ss -tlnp | grep ':8787' || echo "port 8787 free"

# Is the systemd unit name free?
systemctl list-unit-files | grep -i coloringbook || echo "unit name free"

# Does the user already exist?
id coloringbook 2>/dev/null && echo "USER EXISTS — pick a different name" || echo "user free"

# Does the dir already exist?
[ -d /opt/coloring-book ] && echo "DIR EXISTS — pick a different path" || echo "dir free"
[ -d /var/lib/coloringbook ] && echo "DATA DIR EXISTS" || echo "data dir free"

# Is Caddy already running and reachable on 80/443?
systemctl is-active caddy 2>/dev/null && echo "Caddy is running — we'll ADD a site to it"
sudo ss -tlnp | grep -E ':(80|443) ' || echo "no http/https service yet"
```

If anything is taken, **stop and adjust the names** in this file before
proceeding. Search-and-replace `coloringbook` → `coloringbook2` (or
whatever) in this guide and the systemd unit / Caddy snippet below.

---

## Step 1 — Install dependencies (idempotent — skips what's already installed)

```sh
# Node 20 LTS — only install if we don't already have node ≥ 20
node --version 2>/dev/null | grep -qE '^v(2[0-9]|[3-9])' || {
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash
    sudo apt install -y nodejs
}

# Native build tools (bcrypt + better-sqlite3 compile against these)
sudo apt install -y build-essential python3

# Caddy (only install if not already there)
which caddy >/dev/null || {
    sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | sudo tee /etc/apt/sources.list.d/caddy-stable.list
    sudo apt update && sudo apt install -y caddy
}
```

---

## Step 2 — App user, dirs, and code

```sh
# System user — no shell, no home dir, just an identity for the service.
sudo useradd -r -s /usr/sbin/nologin coloringbook

# Dirs — repo, data (DB lives here), and the static web dir for the DMG.
sudo mkdir -p /opt/coloring-book /var/lib/coloringbook /opt/coloringbook-web
sudo chown -R coloringbook:coloringbook /var/lib/coloringbook

# Clone the repo. If your repo is private use a deploy key or a PAT-in-URL.
sudo git clone https://github.com/adi-suresh01/coloring-book.git /opt/coloring-book
sudo chown -R coloringbook:coloringbook /opt/coloring-book

# Build native deps for THIS machine (don't ship node_modules from your Mac).
cd /opt/coloring-book/server
sudo -u coloringbook npm ci
```

If `npm ci` errors compiling `bcrypt` or `better-sqlite3`, you're missing
`build-essential` / `python3`. Re-run step 1.

---

## Step 3 — systemd unit

Write `/etc/systemd/system/coloringbook.service`:

```ini
[Unit]
Description=Coloring Book collab server
After=network.target

[Service]
Type=simple
User=coloringbook
WorkingDirectory=/opt/coloring-book/server
Environment=PORT=8787
Environment=DB_PATH=/var/lib/coloringbook/state.db
ExecStart=/usr/bin/npm start
Restart=on-failure
RestartSec=3
# Conservative resource limits so a server bug can't take down the host.
MemoryMax=512M
TasksMax=128

[Install]
WantedBy=multi-user.target
```

If port `8787` is taken, pick another (say `9787`) and change *both* this
unit AND the Caddy snippet in step 4 to match.

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now coloringbook
sudo systemctl status coloringbook   # should be "active (running)"
sudo journalctl -u coloringbook -n 30
```

Expected log line: `coloring-book server listening on ws://localhost:8787 (db=/var/lib/coloringbook/state.db)`.

---

## Step 4 — Caddy site (additive — does NOT touch your existing config)

If Caddy is already running other sites, **don't** edit the main `Caddyfile`
unless you know it. Instead drop a snippet that the main config can
`import`. If you don't have `import` already wired up, do this once:

```sh
# Make a snippet directory if your Caddyfile doesn't already use one.
sudo mkdir -p /etc/caddy/sites
# Add an `import` line near the TOP of /etc/caddy/Caddyfile (only if not
# already present). Edit by hand:
sudo nano /etc/caddy/Caddyfile
#   add this single line:
#       import sites/*.caddyfile
```

Now create the snippet at `/etc/caddy/sites/coloringbook.caddyfile`:

```caddyfile
# Static download page (DMG download lives here).
colorbook.adisuresh.me {
    root * /opt/coloringbook-web
    file_server
    encode gzip
    # Long cache for the DMG so repeat visits don't re-download.
    @dmg path *.dmg
    header @dmg Cache-Control "public, max-age=86400"
}

# WebSocket / API backend.
api.colorbook.adisuresh.me {
    reverse_proxy localhost:8787
    # WebSockets through Caddy 2 work by default — no extra directive needed.
}
```

Then:

```sh
sudo caddy validate --config /etc/caddy/Caddyfile    # syntax check
sudo systemctl reload caddy                           # zero-downtime reload
```

`reload` (not `restart`) ensures your other Caddy sites stay up. Caddy
fetches Let's Encrypt certs for the two new hostnames on first request.

---

## Step 5 — DNS

Both `colorbook.adisuresh.me` and `api.colorbook.adisuresh.me` need A records
pointing at the server's public IP. Verify after setting:

```sh
dig +short colorbook.adisuresh.me
dig +short api.colorbook.adisuresh.me
# Both should print your server's public IP.
```

If your home ISP rotates IPs, **don't** point DNS directly. Use Cloudflare
Tunnel (or Tailscale Funnel) — the server initiates the connection
outbound, no inbound port forwarding needed, and the IP doesn't matter:

```sh
# Cloudflare Tunnel skeleton
cloudflared tunnel create coloringbook
cloudflared tunnel route dns coloringbook colorbook.adisuresh.me
cloudflared tunnel route dns coloringbook api.colorbook.adisuresh.me
# Then run cloudflared as a systemd service, point the tunnel to localhost:8787 and the local Caddy.
```

---

## Step 6 — Smoke tests (server is up, DMG isn't built yet)

From any machine with `curl`:

```sh
# HTTPS endpoint should return the placeholder text from server.ts.
curl -i https://api.colorbook.adisuresh.me
# expect: HTTP/2 200, body "coloring-book server — connect via WebSocket"

# Signup over the live API
curl -X POST https://api.colorbook.adisuresh.me/auth/signup \
    -H 'Content-Type: application/json' \
    -d '{"username":"smoketest1","password":"hunter22-pw"}'
# expect: {"token":"...","user":{...}}
```

If both work, the backend is live. From your Mac, point the dev app at it:

```sh
cd macos-app
SERVER=https://api.colorbook.adisuresh.me swift run ColoringBook
```

Sign up with a real account; everything should behave the same as it does
locally.

---

## Step 7 — DMG (back on the Mac, not on the server)

Only after step 6 succeeds:

1. Edit `macos-app/Sources/ColoringBook/App.swift` — change the `SERVER`
   default from `http://localhost:8787` to
   `https://api.colorbook.adisuresh.me`. Commit.
2. On Mac:
   ```sh
   cd macos-app
   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
   NOTARY_PROFILE="coloringbook-notary" \
   bash scripts/build-app.sh && bash scripts/make-dmg.sh
   ```
3. Upload the DMG + landing page:
   ```sh
   scp dist/ColoringBook.dmg user@your-server:/opt/coloringbook-web/
   scp landing/index.html user@your-server:/opt/coloringbook-web/
   ```

(The landing-page HTML is a single static file — see the README for a
starter template.)

---

## Updating the server later

```sh
# On Mac
git push

# On server
cd /opt/coloring-book && sudo -u coloringbook git pull
cd server
sudo -u coloringbook npm ci    # only if package.json changed
sudo systemctl restart coloringbook
```

---

## Things that go wrong (with their fixes)

| Symptom | Likely cause | Fix |
|---|---|---|
| `npm ci` fails compiling `bcrypt` or `better-sqlite3` | Missing build tools | `sudo apt install -y build-essential python3` |
| `systemctl status coloringbook` shows "address in use" | Port 8787 already taken | Pick a new port, change unit + Caddy snippet, `daemon-reload` + reload |
| `caddy validate` fails | Bad domain in snippet | Real domain (lowercase, no spaces, A record exists) |
| Browser "ERR_SSL_…" on first visit | DNS not propagated yet | `dig` should resolve to your server first |
| App connects locally but `wss://` fails | Caddy not reverse-proxying | Curl the API endpoint, check Caddy logs (`journalctl -u caddy`) |
| Signup returns 500 | DB dir not writable by user | `chown -R coloringbook: /var/lib/coloringbook` |
| Two-finger pan etc. don't work in DMG | Camera/permissions need a real bundle | Don't run from `swift run` for camera; use the .app from `make-dmg` |
| DMG is "damaged" on a friend's Mac | Notarization failed or staple missing | Re-run `make-dmg.sh` with `NOTARY_PROFILE` set; check `xcrun notarytool log` |

---

## What this guide deliberately does NOT touch

- Your existing Caddy sites (we add a snippet via `import`, never edit your
  main config beyond the one `import` line).
- Other systemd units (we use a unique `coloringbook.service` name).
- Other users / groups.
- Anything in `/etc` outside the new files we explicitly create.
- Existing databases, configs, or data dirs.

If anything in step 0's pre-flight came up red, **stop and rename** before
going further. The whole guide assumes those names are free.
