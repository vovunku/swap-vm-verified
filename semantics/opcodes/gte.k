requires "../swapvm.md"

// 0x24 OnlyTakerTokenBalanceGte — Controls.sol:158-166.
//
// Adds the Gte rule to the SWAPVM semantics. K v7 does not allow reopening `module SWAPVM`
// across files (it reports "Module SWAPVM differs from previous previous declaration"), so this
// file defines a sibling module SWAPVM-GTE that imports SWAPVM and adds the rules. Integration is
// via `requires "opcodes/gte.k"` plus `imports SWAPVM-GTE` from the main module
// (semantics/lemmas.k) — see gte.md "Integration".
//
// The decode rule in swapvm.md has already consumed the [opcode:1][argsLen:1] header and advanced
// <pc> by `2 + argsLen` before #exec fires, exactly mirroring `pcs := add(pcs, 2); ... pcs :=
// add(pcs, argsLength)` in VM.sol:133-138. Gte neither reads nor writes <pc> beyond that (no
// `setNextPC` call), so both arms of this rule inherit the already-advanced value and leave it
// — the same posture as Revert (opcodes/revert.k), Salt (opcodes/salt.k), and Deadline
// (opcodes/deadline.k). The opcode is a pure conditional halt: it either reverts (clearing <k>)
// or is a no-op pass-through (leaves #run in <k>).
//
// RELATIONSHIP TO 0x23. The gate at swapvm.md:177-194 (OnlyTakerTokenBalanceNonZero,
// Controls.sol:140-144) reverts iff `balance == 0` and is the special case of this opcode with
// `minAmount == 1` (since balances are non-negative, `balance < 1 <=> balance == 0`). Gte is the
// generalization: it reverts iff `balance < minAmount`, for an arbitrary on-chain `minAmount`
// the maker bakes into the program. The two opcodes are otherwise identical in shape — both
// read the taker's balance of a 20-byte token via `#balanceOf` (swapvm.md:171-174) and either
// revert or pass through — except that Gte reads an additional 32-byte `minAmount` after the
// 20-byte token. Args layout is `[token:20][minAmount:32]`, total 52 bytes.
//
// DIRECT TWO-ARM FORM. The arms branch on the direct comparison
//   #balanceOf(B, TOK, TAKER) <Int MIN     (REVERT)
//   #balanceOf(B, TOK, TAKER) >=Int MIN    (PASS)
// mirroring the gate's `>Int 0` / `<=Int 0` shape but compared to MIN rather than the constant
// 0. An earlier revision of this file abstracted the comparison into a Bool predicate
// `#balanceLtMin(TOK, MIN)` in order to make a SYMBOLIC universal claim (gte-spec.k) prove: the
// K Haskell backend does not propagate an inequality premise on an uninterpreted-vs-symbolic
// comparison into a refutation of the opposite arm (opcodes/deadline.md:125-156), so the direct
// form stalled the all-path symbolic claim. That trade is now judged WRONG: the predicate made
// the symbolic claim TAUTOLOGICAL (it assumed `#balanceLtMin(TOK, MIN)` as a premise, then the
// rule with the same predicate fired), so the proof established nothing about the actual
// `<` / `>=` definition, and krun could not reduce the predicate either — i.e. NO conformance
// evidence at all. The direct form restores real meaning to the comparison; CONCRETE claims
// (proofs/gte-concrete.k) verify it for fixed inputs, where both sides of the inequality are
// concrete Ints and the SMT solver decides `<Int` / `>=Int` directly — no arm-selection issue.
// The symbolic universal claim no longer proves; that is accepted. See gte.md "Direct form,
// concrete conformance" for the full rationale.
//
// ARG DECODING. The Solidity source reads:
//     address token    = address(bytes20(args));
//     uint256 minAmount = uint256(bytes32(args.slice(20)));
// `address(bytes20(args))` right-zero-pads a short args and truncates a long one to 20 bytes;
// `bytes32(args.slice(20))` does the same at offset 20 to 32 bytes. Under the canonical
// `lengthBytes(ARGS) ==Int 52` side condition the model uses
//   - `Bytes2Int(substrBytes(ARGS,  0, 20), BE, Unsigned)` for the token, exactly the 20-byte
//     big-endian read;
//   - `Bytes2Int(substrBytes(ARGS, 20, 52), BE, Unsigned)` for minAmount, exactly the 32-byte
//     big-endian read at offset 20.
// The round-trip lemma in lemmas.k:64-67 rewrites each `Bytes2Int(Int2Bytes(...))` to the
// symbolic Int a spec supplies, under the standard width bounds (`0 <=Int TOK <Int 2^160`,
// `0 <=Int MIN <Int 2^256`).
//
// PAD-AND-TRUNCATE SOUNDNESS HAZARD (swapvm.md:301-324). The Solidity constrains nothing about
// `args.length`. A short `args` is right-zero-padded at BOTH read sites (so e.g. an argsLen of
// 10 reads a 20-byte token whose last 10 bytes are zero, then a 32-byte minAmount that is all
// zero); a long `args` is silently truncated (so e.g. an argsLen of 100 reads only the first
// 20 bytes as the token and bytes [20:52] as minAmount). Neither case reverts on chain. If the
// model only handled the canonical 52-byte case and let the rest fall through to the `[owise]`
// no-op (swapvm.md:349-351), every such Gte would be SILENTLY DELETED from the model while
// staying live in production — the worst failure direction, sound but wrong. The mitigation
// follows the pattern at swapvm.md:319-324 for opcodes 0x23 and 0x90 and the twins in
// opcodes/jump.k:50-54 and opcodes/deadline.k:121-126: non-canonical lengths revert loudly
// with `"UNMODELLED-ARGS-LENGTH"`, so a proof touching such a Gte fails rather than succeeds
// on a fiction.

module SWAPVM-GTE
  imports SWAPVM

  // Canonical 52-byte Gte, REVERT arm. Solidity:
  //   require(balance >= minAmount, TakerTokenBalanceIsLessThanRequired(...));
  // reverts iff `balance < minAmount`. `#revert(MSG) ~> _ => .K` (swapvm.md:154-156) clears the
  // continuation and sets <status> Reverted(MSG), so the loop never resumes and an arbitrary
  // symbolic tail in the program cannot affect the conclusion. The `Running` side condition
  // guards against Gte firing after a prior Revert, matching the loop rule's own guard
  // (swapvm.md:103) and the analogous guards on Stop, Revert, Jump, Salt, and Deadline. The
  // [owise] unknown-opcode rule (swapvm.md:349-351) is overridden by this more specific rule
  // regardless of which module each lives in: owise rules have lower priority than concrete
  // rules across the whole imported closure.
  rule <k> #exec ( 36 , ARGS ) => #revert("TakerTokenBalanceIsLessThanRequired") ... </k>
       <query> ... <taker> TAKER </taker> ... </query>
       <balances> B </balances>
       <status> Running </status>
    requires lengthBytes(ARGS) ==Int 52
     andBool #balanceOf(B, Bytes2Int(substrBytes(ARGS, 0, 20), BE, Unsigned), TAKER)
             <Int Bytes2Int(substrBytes(ARGS, 20, 52), BE, Unsigned)

  // Canonical 52-byte Gte, PASS arm. `balance >= minAmount`: the require holds, and
  // `_onlyTakerTokenBalanceGte` returns normally. The opcode is a no-op at the register level
  // — reads no register, writes no register, no `setNextPC` — so the continuation #run is left
  // in <k> and the loop proceeds to decode the next instruction. Like Salt (opcodes/salt.k) and
  // Deadline (opcodes/deadline.k), Gte is NOT a halt on this arm: an arbitrary symbolic tail in
  // the program WILL be decoded after Gte passes. The composition shape for positive claims
  // therefore mirrors gate-spec.k / deadline-spec.k on the REVERT arm (HALT, tail unconsumed)
  // and would mirror salt-spec.k / jump-spec.k on the PASS arm (no halt, must terminate
  // concretely); concrete claims for both arms live in proofs/gte-concrete.k.
  rule <k> #exec ( 36 , ARGS ) => .K ... </k>
       <query> ... <taker> TAKER </taker> ... </query>
       <balances> B </balances>
       <status> Running </status>
    requires lengthBytes(ARGS) ==Int 52
     andBool #balanceOf(B, Bytes2Int(substrBytes(ARGS, 0, 20), BE, Unsigned), TAKER)
             >=Int Bytes2Int(substrBytes(ARGS, 20, 52), BE, Unsigned)

  // Non-canonical args: Solidity right-pads short and truncates long without reverting, which is
  // a soundness hazard (swapvm.md:301-324). Revert loudly here so a proof cannot silently
  // succeed on an unmodelled length. Mirrors opcodes 0x23 / 0x90 in swapvm.md:319-324 and the
  // twins in opcodes/jump.k:50-54 and opcodes/deadline.k:121-126.
  rule <k> #exec ( 36 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
       <status> Running </status>
    requires lengthBytes(ARGS) =/=Int 52
endmodule
