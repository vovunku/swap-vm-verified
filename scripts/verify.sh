#!/usr/bin/env bash
# One entry point for reproducing this project's claims. See VERIFY.md for what each
# claim means and which evidence tier it sits at.
#
#   ./scripts/verify.sh setup        start the container, sync sources, kompile K   ~5 min
#   ./scripts/verify.sh semantics    4 K theorems + 2 negative controls             ~30 s
#   ./scripts/verify.sh conformance  K rules vs the real runLoop, 11 programs       ~2 min
#   ./scripts/verify.sh findings     the confirmed-bug reproducers (forge)          ~3 min
#   ./scripts/verify.sh kontrol      XYCSwap: 13 properties under kontrol prove     ~40 min
#   ./scripts/verify.sh kontrol-open the 4 that do NOT close (expected to time out) ~60 min
#   ./scripts/verify.sh mutation     9 mutants scored against the whole suite       ~40 min
#   ./scripts/verify.sh fast         setup + semantics + conformance + findings     ~10 min
#   ./scripts/verify.sh all          everything
#
# Exit code is non-zero if any check that MUST pass fails, or if a negative control that
# MUST fail unexpectedly proves -- the latter means the rule set is inconsistent and every
# result above it is void.
set -uo pipefail

CONTAINER=${CONTAINER:-kontrol}
IMAGE_TAG=$(cat "$(dirname "$0")/../deps/kontrol_release" 2>/dev/null || echo 1.0.255)
IMAGE=${IMAGE:-runtimeverificationinc/kontrol:ubuntu-jammy-$IMAGE_TAG}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE=${REMOTE:-/home/user/swap-vm-verified}
SEM=${SEM:-/home/user/sem}
rc=0

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; rc=1; }
kx()   { docker exec -u user "$CONTAINER" bash -c "$1"; }

cmd_setup() {
  say "setup — image $IMAGE"
  if ! docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    docker run -d --name "$CONTAINER" "$IMAGE" sleep infinity >/dev/null
  fi
  docker start "$CONTAINER" >/dev/null 2>&1 || true

  docker exec "$CONTAINER" mkdir -p "$REMOTE" "$SEM"
  tar cf - -C "$ROOT" --exclude=./out --exclude=./cache --exclude=./.git . \
    | docker exec -i "$CONTAINER" tar xf - -C "$REMOTE"
  tar cf - -C "$ROOT/semantics" . | docker exec -i "$CONTAINER" tar xf - -C "$SEM"
  docker exec "$CONTAINER" chown -R user:user "$REMOTE" "$SEM"

  say "kompile the K semantics (llvm for krun, haskell for kprove)"
  kx "cd $SEM && PATH=/usr/bin:/bin kompile --backend llvm swapvm.md \
        --main-module SWAPVM --syntax-module SWAPVM-SYNTAX -o swapvm-llvm" >/dev/null 2>&1 \
    && ok "swapvm-llvm" || bad "kompile llvm"
  kx "cd $SEM && PATH=/usr/bin:/bin kompile --backend haskell lemmas.k \
        --main-module SWAPVM-BYTES-LEMMAS --syntax-module SWAPVM-SYNTAX -o swapvm-haskell" >/dev/null 2>&1 \
    && ok "swapvm-haskell" || bad "kompile haskell"

  say "kontrol build (needed only for the kontrol tiers; slow)"
  echo "  run: docker exec -u user $CONTAINER bash -c 'cd $REMOTE && FOUNDRY_PROFILE=kontrol kontrol build'"
}

cmd_semantics() {
  say "K semantics — 4 theorems must PROVE, 2 negative controls must FAIL"
  for p in gate-spec pricing-spec pricing-exactout-spec control-sensitivity; do
    if kx "cd $SEM && PATH=/usr/bin:/bin timeout 900 kprove --definition swapvm-haskell proofs/$p.k" >/dev/null 2>&1
      then ok "$p  #Top"; else bad "$p  did not prove"; fi
  done
  for p in negative-control pricing-negative-control; do
    if kx "cd $SEM && PATH=/usr/bin:/bin timeout 900 kprove --definition swapvm-haskell proofs/$p.k" >/dev/null 2>&1
      then bad "$p  PROVED -- control must fail; the rule set may be INCONSISTENT"
      else ok "$p  fails as required"; fi
  done
}

cmd_conformance() {
  say "conformance — K decode loop and instruction rules vs the real ContextLib.runLoop"
  "$ROOT/semantics/conformance/run.sh" && ok "11 K cases + Solidity side" || bad "conformance"
}

cmd_findings() {
  say "findings — reproducers for the CONFIRMED defects in BUGS.md"
  kx "cd $REMOTE && PATH=/home/user/.foundry/bin:/usr/bin:/bin FOUNDRY_PROFILE=default \
      forge test --match-path 'test/kontrol/analysis/repro/*'" \
    && ok "repro suite" || bad "repro suite"
}

cmd_kontrol()      { say "XYCSwap — the 13 properties that close";      "$ROOT/scripts/kontrol-prove.sh" xycswap; }
cmd_kontrol_open() { say "XYCSwap — the 4 that do NOT close (expected to time out)"
                     "$ROOT/scripts/kontrol-prove.sh" xycswap-open; }
cmd_mutation()     { say "mutation — 9 mutants scored against the whole suite"
                     "$ROOT/semantics/mutation/run.sh" && ok mutation || bad mutation; }

case "${1:-fast}" in
  setup)         cmd_setup ;;
  semantics)     cmd_semantics ;;
  conformance)   cmd_conformance ;;
  findings)      cmd_findings ;;
  kontrol)       cmd_kontrol ;;
  kontrol-open)  cmd_kontrol_open ;;
  mutation)      cmd_mutation ;;
  fast)          cmd_setup; cmd_semantics; cmd_conformance; cmd_findings ;;
  all)           cmd_setup; cmd_semantics; cmd_conformance; cmd_findings; cmd_kontrol; cmd_mutation ;;
  *)             sed -n '2,20p' "$0"; exit 64 ;;
esac

echo
[ "$rc" -eq 0 ] && echo "OK — all checks in this tier behaved as specified" \
                || echo "FAILURES above; see VERIFY.md for what each claim means"
exit $rc
