#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

primary_container="new-api-postgres-1"
secondary="root@117.72.63.24"
ssh_key="/root/.ssh/new-api-backup_ed25519"
local_root="/opt/new-api-runtime/backups"
remote_root="/opt/new-api-backups"
stamp="$(date -u +%Y%m%d-%H%M%S)"
work_dir="$(mktemp -d "$local_root/run.XXXXXX")"
status_file="$local_root/last-backup.status"

mark_failed() {
  printf '%s\n' \
    "status=failed" \
    "stamp=$stamp" \
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

docker exec "$primary_container" pg_dump \
  -U root -d new-api --format=custom --no-owner > "$dump_file"

tar -czf "$config_file" \
  --absolute-names \
  /opt/new-api-runtime/.env \
  /opt/new-api/docker-compose.deploy.yml \
  /www/server/panel/vhost/nginx/proxy/ai.bcxtech.cc.cd

scp -i "$ssh_key" -o BatchMode=yes \
  "$dump_file" "$config_file" "$secondary:$remote_root/incoming/"

mv "$dump_file" "$config_file" "$local_root/"
find "$local_root" -maxdepth 1 -type f -mtime +7 -delete
printf '%s\n' \
  "status=success" \
  "stamp=$stamp" \
  "dump_name=$(basename "$dump_file")" \
  "dump_size=$(stat -c %s "$local_root/$(basename "$dump_file")")" \
  "config_size=$(stat -c %s "$local_root/$(basename "$config_file")")" \
  "completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$status_file"
trap - ERR
echo "Backup completed: $stamp"
