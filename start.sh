#!/bin/sh
# Infrlo run command:  sh start.sh
# Installs hermes-agent (editable, from the vendored tarball) if needed,
# then starts the Hermes Agent dashboard with a prebuilt web UI
# (no Node/npm needed at runtime).
#
# NOTE: everything happens here at *runtime*, not in the Build command:
# the Infrlo build step runs in a different working directory than the
# repo root (and its build env has no git), so pip cannot install there.
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

# --- make the installed `hermes` entry-point script reachable ---
USER_BIN="$("$PYBIN" -c 'import site, os; print(os.path.join(site.getuserbase(), "bin"))')"
export PATH="$USER_BIN:$PATH"

# Writable, repo-local home for hermes state/config.
export HERMES_HOME="${HERMES_HOME:-$APP_DIR/.hermes-home}"
mkdir -p "$HERMES_HOME"

# Prebuilt dashboard frontend (built locally with `npm run build` in web/).
export HERMES_WEB_DIST="$APP_DIR/web_dist"

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
echo "Starting hermes dashboard on 0.0.0.0:$PORT ..."
if command -v hermes >/dev/null 2>&1; then
  exec hermes dashboard --no-open --skip-build --host 0.0.0.0 --port "$PORT"
else
  echo "WARNING: 'hermes' script not on PATH, invoking entry point directly"
  exec "$PYBIN" -c 'import sys, os; sys.argv=["hermes","dashboard","--no-open","--skip-build","--host","0.0.0.0","--port",os.environ["PORT"]]; from hermes_cli.main import main; sys.exit(main())'
fi
