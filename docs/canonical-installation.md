# Instalación canónica de Regression

## Contrato

En un Mac terminado solo existe una aplicación Regression descubrible:

```text
/Applications/Regression.app
```

Debe ser un bundle físico, firmado y con identificador `local.regression.launcher`. No puede ser
un symlink al checkout. El runtime público contiene rutas horneadas hacia esta ubicación, por lo
que una copia abierta desde otra carpeta no es equivalente a la instalación estable.

`Regression.app/` en la raíz del repositorio es un artefacto de compilación ignorado por Git. Es
válido mientras se construye o prueba, pero el empaquetador lo desregistra de LaunchServices y no
debe permanecer en una ruta indexada al terminar. Lo mismo se aplica a candidatos, instalaciones
de prueba y builds rechazadas aunque se hayan renombrado como `Regression-1.9.0-installed.app` o
`Regression.full-rebuild-rejected.app`.

## Rollback sin contaminar Finder

No se borran builds históricos necesarios para reproducir o revertir. Se trasladan conservando su
ruta relativa a un árbol cuyo nombre termina en `.noindex`, por ejemplo:

```text
~/Library/Application Support/Regression/Backups/NonCanonicalApps.noindex/
```

El instalador guarda las versiones sustituidas en `Backups/App.noindex`. Así siguen siendo
recuperables, pero Spotlight no las presenta como aplicaciones instaladas. Antes de mover un
bundle se desregistra su ruta concreta con `lsregister -u`; nunca se reinicia globalmente la base
de LaunchServices.

## Puerta de entrega

Ejecuta al final de una instalación, autoactualización o sesión que haya generado bundles:

```bash
bash build/verify-canonical-installation.sh
```

La comprobación falla si ocurre cualquiera de estos casos:

- falta `/Applications/Regression.app`, es un symlink o su firma profunda es inválida;
- Spotlight clasifica otra coincidencia de Regression como aplicación;
- LaunchServices conserva otra ruta cuyo bundle se llama `Regression*.app`;
- existe otra Regression directamente en `/Applications` o `~/Applications`.

La evidencia esperada incluye la versión y el build canónicos. Además se abre la app por ruta,
se confirma que el proceso ejecutado pertenece a `/Applications/Regression.app` y se revisa
visualmente que Steam renderiza. Que un proceso exista o que el código compile no sustituye esta
puerta.

## Incidente de referencia de 2026-08-10

Finder mostraba múltiples versiones porque los backups conservaban extensión `.app` en carpetas
indexables y el empaquetador registraba el bundle de desarrollo. Se archivaron dieciséis bundles
no canónicos bajo `NonCanonicalApps.noindex`, se desregistraron sus rutas y se conservó únicamente
Regression 1.10.0 (35) en `/Applications`.

Durante la auditoría también se detectó que un reparador histórico de Switch2Bridge no reconocía
el shim SDL portable (`@loader_path/libSDL2-real.dylib`) y lo reescribía después de firmar la app.
La detección acepta ahora tanto la variante portable como la histórica; el shim se restauró desde
el asset 1.10.0 verificado y la aplicación volvió a firmarse antes de superar esta puerta.
