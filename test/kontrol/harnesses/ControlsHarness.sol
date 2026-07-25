// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Context } from "../../../src/libs/VM.sol";
import { Controls } from "../../../src/instructions/Controls.sol";

/// @notice External surface over Controls' internal instructions, for symbolic execution.
/// @dev See XYCSwapHarness for why `Context` is assembled in memory rather than passed in.
///
///      Controls instructions touch only `ctx.vm.nextPC` and `ctx.query.{tokenIn,tokenOut,taker}`,
///      and never dispatch, so the null function pointer in `ctx.vm` is never invoked.
///
///      Each method takes the initial program counter as an explicit parameter. This is what
///      makes the "leaves nextPC untouched" branch of the conditional jumps observable: the
///      prover can witness that the value read back equals the value written in, for every
///      input where the guard does not fire.
contract ControlsHarness is Controls {
    /// @notice `_salt` is a declared no-op. Exposed only so the spec can pin that it touches
    ///         nothing — a future refactor that accidentally mutates state would break the
    ///         property rather than slip through silently.
    function salt(uint256 initialPC, bytes calldata args) external pure returns (uint256 nextPC) {
        Context memory ctx;
        ctx.vm.nextPC = initialPC;
        _salt(ctx, args);
        return ctx.vm.nextPC;
    }

    /// @notice `_jump` — unconditional jump to the 2-byte argument.
    function jump(uint256 initialPC, bytes calldata args) external pure returns (uint256 nextPC) {
        Context memory ctx;
        ctx.vm.nextPC = initialPC;
        _jump(ctx, args);
        return ctx.vm.nextPC;
    }

    /// @notice `_stop` — halts the run loop by moving the PC out of any reachable program.
    function stop(uint256 initialPC, bytes calldata args) external pure returns (uint256 nextPC) {
        Context memory ctx;
        ctx.vm.nextPC = initialPC;
        _stop(ctx, args);
        return ctx.vm.nextPC;
    }

    /// @notice `_revert` — always reverts; the spec checks the payload via `vm.expectRevert`.
    function revertInstruction(bytes calldata args) external pure {
        Context memory ctx;
        _revert(ctx, args);
    }

    /// @notice `_jumpIfDirection` — jumps iff the maker's expected direction matches the
    ///         taker's presented direction (`tokenIn < tokenOut`).
    function jumpIfDirection(
        uint256 initialPC,
        address tokenIn,
        address tokenOut,
        bytes calldata args
    ) external pure returns (uint256 nextPC) {
        Context memory ctx;
        ctx.vm.nextPC = initialPC;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        _jumpIfDirection(ctx, args);
        return ctx.vm.nextPC;
    }

    /// @notice `_jumpIfTokenIn` — jumps iff the args token matches `tokenIn`.
    function jumpIfTokenIn(
        uint256 initialPC,
        address tokenIn,
        bytes calldata args
    ) external pure returns (uint256 nextPC) {
        Context memory ctx;
        ctx.vm.nextPC = initialPC;
        ctx.query.tokenIn = tokenIn;
        _jumpIfTokenIn(ctx, args);
        return ctx.vm.nextPC;
    }

    /// @notice `_jumpIfTokenOut` — jumps iff the args token matches `tokenOut`.
    function jumpIfTokenOut(
        uint256 initialPC,
        address tokenOut,
        bytes calldata args
    ) external pure returns (uint256 nextPC) {
        Context memory ctx;
        ctx.vm.nextPC = initialPC;
        ctx.query.tokenOut = tokenOut;
        _jumpIfTokenOut(ctx, args);
        return ctx.vm.nextPC;
    }

    /// @notice `_deadline` — reverts iff `block.timestamp` exceeds the 5-byte deadline.
    ///         `view` because it reads `block.timestamp`; the spec controls the clock with
    ///         `vm.warp`.
    function deadline(address taker, bytes calldata args) external view {
        Context memory ctx;
        ctx.query.taker = taker;
        _deadline(ctx, args);
    }
}
