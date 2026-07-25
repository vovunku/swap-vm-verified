// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test, console } from "forge-std/Test.sol";

import { Context } from "../../../../src/libs/VM.sol";
import { PeggedSwap } from "../../../../src/instructions/PeggedSwap.sol";

/// @notice Executed witness for the exact-in `Panic(0x11)` overflow in `PeggedSwap`, and the
///         reachability measurement that decides how much it matters.
///
/// @dev     forge test --match-path test/kontrol/analysis/repro/PeggedSwapOverflowRepro.t.sol -vv
///
///      ## The defect
///
///      Exact-in normalises the post-trade input reserve twice:
///
///          :163   u1 = x1 * ONE / x0_init          // overflows if x1        > 2**256/ONE
///          :167   Math.sqrt(u1 * ONE) + ...        // overflows if u1        > 2**256/ONE
///
///      Both multiplications are checked and neither is guarded. The instruction *has* a
///      designed answer for an oversized input — the capacity check at `:173` caps `x1` at
///      `uMax` and drains the output reserve — but these two multiplications happen first,
///      so for a large enough `amountIn` the graceful clamp is never reached and the caller
///      gets a bare `Panic(0x11)` instead.
///
///      ## Correction to the ledger
///
///      `BUGS.md` attributed this to `:167` alone. That is only true for `x0_init < ONE`.
///      Which line overflows first depends on the normaliser:
///
///        * `x0_init < ONE = 1e27` — `:167` fires first, at `x1 > (2**256/ONE) * x0_init/ONE`
///          `≈ 1.16e23 * x0_init`.
///        * `x0_init >= ONE` — the division at `:163` has already shrunk `u1`, so `:163`'s own
///          product `x1 * ONE` overflows first, at `x1 > 2**256/ONE ≈ 1.16e50`.
///
///      Measured smallest power-of-ten `amountIn` that reverts, balanced pool:
///
///        | `x0_init` | 1e18 | 1e21 | 1e24 | 1e26 | 1e27 | 1e28 | 1e30 |
///        |-----------|------|------|------|------|------|------|------|
///        | `amountIn`| 1e42 | 1e45 | 1e48 | 1e50 | 1e51 | 1e51 | 1e51 |
///
///      which matches `1.16e23 * x0_init` on the left of the crossover and a flat `1.16e50`
///      on the right.
///
///      ## Reachability
///
///      The `BUGS.md` witness (`x0 = y0 = 1`, `amountIn = 1e24`) reproduces, but only because
///      a 1-wei normaliser is the most amplifying configuration possible. At any normaliser a
///      maker would actually use, `amountIn` has to exceed `1e44`+ wei — beyond the total
///      supply of any deployed ERC20 by ten orders of magnitude or more.
///
///      It is still reachable, because nothing checks the taker's `amount` against their
///      balance before the program runs: `SwapVM` writes it straight into `ctx.swap.amountIn`
///      and calls `runLoop`. So a `quote()` probe, or a swap that would have failed at the
///      transfer anyway, hits the panic. That makes it a quoting-robustness defect — the
///      caller cannot distinguish "over capacity" from "arithmetic fault" — and self-inflicted
///      in every case. No third party can push another party's `amountIn` to these values.
contract PeggedSwapOverflowRepro is Test, PeggedSwap {
    address internal constant TOKEN_LO = address(0x1111);
    address internal constant TOKEN_HI = address(0x2222);

    function exactIn(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        bytes calldata args
    ) external pure returns (uint256 amountOut) {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.query.tokenIn = TOKEN_LO;
        ctx.query.tokenOut = TOKEN_HI;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountIn = amountIn;
        _peggedSwapGrowPriceRange2D(ctx, args);
        amountOut = ctx.swap.amountOut;
    }

    function _args(uint256 x0, uint256 y0, uint256 a) internal pure returns (bytes memory) {
        return abi.encodePacked(x0, y0, a, uint256(1), uint256(1));
    }

    /// @notice The ledger's witness, re-executed: a 1-wei normaliser and `amountIn = 1e24`.
    function test_repro_ledgerWitnessPanics() public {
        (bool ok, bytes memory err) =
            address(this).staticcall(abi.encodeCall(this.exactIn, (1, 1, 1e24, _args(1, 1, 0))));

        assertFalse(ok, "expected a revert");
        assertEq(bytes4(err), bytes4(0x4e487b71), "expected Panic(uint256)");
        uint256 code;
        assembly {
            code := mload(add(err, 0x24))
        }
        assertEq(code, 0x11, "expected Panic(0x11), arithmetic overflow");
    }

    /// @notice The graceful path exists and works — right up until the multiplication overflows.
    /// @dev This is what makes it a defect rather than a domain limit: the same call one
    ///      order of magnitude smaller does exactly the right thing (drain and recompute).
    function test_repro_clampWorksJustBelowTheThreshold() public view {
        bytes memory args = _args(1, 1, 0);

        // x1 <= ~1.16e23 -> no overflow, capacity check fires, output reserve drains.
        uint256 out = this.exactIn(1, 1, 1e23, args);
        assertEq(out, 1, "over-capacity input drains the 1-wei output reserve");
    }

    /// @notice Reachability: at a normaliser a maker would plausibly use, the threshold is
    ///         far beyond any real token supply.
    function test_repro_realisticNormaliserNeedsAbsurdAmountIn() public view {
        bytes memory args = _args(1e21, 1e21, 100e27);

        // 1e33 wei is roughly the largest total supply of any deployed 18-decimal ERC20.
        uint256 out = this.exactIn(1e21, 1e21, 1e33, args);
        assertGt(out, 0, "an input larger than any real token supply still prices cleanly");

        // The panic needs ~1e44.
        (bool ok,) = address(this).staticcall(abi.encodeCall(this.exactIn, (1e21, 1e21, 1e45, args)));
        assertFalse(ok, "1e45 does overflow, but nothing on chain holds 1e45 wei");
    }

    /// @notice Pins the crossover between the `:167` and `:163` overflow sites.
    function test_repro_thresholdScalesThenSaturates() public view {
        assertEq(_smallestRevertingPowerOfTen(1e18), 42, "x0_init < ONE: threshold tracks x0_init");
        assertEq(_smallestRevertingPowerOfTen(1e21), 45, "");
        assertEq(_smallestRevertingPowerOfTen(1e24), 48, "");
        assertEq(_smallestRevertingPowerOfTen(1e27), 51, "at x0_init = ONE the two sites coincide");
        assertEq(_smallestRevertingPowerOfTen(1e28), 51, "x0_init > ONE: :163 saturates the threshold");
        assertEq(_smallestRevertingPowerOfTen(1e30), 51, "");
    }

    function _smallestRevertingPowerOfTen(uint256 X) internal view returns (uint256) {
        bytes memory args = _args(X, X, 0);
        for (uint256 f = 18; f <= 77; ++f) {
            (bool ok,) = address(this).staticcall(abi.encodeCall(this.exactIn, (X, X, 10 ** f, args)));
            if (!ok) return f;
        }
        return 0;
    }
}
