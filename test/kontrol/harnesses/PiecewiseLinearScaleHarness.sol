// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Context, SwapRegisters } from "../../../src/libs/VM.sol";
import {
    PiecewiseLinearScale,
    PiecewiseLinearScaleArgsBuilder
} from "../../../src/instructions/PiecewiseLinearScale.sol";

/// @notice External surface over PiecewiseLinearScale's internal instructions, for symbolic
///         execution. Covers opcodes 0x98 (`PiecewiseLinearScaleBalanceIn`) and 0x99
///         (`PiecewiseLinearScaleBalanceOut`).
///
/// @dev `Context` embeds an internal function pointer (`VM.dispatch`), so it is not
///      ABI-encodable and cannot be passed across an external call. The harness therefore
///      accepts the individual registers and assembles the `Context` in memory.
///
///      `ctx.vm` is left zero-initialised, following `XYCSwapHarness`. That is safe here:
///      `_piecewiseLinearScaleBalanceIn1D` / `_piecewiseLinearScaleBalanceOut1D`
///      (PiecewiseLinearScale.sol:99-111) read only `ctx.swap.amountIn`,
///      `ctx.swap.amountOut` and the balance they write, and `_calcScaleNow` reads only the
///      `args` calldata slice and `block.timestamp`. Neither path reaches `ctx.runLoop()`
///      or `ctx.vm` at all, so the null dispatch pointer is never invoked. (Verified by
///      reading the instruction: there is no `runLoop`, `program`, `takerArgs`, `setNextPC`
///      or `tryChopTakerArgs` call anywhere in the file.)
///
///      Two departures from `XYCSwapHarness`, both forced by the instruction:
///
///      1. The instruction entry points are `view`, not `pure`. `_calcScaleNow` reads
///         `block.timestamp` (PiecewiseLinearScale.sol:131), which is the whole point of a
///         time-based schedule. Specs drive it with `vm.warp(...)`, so "now" is a symbolic
///         input like any other.
///      2. Every register is taken in and every register is handed back, as a
///         `SwapRegisters` struct (plain `uint256`s, so ABI-encodable unlike `Context`).
///         That is what lets a spec state register isolation — that 0x98 moved `balanceIn`
///         and nothing else, and 0x99 moved `balanceOut` and nothing else.
///
///      `args` is the last parameter of every entry point. This matters: the arg parsers
///      (`parsePointScale`, `parseIntervalDuration`) are raw `calldataload`s with no bounds
///      check, so a malformed args block reads past `args.length`. With `args` last, those
///      reads land in ABI padding or past `calldatasize` and yield zero, which is the same
///      thing they would yield in a program whose trailing bytes are zero. It is *not* what
///      they yield inside the real VM, where `args` is a slice of the maker's program and
///      the bytes read are the following instructions — see `MinRateSpec`'s
///      `test_args_lengthIsNotValidated` for the same caveat.
contract PiecewiseLinearScaleHarness is PiecewiseLinearScale {
    /// @dev The scale basis, `2 ** 24`. `_calcScaleNow` returns a value `S` in `[1, 2**24]`
    ///      and the instruction computes `balance * S >> 24`.
    uint256 internal constant SCALE_ONE = 1 << 24;

    /// @notice Opcode 0x98 — shrink `balanceIn` by the current scale.
    function scaleBalanceIn(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountNetPulled,
        bytes calldata args
    ) external view returns (SwapRegisters memory) {
        Context memory ctx;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountIn = amountIn;
        ctx.swap.amountOut = amountOut;
        ctx.swap.amountNetPulled = amountNetPulled;

        _piecewiseLinearScaleBalanceIn1D(ctx, args);

        return ctx.swap;
    }

    /// @notice Opcode 0x99 — shrink `balanceOut` by the current scale.
    function scaleBalanceOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountNetPulled,
        bytes calldata args
    ) external view returns (SwapRegisters memory) {
        Context memory ctx;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountIn = amountIn;
        ctx.swap.amountOut = amountOut;
        ctx.swap.amountNetPulled = amountNetPulled;

        _piecewiseLinearScaleBalanceOut1D(ctx, args);

        return ctx.swap;
    }

    /// @notice The current scale factor `S`, recovered exactly.
    /// @dev `_calcScaleNow` is `private`, so it cannot be exposed directly. It does not have
    ///      to be: feeding `balanceIn = 2**24` through opcode 0x98 gives
    ///      `(2**24 * S) >> 24`, and since `S <= 2**24` the product is at most `2**48` — no
    ///      truncation on the multiply, and the shift is the exact inverse of the factor.
    ///      So the returned balance *is* `S`, bit for bit, with no rounding loss. This turns
    ///      every claim about the scale into a claim about a balance, over the real
    ///      instruction bytecode rather than a re-implementation.
    ///
    ///      Both amount registers are left at zero, so the ordering guard at
    ///      PiecewiseLinearScale.sol:100 always passes and this entry point exercises only
    ///      the schedule arithmetic.
    function scaleOf(bytes calldata args) external view returns (uint256 scale) {
        Context memory ctx;
        ctx.swap.balanceIn = SCALE_ONE;

        _piecewiseLinearScaleBalanceIn1D(ctx, args);

        return ctx.swap.balanceIn;
    }

    /// @notice `PiecewiseLinearScaleArgsBuilder.scaleValue` — `value * (scale + 1) >> 24`.
    /// @dev Loop-free and `pure`; the cheapest surface in this harness.
    function scaleValue(uint256 value, uint24 scale) external pure returns (uint256) {
        return PiecewiseLinearScaleArgsBuilder.scaleValue(value, scale);
    }

    /// @notice `PiecewiseLinearScaleArgsBuilder.unscaleValue` — `((value << 24) + scale) / (scale + 1)`.
    function unscaleValue(uint256 value, uint24 scale) external pure returns (uint256) {
        return PiecewiseLinearScaleArgsBuilder.unscaleValue(value, scale);
    }
}
