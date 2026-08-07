#!/bin/sh
set -eu

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/vocaphone"
token_file="$config_dir/token"
legacy_token="${LOCALFLOW_TOKEN_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/localflow/token}"
legacy_data="${XDG_DATA_HOME:-$HOME/.local/share}/localflow"

# Strip leading/trailing whitespace so " " is treated like an unset value,
# matching Settings.from_env().
trim() {
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

read_trimmed_file() {
  if [ -f "$1" ]; then
    # Avoid swallowing trailing newlines incorrectly: read whole file then trim.
    trim "$(cat "$1")"
  fi
}

mkdir -p "$config_dir"
chmod 700 "$config_dir"

existing="$(read_trimmed_file "$token_file")"
legacy_env="$(trim "${LOCALFLOW_TOKEN:-}")"
legacy_file_token="$(read_trimmed_file "$legacy_token")"

if [ -n "$existing" ]; then
  :
elif [ -n "$legacy_env" ]; then
  printf '%s\n' "$legacy_env" > "$token_file"
  printf 'Migrated Local Flow token from LOCALFLOW_TOKEN\n'
elif [ -n "$legacy_file_token" ]; then
  printf '%s\n' "$legacy_file_token" > "$token_file"
  printf 'Migrated Local Flow token from %s\n' "$legacy_token"
elif [ -d "$legacy_data" ] && [ -n "$(ls -A "$legacy_data" 2>/dev/null || true)" ]; then
  printf 'Found Local Flow data at %s but no bootstrap token.\n' "$legacy_data" >&2
  printf 'Copy %s to %s (or set VOCAPHONE_TOKEN) before minting a new secret so paired phones are not locked out.\n' \
    "$legacy_token" "$token_file" >&2
  exit 1
else
  umask 077
  openssl rand -base64 48 > "$token_file"
fi

chmod 600 "$token_file"
printf 'Token is stored at %s\n' "$token_file"
