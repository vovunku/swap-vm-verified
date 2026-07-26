# `0x03` Jump — formal semantics

Design doc for `semantics/opcodes/jump.k`. Companion to `swapvm.md` (decode loop),
`opcodes/stop.md`, `opcodes/revert.md`, `opcodes/salt.md` (sibling opcodes), and the Phase 1
instruction notes (`PHASE1.md`).

## Source

`Controls.sol:75-82`:

```solidity
/// @dev Unconditional jump to the specified program counter
/// @dev LIMITATION: Jump targets are limited to uint16 (0-65,535) due to 2-byte encoding.
///      For jumps to positions >= 65,536, use Extruction with custom control flow logic.
/// @param args.nextPC | 2 bytes (uint16)
function _jump(Context memory ctx, bytes calldata args) internal pure {
    uint256 nextPC = uint16(bytes2(args));
    ctx.setNextPC(nextPC);
}
```

`setNextPC` (`VM.sol:94-96`) is a one-line store into `ctx.vm.nextPC`. `runLoop`
(`VM.sol:118-149`) is `while (pcs < length)` and, after dispatch, sets `pcs = ctx.vm.nextPC`.
So a Jump instruction's effect is to overwrite whatever the loop's `pcs := add(pcs, 2);
pcs := add(pcs, argsLength)` just stored. The Solidity NatSpec documents the 2-byte limit
explicitly: jump targets are constrained to `[0, 65535]`, and the doc points to `Extruction`
for anything beyond.

`uint16(bytes2(args))` reads the first 2 bytes of `args` as a big-endian unsigned integer and
truncates to 16 bits. So the value ranges over `[0, 65535]` exactly.

## What the K rule does

The decode rule (`swapvm.md:143-149`) consumes the `[opcode:1][argsLen:1]` header and advances
`<pc>` by `2 + argsLen` **before** `#exec` fires. So a Jump instruction that writes `nextPC`
must *overwrite* the already-advanced `<pc>` — exactly as `pcs = ctx.vm.nextPC` overwrites the
advanced `pcs` in the Solidity. `swapvm.md:138-140` states this directly. This is the single
decisive difference between a correct Jump rule and a no-op: a rule that left the advanced `<pc>`
in place would model Salt, not Jump.

```k
rule <k> #exec ( 3 , ARGS ) => .K ... </k>
     <pc> _ => Bytes2Int(substrBytes(ARGS, 0, 2), BE, Unsigned) </pc>
     <status> Running </status>
  requires lengthBytes(ARGS) ==Int 2
```

The continuation `#run` is left in `<k>`. On the next step the loop attempts to decode the
instruction at the jumped-to `<pc>`. Jump is therefore **not a halt**: like Salt, it lets
execution proceed — the difference is *where* execution proceeds to. This is the dominant fact
about Jump's proof shape; see "Composition" below.

The truncation to 16 bits is automatic in the modelled case: `Bytes2Int(substrBytes(ARGS, 0, 2),
BE, Unsigned)` on a 2-byte slice yields exactly the integer in `[0, 65535]` — there is no higher
byte to truncate away. No separate `modInt 65536` is required.

## Pad-and-truncate soundness hazard (swapvm.md:301-324)

The Solidity constrains nothing about `args.length`. A short `args` is right-zero-padded:
`uint16(bytes2(b"\xab"))` reads `\xab\x00` (after the implicit padding to `bytes2`) and yields
`0xab00`, not `0xab`. A long `args` is silently truncated: `uint16(bytes2(b"\xab\xcd\xef"))`
reads only the first 2 bytes and yields `0xabcd`. Neither case reverts on chain.

If the model only handled the canonical 2-byte case and let every non-canonical length fall
through to the `[owise]` unknown-opcode no-op (`swapvm.md:349-351`), every such Jump would be
**silently deleted from the model** while staying live in production — the worst failure
direction, sound but wrong. A real maker program with a length typo at a Jump would silently
re-route execution on chain, and the model would have nothing to say.

The mitigation follows the pattern already in `swapvm.md:319-324` for opcodes `0x23` and `0x90`:
make the gap **loud instead of silent** by reverting with `"UNMODELLED-ARGS-LENGTH"` for any
non-canonical length. A proof touching such a Jump then fails rather than succeeds on a fiction.

```k
rule <k> #exec ( 3 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
  requires lengthBytes(ARGS) =/=Int 2
```

Modelling the pad-and-truncate semantics faithfully — so the rule could be stated over
arbitrary-length `args` and reduce correctly — is Phase 2 work, recorded in
`semantics/OPCODE-BACKLOG.md` (the same status as for opcodes 0x23 and 0x90).

## Integration

`jump.k` defines a **sibling module `SWAPVM-JUMP`** that imports `SWAPVM`, rather than reopening
`module SWAPVM`. K v7 (the toolchain in this repo, v7.1.337) rejects reopening a module across
files with `Module SWAPVM differs from previous declaration`; this is the same constraint that
shaped `stop.k`, `revert.k`, and `salt.k`. Two lines must be added to `semantics/lemmas.k`:

1. `requires "opcodes/jump.k"` at the top (alongside the existing `requires "swapvm.md"` and
   the other opcode `requires`), so K parses the file and `SWAPVM-JUMP` is available to import.
2. `imports SWAPVM-JUMP` inside `module SWAPVM-BYTES-LEMMAS` (alongside the existing
   `imports SWAPVM` and the other opcode imports), so the Jump rules are in scope for every
   spec that imports `SWAPVM-BYTES-LEMMAS` (which is all of them).

A single `requires` alone is **not** sufficient: K does not auto-import the modules of a required
file into the main module. (See `opcodes/stop.md` "Integration" and `opcodes/salt.md`
"Integration" for the same constraint.) This file uses `requires "../swapvm.md"` — resolving
relative to its own directory — so it kompiles correctly when invoked as
`kompile ... lemmas.k` from `semantics/` without an `-I` flag.

## Fidelity gaps (declared per `PLAN.md` D3, D5)

- **Non-canonical args unmodelled.** Solidity right-pads short `args` and truncates long ones
  without reverting; the model reverts with `"UNMODELLED-ARGS-LENGTH"` for any `args.length`
  other than 2. This makes the gap loud rather than silent (swapvm.md:314-316), in the same safe
  direction chosen for opcodes 0x23 and 0x90. Recorded here so it is not mistaken for an
  oversight.
- **`ADMITTED`.** Per the trust model in `PLAN.md` §5a, every instruction rule starts `ADMITTED`.
  This one is not yet exercised by the conformance harness.
- **No `Reverted` arm for the canonical case.** Jump never reverts on its own — the Solidity has
  no `require`, no `revert`, no bounds check of its own. (A Jump landing past the end of the
  program is handled by the loop-exit rule `swapvm.md:100-105`, not by this rule.) A false
  `Reverted` arm is the subject of `proofs/jump-control.k`, which is supposed to fail.

## Composition

Jump is **unlike** the gate (`proofs/gate-spec.k`), Stop (`proofs/stop-spec.k`), and Revert
(`proofs/revert-spec.k`) theorems, and **like** Salt (`proofs/salt-spec.k`) in one decisive
respect: those instructions HALT (the gate reverts and clears the continuation; Stop sets a
sentinel pc; Revert clears the continuation). Jump does not halt — it leaves `#run` in `<k>`, so
the loop proceeds to decode the byte at the *jumped-to* `<pc>`. An arbitrary symbolic tail
`b"\x03\x02" +Bytes TARGET +Bytes TAIL` therefore cannot be the basis of a clean terminating
claim: after Jump fires, the loop tries to decode `TAIL[0]` (wherever the jump landed), and with
a symbolic target the prover cannot determine where execution lands.

The honest shape of a positive claim is to constrain `TGT` concretely in `[0, 65535]` and
*not* include an arbitrary tail that needs decoding — instead let the program terminate at the
jumped-to `<pc>` because the program is exactly `b"\x03\x02" +Bytes Int2Bytes(2, TGT, BE)` (so
the loop-exit rule fires when `<pc>` equals `TGT >= lengthBytes(PGM)`). The positive spec
`proofs/jump-spec.k` states that. The negative control `proofs/jump-control.k` asserts the
wrong post-jump `<pc>` (the post-decode value, not the jumped-to value) and must fail — the
sensitivity twin of `jump-spec.k`.
