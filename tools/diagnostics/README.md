# Diagnósticos de Regression

Estas utilidades aportan instrumentación reproducible sin modificar por sí solas el runtime, la
botella ni los juegos. Los helpers Win64 no se distribuyen dentro de `Regression.app`.

## Helpers Win64

```bash
x86_64-w64-mingw32-gcc -Wall -Wextra -Werror -municode \
  tools/diagnostics/send-input.c -o /tmp/send-input.exe

x86_64-w64-mingw32-gcc -Wall -Wextra -Werror -municode \
  tools/diagnostics/set-display-mode.c -o /tmp/set-display-mode.exe
```

- `send-input.exe <VK>` envía una pulsación y liberación de una tecla virtual de Windows.
- `set-display-mode.exe <ancho> <alto> <Hz>` prueba `ChangeDisplaySettingsExW` en fullscreen.

Ejecútalas con el Wine de `Regression.app`, la misma botella que se esté diagnosticando y
sin wineservers de otros builds. No uses `set-display-mode.exe` mientras un juego tenga la
pantalla capturada; primero cierra el juego limpiamente.

## Diagnóstico nativo de macOS

- `list-windows.swift [filtro] [--all]` enumera CGWindowID, capa y dimensiones para capturas
  reproducibles con `screencapture -l`.
- `stress-native-popover.sh` abre el panel instalado, despliega y pliega Aprendizaje doce veces,
  comprueba el árbol de accesibilidad y exige que Regression vuelva a reposo. Si macOS cierra el
  popover al cambiar el foco, el gate vuelve a resolver sus objetos AX en lugar de reutilizar una
  referencia caducada. El status item se localiza por su descripción accesible, no por el índice
  volátil de la barra de menús, y el script se reejecuta con zsh aunque se invoque accidentalmente
  mediante bash. No toca Steam, la botella ni los juegos.

El estrés necesita que la terminal tenga permiso de Accesibilidad y que Regression esté abierta.

## Métricas de ventanas Windows

`window-metrics.c` enumera resolución, escritorio virtual, rectángulos cliente, monitores y
DPI vistos desde Wine. Sirve para detectar desajustes entre la superficie de macOS, el
rectángulo Windows y el backbuffer de un juego.

```bash
x86_64-w64-mingw32-gcc -municode -O2 \
  tools/diagnostics/window-metrics.c -o build/window-metrics.exe
```

## Cierre limpio de una ventana Windows

`close-window.c` envía `WM_CLOSE` a la primera ventana cuyo título contenga el texto indicado.
Se usa únicamente después de respaldar los datos de la aplicación; no fuerza ni mata procesos.

## Carga aislada de DLLs

`load-dll.c` llama a `LoadLibraryW` sobre una ruta explícita y devuelve el código de error de
Windows. Permite distinguir un fallo del cargador de un fallo posterior de render sin iniciar
un juego ni sustituir DLLs del bundle.
