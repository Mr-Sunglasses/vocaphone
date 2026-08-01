#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository=$(CDPATH= cd -- "$script_dir/../.." && pwd)
destination="$HOME/Library/LaunchAgents/com.example.localflow.gateway.plist"
log_dir="$HOME/Library/Logs/LocalFlow"
template="$script_dir/com.example.localflow.gateway.plist"
program="$repository/server/.venv/bin/localflow-server"
domain="gui/$(id -u)"
service="$domain/com.example.localflow.gateway"

if [ ! -x "$program" ]; then
  printf 'Gateway executable not found at %s\nRun uv sync in server/ first.\n' "$program" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$log_dir"
escaped_repository=$(printf '%s' "$repository" | sed 's/[\/&]/\\&/g')
escaped_home=$(printf '%s' "$HOME" | sed 's/[\/&]/\\&/g')
temporary=$(mktemp "${TMPDIR:-/tmp}/localflow-launch-agent.XXXXXX")
trap 'rm -f "$temporary"' EXIT
sed \
  -e "s/__REPOSITORY__/$escaped_repository/g" \
  -e "s/__HOME__/$escaped_home/g" \
  "$template" > "$temporary"
mv "$temporary" "$destination"
trap - EXIT

launchctl bootout "$service" 2>/dev/null || true
remaining=50
while launchctl print "$service" >/dev/null 2>&1; do
  if [ "$remaining" -eq 0 ]; then
    printf 'Timed out waiting for the previous LaunchAgent to stop.\n' >&2
    exit 1
  fi
  remaining=$((remaining - 1))
  sleep 0.1
done
launchctl bootstrap "$domain" "$destination"
printf 'Installed and started %s\n' "$destination"
