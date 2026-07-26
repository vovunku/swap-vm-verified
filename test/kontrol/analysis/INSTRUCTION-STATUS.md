# Instruction verification status

One row per instruction in `src/instructions/`. This is the coverage map: what has a
specification, what is actually *proven*, what has a confirmed defect, and — because it turns
out to matter more than anything else for finding new bugs — **whether the eight audit firms
ever saw it**.

Regenerate the proof counts from the store (never from a summary):

```bash
docker exec -u user kontrol python3 - <SpecName> < scripts/proof-status.py
```

## Legend

* **props** — properties declared in `test/kontrol/<Name>Spec.t.sol`
* **proven** — highest version PASSED in the proof store. `-` means the spec exists but **no
  proof has ever been run**; those properties are fuzz-green only, which is a much weaker claim
* **repro** — executing reproducers under `analysis/repro/`, i.e. CONFIRMED defects
* **audit** — total mentions across all eight audit PDFs (Bailsec, Decurity, Hashlock, Hexens,
  Mixbytes, Nethermind, OpenZeppelin, Theori)
* **K** — modelled in the K semantics (`semantics/swapvm.md`)

---

## The table

| instruction | lines | props | proven | repro | audit | K | added |
|---|---:|---:|---:|---:|---:|:-:|---|
| PiecewiseLinearScale | 152 | 31 | **24** | 2 | **0** | – | 2026-06 |
| XYCSwap | 34 | 17 | **13** | 0 | – | – | 2025-11 |
| PeggedSwap | 225 | 31 | *rerunning* | 4 | 103 | – | 2025-11 |
| XYCConcentrate | 161 | 21 | **6** | 1 | 169 | – | 2025-11 |
| Fee | 243 | 35 | *in flight* | 0 | 91 | – | 2025-11 |
| Whitelist | 168 | 23 | *in flight* | 1 | **2** | – | 2026-06 |
| OraclePriceAdjuster | 140 | 19 | *in flight* | 1 | 8 | – | 2025-11 |
| BaseFeeAdjuster | 104 | 25 | **–** | 1 | ~40 | – | 2025-11 |
| Controls | 179 | 17 | **–** | 0 | – | ✓ | 2025-11 |
| MinRate | 73 | 13 | **–** | 1 | 23 | – | 2025-11 |
| LimitSwap | 74 | 9 | **0** | 0 | – | ✓ | 2025-11 |
| Balances | 82 | 8 | **–** | 0 | – | ✓ | 2025-11 |
| DutchAuction | 99 | 0 | – | 1 | 33 | – | 2025-11 |
| Invalidators | 136 | 0 | – | 0 | 29 | – | 2025-11 |
| SeriesEpochManager | 74 | 0 | – | 0 | **0** | – | 2026-06 |
| TWAPSwap | 172 | 0 | – | 0 | 47 | – | 2025-11 |
| Decay | 99 | 0 | – | 0 | 189 | – | 2025-11 |
| Extruction | 116 | 0 | – | 0 | 98 | – | 2025-11 |
| FeeExperimental | 148 | 0 | – | 0 | 3 | – | 2025-12 |
| Debug | 73 | 0 | – | 0 | – | – | 2025-11 |

`Power` is a library, not an instruction: 31 properties, **12 proven**, reachable only from
`DutchAuction` and `TWAPSwap`.

---

## What the table says

**Proven, on the current store: 62 properties.** PiecewiseLinearScale 24, XYCSwap 13, Power 12,
PeggedSwap 7 (pre-surgery; being re-proven), XYCConcentrate 6.

**Every harness has a spec — 13 for 13.** No orphans.

**Four specs have no proofs in THIS store: `BalancesSpec`, `ControlsSpec`,
`BaseFeeAdjusterSpec`, `MinRateSpec`.** Read that as a *reproducibility* gap, not an honesty
one. These are Track A, and the Track A commits proved a good deal of it and said so precisely
— `e59732a`: "prove all properties under Kontrol … all PASSED, 0 failing/0 stuck", with
per-property times in `906e2d7` (35m/24m/18m); `7d541e1` is explicit that MinRate is "13 total,
all passing as fuzz tests" with only some PASSED under Kontrol and the rest interrupted.

The proofs are simply not *here*: `out/proofs/` is gitignored and per-machine, so Track A's
store lives in the container it was produced in. To make those rows reproducible someone must
either re-run them on this build or ship that store. Until then they are `TESTED` here even
though they were `PROVED` there.

**Eight instructions have no specification at all**: DutchAuction, Invalidators,
SeriesEpochManager, TWAPSwap, Decay, Extruction, FeeExperimental, Debug. `DutchAuction` has a
confirmed defect anyway — found by reading, not by proving.

**`XYCConcentrate`'s six proven properties are about a hand-written copy**, not the deployed
instruction — see `HARNESS-FIDELITY.md`. The two differentials that would close that boundary
have never persisted a node, and the real-code surface stalls at 197 nodes.

---

## The audit column is the most actionable thing here

All eight audits ran **January–April 2026** (Theori 2026-01-12 … OpenZeppelin 2026-04-09).
Three instructions were added *after* every one of them closed:

| instruction | added | audit mentions |
|---|---|---|
| PiecewiseLinearScale | 2026-06-03 | **0** |
| SeriesEpochManager | 2026-06-04 | **0** |
| Whitelist | 2026-06-05 | **2** (Mixbytes only) |

**Zero mentions across 393 pages by eight firms**, because the code did not exist yet. This is
shipped, un-reviewed surface, and it is where this project's novel findings came from:
PiecewiseLinearScale has two confirmed defects, and Whitelist has one — a gas trap that burns
the taker's entire gas limit (`repro/WhitelistGasTrapRepro.t.sol`).

By contrast Decay (189 mentions), XYCConcentrate (169), PeggedSwap (103), Extruction (98) and
Fee (91) are heavily trodden. Coverage there is worth having; novel findings are unlikely.

**`SeriesEpochManager` is the outstanding opportunity**: post-audit, zero mentions, 74 lines,
one instruction, and no spec. Its `parse` reads 8 bytes with no length validation, so an
instruction encoded with `argsLength < 8` validates against `seriesEpoch[maker][0] == 0` — the
default for any maker who has never touched series 0 — silently disabling batch cancellation
for that order. That is SOURCE-level reasoning and needs an executing witness before it counts.

---

## Cross-cutting patterns

Found by sweeping all twenty instructions rather than reading one closely — and it out-yielded
deep-diving any single file:

1. **`build()` validates, `parse()` does not** — DutchAuction, FeeExperimental, Fee,
   OraclePriceAdjuster, PiecewiseLinearScale, Whitelist, XYCConcentrate. Program bytes are
   maker-assembled and only `parse` runs on chain, so every one of those `require`s is
   decorative. This is the shape behind the confirmed HIGH in `BUGS.md`.
2. **The unsafe `Calldata.slice(bytes,uint256)` overload** — 24 call sites. It does
   `res.length := sub(calls.length, begin)` in raw assembly with no bounds check, while a safe
   overload taking a `bytes4 exception` sits next to it in the same library. Where the sliced
   `.length` becomes a loop bound it is a **gas trap** (PiecewiseLinearScale, Whitelist — both
   confirmed); everywhere else a short `args` silently zero-pads and the instruction parses
   garbage.
3. **Unvalidated jump targets** — `ctx.vm.nextPC` is written from two raw argument bytes in
   Whitelist (×2) and Controls (×4), with no bound or direction check.

---

## Reproducing any row

```bash
./scripts/verify.sh findings                      # all confirmed defects, ~3 min
./scripts/kontrol-prove.sh xycswap                # the 13 XYCSwap proofs
docker exec -u user kontrol python3 - PowerSpec < scripts/proof-status.py
```

See `VERIFY.md` for the full claims table and `PROOF-MAP.md` for proof-store operations.
