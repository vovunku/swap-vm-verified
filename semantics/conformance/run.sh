#!/usr/bin/env bash
# Phase 0 conformance: the K decode loop vs the real ContextLib.runLoop.
#
# Runs the same programs through both engines and compares the final program counter and
# whether execution reverted. Solidity side is test/conformance/RunLoopConformance.t.sol,
# which drives the REAL runLoop with a no-op dispatch stub — the twin of K's `#unknown` rule,
# so both engines do nothing per instruction and only the loop is under test.
#
# Conformance is EVIDENCE ON THESE INPUTS, not proof. See semantics/PLAN.md §5a.
set -euo pipefail

CONTAINER=${CONTAINER:-kontrol}
REMOTE=${REMOTE:-/home/user/sem}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

# program label : K Bytes literal : expected pc : expected status
CASES=(
  'catalogue:b"\x23\x14\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xaa\x90\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x36\x35\xc9\xad\xc5\xde\xa0\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x6c\x6b\x93\x5b\x8b\xbd\x40\x00\x00\x53\x01\x01":91:Running'
  'loneOpcode:b"\x53":2:Reverted'
  'argsOverrun:b"\x53\x40":66:Reverted'
  'empty:b"":0:Running'
  'zeroArg:b"\x50\x00":2:Running'
)

echo "== K side =="
fail=0
for c in "${CASES[@]}"; do
  label="${c%%:*}"; rest="${c#*:}"
  lit="${rest%:*:*}"; rest="${rest#*:}"
  want_pc="${rest%:*}"; want_st="${rest#*:}"

  printf '%s' "$lit" > /tmp/_conf_lit.txt
  docker cp -q /tmp/_conf_lit.txt "$CONTAINER:$REMOTE/_conf_lit.txt" 2>/dev/null || \
    docker cp /tmp/_conf_lit.txt "$CONTAINER:$REMOTE/_conf_lit.txt" >/dev/null
  docker exec "$CONTAINER" chown user:user "$REMOTE/_conf_lit.txt"

  out=$(docker exec "$CONTAINER" bash -c \
      "cd $REMOTE && su user -c 'PATH=/usr/bin:/bin krun --definition swapvm-llvm -cPGM=\$(cat _conf_lit.txt)'" 2>&1)
  pc=$(echo "$out"  | sed -n '/<pc>/,/<\/pc>/p'         | tr -d '\n <>/pc' | tr -d ' ')
  st=$(echo "$out"  | sed -n '/<status>/,/<\/status>/p' | grep -oE 'Running|Reverted' | head -1)

  if [ "$pc" = "$want_pc" ] && [ "$st" = "$want_st" ]; then
    printf '  %-14s pc=%-4s %-9s OK\n' "$label" "$pc" "$st"
  else
    printf '  %-14s pc=%-4s %-9s MISMATCH (wanted pc=%s %s)\n' "$label" "$pc" "$st" "$want_pc" "$want_st"
    fail=1
  fi
done

echo "== Solidity side =="
( cd "$ROOT" && FOUNDRY_PROFILE=default "${FORGE:-$HOME/.foundry/bin/forge}" test \
    --match-path 'test/conformance/*' 2>&1 | tail -4 ) || fail=1

exit $fail
