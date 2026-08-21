#!/bin/bash
# Installer guidato per VideoLoop. Da eseguire SUL Raspberry Pi con sudo.
# Verifica/installa i pacchetti di sistema richiesti (vlc, ffmpeg, rsync,
# inotify-tools), verifica/completa la configurazione di boot (overlay PWM
# in config.txt -- obbligatorio per il LED; segnala il fix HDMI opzionale
# in cmdline.txt, README §6.1) e installa il sottosistema LED (demone, hook,
# permessi, servizi). NON copia/attiva il player (videoloop.sh/
# videoloop.service, README §5) ne' tocca /etc/pam.d/sshd: per quei punti
# stampa istruzioni, perche' richiedono decisioni/informazioni specifiche
# del tuo setup.
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "Esegui con sudo." >&2
    exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== Verifica/installazione pacchetti di sistema =="
MISSING=()
command -v cvlc        >/dev/null 2>&1 || MISSING+=(vlc)
command -v ffmpeg      >/dev/null 2>&1 || MISSING+=(ffmpeg)
command -v rsync       >/dev/null 2>&1 || MISSING+=(rsync)
command -v inotifywait >/dev/null 2>&1 || MISSING+=(inotify-tools)
if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "Pacchetti mancanti: ${MISSING[*]}"
    apt-get update
    apt-get install -y "${MISSING[@]}"
else
    echo "vlc, ffmpeg, rsync, inotify-tools: gia' presenti."
fi

echo
echo "== Configurazione di boot: overlay PWM (obbligatorio per il LED) =="
CONFIG_TXT=/boot/firmware/config.txt
[ -f "$CONFIG_TXT" ] || CONFIG_TXT=/boot/config.txt
if ! grep -q '^dtoverlay=pwm' "$CONFIG_TXT" 2>/dev/null; then
    echo "Overlay PWM assente in $CONFIG_TXT: lo aggiungo (sezione [all], si"
    echo "applica quindi a prescindere da eventuali filtri [cm4]/[cm5]/[pi5]"
    echo "gia' presenti in coda al file)."
    {
        printf '\n[all]\n'
        printf '# VideoLoop: PWM hardware per il LED di stato (README §9.3)\n'
        printf 'dtoverlay=pwm,pin=18,func=2\n'
    } >> "$CONFIG_TXT"
    echo "Aggiunto. Riavvia e rilancia questo script per completare l'installazione."
    exit 0
fi
echo "Overlay PWM gia' presente in $CONFIG_TXT."
if [ ! -d /sys/class/pwm/pwmchip0 ]; then
    echo "ATTENZIONE: /sys/class/pwm/pwmchip0 assente: l'overlay e' in config.txt"
    echo "ma serve un riavvio perche' venga applicato. Riavvia e rilancia install.sh."
    exit 0
fi

echo
echo "== Configurazione di boot: rilevamento HDMI (opzionale, README §6.1) =="
CMDLINE_TXT=/boot/firmware/cmdline.txt
[ -f "$CMDLINE_TXT" ] || CMDLINE_TXT=/boot/cmdline.txt
if grep -q 'video=HDMI-A-[0-9]*:' "$CMDLINE_TXT" 2>/dev/null; then
    echo "$CMDLINE_TXT ha gia' un override video= (nessuna azione)."
else
    echo "$CMDLINE_TXT non forza lo stato del connettore HDMI."
    echo "Serve SOLO se, a installazione completata, il LED resta bloccato su"
    echo "\"code 3\" (monitor non rilevato) pur con un TV collegato e acceso --"
    echo "capita con alcuni TV che non riportano hotplug/EDID in modo"
    echo "riconoscibile dal Pi. Se non sai ancora se ti serve, salta: puoi"
    echo "aggiungerlo in seguito (a mano o rilanciando questo script)."
    CONNECTOR="$(basename "$(ls -d /sys/class/drm/*/ 2>/dev/null | grep -i hdmi | head -n1)" 2>/dev/null || true)"
    CONNECTOR="${CONNECTOR:-HDMI-A-1}"
    read -r -p "Aggiungere \"video=${CONNECTOR}:D\" a $CMDLINE_TXT ora? [y/N] " ans
    if [ "${ans:-}" = "y" ] || [ "${ans:-}" = "Y" ]; then
        cp "$CMDLINE_TXT" "${CMDLINE_TXT}.bak-videoloop"
        # cmdline.txt e' una riga sola: si appende in coda alla stessa riga,
        # separato da uno spazio -- MAI andare a capo in questo file.
        sed -i "1 s/\$/ video=${CONNECTOR}:D/" "$CMDLINE_TXT"
        echo "Aggiunto (backup in ${CMDLINE_TXT}.bak-videoloop)."
        echo "Riavvia e rilancia questo script per completare l'installazione."
        exit 0
    fi
    echo "Saltato."
fi

echo
echo "== Gruppo 'led' e permessi /run/led =="
groupadd -f led
install -m 644 "$SRC_DIR/tmpfiles/led.conf" /etc/tmpfiles.d/led.conf
systemd-tmpfiles --create /etc/tmpfiles.d/led.conf

echo "== Copia script in /usr/local/bin =="
install -m 755 "$SRC_DIR/usr-local-bin/led-daemon.sh"        /usr/local/bin/led-daemon.sh
install -m 755 "$SRC_DIR/usr-local-bin/led-ctl"               /usr/local/bin/led-ctl
install -m 755 "$SRC_DIR/usr-local-bin/led-ssh-hook.sh"       /usr/local/bin/led-ssh-hook.sh
install -m 755 "$SRC_DIR/usr-local-bin/led-sync-watch.sh"     /usr/local/bin/led-sync-watch.sh
install -m 755 "$SRC_DIR/usr-local-bin/led-vlc-stop-hook.sh"  /usr/local/bin/led-vlc-stop-hook.sh
install -m 755 "$SRC_DIR/usr-local-bin/led-vlc-start-hook.sh" /usr/local/bin/led-vlc-start-hook.sh

echo "== Copia unit systemd =="
install -m 644 "$SRC_DIR/systemd/led-daemon.service"      /etc/systemd/system/led-daemon.service
install -m 644 "$SRC_DIR/systemd/led-sync-watch.service"  /etc/systemd/system/led-sync-watch.service

echo "== Copia dispatcher NetworkManager =="
install -m 755 "$SRC_DIR/networkmanager/99-led-wifi" /etc/NetworkManager/dispatcher.d/99-led-wifi

echo "== Abilito i servizi =="
systemctl daemon-reload
systemctl enable --now led-daemon.service
systemctl enable --now led-sync-watch.service

cat <<'EOF'

== Fatto. Restano 3 passi manuali: ==

1) SSH: aggiungi la riga indicata in pam/sshd-snippet.txt a /etc/pam.d/sshd

2) Se il player (o qualunque altro hook) gira come utente non-root,
   aggiungilo al gruppo "led" (creato ora) cosi' puo' chiamare led-ctl
   senza essere root, poi riavvia quel servizio:
     sudo usermod -aG led <utente>
     sudo systemctl restart <servizio-che-usa-quell-utente>

3) Player: se non l'hai gia' installato, vedi README §5. Se hai gia' un
   servizio systemd che avvia il player (diverso da videoloop.service),
   vedi la nota in README §9.4 per aggiungere solo gli hook LED.

4) Modifica MEDIA_DIR in /usr/local/bin/led-sync-watch.sh con la cartella
   media reale, poi: systemctl restart led-sync-watch.service

Test rapido:
   led-ctl set test 200 pulse 3000
   sleep 6
   led-ctl clear test
EOF
