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
   archivos afectados y se registran hashes.

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
3. Cambiar una sola variable.
4. Lanzar desde Steam cuando el DRM lo requiera.
5. Capturar la ventana y mirar la imagen.
6. Interactuar: menús, clicks en extremos, inventario, cámara y opciones.
7. Cambiar una opción gráfica, aplicar, reiniciar y comprobar persistencia.
8. Guardar resultado y módulos efectivos aunque la prueba falle.

Los fallos son datos, pero nunca se promocionan como perfiles. Una prueba que arregla el click y
degrada la imagen sigue siendo fallida.

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

El cierre no termina con la frase del usuario: hay que asociar esa confirmación al run exacto con
`regressionctl verify`, refrescar la app y comprobar visualmente el distintivo. Los intentos fallidos
se mantienen porque explican el aprendizaje; la UI prioriza el mejor perfil perfecto confirmado.
