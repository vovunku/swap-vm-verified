# `0x2b` PrivateOrder — formal semantics

Design doc for `semantics/opcodes/privateorder.k`. Companion to `swapvm.md` (decode loop,
gate at 177-194, pad/truncate at 301-324), `opcodes/txorigin.md` (sibling gate), and the
Phase 1 instruction notes (`PHASE1.md`).

## Source

`Whitelist.sol:103-110` (doc comments 103-104, function body 105-110):

```solidity
/// @notice Allows order to be executed only by the specified Taker
/// @param args.allowedTaker | 10 bytes, last 10 bytes of address are used
function _privateOrder(Context memory ctx, bytes calldata args) internal pure {
    uint80 sender = WhitelistArgsBuilder.wrapToPackedAddress(ctx.query.taker);
    uint80 allowedTaker = args.parsePrivateOrder();

    require(sender == allowedTaker, WhitelistInvalidTaker());
}
```

with the two helpers (`Whitelist.sol:20-24, 81-85`):

```solidity
function parsePrivateOrder(bytes calldata args) internal pure returns (uint80 allowedTaker) {
    assembly ("memory-safe") { allowedTaker := shr(176, calldataload(args.offset)) }
}
function wrapToPackedAddress(address taker) internal pure returns (uint80 packed) {
    packed = uint80(uint160(taker));   // last 10 bytes (80 bits) of the address
}
```

Opcode `0x2b` = 43 decimal. Args layout: `[allowedTaker:10]`, total **10 bytes** — the
packed allowed taker (the low 80 bits of their address). The opcode computes
`uint80(uint160(ctx.query.taker))` — the taker's low 80 bits — and reverts with
`WhitelistInvalidTaker` iff it does NOT equal the packed arg. Otherwise it is a pure
no-op (writes no register, no `setNextPC`).

`#exec` is fired by the decode loop (swapvm.md:141-149) AFTER the `[opcode:1][argsLen:1]`
header has been consumed and `<pc>` advanced by `2 + argsLen`, exactly mirroring
`pcs := add(pcs, 2); ... pcs := add(pcs, argsLength)` in `VM.sol:133-138`. This opcode
neither reads nor writes `<pc>` beyond that, so the rule inherits the already-advanced
value and leaves it — the same posture as the `0x23` gate, Revert, Salt, Deadline, Gte,
and TxOrigin.

## Relationship to `0x23` (OnlyTakerTokenBalanceNonZero)

This opcode is a **pure equality gate** structurally parallel to `0x23`
(Controls.sol:140-144, modelled at swapvm.md:177-194). The two share every structural
decision:

| Aspect | `0x23` | `0x2b` |
|---|---|---|
| Opcode (decimal) | 35 | 43 |
| Args layout | `[token:20]` | `[allowedTaker:10]` |
| Args decode | `address(bytes20(args))` | `shr(176, calldataload(args.offset))` |
| Cell read | `<taker>` (via `#balanceOf`) | `<taker>` (directly) |
| Predicate | `balance > 0` | `packed(taker) == packed(arg)` |
| External read | `IERC20(token).balanceOf(taker)` | none — pure |
| Error selector | `TakerTokenBalanceIsZero` | `WhitelistInvalidTaker` |
| K side condition | `lengthBytes(ARGS) ==Int 20` | `lengthBytes(ARGS) ==Int 10` |
| K arm split | `>Int 0` / `<=Int 0` | `==Int` / `=/=Int` |
| `<status> Running` guard | absent | absent |

The structural difference is the predicate: `0x23` is an **inequality** against zero (an
external `balanceOf` read compared to a constant); `0x2b` is an **equality** between two
decoded values (the taker's packed address and the packed arg). Both are pure gates —
neither writes a register, neither touches `<pc>` beyond the decode advance.

## What the K rule does

Three rules in `opcodes/privateorder.k`:

1. **PASS arm** — canonical `lengthBytes(ARGS) ==Int 10`, premise
   `(TAKER modInt (2 ^Int 80)) ==Int Bytes2Int(ARGS, BE, Unsigned)`: no-op, leaves
   `#run` in `<k>`, loop proceeds.
2. **REVERT arm** — canonical length, premise
   `(TAKER modInt (2 ^Int 80)) =/=Int Bytes2Int(ARGS, BE, Unsigned)`: reverts with
   `"WhitelistInvalidTaker"`, clears `<k>`, sets `<status>`.
3. **UNMODELLED-ARGS-LENGTH arm** — `lengthBytes(ARGS) =/=Int 10`: reverts loudly with
   `"UNMODELLED-ARGS-LENGTH"` so a proof cannot silently succeed on a wrong length.

The packed arg is read with

```k
Bytes2Int(ARGS, BE, Unsigned)   // whole 10-byte args as big-endian uint80
```

Under `lengthBytes(ARGS) ==Int 10` this is the exact 10-byte big-endian read matching
`shr(176, calldataload(args.offset))` on a canonical 10-byte args, and the round-trip
lemma (`lemmas.k:64-67`) rewrites `Bytes2Int(Int2Bytes(10, PACKED, BE), BE, Unsigned) =>
PACKED` under the standard width bound `0 <=Int PACKED <Int 2^80` with N = 10. No
`substrBytes` is needed because the whole args is the packed taker (same as `0x23` reads
the whole args as the token; contrast SupplyShare/Gte, which slice multiple fields).

## The 80-bit packing — `modInt (2 ^Int 80)`

**This is the central modelling decision and a fidelity point worth recording.**

The Solidity discards the high 80 bits of the taker's address before comparing:
`uint80(uint160(taker))` keeps only the low 10 bytes. The K model mirrors this exactly:

```k
TAKER modInt (2 ^Int 80)
```

`modInt (2 ^Int 80)` is the integer analogue of the `uint80(...)` cast: it returns the
unique integer in `[0, 2^80)` congruent to `TAKER` modulo `2^80`, i.e. it discards every
bit at position 80 and above. This is the faithful model of the truncation.

**Why this matters — the collision trade-off (Whitelist.sol:88-95).** Because only the
low 80 bits are compared, two distinct addresses that share their low 10 bytes are
**indistinguishable** to this opcode: both pass the gate identically. The Solidity
doc comments (Whitelist.sol:88-95) document this as a deliberate trade-off:

> Partial account validation trade-off:
> - For packing taker addresses, only last 80 bits of each address are used
> - Mining 80 bits of an Ethereum address is not truly impossible but would take millions
>   of GPU-years time
> - Consider theoretical possibility of such address being mined for an address known for
>   years, avoid orders with "free money" relying on the opcodes
> - The Oorschot–Wiener (birthday) attack can efficiently (though computationally
>   expensively) find 80-bit collisions, however, this supposes attacker controls the
>   both accounts, which means whitelist bypass is not a security break

The K model **faithfully preserves** this truncation rather than closing it. A spec can
reason about the collision directly: two takings `T1` and `T2` with
`T1 modInt (2^80) ==Int T2 modInt (2^80)` but `T1 =/=Int T2` are provably
indistinguishable to the gate. This is the property an integrator reasoning about the
whitelist's security boundary needs; modelling the full 160-bit address would silently
strengthen the model beyond what the chain enforces — the worst failure direction (sound
but wrong, in the opposite direction from the pad/truncate hazard: too strong rather
than too weak).

The packed arg, being produced by `Int2Bytes(10, PACKED, BE)` under
`0 <=Int PACKED <Int 2^80`, is already in `[0, 2^80)` and needs no further reduction.

## Arm selection — why the direct two-arm form works here, no Bool predicate

Unlike Deadline (`#blockTimestamp() >Int DL`, `opcodes/deadline.md:125-156`), Gte
(`#balanceOf(...) <Int MIN`, `opcodes/gte.md` "Arm selection"), and SupplyShare (the
`totalSupply > 0 && balance * 1e18 >= minShareE18 * totalSupply` conjunction,
`opcodes/supplyshare.md` "Arm selection"), this opcode compares two terms for
**EQUALITY**. Equality between two terms — symbolic or concrete — is decidable in the K
Haskell backend (it is discharged by the SMT solver), so the direct two-arm form works:

```k
... requires (TAKER modInt (2 ^Int 80)) ==Int  Bytes2Int(ARGS, BE, Unsigned)   // PASS
... requires (TAKER modInt (2 ^Int 80)) =/=Int Bytes2Int(ARGS, BE, Unsigned)   // REVERT
```

A spec premise `(TAKER modInt 2^80) =/=Int PACKED` refutes the PASS arm (its `==Int`
side condition becomes unsatisfiable) and selects the REVERT arm directly — exactly as
`#balanceOf(...) ==Int 0` selects the `0x23` REVERT arm (swapvm.md:189-193). The
Deadline/Gte/SupplyShare arm-selection limitation only affects **inequalities against
SYMBOLIC values**; it does not apply to `==`/`=/=`, which the SMT solver decides
exhaustively.

This is the same fact that lets the `0x23` gate prove in the direct form. The brief's
modelling section directs trying the direct form first and falling back to a Bool
predicate `#takerMatchesPacked(TAKER, PACKED)` only if kprove stalls — no fallback was
needed; both specs prove (and the control fails) in the direct form. See "Verification"
in the spec files' headers for the recorded rc values.

## Pad-and-truncate hazard

The Solidity constrains nothing about `args.length`. `parsePrivateOrder` does
`shr(176, calldataload(args.offset))`: `calldataload` reads 32 bytes starting at
`args.offset`, then `shr 176` keeps the top 10 bytes (176 = 32*8 - 10*8). On a SHORT
args this reads past the end of `args` into whatever follows in calldata (the EVM
right-zero-pads `calldataload` past the calldata end, but reads real bytes from any
calldata that follows `args`); on a LONG args it silently takes the first 10 bytes and
ignores the rest. Neither case reverts on chain.

If the model only handled the canonical 10-byte case and let the rest fall through to
the `[owise]` unknown-opcode no-op (`swapvm.md:349-351`), every such PrivateOrder would
be **silently deleted from the model** while staying live in production — the worst
failure direction (sound but wrong). A maker program with a length typo at a
PrivateOrder would silently bypass the whitelist on chain, and the model would have
nothing to say.

The mitigation follows the pattern already in `swapvm.md:319-324` for opcodes `0x23` and
`0x90`: make the gap **loud instead of silent** by reverting with
`"UNMODELLED-ARGS-LENGTH"` for any non-canonical length. A proof touching such a
PrivateOrder then fails rather than succeeds on a fiction.

```k
rule <k> #exec ( 43 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
  requires lengthBytes(ARGS) =/=Int 10
```

Modelling the pad-and-truncate semantics faithfully — so the rule could be stated over
arbitrary-length `args` and reduce correctly — is Phase 2 work, recorded alongside the
`0x23` / `0x90` / `0x03` / `0x26` / `0x2a` / `0x2c` entries in `semantics/OPCODE-BACKLOG.md`
(the same status as for those opcodes).

## Fidelity gaps (declared per `PLAN.md` D3, D5)

1. **The 80-bit truncation is FAITHFULLY PRESERVED, not closed.** This is the dominant
   fidelity fact about this opcode and the one an integrator most needs to know. The
   Solidity compares `uint80(uint160(taker))` to the packed arg, discarding the taker's
   high 80 bits. The K model computes `TAKER modInt (2 ^Int 80)`, which is the exact
   integer analogue. Two addresses sharing their low 10 bytes pass identically in both
   the chain and the model — the collision-mining risk documented at
   `Whitelist.sol:88-95` (millions of GPU-years for a single collision; the
   van Oorschot–Wiener birthday attack is feasible but requires the attacker to control
   both accounts, so a whitelist bypass is not a security break) is therefore a property
   a spec can reason about directly. This is **not** a gap to close; modelling the full
   160-bit address would silently strengthen the model beyond the chain.
2. **Non-canonical args unmodelled.** Solidity reads past a short `args` (into following
   calldata, or zero-padded at the calldata end) and truncates a long one without
   reverting; the model reverts with `"UNMODELLED-ARGS-LENGTH"` for any `args.length`
   other than 10. This makes the gap loud rather than silent (swapvm.md:314-316), in the
   same safe direction chosen for opcodes `0x23`, `0x90`, `0x03`, and `0x26`. Recorded
   here so it is not mistaken for an oversight.
3. **`ADMITTED`.** Per the trust model in `PLAN.md` §5a, every instruction rule starts
   `ADMITTED`. This one is not yet exercised by the conformance harness.
4. **No relation between `<taker>` and any environment EOA is encoded.** The model reads
   `<taker>` directly (it is a cell), so unlike `0x26` (`opcodes/txorigin.k`) no
   uninterpreted `#txOrigin()`-style symbol is needed. The taker's full 160-bit value
   lives in the cell; only the rule's `modInt (2 ^Int 80)` projection discards the high
   bits. A spec that needs to relate the taker to another address (e.g. a recipient, or
   tx.origin via some future opcode) does so via premises over the cells directly.

## Integration

`SWAPVM-PRIVATEORDER` is a sibling module; it does not reopen `module SWAPVM`. To wire
it into the kompile unit, add two lines to `semantics/lemmas.k` (the run harness does
this automatically via the recipe in the brief; these are NOT edits this subagent makes —
they are the recipe the integrator applies):

```k
requires "opcodes/privateorder.k"     // at top of lemmas.k, alongside the other opcode requires
...
module SWAPVM-BYTES-LEMMAS
  imports SWAPVM
  imports SWAPVM-PRIVATEORDER          // inside the module, alongside the other imports
  ...
endmodule
```

A single `requires` alone is **not** sufficient: K does not auto-import the modules of a
required file into the main module. (See `opcodes/jump.md` "Integration",
`opcodes/stop.md` "Integration", and `opcodes/txorigin.md` "Integration" for the same
constraint.) This file uses `requires "../swapvm.md"` — resolving relative to its own
directory — so it kompiles correctly when invoked as `kompile ... lemmas.k` from
`semantics/` without an `-I` flag.

The SPECS list gains the two new files alongside the existing twins:

```
proofs/privateorder-spec.k
proofs/privateorder-control.k
```

Sensitivity twin of `privateorder-spec.k` is `privateorder-control.k` — same program and
the OPPOSITE premise (`==Int` instead of `=/=Int`), SAME `Reverted("WhitelistInvalidTaker")`
conclusion — must FAIL, because the `==Int` premise selects the PASS arm, which does not
revert, so the `Reverted` conclusion is never reached. Together they show kprove is
discriminating on the arm selected by the premise rather than choking on the setup. Same
shape as `gate-spec.k` / `negative-control.k`, `txorigin-spec.k` / `txorigin-control.k`,
`deadline-spec.k` / `deadline-control.k`, and the other sibling twins.

The positive claim (`privateorder-spec.k`) takes the REVERT direction: premise
`(TAKER modInt 2^80) =/=Int PACKED`, conclusion `Reverted("WhitelistInvalidTaker")`,
tail unconsumed. This mirrors `gate-spec.k` and `txorigin-spec.k` exactly — the revert
clears `<k>` so an arbitrary symbolic TAIL cannot affect the conclusion and the proof
must not case-split on it.
