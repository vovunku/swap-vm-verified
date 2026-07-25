// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Context, SwapRegisters } from "../../../src/libs/VM.sol";
import { XYCConcentrate, XYCConcentrateArgsBuilder, ONE } from "../../../src/instructions/XYCConcentrate.sol";

/// @notice External surface over XYCConcentrate's internal instruction (opcode 0x51), for
///         symbolic execution.
///
/// @dev `Context` embeds an internal function pointer (`VM.dispatch`), so it is not
///      ABI-encodable and cannot be passed across an external call. As in `XYCSwapHarness`,
///      the harness accepts the individual registers as scalars and assembles the `Context`
///      in memory. `_xycConcentrateGrowLiquidity2D` never calls `ctx.runLoop()`, so leaving
///      `ctx.vm` zero-initialised is safe here.
///
///      ## Three surfaces, three trust levels
///
///      `XYCConcentrate` is one monolithic internal function: liquidity reconstruction
///      (`XYCConcentrate.sol:125-141`) and pricing (`:143-159`) are welded together, and the
///      liquidity half runs `Math.mulDiv` five times. Every `mulDiv` calls `mulmod` inside
///      `Math.mul512`, which KEVM cannot currently collapse — see
///      `test/kontrol/analysis/FINDINGS.md`, "XYCConcentrate — blocked on mul512, not on
///      sqrt". Anything routed through the liquidity half is therefore not provable today.
///
///      The pricing half needs none of that: `:143-159` contains one `MUL`, one `DIV` and
///      one `Math.ceilDiv` per leg — exactly the `XYCSwap` shape that is already proven.
///      So the harness offers three entrypoints, in decreasing order of provability and
///      increasing order of fidelity:
///
///        1. `exactInLeg` / `exactOutLeg` — **LEG-LEVEL**. A line-for-line transcription of
///           `:143-159` with the two virtual reserves promoted to scalar parameters. The
///           only edits are `ctx.swap.` -> `swap.`, `ctx.query.isExactIn` -> `isExactIn`,
///           the two `virtualBalance*` locals becoming parameters, and a returned `clamped`
///           observation flag that records which branch was taken without changing any
///           arithmetic. `_computeL` is not called, not imported into the body, and cannot
///           be introduced by the compiler — these functions are the only place in the
///           harness where the pricing code appears without a preceding liquidity
///           reconstruction. Verified out of band by gas: `exactInLeg` costs a few hundred
///           gas, `full` costs thousands (`forge test --gas-report`).
///
///        2. `virtualReserves` — a transcription of `:125-141`, calling the **real**
///           `XYCConcentrateArgsBuilder._computeL`. Used to state orientation properties,
///           which are about which offset lands on which side and so cannot be expressed on
///           the scalar legs alone. Not provable today (mul512).
///
///        3. `full` — the **real** instruction, unmodified. Used for the recompute guards
///           and to ground surfaces 1 and 2 by differential testing. Not provable today
///           (mul512), but it is the only surface that is bytecode-faithful, so every
///           property stated on 1 or 2 should have a differential companion here.
///
///      Surface 1 is a copy, and a copy is a trust boundary. `XYCConcentrateSpec` closes it
///      with `test_diff_*`, which asserts `full(...)` and `exactInLeg(virtualReserves(...))`
///      agree register-for-register. Read that as part of the harness.
contract XYCConcentrateHarness is XYCConcentrate {
    // -----------------------------------------------------------------------
    // Surface 1 — LEG-LEVEL: the pricing legs, virtual reserves as scalars
    // -----------------------------------------------------------------------

    /// @notice Transcription of `XYCConcentrate.sol:143-159`.
    /// @dev Reproduced verbatim modulo the renamings documented on the contract. In
    ///      particular the rounding directions are untouched: the exact-in leg floors with
    ///      `/`, both partial-fill reconstructions ceil with `Math.ceilDiv`.
    ///
    ///      Note which registers are read. Of the balance registers only `balanceOut` is
    ///      touched — `balanceIn` is never read by `:143-159`, which is why it is absent
    ///      from the leg signatures. The clamp is a *partial fill*: it is what makes
    ///      `amountOut == balanceOut` reachable, and therefore what makes `cannotDrainPool`
    ///      false in the strict form that holds for `XYCSwap`.
    /// @param clamped True iff the partial-fill branch was taken (`:146` or `:153`).
    function _pricingLegs(
        bool isExactIn,
        SwapRegisters memory swap,
        uint256 virtualBalanceIn,
        uint256 virtualBalanceOut
    ) private pure returns (bool clamped) {
        if (isExactIn) {
            require(swap.amountOut == 0, ConcentrateRecomputeDetected(swap.amountIn, swap.amountOut));
            uint256 out = (swap.amountIn * virtualBalanceOut) / (virtualBalanceIn + swap.amountIn);
            if (out > swap.balanceOut) {
                clamped = true;
                out = swap.balanceOut;
                swap.amountIn = Math.ceilDiv(out * virtualBalanceIn, virtualBalanceOut - out);
            }
            swap.amountOut = out;
        } else {
            require(swap.amountIn == 0, ConcentrateRecomputeDetected(swap.amountIn, swap.amountOut));
            if (swap.amountOut > swap.balanceOut) {
                clamped = true;
                swap.amountOut = swap.balanceOut;
            }
            swap.amountIn = Math.ceilDiv(
                swap.amountOut * virtualBalanceIn,
                (virtualBalanceOut - swap.amountOut)
            );
        }
    }

    /// @notice Exact-input pricing leg with the virtual reserves supplied directly.
    /// @param amountOut Pre-populated output register, to exercise the recompute guard at
    ///        `:144`. Pass `0` for the ordinary path.
    function exactInLeg(
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 virtualBalanceIn,
        uint256 virtualBalanceOut
    ) external pure returns (SwapRegisters memory swap, bool clamped) {
        swap.balanceOut = balanceOut;
        swap.amountIn = amountIn;
        swap.amountOut = amountOut;

        clamped = _pricingLegs(true, swap, virtualBalanceIn, virtualBalanceOut);
    }

    /// @notice Exact-output pricing leg with the virtual reserves supplied directly.
    /// @param amountIn Pre-populated input register, to exercise the recompute guard at
    ///        `:152`. Pass `0` for the ordinary path.
    function exactOutLeg(
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 virtualBalanceIn,
        uint256 virtualBalanceOut
    ) external pure returns (SwapRegisters memory swap, bool clamped) {
        swap.balanceOut = balanceOut;
        swap.amountIn = amountIn;
        swap.amountOut = amountOut;

        clamped = _pricingLegs(false, swap, virtualBalanceIn, virtualBalanceOut);
    }

    // -----------------------------------------------------------------------
    // Surface 2 — liquidity reconstruction, for orientation properties
    // -----------------------------------------------------------------------

    /// @notice Transcription of `XYCConcentrate.sol:125-141`, calling the real `_computeL`.
    /// @dev Exists so that a spec can *observe* the two virtual reserves, which the real
    ///      instruction only ever uses as locals. The orientation properties — which token
    ///      role gets the `ONE / sqrtPriceMax` offset, which gets the `sqrtPriceMin / ONE`
    ///      offset, and which side gets `Math.Rounding.Ceil` — are statements about exactly
    ///      these locals and cannot be phrased on the scalar legs.
    /// @return liquidity `L`, the reconstructed liquidity.
    /// @return virtualBalanceIn Real `balanceIn` plus the input side's virtual offset.
    /// @return virtualBalanceOut Real `balanceOut` plus the output side's virtual offset.
    function virtualReserves(
        address tokenIn,
        address tokenOut,
        uint256 balanceIn,
        uint256 balanceOut,
        bytes calldata args
    ) external pure returns (uint256 liquidity, uint256 virtualBalanceIn, uint256 virtualBalanceOut) {
        (uint256 sqrtPriceMin, uint256 sqrtPriceMax) = XYCConcentrateArgsBuilder.parse2D(args);

        bool isTokenInLt = tokenIn < tokenOut;
        uint256 bLt = isTokenInLt ? balanceIn : balanceOut;
        uint256 bGt = isTokenInLt ? balanceOut : balanceIn;

        liquidity = XYCConcentrateArgsBuilder._computeL(bLt, bGt, sqrtPriceMin, sqrtPriceMax);

        if (isTokenInLt) {
            virtualBalanceIn = balanceIn + Math.mulDiv(liquidity, ONE, sqrtPriceMax, Math.Rounding.Ceil);
            virtualBalanceOut = balanceOut + Math.mulDiv(liquidity, sqrtPriceMin, ONE);
        } else {
            virtualBalanceIn = balanceIn + Math.mulDiv(liquidity, sqrtPriceMin, ONE, Math.Rounding.Ceil);
            virtualBalanceOut = balanceOut + Math.mulDiv(liquidity, ONE, sqrtPriceMax);
        }
    }

    // -----------------------------------------------------------------------
    // Surface 3 — the real instruction
    // -----------------------------------------------------------------------

    /// @notice The unmodified instruction, every register under the caller's control.
    /// @dev `args` must be at least 64 bytes: `parse2D` reads `bytes32(args)` and
    ///      `bytes32(args.slice(32))`, and the `Calldata.slice` overload it uses performs no
    ///      bounds checking. Specs build it with `abi.encodePacked(sqrtPriceMin, sqrtPriceMax)`.
    function full(
        address tokenIn,
        address tokenOut,
        bool isExactIn,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes calldata args
    ) external pure returns (SwapRegisters memory) {
        Context memory ctx;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.query.isExactIn = isExactIn;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountIn = amountIn;
        ctx.swap.amountOut = amountOut;

        _xycConcentrateGrowLiquidity2D(ctx, args);

        return ctx.swap;
    }
}
