#!/bin/sh
# Voidwatch upload script for macOS and Linux (also for clients that run through Wine or CrossOver).
# It sends what the module writes and brings back the replies. MIT licence.
#   sh upload.sh                          watch every client in the usual places and in folders.txt
#   sh upload.sh "<voidwatch folder>"     watch one client: the folder the module shows in a game message
# Every character has its own folder inside the voidwatch folder, and its own worker.
set -u
API=${VOIDWATCH_API:-https://voidwatch.xyz/api/v1}

if [ "${1:-}" != --worker ]; then
  HOME_DIR="$HOME/Library/Application Support/Voidwatch"
  [ -d "$HOME_DIR" ] || HOME_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/voidwatch"
  while :; do
    if [ $# -gt 0 ]; then
      found=$1
    else
      found=$(
        for d in "$HOME/Library/Application Support/OTClientV8"/*/voidwatch "$HOME/.otclientv8"/*/voidwatch \
                 "$HOME/.local/share/otclientv8"/*/voidwatch \
                 "$HOME/Library/Application Support/CrossOver/Bottles"/*/drive_c/users/*/AppData/Roaming/OTClientV8/*/voidwatch \
                 "$HOME/.wine/drive_c/users"/*/AppData/Roaming/OTClientV8/*/voidwatch; do
          [ -d "$d" ] && printf '%s\n' "$d"
        done
        [ -f "$HOME_DIR/folders.txt" ] && cat "$HOME_DIR/folders.txt"
      )
    fi
    printf '%s\n' "$found" | while IFS= read -r d; do
      for c in "${d%/}"/*/outbox; do
        [ -d "$c" ] || continue
        c=${c%/outbox}
        pid=$(cat "$c/.pid" 2>/dev/null)
        [ "${pid:-0}" -gt 0 ] && kill -0 "$pid" 2>/dev/null && continue
        sh "$0" --worker "$c" >/dev/null 2>&1 &
        echo $! > "$c/.pid"
      done
    done
    sleep 2
  done
fi

DIR=${2%/}
OUT="$DIR/outbox" IN="$DIR/inbox" TOKEN_FILE="$DIR/.token" AUTH="$DIR/.auth" BODY="$DIR/.body"
SENT_MAP="$DIR/../.minimap-sent"
mkdir -p "$IN"
last_sent=0 minimap_check=0 status_every=30 refused=0 minimap_on=1 wake=0 said=""
# a game client that runs through Wine reports Windows: the website takes the system from here
case $(uname -s 2>/dev/null) in
  Darwin) host_os=macOS ;;
  Linux) host_os=Linux ;;
  *) host_os="" ;;
esac
# the token travels in a header file, so it never shows in the process list
if [ -s "$TOKEN_FILE" ]; then
  chmod 600 "$TOKEN_FILE"
  (umask 077; printf 'Authorization: Bearer %s\n' "$(cat "$TOKEN_FILE")" > "$AUTH")
fi

# one line per change of state, never the token or the code
note() {
  [ "$1" = "$said" ] && return
  said=$1
  [ "$(wc -c < "$DIR/upload.log" 2>/dev/null || echo 0)" -gt 100000 ] && mv -f "$DIR/upload.log" "$DIR/upload.log.1"
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$DIR/upload.log"
}

# request METHOD PATH [curl options]: the answer goes to $BODY, the HTTP status to stdout (000 without a connection)
request() {
  m=$1 p=$2
  shift 2
  if [ -s "$AUTH" ]; then set -- -H "@$AUTH" "$@"; fi
  curl -sS -m 30 -o "$BODY" -w '%{http_code}' -X "$m" "$@" "$API$p" 2>/dev/null
}

field() { sed -n "s/.*\"$2\": *\([0-9a-z]*\).*/\1/p" "$1" 2>/dev/null | head -n 1; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
# the client writes a screenshot on the next frame: send it only once its first and last bytes are there
whole_png() { [ "$(head -c 8 "$1" | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ] && tail -c 12 "$1" | LC_ALL=C grep -q IEND; }
put() { printf '%s' "$2" > "$1.tmp" && mv -f "$1.tmp" "$1"; }

unpair() {
  note "$1, asking for a new code"
  rm -f "$TOKEN_FILE" "$AUTH" "$IN/pair.json" "$IN/reply.json"
  refused=0
}

revoked() { grep -q '"detail":"revoked client"' "$BODY" 2>/dev/null; }

on_refused() {
  refused=$((refused + 1))
  if grep -q '"paired":true' "$IN/pair.json" 2>/dev/null; then
    [ "$refused" -ge 3 ] && unpair "the website refused this client"
  else
    expires=$(field "$IN/pair.json" expiresAt)
    if [ -z "$expires" ] || [ "$now" -gt "$expires" ]; then unpair "the code expired"; else note "waiting until the code is used"; fi
  fi
}

while [ -d "$DIR" ]; do
  now=$(date +%s)
  if [ ! -s "$TOKEN_FILE" ]; then
    if [ -f "$OUT/pair-request.json" ]; then
      code=$(request POST /pair -m 10 -H "Content-Type: application/json" -H "X-Voidwatch-OS: $host_os" --data-binary "@$OUT/pair-request.json")
      token=$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "$BODY" 2>/dev/null)
      if [ "$code" = 200 ] && [ -n "$token" ]; then
        (umask 077; printf '%s' "$token" > "$TOKEN_FILE"; printf 'Authorization: Bearer %s\n' "$token" > "$AUTH")
        put "$IN/pair.json" "$(sed 's/"token":"[^"]*",\{0,1\}//' "$BODY")"
        note "got a pairing code"
      else
        note "pairing failed: HTTP $code $(head -c 200 "$BODY" 2>/dev/null)"
        sleep 30
      fi
    fi
    sleep 1
    continue
  fi

  age=999999
  if [ -f "$OUT/status.json" ]; then
    m=$(mtime "$OUT/status.json")
    age=$((now - m))
    # an old file is left from a closed client: sending it would show the character online
    if [ "$age" -lt 90 ] && { [ "$m" != "$last_sent" ] || [ "$wake" = 1 ]; }; then
      wake=0
      code=$(request POST /status -m 10 -H "Content-Type: application/json" --data-binary "@$OUT/status.json")
      case $code in
        200)
          last_sent=$m refused=0
          mv -f "$BODY" "$IN/reply.json"
          grep -q '"paired":true' "$IN/pair.json" 2>/dev/null || { put "$IN/pair.json" '{"paired":true}'; note "paired"; }
          status_every=$(field "$IN/reply.json" statusEvery)
          status_every=${status_every:-30}
          case $(cat "$IN/reply.json") in *'"minimap":false'*) minimap_on=0 ;; *) minimap_on=1 ;; esac
          if [ "$(field "$IN/reply.json" commands)" != 0 ] && [ "$(request GET /commands -m 10)" = 200 ]; then
            mv -f "$BODY" "$IN/commands.json"
          fi
          note "sending"
          ;;
        401)
          if revoked; then
            unpair "removed on the website"
            continue
          fi
          on_refused
          sleep 5
          continue
          ;;
        422)
          last_sent=$m
          note "the website refused a status: $(head -c 300 "$BODY")"
          ;;
        *)
          note "status failed: HTTP $code"
          sleep 5
          continue
          ;;
      esac
    fi
  fi

  if [ -f "$OUT/capture.png" ]; then
    m=$(mtime "$OUT/capture.png")
    if [ "$m" != "${last_capture:-}" ] && whole_png "$OUT/capture.png" && [ "$(request POST /capture -m 20 -H "Content-Type: image/png" --data-binary "@$OUT/capture.png")" = 200 ]; then
      last_capture=$m
    fi
  fi

  if [ -f "$OUT/results.json" ]; then
    # one result per command: {"id":1,"ok":true,"message":"..."}
    sed 's/},{/}\
{/g; s/^\[//; s/\]$//' "$OUT/results.json" | while IFS= read -r r; do
      id=$(printf '%s' "$r" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
      [ -n "$id" ] && printf '%s' "$r" > "$OUT/.result" \
        && request POST "/commands/$id/result" -m 10 -H "Content-Type: application/json" --data-binary "@$OUT/.result" >/dev/null
    done
    rm -f "$OUT/results.json" "$OUT/.result"
  fi

  # the client's own minimap sits in the write folder, two levels up. The clients there share it, so only the first
  # paired character sends it, and only after it changed.
  if [ "$minimap_on" = 1 ] && [ $((now - minimap_check)) -ge 60 ]; then
    minimap_check=$now
    first=""
    for t in "$DIR"/../*/inbox/pair.json; do grep -q '"paired":true' "$t" 2>/dev/null && { first=$t; break; }; done
    if [ "$first" = "$DIR/../${DIR##*/}/inbox/pair.json" ]; then
      map="" best=0
      for f in "$DIR"/../../minimap*.otmm; do
        [ -f "$f" ] || continue
        mm=$(mtime "$f")
        [ "$mm" -gt "$best" ] && map=$f best=$mm
      done
      if [ -n "$map" ] && [ "$best" != "$(cat "$SENT_MAP" 2>/dev/null)" ]; then
        case $(request POST /minimap -m 120 -H "Content-Type: application/octet-stream" --data-binary "@$map") in
          200 | 409) printf '%s' "$best" > "$SENT_MAP" ;;
        esac
      fi
    fi
  fi

  if [ "$status_every" -le 2 ]; then
    sleep 1
  elif [ "$age" -gt 300 ]; then
    sleep 10 # the client is closed or logged out: no request stays open
  else
    code=$(request GET "/wait?timeout=25" -m 30)
    if [ "$code" = 200 ]; then
      # someone opened the character, an alert fired or a command arrived: send the status again for a new pace
      grep -q '"wake":true' "$BODY" && wake=1
    elif [ "$code" = 401 ] && revoked; then
      unpair "removed on the website"
    else
      sleep 5
    fi
  fi
done
