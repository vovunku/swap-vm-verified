// Concrete-input conformance claims for the 0x50 (XYCSwap) opcode.
//
// Source: `XYCSwap.sol:_xycSwapXD`. The constant-product pricer (x*y=k curve, no fees) — a
// direct structural sibling of `0x53` LimitSwap. The four claims below pin all four arms for
// fully concrete inputs; a claim that proves under kprove is the operational equivalent of
// having `krun` the program (see gte-concrete.k / pricing-spec.k for the pattern). The exact-
// out claim deliberately picks a non-dividing input so the CEILING is exercised (43, not 42).
//
// PROGRAM. `b"\x50\x00"` — opcode 0x50 = 80 decimal, argsLen 0. Args are IGNORED by the
// handler (`bytes calldata /* args */`), so argsLen 0 is the canonical minimal form; the
// opcode places no constraint on args length (like 0x53 LimitSwap, unlike the gates). After
// decode `<pc>` = 2 + 0 = 2 = program length, so the trailing `#run` halts on the next step.
//
// THE FOUR ARMS exercised:
//   A. Exact-in pricing — amountOut = (amountIn * balanceOut) / (balanceIn + amountIn), floored.
//      100 * 100 / (100 + 100) = 50. (XYCSwap.sol exact-in branch.)
//   B. Exact-out pricing — amountIn = ceilDiv(amountOut * balanceIn, balanceOut - amountOut).
//      ceilDiv(30 * 100, 100 - 30) = ceilDiv(3000, 70) = 43 (3000/70 = 42 remainder 60, so
//      ceiling is 43 — NOT 42, which distinguishes ceiling from floor).
//   C. Both-balances-zero revert — balanceIn 0, reverts "XYCSwapRequiresBothBalancesNonZero".
//   D. Recompute revert — exact-in with amountOut already set, reverts "XYCSwapRecomputeDetected".
//
// HAND-COMPUTED QUOTES (cross-checked against the Solidity curve):
//   A. xycQuoteOut(100, 100, 100) = 10000 / 200 = 50          (exact, floor = 50)
//   B. xycQuoteIn(30, 100, 100)  = ceilDiv(3000, 70) = 43      (non-dividing: 42 r.60 -> 43)
module XYCSWAP-CONCRETE
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS
  imports SWAPVM-XYCSWAP

  // ---- Scenario A — EXACT-IN PRICING. amountIn 100, reserves 100/100. The constant-product
  // curve gives amountOut = 100*100/(100+100) = 50. Rule writes <amountOut> 0 => 50 and leaves
  // #run; the trailing loop halts at pc 2. Asserts the EXACT computed amountOut (not just
  // status), which is what distinguishes the constant-product curve from the flat LimitSwap
  // rate (LimitSwap would give 100 here — a mutant swapping the curve would fail this claim).
  claim <k> #run => .K </k>
        <program> b"\x50\x00" </program>
        <pc> 0 => 2 </pc>
        <balanceIn> 100 </balanceIn> <balanceOut> 100 </balanceOut>
        <amountIn> 100 </amountIn> <amountOut> 0 => 50 </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> true </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> _ </taker>
        <balances> _ </balances>
        <invalidators> _ </invalidators>
        <status> Running </status>
        <trace> _ </trace>

  // ---- Scenario B — EXACT-OUT PRICING (ceiling). amountOut 30, reserves 100/100.
  // amountIn = ceilDiv(30*100, 100-30) = ceilDiv(3000, 70) = 43. 70 does not divide 3000
  // (42 * 70 = 2940, remainder 60), so the ceiling is 43, NOT the floor 42. Asserting 43
  // discriminates the rounding direction (ceiling vs floor) — a mutant that used floor would
  // produce 42 and fail this claim. Mirrors how pricing-exactout-spec.k (T2) pins the ceiling.
  claim <k> #run => .K </k>
        <program> b"\x50\x00" </program>
        <pc> 0 => 2 </pc>
        <balanceIn> 100 </balanceIn> <balanceOut> 100 </balanceOut>
        <amountIn> 0 => 43 </amountIn> <amountOut> 30 </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> false </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> _ </taker>
        <balances> _ </balances>
        <invalidators> _ </invalidators>
        <status> Running </status>
        <trace> _ </trace>

  // ---- Scenario C — BOTH-BALANCES-ZERO REVERT. balanceIn 0: the first-line require fails,
  // reverts "XYCSwapRequiresBothBalancesNonZero". pc ends at post-decode 2; #revert clears
  // <k> so neither register is touched.
  claim <k> #run => .K </k>
        <program> b"\x50\x00" </program>
        <pc> 0 => 2 </pc>
        <balanceIn> 0 </balanceIn> <balanceOut> 100 </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> true </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> _ </taker>
        <balances> _ </balances>
        <invalidators> _ </invalidators>
        <status> Running => Reverted("XYCSwapRequiresBothBalancesNonZero") </status>
        <trace> _ </trace>

  // ---- Scenario D — RECOMPUTE REVERT (exact-in). amountOut already 7 (non-zero): the
  // single-assignment guard fires, reverts "XYCSwapRecomputeDetected". This is the safety
  // property that a program cannot price the same register twice; a mutant deleting it would
  // let scenario A's pricing overwrite a prior quote and would fail to revert here.
  claim <k> #run => .K </k>
        <program> b"\x50\x00" </program>
        <pc> 0 => 2 </pc>
        <balanceIn> 100 </balanceIn> <balanceOut> 100 </balanceOut>
        <amountIn> _ </amountIn> <amountOut> 7 </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> true </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> _ </taker>
        <balances> _ </balances>
        <invalidators> _ </invalidators>
        <status> Running => Reverted("XYCSwapRecomputeDetected") </status>
        <trace> _ </trace>

endmodule
