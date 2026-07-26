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
    // balance * 1e18 >= minShareE18 * totalSupply
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

1. **REVERT arm** — canonical `lengthBytes(ARGS) ==Int 28`, premise
   `notBool #supplyShareSufficient(BALANCE, TOTALSUPPLY, MIN)` (conceptually the failure of
   the conjunction): reverts with `"TakerTokenBalanceSupplyShareIsLessThanRequired"`,
   clears `<k>`, sets `<status>`.
2. **PASS arm** — canonical length, premise
   `#supplyShareSufficient(BALANCE, TOTALSUPPLY, MIN)`: no-op, leaves `#run` in `<k>`,
   loop proceeds.
3. **UNMODELLED-ARGS-LENGTH arm** — `lengthBytes(ARGS) =/=Int 28`: reverts loudly with
   `"UNMODELLED-ARGS-LENGTH"` so a proof cannot silently succeed on a wrong length.

The token and minShareE18 are read with

```k
Bytes2Int(substrBytes(ARGS,  0, 20), BE, Unsigned)   // token
Bytes2Int(substrBytes(ARGS, 20, 28), BE, Unsigned)   // minShareE18
```

Under `lengthBytes(ARGS) ==Int 28` these are the exact 20- and 8-byte big-endian reads the
Solidity does, and the round-trip lemma (`lemmas.k:64-67`) rewrites each
`Bytes2Int(Int2Bytes(...))` back to the symbolic Int the spec supplies, under the standard
width bounds (`0 <=Int TOK <Int 2^160` with N = 20; `0 <=Int MIN <Int 2^64` with N = 8).

## The two external reads

The Solidity consults the chain **twice**:

1. **`IERC20(token).balanceOf(ctx.query.taker)`** (Controls.sol:171) — already modelled via
   `#balanceOf(B, TOKEN, HOLDER)` (swapvm.md:171-174), the existing D4 abstraction boundary
   for ERC-20 state (`PLAN.md` D4). SupplyShare reuses it unchanged.
2. **`IERC20(token).totalSupply()`** (Controls.sol:172) — NOT modelled anywhere in
   swapvm.md. Per `PLAN.md` D4 this is an external ERC-20 read at the abstraction boundary,
   modelled here as a local uninterpreted function
   `syntax Int ::= #totalSupply ( Int ) [function, no-evaluators]`
   (see `opcodes/supplyshare.k`). No defining rule: its value is fixed-but-unknown,
   constrained only by spec premises. The brief forbids editing swapvm.md — five sibling
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
- **Quantification lives in the spec.** A spec reasons about supply either through the
  `#supplyShareSufficient` predicate (the recommended path) or directly, e.g.
  `requires #totalSupply(TOK) >Int 0`.

## The share arithmetic the predicate encapsulates

`#supplyShareSufficient(BALANCE, TOTALSUPPLY, MINSHAREE18)` abstracts the full Solidity
require conjunction (Controls.sol:175):

```
   TOTALSUPPLY >Int 0
 andBool
   BALANCE *Int 1000000000000000000  >=Int  MINSHAREE18 *Int TOTALSUPPLY
```

i.e. `totalSupply > 0` AND `balance * 1e18 >= minShareE18 * totalSupply`. The opcode reverts
iff this conjunction FAILS — that is, iff `totalSupply == 0` OR
`balance * 1e18 < minShareE18 * totalSupply`.

The factor `1e18` matches Solidity's `1e18` literal exactly: shares are expressed in
parts-per-1e18 (a minShareE18 of `1e18` means "100% of supply", `5e17` means "50%", etc.).
The product `MINSHAREE18 *Int TOTALSUPPLY` is the symbolic threshold the balance scaled by
`1e18` must reach.

## Arm selection — why the Bool predicate, not the direct arithmetic

The Solidity-faithful condition is the conjunction above. The natural two-arm rule form
would split on the conjunction vs its negation:

```
   requires ... >=Int MIN *Int #totalSupply(...) andBool #totalSupply(...) >Int 0    // PASS
   requires notBool (...)                                                          // REVERT
```

**This does not prove in the K Haskell backend.** The diagnostic was established by the
Deadline subagent (`opcodes/deadline.md:125-156`) and re-confirmed by the Gte subagent
(`opcodes/gte.md` "Arm selection"): the backend does NOT propagate an inequality premise on
an uninterpreted-vs-SYMBOLIC comparison into a refutation of the opposite arm of a two-arm
rule. Here BOTH conjuncts involve uninterpreted functions compared to (or multiplied by)
symbolic values:

- `#totalSupply(...) >Int 0` — uninterpreted-vs-constant, which the gate (`0x23`) shows DOES
  propagate;
- `#balanceOf(...) *Int 1e18 >=Int MIN *Int #totalSupply(...)` — uninterpreted-vs-symbolic
  on BOTH sides, which does NOT propagate.

A spec premise `notBool (#balanceOf(...) *Int 1e18 >=Int MIN *Int #totalSupply(...))` would
not refute the PASS arm, the PASS arm would not halt, the loop would run into the symbolic
TAIL, and the all-path claim would stall — exactly the failure mode the diagnostic
isolates, now confirmed by **two sibling subagents this round** (Deadline, Gte). The brief's
"CRITICAL lesson" directs going straight to the predicate form rather than attempting the
direct two-arm arithmetic form first; this file honours that.

The fix is the same shape Deadline and Gte adopted: abstract the entire conjunction into a
single Bool predicate `#supplyShareSufficient(BAL, TS, MIN)` and branch on THAT. A premise
`notBool #supplyShareSufficient(BAL, TS, MIN)` (implicitly `==Bool true`) then selects the
REVERT arm exactly as:

- `#balanceOf(...) ==Int 0` selects the gate's (`0x23`) REVERT arm,
- `#deadlineExceeded(DL)` selects Deadline's (`0x20`) REVERT arm,
- `#balanceLtMin(TOK, MIN)` selects Gte's (`0x24`) REVERT arm.

The three symbols (`#balanceOf`, `#totalSupply`, `#supplyShareSufficient`) are kept as
independent uninterpreted terms — no simplification rule equates the predicate with its
arithmetic expansion — so the arm-selection condition stays a single atomic Bool the SMT
solver can decide on.

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
2. **The `1e18` arithmetic is encapsulated, not symbolically verified.** The predicate
   abstracts the conjunction `totalSupply > 0 && balance * 1e18 >= minShareE18 * totalSupply`
   but the K rule does not evaluate it. A spec premise
   `notBool #supplyShareSufficient(BAL, TS, MIN)` asserts the predicate's truth value
   directly; the spec does not derive it from concrete `BAL`, `TS`, `MIN` values via the
   arithmetic. This is the price of the predicate-form arm selection the K Haskell backend
   forces. A spec that wanted to verify the arithmetic for a concrete instance would have
   to assume the predicate-to-arithmetic equation as a lemma, which is itself unverified.
3. **The REVERT arm lumps two failure modes.** The Solidity reverts on EITHER
   `totalSupply == 0` OR `balance * 1e18 < minShareE18 * totalSupply`, with the same error
   selector. The model mirrors this — one predicate, one revert — and cannot distinguish
   the two failure modes in a trace. This matches on-chain behaviour (same selector) but
   loses information a debugger might want.

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

The SPECS list gains the two new files alongside the existing twins:

```
proofs/supplyshare-spec.k
proofs/supplyshare-control.k
```

Sensitivity twin of `supplyshare-spec.k` is `supplyshare-control.k` — same premises,
conclusion `Running` instead of `Reverted("TakerTokenBalanceSupplyShareIsLessThanRequired")`
— must FAIL. Together they show kprove is discriminating on the conclusion rather than
choking on the setup. Same shape as gte-spec.k / gte-control.k.
