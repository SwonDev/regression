# AGENTS.md — Reglas del proyecto Regression

Lee `README.md` primero (arquitectura, build, estado y método de investigación FOSS de Regression).
Este archivo es la fuente de verdad de reglas y protocolo (Codex lo lee nativamente).
`CLAUDE.md` es su espejo adaptado para Claude Code — si difieren, manda este.

## Lo que es este proyecto

`Regression.app` es el punto de entrada nativo e independiente para ejecutar Steam de Windows en
macOS. Regression es el único backend operativo, usa su propio runtime, su propia botella y la
única carpeta física `steamapps`, ubicada dentro de esa botella. La app vive en la barra de menús,
no en el Dock, y no requiere instalar, abrir, actualizar ni licenciar CrossOver.

Las menciones a CrossOver se conservan exclusivamente como historia y procedencia de observaciones
antiguas. No es un selector, una ruta de ejecución, una fuente de red ni un propietario alternativo
de juegos. La migración de custodia mueve la carpeta física sin copiar sus aproximadamente 110 GB,
deja ausente el antiguo `steamapps` de CrossOver y no mantiene enlaces compartidos. La base local de
aprendizaje conserva el historial, pero no aplica perfiles automáticamente.

## Reglas inviolables

### Principios (valen más que cualquier arreglo concreto)

1. **JAMÁS se integra algo que rompe lo que ya funciona.** Un arreglo que apaga otra cosa
   no es un arreglo: se revierte al instante y se repiensa. No se negocia ni "de momento".
   Lo que decide es la matriz de validación (ver Protocolo), no las intenciones. Si al
   validar algo que antes funcionaba falla → revertir primero, preguntar después.
2. **El baseline de Regression y las fuentes FOSS mandan.** Si un juego falla, se compara contra
   el último perfil propio blindado y las versiones exactas, convenciones de build, wiring de DLLs,
   configuración y fuentes oficiales del runtime. No se consulta ni ejecuta otro producto para
   diagnosticar. La paridad se demuestra dentro de Regression, no se presupone.
3. **Autonomía operativa estricta.** CrossOver no se invoca desde la aplicación ni desde el CLI,
   no comparte botella, biblioteca o credenciales y no puede ser necesario para lanzar o reparar.
   No se copian DLLs, dylibs ni binarios propietarios. Las observaciones históricas solo explican
   expedientes antiguos; cualquier implementación actual procede de fuentes FOSS oficiales o de
   recursos Apple localmente autorizados.
4. **Legalidad limpia.** Solo fuentes open-source oficiales (Wine/DXMT/DXVK/MoltenVK LGPL,
   Apache, zlib…). Nada de descompilar ni extraer código de binarios propietarios (GUI de
   CrossOver, sistema de licencias, forks privados de DXMT/SPIRV-Cross). Los binarios de
   Apple (GPTK: D3DMetal.framework, libd3dshared.dylib) se usan tal cual los distribuye
   Apple, solo en local, jamás redistribuidos (por eso no están en el repo ni en GitHub).
   Esto es un proyecto personal/educativo: se documenta como tal.
5. **I+D sin techo, promoción aislada y con evidencia.** Los PIN protegen el motor estable;
   no son un límite para investigar un juego que aún falle. En un perfil experimental aislado
   se puede usar Rosetta, otra versión —también más reciente— de Wine, otro toolchain o cualquier
   dependencia abierta necesaria. El baseline propio y la evidencia reproducible sirven para elegir
   y medir cada cambio. El candidato solo se blinda cuando funcionan render, entrada, opciones
   persistentes y gameplay, y nunca puede modificar otro perfil verificado ni introducir una
   dependencia propietaria en el motor propio. Un cambio global exige además su matriz completa.

### Reglas técnicas duras (errores que YA se han cometido y NO se repiten)

1. **Backup antes de tocar botella o bundle** (`backups/`). Sin excepciones. Antes y después de
   empaquetar, ejecutar `build/verify-protected-state.sh`; añadir `--include-bottle` cuando la
   botella canónica esté disponible.
2. **Validación visual obligatoria tras cualquier cambio gráfico**: relanzar app, capturar
   ventana de Steam (screencapture por CGWindowID), confirmar que la tienda renderiza. Si está
   negra → revertir al instante.
3. **NO overrides `d3d11/d3d10core/dxgi=native`** en el registro de la botella: las DLLs de DXMT
   son módulos wine y el override las hace "not found" (tienda negra). DXMT va en system32 sin
   override. Overrides solo para PE planas (d3d9 de DXVK sí).
4. **La dxgi de DXMT es intocable EN PAREJA**: va en system32 Y en wine-root. Wine valida la
   pareja; si wine-root lleva otra dxgi (p.ej. la de wine), la de DXMT deja de cargar y TODOS
   los juegos D3D11 mueren al instante (exit 53). D3D12 necesita la dxgi de wine — el
   conflicto y las vías de solución están documentados en README §8.
5. **No mezclar d3d11/dxgi de Apple con DXMT** en system32 (CEF muere). d3d12* de Apple sí coexiste.
   OJO: las dlls de Apple del GPTK son formato builtin (como las de DXMT): como "native" dan
   "not found"; se cargan solo desde su propio árbol (`lib/apple_gptk/wine`).
6. **Grim Dawn está fijado a D3DMetal por proceso.** `grim dawn.exe` usa el perfil interno
   `lib/profiles/grim-dawn` → `../apple_gptk/wine`, activa D3DMetal solo en ese proceso y fuerza
   `atidxx64/d3d9/nvapi64/nvngx=builtin`. No convertirlo en registro o entorno global: la mezcla
   D3DMetal + d3d9 DXVK fue la causa reproducida de negro y parpadeo.
7. **Limpiar `dxmt-cxpresent-*.id` antes de lanzar** (ya en el launcher): ficheros stale →
   pantalla negra por hwnd reutilizado.
8. **No "probar cosas" en vivo sobre el estado bueno.** Cada experimento en copia de la botella
   o con dlls respaldadas; solo se aplica tras validar.
9. **Antes de diagnosticar, descartar el entorno** (la mitad de los "bugs" históricos):
   wineservers de otros builds corriendo (muerte silenciosa), `services.exe` huérfanos
   (iconos Steam fantasma en la barra de menús), diálogo modal de Steam Cloud bloqueando el
   IPC (los juegos mueren al instante sin log: desactivar cloud del appid en
   `localconfig.vdf`), juego que necesita Steam activo por DRM.
10. **Tras `make install` o tocar el bundle: `Scripts/sign_regression.sh Regression.app`**.
    La firma Apple Development estable conserva el `designated requirement` y, con él, las
    decisiones de privacidad entre builds. No volver a firma ad hoc salvo fallback explícito en
    una máquina sin certificado: obliga a macOS a tratar cada compilación como una app distinta.
11. **PE sin strip** (el strip rompe unwind SEH y la firma de módulos builtin).
12. **No cambiar el modelo de IA ni el stack decidido** sin permiso explícito del usuario.
13. Responde siempre en **español**, con tildes. Código y comentarios del repo en el idioma del
    código existente.
14. **Todo juego confirmado perfecto debe quedar visible como blindado.** Inmediatamente después
    de la confirmación visual —del usuario o del agente cuando este haya controlado directamente
    toda la matriz—, verificar la ejecución exacta en la base local con veredicto `perfect`
    (render, entrada, opciones y gameplay en `passed`) y refrescar la app hasta comprobar la fila
    verde `Verificado perfecto: Regression`. La validación autónoma exige capturas de gameplay,
    cursor/entrada, pausa, cambio y persistencia de opciones, restauración del estado y cierre;
    no se infiere de procesos o logs. Los fallos anteriores se conservan como historial y el
    perfil perfecto tiene prioridad. Si la validación es histórica y anterior a la telemetría,
    registrar una observación importada con App ID, nombre, backend, nota y evidencia/rollback.
    Un exit code 0 jamás crea este estado por sí solo. La confirmación modal del veredicto
    perfecto es una salvaguarda deliberada y no se elimina. Tampoco puede certificarse un run que
    siga en `preparing` o no tenga PID: cualquier marca heredada así se anula, no se promociona.
15. **Los datos externos heredados no tienen autoridad.** Las filas `external_*` antiguas se
    conservan solo para interpretar historia; no se sincronizan, no se muestran como recomendación
    y nunca seleccionan motor, reparación, lanzamiento o certificación. Ver
    `docs/compatibility-platform.md`.
16. **No atribuir un Steam Wine solo por el texto de `ps`.** Tras desacoplarse, macOS suele
    mostrar únicamente `C:\...\Steam.exe`, sin ruta del runtime ni padre útil. El inspector debe
    excluir `steamwebhelper.exe` y resolver el backend mediante los ficheros abiertos del cliente
    real (`lsof`). Un wineserver vivo por sí solo no demuestra que Steam esté activo.
17. **La terminación nativa serializa el estado local.** Cancelar monitorización, reconciliar y
    cerrar SQLite antes de responder a AppKit. La aplicación no espera ni finaliza peticiones a
    CodeWeavers. El cierre limpio instalado debe probarse después de tocar este flujo.
18. **Perfecto funcional no significa rendimiento óptimo.** Un blindado conserva su ejecución,
    configuración y motor exactos aunque exista una versión más nueva. Las alternativas modernas
    entran como candidatos por juego: fuente y huella verificadas, aislamiento, rollback, matriz
    funcional completa y métricas comparables. Nunca promover por número de versión ni ejecutar
    comandos almacenados/aprendidos desde SQLite. Las futuras reparaciones solo pueden usar
    recetas compiladas, permitidas y versionadas.
19. **El popover no usa layouts perezosos anidados.** Las listas actuales son pequeñas y deben
    usar pilas deterministas dentro del único `ScrollView`. `LazyVStack` + `DisclosureGroup`
    provocó un ciclo de AttributeGraph, cursor multicolor y 99,7 % de CPU. Tras tocar la UI,
    desplegar/plegar Aprendizaje repetidamente, confirmar que accesibilidad responde y medir que
    Regression vuelve a reposo antes de empaquetar.
20. **No instalar mitades de builds Wine distintos ni diagnosticar por una línea aislada.** Para
    perfiles se usa `build/wine-profile`, que conserva la configuración de origen, y se verifican
    también `x86_64-windows/ntdll.dll` e `i386-windows/ntdll.dll`. El warning
    `Win32Font.cpp:1129` aparece igualmente mientras Steam sigue vivo, renderiza y lanza juegos:
    no prueba un crash. La decisión exige proceso, captura y huella. El perfil DD2 mantiene el
    `winemac` global intacto y lleva su driver Retina solo en
    `lib/profiles/dragons-dogma-2`.
21. **Una prueba de Steam es una sesión por backend + App ID, no una fila por PID.** Launchers y
    ejecutables principales se conservan en `run_processes`, pero comparten un único run y una
    única verificación. No volver a cerrar en el primer `no longer tracking`: esperar al último
    proceso y a la ventana de unión. Un lanzamiento hecho dentro de Steam recibe una captura
    diagnóstica `processStartBoundary`; no llamarla prelaunch exacta ni mezclarla con la captura
    `preLaunch` del botón de Regression.
22. **DD2 distingue resolución lógica de backing Retina.** El perfil estable usa 1512×945 en
    ventana sin bordes y presenta 3024×1890 físicos. No fijar 3024×1890 como resolución interna:
    esa variante desbordó la ventana, mostró el cursor de macOS y desplazó el click. El letterbox
    16:9 ya estaba documentado en comparaciones históricas y se conserva como incidencia conocida.
23. **Todo I+D abre y mantiene un expediente reproducible.** Antes del primer cambio registrar
    síntoma, baseline Regression e hipótesis falsables; cada experimento cambia una sola
    dimensión, está aislado y tiene rollback. No se cierra por cansancio ni por número de
    intentos: solo con las puertas/evidencias de `docs/compatibility-research.md` y un run perfecto
    exacto de Regression, o se pausa por una dependencia externa concreta y reanudable. Los
    resultados negativos se conservan y nunca se convierten en recetas ejecutables.
24. **Toda prueba de juego empieza con el preflight canónico.** La app y `regressionctl launch`
    deben comprobar el App ID y backend exactos antes de enviar `-applaunch`. Un bloqueo detiene
    la prueba; un aviso se conserva con el run. El preflight solo observa: jamás termina procesos,
    borra marcadores, modifica botellas ni certifica compatibilidad. Su informe v1 debe persistir
    vinculado a la ejecución exacta y conservarse en la exportación; ver
    `docs/game-test-readiness.md`.
25. **DragonSword usa D3DMetal como conjunto indivisible por proceso.**
    `DSClient-Win64-Shipping.exe` selecciona `lib/profiles/dragonsword` y fuerza como builtin
    `atidxx64/d3d9/dcomp/d3d11/d3d12/dxgi/nvapi64/nvngx` únicamente en ese proceso. Anteponer el
    perfil sin neutralizar el load-order global mezcló D3DMetal con la `dxgi` de DXMT y congeló
    Unreal en el logo. No mover este conjunto al registro ni al entorno global; ver
    `docs/games/dragonsword-awakening.md`.
26. **Una limitación visual reproducida en el baseline propio no se maquilla como perfecta.** Si el
    juego no ofrece el modo de pantalla necesario, conservar `Funciona con incidencias`, captura y
    configuración comparables. No forzar resoluciones en el estado bueno. Rotwood fija 1512×870
    dentro de 1512×982; su expediente conserva comparaciones de terceros solo como historia.
27. **Hell Clock está blindado sobre el baseline general, sin perfil especial.** El run
    `2F2DE49D-DE01-4A7F-B2D2-39195EA5D68B` pasó render, gameplay real, cursor Retina, pausa,
    opciones, persistencia, restauración y cierre. Su huella de motor es `033fd4eb…` y la de
    configuración `aa2c5e6b…`; no crear un perfil por ejecutable ni tocar el runtime global para
    este juego sin una regresión reproducida y una matriz completa. Ver `docs/games/hell-clock.md`.
28. **Heroes of Hammerwatch II activa OpenGL forward-compatible solo en `HWR2.exe`.** BGFX pide
    un contexto core 3.2 sin el bit que macOS exige y falla con `0x2095`. El Wine CX 26.3 abierto
    ya contiene `CW Hack 24834`; el router del proceso define `CX_FWD_COMPAT_GL_CTX=1` únicamente
    para el ejecutable exacto y conserva intacto el driver global. No trasladar la variable a
    Steam, al registro ni al entorno general. Run perfecto:
    `F8E4EA27-2E6B-439C-AC93-BD927035B5B5`; ver
    `docs/games/heroes-of-hammerwatch-2.md`.
    Su identidad compilada `heroes-hammerwatch-2.opengl-forward-compatible@1` forma parte de la
    huella de motor `af59b82a9e8102995ccbf5a9c93e1e9e6c62afe3213bea8a0bbe2ff7726236f1`;
    no ejecutar jamás comandos aprendidos desde SQLite.
29. **Easy Anti-Cheat solo se investiga mediante su ruta oficial.** No desactivar, parchear,
    simular ni eludir EAC. En FANTASY LIFE i, el código `206` de macOS ya se superó únicamente
    en un laboratorio Linux ARM aislado ejecutando Proton x86-64 oficial sobre FEX. La prueba
    anónima terminaba en `210` porque `lsteamclient` no obtenía `ConnectToGlobalUser`; con el
    cliente Steam Linux oficial autenticado, el mismo candidato descarga el módulo, obtiene
    HTTP `200`, inicia el mapeo Wine 11 y avanza hasta `208 Cannot run under Virtual Machine`.
    Ese resultado es una política externa observada, no una autorización para ocultar, simular
    o falsear la VM. La repetición desde la instalación creada y lanzada íntegramente por Steam
    ya confirmó el mismo `208`: EULA aceptado por el usuario, manifiesto `StateFlags=4`, build
    `21998011`, prerrequisitos oficiales completos y ejecutable principal ausente. El candidato
    FEX válido es la revisión FS/GS v3:
    conserva las bases dedicadas en long mode y pasa las sondas no-cero; la v2 que devolvía
    selector `0` queda descartada aunque también alcanzase `210`. Proton debe compartir `HOME`
    con el cliente Steam Linux oficial de la misma sesión aislada; no se copian credenciales ni
    tokens de otro backend. El laboratorio gráfico UTM/Venus es un clon separado:
    `/usr/bin/FEX` permanece intacto. Como los `execve` x86 descendientes reentran por
    `binfmt_misc`, la A/B v3 completa usa overrides no persistentes en `/run/binfmt.d` solo con
    Steam/FEX en reposo y restaura ambos handlers a `/usr/bin/FEX` al detenerse. La relajación
    temporal de AppArmor userns solo puede vivir dentro de esa VM y debe revertirse al pausar.
    No quedan A/B legítimas dentro de esa VM: solo se reabre si el proveedor cambia su soporte o
    existe una ruta no-VM que conserve intactos los componentes oficiales. El I+D host nativo ya
    compila FEXCore público `a04b0241` como Mach-O arm64, ejecuta ELF x86-64 reales con glibc y
    transporta el cliente Wine y el `wineserver` oficiales de Proton 11: 52/52 peticiones, 81
    respuestas, 29/29 `writev`, 3/3 `create_file` y servidor con salida `0`. Los sockets Unix
    solicitados por glibc se traducen de forma explícita y todo `connect` absoluto queda
    confinado al RootFS privado, nunca al host. v270 demuestra sintéticamente una tabla acotada
    para traducir las vistas lógicas altas que `ntdll.so` necesita (`0x100000000` y
    `0x7ffffff30000`) a páginas host ordinarias, sin romper las puertas JIT anteriores. v271
    añade consultas huésped↔host reproducibles, da prioridad a la página redirigida y rechaza
    mapas huésped u host solapados; su sonda no crea hilo ni ejecuta código huésped. v272
    reutiliza exactamente el mismo bloque JIT tras sustituir el backing A por B con el hilo
    detenido, verifica que A protegido ya no recibe accesos y limpia/protege/desmapea ambas
    regiones sin traducciones residuales. v273 provoca exactamente un `SIGBUS` controlado dentro
    del JIT, traduce `si_addr` a `0x100000270`, recupera el RIP huésped exacto y restaura
    handlers, mapa y protección; la reconstrucción pública limpia supera toda la matriz. La
    siguiente frontera aplica ese contrato a la mitad PE/Windows oficial de Wine en un RootFS
    nuevo. No se ha ejecutado todavía el orquestador Proton, Steam, EAC ni el juego.
    Este avance no es una integración estable, no ha iniciado el ejecutable principal y no
    permite marcar el juego como compatible; ver `docs/games/fantasy-life-i.md`.
30. **Fields of Mistria está blindado sobre el baseline con el winemac parcheado.** El runner
    propio del estudio (Rust + SDL3) renderiza con OpenGL 4.1; la pantalla verde del arranque
    era la CGL surface clavada al backing 1×1 inicial porque el token `GL_FLUSH_UPDATED` de
    win32u es one-shot y puede perderse (incluido el bug upstream `flags = GL_FLUSH_INTERVAL`).
    El parche `patches/wine-26.3.0-winemac-gl-surface-resync.patch` re-sincroniza el tamaño
    desde el client rect vivo dentro de `macdrv_surface_flush`; su hash fijado en
    `build/verify-protected-state.sh` es `4723d219…` y la mitad PE `winemac.drv` conserva el
    PIN `da91ec70…`. No crear perfil por ejecutable ni mover la lógica a win32u. Run perfecto:
    `BAAC2B06-3CAD-467A-B1F1-834B76B794AD`; expediente `docs/games/fields-of-mistria.md`.
    Además: otro proyecto (Switch2Bridge) instaló el 2026-08-04 un shim de
    `libSDL2-2.0.0.dylib` dentro del bundle; el usuario decidió conservarlo y el bundle se
    refirmó con él. No "limpiarlo" sin consultar.
31. **Titan Quest II usa una receta compilada de doble punto de entrada.** El App ID `1154030`
    inicia Steam y envía `Steam.exe -applaunch 1154030`, la misma ruta que el botón «Jugar».
    Steam recibe todavía
    `ImagePathName=TQ2.exe` desde wineserver, por lo que `env.c` redirige únicamente el sufijo
    completo `\\steamapps\\common\\Titan Quest II\\TQ2.exe` antes de mapear PE. El Shipping
    exacto activa GPTK 4.0b2 desde el componente local verificado y fuerza la ruta D3DMetal
    completa solo en ese proceso. No convertirlo en override global, bypass genérico de VC++ ni
    receta aprendida desde SQLite. El payload de Apple nunca se versiona ni redistribuye; el
    instalador integrado solo verifica, repara y conserva rollback desde el DMG oficial. PIN de
    `ntdll.so`: `adb97ddb…`. Run perfecto final de 1.8.0:
    `228467BB-AECE-40EF-8FE5-E739250AA859`, huella exacta `fb45e5ed…`; expediente
    `docs/games/titan-quest-2.md`.
32. **Forsaken Isle activa Windows Media solo por contenido y por proceso.** El App ID `347940`
    usa .NET 4.5, MonoGame 3.5.1 y SharpDX 2.6.3; sus siete pistas WMA2/ASF fallaban con
    `0xC00D36BB` porque el GStreamer general no incluía ASF ni WMA2. El loader examina solo la
    raíz del juego actual bajo `steamapps/common`, con `lstat`, profundidad 7 y presupuesto 4096,
    y antepone el componente LGPL `windows-media-gstreamer-1@1` únicamente si encuentra
    `.wma`, `.wmv` o `.asf`. No definir `GST_PLUGIN_PATH` global, no instalar codecs en la
    botella y no relocalizar solo una mitad de GStreamer: eso cargó dos instancias y produjo
    `GstCocoaApplicationDelegate` duplicado y `fatal stalled cross-thread pipe`. El instalador
    verifica hashes/firmas y repara un enlace versionado fuera del bundle. Observación perfecta:
    `31104A67-1DE6-4C6D-BE5D-797A60648769`, huella `f6c27341…`; expediente
    `docs/games/forsaken-isle.md`.
33. **La release pública recompila el arranque de Wine para su ruta canónica.** El bundle de
    desarrollo lleva un `--prefix` absoluto hacia el checkout y no se puede convertir en
    descargable sustituyendo texto ni copiándolo sin más. `build/build-public-wine-runtime.sh`
    recompila el wrapper instalado `tools/wine/wine`, el loader interno `loader/wine`,
    `server/wineserver` y `dlls/ntdll/ntdll.so` para
    `/Applications/Regression.app/Contents/SharedSupport/wine-root`; conserva las recetas
    compiladas de Titan Quest II y Windows Media y rechaza cualquier prefijo local. Después,
    `build/verify-release-asset.sh` extrae el tar real y verifica hashes, firmas, VC++/UCRT en
    ambas arquitecturas, medios, dependencias Mach-O, enlaces, ausencia de GPTK o copias de
    laboratorio y un arranque real `wine --version` que debe cargar `ntdll.so`. Nunca copiar
    `loader/wine` a `bin/wine`: el primero pertenece en `lib/wine/x86_64-unix/wine`; el wrapper
    contiene `BINDIR/LIBDIR` y es el único punto de entrada instalado. El tar debe conservar
    xattrs para no perder las firmas de scripts. Una instalación nueva y una actualización
    conservan Regression como único backend operativo; las comparaciones históricas viven en la
    documentación y la base local, no en el producto. No publicar ni instalar una versión que no supere este
    verificador sobre el mismo asset que se subirá a GitHub.
34. **El README raíz es la portada del producto, no el diario de laboratorio.** Debe conservar
    la R oficial, el branding definido en `DESIGN.md`, instalación mediante `releases/latest`,
    capacidades, compatibilidad certificada y rutas claras hacia la documentación. Los detalles
    de arquitectura, matrices A/B, historiales, comandos extensos y expedientes viven en
    `docs/` y se enlazan desde `docs/README.md`. No volver a fijar una versión en la URL de
    instalación ni acumular cronologías en la portada; la release y sus badges deben poder
    avanzar sin que el README quede obsoleto.
35. **Dragonwilds aísla solo el overlay EOS del Shipping exacto.** El crash reproducido exige
    simultáneamente `EXCEPTION_ACCESS_VIOLATION`, D3D11, Steam Overlay, EOSOVH y EOSSDK. La receta
    `unreal-d3d11-dual-overlay-isolation-v1` deshabilita únicamente
    `EOSOVH-Win64-Shipping` dentro de un basename PE exacto; Steam Overlay, EOSSDK y DXMT siguen
    activos. El aprendizaje solo puede persistir `ejecutable + enum conocido`, con límites,
    snapshot y recibo; nunca rutas, DLL arbitrarias ni comandos. Run perfecto:
    `E5244599-5E9F-4F78-BB9B-00CC781E539E`; ver `docs/games/dragonwilds.md`.
36. **Tinkerlands repara estado, no el driver global.** La receta
    `gamemaker-retina-fullscreen-v1` solo transforma `fullscreen=0` a `1` cuando el JSON exacto
    de Tinkerlands declara además `resolution>=6`; conserva el resto, hace backup, es atómica e
    idempotente. No cambiar `RetinaMode`, resolución ni fullscreen globales. Run perfecto:
    `0B6589C9-374B-4570-A30A-645EEF57A497`; ver `docs/games/tinkerlands.md`.
37. **Moonlighter 2 protege el baseline Unity sin perfil especial.** El run
    `9E384BCC-18FA-4BE6-A879-8AA1E724E4C4` pasó menú, gameplay, movimiento, pausa, opciones
    cambiadas/restauradas y cierre sobre el runtime general. No crear una excepción mientras el
    baseline pase. Sigue siendo la puerta Unity obligatoria ante cualquier cambio común de Wine;
    ver `docs/games/moonlighter-2.md`.
38. **La autoactualización usa un único canal estable y nunca interrumpe Regression.** La app
    consulta `SwonDev/regression/releases/latest` al arrancar y cada seis horas, acepta solo una
    versión semántica posterior que no sea draft/prerelease y exige el asset exacto
    `install_regression.sh` del repositorio oficial con digest SHA-256 de GitHub. Está activada por
    defecto, pero solo instala desde `/Applications/Regression.app` y cuando Steam de Regression y
    las operaciones críticas están en reposo. El staging no sigue symlinks y usa permisos privados;
    el modelo cierra primero SQLite y sus tareas y solo después pide a AppKit la terminación; el
    instalador espera el cierre limpio del PID, verifica el release completo, conserva botella y
    GPTK autorizado, archiva rollback y relanza. Si el instalador falla, restaura y vuelve a abrir la
    app anterior; la misma release no se reintenta automáticamente en bucle. Nunca terminar un juego
    para actualizar, aceptar un asset de otro repositorio ni sustituir este flujo por comandos aprendidos; ver
    `docs/automatic-updates.md`.
39. **Cross Blitz combina dos reparaciones Unity estrictamente por proceso.** El App ID
    `1619520` activa `unity-intro-media-borderless-stability`: deshabilita únicamente
    `winegstreamer` para `Cross Blitz.exe`, conserva Media Foundation y añade el argumento
    oficial `-window-mode borderless`. La primera parte evita que la intro corrompa la
    superficie; la segunda impide que Unity 2021.3 vuelva a una superficie gris al cambiar de
    escritorio o recuperar foco en macOS. No cambiar el driver, el registro ni multimedia
    globales. Run perfecto `8EB67186-3D63-4C29-9535-BFC1BAB0A52B`; ver
    `docs/games/cross-blitz.md`.
40. **Luminary Demo protege dos fallos generales de Wine, no una excepción gráfica.** El App ID
    `4059020` usa un bootstrap Unreal que debe resolverse de forma acotada al Shipping instalado;
    después, el runtime aplica el backport oficial de Wine que invalida y verifica los handles
    `HDEVNOTIFY` entre `cfgmgr32` y `sechost`. El crash tardío estaba en
    `CM_Unregister_Notification`/`I_ScUnregisterDeviceNotification`, no en D3DMetal ni DXMT.
    No añadir bypass de VC++ ni override por juego. Run perfecto
    `EE1C5A66-1AAA-4594-B30D-1E8ECFA5A27B`; ver `docs/games/luminary-demo.md`.
41. **Los auxiliares Steam se limpian solo al consolidar la sesión exacta.** Después de que
    todos los PID Windows del run hayan terminado, `GameSessionArtifactCleaner` puede enviar
    `TERM` únicamente a `gameoverlayui64.exe` o `steamerrorreporter*.exe` que coincidan a la vez
    con `-gameid`, un PID Windows finalizado y un `lsof` del runtime de Regression. Nunca termina
    Steam, steamwebhelper, wineserver, otro juego ni otro runtime. El preflight sigue
    siendo de solo lectura.
42. **Borderlands 4 combina D3D12 externo y una traducción ABI estricta.** El App ID `1285190`
    selecciona GPTK 4.0b2 únicamente para el basename `Borderlands4.exe`. Su helper Unix ejecuta
    el syscall Linux x86-64 63 (`uname`) dentro de `__wine_unix_call_dispatcher`; macOS responde
    `SIGSYS` y el manejador anterior corrompía el retorno hasta producir el page fault bajo.
    `wine-26.3.0-macos-linux-uname-sigsys.patch` borra cualquier activación heredada y solo la
    habilita para el basename compilado exacto; dentro del manejador emula la estructura Linux
    solo si coinciden `is_inside_syscall`, `RAX=63` y el opcode previo exacto `0f 05`. La
    variante global dejó negra la tienda CEF en una A/B y fue descartada. No ampliar esa firma,
    globalizar D3DMetal ni copiar el payload de Apple al release. La certificación final es la
    observación importada final `1BDCD9E2-D5F1-4C30-BBDA-43B0E5B3BBCA`, con huellas
    `a2ec1490…`/`d7172135…` posteriores al aislamiento de CEF y respaldada por confirmación
    explícita de gameplay, HUD, cámara, entrada y rendimiento perfectos; ver
    `docs/games/borderlands-4.md`.
43. **Solo `/Applications/Regression.app` puede ser una aplicación descubrible.** La instalación
    estable es un bundle físico, firmado y compilado para esa ruta; nunca un enlace al checkout.
    Los bundles de desarrollo pueden existir mientras se compila o valida, pero no se registran en
    LaunchServices y deben salir de cualquier ruta indexada antes de cerrar el trabajo. Los
    rollbacks se conservan bajo directorios `.noindex`, sin borrarlos ni confundirlos con apps
    instaladas. La puerta final es `build/verify-canonical-installation.sh`: Spotlight,
    LaunchServices y las carpetas de aplicaciones deben resolver únicamente la canónica. Ver
    `docs/canonical-installation.md`.
44. **Un perfecto v15 pertenece al proceso representativo exacto y a una sesión ya cerrada.** El
    `runs.process_id` debe coincidir con la única fila `run_processes.is_representative=1`; el run
    debe haber terminado y la verificación debe ser posterior a ese cierre. Ningún proceso
    rastreado puede seguir abierto ni terminar después de la verificación. Insertar, cambiar o
    borrar después la cadena de procesos invalida el perfecto y desactiva su certificación sin
    borrar la historia. Los lectores degradan los perfectos legacy incoherentes a `invalidated`.
45. **La telemetría degradada es estado visible, no ausencia de eventos.** El monitor conserva
    incidencias tipadas de log ausente/ilegible, rotación, truncado, línea parcial descartada,
    formato inesperado y límite de lectura. Tras una discontinuidad abre una nueva época y no
    consume eventos anteriores para una intención nueva. Las lecturas y estados están acotados;
    recuperar el monitor resuelve la incidencia, pero nunca inventa procesos ni resultados.
46. **Windows Media se repara por contenido, App ID y lease exclusivo.** El inventario parte del
    `appmanifest_<APP_ID>.acf` exacto, abre el árbol de juego de forma anclada, no sigue symlinks y
    respeta profundidad 7, 4096 entradas y 512 KiB de metadatos. Solo una proyección fresca con
    WMA/WMV/ASF, el componente sellado reparable y Steam en reposo autoriza la receta compilada.
    El instalador exige App ID canónico y lease, reconcilia su WAL, usa backup/rollback/recibo
    durable y vuelve a verificar; nunca reparar globalmente al abrir Steam ni ejecutar una URL,
    ruta o comando aprendido desde SQLite.
47. **El catálogo compilado gobierna la identidad de los perfiles.** `identifier`, `revision` y
    `executable` proceden de `GameRuntimeProfileCatalog` y sobrescriben metadatos contradictorios.
    Las rutas GPTK externas se derivan por índice de ese catálogo; las variables genéricas legacy
    no tienen autoridad. El informe de capacidad debe demostrar el conjunto completo DXMT/DXVK o
    D3DMetal y, para este último, la versión GPTK exacta autorizada antes de declarar una ruta
    efectiva.
48. **El runtime público 1.12 se autoriza como conjunto sellado.** Antes de lanzar deben coincidir
    hashes y permisos compilados del wrapper `bin/wine`, `bin/wineserver`, loader Unix,
    `ntdll.so`, `wine.inf`, ambas `ntdll.dll` PE y VC++/UCRT x86+x64. El launcher usa rutas
    absolutas al Wine y al `WINESERVER` del runtime sellado, restablece `PATH` exactamente a
    `/usr/bin:/bin:/usr/sbin:/sbin` y elimina cualquier `WINESERVERSOCKET` heredado. Conserva así
    las utilidades canónicas de macOS sin aceptar Wine, wineserver ni un `PATH` hostil del entorno.
    El runtime de desarrollo permanece fail-closed mientras no exista un PIN reproducible
    separado; no medir el payload vivo para autorizarlo.
49. **Todo lanzamiento por App ID obtiene autoridad durable v17 antes del `spawn`.** El sobre
    vincula run, App ID, backend Regression, preflight completo y reciente, generación fresca de
    requisitos e identidades cerradas de componentes/perfiles; nunca contiene comandos, rutas,
    DLLs o argumentos arbitrarios. La adopción durable de telemetría y el paso a verificación
    explícita están integrados. Las decisiones puras de retry/recuperación no son un ejecutor:
    auto-retry y rollback automáticos permanecen bloqueados hasta conectar una receta compilada,
    verificador y recibo durable. Steam observado, una receta desconocida o el límite agotado
    exige gesto explícito; cerrar telemetría o emitir un recibo nunca certifica render, entrada,
    opciones ni gameplay.
50. **Un contexto OpenGL core 3.2+ sin el bit forward-compatible se concede, no se rechaza.**
    macOS solo expone contextos core 3.2+ en forma forward-compatible, así que esa petición no
    puede satisfacerse de otra manera y antes terminaba siempre en `ERROR_INVALID_VERSION_ARB`.
    `macdrv_context_create` añade ahora el bit para cualquier proceso: convierte un fallo cierto en
    un contexto válido y no puede degradar un título que ya funcione. Es una corrección **general**;
    la variable `CX_FWD_COMPAT_GL_CTX` por ejecutable queda como compatibilidad histórica y no debe
    usarse para blindar un juego nuevo. `REGRESSION_GL_CORE_FORWARD_COMPAT=0` restaura el rechazo
    para una A/B sin recompilar. SDL2, bgfx y HashLink piden ese contexto exacto; ver
    `patches/wine-26.3.0-opengl-core-forward-compat.patch` y `docs/games/cursemark.md`.
51. **La familia HashLink se reconoce por contenido, nunca por ejecutable.** El runtime de
    Heaps/HashLink resuelve toda su tabla de imports GL y se detiene en la primera entrada que no
    resuelve, de modo que las siete funciones de compute/SSBO/indirect que macOS no puede ofrecer
    por encima de GL 4.1 matan el juego antes del primer fotograma. `loader.c` exige `hlboot.dat` y
    `libhl.dll` en la raíz del juego bajo `steamapps/common` antes de exportar
    `REGRESSION_GL_HASHLINK_RUNTIME=1`, y solo entonces `unix_wgl.c` resuelve stubs que **no hacen
    el trabajo** y registran un `ERR` la primera vez que se los invoca. Ningún otro motor los ve.
    No convertir esto en una lista de App IDs ni ampliar el conjunto de funciones sin repetir la
    matriz y comprobar en el log que ningún stub llega a ejecutarse. Run perfecto de Cursemark:
    `2798D808-2007-4C66-ADC9-D5E4A3AB1A11`; ver `docs/games/cursemark.md`.
52. **El runtime se compila desde el tar FOSS oficial más la serie versionada, nunca desde el
    árbol de trabajo tal como esté.** `sources-26.3.0/wine` es un artefacto reproducible, no una
    fuente de verdad: si quedó editado a mano, lo que compiles no será lo publicado. Extraer
    `crossover-sources-26.3.0.tar.gz` en limpio, pasar `build/apply-wine-patches.sh` sin un solo
    rechazo y comprobar que `loader.c` ya no contiene `REGRESSION_EXTERNAL_D3DMETAL_(EXECUTABLE|
    WINE_ROOT)`. Un parche que no aplica sobre el tar oficial está mal generado y se regenera
    contra el árbol canónico; no se fuerza su contexto. Los módulos `lib/wine/x86_64-unix/*.so` se
    pueden sustituir uno a uno firmándolos **ad hoc**, pero `bin/wine`, `bin/wineserver` y el loader
    Unix **no**: el asset público pasó por `strip` y saneado de rutas y no convive con binarios
    crudos, que dejan el arranque colgado. Tras cualquier cambio, `build/refresh-release-pins.sh`
    propaga los digests y escribe la evidencia que permite acreditar sin el árbol de compilación.
    Ver `docs/runtime-rebuild.md`.
53. **La versión del bundle se sube al publicar la release, nunca antes.** Con el canal estable en
    una versión anterior, la reparación se bloquea por downgrade y la app se queda sin vía de
    recuperación; además `supportedApplicationVersion` y `supportedBuildIdentifier` van siempre
    juntos y cambiar uno solo resuelve `unsupportedVariant`, vaciando el conjunto sellado y
    reportando «Runtime incompleto». Un runtime corregido puede convivir con la versión publicada
    actualizando solo su digest en el conjunto sellado, que es como se valida un cambio en la
    instalación real antes de comprometer una versión nueva.

54. **La colisión de overlays no es un problema de Unreal: es del EOS SDK.** Dragonwilds,
    Cloudheim y TMNT: Shredder's Revenge —Unreal los dos primeros, **FNA** el tercero— revientan
    con el mismo puntero corrupto, `0x5320747375725420`, que no es una dirección sino texto ASCII.
    Lo único que comparten es `EOSSDK-Win64-Shipping.dll` y el overlay que instala en la botella.
    Ante un crash sin ventana con RIP en texto legible, comprueba si el juego embarca el EOS SDK
    antes que su motor. La corrección es siempre la misma y siempre por basename exacto:
    deshabilitar `EOSOVH-Win64-Shipping` **solo dentro de ese proceso**. Convertirlo en override
    global dejaría sin overlay a juegos que hoy funcionan.

55. **Una activación compilada solo se aplica si trae respaldo y manifiesto de rollback.** El
    repositorio no promueve un intento a `appliedAwaitingRelaunch` sin huellas antes/después y sin
    un manifiesto de dos entradas —el catálogo v2 que cambió y el formato v1 en cuarentena, cuya
    huella idéntica acredita que no se tocó—. El respaldo se publica **antes** de tocar el catálogo
    vivo y se nombra por su propio contenido, así que repetir la misma activación lo reutiliza en
    vez de acumular copias. El intento recorre siempre `detected → planned → appliedAwaitingRelaunch`;
    reincidir con la receta ya activa lo cierra como `failed` en lugar de reescribir la botella en
    bucle. `restore` solo deshace si el catálogo vivo sigue siendo el que publicó ese recibo.

56. **El permiso de custodia se toma una sola vez por lanzamiento.** Pedirlo otra vez dentro del
    arranque de Steam era un bloqueo circular: la intención de lanzamiento ya está registrada y el
    interlock deniega cualquier permiso mientras exista, de modo que un juego con
    `requiresActiveSteamClient` nunca arrancaba con Steam cerrado y cada reintento renovaba la
    intención. El permiso se adquiere en `launchSteamGeneral` y vive todo el ámbito; ninguna etapa
    interior vuelve a pedirlo.

57. **La ventana para acreditar que un lanzamiento es observable cubre un arranque en frío.** El
    lanzador abre wine, wine levanta el servicio y solo entonces aparece `Steam.exe`, que es lo
    único que el inspector sabe atribuir. Con una ventana de dos segundos ese arranque perdía
    siempre la carrera, la intención se quedaba en disco y la biblioteca se quedaba bloqueada hasta
    matar Steam. La espera termina en cuanto hay evidencia, así que un arranque normal se resuelve
    igual de rápido.

58. **«Arranca y se cierra solo» sin ventana y sin crash: mira Steam Cloud antes que el motor.**
    Si `userdata/<id>/<appid>/remotecache.vdf` declara archivos como sincronizados en local y esos
    archivos **no existen** en la carpeta de guardado del juego, Steam responde «nada que
    descargar» y el juego abandona el arranque por falta de datos. Ningún cambio en Wine, DXMT,
    perfiles o rutas lo arregla. Las partidas siguen en `userdata/<id>/<appid>/remote/`: se copian
    a la carpeta local del juego con `cp -p` para conservar las fechas y no provocar una subida.
    Contrastar la caché contra el disco cuesta segundos y evita horas de diagnóstico en el sitio
    equivocado: `regressionctl cloud-status APP_ID` lo hace por ti, de solo lectura y sin tocar un
    byte de los datos del usuario. Ver `docs/games/core-keeper.md`.

59. **Ante «me lo has roto», el A/B de una variable manda sobre cualquier razonamiento.** Los
    backups de `build/install-runtime-canonical.sh` contienen el runtime anterior **y** sus PIN,
    `ComponentHealth` y verificadores: restaurarlos entero es un experimento limpio de tres
    minutos. Argumentar por qué un cambio «no puede» ser la causa no es evidencia; reproducir el
    fallo con el estado anterior sí. Regression **no borra** nada bajo `drive_c/users`: ningún
    componente referencia `LocalLow` y `GameSessionArtifactCleaner` solo inspecciona procesos.

60. **Una release se corta con `build/release.sh`, no a mano.** Los mismos cuatro binarios de
    arranque se fijan en tres formas —crudo del builder, firmado en el bundle y saneado para el
    asset— repartidas en siete archivos; reconciliarlas a mano costaba horas y fallaba en silencio.
    El orquestador las deriva de los artefactos y las escribe en su sitio, sin saltarse ni un
    verificador. Los pasos sueltos quedan para depurar un fallo concreto.

61. **El PIN de una release ya publicada no se reescribe jamás, ni siquiera por accidente.**
    `refresh-release-pins.sh` hacía un reemplazo global y, como normalmente tienes instalada una
    release publicada, su digest coincidía con el que fijan sus ramas y se las reescribía en
    silencio. `build/verify-public-installed-state.sh` queda fuera de ese barrido: los modos de
    una versión nueva se **añaden** al cortarla. `build/release.sh` toma un testigo del archivo
    antes de sellar y aborta si cambió.

62. **Un juego con launcher no se rastrea por el nombre del juego.** Witcher 3 corre como
    `redprelauncher.exe` y Sonic Adventure 2 como `launcher.exe`; buscar el ejecutable del juego
    da «nunca arrancó» cuando sí arrancó, y matar el patrón equivocado deja el launcher vivo.
    Steam rechaza entonces el siguiente intento con `AppError_16` en `WaitingPrevProcess`, que se
    lee como «el juego no arranca» y manda el diagnóstico al sitio equivocado. Antes de concluir,
    mira qué ejecutable declara Steam en `logs/console_log.txt`.

63. **Una ventana de Wine a pantalla completa vive en la capa 21, no en la 0.** Filtrar por
    `layer == 0` esconde juegos que están renderizando perfectamente. Le pasó a
    `tools/diagnostics/list-windows.swift` y produjo tres diagnósticos falsos de «no abre ventana»
    en una sola sesión. Si un juego «no tiene ventana», compruébalo con `--all` y mirando la capa
    antes de buscar la causa en el motor.

64. **Las cadenas de un binario sugieren; el log del juego acredita.** Enshrouded nombra
    `VK_KHR_ray_tracing_pipeline` en su ejecutable y eso llevó a un diagnóstico falso de
    «incompatible por trazado de rayos». Su propio log decía otra cosa: `skipping device because
    'drawIndirectCount' is not supported`. Antes de cerrar un expediente por lo que aparece en un
    `strings`, busca el log que el juego deja: casi todos dejan uno junto al ejecutable o en
    `drive_c/users`.

65. **Una característica declarada falsa por MoltenVK no se activa a mano.** `drawIndirectCount`
    está a `false` porque `vkCmdDrawIndirectCount` es un **stub vacío**. Forzar el flag haría que
    el juego pasara su comprobación y no pintara la geometría indirecta —un fallo silencioso, que
    es exactamente lo que este proyecto no produce—. Si una característica de MoltenVK falta, la
    salida es implementarla de verdad o declarar el título incompatible.
66. **Un juego que renderiza negro con el audio sonando es un fallo de compilación de pipeline,
    no un crash.** El log del propio juego lo dice en su primera línea de error
    (`DxvkGraphicsPipeline: Failed to compile pipeline`), y el error real de Metal sale con
    `MVK_CONFIG_LOG_LEVEL=4`. El `d3d9` de DXVK declara el sampler normal y el de comparación de
    profundidad **sobre el mismo binding**; Metal no admite dos samplers en un índice, así que
    cualquier juego D3D9 con *shadow mapping* por hardware pierde **todas** sus pipelines. La
    salida es enrutar ese proceso —y solo ese— al `d3d9` builtin de Wine. Ver
    `docs/games/sonic-adventure-2.md`.
67. **La activación de una app no la decide la app: macOS 14 exige que se la cedan.** Wine tiene su
    propio protocolo entre procesos del mismo prefijo (`WineAppWillActivateNotification` →
    `yieldActivationToApplication:`). Regression **participa en él** desde `WineActivationHandoff`.
    Si al lanzar hay delante una app que no es de Wine, nadie cede y el juego queda visible pero
    **sin teclado ni ratón**: no es un juego colgado. Regression se activa al pulsar «Jugar» —el
    usuario acaba de interactuar con ella— y cierra su popover, que si no retiene la ventana *key*
    y se queda las teclas del juego.
68. **Una ventana frontmost no es una ventana *key*, y `AXFocused` no los distingue.** Devuelve
    `true` en los dos casos. Lo único que lo acredita es si las pulsaciones llegan a Wine
    (`WINEDEBUG=+key` → `macdrv_ToUnicodeEx` / `WM_CHAR`). Además, `osascript … set frontmost of
    process` **puede fallar en silencio** con un proceso de Wine: comprueba el frontmost después,
    nunca lo des por hecho.
69. **Antes de diagnosticar el foco, mira el orden de ventanas.** El diálogo de configuración de
    Sonic Adventure 2 se abre detrás de la ventana de Steam, que ocupa la pantalla: los clics
    aterrizaban en Steam y parecía que el juego no arrancaba. `screencapture -l` captura la ventana
    aunque esté tapada, así que una captura correcta no prueba que la ventana reciba los clics.
70. **El inventario tecnológico es evidencia, no una puerta.** Un inventario que excede su
    presupuesto avisa y el lanzamiento continúa; rechazar el lanzamiento por ello impedía jugar a
    un título por el mero tamaño de su carpeta.
71. **Refrescar los PIN no puede borrar evidencia que no se ha podido rederivar.**
    `build/release-runtime-pins.txt` se reescribe entero, así que saltarse la línea de un artefacto
    que el builder no acredita la eliminaba en silencio y dejaba sin acreditar algo que **no había
    cambiado**. La línea anterior se arrastra tal cual.
72. **Un proceso de 32 bits no puede usar DXVK en este runtime.** MoltenVK solo existe en 64
    bits, así que un i386 que cargue el `d3d9` de DXVK no crea instancia Vulkan
    (`Required Vulkan extension VK_KHR_surface not supported`), DXVK lanza `dxvk::DxvkError` y
    `terminate()` mata el proceso. Se le da el `d3d9` builtin de Wine **por arquitectura, no por
    lista de títulos**. Las demás APIs no dependen de Vulkan aquí (D3D11 va por DXMT).
73. **Una redirección de imagen no puede cruzar arquitecturas.** Sustituir el ejecutable de un
    proceso de 32 bits por uno de 64 hace que la creación del proceso falle con
    `ERROR_NOT_SUPPORTED` y Steam lo reporte como `AppError_46`. Se comprueba la máquina del PE
    **antes** de proponer la ruta, no después de romper el arranque.
74. **El argumento que se añade a una línea de comandos es una lista cerrada compilada en el
    loader**, aplicada a un basename exacto y solo si no venía ya. Sirve para `-window-mode
    borderless` (Unity) y `--launcher-skip` (REDengine). Ni el entorno ni la base de aprendizaje
    pueden inyectar un argumento.
75. **Un launcher de proveedor que falla no es el juego.** The Witcher 3 arrancaba perfecto por su
    binario; lo que reventaba era la interfaz Chromium de su prelanzador. Antes de tocar el motor,
    separa la cadena y comprueba **qué eslabón** falla: la ruta del proceso (`ps -o command`) dice
    qué binario se está ejecutando de verdad.
76. **Conceder el foco de una ventana de Wine se hace en el acto; descartar sus eventos, no.**
    Diferir el `makeKeyWindow` un turno del runloop pierde el foco —el juego ya lo movió—, pero
    descartar los `WINDOW_LOST_FOCUS` pendientes dentro de la pila del ordenado **cuelga** a
    algunos juegos antes siquiera de crear su ventana (reproducido con Runika, parado justo tras
    inicializar su input). Las dos mitades se separan, y cada cambio de foco se valida contra
    **ambos** casos: un juego que necesita el foco y otro que se colgaba.
77. **MoltenVK también se compila desde el tar oficial, nunca desde el árbol de trabajo.** El
    `External/SPIRV-Cross` de `sources-26.3.0/moltenvk` es el upstream con los campos que el fork
    de CodeWeavers necesita añadidos **como stubs**: MoltenVK los rellena —`for_mesh_pipeline`,
    `input_primitive_type`, `add_texture_buffer_offsets`, `texture_offset_buffer_index` y el
    `MSLShaderInterfaceVariable` con `binding`/`offset`/`stride`/`normalized`— y el traductor los
    ignora en silencio. El tar **sí** trae la versión buena. Es la misma regla que el runtime de
    Wine, y se incumplió por no comprobarlo: antes de sustituir `libMoltenVK.dylib`, acredita que
    su SPIRV-Cross implementa lo que MoltenVK le pide. Ver `docs/games/enshrouded.md`.
78. **Sustituir `libMoltenVK.dylib` obliga a revalidar la fila D3D9 entera.** MoltenVK sirve a
    DXVK, así que afecta a **todos** los juegos D3D9, no solo al que motivó el cambio. Si no hay
    un juego D3D9 puro instalado con el que acreditarlo, el cambio no se publica.
79. **Un proceso que muere «sin dejar rastro» durante la compilación de shaders suele estar
    colgado, no crasheado.** La salvaguarda de SPIRV-Cross contra bucles de recompilación
    —`Maximum compilation loops detected`— **solo salta si el compilador no declara progreso**
    (`!is_force_recompile_forward_progress`), y su propio comentario admite que «in buggy
    situations we will loop forever». Antes de buscar un crash que no existe, instrumenta la
    cadena `vkCreate*Pipelines` → `getMTLFunction` → `SPIRVToMSLConverter::convert` →
    `compile()` y cuenta entradas y salidas: si entran N y salen 0, es un cuelgue.
    Ver `docs/games/enshrouded.md`.

## Protocolo de trabajo (OBLIGATORIO — cómo se hacen las cosas aquí)

Este proyecto es un sistema de muchas piezas acopladas (wine + DXMT + DXVK + D3DMetal + CEF +
botella + launcher). La historia demuestra que **casi todas las roturas vinieron de cambiar
varias cosas a la vez o de tocar el estado bueno para "probar"**. Sigue este protocolo siempre.

### 1. Antes de cambiar nada

1. **Ejecuta el preflight sin lanzar** (`regressionctl preflight APP_ID --backend <backend>`).
   Si bloquea, corrige primero esa causa ambiental y repite; si avisa, conserva el contexto.
2. **Reproduce el problema** y escribe en qué consiste exactamente (juego, momento, síntoma,
   captura). Si no puedes reproducirlo, no estás arreglando nada: estás adivinando.
3. **Descarta causas ambientales primero** (son la mitad de los "bugs" históricos). El preflight
   automatiza la detección, pero la intervención sigue siendo explícita y revisada:
   - ¿Hay wineservers de OTROS builds corriendo? (`ps aux | grep wineserver`) → mátalos. Un
     wineserver de otro build causa muertes silenciosas que parecen bugs del motor.
   - ¿Hay `services.exe` huérfanos (PPID 1, sin wineserver)? Son restos de sesiones wine
     muertas: dejan **iconos de Steam fantasmas en la barra de menús de macOS** y pueden
     interferir. Se limpian con `kill <pid>` — son seguros de matar.
   - ¿La botella tiene ficheros `dxmt-cxpresent-*.id` stale? (el launcher ya los limpia, pero
     si lanzas wine a mano, límpialos tú).
   - ¿El juego necesita Steam activo (DRM)? Los juegos Unity/IL2CPP mueren al iniciar si Steam
     no está corriendo — no es un bug del motor.
4. **Haz backup** de lo que vas a tocar (botella → copia o tar en `backups/`; dlls → cópialas
   con sufijo `.bak` junto al original). Sin backup no se toca nada.
5. **Consulta la tabla de PINs** (abajo). Si tu arreglo implica tocar un PIN, necesitas validar
   la matriz COMPLETA después, no solo tu juego.

### 2. Cómo se cambia algo

- **UNA variable por cambio.** Una dll, un override, un parámetro. Si cambias dos cosas y algo
  se rompe (o se arregla), no sabes cuál fue — y en este proyecto eso ya ha costado días.
- **Nunca experimentes sobre el estado bueno.** Experimentos en copia de la botella o con dlls
  respaldadas. Solo se aplica al estado bueno tras validar.
- **Método de referencia: baseline/candidato dentro de Regression** (README §3-4). Contrasta el
  runtime protegido con fuentes FOSS oficiales y cambia una sola dimensión en un perfil aislado.
  Ningún experimento requiere instalar, abrir, consultar o inspeccionar CrossOver.

### 3. Después de cambiar algo: matriz de validación

Según lo que tocaste, valida TODO lo de su fila antes de dar el cambio por bueno:

| Si tocaste… | Debes validar (con captura visual) |
|---|---|
| Wine (build, dlls en wine-root) | Steam tienda renderiza + Moonlighter 2 (Unity) + Palworld |
| Perfil aislado por ejecutable | Juego objetivo completo + Steam tienda + un perfil ya blindado no afectado |
| DXMT (d3d11/dxgi/d3d10core) | Steam tienda (CEF) + Palworld (personajes visibles) |
| DXVK / d3d9 | Un juego D3D9 + Steam tienda |
| winemac.drv / parche cross-process | Steam tienda + clicks precisos + Palworld |
| Launcher (env, rutas) | Arranque desde cero: Steam tienda + un juego |
| Registro de la botella (overrides, RetinaMode) | Steam tienda + clicks + un juego |
| Fuentes de la botella | Steam arranca (sin ellas crashea con assert Win32Font) |

Validar = lanzar, capturar con `screencapture -x -l <CGWindowID>` y **mirar la imagen**.
"Compila" o "el proceso corre" NO es validación. Si algo de la matriz falla → **revertir al
instante** (para eso está el backup) y repensar, no apilar otro cambio encima.

Cuando el usuario confirme el resultado perfecto, cerrar el ciclo en la propia UI: registrar el
veredicto sobre el run, refrescar Regression y capturar la fila verde. Esa captura forma parte de
la evidencia del perfil junto a la del juego.

### 4. Tabla de PINs (versiones/config FIJADAS — no tocar sin validar la matriz completa)

Estos PIN fijan el **backend estable predeterminado**, no los entornos aislados de I+D por juego.
Una alternativa puede convivir autocontenida en un perfil individual después de superar sus
pruebas; sustituir un PIN global requiere validar toda la matriz correspondiente.

| Pieza | Valor fijado | Razón | Test que lo protege |
|---|---|---|---|
| DXMT | **v0.72 + parche cross-process propio** | `main` hace invisibles los skeletal meshes | Palworld (personaje visible) |
| Wine | **CX 26.3.0 (`sources-26.3.0/wine`), `--prefix` horneado a la app** | Con prefix `/usr/local` mueren Unity y CEF | Moonlighter 2 + Steam tienda |
| d3d11/dxgi/d3d10core | DXMT en system32 + wine-root, **SIN override `native`** | El override las marca "not found" | Steam tienda |
| d3d11/dxgi de Apple | **NO** en system32 (solo d3d12*) | CEF muere | Steam tienda |
| d3d9 | DXVK 1.10.3, override `native` sí (PE plana) | Funciona | Juego D3D9 |
| Grim Dawn | D3DMetal completo por proceso; `d3d9/atidxx64/nvapi64/nvngx=builtin` | Evita mezcla DXVK y parpadeo | Gameplay + opciones + captura 3024×1964 |
| DragonSword | D3DMetal completo por proceso; ocho módulos builtin fijados | Evita ruta híbrida D3DMetal/DXMT y tirones | Gameplay + pausa + salida + captura 3024×1964 |
| Heroes of Hammerwatch II | `CX_FWD_COMPAT_GL_CTX=1` solo en `HWR2.exe`; OpenGL CX 26.3 | BGFX omite el bit forward-compatible requerido por macOS | Menú + gameplay + foco + Steam + Grim Dawn |
| Titan Quest II | bootstrap exacto → Shipping + GPTK 4.0b2 externo solo en `TQ2-Win64-Shipping.exe` | El bootstrap da un falso negativo de VC++ y Steam conserva su imagen en wineserver | Ambos botones + gameplay + opciones + Steam + matriz Wine |
| Dragonwilds | `EOSOVH-Win64-Shipping=disabled` solo en `RSDragonwilds-Win64-Shipping.exe`; Steam Overlay/EOSSDK/DXMT intactos | Colisión estricta de doble overlay en D3D11 | Gameplay + WASD + cámara + pausa + opciones + Steam + matriz Wine |
| Tinkerlands | Reparación JSON exacta `fullscreen=0,resolution>=6` → fullscreen, con rollback | Desajuste de coordenadas en ventana Retina de alta resolución | Menú + clics + opciones + gameplay + pausa |
| Moonlighter 2 | Baseline general, sin perfil | Control Unity del prefijo y loader Wine | Menú + gameplay + entrada + pausa + opciones restauradas |
| RetinaMode | `n` (HKCU\Software\Wine\Mac Driver) | Alinea clicks | Click en tienda |
| Fuentes | 55 TTFs (corefonts + CJK) en la botella | Sin ellas Steam crashea (assert Win32Font) | Steam arranca |
| DLLs PE | **SIN strip** | El strip rompe unwind SEH y firma de módulos | Juegos Unity |

### 5. Instalación y rutas (no improvisar)

- `Regression.app/` es únicamente el artefacto de desarrollo ignorado por Git. Puede existir
  durante un build, pero no se registra ni se considera una instalación.
- La **única app canónica instalada** es el bundle físico `/Applications/Regression.app`. El
  runtime público se recompila con el `--prefix` de esa ruta; no crear symlinks ni copias con
  extensión `.app` en ubicaciones indexables.
- **No copies la app canónica a otro sitio ni la muevas** sin recompilar Wine con el nuevo
  `--prefix`. Los laboratorios y rollbacks acabados se conservan en `.noindex`.
- Tras cualquier `make install` o cambio en el bundle:
  `Scripts/sign_regression.sh Regression.app`. El script selecciona una identidad de desarrollo
  válida sin guardar su nombre en el repo, aplica las capacidades públicas requeridas por el host
  de juegos y verifica que el requisito designado no dependa del hash del build.
- Tras recompilar/instalar: relanzar y validar la tienda con captura (regla 2).

### 6. Definición de "hecho"

Un cambio está hecho cuando: (1) el problema original ya no se reproduce, (2) la matriz de
validación de su fila pasa entera con capturas, (3) hay backup del estado nuevo si es mejor,
(4) README/AGENTS reflejan el cambio. Si solo cumples el punto 1, has arreglado una cosa y
quizá roto otra — que es exactamente lo que este protocolo existe para evitar.

## Estado rápido (2026-08-14)

- **Contrato de este corte**: el código fuente y los empaquetadores convergen en Regression
  **1.12.7 (45)** y SQLite **v17**. **v1.12.7 (45)** es la release estable actual y
  **v1.11.0 (37)** el baseline histórico; sus verificadores `public-1.11` se conservan como
  gates de transición, no como versión vigente. Toda release futura debe verificar el asset
  exacto y completar su matriz antes de publicarse.

- **Arquitectura operativa actual**: app nativa `LSUIElement` en barra de menús, Regression como
  único backend, una botella propia y una sola biblioteca física de juegos dentro de ella. La
  transferencia desde la ubicación heredada usa un WAL durable, renombres exclusivos, validación
  funcional y rollback antes de finalizar; no copia juegos ni deja enlaces heredados. El lanzador propio está en
  `Regression.app/Contents/MacOS/regression-engine`.
- **Aprendizaje local**: SQLite v17 normalizada en
  `~/Library/Application Support/Regression/Compatibility/compatibility.sqlite`; registra
  sistema, comandos saneados, componentes, backend gráfico, configuración de juego y deltas.
  La identidad de motor excluye `gameconfig.*`, de modo que una resolución distinta no crea un
  stack falso, mientras que cambiar Wine/DLL/registro sí. Las migraciones son transaccionales,
  crean backup privado y no dejan evidencias sin motor asociado. Cada blindado local referencia
  su evidencia, configuración y motor exactos; corregir el último veredicto perfecto lo desactiva
  sin borrar el historial.
  Un exit code 0 queda **sin verificar**: solo una validación visual explícita crea un perfil
  perfecto o con incidencias. Nada se aplica automáticamente al motor propio. Base, exportaciones,
  recibos y logs son privados del usuario (`0700`/`0600`); se retienen como máximo 20 logs del
  lanzador. Los expedientes de I+D separan casos, hipótesis, experimentos de una variable,
  puertas y artefactos con huella; un trigger impide cerrar sin el run perfecto exacto.
  Cada lanzamiento pasa además por un preflight no destructivo; los avisos y bloqueos se
  fingerprintan y se enlazan al run exacto sin convertir el entorno limpio en compatibilidad.
  `run_processes` evita duplicar una misma prueba cuando Steam encadena launcher y ejecutable
  principal; los lanzamientos desde el propio cliente también quedan diagnosticados, con fase y
  latencia explícitas para no falsificar una observación posterior como previa. El perfecto
  exige el PID representativo exacto y todos los procesos cerrados antes de verificar; cualquier
  mutación posterior de esa cadena lo invalida. El monitor de Steam emite incidencias tipadas y
  acotadas ante rotación, truncado, lectura parcial o formato inesperado, en lugar de silenciarlas.
- **Evolución tecnológica**: el inventario local registra baseline, última versión oficial
  revisada, licencia/distribución y política de Wine, GPTK/D3DMetal, DXMT, DXVK, MoltenVK,
  vkd3d y Rosetta. Las tablas de candidatos, métricas, requisitos y recibos no aplican
  cambios. Un trigger bloquea promociones sin perfil por juego, fuente/huella, aislamiento,
  rollback, matriz y comparación equivalente contra el baseline con mejora medible. Apple limita
  Rosetta general después de macOS 27, por
  lo que arm64/WoW64 es una línea prioritaria paralela, nunca una sustitución a ciegas.
- **Referencias externas retiradas**: las filas históricas se conservan para auditoría, pero la app
  y el CLI no consultan CodeWeavers, no sincronizan su catálogo y no exponen un backend comparador.
- OK total con el wine de prefijo propio: **Steam completo, Moonlighter 2 (Unity IL2CPP),
  Palworld (personaje), Grim Dawn, Romestead**, DXVK D3D9. Estado blindado intacto.
- **PIN: Grim Dawn = D3DMetal completo y aislado por ejecutable.** El perfil anterior mezclaba
  DXVK/MoltenVK y parpadeaba; el actual renderiza gameplay Retina 3024×1964, conserva clics y
  opciones y fue confirmado perfecto por el usuario. Evidencia y rollback local:
  `backups/grimdawn-d3dmetal-perfect-20260727-1802/`. Método y expediente reproducible:
  `docs/compatibility-research.md` y `docs/games/grim-dawn.md`.
- **Clair Obscur: Expedition 33**: el baseline propio sin perfil especial fue confirmado perfecto
  por el usuario en el run `4667F4AA-DE5C-4F7A-A7A5-AAAB29829D3C`: título, carga, combate,
  Retina 3024×1964, entrada HID, pausa, opciones y salida limpia. La certificación fija la huella
  `8454bf44804d122d587261d7084ddc08db1185e8c6bc703c5701b5669087c0d7`; expediente y rollback:
  `docs/games/clair-obscur-expedition-33.md` y
  `backups/clair-obscur-investigation-20260729-050233/`.
- **Dragon's Dogma 2 (perfil promocionado, validado con incidencia)**: D3DMetal + Retina por
  proceso, 1512×945 lógicos en ventana sin bordes y backing físico de 3024×1890. El run
  `257CEEDB-8EE7-4D4E-AF6B-589741406C1F` fue confirmado por el usuario con render, rendimiento,
  click, gameplay y opciones estables. Queda como `Funciona con incidencias`, no como perfecto,
  porque conserva letterbox 16:9; la comparación histórica registró la misma franja. No promover 3024×1890
  internos: esa variante desborda y desplaza el click. Perfil, instalador y rollback están
  protegidos; ver `docs/games/dragons-dogma-2.md`.
- **DragonSword : Awakening (perfil perfecto promocionado)**: el run
  `6074F679-9CE1-4D6C-A386-2021F06FDE96` fue confirmado por el usuario con gameplay Retina
  3024×1964, entrada, pausa, opciones, rendimiento sin tirones y salida limpia. El router fuerza
  una ruta D3DMetal completa solo en `DSClient-Win64-Shipping.exe`; la variante híbrida anterior
  quedó registrada como fallo. Perfil, hashes, evidencia y rollback:
  `docs/games/dragonsword-awakening.md` y
  `backups/dragonsword-d3dmetal-rerun-20260729-100602/`.
- **Rotwood (baseline funcional con incidencia visual)**: el run
  `E9316F8E-A6C3-4DE2-A075-6884A923AE4D` completó gameplay, entrada, pausa, opciones y cierre con
  guardado. El usuario confirmó funcionamiento excelente. Las bandas negras superior e inferior
  también constan en la comparación histórica porque el juego fija una superficie 1512×870 dentro de la
  pantalla 1512×982. La base muestra `Funciona con incidencias`; no se creó un perfil innecesario
  ni una certificación perfecta. Evidencia y rollback:
  `docs/games/rotwood.md` y `backups/rotwood-baseline-20260729-111437/`.
- **Hell Clock (baseline general perfecto)**: el run
  `2F2DE49D-DE01-4A7F-B2D2-39195EA5D68B` cargó un save real, renderizó gameplay y HUD sin
  artefactos, mantuvo cursor y clicks precisos, abrió pausa/opciones, persistió VSync al reabrir,
  restauró el valor inicial y cerró limpiamente. La huella final de configuración coincidió con
  la inicial. La app instalada mostró `Verificado perfecto: Regression`; evidencia y rollback:
  `docs/games/hell-clock.md` y `backups/hell-clock-baseline-20260729-120152/`.
- **Heroes of Hammerwatch II (OpenGL aislado perfecto)**: el expediente histórico registra que
  los antiguos baselines fallaban de forma idéntica al crear BGFX OpenGL 3.2 (`0x2095`). El run
  `F8E4EA27-2E6B-439C-AC93-BD927035B5B5` activó el hook público CX 26.3 solo dentro de
  `HWR2.exe`, alcanzó menú y gameplay real, mantuvo entrada y opciones y cerró con `exit=0`.
  Steam siguió renderizando y Grim Dawn superó la matriz de foco y cambio de ventanas. Perfil,
  hashes, evidencia y rollback: `docs/games/heroes-of-hammerwatch-2.md` y
  `backups/heroes-hammerwatch-2-baseline-20260729-122351/`.
  La reconciliación local fija la huella compilada
  `af59b82a9e8102995ccbf5a9c93e1e9e6c62afe3213bea8a0bbe2ff7726236f1` y conserva el snapshot
  global anterior como historial.
- **Secrets of Grindea (baseline general perfecto)**: el run
  `953B6822-AC77-4977-B862-B206D3CE16AE` completó carga, render, HUD, entrada y combate sin los
  trabones iniciales en habilidades o eventos, y cerró normalmente. No necesita perfil por
  ejecutable. `FNA3D_FORCE_DRIVER=OpenGL` empeoró carga, congelaciones y HUD; la compilación
  Metal concurrente provocó page fault en SDL3 de 32 bits. Ambas variables quedan prohibidas
  para este juego. El HUD transitorio reapareció tras respawn sin cambiar `Config.txt`. Catálogo,
  evidencia y rollback: `docs/games/secrets-of-grindea.md` y
  `backups/secrets-of-grindea-baseline-20260802-0544/`.
- **Fields of Mistria (baseline perfecto con winemac parcheado)**: la pantalla verde del
  arranque —registrada también en la comparación histórica— era la CGL surface clavada al backing 1×1 de la ventana
  inicial; el parche propio `wine-26.3.0-winemac-gl-surface-resync` re-sincroniza el tamaño en
  el swap. El run `BAAC2B06-3CAD-467A-B1F1-834B76B794AD` cerró con exit=0 y el usuario registró
  el veredicto perfecto desde la app. Catálogo revisión `2026-08-08.1`; expediente y rollback:
  `docs/games/fields-of-mistria.md` y `backups/fields-of-mistria-investigation-20260807-202141/`.
- **Titan Quest II (Shipping + GPTK 4.0b2, doble entrada)**: el falso negativo de VC++ del
  bootstrap se evita mediante una receta compilada de coincidencia exacta. Tanto el botón de
  Regression como «Jugar» dentro de Steam alcanzaron menú, selección 3D y gameplay; la ejecución
  desde Steam superó movimiento por clic, pausa, opciones y cierre limpio. `lsof` confirmó
  `TQ2-Win64-Shipping.exe`, el `ntdll.so` propio con PIN `adb97ddb…` y D3DMetal/libd3dshared de
  GPTK 4.0b2. El run final `228467BB-AECE-40EF-8FE5-E739250AA859` de Regression 1.8.0 terminó
  con ambos procesos en código `0`, fue confirmado perfecto por el usuario y fijó la huella
  `fb45e5ed…`. Perfil y componente permanecen aislados; expediente
  `docs/games/titan-quest-2.md` y rollback `backups/titan-quest-2-*`.
- **FANTASY LIFE i (I+D EAC, no certificado)**: el expediente histórico registró fallos del host macOS y del antiguo comparador con
  código `206` al mapear el módulo Linux. En la VM Linux ARM aislada, Proton 11 x86-64 oficial
  sobre el candidato FEX FS/GS v3 superó el `210` tras autenticar manualmente el cliente oficial:
  EAC descargó el módulo, obtuvo HTTP `200`, inició el mapeo Wine 11 y devolvió `208 Cannot run
  under Virtual Machine`. Todavía no inició el ejecutable principal. Un clon UTM 5.0.3 expone
  Venus sobre el Apple M5 Pro; DXVK 1.10.3 crea D3D11 y presenta sobre esa GPU, mientras 2.7.1
  queda descartado por la ausencia de `VK_EXT_depth_clip_enable`. El usuario aceptó el EULA y
  Steam completó la instalación oficial (`StateFlags=4`, build `21998011`, 15.203.991.960 bytes).
  El lanzamiento oficial del App ID completó EOS/EAC/UEPrereq/DirectX y reprodujo `208` antes del
  ejecutable principal, descartando propiedad, acuerdo, manifiesto, instalación, sesión e IPC
  como causas pendientes. El runtime está aislado y no sustituye el FEX del sistema; al cerrar,
  ambos handlers volvieron a `/usr/bin/FEX`, AppArmor userns a `1` y no quedaron procesos.
  No ocultar la VM, copiar tokens, desactivar EAC ni presentar este avance como compatibilidad.
  La vía no-VM ya ejecuta ELF x86-64 reales sobre FEXCore público nativo arm64. Un RootFS privado
  con glibc 2.43 completa el `wine64` Unix oficial de Proton 11, `ntdll.so` y `libgcc_s.so.1`,
  imprime la versión y sale con código `0`. El hogar Linux privado fue la única variable que
  eliminó la referencia nula posterior a NSS. El recibo conserva explícitamente
  `proton_executed=false`, `steam_executed=false` y `eac_executed=false`: todavía falta la mitad
  PE/Windows y el orquestador. La VM dejó de ser candidata final por `208`; el motor estable no se
  tocó.
  Expediente y rollback:
  `docs/games/fantasy-life-i.md` y
  `/var/lib/regression-fli-arm-lab/official-valve/compatdata-fli-x86-fex-fsselector-v1-from-arm-prereqs-before-eac-launch.tar.zst`.
- **PIN: DXMT = v0.72 + parche cross-process** (versión fijada desde fuentes FOSS). `main` rompe los
  skeletal meshes de Palworld — NO actualizar sin probar Palworld.
- **PIN: wine compilado con `--prefix` apuntando a la app** (Regression.app/Contents/SharedSupport/wine-root).
  Con el prefix por defecto (/usr/local) los juegos Unity morían al iniciar y CEF tenía crashes.
- **PIN: wine-root y system32 llevan la dxgi de DXMT** (pareja). Cambiar la builtin de
  wine-root por la de wine rompe la carga de la dxgi de DXMT en system32 (los juegos D3D11
  mueren al instante). D3D12 necesita la dxgi de wine → conflicto documentado en README §8.
- **Cube World**: el usuario confirmó render, encuadre, interacción y gameplay perfectos en el
  motor propio blindado; ese dato figura como mejor perfil conocido. El expediente histórico conserva que en la antigua botella comparadora
  reinstalada, las pruebas actuales base/DXVK/D3DMetal muestran pantalla negra y
  "Could not initialize Direct3D"; no confundirlas con el éxito histórico de Regression.
- **FFT**: funcionamiento perfecto confirmado por el usuario en el motor propio tras aceptar el
  permiso de macOS. Conservar el registro respaldado; el diagnóstico antiguo de MoltenVK queda
  como historia de la ruta que fallaba, no como estado final del juego.
- **Steam Cloud desactivado** para 1128000/1004640 (el diálogo modal de sincronización
  bloquea el IPC de Steam y mata los lanzamientos — falso bug del motor).
- Backups consolidados: `backups/regression-last-good-20260726.tar.gz` (bundle exacto desde
  el que se restauró el estado bueno, extracción y firma verificadas),
  `backups/regression-blindado-20260725.tar.gz` (baseline blindado) y
  `backups/botella-config-20260725.tar.gz` (registros + 55 fuentes + DLLs DXMT/DXVK).
  El registro confirmado de FFT sigue en
  `backups/regression-steam-user-fft-perfect-20260726.reg`; los saves preventivos viven en
  `backups/user-data/`.
- Revisión de almacenamiento 2026-07-27: quedan solo las fuentes fijadas 26.3.0. El árbol ocupa
  ~6,0 GiB, incluidos ~1,8 GiB de app local y ~1,5 GiB de backups/evidencia. El expediente final
  de Grim Dawn explica el crecimiento posterior a la limpieza; no hay otra Regression instalada.
- **Instalación**: bundle físico `/Applications/Regression.app`, única app que Spotlight y
  LaunchServices pueden descubrir. Lanzar con `open /Applications/Regression.app`.

## Verificación rápida

```bash
open /Applications/Regression.app        # debe abrir Steam y renderizar la tienda
swift tools/diagnostics/list-windows.swift steam
screencapture -x -l <id> /tmp/check.png  # captura y revisar visualmente
bash build/install-game-profiles.sh      # verifica perfiles Grim Dawn/DD2/DragonSword/HWR2 y firma
bash build/verify-protected-state.sh --include-bottle  # verifica PINs sin lanzar juegos
bash build/verify-canonical-installation.sh             # solo una app en Finder/Spotlight
```

## Build

Scripts en `build/` (README §5). Toolchain ya compilado en `toolchain/x86/` — no recompilar
salvo cambio de versiones. Wine: `build/build-wine.sh`. DXMT: `build/build-dxmt.sh`.
