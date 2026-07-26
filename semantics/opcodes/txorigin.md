# `0x26` OnlyTxOriginTokenBalanceNonZero — formal semantics

## Source

`Controls.sol:146-156` (doc comments 146-151, function body 152-156):

```solidity
/// @dev Checks if tx.origin holds any amount of the specified token (NFTs are natively supported)
/// @dev The opcode allows authorized user to fill the order through 3rd-party contracts
///   Validations through tx.origin are considered weak due to possible transaction flow interception
///   E.g. authorized user performs transaction to 3rd-party protocol with no order filling intention,
///   the 3rd-party protocol may use the authorization to fill the order
/// @param args.token | 20 bytes
function _onlyTxOriginTokenBalanceNonZero(Context memory /* ctx */, bytes calldata args) internal view {
    address token = address(bytes20(args));
    uint256 balance = IERC20(token).balanceOf(tx.origin);
    require(balance > 0, TxOriginTokenBalanceIsZero(tx.origin, token));
}
```

Opcode `0x26` = 38 decimal. Args layout: `[token:20]`, total **20 bytes**. Reads the
**tx.origin** EOA's ERC-20 `balanceOf(token)` and reverts iff the balance is zero;
otherwise it is a pure no-op (writes no register, no `setNextPC`).

`#exec` is fired by the decode loop (swapvm.md:141-149) AFTER the `[opcode:1][argsLen:1]`
header has been consumed and `<pc>` advanced by `2 + argsLen`, exactly mirroring
`pcs := add(pcs, 2); ... pcs := add(pcs, argsLength)` in `VM.sol:133-138`. This opcode
neither reads nor writes `<pc>` beyond that, so the rule inherits the already-advanced
value and leaves it — the same posture as the `0x23` gate, Revert, Salt, Deadline, and
Gte.

## Relationship to `0x23` (OnlyTakerTokenBalanceNonZero)

This opcode is the **tx.origin twin** of `0x23` (Controls.sol:140-144, modelled at
swapvm.md:177-194). The two are byte-for-byte identical at every structural point:

| Aspect | `0x23` | `0x26` |
|---|---|---|
| Opcode (decimal) | 35 | 38 |
| Args layout | `[token:20]` | `[token:20]` |
| Token decode | `address(bytes20(args))` | `address(bytes20(args))` |
| Holder | `ctx.query.taker` | `tx.origin` |
| ERC-20 read | `IERC20(token).balanceOf(taker)` | `IERC20(token).balanceOf(tx.origin)` |
| Predicate | `balance > 0` | `balance > 0` |
| Error selector | `TakerTokenBalanceIsZero(taker, token)` | `TxOriginTokenBalanceIsZero(tx.origin, token)` |
| K side condition | `lengthBytes(ARGS) ==Int 20` | `lengthBytes(ARGS) ==Int 20` |
| K arm split | `>Int 0` / `<=Int 0` | `>Int 0` / `<=Int 0` |
| `<status> Running` guard | absent | absent |

The ONLY modelling difference is the HOLDER argument to `#balanceOf`: `0x23` reads it from
the `<taker>` cell, `0x26` reads it from the uninterpreted `#txOrigin()` symbol. Every
other decision — canonical-length side condition, the `>Int 0` / `<=Int 0` split, the
UNMODELLED-ARGS-LENGTH arm, the absence of a `<status> Running` guard — is inherited
verbatim from swapvm.md:182-194. This is why the brief names `0x23` the direct template.

## What the K rule does

Three rules in `opcodes/txorigin.k`:

1. **PASS arm** — canonical `lengthBytes(ARGS) ==Int 20`, premise
   `#balanceOf(B, Bytes2Int(ARGS, BE, Unsigned), #txOrigin()) >Int 0`: no-op, leaves
   `#run` in `<k>`, loop proceeds.
2. **REVERT arm** — canonical length, premise
   `#balanceOf(B, Bytes2Int(ARGS, BE, Unsigned), #txOrigin()) <=Int 0`: reverts with
   `"TxOriginTokenBalanceIsZero"`, clears `<k>`, sets `<status>`.
3. **UNMODELLED-ARGS-LENGTH arm** — `lengthBytes(ARGS) =/=Int 20`: reverts loudly with
   `"UNMODELLED-ARGS-LENGTH"` so a proof cannot silently succeed on a wrong length.

The token is read with

```k
Bytes2Int(ARGS, BE, Unsigned)   // whole 20-byte args as big-endian uint160
```

Under `lengthBytes(ARGS) ==Int 20` this is the exact 20-byte big-endian read the Solidity
does (`address(bytes20(args))`), and the round-trip lemma (`lemmas.k:64-67`) rewrites
`Bytes2Int(Int2Bytes(...))` back to the symbolic Int the spec supplies, under the standard
width bound `0 <=Int TOK <Int 2^160` with N = 20. No `substrBytes` is needed because the
whole args is the token (same as `0x23`; contrast SupplyShare/Gte, which slice multiple
fields).

## D4 abstraction for `tx.origin` — `#txOrigin()`

`tx.origin` is an EVM environment value the current K config has **no cell for**. The
`<query>` cell carries the swap's `taker`, `recipient`, etc., but not the originating
EOA. Per `PLAN.md` D4 this is an external environment read at the abstraction boundary,
modelled here as a local uninterpreted function

```k
syntax Int ::= #txOrigin () [function, no-evaluators]
```

(`opcodes/txorigin.k`). Properties:

- **`[function]`** — total function symbol (nullary: tx.origin is a property of the
  transaction, not of any particular token read).
- **`no-evaluators`** — the simplifier may not invent a reduction; it stays opaque.
- **Not a cell.** Adding a `<txOrigin>` cell to swapvm.md was explicitly out of scope
  (swapvm.md must remain untouched — five sibling subagents depend on it); the local
  declaration achieves the same abstraction without that coordination cost.
- **Quantification lives in the spec.** A spec reasons about tx.origin's balance directly
  via `#balanceOf(BALS, TOK, #txOrigin())`. The minimal positive claim fixes this to 0
  (`#balanceOf(BALS, TOK, #txOrigin()) ==Int 0`) and asserts the revert.

The opcode then REUSES the existing `#balanceOf` machinery (swapvm.md:171-174) — the same
call `0x23` makes, with `#txOrigin()` in place of `TAKER`. No new balance-lookup symbol is
needed. This matches how Deadline models `block.timestamp` as `#blockTimestamp()`
(`opcodes/deadline.k`) and how SupplyShare models `totalSupply` as `#totalSupply(Int)`
(`opcodes/supplyshare.k`): environment / external values are uninterpreted symbols at the
D4 boundary, never cells.

## Security caveat (recorded from Controls.sol:146-151)

The Solidity doc comments call out that **`tx.origin` validation is weaker than
`ctx.query.taker` validation**. The two relevant `@dev` lines (Controls.sol:147-150):

> The opcode allows authorized user to fill the order through 3rd-party contracts.
> Validations through tx.origin are considered weak due to possible transaction flow
> interception. E.g. authorized user performs transaction to 3rd-party protocol with no
> order filling intention, the 3rd-party protocol may use the authorization to fill the
> order.

Concretely: an authorized EOA that calls an arbitrary third-party contract grants that
contract the ability to fill any order guarded only by `0x26`, because `tx.origin` resolves
to the EOA regardless of the call chain. The twin `0x23` does not have this exposure — it
checks `ctx.query.taker`, which the taker controls directly via the swap query.

**This is a fidelity gap worth recording but not one the K model can close.** The K rule
mirrors the Solidity exactly: it consults `#txOrigin()` (an opaque value fixed per
execution) and reverts iff the balance is zero. The model has no notion of call chain,
flashloan, or compositional attack — those are properties of the surrounding EVM, not of
this instruction. A spec that needs to reason about the attack would have to assert
premises over `#txOrigin()` and the `<taker>` cell jointly (e.g. that they differ, that
`taker` is a contract, etc.); the rule itself is faithful either way.

## Arm selection — why the direct two-arm form works here, no Bool predicate

Unlike Deadline (`#blockTimestamp() >Int DL`, `opcodes/deadline.md:125-156`), Gte
(`#balanceOf(...) <Int MIN`, `opcodes/gte.md` "Arm selection"), and SupplyShare (the
`totalSupply > 0 && balance * 1e18 >= minShareE18 * totalSupply` conjunction,
`opcodes/supplyshare.md` "Arm selection"), this opcode compares `#balanceOf(...)` to a
**CONSTANT** (`0`), not to a symbolic value. The K Haskell backend CAN branch on
`#balanceOf(...) >Int 0` vs `<=Int 0` because constant reasoning IS propagated into arm
refutation — this is the same fact that lets the `0x23` gate (swapvm.md:182-193) prove in
the direct form. The Deadline/Gte/SupplyShare arm-selection limitation only affects
inequalities against SYMBOLIC values.

The brief's "CRITICAL" note directs mirroring `0x23` exactly rather than introducing a
predicate. A spec premise `#balanceOf(BALS, TOK, #txOrigin()) ==Int 0` selects the REVERT
arm exactly as `#balanceOf(...) ==Int 0` selects the `0x23` REVERT arm — no
`#txOriginBalanceNonZero` Bool predicate is needed.

## Pad-and-truncate hazard

The Solidity constrains nothing about `args.length`. A short `args` is right-zero-padded
(so `0x26 0x13` followed by 19 bytes reads a 20-byte token whose last byte is zero); a
long `args` is silently truncated to 20 bytes. Neither case reverts on chain. If the model
only handled the canonical 20-byte case and let the rest fall through to the `[owise]`
no-op (swapvm.md:349-351), every such instance would be SILENTLY DELETED from the model
while staying live in production — the worst failure direction (sound but wrong). The
third rule reverts loudly with `"UNMODELLED-ARGS-LENGTH"` so a proof touching such an
instruction fails rather than succeeds on a fiction. Same pattern as opcodes `0x23` /
`0x90` in swapvm.md:319-324 and the twins in `opcodes/jump.k`, `opcodes/deadline.k`,
`opcodes/gte.k`, and `opcodes/supplyshare.k`.

## Fidelity gaps

1. **`tx.origin` is abstract.** `#txOrigin()` is a fixed-but-unknown value per execution.
   The K model imposes no relation between `#txOrigin()` and the `<taker>` cell, the
   `<recipient>` cell, or any other config value. On chain, the taker may or may not equal
   tx.origin (the swap may be filled through an intermediary contract); the model does NOT
   enforce either. A spec that needs the relation must add it as a premise (e.g.
   `requires TAKER ==Int #txOrigin()` or `requires TAKER =/=Int #txOrigin()`).
2. **The tx.origin security caveat is not modelled.** As recorded above, the Solidity
   doc comments at Controls.sol:147-150 warn that tx.origin validation is interceptable.
   The K rule faithfully mirrors the Solidity instruction but cannot reason about
   compositional / call-chain attacks; those are out of scope for an instruction-level
   semantics and would need to be asserted as spec premises if a proof needed them.
3. **`IERC20.balanceOf` return value is abstract.** Inherited from `#balanceOf`'s D4
   boundary (swapvm.md:171-174): the function returns `B [ bal(TOKEN, HOLDER) ] orDefault
   0`, so its value is whatever the spec's `<balances>` map fixes. No relation to
   `transfer` history, allowances, decimals, etc. is encoded — same gap `0x23` carries.
4. **The REVERT arm conflates "balance is zero" with the `<=Int 0` predicate.**
   `#balanceOf` is `[function, total]` and its defining rule returns `orDefault 0`, so the
   value is always `>=Int 0`; the `<=Int 0` arm therefore fires exactly when the balance
   is `0`. The split is exact, but a reader of the rule may mistake the `<=Int 0` for a
       sign-handling generality that is not in fact exercised. The 0x23 rule carries the
       identical convention.

## Integration

`SWAPVM-TXORIGIN` is a sibling module; it does not reopen `module SWAPVM`. To wire it
into the kompile unit, add two lines to `semantics/lemmas.k` (the run harness does this
automatically via the recipe in the brief; these are NOT edits this subagent makes — they
are the recipe the integrator applies):

```k
requires "opcodes/txorigin.k"     // at top of lemmas.k, alongside the other opcode requires
...
module SWAPVM-BYTES-LEMMAS
  imports SWAPVM
  imports SWAPVM-TXORIGIN          // inside the module, alongside the other imports
  ...
endmodule
```

The SPECS list gains the two new files alongside the existing twins:

```
proofs/txorigin-spec.k
proofs/txorigin-control.k
```

Sensitivity twin of `txorigin-spec.k` is `txorigin-control.k` — same program and
premises, conclusion `Running` instead of
`Reverted("TxOriginTokenBalanceIsZero")` — must FAIL. Together they show kprove is
discriminating on the conclusion rather than choking on the setup. Same shape as
`gate-spec.k` / `negative-control.k`, `deadline-spec.k` / `deadline-control.k`, and the
other sibling twins.
