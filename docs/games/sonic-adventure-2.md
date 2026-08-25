# Sonic Adventure 2 — expediente de compatibilidad

## Estado

- **Steam App ID:** `213610`
- **Ejecutables:** `Sonic Adventure 2/Launcher.exe` (diálogo de configuración) y
  `Sonic Adventure 2/sonic2app.exe` (el juego)
- **Tecnología:** D3D9 (`d3d9.dll`, `d3dx9_42.dll`, `ddraw.dll`), puerto PC de 2012
- **Perfil compilado:** ruta por proceso `sonic2app.exe → d3d9 builtin` (wined3d)
- **Estado:** **funcionando.** Renderizaba negro con la música sonando. Corregido el 2026-08-25.

## Síntoma

El juego arrancaba, se oía la música y la ventana quedaba **completamente negra**. No había crash:
el proceso vivía, animaba su bucle y consumía CPU.

Además, el lanzamiento parecía no producir proceso alguno. Eran dos cosas distintas y ninguna era
del motor gráfico:

1. `regressionctl launch` se rechazaba con `el inventario tecnológico excede el límite de entradas`
   —el juego tiene 4534 entradas y el presupuesto estaba en 4096—.
2. El diálogo de configuración (`Launcher.exe`) se abre **detrás** de la ventana de Steam, que
   ocupa toda la pantalla. Los clics aterrizaban en Steam, no en el botón «Guardar la configuración
   e iniciar SONIC ADVENTURE 2», así que el juego nunca llegaba a arrancar.

## Causa raíz

Lo acredita el log del propio juego, `sonic2App_d3d9.log`, no las cadenas del binario:

```text
info:  DXVK: v1.10.3
err:   DxvkGraphicsPipeline: Failed to compile pipeline
err:     vs  : VS_33a900417a84d417a11417b8859e35de3197e19d
err:     fs  : FS_911893814b2496096a40bce05e50601c8823bb48
```

**Todas** las pipelines gráficas fallan al compilar. Con cero pipelines no se dibuja nada, pero el
resto del juego —audio, lógica, presentación— sigue funcionando: exactamente «negro con música».

El error real lo da el compilador de Metal, con `MVK_CONFIG_LOG_LEVEL=4`:

```text
[mvk-error] VK_ERROR_INVALID_SHADER_NV: Fragment shader function could not be compiled into pipeline
program_source:197:88: error: use of undeclared identifier 's0_2d_shadowSmplr'
```

Y el MSL generado explica por qué está sin declarar:

```text
// Overlapping binding: sampler s0_2d_shadowSmplr [[id(6)]];
void ps_main(..., texture2d<float> s0_2d, sampler s0_2dSmplr,
             depth2d<float> s0_2d_shadow, sampler s0_2d_shadowSmplr, ...)
    r0 = float4(s0_2d_shadow.sample_compare(s0_2d_shadowSmplr, v[1].xy, v[1].z));
```

El `d3d9` de DXVK declara, para cada slot de sampler, **dos** variantes sobre el mismo binding: la
normal y la de comparación de profundidad (*shadow*), y elige entre ellas con una constante de
especialización. Vulkan lo admite; Metal no puede poner dos samplers en el mismo índice.
SPIRV-Cross detecta la colisión, **comenta la declaración** de la variante de sombra y aun así la
sigue usando en el cuerpo: el resultado es MSL que no compila.

No es un problema de un shader concreto ni de un formato de vértice: afecta a cualquier juego D3D9
que use *shadow mapping* por hardware.

## Lo que se descartó, con evidencia

| Hipótesis | Experimento | Resultado |
|---|---|---|
| Los *argument buffers* de Metal son el problema | `MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0` | El defecto de solapamiento desaparece del MSL (`[[id(` pasa a 0), pero Metal falla igual: `cannot reserve 'sampler' resource location at index 0`. El aliasing es de DXVK, no del formato de descriptor. |
| El juego pide formatos de profundidad que se pueden retirar | `d3d9.supportDFFormats = False` en `dxvk.conf` | Los fallos bajan de 89 a 55, pero siguen. El juego usa profundidad comparable por otra vía. |
| `d3d9.floatEmulation = Strict` (perfil propio de DXVK para este juego) | descartado al identificar el sampler de sombra como causa | no era la causa; se deja el perfil de DXVK intacto |

## Corrección

Se enruta **solo ese proceso** al `d3d9` builtin de Wine (wined3d sobre OpenGL), que sí tiene
samplers de sombra nativos en macOS. La ruta es por *basename* exacto, publicada por el lanzador y
consumida por el parche `process-scoped-dll-isolation`:

```bash
export REGRESSION_PROCESS_BUILTIN_DLL_ROUTE_COUNT=1
export REGRESSION_PROCESS_BUILTIN_DLL_ROUTE_0_EXECUTABLE="sonic2app.exe"
export REGRESSION_PROCESS_BUILTIN_DLL_ROUTE_0_DLL="d3d9"
```

Wine solo acepta `d3d9` en esa ruta y solo como *preferencia de builtin*: una ruta no puede
seleccionar un módulo arbitrario, una ruta de disco ni un modo de carga. El resto de juegos D3D9
sigue en DXVK.

Además:

- El presupuesto del inventario tecnológico sube a 262 144 entradas y **deja de ser una puerta**:
  es evidencia de diagnóstico, no una comprobación de seguridad, así que un inventario que no cabe
  avisa y el lanzamiento continúa.
- El diálogo de configuración se abre detrás de Steam. No es un fallo: es una ventana normal y
  Steam ocupa la pantalla. Basta traerla al frente antes de pulsar su botón.

## Validación

- `sonic2App_d3d9.log` **deja de existir**: DXVK ya no interviene en ese proceso.
- El juego renderiza el logo, «Pulsa START» y la demo jugable en 3D con HUD, iluminación y efectos.
- Matriz de la fila «Wine»: tienda de Steam (CEF/DXMT), Fields of Mistria (Unity) y este juego,
  las tres con captura mirada.

## Lecciones

- **El log del juego acredita; las cadenas del binario solo sugieren.** Aquí el `_d3d9.log` daba la
  causa en la primera línea de error.
- **Un fallo de compilación de pipeline se ve como pantalla negra, no como crash.** Si hay audio y
  el proceso consume CPU, el motor gráfico es el primer sitio donde mirar.
- **Una ventana que no responde a los clics puede estar simplemente detrás de otra.** Antes de
  diagnosticar el foco, mirar el orden de ventanas.
