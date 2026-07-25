// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { CalldataPtr, CalldataPtrLib } from "@1inch/solidity-utils/contracts/libraries/CalldataPtr.sol";

import { Context, ContextLib } from "../../../src/libs/VM.sol";
import { MinRate, MinRateArgsBuilder } from "../../../src/instructions/MinRate.sol";

/// @notice External surface over MinRate's internal instructions, for symbolic execution.
///
/// @dev IMPORTANT — read before trusting any proof through this harness.
///
///      Unlike XYCSwap and LimitSwap, MinRate's `_requireMinRate1D` and `_adjustMinRate1D`
///      are NOT pure functions: they call `ctx.runLoop()`, which dispatches the swap program
///      through the internal function pointer `ctx.vm.dispatch`. That dispatch is exactly the
///      pattern `test/kontrol/WORKPLAN.md` classifies as a separate, unscheduled project —
///      "runLoop dispatches through an internal function pointer, which forces the prover to
///      branch over every jump destination." The WORKPLAN's tier-1 listing of MinRate as
///      "pure, no loops" (see `test/kontrol/README.md`) is stale relative to the source.
///
///      To verify MinRate's own logic anyway, this harness installs a STUB dispatcher whose
///      only effect is to populate the missing swap register with a value the caller chose.
///      The run loop is driven by a one-opcode program (`hex"0000"`, opcode and args-length
///      both zero) so `dispatch` fires exactly once and the loop exits. Properties proven
///      through this harness therefore characterise MinRate's rate-checking logic
///      *conditional on* `runLoop` returning a particular pair of amounts — they do not
///      verify the run loop, the dispatcher, or any real pricing instruction. The run loop
///      remains verified by no one.
///
///      The stub preserves the invariant the real swap program is expected to maintain: it
///      only writes the register that was zero on entry (amountOut for exact-in, amountIn
///      for exact-out). This matters because `_adjustMinRate1D` captures `amountIn` /
///      `amountOut` before calling `runLoop` and uses the captured value in its adjustment
///      formula, so the non-zero register must survive the stub unchanged.
///
///      The computed value is carried through `ctx.swap.amountNetPulled`, an unused register
///      that neither MinRate entrypoint reads. Carrying it through memory (rather than a
///      storage slot, as the first version of this harness did) keeps symbolic storage out of
///      the proof entirely — storage read/write terms were the dominant cost in early
///      experiments and made the SMT solver stall.
contract MinRateHarness is MinRate {
    using ContextLib for Context;
    using CalldataPtrLib for CalldataPtr;

    /// @dev Stub dispatcher. Driven exactly once by the one-opcode program. Fills the
    ///      register the swap program is expected to compute (the zero one) from the value
    ///      the entrypoint stashed in `amountNetPulled`, and leaves the other register
    ///      untouched. Reads only memory — no storage access — to keep the proof cheap.
    function _dispatch(Context memory ctx, uint256, bytes calldata) internal {
        uint256 computed = ctx.swap.amountNetPulled;
        if (ctx.swap.amountIn == 0) {
            ctx.swap.amountIn = computed;
        } else {
            ctx.swap.amountOut = computed;
        }
    }

    // -----------------------------------------------------------------------
    // Pure helpers — no runLoop. Direction-routing logic, exposed directly.
    // -----------------------------------------------------------------------

    /// @notice Exposes `MinRateArgsBuilder.parse` so its token-ordering dependence can be
    ///         proven without involving the run loop.
    function parse(bytes calldata args, address tokenIn, address tokenOut)
        external
        pure
        returns (uint64 rateIn, uint64 rateOut)
    {
        return MinRateArgsBuilder.parse(args, tokenIn, tokenOut);
    }

    /// @notice Exposes `MinRateArgsBuilder.build` for roundtrip checks.
    function build(address tokenA, address tokenB, uint64 rateA, uint64 rateB)
        external
        pure
        returns (bytes memory)
    {
        return MinRateArgsBuilder.build(tokenA, tokenB, rateA, rateB);
    }

    // -----------------------------------------------------------------------
    // `_requireMinRate1D` — exact-in direction
    // -----------------------------------------------------------------------

    /// @notice Runs `_requireMinRate1D` with `amountIn` already set and a stubbed run loop
    ///         that fills `amountOut` with `computedAmountOut`.
    /// @dev   `stubProgram` is the one-opcode program (`hex"0000"`); it is passed through
    ///        calldata so the `CalldataPtr` correctly references the current call frame.
    function requireMinRateExactIn(
        uint256 amountIn,
        uint256 computedAmountOut,
        address tokenIn,
        address tokenOut,
        bytes calldata rateArgs,
        bytes calldata stubProgram
    ) external {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.swap.amountIn = amountIn;
        ctx.swap.amountOut = 0;
        ctx.swap.amountNetPulled = computedAmountOut;
        ctx.vm.nextPC = 0;
        ctx.vm.programPtr = CalldataPtrLib.from(stubProgram);
        ctx.vm.dispatch = _dispatch;

        _requireMinRate1D(ctx, rateArgs);
    }

    // -----------------------------------------------------------------------
    // `_requireMinRate1D` — exact-out direction
    // -----------------------------------------------------------------------

    /// @notice Runs `_requireMinRate1D` with `amountOut` already set and a stubbed run loop
    ///         that fills `amountIn` with `computedAmountIn`.
    function requireMinRateExactOut(
        uint256 amountOut,
        uint256 computedAmountIn,
        address tokenIn,
        address tokenOut,
        bytes calldata rateArgs,
        bytes calldata stubProgram
    ) external {
        Context memory ctx;
        ctx.query.isExactIn = false;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.swap.amountIn = 0;
        ctx.swap.amountOut = amountOut;
        ctx.swap.amountNetPulled = computedAmountIn;
        ctx.vm.nextPC = 0;
        ctx.vm.programPtr = CalldataPtrLib.from(stubProgram);
        ctx.vm.dispatch = _dispatch;

        _requireMinRate1D(ctx, rateArgs);
    }

    // -----------------------------------------------------------------------
    // `_requireMinRate1D` — precondition guard
    // -----------------------------------------------------------------------

    /// @notice Runs `_requireMinRate1D` with both registers non-zero, to exercise the
    ///         "amounts already computed" guard rather than the rate check.
    function requireMinRateBothSet(
        uint256 amountIn,
        uint256 amountOut,
        address tokenIn,
        address tokenOut,
        bytes calldata rateArgs,
        bytes calldata stubProgram
    ) external {
        Context memory ctx;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.swap.amountIn = amountIn;
        ctx.swap.amountOut = amountOut;
        ctx.vm.nextPC = 0;
        ctx.vm.programPtr = CalldataPtrLib.from(stubProgram);
        ctx.vm.dispatch = _dispatch;

        _requireMinRate1D(ctx, rateArgs);
    }

    // -----------------------------------------------------------------------
    // `_adjustMinRate1D` — exact-in direction
    // -----------------------------------------------------------------------

    /// @notice Runs `_adjustMinRate1D` exact-in; returns the resulting `amountOut`.
    function adjustMinRateExactIn(
        uint256 amountIn,
        uint256 computedAmountOut,
        address tokenIn,
        address tokenOut,
        bytes calldata rateArgs,
        bytes calldata stubProgram
    ) external returns (uint256 adjustedAmountOut) {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.swap.amountIn = amountIn;
        ctx.swap.amountOut = 0;
        ctx.swap.amountNetPulled = computedAmountOut;
        ctx.vm.nextPC = 0;
        ctx.vm.programPtr = CalldataPtrLib.from(stubProgram);
        ctx.vm.dispatch = _dispatch;

        _adjustMinRate1D(ctx, rateArgs);

        adjustedAmountOut = ctx.swap.amountOut;
    }

    // -----------------------------------------------------------------------
    // `_adjustMinRate1D` — exact-out direction
    // -----------------------------------------------------------------------

    /// @notice Runs `_adjustMinRate1D` exact-out; returns the resulting `amountIn`.
    function adjustMinRateExactOut(
        uint256 amountOut,
        uint256 computedAmountIn,
        address tokenIn,
        address tokenOut,
        bytes calldata rateArgs,
        bytes calldata stubProgram
    ) external returns (uint256 adjustedAmountIn) {
        Context memory ctx;
        ctx.query.isExactIn = false;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.swap.amountIn = 0;
        ctx.swap.amountOut = amountOut;
        ctx.swap.amountNetPulled = computedAmountIn;
        ctx.vm.nextPC = 0;
        ctx.vm.programPtr = CalldataPtrLib.from(stubProgram);
        ctx.vm.dispatch = _dispatch;

        _adjustMinRate1D(ctx, rateArgs);

        adjustedAmountIn = ctx.swap.amountIn;
    }
}
