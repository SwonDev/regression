# Heroes of Hammerwatch II — expediente de compatibilidad

## Estado blindado

- **Steam App ID:** `619820`
- **Ejecutable objetivo:** `HWR2.exe`
- **Backend:** motor propio de Regression, OpenGL 3.2 mediante Wine CX 26.3 abierto
- **Run perfecto:** `F8E4EA27-2E6B-439C-AC93-BD927035B5B5`
- **Huella de configuración y motor:**
  `af59b82a9e8102995ccbf5a9c93e1e9e6c62afe3213bea8a0bbe2ff7726236f1`
- **Resultado:** título, menú y partida real renderizados con BGFX OpenGL 3.2; entrada precisa,
  opciones funcionales, gameplay estable y cierre limpio con `exit=0`.
- **Confirmación:** el usuario describió la ejecución exacta como «perfecta», «excelsa» y una de
  las mejores implementaciones realizadas, después de comprobar menú y gameplay.
- **Dependencia de CrossOver:** ninguna durante la ejecución. CrossOver se utilizó solo como
  referencia A/B; el proceso cargó recursos firmados dentro de `Regression.app`.

La certificación `perfect` pertenece únicamente al run anterior. Los fallos previos de Regression
y CrossOver se conservan en SQLite y en el expediente de I+D: demuestran la causa raíz y nunca se
reinterpretan como éxitos.

El expediente `3423F8A2-5885-45DA-80A9-AD2953EA7E1E` quedó cerrado como `verified`; su
experimento ganador `4529682F-FCE3-4262-B507-862C80D88298` quedó inmutable como `passed`, con
ocho puertas y las ocho evidencias obligatorias completas.

## Causa raíz

Heroes of Hammerwatch II inicializa BGFX solicitando un contexto OpenGL **core 3.2** sin añadir
`WGL_CONTEXT_FORWARD_COMPATIBLE_BIT_ARB`. macOS solo expone los contextos core 3.2 o superiores
como forward-compatible. Tanto el baseline de Regression como CrossOver 26.3 alcanzaban por ello
el mismo error:

```text
Starting BGFX renderer OpenGL 3.2
BGFX Fatal error! Failed to create context 0x00002095.
BGFX Fatal error! SetPixelFormat failed!
```

El árbol Wine CX 26.3 público que ya usa Regression contiene el mecanismo de CodeWeavers
`CW Hack 24834`: cuando `CX_FWD_COMPAT_GL_CTX=1`, añade el bit requerido antes de crear el
contexto. No era necesario inventar una traducción Direct3D ni tocar el registro; faltaba activar
esa capacidad únicamente para el ejecutable exacto.

El router reconoce `HWR2.exe`, antepone su perfil autocontenido y define
`CX_FWD_COMPAT_GL_CTX=1` dentro de ese proceso. Ningún otro juego, Steam ni CEF hereda la variable.
El driver global de Steam mantiene el hash protegido `50fda6d2…`; la inspección del proceso
validado confirmó que el `winemac.so` efectivo procedía del runtime propio y ya contenía el hook
opt-in de CX. El perfil conserva además una reconstrucción determinista del módulo compatible,
sin sustituir el runtime global.

La identidad de esta receta también vive en el catálogo compilado
`GameRuntimeProfileCatalog`. El recolector incorpora únicamente hechos `profile.*` permitidos y
firmados —no comandos aprendidos— a la huella del motor. El run histórico se reconcilió de forma
transaccional desde la huella global `37436b734c8c1cf5db4d18b000401ddf2a98788cf4deb8544dcd23b1804155d2` a la huella aislada
`af59b82a9e8102995ccbf5a9c93e1e9e6c62afe3213bea8a0bbe2ff7726236f1`; el snapshot anterior se conserva como rollback.

## Referencia A/B e hipótesis

| Prueba | Run | Resultado |
|---|---|---|
| Regression baseline | `13A04051-966F-4C7C-8D48-F38097F500E9` | fallo BGFX `0x2095` |
| CrossOver 26.3 baseline | `65857243-9F46-4931-97CD-2A7898F4F35B` | el mismo fallo BGFX `0x2095` |
| Regression, opt-in aislado | `F8E4EA27-2E6B-439C-AC93-BD927035B5B5` | OpenGL 3.2 inicializado; perfecto |

La referencia histórica del proyecto Vessel permitió localizar el patrón OpenGL ya investigado.
La decisión final no copió ningún binario de ese proyecto ni de CrossOver: se contrastó contra la
fuente pública CX 26.3 incluida en Regression y se reconstruyó el artefacto desde esa fuente.

El log del candidato demuestra el cambio causal:

```text
Starting BGFX renderer OpenGL 3.2
BGFX initialized
Renderer: OpenGL 3.2
```

Solo cambió la activación forward-compatible. La instalación física, el registro, RetinaMode,
DXMT, DXVK, D3DMetal y las preferencias del juego permanecieron intactos.

## Matriz funcional

| Puerta | Evidencia observada |
|---|---|
| Render | menú y bosque en gameplay sin artefactos; BGFX inicializado |
| Entrada | personaje, cámara, cursor y menús respondieron con precisión |
| Opciones | configuración del título accesible y estable durante la sesión |
| Gameplay | partida real con personaje, HUD, habilidades, iluminación y escenario activos |
| Cierre | salida normal; sesión agregada con `exit=0` |
| Recursos propios | `lsof` no mostró rutas ejecutables de CrossOver en `HWR2.exe` |
| Steam | tienda completa renderizada antes y después del juego |
| Perfil protegido | Grim Dawn volvió a menú y gameplay; el cambio de ventanas conservó imagen |
| Rollback | router, driver global, PE y configuración previos preservados por hash |

Grim Dawn presenta durante algunos arranques una superficie temporal desbordada hasta que su
ventana recibe foco. La A/B de matriz reprodujo ese estado con el router anterior y confirmó que,
al seleccionar la ventana, el perfil protegido corrige la presentación, permite jugar y soporta
el cambio de ventanas. No se atribuye ese comportamiento histórico al perfil de HWR2.

## Implementación reproducible

La receta queda protegida en:

- `patches/wine-26.3.0-per-process-graphics-routing.patch`;
- `patches/wine-26.3.0-forward-compatible-opengl.patch`;
- `build/build-heroes-hammerwatch-2-profile.sh`;
- `build/build-dd2-profile.sh`, que reconstruye el router compartido de perfiles;
- `build/install-game-profiles.sh`, con instalación transaccional, rollback, hashes y firma;
- `build/verify-protected-state.sh`, que fija el runtime y todos los perfiles anteriores.

Hashes promocionados:

```text
ntdll.so router:                    d580644ea2604f76e16dbb9448255bdadd2543e3bcf2340a20f32202d6e45d45
winemac.so global, sin cambios:     50fda6d287a23324c39c75c7c887ae3ae0bf4e175c61bae4a92229053b5c65f2
winemac.drv global, sin cambios:    da91ec701a18e97c0c3cd943d383ef996092c11d74983876fd44c90b03d5e5b1
winemac.so perfil reproducible:     2e441e71c00738b7434f7161648cb5c0e78f63a9ae8f3ceefa6ab8100b107c67
```

El módulo del perfil se construyó dos veces desde cero con `-g0` y sin `LC_UUID`; ambas
reconstrucciones produjeron exactamente `2e441e71…`. Los módulos PE no se sometieron a `strip`.

## Evidencia privada y rollback

El expediente local vive en:

```text
backups/heroes-hammerwatch-2-baseline-20260729-122351/
```

Contiene SQLite previa, userdata, registros, saves, baseline fallido, referencia CrossOver,
fuentes de la hipótesis, builds reproducibles y capturas del candidato:

```text
regression-gameplay-agent.png       a4f1e7e8d181b3c6ab056af8cbf71f4fcf9ecb02ef1fa31da9e3334e15d45b26
user-menu-confirmation.png          ea3f62b1e27c3864bb10a8921455ed38e04f2fb75154e6888d697f0e5ba7d21b
user-gameplay-confirmation.png      d3e82b3dad86f5e4e426cee2ce93ffb29783f2efe3abd6ed0e7fa40eedb5f42f
steam-before-hwr2.png               4ed7609a31207f58e51ddf76c5e083df0e49412761bca5b3e44384d83b5a40f6
steam-after-clean-exit.png          b45825672153aa5cc6b487c69f1e39c23ad37981e266f1fe3bd9f1006272a62a
hwr2-success.log                    d437cdcce795d622d3d4cfab17c794e165d36bc6bc0fed65ac51e0d5cc990bfe
rollback-manifest.txt               1eff1b958da5347b13e435e39b76f47466033d23d08414e19193ce06fdbe6a13
configuration-snapshot.txt          91f5a6c31a8b21f32e027a333ca71bf97b7124cb34a952a32117da17098d9690
test-report.txt                     eaf63f286043e9ee42db3fa69394b25e65c24e7a1ac159f852566df49e098c9c
signature-report.txt                e599b06178f9a7d51099d969a2372cb0dc6b27ba78df4a06c42f17ac706c00ed
regression-1.7.3-steam-render.png    ba56d45c33076aa033861e5418218e8170cad9752ba160081ba3050416b375b6
regression-1.7.3-hwr2-green-screen.png
                                    6b9187c906057236f5eace8384cdaf4cb33820ff1acd57564af121d59093b78d
compatibility-before-profile-reconciliation.sqlite
                                    2237ffb16d7117fb19d9b96b23ff1c867c10ed847fa65a10a10114b49680178f
compatibility-after-profile-reconciliation.sqlite
                                    85b3eff1c8528c71c702c948ff648fbe48dfbf4849673f25c4bb59a9720d351e
compatibility-closed-research.sqlite f74e504f2a633807ba783749dacdc71e808b2cd449d1d83419fdc2102271bc8b
```

El rollback restaura `ntdll.so` con hash `2a446467…`, retira el perfil HWR2, vuelve a firmar y
ejecuta `build/verify-protected-state.sh --before-hwr2-promotion --include-bottle`. La copia
transaccional del instalador permite revertir una instalación incompleta sin tocar los perfiles
de Grim Dawn, Dragon's Dogma 2 o DragonSword.

## Regla de no regresión

Heroes of Hammerwatch II debe conservar este opt-in exclusivo. No se permite mover
`CX_FWD_COMPAT_GL_CTX` al entorno global de Steam, cambiar el registro de la botella ni sustituir
OpenGL por otra capa sin una nueva A/B completa. Una actualización de Wine puede reemplazar la
receta únicamente si mantiene Steam, Grim Dawn y los demás perfiles protegidos, reproduce menú y
gameplay y mejora con métricas comparables.
