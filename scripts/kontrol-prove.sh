#!/usr/bin/env bash
# Run a kontrol.toml prove profile, ONE PROPERTY PER INVOCATION, and print a verdict table.
#
# WHY ONE PER INVOCATION. `kontrol prove` prints per-proof verdicts only when the whole
# invocation ends, so a batch that is still running looks identical to a batch that is
# stuck. RECONCILIATION.md §2b records an agent killing a three-property batch after 80
# minutes as "stalled"; re-run as singles, two of them passed in 90 seconds. They had
# almost certainly already passed inside the killed run.
#
# Each property gets its own wall-clock budget and writes a `.done` marker, so a run that
# dies is visible rather than silent, and a re-run skips what already finished.
#
#   ./scripts/kontrol-prove.sh xycswap              # the green set
#   ./scripts/kontrol-prove.sh xycswap-open         # the quarantine; expected to time out
#   BUDGET=1800 ./scripts/kontrol-prove.sh xycswap-open
#
# Reproducibility caveat: a profile pins the PROPERTY LIST, not the result. The proof store
# is only valid against the definition digest it was produced under, so any spec, harness or
# lemma edit re-versions every property in the affected contract and forces a re-run. See
# PROOF-MAP.md §"Preserving proofs".
set -uo pipefail

PROFILE="${1:-}"
if [ -z "$PROFILE" ]; then
  echo "usage: $0 <prove-profile>   (e.g. xycswap, xycswap-open)" >&2
  exit 64
fi

CONTAINER=${CONTAINER:-kontrol}
REMOTE=${REMOTE:-/home/user/swap-vm-verified}
BUDGET=${BUDGET:-900}
OUT=${OUT:-/home/user/prove-$PROFILE}

kx() { docker exec -u user "$CONTAINER" bash -c "$1"; }

# Pull the property list straight out of kontrol.toml so the script cannot drift from it.
mapfile -t PROPS < <(kx "cd $REMOTE && python3 - <<'PY'
import re,sys
prof='$PROFILE'
src=open('kontrol.toml').read()
m=re.search(r'^\[prove\.'+re.escape(prof)+r'\](.*?)(?=^\[|\Z)', src, re.S|re.M)
if not m: sys.exit('no such profile: '+prof)
b=re.search(r'match-test\s*=\s*\[(.*?)\]', m.group(1), re.S)
if not b: sys.exit('profile has no match-test: '+prof)
for line in b.group(1).splitlines():
    line=line.split('#')[0].strip().rstrip(',')
    if line.startswith((\"'\",'\"')): print(line[1:-1])
PY")

if [ "${#PROPS[@]}" -eq 0 ]; then echo "no properties resolved for profile '$PROFILE'" >&2; exit 1; fi
echo "profile '$PROFILE': ${#PROPS[@]} properties, budget ${BUDGET}s each"

kx "mkdir -p $OUT"
for p in "${PROPS[@]}"; do
  slug=$(echo "$p" | tr -c 'A-Za-z0-9_' '_')
  if kx "test -f $OUT/$slug.done" 2>/dev/null; then
    printf '  %-72s (cached) %s\n' "$p" "$(kx "cat $OUT/$slug.done")"
    continue
  fi
  start=$(date +%s)
  kx "cd $REMOTE && PATH=/home/user/.local/bin:/home/user/.foundry/bin:/usr/bin:/bin \
      HOME=/home/user FOUNDRY_PROFILE=kontrol \
      timeout $BUDGET kontrol prove --config-profile '$PROFILE' --match-test '$p' \
      > $OUT/$slug.log 2>&1; echo \"exit=\$?\" > $OUT/$slug.done" >/dev/null 2>&1
  rc=$(kx "cat $OUT/$slug.done" | grep -oE '[0-9]+$')
  verdict=$(kx "grep -oE 'PROOF (PASSED|FAILED)' $OUT/$slug.log | tail -1" 2>/dev/null)
  [ "$rc" = "124" ] && verdict="${verdict:-TIMEOUT at ${BUDGET}s}"
  kx "echo 'exit=$rc elapsed=$(( $(date +%s) - start ))s $verdict' > $OUT/$slug.done"
  printf '  %-72s %s\n' "$p" "$(kx "cat $OUT/$slug.done")"
done

echo
echo "=== verdicts (from the proof store, highest version only) ==="
kx "cd $REMOTE && python3 /home/user/xycstatus.py XYCSwapSpec 2>/dev/null | grep -v NO-DATA" || true
echo
echo "logs: docker exec -u user $CONTAINER ls $OUT"
