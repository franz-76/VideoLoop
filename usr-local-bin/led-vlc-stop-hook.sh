#!/bin/bash
# Da usare come ExecStopPost del servizio VLC.
# systemd valorizza SERVICE_RESULT nell'ambiente di ExecStopPost.
#
# Lo stato di errore NON si autocancella con un timer: resta acceso finche'
# VLC non riparte con successo (lo cancella led-vlc-start-hook.sh) oppure,
# se systemd smette di riprovare (StartLimitBurst raggiunto), resta acceso
# di proposito finche' non intervieni — e' il comportamento corretto per
# un'anomalia reale, non un lampeggio a tempo.
set -u

/usr/local/bin/led-ctl clear playing
/usr/local/bin/led-ctl clear no-hdmi

if [ "${SERVICE_RESULT:-success}" != "success" ]; then
    /usr/local/bin/led-ctl set vlc-error 95 code 2
fi
