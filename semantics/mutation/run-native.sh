#!/usr/bin/env bash
# Mutation testing — nix-native. No Docker.
#
# The twin of `run.sh` in this directory. That script drives a Docker container `kontrol`,
# keeping pristine K sources on the host and mutating a working copy inside the container at
# /home/user/sem. Under `nix develop` (see flake.nix) there is no container, so the pristine
# sources and the working copy would be the same files — mutating in place would corrupt the
# tree and the per-mutant "restore from pristine" step would copy a file onto itself.
#
# So this native twin stages swapvm.md / lemmas.k / proofs/ into an isolated WORK directory
# and mutates THERE. The pristine tree under $ROOT/semantics is never touched. The kill table
# has the same meaning as run.sh's: a mutant that SURVIVES is a coverage hole, and a mutant
# that flips a negative control from failing to PROVING is an inconsistent rule set.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
FORGE=${FORGE:-forge}
ONLY=${1:-}
WORK=${WORK:-"$HERE/_work-native"}

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
command -v kprove  >/dev/null 2>&1 || { echo "kprove not on PATH — run 'nix develop' first."; exit 2; }
command -v krun    >/dev/null 2>&1 || { echo "krun not on PATH — run 'nix develop' first."; exit 2; }

# Stage the pristine K sources into WORK. proofs/ is copied so the `proofs/<spec>.k` command
# shape matches the docker twin verbatim; it is never mutated.
stage_pristine() {
  rm -rf "$WORK"
  mkdir -p "$WORK"
  cp "$ROOT/semantics/swapvm.md" "$ROOT/semantics/lemmas.k" "$WORK/"
  cp -r "$ROOT/semantics/proofs" "$WORK/proofs"
}

# name | sed expression applied to swapvm.md — verbatim from run.sh.
MUTANTS=(
  'exactInCeils|s|limitQuoteOut(AIN, BIN, BOUT) => AIN \*Int BOUT /Int BIN|limitQuoteOut(AIN, BIN, BOUT) => #ceilDiv(AIN *Int BOUT, BIN)|'
  'exactOutFloors|s|limitQuoteIn (AOUT, BIN, BOUT) => #ceilDiv(AOUT \*Int BIN, BOUT)|limitQuoteIn (AOUT, BIN, BOUT) => AOUT *Int BIN /Int BOUT|'
  'ceilDivIsFloor|s|( A -Int 1 ) /Int B +Int 1|A /Int B|'
  'orientationFlip|s|requires lengthBytes(ARGS) ==Int 64 andBool TIN <Int TOUT|requires lengthBytes(ARGS) ==Int 64 andBool TIN >=Int TOUT|'
  'gateAlwaysPasses|s|andBool #balanceOf(B, Bytes2Int(ARGS, BE, Unsigned), TAKER) <=Int 0|andBool false|'
  'pcAdvanceOffByOne|s|PC +Int 2 +Int PGM \[ PC +Int 1 \] </pc>|PC +Int 1 +Int PGM [ PC +Int 1 ] </pc>|'
  'prioritiesSwapped|s|\[priority(50)\]|[priorityTMP]|g;s|\[priority(60)\]|[priority(50)]|g;s|\[priorityTMP\]|[priority(60)]|g'
  'argsLengthHoleBack|s|rule <k> #exec ( 35 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>|rule <k> #exec ( 35 , ARGS ) => .K ... </k>|'
  'quoteOperandsSwapped|s|=> AIN \*Int BOUT /Int BIN|=> AIN *Int BIN /Int BOUT|'
)

kompile_both() {
  ( cd "$WORK" && kompile --backend llvm swapvm.md \
      --main-module SWAPVM --syntax-module SWAPVM-SYNTAX -o swapvm-llvm ) >/dev/null 2>&1 || return 1
  ( cd "$WORK" && kompile --backend haskell lemmas.k \
      --main-module SWAPVM-BYTES-LEMMAS --syntax-module SWAPVM-SYNTAX -o swapvm-haskell ) >/dev/null 2>&1 || return 1
}

# prints the list of checks that noticed a divergence from baseline.
score() {
  local killed=""
  SEM_DIR="$WORK" SKIP_BUILD=1 "$ROOT/semantics/conformance/run-native.sh" >/dev/null 2>&1 || killed="$killed conformance"
  ( cd "$ROOT" && "$FORGE" test --match-path 'test/conformance/*' >/dev/null 2>&1 ) || killed="$killed solidity"
  for p in gate-spec pricing-spec control-sensitivity; do
    ( cd "$WORK" && timeout 1800 kprove --definition swapvm-haskell "proofs/$p.k" >/dev/null 2>&1 ) \
      || killed="$killed proof:$p"
  done
  # negative controls MUST keep failing; if one proves, the rule set is inconsistent.
  for p in negative-control pricing-negative-control; do
    if ( cd "$WORK" && timeout 1800 kprove --definition swapvm-haskell "proofs/$p.k" >/dev/null 2>&1 ); then
      killed="$killed INCONSISTENT:$p"
    fi
  done
  echo "$killed"
}

echo "staging pristine semantics into $WORK"
stage_pristine || { echo "stage FAILED"; exit 1; }
kompile_both || { echo "baseline build FAILED"; exit 1; }
base=$(score)
[ -n "$base" ] && { echo "BASELINE IS NOT CLEAN — these already fail:$base"; exit 1; }
echo "baseline clean"; echo

printf '%-24s %s\n' MUTANT "KILLED BY"
for m in "${MUTANTS[@]}"; do
  name="${m%%|*}"; expr="${m#*|}"
  [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && continue

  ( cd "$WORK" && sed -i "$expr" swapvm.md )
  if kompile_both; then
    k=$(score)
    printf '%-24s %s\n' "$name" "${k:-*** SURVIVED ***}"
  else
    printf '%-24s %s\n' "$name" "(did not compile — mutant invalid, not a result)"
  fi
  # restore only swapvm.md, as run.sh does — lemmas.k and proofs/ are never mutated.
  cp "$ROOT/semantics/swapvm.md" "$WORK/swapvm.md"
done

echo; echo "restoring and re-verifying baseline"
kompile_both
final=$(score)
[ -z "$final" ] && echo "baseline reproduces — semantics restored" || echo "RESTORE FAILED:$final"
