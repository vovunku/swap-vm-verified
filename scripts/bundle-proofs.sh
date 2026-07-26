#!/usr/bin/env bash
# Bundle the proof store into a committable artifact.
#
# WHY THIS EXISTS. `out/proofs/` is gitignored and per-machine: a proof lives in the container
# that produced it and is lost with that container. That is why this repository has status
# tables asserting PASSED for proofs no reader can check — see `test/kontrol/README.md`. The
# fix is to ship the store, not to write the number down.
#
# It compresses absurdly well. A quarter-megabyte EVM configuration is repeated, near
# identically, across every node of a KCFG, so zstd finds enormous redundancy:
#
#     XYCSwap, 18 proof dirs:   363 MB  ->  407 KB   (0.11%)
#
# so "ship the store" is cheap enough to commit rather than attach to a release.
#
#   ./scripts/bundle-proofs.sh                 bundle every spec, highest version only
#   ./scripts/bundle-proofs.sh XYCSwapSpec     bundle one spec
#   MERGE=/home/user/wl-work ./scripts/bundle-proofs.sh   pull from another workspace too
#
# Restore with:
#   zstd -dc proofs-<name>.tar.zst | docker exec -i kontrol tar xf - -C <REMOTE>/out/proofs
#
# CAVEAT, and it is load-bearing: a restored proof only counts if your build produces the same
# digest. `Contract.Method.digest` hashes the Foundry artifact, so a different solc version or
# a changed spec re-versions and Kontrol silently re-proves from scratch rather than reporting
# a mismatch. Treat a bundle as a time-saver, never as evidence on its own.
set -uo pipefail

CONTAINER=${CONTAINER:-kontrol}
REMOTE=${REMOTE:-/home/user/swap-vm-verified}
FILTER="${1:-}"
MERGE="${MERGE:-}"
NAME=$([ -n "$FILTER" ] && echo "${FILTER%Spec}" || echo all)
OUT="proofs-$(echo "$NAME" | tr 'A-Z' 'a-z').tar.zst"

command -v zstd >/dev/null || { echo "zstd not on PATH" >&2; exit 1; }

select_dirs() {   # $1 = store path, $2 = filter
  docker exec -u user "$CONTAINER" python3 -c "
import os,re,sys
base,filt=sys.argv[1],sys.argv[2]
if not os.path.isdir(base): sys.exit(0)
best={}
for d in os.listdir(base):
    m=re.match(r'(.*):(\d+)\$', d)
    if not m: continue
    k,v=m.group(1),int(m.group(2))
    if filt and filt not in k: continue
    if k not in best or v>best[k][0]: best[k]=(v,d)
print('\n'.join(d for _,d in best.values()))
" "$1" "$2"
}

echo "selecting highest-version proofs${FILTER:+ for $FILTER}..."
select_dirs "$REMOTE/out/proofs" "$FILTER" > /tmp/_bundle.list
n=$(wc -l < /tmp/_bundle.list)
[ "$n" -eq 0 ] && { echo "no proofs matched" >&2; exit 1; }
echo "  $REMOTE: $n proof dirs"

docker cp /tmp/_bundle.list "$CONTAINER:/tmp/_bundle.list" >/dev/null
docker exec -u user "$CONTAINER" bash -c "cd $REMOTE/out/proofs && tar cf - --files-from=/tmp/_bundle.list" \
  | zstd -T0 -12 -o "$OUT" -f 2>&1 | tail -1

# Optionally fold in a second workspace (agents run in isolated copies with their own stores).
if [ -n "$MERGE" ]; then
  echo "merging from $MERGE ..."
  select_dirs "$MERGE/out/proofs" "$FILTER" > /tmp/_bundle2.list
  m=$(wc -l < /tmp/_bundle2.list)
  echo "  $MERGE: $m proof dirs (restore separately: proofs-merge.tar.zst)"
  if [ "$m" -gt 0 ]; then
    docker cp /tmp/_bundle2.list "$CONTAINER:/tmp/_bundle2.list" >/dev/null
    docker exec -u user "$CONTAINER" bash -c "cd $MERGE/out/proofs && tar cf - --files-from=/tmp/_bundle2.list" \
      | zstd -T0 -12 -o proofs-merge.tar.zst -f 2>&1 | tail -1
  fi
fi

echo
zstd -t "$OUT" >/dev/null 2>&1 && echo "integrity OK" || echo "INTEGRITY CHECK FAILED"
printf 'wrote %s  (%.1f KB, restores to %s MB)\n' "$OUT" \
  "$(stat -c %s "$OUT" | awk '{print $1/1024}')" \
  "$(zstd -dc "$OUT" | wc -c | awk '{printf "%.0f", $1/1048576}')"
