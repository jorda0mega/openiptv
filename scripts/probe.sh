#!/usr/bin/env bash
# Run openiptv-probe against your own Emby server and Xtream provider.
# Prompts for anything not already in the environment; passwords are read
# without echo and never written to disk or shell history.
set -euo pipefail
cd "$(dirname "$0")/.."

ask() { # ask VAR "Prompt" [secret]
  local var=$1 prompt=$2 secret=${3:-}
  if [[ -z "${!var:-}" ]]; then
    if [[ -n "$secret" ]]; then read -rsp "$prompt: " "${var?}"; echo; else read -rp "$prompt: " "${var?}"; fi
  fi
  export "${var?}"
}

echo "Leave a prompt blank to skip it."
ask OPENIPTV_EMBY_CONNECT_USER "Emby Connect username or email (blank to enter a server URL instead)"
if [[ -n "$OPENIPTV_EMBY_CONNECT_USER" ]]; then
  ask OPENIPTV_EMBY_CONNECT_PASS "Emby Connect password" secret
else
  ask OPENIPTV_EMBY_URL "Emby server URL (e.g. https://emby.example.com)"
  if [[ -n "$OPENIPTV_EMBY_URL" ]]; then
    ask OPENIPTV_EMBY_USER "Emby username"
    ask OPENIPTV_EMBY_PASS "Emby password" secret
  fi
fi
ask OPENIPTV_XTREAM_URL "Xtream server URL (e.g. http://line.example.com:8080)"
if [[ -n "$OPENIPTV_XTREAM_URL" ]]; then
  ask OPENIPTV_XTREAM_USER "Xtream username"
  ask OPENIPTV_XTREAM_PASS "Xtream password" secret
fi

cargo run --quiet --release -p openiptv-probe -- "$@"
