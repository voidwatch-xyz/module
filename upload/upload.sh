#!/bin/sh
# Voidwatch upload script for macOS and Linux (also for clients that run through Wine or CrossOver).
# It sends what the module writes and brings back the replies. MIT licence.
#   sh upload.sh "<the voidwatch folder in the client's write directory>"
# The module shows the exact folder in a game message.
set -u
API=${VOIDWATCH_API:-https://voidwatch.xyz/api/v1}
HOME_DIR="$HOME/Library/Application Support/Voidwatch"
[ -d "$HOME_DIR" ] || HOME_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/voidwatch"

# Without a folder: watch every client on this computer. The usual places are searched every 30 s, plus the folders
# listed in folders.txt next to this script (setup adds the one you drag in). Each client gets its own worker.
if [ $# -eq 0 ]; then
  mkdir -p "$HOME_DIR"
  while :; do
    for d in "$HOME/Library/Application Support/OTClientV8"/*/voidwatch "$HOME/.otclientv8"/*/voidwatch "$HOME/.local/share/otclientv8"/*/voidwatch \
             "$HOME/Library/Application Support/CrossOver/Bottles"/*/drive_c/users/*/AppData/Roaming/OTClientV8/*/voidwatch \
             "$HOME/.wine/drive_c/users"/*/AppData/Roaming/OTClientV8/*/voidwatch; do
      [ -d "$d/outbox" ] && printf '%s\n' "$d"
    done > "$HOME_DIR/.found" 2>/dev/null
    [ -f "$HOME_DIR/folders.txt" ] && cat "$HOME_DIR/folders.txt" >> "$HOME_DIR/.found"
    while IFS= read -r d; do
      [ -d "$d" ] || continue
      pid=$(cat "$d/.pid" 2>/dev/null || echo 0)
      kill -0 "$pid" 2>/dev/null || { sh "$0" "$d" >/dev/null 2>&1 & echo $! > "$d/.pid"; }
    done < "$HOME_DIR/.found"
    sleep 30
  done
fi
DIR=$1
OUT="$DIR/outbox" IN="$DIR/inbox" TOKEN_FILE="$DIR/.token"
[ -f "$TOKEN_FILE" ] && chmod 600 "$TOKEN_FILE"
mkdir -p "$IN"
last_capture=0 last_status=0 last_minimap=0 minimap_check=0 status_every=30

auth() { printf 'Authorization: Bearer %s' "$(cat "$TOKEN_FILE")"; }
post_json() { curl -fsS -m 10 -X POST -H "Content-Type: application/json" -H "$(auth)" --data-binary "@$2" "$API$1"; }
field() { printf '%s' "$1" | sed -n "s/.*\"$2\":\([0-9a-z]*\).*/\1/p"; }
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }

send_status() {
  reply=$(post_json /status "$OUT/status.json") || return
  printf '%s' "$reply" > "$IN/reply.json"
  printf '{"paired":true}' > "$IN/pair.json"
  status_every=$(field "$reply" statusEvery); status_every=${status_every:-30}
  last_status=$(date +%s)
  case "$reply" in *'"commands":0'*) ;; *)
    curl -fsS -m 10 -H "$(auth)" "$API/commands" > "$IN/commands.json.tmp" && mv "$IN/commands.json.tmp" "$IN/commands.json" ;;
  esac
  case "$reply" in *'"minimap":false'*) minimap_on=0 ;; *) minimap_on=1 ;; esac
}

while :; do
  if [ ! -s "$TOKEN_FILE" ]; then
    if [ -f "$OUT/pair-request.json" ]; then
      reply=$(curl -fsS -m 10 -X POST -H "Content-Type: application/json" --data-binary "@$OUT/pair-request.json" "$API/pair") && {
        (umask 077; printf '%s' "$reply" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' > "$TOKEN_FILE")
        printf '%s' "$reply" | sed 's/"token":"[^"]*",\{0,1\}//' > "$IN/pair.json"
      }
    fi
    sleep 1
    continue
  fi
  now=$(date +%s)
  if [ -f "$OUT/status.json" ] && [ $((now - last_status)) -ge "$status_every" ]; then send_status; fi
  if [ -f "$OUT/capture.png" ]; then
    m=$(mtime "$OUT/capture.png")
    if [ "$m" != "$last_capture" ]; then
      curl -fsS -m 20 -X POST -H "Content-Type: image/png" -H "$(auth)" --data-binary "@$OUT/capture.png" "$API/capture" >/dev/null && last_capture=$m
    fi
  fi
  if [ -f "$OUT/results.json" ]; then
    # one result per command: {"id":1,"ok":true,"message":"..."}
    sed 's/},{/}\n{/g; s/^\[//; s/\]$//' "$OUT/results.json" | while IFS= read -r r; do
      id=$(printf '%s' "$r" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
      [ -n "$id" ] && printf '%s' "$r" > "$OUT/.result" && post_json "/commands/$id/result" "$OUT/.result" >/dev/null
    done
    rm -f "$OUT/results.json" "$OUT/.result"
  fi
  # the client's own minimap, one folder up; it changes slowly, so look at it once a minute
  if [ "${minimap_on:-1}" = 1 ] && [ $((now - minimap_check)) -ge 60 ]; then
    minimap_check=$now
    map="" best=0
    for f in "$DIR"/../minimap*.otmm; do
      [ -f "$f" ] || continue
      m=$(mtime "$f"); if [ "$m" -gt "$best" ]; then map=$f best=$m; fi
    done
    if [ -n "$map" ] && [ "$best" != "$last_minimap" ]; then
      curl -fsS -m 60 -X POST -H "Content-Type: application/octet-stream" -H "$(auth)" --data-binary "@$map" "$API/minimap" >/dev/null \
        && last_minimap=$(mtime "$map")
    fi
  fi
  if [ "$status_every" -le 2 ]; then
    sleep 1
  else
    # wait until someone opens the character, an alert fires or a command arrives; returns at once when that happens
    reply=$(curl -fsS -m 30 -H "$(auth)" "$API/wait?timeout=25") && case "$reply" in *'"wake":true'*) last_status=0 ;; esac
  fi
done
