#!/usr/bin/env bash
# Phase 0 conformance: the K decode loop vs the real ContextLib.runLoop.
#
# Runs the same programs through both engines and compares the final program counter and
# whether execution reverted. Solidity side is test/conformance/RunLoopConformance.t.sol,
# which drives the REAL runLoop with a no-op dispatch stub — the twin of K's `#unknown` rule,
# so both engines do nothing per instruction and only the loop is under test.
#
# Conformance is EVIDENCE ON THESE INPUTS, not proof. See semantics/PLAN.md §5a.
#
# HONEST LIMITATION: this does not diff the two engines against each other. Each side is
# checked against expectations written independently -- the table below for K, and the
# assertions in test/conformance/*.t.sol for Solidity. Those expectations were derived from
# each other by hand, so a shared mistake would pass both. A true differential harness would
# extract registers from both and compare them mechanically; this is weaker than that.
set -euo pipefail

CONTAINER=${CONTAINER:-kontrol}
REMOTE=${REMOTE:-/home/user/sem}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

# label ; K Bytes literal ; expected pc ; expected status ; balances map ; expected amountOut (- = unchecked) ; amountIn
#
# The catalogue case must supply a non-zero gate balance, or the gate reverts at pc 22 and the
# case is testing the gate rather than the loop. This bit me: repairing the missing config
# variables made the case fail, because the expectation had been recorded from a run with a
# balance set while the script passed none.
CASES=(
  'catalogue;b"\x23\x14\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xaa\x90\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x36\x35\xc9\xad\xc5\xde\xa0\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x6c\x6b\x93\x5b\x8b\xbd\x40\x00\x00\x53\x01\x01";91;Running;bal(170,4660) |-> 5'
  'floorNotCeil;b"\x23\x14\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xaa\x90\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x53\x01\x01";91;Running;bal(170,4660) |-> 5;0;1'
  'floorNonDividing;b"\x23\x14\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xaa\x90\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x07\x53\x01\x01";91;Running;bal(170,4660) |-> 5;11;5'
  'gateRejects;b"\x23\x14\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xaa";22;Reverted;.Map'
  'loneOpcode;b"\x53";2;Reverted;.Map'
  'argsOverrun;b"\x53\x40";66;Reverted;.Map'
  'empty;b"";0;Running;.Map'
  'zeroArg;b"\x50\x00";2;Running;.Map'
)

echo "== K side =="
fail=0
for c in "${CASES[@]}"; do
  IFS=';' read -r label lit want_pc want_st bals want_ao amt <<< "$c"
  amt=${amt:-1000000000000000000}

  printf '%s' "$lit" > /tmp/_conf_lit.txt
  docker cp -q /tmp/_conf_lit.txt "$CONTAINER:$REMOTE/_conf_lit.txt" 2>/dev/null || \
    docker cp /tmp/_conf_lit.txt "$CONTAINER:$REMOTE/_conf_lit.txt" >/dev/null
  docker exec "$CONTAINER" chown user:user "$REMOTE/_conf_lit.txt"

  # Phase 1 added six more configuration variables. Passing only $PGM makes krun fail with
  # "Configuration variable missing", which is how this script silently stopped working.
  out=$(docker exec "$CONTAINER" bash -c \
      "cd $REMOTE && su user -c 'PATH=/usr/bin:/bin krun --definition swapvm-llvm \
         -cPGM=\$(cat _conf_lit.txt) \
         -cTAKER=4660 -cTOKENIN=1 -cTOKENOUT=2 \
         -cAMOUNTIN=$amt -cAMOUNTOUT=0 -cEXACTIN=true \
         -cBALANCES=\"$bals\"'" 2>&1)
  pc=$(echo "$out"  | sed -n '/<pc>/,/<\/pc>/p'         | tr -d '\n <>/pc' | tr -d ' ')
  st=$(echo "$out"  | sed -n '/<status>/,/<\/status>/p' | grep -oE 'Running|Reverted' | head -1)
  # amountOut: the pricing VALUE. Without this the K side cannot distinguish floor from
  # ceiling -- a review found run.sh checked only pc and status, so every rounding mutant
  # survived it.
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
( cd "$ROOT" && FOUNDRY_PROFILE=default "${FORGE:-$HOME/.foundry/bin/forge}" test \
    --match-path 'test/conformance/*' 2>&1 | tail -4 ) || fail=1

exit $fail
