#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository=$(CDPATH= cd -- "$script_dir/../.." && pwd)
destination="$HOME/Library/LaunchAgents/com.example.localflow.gateway.plist"
log_dir="$HOME/Library/Logs/LocalFlow"
template="$script_dir/com.example.localflow.gateway.plist"

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

launchctl bootout "gui/$(id -u)/com.example.localflow.gateway" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$destination"
printf 'Installed and started %s\n' "$destination"
