# FANTASY LIFE i — expediente de compatibilidad EAC

## Estado actual

- **Steam App ID:** `2993780`
- **Cadena de arranque:** `GameBootstrapper.exe` (i386) → `EACLauncher.exe` (x86-64) →
  `Game/Binaries/Win64/NFL1-Win64-Shipping.exe`.
- **Easy Anti-Cheat product ID:** `1c57494d93e24d2091a070296910acec`.
- **Deployment ID:** `607d68cfa8b24890ba88764cc2879d57`.
- **Expediente local:** `CD577AEA-7058-4194-9948-8B7806207D6D`.
- **Estado:** I+D host nativo activa y reproducible: un componente oficial Wine64 de Proton 11
  ya termina sobre FEXCore Darwin; **el juego no está certificado ni blindado**.

El juego sigue fallando en el motor macOS estable de Regression y en CrossOver después de que
EAC descargue correctamente su módulo. El candidato Linux ARM aislado ya supera ese fallo de
mapeo, carga la mitad Unix oficial y alcanza una etapa posterior. La repetición autenticada con
el parche FS/GS v3 superó el anterior código `210`: EAC descargó el módulo, obtuvo HTTP `200`,
inició el mapeo Wine 11 y terminó con código `208`, `Cannot run under Virtual Machine`. Todavía
no se ha iniciado `NFL1-Win64-Shipping.exe` y ese rechazo no se eludirá ocultando o falseando la
virtualización.

El laboratorio gráfico ya no está limitado a CPU. Un clon APFS independiente arrancado con UTM
5.0.3 expone `Virtio-GPU Venus (Apple M5 Pro)` mediante Mesa Venus, completa una cola Vulkan,
presenta `vkcube` por X11 y renderiza visualmente el cliente Steam Linux oficial con CEF. Steam
elige Venus como GPU predeterminada. El usuario ya completó el login manual dentro de ese cliente;
la investigación solo verifica el booleano de sesión y no lee, exporta ni copia identificadores,
credenciales o tokens. El usuario aceptó personalmente el EULA y Steam completó la instalación
oficial: el manifiesto de App ID `2993780` quedó en `StateFlags=4`, build `21998011`, con
`15.203.991.960` bytes en disco. Tras ejecutar el App ID desde esa misma biblioteca y sesión
autenticada, Steam completó EOS, EAC, UEPrereq y DirectX; EAC volvió a descargar su módulo con
HTTP `200`, inició Wine module mapping 11.0 y devolvió exactamente `208 Cannot run under Virtual
Machine`. El ejecutable principal no llegó a aparecer.

La ruta host nativa ya ejecuta ELF x86-64 reales y completa el `wine64` Unix oficial de Proton 11
con glibc 2.43, `ntdll.so` y `libgcc_s.so.1`. Este avance no equivale todavía a «Proton integrado
en macOS» ni a compatibilidad funcional del juego: no se han ejecutado por esa ruta el
orquestador Proton, Steam, EAC ni `NFL1-Win64-Shipping.exe`. Aunque existe además una ruta gráfica
real en la VM, sigue siendo obligatorio superar EAC y completar render, entrada, opciones,
gameplay, estabilidad y cierre antes de considerar cualquier promoción.

El rechazo `208` cierra la VM como solución final, pero abrió una vía distinta y no virtualizada:
un host macOS arm64 que ejecute el proceso Linux oficial sin modificar Steam, Proton o EAC. Esa
línea ya compila y carga FEXCore de forma nativa, ejecuta binarios x86-64 de glibc y SteamRT y ha
cerrado un primer componente oficial de Proton. Su frontera exacta y el punto de reanudación se
documentan más adelante.

## Límites inviolables

1. No se desactiva, parchea, emula ni elude Easy Anti-Cheat.
2. Solo se usan el launcher y los módulos que publica el propio deployment del juego, el runtime
   oficial Proton EAC de Valve y componentes públicos con licencia compatible.
3. No se copian credenciales, tokens ni archivos de sesión desde Steam de macOS, CrossOver,
   Bazzite u otra instalación. La autenticación fue realizada manualmente por el usuario en el
   cliente Linux oficial y aislado; los acuerdos legales también requieren su acción directa.
4. El candidato no modifica la botella, Wine, DXMT, DXVK, D3DMetal ni los perfiles blindados de
   Regression. Tampoco introduce una dependencia de CrossOver.
5. Un proceso vivo, un HTTP `200`, un `dlopen` correcto o un código distinto de `206` no
   certifican el juego. Solo una matriz visual completa sobre la ejecución exacta puede hacerlo.

## Referencia y síntoma reproducido

El usuario posee el juego en Steam y confirmó que el mismo título funciona en Bazzite mediante
Proton. Esa referencia demuestra que el editor habilitó una ruta Linux/Proton para este
deployment, pero no demuestra que el módulo Unix pueda cargarse directamente en un proceso
Mach-O de macOS.

Regression y CrossOver 26.3 reproducen la misma frontera:

```text
Starting Wine module mapping, Wine version: 11.0.
Failed to map the anti-cheat module.
Launcher finished with: 206
```

La descarga termina con HTTP `200`; el fallo sucede al mapear la mitad Unix. El inventario del
deployment encontró módulos `win64` y `linux64`, pero no un módulo `mac64`. El runtime Proton EAC
oficial combina PE con ELF/GLIBC, mientras que el Wine macOS estable carga módulos Unix Mach-O.
Copiar el depot o definir `PROTON_EAC_RUNTIME` en el host macOS no resuelve esa incompatibilidad
de ABI y no se considera una receta válida.

## Fuentes y artefactos oficiales

Se conservaron los artefactos obtenidos por los mecanismos oficiales de Steam:

| Componente | Identidad |
|---|---|
| Proton x86-64 | depot `4628711`, manifest `2323543246978012070`, versión `proton-11.0-1` |
| Proton ARM | depot `4628741` |
| Steam Linux Runtime ARM | depot `4185401` |
| Proton Easy Anti-Cheat Runtime | app `1826330`, depot `1826331` |
| Cliente Steam Linux | build `1785187029` |
| Fuente pública Proton | rama `proton_11.0`, commit `0745bfbc4cf4365e8cf048b003990c59def29948` |
| FEX | paquete/fuente pública `2607` |

El comando de depot aportado por el usuario fue:

```text
download_depot 4628710 4628711 2323543246978012070
```

No se incluyen esos binarios en Git. El repositorio conserva únicamente parches propios sobre
fuentes públicas, herramientas de diagnóstico sin conocimiento privado y la documentación del
experimento.

El depot x86 oficial se registra en el Steam Linux aislado mediante el mecanismo público de
herramientas locales de Proton, no mediante un manifiesto de aplicación inventado.
`tools/research/fli_utm_lab.sh stage-proton` verifica primero estas dos fronteras:

```text
proton
  b56de46d7619ebf6975a625e47c202c81baa375ca3576983e221bc9892b0633b
files/bin/wine
  7a6de49c00d8ed2ba55c6967d3643c5ef729f5e562fb51e47e4f41c6cdb5c92a
```

Venus no implementa `VK_EXT_depth_clip_enable`, por lo que el DXVK 2.7.1 incluido en ese depot
rechaza la GPU antes de crear D3D11. La A/B con el DXVK 1.10.3 público conservado en las fuentes
de CX 26.3 sí crea feature level 11_0 y presenta. El orquestador crea un clon por hardlinks del
Proton oficial y rompe únicamente los hardlinks de `d3d11.dll` y `dxgi.dll`; sus huellas son:

```text
d3d11.dll
  e78bbb4ff8a34bd81ec127f54514ec9b61ce8e6e0f6b81a4a7d3b51b5f5bebf7
dxgi.dll
  e4a06360582d75e4a59fb2ca2c1c8dec3efde910d6fb252b99d125d34819d432
```

Después crea únicamente
`compatibilitytools.d/regression-fli-proton-11-x86-fex-v3-dxvk1103.vdf`, que apunta al candidato
aislado y aparece en Steam como `Regression FLI — Proton 11 + DXVK 1.10.3`. El formato procede de la
[plantilla pública oficial de Proton](https://github.com/ValveSoftware/Proton/blob/proton_11.0/compatibilitytool.vdf.template).
No se crea `appmanifest_4628710.acf` ni se suplanta la instalación del juego. Steam escribió en
su propio `config.vdf` una única asociación `CompatToolMapping` para App ID `2993780`, con
prioridad 250; no existe un mapeo global. El cliente oficial sigue siendo quien valida propiedad,
crea su manifiesto, verifica el contenido y descarga los runtimes requeridos.

## Qué aporta —y qué no— la referencia pública de GameNative

Se auditó el repositorio público de GameNative en el commit
`d61318b9d200f990b9d4141aabcc66821a13702c`. Su código confirma dos decisiones relevantes para
este expediente:

- cada variante de Proton instala un `lsteamclient.dll` emparejado con su ABI concreta;
- el lado Wine solo alcanza Steamworks/EAC cuando existe un `libsteamclient.so` autenticado con
  pipe, usuario global y preparación de propiedad/ticket para el App ID.

Eso sustentó la hipótesis ya comprobada: no basta con que la biblioteca cargue; la sesión Steam
host debe existir y pertenecer legítimamente al usuario. Sin embargo, la pieza que GameNative emplea
para crear esa sesión (`libsteambootstrap.so`) es propietaria, su fuente está retirada
deliberadamente y encapsula interfaces internas no documentadas de Valve. Sus propios avisos de
terceros lo declaran de forma expresa. Por ello Regression no copiará ese binario, no intentará
reconstruir su mapa privado de símbolos ni trasladará tokens desde otra instalación.

Tampoco se emplearán sustitutos de `steam_api` como atajo: no proporcionan la sesión oficial que
EAC espera y convertirían una investigación de compatibilidad en una elusión. La única ruta
válida que queda de esta comparación es la ya abierta: cliente Steam Linux oficial, login manual
del propietario y Proton/EAC oficiales, todo dentro del laboratorio aislado.

## Matriz de hipótesis y resultados

| Variante aislada | Única dimensión | Resultado | Decisión |
|---|---|---|---|
| CrossOver 26.3 + EOS/EAC instalados | referencia | módulo descargado; código `206` al mapear | negativa conservada |
| Regression macOS + runtime Proton EAC | dependencia | ELF/GLIBC frente a Mach-O | no portable directamente |
| Inventario del deployment | dependencia | `linux64` y `win64`; sin `mac64` | confirma la frontera ABI |
| Proton ARM + Steam Runtime ARM | host/arquitectura | Wine ARM no puede cargar EAC `linux64` x86-64 | negativa conservada |
| Proton x86-64 + FEX FS v1 | traducción de CPU | descarga el módulo y supera `206`; termina `210` | avance, no promocionable |
| FEX FS+GS v2 | selector adicional | alcanzó `210`, pero la sonda devolvió selector `0` | descartada: semántica incompleta |
| FEX FS+GS v3 | selectores visibles sin destruir bases dedicadas | FS/GS no-cero, Wine x64 y WoW64 pasan; el `210` desaparece con Steam autenticado | candidato de CPU correcto |
| FEX con seccomp solicitado | sandbox | filtros instalados; mismo `210` | seccomp no es la causa |
| Sonda `dlopen(3)` x86-64 | cargador ELF | `easyanticheat_x64.so` carga con `RTLD_NOW` | el `210` ocurre después de la carga |
| Steam Linux real, anónimo | IPC/propiedad | `steamclient.so` correcto; falla `ConnectToGlobalUser`; `210` | requiere login legítimo |
| UTM 5.0.3 + Venus | GPU virtual | `VENUS_SUBMIT_OK`; `vkcube` visible sobre Apple M5 Pro | presentación Vulkan válida |
| Steam Linux bajo FEXBash | cliente/CEF | login oficial visible y autenticado; Venus es la GPU predeterminada | sesión legítima confirmada sin leer secretos |
| FEX FS/GS v3 directo + `vkcube` x86-64 | traducción/GPU | PID ejecutado por el candidato exacto; Venus visible por XCB | ruta gráfica del candidato válida |
| Proton 11 + DXVK 2.7.1 | D3D11/Venus | falta `VK_EXT_depth_clip_enable`; no crea dispositivo | descartado para esta GPU virtual |
| Proton 11 + DXVK 1.10.3 | D3D11/Venus | feature level 11_0 y presentación visible | candidato gráfico válido y aislado |
| Steam autenticado + FEX v3 + EAC oficial | autenticación | HTTP `200`, mapeo Wine 11; código `208 Cannot run under Virtual Machine` | bloqueo de política externo observado; no eludir |
| Instalación oficial visible | distribución | EULA aceptado por el usuario; manifiesto oficial `StateFlags=4`, build `21998011`; archivos verificados | instalación completa |
| App ID oficial + FEX v3 + Proton 11/DXVK 1.10.3 | lanzamiento íntegro desde Steam | prerrequisitos oficiales completos; EAC HTTP `200`, mapeo Wine 11 y código `208`; ejecutable principal ausente | bloqueo de virtualización confirmado; no eludir |
| FEXCore Darwin + ELF/glibc reales | ABI host no-VM | `/usr/bin/true` y binarios SteamRT x86-64 terminan con código `0` | cargador y ABI mínima reproducidos |
| Wine64 Unix + ntdll/libgcc, sin `HOME` | entorno huésped | alcanza NSS y termina en acceso huésped nulo, sin syscall pendiente | hipótesis aislada; no parchear señales |
| Misma huella + `HOME=/home/regression` | una variable de entorno | imprime 10 bytes de versión y termina con `exit_group(0)` | primer componente oficial de Proton completado; no es Proton completo |

La ruta ARM directa quedó cerrada como resultado negativo. La hipótesis investigada
`69B64100-BEDD-46CE-B931-00BFC1B152ED` prueba Proton x86-64 oficial sobre FEX y está vinculada al
experimento `BA3FA6CD-199B-4691-BBFA-02910F958CD4`, cerrado como `failed`. El expediente
`CD577AEA-7058-4194-9948-8B7806207D6D` queda en `pausedExternalDependency` con las huellas del
manifiesto y de la prueba oficial vinculadas en la base local.

## Causa exacta del bloqueo actual

La frontera anterior estaba causada por el cliente anónimo. Proton encontraba y cargaba la
biblioteca host correcta, pero no podía obtener el usuario global:

```text
trace:steamclient:steamclient_init Loaded host steamclient from ".../linux64/steamclient.so"
err:steamclient:steamclient_init_registry Failed to connect to Steam
```

La fuente pública exacta de Valve, `lsteamclient/unixlib.cpp:700-716`, demuestra que ese mensaje
solo aparece cuando falla `CreateSteamPipe()` o `ConnectToGlobalUser()`. `setup_eac_bridge()` se
ejecuta después de obtener ambos handles. El login manual legítimo resolvió esa frontera: la A/B
autenticada dejó de devolver `210`, descargó el módulo EAC con HTTP `200`, inició el mapeo Wine
11 y terminó en:

```text
Launcher finished with: 208, 'Cannot run under Virtual Machine.'.
```

La evidencia exacta vive en
`/var/lib/regression-fli-utm/evidence/fli-auth-official-dxvk271-v2/`. Este resultado demuestra
que la sesión Steam, `lsteamclient` y el puente EAC ya avanzan más allá de la autenticación. No
demuestra compatibilidad: el ejecutable principal sigue sin aparecer. Regression no desactivará
EAC ni ocultará, simulará o falseará la VM para rodear el `208`.

El cliente Proton debe compartir `HOME` con ese Steam Linux oficial. Usar el directorio separado
de FEX como `HOME` permite arrancar Wine, pero impide que `lsteamclient` encuentre la sesión del
cliente; la A/B reproducida termina entonces en `unable to load native steamclient library`.
Compartir únicamente `HOME` no copia secretos: ambos procesos pertenecen a la misma sesión
aislada y la autenticación fue realizada manualmente por el usuario.

La comprobación de requisitos de Steam también debe ejecutarse dentro de la traducción. Lanzar
`steam.sh` desde un shell ARM hace que su `ldd` anfitrión diagnostique erróneamente que falta
`libc.so.6` de 32 bits. Lanzar el script completo mediante `FEXBash` satisface los requisitos,
inicia `steam-runtime-launcher-service`, pressure-vessel y CEF, y mantiene un único árbol de
procesos controlado por systemd.

Esa puerta ya se cerró también con la distribución íntegramente creada por Steam. El usuario
aceptó el EULA, el cliente creó `appmanifest_2993780.acf`, verificó el contenido, dejó el
manifiesto en `StateFlags=4` y lanzó el App ID desde su biblioteca autenticada. La repetición
terminó en el mismo `208` antes de `NFL1-Win64-Shipping.exe`. Por tanto, no quedan como causas
pendientes la propiedad, el acuerdo legal, la instalación, los prerrequisitos, el manifiesto,
la sesión Steam ni el puente inicial de EAC. La frontera observada es la comprobación de
virtualización del módulo oficial y no se rodeará ocultando o falseando la VM.

## Candidato FEX y alcance de los parches

El Proton x86-64 oficial alcanzaba instrucciones que escriben los selectores FS/GS en modo de
64 bits. FEX 2607 rechazaba esas operaciones antes de que Wine pudiera iniciar. Los candidatos
locales permiten actualizar esos dos selectores empleando el mecanismo existente de FEX:

- `patches/fex-2607-x86_64-fs-selector.patch`;
- `patches/fex-2607-x86_64-gs-selector.patch`.

La primera revisión hacía avanzar Wine, pero devolvía siempre selector `0` y reutilizaba el
mecanismo de segmentos heredados para sobrescribir `fs_cached`/`gs_cached`. Eso destruía la base
dedicada que long mode mantiene separada del selector visible. Por tanto, el binario v2 con
SHA-256 `7ddfca344920b69eabf0ecb6c1d0c78cc55993d3335a10a95534dd19dfd63435`
queda invalidado aunque alcanzase el código `210`.

La revisión v3 aplica la semántica mínima comprobable:

- siempre conserva y devuelve el selector visible en `fs_idx`/`gs_idx`;
- solo deriva la base desde el descriptor en modos que no sean de 64 bits;
- no toca la base FS/GS dedicada de long mode.

El binario combinado FS+GS v3 tiene SHA-256:

```text
52dd0d29966fe71b71f6f1b042bdc2254494568261f65dd51d0bee3494d97761
```

Para la A/B gráfica se preparó un runtime autocontenido sin sustituir `/usr/bin/FEX`:

```text
/var/lib/regression-fli-utm/fex-fs-gs-preserve-base-v3/bin/FEX
  52dd0d29966fe71b71f6f1b042bdc2254494568261f65dd51d0bee3494d97761
/var/lib/regression-fli-utm/fex-fs-gs-preserve-base-v3/bin/FEXBash
  138c034edd814d8c3cb8a49bd0b09c44e4b008b0e0395ed59af7865314254230
/var/lib/regression-fli-utm/fex-fs-gs-preserve-base-v3/bin/FEXServer
  53cee8aa4102c2e6e75255114f612975637950d377101c0a6d298164d011bff1
```

`FEXBash` resuelve el intérprete `FEX` adyacente para su primer proceso. Sin embargo, una llamada
`execve(2)` posterior desde un ELF x86 puede volver a entrar por `binfmt_misc`; si el handler
global sigue apuntando a `/usr/bin/FEX`, los descendientes ya no quedan garantizados sobre v3.
Esto se reprodujo con `vkcube`: la variante iniciada a través del shell terminó con
`/proc/<pid>/exe=/usr/bin/FEX`, mientras que la invocación directa del candidato conservó la ruta
y la huella v3 exactas.

Por tanto, la A/B de Steam completa necesita seleccionar v3 también en los dos handlers FEX del
invitado. `tools/research/fli_utm_lab.sh start-steam-v3` lo hace únicamente con Steam y FEX en
reposo, mediante overrides no persistentes en `/run/binfmt.d`; verifica ambos intérpretes antes
de arrancar. No sustituye `/usr/bin/FEX` ni los ficheros de `/usr/lib/binfmt.d`. Al detener Steam,
el script elimina solo sus propios overrides, reinicia `systemd-binfmt` y exige que ambos handlers
vuelvan a `/usr/bin/FEX`. Un reinicio de la VM también descarta `/run`, pero no sustituye la
restauración explícita y verificable.

La sonda estática `tools/research/fex_segment_selector_probe.S` instala mediante `modify_ldt(2)`
un descriptor con selector no nulo, escribe FS o GS y exige recuperar exactamente ese valor. Sus
binarios de prueba tienen estas huellas:

```text
FS  7a61b7f99a28e10913daa2e50532d55c36ea2d7c051a2b8413c8824e7bf191eb
GS  c6229fcc371de958efa6638040bf202785d53930d1d385eeb452b2a6a4a3297e
```

La matriz directa fue: FEX oficial → `SIGSEGV`/139; v2 → ejecución con roundtrip incorrecto/1;
v3 → roundtrip correcto/0 para FS y GS. El mismo v3 inició `cmd.exe` x86-64 y el `cmd.exe` WoW64.
Después, con el prefijo restaurado y Steam oficial anónimo, EAC volvió a superar `206` y acabó en
`210`; esto descarta una regresión del traductor hasta la frontera de autenticación.

`systemd-binfmt` registra también el handler Rosetta de Lima y su firma x86-64 se solapa con la
de FEX. Si ambos están activos, Rosetta puede interceptar la sonda y producir una A/B falsa. En el
laboratorio se guarda el estado del handler, se desregistra Rosetta solo durante el experimento y
se restaura al terminar. Este procedimiento no forma parte de ninguna receta de producción.

Estos parches siguen siendo **candidatos de investigación**, no una corrección general aceptada.
Que las sondas, Wine y EAC avancen no demuestra que la semántica completa sea correcta para todas
las aplicaciones. No pueden entrar en el runtime estable sin revisión upstream, matriz de
Wine/Steam y una validación completa del juego.

La sonda `tools/research/eac_dlopen_probe.py` se limita a `dlopen(3)` con `RTLD_NOW|RTLD_LOCAL`.
No resuelve símbolos privados, no llama a EAC y no modifica el módulo; solo separa errores del
cargador ELF de fallos de inicialización posteriores.

## Laboratorio, rollback y evidencia privada

Las pruebas iniciales de CPU viven en la VM Lima `regression-dxvk`. La prueba gráfica usa un clon
APFS independiente llamado `Regression FLI Venus Lab`; el disco Lima original permanece detenido
y sin modificar. Sus rutas principales son:

```text
/var/lib/regression-fli-arm-lab/
/private/tmp/regression-dxvk-linux/fli-linux-steam-reference/
/Users/adrianpereradelgado/Library/Containers/com.utmapp.UTM/Data/Documents/
  Regression FLI Venus Lab.utm/Data/regression-dxvk-venus.qcow2
/var/lib/regression-fli-utm/fli-linux-steam-reference/
/var/lib/regression-fli-utm/fli-game-clone/
```

La VM usa QEMU ARM64/HVF, 8 núcleos, 8 GiB, UEFI y
`virtio-gpu-gl-pci,hostmem=256M,blob=true,venus=true`. El invitado expone
`/dev/dri/renderD128`; Mesa Venus 26.0.3 enumera el Apple M5 Pro. La sonda sin pantalla
`tools/research/venus_submit_probe.c` y la presentación X11 de `vkcube` pasaron. Además, el
`vkcube` x86-64 del rootfs se ejecutó invocando directamente FEX v3, cuyo ejecutable vivo tuvo la
huella `52dd0d29966fe71b71f6f1b042bdc2254494568261f65dd51d0bee3494d97761`; seleccionó Venus y
presentó visualmente sin detener el Steam de referencia. Evidencia visual privada:

```text
/private/tmp/regression-dxvk-linux/utm-lab/evidence/venus-vkcube-x11-20260730.png
/private/tmp/regression-dxvk-linux/utm-lab/evidence/venus-vkcube-x86-fex-v3-direct-20260730.png
/private/tmp/regression-dxvk-linux/utm-lab/evidence/steam-linux-login-venus-20260730.png
```

La captura directa del candidato tiene SHA-256
`92d100e1bd104920a400414149a77eb31cb0ad6cb95aaba829394370dfa1a9f2`.

El disco virtual se amplió con la VM detenida desde su tamaño anterior hasta 96 GiB; ext4 ocupa
91,9 GiB y mantiene unos 35,9 GiB disponibles. Antes de cambiarlo se creó un clon APFS completo:

```text
/Users/adrianpereradelgado/Library/Containers/com.utmapp.UTM/Data/Documents/
  Regression FLI Venus Lab Backups/before-expand-20260730-0847/
```

El recibo interno `evidence/storage-expand-20260730/` conserva geometría y comprobaciones del
filesystem. La VM dispone además de 4 GiB de zram volátil; no existe presión de memoria o disco
que explique el bloqueo del instalador.

La copia local del juego en ext4 está completa: `15.203.991.960` bytes, 153 ficheros y cero
enlaces simbólicos. `tools/research/fli_utm_lab.sh verify-game` comprueba su tamaño y estas
fronteras antes de cualquier lanzamiento:

```text
EACLauncher.exe
  e86f518b447a90790f8458bd7be36bc42ae3cdaf723e6b9efcdcea3b544fd95c
EasyAntiCheat/Settings.json
  604da8db104b1e4de245bbdf8fdb43cc71b9fa902975f7168f96974e98c85cfe
```

La biblioteca de Steam contiene `common/FANTASY LIFE i` enlazado hacia esa copia aislada; el
manifiesto, la propiedad y el estado de instalación los creó y validó el propio cliente oficial.
La primera instalación oficial no podía progresar porque los 214 nodos de la copia aislada eran
`root:root`; Steam podía leerlos, pero no escribirlos ni verificarlos. El comando
`prepare-steam-library` exige Steam/FEX en reposo, rechaza propietarios mezclados, conserva
propietarios y hashes críticos antes/después y cambia únicamente esa copia a la cuenta local del
laboratorio. El recibo privado es
`evidence/steam-library-ownership-2993780-20260730-095503/`; los hashes de EAC no cambiaron.

No se importó `appmanifest_2993780.acf`: el propio Steam oficial comprobó la licencia, creó el
manifiesto y verificó los archivos existentes. El resultado final es `StateFlags=4`, build
`21998011`; su huella SHA-256 es
`1486485c0eab4e5d36bb07f45ba9d38a13bc8bf9458ccb6e5e0bf11e423bd88f`. La asociación Proton fue
escrita por Steam solo para App ID `2993780`; su recibo está en
`evidence/steam-compat-tool-2993780-20260730-093229/`. El modo silencioso dejaba el modal de
instalación en un callback CEF sin crear tarea de contenido. La A/B `start-steam-system-visible`
mantiene igual FEX, biblioteca y sesión, elimina únicamente `-silent` y alcanzó el EULA. Su
recibo es `evidence/steam-install-system-visible-20260730-100921/`.

Ubuntu restringe los espacios de nombres de usuario mediante AppArmor. `bwrap` queda oculto tras
el intérprete `binfmt` de FEX y el perfil por ruta no se adjunta, por lo que pressure-vessel falla
al escribir `uid_map`. Solo dentro de esta VM desechable se usa temporalmente el mecanismo de un
arranque documentado por Ubuntu:

```text
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
```

No se persiste, no se aplica al host ni al backend macOS y se revierte antes de pausar con:

```text
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=1
```

El prefijo limpio previo al lanzamiento EAC está archivado en:

```text
/var/lib/regression-fli-arm-lab/official-valve/
  compatdata-fli-x86-fex-fsselector-v1-from-arm-prereqs-before-eac-launch.tar.zst
```

SHA-256 verificado:

```text
80127fb9d3fdc0b1a9bf2e89a07b72ae76c5fcf1d17a5588e235fa1e04cbd51a
```

Evidencias relevantes:

```text
evidence/logs-x86-fex-fs-gs-v2-direct-wine-seccomp-ab/
evidence/logs-fli-x86-fex-fs-gs-v2-needsseccomp-eac-runtime-xvfb/
evidence/logs-fli-x86-fex-fs-gs-v2-real-steam-ipc-anonymous/
evidence/logs-fli-x86-fex-fs-gs-v2-real-steam-anonymous-waitforexitandrun/
evidence/logs-fli-x86-fex-fs-gs-v2-real-steam-anonymous-waitforexitandrun-steamclient-trace/
evidence/logs-fli-x86-fex-fs-gs-preserve-base-v3-real-steam-anonymous-shared-home-20260730-001144/
/var/lib/regression-fli-utm/evidence/fli-auth-official-dxvk271-v2/
/var/lib/regression-fli-utm/evidence/d3d11-probe-dxvk1103-upstream-v2/
/var/lib/regression-fli-utm/evidence/steam-compat-tool-2993780-20260730-093229/
/var/lib/regression-fli-utm/evidence/steam-library-ownership-2993780-20260730-095503/
/var/lib/regression-fli-utm/evidence/steam-install-system-visible-20260730-100921/
/var/lib/regression-fli-utm/evidence/pause-eula-20260730-103158/
/var/lib/regression-fli-utm/evidence/official-install-complete-20260730-112540/
/var/lib/regression-fli-utm/evidence/official-manifest-v3-dxvk1103-run-20260730-113358/
```

El último directorio es el expediente decisivo del lanzamiento oficial. Contiene el estado
previo, capturas, ventana X11, procesos, resultado, log EAC y un log Steam saneado; sus ocho
artefactos pasan `sha256sum -c SHA256SUMS`. Permanece privado (`0700` para el directorio y
`0600` para los archivos) y no almacena credenciales ni identificadores de cuenta.

La última traza tiene huella de árbol
`3abc09b179669e65b52dca191bb61eb22a24bfe4cfc280b70e1dff430a2bb20d` sobre su manifiesto
`tree.sha256`. La traza v2 anterior conserva la huella
`b41785a71961ccfd856a9a072961e21273cd9d80e9877dfc10c7214f26173a47` como historia. Los
directorios de autenticación son privados, están fuera del repo y no deben exportarse. Nunca se
registran contenidos de `steam.token`, QR, contraseñas ni identificadores de cuenta.

## Ruta host nativa macOS arm64 — frontera reproducida

La VM no puede convertirse en la solución del juego porque EAC la rechaza explícitamente. Por
eso se abrió el expediente host nativo `76976A0F-0B95-4363-B5AA-90AF9D0747EB`, completamente
separado del runtime estable. La hipótesis
`5F211890-DC8E-43B8-80FA-64EB06E1F760` exige conservar sin cambios Steam Linux, Proton y EAC y
reemplazar únicamente la dependencia de hipervisor por una ejecución FEX nativa sobre macOS.

La fuente usada es el submódulo público FEX incluido por Proton en la revisión exacta
`a04b0241c2fe3911729842205cd8643981108aad`. El experimento
`8E6CA24A-9414-4534-8E48-2249CD205DA8` avanzó mediante puertas reproducibles, cada una con su
control:

1. `fex-a04b0241-darwin-core-stage1.patch` permite construir las 163 unidades de FEXCore como
   `libFEXCore.dylib` Mach-O arm64 y cargar la biblioteca bajo runtime endurecido.
2. `fex-a04b0241-darwin-map-jit-stage2.patch` añade `MAP_JIT` solo a asignaciones ejecutables. La
   sonda firmada con `allow-jit` escribe código arm64, cierra la ventana de escritura y devuelve
   `42`.
3. Las sondas de contexto, dispatcher y ELF cerraron la creación del contexto, el acceso JIT y
   el cargador `PT_INTERP`. Un `/usr/bin/true` de Fedora 43 y binarios oficiales de SteamRT
   ejecutan `ld-linux`/glibc x86-64 y terminan con código `0`.
4. El RootFS mínimo de Wine64 incorpora, con origen y SHA-256, `wine64` y `ntdll.so` oficiales de
   Proton 11, glibc 2.43 y `libgcc_s.so.1` oficial de SteamRT. La sonda traduce únicamente el
   subconjunto Linux observado; los sockets Unix y sus flags se convierten explícitamente y todo
   `connect` absoluto se resuelve dentro del RootFS privado. Las dos consultas a
   `/var/run/nscd/socket` devolvieron `ENOENT` confinado, sin alcanzar el host.
5. Sin `HOME`, Wine completaba NSS y alcanzaba un acceso huésped nulo sin syscall pendiente. No
   se parcheó la señal. La A/B v19 añadió solo `HOME=/home/regression`: desapareció la frontera
   nula, Wine escribió 10 bytes de versión y terminó con `exit_group(0)`.

El recibo v19 registra `main_completed=true`, `proton_component_executed=true`, 16 backpatches
desalineados atendidos y ninguna syscall desconocida. También conserva explícitamente
`proton_executed=false`, `steam_executed=false` y `eac_executed=false`; «componente oficial de
Proton» y «Proton completo» no se confunden.

Evidencia privada conservada:

```text
~/Library/Application Support/Regression/Research/
  fli-nonvm-host/official-eac-elf-header-v1/
  fli-fexcore-darwin-stage1-repro-v1/
  fli-fexcore-darwin-stage2-repro-v1/
  fli-fexcore-process-control-v58/
  fli-proton11-wine64-rootfs-glibc243-ntdll-v3/
  fli-fexcore-proton11-wine64-glibc243-ntdll-v19/
```

El recibo principal `process-probe.json` de v19 tiene SHA-256
`86aedcbd185897650a88e6b96372854a3ee4a1a312d6f77d8563be01df4fd5ca`; la huella del inventario
RootFS asociado es `6d43f6b40910fca0ab67b526697db42633a0e63b2c43371b30f2802a59795359`.
La reproducción stage 2 anterior conserva la huella
`0aa65bd81fb58528d36d9d5d75f75507d2f485088a2221f82b8ad7ec5d1fb4dd` como historia.

Estos resultados no son todavía Proton para macOS ni una ejecución de FANTASY LIFE i. La mitad
PE/Windows oficial de `cmd.exe` y su cierre estático de 15 módulos ya se materializó en un RootFS
nuevo. La consulta a
`/opt/proton/files/lib/wine/x86_64-windows/wine64.exe` fue solo una sonda de existencia de Wine,
no el siguiente binario requerido. La frontera real posterior es `execve(2)` sobre
`/opt/proton/files/lib/wine/i386-unix/wine-preloader`: un ELF Linux i386 estático. El código
público de Wine explica la selección: el primer cargador x86-64 cambia de forma deliberada al
cargador alternativo de 32 bits para conservar prefijos compatibles con WoW64. La siguiente A/B
debe capturar y clasificar su `argv` exacto antes de diseñar un salto de proceso; no se reenviará
un `execve` huésped al host ni se añadirá soporte ELF32 a ciegas. Steam, EAC, el juego, las
credenciales y la botella canónica permanecen fuera del experimento.

## Conclusión y siguiente vía legítima

La A/B oficial ya se completó y reprodujo `208`. No queda otra variable local legítima que
cambiar dentro de esa VM: ocultar su naturaleza, parchear el launcher, alterar EAC o falsear sus
respuestas sería una elusión y queda expresamente fuera del proyecto. La ruta activa es ahora el
host nativo no virtualizado descrito arriba. Ya ha cerrado cargador ELF, glibc y un componente
Wine64 oficial, pero todavía no ha ejecutado el orquestador Proton, Steam ni EAC.

La interpretación coincide con la documentación pública vigente: el
[soporte oficial de Epic](https://www.epicgames.com/help/c-202300000001639/c-202300000001736/easy-anti-cheat-eac-error-cannot-run-under-virtual-machine-a202300000085408)
indica que la interfaz cliente de EAC no admite actualmente máquinas virtuales, y
[Steamworks](https://partner.steamgames.com/doc/steamhardware/proton?l=spanish) aclara que el
soporte EAC de Proton se habilita por compilación y que los fallos restantes deben escalarse al
proveedor y a Valve. Ninguna de las dos fuentes ofrece una corrección del lado del jugador.

El expediente solo se reabre si ocurre una de estas condiciones verificables:

1. LEVEL5/Epic habilitan oficialmente este deployment para el entorno virtualizado empleado o
   publican una actualización de EAC que cambie el resultado.
2. Valve publica una ruta macOS/ARM no virtualizada y compatible con el módulo oficial del juego.
3. Regression desarrolla una ejecución ARM no-VM que conserve Steam y EAC oficiales; antes de
   probar el juego deberá superar sondas independientes de ABI, gráficos y aislamiento.

Si alguna condición cambia, la primera prueba repetirá el App ID oficial sin modificar EAC y
comparará su huella con este baseline. Solo si aparece `NFL1-Win64-Shipping.exe` se abrirá la
matriz de render, cursor/entrada, opciones, persistencia, gameplay, foco, estabilidad y cierre.

## Estado que debe quedar al pausar

Antes de apagar o devolver la VM a su baseline:

- detener únicamente Steam Linux/Xvfb/FEX del laboratorio;
- conservar `/usr/bin/FEX` intacto y detener el runtime candidato autocontenido;
- eliminar los overrides propios de `/run/binfmt.d` y verificar que FEX x86/x86-64 vuelven a
  `/usr/bin/FEX`;
- restaurar el handler Rosetta que existía antes del experimento cuando se use el laboratorio
  Lima original;
- devolver `kernel.apparmor_restrict_unprivileged_userns=1`;
- comprobar que no quedan procesos Wine/EAC huérfanos;
- ejecutar las pruebas Swift y `build/verify-protected-state.sh --include-bottle` en Regression.

El expediente queda pausado por el bloqueo externo concreto `208 Cannot run under Virtual
Machine`, reproducido mediante la instalación y el lanzamiento oficiales. Esta pausa conserva
todos los resultados negativos y no declara el juego compatible. El 30 de julio Steam salió por
su mecanismo oficial, no quedaron procesos Steam/FEX/EAC, ambos handlers x86 volvieron a
`/usr/bin/FEX` y AppArmor userns quedó restaurado a `1`. El manifiesto oficial permanece completo,
los hashes EAC siguen intactos y el expediente decisivo pasa su índice SHA-256.

En el checkpoint host nativo del 30 de julio no quedó ninguna compilación ni sonda en ejecución.
La VM Venus se detuvo mediante `systemctl poweroff` después de verificar: Steam parado, handlers
x86/x86-64 restaurados a `/usr/bin/FEX`, AppArmor userns en `1`, manifiesto oficial
`StateFlags=4`, 153 archivos, cero enlaces y los dos hashes EAC sin cambios. La reanudación ya no
parte de la antigua sonda de contexto: el control v58 y el candidato v19 cerraron Wine64 con
código `0`. El siguiente experimento pertenece al laboratorio macOS nativo y debe crear un nuevo
RootFS que añada únicamente la mitad `x86_64-windows` oficial de Wine y su cierre comprobado. No
se arranca la VM ni se introduce todavía Steam, EAC o el juego.

### Checkpoint host nativo — 31 de julio de 2026, 05:33 WEST

La investigación avanzó hasta ejecutar el `wineserver` x86-64 oficial de Proton 11 sobre el
ayudante FEXCore macOS ARM separado. El `session_mapping` ya supera, con formas exactas y dentro
del arena privada, `pwrite64(0x144000)`, `ftruncate(0x144000)` y
`mmap(MAP_SHARED, 0x144000)`. Después pasan dos `mmap` anónimos de 135168 bytes y `getpid()`
devuelve el PID real del ayudante creado por `posix_spawn`. El último expediente semánticamente
válido e íntegro es:

```text
~/Library/Application Support/Regression/Research/
  fli-posix-spawn-fex-wineserver-v61e-measure-setpriority-signed/
```

Ese run localizó la siguiente frontera exacta como syscall x86-64 141:
`setpriority(PRIO_PROCESS, who=getpid(), nice=-20)`. El tercer argumento llega al handler
zero-extended y se debe reinterpretar como `int32_t`; su valor confirmado es `-20`. Las A/B
`v62`, `v62b`, `v62c` y `v62d` quedan expresamente descartadas: durante ellas se identificó por
error la syscall 141 como `getpriority` (que en realidad es la 140). La semántica incorrecta se
revirtió antes de cualquier promoción y esos directorios solo conservan historia negativa.

El árbol de trabajo contiene ahora un candidato **todavía no validado** para la forma exacta
`setpriority(..., -20)`. Invoca la operación real únicamente sobre el PID del propio ayudante y
traduce el rechazo de privilegios del host a `EACCES` Linux; no simula capacidades. Al reanudar,
la primera y única acción experimental debe ser una A/B fresca `v63` con
`--diagnostic-post-session-syscall-limit 7`. Solo si confirma `setpriority_call_count=1`, PID
coincidente, nice `-20`, rechazo esperado o éxito host real, ausencia de syscall desconocida y
todos los hashes íntegros, se avanzará al límite 8 para medir el probable restablecimiento a
nice `0`. No se debe retomar desde ninguno de los runs v62 descartados.

Al pausar no quedó ningún ayudante FEXCore/wineserver efímero. La VM
`Regression FLI Venus Lab` se detuvo limpiamente mediante la solicitud de apagado de `utmctl` y
su estado final fue `stopped`. Regression estable, Steam, EAC, las botellas y los perfiles
blindados no fueron ejecutados ni modificados en esta etapa. Steam, el orquestador Proton, EAC y
FANTASY LIFE i todavía no han entrado por la ruta macOS nativa; no se declara compatibilidad.

### Checkpoint host nativo — 31 de julio de 2026, frontera v161

El ABI stage 3 ya coincide entre el ayudante y `libFEXCore.dylib`. La A/B v156 cerró el
`wineserver` oficial de Proton 11 con `exit_group(0)` después de entregar al cliente controlado
el payload 931 y un descriptor mediante `SCM_RIGHTS`. Sobre esa base, v161 arrancó el mismo
`wineserver --foreground` en un ayudante FEX separado y compartió únicamente el RootFS y
`HOME=/home/regression` con `wine-preloader` y `cmd.exe` oficiales.

El servidor publicó correctamente el socket privado
`/tmp/.wine-501/server-100000e-1f6f348/socket`. El cliente realizó tres `connect`: los dos
primeros fueron las consultas NSS confinadas y esperadamente ausentes; el tercero dejó de entrar
por `clone3`/`execve`, pero fue rechazado por el traductor antes de invocar `connect(2)` de macOS
con `EINVAL`. `connect_rootfs_confined_count=2` demuestra que esa tercera ruta no llegó a
`ResolveGuestPath`. La siguiente syscall observada fue una forma aún no admitida de
`prlimit64`; no se debe tocar hasta cerrar primero el `connect`.

Evidencia preservada:

```text
~/Library/Application Support/Regression/Research/
  fli-proton11-combined-rootfs-v161-wineserver-prefix-plus-pe/
  fli-proton11-combined-v161-cmd/
/private/tmp/regression-fli-v161-wineserver-wrapper.log
```

Antes de pausar se añadió únicamente telemetría escalar al handler de `connect`: descriptor,
familia, longitudes, clase y huella de ruta, longitud host, errores host/Linux y motivo exacto.
No cambia ningún retorno ni traducción. El ayudante recompiló y pasó su fixture x86-64 controlado
en `/private/tmp/regression-fli-connect-telemetry-control-v162/`. **v162 no se ejecutó**. Al
reanudar se debe crear un RootFS nuevo desde el baseline v99, añadir el cierre PE exacto de v60 y
repetir la misma A/B con el servidor en otro ayudante. Solo después de medir si la tercera forma
es vacía, abstracta o relativa se diseñará una corrección de una variable.

Al cerrar este checkpoint no quedó ningún proceso del laboratorio, `wine-preloader`, FEXCore ni
`wineserver` oficial de Proton. Tampoco había proceso QEMU/UTM activo. El `wineserver` de
CrossOver que pudiera pertenecer a la sesión normal del usuario queda expresamente fuera del
árbol de procesos propio y no se termina. Regression estable, Steam, EAC, botellas y perfiles
siguen intactos; no se declara que Proton completo, EAC o FANTASY LIFE i se hayan ejecutado en
macOS.

### Checkpoint host nativo — 1 de agosto de 2026, frontera v270

Las iteraciones v162–v265 cerraron de forma incremental el transporte oficial Wine entre
cliente y `wineserver` y las omisiones de traducción de memoria baja en el JIT. El candidato
v265 conserva 52/52 peticiones cliente, 81 respuestas, 29/29 `writev`, 3/3 `create_file` y un
`wineserver` que termina con código `0`. La traza posterior demostró que la siguiente caída no
era otra forma IPC: `ntdll.so` necesita dos vistas RW altas y Wine intenta reservar además su
intervalo superior convencional. El arena host privado de FEXCore solo ofrece aproximadamente
4,5 GiB y no puede materializar esas direcciones literalmente en macOS.

v270 añade una tabla acotada, desactivada por defecto, que desacopla dirección lógica huésped y
dirección host. La prueba sintética configuró dos intervalos antes de `InitCore`, escribió y leyó
`0x100000270` y `0x7ffffff30270` desde páginas host ordinarias y devolvió la suma esperada. Las
tres puertas anteriores (`execute-one`, bias bajo y página dispersa) siguieron pasando. Después
se regeneró el parche completo de etapa 3 y se reconstruyó desde la revisión pública exacta
`a04b0241c2fe3911729842205cd8643981108aad`; pasaron también carga, allocator, contexto,
compilación, linking, invalidación directa e indirecta, ELF mínimo y bootstrap PT_INTERP.

Evidencia y rollback:

```text
backups/fli-v270-sparse-high-regions-prechange-20260801-064638/
~/Library/Application Support/Regression/Research/
  fli-fexcore-darwin-v270-sparse-high-regions-repro/
```

El parche de etapa 3 tiene SHA-256
`81c35111162af5a87841252987dc5048ebfdac281e45e1c908dbf3ed30571ee4`; la biblioteca de la
reconstrucción canónica tiene SHA-256
`f6b44f227068dbc9b701e67591c4af8b0fd44cb64f22a5f203a86fd94063c91a`.

La prueba todavía no implementa el ciclo de vida completo de memoria virtual: faltan
`mprotect`, `munmap` y la traducción inversa de fallos host→huésped para esas regiones. Por eso
v270 no se ha aplicado aún a Wine y no ha ejecutado el orquestador Proton, Steam, EAC ni el
juego. La siguiente A/B seguirá siendo sintética y añadirá solo esas semánticas; después se
creará un RootFS Wine nuevo. Esta frontera no cambia la conclusión de compatibilidad: FANTASY
LIFE i continúa sin certificar en Regression.

### Checkpoint host nativo — 1 de agosto de 2026, frontera v271

v271 cerró primero el contrato bidireccional que necesita el ciclo de vida posterior. El
contexto ahora puede traducir huésped→host y host→huésped para el bias bajo, la página dispersa
y dos regiones altas acotadas. La página redirigida gana sobre el shadow lineal en ambos
sentidos. La configuración rechaza solapamientos lógicos y host, direcciones no mapeadas y
punteros de salida nulos; un rechazo no altera el valor de salida.

La nueva puerta recorrió exactamente `0x1e2f70`, `0x7ffe0270`, `0x100000270` y
`0x7ffffff30270`, recuperó las cuatro direcciones huésped originales y pasó sin crear hilo,
decodificar x86 ni ejecutar código huésped. Antes de aceptarla se repitieron las cuatro puertas
v270. Después se regeneró el parche acumulado de etapa 3 y una reconstrucción virgen desde FEX
público `a04b0241c2fe3911729842205cd8643981108aad` superó toda la matriz.

Evidencia y rollback:

```text
backups/fli-v271-bidirectional-address-translation-prechange-20260801-071452/
~/Library/Application Support/Regression/Research/
  fli-fexcore-darwin-v271-bidirectional-address-translation-repro/
```

El parche de etapa 3 tiene SHA-256
`06c2402ad010f736cd88cfc2d4bef50b8642dd278065148f01e2d7f7911d7c03`; la dylib reproducida
tiene SHA-256 `680b62d7bb657817144958d2aab5800759e89953f7b59239d7caab3c1c8a5fa1`.

Esta API aún describe mapas estáticos. No registra ni retira regiones durante la vida real de
Wine, no aplica `mprotect`/`munmap` y todavía no convierte un fallo host en un evento huésped.
La siguiente A/B seguirá siendo sintética y añadirá únicamente registro, protección y limpieza
sin traducciones obsoletas; después se validará el reporte inverso de fallos. Solo entonces se
creará un RootFS Wine nuevo. Proton, Steam, EAC y FANTASY LIFE i no se han ejecutado todavía por
esta ruta y el juego continúa sin certificar en Regression.

### Checkpoint host nativo — 1 de agosto de 2026, frontera v272

v272 cerró el ciclo de vida sintético de esas regiones sin modificar otra vez FEXCore. El JIT de
v271 ya carga `GuestBase`, `Size` y `HostBase` desde la tabla del contexto en tiempo de ejecución;
la nueva puerta demuestra ahora esa propiedad en vez de inferirla del código. Compiló una sola
carga desde `0x100000270`, leyó `0x11223344` desde el backing A, sustituyó la misma región por B
con el hilo detenido, protegió A y volvió a ejecutar sin llamar a `CompileRIP`. El host code fue
idéntico antes y después y la segunda lectura devolvió `0x55667788` desde B.

Después vació la tabla, rechazó las traducciones huésped→host y host→huésped obsoletas sin
modificar las variables de salida, protegió B y desmapeó ambos backings. Una comprobación final
volvió a rechazar la dirección lógica ya retirada. El primer intento de la sonda quedó como
negativo de infraestructura: un helper de `LookupCache` requería un símbolo interno no exportado
por la dylib. Se sustituyó solo esa lectura por la tabla compartida bajo su read lock; los cinco
gates heredados pasaron antes de aceptar la puerta nueva.

La reconstrucción canónica desde FEX público
`a04b0241c2fe3911729842205cd8643981108aad` superó toda la matriz, incluida v272. El parche de
etapa 3 no cambió y conserva SHA-256
`06c2402ad010f736cd88cfc2d4bef50b8642dd278065148f01e2d7f7911d7c03`: v272 es una nueva
garantía reproducible del contrato existente, no otro comportamiento añadido a ciegas.

Evidencia y rollback:

```text
backups/fli-v272-region-lifecycle-prechange-20260801-073825/
~/Library/Application Support/Regression/Research/
  fli-fexcore-darwin-v272-region-lifecycle-repro/
```

La dylib reconstruida tiene SHA-256
`b4049ce43a7b9d4cdcdde176e8d467ac38066783819658fb18a0dabce1f445d8`; el índice de evidencia,
`59362e0193e83cdd5db66f68d3da5f0880e969903bbbf08755bdfa8da07fad5a`.

Todavía falta demostrar que un fallo host dentro de una región puede atribuirse de forma segura
a la dirección huésped correspondiente y entregarse por la ruta de señales sin confundir el
shadow bajo. La siguiente A/B seguirá siendo sintética y cambiará únicamente esa dimensión. Solo
si pasa se creará un RootFS Wine nuevo. Proton, Steam, EAC y FANTASY LIFE i no se han ejecutado
por esta ruta y el juego continúa sin certificar en Regression.

### Checkpoint host nativo — 1 de agosto de 2026, frontera v273

v273 cerró también la atribución inversa controlada sin modificar FEXCore ni el parche de etapa
3. La sonda registró una región lógica desde `0x100000000`, compiló una única carga desde
`0x100000270` y, después de compilar, protegió su backing host con `PROT_NONE`. La ejecución
produjo exactamente un `SIGBUS` de macOS (`signal=10`, `code=1`) con el PC dentro del bloque JIT
y `si_addr` exactamente en el backing protegido más `0x270`.

El handler local tradujo esa dirección host de vuelta a `0x100000270` mediante la API pública de
v271 y `RestoreRIPFromHostPC` recuperó exactamente el RIP huésped de la instrucción que falló
(`GuestRIP + 10`). Para no convertir la prueba en un crash, redirigió únicamente esa señal
esperada al stub `GuestSignal_SIGSEGV` de FEX. `ExecuteThread` retornó, se restauraron los
handlers originales, se vació la tabla, se devolvió el backing a lectura/escritura y se comprobó
que ya no quedaba ninguna traducción residual.

Los seis gates heredados pasaron antes del cambio; después pasaron otra vez junto con la puerta
nueva. Finalmente se reconstruyó todo desde la revisión pública exacta de FEX
`a04b0241c2fe3911729842205cd8643981108aad` y volvió a pasar la matriz completa: loader,
allocator, contexto, init, compilación, ejecución, linking, invalidaciones, ELF x86-64,
`PT_INTERP`, shadow bajo, página dispersa, regiones altas, traducción bidireccional, ciclo de
vida y atribución del fallo.

Evidencia y rollback:

```text
backups/fli-v273-region-fault-attribution-prechange-20260801-075931/
~/Library/Application Support/Regression/Research/
  fli-fexcore-darwin-v273-prechange-inherited-gates/
  fli-fexcore-darwin-v273-region-fault-attribution/
  fli-fexcore-darwin-v273-region-fault-attribution-rerun-1/
  fli-fexcore-darwin-v273-region-fault-attribution-repro/
```

La dylib limpia v273 tiene SHA-256
`b84a4ea19d612b3877b86c7194314922cd357c4acd08fcc25f292582c4f4cbdf`; el índice del árbol de
evidencia, `739bc26471d505d8fc07d1607a36474d6dbffe73169de10ada575639f919808e`. El parche de etapa 3
permanece sin cambios con SHA-256
`06c2402ad010f736cd88cfc2d4bef50b8642dd278065148f01e2d7f7911d7c03`.

Esta es una prueba reproducible de atribución y recuperación, no una integración estable. La
siguiente frontera es aplicar el mismo contrato, una sola variable cada vez, a la mitad
PE/Windows oficial de Wine dentro de un RootFS nuevo. Proton, Steam, EAC y FANTASY LIFE i aún no
se han ejecutado por esta ruta nativa y el juego continúa sin certificar en Regression.
