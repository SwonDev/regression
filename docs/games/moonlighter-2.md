# Moonlighter 2: The Endless Vault — expediente de compatibilidad

## Estado blindado

- **Steam App ID:** `2350790`
- **Tecnología:** Unity
- **Backend:** motor propio de Regression, baseline general protegido
- **Perfil especial:** ninguno
- **Run perfecto:** `9E384BCC-18FA-4BE6-A879-8AA1E724E4C4`
- **Huella de configuración:** `a6601afa279218f05f11c770759898744ff0dcc0bc9a5527cefb19a1bc2331b9`
- **Huella de motor:** `28d3234281bc056e55cb93c13dbb06d50b53771467c154733de930ef70afa5d1`

Moonlighter 2 no necesitó una excepción. Forma parte de la matriz que impide promover una
modificación de Wine incompatible con Unity: mantenerlo en el baseline es una decisión explícita,
no la ausencia de diagnóstico.

## Matriz funcional exacta

La ejecución certificada verificó:

- menú e interfaz completa;
- carga de partida y gameplay real;
- movimiento del personaje y respuesta de entrada;
- pausa;
- acceso a opciones;
- cambio y restauración de idioma;
- cambio y restauración de vibración;
- salida desde el propio juego.

Evidencia privada principal:

```text
exact-run-menu.png                 2ca786cb50dd95a32d6aab66d3cdf9eca8418f0b5771e2a504124125dbc90e84
exact-run-gameplay.png             01720c25e739884ee8824350b5eacf82d0ac1dee4ecefe3b9a7e732ea5d1ccf1
exact-run-after-movement.png       e34d6817e0139031f6a5a3672d974f74d4a113a768bf600ad7b38e2a95938515
exact-run-pause.png                b479cbec31de87ee7ffa332c06f52710db04099f1458fd2a465338f9820ecd9a
exact-run-language-restored.png    250aafeae6a6a8a46968e74a789be1dbcf84dc51a0071d2ea413161bcc3e4709
exact-run-vibration-restored.png   8c6eee38e73b6426a01ab4ad8662c8f9c5c439d6a518fa794739330f6602b929
```

## Rollback y regla de no regresión

- Baseline de datos: `backups/three-games-baseline-20260808-224354/game-state/Moonlighter2/`.
- Evidencia: `work/three-games-20260808/evidence/moonlighter2/`.

No crear un perfil especial mientras el baseline siga pasando. Cualquier cambio de Wine, loader,
prefijo o DLL común debe volver a ejecutar Moonlighter 2 con gameplay y no limitarse al arranque.
Un representante auxiliar como `UnityCrashHandler64.exe` no decide el resultado de la sesión:
mandan la agrupación por run y la evidencia visual del proceso principal.
