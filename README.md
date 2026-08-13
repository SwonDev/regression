<p align="center">
  <img src="assets/icon/oficial/regression-squircle.png" width="132" alt="Icono de Regression">
</p>

<h1 align="center">Regression</h1>

<p align="center">
  <strong>Juegos de Windows en macOS, con perfiles aislados, reparación automática y evidencia real.</strong>
</p>

<p align="center">
  <a href="https://github.com/SwonDev/regression/releases/latest">
    <img src="https://img.shields.io/github/v/release/SwonDev/regression?style=for-the-badge&label=release&color=5E5CE6" alt="Última release">
  </a>
  <img src="https://img.shields.io/badge/macOS-14%2B-0A84FF?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 14 o posterior">
  <img src="https://img.shields.io/badge/Apple%20Silicon-required-1C1C1E?style=for-the-badge&logo=apple&logoColor=white" alt="Apple Silicon">
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/license-LGPL--2.1%2B-30D158?style=for-the-badge" alt="Licencia LGPL 2.1 o posterior">
  </a>
</p>

<p align="center">
  <a href="https://github.com/SwonDev/regression/releases/latest"><strong>Descargar</strong></a>
  ·
  <a href="#compatibilidad-certificada"><strong>Compatibilidad</strong></a>
  ·
  <a href="docs/README.md"><strong>Documentación</strong></a>
  ·
  <a href="#desarrollo"><strong>Desarrollo</strong></a>
</p>

---

Regression es una aplicación nativa de barra de menús que ejecuta Steam para Windows mediante
su propio motor de compatibilidad. Detecta el juego, prepara únicamente lo que necesita y mantiene
cada corrección aislada para no alterar los títulos que ya funcionan.

Regression es el único motor operativo. Su botella contiene la única carpeta física de juegos:
no comparte `steamapps`, credenciales, registro ni configuración con CrossOver, y no requiere
comprar, instalar o configurar otro producto de compatibilidad. Si detecta una biblioteca heredada,
la traslada dentro de la botella propia mediante renombres atómicos, sin copiar los juegos, y
mantiene rollback hasta que Steam y un juego se validan de forma explícita.

> [!IMPORTANT]
> Regression está en desarrollo activo y es un proyecto personal y educativo. La compatibilidad
> se certifica juego a juego mediante render, entrada, opciones y gameplay reales; un proceso que
> termina correctamente no se marca como compatible por sí solo.

## Instalación

```bash
curl --proto '=https' --tlsv1.2 -fsSL \
  https://github.com/SwonDev/regression/releases/latest/download/install_regression.sh | bash
```

El instalador es auditable, transaccional y conserva rollback. Antes de sustituir una instalación
comprueba la firma, el SHA-256 y el contenido del runtime descargado.

Después de la primera instalación, Regression detecta nuevas releases estables al arrancar y cada
seis horas. La actualización automática está activada por defecto: espera a que Steam de Regression
quede en reposo, descarga y verifica el instalador oficial, conserva botella y perfiles, reemplaza
la app de forma transaccional y la reinicia. Todo el flujo se controla desde **Mantenimiento**;
no hace falta volver a GitHub. [Detalles y garantías](docs/automatic-updates.md).

**Requisitos**

- Mac con Apple Silicon.
- macOS 14 o posterior.
- Rosetta 2; el instalador la prepara si falta.
- Cuenta gratuita de Apple Developer solo para los perfiles que necesiten GPTK/D3DMetal.

<details>
<summary><strong>Qué prepara automáticamente</strong></summary>

| Capa | Comportamiento |
|---|---|
| Runtime | Wine, DXMT, DXVK, MoltenVK, VC++/UCRT x86 y x64 |
| Steam | Instalación oficial de Valve y botella propia recuperable |
| Medios | Windows Media WMA/WMV/ASF cuando el contenido del juego lo exige |
| Entrada | SDL y Switch2Bridge para mandos compatibles |
| Fuentes | Source Han Sans y recursos redistribuibles permitidos |
| Apple GPTK | Verificación y reparación desde una copia autorizada del usuario; nunca se redistribuye |

Modos disponibles: `--check`, `--verify-release`, `--yes`, `--launch` y `--help`.

</details>

## Diseñado para reparar sin romper

<table>
  <tr>
    <td width="33%" valign="top">
      <h3>🧭 Autodetección</h3>
      Identifica ejecutable, motor, contenido multimedia y requisitos antes de lanzar.
    </td>
    <td width="33%" valign="top">
      <h3>🛠️ Autorreparación</h3>
      Verifica manifiestos y reconstruye componentes permitidos de forma transaccional.
    </td>
    <td width="33%" valign="top">
      <h3>🧩 Aislamiento</h3>
      Las recetas se activan por juego y proceso. No se convierten en variables globales.
    </td>
  </tr>
  <tr>
    <td width="33%" valign="top">
      <h3>✅ Evidencia real</h3>
      Render, entrada, opciones y gameplay deben confirmarse visualmente.
    </td>
    <td width="33%" valign="top">
      <h3>↩️ Rollback</h3>
      Los cambios protegidos generan backup y se revierten si falla una puerta.
    </td>
    <td width="33%" valign="top">
      <h3>🔒 Privacidad local</h3>
      Perfiles, logs saneados y verificaciones permanecen en el Mac del usuario.
    </td>
  </tr>
</table>

## Una utilidad nativa de macOS

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/menubar/previews/all-states-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="assets/menubar/previews/all-states-light.png">
    <img src="assets/menubar/previews/all-states-dark.png" width="460" alt="Estados visuales de Regression en la barra de menús">
  </picture>
</p>

Regression vive en la barra de menús, no en el Dock. La R comunica cuatro estados legibles:
preparado, trabajando, Steam activo y error. El popover reúne motor, biblioteca, juegos,
certificaciones, aprendizaje local y mantenimiento sin convertir la experiencia en un gestor
de botellas.

## Compatibilidad certificada

La siguiente lista procede del catálogo local versionado y de ejecuciones perfectas confirmadas.
Los expedientes públicos explican causa, receta, evidencia y regla de no regresión.

| Juego | Estado | Expediente |
|---|---|---|
| Cube World | Verificado perfecto | Catálogo integrado |
| FINAL FANTASY TACTICS — The Ivalice Chronicles | Verificado perfecto | Catálogo integrado |
| Grim Dawn | Verificado perfecto | [Ver expediente](docs/games/grim-dawn.md) |
| Clair Obscur: Expedition 33 | Verificado perfecto | [Ver expediente](docs/games/clair-obscur-expedition-33.md) |
| DragonSword: Awakening | Verificado perfecto | [Ver expediente](docs/games/dragonsword-awakening.md) |
| Hell Clock | Verificado perfecto | [Ver expediente](docs/games/hell-clock.md) |
| Heroes of Hammerwatch II | Verificado perfecto | [Ver expediente](docs/games/heroes-of-hammerwatch-2.md) |
| Secrets of Grindea | Verificado perfecto | [Ver expediente](docs/games/secrets-of-grindea.md) |
| Fields of Mistria | Verificado perfecto | [Ver expediente](docs/games/fields-of-mistria.md) |
| Titan Quest II | Verificado perfecto | [Ver expediente](docs/games/titan-quest-2.md) |
| Forsaken Isle | Verificado perfecto | [Ver expediente](docs/games/forsaken-isle.md) |
| RuneScape: Dragonwilds | Verificado perfecto | [Ver expediente](docs/games/dragonwilds.md) |
| Tinkerlands | Verificado perfecto | [Ver expediente](docs/games/tinkerlands.md) |
| Moonlighter 2: The Endless Vault | Verificado perfecto | [Ver expediente](docs/games/moonlighter-2.md) |
| Cross Blitz | Verificado perfecto | [Ver expediente](docs/games/cross-blitz.md) |
| Luminary Demo | Verificado perfecto | [Ver expediente](docs/games/luminary-demo.md) |
| Borderlands® 4 | Verificado perfecto | [Ver expediente](docs/games/borderlands-4.md) |

También forman parte de la matriz de regresión Steam/CEF, Palworld y la ruta D3D9. Moonlighter 2
es a la vez un juego certificado y el control Unity obligatorio para cambios comunes de Wine.

**Validados con incidencia conocida**

- [Dragon's Dogma 2](docs/games/dragons-dogma-2.md): letterbox 16:9 compartido por la referencia.
- [Rotwood](docs/games/rotwood.md): superficie 1512×870 dentro de la pantalla disponible.

**Investigación abierta**

- [FANTASY LIFE i](docs/games/fantasy-life-i.md): bloqueado por la política oficial de EAC en
  entornos virtualizados; no se elude ni se presenta como compatible.

## Cómo funciona

```mermaid
flowchart LR
    A["Juego de Steam"] --> B["Preflight de solo lectura"]
    B --> C["Router por ejecutable y contenido"]
    C --> D["Runtime general protegido"]
    C --> E["Perfil aislado"]
    C --> F["Componente autorreparable"]
    D --> G["Ejecución observada"]
    E --> G
    F --> G
    G --> H["Verificación visual"]
    H --> I["Perfil blindado"]
```

El runtime general permanece fijado. Una corrección solo se promociona cuando supera la matriz
del juego objetivo, Steam y los perfiles afectados. Las recetas se compilan y versionan; la base
de aprendizaje nunca ejecuta comandos almacenados.

## Componentes

| Área | Implementación |
|---|---|
| Aplicación | Swift 6, SwiftUI, Observation y AppKit donde macOS lo requiere |
| Compatibilidad | Wine x86-64 sobre Rosetta 2 |
| D3D11 | DXMT v0.72 con parche cross-process protegido |
| D3D9 | DXVK 1.10.3 |
| D3D12 | Perfil D3DMetal autorizado por juego cuando corresponde |
| Presentación | winemac, MoltenVK y perfiles OpenGL aislados |
| Datos | SQLite local con huellas de configuración, motor y evidencia |
| Distribución | Runtime recompilado para la ruta pública y asset verificado tras extraer |

## Documentación

| Quiero… | Documento |
|---|---|
| Entender el proyecto | [Índice de documentación](docs/README.md) |
| Conocer el protocolo de compatibilidad | [Investigación reproducible](docs/compatibility-research.md) |
| Revisar arquitectura, datos y privacidad | [Plataforma de compatibilidad](docs/compatibility-platform.md) |
| Entender autorreparación y evolución de runtimes | [Evolución tecnológica](docs/runtime-evolution.md) |
| Preparar una prueba segura | [Preflight y evidencia](docs/game-test-readiness.md) |
| Revisar la app nativa | [Auditoría nativa](docs/native-app-audit.md) |
| Consultar un juego | [Expedientes de juegos](docs/README.md#expedientes-de-juegos) |

Las reglas operativas para agentes y mantenedores viven en [`AGENTS.md`](AGENTS.md). El contrato
visual está en [`DESIGN.md`](DESIGN.md).

## Desarrollo

```bash
# Validación Swift
swift test
swift build -c release

# Estado protegido y botella
bash build/verify-protected-state.sh --include-bottle

# Empaquetado nativo
bash Scripts/package_regression.sh
codesign --verify --deep --strict Regression.app

# Verificación del asset que recibiría un Mac limpio
bash build/verify-release-asset.sh ASSET CHECKSUM VERSION
```

El verificador extrae el mismo tar que recibirá el usuario, audita dependencias, firmas,
redistribuibles y rutas, y ejecuta además un arranque mínimo de Wine. Un asset cuyo wrapper no
pueda localizar y cargar su `ntdll.so` se rechaza antes de poder publicarse o instalarse.

`Regression.app/` es el artefacto local de desarrollo y no debe aparecer como instalación. La
única app canónica es el bundle físico `/Applications/Regression.app`; el Wine público se
recompila para `/Applications/Regression.app/Contents/SharedSupport/wine-root`. Mover el bundle
sin recompilar rompe sus rutas horneadas. Antes de entregar una build, ejecuta
`bash build/verify-canonical-installation.sh` para comprobar firma, Spotlight y LaunchServices.

## Licencia y límites

El código propio se distribuye bajo [LGPL-2.1 o posterior](LICENSE). Las atribuciones y límites
de redistribución están documentados en [NOTICE.md](NOTICE.md).

- No se publican credenciales, botellas, saves ni datos locales.
- No se copian binarios propietarios de productos de comparación.
- GPTK/D3DMetal pertenece a Apple y solo se usa desde una instalación autorizada del usuario.
- Regression no está afiliado con Valve, Apple, CodeWeavers ni los estudios de los juegos.

---

<p align="center">
  <img src="assets/icon/oficial/regression-icon.svg" width="34" alt="">
  <br>
  <strong>Regression</strong><br>
  <sub>Compatibilidad medible. Reparaciones aisladas. Cero certificaciones por intuición.</sub>
</p>
