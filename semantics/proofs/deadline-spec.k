module DEADLINE-SPEC
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // Phase 1 sibling of gate-spec.k. For ANY program that begins with Deadline(DL) — with TAIL an
  // arbitrary, symbolic byte string — a block timestamp strictly after DL ends reverted with
  // "DeadlineReached".
  //
  // TAIL is never decoded: #revert discards the continuation (swapvm.md:154-156), so its contents
  // cannot affect the conclusion and the proof must not case-split on it. Same shape as
  // gate-spec.k, revert-spec.k, and stop-spec.k.
  //
  // b"\x20\x05" is the [opcode:1][argsLen:1] header — opcode 0x20 = 32 decimal, argsLen 5 (the
  // uint40 deadline). After the decode loop fires <pc> = 2 + 5 = 7. The deadline value itself is
  // constructed via `Int2Bytes(5, DL, BE)` so the round-trip lemma in lemmas.k:64-67 rewrites
  // `Bytes2Int(Int2Bytes(5, DL, BE), BE, Unsigned) => DL` exactly, under the premise
  // `0 <=Int DL andBool DL <Int 2^40` (which is the lemma's required bound
  // `0 <=Int V andBool V <Int 2 ^Int (8 *Int N)` with N = 5).
  //
  // ARM SELECTION — why the premise is `#deadlineExceeded(DL)` and not `#blockTimestamp() >Int
  // DL`. The Deadline rule (opcodes/deadline.k) has two canonical arms that split on whether the
  // deadline has been exceeded. The natural Solidity-faithful condition is
  // `#blockTimestamp() >Int DEADLINE` vs `#blockTimestamp() <=Int DEADLINE`, and a spec premise
  // `#blockTimestamp() >Int DL` OUGHT to select the REVERT arm by contradicting the PASS arm.
  // Empirically it does not: the K Haskell backend does not propagate an inequality premise on
  // an uninterpreted-vs-symbolic comparison into a refutation of the opposite arm, so the PASS
  // arm is also explored; the PASS arm does not halt, the loop runs into a symbolic TAIL, and the
  // all-path claim stalls with 20+ unexplored branches. The gate rule avoids this because its
  // arms compare `#balanceOf(...)` to a CONSTANT (0), not a symbolic value, and constant
  // reasoning IS propagated. The fix — recorded in opcodes/deadline.k and deadline.md "Arm
  // selection" — is to abstract the comparison itself into a Bool predicate
  // `#deadlineExceeded(DL)` (conceptually `#blockTimestamp() >Int DL`) and branch on THAT. A
  // premise `#deadlineExceeded(DL)` (implicitly `==Bool true`) then selects the REVERT arm
  // exactly as `#balanceOf(...) ==Int 0` selects the gate's REVERT arm. Both `#blockTimestamp()`
  // and `#deadlineExceeded(DL)` are uninterpreted, both honour PLAN.md D4, and neither is a cell.
  //
  // The `lengthBytes(TAIL) >=Int 0` side condition is NOT decorative — do not delete. Once
  // `lengthBytes(b"\x20\x05" +Bytes Int2Bytes(5, DL, BE) +Bytes TAIL)` rewrites to
  // `7 +Int lengthBytes(TAIL)`, no axiom forces `lengthBytes` non-negative, so without this
  // premise the prover can take the `PC >= length` termination branch at <pc> 0 and the claim
  // gets stuck. Same reason as gate-spec.k:27-32, revert-spec.k:18-22, and stop-spec.k:21-24.
  //
  // NOTE on the opcode byte: it is `\x20` (= 32 decimal), NOT `\x14` (= 20 decimal). The two
  // are easy to confuse because 0x20 reads as "20" in hex, but the rule keys on the DECIMAL
  // opcode `#exec ( 32 , ARGS )` and the program byte is the hex literal 0x20. An earlier draft
  // used `\x14` (20 decimal); the result was an `#unknown(20, ...)` trace entry and the
  // `[owise]` no-op firing instead of the Deadline rule — the diagnostic that surfaced this.
  //
  // Sensitivity twin: deadline-control.k — same premises, conclusion `Running` instead of
  // `Reverted("DeadlineReached")` — must FAIL. Together they show kprove is discriminating on
  // the conclusion rather than choking on the setup.
  claim <k> #run => .K </k>
        <program> b"\x20\x05" +Bytes Int2Bytes(5, DL, BE) +Bytes TAIL </program>
        <pc> 0 => 7 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> _ </taker>
        <balances> _ </balances>
        <invalidators> _ </invalidators>
        <status> Running => Reverted("DeadlineReached") </status>
        <trace> _ </trace>
    requires 0 <=Int DL andBool DL <Int (2 ^Int 40)
     andBool #deadlineExceeded(DL)
     andBool lengthBytes(TAIL) >=Int 0

endmodule
