// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;


import { Context, SwapRegisters } from "../../../src/libs/VM.sol";
import { PeggedSwap } from "../../../src/instructions/PeggedSwap.sol";

/// @notice External surface over PeggedSwap's internal instruction, for symbolic execution.
///
/// @dev `Context` embeds an internal function pointer (`VM.dispatch`), so it is not
///      ABI-encodable and cannot be passed across an external call. As in `XYCSwapHarness`,
///      the harness therefore accepts the individual registers as scalars and assembles the
///      `Context` in memory.
///
///      `ctx.vm` is left zero-initialised, which is safe here for the same reason it is safe
///      in `XYCSwapHarness`: `_peggedSwapGrowPriceRange2D` never calls `ctx.runLoop()` and
///      never dispatches, so the null function pointer is never invoked. It reads exactly
///      four context fields — `ctx.query.isExactIn`, `ctx.query.tokenIn`,
///      `ctx.query.tokenOut` (`PeggedSwap.sol:139-140`, consumed by
///      `PeggedSwapArgsBuilder.parseRatesAndBalances` at `:76-78`) and `ctx.swap` — so all
///      four are exposed as parameters. The token addresses matter: their *ordering*
///      selects which of `rateLt`/`rateGt` applies and which of `x0`/`y0` is the input-side
///      normaliser, which is a known vulnerability class in this codebase and the subject
///      of the direction-symmetry properties in the spec.
///
///      The whole `SwapRegisters` struct is returned rather than a single amount, so that
///      register-isolation properties (`amountNetPulled` untouched, balances not mutated)
///      are expressible.
contract PeggedSwapHarness is PeggedSwap {
    /// @notice `_peggedSwapGrowPriceRange2D` with every register and both token addresses
    ///         under the caller's control.
    /// @dev The fully general entry point. Use it when a property needs to observe or vary
    ///      a register the narrower wrappers pin to zero — in particular `amountNetPulled`,
    ///      and the "wrong" amount register that trips the recompute guards at
    ///      `PeggedSwap.sol:157` (exact-in) and `:194` (exact-out).
    function run(
        bool isExactIn,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountNetPulled,
        address tokenIn,
        address tokenOut,
        bytes calldata args
    )
        external
        pure
        returns (SwapRegisters memory)
    {
        Context memory ctx;
        ctx.query.isExactIn = isExactIn;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountIn = amountIn;
        ctx.swap.amountOut = amountOut;
        ctx.swap.amountNetPulled = amountNetPulled;

        _peggedSwapGrowPriceRange2D(ctx, args);

        return ctx.swap;
    }

    /// @notice Exact-input direction: the taker fixes `amountIn`, the VM computes `amountOut`.
    /// @dev `amountOut` and `amountNetPulled` enter as zero, i.e. the register state a
    ///      well-formed program presents to the instruction.
    function exactIn(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        address tokenIn,
        address tokenOut,
        bytes calldata args
    )
        external
        pure
        returns (SwapRegisters memory)
    {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountIn = amountIn;

        _peggedSwapGrowPriceRange2D(ctx, args);

        return ctx.swap;
    }

    /// @notice Exact-output direction: the taker fixes `amountOut`, the VM computes `amountIn`.
    /// @dev `amountIn` and `amountNetPulled` enter as zero.
    function exactOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountOut,
        address tokenIn,
        address tokenOut,
        bytes calldata args
    )
        external
        pure
        returns (SwapRegisters memory)
    {
        Context memory ctx;
        ctx.query.isExactIn = false;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountOut = amountOut;

        _peggedSwapGrowPriceRange2D(ctx, args);

        return ctx.swap;
    }
}
