#!/usr/bin/env bash
# Validates every stack's docker-compose.yml: checks it's syntactically
# valid YAML/Compose, and that every ${VAR} it references is documented in
# .env.example (using dummy values, since CI has no real secrets). This is
# the exact manual process that caught this repo's original YAML bugs and
# the GUI installer's variable-name mismatches - run on every push so a
# future change can't silently reintroduce either class of bug.
#
# Usage: _scripts/validate-stacks.sh   (run from anywhere; finds repo root itself)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

STACKS="caddy authentik media-stack privacy-stack security-stack email-stack monitoring-stack notification-stack utilities immich-app"
ENV_EXAMPLE=".env.example"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

FAILED=0

for stack in $STACKS; do
  echo "=== $stack ==="
  compose="$stack/docker-compose.yml"

  if [ ! -f "$compose" ]; then
    echo "  FAIL: $compose does not exist"
    FAILED=1
    continue
  fi

  # Build a test .env from this stack's section of .env.example, using its
  # real example values as-is (e.g. "8080", "./library", "D:\Media\Movies")
  # rather than a generic placeholder - values matter here: a bare
  # placeholder like "dummyvalue123" isn't a valid port number, and reads
  # as a *named volume* rather than a bind-mount path, which would make
  # this script fail on inputs that are actually fine. Strips trailing
  # "# comment" portions, which .env.example uses but a real .env must not.
  dummy_env="$TMPDIR/$stack.env"
  awk -v marker="# ===== $stack/.env =====" '
    $0 == marker { grab=1; next }
    /^# =====/ && grab { grab=0 }
    grab && /^[A-Za-z_][A-Za-z0-9_]*=/ {
      sub(/[ \t]+#.*/, "")
      print
    }
  ' "$ENV_EXAMPLE" > "$dummy_env"

  if [ ! -s "$dummy_env" ]; then
    echo "  WARN: no '# ===== $stack/.env =====' section found in $ENV_EXAMPLE - skipping var-completeness check"
  fi

  output=$(docker compose -f "$compose" --env-file "$dummy_env" config 2>&1 >/dev/null)
  exit_code=$?

  if [ $exit_code -ne 0 ]; then
    echo "  FAIL: docker compose config failed"
    echo "$output" | sed 's/^/    /'
    FAILED=1
    continue
  fi

  missing=$(echo "$output" | grep -oE '[A-Za-z_][A-Za-z0-9_]*\\?" variable is not set' | sed 's/\\\?" variable is not set//' | sort -u)
  if [ -n "$missing" ]; then
    echo "  FAIL: referenced but not documented in $ENV_EXAMPLE:"
    echo "$missing" | sed 's/^/    /'
    FAILED=1
    continue
  fi

  echo "  OK"
done

echo ""
if [ $FAILED -ne 0 ]; then
  echo "One or more stacks failed validation."
  exit 1
fi
echo "All stacks valid."
