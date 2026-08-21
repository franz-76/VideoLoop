#!/bin/bash
# Da usare come ExecStartPre del servizio VLC.
# Cancella un eventuale stato di errore residuo (VLC e' ripartito con
# successo) e segnala "in riproduzione" col respiro.
set -u

/usr/local/bin/led-ctl clear vlc-error
/usr/local/bin/led-ctl set playing 10 pulse 3000
