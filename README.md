# Boondock-Edge-Docker

Docker Compose deployment tooling for [Boondock-Edge-API](https://github.com/Boondock-Echo/Boondock-Edge-API)
and [Boondock-Edge-Dashboard](https://github.com/Boondock-Echo/Boondock-Edge-Dashboard), included here as git
submodules. Supports deploying either app independently, or both together behind a Caddy reverse proxy that
handles SSL automatically via Let's Encrypt.

## Layout

- `docker/api.Dockerfile`, `docker/dashboard.Dockerfile` — build files for the two apps. They live here rather
  than inside the submodules, so those repos stay untouched; `build.context` points at the submodule directory
  and `build.dockerfile` points back at these files.
- `docker-compose.api.yml` — deploy the API alone.
- `docker-compose.dashboard.yml` — deploy the Dashboard alone.
- `docker-compose.yml` — deploy API + Dashboard + Caddy together, with subdomain-based routing.
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
    # Edit boondock.env: set API_DOMAIN, APP_DOMAIN, CADDY_EMAIL,
    # REACT_APP_EDGE_SERVER_ENDPOINT (must end in /api), CORS_ALLOWED_ORIGINS,
    # and a real SECRET_KEY.

Generate a `SECRET_KEY` value and paste it into `boondock.env`:

    python3 -c "import secrets; print(secrets.token_hex(32))"

If you leave `SECRET_KEY` blank, the API auto-generates and persists one to
`$BOONDOCK_DATA_ROOT/db/.secret_key` on first boot instead — that works, but
setting it explicitly makes rotation easier to reason about later.

`boondock.env` is gitignored — never commit it.

### 3. Deploy

All commands must include `--env-file boondock.env` (Compose does not
auto-load a file with this name):

**API only:**

    docker compose --env-file boondock.env -f docker-compose.api.yml up -d --build

**Dashboard only:**

    docker compose --env-file boondock.env -f docker-compose.dashboard.yml up -d --build

**Combined (API + Dashboard + Caddy, with automatic HTTPS):**

    docker compose --env-file boondock.env -f docker-compose.yml up -d --build

Point `API_DOMAIN` and `APP_DOMAIN`'s DNS A/AAAA records at this host and
ensure ports 80/443 are reachable before starting the combined stack, so
Caddy can complete the Let's Encrypt HTTP-01 challenge.

### Local/staging testing without real public DNS

Either:

- Temporarily add `acme_ca https://acme-staging-v02.api.letsencrypt.org/directory`
  inside the top-level `{ }` block of `caddy/Caddyfile` to avoid Let's Encrypt
  production rate limits while iterating, or
- Append `tls internal` inside each site block to have Caddy mint
  locally-trusted self-signed certs (works with hostnames added to
  `/etc/hosts` or `*.localtest.me`-style domains, no real cert issuance).

### Updating the submodules

    git submodule update --remote --merge
    docker compose --env-file boondock.env -f docker-compose.yml up -d --build

## Verification checklist

1. `docker build -f docker/api.Dockerfile -t boondock-edge-api:test ./Boondock-Edge-API`
2. `docker build -f docker/dashboard.Dockerfile --build-arg REACT_APP_EDGE_SERVER_ENDPOINT=https://api.example.com/api -t boondock-edge-dashboard:test ./Boondock-Edge-Dashboard`
3. `docker compose --env-file boondock.env -f <each compose file> config` — validates interpolation before `up`.
4. `curl -s http://localhost:4000/api/health/system?current=true` against a running API container.
5. Load the Dashboard in a browser; confirm API calls in the Network tab go to `https://api.example.com/api/...`,
   a hard-refresh on a deep link (e.g. `/settings`) still renders, there are no CORS errors, and a live-audio
   stream's WebSocket connects to `wss://app.example.com/socket.io/...`.
6. `docker compose logs -f caddy` on first `up` — confirm ACME certificate issuance for both domains.
7. `docker compose restart api` — confirm previously written recordings/db/users survive (validates the
   `boondock_api_data` volume).
