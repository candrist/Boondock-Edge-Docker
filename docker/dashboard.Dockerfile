# syntax=docker/dockerfile:1
#
# Boondock-Edge-Dashboard production image: CRA build stage -> static nginx.
#
# Build context MUST be the Boondock-Edge-Dashboard submodule directory:
#   build:
#     context: ./Boondock-Edge-Dashboard
#     dockerfile: ../docker/dashboard.Dockerfile
#     args:
#       REACT_APP_EDGE_SERVER_ENDPOINT: ${REACT_APP_EDGE_SERVER_ENDPOINT}

# ---------- Stage 1: build the CRA static bundle ----------
FROM node:20-alpine AS build

WORKDIR /app

# CRA bakes REACT_APP_* vars into the JS bundle at BUILD time, not read at
# container runtime, so this MUST be a build ARG (see boondock.env.sample).
#
# IMPORTANT: every call site in this app (src/App.js, LoginPage.js,
# services/tagsService.js, etc.) builds request URLs as
# `${edgeServerEndpoint}/branding`, `${edgeServerEndpoint}/auth/login`, etc.
# The Flask API mounts those routes under /api/... , so this value MUST
# already include the /api suffix, e.g.:
#   REACT_APP_EDGE_SERVER_ENDPOINT=https://api.example.com/api
# Setting it to the bare host (https://api.example.com) will 404 every call.
ARG REACT_APP_EDGE_SERVER_ENDPOINT
ENV REACT_APP_EDGE_SERVER_ENDPOINT=${REACT_APP_EDGE_SERVER_ENDPOINT}

# NOTE: Boondock-Edge-Dashboard's .gitignore excludes package-lock.json and
# no lockfile is committed/present in the repo, so `npm ci` (which requires
# a lockfile) cannot be used here. `npm install` is used instead — this is
# less reproducible build-to-build than `npm ci`. Recommend the Dashboard
# repo commit a package-lock.json so this can be switched to `npm ci` later.
COPY package.json ./
RUN npm install --no-audit --no-fund

COPY . .
RUN npm run build

# ---------- Stage 2: serve the static bundle with nginx ----------
FROM nginx:1.27-alpine AS runtime

COPY --from=build /app/build /usr/share/nginx/html

# Minimal SPA config: fall back to index.html for client-side routing
# (react-router-dom) so refreshing on a deep link (e.g. /settings) works,
# plus a cheap /health endpoint for the container HEALTHCHECK / Caddy.
RUN cat > /etc/nginx/conf.d/default.conf <<'CONF'
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    gzip on;
    gzip_types text/plain text/css application/javascript application/json image/svg+xml;

    location = /health {
        default_type text/plain;
        return 200 'ok';
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
CONF

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://127.0.0.1:80/health >/dev/null 2>&1 || exit 1

CMD ["nginx", "-g", "daemon off;"]
