#!/usr/bin/env bash
# Sostituisce /opt/videoloop/videoloop.sh originale.
# Nessuna gestione di pidfile/nohup/background/start-stop-status: sotto
# systemd non serve, ci pensa systemd stesso (systemctl start|stop|restart|
# status videoloop). Con `exec` lo script sostituisce se stesso con cvlc,
# cosi' systemd traccia direttamente il PID reale di cvlc e i segnali di
# stop arrivano dritti a lui, senza livelli intermedi.
set -euo pipefail

MEDIA_DIR="/opt/media_optimized"

CMD=(
  cvlc
  -I dummy
  --fullscreen
  --no-osd
  --loop
  --aout=alsa
  --alsa-audio-device=plughw:CARD=vc4hdmi,DEV=0
  --file-caching=3000
  --image-duration=10
  --no-video-title-show
)

shopt -s nullglob

# Se non c'e' un monitor HDMI collegato, cvlc fallisce subito (drm_vout:
# "Failed to find output"): senza questa attesa, StartLimitBurst si esaurisce
# in pochi secondi e il servizio si ferma per sempre, cosa che con il vecchio
# watchdog cron (nessun limite, ritentava ogni minuto) non succedeva. Invece
# di rilanciare cvlc a raffica, aspettiamo con un poll leggero che un
# connettore DRM risulti "connected" prima di provare ad avviare cvlc.
# Segnala "monitor HDMI non disponibile" (codice 3, vedi README §9.1) solo se
# il display non c'e' GIA' al primo controllo — cosi' un boot normale, col
# monitor gia' collegato, non fa comparire e sparire il codice per un istante.
wait_for_display() {
  local status_files f signaled=0
  while true; do
    status_files=(/sys/class/drm/*/status)
    for f in "${status_files[@]}"; do
      [ "$(cat "$f" 2>/dev/null)" = "connected" ] && {
        /usr/local/bin/led-ctl clear no-hdmi || true
        return 0
      }
    done
    if [ "$signaled" -eq 0 ]; then
      /usr/local/bin/led-ctl set no-hdmi 60 code 3 || true
      signaled=1
    fi
    sleep 2
  done
}
wait_for_display

files=(
  "$MEDIA_DIR"/*.mp4
  "$MEDIA_DIR"/*.m4v
  "$MEDIA_DIR"/*.mov
  "$MEDIA_DIR"/*.jpg
  "$MEDIA_DIR"/*.jpeg
  "$MEDIA_DIR"/*.png
)

if [ "${#files[@]}" -eq 0 ]; then
  echo "Nessun media trovato in $MEDIA_DIR" >&2
  exit 1
fi

# Segnaliamo "in riproduzione" solo ora che sappiamo che il monitor c'e' e
# che ci sono file da riprodurre — non prima (il display potrebbe non
# essere ancora disponibile a lungo). "|| true": un problema del LED non
# deve mai impedire l'avvio del video, che resta la funzione primaria.
/usr/local/bin/led-ctl clear vlc-error || true
/usr/local/bin/led-ctl set playing 10 pulse 3000 || true

exec "${CMD[@]}" "${files[@]}"
