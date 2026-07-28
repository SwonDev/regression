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

## Plataforma de aprendizaje v6

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
- La base viva migró a v6 con `quick_check=ok`, 0 referencias huérfanas, 5 juegos, 19 ejecuciones,
  5 verificaciones, 2 observaciones, 3 certificaciones activas y 7 motores normalizados. Una marca
  heredada de No Rest for the Wicked sin proceso real quedó invalidada y no genera blindado.

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

- Los manifests instalados se cachean por backend y solo se releen cada 60 segundos. El historial
  se actualiza cada 30 segundos o inmediatamente tras telemetría nueva, no en cada tick visual.
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
- El cierre de la app cancela tareas, reconcilia evidencias y serializa el cierre SQLite antes de
  responder a AppKit, pero no espera indefinidamente a una petición de red ya cancelada. AppKit
  usa terminación diferida únicamente durante esa secuencia acotada.
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
- La app sigue siendo `LSUIElement`: no ocupa el Dock y CrossOver solo aparece cuando una acción de
  configuración, reparación, actualización o licencia lo exige.

## Empaquetado, rollback y evidencia

`Scripts/package_regression.sh` verifica el estado protegido antes y después, compila los dos
ejecutables, crea un snapshot SQLite privado, conserva un backup nativo persistente y usa una
copia APFS temporal para poder restaurar el bundle completo ante cualquier fallo. Después firma
en profundidad y valida la firma.

Build canónico instalado: **Regression 1.4.0 (16)**.

- Backup nativo previo:
  `backups/native-packaging/regression-native-before-1.4.0-16-20260728-091139.tar.gz`.
- Backup de aprendizaje previo:
  `~/Library/Application Support/Regression/Compatibility/Backups/compatibility-before-1.4.0-16-20260728-091139-45922.sqlite`.
- Popover activo instalado:
  `backups/native-audit-20260728/popover-active-1.4.0-16.png`, SHA-256
  `e783cba086b93bbf4e7feb34f0436888261f0cc71a55f56873e064e8a0b44704`.
- Tienda Steam del motor propio a 3024×1740:
  `backups/native-audit-20260728/steam-store-1.4.0-16.png`, SHA-256
  `83d8b3261b9089db1fcef6e5a42ca1dedac259627d1caf4fdaa528753ccc5a2a`.

La app permanece sin App Sandbox deliberadamente porque debe ejecutar Wine/CrossOver y acceder a
botellas externas. La mitigación es alcance local, permisos privados, saneado de telemetría,
ausencia de secretos y ausencia de envío propio a servidores.

## Gates ejecutados

- Swift 6.3.3 / Xcode 26.6 (17F113).
- `swift test`: 37 casos, 36 ejecutados, 1 diagnóstico local omitido, 0 fallos.
- `swift build -Xswiftc -warnings-as-errors`: correcto.
- `swift build -c release`: correcto.
- `bash -n Scripts/*.sh build/*.sh`: correcto.
- `npx @google/design.md lint DESIGN.md`: 0 errores y 0 avisos.
- `git diff --check`: correcto.
- `codesign --verify --deep --strict Regression.app`: correcto.
- Estado protegido de app y botella: correcto antes y después del empaquetado.
- Migración v6 ensayada sobre copia y ejecutada en la base viva: integridad correcta.
- Consulta pública real: ficha de Cube World enlazada; fuente externa separada del veredicto local.
- Inspección visual instalada: popover activo correcto y tienda Steam completa, sin negro,
  desbordes ni corrupción. No se lanzó ningún juego.
- Cierre de la primera tanda mediante `Steam -shutdown` y terminación limpia de Regression, sin
  procesos Wine huérfanos; relanzamiento final correcto para validar el nuevo detector. Una prueba
  posterior reprodujo y corrigió la espera ilimitada del catálogo: la instancia final respondió a
  `NSRunningApplication.terminate()` y salió limpiamente en menos de un segundo.

## Trabajo deliberadamente diferido

- No se repitió gameplay: ningún cambio de esta pasada afecta runtime o perfiles, y el usuario
  pidió consolidar la base antes de seguir probando juegos.
- La aplicación automática de configuraciones aprendidas permanece desactivada. Requerirá una
  instrucción específica, perfil experimental aislado, rollback y matriz de validación.
- La notarización con Developer ID queda fuera del proyecto personal actual; el bundle usa firma
  ad hoc válida localmente.
