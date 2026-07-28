#!/bin/zsh
set -euo pipefail

readonly APP_NAME="Regression"
readonly MAX_IDLE_ATTEMPTS=30
readonly REQUIRED_IDLE_SAMPLES=3
readonly IDLE_CPU_THRESHOLD=10

app_pid="$(pgrep -x "$APP_NAME" | tail -n 1)"
if [[ -z "$app_pid" ]]; then
    print -u2 "Regression no está ejecutándose. Abre la app instalada antes de esta prueba."
    exit 1
fi

osascript <<'APPLESCRIPT'
tell application "System Events"
    tell process "Regression"
        set statusItem to menu bar item 1 of menu bar 2
        set scrollArea to missing value
        repeat 3 times
            try
                set scrollArea to scroll area 1 of group 1 of pop over 1 of statusItem
                exit repeat
            on error
                click statusItem
                delay 1
            end try
        end repeat
        if scrollArea is missing value then error "No se pudo abrir el panel de Regression."

        -- Con bibliotecas grandes, Accesibilidad expone solo los controles cercanos al viewport.
        -- Colapsar temporalmente Juegos hace visible Aprendizaje sin depender del número de filas.
        set value of scroll bar 1 of scrollArea to 0
        delay 0.25
        set descendants to entire contents of scrollArea
        set gamesTriangle to missing value
        repeat with elementRef in descendants
            try
                if role of elementRef is "AXDisclosureTriangle" then
                    set gamesTriangle to elementRef
                    exit repeat
                end if
            end try
        end repeat
        if gamesTriangle is missing value then error "No se encontró el grupo Juegos instalados."
        if value of gamesTriangle is true then
            perform action "AXPress" of gamesTriangle
            delay 0.35
        end if

        repeat 12 times
            set descendants to entire contents of scrollArea
            set triangleIndex to 0
            set learningTriangle to missing value

            repeat with elementRef in descendants
                try
                    if role of elementRef is "AXDisclosureTriangle" then
                        set triangleIndex to triangleIndex + 1
                        if triangleIndex is 2 then
                            set learningTriangle to elementRef
                            exit repeat
                        end if
                    end if
                end try
            end repeat

            if learningTriangle is missing value then
                error "No se encontró el grupo Aprendizaje local."
            end if

            perform action "AXPress" of learningTriangle
            delay 0.25
        end repeat

        -- El popover puede cerrarse al cambiar el foco entre procesos de Accesibilidad.
        -- Reabrirlo y volver a resolver sus referencias evita conservar objetos AX caducados.
        set scrollArea to missing value
        repeat 3 times
            try
                set scrollArea to scroll area 1 of group 1 of pop over 1 of statusItem
                exit repeat
            on error
                click statusItem
                delay 0.5
            end try
        end repeat
        if scrollArea is missing value then error "El panel desapareció durante el estrés."
        set descendants to entire contents of scrollArea
        set triangleIndex to 0
        repeat with elementRef in descendants
            try
                if role of elementRef is "AXDisclosureTriangle" then
                    set triangleIndex to triangleIndex + 1
                    if triangleIndex is 2 then
                        if value of elementRef is false then
                            perform action "AXPress" of elementRef
                        end if
                        exit repeat
                    end if
                end if
            end try
        end repeat
    end tell
end tell
APPLESCRIPT

idle_samples=0
for attempt in {1..$MAX_IDLE_ATTEMPTS}; do
    if ! kill -0 "$app_pid" 2>/dev/null; then
        print -u2 "Regression terminó durante la prueba del popover."
        exit 1
    fi

    current_cpu="$(ps -p "$app_pid" -o %cpu= | tr -d ' ')"
    if awk -v cpu="$current_cpu" -v threshold="$IDLE_CPU_THRESHOLD" \
        'BEGIN { exit !(cpu < threshold) }'; then
        idle_samples=$((idle_samples + 1))
        if (( idle_samples >= REQUIRED_IDLE_SAMPLES )); then
            break
        fi
    else
        idle_samples=0
    fi
    sleep 1
done

if (( idle_samples < REQUIRED_IDLE_SAMPLES )); then
    sample "$app_pid" 3 -file "/tmp/regression-popover-stress-${app_pid}.sample.txt" >/dev/null
    print -u2 "Regression no volvió a reposo; muestra guardada en /tmp/regression-popover-stress-${app_pid}.sample.txt"
    exit 1
fi

element_count="$(osascript <<'APPLESCRIPT'
tell application "System Events"
    tell process "Regression"
        set statusItem to menu bar item 1 of menu bar 2
        set scrollArea to missing value
        repeat 3 times
            try
                set scrollArea to scroll area 1 of group 1 of pop over 1 of statusItem
                exit repeat
            on error
                click statusItem
                delay 0.5
            end try
        end repeat
        if scrollArea is missing value then error "No se pudo reabrir el panel para inspeccionarlo."
        set descendants to entire contents of scrollArea
        set elementCount to count of descendants

        -- Restaura la presentación habitual con Juegos instalados desplegado.
        set value of scroll bar 1 of scrollArea to 0
        delay 0.25
        set descendants to entire contents of scrollArea
        repeat with elementRef in descendants
            try
                if role of elementRef is "AXDisclosureTriangle" then
                    if value of elementRef is false then
                        perform action "AXPress" of elementRef
                    end if
                    exit repeat
                end if
            end try
        end repeat
        return elementCount
    end tell
end tell
APPLESCRIPT
)"

if (( element_count <= 0 )); then
    print -u2 "El árbol de accesibilidad del popover quedó vacío."
    exit 1
fi

print "Popover estable: PID ${app_pid}, ${element_count} elementos accesibles y CPU en reposo."
