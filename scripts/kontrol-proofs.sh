#!/usr/bin/env bash
# Archive and restore the Kontrol proof store.
#
# Proofs are expensive: 8.5 h of CPU produced the current store. They live in
# `out/proofs/`, which is gitignored, and are lost with the container or the working tree.
#
# IMPORTANT: a proof is only valid against the definition digest it was produced under.
# Restoring into a tree whose specs or lemmas.k have changed does NOT resurrect the result --
# Kontrol will mint a new version and re-prove. Archive/restore buys you machine loss and
# container rebuilds, not spec edits.
set -euo pipefail

CONTAINER=${CONTAINER:-kontrol}
REMOTE=${REMOTE:-/home/user/swap-vm-verified}
ARCHIVE=${ARCHIVE:-proofs-archive.tar.zst}

case "${1:-}" in
  save)
    docker exec "$CONTAINER" bash -c "cd $REMOTE && tar cf - out/proofs out/digest 2>/dev/null" \
      | zstd -T0 -3 -o "$ARCHIVE" -f
    echo "saved $(du -h "$ARCHIVE" | cut -f1) -> $ARCHIVE"
    ;;
  restore)
    zstd -dc "$ARCHIVE" | docker exec -i "$CONTAINER" bash -c "cd $REMOTE && tar xf -"
    docker exec "$CONTAINER" bash -c "chown -R user:user $REMOTE/out/proofs"
    echo "restored. Verify with: kontrol list"
    ;;
  prune)
    # Delete superseded versions, keeping the highest per property. 24% of the store.
    docker exec "$CONTAINER" bash -c "cd $REMOTE/out/proofs && \
      ls -d *:* 2>/dev/null | sed 's/:[0-9]*\$//' | sort -u | while read -r n; do \
        keep=\$(ls -d \"\$n\":* 2>/dev/null | sed 's/.*://' | sort -n | tail -1); \
        for d in \"\$n\":*; do [ \"\$d\" = \"\$n:\$keep\" ] || rm -rf \"\$d\"; done; \
      done"
    echo "pruned superseded versions"
    ;;
  *)
    echo "usage: $0 {save|restore|prune}" >&2; exit 1 ;;
esac
