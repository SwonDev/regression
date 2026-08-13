# Checkpoint — Regression AAA/autonomía

Fecha: 2026-08-13 20:51 WEST
Worktree: `/Users/adrianpereradelgado/Documents/Vibeclaude/Regression-aaa-autonomy`
Rama: `codex/regression-aaa-autonomy`
Base: `e47f48796ff0b428b15c2c2e6e4fa4c3512077c8` (`v1.10.1`)
Estado: cierre final 1.11.0 preparado para publicación; código, UI, artefacto, instalación y
matriz funcional instalada validados sobre el mismo corte.

> Este documento conserva el checkpoint de la pausa y añade al final el estado de cierre. Ante
> cualquier diferencia, manda la sección «Cierre final 20:51».

## Estado seguro al pausar

- La instalación canónica sigue siendo `/Applications/Regression.app` `1.10.1 (36)`.
- Regression, Steam nativo, Steam Wine, wineserver, bundles QA, SwiftPM y packaging están cerrados.
- La única `steamapps` física está dentro de la botella Regression:
  - tipo: directorio físico;
  - inode: `28262319`;
  - device: `16777234`;
  - la antigua ruta CrossOver `steamapps` está ausente.
- `git diff --check` pasa.
- Hay 48 entradas modificadas/nuevas deliberadas en el worktree. No limpiar, resetear ni mezclar con el checkout antiguo `Regression`.
- No se instaló, etiquetó, publicó ni subió ninguna release nueva en este corte.

## Cortes completados y congelados

1. Custodia física independiente y fresh install:
   - una única biblioteca física dentro de Regression;
   - migración por rename sin copiar aproximadamente 110 GB;
   - WAL, interlocks, recuperación, rollback y fresh install sin fuente CrossOver;
   - el error del Mac limpio «la ruta heredada no contiene steamapps» queda cubierto.

2. Instalador fresh-host:
   - promoción canónica antes de ejecutar el Wine con prefix absoluto;
   - staging de botella y rollback íntegro fresh/upgrade;
   - preservación de la única `steamapps` sin duplicarla.

3. Salud y autorreparación:
   - VC++/UCRT sellados;
   - Windows Media y requisitos runtime visibles;
   - escáner read-only de tecnologías por App ID;
   - lifecycle durable de reparaciones, detección fail-closed y cuarentena legacy.

4. Wine/FOSS:
   - serie estricta sobre el tar oficial CrossOver FOSS 26.3.0;
   - SHA oficial `ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872`;
   - aplicación idempotente sin fuzz y compilación real de `ntdll.so` x86_64.

5. UI AAA:
   - un único `ScrollView`, sin `LazyVStack`;
   - estados críticos promovidos arriba, recovery accionable y controles críticos >= 32 pt;
   - licencia legible en oscuro/alto contraste y layouts accesibles;
   - revisión visual Round 4: PASS con P0=0/P1=0 para el freeze anterior a la integración UI de consentimiento GPTK 3.0.

6. GPTK multigeneración:
   - perfiles históricos Grim Dawn/DragonSword/DD2 tipados como GPTK 3.0;
   - Titan Quest II/Borderlands 4 tipados como GPTK 4.0b2;
   - loader fail-closed por proceso, sin fallback silencioso;
   - autoridad 3.0 exige flag emitida únicamente por `--component 3.0 --verify-only`.

7. Consentimiento GPTK 3.0 existente — corte final de esta pausa:
   - health con un único root FD anclado, inodes/ctime y revalidación de padres, archivos y seis aliases;
   - tests adversariales de sustitución de raíz, subárbol y ABA A→B→A;
   - `--inspect-existing` y `--authorize-existing` sin DMG, sin copiar ni instalar payload;
   - token privado de un solo uso, <=10 minutos, recibo específico sin `dmg_sha256`;
   - `--verify-only --component 3.0` exige bytes, topología y recibo exactos;
   - eliminado el bypass productivo `existing-consent-gate`: ninguna variable de entorno puede saltarse la verificación ni acuñar recibos;
   - re-review independiente final: PASS, P0=0/P1=0/P2=0;
   - evidencia: 22/22 Swift focales, dos suites shell, Release con warnings-as-errors, `bash -n`, ShellCheck y diff-check verdes.

## Evidencia global conocida

- Suite Swift completa más reciente antes del último corte GPTK: 262 ejecutadas, 1 omitida diagnóstica, 0 fallos.
- El último corte GPTK posterior pasó sus 22/22 focales y build Release; la suite completa global debe repetirse al reanudar.
- La auditoría visual Round 4 pasó antes de integrar la futura UI específica del consentimiento 3.0; esa UI requiere Round 5.
- No se abrió Regression canónica, Steam nativo, Steam Wine ni juegos durante el cierre.

## Bloqueos de release detectados — no publicar hasta cerrarlos

1. Unificar `1.11.0 (37)` en `package_regression`, `package_release`, instalador, catálogo de salud, fixtures y gate público, preservando modos históricos.
2. Dar al instalador la misma autoridad externa de VC++/UCRT/Windows Media que usa `verify-release-asset`; no aceptar solo un manifiesto autocontenido.
3. Hacer que `package_release.sh` emita y valide el `install_regression.sh` exacto de la misma versión/build.
4. Preservar GPTK únicamente si generación, hashes, topología y recibo son autorizados; no copiar cualquier D3DMetal por mera existencia.
5. Rechazar también symlinks relativos que escapen del bundle, tanto en verificador como en instalador.
6. Fijar autoridad independiente para el digest descargado, retirar CrossOver de `NSAppleEventsUsageDescription` e incluir el instalador GPTK en los backups nativos.

## Punto exacto de reanudación

1. No tocar más el Core/script GPTK 3.0 salvo un hallazgo nuevo reproducible: ese corte está congelado y revisado.
2. Integrar `--inspect-existing`/`--authorize-existing` en `RegressionAppModel` y en la hoja nativa:
   - título, versión, confirmación y fuente dinámicos para 3.0;
   - sin selector DMG para 3.0;
   - 4.0b2 permanece sin cambios;
   - añadir fixtures `gptk3-*`.
3. Reabrir al crítico visual severo para Round 5: normal claro/oscuro, alto contraste, Accessibility 5, hoja completa, targets y VoiceOver.
4. Corregir los seis bloqueos de release anteriores y pedir re-review independiente.
5. Congelar el árbol y ejecutar:
   - suite Swift completa warnings-as-errors;
   - Release warnings-as-errors;
   - todas las suites shell + ShellCheck;
   - gate completo de Wine contra el tar oficial;
   - `git diff --check` y revisión final del diff.
6. Solo entonces promover a `1.11.0 (37)`, reconstruir inputs/runtime, generar el asset exacto y verificarlo externamente.
7. Instalar ese mismo asset en `/Applications` sin `--launch`, verificar GPTK y el inode único de `steamapps`.
8. Ejecutar la matriz funcional únicamente con Steam de Windows bajo Regression —jamás `/Applications/Steam.app`— y con captura real.
9. Si todo pasa: commit, push, tag y release GitHub con los tres assets exactos; volver a descargar y comparar hashes antes de publicar como latest.

## Comandos iniciales al retomar

```bash
cd /Users/adrianpereradelgado/Documents/Vibeclaude/Regression-aaa-autonomy
git status --short
git diff --check
swift test -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
```

No usar el checkout antiguo `/Users/adrianpereradelgado/Documents/Vibeclaude/Regression` para implementar ni empaquetar.

## Reanudación final 18:20

- Todos los cortes enumerados arriba se integraron y pasaron revisión independiente.
- Round 5C y Round 6 visual: PASS, P0=0/P1=0/P2=0; UI accesible y sin presencia operativa o
  visual de CrossOver/CodeWeavers.
- Suite final: 304 pruebas, 1 diagnóstico omitido, 0 fallos; Debug y Release con
  warnings-as-errors; suites shell y serie Wine estricta verdes.
- Se corrigió la comparación temporal de verificaciones para usar la precisión ISO-8601 durable
  de SQLite; conserva el rechazo de verificaciones realmente anteriores.
- `/Applications/Regression.app` es 1.11.0 (37), firma válida y estado público protegido PASS.
- La única `steamapps` sigue siendo el directorio físico inode `28262319`, device `16777234`,
  dentro de Regression; la ruta heredada CrossOver sigue ausente.
- Validación funcional instalada: Steam de Windows mostró tienda y biblioteca autenticadas;
  Moonlighter 2 renderizó correctamente a 3024×1964. Palworld no está instalado y su preflight
  bloqueó correctamente; no se descargó ni se afirmó una validación inexistente.
- Regression, Steam de Windows, juegos y wineserver quedaron cerrados. La aplicación nativa
  `/Applications/Steam.app` no se abrió ni se utilizó.
- El primer tar `ffb38df2…` quedó invalidado porque precedía al último cambio fuente y se movió,
  junto a sidecar/installer/autoridad, a
  `build/release-1.11.0/invalidated-post-asset-source-change/`.
- Punto exacto actual: regenerar el tar.gz desde el árbol congelado, repetir verificadores,
  reinstalar ese hash exacto, confirmar canónica/biblioteca, commit, push a `master`, tag
  `v1.11.0`, crear release latest y volver a descargar los tres assets para comparar hashes.

## Cierre final 20:51

- El defecto de migración v13→v14 con experimentos I+D ya aprobados quedó reproducido y
  corregido transaccionalmente: los 17 triggers se retiran dentro de `BEGIN IMMEDIATE`, se
  reconstruye el subgrafo y se recrean antes del `COMMIT`; un fallo conserva filas, versión,
  triggers y ausencia de tablas temporales. Revisión severa: PASS, P0=0/P1=0/P2=0.
- Artefacto final instalado y revisado:
  `build/release-1.11.0/Regression-1.11.0-macos-arm64.tar.gz`, SHA-256
  `47740fbf27e6e792e2f6c5bf0b08a8ca7344f0bd1241adb0ad0e72569c3baa7e`.
- Instalador exacto: `build/release-1.11.0/install_regression.sh`, SHA-256
  `bba8a3225d5f79d2fb5d4d620f54043d1c9a00b10536cce43f846cec1aa3e40b`.
- `/Applications/Regression.app` está en 1.11.0 (37), firma profunda válida; base SQLite v14
  íntegra; `regressionctl` instalado SHA-256
  `1e03b01193db62bebcff35d31a1af85085eac1780d121fedd14c72318597fca9`; engine SHA-256
  `0aa2c39d5476d8b5767d9a1979af5ecaf96f36648cbe15d376a761aad06e7ca4`.
- La única `steamapps` sigue física dentro de Regression con inode `28262319` y device
  `16777234`; la ruta CrossOver permanece ausente.
- La aparente tienda negra no era una regresión: Steam marca el webview `WasHidden 1` al lanzar
  el juego. La puerta correcta confirmó `WasHidden 0` y Tienda renderizada antes del juego
  (`/private/tmp/regression-1.11-final-steam-visible.png`); Moonlighter 2 renderizó a 3024×1964
  (`/private/tmp/regression-1.11-final-moonlighter2-confirmed.png`); después del cierre, el control
  oculto fue negro y, tras volver realmente a Biblioteca/Tienda, un nuevo `WasHidden 0` produjo
  Tienda renderizada (`/private/tmp/regression-1.11-final-steam-postgame-reactivated.png`). No se
  modificaron runtime, DLL, caché, botella ni `steamapps`, y esta pasada no acuñó un nuevo
  veredicto perfecto.
- Steam de Windows, Moonlighter, Wine y wineserver quedaron cerrados; nunca se abrió Steam
  nativo. Los gates finales pasaron: 304 pruebas Swift con 1 diagnóstico omitido y 0 fallos,
  Release warnings-as-errors, suites shell, transición pública, serie Wine reproducible,
  ShellCheck crítico, `git diff --check` y verificación clean-PATH del asset. Falta únicamente
  commit/push/tag/release y descargar de GitHub los tres assets publicados para comparar hashes.
