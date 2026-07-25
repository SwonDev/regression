# AGENTS.md — Reglas del proyecto Regression

Lee `README.md` primero (arquitectura, build, estado, método de investigación de CrossOver).

## Lo que es este proyecto

Motor Windows→macOS propio tipo CrossOver, compilado desde fuentes open-source. La app
`Regression.app` abre Steam de Windows con doble click. **No es** un gestor de botellas ni tiene
GUI: la UX objetivo es "abrir app → Steam", decidida por el usuario y no negociable.

## Reglas duras (errores que ya se han cometido y NO se repiten)

1. **Backup antes de tocar botella o bundle** (`backups/`). Sin excepciones.
2. **Validación visual obligatoria tras cualquier cambio gráfico**: relanzar app, capturar
   ventana de Steam (screencapture por CGWindowID), confirmar que la tienda renderiza. Si está
   negra → revertir al instante.
3. **NO overrides `d3d11/d3d10core/dxgi=native`** en el registro de la botella: las DLLs de DXMT
   son módulos wine y el override las hace "not found" (tienda negra). DXMT va en system32 sin
   override. Overrides solo para PE planas (d3d9 de DXVK sí).
4. **No mezclar d3d11/dxgi de Apple con DXMT** en system32 (CEF muere). d3d12* de Apple sí coexiste.
5. **Limpiar `dxmt-cxpresent-*.id` antes de lanzar** (ya en el launcher): ficheros stale →
   pantalla negra por hwnd reutilizado.
6. **No "probar cosas" en vivo sobre el estado bueno.** Cada experimento en copia de la botella
   o con dlls respaldadas; solo se aplica tras validar.
7. **No cambiar el modelo de IA ni el stack decidido** sin permiso explícito del usuario.
8. **Nada de ingeniería inversa de binarios propietarios** (GUI CrossOver, licencias, forks
   privados de DXMT/SPIRV-Cross). Se trabaja con fuentes LGPL oficiales, datos de botellas,
   crossties y comparativas A/B (método en README §3-4).
9. Responde siempre en **español**, con tildes. Código y comentarios del repo en el idioma del
   código existente.

## Protocolo de trabajo (OBLIGATORIO — cómo se hacen las cosas aquí)

Este proyecto es un sistema de muchas piezas acopladas (wine + DXMT + DXVK + D3DMetal + CEF +
botella + launcher). La historia demuestra que **casi todas las roturas vinieron de cambiar
varias cosas a la vez o de tocar el estado bueno para "probar"**. Sigue este protocolo siempre.

### 1. Antes de cambiar nada

1. **Reproduce el problema** y escribe en qué consiste exactamente (juego, momento, síntoma,
   captura). Si no puedes reproducirlo, no estás arreglando nada: estás adivinando.
2. **Descarta causas ambientales primero** (son la mitad de los "bugs" históricos):
   - ¿Hay wineservers de OTROS builds corriendo? (`ps aux | grep wineserver`) → mátalos. Un
     wineserver de otro build causa muertes silenciosas que parecen bugs del motor.
   - ¿Hay `services.exe` huérfanos (PPID 1, sin wineserver)? Son restos de sesiones wine
     muertas: dejan **iconos de Steam fantasmas en la barra de menús de macOS** y pueden
     interferir. Se limpian con `kill <pid>` — son seguros de matar.
   - ¿La botella tiene ficheros `dxmt-cxpresent-*.id` stale? (el launcher ya los limpia, pero
     si lanzas wine a mano, límpialos tú).
   - ¿El juego necesita Steam activo (DRM)? Los juegos Unity/IL2CPP mueren al iniciar si Steam
     no está corriendo — no es un bug del motor.
3. **Haz backup** de lo que vas a tocar (botella → copia o tar en `backups/`; dlls → cópialas
   con sufijo `.bak` junto al original). Sin backup no se toca nada.
4. **Consulta la tabla de PINs** (abajo). Si tu arreglo implica tocar un PIN, necesitas validar
   la matriz COMPLETA después, no solo tu juego.

### 2. Cómo se cambia algo

- **UNA variable por cambio.** Una dll, un override, un parámetro. Si cambias dos cosas y algo
  se rompe (o se arregla), no sabes cuál fue — y en este proyecto eso ya ha costado días.
- **Nunca experimentes sobre el estado bueno.** Experimentos en copia de la botella o con dlls
  respaldadas. Solo se aplica al estado bueno tras validar.
- **Método de referencia: A/B contra CrossOver** (README §3-4). Antes de inventar una solución,
  mira qué hace CrossOver 26.3.0 (fuentes en `sources-26.3.0/`, botella real, crossties) y
  replica eso. La paridad se consigue igualando el stack exacto, no improvisando por juego.

### 3. Después de cambiar algo: matriz de validación

Según lo que tocaste, valida TODO lo de su fila antes de dar el cambio por bueno:

| Si tocaste… | Debes validar (con captura visual) |
|---|---|
| Wine (build, dlls en wine-root) | Steam tienda renderiza + Moonlighter 2 (Unity) + Palworld |
| DXMT (d3d11/dxgi/d3d10core) | Steam tienda (CEF) + Palworld (personajes visibles) |
| DXVK / d3d9 | Un juego D3D9 + Steam tienda |
| winemac.drv / parche cross-process | Steam tienda + clicks precisos + Palworld |
| Launcher (env, rutas) | Arranque desde cero: Steam tienda + un juego |
| Registro de la botella (overrides, RetinaMode) | Steam tienda + clicks + un juego |
| Fuentes de la botella | Steam arranca (sin ellas crashea con assert Win32Font) |

Validar = lanzar, capturar con `screencapture -x -l <CGWindowID>` y **mirar la imagen**.
"Compila" o "el proceso corre" NO es validación. Si algo de la matriz falla → **revertir al
instante** (para eso está el backup) y repensar, no apilar otro cambio encima.

### 4. Tabla de PINs (versiones/config FIJADAS — no tocar sin validar la matriz completa)

| Pieza | Valor fijado | Razón | Test que lo protege |
|---|---|---|---|
| DXMT | **v0.72 + parche cross-process propio** | `main` hace invisibles los skeletal meshes | Palworld (personaje visible) |
| Wine | **CX 26.3.0 (`sources-26.3.0/wine`), `--prefix` horneado a la app** | Con prefix `/usr/local` mueren Unity y CEF | Moonlighter 2 + Steam tienda |
| d3d11/dxgi/d3d10core | DXMT en system32 + wine-root, **SIN override `native`** | El override las marca "not found" | Steam tienda |
| d3d11/dxgi de Apple | **NO** en system32 (solo d3d12*) | CEF muere | Steam tienda |
| d3d9 | DXVK 1.10.3, override `native` sí (PE plana) | Funciona | Juego D3D9 |
| RetinaMode | `n` (HKCU\Software\Wine\Mac Driver) | Alinea clicks | Click en tienda |
| Fuentes | 55 TTFs (corefonts + CJK) en la botella | Sin ellas Steam crashea (assert Win32Font) | Steam arranca |
| DLLs PE | **SIN strip** | El strip rompe unwind SEH y firma de módulos | Juegos Unity |

### 5. Instalación y rutas (no improvisar)

- La **app canónica vive en el proyecto** (`Regression.app/`) porque el `--prefix` del wine va
  horneado a esa ruta absoluta. `/Applications/Regression.app` es un **symlink** a ella.
- **No copies la app a otro sitio ni la muevas** sin recompilar wine con el nuevo `--prefix`.
- Tras cualquier `make install` o cambio en el bundle: `codesign --force --deep --sign - Regression.app`.
- Tras recompilar/instalar: relanzar y validar la tienda con captura (regla 2).

### 6. Definición de "hecho"

Un cambio está hecho cuando: (1) el problema original ya no se reproduce, (2) la matriz de
validación de su fila pasa entera con capturas, (3) hay backup del estado nuevo si es mejor,
(4) README/AGENTS reflejan el cambio. Si solo cumples el punto 1, has arreglado una cosa y
quizá roto otra — que es exactamente lo que este protocolo existe para evitar.

## Estado rápido (2026-07-25, FINAL)

- OK total con el wine de prefijo propio: **Steam completo, Moonlighter 2 (Unity IL2CPP),
  Palworld (personaje), Grim Dawn, Romestead**, DXVK D3D9.
- **PIN: DXMT = v0.72 + parche cross-process** (versión exacta de CrossOver). `main` rompe los
  skeletal meshes de Palworld — NO actualizar sin probar Palworld.
- **PIN: wine compilado con `--prefix` apuntando a la app** (Regression.app/Contents/SharedSupport/wine-root).
  Con el prefix por defecto (/usr/local) los juegos Unity morían al iniciar y CEF tenía crashes.
- Backups: `backups/regression-blindado-20260725.tar.gz` (**el de referencia**: app + docs +
  parches + scripts, estado verificado OK al 100 %) y `backups/botella-config-20260725.tar.gz`
  (registros + 55 fuentes + DLLs DXMT/DXVK de system32). Para volver a este punto: restaurar
  ambos. Históricos: `regression-app-final-20260725.tar.gz` (solo app).
- **Instalación**: `/Applications/Regression.app` → symlink a la app del proyecto (canónica).
  Lanzar con `open -a Regression` desde cualquier sitio.

## Verificación rápida

```bash
open -a "$PWD/Regression.app"            # debe abrir Steam y renderizar la tienda
swift /tmp/winid3.swift                  # id de la ventana "Steam" (si existe el script)
screencapture -x -l <id> /tmp/check.png  # captura y revisar visualmente
```

## Build

Scripts en `build/` (README §5). Toolchain ya compilado en `toolchain/x86/` — no recompilar
salvo cambio de versiones. Wine: `build/build-wine.sh`. DXMT: `build/build-dxmt.sh`.
