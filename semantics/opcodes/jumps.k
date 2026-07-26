requires "../swapvm.md"

// 0x30 JumpIfDirection — Controls.sol:95-103.
//
// The conditional twin of `0x03` Jump (opcodes/jump.k). It reads a condition derived
// from <query> + ARGS, and IF IT HOLDS overwrites the decode-advanced <pc> with a uint16
// target read from ARGS — exactly as Jump does. If the condition does NOT hold, the rule is
// a no-op: it leaves the decode-advanced <pc> in place and the loop falls through to the
// next instruction (the Solidity `if (cond) { ctx.setNextPC(...) }` with no else branch).
//
// As with Jump, the decode rule in swapvm.md (143-149) has already consumed the
// [opcode:1][argsLen:1] header and advanced <pc> by `2 + argsLen` BEFORE #exec fires. A
// conditional jump that takes its branch OVERWRITES that already-advanced value
// (swapvm.md:138-140) — the K analogue of `ctx.vm.nextPC = pcs; ...; pcs = ctx.vm.nextPC` in
// VM.sol, identical to the unconditional Jump. A conditional jump that does NOT take its
// branch leaves the advanced value untouched, modelling the Solidity's missing else. The two
// rules per opcode below pin down each case.
//
// K v7 cannot reopen `module SWAPVM`, so this file defines a sibling module SWAPVM-JUMPS
// that imports SWAPVM and adds the rules. Integration is via `requires "opcodes/jumps.k"`
// plus `imports SWAPVM-JUMPS` from semantics/lemmas.k — see jumps.md "Integration".
//
// PAD-AND-TRUNCATE SOUNDNESS HAZARD (swapvm.md:301-324). The Solidity constrains nothing
// about args.length: `bytes1(args)`, `address(bytes20(args))`, and `bytes2(args.slice(...))`
// all right-zero-pad short args and truncate long ones with no revert. Modelling only the
// canonical length and letting the rest fall through to the [owise] no-op (swapvm.md:349-351)
// would SILENTLY DELETE conditional jumps from the model — a soundness hazard in the worst
// direction. Each opcode therefore has an UNMODELLED-ARGS-LENGTH arm that reverts loudly,
// mirroring the pattern at swapvm.md:319-324 for opcodes 0x23 and 0x90 and the analogous arm
// in opcodes/jump.k.

module SWAPVM-JUMPS
  imports SWAPVM

  // 0x30 JumpIfDirection — Controls.sol:95-103.
  //
  // args = 1 byte expectedDirection (0 = false, nonzero = true) + 2 bytes nextPC (uint16 BE).
  // swapDirection = tokenIn < tokenOut (Controls.sol:98). Jump iff expectedDirection == swapDirection.
  //
  // Solidity: `bool expectedDirection = bytes1(args) != 0; bool swapDirection = ctx.query.tokenIn
  // < ctx.query.tokenOut; if (expectedDirection == swapDirection) { uint256 nextPC =
  // uint16(bytes2(args.slice(1))); ctx.setNextPC(nextPC); }`.
  //
  // The condition `(ARGS [ 0 ] =/=Int 0) ==Bool (TIN <Int TOUT)` branches on `==Bool` between
  // two Bool expressions; the inner `TIN <Int TOUT` is a comparison between two <query> cell
  // variables, which the Haskell backend handles natively (per the task brief's note on
  // cell-variable comparisons). The fall-through rule uses `=/=Bool` so the two arms are
  // exhaustive and mutually exclusive for canonical-length ARGS.

  // Branch taken — overwrite <pc> with uint16 target read from ARGS[1:3].
  rule <k> #exec ( 48 , ARGS ) => .K ... </k>
       <pc> _ => Bytes2Int(substrBytes(ARGS, 1, 3), BE, Unsigned) </pc>
       <tokenIn> TIN </tokenIn> <tokenOut> TOUT </tokenOut>
       <status> Running </status>
    requires lengthBytes(ARGS) ==Int 3
     andBool (ARGS [ 0 ] =/=Int 0) ==Bool (TIN <Int TOUT)

  // Branch not taken — no-op, <pc> keeps its decode-advanced value (=> .K with no <pc> write).
  rule <k> #exec ( 48 , ARGS ) => .K ... </k>
       <tokenIn> TIN </tokenIn> <tokenOut> TOUT </tokenOut>
       <status> Running </status>
    requires lengthBytes(ARGS) ==Int 3
     andBool (ARGS [ 0 ] =/=Int 0) =/=Bool (TIN <Int TOUT)

  // Non-canonical args: Solidity pads/truncates without reverting, a soundness hazard
  // (swapvm.md:301-324). Revert loudly. Mirrors opcodes/jump.k and swapvm.md:319-324.
  rule <k> #exec ( 48 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
    requires lengthBytes(ARGS) =/=Int 3

  // 0x31 JumpIfTokenIn — Controls.sol:105-115.
  //
  // args = 20 bytes token + 2 bytes nextPC (uint16 BE).
  // Jump iff address(bytes20(args)) == ctx.query.tokenIn.
  //
  // Solidity: `address token = address(bytes20(args)); if (token == ctx.query.tokenIn)
  // { uint256 nextPC = uint16(bytes2(args.slice(20))); ctx.setNextPC(nextPC); }`.
  //
  // ARM-SELECTION NOTE. The first draft of this rule put `Bytes2Int(substrBytes(ARGS, 0, 20),
  // BE, Unsigned)` directly in the <tokenIn> cell pattern of the LHS to force unification.
  // kompile rejects that with "Illegal function symbol ... on LHS of rule": K forbids hooked
  // function symbols (substrBytes, Bytes2Int) inside cell patterns on the LHS of a semantic
  // rule. The fallback — and the form used here — is a side condition
  // `TIN ==Int Bytes2Int(substrBytes(ARGS, 0, 20), BE, Unsigned)` on the jump arm, paired with
  // `=/=Int` on the fall-through arm. Logically equivalent; the Haskell backend discharge is on
  // the side condition rather than on pattern unification. (An alternative would be a Bool
  // predicate `#jumpIfTokenInHolds(ARGS, TIN)`, but the direct side condition kompiles and
  // proves, so the predicate indirection is unnecessary.)

  // Branch taken — token prefix of ARGS equals tokenIn; overwrite <pc>.
  rule <k> #exec ( 49 , ARGS ) => .K ... </k>
       <pc> _ => Bytes2Int(substrBytes(ARGS, 20, 22), BE, Unsigned) </pc>
       <tokenIn> TIN </tokenIn>
       <status> Running </status>
    requires lengthBytes(ARGS) ==Int 22
     andBool TIN ==Int Bytes2Int(substrBytes(ARGS, 0, 20), BE, Unsigned)

  // Branch not taken — no-op, <pc> keeps its decode-advanced value.
  rule <k> #exec ( 49 , ARGS ) => .K ... </k>
       <tokenIn> TIN </tokenIn>
       <status> Running </status>
    requires lengthBytes(ARGS) ==Int 22
     andBool TIN =/=Int Bytes2Int(substrBytes(ARGS, 0, 20), BE, Unsigned)

  // Non-canonical args — revert loudly.
  rule <k> #exec ( 49 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
    requires lengthBytes(ARGS) =/=Int 22

  // 0x32 JumpIfTokenOut — Controls.sol:117-127.
  //
  // args = 20 bytes token + 2 bytes nextPC (uint16 BE).
  // Jump iff address(bytes20(args)) == ctx.query.tokenOut.
  //
  // Solidity: `address token = address(bytes20(args)); if (token == ctx.query.tokenOut)
  // { uint256 nextPC = uint16(bytes2(args.slice(20))); ctx.setNextPC(nextPC); }`.
  //
  // Structurally identical to 0x31 above, reading <tokenOut> instead of <tokenIn>. Same
  // arm-selection note applies: the jump arm uses a `TOUT ==Int ...` side condition (the LHS
  // cell-pattern form was rejected by kompile for hooked-function-in-LHS, same as 0x31).

  // Branch taken — token prefix of ARGS equals tokenOut; overwrite <pc>.
  rule <k> #exec ( 50 , ARGS ) => .K ... </k>
       <pc> _ => Bytes2Int(substrBytes(ARGS, 20, 22), BE, Unsigned) </pc>
       <tokenOut> TOUT </tokenOut>
       <status> Running </status>
    requires lengthBytes(ARGS) ==Int 22
     andBool TOUT ==Int Bytes2Int(substrBytes(ARGS, 0, 20), BE, Unsigned)

  // Branch not taken — no-op, <pc> keeps its decode-advanced value.
  rule <k> #exec ( 50 , ARGS ) => .K ... </k>
       <tokenOut> TOUT </tokenOut>
       <status> Running </status>
    requires lengthBytes(ARGS) ==Int 22
     andBool TOUT =/=Int Bytes2Int(substrBytes(ARGS, 0, 20), BE, Unsigned)

  // Non-canonical args — revert loudly.
  rule <k> #exec ( 50 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
    requires lengthBytes(ARGS) =/=Int 22
endmodule
