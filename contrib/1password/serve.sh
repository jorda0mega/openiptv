#!/usr/bin/env bash
# Start the OpenIPTV web server with logins read from 1Password at runtime.
# Values go straight into the server's memory; nothing is written to disk.
#
#   scripts/serve.sh --emby "Emby Connect" --xtream "My IPTV"        # this Mac only
#   scripts/serve.sh --emby "Emby Connect" --xtream "My IPTV" --lan  # + phone on Wi-Fi
#
# --emby takes an Emby Connect login item (username/password). Use
# --emby-server-url URL to treat it as a direct server login instead.
# --xtream takes a login item whose website or a field holds the server URL
# (or a full playlist link with username/password).
set -euo pipefail
cd "$(dirname "$0")/../.."

emby_item="" xtream_item="" emby_url="" lan=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --emby) emby_item=$2; shift 2 ;;
    --emby-server-url) emby_url=$2; shift 2 ;;
    --xtream) xtream_item=$2; shift 2 ;;
    --lan) lan=1; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

cargo build --quiet --release -p openiptv-edge
(cd web && { [[ -d node_modules ]] || npm install --no-audit --no-fund; } && npm run --silent build)

summary=$(mktemp -t openiptv-fields)
trap 'rm -f "$summary"' EXIT
items=""
retry() { for attempt in 1 2 3 4 5; do "$@" && return 0; echo "1Password step failed (attempt $attempt); approve the prompt in 1Password" >&2; sleep 2; done; return 1; }
list_items() { items=$(op item list --format json); }
retry list_items

if [[ -n "$xtream_item" ]]; then
  read -r _ xid < <(python3 -I contrib/1password/op_helper.py find "$xtream_item" <<<"$items")
  exports=""
  read_xtream() { exports=$(op item get "$xid" --format json | python3 -I contrib/1password/op_helper.py xtream "$summary"); }
  retry read_xtream
  eval "$exports"
  unset exports
  sed -n 's/^mapping: /xtream: /p' "$summary" >&2
fi

if [[ -n "$emby_item" ]]; then
  read -r vault eid < <(python3 -I contrib/1password/op_helper.py find "$emby_item" <<<"$items")
  if [[ -n "$emby_url" ]]; then
    export OPENIPTV_EMBY_URL="$emby_url"
    export OPENIPTV_EMBY_USER="op://$vault/$eid/username" OPENIPTV_EMBY_PASS="op://$vault/$eid/password"
  else
    export OPENIPTV_EMBY_CONNECT_USER="op://$vault/$eid/username" OPENIPTV_EMBY_CONNECT_PASS="op://$vault/$eid/password"
  fi
fi

[[ -n "$lan" ]] && export OPENIPTV_EDGE_ADDR="${OPENIPTV_EDGE_ADDR:-0.0.0.0:8787}"
exec op run -- ./target/release/openiptv-edge
