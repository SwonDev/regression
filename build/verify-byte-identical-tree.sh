#!/usr/bin/env bash
# Compara dos árboles sin seguir enlaces y sella bytes, modos y atributos extendidos.
set -Eeuo pipefail

EXPECTED_TREE="${1:-}"
ACTUAL_TREE="${2:-}"
VERIFY_SCRATCH=""
shift_count=2
if (( $# >= shift_count )); then
    shift "$shift_count"
else
    set --
fi
EXCLUDED_RELATIVE_PATHS=()
if (( $# > 0 )); then
    EXCLUDED_RELATIVE_PATHS=("$@")
fi
PERL_EXCLUSIONS=(".regression-verifier-no-exclusion")
if (( ${#EXCLUDED_RELATIVE_PATHS[@]} > 0 )); then
    PERL_EXCLUSIONS+=("${EXCLUDED_RELATIVE_PATHS[@]}")
fi

fail()
{
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup()
{
    if [[ -n "$VERIFY_SCRATCH" && "$VERIFY_SCRATCH" == /private/tmp/regression-tree-verify.* ]]; then
        find "$VERIFY_SCRATCH" -mindepth 1 -depth -delete
        /bin/rmdir "$VERIFY_SCRATCH" 2>/dev/null || true
    fi
}
trap cleanup EXIT

[[ -d "$EXPECTED_TREE" && ! -L "$EXPECTED_TREE" ]] \
    || fail "el árbol esperado no es un directorio físico: $EXPECTED_TREE"
[[ -d "$ACTUAL_TREE" && ! -L "$ACTUAL_TREE" ]] \
    || fail "el árbol candidato no es un directorio físico: $ACTUAL_TREE"
if (( ${#EXCLUDED_RELATIVE_PATHS[@]} > 0 )); then
    for excluded_relative in "${EXCLUDED_RELATIVE_PATHS[@]}"; do
        [[ -n "$excluded_relative" ]] || fail "una exclusión vacía no está permitida"
        [[ "$excluded_relative" != /* && "$excluded_relative" != *".."* ]] \
            || fail "exclusión insegura: $excluded_relative"
    done
fi

VERIFY_SCRATCH="$(mktemp -d /private/tmp/regression-tree-verify.XXXXXX)"
chmod 700 "$VERIFY_SCRATCH"
EXCLUDE_FILE="$VERIFY_SCRATCH/excludes"
if (( ${#EXCLUDED_RELATIVE_PATHS[@]} > 0 )); then
    for excluded_relative in "${EXCLUDED_RELATIVE_PATHS[@]}"; do
        if [[ "$excluded_relative" == */ ]]; then
            printf './%s\n./%s*\n' \
                "${excluded_relative%/}" "$excluded_relative"
        else
            printf './%s\n' "$excluded_relative"
        fi
    done > "$EXCLUDE_FILE"
else
    : > "$EXCLUDE_FILE"
fi

write_tree_manifests()
{
    local tree="$1"
    local mtree_output="$2"
    local xattr_output="$3"
    (
        cd "$tree"
        /usr/sbin/mtree -c -X "$EXCLUDE_FILE" \
            -k type,mode,link,sha256digest \
            | sed -n '/^# \.$/,$p'
    ) > "$mtree_output"
    (
        cd "$tree"
        xattr -r -l -x -s . 2>/dev/null \
            | /usr/bin/perl -e '
                use strict;
                use warnings;
                my @exact = map { "./$_" } grep { $_ !~ m{/$} } @ARGV;
                my @subtrees = map {
                    my $path = $_;
                    $path =~ s{/$}{};
                    "./$path";
                } grep { m{/$} } @ARGV;
                my ($path, $attribute, $hex) = (undef, undef, "");
                sub excluded {
                    my ($candidate) = @_;
                    for my $exact (@exact) {
                        return 1 if $candidate eq $exact;
                    }
                    for my $root (@subtrees) {
                        return 1 if $candidate eq $root || index($candidate, "$root/") == 0;
                    }
                    return 0;
                }
                sub emit {
                    return unless defined $path && !excluded($path);
                    print "$path\t$attribute\t$hex\n";
                }
                while (<STDIN>) {
                    chomp;
                    if (/^(.*): ([^:]+):$/) {
                        emit();
                        ($path, $attribute, $hex) = ($1, $2, "");
                    } elsif (/^[0-9A-Fa-f]{8}\s{2}((?:[0-9A-Fa-f]{2}\s)+)/) {
                        my $bytes = $1;
                        $bytes =~ s/\s+//g;
                        $hex .= lc $bytes;
                    }
                }
                emit();
            ' "${PERL_EXCLUSIONS[@]}" \
            | LC_ALL=C sort
    ) > "$xattr_output"
}

EXPECTED_MTREE="$VERIFY_SCRATCH/expected.mtree"
ACTUAL_MTREE="$VERIFY_SCRATCH/actual.mtree"
EXPECTED_XATTRS="$VERIFY_SCRATCH/expected.xattrs"
ACTUAL_XATTRS="$VERIFY_SCRATCH/actual.xattrs"
write_tree_manifests "$EXPECTED_TREE" "$EXPECTED_MTREE" "$EXPECTED_XATTRS"
write_tree_manifests "$ACTUAL_TREE" "$ACTUAL_MTREE" "$ACTUAL_XATTRS"

MTREE_DIFF="$VERIFY_SCRATCH/mtree.diff"
if ! /usr/sbin/mtree -f "$EXPECTED_MTREE" -f "$ACTUAL_MTREE" > "$MTREE_DIFF" \
    || ! cmp -s "$EXPECTED_XATTRS" "$ACTUAL_XATTRS"; then
    printf '%s\n' 'Diferencias mtree:' >&2
    sed -n '1,80p' "$MTREE_DIFF" >&2
    printf '%s\n' 'Diferencias xattrs:' >&2
    diff -U 0 "$EXPECTED_XATTRS" "$ACTUAL_XATTRS" \
        | sed -n '1,80p' >&2 || true
    fail "el árbol candidato no es byte a byte equivalente"
fi

printf 'Árbol byte a byte verificado: %s\n' \
    "$(shasum -a 256 "$EXPECTED_MTREE" "$EXPECTED_XATTRS" \
        | shasum -a 256 | awk '{ print $1 }')"
