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
// uint40. The model reads `Bytes2Int(ARGS, BE, Unsigned)` — the WHOLE ARGS, not a substr. Under
// the rule's `lengthBytes(ARGS) ==Int 5` side condition the two are equivalent (ARGS is exactly 5
// bytes, so reading all of it equals reading its first 5 bytes), and the no-substr form matches
// the gate rule's pattern at swapvm.md:187. See deadline.md "Why the rule reads the whole ARGS".
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
// Per PLAN.md D4 it is abstracted out of the K configuration. Two uninterpreted symbols are
// declared below:
//
//   - `#blockTimestamp()` — the D4 abstraction of the chain's `block.timestamp`, per the task
//     brief. A nullary total function `[function, no-evaluators]`; its value is fixed-but-
//     unknown, constrained only by spec premises. This is the symbol a spec uses to reason about
//     the timestamp directly (e.g. `requires #blockTimestamp() >Int 0`).
//
//   - `#deadlineExceeded(DEADLINE)` — a Bool predicate that the RULE uses for arm selection.
//     Conceptually `#deadlineExceeded(DL) == (#blockTimestamp() >Int DL)`; it is kept
//     uninterpreted (no simplification rule defining it in terms of `#blockTimestamp()`) so that
//     the arm-selection side condition stays a single atomic Bool the SMT solver can decide on,
//     rather than a comparison between an uninterpreted function and a symbolic value.
//
// WHY TWO SYMBOLS. The brief's suggested rule form `requires #blockTimestamp() >Int DEADLINE`
// does NOT prove in this backend: a two-arm rule splitting on `#blockTimestamp() >Int X` vs
// `#blockTimestamp() <=Int X` cannot have an arm excluded by a premise `#blockTimestamp() >Int
// DL`, because the K Haskell backend's SMT encoding does not propagate the premise's inequality
// on an uninterpreted-vs-symbolic comparison into a refutation of the opposite arm. This was
// confirmed empirically: the same rule shape with `#balanceOf(...) <=Int 0` vs `>Int 0` (gate,
// comparing to a CONSTANT) DOES prove, but the identical shape with `#testVal(...) >Int X` vs
// `<=Int X` (comparing to a SYMBOLIC value) does NOT. Re-casting the branch condition as a Bool
// predicate `#deadlineExceeded(DL)` makes the arm selection a direct `Bool` match: the REVERT
// arm requires `#deadlineExceeded(DL)` and the PASS arm requires `notBool #deadlineExceeded(DL)`,
// and a spec premise `#deadlineExceeded(DL)` selects the REVERT arm exactly as gate-spec's
// `#balanceOf(...) ==Int 0` selects its REVERT arm. See deadline.md "Arm selection" for the full
// diagnostic, including the minimal reproducer that isolates this backend behaviour from all the
// decode/bytes machinery.
//
// Both symbols honour the D4 boundary: neither has a defining rule, neither is a cell, and the
// spec quantifies over timestamps via premises rather than assuming a value. Adding a `<timestamp>`
// cell to swapvm.md was explicitly out of scope (six sibling subagents depend on swapvm.md being
// untouched); these local declarations achieve the abstraction without that coordination cost.

module SWAPVM-DEADLINE
  imports SWAPVM

  // The current block timestamp, as an uninterpreted total function. This is the PLAN.md D4
  // abstraction boundary for the chain's `block.timestamp` environment input, per the task
  // brief. No defining rule: its value is fixed-but-unknown, constrained only by spec premises.
  // `[function, no-evaluators]` marks it as a total function symbol and prevents the simplifier
  // from inventing a reduction. The rule below does NOT branch on this symbol directly — see
  // `#deadlineExceeded` for why, and the file header for the full diagnostic.
  syntax Int ::= #blockTimestamp () [function, no-evaluators]

  // A Bool predicate abstracting `block.timestamp >Int DEADLINE`. The RULE branches on this
  // rather than on `#blockTimestamp() >Int DEADLINE` directly, because the K Haskell backend
  // cannot exclude an arm of a two-arm rule whose side condition compares an uninterpreted
  // function to a symbolic value (see file header). A spec premise `#deadlineExceeded(DL)`
  // (implicitly `==Bool true`) selects the REVERT arm; `notBool #deadlineExceeded(DL)` would
  // select the PASS arm. Conceptually `#deadlineExceeded(DL) == (#blockTimestamp() >Int DL)`;
  // the two are kept as independent uninterpreted symbols (no simplification rule equating them)
  // so the arm-selection condition stays decidable for the SMT solver.
  syntax Bool ::= #deadlineExceeded ( Int ) [function, no-evaluators]

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
  //
  // Reads `Bytes2Int(ARGS, BE, Unsigned)` — the WHOLE ARGS — rather than a substr. See deadline.md
  // "Why the rule reads the whole ARGS": under `lengthBytes(ARGS) ==Int 5` the two are equivalent,
  // and the no-substr form reduces in one step via the round-trip lemma (lemmas.k:64-67).
  rule <k> #exec ( 32 , ARGS ) => #revert("DeadlineReached") ... </k>
       <status> Running </status>
    requires lengthBytes(ARGS) ==Int 5
     andBool #deadlineExceeded(Bytes2Int(ARGS, BE, Unsigned))

  // Canonical 5-byte Deadline, PASS arm. `block.timestamp <= deadline`: the deadline has NOT
  // been exceeded, the require holds, and `_deadline` returns normally. The opcode is a no-op at
  // the register level — reads no register, writes no register, no `setNextPC` — so the
  // continuation #run is left in <k> and the loop proceeds to decode the next instruction. Like
  // Salt (opcodes/salt.k), Deadline is NOT a halt on this arm: an arbitrary symbolic tail in the
  // program WILL be decoded after Deadline passes. The composition shape for positive claims
  // therefore mirrors salt-spec.k / jump-spec.k, not gate-spec.k — see deadline.md "Composition".
  rule <k> #exec ( 32 , ARGS ) => .K ... </k>
       <status> Running </status>
    requires lengthBytes(ARGS) ==Int 5
     andBool notBool #deadlineExceeded(Bytes2Int(ARGS, BE, Unsigned))

  // Non-canonical args: Solidity right-pads short and truncates long without reverting, which is
  // a soundness hazard (swapvm.md:301-324). Revert loudly here so a proof cannot silently
  // succeed on an unmodelled length. Mirrors opcodes 0x23 / 0x90 in swapvm.md:319-324 and the
  // twin in opcodes/jump.k:50-54.
  rule <k> #exec ( 32 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
    requires lengthBytes(ARGS) =/=Int 5
endmodule
