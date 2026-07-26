requires "../swapvm.md"

// 0x2c WhitelistCoequal — Whitelist.sol:112-129.
//
// Adds the WhitelistCoequal rule to the SWAPVM semantics. K v7 does not allow
// reopening `module SWAPVM` across files (it reports "Module SWAPVM differs from previous
// declaration"), so this file defines a sibling module SWAPVM-WHITELISTS that imports SWAPVM
// and adds the rule. Integration is via `requires "opcodes/whitelists.k"` plus
// `imports SWAPVM-WHITELISTS` from the main module (semantics/lemmas.k) — see
// whitelists.md "Integration".
//
// WHAT THE OPCODE DOES. A conditional jump over a variable-length list of packed addresses.
//   uint80 sender = wrapToPackedAddress(ctx.query.taker);   // uint80(uint160(taker))
//   bytes calldata list = args.slice(2);                    // 10-byte packed entries
//   for (i = list.length / 10; i-- > 0; )
//     if (sender == list.parseWhitelistCoequalIx(i)) { ctx.vm.nextPC = pc; return; }
//   // (else fall through, no revert)
// Outcomes: JUMP (taker in list) or FALL THROUGH (not in list). Never reverts.
//
// THE LOOP IS INTRACTABLE TO MODEL LITERALLY (the load-bearing decision for this file).
//
// The opcode's main control flow is a `while (i-- > 0)` loop over a variable-length byte
// array, parsing packed 10-byte entries. The Solidity length `list.length / 10` is itself
// SYMBOLIC once `ARGS` is symbolic — the K prover would have to unfold the loop an unknown
// number of times against a list of unknown length and unknown contents, which the Haskell
// backend cannot reduce to a closed form. The same intractability affected Extruction
// (opcodes/extruction.k), where the unmodellable surface was an arbitrary external call;
// here the unmodellable surface is the byte-level list parse. Per PLAN.md D4
// (cross-referenced in opcodes/extruction.md "The abstraction boundary (PLAN.md D4)"), the
// honest direction is to abstract the OUTCOME of the loop as a Bool predicate and prove
// STRUCTURAL properties about it (which arm fires given which predicate holds), rather than
// pretending to model the iteration.
//
// The chosen predicate abstraction:
//
//   - `#coequalWhitelistContains(ARGS, PACKED)` — conceptually the result of the 0x2c loop,
//     i.e. PACKED matches some 10-byte entry in ARGS[2:]. The byte-level list parsing is
//     NOT modelled.
//
// WHY A Bool predicate, not direct inequality — the arm-selection limitation.
//
// The K Haskell backend's SMT encoding does NOT propagate an inequality premise on an
// uninterpreted-vs-symbolic comparison into a refutation of the opposite arm of a multi-arm
// rule. This was established empirically by the Deadline subagent (opcodes/deadline.md:125-156)
// and re-confirmed by Gte (opcodes/gte.md "Arm selection") and SupplyShare
// (opcodes/supplyshare.md "Arm selection"). The fix — the SAME fix Deadline, Gte, and
// SupplyShare adopted — is to abstract the branch condition itself into a free Bool predicate
// and split on THAT. A spec premise `#coequalWhitelistContains(...)` (implicitly `==Bool true`)
// selects the JUMP arm; `notBool #coequalWhitelistContains(...)` selects the FALL-THROUGH arm.
// The predicate is kept as an independent uninterpreted symbol (no simplification rule
// defining it in terms of the bytes) so the arm-selection condition stays a single atomic
// Bool the SMT solver can decide on.
//
// THE 80-BIT PACKING — FIDELITY POINT (Whitelist.sol:88-95, 81-85). The opcode computes
// `sender = uint80(uint160(ctx.query.taker))` — the taker's address TRUNCATED TO ITS LOW 80
// BITS. The K model FAITHFULLY preserves this via `TAKER modInt (2 ^Int 80)`, the same shape
// used by the 0x2b twin (opcodes/privateorder.k:92-95). Two addresses sharing their low 10
// bytes are INDISTINGUISHABLE to this opcode; this is a deliberate collision-resistance
// trade-off documented in Whitelist.sol:88-95 and preserved by the model, not a gap to close.
// The packed taker is passed to the whitelist predicate as `TAKER modInt (2 ^Int 80)`.
//
// <pc> OVERWRITE vs INHERIT. The JUMP arm overwrites `<pc>` with the uint16 read from
// ARGS[0:2] (mirroring `ctx.vm.nextPC = pc; pcs = ctx.vm.nextPC` — swapvm.md:138-140),
// exactly like Jump (opcodes/jump.k). The FALL-THROUGH arm inherits the decode-advanced
// `<pc>` and leaves it — the same posture as Salt, Deadline, Gte, and the 0x2b PASS arm.
//
// PAD-AND-TRUNCATE SOUNDNESS HAZARD (swapvm.md:301-324). The Solidity constrains nothing
// about `args.length`: `args.slice(2)` silently produces whatever the bytes happen to be,
// and the integer division `list.length / 10` silently ignores a trailing partial entry.
// A SHORT args reads a DIFFERENT list than the maker encoded (right-zero-padded by Solidity's
// calldata semantics), and an OFF-PITCH args (e.g. 13 bytes, which `length / 10` truncates
// to one 10-byte entry plus 3 ignored bytes) reads a list whose trailing partial is silently
// dropped. Neither case reverts on chain. If the model only handled the canonical-pitch case
// and let the rest fall through to the `[owise]` no-op (swapvm.md:349-351), every such
// Whitelist would be SILENTLY DELETED from the model while staying live in production — the
// worst failure direction (sound but wrong).
//
// The structural length constraint below — `lengthBytes(ARGS) >=Int 2 andBool
// (lengthBytes(ARGS) -Int 2) modInt 10 ==Int 0` — admits exactly the args lengths whose
// payload is a whole number of packed entries after the fixed 2-byte header. Anything else
// reverts loudly with `"UNMODELLED-ARGS-LENGTH"`, mirroring opcodes 0x23 / 0x90 in
// swapvm.md:319-324 and the twins throughout the sibling opcode files.
//
// NOTE on the `>=Int` lower bound vs `==Int`. The header is 2 bytes (pc) and the payload is
// `N * 10` bytes; a 0-byte payload (N = 0) is LEGAL on chain — it makes the whitelist
// always-empty and the loop never matches, so the opcode FALLS THROUGH. The model admits
// this: `lengthBytes(ARGS) >=Int 2` admits the 2-byte empty case. An `==Int` constraint
// would WRONGLY exclude the empty list, which is a real on-chain configuration. The `>=`
// lower bound plus the `modInt` pitch constraint are the faithful shape.

module SWAPVM-WHITELISTS
  imports SWAPVM

  // True iff (TAKER modInt 2^80) matches some packed entry in ARGS[2:]. The result of the
  // 0x2c while loop, abstracted. The byte-level list parsing (`args.slice(2)`,
  // `list.parseWhitelistCoequalIx(i)`, the `i--` iteration) is NOT modelled; this predicate
  // encapsulates its outcome. A spec premise `#coequalWhitelistContains(ARGS, TAKER modInt 2^80)`
  // selects the JUMP arm; its negation selects the FALL-THROUGH arm.
  syntax Bool ::= #coequalWhitelistContains ( Bytes , Int ) [function, no-evaluators]

  // ------------------------------------------------------------
  // 0x2c WhitelistCoequal — args = 2 bytes pc + N*10 bytes packed addresses.
  // ------------------------------------------------------------

  // Canonical-pitch args, JUMP arm. The taker's low 80 bits are in the list: the loop
  // matches, `ctx.vm.nextPC = args.parseWhitelistCoequalPC()` (= uint16 of ARGS[0:2]), and
  // the function returns. The decode-advanced <pc> is OVERWRITTEN, mirroring Jump
  // (opcodes/jump.k). The `Running` side condition guards against firing after a prior
  // Revert, matching the loop rule's own guard (swapvm.md:103) and the analogous guard on
  // every other opcode rule.
  rule <k> #exec ( 44 , ARGS ) => .K ... </k>
       <pc> _ => Bytes2Int(substrBytes(ARGS, 0, 2), BE, Unsigned) </pc>
       <query> ... <taker> TAKER </taker> ... </query>
       <status> Running </status>
    requires lengthBytes(ARGS) >=Int 2
     andBool (lengthBytes(ARGS) -Int 2) modInt 10 ==Int 0
     andBool #coequalWhitelistContains(ARGS, TAKER modInt (2 ^Int 80))

  // Canonical-pitch args, FALL-THROUGH arm. The taker's low 80 bits are NOT in the list:
  // the loop exits without matching, the function returns normally, and execution continues
  // at the decode-advanced <pc>. The opcode is a no-op at the register level on this arm —
  // reads only <taker>, writes no register, no `setNextPC`. Like Salt, Deadline, Gte, and
  // 0x2b on their PASS arms, this opcode is NOT a halt here: an arbitrary symbolic tail in
  // the program WILL be decoded after the Whitelist falls through.
  rule <k> #exec ( 44 , ARGS ) => .K ... </k>
       <query> ... <taker> TAKER </taker> ... </query>
       <status> Running </status>
    requires lengthBytes(ARGS) >=Int 2
     andBool (lengthBytes(ARGS) -Int 2) modInt 10 ==Int 0
     andBool notBool #coequalWhitelistContains(ARGS, TAKER modInt (2 ^Int 80))

  // Non-canonical args: Solidity silently reads a different list than the maker encoded
  // (right-pad on short args; ignored trailing partial on off-pitch args) without reverting,
  // which is the same pad-and-truncate soundness hazard documented at swapvm.md:301-324.
  // Revert loudly here so a proof cannot silently succeed on an unmodelled length. Mirrors
  // opcodes 0x23 / 0x90 in swapvm.md:319-324 and the twins throughout the sibling opcode
  // files.
  rule <k> #exec ( 44 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
       <status> Running </status>
    requires lengthBytes(ARGS) <Int 2 orBool (lengthBytes(ARGS) -Int 2) modInt 10 =/=Int 0

endmodule
