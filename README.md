# VideoLoop

Un dispositivo minimale per trasformare un qualunque display con ingresso HDMI in un Kiosk permanente.

Ovvero: uno scatolino (Raspberry Pi Zero 2W) che riproduce in sequenza video (e foto, convertite in video) in loop continuo fino a Full HD 60Hz. I contenuti possono esser aggiornati da remoto con strumenti di base, l'ottimizzazione audio/video è gestibile sul device stesso. 

## 1. Caratteristiche

- **Loop video** (anche con audio) su hardware minimale, fino a Full HD
  60Hz.
- **Nessun server né servizio di streaming**: la soluzione è pensata per poter essere usata in ambienti segregati o privi di connessione di rete. Tutti i contenuti sono persistenti sul device. Nessun traffico di rete, nessun servizio di streaming attivo, nessuna occupazione di rete (al di fuori delle sessioni di aggiornamento se eseguite da remoto).
- **Aggiornamento dei contenuti da remoto**: se il device è connesso ad una rete WiFi, i contenuti possono essere aggiornati da remoto, manualmente o tramite tool di sincronizzazione automatici. Nonostante la connessione al WiFi, rimane un
  attore passivo in rete esponendo il solo servizio ssh per le connessioni in ingresso, minimizzando la superficie d'attacco.
- **Ottimizzazione dei media sul device stesso**: i contenuti vengono ottimizzati per la decodifica da parte della GPU per mantenere il rendering fluido. Gli script e gli strumenti di *ridimensionamento/
  conversione video e conversione foto→video* sono disponibili e preconfigurati per processare correttamente i media.
- **Feedback di stato via LED**: tramite l'installazione di un LED aggiuntivo, è possibile monitorare il funzionamento del dispositivo e diagnosticare eventuali anomalie senza doversi connettere al device. Un indicazione chiara anche per i non addetti ai lavori.
- **Alimentabile da TV**: se il display a cui viene collegato è dotato di una porta USB che eroga alimentazione non è necessario prevedere un alimentatore separato; il basso assorbimento di potenza del dispositivo lo rende largamente compatibile.

## 2. Estensioni future

- **Ottimizzazione automatica dei contenuti**: monitorare la cartella di
  deposito (quella usata da rsync, o quella configurata) e, alla modifica
  dei contenuti, convertire e spostare automaticamente i media nella
  cartella di riproduzione — oggi la conversione richiede il lancio
  manuale di `optimize_media.sh` (§8). Includerebbe anche la rimozione dei
  media non più presenti nella cartella sorgente.

## 3. Requisiti

- Raspberry Pi con Raspberry Pi OS (testato su Zero 2W, 64 bit) e uscita
  HDMI.
- `vlc` (per `cvlc`) e `ffmpeg` nel `PATH`.
- `rsync` sulla macchina che aggiorna i contenuti (nessun requisito
  lato device oltre a un utente SSH con permesso di scrittura sulla
  cartella media).
- Solo per il feedback LED (§9, opzionale): `inotify-tools`, un canale PWM
  hardware libero, 2 LED + resistenze di limitazione.

## 4. Struttura del repository

```
videoloop/videoloop.sh             -> /opt/videoloop/videoloop.sh (player, §6)
videoloop/optimize_media.sh        -> /opt/videoloop/optimize_media.sh (§8)
systemd/videoloop.service          -> /etc/systemd/system/videoloop.service (§6)
udev/99-videoloop-hotplug.rules    -> /etc/udev/rules.d/99-videoloop-hotplug.rules (§6.1)

usr-local-bin/led-daemon.sh         -> /usr/local/bin/led-daemon.sh (§9)
usr-local-bin/led-ctl               -> /usr/local/bin/led-ctl (§9)
usr-local-bin/led-ssh-hook.sh       -> /usr/local/bin/led-ssh-hook.sh (§9)
usr-local-bin/led-sync-watch.sh     -> /usr/local/bin/led-sync-watch.sh (§7, §9)
usr-local-bin/led-vlc-start-hook.sh -> /usr/local/bin/led-vlc-start-hook.sh (§9)
usr-local-bin/led-vlc-stop-hook.sh  -> /usr/local/bin/led-vlc-stop-hook.sh (§9)
systemd/led-daemon.service          -> /etc/systemd/system/led-daemon.service (§9)
systemd/led-sync-watch.service      -> /etc/systemd/system/led-sync-watch.service (§9)
systemd/vlc-player.service.example  -> template generico per il player sotto systemd
systemd/vlc-player.service.d-led.conf.example
                                     -> override per aggiungere gli hook LED a un servizio player esistente (§9.4)
networkmanager/99-led-wifi          -> /etc/NetworkManager/dispatcher.d/99-led-wifi (§9)
tmpfiles/led.conf                   -> /etc/tmpfiles.d/led.conf, permessi /run/led (§9.4)
pam/sshd-snippet.txt                -> riga da aggiungere a /etc/pam.d/sshd, per lo stato SSH del LED (§9)
install.sh                          -> installer guidato del feedback LED (§5)
```

## 5. Installazione

1. Copia questa cartella sul Pi (es. `rsync -av videoloop/ pi@host:~/videoloop/`).
2. Sul Pi: `sudo ~/videoloop/install.sh` — verifica/installa i pacchetti
   di sistema (`vlc`, `ffmpeg`, `rsync`, `inotify-tools`).
3. Copia `videoloop/videoloop.sh` (e, se vuoi la conversione media
   integrata sul device, `videoloop/optimize_media.sh`) in
   `/opt/videoloop/` sul Pi.
4. Copia `systemd/videoloop.service` in
   `/etc/systemd/system/videoloop.service` — adatta `User`/`Group` al tuo
   utente (l'esempio nel repo usa `san`).
5. `systemctl daemon-reload && systemctl enable --now videoloop.service`
6. Verifica: `systemctl status videoloop`, `journalctl -u videoloop -f`.

Questo basta per la riproduzione. Il feedback LED (§9) è indipendente e
opzionale.

## 6. Riproduzione in loop — `videoloop.sh`

`videoloop.sh` sostituisce `/opt/videoloop/videoloop.sh` e gira sotto
`videoloop.service` (systemd): `cvlc` in loop sui file di
`/opt/media_optimized`, fullscreen, senza OSD, audio via ALSA sull'uscita
HDMI. Lo script termina con `exec "${CMD[@]}"`: si sostituisce con `cvlc`
invece di lanciarlo in background, cosi' systemd traccia direttamente il
processo reale (`Type=simple`), senza livelli intermedi.

Robustezza gestita interamente da systemd, non dallo script:

- `Restart=always` / `RestartSec=2`: riavvio in 1-2s su crash.
- `StartLimitBurst=5` / `StartLimitIntervalSec=60`: dopo 5 crash in 60s il
  servizio si ferma, invece di consumare risorse ritentando all'infinito —
  a quel punto resta acceso il codice LED di errore (§9.1, `code 2`)
  finché non intervieni.
- `TimeoutStopSec=15`: SIGTERM, attesa, poi SIGKILL automatico allo stop.
- Log unificati in `journalctl -u videoloop -f`, nessun file di log da
  gestire.

### 6.1 Rilevamento del monitor HDMI

**TV che non riportano hotplug/EDID in modo riconoscibile**: su alcuni TV
(pannelli consumer, non monitor da PC) `/sys/class/drm/*/status` non passa
mai a `connected` pur con segnale HDMI attivo, e l'attesa resta bloccata
all'infinito (LED fisso su `code 3`, TV comunque acceso e funzionante).
<u>Per disabilitare il controllo:</u>

 `install.sh` (§5) lo propone in modo interattivo durante l'installazione del LED. Per farlo a mano, aggiungere alla riga esistente di `/boot/firmware/cmdline.txt`
(stesso file, stessa riga, separato da uno spazio — su OS più vecchi
`/boot/cmdline.txt`)

```
video=HDMI-A-1:D
```

e riavviare. 

Il nome del connettore va verificato con `ls /sys/class/drm |
grep -i hdmi` (su Pi Zero 2W, che ha una sola porta mini-HDMI, è quasi
sempre `HDMI-A-1`). Il flag `D` forza il connettore a uno stato digitale
abilitato, bypassando il rilevamento hardware hotplug/EDID che su quel TV
non viene interpretato correttamente. Poiché lo stato del connettore viene
forzato, il rilevamento a caldo di un vero scollegamento
potrebbe non essere più affidabile sullo stesso connettore: usalo solo se
il device resta bloccato su `code 3` all'avvio con il TV acceso, non
preventivamente.

**Monitor spento/scollegato a riproduzione già avviata**: dipende dal
comportamento del monitor. Se tiene "alto" l'hotplug-detect anche da
spento (comune sui monitor da PC), il kernel non vede nessuna
disconnessione, il dispositivo continua a renderizzare il video e l'immagine
torna da sola alla riaccensione. Se invece il monitor/TV rilascia
l'hotplug-detect allo spegnimento (comune sui pannelli da digital
signage), il kernel genera un evento di disconnessione reale — coperto da
`udev/99-videoloop-hotplug.rules`, che intercetta l'evento e forza un riavvio pulito del servizio ad ogni transizione, in entrambe le direzioni:

```
sudo cp udev/99-videoloop-hotplug.rules /etc/udev/rules.d/99-videoloop-hotplug.rules
sudo udevadm control --reload-rules
```

Il codice LED di errore (`code 2`) non si autocancella con un timer a
tempo: resta acceso finché la riproduzione non riparte con successo,
oppure — dopo `StartLimitBurst` — resta acceso di proposito, a segnalare
un guasto reale e non un semplice transitorio.

## 7. Aggiornamento dei contenuti — rsync

Il device non espone alcun servizio applicativo: riceve solo connessioni via SSH. Nessuna occupazione di rete al di
fuori delle sessioni di sync, nessuna superficie d'attacco oltre a SSH —
isolabile su un segmento di rete dedicato allo scopo.

```
rsync -av --delete media/ pi@host:/opt/media/
```

I file entrano nella cartella "grezza" (`/opt/media`); `videoloop.sh`
riproduce invece `/opt/media_optimized` (§8), popolata da
`optimize_media.sh`. Dopo un sync (ed eventuale ottimizzazione), un
riavvio del servizio applica la nuova playlist — pochi secondi, non serve
mai riavviare il device:

```
systemctl restart videoloop
```

Se installato, `led-sync-watch.sh` (§9) segnala visivamente il sync in
corso: monitora la cartella media con `inotifywait` e resta in stato "sync"
finché non trascorrono alcuni secondi senza nuove scritture.

## 8. Ottimizzazione dei media — `optimize_media.sh`

Converte i file grezzi in `/opt/media` nel formato che
`videoloop.sh` si aspetta in `/opt/media_optimized` — stessa risoluzione/
framerate/codec per tutti (H.264 yuv420p, faststart) indipendentemente dal
formato sorgente, così il *player video* non deve rincodificare al volo file
eterogenei. Richiede `ffmpeg` nel `PATH`.

```bash
/opt/videoloop/optimize_media.sh [cartella-sorgente] [cartella-destinazione]
```

I parametri sono definibili  via
variabili d'ambiente e preimpostati come segue:

- `WIDTH`/`HEIGHT` (default 1920x1080)

- `FPS` (default
  25)

- `IMAGE_DURATION` (secondi di permanenza per le immagini, default 10)

- `CRF` (qualità H.264, default 23 — più basso è più definito/pesante).

- Riconosce immagini (jpg/jpeg/png/bmp/webp) e video (mp4/mov/m4v/mkv/avi/
  webm) per estensione; il resto viene saltato con un avviso.

## 9. Feedback LED (funzione accessoria)

Indicazione luminosa dello stato del device tramite **LED**, utile per
diagnosticare il device (in riproduzione / errore / sync in corso / SSH
attivo) senza dover collegare uno schermo, incluso un **codice a
lampeggi** per le anomalie.

- Cablaggio (§9.2).

- verifica/completa la configurazione di boot (overlay PWM in `config.txt`,
  aggiunto automaticamente se assente da *install.sh* — dopo il primo riavvio rilancia
  lo script per proseguire e segui le indicazioni fornite.

- Adatta `MEDIA_DIR` in `led-sync-watch.sh` alla cartella che il player
  riproduce.

- Testa manualmente:
  
  ```
  sudo led-ctl set test 200 pulse 3000
  sleep 6
  sudo led-ctl clear test
  ```

### 9.1 Stati previsti

Le modalità di accensione e/o lampeggio ldel led indicano lo stato di funzionamento del device.

| #   | Categoria   | Stato                                            | Pattern                                           | Priorità | Descrizione "a voce"                                                   |
| --- | ----------- | ------------------------------------------------ | ------------------------------------------------- | -------- | ---------------------------------------------------------------------- |
| 1   | Anomalo     | WiFi/rete assente                                | 4 lampi veloci + **1** lampo lento                | 100      | "lampeggia veloce quattro volte, poi un lampo lento, pausa, si ripete" |
| 2   | Anomalo     | Player non risponde / crash                      | 4 lampi veloci + **2** lampi lenti                | 95       | "...poi due lampi lenti..."                                            |
| 3   | Transizione | Spegnimento in corso                             | 3 impulsi di intensità decrescente                | 90       | "pulsa sempre più debole finché si spegne"                             |
| 4   | Operativo   | Sync media (rsync) in corso                      | lampeggio continuo a ritmo medio                  | 80       | "lampeggia a velocità media, senza pause"                              |
| 5   | Operativo   | Sessione SSH attiva                              | due lampi ravvicinati, pausa                      | 70       | "due lampi veloci vicini, poi pausa, si ripete"                        |
| 6   | Anomalo     | Monitor HDMI non disponibile                     | 4 lampi veloci + **3** lampi lenti, pausa, ripete | 60       | "...poi tre lampi lenti..."                                            |
| 7   | Transizione | SO avviato, player non ancora attivo (boot/idle) | lampeggio continuo veloce                         | 5 (base) | "lampeggia veloce, senza pause, sempre uguale"                         |
| 8   | Operativo   | In riproduzione                                  | respiro                                           | 10       | "si accende e spegne dolcemente, come un respiro"                      |
| 9   | Transizione | Alimentato, SO non ancora avviato                | spento                                            | n/a      | "spento"                                                               |

Lo stato 6 (monitor assente) potrebbe non essere rilevato a seconda del tipo di display in uso e delle modalità di gestione HDMI impostate nei parametri di *boot*.

Gli stati "continui" (boot, sync) lampeggiano sempre alla stessa velocità senza mai fermarsi;
gli stati "a gruppi" (ssh, anomalie) fanno una sequenza breve e poi una
pausa lunga prima di ripetere — il numero di lampi lenti dopo il
preambolo veloce è **il codice errore**, contabile per identificare lo stato.

### 9.2 Elettronica

Componenti: 1(o più) LED con limitazione di corrente tramite resistenza di valore adeguato al tipo di LED installato. Un solo pin pilotato, in PWM hardware:

| Segnale    | GPIO (BCM) | Pin fisico header 40 | Funzione            |
| ---------- | ---------- | -------------------- | ------------------- |
| LED (PWM0) | GPIO18     | 12                   | ALT5 / PWM hardware |
| GND        | —          | 14                   | comune              |

```
GPIO18 (pin12) ──[R]── Anodo LED1 ── Catodo ── GND (pin14)
GPIO18 (pin12) ──[R]── Anodo LED2 ── Catodo ── GND (pin14)
```

Ogni LED ha la propria resistenza (non condivisa) di valore indicativo **150 Ω**. Vista la tensione di 3.3V del GPIO, se  risultasse troppo poco luminoso è possibile diminuirne il valore verso 100 Ω; se troppo intenso è possibile aumentarlo verso 220-330 Ω. Deve essere comunque rispettato il limite di corrente erogabile dal GPIO, *max ~16 mA per pin*.

### 9.3 Attivazione del PWM hardware

Il Pi Zero 2W ha 2 canali PWM hardware; in questo caso usiamo PWM0 su GPIO18. Va
abilitato via overlay del device tree — `install.sh` (§5) lo aggiunge da
solo se manca. Per farlo a mano: aggiungi questa riga a
`/boot/firmware/config.txt` (su OS più vecchi: `/boot/config.txt`), in una
sezione `[all]` (per non ereditare eventuali filtri `[cm4]`/`[cm5]`/`[pi5]`
già presenti in coda al file) e riavvia:

```
dtoverlay=pwm,pin=18,func=2
```

Dopo il riavvio deve esistere `/sys/class/pwm/pwmchip0` (verificalo con
`ls /sys/class/pwm/pwmchip0`). `led-daemon.sh` si occupa da solo di
esportare il canale (`pwm0`), impostare periodo e abilitarlo.

**Nota — gestione PWM hardware vs. gestione del LED da codice**: tutti i
pattern del LED, respiro (`pulse`) incluso, sono generati in PWM hardware,
non pilotando il pin da software ad ogni ciclo. Il canale PWM0 è un blocco
dedicato del SoC: una volta impostato un duty cycle, l'hardware continua a
generare il segnale in autonomia, senza bisogno che la CPU intervenga ad
ogni ciclo del segnale stesso. Il software si limita ad *aggiornare*
periodicamente quel valore per ottenere le rampe di salita/discesa (una
scrittura su sysfs, `echo ... > file`, builtin di bash, senza fork di
processi esterni): il loop del demone gira ogni 50ms, riscrive il valore
solo se cambia rispetto al tick precedente, e usa la variabile builtin
`$EPOCHREALTIME` invece di un comando esterno `date` per il timestamp.
Nessun impatto misurabile sulla riproduzione video, che decodifica
comunque via GPU e non è mai bloccata dal demone LED.

Diverso sarebbe pilotare il LED interamente da codice (accensione/
spegnimento del pin ad ogni passo tramite un comando esterno ad ogni
tick, invece che affidando il segnale continuo all'hardware): ogni
invocazione di un processo esterno costa qualche millisecondo di
fork/exec, e ripetuta decine di volte al secondo introdurrebbe overhead e
micro-jitter nello scheduling — con un margine di rischio reale di
stutter audio/video se capita mentre il player ha bisogno di quel core.
Con il PWM hardware questo problema non si pone: il segnale luminoso è
generato dal SoC, non dalla CPU.

### 9.4 Architettura software e permessi

- `led-daemon.sh`: demone che configura il canale PWM hardware e lo
  pilota in loop leggendo lo stato con priorità più alta tra i file
  presenti in `/run/led/state.d/`, traducendolo in un duty cycle 0-100%
  secondo il pattern (`blink`, `pulse`, `double`, `code`, `solid`, `off`).
- `led-ctl`: comando per impostare/rimuovere uno stato
  (`led-ctl set <nome> <priorità> <pattern> [arg]` / `led-ctl clear
  <nome>`). Lo usano tutti gli hook qui sotto.
- Hook che chiamano `led-ctl`:
  - il servizio systemd del player (`videoloop.service` o equivalente,
    tramite `ExecStartPre`/`ExecStopPost`) → `pulse 3000` quando la
    riproduzione parte, lo rimuove quando si ferma, imposta `code 2` se
    termina in modo anomalo.
  - `99-led-wifi` (dispatcher NetworkManager) → `code 1` su
    disconnessione dell'interfaccia WiFi.
  - `led-ssh-hook.sh` (via PAM) → `double` mentre c'è almeno una sessione
    SSH aperta.
  - `led-sync-watch.sh` (systemd service, usa `inotifywait`) → `blink
    400` finché la cartella media riceve scritture (rsync in corso).

Lo spegnimento (`fade`) non passa dai file di stato: è gestito
direttamente dal trap su `SIGTERM` del demone, per garantire che parta
subito e in modo deterministico indipendentemente da cos'altro fosse
attivo.

Tutti gli stati transitori si auto-ripuliscono; solo lo stato base "idle"
(`blink 150`, priorità 5) resta scritto in permanenza dal daemon.

**Permessi**: `led-daemon.service` gira come root e crea
`/run/led/state.d`; qualunque hook che chiama `led-ctl` da un utente
non-root (tipicamente il servizio del player) deve appartenere al gruppo
`led` per potervi scrivere. `install.sh` crea il gruppo e installa
`tmpfiles/led.conf` (che fissa i permessi `2775 root:led` su `/run/led` e
`/run/led/state.d`), ma **tocca a te** aggiungere ogni utente non-root che
userà `led-ctl`: `sudo usermod -aG led <utente>` seguito da un riavvio del
servizio in questione (non serve rilogin: systemd rilegge i gruppi ad
ogni avvio del servizio). La regola è riapplicata ad ogni avvio di
`led-daemon.service` tramite `ExecStartPre=systemd-tmpfiles --create`,
perché `/run` è tmpfs e il demone stesso cancella e ricrea `state.d` ad
ogni proprio riavvio — un `chmod` fatto a mano sparirebbe al riavvio
successivo del demone.

**Nota — aggiungere gli hook LED a un servizio player già esistente**: se
il player non è `videoloop.service` ma un altro servizio systemd che avvii
già tu, non serve riscriverlo — basta un override che aggiunga gli hook:

```
mkdir -p /etc/systemd/system/<nome-servizio>.service.d
cp systemd/vlc-player.service.d-led.conf.example \
   /etc/systemd/system/<nome-servizio>.service.d/led.conf
systemctl daemon-reload
systemctl restart <nome-servizio>
```

## Licenza

MIT — vedi [LICENSE](LICENSE).
