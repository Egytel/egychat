# Deploying egychat (Chatwoot fork) on a fresh Ubuntu 24.04 Server

This guide documents every step required to get the **egychat** fork of Chatwoot
running on a freshly deployed **Ubuntu 24.04 LTS** server, using the official
installation script that ships in the repo (`deployment/setup_20.04.sh`, also
known as `cwctl`).

The process was verified against:

- OS: **Ubuntu 24.04.4 LTS** (`noble`)
- Branch: **`private/main`** (whitelabeled branch)
- Resources: 6 GB RAM, 8 vCPU, ~59 GB disk, running as `root`
- Chatwoot version reported by the script: **v4.16.2**

---

## 1. What the install script does

The script `deployment/setup_20.04.sh` performs a **native** (non-Docker)
installation and runs Chatwoot under `systemd`. The main entry point is
`install()` (triggered by `-i` / `-I <branch>`), which runs 9 steps:

| Step | What happens |
|------|--------------|
| 1/9 | Installs common dependencies via `apt` (git, Node.js 24, pnpm, image libs, etc.) |
| 2/9 | Installs databases: **PostgreSQL 16 + pgvector** and **Redis** |
| 3/9 | Installs webserver (Nginx + certbot) — *skipped unless you want domain + SSL* |
| 4/9 | Installs **RVM** and **Ruby 3.4.4** (for the `chatwoot` user) |
| 5/9 | Creates the `chatwoot` PostgreSQL role and enables Postgres/Redis services |
| 6/9 | Clones the repo, `git checkout` the branch, `bundle`, `pnpm i`, writes `.env`, precompiles assets |
| 7/9 | Runs DB migrations (`rails db:chatwoot_prepare`) |
| 8/9 | Installs the `chatwoot.target` systemd units (web + worker) and the `cwctl` CLI |
| 9/9 | SSL/TLS setup — *skipped* when no domain is provided |

At the end the app is reachable at **`http://<server-public-ip>:3000`**.

---

## 2. Prerequisites on a fresh Ubuntu 24.04

Boot the server and log in as `root` (or a user with `sudo`). Confirm the OS:

```bash
cat /etc/os-release
```

Only `git` was present out of the box; the script installs everything else.

> **Note:** The script is designed for Ubuntu 20.04/22.04/24.04 and must be run as
> **root**.

---

## 3. Get the repo (and the `private/main` branch)

```bash
cd /opt   # or any location you like
git clone https://github.com/Egytel/egychat.git
cd egychat
git fetch origin private/main
git checkout private/main
```

The whitelabeled branch `private/main` is the one we deploy.

---

## 4. Required adaptations to the install script

The stock `setup_20.04.sh` was written for the upstream `chatwoot/chatwoot`
repo. For this fork on Ubuntu 24.04, two one-line edits are required.

### 4.1 Point the clone at the fork (not upstream)

In `deployment/setup_20.04.sh`, inside `setup_chatwoot()`, the script clones the
**upstream** Chatwoot repo:

```bash
git clone https://github.com/chatwoot/chatwoot.git
```

Change it to clone **this** fork:

```bash
git clone https://github.com/Egytel/egychat.git chatwoot
```

> Why: `git checkout private/main` would otherwise fail, because the
> `private/main` branch only exists in the `Egytel/egychat` fork, not in
> `chatwoot/chatwoot`.

### 4.2 Fix the `libgdbm6` package for Ubuntu 24.04

In `install_dependencies()`, the package list contains `libgdbm6`, which **does
not exist** on Ubuntu 24.04 (it was renamed to `libgdbm6t64`). Without this fix,
`apt-get install` fails on a fresh 24.04 box.

Change:

```bash
libgmp-dev libncurses5-dev libffi-dev libgdbm6 libgdbm-dev sudo \
```

to:

```bash
libgmp-dev libncurses5-dev libffi-dev libgdbm6t64 libgdbm-dev sudo \
```

---

## 5. Run the installation

Run the script as **root**, telling it to install the `private/main` branch:

```bash
cd /opt/egychat
bash deployment/setup_20.04.sh -I private/main
```

The script is **interactive** and asks two questions:

```
Would you like to configure a domain and SSL for Chatwoot?(yes or no): no
Would you like to install Postgres and Redis? (Answer no if you plan to use external services)(yes or no): yes
```

- Answer **no** to domain + SSL when you want plain `http://<ip>:3000`.
- Answer **yes** to installing Postgres and Redis (local single-server setup).

All output is also logged to `/var/log/chatwoot-setup.log`:

```bash
tail -f /var/log/chatwoot-setup.log
```

> ⏱ The full install takes a long time (often 30–60 min): RVM + Ruby 3.4.4
> compilation, `bundle install`, `pnpm install`, and Rails asset precompilation
> are the slowest steps.

---

## 6. What gets installed on the server

After a successful run:

- **Ruby 3.4.4** via RVM, owned by the `chatwoot` system user
  (`/home/chatwoot/.rvm`)
- **Node.js 24** and **pnpm** (system-wide)
- **PostgreSQL 16** + **pgvector** with a `chatwoot` superuser role
- **Redis** (local)
- The app code at **`/home/chatwoot/chatwoot`** (checked out to `private/main`)
- Production environment at `/home/chatwoot/chatwoot/.env`
- **systemd units**: `chatwoot.target` (full: web + worker)
  - `chatwoot-web.1.service` — Rails web server on port **3000**
  - `chatwoot-worker.1.service` — Sidekiq background worker
- **`cwctl`** CLI installed to `/usr/local/bin/cwctl`

---

## 7. Verify the installation

Check the services are active:

```bash
systemctl status chatwoot.target
systemctl status chatwoot-web.1.service
systemctl status chatwoot-worker.1.service
```

Check the web server is listening and responding:

```bash
ss -ltnp | grep :3000          # ruby process listening on 0.0.0.0:3000
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000   # -> 302
curl -s -L http://localhost:3000 | grep -io '<title>[^<]*</title>'
# -> <title>SuperAdmin | Chatwoot</title>  (onboarding page, HTTP 200)
```

Confirm the production database was created:

```bash
sudo -i -u postgres psql -tAc "SELECT datname FROM pg_database WHERE datname='chatwoot_production';"
# -> chatwoot_production
```

Get the public IP and open the app in a browser:

```bash
curl http://checkip.amazonaws.com -s
# -> open http://<public-ip>:3000
```

On first visit you will be asked to create the admin account.

---

## 8. Managing the installation

The script installs `cwctl`, a CLI for day-to-day management:

```bash
cwctl --help          # show usage
cwctl --status        # deployment status
cwctl --restart       # restart the Chatwoot server
cwctl --logs web      # follow web logs
cwctl --logs worker   # follow worker logs
cwctl --console       # open a Rails console
cwctl -U private/main # upgrade from the private/main branch
```

Or use systemd directly:

```bash
systemctl restart chatwoot.target
journalctl -u chatwoot-web.1.service -f
```

---

## 9. Environment variables

The production `.env` is generated from `.env.example` by the script at
`/home/chatwoot/chatwoot/.env`. Key values set automatically:

| Variable | Value |
|----------|-------|
| `SECRET_KEY_BASE` | random 63-char value |
| `RAILS_ENV` | `production` |
| `NODE_ENV` | `production` |
| `REDIS_URL` | `redis://localhost:6379` |
| `POSTGRES_HOST` | `localhost` |
| `POSTGRES_USERNAME` | `chatwoot` |
| `POSTGRES_PASSWORD` | random (stored in `/opt/chatwoot/config/.pg_pass`) |
| `INSTALLATION_ENV` | `linux_script` |
| `FRONTEND_URL` | `http://<ip>:3000` (unless SSL configured) |

After editing `.env`, restart with `cwctl --restart`.

---

## 10. Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `apt-get install` fails on `libgdbm6` | Apply §4.2 (`libgdbm6` → `libgdbm6t64`) |
| `git checkout private/main` fails | Apply §4.1 (clone URL must point to the fork) |
| App not reachable at `:3000` | `systemctl status chatwoot-web.1.service`; check `journalctl -u chatwoot-web.1.service` |
| Port 3000 not reachable externally | Open the port in the cloud provider security group / `ufw` |
| Install fails partway | Logs are in `/var/log/chatwoot-setup.log`; re-run the script (it is idempotent for DB/RVM) |
