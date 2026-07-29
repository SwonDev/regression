# Protocolo de investigación de compatibilidad

Este documento convierte el trabajo A/B contra CrossOver en un procedimiento repetible. El
objetivo no es copiar binarios propietarios: es observar una ejecución correcta, identificar la
diferencia mínima y reproducir legalmente ese comportamiento en el motor propio mediante fuentes
públicas, recursos locales autorizados y configuración aislada.

`AGENTS.md` sigue siendo la norma obligatoria. Este documento explica cómo ejecutarla en la
práctica cuando un juego funciona en CrossOver y falla en Regression.

## Principios

1. **La referencia es el comportamiento, no una intuición.** Hay que ejecutar el mismo juego en
   CrossOver y Regression, en el mismo Mac y, cuando sea posible, con los mismos archivos, save,
   resolución y escena.
2. **Un proceso correcto no demuestra una imagen correcta.** La validación exige observar el
   juego, interactuar con él y capturar su ventana.
3. **Cada juego tiene un perfil aislado.** Un ajuste verificado no se traslada al registro global
   ni al launcher común si puede expresarse por nombre de ejecutable, App ID o perfil.
4. **Una variable por prueba.** Backend, DLL, override, variable de entorno, RetinaMode y
   resolución se prueban por separado.
5. **CrossOver no es una dependencia del motor propio.** Se permite inspección estática de su
   instalación y uso normal de sus herramientas oficiales. No se enlazan sus rutas ni se copian
   sus binarios propietarios a Regression.
6. **La promoción requiere rollback.** Antes de modificar la app o una botella se preservan los
   archivos afectados y se registran hashes. El instalador debe restaurarlos automáticamente si
   falla cualquier etapa posterior —incluida la firma— y esa ruta de error se prueba en un clon,
   no sobre el bundle canónico.
7. **Los módulos builtin se tratan como familias de build.** No se copia una mitad Unix de
   `ntdll`, `winemac` o un backend desde un directorio reconfigurado sobre las mitades PE de otro.
   Primero se identifica el build que produjo el runtime canónico, se recompila ahí y se protegen
   por hash todas las mitades que deliberadamente deben permanecer iguales. Un warning conocido
   en un log no sustituye la reproducción: `Win32Font.cpp:1129` también aparece con Steam sano.
8. **No se abandona una línea por acumulación de intentos.** Un resultado negativo falsifica una
   hipótesis o descarta un candidato, pero no cierra el problema. Se vuelve a la evidencia, se
   reordena la lista de causas y se continúa con la siguiente prueba discriminante.
9. **Una pausa no es una conclusión.** Solo se admite cuando falta una dependencia externa
   concreta —fuente, artefacto, permiso, hardware o actualización del proveedor— y debe quedar
   escrita de forma que otra sesión pueda reanudarla sin repetir trabajo.

## Bucle obligatorio de diagnóstico

Cada investigación parte de un feedback loop explícito:

```text
reproducir → capturar baseline → formular hipótesis ordenadas
           → predecir una diferencia observable → cambiar una variable
           → medir y mirar → conservar evidencia → aceptar o falsificar
           → volver a la causa mientras el criterio de cierre no esté completo
```

Antes del primer baseline se ejecuta el preflight del juego y backend exactos, sin lanzar nada:

```bash
Regression.app/Contents/SharedSupport/bin/regressionctl preflight APP_ID --backend regression
```

Un resultado `blocked` detiene la prueba: primero se corrige el entorno y se repite la
comprobación. Un resultado `warning` permite continuar, pero queda asociado automáticamente a la
ejecución para que no se confunda con una diferencia del motor. El preflight solo observa: no
termina procesos, no elimina marcadores ni modifica una botella.

Después se abre un expediente local con `regressionctl research-open`. El expediente guarda el
síntoma reproducible y el comportamiento observado en CrossOver. Cada causa posible se registra
como hipótesis falsable, con una predicción que indique qué observación la apoyará y qué
observación la descartará. “Probar otra DLL” no es una hipótesis; “la pareja `d3d11/dxgi` no
pertenece al mismo backend y por eso el módulo efectivo difiere de CrossOver” sí lo es.

Las hipótesis se ordenan por:

1. capacidad de explicar todos los síntomas, no solo uno;
2. evidencia diferencial contra CrossOver;
3. coste y riesgo de la prueba;
4. posibilidad de aislar una única variable;
5. valor del resultado negativo para reducir el espacio de búsqueda.

Si el fallo es intermitente, primero se mide su frecuencia con una escena y duración fijadas. Un
candidato no se acepta porque haya funcionado una vez: debe superar suficientes repeticiones para
que el síntoma histórico deje de reproducirse y conservar las mismas condiciones de comparación.
El número exacto depende del fallo, pero debe declararse antes de ver el resultado.

## Expediente persistente y estados

El esquema local v12 separa los candidatos tecnológicos de los experimentos que realmente se han
ejecutado y conserva el estado previo de cada prueba:

- `compatibility_research_cases`: problema, expectativa CrossOver, estado y conclusión;
- `research_hypotheses`: causas ordenadas, predicción, apoyo o falsación;
- `research_experiments`: una única dimensión cambiada, aislamiento, baseline, candidato, run y
  rollback;
- `research_gate_results`: resultado de cada puerta funcional;
- `research_artifacts`: referencias privadas y huellas de capturas, inventarios, builds, tests,
  firma y rollback.
- `run_preflight_reports`: diagnóstico saneado, fingerprint SHA-256 y vínculo con el run exacto.
- `run_processes`: launcher, ejecutable principal y cierres de una única sesión lógica, sin
  multiplicar el número de experimentos por PID.

Los estados de un expediente son `open`, `investigating`, `validationPending`, `verified` y
`pausedExternalDependency`. No existen “abandonado” ni “cerrado sin resolver”. Un experimento
fallido o revertido permanece en el historial para que otra sesión no vuelva a dar el mismo paso.

La base no almacena comandos, scripts ni blobs. Solo conserva descripciones saneadas, IDs,
referencias privadas y fingerprints. Los perfiles y recetas ejecutables siguen compilados y
revisados en el repositorio.

## Fase 1: establecer dos baselines

### Baseline Regression

- Arrancar desde la app canónica, nunca desde un wine improvisado.
- Descartar wineservers ajenos, procesos huérfanos, diálogos modales de Steam Cloud y ficheros
  `dxmt-cxpresent-*.id` obsoletos.
- Anotar App ID, ejecutable real, argumentos, resolución lógica de macOS, resolución interna del
  juego, modo de ventana y configuración gráfica.
- Capturar el síntoma exacto: negro, parpadeo, geometría dañada, click desplazado, bloqueo al
  cambiar opciones, crash o cierre normal.

### Baseline CrossOver

- Usar la botella donde el usuario ya sabe que el juego funciona.
- No reinstalar el juego si ambas botellas pueden usar una única biblioteca física de Steam.
- Fijar una escena reproducible: menú, personaje/save y zona concreta.
- Confirmar visualmente render, entrada, cambio de opciones y persistencia tras reinicio.
- Registrar la versión exacta de CrossOver y el backend explícito de la botella. El modo
  “automático” no se presupone: hay que comprobar qué ruta termina activa.

### Distinguir una regresión de una limitación compartida

Si una imperfección visual aparece en Regression, primero hay que reproducir la misma escena en
CrossOver y comparar tanto la captura como la configuración escrita por el juego. Cuando ambos
backends producen la misma superficie y la propia interfaz del título no ofrece otra relación de
aspecto, el defecto no demuestra una regresión del motor. Se conserva el baseline funcional como
`Funciona con incidencias`; no se fuerza una resolución en el estado bueno ni se crea un perfil
que solo oculte el síntoma. Rotwood documenta este caso con una superficie 1512×870 compartida en
una pantalla 1512×982: [`games/rotwood.md`](games/rotwood.md).

La paridad con CrossOver tampoco convierte el resultado en perfecto. Si el usuario considera la
presentación incorrecta, la incidencia sigue explícita. Una mejora posterior debe investigarse
como candidato aislado y superar render, composición, entrada, opciones, persistencia y rollback.

## Fase 2: observar sin descompilar

La observación permitida y útil incluye:

- árbol de procesos, comandos y argumentos saneados;
- módulos cargados mediante `lsof`;
- variables de entorno relevantes sin credenciales;
- claves gráficas del registro de la botella;
- crossties públicos o legibles como datos de configuración;
- estructura y hashes de recursos con licencia de uso local;
- logs de Wine, DXMT, DXVK, D3DMetal, MoltenVK y Steam;
- resolución lógica, resolución de framebuffer y geometría de ventanas.

No se descompila la GUI, el sistema de licencias, `cxcompatdb` ni forks privados. Si CrossOver usa
una pieza no pública, la salida válida es investigar una implementación abierta equivalente, no
extraerla.

## Fase 3: construir una matriz de diferencias

Antes de modificar código se prepara una tabla con, al menos:

| Dimensión | CrossOver correcto | Regression fallido | Candidato aislado |
|---|---|---|---|
| Wine/prefix | versión y prefix efectivos | versión y prefix efectivos | igualar convención |
| Backend D3D | D3DMetal, DXMT, DXVK o vkd3d | ruta realmente cargada | un solo backend |
| DLLs | módulos y orden de carga | módulos y orden de carga | perfil propio |
| Overrides | builtin/native/ausente | configuración efectiva | override por proceso |
| Pantalla | lógica, framebuffer, fullscreen | valores observados | conservar render e input |
| Resultado | render, clicks, opciones, gameplay | síntoma exacto | criterio de aceptación |

La matriz evita confundir una correlación —por ejemplo, que una resolución menor alinee el ratón—
con la causa raíz.

## Fase 4: experimentar sin tocar el estado bueno

1. Crear backup de botella, perfil, DLL o bundle que vaya a cambiar.
2. Usar una copia o variables de proceso para el primer candidato.
3. Registrar la hipótesis, la predicción y la única dimensión que cambia.
4. Lanzar desde Steam cuando el DRM lo requiera.
5. Capturar la ventana y mirar la imagen.
6. Interactuar: menús, clicks en extremos, inventario, cámara y opciones.
7. Cambiar una opción gráfica, aplicar, reiniciar y comprobar persistencia.
8. Guardar resultado y módulos efectivos aunque la prueba falle.

Los fallos son datos, pero nunca se promocionan como perfiles. Una prueba que arregla el click y
degrada la imagen sigue siendo fallida.

Una prueba preparada se registra con `regressionctl research-stage`; tras el lanzamiento se
vincula al run exacto mediante `research-attach-run`. Las puertas y evidencias se incorporan una
por una. Así un reinicio de sesión, una compactación de contexto o un agente distinto no pueden
convertir un recuerdo parcial en una conclusión.

## Fase 5: promover un perfil

Un candidato verificado se integra con este orden de preferencia:

1. selección por App ID o nombre exacto del ejecutable;
2. árbol de DLLs propio antepuesto solo a ese proceso;
3. variables y overrides añadidos dentro del proceso;
4. script idempotente que verifica hashes y vuelve a firmar el bundle;
5. parche versionado aplicable a la fuente original;
6. documentación del motivo, no solo del resultado.

No se acepta como perfil individual una mutación global de `system32`, `WINEDLLPATH`, registro o
RetinaMode. Si el cambio debe ser global, se aplica la matriz completa de `AGENTS.md`.

Cuando el candidato necesita Retina y el baseline mantiene `RetinaMode=n`, el patrón aceptado es
un driver dentro del perfil por proceso que lea una variable también definida por ese proceso.
El driver global y el registro de Steam no cambian. Dragon's Dogma 2 documenta esta técnica y la
incidencia de emparejamiento de módulos en
[`games/dragons-dogma-2.md`](games/dragons-dogma-2.md).

Anteponer un directorio tampoco basta si la botella conserva overrides globales que vuelven a
introducir módulos de otro backend. DragonSword demuestra que la ruta debe seleccionarse como un
conjunto coherente dentro del proceso: perfil, variables y load-order. El diagnóstico y la receta
blindada están en [`games/dragonsword-awakening.md`](games/dragonsword-awakening.md).

Un fallo de creación OpenGL tampoco justifica cambiar de API por intuición. Heroes of Hammerwatch
II demostró que primero hay que comparar el error exacto contra la fuente Wine de referencia:
BGFX pedía core 3.2 sin el bit forward-compatible y el árbol CX 26.3 ya ofrecía un hook opt-in
para ese caso. La promoción activa el hook solo en `HWR2.exe`, conserva el driver global y prueba
Steam más Grim Dawn. El expediente reproducible está en
[`games/heroes-of-hammerwatch-2.md`](games/heroes-of-hammerwatch-2.md).

“Funciona perfecto” y “mejor opción conocida” son afirmaciones independientes. Una versión más
reciente de Wine, GPTK/D3DMetal, DXMT, DXVK, MoltenVK o vkd3d solo puede promocionarse si el
candidato es por juego, tiene fuente/huella verificadas, está aislado, dispone de rollback,
supera toda la matriz y aporta una medición comparable. El contrato técnico está en
[`runtime-evolution.md`](runtime-evolution.md).

## Fase 6: evidencia y aprendizaje

Cada perfil perfecto debe conservar:

- configuración exacta y hashes de los componentes;
- captura local del resultado y su SHA-256;
- lista saneada de módulos cargados;
- resolución, backend, App ID y ejecutable;
- comprobación de ausencia de rutas de CrossOver en el proceso propio;
- resultado de build, tests, firma y aplicación del parche;
- confirmación visual explícita del usuario;
- ruta de rollback;
- expediente del juego dentro de `docs/games/`;
- observación en Engram y nota de memoria cuando el usuario lo solicite.
- registro `perfect` en la base de compatibilidad y captura de la fila verde
  `Verificado perfecto: Regression` después de refrescar la app.

El cierre estructurado exige además estas ocho puertas sobre el mismo experimento:

1. referencia CrossOver reproducida;
2. render correcto;
3. entrada precisa;
4. opciones gráficas modificables y persistentes;
5. gameplay representativo;
6. ausencia de recursos ejecutables de CrossOver en el motor propio;
7. matriz de regresión correspondiente al componente tocado;
8. rollback ensayado o verificado.

Y estas ocho evidencias con huella:

1. captura CrossOver;
2. captura Regression;
3. inventario de módulos;
4. snapshot de configuración;
5. informe de build;
6. informe de tests;
7. informe de firma;
8. manifiesto de rollback.

Los triggers SQLite y la política Swift impiden marcar el experimento como `passed` o el
expediente como `verified` si falta cualquiera de ellas, si las huellas de baseline y candidato
son iguales o si el run vinculado no creó un blindado perfecto y activo de Regression. Corregir
posteriormente ese veredicto reabre el expediente automáticamente.

La base SQLite de Regression registra ejecuciones, comparaciones y métricas, pero no debe aplicar
por sí sola un perfil al motor propio. La promoción sigue siendo una decisión de ingeniería
respaldada por evidencia visual, rendimiento y rollback.

## Criterio de cierre

Un juego queda blindado cuando, desde la instalación canónica:

- renderiza sin fallos durante una escena representativa;
- los clicks son precisos en toda la pantalla;
- las opciones gráficas se pueden cambiar y persisten;
- el gameplay es estable;
- el proceso usa únicamente recursos autorizados de Regression;
- Steam y al menos un perfil ya verificado siguen intactos cuando el cambio comparte una pieza;
- existe rollback y el cambio es reproducible desde el repositorio.

El cierre no termina con una impresión verbal ni con un exit code: hay que asociar la validación
al run exacto con `regressionctl verify`, refrescar la app y comprobar visualmente el distintivo.
La validación puede proceder del usuario o del agente cuando este haya controlado y capturado
directamente toda la matriz: render, entrada en distintas zonas, gameplay, pausa, cambio y
persistencia de opciones, restauración del estado y cierre. Los intentos fallidos se mantienen
porque explican el aprendizaje; la UI prioriza el mejor perfil perfecto confirmado.

Solo hay dos salidas legítimas del trabajo activo:

- **verificado**: toda la matriz, la evidencia, el blindado, la independencia y el rollback están
  completos;
- **pausado por dependencia externa concreta**: la causa bloqueante queda identificada, se
  conserva el siguiente experimento y la investigación es reanudable.

“Compila”, “ha abierto”, “esta vez no falló” o “se han probado muchas cosas” nunca son condiciones
de cierre.

## Comandos del expediente

```bash
regressionctl research
regressionctl research-protocol
regressionctl research-open APP_ID --symptom "..." --expected "..." [--name "..."]
regressionctl research-hypothesis CASE_ID --rank 1 --statement "..." --prediction "..."
regressionctl research-stage CASE_ID --dimension graphicsBackend --change "..." \
  --rollback "..." --baseline "..." [--hypothesis UUID]
regressionctl research-attach-run EXPERIMENT_ID RUN_ID
regressionctl research-gate EXPERIMENT_ID rendering passed --evidence "..."
regressionctl research-artifact EXPERIMENT_ID regressionCapture \
  --reference "..." --fingerprint "sha256:..."
regressionctl research-finish EXPERIMENT_ID failed --note "..."
regressionctl research-complete CASE_ID EXPERIMENT_ID --resolution "..."
```

`research-protocol` enumera los valores permitidos vigentes. La exportación JSON incluye todo el
expediente, pero nunca aplica ni ejecuta lo aprendido.
