# syntax=docker/dockerfile:1
#
# Boondock-Edge-Dashboard build image.
#
# This does NOT serve the dashboard itself — Boondock-Edge-API already has a
# built-in catch-all route (app/routes/react.py) that serves a React build
# from $BOONDOCK_DATA_ROOT/dashboard/, which is how the bare-metal installer
# runs it too (one service, one origin, no CORS). This image just builds the
# CRA bundle and, when run, copies it into that same shared volume so the
# API can serve it — see the one-shot "dashboard-build" service in
# docker-compose.yml, which mounts boondock_api_data at /data before the api
# service starts.
#
# Build context MUST be the Boondock-Edge-Dashboard submodule directory:
#   build:
#     context: ./Boondock-Edge-Dashboard
#     dockerfile: ../docker/dashboard.Dockerfile
#     args:
#       DISABLE_ESLINT_PLUGIN: ${DISABLE_ESLINT_PLUGIN:-true}

FROM node:20-alpine AS build

WORKDIR /app

# REACT_APP_EDGE_SERVER_ENDPOINT is deliberately left unset here: every call
# site in this app (src/App.js, LoginPage.js, services/tagsService.js, etc.)
# falls back to the relative path '/api' when it's unset, which is exactly
# right now that the API serves the dashboard from the same origin — no
# cross-origin URL needs to be baked in at build time.

# NOTE: Boondock-Edge-Dashboard's .gitignore excludes package-lock.json and
# no lockfile is committed/present in the repo, so `npm ci` (which requires
# a lockfile) cannot be used here. `npm install` is used instead — this is
# less reproducible build-to-build than `npm ci`. Recommend the Dashboard
# repo commit a package-lock.json so this can be switched to `npm ci` later.
COPY package.json ./
RUN npm install --no-audit --no-fund

COPY . .

# tsconfig.json in this repo is a stray leftover from an unrelated Next.js
# project (paths point at "../frontendv2-nextbckp", plugins: [{"name":
# "next"}]) — there are no .ts/.tsx files and nothing in src/ imports its
# "@/"/"@legacy/" path aliases. Its mere presence still makes
# react-scripts' config/modules.js require the "typescript" package (which
# isn't installed), failing the build with "Cannot find module
# 'typescript'". Removing it from this build-stage copy only (the submodule
# itself is untouched) restores plain-JS CRA behavior.
RUN rm -f tsconfig.json

# Without a committed package-lock.json (see note above), `npm install`
# resolves a fresh dependency tree each build, which can pull in an eslint
# version newer than the one react-scripts 5's bundled
# eslint-config-react-app was tested against. That mismatch makes the build
# fail with "eslint-config-react-app/jest#overrides[0]: Environment key
# 'jest/globals' is unknown" — a lint-config version-drift issue, not an
# actual problem in this app's code. DISABLE_ESLINT_PLUGIN is CRA's
# supported flag to skip ESLint checking during the production build;
# webpack/Babel still fail the build on real syntax/type errors. Sourced
# from boondock.env (next to PRODUCTION_MODE) as a build arg so it can be
# flipped back to false without editing this Dockerfile, once the Dashboard
# repo pins compatible eslint versions.
ARG DISABLE_ESLINT_PLUGIN=true
ENV DISABLE_ESLINT_PLUGIN=${DISABLE_ESLINT_PLUGIN}
RUN npm run build

VOLUME /data

# Wipe any previous build's output first (SPA static assets are
# content-hashed per file, e.g. main.a1b2c3.js — without this, old hashed
# chunks from prior builds would just accumulate under /data/dashboard
# forever) before copying the fresh build in.
CMD ["sh", "-c", "rm -rf /data/dashboard && mkdir -p /data/dashboard && cp -a /app/build/. /data/dashboard/"]
