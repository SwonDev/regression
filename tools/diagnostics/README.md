# Utilidades de diagnóstico

Estas herramientas Win64 son auxiliares de prueba. No forman parte del runtime ni se
distribuyen dentro de `Regression.app`.

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
# Diagnósticos de Regression

Estas utilidades son instrumentación reproducible del motor. No forman parte del runtime
distribuido ni modifican la botella por sí solas.

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
