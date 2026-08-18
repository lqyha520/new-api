#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

root="/opt/new-api-backups"
incoming="$root/incoming"
archives="$root/archives"
state="$root/state"
container="new-api-postgres-1"
status_file="$state/last-restore.status"
stage="starting"

mark_failed() {
  printf '%s\n' \
    "status=failed" \
    "stage=$stage" \
    "error=${BASH_COMMAND:-unknown}" \
    "completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$status_file"
}
trap mark_failed ERR

mkdir -p "$incoming" "$archives" "$state"
dump_file="$(find "$incoming" -maxdepth 1 -type f -name 'new-api-*.dump' -mmin +2 -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2- || true)"
[ -n "$dump_file" ] || exit 0

stamp="$(basename "$dump_file" .dump)"
marker="$state/last-restored"
[ "$(cat "$marker" 2>/dev/null || true)" = "$stamp" ] && exit 0

stage="copy_dump"
docker cp "$dump_file" "$container:/tmp/$stamp.dump"
stage="pg_restore"
docker exec "$container" pg_restore \
  --clean --if-exists --no-owner --exit-on-error \
  -U root -d new-api "/tmp/$stamp.dump"
stage="archive"
docker exec "$container" rm -f "/tmp/$stamp.dump"

mv "$dump_file" "$archives/"
config_file="$incoming/new-api-config-${stamp#new-api-}.tar.gz"
[ -f "$config_file" ] && mv "$config_file" "$archives/"
printf '%s\n' "$stamp" > "$marker"
find "$archives" -type f -mtime +30 -delete
printf '%s\n' \
  "status=success" \
  "restored=$stamp" \
  "completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$status_file"
trap - ERR
echo "Restored backup: $stamp"
