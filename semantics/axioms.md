# Trust ledger

Every instruction rule is a claim about the deployed bytecode. This file tracks the status of
each one. See `PLAN.md` §5a for the model.

| State | Meaning |
|---|---|
| `ADMITTED` | Asserted. No proof, no executed conformance coverage. **All rules start here.** |
| `TESTED` | Conformance **runs** it on concrete inputs **on both engines** and they agree. Evidence on those inputs, not proof. |
| `PROVEN` | A Kontrol proof discharges it against the real bytecode. Phase R only, out of scope this pass. |

**Conformance is evidence, not proof.** A green suite means well-tested and still admitted.

**Nothing in this file is `PROVEN`.** That tier means a Kontrol proof against real deployed
bytecode. No rule here has one. `kprove` verdicts on the K definition are a different and
weaker thing — they discharge a theorem *given* the rules, which is what the `ADMITTED`/`TESTED`
column is for.

**`TESTED` is two-sided, and this pass had to say so out loud.** The merge added a large,
genuinely good Solidity conformance harness and no K-side execution at all. The tier definition
above now spells out what was previously only implied by the D-1 note further down: *no Solidity
test can kill a mutant in the K semantics*, so a Solidity-only case cannot move a K rule off
`ADMITTED` however many arms it covers.

### `conformance-verified` is not a fourth tier

`OPCODE-BACKLOG.md:16` introduced a status of that name and applies it to 13 opcodes. Its own
definition is:

> **conformance-verified** — modelled AND has concrete K claims + Solidity tests showing
> K↔production agreement

Taken literally — *has* claims, *has* tests — it is a statement about which **files exist**, not
about anything that ran. Nothing in the tree runs the K half (§C-1), and as the definition is
built the K half cannot even load. So:

**`conformance-verified` maps to `ADMITTED` here.** It is weaker than `TESTED`, not equal to it
and not stronger. It is recorded in this table as an external label so the mismatch is visible,
not adopted as a tier.

| External label | Where | Means here |
|---|---|---|
| `conformance-verified` | `OPCODE-BACKLOG.md:16` and 13 opcode rows | `ADMITTED` — artifacts exist on both sides; only the Solidity side has ever been executed |

The label is also applied **inversely to the evidence**. The three opcodes that do have executed
two-engine conformance — `0x23`, `0x53`, `0x90` — are labelled plain `modelled`
(`OPCODE-BACKLOG.md:35,61,84`). The 13 labelled `conformance-verified` are exactly the ones whose
K side has never run. Whoever owns that file should either run the K half or rename the status to
something like `conformance-drafted`.

## Instruction rules

The opcode set is **derived, not listed** — this table went stale once by being hand-maintained.
The derivation is `grep -o '#exec ( [0-9]*' semantics/swapvm.md semantics/opcodes/*.k`, which
yields decimal `0 1 2 3 4 32 35 36 37 38 43 44 45 48 49 50 83 144` — **18 opcodes**, hex
`00 01 02 03 04 20 23 24 25 26 2b 2c 2d 30 31 32 53 90`. Re-run it before trusting the table.
Re-derived after the merge: **the set is unchanged at 18.** The merge rewrote rules, it did not
add opcodes.

K rule line numbers are re-derived from the same grep — four files moved (`deadline.k`, `gte.k`,
`supplyshare.k`, `whitelists.k` were rewritten). Solidity locations are **function bodies**,
re-checked against `src/instructions/` at merge commit `30ec9c7`; `src/` was untouched by the
merge, so those are unchanged.

The two evidence columns are separate on purpose. `State` is their **conjunction**, because a
one-sided harness compares a model against itself.

| Opcode | Instruction | K rules | Implementation | K side executed | Solidity side executed | State |
|---|---|---|---|---|---|---|
| `0x00` | `Stop` | `opcodes/stop.k:48` | `Controls.sol:90-93` | no | **no — not in the dispatch table** | `ADMITTED` |
| `0x01` | `Revert` | `opcodes/revert.k:37` | `Controls.sol:85-87` | no — `conformance-concrete.k:45` never run | yes — `revert_unwinds` | `ADMITTED` |
| `0x02` | `Salt` | `opcodes/salt.k:40` | `Controls.sol:73` | no — `conformance-concrete.k:39` never run | yes — `salt_is_noop` (non-discriminating, D-3) | `ADMITTED` |
| `0x03` | `Jump` | `opcodes/jump.k:45,53` | `Controls.sol:79-82` | no — `conformance-concrete.k:52` never run | yes — `jump_overwrites_pc` | `ADMITTED` |
| `0x04` | `Extruction` | `opcodes/extruction.k:72,81` | `Extruction.sol:90-115` | no | **no — not in the dispatch table** | `ADMITTED` — and it is an abstraction, not a definition; see the abstraction log |
| `0x20` | `Deadline` | `opcodes/deadline.k:91,103,112` | `Controls.sol:131-134` | no — `deadline-concrete.k` never run | yes — `deadline_expired_reverts`, `_notExpired_passes` | `ADMITTED` |
| `0x23` | `OnlyTakerTokenBalanceNonZero` | `swapvm.md:183,189` | `Controls.sol:140-144` | **yes** — `krun` cases `catalogue`/`gateRejects` | yes — `holdingTakerGetsQuote`, `zeroBalanceTakerIsRejected` | **`TESTED`** |
| `0x24` | `OnlyTakerTokenBalanceGte` | `opcodes/gte.k:86,103,115` | `Controls.sol:161-166` | no — `gte-concrete.k` never run | yes — `gte_belowMin_reverts`, `_atMin_passes` | `ADMITTED` |
| `0x25` | `OnlyTakerTokenSupplyShareGte` | `opcodes/supplyshare.k:148,170,185` | `Controls.sol:171-178` | no — `supplyshare-concrete.k` never run | yes — `supplyShare_zeroSupply_reverts`, `_boundary_passes` | `ADMITTED` |
| `0x26` | `OnlyTxOriginTokenBalanceNonZero` | `opcodes/txorigin.k:98,113,123` | `Controls.sol:152-156` | no — `txorigin-concrete.k` never run | yes — `txOrigin_zeroBalance_reverts`, `_holdsBalance_passes` | `ADMITTED` |
| `0x2b` | `PrivateOrder` | `opcodes/privateorder.k:92,104,115` | `Whitelist.sol:105-110` | no — `conformance-concrete.k:97,104` never run | yes — `privateOrder_takerMatches`, `_takerRejected` | `ADMITTED` |
| `0x2c` | `WhitelistCoequal` | `opcodes/whitelists.k:311,325,339` | `Whitelist.sol:116-129` | no — `whitelistcoequal-concrete.k` never run | yes — but **both cases are non-discriminating**; see D-3 | `ADMITTED` |
| `0x2d` | `WhitelistSequential` | `opcodes/whitelists.k:364,375,390,404,415` | `Whitelist.sol:141-167` | no — `whitelistsequential-concrete.k` never run | yes — revert case discriminates, jump case does not (D-3) | `ADMITTED` |
| `0x30` | `JumpIfDirection` | `opcodes/jumps.k:51,59,67` | `Controls.sol:96-103` | no — `conformance-concrete.k:59,67` never run | yes — `jumpIfDirection_taken`, `_fallThrough` | `ADMITTED` — and see **DEFECT D-2**, now confirmed |
| `0x31` | `JumpIfTokenIn` | `opcodes/jumps.k:90,98,105` | `Controls.sol:109-115` | no — `conformance-concrete.k:75,82` never run | yes — but **both cases are non-discriminating**; see D-3 | `ADMITTED` |
| `0x32` | `JumpIfTokenOut` | `opcodes/jumps.k:121,129,136` | `Controls.sol:121-127` | no — `conformance-concrete.k:89` never run | one case, **non-discriminating**; see D-3 | `ADMITTED` |
| `0x53` | `LimitSwap` | `swapvm.md:252,256,266,275,283,292` | `LimitSwap.sol:40-53` | **yes** — `krun` cases `floorNotCeil`/`floorNonDividing`/`revPrices`/`revRecompute`/`revRecomputeOut` | yes — ten of the twelve Phase-1 cases | **`TESTED`** |
| `0x90` | `StaticBalances` | `swapvm.md:203,209,215` | `Balances.sol:37-47` | **yes** — `krun` case `catalogue` | yes — both orientations, `doubleBalancesReverts` | **`TESTED`** |

### Why fifteen of eighteen are still `ADMITTED` after a merge that looked like it fixed this

This is the point of the file, so the negative evidence is spelled out rather than implied. The
previous version of this table recorded the same 15/3 split. **The split did not change, but
three of the four reasons behind it did.** Re-derived, not carried forward:

**1. The Solidity conformance driver no longer refuses them — this reason is GONE.**
`InstructionConformance.t.sol:64-84` now has **sixteen** dispatch arms, not three:

    if (opcode == 0x23) _onlyTakerTokenBalanceNonZero(ctx, args);
    else if (opcode == 0x90) _staticBalancesXD(ctx, args);
    else if (opcode == 0x53) _limitSwap1D(ctx, args);
    else if (opcode == 0x01) _revert(ctx, args);
    ... 0x02 0x03 0x30 0x31 0x32 0x2b 0x20 0x24 0x25 0x26 0x2c 0x2d ...
    else revert("unmodelled opcode in conformance driver");

**And the dispatch routes to REAL instruction bodies, not to a stub.** The test contract is
`contract InstructionConformanceTest is Test, Controls, Balances, LimitSwap, Whitelist`
(`:46`) and each arm calls the inherited production method (`_deadline`, `_whitelistSequential`,
…). Only the table is the test's own, which is what the production VM generates anyway. Nothing
is reimplemented — this was checked by reading every arm, because a harness that transcribes an
instruction discharges nothing. It does not transcribe. 34 test functions, up from 12.

Two opcodes are still not routed: **`0x00` Stop and `0x04` Extruction hit the `else` and revert
with a driver error.** For `0x00` that is deliberate and documented at
`conformance-concrete.k:26-28` — the K rule leaves `<pc>` at the post-decode value while
`Controls.sol:91` sets `nextPC = type(uint256).max`, a real fidelity gap that a `pc` assertion
would surface as a mismatch. Deferring the case does not make the gap go away; `0x00` is the one
opcode where the two engines are **known** to disagree on an observable and no case asserts it.

**2. The K conformance harness still never executes them.** `conformance/run.sh` and its nix
twin `conformance/run-native.sh` were **not touched by the merge**. Both still carry the same
identical 11-case table, and every case's program bytes are still built from `\x23`, `\x90`,
`\x53`, plus `\x50` in `zeroArg` — and `0x50` is *unmodelled*, so that case exercises the
`[owise]` no-op, not an instruction rule. No case contains a `\x00`, `\x01`, `\x02`, `\x03`,
`\x04`, `\x20`, `\x24`, `\x25`, `\x26`, `\x2b`, `\x2c`, `\x2d`, `\x30`, `\x31` or `\x32` in
opcode position.

**3. The new K-side "harness" is seven files of `kprove` claims that nothing runs.** The merge
added `proofs/conformance-concrete.k` and six `*-concrete.k` companions — **7 files, 22 claims**
— whose headers state that agreement with the Solidity side "IS the conformance evidence". The
intent is right and the claim shapes are good. But:

- `run-proofs.sh:49-56` still enumerates **six** specs. None of the seven concrete files is in
  it. No other script in the tree invokes `kprove` on them.
- `proofs/README.md`'s full-suite audit predates them (it enumerates 36 files; there are 33) and
  records no verdict for any of them.
- **They cannot load against the definition `run-proofs.sh` builds.** Each imports the opcode
  module it needs — `imports SWAPVM-DEADLINE`, `SWAPVM-GTE`, `SWAPVM-SUPPLYSHARE`,
  `SWAPVM-TXORIGIN`, `SWAPVM-WHITELISTS`, `SWAPVM-REVERT`, `SWAPVM-SALT`, `SWAPVM-JUMP`,
  `SWAPVM-JUMPS`, `SWAPVM-PRIVATEORDER` — and `swapvm-haskell` contains none of them (C-1).

There is a silver lining worth recording: this is a **louder** failure mode than before. The old
`*-spec.k` files imported only `SWAPVM`, so they loaded and silently dispatched into the
`[owise]` no-op. The concrete files name the missing modules explicitly, so they fail to parse
rather than proving something vacuous.

**4. The mutation harness still never touches them.** `mutation/run-native.sh:44` stages exactly
`swapvm.md` and `lemmas.k`; `:48` and `:98` apply every mutation to `swapvm.md` alone; `:105-106`
restores only `swapvm.md`. The docker twin `mutation/run.sh:66-67,79` does the same. `opcodes/*.k`
is not copied and not mutated. Every rule in those twelve files is mutation-untested by
construction — unchanged by the merge.

**5. Solidity unit tests for these instructions exist and still do not count.**
`test/Controls.t.sol`, `test/Whitelist.t.sol` and `test/PrivateOrder.t.sol` exercise the real
bodies. They discharge nothing here, for the reason recorded under D-1: **no Solidity test can
kill a mutant in the K semantics.** They import only from `src/` and are structurally constant
under mutation of the model. The same argument now applies, uncomfortably, to the 22 new
`test_conformance_*` functions: they are excellent tests *of Solidity* and they are not evidence
*about a K rule* until the K half of each pair is run and agrees.

**6. And the modules are still not in any compiled definition** — see C-1, which the merge did
not address and which is now confirmed by execution rather than by reading.

### The two sides do not run identical bytes

The concrete files and the Solidity tests both assert they run "the SAME bytes". They do not,
quite, and this should not be discovered later by someone re-running them:

- `gte-concrete.k:52` uses `Int2Bytes(20, 1, BE)` for the token; the Solidity test patches the
  deployed `GateTokenMock` address. `gte-concrete.k:39-41` admits the placeholder.
- `txorigin-concrete.k:67` pins `#txOrigin() ==Int 771`; the Solidity test uses forge's runner
  EOA (`InstructionConformance.t.sol:508-509`).
- `supplyshare-concrete.k` pins `#totalSupply(1)` by premise; Solidity calls `setTotalSupply`.

None of these differences can change the asserted `pc`/`status`, so the comparison is defensible
— but it is a comparison of *outcomes on structurally matched inputs*, not a byte-for-byte
differential. `conformance/run.sh:11-16` already states this limitation for the Phase 1 trio; it
applies at least as strongly here.

## CORRECTION C-1 — the twelve opcode modules are not wired into any definition. **CONFIRMED BY EXECUTION**

**Previously recorded as a module-graph reading with the note "not verified by execution". It has
since been verified.** `proofs/README.md:68-84` reports a full-suite run dated 2026-07-26 which
found that the compiled `definition.kore` "contains exactly four modules and zero occurrences of
`DeadlineReached`, `WhitelistInvalidTaker`, or `InstructionRevert`". The reading was right.

The count in the previous heading was wrong: it said "fifteen opcode modules" while listing
twelve names. There are **twelve module files covering fifteen opcodes** — `SWAPVM-STOP`,
`SWAPVM-REVERT`, `SWAPVM-SALT`, `SWAPVM-JUMP`, `SWAPVM-JUMPS` (three opcodes),
`SWAPVM-EXTRUCTION`, `SWAPVM-DEADLINE`, `SWAPVM-GTE`, `SWAPVM-SUPPLYSHARE`, `SWAPVM-TXORIGIN`,
`SWAPVM-PRIVATEORDER`, `SWAPVM-WHITELISTS` (two opcodes). Corrected here.

**The merge did not touch the wiring. Re-checked against the files, not the audit:**

- `semantics/lemmas.k:1` is `requires "swapvm.md"` and nothing else. No `requires` of any
  `opcodes/*.k`.
- `semantics/lemmas.k:12-13` is `module SWAPVM-BYTES-LEMMAS` / `imports SWAPVM`. No sibling
  import.
- Every one of the twelve `opcodes/*.k` files opens with `requires "../swapvm.md"` and closes a
  module nothing imports. `grep -rn 'requires "' semantics/` finds exactly one live `requires` in
  the whole tree: `lemmas.k:1`.
- `run-proofs.sh:41-44` builds `swapvm-haskell` by `kompile --backend haskell lemmas.k`. That
  definition contains the decode loop, `0x23`, `0x90`, `0x53`, the bytes lemmas — and not one of
  the fifteen new rules.

Consequences, as measured in the 2026-07-26 run and re-derived for the post-merge tree:

- The 7 `*-concrete.k` files name the absent modules directly, so they **do not parse**. Exit
  code 113 is what the audit recorded for the analogous pre-merge files.
- The 10 surviving `*-spec.k` / `*-control.k` pairs for `0x00`–`0x04`, `0x26`, `0x2b`, `0x30`–`0x32`
  import only `SWAPVM`, so they load and dispatch `#exec(N, ARGS)` into the `[owise]`
  unknown-opcode no-op at `swapvm.md:349-351`.
- The audit performed the decisive experiment without meaning to: *"The as-committed run is the
  experiment 'delete every new instruction rule and see whether the controls still fail
  correctly.' They do. So no control's failure is evidence of anything."*
  (`proofs/README.md:82-84`.)
- And it found the mirror image: `salt-spec.k` with its `<trace>` cell anonymised **proves against
  the as-committed definition, which has no Salt rule at all** (`proofs/README.md:162-164`). Its
  only discrimination against the unknown-opcode no-op is the trace entry. That is the
  vacuous-green failure this file exists to catch, caught.

**A `wired` scratch experiment exists and is not the repo.** `proofs/README.md:88-89` describes a
scratch `lemmas.k` with the fifteen `requires` and fifteen `imports` added. Under it, all fifteen
specs prove and all fifteen controls fail. **That is a verdict about a file that is not in this
repository**, and the merge has since deleted six of those specs and six of those controls.
Nothing in the tree, at any commit, has ever been proved against a definition that contains an
opcode module.

**Documents that assert the wiring already exists.** `opcodes/revert.md:97-98` instructs the
reader to add `imports SWAPVM-REVERT` "alongside the existing `imports SWAPVM` and `imports
SWAPVM-STOP`" — `lemmas.k` has no `imports SWAPVM-STOP`. `OPCODE-BACKLOG.md:111` says the modules
"must be wired into `lemmas.k`" and points at `opcodes/README.md`, a file that does not exist; it
also still lists only five module names where there are twelve. The first is
stale-in-the-past-tense; the second is honest and incomplete.

**Not verified in this environment.** No `kompile`, `kprove`, `krun`, `kontrol`, `forge` or `nix`
on `PATH`; no `semantics/swapvm-llvm/` or `swapvm-haskell/` in the tree; no Kontrol proof store.
`docker` is present. The confirmation above is quoted from `proofs/README.md`'s recorded run, and
that run **predates the merge** — so it confirms the wiring defect (unchanged) but not any verdict
about the reworked rules. **The one-line fix is still unapplied, and it is the highest-value
action available anywhere in this file.** This file does not own `lemmas.k` or `proofs/`.

## DEFECT D-2 — `0x30` reintroduces the D-1 precedence bug. **CONFIRMED. Survives the merge.**

Previously recorded here as "flagged, not yet reproduced". It has since been reproduced, and the
merge left it in place. `opcodes/jumps.k:55-56` and `:62-63`, verbatim at `30ec9c7`:

    requires lengthBytes(ARGS) ==Int 3
     andBool (ARGS [ 0 ] =/=Int 0) ==Bool (TIN <Int TOUT)

The two *operands* are parenthesised. The *comparison* is not. `==Bool` and `=/=Bool` sit in the
loosest priority block, below `andBool` (`domains.md:1128-1130`), so this compiles as

    ( lengthBytes(ARGS) ==Int 3 andBool (ARGS [ 0 ] =/=Int 0) ) ==Bool ( TIN <Int TOUT )

**Machine-checked** (`proofs/README.md:166-181`): a scratch claim that a 4-byte-args `0x30` must
revert `UNMODELLED-ARGS-LENGTH` **fails**, with residual `<pc> 10`, `<status> Running` under
`false ==Bool TIN <Int TOUT`; adding two pairs of parentheses makes the same claim **prove**.

`grep -n '==Bool\|=/=Bool'` across `swapvm.md`, `opcodes/*.k` and `lemmas.k` returns exactly
seven rule-level hits: five in `swapvm.md` (`:260,273,281,290,298`), all carrying the D-1 fix
`andBool ( ... ==Bool ( ... ) )`, and `jumps.k:56` and `:63`, which do not. `0x31` and `0x32` use
`==Int`, which binds tighter than `andBool`, and are unaffected.

The damage, corrected against the audit's residual:

- **Canonical length** (`lengthBytes(ARGS) ==Int 3`): the swallowed conjunct is `true`, so the
  compiled guard coincides with the intended one. The canonical branch is *accidentally* correct
  — which is precisely why a canonical-only test never catches this, the same blind spot that let
  D-1 survive. Both `0x30` conformance cases are canonical-length, on both engines.
- **Non-canonical length**: the left side is `false` whatever `ARGS[0]` is, so the jump arm's
  guard collapses to `TIN >=Int TOUT` and the fall-through arm's to `TIN <Int TOUT`. Exactly one
  of those always holds — and the `UNMODELLED-ARGS-LENGTH` arm holds too. **Two of the three rules
  are enabled simultaneously on every non-canonical `0x30`**, defeating the very guard that arm
  was written to protect. Worse, the jump arm then evaluates `substrBytes(ARGS, 1, 3)` on an args
  that may be shorter than three bytes.

`jumpifdirection-spec`/`-control` return 0/1 with and without the parentheses, so **the pair's
verdict is not evidence about this defect** — which is the second time in this file that a
green control has meant nothing.

D-1's recorded lesson said keeping priorities "would mask the next overlap the same way". This is
the next overlap, it arrived without priorities, and it has now survived a merge that rewrote four
neighbouring opcode files. The fix is the D-1 fix:
`andBool ( (ARGS [ 0 ] =/=Int 0) ==Bool (TIN <Int TOUT) )`.

`opcodes/jumps.k` is owned by another pass; this file does not edit it.

## DEFECT D-3 — four of the new conformance cases cannot fail. **NEW, found this pass**

**Found by construction-checking the new cases, on both engines.** The decode loop advances
`<pc>` to `2 + argsLen` for every instruction regardless of what the instruction body does. So any
case whose only assertion is `pc == 2 + argsLen` with `status Running` **is passed by a no-op** —
it survives deleting the rule it is supposed to test.

That is unavoidable for a pass-arm case, and harmless when its partner case asserts something
else. The defect is that in four places the *jump target was chosen equal to `2 + argsLen`*, so
the taken and not-taken cases assert the **same** final `pc` and neither can distinguish the
branch from the fall-through, or either from rule deletion:

| Opcode | Cases | argsLen | fall-through `pc` | jump target | Discriminates? |
|---|---|---|---|---|---|
| `0x31` `JumpIfTokenIn` | `conformance-concrete.k:75,82` + `jumpIfTokenIn_taken`/`_fallThrough` | 22 | 24 | **24** | **no — both cases assert 24** |
| `0x32` `JumpIfTokenOut` | `conformance-concrete.k:89` + `jumpIfTokenOut_taken` | 22 | 24 | **24** | **no** — and there is no fall-through case at all, on either engine |
| `0x2c` `WhitelistCoequal` | `whitelistcoequal-concrete.k` A/B + `whitelistCoequal_match_jumps`/`_noMatch_fallsThrough` | 12 | 14 | **14** | **no — both cases assert 14** |
| `0x2d` `WhitelistSequential` | `whitelistsequential-concrete.k` A + `whitelistSequential_match_jumps` | 19 | 21 | **21** | **no** (its partner case B asserts a revert and does discriminate) |
| `0x30` `JumpIfDirection` | `conformance-concrete.k:59,67` + `jumpIfDirection_taken`/`_fallThrough` | 3 | 5 | 9 | **yes** |
| `0x03` `Jump` | `conformance-concrete.k:52` + `jump_overwrites_pc` | 2 | 4 | 5 | **yes** |

`whitelistcoequal-concrete.k:46-48` states the coincidence in its own comment without drawing the
conclusion: *"Both end at `<pc>` 14 = program length: scenario A because the jump target IS 14,
scenario B because the FALL-THROUGH arm inherits the decode-advanced pc (2 + 12 = 14)."*

**Consequence.** `0x2c` has, on both engines, **zero discriminating evidence of any kind**: its
three rules are JUMP, FALL-THROUGH and `UNMODELLED-ARGS-LENGTH`; the first two are covered only by
these two indistinguishable cases and the third by nothing. `0x31` and `0x32` are the same. This
is `0x2c`/`0x31`/`0x32` *labelled* `conformance-verified` in `OPCODE-BACKLOG.md`.

**The fix is one literal per case**: make the jump target differ from `2 + argsLen` — e.g. target
`30` on a 24-byte `0x31` program — on both engines. Cheap, and it converts four vacuous cases into
real ones. It also has to be done before the concrete claims are ever run, or they will come back
green and mean nothing, which is the exact failure C-1 and D-1 both already produced once.

Not reproduced by execution: no toolchain here. The argument is arithmetic on the decode rule
(`swapvm.md:143`, `VM.sol:118-150`) and the literals in the cases, both of which are in the tree.

## DEFECT D-1 — FIXED. `0x53` diverged on reversed token order

**Found by conformance, on a clean build, reproducible.** The semantics was WRONG for
exact-in when `tokenIn > tokenOut`.

| case | direction byte | Solidity | K |
|---|---|---|---|
| `tokenIn < tokenOut` | `0x01` | prices | prices ✓ |
| `tokenIn > tokenOut` | `0x00` | **prices** (`amountOut = 0.5e18`) | **`Reverted("LimitSwapRecomputeDetected")`** ✗ |
| `tokenIn < tokenOut` | `0x00` | mismatch | mismatch ✓ |
| `tokenIn > tokenOut` | `0x01` | mismatch | mismatch ✓ |

**The real cause is operator precedence, not rule selection.** K's `==Bool` and `=/=Bool` sit at
the *bottom* of the `Bool` grammar, below `andBool`. So

    requires BIN >Int 0 andBool BOUT >Int 0 andBool AOUT ==Int 0
     andBool #makerDirLt(ARGS) ==Bool ( TIN <Int TOUT )

compiled as **`(BIN>0 ∧ BOUT>0 ∧ AOUT==0 ∧ makerDirLt) ==Bool (tokenIn<tokenOut)`** — the whole
conjunction compared against the direction. Confirmed by reading `swapvm-llvm/compiled.txt`.

Consequence: whenever `makerDirLt` and `tokenIn<tokenOut` are **both false** — the reversed
branch, half of all token pairs — both sides are `false` and the guard is `true`
**unconditionally, for every `amountOut`**. The pricing rule and the recompute rule were not
mutually exclusive; both were permanently enabled.

**My `[priority(50)]/[priority(60)]` fix only chose between two always-enabled rules**, and it
chose wrong in the other direction: it traded a spurious *revert* for a spurious *price*. That is
strictly worse — a false revert is a false negative, a false price defeats the single-assignment
safety guard entirely.

**The correct fix is to parenthesise** — `andBool ( #makerDirLt(ARGS) ==Bool ( TIN <Int TOUT ) )`
— after which all six rules are genuinely disjoint and **the priorities are deleted**, because
keeping them would mask the next overlap the same way. Verified on a clean rebuild with no
priorities, all four rows correct including the two the priority fix had broken.

**The "lesson" previously recorded here — *"overlapping rules need explicit priorities even when
their side conditions look disjoint"* — was FALSE and has been deleted.** K never applies a rule
whose `requires` evaluates to `false`; priority only orders rules whose guards all hold. The side
condition was never being ignored — it was a *different* side condition than the one written. Two
real lessons replace it:

1. **Parenthesise every `==Bool` / `=/=Bool`.** They bind looser than `andBool`, so an
   unparenthesised comparison silently swallows the preceding conjunction.
2. **Read the compiled guard, not the source guard.** `compiled.txt` shows what K actually built.

**Lesson 1 was not applied to the opcodes merged after it was written, and still has not been.**
See D-2 above, now confirmed by a machine-checked scratch claim.

**Downgraded once already.** A reviewer established that `semantics/conformance/run.sh` had been
broken since Phase 1 — it passed only `$PGM` while the configuration had grown six more variables,
so `krun` failed on the first case and **the K engine executed no program at all** under the
shipped harness. Every mutant to `swapvm.md` survived it trivially. `run.sh` is now repaired, with
per-case configuration and an added gate-rejection case.

Mutation testing then found the suite missed: exact-in rounding direction, all three secondary
revert arms, and the orientation branch. Six tests were added; one of them found D-1. Removing the
parentheses again now fails `revPrices` — verified by doing exactly that.

Still **not `PROVEN`**: evidence on a handful of inputs, not a proof over all inputs.

## Generic bytes lemmas

`semantics/lemmas.k`. Not domain facts — definitional identities about `+Bytes`, `substrBytes`,
`Int2Bytes`, `Bytes2Int` that plain K does not ship. Without them a symbolic program built by
concatenation cannot be decoded at all: the prover cannot reduce
`(b"\x23\x14" +Bytes ... +Bytes TAIL) [ 0 ]` to `0x23`.

| Lemma | State | Note |
|---|---|---|
| `lengthBytes` of concat | `ADMITTED` | definitional |
| `lengthBytes(Int2Bytes(N,..)) => N` | `ADMITTED` | requires `N >= 0` |
| index into left operand | `ADMITTED` | requires `I < lengthBytes(B1)` |
| slice within left / within right | `ADMITTED` | side conditions make them total |
| full-width slice is identity | `ADMITTED` | requires `E == lengthBytes(B)` |
| `Bytes2Int ∘ Int2Bytes` round-trip | `ADMITTED` | requires `V < 2^(8N)`; the bound is what makes it exact rather than truncating |
| index into **right** operand | `ADMITTED` | added in Phase 2; without it the opcode and args-length bytes of any instruction after the first cannot be read |
| slice **straddling** the concatenation point | `ADMITTED` | added in Phase 2; splits at the boundary |

Nine rules, **unchanged by the merge** — `lemmas.k` is byte-identical at `7fef407` and `30ec9c7`.
Every theorem and every claim below therefore inherits `ADMITTED` from this table alone, before
any question about the instruction rules is reached. The `*-concrete.k` files import
`SWAPVM-BYTES-LEMMAS` too, so this applies to them as well.

**Correction to the "side conditions make them total" claim above: it is not literally true of the
two Phase 2 additions.** Neither carries an upper bound (`I < len(B1)+len(B2)`;
`E <= len(B1)+len(B2)`). A review verified this is nonetheless **not exploitable**, but for a
different reason than totality: K's `Bytes[_]` is genuinely partial, so out of range both sides of
the rule are equally stuck. There is no totalizing default the lemma could contradict. Sound, but
the justification recorded here was the wrong one.

The five slice/index rules were also checked for the D-1 hazard and are **pairwise disjoint**:
left-index (`I < len B1`) vs right-index (`len B1 <= I`); within-left (`E <= len B1`) vs
within-right (`len B1 <= S`) vs straddle (`S < len B1 < E`). The only overlap is straddle against
the full-width identity rule, and they are confluent.

## Decode loop

| Component | Implementation | State | Notes |
|---|---|---|---|
| fetch/decode/dispatch | `VM.sol:118-150` | `TESTED` | `opcode = shr(248,w)`, `argsLen = and(shr(240,w),0xff)`, `pc += 2 + argsLen` |
| program-length bound | `VM.sol:143` | `TESTED` | reverts `RunLoopExceedProgramLength` when `pcs > length` |

Discharged by `semantics/conformance/run.sh` — **eleven** programs agree on final `pc`, revert
status and `amountOut` across both engines, plus **forty** Solidity-side test functions
(`RunLoopConformance.t.sol` 6, `InstructionConformance.t.sol` 34). This is the one row the merge
strengthened without qualification: every new instruction case also exercises the loop, and the
loop is in the compiled definition, so both engines really do run it.

**`TESTED`, not `PROVEN`**: evidence on those inputs, not a proof over all programs.

**Counts re-derived, not carried forward.** `grep -c 'function test'` gives 34 and 6;
`conformance/run.sh` carries 11 cases. The previous version of this section said "eighteen
Solidity-side test functions", correct before the merge and stale now.

Conformance already caught one drift. The first version of the K bound-check rules reverted with
`pc` still at the instruction start, while the real VM reports the *advanced* value — `(91, 90)`
where the model said `88`. Both reverted with the same reason, so only a test that inspects the
revert arguments distinguishes them. Fixed to advance before checking.

## Theorems and what they rest on

A theorem inherits the **weakest** state among the instructions it touches.

`semantics/proofs/` holds **33** `.k` files, down from 36. Three kinds, and they must not be
conflated:

| Kind | Count | What it is |
|---|---|---|
| `*-spec.k` | 13 | A symbolic universal claim asserted to PROVE. A theorem. |
| `*-control.k`, `negative-control.k`, `pricing-negative-control.k` | 12 | A claim known to be FALSE, asserted to FAIL. **Not a theorem.** |
| `control-sensitivity.k` | 1 | A control's twin: same premises, correct conclusion, must PROVE. A theorem. |
| `*-concrete.k` | 7 | **New with the merge.** Fully concrete input, asserted to PROVE. Not a universal theorem — a `kprove`-executed test case. |

13 + 12 + 1 + 7 = 33.

### What a `*-concrete.k` is, and what it is worth

Characterised from the files, because the merge introduced the kind and no document defines it.
Each claim fixes the program bytes, the registers and (where needed) the uninterpreted
environment symbol by premise, then asserts an exact final `<pc>` and `<status>`. The headers
justify the form: `krun` hangs on revert-producing cases in that environment for both backends, so
`kprove` on a fully concrete configuration is used as a substitute execution
(`conformance-concrete.k:1-8`).

That is a legitimate and rather clever move. Its worth, stated exactly:

- **A concrete claim is worth roughly one `krun`, not one theorem.** It says "this input reaches
  this state", quantified over nothing. It cannot replace the universal `*-spec.k` it deleted, and
  the headers are honest that it does not try to.
- **It is only worth that once it is run.** None has been. See C-1 and reason 3 above.
- **A PASS-arm concrete claim is vacuous-green-prone by construction.** The `[owise]` no-op
  advances `<pc>` identically, so it proves with the rule deleted — the `salt-spec.k` pattern the
  audit already caught. Of the 22 claims, the discriminating ones are the seven that assert a
  `Reverted(...)` status plus `jump` (`pc 5 ≠ 4`) and `jumpIfDirection`-taken (`pc 9 ≠ 5`). The
  other thirteen assert a `pc` the no-op would also produce; four of those are D-3.
- **Five opcodes lost their negative control and did not get a replacement.** `deadline-control.k`,
  `gte-control.k`, `supplyshare-control.k`, `whitelistcoequal-control.k` and
  `whitelistsequential-control.k` were deleted by the merge. `0x20`, `0x24`, `0x25`, `0x2c`, `0x2d`
  now have **no must-fail claim of any kind**. Per this file's own rule — a proof that cannot fail
  proves nothing — a concrete claim needs a discriminating partner just as a spec needs a twin,
  and the revert-arm scenarios are doing that job for three of the five while `0x2c` has none.

### The table

`as-merged` verdicts are quoted from the full-suite run recorded at `proofs/README.md:92-114`
(K v7.1.337, Haskell backend, `kontrol` container, 2026-07-26). **That run predates this merge.**
Rows whose spec file and whose K rules were both untouched by the merge keep their verdict; rows
whose rules were rewritten, or whose files the merge deleted or added, do not.

| File | Kind | Depends on | Effective state | Verdict on record |
|---|---|---|---|---|
| `gate-spec.k` (T0) | spec | `0x23`, decode loop, bytes lemmas | `ADMITTED` | **`#Top`** (exit 0) |
| `pricing-spec.k` (T1) | spec | `0x23`, `0x90`, `0x53`, decode loop, bytes lemmas | `ADMITTED` | **`#Top`** |
| `pricing-exactout-spec.k` (T2) | spec | same as T1 | `ADMITTED` | **`#Top`** |
| `control-sensitivity.k` | twin, must PROVE | `0x23`, decode loop, bytes lemmas | `ADMITTED` | **`#Top`** |
| `stop-spec.k` | spec | `0x00` — **not in the definition** | **VOID** | exit 1 as-merged; 0 only under the scratch `wired` `lemmas.k` |
| `revert-spec.k` | spec | `0x01` — not in the definition | **VOID** | exit 1 as-merged; 0 wired |
| `salt-spec.k` (2 claims) | spec | `0x02` — not in the definition | **VOID** | exit 1 as-merged; 0 wired. **Proves with the rule absent** once `<trace>` is anonymised |
| `jump-spec.k` | spec | `0x03` — not in the definition | **VOID** | exit 1 as-merged; 0 wired |
| `extruction-spec.k` | spec | `0x04` — not in the definition; **an abstraction** | **VOID** | exit 1 as-merged; 0 wired |
| `txorigin-spec.k` | spec | `0x26`, `#txOrigin` — module absent | **VOID** | **113** (parse failure) as-merged; 0 wired. Non-vacuity unestablished: `#balanceOf` does not reduce under a symbolic holder |
| `privateorder-spec.k` | spec | `0x2b` — not in the definition | **VOID** | exit 1 as-merged; 0 wired. Premise-flip control, **no sensitivity twin** |
| `jumpifdirection-spec.k` | spec | `0x30` — not in the definition | **VOID** | exit 1 as-merged; 0 wired. **Verdict unchanged with and without the D-2 bug** — carries no information about it |
| `jumpiftokenin-spec.k` | spec | `0x31` — not in the definition | **VOID** | exit 1 as-merged; 0 wired |
| `jumpiftokenout-spec.k` | spec | `0x32` — not in the definition | **VOID** | exit 1 as-merged; 0 wired |
| `conformance-concrete.k` (10 claims) | concrete | `0x01`,`0x02`,`0x03`,`0x2b`,`0x30`,`0x31`,`0x32` — modules absent | **VOID — never run** | **none.** Does not parse as-merged; not in `run-proofs.sh` |
| `deadline-concrete.k` (2) | concrete | `0x20`, `#blockTimestamp` — module absent | **VOID — never run** | **none** |
| `gte-concrete.k` (2) | concrete | `0x24` — module absent | **VOID — never run** | **none** |
| `supplyshare-concrete.k` (2) | concrete | `0x25`, `#totalSupply` — module absent | **VOID — never run** | **none** |
| `txorigin-concrete.k` (2) | concrete | `0x26`, `#txOrigin` — module absent | **VOID — never run** | **none** |
| `whitelistcoequal-concrete.k` (2) | concrete | `0x2c` — module absent | **VOID — never run**, and **non-discriminating even if run** (D-3) | **none** |
| `whitelistsequential-concrete.k` (2) | concrete | `0x2d`, `#blockTimestamp` — module absent | **VOID — never run**; scenario A non-discriminating (D-3) | **none** |

Every row is `ADMITTED` or worse. For T0/T1/T2 and `control-sensitivity.k` that is the bytes
lemmas dominating three `TESTED` instructions — the ordinary weakest-dependency result, and those
four verdicts are real.

For the other nineteen it is stronger than `ADMITTED`, which is why they are marked **VOID**
rather than given a tier: the rule they rest on is not in the definition the prover builds, so
neither a pass nor a fail carries information. **Do not read them as "proved but admitted".**
Ten were "written, run, failed for the wrong reason". Seven are "written, never run". Six were
"written, run, then deleted and replaced" — their verdicts described predicate-form rules that no
longer exist.

Three specs carry an extra dependency worth naming separately: `extruction-spec.k` is a claim
about an **abstraction**, not about the instruction, as are the two whitelist concrete files to a
lesser degree since the merge. See the abstraction log.

### T1, unchanged

**T1** (`kprove` returns `#Top`) — `semantics/proofs/pricing-spec.k`. Runs the whole
three-instruction program with `amountIn` and both maker reserves **symbolic**, and pins the quote
to exactly the floor of the maker's rate:

    amountOut * balanceIn <= amountIn * balanceOut          (maker safety)
    (amountOut + 1) * balanceIn > amountIn * balanceOut     (taker safety)

Both bounds are required: the first alone is satisfied by returning 0, the second alone by
returning something huge. Together they determine `amountOut` uniquely.

This is the first theorem here about the **money** rather than about access control, and it proves
the rounding decision `LimitSwap.sol:49` documents as intentional — the sub-wei remainder goes to
the maker on every fill.

Negative control `pricing-negative-control.k` — the same claim with the maker-safety inequality
reversed — **fails as required**, at `pc 91`, with the real quote in the register.

**Caveat that must travel with T1, stated exactly.** `LimitSwap.sol:49` is plain checked
arithmetic — no `mulDiv` — so the divergence condition is precise: **K and the EVM differ iff
`amountIn * balanceOut >= 2^256`**, where the EVM reverts `Panic(0x11)` and K computes. Below that
they agree exactly, and the quotient is then also below `2^256`, so there is no second gap.

**The `amountIn < 2^256` hypothesis does not bound the product, and is inert** — a review deleted
it and the claim still proves. So T1 holds for arbitrarily large `amountIn`, including the region
where the EVM would revert. `amountIn` is taker-chosen, so the divergence is reachable by
construction for any `balanceOut`, at `amountIn >= 2^256 / balanceOut`.

Read T1 as *"given the product does not overflow"*.

### T0, unchanged

**T0** (`kprove` returns `#Top`) — `semantics/proofs/gate-spec.k`. For any program beginning
`0x23 0x14 G`, with `TAIL` symbolic, a taker holding zero `G` ends
`Reverted("TakerTokenBalanceIsZero")`. `TAIL` is never decoded, because `#revert` discards the
continuation, so the proof does not case-split on it.

Effective state is `ADMITTED` because the bytes lemmas are admitted, even though all three
instructions are `TESTED`. The theorem inherits the weakest dependency.

## Coverage

Derived, never hand-listed — the previous number went stale by being typed.

- `src/libs/OpcodeList.sol` declares **256** enum slots, of which **52 are named** and 204 are
  reserved `_xx`. (Counted by matching `/* hh */ Name` and excluding `_hh`.)
- The K semantics models **18** — `grep '#exec ( ' semantics/swapvm.md semantics/opcodes/*.k`.
- So: **18 of 52 named opcodes**.
- Of the 52 named, **6 are debug-bank entries** (`0x10`–`0x14`, `0x1a`) wired only into the
  `*Debug` opcode sets. **46 are production-dispatched**, so the modelled fraction of what
  actually runs is **18 of 46**, leaving **28 unmodelled-but-dispatched**. Each of those 28 is a
  live soundness hazard: it falls through to the `[owise]` no-op (`swapvm.md:349-351`) while
  production either runs real logic or reverts `UnknownOpcode`.

Second-order coverage, which is the number that actually moved this merge:

- **3 of 18** modelled opcodes are `TESTED` — unchanged.
- **16 of 18** are now dispatched to real production bodies by the Solidity conformance driver,
  up from 3. Not `0x00`, not `0x04`.
- **0 of 15** of the new opcodes have any K-side execution. Unchanged.
- **0 of 33** proof files can be run against a definition containing an opcode module. Unchanged.

### Files outside this one that still state an outdated number

This pass edits only `semantics/axioms.md`. Each of these was re-checked against the current file
and still needs the correction; I did not make it.

| Location | Says | Should say |
|---|---|---|
| `semantics/DEMO.md:149` | heading "Coverage: 3 of 52 opcodes" | 18 of 52 |
| `semantics/DEMO.md:151-152` | "implements **three** — `0x23`, `0x90`, `0x53`" | the 18-opcode set |
| `semantics/DEMO.md:128-130` | "All three instruction rules and the decode loop are `TESTED`" | three are `TESTED`; fifteen are `ADMITTED` |
| `semantics/DEMO.md:147` | "21 Solidity tests, 11 K conformance cases" | 40 and 11 — was already wrong at 18, and the merge moved it to 40 |
| `semantics/proofs/README.md:3` | "Six files. **Two of them are supposed to FAIL.**" | 33 files; 12 supposed to fail |
| `semantics/proofs/README.md:52` | "Every instruction rule is `TESTED`" | three are `TESTED`, fifteen `ADMITTED` |
| `semantics/proofs/README.md:56` | "models **3 of the 52** named opcodes" | 18 of 52 |
| `semantics/proofs/README.md:65` | "36 `.k` files: the six above plus **15 new spec/control pairs**" | 33 files, and six of those pairs no longer exist |
| `semantics/proofs/README.md:92-114` | verdict table lists `deadline`, `gte`, `supplyshare`, `whitelistcoequal`, `whitelistsequential` spec/control pairs | those ten files were deleted by the merge; the verdicts describe rules that no longer exist |
| `semantics/OPCODE-BACKLOG.md:5` | "47 opcodes are wired to handlers; 3 are modelled (`0x23`, `0x53`, `0x90`); the other 44 are below" | contradicts its own `:110` — 46 dispatched, 18 modelled |
| `semantics/OPCODE-BACKLOG.md:111` | lists five sibling modules to wire | there are twelve; and it points at `opcodes/README.md`, which does not exist |
| `semantics/run-proofs.sh:12,49-56` | six specs, "Two of the six specs are supposed to FAIL" | 33 files; the seven `*-concrete.k` are run by nothing |
| `VERIFY.md:156` | "3 of 52 opcodes are modelled in K" | 18 of 52 |
| `demo/README.md:67` | "3 of 52 opcodes are modelled" | 18 of 52 |
| `demo/server.py:248` | citation string "`DEMO.md` §5a — 3 of 52 opcodes modelled" | tracks whatever §5a becomes |
| `demo/data/proofs.json` | 36 entries, including 10 deleted files; no `*-concrete.k` | regenerate from `gen_data.py` |
| `semantics/opcodes/whitelists.k:40-90` | header prose still describes `#coequalWhitelistContains` / `#sequentialWhitelistJumps` / `#sequentialWhitelistReverts` as the live modelling | those predicates were replaced by `#coequalContains` / `#seqOutcome` in the same file, `:181-196` and `:259-290` |
| `semantics/proofs/conformance-concrete.k:20-28` | "Deadline, Gte, SupplyShare, TxOrigin, both Whitelists … are conformance-untestable in the current modelling" | six `*-concrete.k` files for exactly those opcodes were added in the same merge |

`demo/gen_data.py` is correct and is where the derivation in this file came from: `:87-99` scans
`#exec` across `swapvm.md` and `opcodes/*.k`, and `:131` now classifies controls on the
**suffix** `-control` rather than the substring, which fixes the `control-sensitivity.k`
misclassification recorded as contradiction 4 in the previous version of this file. **That
correction is confirmed in the generator and not yet reflected in the committed
`demo/data/proofs.json`**, which still predates the merge entirely. Note also that `gen_data.py`
has no case for `*-concrete.k` and will classify all seven as `theorem` / expected `#Top`; per the
kind table above they are executed test cases, not theorems.

## Contradictions between the docs and the files

Recorded, not silently fixed. Each is checkable in one command.

1. **`OPCODE-BACKLOG.md` contradicts itself, still.** Line 5: "47 opcodes are wired to handlers;
   3 are modelled". Line 110: "18 modelled (3 in `swapvm.md` + 15 in `semantics/opcodes/`), 28
   unmodelled-but-dispatched = 46 dispatched total." The count line is right on both figures; the
   header is stale on both. Every per-opcode row in between is flipped to **modelled** or
   **conformance-verified**, so the header disagrees with the table directly beneath it.
2. **`OPCODE-BACKLOG.md` applies `conformance-verified` inversely to the evidence.** The three
   opcodes with executed two-engine conformance are labelled `modelled`; the thirteen labelled
   `conformance-verified` have no executed K side. See the tier section.
3. **`proofs/README.md` describes a directory that no longer exists**, twice over: "Six files"
   (there are 33) at `:3`, and "36 `.k` files" at `:65`. Ten files in its verdict table were
   deleted by the merge.
4. **`run-proofs.sh` enumerates six specs.** The other twenty-seven files are run by no script in
   the tree, which is why no verdict exists for them — including all seven of the merge's new
   concrete-conformance files, whose entire purpose is to be run.
5. **`conformance-concrete.k:20-28` declares six opcodes conformance-untestable** in the same
   merge that added conformance files for all six. The header was written against the pre-rework
   predicate form and not updated when the reworks landed alongside it.
6. **`opcodes/revert.md:97-98` claims an import that is not there** — "alongside the existing
   `imports SWAPVM` and `imports SWAPVM-STOP`". `lemmas.k:12-13` imports only `SWAPVM`. See C-1.
7. **`OPCODE-BACKLOG.md:111` points at `semantics/opcodes/README.md`**, which does not exist, and
   names five of the twelve modules.
8. **`demo/data/proofs.json` is a snapshot of a deleted directory.** 36 entries; 10 name files
   that are gone; none of the 7 concrete files appears.

That is eight, on top of the five this project has already found and fixed. The pattern is
consistent and worth naming: **every stale claim in this tree has been a count or a status copied
forward by hand.** Everything in this file that is a count is now derived by a command that is
written next to it.

## Abstraction log

Records every firing of the `PLAN.md` D3/D4 trigger — an instruction weakened from an exact
definition to axioms, with the measurement that forced it. Empty is the good state.

**The merge shrank this log substantially, and that is the single best thing in it.** Four of the
six entries have been retired. Uninterpreted symbols in the tree dropped from **nine to three**
— `grep -rn 'no-evaluators' semantics/opcodes/*.k semantics/swapvm.md` now returns declarations
for `#blockTimestamp()` (`deadline.k:79`), `#txOrigin()` (`txorigin.k:81`) and `#totalSupply(Int)`
(`supplyshare.k:131`) and nothing else.

### Still open

| Opcode | Weakened to | What forced it |
|---|---|---|
| `0x04` `Extruction` | `#revert("ExtructionUnmodelled")` on every canonical call (`extruction.k:72`) | The instruction delegates to `I{Static,}Extruction(target)` at a **maker-chosen address**, and the return triple overwrites `<pc>`, the chop cursor and the **entire** `<swap>` cell. Modelling it soundly means modelling arbitrary code. Strategy (A) — loud revert — was chosen over (B) — fresh symbolic cells — because (B) risks vacuous proofs unless every premise is load-bearing (`extruction.k:28-39`). |
| `0x20` `Deadline` | `#blockTimestamp()` uninterpreted (`deadline.k:79`) | `block.timestamp` is an environment input (D4). Irreducible; a concrete claim must pin it by premise. |
| `0x25` `OnlyTakerTokenSupplyShareGte` | `#totalSupply(_)` uninterpreted (`supplyshare.k:131`) | `totalSupply()` is an external call (D4). Same shape. |
| `0x26` `OnlyTxOriginTokenBalanceNonZero` | `#txOrigin()` uninterpreted (`txorigin.k:81`) | `tx.origin` is an environment input (D4). |
| `0x00` `Stop` | `<pc>` left at the post-decode value (`stop.k:39-48`) | Not a D3/D4 abstraction but a **known fidelity gap**: `Controls.sol:91` sets `nextPC = type(uint256).max`. Modelling it literally forced the prover to discharge every decode side condition against `2^256 + …` and stalled at 24+ branches. Recorded in `stop.md` as a nuance; it is the reason `0x00` is excluded from the conformance driver. |

### Retired by the merge, with the evidence

| Opcode | Was | Now | Why this counts as retired |
|---|---|---|---|
| `0x20` `Deadline` | `#deadlineExceeded(_)` uninterpreted **Bool predicate** | direct `#blockTimestamp() >Int DL` / `<=Int DL` (`deadline.k:94,106`) | The predicate was the arm-selection workaround. With it, a spec assuming `#deadlineExceeded(DL)` and a rule branching on the same symbol were the same statement — the proof established nothing about the underlying comparison. The environment symbol remains; the tautology does not. |
| `0x24` `OnlyTakerTokenBalanceGte` | `#balanceLtMin(TOK, MIN)` uninterpreted | direct `#balanceOf(B, TOK, TAKER) <Int MIN` / `>=Int MIN` (`gte.k:92,109`) | **This one had been shown to be vacuous.** `#balanceLtMin` took only the token and the minimum; the rules bound `<taker>` and `<balances>` and never used them, and kompile said so — "Variable 'TAKER' defined but not used". A scratch claim pinning the balance to 10^30 with `minAmount = 1` and asserting the revert **PROVED** (`proofs/README.md:155-160`). The new rules read `B` and `TAKER` in the guard. Verified by reading `gte.k:86-115`. |
| `0x25` `OnlyTakerTokenSupplyShareGte` | `#supplyShareSufficient(_,_,_)` uninterpreted | the literal conjunction `#totalSupply(T) >Int 0 andBool #balanceOf(...) *Int 10^18 >=Int MIN *Int #totalSupply(T)`, with the REVERT arm carrying its explicit `notBool` negation (`supplyshare.k:148-183`; three arms at `:148,170,185`) | The two arms are now literal negations of each other rather than a predicate and its `notBool`. |
| `0x2c` `WhitelistCoequal` | `#coequalWhitelistContains` uninterpreted | `#coequalContains(Bytes, Int)` a real recursive `[function]` (`whitelists.k:181-196`) | Base case on the empty list, recursive case comparing `Bytes2Int(substrBytes(LIST,0,10),BE,Unsigned)` and recursing on the 10-byte tail. Mirrors the `while (i-- > 0)` loop in `Whitelist.sol:120-128`. Concrete lists reduce; symbolic lists are **stuck**, which is the honest posture — no false `#Top`. |
| `0x2d` `WhitelistSequential` | `#sequentialWhitelistJumps` and `#sequentialWhitelistReverts`, two **independent** uninterpreted symbols | `#seqOutcome(Bytes, Int, Int)` a single recursive `[function]` returning one of `#wlJump()` / `#wlRevert()` / `#wlFallthrough()` (`whitelists.k:260-289`) | **This retires a stated soundness gap.** The previous form recorded that the two predicates could never both hold by Solidity control flow, but were independent symbols K knew nothing of — so a spec selecting one arm was trusting the exclusivity itself, and nothing checked it. A single function returning one of three constructors makes the exclusivity **structural**. The gap is closed by construction, not by assumption. The address-match test also now precedes the duration test, matching `Whitelist.sol:158-163`, which is a real ordering fidelity point. |

### What the retirement does and does not buy

It removes the tautology. It does not, by itself, produce evidence — and the difference matters
because the merge's own documents describe it as if it did.

A rule built on an uninterpreted predicate was `ADMITTED` in a stronger sense than an unproved
concrete rule: there was no conformance test that *could* discharge it, because the predicate had
no evaluator on either engine. That is genuinely fixed for `0x24`, `0x2c` and `0x2d`, and fixed on
the guard for `0x20` and `0x25`. Those five opcodes moved from **untestable** to **testable**.

**Testable is not tested.** Nothing has run them. `0x20`, `0x25` and `0x26` also remain
`krun`-unreachable — `#blockTimestamp()`, `#totalSupply()` and `#txOrigin()` have no evaluator, so
the LLVM backend still aborts, which is exactly why the merge used concrete `kprove` claims
instead. That substitution is sound. It has not been executed.

## Negative controls

Statements known to be FALSE, asserted to fail. If one ever closes, the rule set is inconsistent
and every result above it is void. See `PLAN.md` §5a.

**Twelve must-fail files, down from seventeen.** Plus `control-sensitivity.k`, which must PROVE.

| Control | Expected | Result |
|---|---|---|
| `negative-control.k` — gate first, balance NON-zero, asserts `Reverted` | must FAIL | **FAILS at `<pc> 22`, `<status> Running`** — a real computed counterexample |
| `control-sensitivity.k` — identical premises, conclusion `Running` | must PROVE | **`#Top`** |
| `pricing-negative-control.k` — T1 with the maker-safety inequality REVERSED | must FAIL | **FAILS at `pc 91`** with the real quote in the register |
| `pricing-spec.k` itself | doubles as T1's sensitivity witness | **`#Top`** — same premises, correct conclusion |
| `stop-control.k`, `revert-control.k`, `salt-control.k`, `jump-control.k`, `extruction-control.k`, `privateorder-control.k`, `jumpifdirection-control.k`, `jumpiftokenin-control.k`, `jumpiftokenout-control.k` | each must FAIL | **fail — for the wrong reason.** Their opcode is not in the definition, so the failure is the `[owise]` no-op, not the claim |
| `txorigin-control.k` | must FAIL | **exit 113 — parse failure.** Names `#txOrigin`, whose module nothing imports |
| `deadline-control.k`, `gte-control.k`, `supplyshare-control.k`, `whitelistcoequal-control.k`, `whitelistsequential-control.k` | — | **DELETED by the merge.** `0x20`, `0x24`, `0x25`, `0x2c`, `0x2d` now have no must-fail claim at all |

The nine surviving new controls are written to the shape this file demands — a concrete program
prefix, the real rule firing, and the falsity located in the *conclusion*. The audit's
near-neighbour assessment (`proofs/README.md:119-135`) confirms it under the scratch `wired`
build: thirteen were conclusion-flips with identical premises, and the spec is its own sensitivity
twin. **Two are not**: `privateorder` and `txorigin` negate the *premise* rather than the
conclusion, copying `negative-control.k`'s shape without copying its twin. There is no PASS-arm
claim for `0x2b` or `0x26`, so those two pairs are incomplete by rule 2.

**And note what C-1 does to all of it.** A control run against a definition that lacks its opcode
rule fails for an incidental reason. Ten of the twelve must-fail controls currently "fail
correctly" for exactly the reason this file ruled inadmissible once already. Running
`run-proofs.sh` extended to all 33 files before wiring `lemmas.k` would produce a green table that
means nothing. **The wiring must come first.**

**The previous control was inert and has been replaced.** It dropped the gate prefix and asserted
an arbitrary program reverts. It did fail — but at `<pc> 0`, before any instruction executed, on a
residual branch where no decode rule applies to a symbolic first byte. A review established the
decisive fact: a claim that is *true* fails with a byte-identical residual. It would have kept
"failing correctly" with every instruction rule deleted. **A negative control with a symbolic
prefix cannot discriminate** — the prefix must be concrete.

**A sharper T1 control exists and should be added:** change `<=Int` to `<Int` in the maker-safety
bound — a **one-character** edit. It is false exactly when `balanceIn` divides
`amountIn * balanceOut`, so it discriminates the rounding decision itself rather than the
direction of an inequality. A review verified it fails. The shipped control reverses the
inequality, which is false for almost every input and is therefore a distant neighbour.

The pair is the point. A control that fails proves nothing on its own — it may be failing for an
incidental reason. The sensitivity witness has the same setup and the correct conclusion and
**proves**, which shows `kprove` is discriminating on the conclusion rather than choking on the
premises.

## What would actually move a row, in order of value

Not a plan — this file does not own any of these — but the evidence above points at a short list
and it is cheaper to write it down than to have it re-derived a third time.

1. **Add fifteen `requires` and twelve `imports` to `lemmas.k`.** Until then no verdict from any
   of the 27 non-original proof files is worth reading, and the seven new concrete files cannot
   even be loaded. Known to work: the scratch `wired` build in `proofs/README.md`.
2. **Add the seven `*-concrete.k` files to `run-proofs.sh`** and record the verdicts. This is the
   step that would convert thirteen rows from `ADMITTED` to `TESTED`, and it is the step the merge
   left out.
3. **Fix D-3 first, or step 2 comes back green and meaningless** for `0x2c`, `0x31`, `0x32` and
   half of `0x2d`.
4. **Fix D-2** — two pairs of parentheses at `jumps.k:56,63`.
5. **Stage `opcodes/*.k` into the mutation harness.** As long as `mutation/run-native.sh:44`
   copies only two files, no mutation study says anything about fifteen of eighteen opcodes.
