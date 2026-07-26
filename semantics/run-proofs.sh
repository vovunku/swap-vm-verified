#!/usr/bin/env bash
# Run the full SwapVM proof suite natively — no Docker, no `su user`.
#
# The nix-native twin of the docker command documented in `proofs/README.md:17`:
#
#     docker exec kontrol bash -c "cd /home/user/sem && su user -c \
#       'PATH=/usr/bin:/bin kprove --definition swapvm-haskell proofs/<file>.k'"
#
# Here you already have `kompile`/`kprove` from `nix develop` (see flake.nix), so the
# container is gone and the inner command runs directly in this directory.
#
# Two of the six specs are supposed to FAIL. That is the design (proofs/README.md:3): a
# control that cannot fail proves nothing, and a control that unexpectedly PROVES means the
# rule set is inconsistent and every result above it is void. This script enforces both
# directions and exits non-zero on any mismatch, including a control that flips to PROVED.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# The flake.nix devShell puts `kontrol`/`kevm` on PATH but NOT the raw K toolchain
# (kompile/kprove/krun). K is bundled as a transitive dep of kontrol and mounted only inside
# the kontrol/kevm wrapper scripts. Recover its bin dir from the wrapper so this runs under
# plain `nix develop` with no flake edit. If kompile is already on PATH (e.g. a global install
# or a future flake change), the discovery is skipped.
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

PROVE_TIMEOUT=${PROVE_TIMEOUT:-1800}

echo "== building swapvm-haskell (proofs use this definition) =="
kompile --backend haskell lemmas.k \
  --main-module SWAPVM-BYTES-LEMMAS --syntax-module SWAPVM-SYNTAX \
  -o swapvm-haskell >/tmp/swapvm-kompile-haskell.log 2>&1 \
  || { echo "haskell kompile FAILED — see /tmp/swapvm-kompile-haskell.log"; exit 2; }

# name | expect (prove | fail)
#   prove : kprove must exit 0 (#Top)
#   fail  : kprove must NOT exit 0 — the negative controls (proofs/README.md:7-13)
SPECS=(
  'gate-spec|prove'                # T0 — gate reverts on zero balance, any symbolic tail
  'pricing-spec|prove'             # T1 — exact-in is exactly the floor
  'pricing-exactout-spec|prove'    # T2 — exact-out is exactly the ceiling
  'control-sensitivity|prove'      # negative-control's twin: same premises, correct conclusion
  'negative-control|fail'          # balance non-zero, asserting the same revert — must fail
  'pricing-negative-control|fail'  # maker-safety inequality reversed — must fail
)

echo
printf '%-28s %-8s %-12s %s\n' SPEC EXPECT RESULT ""
printf '%-28s %-8s %-12s %s\n' "----------------------------" "------" "----------" ""
mismatch=0
for s in "${SPECS[@]}"; do
  name="${s%%|*}"; expect="${s##*|}"

  out=/tmp/swapvm-prove-${name}.out
  if timeout "$PROVE_TIMEOUT" kprove --definition swapvm-haskell "proofs/${name}.k" >"$out" 2>&1; then
    status=PROVED
  else
    rc=$?
    if [ "$rc" -eq 124 ]; then status=TIMEOUT; else status=not-proved; fi
  fi

  verdict=OK
  case "$expect" in
    prove)
      [ "$status" = "PROVED" ] || verdict="BAD (wanted PROVED)"
      ;;
    fail)
      # A control that PROVES is the worst outcome: inconsistent rule set.
      [ "$status" = "not-proved" ] || verdict="INCONSISTENT (control proved)"
      ;;
  esac
  { [ "$status" = "TIMEOUT" ]; } && verdict="TIMEOUT"
  [ "$verdict" = "OK" ] || mismatch=1

  printf '%-28s %-8s %-12s %s\n' "$name" "$expect" "$status" "$verdict"
done

echo
if [ "$mismatch" = "0" ]; then
  echo "all proofs match expectations"
else
  echo "MISMATCH — per-spec output in /tmp/swapvm-prove-*.out"
fi
exit $mismatch
