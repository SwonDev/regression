# Evolución de runtimes, rendimiento y autonomía

Fecha de revisión del inventario: **28 de julio de 2026**. Este documento define cómo Regression
puede adoptar tecnologías nuevas sin degradar un juego que ya funciona ni convertir CrossOver en
una dependencia del motor propio.

## Dos afirmaciones distintas

Regression separa deliberadamente:

1. **Compatibilidad funcional perfecta**: una ejecución exacta superó render, precisión de
   entrada, cambios gráficos persistentes y gameplay. Esta confirmación crea un blindado local
   persistente ligado a su configuración y huella de motor.
2. **Mejor opción conocida**: además de funcionar, un candidato aislado demuestra mediante
   mediciones que mejora rendimiento, frame pacing, resolución o calidad sin regresiones.

Un blindado no caduca porque aparezca una versión nueva. Tampoco afirma que su motor sea para
siempre el más rápido: mantiene un baseline reproducible mientras I+D compara alternativas.

## Inventario técnico revisado

El catálogo `RuntimeTechnologyCatalog` se sincroniza con SQLite en cada apertura. Es un snapshot
documental, no un actualizador, y nunca descarga ni activa componentes.

| Tecnología | Baseline protegido | Versión/línea observada | Política |
|---|---:|---:|---|
| Rosetta | Gestionada por macOS | Gestionada por macOS | Sistema; planificar salida de x86_64. |
| Wine | 11.0, linaje CX 26.3.0 y prefijo propio | 11.0 estable | Otros builds solo como candidatos por juego. |
| Apple GPTK / D3DMetal | 3.0 local | GPTK 4 | Binarios aportados por el usuario; nunca redistribuidos. |
| DXMT | 0.72 + parche cross-process | 0.80 | El PIN global no cambia sin Steam y Palworld. |
| DXVK | 1.10.3 para D3D9 | 3.0.2 | Comparar junto al runtime Vulkan exacto. |
| MoltenVK | 1.2.10 | 1.4.2 | Candidato conjunto, no reemplazo global aislado. |
| Wine vkd3d | 1.18 | 1.18 revisado | Baseline D3D12; conflicto `dxgi` aún protegido. |
| vkd3d-proton | Sin baseline | 3.0.1 | Línea separada de investigación, no actualización directa. |
| CrossOver | 26.3.0 observado | Gestionado por CrossOver | Referencia licenciada, nunca runtime propio. |

Fuentes oficiales del snapshot:

- [Apple Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/) — GPTK 4,
  Metal 4 y herramientas actuales de evaluación, captura y rendimiento.
- [Rosetta](https://developer.apple.com/documentation/Apple-Silicon/about-the-rosetta-translation-environment)
  y [notas de macOS 26.4](https://developer.apple.com/documentation/macos-release-notes/macos-26_4-release-notes)
  — Rosetta general continúa hasta macOS 27; después queda un subconjunto para juegos antiguos.
- [Wine 11.0](https://www.winehq.org/news/2026011301).
- [DXMT 0.80](https://github.com/3Shain/dxmt/releases/tag/v0.80),
  [DXVK 3.0.2](https://github.com/doitsujin/dxvk/releases/tag/v3.0.2),
  [MoltenVK 1.4.2](https://github.com/KhronosGroup/MoltenVK/releases/tag/v1.4.2) y
  [vkd3d-proton 3.0.1](https://github.com/HansKristian-Work/vkd3d-proton/releases/tag/v3.0.1).

Las versiones se actualizan únicamente después de contrastar la fuente oficial y registrar la
fecha. “Hay una versión nueva” significa **candidato de investigación**, no “actualizar estable”.

## Esquema v12

La base local conserva las cinco áreas de evolución tecnológica de v9:

| Tabla | Guarda | No puede hacer |
|---|---|---|
| `runtime_technologies` | Fuente oficial, licencia/distribución, baseline, última versión revisada y política. | Descargar o cambiar un runtime. |
| `runtime_candidates` | Versión candidata, ámbito, huellas, aislamiento, rollback y estado de la matriz. | Promover un candidato global o sin evidencia. |
| `optimization_assessments` | Resolución, preset, FPS, 1 % low, frame time p95 y conclusión. | Convertir un cierre limpio en “mejor conocido”. |
| `game_runtime_requirements` | Requisitos declarativos de runtime, backend, arquitectura, dependencia o permiso. | Almacenar scripts o comandos arbitrarios. |
| `repair_receipts` | Receta permitida/versionada, antes/después, resultado y rollback. | Contener ni ejecutar la implementación de la receta. |

El esquema v10 añade el expediente de investigación que faltaba entre “candidato” y
“promocionado”:

| Tabla | Función |
|---|---|
| `compatibility_research_cases` | Síntoma reproducible, referencia CrossOver, estado y conclusión. |
| `research_hypotheses` | Causas ordenadas y predicciones falsables. |
| `research_experiments` | Una dimensión cambiada, aislamiento, rollback y run exacto. |
| `research_gate_results` | Render, entrada, opciones, gameplay, independencia, matriz y rollback. |
| `research_artifacts` | Referencias privadas y huellas de la evidencia reproducible. |

El esquema v11 añade `run_preflight_reports`: conserva el diagnóstico no destructivo del entorno
anterior a cada lanzamiento, vinculado al App ID, backend y run exactos. Este informe permite
separar una prueba contaminada de un fallo del candidato, pero nunca sustituye la matriz funcional
ni convierte un entorno limpio en compatibilidad.

El esquema v12 añade `run_processes` para que un launcher y el ejecutable real no se conviertan en
dos experimentos ficticios. También distingue un preflight exacto anterior al lanzamiento de una
instantánea tomada al observar el inicio desde la interfaz completa de Steam. Ambas rutas conservan
la misma matriz; la procedencia temporal nunca modifica por sí sola un veredicto.

Triggers de SQLite y la política Swift bloquean una promoción salvo que sea por juego, tenga
fuente y huella verificadas, esté aislada, disponga de rollback, identifique baseline/candidato,
supere la matriz funcional completa y compare ambas rutas con la misma resolución y preset. Las
métricas deben cubrir exactamente los mismos campos en ambas mediciones, ser finitas, positivas y
acotadas; ninguna puede empeorar y al menos una —FPS medio, 1 % low o p95 de frame time— debe
mejorar de forma efectiva. Una fuente HTTPS solo es confiable si su host coincide con el sitio
oficial o de versiones registrado para la tecnología.

## Flujo de I+D protegido

```text
descubrir → preparar copia aislada → medir baseline → probar una variable
          → validar matriz → medir candidato → revisar → promover por juego
                              ↘ fallo/regresión → rollback + conservar evidencia
```

Reglas:

1. El baseline certificado nunca se modifica para preparar el experimento.
2. Cada candidato tiene un Steam App ID o permanece como investigación global no promocionable.
3. Una variable por experimento: Wine, backend gráfico, DLL, registro o toolchain.
4. La comparación usa la misma escena, resolución, preset y condiciones siempre que el juego lo
   permita. Se conservan promedio FPS, 1 % low y p95 de frame time cuando estén disponibles.
5. La matriz funcional sigue mandando: render, entrada, opciones persistentes, gameplay y las
   regresiones exigidas por el componente tocado.
6. Solo una revisión explícita puede promover. La base no aplica perfiles por sí sola.
7. Un expediente nunca se cierra por número de intentos. Continúa con la siguiente hipótesis
   discriminante o queda pausado únicamente por una dependencia externa concreta y reanudable.
8. La certificación funcional, el expediente de causa raíz y la optimización se enlazan, pero no
   se sustituyen: cada afirmación conserva sus propias puertas.

## Autoinstalación, autorreparación y autoselección

La arquitectura está preparada para esas capacidades, pero en esta versión permanecen en modo
**observar y recomendar**. Se habilitarán por fases:

### Fase A — recomendación segura

- detectar requisitos ausentes sin modificar el sistema;
- mostrar la fuente, licencia, tamaño, impacto y acción propuesta;
- ofrecer siempre cancelar, exportar el diagnóstico y usar el baseline.

### Fase B — recetas permitidas y reversibles

- catálogo de recetas compiladas en el código, cada una con ID, versión y pruebas;
- descarga solo desde fuente oficial, checksum/firma y licencia comprobados;
- backup previo, instalación atómica, recibo privado y rollback probado;
- permisos de macOS solicitados justo cuando sean necesarios y con explicación concreta.

Los datos aprendidos nunca se convierten en shell, argumentos arbitrarios ni URLs ejecutables.
Solo pueden alimentar parámetros tipados de una receta incluida y auditada en Regression.

### Fase C — selección automática acotada

- únicamente entre perfiles ya promovidos para ese juego y ese dispositivo;
- fallback inmediato al último blindado funcional;
- detección de regresión y rollback sin tocar otros perfiles;
- elección explicable: motor, versión, evidencia, rendimiento y motivo.

## Salida progresiva de Rosetta

El runtime estable actual es x86_64 porque reproduce el comportamiento validado. Apple ha
publicado que Rosetta de propósito general termina después de macOS 27, por lo que no puede ser
la única arquitectura futura.

La línea de trabajo es paralela, no una migración destructiva:

1. inventariar qué piezas siguen siendo x86_64 y qué juegos dependen de ellas;
2. construir Wine/WoW64 y componentes propios para arm64 en un runtime autocontenido;
3. medir compatibilidad y rendimiento por juego contra el baseline Rosetta;
4. promover perfiles arm64 únicamente cuando igualen toda la matriz y mejoren o mantengan el
   rendimiento;
5. conservar el subconjunto Rosetta que macOS permita para títulos heredados cuando aporte valor.

## CrossOver como referencia temporal

CrossOver permite establecer un resultado esperado y observar configuración pública, logs,
versiones y comportamiento. Regression no copia binarios propietarios, forks privados,
`cxcompatdb` ni licencias. Toda solución independiente se reconstruye con fuentes abiertas o con
componentes Apple instalados legítimamente por el usuario.

Cuando Regression acumule perfiles propios reproducibles y alternativas modernas medidas, la
ausencia de CrossOver afectará únicamente al backend de referencia: los blindados del motor propio,
la base de aprendizaje, las recetas y la selección por juego seguirán siendo locales.

## Diagnóstico

```bash
Regression.app/Contents/SharedSupport/bin/regressionctl technologies
Regression.app/Contents/SharedSupport/bin/regressionctl candidates
Regression.app/Contents/SharedSupport/bin/regressionctl optimization
Regression.app/Contents/SharedSupport/bin/regressionctl requirements
Regression.app/Contents/SharedSupport/bin/regressionctl repair-receipts
Regression.app/Contents/SharedSupport/bin/regressionctl database
```

La exportación JSON incluye el inventario y todo el historial técnico. Continúa excluyendo
credenciales, datos de cuenta y comandos no permitidos.
