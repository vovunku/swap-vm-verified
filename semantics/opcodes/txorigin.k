requires "../swapvm.md"

// 0x26 OnlyTxOriginTokenBalanceNonZero — Controls.sol:146-156.
//
// Adds the rule to the SWAPVM semantics. K v7 does not allow reopening `module SWAPVM`
// across files (it reports "Module SWAPVM differs from previous declaration"), so this
// file defines a sibling module SWAPVM-TXORIGIN that imports SWAPVM and adds the rules.
// Integration is via `requires "opcodes/txorigin.k"` plus `imports SWAPVM-TXORIGIN` from
// the main module (semantics/lemmas.k) — see txorigin.md "Integration".
//
// RELATIONSHIP TO 0x23 (OnlyTakerTokenBalanceNonZero). This opcode is the tx.origin TWIN
// of 0x23 (swapvm.md:177-194, Controls.sol:140-144). The two are byte-for-byte identical
// at every structural point: same 20-byte args layout (`address(bytes20(args))`), same
// ERC-20 read (`IERC20(token).balanceOf(HOLDER)`), same `require(balance > 0, ...)`. The
// ONLY difference is the HOLDER passed to balanceOf: 0x23 uses `ctx.query.taker`
// (ctx-relative), 0x26 uses `tx.origin` (environment-relative). Every other modelling
// decision — the canonical-length side condition, the `>Int 0` / `<=Int 0` split, the
// UNMODELLED-ARGS-LENGTH arm, the absence of a `<status> Running` guard — is inherited
// verbatim from the 0x23 rule. This is the direct template cited in the brief.
//
// The decode rule in swapvm.md (143-149) has already consumed the [opcode:1][argsLen:1]
// header and advanced <pc> by `2 + argsLen` BEFORE #exec fires, exactly mirroring
// `pcs := add(pcs, 2); ... pcs := add(pcs, argsLength)` in VM.sol:133-138. This opcode
// neither reads nor writes <pc> beyond that (no `setNextPC` call), so the rules inherit
// the already-advanced value and leave it — the same posture as the 0x23 gate, Revert
// (opcodes/revert.k), Salt (opcodes/salt.k), Deadline (opcodes/deadline.k), and Gte
// (opcodes/gte.k). The opcode is a pure conditional halt: it either reverts (clearing
// <k>) or is a no-op pass-through (leaves #run in <k>).
//
// EXTERNAL STATE — tx.origin. `tx.origin` is an EVM environment value the current K
// config has no cell for (the `<query>` cell carries `taker`, `recipient`, etc., but not
// the originating EOA). Per PLAN.md D4 it lives at the abstraction boundary, so this file
// declares it as a local uninterpreted function
//     syntax Int ::= #txOrigin () [function, no-evaluators]
// (see below). No defining rule: its value is fixed-but-unknown per execution,
// constrained only by spec premises. This is the same modelling posture Deadline takes
// for `block.timestamp` (`#blockTimestamp()`, opcodes/deadline.k) and SupplyShare takes
// for `totalSupply` (`#totalSupply(Int)`, opcodes/supplyshare.k). The brief forbids
// editing swapvm.md — five sibling subagents depend on it being untouched — so the symbol
// is declared locally in SWAPVM-TXORIGIN rather than added to a new cell.
//
// The opcode then reuses the existing `#balanceOf` machinery (swapvm.md:171-174) by
// calling `#balanceOf(B, TOKEN, #txOrigin())` — the same call 0x23 makes with TAKER in
// place of #txOrigin(). No new balance-lookup symbol is needed.
//
// ARM SELECTION — why the direct two-arm form works here, no Bool predicate needed.
// Unlike Deadline (`#blockTimestamp() >Int DL`), Gte (`#balanceOf(...) <Int MIN`), and
// SupplyShare (the `totalSupply > 0 && balance * 1e18 >= ... * totalSupply` conjunction),
// this opcode compares `#balanceOf(...)` to a CONSTANT (0), not to a symbolic value.
// The K Haskell backend CAN branch on `#balanceOf(...) >Int 0` vs `<=Int 0` because
// constant reasoning IS propagated into arm refutation — this is the same fact that makes
// the 0x23 gate (swapvm.md:182-193) prove in the direct form. The Deadline/Gte/SupplyShare
// arm-selection limitation ONLY affects inequalities against SYMBOLIC values. The brief's
// "CRITICAL" note directs mirroring 0x23 exactly rather than introducing a predicate;
// this file honours that. A spec premise `#balanceOf(BALS, TOK, #txOrigin()) ==Int 0`
// selects the REVERT arm exactly as `#balanceOf(...) ==Int 0` selects the 0x23 REVERT arm.
//
// PAD-AND-TRUNCATE SOUNDNESS HAZARD (swapvm.md:301-324). The Solidity constrains nothing
// about `args.length`: `address(bytes20(args))` right-zero-pads a short args and truncates
// a long one to 20 bytes, with no revert. If the model only handled the canonical 20-byte
// case and let the rest fall through to the `[owise]` no-op (swapvm.md:349-351), every
// such instance would be SILENTLY DELETED from the model while staying live in production
// — the worst failure direction (sound but wrong). The third rule reverts loudly with
// `"UNMODELLED-ARGS-LENGTH"` so a proof touching such an instruction fails rather than
// succeeds on a fiction. Same pattern as opcodes 0x23 / 0x90 in swapvm.md:319-324 and the
// twins in opcodes/jump.k:50-54, opcodes/deadline.k:121-126, opcodes/gte.k:142-148, and
// opcodes/supplyshare.k:184-191.

module SWAPVM-TXORIGIN
  imports SWAPVM

  // The transaction's originating EOA, as an uninterpreted nullary function. This is the
  // PLAN.md D4 abstraction boundary for the EVM `tx.origin` value read in
  // Controls.sol:154 (`IERC20(token).balanceOf(tx.origin)`). No defining rule: its value
  // is fixed-but-unknown per execution, constrained only by spec premises.
  // `[function, no-evaluators]` marks it as a total function symbol and prevents the
  // simplifier from inventing a reduction. Nullary (rather than taking the token) because
  // tx.origin is a property of the TRANSACTION, not of any particular token read. The rule
  // below consults it via the existing `#balanceOf(B, TOKEN, HOLDER)` machinery
  // (swapvm.md:171-174) — same call 0x23 makes, with #txOrigin() in place of TAKER.
  syntax Int ::= #txOrigin () [function, no-evaluators]

  // Canonical 20-byte case, PASS arm. Solidity:
  //   uint256 balance = IERC20(token).balanceOf(tx.origin);
  //   require(balance > 0, TxOriginTokenBalanceIsZero(tx.origin, token));
  // (Controls.sol:153-155). The require passes — balance strictly positive — and the
  // function returns normally. The opcode is a no-op at the register level: reads no
  // register, writes no register, no `setNextPC`. The continuation #run is left in <k>
  // and the loop proceeds to decode the next instruction. Like the 0x23 gate (and unlike
  // Salt/Deadline/Gte on their PASS arms), this opcode IS a halt on the REVERT arm but
  // NOT on this arm; a positive claim covering the REVERT arm leaves the tail unconsumed
  // (#revert discards the continuation), and a positive claim covering this arm would
  // have to terminate concretely — same composition shape as 0x23.
  //
  // Mirrors swapvm.md:182-187 (the 0x23 PASS arm) exactly, with `#txOrigin()` in place of
  // the `<taker>` cell read. Reads the whole ARGS as a 20-byte big-endian unsigned int —
  // exact under `lengthBytes(ARGS) ==Int 20`, no substrBytes needed (0x23 does the same).
  rule <k> #exec ( 38 , ARGS ) => .K ... </k>
       <balances> B </balances>
    requires lengthBytes(ARGS) ==Int 20
     andBool #balanceOf(B, Bytes2Int(ARGS, BE, Unsigned), #txOrigin()) >Int 0

  // Canonical 20-byte case, REVERT arm. Balance is zero (or, in principle, negative —
  // but #balanceOf is `[function, total]` and its defining rule returns
  // `orDefault 0`, so it is always >= 0; the `<=Int 0` arm therefore fires exactly when
  // the balance is 0). `#revert(MSG) ~> _ => .K` (swapvm.md:154-156) clears the
  // continuation and sets <status> Reverted(MSG), so the loop never resumes and an
  // arbitrary symbolic tail in the program cannot affect the conclusion.
  //
  // Mirrors swapvm.md:189-193 (the 0x23 REVERT arm) exactly, with `#txOrigin()` in place
  // of the `<taker>` cell read and `"TxOriginTokenBalanceIsZero"` (Controls.sol:155) in
  // place of `"TakerTokenBalanceIsZero"`.
  rule <k> #exec ( 38 , ARGS ) => #revert("TxOriginTokenBalanceIsZero") ... </k>
       <balances> B </balances>
    requires lengthBytes(ARGS) ==Int 20
     andBool #balanceOf(B, Bytes2Int(ARGS, BE, Unsigned), #txOrigin()) <=Int 0

  // Non-canonical args: Solidity right-pads short and truncates long without reverting,
  // which is a soundness hazard (swapvm.md:301-324). Revert loudly here so a proof cannot
  // silently succeed on an unmodelled length. Mirrors opcodes 0x23 / 0x90 in
  // swapvm.md:319-324 and the twins in opcodes/jump.k:50-54, opcodes/deadline.k:121-126,
  // opcodes/gte.k:142-148, and opcodes/supplyshare.k:184-191.
  rule <k> #exec ( 38 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
    requires lengthBytes(ARGS) =/=Int 20
endmodule
