# Boondock-Edge-Docker

Docker Compose deployment tooling for [Boondock-Edge-API](https://github.com/Boondock-Echo/Boondock-Edge-API)
and [Boondock-Edge-Dashboard](https://github.com/Boondock-Echo/Boondock-Edge-Dashboard), included here as git
submodules. The combined deployment runs Boondock-Edge-API as the single service — it serves both `/api/*`
and the dashboard UI itself from the same origin (matching how the bare-metal installer runs it) — behind a
Caddy reverse proxy that handles SSL automatically via Let's Encrypt. `docker-compose.api.yml` is also
available to run the API alone, with no dashboard UI at all.

## Layout

- `docker/api.Dockerfile` — build file for Boondock-Edge-API. Lives here rather than inside the submodule, so
  that repo stays untouched; `build.context` points at the submodule directory and `build.dockerfile` points
  back at this file.
- `docker/dashboard.Dockerfile` — builds the Boondock-Edge-Dashboard static bundle. It doesn't serve anything
  itself; it copies its build output into the shared data volume so the API can serve it (see
  `dashboard-build` in `docker-compose.yml`).
- `docker-compose.api.yml` — deploy the API alone, with no dashboard UI.
- `docker-compose.yml` — deploy the API (serving the dashboard UI itself) + Caddy together.
- `caddy/Caddyfile` — reverse proxy / TLS config for the combined deployment.
- `boondock.env.sample` — template for the single shared env file, `boondock.env`.

## Getting started

### 1. Clone with submodules

    git clone https://github.com/candrist/Boondock-Edge-Docker.git
    cd Boondock-Edge-Docker
    git submodule update --init --recursive

(This currently lives under `candrist`; it will move to `Boondock-Echo`
later, at which point this URL will be updated.)

If you have push access and want to push over SSH instead of HTTPS:

    git remote set-url --push origin git@github.com:candrist/Boondock-Edge-Docker.git

(If you already cloned without `--recursive`, just run the
`git submodule update --init --recursive` line above from the repo root.)

### 2. Configure environment

    cp boondock.env.sample boondock.env
    # Edit boondock.env: set DOMAIN, CADDY_EMAIL, and a real SECRET_KEY.

Generate a `SECRET_KEY` value and paste it into `boondock.env`:

    python3 -c "import secrets; print(secrets.token_hex(32))"

If you leave `SECRET_KEY` blank, the API auto-generates and persists one to
`$BOONDOCK_DATA_ROOT/db/.secret_key` on first boot instead — that works, but
setting it explicitly makes rotation easier to reason about later.

`boondock.env` is gitignored — never commit it.

### 3. Deploy

All commands must include `--env-file boondock.env` (Compose does not
auto-load a file with this name):

**Combined (API serving the dashboard UI + Caddy, with automatic HTTPS):**

    docker compose --env-file boondock.env -f docker-compose.yml up -d --build

Point `DOMAIN`'s DNS A/AAAA record at this host and ensure ports 80/443 are
reachable before starting, so Caddy can complete the Let's Encrypt HTTP-01
challenge. `FLASK_PORT` (default 4000) is also published directly on the
host, unproxied — open that in any firewall too if field Boondock Edge
devices need to reach the API directly over plain HTTP/WebSocket rather
than through Caddy.

**API only (no dashboard UI):**

    docker compose --env-file boondock.env -f docker-compose.api.yml up -d --build

If you're switching an existing deployment from an older version of this
repo that ran a separate `dashboard` container, add `--remove-orphans` to
the combined command above once, to clean up the now-unused container/image.

### 4. Create the first admin login

Boondock-Edge-API doesn't seed a default account — the admin login is
normally created by a one-time setup step (`manage.py setup`) that the
bare-metal installer runs automatically from `install.conf`'s
`ADMIN_EMAIL`/`ADMIN_PASSWORD`. This Docker setup doesn't run that step for
you, so without it there's nothing to log in with. Run it once, against
whichever compose file you deployed (swap `docker-compose.yml` for
`docker-compose.api.yml` if you're running the API standalone):

    docker compose --env-file boondock.env -f docker-compose.yml exec api sh -c '
      cat > /tmp/setup.json <<EOF
    {
      "admin": { "email": "you@example.com", "password": "ChangeMe123!" },
      "selected_devices": [],
      "wifi": {},
      "preferences": { "inbox_view": "continuous", "message_sorting": "newest" }
    }
    EOF
      python manage.py setup --config /tmp/setup.json
      rm -f /tmp/setup.json
    '

Replace the email and password (8+ characters) before running it. Log in to
the Dashboard with those credentials afterward. `selected_devices` is left
empty and `"wifi": {}` falls back to Boondock-Edge-API's internal-hotspot
defaults, since there's no real Boondock Edge hardware/Wi-Fi to configure
inside a container — see `load_setup()` in `Boondock-Edge-API/manage.py` for
the full schema if you need to change that.

`"wifi": {}` must be present (not omitted) here: `manage.py`'s
`load_setup()` has a bug where omitting `wifi` entirely crashes with
`KeyError: 'wifi'` (it only handles "wifi provided but invalid" vs "wifi
provided and valid", not "wifi missing") — passing an empty-but-present
object routes it into the same safe default-filling path without touching
Boondock-Edge-API's own code. Worth reporting upstream if you have a way to.

Re-running this command is safe (`manage.py setup` applies idempotently),
but note it always resets the admin password to whatever's in the
setup.json you pass, so don't re-run it casually once you've changed your
password from the Dashboard.

### Local/staging testing without real public DNS

Either:

- Temporarily add `acme_ca https://acme-staging-v02.api.letsencrypt.org/directory`
  inside the top-level `{ }` block of `caddy/Caddyfile` to avoid Let's Encrypt
  production rate limits while iterating, or
- Append `tls internal` inside the `{$DOMAIN} { ... }` site block to have
  Caddy mint a locally-trusted self-signed cert (works with a hostname added
  to `/etc/hosts` or a `*.localtest.me`-style domain, no real cert issuance).

### Updating the submodules

    git submodule update --remote --merge
    docker compose --env-file boondock.env -f docker-compose.yml up -d --build

This also rebuilds and re-copies the dashboard bundle via the `dashboard-build`
one-shot service, so a Dashboard-only update still takes effect even though
there's no long-running dashboard container to restart.

## Verification checklist

1. `docker build -f docker/api.Dockerfile -t boondock-edge-api:test ./Boondock-Edge-API`
2. `docker build -f docker/dashboard.Dockerfile -t boondock-edge-dashboard-build:test ./Boondock-Edge-Dashboard`
3. `docker compose --env-file boondock.env -f <each compose file> config` — validates interpolation before `up`.
4. `curl -s http://localhost:4000/api/health/system?current=true` against a running API container.
5. Load the Dashboard in a browser at `https://<DOMAIN>/`; confirm API calls in the Network tab go to
   relative `/api/...` (same origin, no CORS errors), a hard-refresh on a deep link (e.g. `/settings`) still
   renders, and a live-audio stream's WebSocket connects to `wss://<DOMAIN>/socket.io/...`.
6. `docker compose logs -f caddy` on first `up` — confirm ACME certificate issuance for `DOMAIN`.
7. `docker compose restart api` — confirm previously written recordings/db/users survive (validates the
   `boondock_api_data` volume).
8. `docker compose logs dashboard-build` — confirm it ran to completion (exit code 0) before `api` started;
   if the dashboard looks stale after an update, re-run `up -d --build` to force `dashboard-build` to rerun.
