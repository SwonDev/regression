# Plataforma local de compatibilidad y aprendizaje

Fecha de contrato: 14 de agosto de 2026. Esquema SQLite actual: **v17**.

Esta capa conserva evidencia reproducible de cada ejecución de Regression. No consulta servicios
de compatibilidad de terceros ni altera el motor, la botella o la configuración de un juego. La
aplicación automática de perfiles queda expresamente fuera de alcance hasta que exista un protocolo
separado con rollback y matriz de validación.

## Fuentes de verdad y precedencia

1. **Certificación local perfecta**: confirmación visual explícita de render, precisión de entrada,
   opciones gráficas persistentes y gameplay. Es la única fuente que muestra
   `Verificado perfecto: Regression`.
2. **Ejecuciones y observaciones locales**: conservan éxitos, incidencias, fallos y estados sin
   verificar. Un código de salida 0 nunca se convierte por sí solo en compatibilidad.
3. **Referencias históricas importadas**: contexto de expedientes anteriores, sin red ni autoridad
   operativa. Nunca certifican, instalan dependencias o aplican configuraciones.

Los fallos históricos no se borran cuando aparece un perfil perfecto: sirven para comparar qué
cambió. La certificación perfecta tiene prioridad visual, pero no reescribe el historial.

## Modelo de datos

La base vive en
`~/Library/Application Support/Regression/Compatibility/compatibility.sqlite` con directorios
`0700`, archivos `0600`, claves foráneas activas, WAL, `synchronous=FULL` y comprobación de
integridad en cada apertura.

| Área | Tablas | Responsabilidad |
|---|---|---|
| Juegos | `games` | Steam App ID y nombre público normalizado. |
| Ejecuciones | `runs`, `run_processes`, `run_events`, `run_verifications` | Sesión lógica, cadena de PID, comando saneado, sistema, tiempos, cierre y veredicto modal. |
| Evidencia histórica | `compatibility_observations` | Validaciones importadas anteriores a la telemetría. |
| Configuración | `configuration_snapshots` | Snapshot completo y deduplicado por SHA-256. |
| Motores | `engine_snapshots`, `engine_facts`, `run_engine_snapshots`, `observation_engine_snapshots` | Identidad consultable del stack y vínculo con cada evidencia. |
| Blindados | `verified_game_certifications` | Catálogo canónico y certificaciones locales con procedencia, configuración y motor exactos. |
| Referencias históricas | `external_catalog_sources`, `external_catalog_sync_state`, `external_game_records`, `external_game_links` | Datos heredados conservados para explicar expedientes antiguos; no se sincronizan ni gobiernan el producto. |
| Evolución de runtimes | `runtime_technologies`, `runtime_candidates` | Baselines, versiones observadas y candidatos aislados con gates de promoción. |
| Rendimiento | `optimization_assessments` | Métricas separadas de la certificación funcional. |
| Requisitos y reparación | `game_runtime_requirements`, `repair_receipts` | Requisitos declarativos y recibos de recetas permitidas; nunca comandos aprendidos. |
| Expedientes de I+D | `compatibility_research_cases`, `research_hypotheses`, `research_experiments`, `research_gate_results`, `research_artifacts` | Hipótesis falsables, pruebas de una variable, puertas funcionales y referencias privadas con huella. |
| Preparación de pruebas | `run_preflight_reports` | Diagnóstico saneado, fase temporal, latencia y firma lógica del entorno asociado a cada lanzamiento. |
| Autoridad de lanzamiento | `launch_envelopes`, `launch_envelope_events`, `launch_envelope_receipts` | Intención durable anterior al `spawn`, transiciones auditables y recibos sin comandos ni autoridad de certificación. |
| Migraciones | `schema_migrations` + `PRAGMA user_version` | Evolución atómica y auditable. |

Dos triggers de inserción/actualización protegen tanto ejecuciones como observaciones: SQLite
rechaza cualquier veredicto `perfect` si una de las cuatro dimensiones no vale `passed`. La misma
regla existe en Swift y se vuelve a comprobar tras migrar, de modo que un error de una capa no
puede degradar silenciosamente el contrato.

Una ejecución debe haber recibido un PID real y haber salido de `preparing` antes de aceptar un
veredicto perfecto. La migración v6 anula como `invalidated` cualquier marca heredada que incumpla
esa regla; el evento original se conserva para auditoría, pero no crea perfil verde ni blindado.

## Custodia de procesos y perfectos v15

El esquema v15 hace que la cadena de procesos forme parte de la evidencia, no sea solo
telemetría auxiliar. Para que un veredicto `perfect` sea público deben cumplirse simultáneamente:

1. `runs.process_id` existe, el run no sigue en `preparing` y tiene `ended_at`;
2. existe una única fila `run_processes` representativa con ese mismo PID;
3. ningún proceso del run permanece abierto;
4. ningún proceso terminó después de `run_verifications.verified_at`;
5. la verificación se registró después del cierre del run.

Los triggers de inserción, actualización y borrado de `run_processes` vuelven a evaluar ese sello.
Si aparece un proceso tardío, cambia el representante o se reabre un cierre, la verificación se
invalida y la certificación se desactiva. No se borra ningún evento: los lectores públicos
presentan como `invalidated` cualquier perfecto legacy incoherente y la exportación conserva la
causa auditable.

## Salud de la telemetría

`SteamLogReadOutcome` y `TelemetryPollOutcome` conservan incidencias tipadas. El monitor distingue
log ausente o ilegible, sustitución, truncado, línea pendiente abandonada, exceso de formato no
reconocido y límite de lectura. Una incidencia persistente continúa visible aunque no sea nueva;
la recuperación se emite por separado.

La lectura es incremental y acotada: hasta 512 KiB por pasada, 256 KiB de línea pendiente y ocho
logs monitorizados. La rotación o reescritura cambia la época del log, descarta el fragmento
ambiguo y no permite que eventos de la época anterior consuman una intención o sesión nueva. El
coordinador ignora además eventos anteriores a la fecha verificable del run. Estas incidencias
explican por qué falta evidencia; no crean por sí mismas un crash, un éxito o una reparación.

## Autoridad de lanzamiento v17

La v17 conserva el sobre introducido por v16 y cierra su recuperación de proceso. La intención vincula un
run y App ID canónicos al backend Regression, al preflight completo y no bloqueado de los últimos
90 segundos, a la generación fresca del inventario de requisitos y a identidades cerradas de
componentes sellados o perfiles compilados. También exige que el runtime, Windows Media cuando
corresponda y el renderer elegido hayan superado sus autoridades respectivas. El sobre es
deliberadamente inerte: no contiene ejecutables, rutas, DLLs, argumentos ni comandos que SQLite
pudiera convertir en código.

Sus fases distinguen intención durable, autorización, proceso iniciado, espera de telemetría,
espera de verificación, finalización, fallo anterior al `spawn` y rollback. SQLite valida las
transiciones persistidas y la coherencia de los recibos. La ruta operativa prepara y guarda el
sobre, autoriza el `spawn` y adopta el mismo run en telemetría mientras continúa abierto —por
ejemplo, al pasar de un lanzamiento CLI a la app activa—. Tras relanzar Regression, el arranque
cierra y reconcilia el run interrumpido para auditoría; no reanuda su telemetría como si la sesión
siguiera viva. El sobre avanza a `awaitingVerification` al cerrar una sesión viva y solo se
completa después de una verificación explícita. Por eso ni un evento, ni un recibo, ni un código
de salida pueden crear `Verificado perfecto`.

El límite vuelve a comprobar el preflight sellado en la transacción del boundary y no admite más
de 90 segundos. Si `Process.run()` rechaza síncronamente el ejecutable después del marker, el run,
su evento, el receipt y el envelope terminan atómicamente como `failedBeforeSpawn`. En el arranque,
una sesión con proceso representativo cerrado conserva su resultado y espera verificación; un
fallo confirmado sin PID termina como pre-spawn; la evidencia ambigua queda en
`rollbackPending` hasta una recuperación explícita que la registra como `rolledBack`.

`retryDecision` y `recoveryDecision` son por ahora políticas puras, cubiertas por tests, no un
ejecutor. Expresan que solo una receta y versión compiladas, originadas en Regression y todavía sin
retry podrían optar a un reintento, y distinguen rollback de reconciliación según la fase. No hay
un caller que ejecute de forma segura ese auto-retry o rollback, verifique su resultado y emita el
recibo correspondiente. Ambas mutaciones automáticas permanecen bloqueadas hasta integrar ese
ejecutor y su verificador. Steam observado, una receta no permitida, una fase incompatible o el
límite agotado requieren siempre un gesto nuevo del usuario.

Una certificación creada desde una verificación local guarda su ejecución u observación de origen,
el fingerprint completo de configuración y el fingerprint normalizado del motor. Al corregir el
último veredicto perfecto, esa certificación pasa a inactiva; no se borra y continúa disponible en
la exportación histórica. Los blindados embebidos conservan su expediente canónico y se enlazan
automáticamente a evidencia local cuando existe.

La persistencia manual se prueba de extremo a extremo: alta desde una ejecución real, cierre de
SQLite, reapertura, recuperación de la misma procedencia/configuración/motor y presencia en la
exportación JSON. La interfaz enumera los blindados activos para que la persistencia no dependa de
inferirla desde una fila de juego instalada.

Una certificación funcional y una optimización son afirmaciones distintas. El blindado fija una
ruta reproducible; las versiones más recientes se registran como candidatos aislados y no pueden
promocionarse sin rollback, matriz completa y rendimiento medido. El contrato detallado está en
[`runtime-evolution.md`](runtime-evolution.md).

Un candidato tampoco equivale a un experimento: el primero describe una tecnología posible; el
segundo demuestra qué hipótesis se probó, qué única dimensión cambió y qué run exacto produjo el
resultado. El esquema actual impide cerrar un expediente sin las ocho puertas funcionales, ocho
artefactos con huella, identidades distintas de baseline/candidato y una certificación perfecta
activa del mismo run de Regression. Los expedientes fallidos se conservan y una corrección del
veredicto reabre automáticamente el que se había cerrado.

Antes de cada lanzamiento, el protocolo v2 de preparación comprueba de forma no destructiva la
base, el motor Regression, la instalación del juego, el aislamiento de Steam y Wine, servicios huérfanos,
marcadores de presentación, almacenamiento, telemetría y biblioteca propia. Un bloqueo
inequívoco impide crear una prueba contaminada; un aviso se permite y se conserva. Cada informe
se vincula por App ID y backend al `run` exacto, se codifica como JSON canónico, se acompaña de
SHA-256 y se revalida al leer y exportar. Desde el botón de Regression la fase es `preLaunch` y
solo puede persistirse mientras el run continúa en `preparing`. Cuando el usuario inicia desde la
interfaz completa de Steam, Regression no dispone de un hook previo oficial: toma la instantánea
al detectar el primer proceso, almacena `processStartBoundary` y su latencia, y jamás la presenta
como evidencia previa exacta. Un informe verde no certifica render, entrada, opciones ni gameplay.

## Identidad normalizada de motor

El fingerprint de motor se calcula solo con:

- runtime y versión de Regression;
- configuración permitida de botella y registro;
- backend gráfico observado;
- firmas SHA-256 y tamaños de DLLs gráficas y componentes runtime.

Las claves `gameconfig.*` se excluyen deliberadamente. Cambiar la resolución de Grim Dawn no crea
un motor nuevo; cambiar `dxgi.dll`, Wine, DXMT, DXVK, D3DMetal o una clave del registro sí. El
snapshot completo del juego permanece asociado a la ejecución, por lo que ambas dimensiones se
pueden comparar sin mezclarlas.

`regressionctl engines` agrega por motor juegos observados y resultados perfectos, con
incidencias, fallidos o pendientes. Esto permite responder qué stack produjo el mejor resultado
sin asumir que todos los perfiles de un mismo backend son equivalentes.

## Datos externos heredados — solo historia

Las tablas `external_*` pueden contener metadatos públicos capturados por versiones antiguas. Se
conservan para que los expedientes históricos sigan siendo interpretables, pero la aplicación y
el CLI actuales no realizan peticiones a CodeWeavers, no exponen una sincronización y no usan esos
datos para seleccionar motores, reparar, lanzar o certificar. No existe un backend, proceso de
enlace o requisito de red asociado a ellos.

## Migraciones y recuperación

La apertura es transaccional. Antes de elevar una base existente con datos, se crea mediante la
API de backup de SQLite una copia íntegra en `Compatibility/Backups/`, se valida y se protege en
`0600`. Si una migración falla, la transacción se revierte y la aplicación conserva el backup.

El empaquetador realiza además un snapshot independiente antes de instalar una versión nueva. La
migración v5 reconstruye las identidades de motor para todas las ejecuciones y observaciones
existentes. La v6 enlaza los blindados con su procedencia exacta y recupera como certificaciones
locales solo los veredictos perfectos históricos asociados a un lanzamiento real. La v7 añade el
inventario tecnológico, candidatos aislados, métricas, requisitos declarativos y
recibos de reparación. La v8 exige además una comparación equivalente contra el baseline: misma
resolución y preset, ninguna regresión en métricas comunes y una mejora efectiva como mínimo.
Sus triggers impiden declarar una opción óptima sin métricas o promover un candidato sin
aislamiento, huellas, rollback, matriz y mejora comparada. La validación final exige que ninguna
evidencia quede sin motor asociado y que ningún blindado local activo apunte a un veredicto
incompleto u obsoleto.
La v9 cierra dos vías de falsa optimización: todas las métricas disponibles deben tener la misma
cobertura en baseline y candidato, y los valores deben ser finitos, positivos y acotados. Además,
la resolución y el preset dejan de ser opcionales para `bestKnown`, y la política Swift rechaza
fuentes cuyo host no coincida con el sitio oficial registrado para la tecnología.
La v10 añade expedientes de I+D, hipótesis falsables, experimentos de una sola dimensión,
puertas y artefactos con huella. Sus triggers impiden cerrar un caso sin aislamiento, rollback,
evidencia completa y el blindado perfecto del run exacto de Regression; una corrección posterior
del veredicto reabre el expediente.
La v11 añade `run_preflight_reports` y exige que la preparación persistida coincida con el App ID
y backend de la ejecución. Conserva únicamente resultados saneados —sin PID, comandos crudos,
rutas personales ni datos de cuenta— y verifica contadores, versión de protocolo y huella al
reabrir. La migración no crea diagnósticos retroactivos ni altera ejecuciones históricas.
La v12 normaliza cada PID en `run_processes` y mantiene un único run por sesión activa de backend
y App ID. El launcher, el binario principal y sus cierres siguen siendo auditables, pero ya no
cuentan como pruebas independientes. También añade fase y latencia al diagnóstico: los informes
v1 existentes migran como `preLaunch`, mientras que los futuros lanzamientos observados dentro de
Steam se distinguen como `processStartBoundary`. El historial anterior no se fusiona ni reescribe.
La v13 incorpora el ciclo durable de reparaciones compiladas, con estado y recibos recuperables.
La v14 reconstruye el subgrafo de I+D para que el baseline operativo sea Regression y conserva los
valores antiguos exclusivamente por compatibilidad de lectura del historial.
La v15 reinstala atómicamente los guards de promoción de I+D y exige que toda evidencia perfecta
de un run conserve su PID exacto en una fila `run_processes` marcada como representativa. Los
lectores públicos degradan a `invalidated` cualquier perfecto legacy que ya no cumpla ese sello.
La v17 mantiene la autoridad durable de lanzamiento por App ID. Migra desde v16 sin reinterpretar
perfectos ni recibos anteriores, sustituye transaccionalmente el guard de transición y vuelve a
validar la integridad completa antes de confirmar `PRAGMA user_version=17`.

Comprobaciones:

```bash
Regression.app/Contents/SharedSupport/bin/regressionctl database
Regression.app/Contents/SharedSupport/bin/regressionctl processes [RUN_ID]
Regression.app/Contents/SharedSupport/bin/regressionctl engines
Regression.app/Contents/SharedSupport/bin/regressionctl technologies
Regression.app/Contents/SharedSupport/bin/regressionctl candidates
Regression.app/Contents/SharedSupport/bin/regressionctl optimization
Regression.app/Contents/SharedSupport/bin/regressionctl research
Regression.app/Contents/SharedSupport/bin/regressionctl research-protocol
Regression.app/Contents/SharedSupport/bin/regressionctl preflight
Regression.app/Contents/SharedSupport/bin/regressionctl preflight 219990 --backend regression
Regression.app/Contents/SharedSupport/bin/regressionctl export /tmp/regression.json
```

Para ensayar una migración sobre una copia, `regressionctl` admite únicamente por terminal
`REGRESSION_COMPATIBILITY_DATABASE_PATH=/ruta/copia.sqlite`; la app instalada siempre usa la ruta
canónica. Este override existe para diagnóstico y CI, no para dividir el historial del usuario.

## Gates de esta capa

- Migración desde un esquema legado con backup privado.
- Migración v16→v17 con custodia perfecta intacta y sustitución transaccional del guard de spawn;
  la autoridad existente permanece intacta hasta crear nueva evidencia o recuperarla explícitamente.
- Rechazo de perfectos incompletos en Swift y SQLite.
- Rechazo de sobres con App ID/backend/preflight/requisitos no coincidentes, transiciones ilegales
  o recibos incompatibles.
- Adopción operativa del run para telemetría, avance a espera de verificación y cierre solo tras
  verificación explícita.
- Política pura de recuperación/retry probada sin presentar auto-retry o rollback como integrados;
  su futura ejecución deberá demostrar receta compilada, verificación y recibo durable.
- Alta y desactivación reversible de un blindado local ligado a evidencia/configuración/motor.
- Persistencia del blindado manual tras reapertura y presencia con procedencia exacta en JSON.
- Rechazo Swift/SQLite de promociones sin aislamiento, rollback, matriz y medición.
- Rechazo de una opción `bestKnown` sin ninguna métrica de rendimiento.
- Reconciliación de observaciones interrumpidas como `unknown`, nunca como éxito o fallo inferido.
- Normalización de dos configuraciones gráficas de juego bajo un mismo motor.
- Ausencia de sincronización externa o autoridad operativa en las referencias heredadas.
- Rechazo de informes de preparación vinculados a otro juego o backend.
- Verificación SHA-256 y exportación del diagnóstico previo sin convertirlo en certificación.
- Agrupación de launcher y ejecutable principal en un run con procesos exportables por separado.
- Rechazo de una captura `preLaunch` añadida después de iniciar y de una captura observada sin PID.
