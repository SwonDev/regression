#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${REGRESSION_APP_PATH:-$ROOT/Regression.app}"
WINE_ROOT="$APP/Contents/SharedSupport/wine-root"
DEFAULT_BOTTLE="$HOME/Library/Application Support/Regression/Bottles/Steam"
INCLUDE_BOTTLE=false
BEFORE_DD2_PROMOTION=false
BEFORE_DRAGONSWORD_PROMOTION=false
BEFORE_HWR2_PROMOTION=false
BEFORE_TQ2_ROUTE_UNIFICATION=false
BEFORE_WINDOWS_MEDIA_PROMOTION=false
BEFORE_WINDOWS_MEDIA_LINK_FIX=false
BEFORE_THREE_GAMES_PROMOTION=false
BEFORE_THREE_GAMES_HARDENING=false
BEFORE_BORDERLANDS4_PROMOTION=false
BEFORE_BORDERLANDS4_PROCESS_ISOLATION=false
BEFORE_1_11_PROMOTION=false
RELEASE_1_11_DEVELOPMENT_CANDIDATE=false
RELEASE_1_12_DEVELOPMENT_CANDIDATE=false
CANDIDATE_1_12_2_BEFORE_RUNTIME_CONTROL_FIX=false

for argument in "$@"; do
    case "$argument" in
        --include-bottle)
            INCLUDE_BOTTLE=true
            ;;
        --before-dd2-promotion)
            BEFORE_DD2_PROMOTION=true
            ;;
        --before-dragonsword-promotion)
            BEFORE_DRAGONSWORD_PROMOTION=true
            ;;
        --before-hwr2-promotion)
            BEFORE_HWR2_PROMOTION=true
            ;;
        --before-tq2-route-unification)
            BEFORE_TQ2_ROUTE_UNIFICATION=true
            ;;
        --before-windows-media-promotion)
            BEFORE_WINDOWS_MEDIA_PROMOTION=true
            ;;
        --before-windows-media-link-fix)
            BEFORE_WINDOWS_MEDIA_LINK_FIX=true
            ;;
        --before-three-games-promotion)
            BEFORE_THREE_GAMES_PROMOTION=true
            ;;
        --before-three-games-hardening)
            BEFORE_THREE_GAMES_HARDENING=true
            ;;
        --before-borderlands4-promotion)
            BEFORE_BORDERLANDS4_PROMOTION=true
            ;;
        --before-borderlands4-process-isolation)
            BEFORE_BORDERLANDS4_PROCESS_ISOLATION=true
            ;;
        --before-1.11-promotion)
            BEFORE_1_11_PROMOTION=true
            ;;
        --release-1.11-development-candidate)
            RELEASE_1_11_DEVELOPMENT_CANDIDATE=true
            ;;
        --release-1.12-development-candidate)
            RELEASE_1_12_DEVELOPMENT_CANDIDATE=true
            ;;
        --candidate-1.12.2-before-runtime-control-fix)
            CANDIDATE_1_12_2_BEFORE_RUNTIME_CONTROL_FIX=true
            ;;
        *)
            echo "Uso: $0 [--include-bottle] [--before-dd2-promotion|--before-dragonsword-promotion|--before-hwr2-promotion|--before-tq2-route-unification|--before-windows-media-promotion|--before-windows-media-link-fix|--before-three-games-promotion|--before-three-games-hardening|--before-borderlands4-promotion|--before-borderlands4-process-isolation|--before-1.11-promotion|--release-1.11-development-candidate|--release-1.12-development-candidate|--candidate-1.12.2-before-runtime-control-fix]" >&2
            exit 64
            ;;
    esac
done

PROMOTION_BASELINES=0
$BEFORE_DD2_PROMOTION && PROMOTION_BASELINES=$((PROMOTION_BASELINES + 1))
$BEFORE_DRAGONSWORD_PROMOTION && PROMOTION_BASELINES=$((PROMOTION_BASELINES + 1))
$BEFORE_HWR2_PROMOTION && PROMOTION_BASELINES=$((PROMOTION_BASELINES + 1))
$BEFORE_TQ2_ROUTE_UNIFICATION && PROMOTION_BASELINES=$((PROMOTION_BASELINES + 1))
$BEFORE_WINDOWS_MEDIA_PROMOTION && PROMOTION_BASELINES=$((PROMOTION_BASELINES + 1))
$BEFORE_WINDOWS_MEDIA_LINK_FIX && PROMOTION_BASELINES=$((PROMOTION_BASELINES + 1))
$BEFORE_THREE_GAMES_PROMOTION && PROMOTION_BASELINES=$((PROMOTION_BASELINES + 1))
$BEFORE_THREE_GAMES_HARDENING && PROMOTION_BASELINES=$((PROMOTION_BASELINES + 1))
$BEFORE_BORDERLANDS4_PROMOTION && PROMOTION_BASELINES=$((PROMOTION_BASELINES + 1))
$BEFORE_BORDERLANDS4_PROCESS_ISOLATION && PROMOTION_BASELINES=$((PROMOTION_BASELINES + 1))
$BEFORE_1_11_PROMOTION && PROMOTION_BASELINES=$((PROMOTION_BASELINES + 1))
$RELEASE_1_11_DEVELOPMENT_CANDIDATE && PROMOTION_BASELINES=$((PROMOTION_BASELINES + 1))
$RELEASE_1_12_DEVELOPMENT_CANDIDATE && PROMOTION_BASELINES=$((PROMOTION_BASELINES + 1))
$CANDIDATE_1_12_2_BEFORE_RUNTIME_CONTROL_FIX && PROMOTION_BASELINES=$((PROMOTION_BASELINES + 1))
if (( PROMOTION_BASELINES > 1 )); then
    echo "ERROR: los modos de verificación protegida son mutuamente excluyentes." >&2
    exit 64
fi
TRANSITION_1_11=false
if $BEFORE_1_11_PROMOTION || $RELEASE_1_11_DEVELOPMENT_CANDIDATE; then
    TRANSITION_1_11=true
fi

verify_hash()
{
    local expected="$1"
    local relative_path="$2"
    local path="$APP/$relative_path"
    local actual

    [[ -f "$path" ]] || {
        echo "ERROR: falta el recurso protegido: $path" >&2
        exit 1
    }
    actual="$(shasum -a 256 "$path" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || {
        echo "ERROR: cambió el recurso protegido: $relative_path" >&2
        echo "Esperado: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    }
}

verify_bottle_hash()
{
    local expected="$1"
    local relative_path="$2"
    local bottle="${REGRESSION_BOTTLE_PATH:-$DEFAULT_BOTTLE}"
    local path="$bottle/$relative_path"
    local actual

    [[ -f "$path" ]] || {
        echo "ERROR: falta el recurso protegido de la botella: $path" >&2
        exit 1
    }
    actual="$(shasum -a 256 "$path" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || {
        echo "ERROR: cambió el recurso protegido de la botella: $relative_path" >&2
        echo "Esperado: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    }
}

verify_transition_hash()
{
    local development_hash="$1"
    local public_transition_hash="$2"
    local relative_path="$3"
    if $TRANSITION_1_11; then
        verify_hash "$public_transition_hash" "$relative_path"
    else
        verify_hash "$development_hash" "$relative_path"
    fi
}

verify_mode()
{
    local expected="$1"
    local relative_path="$2"
    local path="$APP/$relative_path"
    local actual

    [[ -f "$path" ]] || {
        echo "ERROR: falta el recurso protegido: $path" >&2
        exit 1
    }
    actual="$(stat -f '%Lp' "$path")"
    [[ "$actual" == "$expected" ]] || {
        echo "ERROR: modo inesperado en el recurso protegido: $relative_path" >&2
        echo "Esperado: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    }
}

normalized_macho_sha256()
{
    local path="$1"
    local require_signature="$2"
    local scratch digest status

    [[ -f "$path" && ! -L "$path" ]] || {
        echo "ERROR: falta el Mach-O que se debe normalizar: $path" >&2
        return 1
    }
    scratch="$(mktemp -d /private/tmp/regression-macho-authority.XXXXXX)"
    cp "$path" "$scratch/payload"
    if [[ "$require_signature" == "true" ]]; then
        codesign --verify --strict "$path" || {
            find "$scratch" -depth -delete
            return 1
        }
        codesign --remove-signature "$scratch/payload" || {
            find "$scratch" -depth -delete
            return 1
        }
    elif codesign --verify --strict "$scratch/payload" >/dev/null 2>&1; then
        codesign --remove-signature "$scratch/payload" || {
            find "$scratch" -depth -delete
            return 1
        }
    fi

    set +e
    digest="$(/usr/bin/python3 "$ROOT/build/normalized-macho-sha256.py" "$scratch/payload")"
    status=$?
    set -e
    find "$scratch" -depth -delete
    [[ $status -eq 0 && "$digest" =~ ^[0-9a-f]{64}$ ]] || {
        echo "ERROR: no se pudo normalizar la firma Mach-O: $path" >&2
        return 1
    }
    printf '%s\n' "$digest"
}

verify_release_1_12_development_runtime_authority()
{
    # Los hashes de ComponentHealth y verify-release-asset son post-strip y post-firma
    # ad hoc: no son bytes válidos para un bundle de desarrollo firmado con identidad Apple.
    # La raíz del builder se fija por sus hashes pre-firma medidos en
    # build/release-1.12.0/evidence/public-runtime-hashes.txt. El gate acredita la
    # identidad de cada Mach-O firmado frente al builder mediante su huella normalizada
    # y, de forma complementaria, conserva sus contratos semánticos observables.
    local runtime_build="${REGRESSION_1_12_DEVELOPMENT_RUNTIME_BUILD:-$ROOT/build/release-1.12.0/wine64-public}"
    local build_relative app_relative expected expected_normalized actual_normalized
    local -a runtime_entries=(
        "4e6822021df7a1147c109fd879c180049b2c1d7537d8eb7a11d379f6a72c0991:tools/wine/wine:bin/wine"
        "9e67095e59ff44d0a519d611037953de79d510b064bf79ea7d283d2251ae33a1:server/wineserver:bin/wineserver"
        "7954955be20e8b3ea7714ca62f3cd256ab867e43517b2edd6d96f2ec0b398bcc:loader/wine:lib/wine/x86_64-unix/wine"
        "18d0f87b09e5735a7c819844488234f9a0f25c8dc1cc144e0be80733e1604cdc:dlls/ntdll/ntdll.so:lib/wine/x86_64-unix/ntdll.so"
    )

    # El árbol de compilación pesa gigabytes y nunca se versiona, así que acaba
    # desapareciendo y con él la posibilidad de acreditar o publicar nada. La
    # evidencia versionada conserva, por binario, su hash en el builder y su
    # huella sin firma: con eso basta para acreditar el runtime instalado.
    local evidence="$ROOT/build/release-runtime-pins.txt"
    if [[ ! -d "$runtime_build" || -L "$runtime_build" ]]; then
        [[ -f "$evidence" ]] || {
            echo "ERROR: no hay builder sellado ($runtime_build) ni evidencia versionada" >&2
            echo "       genera la evidencia con build/refresh-release-pins.sh" >&2
            exit 1
        }
        local evidence_normalized actual_normalized app_relative_from_evidence
        while read -r _builder_sha builder_normalized _build_relative app_relative_from_evidence; do
            [[ "$_builder_sha" == \#* || -z "${app_relative_from_evidence:-}" ]] && continue
            actual_normalized="$(normalized_macho_sha256 \
                "$WINE_ROOT/$app_relative_from_evidence" true)" || exit 1
            [[ "$actual_normalized" == "$builder_normalized" ]] || {
                echo "ERROR: el runtime instalado no coincide con la evidencia del builder: $app_relative_from_evidence" >&2
                exit 1
            }
            verify_mode 755 "Contents/SharedSupport/wine-root/$app_relative_from_evidence"
        done < "$evidence"
        return 0
    fi
    for entry in "${runtime_entries[@]}"; do
        IFS=: read -r expected build_relative app_relative <<< "$entry"
        [[ -f "$runtime_build/$build_relative" && ! -L "$runtime_build/$build_relative" ]] || {
            echo "ERROR: falta el binario sellado del builder 1.12: $build_relative" >&2
            exit 1
        }
        actual="$(shasum -a 256 "$runtime_build/$build_relative" | awk '{print $1}')"
        [[ "$actual" == "$expected" ]] || {
            echo "ERROR: cambió el binario sellado del builder 1.12: $build_relative" >&2
            exit 1
        }
        verify_mode 755 "Contents/SharedSupport/wine-root/$app_relative"
        codesign --verify --strict "$WINE_ROOT/$app_relative" || {
            echo "ERROR: el runtime 1.12 del bundle no conserva una firma verificable: $app_relative" >&2
            exit 1
        }
        expected_normalized="$(normalized_macho_sha256 "$runtime_build/$build_relative" false)" || exit 1
        actual_normalized="$(normalized_macho_sha256 "$WINE_ROOT/$app_relative" true)" || exit 1
        [[ "$actual_normalized" == "$expected_normalized" ]] || {
            echo "ERROR: el runtime firmado no coincide con el builder 1.12: $app_relative" >&2
            exit 1
        }
    done

    # Estas sondas no acreditan identidad: la acreditación se cerró arriba con la
    # huella normalizada de los bytes Mach-O. Solo protegen contratos observables
    # que el launcher necesita conservar para Steam y los perfiles aislados.
    strings -a "$WINE_ROOT/bin/wine" | grep -F \
        '/Applications/Regression.app/Contents/SharedSupport/wine-root/bin' >/dev/null || {
        echo "ERROR: el wrapper Wine no conserva el prefijo público 1.12." >&2
        exit 1
    }
    for required in \
        'REGRESSION_BOOTSTRAP_REDIRECT_COUNT' \
        'REGRESSION_EXTERNAL_D3DMETAL_ROUTE_COUNT' \
        'REGRESSION_WINDOWS_MEDIA_PROFILE' \
        'REGRESSION_PROCESS_DLL_ISOLATION_ROUTE_COUNT' \
        'compiled-repair-activations-v2.tsv'
    do
        strings -a "$WINE_ROOT/lib/wine/x86_64-unix/ntdll.so" | grep -F "$required" >/dev/null || {
            echo "ERROR: ntdll.so no conserva el contrato 1.12: $required" >&2
            exit 1
        }
    done
    if strings -a "$WINE_ROOT/lib/wine/x86_64-unix/ntdll.so" \
        | grep -E 'REGRESSION_EXTERNAL_D3DMETAL_(EXECUTABLE|WINE_ROOT)' >/dev/null; then
        echo "ERROR: ntdll.so conserva la ruta GPTK genérica heredada." >&2
        exit 1
    fi
}

[[ -d "$WINE_ROOT" ]] || {
    echo "ERROR: falta el runtime propio en $WINE_ROOT" >&2
    exit 1
}

if $RELEASE_1_12_DEVELOPMENT_CANDIDATE || $CANDIDATE_1_12_2_BEFORE_RUNTIME_CONTROL_FIX; then
    if $CANDIDATE_1_12_2_BEFORE_RUNTIME_CONTROL_FIX; then
        expected_engine_hash="38be0b5fd0bed42e5467f9a61c5c972733898523eeac3e34e83eb5317efb3edf"
    else
        expected_engine_hash="c50138d424af649291c7906725ec24c799ca67124c956fd4ea7ec570ba810b0a"
    fi
    verify_hash "$expected_engine_hash" \
        "Contents/MacOS/regression-engine"
    verify_mode 755 "Contents/MacOS/regression-engine"
    verify_hash f6bcd552320e3713693d0a0bbf1af4932b573fc35798282c1724f2b52a688660 \
        "Contents/SharedSupport/bin/install-apple-gptk-component"
    verify_mode 755 "Contents/SharedSupport/bin/install-apple-gptk-component"
    verify_hash b1469e452c6ebe94b27fb64504c31f50e251c24ea571ab8eee32ae5015fd0d5f \
        "Contents/SharedSupport/bin/install-windows-media-component"
    verify_mode 755 "Contents/SharedSupport/bin/install-windows-media-component"
    verify_hash da8ba98d99d157f981ef3a2472dc9d74c9ce4673ef126bdd61851b9dd21dedb3 \
        "Contents/SharedSupport/components/windows-media/1/manifest.sha256"
    (
        cd "$APP/Contents/SharedSupport/components/windows-media/1"
        shasum -a 256 -c manifest.sha256 >/dev/null
    ) || {
        echo "ERROR: el payload Windows Media 1.12 no supera su manifiesto." >&2
        exit 1
    }
    verify_hash 884912891b7a3f5440a46b30b9241aa604e248fbbe578498058658e2293b00f4 \
        "Contents/SharedSupport/components/steam-bottle-baseline/1/manifest.sha256"
    (
        cd "$APP/Contents/SharedSupport/components/steam-bottle-baseline/1"
        shasum -a 256 -c manifest.sha256 >/dev/null
    ) || {
        echo "ERROR: la receta gráfica de botella 1.12 no supera su manifiesto." >&2
        exit 1
    }
    verify_release_1_12_development_runtime_authority
    codesign --verify --deep --strict "$APP"
    echo "Candidato de desarrollo 1.12 verificado: medios y runtime sellado."
    exit 0
fi

# Lanzador y módulos propios que protegen Steam, DXMT, entrada y routing por juego.
if $RELEASE_1_11_DEVELOPMENT_CANDIDATE; then
    verify_hash 0aa2c39d5476d8b5767d9a1979af5ecaf96f36648cbe15d376a761aad06e7ca4 \
        "Contents/MacOS/regression-engine"
elif $BEFORE_1_11_PROMOTION; then
    verify_hash ccd590e7e5d395757add0b561bf9fa76d54deb56c491706e28004259c0df913e \
        "Contents/MacOS/regression-engine"
elif $BEFORE_BORDERLANDS4_PROMOTION; then
    verify_hash 5b8398a2703838342c5d5df751cae2da60de8ddeec0aec19774271fa621f91cf \
        "Contents/MacOS/regression-engine"
elif $BEFORE_TQ2_ROUTE_UNIFICATION; then
    verify_hash 5d8f999827ae6cf8ccdf292e8bed4c388ca5120ac4778a305f0890d9a41cdbbc \
        "Contents/MacOS/regression-engine"
elif $BEFORE_WINDOWS_MEDIA_PROMOTION; then
    verify_hash fd4e3e7ca59926b7977c63d9400dfb44a156f0aeb96b222ee3eba2c57fab3e4e \
        "Contents/MacOS/regression-engine"
elif $BEFORE_THREE_GAMES_PROMOTION || $BEFORE_DD2_PROMOTION || \
     $BEFORE_DRAGONSWORD_PROMOTION || $BEFORE_HWR2_PROMOTION || \
     $BEFORE_WINDOWS_MEDIA_LINK_FIX; then
    verify_hash 5d99cae95a60c84b8bc9759736ed9e9bec1dafe9b9af8a8190f26c232781ec60 \
        "Contents/MacOS/regression-engine"
else
    verify_hash c50138d424af649291c7906725ec24c799ca67124c956fd4ea7ec570ba810b0a \
        "Contents/MacOS/regression-engine"
fi
if $RELEASE_1_11_DEVELOPMENT_CANDIDATE; then
    verify_hash 291bc4ecf61dc9c7efdebbe9e8e5737baff594ee4bfa626b90b1647a64333073 \
        "Contents/SharedSupport/bin/install-apple-gptk-component"
else
    verify_hash f6bcd552320e3713693d0a0bbf1af4932b573fc35798282c1724f2b52a688660 \
        "Contents/SharedSupport/bin/install-apple-gptk-component"
fi
if ! $BEFORE_WINDOWS_MEDIA_PROMOTION; then
    verify_hash b1469e452c6ebe94b27fb64504c31f50e251c24ea571ab8eee32ae5015fd0d5f \
        "Contents/SharedSupport/bin/install-windows-media-component"
    if $BEFORE_1_11_PROMOTION || $RELEASE_1_11_DEVELOPMENT_CANDIDATE; then
        verify_hash da8ba98d99d157f981ef3a2472dc9d74c9ce4673ef126bdd61851b9dd21dedb3 \
            "Contents/SharedSupport/components/windows-media/1/manifest.sha256"
    elif $BEFORE_WINDOWS_MEDIA_LINK_FIX; then
        verify_hash d93847ced54536cbaaf8ed7922537dfb043448e0168184375c552e774fe35199 \
            "Contents/SharedSupport/components/windows-media/1/manifest.sha256"
    else
        verify_hash da8ba98d99d157f981ef3a2472dc9d74c9ce4673ef126bdd61851b9dd21dedb3 \
            "Contents/SharedSupport/components/windows-media/1/manifest.sha256"
    fi
    (
        cd "$APP/Contents/SharedSupport/components/windows-media/1"
        shasum -a 256 -c manifest.sha256 >/dev/null
    ) || {
        echo "ERROR: el payload protegido Windows Media no supera su manifiesto." >&2
        exit 1
    }
fi
if $RELEASE_1_11_DEVELOPMENT_CANDIDATE; then
    verify_hash "${REGRESSION_1_11_DEVELOPMENT_NTDLL_SHA256:-PENDING_1_11_NTDLL_SHA256}" "Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
elif $BEFORE_1_11_PROMOTION; then
    verify_hash 25a02aedaf914ee997cabd82c538d1b139b55d342d9c9c27c149a443ab406b2b "Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
elif $BEFORE_BORDERLANDS4_PROCESS_ISOLATION; then
    verify_hash 788a3fc9e19be0c7b8de7b1ce8ba78ceabcd25075ab1008172c17ce0e5d80346 "Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
elif $BEFORE_BORDERLANDS4_PROMOTION; then
    verify_hash 7d8ca564e18a75776acf8a4ea864b8b51f09684de12058c08cdfad1b26aa16b9 "Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
elif $BEFORE_DD2_PROMOTION; then
    verify_hash 2cd0f030fd0b92bbf17308021d23b2a2fede6ab02d528c44c03753dfcb049c97 "Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
elif $BEFORE_DRAGONSWORD_PROMOTION; then
    verify_hash 9e37f4a1c4c163909b7bc26b2a38b6408f02e261ddbf079b9608bc884b65f67d "Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
elif $BEFORE_HWR2_PROMOTION; then
    verify_hash 2a446467a9faa0885f350d096fb6424c92f62201b733f974150c931e3a535a6a "Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
elif $BEFORE_WINDOWS_MEDIA_PROMOTION; then
    verify_hash adb97ddb229a7e20b1cac89b88ba81cfd9c9871c801b97dc50a596f0c5e2f113 "Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
elif $BEFORE_THREE_GAMES_PROMOTION || $BEFORE_TQ2_ROUTE_UNIFICATION || \
     $BEFORE_WINDOWS_MEDIA_LINK_FIX; then
    verify_hash 9e3eb235bbe60a06bd2da4fe0199be8370c1beb02438c9a98a9a0e0d7ff3014c "Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
elif $BEFORE_THREE_GAMES_HARDENING; then
    verify_hash bf4f25e96883150e955f4465a5a15cbd6adaf0f152a8e1239004486dfbf2b81a "Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
else
    verify_hash a91d345dad3cbfacb5d20f862754de0eabf0e1b0a447bab729f3149fe334d942 "Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
fi

DRAGONSWORD_PROFILE="$WINE_ROOT/lib/profiles/dragonsword"
if $BEFORE_DD2_PROMOTION || $BEFORE_DRAGONSWORD_PROMOTION; then
    [[ ! -e "$DRAGONSWORD_PROFILE" && ! -L "$DRAGONSWORD_PROFILE" ]] || {
        echo "ERROR: el baseline previo ya contiene un perfil DragonSword inesperado." >&2
        exit 1
    }
else
    [[ -L "$DRAGONSWORD_PROFILE" &&
       "$(readlink "$DRAGONSWORD_PROFILE")" == "../apple_gptk/wine" ]] || {
        echo "ERROR: el perfil protegido de DragonSword ya no apunta al runtime Apple interno." >&2
        exit 1
    }
fi

HWR2_PROFILE="$WINE_ROOT/lib/profiles/heroes-hammerwatch-2"
if $BEFORE_DD2_PROMOTION || $BEFORE_DRAGONSWORD_PROMOTION || $BEFORE_HWR2_PROMOTION; then
    [[ ! -e "$HWR2_PROFILE" && ! -L "$HWR2_PROFILE" ]] || {
        echo "ERROR: el baseline previo ya contiene un perfil Heroes of Hammerwatch II inesperado." >&2
        exit 1
    }
else
    verify_transition_hash \
        2e441e71c00738b7434f7161648cb5c0e78f63a9ae8f3ceefa6ab8100b107c67 \
        ef3217d35cbc67701ba01b5fa82d082093ef5e734d41177c0d8f09dd28d62359 \
        "Contents/SharedSupport/wine-root/lib/profiles/heroes-hammerwatch-2/x86_64-unix/winemac.so"
fi
verify_transition_hash 44b1379db1b9e3472d1746830eddd88718dbbc761de2e406d45b8be198593ef3 885c0421bfe30600bae9df83961b0fcbb5b9ccd1c02e7b071ce213ff2522e34a "Contents/SharedSupport/wine-root/lib/wine/x86_64-windows/ntdll.dll"
verify_transition_hash 3d2b085b1dce4db5615a2a95d96860b644e1bfd4c907d0a68d177d02bd2010e8 7b580e19eb4fce14b5730cd2835c5204dc2622ce0fc4f33b68b0155864477667 "Contents/SharedSupport/wine-root/lib/wine/i386-windows/ntdll.dll"
verify_transition_hash e2d3d63343702678441b4e28d9278f433fae543c460dd2e651ca1e399695e577 978c2fe766d06db1d52abd86f96674988caee93ac587951a951f994032e1fb46 "Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/winemac.so"
verify_transition_hash da91ec701a18e97c0c3cd943d383ef996092c11d74983876fd44c90b03d5e5b1 e921d454fbc67a40addb2e8e8e795f9d5274062b731c31a6280403850be687eb "Contents/SharedSupport/wine-root/lib/wine/x86_64-windows/winemac.drv"
verify_transition_hash aaf38489b18bfeb967b7e6298510b46973ed79f516441b7fd74c95a3cf6b15ec 972000e02f63be8f84d414108d2f6aa5edd8e924111d1d58a07b8fa1b1c91060 "Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/winemetal.so"
verify_hash 87ed91e86f1f4620f5229b7a0d4f1f8c5436a56088e8d4692201fe0c7d5b0deb "Contents/SharedSupport/wine-root/lib/wine/x86_64-windows/d3d10core.dll"
verify_hash e6209af3a04947504af1f12b4533eded103687841197cff45a92d1a5f916c0a8 "Contents/SharedSupport/wine-root/lib/wine/x86_64-windows/d3d11.dll"
verify_hash 25f74dafc3ebaf77ddc5a7b32d933853462c303a2636399860e80937cda82941 "Contents/SharedSupport/wine-root/lib/wine/x86_64-windows/dxgi.dll"

# Perfil local Apple GPTK de Grim Dawn. Se verifica, nunca se redistribuye.
verify_transition_hash c999c40698b7fc23c864165fb1364e6a40a8572469775947845afd42f4dfc9e7 18995adb10bed163b7f58ab184c747b1ae6447043292d3497a515bc32e5972b5 "Contents/SharedSupport/wine-root/lib/apple_gptk/wine/x86_64-windows/atidxx64.dll"
verify_transition_hash 7c2bfeb66b18e3ec10c3ee92c9d42f4e3123692d568d14c831aec1a13aa03f79 13a621833929d7ced7761d0cf9f9b57765345633dfb83161c2735e9cfb57b0f5 "Contents/SharedSupport/wine-root/lib/apple_gptk/wine/x86_64-windows/d3d11.dll"
verify_transition_hash bbda1c4e94ee70255c528c5689b28333ca9bece2d755ede7c4197977a534704f dca51fb33c5d79d36dae95131205b96c837db5c2579d0bfd5fcf3d15e887b324 "Contents/SharedSupport/wine-root/lib/apple_gptk/wine/x86_64-windows/d3d12.dll"
verify_transition_hash 1b1f2d80349e043e6c628b515ba6b44478a1209c504e6c9f3dae4a9d1b06d561 5e1d256b455f744979092f901a0baeb0053ab291f53e0f6b65f5354043b56d57 "Contents/SharedSupport/wine-root/lib/apple_gptk/wine/x86_64-windows/dxgi.dll"
if $TRANSITION_1_11; then
    for omitted_apple_module in nvapi64.dll nvngx.dll; do
        [[ ! -e "$WINE_ROOT/lib/apple_gptk/wine/x86_64-windows/$omitted_apple_module" &&
           ! -L "$WINE_ROOT/lib/apple_gptk/wine/x86_64-windows/$omitted_apple_module" ]] || {
            echo "ERROR: el baseline público contiene un módulo Apple inesperado: $omitted_apple_module" >&2
            exit 1
        }
    done
else
    verify_hash f073fc2377b305380bcd8c228394e48abe1caf09116e12875cb656774a14b4dc "Contents/SharedSupport/wine-root/lib/apple_gptk/wine/x86_64-windows/nvapi64.dll"
    verify_hash d7c0df74d9bb4de5e2a3cc357b2309148fd3fdc824fe7941e4d789dbd072ff99 "Contents/SharedSupport/wine-root/lib/apple_gptk/wine/x86_64-windows/nvngx.dll"
fi
verify_transition_hash 5131e631eee8b542eadf48f4df9fd662d9aeeb59139137e0e6e14047dc434995 402ace6dd1c1c2ce58bb15ac68e64829b809fe3f5bdc344298cb4a8365ce1ae6 "Contents/SharedSupport/wine-root/lib/apple_gptk/external/libd3dshared.dylib"
verify_transition_hash 05a7beaed4494a4f5f53d3f626a82fffc3b70146436a908b7048a0632a49e1a8 9908d7990c28d3a25c8530b96ab703588b2c7d49dfb06155d24b130638b6cf99 "Contents/SharedSupport/wine-root/lib/apple_gptk/external/D3DMetal.framework/Versions/A/D3DMetal"

GRIM_PROFILE="$WINE_ROOT/lib/profiles/grim-dawn"
[[ -L "$GRIM_PROFILE" && "$(readlink "$GRIM_PROFILE")" == "../apple_gptk/wine" ]] || {
    echo "ERROR: el perfil protegido de Grim Dawn ya no apunta al runtime Apple interno." >&2
    exit 1
}

if $BEFORE_DD2_PROMOTION; then
    [[ ! -e "$WINE_ROOT/lib/profiles/dragons-dogma-2" &&
       ! -L "$WINE_ROOT/lib/profiles/dragons-dogma-2" ]] || {
        echo "ERROR: el baseline previo ya contiene un perfil DD2 inesperado." >&2
        exit 1
    }
else
    DD2_PROFILE="$WINE_ROOT/lib/profiles/dragons-dogma-2"
    verify_transition_hash 34d373a22fd224fec6e32d1bf7f31c647c518345752dc6bc632883c8c9aefc42 d1eea3dc9b027f8ef012e4270dac8bfcf7fe335a1e914f70c928203a8ffd33e8 "Contents/SharedSupport/wine-root/lib/profiles/dragons-dogma-2/x86_64-unix/winemac.so"
    verify_transition_hash 2ee679fa891fa336b2dd3623a1945f47c1c5834853e66eff342ba356c12d8c32 1dd6150e520dcb74d0a21f19186a0df4e77de2f0e6348a6160acb76ac6918f55 "Contents/SharedSupport/wine-root/lib/profiles/dragons-dogma-2/x86_64-windows/winemac.drv"
    dd2_modules=(atidxx64 d3d11 d3d12 dxgi)
    if ! $TRANSITION_1_11; then
        dd2_modules+=(nvapi64 nvngx)
    fi
    for module in "${dd2_modules[@]}"; do
        [[ -L "$DD2_PROFILE/x86_64-unix/$module.so" &&
           "$(readlink "$DD2_PROFILE/x86_64-unix/$module.so")" == "../../../apple_gptk/wine/x86_64-unix/$module.so" ]] || {
            echo "ERROR: enlace Unix inesperado en el perfil DD2: $module" >&2
            exit 1
        }
        [[ -L "$DD2_PROFILE/x86_64-windows/$module.dll" &&
           "$(readlink "$DD2_PROFILE/x86_64-windows/$module.dll")" == "../../../apple_gptk/wine/x86_64-windows/$module.dll" ]] || {
            echo "ERROR: enlace PE inesperado en el perfil DD2: $module" >&2
            exit 1
        }
    done
    if $TRANSITION_1_11; then
        for omitted_dd2_module in nvapi64 nvngx; do
            [[ ! -e "$DD2_PROFILE/x86_64-unix/$omitted_dd2_module.so" &&
               ! -L "$DD2_PROFILE/x86_64-unix/$omitted_dd2_module.so" &&
               ! -e "$DD2_PROFILE/x86_64-windows/$omitted_dd2_module.dll" &&
               ! -L "$DD2_PROFILE/x86_64-windows/$omitted_dd2_module.dll" ]] || {
                echo "ERROR: el baseline público contiene un enlace DD2 inesperado: $omitted_dd2_module" >&2
                exit 1
            }
        done
    fi
fi

if $INCLUDE_BOTTLE; then
    verify_bottle_hash 0b97d99a61eeeefefc4451d49477d31dc8c6e50ecca7651003655ac67f72aef4 "drive_c/windows/system32/d3d10core.dll"
    verify_bottle_hash e6209af3a04947504af1f12b4533eded103687841197cff45a92d1a5f916c0a8 "drive_c/windows/system32/d3d11.dll"
    verify_bottle_hash ff2062e17cfb5d4a0e4259e01fb264bb53e33fa093816e60c6e5a8f1e201b0eb "drive_c/windows/system32/d3d9.dll"
    verify_bottle_hash 25f74dafc3ebaf77ddc5a7b32d933853462c303a2636399860e80937cda82941 "drive_c/windows/system32/dxgi.dll"
fi

codesign --verify --deep --strict "$APP"
if $BEFORE_DD2_PROMOTION; then
    echo "Baseline previo a DD2 verificado: runtime, Grim Dawn y firma intactos."
elif $BEFORE_DRAGONSWORD_PROMOTION; then
    echo "Baseline previo a DragonSword verificado: runtime, Grim Dawn/DD2 y firma intactos."
elif $BEFORE_HWR2_PROMOTION; then
    echo "Baseline previo a Heroes of Hammerwatch II verificado: runtime y perfiles anteriores intactos."
else
    echo "Estado protegido verificado: runtime y perfiles Grim Dawn/DD2/DragonSword/HWR2 intactos."
fi
if $INCLUDE_BOTTLE; then
    echo "Botella canónica verificada: pareja DXMT y D3D9 fijadas."
fi
