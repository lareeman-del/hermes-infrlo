#!/bin/sh
# Infrlo run command:  sh start.sh
# Starts the Hermes Agent dashboard with a prebuilt web UI
# (no Node/npm needed at runtime).
set -eu

cd "$(dirname "$0")"
APP_DIR="$PWD"

# Hermes source tree (vendored as a tarball: Infrlo's build env has no git,
# so pip cannot clone it — extract here, installed editable at build time).
if [ ! -f "$APP_DIR/hermes-src/hermes_cli/__init__.py" ]; then
  echo "Extracting hermes-src.tar.gz ..."
  mkdir -p "$APP_DIR/hermes-src"
  tar -xzf "$APP_DIR/hermes-src.tar.gz" -C "$APP_DIR/hermes-src"
fi

# Find the python that has hermes_cli installed (the build env's python).
PYBIN=""
for py in python3 python; do
  if command -v "$py" >/dev/null 2>&1 && "$py" -c "import hermes_cli" 2>/dev/null; then
    PYBIN="$(command -v "$py")"
    break
  fi
done
if [ -z "$PYBIN" ]; then
  echo "ERROR: no python interpreter with hermes_cli installed was found" >&2
  exit 1
fi
export PATH="$("$PYBIN" -c 'import sysconfig; print(sysconfig.get_path("scripts"))'):$PATH"

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
echo "Starting hermes dashboard on 0.0.0.0:$PORT ..."
exec hermes dashboard --no-open --skip-build --host 0.0.0.0 --port "$PORT"
