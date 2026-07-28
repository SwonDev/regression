# Auditoría integral de la base nativa

Fecha: 28 de julio de 2026. Alcance: SwiftUI/AppKit, coordinación de backends, aprendizaje local,
catálogo público, CLI, privacidad, rendimiento, ciclo de vida, empaquetado, documentación y
coherencia del proyecto. Esta pasada no modificó Wine, DXMT, DXVK, D3DMetal, Apple GPTK, la
botella ni los perfiles de juegos blindados, y no lanzó ningún juego.

## Baseline y límites protegidos

Antes y después de empaquetar se ejecutó `build/verify-protected-state.sh --include-bottle`.
Quedaron intactos los hashes del runtime, la pareja DXMT, D3D9, el perfil relativo de Grim Dawn,
el launcher propio y la botella canónica. `/Applications/Regression.app` continúa siendo un
symlink al bundle del proyecto porque el prefijo de Wine está horneado en esa ruta.

El trabajo se limitó a la capa nativa y a su base de evidencia. El backend CrossOver continúa
usando únicamente su CLI oficial; el motor propio no incorporó ni enlazó binarios propietarios.
La referencia pública de CodeWeavers se trata como contexto, nunca como certificación local.

## Plataforma de aprendizaje v10

- El contrato perfecto exige `render`, `input`, `options` y `gameplay` en `passed`, tanto en Swift
  como mediante triggers SQLite. Un código de salida 0 no certifica nada.
- Una ejecución debe tener PID real y haber abandonado `preparing`. La migración v6 invalida las
  marcas heredadas imposibles y conserva su historial; no las convierte en perfiles verdes.
- Cada certificación enlaza su ejecución u observación exacta, fingerprint de configuración,
  fingerprint de motor, revisión de catálogo, origen y estado activo. Corregir la última evidencia
  perfecta desactiva la certificación sin borrarla.
- Las ejecuciones interrumpidas se reconcilian como `unknown`. No quedan observaciones activas
  indefinidamente ni se infiere éxito o fallo.
- Los motores se normalizan por backend/proveedor, botella/registro permitidos, capa gráfica y
  hashes de componentes. Las opciones propias del juego permanecen separadas para no inventar un
  motor nuevo al cambiar resolución o calidad.
- Las migraciones son transaccionales y crean previamente un backup SQLite íntegro y privado. La
  base usa claves foráneas, WAL, `synchronous=FULL`, directorio `0700` y ficheros `0600`.
- Las migraciones v7, v8 y v9 añaden inventario tecnológico, candidatos aislados, mediciones,
  requisitos declarativos y recibos de reparación. Un candidato no puede promocionarse por ser
  más nuevo: necesita fuente y huella verificadas, rollback, matriz completa y una comparación
  equivalente que mejore al menos una métrica sin degradar ninguna común.
- La migración v10 añade expedientes de I+D reproducibles. Cada caso conserva hipótesis falsables
  ordenadas, experimentos de una sola dimensión, aislamiento, rollback, la ejecución exacta de
  Regression, ocho puertas funcionales y ocho artefactos obligatorios con SHA-256. Ni Swift ni
  SQLite permiten verificar un expediente sin un blindado perfecto y activo del mismo `run`.
- Un expediente nunca se abandona por número de intentos: queda verificado o pausado por una
  dependencia externa concreta y reanudable. Corregir después el veredicto perfecto reabre el
  caso sin borrar su historial.
- Los nombres públicos descubiertos en los `appmanifest` prevalecen sobre el marcador provisional
  `Steam App <ID>`. El arranque reconcilia el catálogo antes de leer el historial y repara
  ejecuciones antiguas sin recrearlas ni perder sus incidencias.
- La base viva está en v10 con `quick_check=ok`, 0 referencias huérfanas, 6 juegos, 25 ejecuciones,
  7 verificaciones, 2 observaciones, 3 certificaciones activas, 9 motores normalizados y
  9 tecnologías inventariadas. Aún no hay candidatos, reparaciones, optimizaciones ni expedientes
  de I+D creados: el protocolo está disponible, pero no inventa experimentos retroactivos.

El contrato completo, el esquema y las reglas de extensión están en
[`docs/compatibility-platform.md`](compatibility-platform.md).

## Catálogo público de CodeWeavers

- Se añadió un proveedor desacoplado para las páginas públicas de Compatibility Database y su
  JSON-LD. Solo enlaza coincidencias exactas por Steam App ID o título normalizado.
- La red usa sesión efímera sin cookies, HTTPS y hosts/rutas permitidos, límite de 3 MB, timeouts,
  validación de URL canónica y caché persistente con `ETag`/`Last-Modified`.
- La caché positiva dura 7 días y la negativa 30. Una reserva persistente impone 100 segundos
  entre peticiones y la sincronización es secuencial, por lo que abrir el menú no martillea el
  servicio ni bloquea Steam.
- Un fallo conserva la última ficha válida. El usuario puede desactivar la consulta desde el área
  de aprendizaje local.
- La comparación pública nunca altera el motor, instala dependencias ni concede el distintivo
  verde. El CLI expone `catalog`, `catalog-sync` y `comparisons` para auditar los datos.
- La prueba real enlazó Cube World con su ficha oficial, valoración macOS 4/5 y CrossOver 26.0.0;
  la comparación conserva por separado el blindado perfecto de Regression.

## Robustez, rendimiento y ciclo de vida

- Los manifests instalados se cachean por backend y solo se releen cada 60 segundos. Su lectura se
  ejecuta en un actor dedicado y una detección antigua no puede sobrescribir otra más reciente. El
  historial se actualiza cada 30 segundos o inmediatamente tras telemetría nueva, no en cada tick
  visual.
- Los hashes de componentes y configuraciones de juego, y la lectura de logs de error, también se
  ejecutan fuera de `MainActor`. Los logs se leen desde una cola máxima de 64 KiB, se sanean y solo
  entregan hasta 2.000 caracteres; un log grande ya no puede bloquear el popover.
- La biblioteca es buscable por título o Steam App ID y se revela en páginas de 24 filas; los
  blindados, en páginas de 8. Se conserva un único `ScrollView` y no se reintroducen los
  `LazyVStack` anidados que causaron el bloqueo anterior.
- El Steam App ID tiene una frontera canónica única: dígitos ASCII, rango `UInt32`, valor distinto
  de cero y eliminación de ceros iniciales. La recogida de ajustes rechaza traversal, separadores,
  NUL y enlaces simbólicos que salgan de las raíces del juego o usuario.
- Coordinador, detección e inspector dependen de protocolos mínimos para comprobar conflictos,
  cierre oficial, botella dañada y atribución de procesos sin ejecutar Wine en los tests. La
  consulta de actualización de CrossOver es inyectable, limita el appcast a 1 MiB y nunca afirma
  que el producto está al día si la respuesta no puede validarse.
- La consulta de ficha externa usa SQL indexado directo; perfiles, certificaciones y comparaciones
  se agrupan una sola vez por refresco. La comprobación de salud SQLite deja de ejecutarse en el
  bucle corto y pasa a una cadencia de 30 minutos o a petición.
- El icono de estado usa observación nativa en lugar de un timer de 250 ms. Los estados son iconos
  estáticos y nítidos (`ready`, `working`, `running`, `error`), sin spritesheet ni animación
  artificial.
- El monitor de logs conserva líneas parciales y detecta rotación. Los lanzamientos simultáneos
  reciben logs privados únicos y se retienen como máximo 20.
- La unificación de `steamapps` mantiene backup único, recibo privado y rollback si cualquier paso
  falla.
- El runtime estable y los experimentos modernos son estados distintos. Los perfiles perfectos
  conservan su stack exacto; Wine, GPTK/D3DMetal, DXMT, DXVK, MoltenVK, vkd3d y la futura ruta
  arm64/WoW64 se investigan como candidatos por juego. SQLite no puede almacenar ni ejecutar
  comandos arbitrarios: una futura autorreparación solo podrá invocar recetas compiladas,
  permitidas, versionadas y reversibles.
- El cierre de la app cancela tareas, reconcilia evidencias y serializa el cierre SQLite antes de
  responder a AppKit, pero no espera indefinidamente a una petición de red ya cancelada. AppKit
  usa terminación diferida únicamente durante esa secuencia acotada.
- La jerarquía del popover usa pilas deterministas dentro de su único `ScrollView`. La combinación
  anterior de `LazyVStack` anidados con `DisclosureGroup` podía dejar AttributeGraph recalculando
  geometría indefinidamente, bloquear el hilo principal y consumir un núcleo completo. El caso se
  reprodujo con una muestra de pila, se corrigió sin tocar datos ni backends y se sometió a doce
  aperturas/cierres consecutivos de Aprendizaje; después quedó estable entre 0 y 1,4 % de CPU.
- Durante la validación se detectó que macOS mostraba un `Steam.exe` desacoplado sin la ruta Wine en
  `ps`, por lo que la UI afirmaba erróneamente que Steam propio estaba cerrado. El inspector ahora
  identifica solo el cliente principal —excluye `steamwebhelper.exe`— y atribuye el backend por
  los ficheros de runtime realmente abiertos con `lsof`. No usa un wineserver stale como señal.
  La prueba instalada confirmó `Steam Regression: activo` mientras la tienda estaba abierta.

## Interfaz y limpieza

- El popover se reorganizó por intención: estado y acciones, motor/biblioteca, métricas, juegos,
  aprendizaje y diagnóstico. Los blindados locales y la referencia pública usan jerarquía y color
  distintos para evitar confundir evidencia con contexto externo.
- El icono de Regression queda centrado y con peso óptico equivalente al resto de la barra de
  menús. Cambia de forma estática según estado y conserva contraste en claro/oscuro.
- Los recursos derivados del spritesheet descartado se retiraron de Assets y se movieron de forma
  recuperable a `~/.Trash/Regression-menubar-obsolete-20260728/`. Se conservaron la fuente original
  de ImageGen, las previsualizaciones y los cuatro estados canónicos.
- “Aprendizaje local” enumera los blindados persistentes con su procedencia y huella de motor.
  “Evolución tecnológica” comunica cuántas tecnologías y candidatos existen y deja claro que la
  app todavía observa y recomienda: no descarga, repara ni sustituye motores automáticamente.
  “I+D verificable” cuenta por separado los casos y pruebas reales sometidos al expediente v10.
- La app sigue siendo `LSUIElement`: no ocupa el Dock y CrossOver solo aparece cuando una acción de
  configuración, reparación, actualización o licencia lo exige.

## Identidad, privacidad y permisos

- Se sustituyó la firma ad hoc —cuyo requisito designado dependía del hash de cada build— por una
  identidad Apple Development local y estable. El repositorio no contiene el nombre, el equipo ni
  ningún dato del certificado. `Scripts/sign_regression.sh` permite elegir otra identidad mediante
  entorno y mantiene un fallback ad hoc explícito para otras máquinas.
- La firma usa runtime endurecido y las capacidades públicas observadas en el host de CrossOver:
  automatización Apple Events, memoria ejecutable sin firma, entrada de audio y cámara. No se
  añadió App Sandbox porque Regression debe ejecutar Wine y acceder a botellas externas.
- `Info.plist` explica micrófono, cámara, Escritorio, Documentos y Descargas. macOS solo pregunta
  cuando un juego usa ese recurso; no se intenta conceder permisos en silencio ni se ejecuta
  `tccutil reset`. El usuario aceptó el diálogo mostrado durante esta validación.
- El empaquetador comprueba que todas las explicaciones y capacidades sigan presentes y que el
  requisito designado no vuelva a depender de `cdhash`. Así las decisiones de privacidad pueden
  sobrevivir a futuras compilaciones firmadas por la misma identidad.

## Empaquetado, rollback y evidencia

`Scripts/package_regression.sh` verifica el estado protegido antes y después, compila los dos
ejecutables, crea un snapshot SQLite privado, conserva un backup nativo persistente y usa una
copia APFS temporal para poder restaurar el bundle completo ante cualquier fallo. Después firma
en profundidad, verifica las capacidades y rechaza una identidad efímera cuando existe un
certificado de desarrollo válido.

Build canónico instalado: **Regression 1.5.2 (23)**.

- Backup nativo previo:
  `backups/native-packaging/regression-native-before-1.5.2-23-20260728-163709.tar.gz`,
  SHA-256 `2999e79d47a9a9f8e99c6f32f567de87ab81f87a21c078a47d606aec14116a84`.
- Backup de aprendizaje previo:
  `~/Library/Application Support/Regression/Compatibility/Backups/compatibility-before-1.5.2-23-20260728-163709-58464.sqlite`,
  SHA-256 `116e285b17e30c9c28077112475762ac7399d3849d0c21bcf60ef7bbe5de05c0`.
  El empaquetador valida ahora esta copia mediante URI `immutable` y no deja sidecars WAL.
- Aprendizaje v10 instalado, con nombres históricos reparados:
  `backups/native-audit-20260728/aprendizaje-v10-nombres-1.5.2-23.png`, SHA-256
  `1024b653441a5faf91f76c127df0c0c7de017fc98d28466246f1a20dc47c4ffb`.
- Tienda de Steam renderizada mediante el motor propio, sin lanzar juegos:
  `backups/native-audit-20260728/steam-render-1.5.2-23.png`, SHA-256
  `56be54ae13b624370b4ae4dd38f195905898c53409ee5cf6d7b43c9410e44a59`.

Evidencia visual de los builds precedentes, conservada como historial:

- Popover 1.5.1 instalado, con búsqueda y paginación:
  `backups/native-audit-20260728/popover-responsive-1.5.1-22.png`, SHA-256
  `72fd4833720cdb44805b5c3ec6ae0504654732bfcea74f8e6481ad93d53b1800`.
- Búsqueda real filtrada a Grim Dawn:
  `backups/native-audit-20260728/popover-search-1.5.1-22.png`, SHA-256
  `018bba64759bd02f556b63237b97184d648b29784fd351294491c6a8e394aeec`.
- Tienda de Steam renderizada mediante CrossOver, sin lanzar juegos:
  `backups/native-audit-20260728/steam-render-1.5.1-22.png`, SHA-256
  `02b3b04efda706e545ef6184429244d1e85b7304bc224426be2c4f845a27742f`.

- Popover activo instalado:
  `backups/native-audit-20260728/popover-active-1.5.0-21.png`, SHA-256
  `00258f9eae95d58ff14d14015e2e2e2349d2cd3f82f0f48cab4d548e299002fb9`.
- Aprendizaje, evolución tecnológica, esquema v9 y ejecuciones visibles en la app instalada:
  `backups/native-audit-20260728/aprendizaje-runtime-1.5.0-21.png`, SHA-256
  `4483249bb5c9136e144f1f13651eef403508aef481390533805df79f635b5bd0`.
- La captura histórica de tienda del motor propio 1.4.0 (16) se conserva como evidencia del
  runtime, que esta pasada no modificó.

La app permanece sin App Sandbox deliberadamente porque debe ejecutar Wine/CrossOver y acceder a
botellas externas. La mitigación es alcance local, permisos privados, saneado de telemetría,
ausencia de secretos y ausencia de envío propio a servidores.

## Gates ejecutados

- Swift 6.3.3 / Xcode 26.6 (17F113).
- `swift test`: 70 casos, 69 ejecutados, 1 diagnóstico local optativo omitido, 0 fallos.
- `swift test --sanitize=thread`: 70 casos, 0 carreras detectadas y 0 fallos.
- Cobertura LLVM agregada: 88,82 % de líneas, 85,44 % de funciones y 78,98 % de regiones.
- `swift build -Xswiftc -warnings-as-errors`: correcto.
- `swift build -c release`: correcto.
- `bash -n Scripts/*.sh build/*.sh`: correcto.
- `npx @google/design.md lint DESIGN.md`: 0 errores y 0 avisos.
- `git diff --check`: correcto.
- `codesign --verify --deep --strict Regression.app`: correcto.
- Estado protegido de app y botella: correcto antes y después del empaquetado.
- Rutas heredadas v6/v7→v8, v8→v9 y v9→v10 ensayadas sobre copias, además de la migración
  integral cubierta por tests: integridad, referencias, ejecuciones y certificaciones
  conservadas. La base viva quedó en v10 y su backup anterior coincide byte a byte con el creado
  por la migración.
- Consulta pública real: ficha de Cube World enlazada; fuente externa separada del veredicto local.
- Inspección visual instalada: popover correcto, motor propio activo, esquema v10, bloque de I+D
  verificable y nombres `DragonSword : Awakening` y `Dragon's Dogma 2` visibles en el historial.
  La tienda de Steam renderizó a 3024×1740. No se lanzó ningún juego.
- Estrés instalado del área Aprendizaje: doce transiciones, árbol de accesibilidad operativo,
  86 elementos accesibles con Juegos temporalmente colapsado y restaurado al final, y CPU de la
  app en reposo (0,4 % en la comprobación posterior). El gate localiza la sección aunque
  una biblioteca grande deje controles fuera del viewport. `tools/diagnostics/stress-native-popover.sh`
  conserva esta prueba; el cursor multicolor y el 99,7 % sostenido dejaron de reproducirse.
- Cierre de la primera tanda mediante `Steam -shutdown` y terminación limpia de Regression, sin
  procesos Wine huérfanos; relanzamiento final correcto para validar el nuevo detector. Una prueba
  posterior reprodujo y corrigió la espera ilimitada del catálogo: la instancia final respondió a
  `NSRunningApplication.terminate()` y salió limpiamente en menos de un segundo.

## Trabajo deliberadamente diferido

- No se repitió gameplay: ningún cambio de esta pasada afecta runtime o perfiles, y el usuario
  pidió consolidar la base antes de seguir probando juegos.
- La aplicación automática de configuraciones aprendidas permanece desactivada. Requerirá una
  instrucción específica, perfil experimental aislado, rollback y matriz de validación.
- La distribución notarizada con Developer ID queda fuera del proyecto personal actual. El bundle
  local usa una firma Apple Development estable; en una máquina sin certificado el script avisa
  antes de recurrir a firma ad hoc.
