# Trust ledger

Every instruction rule is a claim about the deployed bytecode. This file tracks the status of
each one. See `PLAN.md` §5a for the model.

| State | Meaning |
|---|---|
| `ADMITTED` | Asserted. No proof, no conformance coverage. **All rules start here.** |
| `TESTED` | Conformance exercises it on concrete programs. Evidence on those inputs, not proof. |
| `PROVEN` | A Kontrol proof discharges it against the real bytecode. Phase R only, out of scope this pass. |

**Conformance is evidence, not proof.** A green suite means well-tested and still admitted.

**Nothing in this file is `PROVEN`.** That tier means a Kontrol proof against real deployed
bytecode. No rule here has one. `kprove` verdicts on the K definition are a different and
weaker thing — they discharge a theorem *given* the rules, which is what the `ADMITTED`/`TESTED`
column is for.

## Instruction rules

The opcode set is **derived, not listed** — this table went stale once by being hand-maintained.
The derivation is `grep -o '#exec ( [0-9]*' semantics/swapvm.md semantics/opcodes/*.k`, which
yields decimal `0 1 2 3 4 32 35 36 37 38 43 44 45 48 49 50 83 144` — **18 opcodes**, hex
`00 01 02 03 04 20 23 24 25 26 2b 2c 2d 30 31 32 53 90`. Re-run it before trusting the table.

Solidity locations are **function bodies** (`function` line through closing brace), verified
against `src/instructions/` at `vk/demo` `931afb9`, not copied from the opcode design docs.

| Opcode | Instruction | K rules | Implementation | State | Discharged by |
|---|---|---|---|---|---|
| `0x00` | `Stop` | `opcodes/stop.k:48` | `Controls.sol:90-93` | `ADMITTED` | **nothing** |
| `0x01` | `Revert` | `opcodes/revert.k:37` | `Controls.sol:85-87` | `ADMITTED` | **nothing** |
| `0x02` | `Salt` | `opcodes/salt.k:40` | `Controls.sol:73` | `ADMITTED` | **nothing** |
| `0x03` | `Jump` | `opcodes/jump.k:45,53` | `Controls.sol:79-82` | `ADMITTED` | **nothing** |
| `0x04` | `Extruction` | `opcodes/extruction.k:72,81` | `Extruction.sol:90-115` | `ADMITTED` | **nothing** — and it is an abstraction, not a definition; see the abstraction log |
| `0x20` | `Deadline` | `opcodes/deadline.k:104,116,125` | `Controls.sol:131-134` | `ADMITTED` | **nothing** |
| `0x23` | `OnlyTakerTokenBalanceNonZero` | `swapvm.md:183,189` | `Controls.sol:140-144` | `TESTED` | K cases `catalogue`/`gateRejects` + `InstructionConformance.t.sol` (`holdingTakerGetsQuote`, `zeroBalanceTakerIsRejected`) |
| `0x24` | `OnlyTakerTokenBalanceGte` | `opcodes/gte.k:115,133,146` | `Controls.sol:161-166` | `ADMITTED` | **nothing** |
| `0x25` | `OnlyTakerTokenSupplyShareGte` | `opcodes/supplyshare.k:153,174,189` | `Controls.sol:171-178` | `ADMITTED` | **nothing** |
| `0x26` | `OnlyTxOriginTokenBalanceNonZero` | `opcodes/txorigin.k:98,113,123` | `Controls.sol:152-156` | `ADMITTED` | **nothing** |
| `0x2b` | `PrivateOrder` | `opcodes/privateorder.k:92,104,115` | `Whitelist.sol:105-110` | `ADMITTED` | **nothing** |
| `0x2c` | `WhitelistCoequal` | `opcodes/whitelists.k:187,201,214` | `Whitelist.sol:116-129` | `ADMITTED` | **nothing** — and the list loop is abstracted; see the abstraction log |
| `0x2d` | `WhitelistSequential` | `opcodes/whitelists.k:225,237,248,257` | `Whitelist.sol:141-167` | `ADMITTED` | **nothing** — and the time/list loop is abstracted; see the abstraction log |
| `0x30` | `JumpIfDirection` | `opcodes/jumps.k:51,59,67` | `Controls.sol:96-103` | `ADMITTED` | **nothing** — and see **DEFECT D-2** below |
| `0x31` | `JumpIfTokenIn` | `opcodes/jumps.k:90,98,105` | `Controls.sol:109-115` | `ADMITTED` | **nothing** |
| `0x32` | `JumpIfTokenOut` | `opcodes/jumps.k:121,129,136` | `Controls.sol:121-127` | `ADMITTED` | **nothing** |
| `0x53` | `LimitSwap` | `swapvm.md:252,256,266,275,283,292` | `LimitSwap.sol:40-53` | `TESTED` | K cases `floorNotCeil`/`floorNonDividing`/`revPrices`/`revRecompute`/`revRecomputeOut` + ten of the twelve `InstructionConformance.t.sol` cases (all but `zeroBalanceTakerIsRejected`, which reverts at the gate, and `doubleBalancesReverts`) |
| `0x90` | `StaticBalances` | `swapvm.md:203,209,215` | `Balances.sol:37-47` | `TESTED` | K case `catalogue` + `InstructionConformance.t.sol` (both orientations, `doubleBalancesReverts`) |

### Why fifteen of eighteen are `ADMITTED`, stated exactly

This is the point of the file, so the negative evidence is spelled out rather than implied.

**The K conformance harness never executes them.** `conformance/run.sh` and its nix twin
`conformance/run-native.sh` carry an identical 11-case table. Every case's program bytes are
built from `\x23`, `\x90`, `\x53`, plus `\x50` in `zeroArg` — and `0x50` is *unmodelled*, so
that case exercises the `[owise]` no-op, not an instruction rule. No case contains a `\x00`,
`\x01`, `\x02`, `\x03`, `\x04`, `\x20`, `\x24`, `\x25`, `\x26`, `\x2b`, `\x2c`, `\x2d`, `\x30`,
`\x31` or `\x32` in opcode position. Adding one would be the cheapest possible move from
`ADMITTED` to `TESTED` for the halting opcodes.

**The Solidity conformance driver refuses them.** `test/conformance/InstructionConformance.t.sol:45-49`:

    function _dispatch(Context memory ctx, uint256 opcode, bytes calldata args) internal {
        if (opcode == 0x23) _onlyTakerTokenBalanceNonZero(ctx, args);
        else if (opcode == 0x90) _staticBalancesXD(ctx, args);
        else if (opcode == 0x53) _limitSwap1D(ctx, args);
        else revert("unmodelled opcode in conformance driver");
    }

Three arms. Every other modelled opcode hits the `else` and reverts with a driver error, so a
conformance program containing one cannot run at all on the Solidity side.

**The mutation harness never touches them.** `mutation/run-native.sh:44` stages exactly
`swapvm.md` and `lemmas.k` into the work directory; `opcodes/*.k` is not copied and not mutated.
Every rule in those fifteen files is mutation-untested by construction.

**Solidity unit tests for these instructions exist and do not count.** `test/Controls.t.sol`,
`test/Whitelist.t.sol` and `test/PrivateOrder.t.sol` exercise the real `_stop`, `_jump`,
`_deadline`, `_privateOrder`, `_whitelist*` bodies. They discharge nothing here, for the reason
already recorded below under D-1: **no Solidity test can kill a mutant in the K semantics.**
Those files import only from `src/` and have no coupling to `swapvm.md` or `opcodes/*.k`, so
they are structurally constant under mutation of the model. A test that cannot distinguish a
correct rule from a wrong one is not evidence about the rule.

**They are also not in the compiled definition at all** — see the next section, which is worse
than being untested.

## CORRECTION C-1 — the fifteen opcode modules are not wired into any definition

**Found by reading the module graph, not by running anything.** The fifteen new opcodes each
live in a sibling module (`SWAPVM-STOP`, `SWAPVM-REVERT`, `SWAPVM-SALT`, `SWAPVM-JUMP`,
`SWAPVM-JUMPS`, `SWAPVM-EXTRUCTION`, `SWAPVM-DEADLINE`, `SWAPVM-GTE`, `SWAPVM-SUPPLYSHARE`,
`SWAPVM-TXORIGIN`, `SWAPVM-PRIVATEORDER`, `SWAPVM-WHITELISTS`) because K v7 refuses to reopen
`module SWAPVM` across files. Each file's header states the integration recipe: `requires
"opcodes/<name>.k"` plus `imports SWAPVM-<NAME>` from `semantics/lemmas.k`.

**Neither half of that recipe has been applied.**

- `semantics/lemmas.k:1` is `requires "swapvm.md"` and nothing else. No `requires` of any
  `opcodes/*.k`.
- `semantics/lemmas.k:12-13` is `module SWAPVM-BYTES-LEMMAS` / `imports SWAPVM`. No sibling
  import.
- Every one of the 36 files under `proofs/` imports exactly `SWAPVM` and `SWAPVM-BYTES-LEMMAS`.
  None imports an opcode module directly either.
- `run-proofs.sh` builds `swapvm-haskell` by `kompile --backend haskell lemmas.k`. That
  definition therefore contains the decode loop, `0x23`, `0x90`, `0x53`, the bytes lemmas — and
  not one of the fifteen new rules.

Consequences, by spec:

- Specs whose premises name an uninterpreted symbol declared only inside an opcode module
  cannot **parse** against `swapvm-haskell`: `#deadlineExceeded` (`opcodes/deadline.k:88`),
  `#balanceLtMin` (`gte.k:103`), `#supplyShareSufficient`/`#totalSupply` (`supplyshare.k:121,138`),
  `#txOrigin` (`txorigin.k:81`), `#coequalWhitelistContains`/`#sequentialWhitelistJumps`/
  `#sequentialWhitelistReverts` (`whitelists.k:152,163,175`).
- The remainder — `stop`, `revert`, `salt`, `jump`, `jumpif*`, `privateorder`, `extruction` —
  parse, then dispatch `#exec(N, ARGS)` into the `[owise]` unknown-opcode no-op at
  `swapvm.md:349-351`. A claim asserting a revert would fail; a claim asserting `Running` might
  pass **for the wrong reason**, which is exactly the vacuous-green failure this file exists to
  catch.

Either way, **no verdict from any of the seventeen new spec/control pairs can be trusted, and
none appears to have been produced.** `run-proofs.sh:52-59` still enumerates six specs. There
is no recorded verdict for any of the other thirty files anywhere in the tree.

**Two documents assert the wiring already exists.** `opcodes/revert.md:97-98` instructs the
reader to add `imports SWAPVM-REVERT` "alongside the existing `imports SWAPVM` and `imports
SWAPVM-STOP`" — `lemmas.k` has no `imports SWAPVM-STOP`. `OPCODE-BACKLOG.md:110` says the
modules "must be wired into `lemmas.k`" and points at `opcodes/README.md`, a file that does not
exist. The first is stale-in-the-past-tense; the second is honest.

**Not verified by execution.** This environment has no `kompile`, `kprove`, `krun` or `forge` on
`PATH`, no `semantics/swapvm-llvm/` or `swapvm-haskell/` in the tree, and no Kontrol proof
store. The finding rests on reading `lemmas.k`, the 36 spec headers and `run-proofs.sh`, which
is sufficient for the module-graph claim but not for the resulting verdicts. **Someone with the
toolchain should run `semantics/run-proofs.sh` extended to all 18 specs and record what
happens.** This file does not own `lemmas.k` or `proofs/`.

## DEFECT D-2 — `0x30` reintroduces the D-1 precedence bug. Flagged, not yet reproduced

`opcodes/jumps.k:55-56` and `62-63`:

    requires lengthBytes(ARGS) ==Int 3
     andBool (ARGS [ 0 ] =/=Int 0) ==Bool (TIN <Int TOUT)

The two *operands* are parenthesised. The *comparison* is not. By the precedence fact D-1
established below — `==Bool` and `=/=Bool` sit at the bottom of the `Bool` grammar, below
`andBool` — this compiles as

    ( lengthBytes(ARGS) ==Int 3 andBool (ARGS [ 0 ] =/=Int 0) ) ==Bool ( TIN <Int TOUT )

the whole conjunction compared against the direction. That is the D-1 shape verbatim.
`swapvm.md:260,273,281,290,298` all carry the D-1 fix — `andBool ( ... ==Bool ( ... ) )`.
`jumps.k:56` and `:63` are the only other `==Bool`/`=/=Bool` in any rule in the tree, and they
do not.

Worked through, the damage is narrower than D-1 but real:

- **Canonical length** (`lengthBytes(ARGS) ==Int 3`): the swallowed conjunct is `true`, so
  `(true andBool a0=/=0)` reduces to `a0=/=0` and the compiled guard coincides with the intended
  one. The canonical branch is *accidentally* correct — which is precisely why a canonical-only
  test would never catch this, the same blind spot that let D-1 survive.
- **Non-canonical length**: the left side is `false` whatever `ARGS[0]` is. The jump arm's guard
  collapses to `TIN >=Int TOUT`, the fall-through arm's to `TIN <Int TOUT`. Exactly one of those
  always holds — and the `UNMODELLED-ARGS-LENGTH` arm (`lengthBytes(ARGS) =/=Int 3`) holds too.
  **Two of the three rules are enabled simultaneously on every non-canonical `0x30`**, the same
  "both rules permanently enabled" condition as D-1. Worse, the jump arm then evaluates
  `substrBytes(ARGS, 1, 3)` on an args that may be shorter than three bytes.

D-1's recorded lesson said keeping priorities "would mask the next overlap the same way". This
is the next overlap, and it arrived without priorities.

**Not reproduced.** No `kompile` in this environment, and `SWAPVM-JUMPS` is not in any
definition (C-1), so there is nothing compiled to read. The diagnosis is by the precedence rule
D-1 verified against `swapvm-llvm/compiled.txt` on this same codebase, not by re-reading a
compiled artifact — and D-1's own lesson 2 is *read the compiled guard, not the source guard*.
**Treat this as a flag, not a finding, until someone rebuilds and greps `compiled.txt`.** The
fix, if confirmed, is the D-1 fix: `andBool ( (ARGS [ 0 ] =/=Int 0) ==Bool (TIN <Int TOUT) )`.

`opcodes/jumps.k` is owned by another pass; this file does not edit it.

## DEFECT D-1 — FIXED. `0x53` diverged on reversed token order

**Found by conformance, on a clean build, reproducible.** The semantics is WRONG for
exact-in when `tokenIn > tokenOut`.

| case | direction byte | Solidity | K |
|---|---|---|---|
| `tokenIn < tokenOut` | `0x01` | prices | prices ✓ |
| `tokenIn > tokenOut` | `0x00` | **prices** (`amountOut = 0.5e18`) | **`Reverted("LimitSwapRecomputeDetected")`** ✗ |
| `tokenIn < tokenOut` | `0x00` | mismatch | mismatch ✓ |
| `tokenIn > tokenOut` | `0x01` | mismatch | mismatch ✓ |

Three of four combinations are correct. Only the case where `#makerDirLt` and
`tokenIn < tokenOut` are **both false** fails, and it falls through to the exact-in recompute
rule — which requires `AOUT =/=Int 0` while `AOUT` is `0`. That should be impossible, so the
success rule must be failing to apply for a reason not yet identified; `#exec(83)` then matches
the next rule instead.

Ruled out so far: the two rules are mutually exclusive on `AOUT` (verified in the compiled
source, host and container md5 identical); moving the discrimination from a cell pattern into
`requires` changes nothing; the firing rule is the **exact-in** recompute arm, confirmed by
renaming the two arms apart and re-running.

**Impact.** Half of all token pairs — every maker whose `tokenIn` sorts above `tokenOut` —
are modelled as reverting when they price. Any theorem touching `0x53` on that branch is
unsound. The Phase 1 gate theorem is unaffected: it reverts at the gate and never reaches
`0x53`.

**FIXED — but my first fix was wrong, and the diagnosis recorded here was wrong too.**

**The real cause is operator precedence, not rule selection.** K's `==Bool` and `=/=Bool` sit
at the *bottom* of the `Bool` grammar, below `andBool`. So

    requires BIN >Int 0 andBool BOUT >Int 0 andBool AOUT ==Int 0
     andBool #makerDirLt(ARGS) ==Bool ( TIN <Int TOUT )

compiled as **`(BIN>0 ∧ BOUT>0 ∧ AOUT==0 ∧ makerDirLt) ==Bool (tokenIn<tokenOut)`** — the whole
conjunction compared against the direction. Confirmed by reading `swapvm-llvm/compiled.txt`.

Consequence: whenever `makerDirLt` and `tokenIn<tokenOut` are **both false** — the reversed
branch, half of all token pairs — the left side is `false`, the right side is `false`, and the
guard is `true` **unconditionally, for every `amountOut`**. The pricing rule and the recompute
rule were not mutually exclusive; both were permanently enabled.

**My `[priority(50)]/[priority(60)]` fix only chose between two always-enabled rules**, and it
chose wrong in the other direction: it traded a spurious *revert* for a spurious *price*. With
priorities, a reversed-order program with `amountOut` already set **priced anyway** where
Solidity reverts `LimitSwapRecomputeDetected`. That is strictly worse — a false revert is a
false negative, a false price defeats the single-assignment safety guard entirely. Both
recompute arms were effectively deleted from the model for reversed-order makers.

**The correct fix is to parenthesise** — `andBool ( #makerDirLt(ARGS) ==Bool ( TIN <Int TOUT ) )`
— after which all six rules are genuinely disjoint and **the priorities are deleted**, because
keeping them would mask the next overlap the same way.

Verified on a clean rebuild with no priorities, all four rows correct including the two the
priority fix had broken:

| direction | `amountOut` | K | Solidity |
|---|---|---|---|
| reversed, dir `0x00` | 0 | prices | prices ✓ |
| reversed, dir `0x00` | 7 | `Reverted("LimitSwapRecomputeDetected")` | reverts ✓ |
| forward, dir `0x01` | 0 | prices | prices ✓ |
| forward, dir `0x01` | 7 | `Reverted("LimitSwapRecomputeDetected")` | reverts ✓ |

**The "lesson" previously recorded here — *"overlapping rules need explicit priorities even
when their side conditions look disjoint"* — was FALSE and has been deleted.** K never applies
a rule whose `requires` evaluates to `false`; priority only orders rules whose guards all hold.
The side condition was never being ignored — it was a *different* side condition than the one
written. Two real lessons replace it:

1. **Parenthesise every `==Bool` / `=/=Bool`.** They bind looser than `andBool`, so an
   unparenthesised comparison silently swallows the preceding conjunction.
2. **Read the compiled guard, not the source guard.** `compiled.txt` shows what K actually
   built. My earlier claim to have "verified in the compiled source" that the rules were
   mutually exclusive was false — the compiled source showed the opposite.

**Lesson 1 was not applied to the opcodes merged after it was written.** See D-2 above.

**Independently confirmed.** Two reviewers reached the precedence diagnosis separately, and a
mutation study verified the parenthesised version is correct across all four
direction/orientation combinations with the priorities removed.

Conformance cases were added that would have caught this: reversed token order both pricing
and with a pre-set output register, on both legs, on **both engines**. The K side previously
had no reversed-branch case at all, which is why a mutation study found that reintroducing D-1
left the entire suite green. Verified by doing exactly that — removing the parentheses again
now fails `revPrices`. The previous four-case table never varied the output
register off zero on the reversed branch, which is the only region where the model diverged.

Diagnosis that worked, after several that did not: `krun --depth N` to step to the exact
configuration before the dispatch and read the cells, rather than reasoning about what should
match. Renaming the two recompute arms apart identified which one fired.

**Downgraded after review.** A reviewer established that `semantics/conformance/run.sh` had
been broken since Phase 1 — it passed only `$PGM` while the configuration had grown six more
variables, so `krun` failed on the first case and **the K engine executed no program at all**
under the shipped harness. Every mutant to `swapvm.md` survived it trivially. The comparison
that justified `TESTED` was manual, one-time and undated. `run.sh` is now repaired, with
per-case configuration and an added gate-rejection case.

Mutation testing then found the suite missed: exact-in rounding direction (the catalogue
program divides exactly, so floor and ceiling were indistinguishable), all three secondary
revert arms, and the orientation branch — the reversed-order test asserted only a revert
selector and passed under a full orientation flip. Six tests were added; one of them found
defect D-1.

**A mutation study qualified these markings and they should be read narrowly.** No Solidity
test can kill a mutant in `swapvm.md` — those files import only from `src/` and have no
coupling to the K semantics, so the Solidity column is structurally constant under mutation.
Only the K case table and the proofs are mutation-sensitive. The K table now checks `amountOut`
and covers the reversed branch, which closed the largest hole: before that, reintroducing D-1
by removing the parentheses left the entire suite green. Verified by doing exactly that — it is
now caught by `revPrices`.

`TESTED` via `test/conformance/InstructionConformance.t.sol`, which routes opcodes to the
**real instruction bodies** inherited from `Controls`, `Balances` and `LimitSwap` — only the
dispatch table is ours, which is what the production VM generates anyway. No instruction logic
is reimplemented, so this compares K rules against production code and not against a
transcription. **This applies to three opcodes only** — the driver's dispatch has three arms
(`InstructionConformance.t.sol:46-49`) and reverts on everything else.

Four cases agree register-for-register with `krun`: holding taker prices at 1:2
(`amountOut = 2e18`), zero-balance taker reverts `TakerTokenBalanceIsZero` with balances
untouched, reversed token order swaps the balance pair then rejects on direction, and exact-out
rounds **up** (`amountIn = 2`, where floor would give 1 — so the assertion distinguishes
rounding direction rather than merely exercising the path).

Still **not `PROVEN`**: evidence on four inputs, not a proof over all inputs.

## Generic bytes lemmas

`semantics/lemmas.k`. Not domain facts — definitional identities about `+Bytes`,
`substrBytes`, `Int2Bytes`, `Bytes2Int` that plain K does not ship. Without them a symbolic
program built by concatenation cannot be decoded at all: the prover cannot reduce
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

Nine rules, unchanged by the fifteen-opcode merge — `lemmas.k` was not modified. Every one of
the eighteen theorems below therefore inherits `ADMITTED` from this table alone, before any
question about the instruction rules is reached.

**Correction to the "side conditions make them total" claim above: it is not literally true of
the two Phase 2 additions.** Neither carries an upper bound (`I < len(B1)+len(B2)`;
`E <= len(B1)+len(B2)`). A review verified this is nonetheless **not exploitable**, but for a
different reason than totality: K's `Bytes[_]` is genuinely partial, so out of range both sides
of the rule are equally stuck — `(b"\x01\x02" +Bytes b"\x03")[5] ==Int 0` and `==Int 9` both
fail. There is no totalizing default the lemma could contradict. Sound, but the justification
recorded here was the wrong one.

The five slice/index rules were also checked for the D-1 hazard and are **pairwise disjoint**:
left-index (`I < len B1`) vs right-index (`len B1 <= I`); within-left (`E <= len B1`) vs
within-right (`len B1 <= S`) vs straddle (`S < len B1 < E`). The only overlap is straddle
against the full-width identity rule, and they are confluent.

The two Phase 2 additions were each found by a stall, not written speculatively. The pricing
claim stopped at `pc 22` — it had decoded the gate and could not read the second instruction's
args-length byte, because that byte falls in the *right* operand of a concatenation and only a
left-index rule existed.

## Decode loop

| Component | Implementation | State | Notes |
|---|---|---|---|
| fetch/decode/dispatch | `VM.sol:118-150` | `TESTED` | `opcode = shr(248,w)`, `argsLen = and(shr(240,w),0xff)`, `pc += 2 + argsLen` |
| program-length bound | `VM.sol:143` | `TESTED` | reverts `RunLoopExceedProgramLength` when `pcs > length` |

Discharged by `semantics/conformance/run.sh` — **eleven** programs agree on final `pc`, revert
status and `amountOut` across both engines, plus **eighteen** Solidity-side test functions
(`RunLoopConformance.t.sol` 6, `InstructionConformance.t.sol` 12). **`TESTED`, not `PROVEN`**:
this is evidence on those inputs, not a proof over all programs.

**Corrected counts.** This section previously said "five programs" and "six Solidity-side
assertions on decoded opcodes and args lengths". `run.sh` now carries 11 cases and the two
conformance test files carry 18 `function test*` between them. `DEMO.md:144` says "21 Solidity
tests, 11 K conformance cases" — the 11 is right, the 21 does not match the 18 test functions
under `test/conformance/`; whoever owns `DEMO.md` should re-derive it from `forge test
--match-path 'test/conformance/*'` rather than from memory.

Conformance already caught one drift. The first version of the K bound-check rules reverted
with `pc` still at the instruction start, while the real VM reports the *advanced* value —
`(91, 90)` where the model said `88`. Both reverted with the same reason, so only a test that
inspects the revert arguments distinguishes them. Fixed to advance before checking.

## Theorems and what they rest on

A theorem inherits the **weakest** state among the instructions it touches.

One row per `*-spec.k` in `semantics/proofs/`. There are **18** of them. A `*-control.k` is a
claim asserted to FAIL and is **not a theorem**; the eighteen controls are in their own table
further down. 18 + 18 = the 36 `.k` files in the directory.

| Theorem (`proofs/…`) | Depends on | Effective state | Verdict on record |
|---|---|---|---|
| `gate-spec.k` (T0) | `0x23`, decode loop, bytes lemmas | `ADMITTED` | `#Top` |
| `pricing-spec.k` (T1) | `0x23`, `0x90`, `0x53`, decode loop, bytes lemmas | `ADMITTED` | `#Top` |
| `pricing-exactout-spec.k` (T2) | same as T1 | `ADMITTED` | `#Top` |
| `stop-spec.k` | `0x00`, decode loop, bytes lemmas | `ADMITTED` | **none — see C-1** |
| `revert-spec.k` | `0x01`, decode loop, bytes lemmas | `ADMITTED` | **none — see C-1** |
| `salt-spec.k` | `0x02`, decode loop, bytes lemmas | `ADMITTED` | **none — see C-1** |
| `jump-spec.k` | `0x03`, decode loop, bytes lemmas | `ADMITTED` | **none — see C-1** |
| `extruction-spec.k` | `0x04`, decode loop, bytes lemmas | `ADMITTED` | **none — see C-1** |
| `deadline-spec.k` | `0x20`, decode loop, bytes lemmas, `#deadlineExceeded` | `ADMITTED` | **none — see C-1** |
| `gte-spec.k` | `0x24`, decode loop, bytes lemmas, `#balanceLtMin` | `ADMITTED` | **none — see C-1** |
| `supplyshare-spec.k` | `0x25`, decode loop, bytes lemmas, `#supplyShareSufficient` | `ADMITTED` | **none — see C-1** |
| `txorigin-spec.k` | `0x26`, decode loop, bytes lemmas, `#txOrigin` | `ADMITTED` | **none — see C-1** |
| `privateorder-spec.k` | `0x2b`, decode loop, bytes lemmas | `ADMITTED` | **none — see C-1** |
| `whitelistcoequal-spec.k` | `0x2c`, decode loop, bytes lemmas, `#coequalWhitelistContains` | `ADMITTED` | **none — see C-1** |
| `whitelistsequential-spec.k` | `0x2d`, decode loop, bytes lemmas, `#sequentialWhitelistJumps` | `ADMITTED` | **none — see C-1** |
| `jumpifdirection-spec.k` | `0x30`, decode loop, bytes lemmas | `ADMITTED` | **none — see C-1**, and **D-2** |
| `jumpiftokenin-spec.k` | `0x31`, decode loop, bytes lemmas | `ADMITTED` | **none — see C-1** |
| `jumpiftokenout-spec.k` | `0x32`, decode loop, bytes lemmas | `ADMITTED` | **none — see C-1** |

Every row is `ADMITTED`. For T0/T1/T2 that is the bytes lemmas dominating three `TESTED`
instructions — the ordinary weakest-dependency result. For the other fifteen it is stronger than
that: the instruction they rest on is `ADMITTED`, the theorem has no recorded verdict, and per
C-1 it could not have produced one against the definition `run-proofs.sh` builds. **Do not read
the fifteen new rows as "proved but admitted". Read them as "written, never run".**

Three of the fifteen carry an extra dependency worth naming separately: `extruction-spec.k`,
`whitelistcoequal-spec.k` and `whitelistsequential-spec.k` are claims about an **abstraction**,
not about the instruction. See the abstraction log.

### T1, unchanged

**T1** (`kprove` returns `#Top`) — `semantics/proofs/pricing-spec.k`. Runs the whole
three-instruction program with `amountIn` and both maker reserves **symbolic**, and pins the
quote to exactly the floor of the maker's rate:

    amountOut * balanceIn <= amountIn * balanceOut          (maker safety)
    (amountOut + 1) * balanceIn > amountIn * balanceOut     (taker safety)

Both bounds are required: the first alone is satisfied by returning 0, the second alone by
returning something huge. Together they determine `amountOut` uniquely.

This is the first theorem here about the **money** rather than about access control, and it
proves the rounding decision `LimitSwap.sol:49` documents as intentional — the sub-wei
remainder goes to the maker on every fill.

Negative control `pricing-negative-control.k` — the same claim with the maker-safety
inequality reversed — **fails as required**. It reaches the arithmetic, unlike the Phase 1
control it replaced.

**Caveat that must travel with T1, stated exactly.** `LimitSwap.sol:49` is plain checked
arithmetic — no `mulDiv` — so the divergence condition is precise: **K and the EVM differ iff
`amountIn * balanceOut >= 2^256`**, where the EVM reverts `Panic(0x11)` and K computes. Below
that they agree exactly, and the quotient is then also below `2^256`, so there is no second gap.

**The `amountIn < 2^256` hypothesis does not bound the product, and is inert** — a review
deleted it and the claim still proves. So T1 holds for arbitrarily large `amountIn`, including
the region where the EVM would revert. `amountIn` is taker-chosen, so the divergence is
reachable by construction for any `balanceOut`, at `amountIn >= 2^256 / balanceOut`.

Read T1 as *"given the product does not overflow"*.

### T0, unchanged

**T0** (`kprove` returns `#Top`) — `semantics/proofs/gate-spec.k`. For any program
beginning `0x23 0x14 G`, with `TAIL` symbolic, a taker holding zero `G` ends
`Reverted("TakerTokenBalanceIsZero")`. `TAIL` is never decoded, because `#revert` discards the
continuation, so the proof does not case-split on it.

Effective state is `ADMITTED` because the bytes lemmas are admitted, even though all three
instructions are `TESTED`. The theorem inherits the weakest dependency.

## Coverage

Derived, never hand-listed — the previous number went stale by being typed.

- `src/libs/OpcodeList.sol` declares 256 enum slots, of which **52 are named** and 204 are
  reserved `_xx`.
- The K semantics models **18** — `grep '#exec ( ' semantics/swapvm.md semantics/opcodes/*.k`.
- So: **18 of 52 named opcodes**, or 3 of 52 before the merge.
- Of the 52 named, 6 are debug-bank entries (`0x10`–`0x14`, `0x1a`) wired only into the `*Debug`
  opcode sets. **46 are production-dispatched**, so the modelled fraction of what actually runs
  is **18 of 46**, leaving 28 unmodelled-but-dispatched. Each of those 28 is a live soundness
  hazard: it falls through to the `[owise]` no-op (`swapvm.md:349-351`) while production either
  runs real logic or reverts `UnknownOpcode`.

### "3 of 52" still appears in five places outside this file

This pass edits only `semantics/axioms.md`. Each of these needs the same correction and I did
not make it:

| Location | Says | Should say |
|---|---|---|
| `semantics/DEMO.md:149` | heading "Coverage: 3 of 52 opcodes" | 18 of 52 |
| `semantics/DEMO.md:151-152` | "implements **three** — `0x23`, `0x90`, `0x53`" | the 18-opcode set |
| `semantics/DEMO.md:128-130` | "All three instruction rules and the decode loop are `TESTED`" | three are `TESTED`; fifteen are `ADMITTED` |
| `semantics/proofs/README.md:3` | "Six files. **Two of them are supposed to FAIL.**" | 36 files, 18 supposed to fail |
| `semantics/proofs/README.md` (last §) | "models **3 of the 52** named opcodes"; "Every instruction rule is `TESTED`" | 18 of 52; three are `TESTED`, fifteen `ADMITTED` |
| `semantics/OPCODE-BACKLOG.md:5` | "3 are modelled (`0x23`, `0x53`, `0x90`); the other 44 are below" | contradicts its own `:109` — see below |
| `semantics/run-proofs.sh:48-59` | six specs, "Two of the six specs are supposed to FAIL" | 36 |
| `VERIFY.md:156` | "3 of 52 opcodes are modelled in K" | 18 of 52 |
| `demo/README.md:67` | "3 of 52 opcodes are modelled" | 18 of 52 |
| `demo/server.py:248` | citation string "`DEMO.md` §5a — 3 of 52 opcodes modelled" | tracks whatever §5a becomes |

`demo/data/claims.json` and `demo/gen_data.py` are already correct: `gen_data.py:87-99` derives
the set by scanning `#exec` across `swapvm.md` and `opcodes/*.k`, which is the right shape and
is where the derivation in this file came from.

## Contradictions between the docs and the files

Recorded, not silently fixed. Each is checkable in one command.

1. **`OPCODE-BACKLOG.md` contradicts itself.** Line 5: "47 opcodes are wired to handlers; 3 are
   modelled (`0x23`, `0x53`, `0x90`); the other 44 are below." Line 109: "18 modelled (3 in
   `swapvm.md` + 15 in `semantics/opcodes/`), 28 unmodelled-but-dispatched = 46 dispatched
   total." The count line is right on the modelled figure and on 46; the header is stale on both
   the 3 and the 47. Every per-opcode row in between is already flipped to **modelled**, so the
   header disagrees with the table directly beneath it.
2. **`proofs/README.md` describes a directory that no longer exists.** "Six files. Two of them
   are supposed to FAIL." There are 36. It also asserts "Every instruction rule is `TESTED`,
   never `PROVEN`" — fifteen of the eighteen are `ADMITTED`, not `TESTED`.
3. **`run-proofs.sh` enumerates six specs.** The other thirty are never run by any script in the
   tree, which is why no verdict exists for them.
4. **`demo/data/proofs.json` mis-classifies `control-sensitivity.k`.** It is recorded as
   `"expected": "FAIL", "kind": "negative control"`. It must **PROVE** — `run-proofs.sh:56` has
   `'control-sensitivity|prove'` and `proofs/README.md` lists it as `#Top`. Its whole purpose is
   to be the twin that proves. The cause is `gen_data.py:114`, which classifies on
   `'control' in name`; the filename contains "control" without being one. If the demo ever
   gates on this data, a *correct* run of `control-sensitivity.k` will be reported as a failure —
   and, worse, an *inconsistent* rule set that made it prove would be reported as expected.
5. **`opcodes/revert.md:97-98` claims an import that is not there** — "alongside the existing
   `imports SWAPVM` and `imports SWAPVM-STOP`". `lemmas.k:12-13` imports only `SWAPVM`. See C-1.
6. **`OPCODE-BACKLOG.md:110` points at `semantics/opcodes/README.md`**, which does not exist.
7. **`DEMO.md:144`'s "21 Solidity tests"** does not match the 18 `function test*` under
   `test/conformance/`.

## Abstraction log

Records every firing of the `PLAN.md` D3/D4 trigger — an instruction weakened from an exact
definition to axioms, with the measurement that forced it. Empty is the good state.

**It is no longer empty.** Six entries arrived with the fifteen-opcode merge.

| Opcode | Weakened to | What forced it |
|---|---|---|
| `0x04` `Extruction` | `#revert("ExtructionUnmodelled")` on every canonical call (`extruction.k:72`) | The instruction delegates to `I{Static,}Extruction(target)` at a **maker-chosen address**, and the return triple overwrites `<pc>`, the chop cursor and the **entire** `<swap>` cell. Modelling it soundly means modelling arbitrary code. Strategy (A) — loud revert — was chosen over (B) — fresh symbolic cells — because (B) risks vacuous proofs unless every premise is load-bearing (`extruction.k:28-39`). |
| `0x20` `Deadline` | `#blockTimestamp()` and `#deadlineExceeded(_)` uninterpreted (`deadline.k:78,88`) | `block.timestamp` is an environment input (D4). The *second* symbol is a proof-engineering forced move, not a modelling one: with the faithful `#blockTimestamp() >Int DL` guard, the Haskell backend does not refute the opposite arm, the PASS arm is explored, the loop runs into a symbolic `TAIL`, and the all-path claim stalls with 20+ unexplored branches (`deadline-spec.k:22-34`). |
| `0x24` `OnlyTakerTokenBalanceGte` | `#balanceLtMin(TOK, MIN)` uninterpreted (`gte.k:103`) | Same backend limitation: the arms compare a balance to a **symbolic** bound rather than to the constant `0`, and constant reasoning is the only kind that propagates. |
| `0x25` `OnlyTakerTokenSupplyShareGte` | `#totalSupply(_)`, `#supplyShareSufficient(_,_,_)` uninterpreted (`supplyshare.k:121,138`) | `totalSupply()` is an external call (D4); the `balance * 1e18 >= minShareE18 * totalSupply` conjunction is then symbolic-vs-symbolic, same stall. |
| `0x26` `OnlyTxOriginTokenBalanceNonZero` | `#txOrigin()` uninterpreted (`txorigin.k:81`) | `tx.origin` is an environment input (D4). |
| `0x2c`/`0x2d` `Whitelist*` | `#coequalWhitelistContains`, `#sequentialWhitelistJumps`, `#sequentialWhitelistReverts` uninterpreted (`whitelists.k:152,163,175`) | The byte-level list parsing, the `i--` loop, the duration arithmetic and the in-window revert are **all inside** these predicates. Nothing about the loop is modelled; only its outcome. |

**One of these carries a stated soundness gap that K does not enforce.**
`whitelists.k:170-174` records it: `#sequentialWhitelistJumps` and `#sequentialWhitelistReverts`
can never both hold by Solidity control flow (a jump returns before any revert can fire), but
they are **independent uninterpreted symbols** and K knows nothing of that. A spec that selects
one arm is trusting the exclusivity itself. Nothing in the tree checks it. Any theorem over
`0x2d` inherits that trust.

A rule built on an uninterpreted predicate is `ADMITTED` in a stronger sense than an unproved
concrete rule: there is no conformance test that *could* discharge it, because the predicate has
no evaluator on either engine. `krun` cannot execute a program containing `0x20`, `0x24`, `0x25`,
`0x26`, `0x2c` or `0x2d` to a concrete answer at all. Six of the fifteen new opcodes are
therefore not merely untested but **untestable by the existing harness** — moving them off
`ADMITTED` requires either a `<blockTimestamp>`/`<totalSupplies>` cell or a differential harness
that supplies the predicate's value.

## Negative controls

Statements known to be FALSE, asserted to fail. If one ever closes, the rule set is
inconsistent and every result above it is void. See `PLAN.md` §5a.

Eighteen files. **Seventeen are must-FAIL claims; `control-sensitivity.k` is the odd one — it
must PROVE.** See contradiction 4 above: the demo data gets this backwards.

| Control | Expected | Result |
|---|---|---|
| `negative-control.k` — gate first, balance NON-zero, asserts `Reverted` | must FAIL | **FAILS at `<pc> 22`, `<status> Running`** — a real computed counterexample |
| `control-sensitivity.k` — identical premises, conclusion `Running` | must PROVE | **`#Top`** |
| `pricing-negative-control.k` — T1 with the maker-safety inequality REVERSED | must FAIL | **FAILS at `pc 91`** with the real quote in the register |
| `pricing-spec.k` itself | doubles as T1's sensitivity witness | **`#Top`** — same premises, correct conclusion |
| `stop-control.k`, `revert-control.k`, `salt-control.k`, `jump-control.k`, `extruction-control.k`, `deadline-control.k`, `gte-control.k`, `supplyshare-control.k`, `txorigin-control.k`, `privateorder-control.k`, `whitelistcoequal-control.k`, `whitelistsequential-control.k`, `jumpifdirection-control.k`, `jumpiftokenin-control.k`, `jumpiftokenout-control.k` | each must FAIL | **no result on record.** Not in `run-proofs.sh`; not runnable against `swapvm-haskell` as built (C-1) |

Each of the fifteen new controls is written to the shape this file demands — a concrete program
prefix, the real rule firing, and the falsity located in the *conclusion*. Read the headers:
`stop-control.k` asserts Stop reverts, `salt-control.k` asserts Salt reverts,
`jumpifdirection-control.k` asserts the taken branch left `<pc>` at the post-decode value. Their
sensitivity twins are the matching `*-spec.k`, exactly as `pricing-spec.k` twins
`pricing-negative-control.k`. **The shape is right and the evidence is absent.** A control that
has never been run is not a control; it is a file.

**A sharper T1 control exists and should be added:** change `<=Int` to `<Int` in the
maker-safety bound — a **one-character** edit. It is false exactly when `balanceIn` divides
`amountIn * balanceOut`, so it discriminates the rounding decision itself rather than the
direction of an inequality. A review verified it fails. The shipped control reverses the
inequality, which is false for almost every input and is therefore a distant neighbour.

The pair is the point. A control that fails proves nothing on its own — it may be failing for
an incidental reason. The sensitivity witness has the same setup and the correct conclusion and
**proves**, which shows `kprove` is discriminating on the conclusion rather than choking on the
premises.

**The previous control was inert and has been replaced.** It dropped the gate prefix and
asserted an arbitrary program reverts. It did fail — but at `<pc> 0`, before any instruction
executed, on a residual branch where no decode rule applies to a symbolic first byte. A review
established the decisive fact: a claim that is *true* fails with a byte-identical residual. It
would have kept "failing correctly" with every instruction rule deleted. **A negative control
with a symbolic prefix cannot discriminate** — the prefix must be concrete.

**And note what C-1 does to that lesson.** A control run against a definition that lacks its
opcode rule fails for an incidental reason — the `[owise]` no-op, not the claim. Fifteen of the
seventeen must-fail controls would currently "fail correctly" for exactly the reason this file
already ruled inadmissible once. Running them before wiring `lemmas.k` would produce a green
`run-proofs.sh` that means nothing.
