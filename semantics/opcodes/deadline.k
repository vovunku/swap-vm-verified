requires "../swapvm.md"

// 0x20 Deadline — Controls.sol:129-134.
//
// Adds the Deadline rule to the SWAPVM semantics. K v7 does not allow reopening `module SWAPVM`
// across files (it reports "Module SWAPVM differs from previous declaration"), so this file
// defines a sibling module SWAPVM-DEADLINE that imports SWAPVM and adds the rules. Integration
// is via `requires "opcodes/deadline.k"` plus `imports SWAPVM-DEADLINE` from the main module
// (semantics/lemmas.k) — see deadline.md "Integration".
//
// The decode rule in swapvm.md has already consumed the [opcode:1][argsLen:1] header and advanced
// <pc> by `2 + argsLen` before #exec fires, exactly mirroring `pcs := add(pcs, 2); ... pcs :=
// add(pcs, argsLength)` in VM.sol:133-138. Deadline neither reads nor writes <pc> beyond that
// (no `setNextPC` call), so both arms of this rule inherit the already-advanced value and leave
// it — the same posture as Revert (opcodes/revert.k) and Salt (opcodes/salt.k). The opcode is a
// pure conditional halt: it either reverts (clearing <k>) or is a no-op pass-through (leaves #run
// in <k>).
//
// The Solidity reads `uint40(bytes5(args))`, i.e. the first 5 bytes of `args` as a big-endian
// uint40. The model reads `Bytes2Int(substrBytes(ARGS, 0, 5), BE, Unsigned)` — the explicit substr
// mirrors Solidity's 5-byte read and is the form used in the rule below. (Under the rule's
// `lengthBytes(ARGS) ==Int 5` side condition this is equivalent to reading the whole ARGS; the
// substr form is preferred here so the rule text matches the Solidity `bytes5(args)` read exactly.)
//
// PAD-AND-TRUNCATE SOUNDNESS HAZARD (swapvm.md:301-324). The Solidity constrains nothing: a
// short `args` is right-zero-padded, and a long `args` is silently truncated to the first 5 bytes.
// There is NO revert for a wrong length. Modelling only the canonical-length case and letting
// the others fall through to the `[owise]` no-op (swapvm.md:349-351) would SILENTLY DELETE the
// deadline gate from the model — the worst failure direction, sound but wrong. The mitigation
// follows the pattern at swapvm.md:319-324 for opcodes 0x23 and 0x90 and the twin at
// opcodes/jump.k:50-54: non-canonical lengths revert loudly with `"UNMODELLED-ARGS-LENGTH"`, so
// a proof touching such a Deadline fails rather than succeeds on a fiction.
//
// block.timestamp is an EXTERNAL ENVIRONMENT input — no on-chain state for the VM to consult.
// Per PLAN.md D4 it is abstracted out of the K configuration. ONE uninterpreted symbol is
// declared below:
//
//   - `#blockTimestamp()` — the D4 abstraction of the chain's `block.timestamp`, per the task
//     brief. A nullary total function `[function, no-evaluators]`; its value is fixed-but-
//     unknown, constrained only by spec premises. This is the symbol a spec uses to reason about
//     the timestamp directly (e.g. `requires #blockTimestamp() ==Int 100`).
//
// DIRECT COMPARISON FORM. The rule branches on `#blockTimestamp() >Int DL` vs
// `#blockTimestamp() <=Int DL` DIRECTLY — no Bool predicate intermediary. This is the change
// from the earlier `#deadlineExceeded(DL)` form (see deadline.md "Direct form, concrete
// conformance" for the rationale). The earlier predicate form was adopted because a SYMBOLIC
// universal claim did not prove against a direct-comparison rule whose arms compared an
// uninterpreted function to a SYMBOLIC value — but the proof it enabled was TAUTOLOGICAL: the
// spec assumed `#deadlineExceeded(DL)` as a premise and the rule branched on the same predicate,
// so the proof established nothing about whether the underlying `>` / `<=` matched Solidity.
// Worse, krun could not reduce the predicate, so there was NO conformance evidence at all —
// symbolic universality bought at the cost of zero real verification.
//
// The direct form regains real verification at the cost of symbolic universality. A symbolic
// universal claim over arbitrary DL does NOT prove in this form (same arm-selection limitation
// that sank the earlier direct-form attempt: the K Haskell backend does not propagate an
// inequality premise on an uninterpreted-vs-symbolic comparison into a refutation of the
// opposite arm). CONCRETE claims, however, prove cleanly: with both `#blockTimestamp()` (fixed
// by a premise) and DL concrete Ints, the SMT solver decides `>Int` / `<=Int` directly and arm
// selection is immediate. So the concrete claims in `proofs/deadline-concrete.k` ARE the
// conformance evidence — they verify the actual comparison against Solidity for fixed inputs,
// which the predicate-form symbolic proof could never do.
//
// `#blockTimestamp()` honours the D4 boundary: no defining rule, not a cell. Its value is fixed
// by a premise in each concrete claim (e.g. `requires #blockTimestamp() ==Int 100`). Adding a
// `<timestamp>` cell to swapvm.md was explicitly out of scope (six sibling subagents depend on
// swapvm.md being untouched); this local declaration achieves the abstraction without that
// coordination cost.

module SWAPVM-DEADLINE
  imports SWAPVM

  // The current block timestamp, as an uninterpreted total function. This is the PLAN.md D4
  // abstraction boundary for the chain's `block.timestamp` environment input, per the task
  // brief. No defining rule: its value is fixed-but-unknown, constrained only by spec premises.
  // `[function, no-evaluators]` marks it as a total function symbol and prevents the simplifier
  // from inventing a reduction. The rule below branches on `#blockTimestamp() >Int DL` DIRECTLY
  // (see file header); concrete claims fix `#blockTimestamp()` via a premise and prove cleanly.
  syntax Int ::= #blockTimestamp () [function, no-evaluators]

  // Canonical 5-byte Deadline, REVERT arm. Solidity:
  //   require(block.timestamp <= deadline, DeadlineReached(ctx.query.taker, deadline));
  // reverts iff `block.timestamp > deadline`, i.e. iff the deadline has been exceeded.
  // `#revert(MSG) ~> _ => .K` (swapvm.md:154-156) clears the continuation and sets <status>
  // Reverted(MSG), so the loop never resumes and an arbitrary symbolic tail in the program
  // cannot affect the conclusion. The `Running` side condition guards against Deadline firing
  // after a prior Revert, matching the loop rule's own guard (swapvm.md:103) and the analogous
  // guards on Stop, Revert, Jump, and Salt. The [owise] unknown-opcode rule (swapvm.md:349-351)
  // is overridden by this more specific rule regardless of which module each lives in: owise
  // rules have lower priority than concrete rules across the whole imported closure.
  rule <k> #exec ( 32 , ARGS ) => #revert("DeadlineReached") ... </k>
       <status> Running </status>
    requires lengthBytes(ARGS) ==Int 5
     andBool #blockTimestamp() >Int Bytes2Int(substrBytes(ARGS, 0, 5), BE, Unsigned)

  // Canonical 5-byte Deadline, PASS arm. `block.timestamp <= deadline`: the deadline has NOT
  // been exceeded, the require holds, and `_deadline` returns normally. The opcode is a no-op at
  // the register level — reads no register, writes no register, no `setNextPC` — so the
  // continuation #run is left in <k> and the loop proceeds to decode the next instruction. Like
  // Salt (opcodes/salt.k), Deadline is NOT a halt on this arm: an arbitrary symbolic tail in the
  // program WILL be decoded after Deadline passes. The composition shape for concrete claims
  // terminates via the loop-exit rule (swapvm.md:100-105) when `<pc> = 7 >= lengthBytes(PGM)`.
  rule <k> #exec ( 32 , ARGS ) => .K ... </k>
       <status> Running </status>
    requires lengthBytes(ARGS) ==Int 5
     andBool #blockTimestamp() <=Int Bytes2Int(substrBytes(ARGS, 0, 5), BE, Unsigned)

  // Non-canonical args: Solidity right-pads short and truncates long without reverting, which is
  // a soundness hazard (swapvm.md:301-324). Revert loudly here so a proof cannot silently
  // succeed on an unmodelled length. Mirrors opcodes 0x23 / 0x90 in swapvm.md:319-324 and the
  // twin in opcodes/jump.k:50-54.
  rule <k> #exec ( 32 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
    requires lengthBytes(ARGS) =/=Int 5
endmodule
