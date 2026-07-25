// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Context, SwapRegisters } from "../../../src/libs/VM.sol";
import { BaseFeeAdjuster } from "../../../src/instructions/BaseFeeAdjuster.sol";

/// @notice External surface over BaseFeeAdjuster's internal instruction, for symbolic execution.
/// @dev `Context` embeds an internal function pointer (`VM.dispatch`), so it is not
///      ABI-encodable and cannot be passed across an external call. The harness therefore
///      accepts the individual registers and assembles the `Context` in memory.
///
///      `ctx.vm` is left zero-initialised. `_baseFeeAdjuster1D` reads only
///      `ctx.query.isExactIn` and `ctx.swap`, and never dispatches, so the null function
///      pointer is never invoked. Should a future instruction under test call
///      `ctx.runLoop()`, this harness shape is no longer valid for it.
///
///      Two departures from `XYCSwapHarness`, both forced by the instruction:
///
///      1. The entry points are `view`, not `pure`. `_baseFeeAdjuster1D` reads
///         `block.basefee`, which is the whole point of the instruction. Specs drive it
///         with `vm.fee(...)`, so the gas price is a symbolic input like any other.
///      2. Every register is taken in and every register is handed back, as a
///         `SwapRegisters` struct. BaseFeeAdjuster is a *post-swap adjuster*: it runs on
///         registers a previous instruction already populated, and it requires both
///         `amountIn` and `amountOut` to be non-zero. Returning the full register file
///         (which, unlike `Context`, is plain `uint256`s and so is ABI-encodable) is what
///         lets a spec state register isolation — that only the intended register moved.
contract BaseFeeAdjusterHarness is BaseFeeAdjuster {
    /// @notice Exact-input direction: the instruction raises `amountOut` in the taker's favour.
    function exactIn(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountNetPulled,
        bytes calldata args
    ) external view returns (SwapRegisters memory) {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountIn = amountIn;
        ctx.swap.amountOut = amountOut;
        ctx.swap.amountNetPulled = amountNetPulled;

        _baseFeeAdjuster1D(ctx, args);

        return ctx.swap;
    }

    /// @notice Exact-output direction: the instruction lowers `amountIn` in the taker's favour.
    function exactOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountNetPulled,
        bytes calldata args
    ) external view returns (SwapRegisters memory) {
        Context memory ctx;
        ctx.query.isExactIn = false;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountIn = amountIn;
        ctx.swap.amountOut = amountOut;
        ctx.swap.amountNetPulled = amountNetPulled;

        _baseFeeAdjuster1D(ctx, args);

        return ctx.swap;
    }
}
