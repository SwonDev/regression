# Plataforma local de compatibilidad y aprendizaje

Fecha de contrato: 28 de julio de 2026. Esquema SQLite actual: **v11**.

Esta capa conserva evidencia reproducible de cada ejecución y permite comparar Regression con
fuentes públicas. No altera el motor, la botella ni la configuración de un juego. La aplicación
automática de perfiles queda expresamente fuera de alcance hasta que exista un protocolo separado
con rollback y matriz de validación.

## Fuentes de verdad y precedencia

1. **Certificación local perfecta**: confirmación visual explícita de render, precisión de entrada,
   opciones gráficas persistentes y gameplay. Es la única fuente que muestra
   `Verificado perfecto: Regression`.
2. **Ejecuciones y observaciones locales**: conservan éxitos, incidencias, fallos y estados sin
   verificar. Un código de salida 0 nunca se convierte por sí solo en compatibilidad.
3. **Catálogo público externo**: contexto de investigación. Una valoración alta de CodeWeavers no
   certifica Regression, no instala dependencias y no aplica configuraciones.

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
| Ejecuciones | `runs`, `run_events`, `run_verifications` | Comando saneado, sistema, tiempos, cierre y veredicto modal. |
| Evidencia histórica | `compatibility_observations` | Validaciones importadas anteriores a la telemetría. |
| Configuración | `configuration_snapshots` | Snapshot completo y deduplicado por SHA-256. |
| Motores | `engine_snapshots`, `engine_facts`, `run_engine_snapshots`, `observation_engine_snapshots` | Identidad consultable del stack y vínculo con cada evidencia. |
| Blindados | `verified_game_certifications` | Catálogo canónico y certificaciones locales con procedencia, configuración y motor exactos. |
| Fuentes públicas | `external_catalog_sources`, `external_catalog_sync_state`, `external_game_records`, `external_game_links` | Caché, cadencia, ficha normalizada y vínculo local. |
| Evolución de runtimes | `runtime_technologies`, `runtime_candidates` | Baselines, versiones observadas y candidatos aislados con gates de promoción. |
| Rendimiento | `optimization_assessments` | Métricas separadas de la certificación funcional. |
| Requisitos y reparación | `game_runtime_requirements`, `repair_receipts` | Requisitos declarativos y recibos de recetas permitidas; nunca comandos aprendidos. |
| Expedientes de I+D | `compatibility_research_cases`, `research_hypotheses`, `research_experiments`, `research_gate_results`, `research_artifacts` | Hipótesis falsables, pruebas de una variable, puertas funcionales y referencias privadas con huella. |
| Preparación de pruebas | `run_preflight_reports` | Diagnóstico saneado y firmado lógicamente del entorno exacto anterior a cada lanzamiento. |
| Migraciones | `schema_migrations` + `PRAGMA user_version` | Evolución atómica y auditable. |

Dos triggers de inserción/actualización protegen tanto ejecuciones como observaciones: SQLite
rechaza cualquier veredicto `perfect` si una de las cuatro dimensiones no vale `passed`. La misma
regla existe en Swift y se vuelve a comprobar tras migrar, de modo que un error de una capa no
puede degradar silenciosamente el contrato.

Una ejecución debe haber recibido un PID real y haber salido de `preparing` antes de aceptar un
veredicto perfecto. La migración v6 anula como `invalidated` cualquier marca heredada que incumpla
esa regla; el evento original se conserva para auditoría, pero no crea perfil verde ni blindado.

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

Antes de cada lanzamiento, el protocolo v1 de preparación comprueba de forma no destructiva la
base, el backend, la instalación del juego, el aislamiento de Steam y Wine, servicios huérfanos,
marcadores de presentación, almacenamiento, telemetría y biblioteca compartida. Un bloqueo
inequívoco impide crear una prueba contaminada; un aviso se permite y se conserva. Cada informe
se vincula por App ID y backend al `run` exacto, se codifica como JSON canónico, se acompaña de
SHA-256 y se revalida al leer y exportar. Un preflight verde no certifica render, entrada,
opciones ni gameplay.

## Identidad normalizada de motor

El fingerprint de motor se calcula solo con:

- backend y versión del proveedor;
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

## Referencia pública de CodeWeavers

La integración usa exclusivamente páginas públicas de la
[Compatibility Database](https://www.codeweavers.com/compatibility) y su JSON-LD de Schema.org.
No consulta ni copia `cxcompatdb`, crossties privados, binarios, datos de licencia ni bases internas.

Proceso de enlace:

1. Prioriza un mapeo conocido y revisable por Steam App ID cuando existe.
2. Prueba una URL de ficha probable derivada del nombre público.
3. Si no coincide exactamente, usa la búsqueda pública y acepta únicamente título normalizado
   exacto o Steam App ID exacto.
4. Rechaza redirecciones, fichas canónicas o enlaces fuera de HTTPS y de
   `codeweavers.com/compatibility`.
5. Guarda solo nombre, compañía/categoría públicas, Steam App ID, valoración macOS/Linux,
   versión de CrossOver, fecha, URL, validadores HTTP y fingerprint del JSON-LD.

Las valoraciones públicas se conservan en su escala original 0–5. La comparación derivada puede
indicar acuerdo, que Regression supera la referencia o que la referencia pública supera el
resultado local; si falta evidencia local o pública, queda como `insufficientEvidence`.

### Red, caché y privacidad

- Sesión efímera sin cookies, caché del sistema ni credenciales.
- Límite de respuesta de 3 MB, timeouts y lista cerrada de hosts/rutas.
- `ETag`/`Last-Modified` para no descargar fichas sin cambios.
- Caché positiva de 7 días y negativa de 30 días.
- Cadencia persistente mínima de 100 segundos entre peticiones, incluso entre reinicios, conforme
  al `Crawl-delay` público observado; la sincronización es secuencial y nunca bloquea Steam.
- La opción puede desactivarse desde “Aprendizaje local”. La app envía únicamente el nombre
  público del juego cuando necesita buscarlo y conserva los metadatos normalizados localmente.
- Un fallo de red mantiene la última ficha válida y se muestra como incidencia recuperable.

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

Comprobaciones:

```bash
Regression.app/Contents/SharedSupport/bin/regressionctl database
Regression.app/Contents/SharedSupport/bin/regressionctl engines
Regression.app/Contents/SharedSupport/bin/regressionctl technologies
Regression.app/Contents/SharedSupport/bin/regressionctl candidates
Regression.app/Contents/SharedSupport/bin/regressionctl optimization
Regression.app/Contents/SharedSupport/bin/regressionctl research
Regression.app/Contents/SharedSupport/bin/regressionctl research-protocol
Regression.app/Contents/SharedSupport/bin/regressionctl preflight
Regression.app/Contents/SharedSupport/bin/regressionctl preflight 219990 --backend regression
Regression.app/Contents/SharedSupport/bin/regressionctl catalog
Regression.app/Contents/SharedSupport/bin/regressionctl comparisons
Regression.app/Contents/SharedSupport/bin/regressionctl export /tmp/regression.json
```

Para ensayar una migración sobre una copia, `regressionctl` admite únicamente por terminal
`REGRESSION_COMPATIBILITY_DATABASE_PATH=/ruta/copia.sqlite`; la app instalada siempre usa la ruta
canónica. Este override existe para diagnóstico y CI, no para dividir el historial del usuario.

## Cómo añadir otra fuente pública

1. Implementar `ExternalCompatibilityProviding` con modelo normalizado y lista cerrada de URLs.
2. Definir cadencia, TTL y página informativa oficiales en `ExternalCatalogSource`.
3. Añadir tests de parser con HTML mínimo, redirecciones hostiles, documentos incompletos y
   coincidencias ambiguas.
4. Mantener la fuente identificada en todas las claves. Nunca combinar entradas solo por App ID.
5. Elegir explícitamente qué fuente alimenta cada comparación; ninguna puede producir una
   certificación local.

## Gates de esta capa

- Migración desde un esquema legado con backup privado.
- Rechazo de perfectos incompletos en Swift y SQLite.
- Alta y desactivación reversible de un blindado local ligado a evidencia/configuración/motor.
- Persistencia del blindado manual tras reapertura y presencia con procedencia exacta en JSON.
- Rechazo Swift/SQLite de promociones sin aislamiento, rollback, matriz y medición.
- Rechazo de una opción `bestKnown` sin ninguna métrica de rendimiento.
- Reconciliación de observaciones interrumpidas como `unknown`, nunca como éxito o fallo inferido.
- Normalización de dos configuraciones gráficas de juego bajo un mismo motor.
- Caché y cadencia persistente.
- Parser JSON-LD macOS/Linux y filtrado de enlaces.
- Rechazo de una URL canónica que imita el dominio oficial.
- Confirmación de que una valoración pública 5/5 deja el estado local como no verificado.
- Rechazo de informes de preparación vinculados a otro juego o backend.
- Verificación SHA-256 y exportación del diagnóstico previo sin convertirlo en certificación.
