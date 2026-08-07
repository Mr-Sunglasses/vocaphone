#!/bin/sh
set -eu

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/vocaphone"
token_file="$config_dir/token"

mkdir -p "$config_dir"
chmod 700 "$config_dir"
if [ ! -f "$token_file" ]; then
  umask 077
  openssl rand -base64 48 > "$token_file"
fi
chmod 600 "$token_file"
printf 'Token is stored at %s\n' "$token_file"
