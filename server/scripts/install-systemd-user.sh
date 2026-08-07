#!/bin/sh
# Install a systemd --user unit that keeps the native Linux gateway running.
# Requires: uv sync already done in server/ (creates .venv/bin/vocaphone-server).
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository=$(CDPATH= cd -- "$script_dir/../.." && pwd)
unit_name="com.vocahq.vocaphone.gateway.service"
template="$script_dir/$unit_name"
program="$repository/server/.venv/bin/vocaphone-server"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
destination="$unit_dir/$unit_name"

if [ ! -x "$program" ]; then
  printf 'Gateway executable not found at %s\nRun: cd server && uv sync --all-groups --extra engines\n' \
    "$program" >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  printf 'systemctl not found; this helper needs systemd.\n' >&2
  exit 1
fi

mkdir -p "$unit_dir"
escaped_repository=$(printf '%s' "$repository" | sed 's/[\/&]/\\&/g')
temporary=$(mktemp "${TMPDIR:-/tmp}/vocaphone-systemd.XXXXXX")
trap 'rm -f "$temporary"' EXIT
sed -e "s/__REPOSITORY__/$escaped_repository/g" "$template" > "$temporary"
mv "$temporary" "$destination"
trap - EXIT

systemctl --user daemon-reload
systemctl --user enable --now "$unit_name"

printf 'Installed and started %s\n' "$destination"
printf 'Status:  systemctl --user status %s\n' "$unit_name"
printf 'Logs:    journalctl --user -u %s -f\n' "$unit_name"
printf 'Stop:    systemctl --user stop %s\n' "$unit_name"
printf '\nTo keep the gateway running after logout, once per user:\n'
printf '  loginctl enable-linger %s\n' "$(id -un)"
