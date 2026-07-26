requires "../swapvm.md"

// 0x42 InvalidateTokenOut — Invalidators.sol:_invalidateTokenOut1D (lines 122-135).
//
// Adds the rule to the SWAPVM semantics. K v7 does not allow reopening `module SWAPVM`
// across files (it reports "Module SWAPVM differs from previous declaration"), so this
// file defines a sibling module SWAPVM-INVALIDATETOKENOUT that imports SWAPVM and adds the
// rules. Integration is via `requires "opcodes/invalidatetokenout.k"` plus
// `imports SWAPVM-INVALIDATETOKENOUT` from the aggregated module (semantics/_lemmas-all.k)
// — see invalidatetokenout.md "Integration".
//
// UNLIKE EVERY MODELLED OPCODE SO FAR, this one is not a pure conditional halt. It is the
// first instruction that (a) reads the swap registers `<amountOut>` / `<balanceOut>`,
// (b) mutates the `<invalidators>` cell, and (c) RECURSES INTO runLoop. Each is modelled
// below. The Solidity source:
//
//   function _invalidateTokenOut1D(Context memory ctx, bytes calldata /* args */) internal {
//       if (ctx.swap.amountOut == 0) { ctx.runLoop(); }              // DEFER
//       require(ctx.swap.amountOut > 0, InvalidateTokenOutExpectsAmountOutToBeComputed());
//       uint256 prefilled = tokenOutInvalidators[ctx.query.maker][ctx.query.orderHash][ctx.query.tokenOut];
//       uint256 newFilled = prefilled + ctx.swap.amountOut;
//       require(newFilled <= ctx.swap.balanceOut, InvalidatorsTokenOutExceeded(...));
//       if (!ctx.vm.isStaticContext) { tokenOutInvalidators[...][tokenOut] = newFilled; }
//   }
//
// ARGS ARE IGNORED. The handler signature is `bytes calldata /* args */`: the args-length
// byte still drives `<pc>` advance in the decode loop (`pc += 2 + argsLen`), but the payload
// itself is never read. Consequently this opcode places NO constraint on `lengthBytes(ARGS)`
// and needs NO `UNMODELLED-ARGS-LENGTH` arm — the same posture as `0x53` LimitSwap
// (swapvm.md:326-328). Any args length is accepted; the rule fires regardless.
//
// THE DEFERRAL (`if (amountOut == 0) ctx.runLoop()`). This is the load-bearing modelling
// decision. `_invalidateTokenOut1D` is placed in a program BEFORE the pricer that computes
// `amountOut` (the exact-in case: amountIn is known, amountOut is derived). When it runs
// with `amountOut` still 0, it RE-ENTERS `runLoop` — a recursive call that executes the
// REST of the program from the already-advanced `nextPC`. Some later instruction (e.g.
// `0x53` LimitSwap in exact-in mode) writes `amountOut`; when the inner loop ends (pc
// reaches the program end), control returns past the `if` and the require check runs with
// the now-computed value. This is a yield/resume mechanism, not a jump: the instruction
// neither reads nor writes `<pc>` beyond the decode advance.
//
// K MODEL OF THE RECURSION. The decode step (swapvm.md:143-149) rewrites
//   <k> #run => #exec(OP, ARGS) ~> #run ... </k>
// so when `#exec(66, _)` fires, the trailing `#run` (the loop continuation) is already on
// the stack. The deferral rule emits `#run ~> #checkTokenOut` in place of `#exec`, giving
//   <k> #run ~> #checkTokenOut ~> #run ... </k>
// The LEFTMOST `#run` is the INNER loop: it processes the rest of the program (the deferred
// tail) starting from the already-advanced `<pc>`, exactly mirroring the recursive
// `ctx.runLoop()` call. When `<pc>` reaches the end it rewrites to `.K`, leaving
// `#checkTokenOut ~> #run`; `#checkTokenOut` then runs the require check on the (possibly
// now-computed) `<amountOut>`; the trailing `#run` sees `<pc>` at the end and halts. This
// reproduces the Solidity control flow precisely, including the fact that a revert inside
// the deferred tail propagates: `#revert(MSG) ~> _ => .K` (swapvm.md:154-156) clears the
// whole continuation, so `#checkTokenOut` never runs — matching the EVM unwind.
//
// THE IMMEDIATE PATH (`amountOut =/=Int 0`). No deferral: the check runs at once, then the
// trailing `#run` continues with the next instruction (the normal loop step). The rule emits
// just `#checkTokenOut`, giving `#checkTokenOut ~> #run`.
//
// THE CHECK is factored into a named continuation `#checkTokenOut` rather than inlined into
// `#exec`, because BOTH paths (deferred and immediate) run the identical require sequence.
// Centralising it makes the two paths literally share the check and makes the deferral
// mechanism the only thing the `#exec` rules do. `#checkTokenOut` has three arms mirroring
// the two Solidity `require`s plus the success write:
//   1. amountOut <=Int 0          -> #revert("InvalidateTokenOutExpectsAmountOutToBeComputed")
//   2. prefilled + amountOut > balanceOut -> #revert("InvalidatorsTokenOutExceeded")
//   3. prefilled + amountOut <= balanceOut -> write the invalidator, no-op pass
// Arm 1 is reachable ONLY via the deferral path whose inner loop failed to compute
// amountOut (on the immediate path amountOut is already > 0 by the guard). It is the K
// twin of the second-line require `amountOut > 0` that fires when `runLoop()` returned
// without anyone setting the register.
//
// INVALIDATOR STATE — the `<invalidators>` cell. swapvm.md:62 declares `<invalidators>
// .Map </invalidators>` and no modelled opcode has used it until now. The Solidity stores
// `tokenOutInvalidators[maker][orderHash][tokenOut] = filled:uint256`. The model keys that
// same fact with the constructor `invalOut(MAKER, OH, TOK)` (declared below) and reads it
// via the `[function, total]` helper `#prefilledOut(INV, MAKER, OH, TOK)`, which is a
// structural twin of `#balanceOf` (swapvm.md:171-174): `orDefault 0` on a missing key, so a
// first fill reads prefilled = 0. The future `0x41` InvalidateTokenIn will reuse this cell
// with a distinct key constructor `invalIn(...)`.
//
// MISSING QUERY FIELDS — maker and orderHash. The `<query>` cell (swapvm.md:55-60) carries
// `taker`, `tokenIn`, `tokenOut`, `isExactIn` but NOT `maker` or `orderHash`, which the
// Solidity reads as `ctx.query.maker` / `ctx.query.orderHash`. These are fixed per
// execution (properties of the signed order, like `tx.origin`), so per PLAN.md D4 they are
// modelled as local uninterpreted nullary functions `#maker()` / `#orderHash()` — exactly
// the pattern `opcodes/txorigin.k` uses for `#txOrigin()` and `opcodes/supplyshare.k` uses
// for `#totalSupply(Int)`. The brief forbids editing swapvm.md (sibling subagents depend on
// it being untouched), so the symbols are declared here rather than added as cells. A
// concrete claim pins them via premises (`requires #maker() ==Int ...`).
//
// QUOTE/SWAP DIVERGENCE — NOT MODELLED. The Solidity guards the storage write with
// `if (!ctx.vm.isStaticContext)`: in quote (static) mode the check runs but the filled
// counter is NOT updated, so a quote may succeed while a swap reverts if the order was
// filled in between (Invalidators.sol:118-121). The K configuration has no `isStaticContext`
// cell and no notion of a quote mode — every execution is modelled as the SWAP path, the
// security-critical one, consistently with every other modelled opcode (none branch on
// static context). The model therefore performs the write unconditionally. This is correct
// for swap-mode reasoning and for the no-replay / no-overfill properties the opcode exists
// to enforce; the quote-only check-without-write path is a strict subset that is simply out
// of scope, not contradicted. Stated plainly: a theorem over this rule is a theorem about
// swap execution, not quote execution.
//
// ARITHMETIC OVERFLOW — REACHABLE, reason diverges. `prefilled + amountOut` is Solidity 0.8
// checked `uint256` addition: it reverts `Panic(0x11)` on wraparound. The model uses
// unbounded `+Int`, so the sum never wraps and the overfill arm (`> balanceOut`) fires
// instead with reason "InvalidatorsTokenOutExceeded". This is NOT unreachable: the public
// `invalidateTokenOut(orderHash, tokenOut)` (Invalidators.sol:72-76) — the standard order-
// cancellation path — sets the counter to `type(uint256).max`. After a cancel, every
// subsequent `_invalidateTokenOut1D` with `amountOut > 0` hits the checked add at :130 and
// reverts `Panic(0x11)`; the model reverts `InvalidatorsTokenOutExceeded`. BOTH revert, so
// this is not permissive (the soundness direction is correct), but it is an ordinary,
// reachable path where the model's REVERT REASON is wrong, and any theorem stated about the
// reason on this path is wrong too. Recorded here as a known limitation, not modelled.

module SWAPVM-INVALIDATETOKENOUT
  imports SWAPVM

  // The maker address (ctx.query.maker) and the order hash (ctx.query.orderHash), as
  // uninterpreted nullary total functions. Fixed per execution, never reduced by the
  // simplifier — their values come from spec premises (`requires #maker() ==Int 7`).
  // `[function, no-evaluators]` is the same attribute `#txOrigin()` / `#totalSupply(_)`
  // carry (opcodes/txorigin.k, opcodes/supplyshare.k).
  syntax Int ::= #maker () [function, no-evaluators]
  syntax Int ::= #orderHash () [function, no-evaluators]

  // Key into `<invalidators>` for the tokenOut filled counter. Twin of `bal(token, holder)`
  // (swapvm.md:169) for the balances cell. `(maker, orderHash, tokenOut)` is exactly the
  // three-level Solidity mapping key `tokenOutInvalidators[maker][orderHash][tokenOut]`.
  syntax KItem ::= invalOut ( Int , Int , Int )

  // The deferred check continuation shared by both #exec paths (see header). Declared so the
  // deferral rule can schedule `#run ~> #checkTokenOut` and the immediate rule `#checkTokenOut`.
  syntax KItem ::= "#checkTokenOut"

  // Read the prefilled amount for (maker, orderHash, tokenOut) from the invalidators map, or
  // 0 if no fill has been recorded yet. Structural twin of `#balanceOf` (swapvm.md:171-174):
  // the `orDefault 0` gives the uint256 default for a fresh key, and the `[owise]` arm keeps
  // the function total on a non-Int residual.
  syntax Int ::= #prefilledOut ( Map , Int , Int , Int ) [function, total]
  rule #prefilledOut(INV, MAKER, OH, TOK)
    => {INV [ invalOut(MAKER, OH, TOK) ] orDefault 0}:>Int
    requires isInt(INV [ invalOut(MAKER, OH, TOK) ] orDefault 0)
  rule #prefilledOut(_, _, _, _) => 0 [owise]

  // ---- #exec dispatch: split on whether amountOut is already computed ----

  // DEFERRAL arm. `amountOut == 0`: the pricer has not run yet. Emit `#run ~> #checkTokenOut`
  // so the INNER #run (the trailing decode loop) consumes the rest of the program first —
  // during which a later instruction writes `<amountOut>` — and only then does the check
  // fire. See header "K MODEL OF THE RECURSION". The `Running` guard matches the loop rule
  // (swapvm.md:103) and the analogous guards on Gte / SupplyShare. `#exec(66, _)` is more
  // specific than the `[owise]` unknown-opcode rule (swapvm.md:349-351), so it takes priority.
  // A single `==Int 0` premise: no `andBool`, so the D-1 `==Bool` precedence hazard
  // (axioms.md "DEFECT D-1") does not apply.
  rule <k> #exec ( 66 , _ ) => #run ~> #checkTokenOut ... </k>
       <amountOut> AOUT </amountOut>
       <status> Running </status>
    requires AOUT ==Int 0

  // IMMEDIATE arm. `amountOut =/=Int 0`: the value is already known (e.g. exact-OUT mode or
  // a re-entry after the pricer). No deferral — run the check at once, then the trailing
  // `#run` steps to the next instruction. Mutually exclusive with the deferral arm on AOUT.
  rule <k> #exec ( 66 , _ ) => #checkTokenOut ... </k>
       <amountOut> AOUT </amountOut>
       <status> Running </status>
    requires AOUT =/=Int 0

  // ---- #checkTokenOut: the shared require sequence (Invalidators.sol:128-134) ----

  // Arm 1 — expects-computed. `amountOut` is still <= 0 after the deferral ran (or, on the
  // immediate path, this is unreachable because AOUT =/=Int 0). This is the K twin of
  // `require(ctx.swap.amountOut > 0, InvalidateTokenOutExpectsAmountOutToBeComputed())`:
  // a program that defers and reaches the program end without any instruction computing
  // amountOut reverts here. `#revert` clears `<k>`, so the trailing `#run` is discarded.
  rule <k> #checkTokenOut => #revert("InvalidateTokenOutExpectsAmountOutToBeComputed") ... </k>
       <amountOut> AOUT </amountOut>
       <status> Running </status>
    requires AOUT <=Int 0

  // Arm 2 — overfill. `prefilled + amountOut > balanceOut`: the cumulative fill would exceed
  // the maker's output reserve. K twin of
  //   require(newFilled <= ctx.swap.balanceOut, InvalidatorsTokenOutExceeded(...)).
  // `#prefilledOut` reads the prior fill (0 for a fresh key); the unbounded `+Int` models
  // the Solidity sum below the 2^256 overflow ceiling (see header "ARITHMETIC OVERFLOW").
  // Disjoint from arm 1 (AOUT > 0) and arm 3 (the `<=Int balanceOut` mirror).
  rule <k> #checkTokenOut => #revert("InvalidatorsTokenOutExceeded") ... </k>
       <amountOut> AOUT </amountOut>
       <balanceOut> BOUT </balanceOut>
       <query> ... <tokenOut> TOUT </tokenOut> ... </query>
       <invalidators> INV </invalidators>
       <status> Running </status>
    requires AOUT >Int 0
     andBool #prefilledOut(INV, #maker(), #orderHash(), TOUT) +Int AOUT >Int BOUT

  // Arm 3 — pass + write. The fill fits: `prefilled + amountOut <= balanceOut`. The check
  // passes and the filled counter is updated to `prefilled + amountOut`, modelling the
  // swap-path write `tokenOutInvalidators[...] = newFilled`. The map update recomputes
  // `#prefilledOut` on the SAME `INV` (a `[function, total]`, so it reduces to the value
  // the requires clause tested) — K cannot bind a subterm across the side condition and the
  // rewrite, so the shared call is repeated textually; it denotes one and the same int.
  // Leaving `#run` in `<k>` lets the loop proceed to the next instruction (immediate path) or
  // halt (deferred path, pc already at end).
  rule <k> #checkTokenOut => .K ... </k>
       <amountOut> AOUT </amountOut>
       <balanceOut> BOUT </balanceOut>
       <query> ... <tokenOut> TOUT </tokenOut> ... </query>
       <invalidators>
         INV => INV [ invalOut(#maker(), #orderHash(), TOUT)
                        <- #prefilledOut(INV, #maker(), #orderHash(), TOUT) +Int AOUT ]
       </invalidators>
       <status> Running </status>
    requires AOUT >Int 0
     andBool #prefilledOut(INV, #maker(), #orderHash(), TOUT) +Int AOUT <=Int BOUT
endmodule
