#!/bin/bash
# Demone LED di stato — monocolore, colore del brand (LED blu qui a titolo d'esempio).
# Pilota 2x LED blu (in parallelo, uno per estremo del logo) su un unico
# canale PWM hardware (GPIO18 / PWM0), cosi' l'effetto "respiro" e' gestito
# dal chip PWM e non da un loop software che accende/spegne il pin.
#
# Legge /run/led/state.d/*, applica il pattern con priorita' piu' alta.
# Formato file di stato: "<priorita> <pattern> [<arg>]"
#   blink <half_ms>   lampeggio continuo regolare
#   pulse <period_ms> respiro (rampa triangolare 0 -> 100 -> 0)
#   double             doppio lampo ravvicinato + pausa lunga (ripetuto)
#   code <N>           codice errore: preambolo lampi veloci + N lampi lenti + pausa
#   solid              acceso fisso (utile per test manuali)
#   off                spento
set -u

PWMCHIP=/sys/class/pwm/pwmchip0
PWM="$PWMCHIP/pwm0"
PERIOD_NS=1000000       # 1 kHz, ben sopra la soglia di percezione del flicker
STATE_DIR=/run/led/state.d
POLL_INTERVAL=0.03       # 30 ms => ~33 aggiornamenti/s, respiro fluido

mkdir -p "$STATE_DIR"

# --- inizializzazione PWM hardware --------------------------------------
pwm_init() {
    if [ ! -d "$PWM" ]; then
        echo 0 > "$PWMCHIP/export"
        # sysfs impiega qualche istante a creare i nodi
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            [ -d "$PWM" ] && break
            sleep 0.05
        done
    fi
    echo "$PERIOD_NS" > "$PWM/period"
    echo 0 > "$PWM/duty_cycle"
    echo 1 > "$PWM/enable"
}

pwm_set_duty_pct() {
    # $1 = 0..100
    local pct=$1
    local ns=$(( PERIOD_NS * pct / 100 ))
    echo "$ns" > "$PWM/duty_cycle"
}

# --- spegnimento pulito (dissolvenza) -----------------------------------
shutdown_fade() {
    local peak
    for peak in 100 70 40; do
        local step
        for step in $(seq 0 10 "$peak"); do pwm_set_duty_pct "$step"; sleep 0.015; done
        for step in $(seq "$peak" -10 0); do pwm_set_duty_pct "$step"; sleep 0.015; done
        sleep 0.1
    done
    pwm_set_duty_pct 0
}

on_term() {
    shutdown_fade
    echo 0 > "$PWM/enable" 2>/dev/null || true
    rm -rf "$STATE_DIR"
    exit 0
}
trap on_term SIGTERM SIGINT

# --- motore pattern: calcola il duty (0-100) dato pattern/arg/tempo trascorso
# Usa una variabile globale DUTY invece di command substitution, per non
# forkare una subshell ad ogni tick.
compute_duty() {
    local pattern=$1 arg=$2 elapsed=$3
    case "$pattern" in
        off)
            DUTY=0
            ;;
        solid)
            DUTY=100
            ;;
        blink)
            local half=$arg cycle phase
            [ "$half" -gt 0 ] || half=200
            cycle=$(( half * 2 ))
            phase=$(( elapsed % cycle ))
            DUTY=$(( phase < half ? 100 : 0 ))
            ;;
        pulse)
            local period=$arg half phase
            [ "$period" -gt 0 ] || period=3000
            half=$(( period / 2 ))
            phase=$(( elapsed % period ))
            if [ "$phase" -lt "$half" ]; then
                DUTY=$(( phase * 100 / half ))
            else
                DUTY=$(( (period - phase) * 100 / half ))
            fi
            ;;
        double)
            # due lampi da 120ms separati da 120ms, poi pausa fino a 2000ms
            local phase=$(( elapsed % 2000 ))
            if [ "$phase" -lt 120 ] || { [ "$phase" -ge 240 ] && [ "$phase" -lt 360 ]; }; then
                DUTY=100
            else
                DUTY=0
            fi
            ;;
        code)
            # preambolo: 4 lampi veloci (90 on / 90 off) = 720ms
            # pausa breve: 400ms
            # N lampi lenti (380 on / 380 off) = N*760ms
            # pausa lunga: 1600ms
            local n=$arg
            [ "$n" -ge 1 ] 2>/dev/null || n=1
            local preamble=720 gap=400 slow=$(( n * 760 )) pause=1600
            local cycle=$(( preamble + gap + slow + pause ))
            local phase=$(( elapsed % cycle ))
            if [ "$phase" -lt "$preamble" ]; then
                local within=$(( phase % 180 ))
                DUTY=$(( within < 90 ? 100 : 0 ))
            elif [ "$phase" -lt "$((preamble + gap))" ]; then
                DUTY=0
            elif [ "$phase" -lt "$((preamble + gap + slow))" ]; then
                local sub=$(( phase - preamble - gap ))
                local within=$(( sub % 760 ))
                DUTY=$(( within < 380 ? 100 : 0 ))
            else
                DUTY=0
            fi
            ;;
        *)
            DUTY=0
            ;;
    esac
}

# --- orologio senza fork (bash 5: $EPOCHREALTIME, niente `date`) --------
# Il separatore decimale di EPOCHREALTIME segue LC_NUMERIC (su questo sistema
# e' una virgola, non un punto): non spezziamo su IFS=. ma togliamo tutto
# cio' che precede/segue il primo carattere non numerico, qualunque esso sia.
now_ms() {
    local epoch=$EPOCHREALTIME sec frac
    sec=${epoch%%[!0-9]*}
    frac=${epoch#*[!0-9]}
    printf -v NOW_MS '%d' "$(( 10#$sec * 1000 + 10#${frac:0:3} ))"
}

# --- stato di base -------------------------------------------------------
pwm_init
echo "5 blink 150" > "$STATE_DIR/idle"

# --- loop principale -------------------------------------------------------
current_key=""
pattern_start=0
last_duty=-1

while true; do
    winner_prio=-1
    winner_pattern="off"
    winner_arg=0

    for f in "$STATE_DIR"/*; do
        [ -f "$f" ] || continue
        read -r prio pattern arg < "$f" 2>/dev/null || continue
        [ -n "$prio" ] || continue
        arg=${arg:-0}
        if [ "$prio" -gt "$winner_prio" ] 2>/dev/null; then
            winner_prio=$prio
            winner_pattern=$pattern
            winner_arg=$arg
        fi
    done

    key="$winner_pattern $winner_arg"
    now_ms
    now=$NOW_MS

    if [ "$key" != "$current_key" ]; then
        current_key=$key
        pattern_start=$now
    fi

    compute_duty "$winner_pattern" "$winner_arg" "$(( now - pattern_start ))"

    if [ "$DUTY" != "$last_duty" ]; then
        pwm_set_duty_pct "$DUTY"
        last_duty=$DUTY
    fi

    sleep "$POLL_INTERVAL"
done
