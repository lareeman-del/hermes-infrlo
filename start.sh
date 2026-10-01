#!/bin/sh
# Render run command:  sh start.sh
# Installs hermes-agent (editable, from the vendored tarball) and Node.js
# (needed by the dashboard's terminal chat) if needed, then starts the
# Hermes Agent dashboard with a prebuilt web UI.
#
# NOTE: everything happens here at *runtime*, not in the Build command:
# the build step may run in a different working directory than the
# repo root, so pip cannot install there reliably.
set -eu

cd "$(dirname "$0")"
APP_DIR="$PWD"

# --- vendored hermes-agent source (tarball ships inside this repo) ---
if [ ! -f "$APP_DIR/hermes-src/hermes_cli/__init__.py" ]; then
  echo "Extracting hermes-src.tar.gz ..."
  mkdir -p "$APP_DIR/hermes-src"
  tar -xzf "$APP_DIR/hermes-src.tar.gz" -C "$APP_DIR/hermes-src"
fi

# --- python ---
PYBIN=""
for py in python3 python; do
  if command -v "$py" >/dev/null 2>&1; then PYBIN="$(command -v "$py")"; break; fi
done
if [ -z "$PYBIN" ]; then echo "ERROR: no python interpreter found" >&2; exit 1; fi

# --- install hermes-agent (editable) if not already importable ---
if ! "$PYBIN" -c "import hermes_cli" 2>/dev/null; then
  echo "Installing hermes-agent (editable, this takes a minute) ..."
  "$PYBIN" -m pip install -e "$APP_DIR/hermes-src[web]"
fi

# --- aiohttp (needed by the Hermes gateway's local API server; not in the [web] extra) ---
if ! "$PYBIN" -c "import aiohttp" 2>/dev/null; then
  echo "Installing aiohttp (for the Hermes gateway) ..."
  "$PYBIN" -m pip install "aiohttp==3.14.3"
fi

# --- make the installed `hermes` entry-point script reachable ---
USER_BIN="$("$PYBIN" -c 'import site, os; print(os.path.join(site.getuserbase(), "bin"))')"
export PATH="$USER_BIN:$PATH"

# --- node.js (the dashboard's terminal chat needs Node 18+) ---
# Official prebuilt binary, repo-local, no root needed.
NODE_VER="v24.21.0"
NODE_DIR="$APP_DIR/.node"
if [ ! -x "$NODE_DIR/bin/node" ]; then
  echo "Installing Node.js $NODE_VER (for dashboard terminal chat) ..."
  mkdir -p "$NODE_DIR" /tmp
  curl -fsSL "https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}-linux-x64.tar.xz" \
    -o /tmp/node-dist.tar.xz
  tar -xJf /tmp/node-dist.tar.xz -C "$NODE_DIR" --strip-components=1
  rm -f /tmp/node-dist.tar.xz
fi
export PATH="$NODE_DIR/bin:$PATH"
# The dashboard's terminal chat resolves node via $HERMES_NODE first, then
# $HERMES_HOME/node — a bare PATH export is not enough for its spawner.
export HERMES_NODE="$NODE_DIR/bin/node"
echo "DIAG: node $(node --version 2>/dev/null || echo MISSING)"

# --- memory trims for Render's 512MB free tier ---
# Each dashboard chat session spawns a Node TUI process; V8's default heap
# (~2GB on 64-bit) lets a single session push the whole box over Render's
# 512MB kill limit. Cap it — the TUI is a thin terminal client, it doesn't
# need more. Inherited by every child process (incl. the chat spawner).
export NODE_OPTIONS="--max-old-space-size=160"
# No .pyc writes on the ephemeral filesystem (minor disk/memory churn saver).
export PYTHONDONTWRITEBYTECODE=1
echo "DIAG: NODE_OPTIONS=$NODE_OPTIONS"

# Writable, repo-local home for hermes state/config.
export HERMES_HOME="${HERMES_HOME:-$APP_DIR/.hermes-home}"
mkdir -p "$HERMES_HOME"

# Prebuilt dashboard frontend (built locally with `npm run build` in web/).
export HERMES_WEB_DIST="$APP_DIR/web_dist"

# Prebuilt terminal-chat TUI bundle (built from ui-tui/ at tag v2026.9.24,
# vendored as tui-dist/dist/entry.js). The dashboard's chat spawns
# `node $HERMES_TUI_DIR/dist/entry.js`; without it the trimmed source has
# neither tui_dist/ nor ui-tui/ and the chat dies with a misleading
# "needs Node.js" message (any SystemExit maps to it).
export HERMES_TUI_DIR="$APP_DIR/tui-dist"

# --- model provider: reformboss gateway (custom OpenAI-compatible endpoint) ---
# Needs REFORMBOSS_API_KEY in the platform's env vars. Merged into
# $HERMES_HOME/config.yaml on every boot so the wiring survives the free
# tier's ephemeral filesystem. The default model is only set when the user
# hasn't picked one — a switch in the dashboard UI lasts until the next
# restart/redeploy.
if [ -n "${REFORMBOSS_API_KEY:-}" ]; then
  RB_BASE_URL="${REFORMBOSS_BASE_URL:-https://api.reformboss.com/v1}"
  RB_MODEL="${REFORMBOSS_MODEL:-deepseek-v4-pro}"
  "$PYBIN" - "$HERMES_HOME" "$RB_BASE_URL" "$RB_MODEL" <<'PYEOF' || \
    echo "WARNING: reformboss provider wiring failed, continuing without it"
import os, sys
home, base_url, default_model = sys.argv[1], sys.argv[2], sys.argv[3]
import yaml
cfg_path = os.path.join(home, "config.yaml")
cfg = {}
if os.path.exists(cfg_path):
    with open(cfg_path) as f:
        loaded = yaml.safe_load(f)
        cfg = loaded if isinstance(loaded, dict) else {}
providers = cfg.get("providers")
if not isinstance(providers, dict):
    providers = cfg["providers"] = {}
providers["reformboss"] = {"base_url": base_url, "key_env": "REFORMBOSS_API_KEY"}
model = cfg.get("model")
if not isinstance(model, dict):
    model = cfg["model"] = {}
if not model.get("default"):
    # provider = the named `providers:` entry (resolves with its base_url/key_env);
    # bare "custom" would show as unauthenticated in the model picker.
    model.update({"provider": "reformboss", "default": default_model,
                  "base_url": base_url, "key_env": "REFORMBOSS_API_KEY"})
with open(cfg_path, "w") as f:
    yaml.safe_dump(cfg, f, allow_unicode=True)
print("provider wiring OK: reformboss ->", cfg_path)
PYEOF
fi

# Basic-auth gate — mandatory for non-loopback binds since mid-2026.
export HERMES_DASHBOARD_BASIC_AUTH_USERNAME="${HERMES_DASHBOARD_BASIC_AUTH_USERNAME:-admin}"
if [ -z "${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD:-}" ]; then
  HERMES_DASHBOARD_BASIC_AUTH_PASSWORD="$("$PYBIN" -c 'import secrets; print(secrets.token_urlsafe(24))')"
  export HERMES_DASHBOARD_BASIC_AUTH_PASSWORD
  echo "NOTE: HERMES_DASHBOARD_BASIC_AUTH_PASSWORD was not set - generated one: $HERMES_DASHBOARD_BASIC_AUTH_PASSWORD"
fi
if [ -z "${HERMES_DASHBOARD_BASIC_AUTH_SECRET:-}" ]; then
  export HERMES_DASHBOARD_BASIC_AUTH_SECRET="$("$PYBIN" -c 'import secrets; print(secrets.token_urlsafe(32))')"
fi

PORT="${PORT:-8080}"
export PORT
if [ -z "${PORT+x}" ]; then
  echo "DIAG: PORT was NOT set by platform env; using default 8080"
else
  echo "DIAG: PORT from platform env: $PORT"
fi
echo "DIAG: port-ish env vars:"; printenv | grep -i -E 'port|host' | sed 's/=.*/=<set>/' || true
echo "Starting hermes dashboard on 0.0.0.0:$PORT ..."
if command -v hermes >/dev/null 2>&1; then
  exec hermes dashboard --no-open --skip-build --host 0.0.0.0 --port "$PORT"
else
  echo "WARNING: 'hermes' script not on PATH, invoking entry point directly"
  exec "$PYBIN" -c 'import sys, os; sys.argv=["hermes","dashboard","--no-open","--skip-build","--host","0.0.0.0","--port",os.environ["PORT"]]; from hermes_cli.main import main; sys.exit(main())'
fi
