# Preparación reproducible de pruebas

Regression ejecuta una comprobación previa antes de solicitar a Steam el lanzamiento de un
juego. Su finalidad es evitar que un wineserver ajeno, un servicio huérfano, una biblioteca
incompleta o una base dañada se confundan con un fallo del motor o del título.

La comprobación es deliberadamente conservadora:

- **observa, pero no repara**;
- no termina procesos ni elimina archivos;
- no cambia el registro, la botella, el runtime ni un perfil blindado;
- no guarda PID, comandos completos, rutas personales ni datos de cuenta;
- un aviso se conserva como contexto, pero un bloqueo inequívoco impide lanzar el juego.

## Contrato

El protocolo v2 revisa diez dimensiones y conserva también la procedencia temporal de la captura:

| Dimensión | Qué demuestra | Bloquea cuando… |
|---|---|---|
| Base de aprendizaje | `quick_check`, claves foráneas y esquema esperado | SQLite no es íntegra o la migración no terminó |
| Motor seleccionado | botella, Steam y launcher detectables | falta o está dañado el backend requerido |
| Aislamiento de Steam | un único backend escritor | CrossOver y Regression coexisten o está activo el backend equivocado |
| Juego objetivo | manifest, App ID y carpeta contenida en `steamapps/common` | la instalación falta, no coincide o intenta escapar de la biblioteca |
| Aislamiento de Wine | procedencia del ejecutable real de cada wineserver | hay un wineserver inequívocamente ajeno |
| Ciclo de servicios | relación entre `services.exe` y wineserver | queda un `services.exe` con PPID 1 sin wineserver vivo |
| Presentación DXMT | marcadores `dxmt-cxpresent-*.id` | no bloquea: el launcher canónico los reinicia; un resto cerrado queda como aviso |
| Almacenamiento | espacio para cachés, logs y actualizaciones | queda menos de 1 GB; por debajo de 5 GB se avisa |
| Telemetría | lectura de los logs locales de Steam | la ruta existe pero no puede leerse, o su raíz no está disponible |
| Biblioteca compartida | mismos bytes para la comparación A/B | no bloquea por sí sola; una divergencia queda explícita como aviso |

El lector de manifests resuelve el enlace simbólico canónico de `steamapps` antes de enumerar la
biblioteca. De ese modo el backend Regression valida las instalaciones físicas de CrossOver sin
duplicarlas y sin tratar el symlink como un archivo ordinario.

Los procesos se clasifican con la columna **`comm` de `ps`**, que contiene solo el ejecutable real
y conserva rutas con espacios. No se busca la palabra `wineserver` en los argumentos. Así un
comando de terminal, un log o un helper no se convierte en un falso wineserver y una aplicación
con nombre compuesto tampoco queda invisible. Esta regla complementa —no sustituye— la atribución de
`Steam.exe`: el backend del cliente desacoplado sigue resolviéndose con sus ficheros abiertos
mediante `lsof`, tal como exige `AGENTS.md`.

## Persistencia y esquema v12

Una comprobación general desde el popover solo actualiza el estado visible. Cuando el usuario
lanza un juego desde el botón de Regression y el resultado es `ready` o `warning`:

1. se crea la ejecución con estado `preparing`;
2. se inserta en `run_preflight_reports` la instantánea exacta;
3. SQLite verifica App ID, backend, contadores y JSON;
4. el JSON se firma lógicamente con SHA-256 y se vuelve a comprobar al leerlo;
5. solo entonces se envía `-applaunch` a Steam.

Ese contrato se guarda como `capturePhase=preLaunch` y SQLite lo rechaza si el proceso ya llegó a
iniciarse. El cliente completo de Steam sigue siendo la interfaz principal y también permite
pulsar «Jugar» directamente. Valve no ofrece a Regression un callback previo para ese gesto: al
detectar el primer proceso en `gameprocess_log.txt`, la app ejecuta inmediatamente la misma matriz
y persiste `capturePhase=processStartBoundary` junto a la latencia de observación. Se admite sobre
un run que ya tenga PID, pero no se etiqueta ni se comunica como preparación previa exacta.

Steam puede encadenar un launcher y el binario principal para un solo App ID. El esquema v12
conserva cada uno en `run_processes`, actualiza cuál representa la sesión y espera a que terminen
todos antes de cerrar el run. Los eventos siguen auditables y exportables, pero una pulsación del
usuario produce una única prueba y una única posible verificación.

Si la instantánea no puede persistirse, la intención de telemetría se cierra como fallo previo y
el juego no se solicita. Las exportaciones incluyen `preflightSnapshots` por separado de los
veredictos: un entorno limpio nunca equivale a render, entrada, opciones o gameplay correctos.

La migración de una base anterior crea primero el backup privado y transaccional ya definido por
`CompatibilityRepository`. Los datos permanecen en:

```text
~/Library/Application Support/Regression/Compatibility/compatibility.sqlite
```

con directorios `0700` y archivos `0600`.

## Uso

La app muestra el último estado general en **Mantenimiento → Preparación para pruebas**. La
comprobación también puede ejecutarse sin lanzar nada:

```bash
Regression.app/Contents/SharedSupport/bin/regressionctl preflight
Regression.app/Contents/SharedSupport/bin/regressionctl preflight 219990 --backend regression
```

`regressionctl launch` usa el mismo preflight. Si necesita cambiar de backend, primero solicita
el cierre normal del Steam activo; no inicia un segundo cliente intermedio.

## Relación con CrossOver y Apple

El preflight sigue el principio de botellas separadas de CrossOver y usa únicamente su CLI
oficial cuando ese backend está seleccionado. La documentación de CodeWeavers permite activar
canales de log y variables por lanzamiento, pero Regression no aprende comandos arbitrarios ni
convierte un log en una receta.

Apple recomienda un flujo de diagnóstico que separa descubrimiento, preparación, ejecución,
validación y entrega de evidencia. Game Porting Toolkit 4 añade `gpucapture` y `gpudebug`, pero
esas herramientas requieren macOS 27, Xcode 27 y GPTK 4. En el entorno estable actual permanecen
como candidatos futuros de I+D; no sustituyen D3DMetal ni ningún PIN validado.

Referencias oficiales:

- [Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/)
- [Repositorio oficial de Apple Game Porting Toolkit](https://github.com/apple/game-porting-toolkit/)
- [Steamworks API: inicialización y relanzamiento por App ID](https://partner.steamgames.com/doc/sdk/api?l=latam)
- [Steamworks: opciones de lanzamiento y ejecutables](https://partner.steamgames.com/doc/features/steamvr/settings?language=english)
- [CrossOver Mac User Guide](https://www.codeweavers.com/support/docs/crossover-mac/index)
- [OSLog](https://developer.apple.com/documentation/OSLog)

## Lo que aún exige una persona

Un preflight verde solo confirma que la prueba está limpia. El cierre sigue exigiendo:

- captura e inspección visual;
- clicks precisos en centro y extremos;
- cambio y persistencia de opciones;
- gameplay real;
- veredicto manual sobre la ejecución exacta;
- fila verde `Verificado perfecto: Regression`.
