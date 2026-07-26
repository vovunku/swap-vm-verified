# `0x25` OnlyTakerTokenSupplyShareGte — formal semantics

## Source

`Controls.sol:168-178`:

```solidity
/// @dev Checks if the taker holds at least a certain share of the total token supply
/// @param args.token       | 20 bytes
/// @param args.minShareE18 | 8 bytes
function _onlyTakerTokenSupplyShareGte(Context memory ctx, bytes calldata args) internal view {
    address token = address(bytes20(args));
    uint64 minShareE18 = uint64(bytes8(args.slice(20)));
    uint256 balance = IERC20(token).balanceOf(ctx.query.taker);
    uint256 totalSupply = IERC20(token).totalSupply();
    // balance * 1e18 / totalSupply >= minShareE18
    require(totalSupply > 0 && balance * 1e18 >= minShareE18 * totalSupply,
            TakerTokenBalanceSupplyShareIsLessThanRequired(...));
}
```

Opcode `0x25` = 37 decimal. Args layout: `[token:20][minShareE18:8]`, total **28 bytes**.
Reads the taker's ERC-20 `balanceOf(token)` AND the token's ERC-20 `totalSupply()`, and
reverts iff the conjunction `totalSupply > 0 && balance * 1e18 >= minShareE18 * totalSupply`
FAILS; otherwise it is a pure no-op (writes no register, no `setNextPC`).

`#exec` is fired by the decode loop (swapvm.md:141-149) AFTER the `[opcode:1][argsLen:1]`
header has been consumed and `<pc>` advanced by `2 + argsLen`, exactly mirroring
`pcs := add(pcs, 2); ... pcs := add(pcs, argsLength)` in `VM.sol:133-138`. SupplyShare
neither reads nor writes `<pc>` beyond that, so the rule inherits the already-advanced
value and leaves it — the same posture as Revert, Salt, Deadline, and Gte.

## What the K rule does

Three rules in `opcodes/supplyshare.k`:

1. **REVERT arm** — canonical `lengthBytes(ARGS) ==Int 28`, side condition
   `notBool (totalSupply >Int 0 andBool balance *Int 1e18 >=Int minShare *Int totalSupply)`:
   reverts with `"TakerTokenBalanceSupplyShareIsLessThanRequired"`, clears `<k>`, sets
   `<status>`.
2. **PASS arm** — canonical length, side condition
   `totalSupply >Int 0 andBool balance *Int 1e18 >=Int minShare *Int totalSupply`: no-op,
   leaves `#run` in `<k>`, loop proceeds.
3. **UNMODELLED-ARGS-LENGTH arm** — `lengthBytes(ARGS) =/=Int 28`: reverts loudly with
   `"UNMODELLED-ARGS-LENGTH"` so a proof cannot silently succeed on a wrong length.

The two canonical arms' side conditions are the LITERAL Solidity conjunction and its
negation — no predicate abstraction. The token and minShareE18 are read with

```k
Bytes2Int(substrBytes(ARGS,  0, 20), BE, Unsigned)   // token
Bytes2Int(substrBytes(ARGS, 20, 28), BE, Unsigned)   // minShareE18
```

Under `lengthBytes(ARGS) ==Int 28` these are the exact 20- and 8-byte big-endian reads the
Solidity does, and the round-trip lemma (`lemmas.k:64-67`) rewrites each
`Bytes2Int(Int2Bytes(...))` back to the symbolic Int the spec supplies, under the standard
width bounds (`0 <=Int TOK <Int 2^160` with N = 20; `0 <=Int MIN <Int 2^64` with N = 8).
The literal `1e18` is written as its full integer expansion `1000000000000000000` in the
K rule, matching Solidity exactly.

## The two external reads

The Solidity consults the chain **twice**:

1. **`IERC20(token).balanceOf(ctx.query.taker)`** (Controls.sol:174) — already modelled via
   `#balanceOf(B, TOKEN, HOLDER)` (swapvm.md:171-174), the existing D4 abstraction boundary
   for ERC-20 state (`PLAN.md` D4). SupplyShare reuses it unchanged.
2. **`IERC20(token).totalSupply()`** (Controls.sol:175) — NOT modelled anywhere in
   swapvm.md. Per `PLAN.md` D4 this is an external ERC-20 read at the abstraction boundary,
   modelled here as a local uninterpreted function
   `syntax Int ::= #totalSupply ( Int ) [function, no-evaluators]`
   (see `opcodes/supplyshare.k`). No defining rule: its value is fixed-but-unknown,
   constrained only by spec premises. The brief forbids editing swapvm.md — six sibling
   subagents depend on it being untouched — so the symbol is declared locally in
   `SWAPVM-SUPPLYSHARE` rather than added to the `<balances>` cell or a new `<totalSupplies>`
   cell. This matches how Deadline models `block.timestamp` as `#blockTimestamp()` and how
   the brief directs modelling `totalSupply`.

## D4 abstraction for `#totalSupply`

`#totalSupply(TOKEN)` is the D4 boundary for `IERC20(token).totalSupply()`:

- **`[function]`** — total function symbol of the token address.
- **`no-evaluators`** — the simplifier may not invent a reduction; it stays opaque.
- **Not a cell.** Adding a `<totalSupplies>` cell to swapvm.md was explicitly out of scope
  (swapvm.md must remain untouched); the local declaration achieves the same abstraction.
- **Quantification lives in the spec.** A concrete spec pins the supply via a premise
  (e.g. `requires #totalSupply(1) ==Int 1000`); a future symbolic spec, should the backend
  grow the missing SMT propagation, would quantify over it as a free variable.

## Direct form, concrete conformance — why not the predicate form

The rule branches on the DIRECT arithmetic

```k
totalSupply >Int 0
 andBool
balance *Int 1000000000000000000  >=Int  minShare *Int totalSupply        (PASS)
notBool ( ... )                                                        (REVERT)
```

rather than on an abstracted Bool predicate. An earlier revision of this opcode used a
predicate `#supplyShareSufficient(BAL, TS, MIN)` (conceptually the conjunction above) and
a symbolic universal claim `proofs/supplyshare-spec.k` branched on it. That revision was
WRONG and has been reverted. Two independent problems, identical to the Gte subagent's
diagnosis (`opcodes/gte.md` "Direct form, concrete conformance"):

1. **The symbolic claim was TAUTOLOGICAL.** `supplyshare-spec.k` assumed
   `notBool #supplyShareSufficient(...)` as a premise, and the rule's REVERT arm fired on
   the same `#supplyShareSufficient(...)` — so the "proof" assumed the predicate and then
   concluded under the predicate, establishing NOTHING about whether the underlying
   conjunction matched Solidity. A wrong definition (e.g. `<=Int` vs `<Int`, comparing the
   wrong token, or omitting the `totalSupply > 0` conjunct) would have passed identically.
   This is the worst kind of false confidence: green CI, no content.
2. **`krun` could not reduce the predicate either.** With `[function, no-evaluators]` and
   no simplification rule equating the predicate to its underlying conjunction (the
   simplification rule was deliberately omitted because it would re-introduce the
   arm-selection issue — see below), a concrete `krun` on a SupplyShare program would leave
   `#supplyShareSufficient(BAL, TS, MIN)` as a residual symbol. So the predicate form had
   NO conformance evidence of any kind: not from kprove (the proof was tautological) and
   not from krun (the predicate does not reduce).

The direct form restores MEANING to the comparison: the rule now says what the Solidity
says, and a wrong definition would be caught by any claim that exercises it.

### Why the symbolic universal claim no longer proves

The direct form has a known limitation: a SYMBOLIC universal claim over arbitrary `TOK`,
`MIN`, and `TAKER` does NOT prove. The K Haskell backend (v7.1.337, the toolchain in this
repo) does not propagate an inequality premise on an uninterpreted-vs-symbolic comparison
into a refutation of the opposite arm of a two-arm rule (diagnostic in
`opcodes/deadline.md:125-156`; re-confirmed for the Gte opcode — `opcodes/gte.md` "Arm
selection"). Here BOTH conjuncts involve uninterpreted functions compared to (or
multiplied by) symbolic values:

- `#totalSupply(...) >Int 0` — uninterpreted-vs-constant, which the gate (`0x23`) shows DOES
  propagate;
- `#balanceOf(...) *Int 1e18 >=Int MIN *Int #totalSupply(...)` — uninterpreted-vs-symbolic
  on BOTH sides, which does NOT propagate.

With arms the conjunction vs its negation and a premise asserting the negation, the PASS
arm is still explored, the PASS arm does not halt (it leaves `#run` in `<k>`), the loop
runs into the symbolic `TAIL`, and the all-path claim stalls — exactly the failure mode
the diagnostic isolates, now confirmed by **three sibling subagents** (Deadline, Gte,
SupplyShare).

The gate rule (`swapvm.md:182-193`) avoids this only because its arms compare
`#balanceOf(...)` to a CONSTANT (`0`), not a symbolic value, and constant reasoning IS
propagated.

### The right trade: concrete claims

The arm-selection limitation does NOT affect CONCRETE claims. With both `#balanceOf(B,
TOK, TAKER)` and `MIN` reduced to concrete Ints — the former by `#balanceOf`'s defining
rule on a concrete `<balances>` cell, the latter by a concrete `Int2Bytes(8, MIN, BE)`
payload — and `#totalSupply(TOK)` pinned by a spec premise (e.g.
`requires #totalSupply(1) ==Int 1000`), the entire conjunction becomes a concrete
arithmetic fact the SMT solver decides immediately. The 1e18 multiplications are concrete;
SMT handles them directly.

The two concrete claims in `proofs/supplyshare-concrete.k` therefore ARE the conformance
evidence: each runs a fully-concrete 30-byte program through `#run` and asserts the exact
final `<pc>` and `<status>`. A concrete claim that proves under kprove is the operational
equivalent of having `krun` the program — and unlike the predicate form, krun CAN reduce
the direct conjunction on a concrete `<balances>` cell.

The trade is asymmetric and correct: concrete conformance is REAL verification, the
tautological symbolic claim was not. The symbolic universal claim is sacrificed; the
concrete claims are added. Should the K backend grow the missing SMT propagation, the
symbolic universal claim can be reinstated on top of the direct form (the prior
`supplyshare-spec.k` shape, minus the predicate).

### Diagnostic cross-reference

The arm-selection limitation was isolated with the same minimal reproducer recorded in
`opcodes/deadline.md:125-156`: a fake opcode `200` with three shapes — comparison to a
constant (proves), comparison to a symbolic value via inequality premise (fails), Bool
predicate (proves). The reproducer was run in-tree against the same kompiled definition
shape the real proof uses, so the result is on the same backend, not a toy. The SupplyShare
change here adopts the "comparison to a symbolic value" shape directly and accepts its
consequence, matching the choice the Gte subagent made (`opcodes/gte.md` "Direct form,
concrete conformance").

## Pad-and-truncate hazard

The Solidity constrains nothing about `args.length`. A short `args` is right-zero-padded at
BOTH read sites; a long `args` is silently truncated. Neither case reverts on chain. If the
model only handled the canonical 28-byte case and let the rest fall through to the
`[owise]` no-op (swapvm.md:349-351), every such SupplyShare would be SILENTLY DELETED from
the model while staying live in production — the worst failure direction (sound but wrong).
The third rule reverts loudly with `"UNMODELLED-ARGS-LENGTH"` so a proof touching such a
SupplyShare fails rather than succeeds on a fiction. Same pattern as opcodes 0x23 / 0x90 in
swapvm.md:319-324 and the twins in jump.k, deadline.k, and gte.k.

## Fidelity gaps

1. **`#totalSupply` is abstract.** Its value is fixed-but-unknown; the K model imposes no
   relation between `#totalSupply(TOK)` and `#balanceOf(B, TOK, HOLDER)` for any holder. On
   chain, the sum of all holders' balances equals the total supply; the model does NOT
   enforce this invariant. A spec that needs it must add the premise by hand
   (e.g. `requires #totalSupply(TOK) >=Int #balanceOf(BALS, TOK, TAKER)`).
2. **No symbolic universal claim.** The direct two-arm form does not support a symbolic
   universal claim over arbitrary `TOK` / `MIN` / `TAKER` because the K Haskell backend
   does not propagate an inequality premise on an uninterpreted-vs-symbolic comparison
   into a refutation of the opposite arm (see "Direct form, concrete conformance"). The
   conformance burden is carried instead by the two CONCRETE claims in
   `proofs/supplyshare-concrete.k`, which prove and exercise the real conjunction on fixed
   inputs. This is more evidence than the prior predicate form provided (its symbolic claim
   was tautological; see above). The trade is asymmetric and correct.
3. **The REVERT arm lumps two failure modes.** The Solidity reverts on EITHER
   `totalSupply == 0` OR `balance * 1e18 < minShareE18 * totalSupply`, with the same error
   selector. The model mirrors this — one negated conjunction, one revert — and cannot
   distinguish the two failure modes in a trace. This matches on-chain behaviour (same
   selector) but loses information a debugger might want. Scenario A of the concrete
   claims exercises the `totalSupply == 0` path; a future additional concrete claim could
   pin the `balance * 1e18 < minShare * totalSupply` path on a non-zero totalSupply.

## Solidity mock gap (flagged for integrator, NOT this subagent's scope)

`Controls.sol:174-175` consults BOTH `IERC20(token).balanceOf(taker)` AND
`IERC20(token).totalSupply()`. The current Solidity conformance fixture `GateTokenMock`
(`test/conformance/InstructionConformance.t.sol:16-22`) exposes ONLY `balanceOf`:

```solidity
contract GateTokenMock {
    mapping(address => uint256) public balanceOf;
    function setBalance(address holder, uint256 amount) external {
        balanceOf[holder] = amount;
    }
}
```

To run the Solidity mirror of the two K claims in `proofs/supplyshare-concrete.k`, the
integrator must extend `GateTokenMock` (or replace it with a minimal ERC-20) to expose
`totalSupply` — e.g. add a `uint256 public totalSupply;` field with a `setTotalSupply`
setter, or rename the mock and inherit OpenZeppelin's `ERC20`. Until that is done, the
Solidity-side conformance mirror of these two K claims cannot be wired into
`InstructionConformance.t.sol`. The K side (this file, `opcodes/supplyshare.k`, and
`proofs/supplyshare-concrete.k`) is complete and self-contained and proves without it.

## Integration

`SWAPVM-SUPPLYSHARE` is a sibling module; it does not reopen `module SWAPVM`. To wire it
into the kompile unit, add two lines to `semantics/lemmas.k` (the run harness does this
automatically via the recipe in the brief; these are NOT edits this subagent makes — they
are the recipe the integrator applies):

```k
requires "opcodes/supplyshare.k"     // at top of lemmas.k, alongside the other opcode requires
...
module SWAPVM-BYTES-LEMMAS
  imports SWAPVM
  imports SWAPVM-SUPPLYSHARE          // inside the module, alongside the other imports
  ...
endmodule
```

The SPECS list gains the new file replacing the deleted twins:

```
proofs/supplyshare-concrete.k        // (was: supplyshare-spec.k + supplyshare-control.k)
```

The two prior entries (`supplyshare-spec|prove`, `supplyshare-control|fail`) are GONE —
both were tautological / sensitivity-twin-of-tautological under the predicate form. A
harness entry per concrete claim would look like `supplyshare-concrete|prove` (kprove
proves BOTH claims in the module on a single invocation).
