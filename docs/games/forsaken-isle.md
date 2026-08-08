# Forsaken Isle — expediente de compatibilidad

## Estado blindado

- **Steam App ID:** `347940`
- **Ejecutable:** `ForsakenIsle.exe`
- **Tecnología:** PE32 administrado, .NET Framework 4.5, MonoGame 3.5.1 Windows Desktop y
  SharpDX 2.6.3
- **Backend:** motor propio de Regression, gráficos baseline; extensión multimedia aislada
  Windows Media/GStreamer
- **Puntos de entrada:** botón de Regression y botón «Jugar» del Steam de Windows
- **Perfil compilado:** `windows-media-gstreamer-autodetect@1`
- **Observación perfecta:** `31104A67-1DE6-4C6D-BE5D-797A60648769`
- **Huella de motor/configuración:**
  `f6c2734165d679081d1f3e9126126561a19e375ef681bd8dfc84ef6f0788be69`
- **Resultado:** menú, generación de mundo, entrada y gameplay prolongado confirmados perfectos
  por el usuario.

El último run canónico `31BA54AF-5117-40B9-870F-BC9C11EBE66A` no se reinterpretó como éxito:
después de la validación se cerró con `SIGTERM` desde el laboratorio y la telemetría lo conserva
como `crashed`. La certificación procede de la observación histórica explícita, prevista para
validaciones visuales que no pueden enlazarse limpiamente a un run final.

## Síntoma y causa raíz

Forsaken Isle terminaba antes de mostrar el menú. La traza administrada acababa al crear un
`Song` con:

```text
SharpDXException HRESULT 0xC00D36BB
```

El contenido del juego contiene siete pistas **WMA2 dentro de contenedores ASF**. Wine Mono,
.NET 4.5, MonoGame y SharpDX ya cargaban; instalar otra versión de .NET no resolvía el punto de
fallo. `winegstreamer` llegaba a la ruta multimedia, pero el runtime general de Regression no
incluía ni el demultiplexor ASF ni el decodificador WMA2:

1. Sin extensión, GStreamer informó `Missing decoder: Advanced Streaming Format (ASF)`.
2. Añadir únicamente `libgstasf` abrió el contenedor y expuso el segundo requisito: WMA2.
3. Añadir `gst-libav` construido contra FFmpeg LGPL permitió decodificar la pista y el juego
   alcanzó menú, creación de mundo y gameplay.

Vessel se usó como referencia de arquitectura para revisar su detección de MonoGame/.NET, pero no
tenía una receta nominativa ni una prueba histórica vigente de Forsaken Isle. CrossOver tampoco
lo ejecutaba. La solución se obtuvo de la traza reproducida y de componentes públicos, sin copiar
DLL, configuración ni código propietario.

## Experimentos descartados y hallazgo de integración

| Candidato | Resultado | Conclusión |
|---|---|---|
| Instalar/forzar .NET 4.x | El fallo seguía en `Song` | El CLR no era la causa |
| GStreamer baseline | Falta ASF | Repro rojo determinista |
| Solo `libgstasf` 1.24.4 | Falta WMA2 | El contenedor ya se abría; faltaba códec |
| ASF + `gst-libav` 1.24.4 + FFmpeg 6.1.6 LGPL | Menú y gameplay | Combinación mínima funcional |
| Plugins integrados con GStreamer relocalizado dentro del bundle de desarrollo | Ventana vacía o detenida; `GstCocoaApplicationDelegate` duplicado y `fatal stalled cross-thread pipe` | `dyld` cargaba una segunda instancia de GStreamer |
| Plugins con los mismos install names GStreamer que `winegstreamer.so` | Menú canónico estable | Receta final exacta |

El último punto es esencial: en el bundle de desarrollo los dos plugins conservan las rutas
absolutas del toolchain que ya usa `winegstreamer.so`. No es una dependencia accidental del
juego, sino la forma de garantizar una sola instancia GStreamer dentro del proceso. Al construir
el asset público, `Scripts/package_release.sh` relocaliza **ambos lados** a `@rpath` y regenera el
manifiesto después de modificar los Mach-O.

## Corrección generalizable y aislada

`patches/wine-26.3.0-windows-media-autodetect.patch` añade al loader de Wine una receta
compilada, sin entradas procedentes de SQLite ni del registro:

- solo considera ejecutables situados bajo `steamapps/common`;
- deriva únicamente la raíz del juego actual;
- recorre como máximo 7 niveles y 4096 entradas;
- no sigue enlaces simbólicos (`lstat`);
- activa el componente solo si encuentra `.wma`, `.wmv` o `.asf`;
- exige que el payload firmado contenga `libgstasf.dylib` y `libgstlibav.dylib`;
- antepone el directorio únicamente al `GST_PLUGIN_PATH` de ese proceso;
- registra `REGRESSION_WINDOWS_MEDIA_PROFILE=windows-media-gstreamer-1@1`.

Steam, CEF y cualquier juego que no contenga esos medios conservan el entorno general. El perfil
Swift para App ID `347940` documenta y protege la identidad probada, pero la detección de contenido
permite que otro juego equivalente reciba la misma capacidad sin una lista nominativa y sin
modificar su ruta gráfica.

## Componente autoinstalable y autorreparable

`build/build-windows-media-component.sh` fija y construye:

- GStreamer plugins-ugly ASF `1.24.4`;
- GStreamer gst-libav `1.24.4`;
- FFmpeg `n6.1.6`, commit `f1e3a2bf7a2f2cde936d1ed97f09a26853d20125`, con GPL y
  nonfree desactivados;
- arquitectura x86_64 para el Wine estable bajo Rosetta.

El bundle incluye únicamente los plugins, las seis dylib necesarias de FFmpeg, licencias,
`BUILD.txt` y `manifest.sha256`. `Scripts/install_windows_media_component.sh` verifica cada hash
y la firma de los plugins y expone el componente mediante un enlace versionado y reparable en:

```text
~/Library/Application Support/Regression/Components/WindowsMedia/1
```

El launcher ejecuta la verificación/reparación antes de Steam. Si falta o está desviado, conserva
el estado anterior en `Backups/Components/WindowsMedia` y restaura el enlace al payload firmado;
no descarga código en tiempo de juego, no modifica la botella y no duplica los binarios.

## Matriz funcional y de no regresión

| Puerta | Evidencia |
|---|---|
| Repro original | run `D8DFDE71-76BC-40E5-A1CB-B22E9E6BDF64`: exit 1 antes de ventana; HRESULT `0xC00D36BB` |
| A/B mínima | `ab-asf-wma-menu.png`, SHA-256 `f71c8a3e…`; menú, mundo y gameplay confirmados |
| App canónica exacta | `canonical-exact-ab-menu.png`, SHA-256 `ca287770…`; usuario confirmó arranque perfecto |
| Activación aislada | log `regression-20260808-181437-262-11B71FC2.log`: una activación para `ForsakenIsle.exe`; ningún error Media Foundation/GStreamer fatal |
| Entrada y gameplay | generación de mundo y sesión prolongada confirmadas por el usuario |
| Certificación visible | `regression-forsaken-perfect-row.png`, SHA-256 `c54da00f…`; la app canónica muestra App ID `347940` y `Verificado perfecto: Regression` |
| Autorreparación | enlace del componente retirado en A/B y recreado por el instalador con manifiesto válido |
| Asset público en staging | `Regression-1.8.0-macos-arm64.tar.zst`, SHA-256 `3fce1b11…`; 559 MiB, firma válida, manifiesto completo y plugins con `@rpath` autocontenido; no publicado |
| Swift | 96 pruebas, 0 fallos; incluye perfil exacto/no heredado y launch idempotente |
| Estado protegido | `ntdll.so`, launcher, instalador y manifiesto fijados por SHA-256; botella y perfiles anteriores se verifican sin cambios |

## Tres iconos de Steam observados durante el laboratorio

No eran tres instalaciones ni un requisito de Forsaken Isle. Durante la última comprobación se
enviaron manualmente dos comandos `regressionctl launch` mientras el primer Steam todavía estaba
arrancando; cada CLI es un proceso independiente y no comparte el actor nativo que deduplica
solicitudes. Los dos clientes Wine redundantes y un `steamwebhelper` hicieron visibles tres iconos.

Después de cerrar Steam quedaron 25 helpers CEF con PPID 1 y ningún `Steam.exe`/`wineserver`;
se limpiaron como huérfanos. `ProcessLauncher` protege ahora la ruta normal de la app: dos
solicitudes activas idénticas en una misma instancia devuelven el mismo PID y log. La prueba
`testIdenticalActiveLaunchIsIdempotent` fija ese contrato. El CLI sigue siendo una herramienta de
diagnóstico independiente y no debe usarse en paralelo para simular dobles clics.

## PIN, evidencia y rollback

```text
ntdll.so:                    9e3eb235bbe60a06bd2da4fe0199be8370c1beb02438c9a98a9a0e0d7ff3014c
launcher regression-engine: 5d99cae95a60c84b8bc9759736ed9e9bec1dafe9b9af8a8190f26c232781ec60
instalador Windows Media:    c43da8ed5b54d6c663a5455d4296accde8d96f5237384f9322bea548e5c6d00d
manifiesto del componente:   ac662661fb3384c6ad100066391cab209f9de60b2e129fb92e07365ee6fe9bb1
```

- Estado previo completo: `backups/forsaken-isle-prechange-20260808-MusKYt/`.
- Investigación y capturas privadas: `work/forsaken-isle-20260808/`.
- Backups transaccionales del bundle nativo: `backups/native-packaging/`.
- La botella canónica no recibió DLL, override ni cambios de registro.

## Regla de no regresión

No instalar codecs en `system32`, no definir `GST_PLUGIN_PATH` globalmente y no activar el
componente por App ID aprendido. Cualquier cambio futuro en `winegstreamer`, GStreamer, FFmpeg,
el escáner acotado o la relocalización del asset debe repetir: ausencia de activación en Steam/CEF,
Forsaken Isle con menú y gameplay, prueba de autorreparación, `swift test`, estado protegido,
firma y tienda Steam renderizada. Los intentos fallidos se conservan; nunca se convierten en
recetas ejecutables.
