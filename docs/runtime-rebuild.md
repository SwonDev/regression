# Recompilar el runtime sin romper la instalación

Este documento existe porque el 19 de agosto de 2026 se recompiló el runtime desde el árbol de
trabajo `sources-26.3.0/wine` sin comprobar que reprodujera la release publicada. Ese árbol había
quedado en un estado **anterior** a la migración que retiró el contrato GPTK heredado, de modo que
el `ntdll.so` resultante reintrodujo una ruta de entorno que 1.12.3 ya había eliminado. El
diagnóstico posterior culpó a la migración —"retirarla rompe Cursemark"— cuando la causa real era
el árbol. Compilar desde el tar oficial dejó el mismo binario sin contrato heredado y con el juego
funcionando.

## Regla

**El runtime se compila desde el tar FOSS oficial más la serie de parches versionada, nunca desde
el árbol de trabajo tal como esté.** El árbol de trabajo es un artefacto reproducible, no una
fuente de verdad: si alguien lo editó a mano, lo que compiles no será lo que se publicó.

```bash
CLEAN=/private/tmp/regression-wine-clean
rm -rf "$CLEAN" && mkdir -p "$CLEAN"
tar -xzf crossover-sources-26.3.0.tar.gz -C "$CLEAN" sources/wine
REGRESSION_WINE_SOURCE="$CLEAN/sources/wine" bash build/apply-wine-patches.sh
```

El aplicador debe recorrer la serie entera sin un solo rechazo. Un parche que no aplica sobre el
tar oficial está mal generado: se regenera contra el árbol canónico, no se fuerza el contexto.

Comprobaciones que delatan un árbol equivocado antes de gastar una compilación:

```bash
# El contrato de entorno heredado debe estar retirado.
grep -c 'REGRESSION_EXTERNAL_D3DMETAL_\(EXECUTABLE\|WINE_ROOT\)' \
    "$CLEAN/sources/wine/dlls/ntdll/unix/loader.c"   # 0
```

## Qué se puede sustituir en el runtime instalado y qué no

No todo el runtime admite el mismo trato. El asset público pasa por `strip -S`, `install_name_tool`
y borrado de rutas locales, así que sus binarios ya no son los que salen del compilador.

| Pieza | ¿Sustituible con un binario recién compilado? |
|---|---|
| `lib/wine/x86_64-unix/*.so` (ntdll, opengl32, winemac…) | Sí, firmando cada uno **ad hoc** |
| `bin/wine`, `bin/wineserver`, `lib/wine/x86_64-unix/wine` | **No**: rompen el arranque contra el resto del runtime publicado |

Sustituir los tres binarios de arranque por versiones crudas dejó el juego colgado en
`sdl.Sdl.init` con `Program timeout`, aunque cada uno funcionara por separado. Si hay que
cambiarlos, se regenera y publica el runtime público completo, no se mezclan generaciones.

Cada `.so` sustituido necesita su firma ad hoc, igual que la traía la release:

```bash
codesign -f -s - "$WINE_ROOT/lib/wine/x86_64-unix/ntdll.so"
bash Scripts/sign_regression.sh /Applications/Regression.app
```

Sin ella, `verify-protected-state.sh` corta con `code object is not signed at all`.

## Después de tocar el runtime

```bash
bash build/refresh-release-pins.sh --builder "$PWD/build/wine64-canonical"
bash build/refresh-release-pins.sh --check    # debe quedar limpio
swift build -c release                        # ComponentHealth lleva los PIN compilados
```

`refresh-release-pins.sh` propaga los digests a ComponentHealth, su test y los verificadores, y
escribe `build/release-runtime-pins.txt`. Esa evidencia sustituye al árbol de compilación: el
verificador acredita contra ella cuando el builder ya no existe, que es lo que antes dejaba
bloqueada cualquier release.

El script solo acredita un binario del builder si sus bytes coinciden con los del runtime
instalado. Cuando avisa de que *no corresponde*, no es un fallo suyo: está diciendo que ese binario
del bundle procede de otra compilación y no debe declararse como generado por este builder.

## La versión se sube al publicar, nunca antes

Subir `CFBundleShortVersionString` antes de que exista la release deja la app sin salida: el canal
estable ofrece una versión anterior, la reparación se bloquea para evitar un downgrade y
`ComponentHealth` resuelve `unsupportedVariant` en cuanto el build identificador deja de coincidir,
vaciando el conjunto sellado y reportando «Runtime incompleto: no permite verificar VC++ y UCRT».

`supportedApplicationVersion` y `supportedBuildIdentifier` van **siempre juntos**: cambiar uno solo
produce exactamente ese estado.

Un runtime corregido puede convivir con la versión publicada sin tocar el contrato: basta actualizar
su digest en el conjunto sellado. Es lo que permite validar un cambio en la instalación real antes
de comprometer una versión nueva.
