#!/usr/bin/env bash

set -euo pipefail

# Construye y ejecuta una sonda mínima de Context FEX. El modo init-core añade
# el dispatcher; compile-one compila un NOP y execute-one ejecuta un bloque
# controlado que termina con HLT; execute-linked fuerza además el enlazado
# dinámico entre dos bloques; los modos invalidate deshacen enlaces directos
# e indirectos de forma segura, siempre sin cargar ningún ELF.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE_SOURCE="$ROOT/tools/research/fli_fexcore_context_probe.cpp"
LIBRARY=""
FEX_SOURCE=""
FEX_BUILD=""
OUTPUT_DIRECTORY=""
EXPECTED=""

usage() {
  cat <<'EOF'
Uso: tools/research/run_fli_fexcore_context_probe.sh \
  --library RUTA --fex-source RUTA --fex-build RUTA \
  --expect context|init-core|compile-one|execute-one|execute-linked|invalidate-linked|invalidate-indirect|execute-low-memory-bias|execute-sparse-page-redirect|execute-sparse-high-regions|inspect-address-translation|execute-region-lifecycle|execute-region-fault-attribution --output-dir RUTA_PRIVADA

context    Crea y destruye un Context FEXCore nativo sin dispatcher.
init-core Inicializa también el dispatcher, sin crear hilos huéspedes.
compile-one Decodifica y compila un NOP x86-64, pero no ejecuta el bloque.
execute-one Ejecuta `mov eax, 42; hlt` y comprueba el resultado en el host.
execute-linked Ejecuta dos bloques y obliga al enlazador JIT a conectarlos.
invalidate-linked Invalida esos bloques y obliga al JIT a deshacer el enlace.
invalidate-indirect Fuerza e invalida un enlace fuera del alcance de una rama.
execute-low-memory-bias Escribe y relee un valor en la dirección huésped baja
  0x1e2f70 mediante una página host alta, sin mapear memoria baja en macOS.
execute-sparse-page-redirect Aísla 0x7ffe0000 en una página host propia y
  comprueba que 0x7ffe1000 continúa usando el shadow lineal adyacente.
execute-sparse-high-regions Traduce simultáneamente una región sobre 4 GiB y
  otra próxima al límite superior de Wine hacia dos páginas host ordinarias.
inspect-address-translation Verifica en el host las traducciones huésped↔host,
  los recorridos de ida y vuelta y el rechazo de regiones solapadas.
execute-region-lifecycle Reutiliza un único bloque JIT mientras sustituye su
  backing host con el hilo detenido; después retira el mapa y prueba que no
  quedan traducciones obsoletas antes de proteger y desmapear ambas páginas.
execute-region-fault-attribution Protege el backing de 0x100000270, captura el
  único fallo host producido por la carga JIT y exige que la traducción inversa
  lo atribuya exactamente a esa dirección huésped antes de restaurar el host.

Los modos execute ejecutan únicamente bytes x86-64 controlados. Ningún modo
carga un ELF huésped, Proton, Steam o EAC. inspect-address-translation no
ejecuta siquiera un bloque huésped; execute-region-lifecycle solo ejecuta el
mismo bloque controlado antes y después de una actualización host explícita;
execute-region-fault-attribution provoca únicamente una carga protegida.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --library)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      LIBRARY="$2"
      shift 2
      ;;
    --fex-source)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      FEX_SOURCE="$2"
      shift 2
      ;;
    --fex-build)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      FEX_BUILD="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      OUTPUT_DIRECTORY="$2"
      shift 2
      ;;
    --expect)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      EXPECTED="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

[[ -f "$LIBRARY" && ! -L "$LIBRARY" ]] || {
  echo "ERROR: --library debe señalar una dylib regular." >&2
  exit 66
}
[[ -d "$FEX_SOURCE/FEXCore/include" && -d "$FEX_BUILD/include" ]] || {
  echo "ERROR: faltan las cabeceras fuente o generadas de FEXCore." >&2
  exit 66
}
[[ -n "$OUTPUT_DIRECTORY" && ! -L "$OUTPUT_DIRECTORY" ]] || {
  echo "ERROR: --output-dir es obligatorio y no puede ser un enlace simbólico." >&2
  exit 66
}
[[ "$EXPECTED" == "context" || "$EXPECTED" == "init-core" || "$EXPECTED" == "compile-one" || "$EXPECTED" == "execute-one" \
  || "$EXPECTED" == "execute-linked" || "$EXPECTED" == "invalidate-linked" || "$EXPECTED" == "invalidate-indirect" \
  || "$EXPECTED" == "execute-low-memory-bias" || "$EXPECTED" == "execute-sparse-page-redirect" \
  || "$EXPECTED" == "execute-sparse-high-regions" || "$EXPECTED" == "inspect-address-translation" \
  || "$EXPECTED" == "execute-region-lifecycle" || "$EXPECTED" == "execute-region-fault-attribution" ]] || {
  echo "ERROR: --expect no coincide con ningún modo permitido de la sonda." >&2
  exit 64
}

IDENTITY="${REGRESSION_CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Apple Development:/ { print $2; exit }')"
fi
[[ -n "$IDENTITY" && "$IDENTITY" != "-" ]] || {
  echo "ERROR: la prueba endurecida requiere una identidad Apple Development estable." >&2
  exit 69
}

BUILD_DIRECTORY="$(mktemp -d /private/tmp/regression-fli-fex-context-probe.XXXXXX)"
cleanup() {
  case "$BUILD_DIRECTORY" in
    /private/tmp/regression-fli-fex-context-probe.*)
      rm -rf -- "$BUILD_DIRECTORY"
      ;;
  esac
}
trap cleanup EXIT

RUNTIME_DIRECTORY="$BUILD_DIRECTORY/runtime"
mkdir -m 0700 "$RUNTIME_DIRECTORY"
RUNTIME_LIBRARY="$RUNTIME_DIRECTORY/libFEXCore.dylib"
FMT_LIBRARY="$RUNTIME_DIRECTORY/libfmt.12.dylib"
PROBE="$RUNTIME_DIRECTORY/fli-fexcore-context-probe"

cp "$LIBRARY" "$RUNTIME_LIBRARY"
cp -L /opt/homebrew/opt/fmt/lib/libfmt.12.dylib "$FMT_LIBRARY"
install_name_tool -id @rpath/libfmt.12.dylib "$FMT_LIBRARY"
install_name_tool \
  -change /opt/homebrew/opt/fmt/lib/libfmt.12.dylib \
  @loader_path/libfmt.12.dylib \
  "$RUNTIME_LIBRARY"

codesign --force --sign "$IDENTITY" --options runtime "$FMT_LIBRARY" >/dev/null
codesign --force --sign "$IDENTITY" --options runtime "$RUNTIME_LIBRARY" >/dev/null

PROBE_DEFINE=""
if [[ "$EXPECTED" == "execute-low-memory-bias" || "$EXPECTED" == "execute-sparse-page-redirect" \
  || "$EXPECTED" == "execute-sparse-high-regions" || "$EXPECTED" == "inspect-address-translation" \
  || "$EXPECTED" == "execute-region-lifecycle" || "$EXPECTED" == "execute-region-fault-attribution" ]]; then
  PROBE_DEFINE="-DREGRESSION_FEXCORE_GUEST_MEMORY_BIAS=1"
fi

/usr/bin/c++ \
  -std=c++20 \
  -arch arm64 \
  -Wall \
  -Wextra \
  -Werror \
  -Wno-unused-parameter \
  -O2 \
  -DARCHITECTURE_arm64=1 \
  -I "$FEX_SOURCE/FEXCore/include" \
  -I "$FEX_SOURCE/FEXCore/Source" \
  -I "$FEX_BUILD/include" \
  -I "$FEX_SOURCE/FEXHeaderUtils" \
  -I "$FEX_SOURCE/CodeEmitter" \
  -I "$FEX_SOURCE/External/unordered_dense/include" \
  -isystem /opt/homebrew/include \
  ${PROBE_DEFINE:+"$PROBE_DEFINE"} \
  "$PROBE_SOURCE" \
  -L "$RUNTIME_DIRECTORY" \
  -lFEXCore \
  -Wl,-rpath,@executable_path \
  -o "$PROBE"

if [[ "$EXPECTED" == "init-core" || "$EXPECTED" == "compile-one" || "$EXPECTED" == "execute-one" \
  || "$EXPECTED" == "execute-linked" || "$EXPECTED" == "invalidate-linked" || "$EXPECTED" == "invalidate-indirect" \
  || "$EXPECTED" == "execute-low-memory-bias" || "$EXPECTED" == "execute-sparse-page-redirect" \
  || "$EXPECTED" == "execute-sparse-high-regions" || "$EXPECTED" == "inspect-address-translation" \
  || "$EXPECTED" == "execute-region-lifecycle" || "$EXPECTED" == "execute-region-fault-attribution" ]]; then
  codesign --force --sign "$IDENTITY" --options runtime --entitlements "$ROOT/tools/research/fli_nonvm_host_probe.entitlements" "$PROBE" >/dev/null
else
  codesign --force --sign "$IDENTITY" --options runtime "$PROBE" >/dev/null
fi

codesign --verify --strict "$FMT_LIBRARY"
codesign --verify --strict "$RUNTIME_LIBRARY"
codesign --verify --strict "$PROBE"

RECEIPT="$BUILD_DIRECTORY/context-probe.json"
"$PROBE" "--$EXPECTED" | tee "$RECEIPT"
grep -Fq '"context_created":true' "$RECEIPT" || {
  echo "ERROR: FEXCore no creó el contexto nativo esperado." >&2
  exit 70
}
grep -Fq '"small_alignment_allocation":true' "$RECEIPT" || {
  echo "ERROR: el allocator host no respeta la alineación mínima de fextl." >&2
  exit 70
}
if [[ "$EXPECTED" == "init-core" || "$EXPECTED" == "compile-one" || "$EXPECTED" == "execute-one" \
  || "$EXPECTED" == "execute-linked" || "$EXPECTED" == "invalidate-linked" || "$EXPECTED" == "invalidate-indirect" \
  || "$EXPECTED" == "execute-low-memory-bias" || "$EXPECTED" == "execute-sparse-page-redirect" \
  || "$EXPECTED" == "execute-sparse-high-regions" || "$EXPECTED" == "inspect-address-translation" \
  || "$EXPECTED" == "execute-region-lifecycle" || "$EXPECTED" == "execute-region-fault-attribution" ]]; then
  grep -Fq '"init_core":true' "$RECEIPT" || {
    echo "ERROR: FEXCore no inicializó el dispatcher nativo esperado." >&2
    exit 70
  }
else
  grep -Fq '"init_core":false' "$RECEIPT" || {
    echo "ERROR: la sonda context invocó InitCore inesperadamente." >&2
    exit 70
  }
fi
if [[ "$EXPECTED" == "compile-one" || "$EXPECTED" == "execute-one" || "$EXPECTED" == "execute-linked" \
  || "$EXPECTED" == "invalidate-linked" || "$EXPECTED" == "invalidate-indirect" \
  || "$EXPECTED" == "execute-low-memory-bias" || "$EXPECTED" == "execute-sparse-page-redirect" \
  || "$EXPECTED" == "execute-sparse-high-regions" || "$EXPECTED" == "execute-region-lifecycle" \
  || "$EXPECTED" == "execute-region-fault-attribution" ]]; then
  grep -Fq '"guest_x86_decoded":true' "$RECEIPT" || {
    echo "ERROR: la sonda no decodificó la instrucción x86-64 controlada." >&2
    exit 70
  }
  grep -Fq '"jit_block_compiled":true' "$RECEIPT" || {
    echo "ERROR: la sonda no compiló el bloque JIT controlado." >&2
    exit 70
  }
fi
if [[ "$EXPECTED" == "execute-one" || "$EXPECTED" == "execute-linked" || "$EXPECTED" == "invalidate-linked" \
  || "$EXPECTED" == "invalidate-indirect" || "$EXPECTED" == "execute-low-memory-bias" \
  || "$EXPECTED" == "execute-sparse-page-redirect" || "$EXPECTED" == "execute-sparse-high-regions" \
  || "$EXPECTED" == "execute-region-lifecycle" || "$EXPECTED" == "execute-region-fault-attribution" ]]; then
  grep -Fq '"guest_code_executed":true' "$RECEIPT" || {
    echo "ERROR: la sonda no ejecutó el bloque huésped controlado." >&2
    exit 70
  }
  if [[ "$EXPECTED" == "execute-region-fault-attribution" ]]; then
    grep -Fq '"guest_region_fault_count":1' "$RECEIPT" || {
      echo "ERROR: la sonda no observó exactamente un fallo host controlado." >&2
      exit 70
    }
    grep -Eq '"guest_region_fault_signal":(10|11)' "$RECEIPT" || {
      echo "ERROR: el fallo controlado no llegó como SIGBUS o SIGSEGV." >&2
      exit 70
    }
    grep -Fq '"guest_region_fault_guest_address":4294967920' "$RECEIPT" || {
      echo "ERROR: el fallo host no se atribuyó a 0x100000270." >&2
      exit 70
    }
    grep -Fq '"guest_region_fault_expected_guest_address":4294967920' "$RECEIPT" || {
      echo "ERROR: el control no conservó la dirección huésped esperada." >&2
      exit 70
    }
    for field in \
      guest_region_fault_handler_attached \
      guest_region_fault_seen \
      guest_region_fault_host_pc_in_jit \
      guest_region_fault_translation_succeeded \
      guest_region_fault_expected_host_matched \
      guest_region_fault_backing_protected \
      guest_region_fault_handlers_restored \
      guest_region_fault_backing_restored \
      guest_region_fault_map_cleared \
      guest_region_fault_attribution_passed; do
      grep -Fq "\"${field}\":true" "$RECEIPT" || {
        echo "ERROR: falló la comprobación de atribución host→huésped: ${field}." >&2
        exit 70
      }
    done
  elif [[ "$EXPECTED" == "execute-region-lifecycle" ]]; then
    grep -Fq '"guest_result":1432778632' "$RECEIPT" || {
      echo "ERROR: el bloque JIT reutilizado no leyó el backing actualizado." >&2
      exit 70
    }
    grep -Fq '"guest_lifecycle_initial_result":287454020' "$RECEIPT" || {
      echo "ERROR: la primera ejecución no leyó el backing inicial." >&2
      exit 70
    }
    grep -Fq '"guest_lifecycle_updated_result":1432778632' "$RECEIPT" || {
      echo "ERROR: la segunda ejecución no leyó el backing sustituido." >&2
      exit 70
    }
    for field in \
      guest_region_update_passed \
      guest_region_clear_passed \
      guest_backing_protection_passed \
      guest_backing_unmap_passed \
      jit_block_reused_after_region_update \
      guest_region_lifecycle_passed; do
      grep -Fq "\"${field}\":true" "$RECEIPT" || {
        echo "ERROR: falló la comprobación del ciclo de regiones: ${field}." >&2
        exit 70
      }
    done
  elif [[ "$EXPECTED" == "execute-low-memory-bias" ]]; then
    grep -Fq '"guest_result":305419896' "$RECEIPT" || {
      echo "ERROR: la carga huésped baja no devolvió el valor esperado." >&2
      exit 70
    }
    grep -Fq '"guest_low_target_address":1978224' "$RECEIPT" || {
      echo "ERROR: la sonda no ejercitó la dirección huésped baja prevista." >&2
      exit 70
    }
    grep -Fq '"guest_low_stored_value":305419896' "$RECEIPT" || {
      echo "ERROR: la escritura huésped baja no alcanzó la página host segura." >&2
      exit 70
    }
    grep -Fq '"guest_memory_bias_passed":true' "$RECEIPT" || {
      echo "ERROR: la traducción huésped→host no superó el control completo." >&2
      exit 70
    }
  elif [[ "$EXPECTED" == "execute-sparse-page-redirect" ]]; then
    grep -Fq '"guest_result":2271560481' "$RECEIPT" || {
      echo "ERROR: la página lineal adyacente no devolvió el valor esperado." >&2
      exit 70
    }
    grep -Fq '"guest_redirect_target_address":2147353200' "$RECEIPT" || {
      echo "ERROR: la sonda no ejercitó la página redirigida prevista." >&2
      exit 70
    }
    grep -Fq '"guest_adjacent_target_address":2147357296' "$RECEIPT" || {
      echo "ERROR: la sonda no ejercitó la página lineal adyacente." >&2
      exit 70
    }
    grep -Fq '"guest_redirect_stored_value":305419896' "$RECEIPT" || {
      echo "ERROR: la escritura redirigida no alcanzó su página host aislada." >&2
      exit 70
    }
    grep -Fq '"guest_adjacent_stored_value":2271560481' "$RECEIPT" || {
      echo "ERROR: la escritura adyacente no permaneció en el shadow lineal." >&2
      exit 70
    }
    grep -Fq '"guest_sparse_redirect_passed":true' "$RECEIPT" || {
      echo "ERROR: la redirección dispersa no superó el control completo." >&2
      exit 70
    }
  elif [[ "$EXPECTED" == "execute-sparse-high-regions" ]]; then
    grep -Fq '"guest_result":1720232652' "$RECEIPT" || {
      echo "ERROR: las dos cargas altas no produjeron el resultado conjunto esperado." >&2
      exit 70
    }
    grep -Fq '"guest_high_region_1_target_address":4294967920' "$RECEIPT" || {
      echo "ERROR: la primera región alta no usó la dirección lógica prevista." >&2
      exit 70
    }
    grep -Fq '"guest_high_region_2_target_address":140737487503984' "$RECEIPT" || {
      echo "ERROR: la segunda región alta no usó la dirección lógica prevista." >&2
      exit 70
    }
    grep -Fq '"guest_high_region_1_stored_value":287454020' "$RECEIPT" || {
      echo "ERROR: la primera escritura alta no alcanzó su página host." >&2
      exit 70
    }
    grep -Fq '"guest_high_region_2_stored_value":1432778632' "$RECEIPT" || {
      echo "ERROR: la segunda escritura alta no alcanzó su página host." >&2
      exit 70
    }
    grep -Fq '"guest_sparse_high_regions_passed":true' "$RECEIPT" || {
      echo "ERROR: la traducción simultánea de regiones altas no superó el control completo." >&2
      exit 70
    }
  else
    grep -Fq '"guest_result":42' "$RECEIPT" || {
      echo "ERROR: el bloque huésped no produjo el resultado esperado." >&2
      exit 70
    }
  fi
  if [[ "$EXPECTED" == "execute-linked" || "$EXPECTED" == "invalidate-linked" ]]; then
    grep -Fq '"runtime_link_exercised":true' "$RECEIPT" || {
      echo "ERROR: la sonda no atravesó el enlazador dinámico de bloques." >&2
      exit 70
    }
  fi
  if [[ "$EXPECTED" == "invalidate-linked" ]]; then
    grep -Fq '"code_invalidation_exercised":true' "$RECEIPT" || {
      echo "ERROR: la sonda no deshizo el enlace JIT mediante invalidación." >&2
      exit 70
    }
  fi
  if [[ "$EXPECTED" == "invalidate-indirect" ]]; then
    grep -Fq '"indirect_link_exercised":true' "$RECEIPT" || {
      echo "ERROR: la sonda no forzó el enlazador JIT indirecto." >&2
      exit 70
    }
    grep -Fq '"indirect_invalidation_exercised":true' "$RECEIPT" || {
      echo "ERROR: la sonda no deshizo el enlace JIT indirecto." >&2
      exit 70
    }
  fi
else
  grep -Fq '"guest_code_executed":false' "$RECEIPT" || {
    echo "ERROR: el recibo no conserva la frontera de no ejecución huésped." >&2
    exit 70
  }
fi
if [[ "$EXPECTED" == "inspect-address-translation" ]]; then
  grep -Fq '"address_translation_contract_enabled":true' "$RECEIPT" || {
    echo "ERROR: la sonda no activó el contrato bidireccional de direcciones." >&2
    exit 70
  }
  grep -Fq '"round_trip_low_guest_address":1978224' "$RECEIPT" || {
    echo "ERROR: la dirección baja no completó su recorrido host→huésped." >&2
    exit 70
  }
  grep -Fq '"round_trip_redirect_guest_address":2147353200' "$RECEIPT" || {
    echo "ERROR: la página redirigida no completó su recorrido host→huésped." >&2
    exit 70
  }
  grep -Fq '"round_trip_high_region_1_guest_address":4294967920' "$RECEIPT" || {
    echo "ERROR: la primera región alta no completó su recorrido host→huésped." >&2
    exit 70
  }
  grep -Fq '"round_trip_high_region_2_guest_address":140737487503984' "$RECEIPT" || {
    echo "ERROR: la segunda región alta no completó su recorrido host→huésped." >&2
    exit 70
  }
  for field in \
    invalid_guest_overlap_rejected \
    invalid_host_overlap_rejected \
    unmapped_guest_rejected \
    unmapped_host_rejected \
    null_translation_output_rejected \
    address_translation_contract_passed; do
    grep -Fq "\"${field}\":true" "$RECEIPT" || {
      echo "ERROR: falló la comprobación del contrato de direcciones: ${field}." >&2
      exit 70
    }
  done
fi
grep -Fq '"guest_elf_executed":false' "$RECEIPT" || {
  echo "ERROR: el recibo no conserva la frontera de no ejecución huésped." >&2
  exit 70
}

install -d -m 0700 "$OUTPUT_DIRECTORY"
install -m 0600 "$RECEIPT" "$OUTPUT_DIRECTORY/context-probe.json"
{
  printf 'schema=%s\n' '1'
  printf 'signature=%s\n' 'valid'
  printf 'hardened_runtime=%s\n' 'yes'
  if [[ "$EXPECTED" == "init-core" || "$EXPECTED" == "compile-one" || "$EXPECTED" == "execute-one" \
    || "$EXPECTED" == "execute-linked" || "$EXPECTED" == "invalidate-linked" || "$EXPECTED" == "invalidate-indirect" \
    || "$EXPECTED" == "execute-low-memory-bias" || "$EXPECTED" == "execute-sparse-page-redirect" \
    || "$EXPECTED" == "execute-sparse-high-regions" || "$EXPECTED" == "inspect-address-translation" \
    || "$EXPECTED" == "execute-region-lifecycle" || "$EXPECTED" == "execute-region-fault-attribution" ]]; then
    printf 'allow_jit=%s\n' 'true'
  else
    printf 'allow_jit=%s\n' 'false'
  fi
  printf 'team_identifier=%s\n' 'present-and-matched'
  printf 'probe_mode=%s\n' "$EXPECTED"
  if [[ "$EXPECTED" == "execute-one" || "$EXPECTED" == "execute-linked" || "$EXPECTED" == "invalidate-linked" \
    || "$EXPECTED" == "invalidate-indirect" || "$EXPECTED" == "execute-low-memory-bias" \
    || "$EXPECTED" == "execute-sparse-page-redirect" || "$EXPECTED" == "execute-sparse-high-regions" \
    || "$EXPECTED" == "execute-region-lifecycle" || "$EXPECTED" == "execute-region-fault-attribution" ]]; then
    printf 'guest_execution=%s\n' 'controlled-block-only'
  else
    printf 'guest_execution=%s\n' 'none'
  fi
} > "$OUTPUT_DIRECTORY/signature.txt"
shasum -a 256 "$PROBE_SOURCE" \
  | sed "s#  $ROOT/#  repository/#" \
  > "$OUTPUT_DIRECTORY/sources.sha256"
shasum -a 256 "$LIBRARY" \
  | awk '{ print $1 "  input-libFEXCore.dylib" }' \
  > "$OUTPUT_DIRECTORY/library.sha256"
(
  cd "$OUTPUT_DIRECTORY"
  shasum -a 256 context-probe.json signature.txt sources.sha256 library.sha256 > tree.sha256
)
chmod 0600 "$OUTPUT_DIRECTORY"/*.txt "$OUTPUT_DIRECTORY"/*.json "$OUTPUT_DIRECTORY"/*.sha256

echo "Sonda FEXCore nativa verificada: $EXPECTED."
echo "Evidencia privada: $OUTPUT_DIRECTORY"
