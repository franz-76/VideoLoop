#!/bin/bash
# Chiamato da PAM (session open/close) su ogni login/logout SSH.
# Tiene un contatore di sessioni attive perche' possono essercene piu' di una
# in parallelo: lo stato "ssh" va tolto solo quando l'ultima si chiude.
set -eu

COUNT_DIR=/run/led
COUNT_FILE="$COUNT_DIR/ssh-sessions"
LOCK_FILE="$COUNT_DIR/ssh-sessions.lock"
mkdir -p "$COUNT_DIR"

exec 9>"$LOCK_FILE"
flock 9

count=0
[ -f "$COUNT_FILE" ] && count=$(cat "$COUNT_FILE")

case "${PAM_TYPE:-}" in
    open_session)
        count=$((count + 1))
        echo "$count" > "$COUNT_FILE"
        /usr/local/bin/led-ctl set ssh 70 double
        ;;
    close_session)
        count=$((count - 1))
        [ "$count" -lt 0 ] && count=0
        echo "$count" > "$COUNT_FILE"
        if [ "$count" -eq 0 ]; then
            /usr/local/bin/led-ctl clear ssh
        fi
        ;;
esac
