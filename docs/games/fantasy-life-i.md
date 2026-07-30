# FANTASY LIFE i — expediente de compatibilidad EAC

## Estado actual

- **Steam App ID:** `2993780`
- **Cadena de arranque:** `GameBootstrapper.exe` (i386) → `EACLauncher.exe` (x86-64) →
  `Game/Binaries/Win64/NFL1-Win64-Shipping.exe`.
- **Easy Anti-Cheat product ID:** `1c57494d93e24d2091a070296910acec`.
- **Deployment ID:** `607d68cfa8b24890ba88764cc2879d57`.
- **Expediente local:** `CD577AEA-7058-4194-9948-8B7806207D6D`.
- **Estado:** investigación activa; **no está certificado ni blindado**.

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
credenciales o tokens. Steam reconoce la propiedad y ofrece instalar localmente los 14,39 GB.
El flujo oficial está detenido deliberadamente en el EULA del juego, que debe aceptar el usuario.

Este avance no equivale todavía a «Proton integrado en macOS» ni a compatibilidad funcional del
juego. Aunque ya existe una ruta gráfica real en la VM, sigue siendo obligatorio superar EAC y
completar render, entrada, opciones, gameplay, estabilidad y cierre antes de considerar cualquier
promoción.

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

Eso refuerza la hipótesis activa: no basta con que la biblioteca cargue; la sesión Steam host
debe existir y pertenecer legítimamente al usuario. Sin embargo, la pieza que GameNative emplea
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
| Instalación oficial visible | distribución | propiedad y 14,39 GB reconocidos; botón responde y alcanza el EULA | espera aceptación humana antes de crear manifiesto |

La ruta ARM directa quedó cerrada como resultado negativo. La hipótesis activa
`69B64100-BEDD-46CE-B931-00BFC1B152ED` prueba Proton x86-64 oficial sobre FEX y está vinculada al
experimento `BA3FA6CD-199B-4691-BBFA-02910F958CD4`.

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

La prueba que produjo `208` lanzó el conjunto oficial desde una copia verificada, pero aún no
desde un `appmanifest_2993780.acf` creado por el propio cliente Linux. Antes de atribuir el
resultado definitivamente a la política del proveedor, la siguiente puerta es completar la
instalación oficial y lanzar desde la biblioteca de esa misma sesión. Steam reconoce la propiedad
y el tamaño, y el modo visible ya alcanzó el EULA. El usuario debe aceptar ese acuerdo; después
Steam podrá crear su manifiesto y verificar la copia local sin importar estado de cuenta desde
otro backend.

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

La biblioteca de Steam contiene únicamente un enlace `common/FANTASY LIFE i` hacia esa copia.
La primera instalación oficial no podía progresar porque los 214 nodos de la copia aislada eran
`root:root`; Steam podía leerlos, pero no escribirlos ni verificarlos. El comando
`prepare-steam-library` exige Steam/FEX en reposo, rechaza propietarios mezclados, conserva
propietarios y hashes críticos antes/después y cambia únicamente esa copia a la cuenta local del
laboratorio. El recibo privado es
`evidence/steam-library-ownership-2993780-20260730-095503/`; los hashes de EAC no cambiaron.

No se ha importado `appmanifest_2993780.acf`: será el propio Steam oficial quien compruebe la
licencia, cree el manifiesto y verifique los archivos existentes. La asociación Proton fue
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
```

La última traza tiene huella de árbol
`3abc09b179669e65b52dca191bb61eb22a24bfe4cfc280b70e1dff430a2bb20d` sobre su manifiesto
`tree.sha256`. La traza v2 anterior conserva la huella
`b41785a71961ccfd856a9a072961e21273cd9d80e9877dfc10c7214f26173a47` como historia. Los
directorios de autenticación son privados, están fuera del repo y no deben exportarse. Nunca se
registran contenidos de `steam.token`, QR, contraseñas ni identificadores de cuenta.

## Próxima A/B legítima

1. Mantener abierto el EULA oficial y pedir al usuario que lo acepte; ningún agente lo acepta en
   su nombre.
2. Comprobar que Steam crea `appmanifest_2993780.acf`, inicia una tarea real de contenido y
   verifica la copia local en vez de descargar otra instalación completa. El comando de solo
   lectura `tools/research/fli_utm_lab.sh install-status` muestra únicamente campos técnicos
   permitidos y omite `LastOwner` y cualquier dato de cuenta.
3. Registrar la huella del manifiesto creado por Steam y de los archivos críticos después de la
   verificación; cualquier cambio inesperado invalida la copia y exige un nuevo baseline.
4. Detener Steam limpiamente y repetir con el runtime FS/GS v3 autocontenido. El orquestador
   conmutará los handlers FEX solo con Steam/FEX en reposo y conservará el mismo `HOME`
   autenticado sin inspeccionar sus contenidos privados.
5. Lanzar App ID `2993780` desde el cliente oficial usando exclusivamente
   `Regression FLI — Proton 11 + DXVK 1.10.3` y capturar proceso, logs y ventana.
6. Verificar si la ruta íntegramente creada por Steam reproduce `208` o alcanza
   `NFL1-Win64-Shipping.exe`. No ocultar la VM si vuelve a aparecer `208`.
7. Si EAC pasa, validar la presentación Venus sin cambiar simultáneamente otra dimensión.
8. Solo después: validar render, cursor/entrada, opciones, persistencia, gameplay,
   cambio de foco, estabilidad y cierre; después ejecutar la matriz de regresión protegida.

Si la prueba oficial vuelve a devolver `208`, se conservará como evidencia de una política
externa concreta. No se apilarán flags, no se modificará EAC y no se falseará la virtualización
para forzar un resultado.

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

El expediente puede pausarse con el bloqueo concreto «aceptación manual del EULA oficial en el
cliente Steam Linux aislado» o, después, con un rechazo `208` reproducido mediante la instalación
creada por Steam. Esa pausa conserva todos los resultados negativos y no declara el juego
compatible. La pausa del 30 de julio quedó con Steam/FEX detenidos, ambos handlers en
`/usr/bin/FEX`, AppArmor userns restaurado a `1`, manifiesto ausente y hashes EAC intactos. Su
recibo `RESUME.txt` tiene SHA-256
`b842c5c5038e936cd31fb53987c8dbe091e90b1e7aab68244b1e6c8db02c01e1`.
