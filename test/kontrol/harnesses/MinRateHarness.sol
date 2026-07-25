// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { CalldataPtrLib } from "@1inch/solidity-utils/contracts/libraries/CalldataPtr.sol";

import { Context, SwapRegisters } from "../../../src/libs/VM.sol";
import { MinRate } from "../../../src/instructions/MinRate.sol";

/// @notice External surface over MinRate's internal instructions, for symbolic execution.
///
/// @dev `Context` embeds an internal function pointer (`VM.dispatch`), so it is not
///      ABI-encodable and cannot be passed across an external call. As in
///      `XYCSwapHarness` / `LimitSwapHarness`, the harness therefore accepts the
///      individual registers as scalars and assembles the `Context` in memory.
///
///      MinRate is the first instruction under verification that **does** call
///      `ctx.runLoop()`, so — unlike the earlier harnesses — `ctx.vm` cannot be left
///      zero-initialised: `runLoop` would jump through a null function pointer. This
///      harness therefore wires `ctx.vm` up for real:
///
///        * `ctx.vm.programPtr` points at the `program` calldata argument;
///        * `ctx.vm.dispatch` is bound to `_writeSwapAmounts`, a stub instruction that
///          writes the two swap amounts carried in its `args` straight into the registers.
///
///      The stub stands in for "whatever the rest of the maker's program computed".
///      Because the harness controls the program bytes, `runLoop`'s return value
///      `(swapAmountIn, swapAmountOut)` becomes a free symbolic pair, which is exactly
///      the input MinRate's rate comparison consumes. Modelling the inner program this
///      way keeps the proof about MinRate rather than about the run loop, while still
///      exercising the real `runLoop` code path.
///
///      There is exactly one function of `dispatch`'s type in this contract, so the
///      indirect jump has a single concrete destination and the prover does not have to
///      branch over jump targets (see test/kontrol/README.md, "Scope").
///
///      The expected `program` encoding is one instruction, 66 bytes:
///
///        byte  0      opcode (ignored by the stub)
///        byte  1      args length, must be 0x40
///        bytes 2..33  swapAmountIn
///        bytes 34..65 swapAmountOut
///
///      MinRate compares `ctx.query.tokenIn < ctx.query.tokenOut` to decide which of the
///      two rates in `args` applies, so the token addresses are exposed as parameters.
///      Specs targeting the direction-dependent rate selection must vary them.
contract MinRateHarness is MinRate {
    /// @notice Stub instruction standing in for the rest of the maker's program.
    /// @dev Bound to `ctx.vm.dispatch`; `runLoop` invokes it once per program instruction.
    ///      Leaves `nextPC` alone so the run loop advances normally, and touches no
    ///      register other than the two amounts, so register-isolation properties stated
    ///      about the harness are properties of MinRate itself.
    function _writeSwapAmounts(Context memory ctx, uint256, bytes calldata args) internal pure {
        ctx.swap.amountIn = uint256(bytes32(args[0:32]));
        ctx.swap.amountOut = uint256(bytes32(args[32:64]));
    }

    /// @dev Wires the VM half of the context: the program to run and the dispatcher.
    function _bootstrap(Context memory ctx, bytes calldata program) private pure {
        ctx.vm.programPtr = CalldataPtrLib.from(program);
        ctx.vm.dispatch = _writeSwapAmounts;
    }

    // -----------------------------------------------------------------------
    // 0xb0 — RequireMinRate
    // -----------------------------------------------------------------------

    /// @notice `_requireMinRate1D` with both amount registers under the caller's control.
    /// @dev Pass `amountIn == 0` and `amountOut == 0` for the ordinary path; a non-zero
    ///      pair exercises the `MinRateExpectedBeforeSwapAmountsComputed` guard.
    ///      `isExactIn` is not a parameter because `_requireMinRate1D` never reads it.
    function requireMinRate(
        uint256 amountIn,
        uint256 amountOut,
        address tokenIn,
        address tokenOut,
        bytes calldata args,
        bytes calldata program
    ) external returns (SwapRegisters memory) {
        Context memory ctx;
        _bootstrap(ctx, program);
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.swap.amountIn = amountIn;
        ctx.swap.amountOut = amountOut;

        _requireMinRate1D(ctx, args);

        return ctx.swap;
    }

    /// @notice `_requireMinRate1D` entered with the balance registers populated, so that a
    ///         spec can observe whether the instruction leaves them alone.
    function requireMinRateWithBalances(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountNetPulled,
        address tokenIn,
        address tokenOut,
        bytes calldata args,
        bytes calldata program
    ) external returns (SwapRegisters memory) {
        Context memory ctx;
        _bootstrap(ctx, program);
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountNetPulled = amountNetPulled;

        _requireMinRate1D(ctx, args);

        return ctx.swap;
    }

    // -----------------------------------------------------------------------
    // 0xb1 — AdjustMinRate
    // -----------------------------------------------------------------------

    /// @notice `_adjustMinRate1D` with both amount registers under the caller's control.
    /// @dev The pre-run register values matter here in a way they do not for the guard
    ///      variant: the clamp divides the *pre-`runLoop`* `amountIn` (exact-in) or
    ///      `amountOut` (exact-out), not the amounts `runLoop` returned.
    function adjustMinRate(
        bool isExactIn,
        uint256 amountIn,
        uint256 amountOut,
        address tokenIn,
        address tokenOut,
        bytes calldata args,
        bytes calldata program
    ) external returns (SwapRegisters memory) {
        Context memory ctx;
        _bootstrap(ctx, program);
        ctx.query.isExactIn = isExactIn;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.swap.amountIn = amountIn;
        ctx.swap.amountOut = amountOut;

        _adjustMinRate1D(ctx, args);

        return ctx.swap;
    }

    /// @notice `_adjustMinRate1D` entered with the balance registers populated.
    /// @param amount Goes into `amountIn` when `isExactIn`, into `amountOut` otherwise —
    ///        i.e. the taker-fixed leg, which is the leg the clamp reads.
    function adjustMinRateWithBalances(
        bool isExactIn,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amount,
        uint256 amountNetPulled,
        address tokenIn,
        address tokenOut,
        bytes calldata args,
        bytes calldata program
    ) external returns (SwapRegisters memory) {
        Context memory ctx;
        _bootstrap(ctx, program);
        ctx.query.isExactIn = isExactIn;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountNetPulled = amountNetPulled;
        if (isExactIn) {
            ctx.swap.amountIn = amount;
        } else {
            ctx.swap.amountOut = amount;
        }

        _adjustMinRate1D(ctx, args);

        return ctx.swap;
    }
}
