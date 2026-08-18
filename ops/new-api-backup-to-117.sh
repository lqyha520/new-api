#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

primary_container="new-api-postgres-1"
secondary="root@117.72.63.24"
secondary_port="22222"
ssh_key="/root/.ssh/new-api-backup_ed25519"
local_root="/opt/new-api-runtime/backups"
remote_root="/opt/new-api-backups"
local_only="${BACKUP_LOCAL_ONLY:-0}"
stamp="$(date -u +%Y%m%d-%H%M%S)"
work_dir="$(mktemp -d "$local_root/run.XXXXXX")"
status_file="$local_root/last-backup.status"
stage="starting"

mark_failed() {
  printf '%s\n' \
    "status=failed" \
    "stamp=$stamp" \
    "stage=$stage" \
    "error=${BASH_COMMAND:-unknown}" \
    "completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$status_file"
}
trap mark_failed ERR

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

mkdir -p "$local_root"

dump_file="$work_dir/new-api-$stamp.dump"
config_file="$work_dir/new-api-config-$stamp.tar.gz"

stage="pg_dump"
docker exec "$primary_container" pg_dump \
  -U root -d new-api --format=custom --no-owner > "$dump_file"

stage="archive_config"
tar -czf "$config_file" \
  --absolute-names \
  /opt/new-api-runtime/.env \
  /opt/new-api/docker-compose.deploy.yml \
  /www/server/panel/vhost/nginx/proxy/ai.bcxtech.cc.cd

if [ "$local_only" != "1" ]; then
  stage="upload"
  for attempt in 1 2 3 4 5; do
    if scp -P "$secondary_port" -i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=20 \
      -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
      "$dump_file" "$config_file" "$secondary:$remote_root/incoming/"; then
      break
    fi
    [ "$attempt" = 5 ] && exit 1
    sleep $((attempt * 5))
  done
fi

stage="finalize"
mv "$dump_file" "$config_file" "$local_root/"
find "$local_root" -maxdepth 1 -type f -mtime +7 -delete
printf '%s\n' \
  "status=success" \
  "stamp=$stamp" \
  "dump_name=$(basename "$dump_file")" \
  "config_name=$(basename "$config_file")" \
  "dump_size=$(stat -c %s "$local_root/$(basename "$dump_file")")" \
  "config_size=$(stat -c %s "$local_root/$(basename "$config_file")")" \
  "transfer=$([ "$local_only" = "1" ] && echo pending || echo direct)" \
  "completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$status_file"
trap - ERR
echo "Backup completed: $stamp"
