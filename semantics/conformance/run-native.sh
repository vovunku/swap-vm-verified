#!/usr/bin/env bash
# Phase 0 conformance — nix-native. No Docker.
#
# The twin of `run.sh` in this directory, which drives a Docker container `kontrol`. Under
# `nix develop` (see flake.nix) `krun` and `forge` are already on PATH, so the container,
# `su user`, `docker cp` and `chown` all disappear and the inner commands run locally.
#
# Same caveat as `run.sh`: conformance is EVIDENCE ON THESE INPUTS, not proof. See
# semantics/PLAN.md §5a.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# The sem root that holds swapvm.md and gets the kompiled `swapvm-llvm/` definition.
# Override SEM_DIR + SKIP_BUILD=1 to point at a staging dir (used by mutation/run-native.sh).
SEM_DIR=${SEM_DIR:-"$(cd "$HERE/.." && pwd)"}
SKIP_BUILD=${SKIP_BUILD:-0}
FORGE=${FORGE:-forge}

# The flake.nix devShell puts `kontrol`/`kevm` on PATH but NOT the raw K toolchain
# (kompile/kprove/krun). K is bundled as a transitive dep of kontrol and mounted only inside
# the kontrol/kevm wrapper scripts. Recover its bin dir from the wrapper so this runs under
# plain `nix develop` with no flake edit. Skipped if the tools are already on PATH.
discover_k_bin() {
  local wrapper p
  wrapper="$(command -v kontrol 2>/dev/null)" || return 1
  while IFS= read -r p; do
    [ -x "$p/kompile" ] && [ -x "$p/kprove" ] && [ -x "$p/krun" ] && { printf '%s' "$p"; return 0; }
  done < <(grep -oE '/nix/store/[a-z0-9]+-[a-z0-9.+_-]+/bin' "$wrapper" | sort -u)
  return 1
}
command -v kompile >/dev/null 2>&1 || { K_BIN="$(discover_k_bin)" && export PATH="$K_BIN:$PATH"; }
command -v kompile >/dev/null 2>&1 || { echo "kompile not on PATH and not discoverable — run 'nix develop' first."; exit 2; }
command -v krun    >/dev/null 2>&1 || { echo "krun not on PATH — run 'nix develop' first."; exit 2; }

if [ "$SKIP_BUILD" != "1" ]; then
  echo "== building swapvm-llvm (krun definition) in $SEM_DIR =="
  ( cd "$SEM_DIR" && kompile --backend llvm swapvm.md \
      --main-module SWAPVM --syntax-module SWAPVM-SYNTAX -o swapvm-llvm ) \
      >/tmp/swapvm-kompile-llvm.log 2>&1 \
    || { echo "llvm kompile FAILED — see /tmp/swapvm-kompile-llvm.log"; exit 2; }
fi

# label ; K Bytes literal ; expected pc ; expected status ; balances ; expected amountOut (- = unchecked) ; amountIn ; tokenIn ; tokenOut ; amountOut-in ; exactIn
#
# Verbatim from run.sh: the same programs and the same hand-derived expectations.
CASES=(
  'catalogue;b"\x23\x14\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xaa\x90\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x36\x35\xc9\xad\xc5\xde\xa0\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x6c\x6b\x93\x5b\x8b\xbd\x40\x00\x00\x53\x01\x01";91;Running;bal(170,4660) |-> 5'
  'floorNotCeil;b"\x23\x14\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xaa\x90\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x53\x01\x01";91;Running;bal(170,4660) |-> 5;0;1'
  'floorNonDividing;b"\x23\x14\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xaa\x90\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x07\x53\x01\x01";91;Running;bal(170,4660) |-> 5;11;5'
  'revPrices;b"\x23\x14\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xaa\x90\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x36\x35\xc9\xad\xc5\xde\xa0\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x6c\x6b\x93\x5b\x8b\xbd\x40\x00\x00\x53\x01\x00";91;Running;bal(170,4660) |-> 5;500000000000000000;1000000000000000000;9;2;0;true'
  'revRecompute;b"\x23\x14\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xaa\x90\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x36\x35\xc9\xad\xc5\xde\xa0\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x6c\x6b\x93\x5b\x8b\xbd\x40\x00\x00\x53\x01\x00";91;Reverted;bal(170,4660) |-> 5;-;1000000000000000000;9;2;7;true'
  'revRecomputeOut;b"\x23\x14\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xaa\x90\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x36\x35\xc9\xad\xc5\xde\xa0\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x6c\x6b\x93\x5b\x8b\xbd\x40\x00\x00\x53\x01\x00";91;Reverted;bal(170,4660) |-> 5;-;7;9;2;3;false'
  'gateRejects;b"\x23\x14\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xaa";22;Reverted;.Map'
  'loneOpcode;b"\x53";2;Reverted;.Map'
  'argsOverrun;b"\x53\x40";66;Reverted;.Map'
  'empty;b"";0;Running;.Map'
  'zeroArg;b"\x50\x00";2;Running;.Map'
)

echo "== K side (krun in $SEM_DIR) =="
fail=0
for c in "${CASES[@]}"; do
  IFS=';' read -r label lit want_pc want_st bals want_ao amt tin tout aoin exin <<< "$c"
  amt=${amt:-1000000000000000000}; tin=${tin:-1}; tout=${tout:-2}; aoin=${aoin:-0}; exin=${exin:-true}

  # Hand the bytes literal to krun via a file, as run.sh does: passing it inline risks the
  # shell eating the quotes and backslashes in the K `b"..."` token.
  lit_file="$SEM_DIR/_conf_lit.txt"
  printf '%s' "$lit" > "$lit_file"

  out=$(cd "$SEM_DIR" && krun --definition swapvm-llvm \
        -cPGM="$(cat _conf_lit.txt)" \
        -cTAKER=4660 -cTOKENIN=$tin -cTOKENOUT=$tout \
        -cAMOUNTIN=$amt -cAMOUNTOUT=$aoin -cEXACTIN=$exin \
        -cBALANCES="$bals" 2>&1)
  pc=$(echo "$out"  | sed -n '/<pc>/,/<\/pc>/p'         | tr -d '\n <>/pc' | tr -d ' ')
  st=$(echo "$out"  | sed -n '/<status>/,/<\/status>/p' | grep -oE 'Running|Reverted' | head -1)
  ao=$(echo "$out"  | sed -n '/<amountOut>/,/<\/amountOut>/p' | grep -oE '[0-9]+' | head -1)
  [ "${want_ao:--}" = "-" ] && ao_ok=1 || { [ "$ao" = "$want_ao" ] && ao_ok=1 || ao_ok=0; }

  if [ "$pc" = "$want_pc" ] && [ "$st" = "$want_st" ] && [ "$ao_ok" = "1" ]; then
    printf '  %-18s pc=%-4s %-9s amountOut=%-6s OK\n' "$label" "$pc" "$st" "${ao:--}"
  else
    printf '  %-18s pc=%-4s %-9s amountOut=%-6s MISMATCH (wanted pc=%s %s amountOut=%s)\n' \
      "$label" "$pc" "$st" "${ao:--}" "$want_pc" "$want_st" "${want_ao:--}"
    fail=1
  fi
done

echo "== Solidity side =="
( cd "$ROOT" && FOUNDRY_PROFILE=default "$FORGE" test \
    --match-path 'test/conformance/*' 2>&1 | tail -4 ) || fail=1

exit $fail
