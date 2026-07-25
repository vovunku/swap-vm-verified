#!/usr/bin/env bash
# Mutation testing for the SwapVM semantics.
#
# Breaks the semantics in a known way, rebuilds, runs the whole suite, and reports whether
# anything noticed. A mutant that survives is a coverage hole; the kill table is the evidence
# that the suite detects broken behaviour rather than merely passing.
#
# WHY THIS EXISTS. A green proof is unfalsifiable-looking — an audience cannot distinguish a
# real theorem from a vacuous one, and this project has produced both. The first mutation study
# here found the shipped harness killed ZERO mutants, because `run.sh` had been broken since
# Phase 1 and the K engine never executed a program. The suite looked healthy and detected
# nothing. This script makes that failure mode impossible to hide.
#
# A mutant that flips a NEGATIVE CONTROL from failing to proving is the worst outcome: it means
# the mutated rule set is inconsistent, and an inconsistent theory proves everything.
set -uo pipefail

CONTAINER=${CONTAINER:-kontrol}
REMOTE=${REMOTE:-/home/user/sem}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
FORGE=${FORGE:-$HOME/.foundry/bin/forge}
ONLY=${1:-}

# name | sed expression applied to swapvm.md
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
  docker exec "$CONTAINER" bash -c \
    "cd $REMOTE && su user -c 'PATH=/usr/bin:/bin kompile --backend llvm swapvm.md --main-module SWAPVM --syntax-module SWAPVM-SYNTAX -o swapvm-llvm' >/dev/null 2>&1" || return 1
  docker exec "$CONTAINER" bash -c \
    "cd $REMOTE && su user -c 'PATH=/usr/bin:/bin kompile --backend haskell lemmas.k --main-module SWAPVM-BYTES-LEMMAS --syntax-module SWAPVM-SYNTAX -o swapvm-haskell' >/dev/null 2>&1" || return 1
}

# prints the list of checks that noticed
score() {
  local killed=""
  ./semantics/conformance/run.sh >/dev/null 2>&1 || killed="$killed conformance"
  "$FORGE" test --match-path 'test/conformance/*' >/dev/null 2>&1 || killed="$killed solidity"
  for p in gate-spec pricing-spec control-sensitivity; do
    docker exec "$CONTAINER" bash -c \
      "cd $REMOTE && su user -c 'PATH=/usr/bin:/bin timeout 1800 kprove --definition swapvm-haskell proofs/$p.k' >/dev/null 2>&1" \
      || killed="$killed proof:$p"
  done
  # negative controls MUST keep failing; if one proves, the rule set is inconsistent
  for p in negative-control pricing-negative-control; do
    if docker exec "$CONTAINER" bash -c \
        "cd $REMOTE && su user -c 'PATH=/usr/bin:/bin timeout 1800 kprove --definition swapvm-haskell proofs/$p.k' >/dev/null 2>&1"; then
      killed="$killed INCONSISTENT:$p"
    fi
  done
  echo "$killed"
}

echo "restoring pristine semantics"
docker cp "$ROOT/semantics/swapvm.md" "$CONTAINER:$REMOTE/swapvm.md" >/dev/null
docker cp "$ROOT/semantics/lemmas.k"  "$CONTAINER:$REMOTE/lemmas.k"  >/dev/null
docker exec "$CONTAINER" chown user:user "$REMOTE/swapvm.md" "$REMOTE/lemmas.k"
kompile_both || { echo "baseline build FAILED"; exit 1; }
base=$(score)
[ -n "$base" ] && { echo "BASELINE IS NOT CLEAN — these already fail:$base"; exit 1; }
echo "baseline clean"; echo

printf '%-24s %s\n' MUTANT "KILLED BY"
for m in "${MUTANTS[@]}"; do
  name="${m%%|*}"; expr="${m#*|}"
  [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && continue

  docker exec "$CONTAINER" bash -c "cd $REMOTE && sed -i '$expr' swapvm.md"
  if kompile_both; then
    k=$(score)
    printf '%-24s %s\n' "$name" "${k:-*** SURVIVED ***}"
  else
    printf '%-24s %s\n' "$name" "(did not compile — mutant invalid, not a result)"
  fi
  docker cp "$ROOT/semantics/swapvm.md" "$CONTAINER:$REMOTE/swapvm.md" >/dev/null
  docker exec "$CONTAINER" chown user:user "$REMOTE/swapvm.md"
done

echo; echo "restoring and re-verifying baseline"
kompile_both
final=$(score)
[ -z "$final" ] && echo "baseline reproduces — semantics restored" || echo "RESTORE FAILED:$final"
