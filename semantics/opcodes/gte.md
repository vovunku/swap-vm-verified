# `0x24` OnlyTakerTokenBalanceGte — formal semantics

## Source

`Controls.sol:158-166`:

```solidity
/// @dev Checks if the taker holds at least a certain amount of tokens
/// @param args.token     | 20 bytes
/// @param args.minAmount | 32 bytes
function _onlyTakerTokenBalanceGte(Context memory ctx, bytes calldata args) internal view {
    address token = address(bytes20(args));
    uint256 minAmount = uint256(bytes32(args.slice(20)));
    uint256 balance = IERC20(token).balanceOf(ctx.query.taker);
    require(balance >= minAmount, TakerTokenBalanceIsLessThanRequired(ctx.query.taker, token, balance, minAmount));
}
```

Opcode `0x24` = 36 decimal. Args layout: `[token:20][minAmount:32]`, total **52 bytes**. Reads
the taker's ERC-20 `balanceOf(token)` and reverts iff `balance < minAmount`; otherwise it is a
pure no-op (writes no register, no `setNextPC`).

`#exec` is fired by the decode loop (swapvm.md:141-149) AFTER the `[opcode:1][argsLen:1]`
header has been consumed and `<pc>` advanced by `2 + argsLen`, exactly mirroring
`pcs := add(pcs, 2); ... pcs := add(pcs, argsLength)` in `VM.sol:133-138`. Gte neither reads nor
writes `<pc>` beyond that, so the rule inherits the already-advanced value and leaves it — the
same posture as Revert, Salt, and Deadline.

## What the K rule does

Three rules in `opcodes/gte.k`:

1. **REVERT arm** — canonical `lengthBytes(ARGS) ==Int 52`, condition
   `#balanceOf(B, TOK, TAKER) <Int MIN`: reverts with
   `"TakerTokenBalanceIsLessThanRequired"`, clears `<k>`, sets `<status>`.
2. **PASS arm** — canonical length, condition `#balanceOf(B, TOK, TAKER) >=Int MIN`: no-op,
   leaves `#run` in `<k>`, loop proceeds.
3. **UNMODELLED-ARGS-LENGTH arm** — `lengthBytes(ARGS) =/=Int 52`: reverts loudly with
   `"UNMODELLED-ARGS-LENGTH"` so a proof cannot silently succeed on a wrong length.

The token and minAmount are read with

```k
Bytes2Int(substrBytes(ARGS,  0, 20), BE, Unsigned)   // token
Bytes2Int(substrBytes(ARGS, 20, 52), BE, Unsigned)   // minAmount
```

Under `lengthBytes(ARGS) ==Int 52` these are the exact 20- and 32-byte big-endian reads the
Solidity does, and the round-trip lemma (`lemmas.k:64-67`) rewrites each `Bytes2Int(Int2Bytes(...))`
back to the symbolic Int the spec supplies, under the standard width bounds
(`0 <=Int TOK <Int 2^160`, `0 <=Int MIN <Int 2^256`).

`<balances>` is consulted via `#balanceOf` (`swapvm.md:171-174`), the existing abstraction
boundary for ERC-20 state (`PLAN.md` D4). Gte reads `#balanceOf(B, token, taker)` — no new
external state is introduced.

## Relationship to `0x23` (OnlyTakerTokenBalanceNonZero)

The gate at `swapvm.md:177-194` (`Controls.sol:140-144`) reverts iff `balance == 0`. Since
balances are non-negative, `balance < 1 <=> balance == 0`, so the gate is exactly Gte with
`minAmount == 1`. Gte is the generalization: an arbitrary on-chain `minAmount` the maker bakes
into the program. The two opcodes share everything else — same `<taker>` / `<balances>` read,
same revert-or-pass structure, same `<pc>` posture — except Gte's args carry an extra 32-byte
`minAmount` after the 20-byte token, and the revert reason differs
(`TakerTokenBalanceIsLessThanRequired` vs `TakerTokenBalanceIsZero`).

The K rule mirrors the gate's two-arm shape directly: the gate splits on
`#balanceOf(...) >Int 0` vs `<=Int 0` (comparison to a constant), Gte splits on
`#balanceOf(...) <Int MIN` vs `>=Int MIN` (comparison to a value read from args).

## Direct form, concrete conformance — why not the predicate form

The rule branches on the DIRECT comparison

```k
#balanceOf(B, TOK, TAKER) <Int MIN     (REVERT)
#balanceOf(B, TOK, TAKER) >=Int MIN    (PASS)
```

rather than on an abstracted Bool predicate. An earlier revision of this opcode used a predicate
`#balanceLtMin(TOK, MIN)` (conceptually `#balanceOf(BALS, TOK, TAKER) <Int MIN`) and a symbolic
universal claim `proofs/gte-spec.k` branched on it. That revision was WRONG and has been
reverted. Two independent problems:

1. **The symbolic claim was TAUTOLOGICAL.** `gte-spec.k` assumed `#balanceLtMin(TOK, MIN)` as a
   premise, and the rule's REVERT arm fired on the same `#balanceLtMin(TOK, MIN)` — so the
   "proof" assumed the predicate and then concluded under the predicate, establishing NOTHING
   about whether the underlying `<` / `>=` definition matched Solidity. A wrong definition
   (e.g. `<=Int MIN` vs `<Int MIN`, or comparing the wrong token) would have passed identically.
   This is the worst kind of false confidence: green CI, no content.
2. **krun could not reduce the predicate either.** With `[function, no-evaluators]` and no
   simplification rule equating the predicate to the underlying comparison (the simplification
   rule was deliberately omitted because it would re-introduce the arm-selection issue — see
   below), a concrete `krun` on a Gte program would leave `#balanceLtMin(1, 10)` as a residual
   symbol. So the predicate form had NO conformance evidence of any kind: not from kprove (the
   proof was tautological) and not from krun (the predicate does not reduce).

The direct form restores MEANING to the comparison: the rule now says what the Solidity says,
and a wrong definition would be caught by any claim that exercises it.

### Why the symbolic universal claim no longer proves

The direct form has a known limitation: a SYMBOLIC universal claim over arbitrary `TOK`, `MIN`,
and `TAKER` does NOT prove. The K Haskell backend (v7.1.337, the toolchain in this repo) does
not propagate an inequality premise on an uninterpreted-vs-symbolic comparison into a
refutation of the opposite arm of a two-arm rule. With arms `#balanceOf(...) <Int MIN` vs
`>=Int MIN` and a premise `#balanceOf(...) <Int MIN`, the PASS arm is still explored, the PASS
arm does not halt (it leaves `#run` in `<k>`), the loop runs into the symbolic `TAIL`, and the
all-path claim stalls. This is the same failure mode the Deadline subagent's diagnostic
isolated (`opcodes/deadline.md:125-156`) with a minimal reproducer: a fake opcode with arms
`#testVal(0) >Int X` vs `<=Int X` and premise `#testVal(0) >Int X` FAILS to prove.

The gate rule (`swapvm.md:182-193`) avoids this only because its arms compare `#balanceOf(...)`
to a CONSTANT (`0`), not a symbolic value, and constant reasoning IS propagated. Gte compares
to a SYMBOLIC `MIN` (read from args), so the direct form is exposed.

### The right trade: concrete claims

The arm-selection limitation does NOT affect CONCRETE claims. With both `#balanceOf(B, TOK,
TAKER)` and `MIN` reduced to concrete Ints — the former by `#balanceOf`'s defining rule on a
concrete `<balances>` cell, the latter by a concrete `Int2Bytes(32, MIN, BE)` payload — the
`<Int` / `>=Int` split is a concrete arithmetic fact the SMT solver decides immediately, with
no uninterpreted-vs-symbolic comparison in the way.

The two concrete claims in `proofs/gte-concrete.k` therefore ARE the conformance evidence: each
runs a fully-concrete 54-byte program through `#run` and asserts the exact final `<pc>` and
`<status>`. A concrete claim that proves under kprove is the operational equivalent of having
`krun` the program — and unlike the predicate form, krun CAN reduce the direct comparison on a
concrete `<balances>` cell.

The trade is asymmetric and correct: concrete conformance is REAL verification, the
tautological symbolic claim was not. The symbolic universal claim is sacrificed; the concrete
claims are added. Should the K backend grow the missing SMT propagation, the symbolic universal
claim can be reinstated on top of the direct form (the prior `gte-spec.k` shape, minus the
predicate).

### Diagnostic cross-reference

The arm-selection limitation was isolated with the same minimal reproducer recorded in
`opcodes/deadline.md:125-156`: a fake opcode `200` with three shapes — comparison to a constant
(proves), comparison to a symbolic value via inequality premise (fails), Bool predicate
(proves). The reproducer was run in-tree against the same kompiled definition shape the real
proof uses, so the result is on the same backend, not a toy. The Gte change here adopts the
"comparison to a symbolic value" shape directly and accepts its consequence; the Deadline and
SupplyShare opcodes (`opcodes/deadline.k`, `opcodes/supplyshare.k`) chose the predicate shape
instead, because their symbolic universal claims were NOT tautological (their premises
constrained the predicate, not a separate uninterpreted function with its own definition). Gte's
situation differs: there was nothing to constrain independently — the predicate WAS the
comparison — so the predicate form collapsed into tautology.

## Pad-and-truncate soundness hazard (swapvm.md:301-324)

The Solidity constrains nothing about `args.length`. A short `args` is right-zero-padded at
BOTH read sites:

- `address(bytes20(args))` pads a <20-byte args with zero bytes on the right (so e.g. a 10-byte
  args reads as a 20-byte address whose last 10 bytes are zero);
- `bytes32(args.slice(20))` pads a short tail with zero bytes (so e.g. an argsLen of 30 reads
  only 10 bytes at offset 20, then 22 zero bytes, yielding a small minAmount).

A long `args` is silently truncated at both sites (so e.g. an argsLen of 100 reads only bytes
`[0:20]` as the token and bytes `[20:52]` as minAmount, ignoring bytes `[52:100]`). Neither
case reverts on chain.

If the model only handled the canonical 52-byte case and let every non-canonical length fall
through to the `[owise]` unknown-opcode no-op (`swapvm.md:349-351`), every such Gte would be
**silently deleted from the model** while staying live in production — the worst failure
direction, sound but wrong. A real maker program with a length typo at a Gte would silently
bypass the balance check on chain, and the model would have nothing to say.

The mitigation follows the pattern already in `swapvm.md:319-324` for opcodes `0x23` and
`0x90`, and the twins at `opcodes/jump.k:50-54` and `opcodes/deadline.k:121-126`: make the gap
**loud instead of silent** by reverting with `"UNMODELLED-ARGS-LENGTH"` for any non-canonical
length. A proof touching such a Gte then fails rather than succeeds on a fiction.

```k
rule <k> #exec ( 36 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
  requires lengthBytes(ARGS) =/=Int 52
```

Modelling the pad-and-truncate semantics faithfully — so the rule could be stated over
arbitrary-length `args` and reduce correctly — is Phase 2 work, recorded alongside the same
status for opcodes `0x23`, `0x90`, `0x03` (Jump), and `0x20` (Deadline).

## Integration

`gte.k` defines a **sibling module `SWAPVM-GTE`** that imports `SWAPVM`, rather than reopening
`module SWAPVM`. K v7 (the toolchain in this repo) rejects reopening a module across files with
`Module SWAPVM differs from previous declaration`; this is the same constraint that shaped
`stop.k`, `revert.k`, `salt.k`, `jump.k`, and `deadline.k`. Two lines must be added to
`semantics/lemmas.k`:

1. `requires "opcodes/gte.k"` at the top (alongside the existing `requires "swapvm.md"` and
   the other opcode `requires`), so K parses the file and `SWAPVM-GTE` is available to import.
2. `imports SWAPVM-GTE` inside `module SWAPVM-BYTES-LEMMAS` (alongside the existing
   `imports SWAPVM` and the other opcode imports), so the Gte rules are in scope for every spec
   that imports `SWAPVM-BYTES-LEMMAS` (which is all of them).

A single `requires` alone is **not** sufficient: K does not auto-import the modules of a
required file into the main module. (See `opcodes/jump.md` "Integration",
`opcodes/deadline.md` "Integration" for the same constraint.) This file uses
`requires "../swapvm.md"` — resolving relative to its own directory — so it kompiles correctly
when invoked as `kompile ... lemmas.k` from `semantics/` without an `-I` flag.

`run-proofs.sh` is not currently integrated (the harness is build-and-kprove only in this
environment); when it is re-wired, the prior entries

```
'gte-spec|prove'                  # DELETED — symbolic claim was tautological under predicate form
'gte-control|fail'                # DELETED — sensitivity twin of the tautological claim
```

should NOT be re-added. The concrete claims in `proofs/gte-concrete.k` replace them; a harness
entry per claim would look like `gte-concrete|prove`.

## Fidelity gaps (declared per `PLAN.md` D3, D4, D5)

- **No symbolic universal claim.** The direct two-arm form does not support a symbolic
  universal claim over arbitrary `TOK` / `MIN` / `TAKER` because the K Haskell backend does not
  propagate an inequality premise on an uninterpreted-vs-symbolic comparison into a refutation
  of the opposite arm (see "Direct form, concrete conformance"). The conformance burden is
  carried instead by the two CONCRETE claims in `proofs/gte-concrete.k`, which prove and
  exercise the real `<Int` / `>=Int` split on fixed inputs. This is more evidence than the
  prior predicate form provided (its symbolic claim was tautological; see above). The trade is
  asymmetric and correct.
- **Non-canonical args unmodelled.** Solidity right-pads short `args` and truncates long ones
  without reverting; the model reverts with `"UNMODELLED-ARGS-LENGTH"` for any `args.length`
  other than 52. This makes the gap loud rather than silent (`swapvm.md:314-316`), in the same
  safe direction chosen for opcodes `0x23`, `0x90`, `0x03`, and `0x20`. Recorded here so it is
  not mistaken for an oversight.
- **Revert reason collapsed to a token.** Per D5, the revert reason in the K model is an
  opaque token. The Solidity's `TakerTokenBalanceIsLessThanRequired(ctx.query.taker, token,
  balance, minAmount)` carries the taker address, token, balance, and minAmount as error
  payload; the K model collapses this to the string token
  `"TakerTokenBalanceIsLessThanRequired"`. The fidelity gap — the real VM's revert data carries
  taker, token, balance, and minAmount, K's does not — mirrors the same gap declared in
  `opcodes/revert.k` for `InstructionRevert` and in `opcodes/deadline.md:251-255` for
  `DeadlineReached`.
- **`ADMITTED`.** Per the trust model in `PLAN.md` §5a, every instruction rule starts
  `ADMITTED`. This opcode is exercised by the concrete conformance claims in
  `proofs/gte-concrete.k` (both arms), cross-checked against the Solidity side in
  `test/conformance/InstructionConformance.t.sol`.

## Composition

Gte is **like** the gate (`proofs/gate-spec.k`) on the REVERT arm and **unlike** it on the
PASS arm:

- The REVERT arm halts: `#revert` clears the continuation (`swapvm.md:154-156`), so any tail in
  the program is unconsumed. A positive claim could in principle quantify over an arbitrary
  symbolic `TAIL` exactly as `gate-spec.k` and `deadline-spec.k` do — except that the direct
  two-arm form does not support such a symbolic claim (see "Direct form, concrete conformance").
- The PASS arm does not halt: it leaves `#run` in `<k>`, so the loop proceeds to decode the
  byte at the next `<pc>`. An arbitrary symbolic tail therefore cannot be the basis of a clean
  terminating claim, for the same reason it cannot in `salt-spec.k`, `jump-spec.k`, and
  `deadline-spec.k`: with a symbolic tail the first byte of the tail is symbolic and no decode
  rule reduces, so the prover gets stuck with a residual indistinguishable from a false claim's.

Both arms therefore terminate CONCRETELY in the claims in `proofs/gte-concrete.k`: the program
is exactly the 54-byte Gte and the loop-exit rule (`swapvm.md:100-105`) fires when
`<pc> = 54 >= lengthBytes(PGM)`. The two claims cover both arms (REVERT for `balance < MIN`,
PASS for `balance >= MIN`, including the boundary `balance == MIN`).
