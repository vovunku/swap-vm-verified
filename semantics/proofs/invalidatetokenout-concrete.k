// Concrete-input conformance claims for the 0x42 (InvalidateTokenOut) opcode.
//
// Source: `Invalidators.sol:_invalidateTokenOut1D` (lines 122-135). Unlike every modelled
// opcode so far this one is NOT a pure conditional halt: it reads the swap registers
// (`<amountOut>`, `<balanceOut>`), mutates the `<invalidators>` cell, and — when amountOut
// is not yet computed — RECURSES INTO runLoop. The three claims below pin those behaviours
// for fully concrete inputs; a claim that proves under kprove is the operational equivalent
// of having `krun` the program (see gte-concrete.k / txorigin-concrete.k for the pattern).
//
// PROGRAM. `b"\x42\x00"` — opcode 0x42 = 66 decimal, argsLen 0. Args are IGNORED by the
// handler (`bytes calldata /* args */`), so argsLen 0 is the canonical minimal form; the
// opcode places no constraint on args length (like 0x53 LimitSwap, unlike the gates). After
// decode `<pc>` = 2 + 0 = 2 = program length, so the trailing `#run` halts on the next step.
//
// THE THREE ARMS exercised:
//   A. Overfill REVERT — amountOut already set, prefilled + amountOut > balanceOut. Immediate
//      path (`#exec => #checkTokenOut`), arm 2 of #checkTokenOut. (Invalidators.sol:131)
//   B. PASS + WRITE — the fill fits, the invalidator is updated. Immediate path, arm 3.
//      Asserts the EXACT final `<invalidators>` map entry. (Invalidators.sol:133)
//   C. Expects-computed REVERT — amountOut == 0 and the deferred tail computes nothing.
//      Deferral path (`#exec => #run ~> #checkTokenOut`): the inner #run consumes the (empty)
//      tail and halts, then arm 1 fires. This is the claim that exercises the RECURSION.
//      (Invalidators.sol:124-128)
//
// MISSING QUERY FIELDS. The handler reads `ctx.query.maker` / `ctx.query.orderHash`, which
// are not `<query>` cells in the K config. They are uninterpreted nullary functions
// (`#maker()` / `#orderHash()`, opcodes/invalidatetokenout.k). All three claims pin them
// concretely (`requires #maker() ==Int 7` / `#orderHash() ==Int 99`): this is required for
// `#prefilledOut` to reduce, because a symbolic key (`invalOut(#maker(), ...)`) into a
// concrete map cannot be resolved by the simplifier — the SAME reason txorigin-concrete.k
// pins `#txOrigin()`. Pinning makes the lookup key concrete so the [function, total] defining
// rule (or its [owise] twin) fires.
module INVALIDATETOKENOUT-CONCRETE
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS
  imports SWAPVM-INVALIDATETOKENOUT

  // ---- Scenario A — OVERFILL REVERT (immediate path). amountOut 100, balanceOut 50,
  // prefilled 0 (empty map). 0 + 100 = 100 > 50, arm 2 fires, reverts
  // "InvalidatorsTokenOutExceeded". pc ends at post-decode 2; #revert clears <k> so the
  // trailing #run is discarded and <invalidators> is left untouched.
  claim <k> #run => .K </k>
        <program> b"\x42\x00" </program>
        <pc> 0 => 2 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> 50 </balanceOut>
        <amountIn> _ </amountIn> <amountOut> 100 </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> 5 </tokenOut>
        <taker> _ </taker>
        <balances> _ </balances>
        <invalidators> .Map </invalidators>
        <status> Running => Reverted("InvalidatorsTokenOutExceeded") </status>
        <trace> _ </trace>
    requires #maker() ==Int 7 andBool #orderHash() ==Int 99

  // ---- Scenario B — PASS + WRITE (immediate path). amountOut 30, balanceOut 50,
  // prefilled 0. 0 + 30 = 30 <= 50, arm 3 fires: the check passes and the filled counter is
  // written to invalOut(#maker(), #orderHash(), 5) |-> 30. #maker()/#orderHash() are pinned
  // to 7 / 99 so the final map entry is the concrete literal invalOut(7, 99, 5) |-> 30.
  // pc ends at 2 (post-decode) and status stays Running; the trailing #run sees pc >= length
  // and halts. This is the only arm that mutates <invalidators>, so it is the one that
  // verifies the storage write against Solidity's `tokenOutInvalidators[...] = newFilled`.
  claim <k> #run => .K </k>
        <program> b"\x42\x00" </program>
        <pc> 0 => 2 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> 50 </balanceOut>
        <amountIn> _ </amountIn> <amountOut> 30 </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> 5 </tokenOut>
        <taker> _ </taker>
        <balances> _ </balances>
        <invalidators> .Map => invalOut(7, 99, 5) |-> 30 </invalidators>
        <status> Running </status>
        <trace> _ </trace>
    requires #maker() ==Int 7 andBool #orderHash() ==Int 99

  // ---- Scenario C — EXPECTS-COMPUTED REVERT (deferral path). amountOut 0: the pricer has
  // not run. The deferral rule emits `#run ~> #checkTokenOut`; the inner #run consumes the
  // empty tail (pc already 2 >= length 2) and halts, then #checkTokenOut sees amountOut
  // still 0 and arm 1 fires, reverting "InvalidateTokenOutExpectsAmountOutToBeComputed".
  // This is the claim that exercises the runLoop recursion: a model that omitted the
  // deferral would have no rule for #exec(66,_) at amountOut 0 and would fall through to the
  // [owise] unknown-opcode no-op (status Running) — the wrong answer. pc ends at 2.
  claim <k> #run => .K </k>
        <program> b"\x42\x00" </program>
        <pc> 0 => 2 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> 50 </balanceOut>
        <amountIn> _ </amountIn> <amountOut> 0 </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> 5 </tokenOut>
        <taker> _ </taker>
        <balances> _ </balances>
        <invalidators> .Map </invalidators>
        <status> Running => Reverted("InvalidateTokenOutExpectsAmountOutToBeComputed") </status>
        <trace> _ </trace>
    requires #maker() ==Int 7 andBool #orderHash() ==Int 99

endmodule
