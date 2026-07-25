// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Context } from "../../../src/libs/VM.sol";
import { Balances } from "../../../src/instructions/Balances.sol";

/// @notice External surface over Balances' `_staticBalancesXD`, for symbolic execution.
/// @dev See XYCSwapHarness for why `Context` is assembled in memory rather than passed in.
///
///      `_staticBalancesXD` reads `ctx.query.tokenIn` / `ctx.query.tokenOut` to decide the
///      assignment direction, and reads `ctx.swap.balanceIn` / `ctx.swap.balanceOut` only for
///      the zero-balance guard. It never dispatches, so `ctx.vm` is left zero-initialised
///      and the null function pointer is never invoked.
///
///      The dynamic variant `_dynamicBalancesXD` is intentionally NOT exposed here: it does
///      SLOAD/SSTORE through the `balances` mapping and falls in tier 3 (see README.md).
///
///      Both the *incoming* register state and the *resulting* registers are surfaced. The
///      incoming pair exists solely to exercise the zero-balance guard — in particular to
///      prove that a second application is rejected rather than silently overwriting.
contract BalancesHarness is Balances {
    /// @notice Applies `_staticBalancesXD` and returns the resulting balance registers.
    /// @param incomingBalanceIn  Initial `ctx.swap.balanceIn`  — must be 0 to clear the guard.
    /// @param incomingBalanceOut Initial `ctx.swap.balanceOut` — must be 0 to clear the guard.
    /// @param args               64 bytes: two packed uint256 (`BalancesArgsBuilder.build`).
    function applyStatic(
        address tokenIn,
        address tokenOut,
        uint256 incomingBalanceIn,
        uint256 incomingBalanceOut,
        bytes calldata args
    ) external pure returns (uint256 balanceIn, uint256 balanceOut) {
        Context memory ctx;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.swap.balanceIn = incomingBalanceIn;
        ctx.swap.balanceOut = incomingBalanceOut;

        _staticBalancesXD(ctx, args);

        balanceIn = ctx.swap.balanceIn;
        balanceOut = ctx.swap.balanceOut;
    }
}
