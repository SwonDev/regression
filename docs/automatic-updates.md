# Actualizaciones automáticas de Regression

Regression consulta el endpoint oficial `releases/latest` al arrancar y cada seis horas mientras
permanece abierto en la barra de menús. Las actualizaciones automáticas están activadas por defecto
y pueden desactivarse desde **Mantenimiento** sin desactivar la detección de versiones nuevas.

## Canal aceptado

La aplicación solo acepta una release que cumpla simultáneamente estas condiciones:

- procede de `SwonDev/regression` mediante HTTPS;
- no es borrador ni prerelease;
- tiene una versión semántica estrictamente posterior a la instalada;
- incluye el asset exacto `install_regression.sh` en el repositorio oficial;
- GitHub publica un digest SHA-256 válido para ese asset;
- la respuesta y el instalador respetan límites de tamaño acotados.

El redirect final de descarga puede usar la infraestructura oficial de objetos de GitHub, pero el
asset inicial nunca puede apuntar a otro repositorio. Regression vuelve a calcular el SHA-256 antes
de escribir o ejecutar el instalador.

## Instalación sin interrumpir juegos

La actualización automática solo se ejecuta desde `/Applications/Regression.app`. Si Steam del
motor Regression o una operación crítica están activos, la release queda pendiente y se instala
automáticamente en el primer refresco en reposo. No se termina un juego, no se mata Wine y no se
modifica la botella para forzar una actualización.

El staging privado usa permisos `0700`, el instalador `0700` y el log `0600`; no se siguen enlaces
simbólicos en el destino. Tras verificar el script, Regression inicia el instalador transaccional,
cierra primero su base SQLite y sus tareas, y solo entonces solicita a AppKit una terminación
inmediata. El instalador espera ese PID antes de sustituir la app,
verifica el tar completo, firma, runtime, redistribuibles y un arranque real de Wine, conserva la
botella y el GPTK local autorizado, archiva rollback y relanza Regression.

Si falla cualquier puerta, la app anterior permanece o se restaura y se vuelve a abrir. Regression
recuerda la versión intentada: no repite automáticamente el mismo fallo en bucle y deja una acción
de reintento manual dentro de **Mantenimiento**. Nunca se marca una actualización fallida como
instalada.

## Controles visibles

En **Mantenimiento** se muestran:

- el interruptor «Actualizar Regression automáticamente»;
- la versión instalada y la hora de la última comprobación;
- el estado de descarga, instalación o error;
- la actualización pendiente cuando Steam debe cerrarse primero;
- «Actualizar y reiniciar» como alternativa manual dentro de la propia app.

El usuario no necesita abrir GitHub ni ejecutar comandos para actualizar una instalación canónica.
