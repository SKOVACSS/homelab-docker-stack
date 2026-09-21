#!/usr/bin/env bash
# Validates every stack's docker-compose.yml: checks it's syntactically
# valid YAML/Compose, and that every ${VAR} it references is documented in
# .env.example (using dummy values, since CI has no real secrets). This is
# the exact manual process that caught this repo's original YAML bugs and
# the GUI installer's variable-name mismatches - run on every push so a
# future change can't silently reintroduce either class of bug.
#
# Most stacks only need --env-file for this (no on-disk changes at all).
# immich-app's compose file uses `env_file:`, which Compose reads straight
# off disk regardless of --env-file, so for that one stack this script
# briefly swaps in a dummy .env and restores your real one immediately
# after - do not Ctrl-C the script while it's on that stack.
#
# Usage: _scripts/validate-stacks.sh   (run from anywhere; finds repo root itself)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

STACKS="caddy authentik media-stack privacy-stack security-stack email-stack monitoring-stack notification-stack utilities immich-app dashboard dns-stack"
ENV_EXAMPLE=".env.example"

# Self-heal from a previous run that got interrupted before it could
# restore a real .env it had swapped out (see the incident this comment
# is here because of - CHANGELOG.md's 1.0.1 entry).
for stack in $STACKS; do
  leftover="$stack/.env.validate-stacks-backup"
  if [ -f "$leftover" ]; then
    echo "Found $leftover from an interrupted previous run - restoring it to $stack/.env before continuing."
    mv "$leftover" "$stack/.env"
  fi
done

FAILED=0

for stack in $STACKS; do
  echo "=== $stack ==="
  compose="$stack/docker-compose.yml"

  if [ ! -f "$compose" ]; then
    echo "  FAIL: $compose does not exist"
    FAILED=1
    continue
  fi

  # Build the test .env from this stack's section of .env.example, using
  # its real example values as-is (e.g. "8080", "./library",
  # "D:\Media\Movies") rather than a generic placeholder - values matter
  # here: a bare placeholder like "dummyvalue123" isn't a valid port
  # number, and reads as a *named volume* rather than a bind-mount path,
  # which would make this script fail on inputs that are actually fine.
  # Strips trailing "# comment" portions, which .env.example uses but a
  # real .env must not.
  dummy_content=$(awk -v marker="# ===== $stack/.env =====" '
    $0 == marker { grab=1; next }
    /^# =====/ && grab { grab=0 }
    grab && /^[A-Za-z_][A-Za-z0-9_]*=/ {
      sub(/[ \t]+#.*/, "")
      print
    }
  ' "$ENV_EXAMPLE")

  if [ -z "$dummy_content" ]; then
    echo "  WARN: no '# ===== $stack/.env =====' section found in $ENV_EXAMPLE - skipping var-completeness check"
  fi

  needs_on_disk_env=$(grep -c "env_file:" "$compose" 2>/dev/null || true)
  dummy_file=$(mktemp)
  echo "$dummy_content" > "$dummy_file"

  real_env="$stack/.env"
  swapped=0
  if [ "$needs_on_disk_env" -gt 0 ]; then
    if [ -f "$real_env" ]; then
      cp "$real_env" "$real_env.validate-stacks-backup"
    fi
    cp "$dummy_file" "$real_env"
    swapped=1
  fi

  output=$(docker compose -f "$compose" --env-file "$dummy_file" config 2>&1 >/dev/null)
  exit_code=$?
  rm -f "$dummy_file"

  if [ "$swapped" -eq 1 ]; then
    if [ -f "$real_env.validate-stacks-backup" ]; then
      mv "$real_env.validate-stacks-backup" "$real_env"
    else
      rm -f "$real_env"
    fi
  fi

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
