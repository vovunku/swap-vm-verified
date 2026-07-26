// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Context } from "../../../src/libs/VM.sol";
import { XYCSwap } from "../../../src/instructions/XYCSwap.sol";

/// @notice External surface over XYCSwap's internal instruction, for symbolic execution.
/// @dev `Context` embeds an internal function pointer (`VM.dispatch`), so it is not
///      ABI-encodable and cannot be passed across an external call. The harness therefore
///      accepts the individual registers and assembles the `Context` in memory.
///
///      `ctx.vm` is left zero-initialised. `_xycSwapXD` reads only `ctx.query.isExactIn`
///      and `ctx.swap`, and never dispatches, so the null function pointer is never
///      invoked. Should a future instruction under test call `ctx.runLoop()`, this
///      harness shape is no longer valid for it.
///
///      ## Why `args` is not a parameter
///
///      `_xycSwapXD(Context memory, bytes calldata /* args */)` never reads its second
///      parameter — it is unnamed in the production source. Every property in
///      `XYCSwapSpec` passed the literal `""` at every call site, so the arguments were
///      already fixed to empty everywhere they were ever proven. Supplying
///      `msg.data[0:0]` — a concrete zero-length calldata slice — therefore states the
///      same theorems over the same domain, and removes a dynamic ABI-decoded parameter
///      from the proof surface.
///
///      It is also load-bearing for `--cse`. Kontrol 1.0.255 derives the summary target
///      from the AST type string via `arg_types.split()[1]`
///      (`kontrol/solc_to_k.py:1139-1140`), which takes the second whitespace-delimited
///      token as the whole argument list. Any reference-type parameter carries a data
///      location, so `function (uint256,uint256,uint256,bytes memory) external ...`
///      truncates to `(uint256,uint256,uint256,bytes` and the generated target matches
///      nothing — `--cse` aborts with `Test identifiers not found`. With no reference-type
///      parameter the type string has no interior space and the target resolves.
///      This is an upstream defect and should be reported; the harness is not shaped
///      around it, but it is unblocked by the same change.
contract XYCSwapHarness is XYCSwap {
    /// @notice Exact-input direction: the taker fixes `amountIn`, the VM computes `amountOut`.
    function exactIn(uint256 balanceIn, uint256 balanceOut, uint256 amountIn)
        external
        pure
        returns (uint256 amountOut)
    {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountIn = amountIn;

        _xycSwapXD(ctx, msg.data[0:0]);

        amountOut = ctx.swap.amountOut;
    }

    /// @notice Exact-output direction: the taker fixes `amountOut`, the VM computes `amountIn`.
    function exactOut(uint256 balanceIn, uint256 balanceOut, uint256 amountOut)
        external
        pure
        returns (uint256 amountIn)
    {
        Context memory ctx;
        ctx.query.isExactIn = false;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountOut = amountOut;

        _xycSwapXD(ctx, msg.data[0:0]);

        amountIn = ctx.swap.amountIn;
    }

    /// @notice Exact-input entry that leaves `amountOut` pre-populated, to exercise the
    ///         recompute guard rather than the pricing path.
    function exactInWithAmountOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut
    ) external pure returns (uint256) {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountIn = amountIn;
        ctx.swap.amountOut = amountOut;

        _xycSwapXD(ctx, msg.data[0:0]);

        return ctx.swap.amountOut;
    }
}
