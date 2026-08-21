#!/bin/bash
# Segnala "sync media in corso" finche' la cartella media riceve scritture
# (es. durante un rsync). Richiede il pacchetto inotify-tools.
set -u

MEDIA_DIR="/home/pi/media"   # <-- adatta alla cartella riprodotta da VLC
IDLE_TIMEOUT=5                 # secondi di silenzio prima di considerare finito il sync

if [ ! -d "$MEDIA_DIR" ]; then
    echo "led-sync-watch: cartella $MEDIA_DIR non trovata" >&2
    exit 1
fi

while true; do
    # attesa bloccante del primo evento
    inotifywait -q -r -e modify,create,delete,moved_to,moved_from,close_write "$MEDIA_DIR" >/dev/null 2>&1
    /usr/local/bin/led-ctl set sync 80 blink 400

    # finche' arrivano eventi entro IDLE_TIMEOUT secondi, resta in stato "sync"
    while inotifywait -q -r -t "$IDLE_TIMEOUT" -e modify,create,delete,moved_to,moved_from,close_write "$MEDIA_DIR" >/dev/null 2>&1; do
        :
    done

    /usr/local/bin/led-ctl clear sync
done
