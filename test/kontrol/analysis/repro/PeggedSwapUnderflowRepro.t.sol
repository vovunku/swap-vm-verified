// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Context } from "../../../../src/libs/VM.sol";
import { PeggedSwap } from "../../../../src/instructions/PeggedSwap.sol";

/// @notice Standalone reproducer for the unguarded `Panic(0x11)` underflows in `PeggedSwap`,
///         together with the measurement of how far a real caller has to go to reach one.
///
/// @dev Self-contained: depends only on `src/`, not on the Kontrol harnesses, so it can be
///      dropped into a clean checkout and run with
///
///          forge test --match-path test/kontrol/analysis/repro/PeggedSwapUnderflowRepro.t.sol -vv
///
///      ## The defect
///
///      Two sites reconstruct the post-trade input reserve and subtract the pre-trade one with
///      a **checked** subtraction:
///
///          :179   Math.ceilDiv(x1Capped - x0, rateIn)     // exact-in, capacity/drain path
///          :215   Math.ceilDiv(x1 - x0, rateIn)           // exact-out
///
///      In both cases the larger operand has been round-tripped through the normalised
///      `u` domain:
///
///          x0  ->  u  = x0 * ONE / x0_init      (floor, PeggedSwapMath.sol:47)
///          u   ->  u' = solve(...)              (two floors, PeggedSwapMath.sol:100 and :103)
///          u'  ->  x1 = ceilDiv(u' * x0_init, ONE)
///
///      That round trip is not expansive. When `x0_init` exceeds `ONE = 1e27`, one `u`-ulp is
///      worth `x0_init / ONE` wei of `x0` — more than the single reconstructing `ceilDiv` can
///      add back — so `x1 < x0` is reachable and the subtraction reverts with a bare
///      `Panic(0x11)`, not a named SwapVM error.
///
///      ## Exact arithmetic at the `:215` witness
///
///      With `x0_init = y0_init = 1e30`, `linearWidth = 0`, `rateLt = rateGt = 1`,
///      `balanceIn = 1e30 + 1`, `balanceOut = 1`, `amountOut = 1`, `tokenIn < tokenOut`:
///
///        | quantity                        | value                                  |
///        |---------------------------------|----------------------------------------|
///        | `x0 = balanceIn * rateIn`        | `1e30 + 1`                             |
///        | `u  = x0 * ONE / x0_init`        | `1e27`  <- the `+1` truncates away     |
///        | `v  = y0 * ONE / y0_init`        | `0`                                    |
///        | `C  = invariantFromReserves(..)` | `1e27`                                 |
///        | `y1 = y0 - amountOut * rateOut`  | `0`                                    |
///        | `v1`, `invariantV1`              | `0`, `0`                               |
///        | `rightSide = C - invariantV1`    | `1e27`                                 |
///        | `u' = solve(1e27, 0)`            | `1e27`                                 |
///        | `x1 = ceilDiv(u' * x0_init, ONE)`| `1e30`                                 |
///        | **`x1 - x0`**                    | **`-1`  -> Panic(0x11)**               |
///
///      One `u`-ulp here is `x0_init / ONE = 1000` wei, so the single extra wei in `balanceIn`
///      is invisible to `u` and is lost. At `balanceIn = 1e30` exactly the same path gives
///      `x1 - x0 = 0`, `amountIn = 0`, bumped to `1` by the guard at `:218-220`, and the call
///      succeeds. The underflow is exactly one wei deep.
///
///      ## How far a caller has to go — measured, not assumed
///
///      This is the part that decides how much the finding is worth, and it was missing from
///      the first version of this file. Three measurements, all pinned as tests below:
///
///      * **`x0_init` must exceed `ONE`.** Nothing underflows at or below `1e26`; the first
///        failures appear around `3e26`. Below that a `u`-ulp is worth less than a wei and the
///        reconstructing `ceilDiv` covers the loss. The repo's own fixture sits at `1e21`
///        (`test/invariants/pegged/BalancedCurve.t.sol:17-18`).
///
///      * **The failing exact-out requests are dust.** On a pool at `(x0_init + 1, x0_init)`
///        with `A = 100e27`, the smallest `amountOut` that prices successfully is
///        `~10 * x0_init / ONE` wei — ten `u`-ulps. Everything above that is fine:
///
///          | `x0_init` | smallest `amountOut` that works |
///          |-----------|---------------------------------|
///          | `1e28`    | `1e2`                           |
///          | `1e29`    | `1e3`                           |
///          | `1e30`    | `1e4`                           |
///
///        At `1e30` the entire reverting window is `amountOut < 1e4` wei out of a `1e30` wei
///        reserve — a relative size of `1e-26`. A balanced pool with any economically
///        meaningful request never reverts, at any normaliser or any `A`.
///
///      * **The `:179` site needs an exhausted output reserve.** Exact-in underflows only when
///        `balanceOut * ONE / y0_init == 0`, i.e. when the output reserve has fallen below one
///        `u`-ulp. There it reverts for *every* `amountIn`, including one wei. At `x0_init = 1e28`
///        that means `balanceOut <= 9`; at `balanceOut >= 16` the same call succeeds.
///
///      * **Rate scaling protects rather than amplifies.** With a 6-vs-18-decimal pair
///        (`rateLt = 1e12`), the final `ceilDiv(..., rateIn)` divides the lost wei away. A sweep
///        of raw balances from `1e6` to `1e18` — normalisers of `1e18` up to `1e30` — produces
///        no underflow at all.
///
///      ## Verdict
///
///      Reachable, discontinuous in a single wei, and confined to dust-sized requests on pools
///      whose normaliser is nine orders of magnitude above the repo's own fixture, or to pools
///      whose output reserve is already exhausted. Programs are maker-signed, so this is maker
///      self-harm rather than a taker attack: the order is silently unquotable for small
///      exact-out amounts while appearing healthy. The one integration hazard worth naming is
///      that routers commonly probe an unknown pool with a dust amount, and such a probe gets
///      an unattributable arithmetic panic rather than a price.
///
///      ## Note on provenance, worth recording because it nearly went the other way
///
///      A Kontrol proof of this witness FAILED, which looked at first like evidence against the
///      finding. It was not. The spec declared its error selectors `immutable`, and
///      `run-constructor = false` makes immutables read as zero under Kontrol, so the selector
///      comparison failed while the revert itself reproduced exactly. **A failing proof is not
///      evidence against a bug until you have read why it failed.**
contract PeggedSwapUnderflowRepro is Test, PeggedSwap {
    address internal constant TOKEN_LO = address(0x1111);
    address internal constant TOKEN_HI = address(0x2222);

    /// @dev Minimal external surface over the internal instruction. `PeggedSwap` never calls
    ///      `ctx.runLoop()`, so leaving `ctx.vm` zero-initialised is safe here — the null
    ///      dispatch pointer is never invoked.
    function exactOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountOut,
        address tokenIn,
        address tokenOut,
        bytes calldata args
    ) external pure returns (uint256 amountIn) {
        Context memory ctx;
        ctx.query.isExactIn = false;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountOut = amountOut;

        _peggedSwapGrowPriceRange2D(ctx, args);

        amountIn = ctx.swap.amountIn;
    }

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

    function _args() internal pure returns (bytes memory) {
        // x0, y0, linearWidth, rateLt, rateGt
        return abi.encodePacked(uint256(1e30), uint256(1e30), uint256(0), uint256(1), uint256(1));
    }

    function _args(uint256 x0, uint256 y0, uint256 a) internal pure returns (bytes memory) {
        return abi.encodePacked(x0, y0, a, uint256(1), uint256(1));
    }

    function _panicCode(bytes memory err) internal pure returns (uint256 code) {
        if (bytes4(err) != bytes4(0x4e487b71)) return type(uint256).max;
        assembly {
            code := mload(add(err, 0x24))
        }
    }

    // ------------------------------------------------------------------ the defect, at :215

    /// @notice The defect: an exact-out quote reverts with a bare arithmetic panic.
    function test_repro_exactOutPanicsOnOneExtraWei() public {
        bytes memory args = _args();

        (bool ok, bytes memory err) = address(this).staticcall(
            abi.encodeCall(this.exactOut, (1e30 + 1, 1, 1, TOKEN_LO, TOKEN_HI, args))
        );

        assertFalse(ok, "expected the call to revert");
        assertEq(bytes4(err), bytes4(0x4e487b71), "expected Panic(uint256)");
        assertEq(_panicCode(err), 0x11, "expected Panic(0x11), arithmetic underflow");
    }

    /// @notice The boundary: one wei less on the input balance and the same call succeeds.
    /// @dev This is what makes it a defect rather than a documented domain limit — the failure
    ///      is discontinuous in a single wei of a maker-supplied balance.
    function test_repro_oneWeiLessSucceeds() public view {
        uint256 amountIn = this.exactOut(1e30, 1, 1, TOKEN_LO, TOKEN_HI, _args());
        assertEq(amountIn, 1, "at 1e30 the quote succeeds and is bumped to one wei");
    }

    /// @notice Realistic pool sizes are unaffected, which is why fuzzing at default scales
    ///         never finds this.
    function test_repro_realisticNormaliserIsUnaffected() public view {
        bytes memory args = _args(1e21, 1e21, 0);
        uint256 amountIn = this.exactOut(1e21 + 1, 1, 1, TOKEN_LO, TOKEN_HI, args);
        assertGt(amountIn, 0, "a 1e21 normaliser prices without reverting");
    }

    // ------------------------------------------------------- the second site, at :179

    /// @notice The exact-in capacity path has the same underflow, and there it fires for every
    ///         input amount rather than only for dust.
    /// @dev `balanceOut = 1` with `y0_init = 1e28` gives `v == 0`, so the capacity check at
    ///      `:173` always trips and `:179` computes `x1Capped - x0` with `x1Capped < x0`.
    function test_repro_exactInDrainPathAlsoUnderflows() public {
        bytes memory args = _args(1e28, 1e28, 0);

        uint256[4] memory amounts = [uint256(1), 1e18, 1e28, 2e28];
        for (uint256 i = 0; i < 4; ++i) {
            (bool ok, bytes memory err) =
                address(this).staticcall(abi.encodeCall(this.exactIn, (1e28 + 1, 1, amounts[i], args)));
            assertFalse(ok, "every exact-in amount reverts once the output reserve is exhausted");
            assertEq(_panicCode(err), 0x11, "Panic(0x11) at :179");
        }
    }

    /// @notice ...and stops as soon as the output reserve is worth at least one `u`-ulp.
    function test_repro_exactInDrainPathRecoversAboveOneUlp() public view {
        bytes memory args = _args(1e28, 1e28, 0);
        // one u-ulp is 1e28 / 1e27 == 10 wei of y; below that v floors to zero.
        uint256 out = this.exactIn(1e28 + 1, 16, 1e29, args);
        assertEq(out, 16, "a 16-wei output reserve drains cleanly instead of panicking");
    }

    // ------------------------------------------------------------------- reachability

    /// @notice `x0_init` must exceed `ONE` before anything can go wrong.
    function test_repro_thresholdIsAroundONE() public view {
        for (uint256 e = 18; e <= 26; ++e) {
            assertEq(_failuresNear(10 ** e), 0, "clean at and below 1e26");
        }
        assertGt(_failuresNear(1e28), 0, "1e28 is dirty");
    }

    /// @notice The reverting exact-out window is roughly ten `u`-ulps wide — dust, and nothing
    ///         but dust.
    function test_repro_onlyDustSizedRequestsRevert() public view {
        assertEq(_smallestOkAmountOut(1e28, 100e27), 1e2, "1e28 normaliser: everything from 100 wei up works");
        assertEq(_smallestOkAmountOut(1e29, 100e27), 1e3, "");
        assertEq(_smallestOkAmountOut(1e30, 100e27), 1e4, "");
    }

    /// @notice An economically meaningful trade never reverts, at any normaliser or width.
    function test_repro_meaningfulTradesNeverRevert() public view {
        for (uint256 e = 18; e <= 30; ++e) {
            uint256 X = 10 ** e;
            for (uint256 i = 1; i <= 8; ++i) {
                uint256 bIn = X + (X / 100) * i;
                uint256 bOut = X - (X / 100) * i;
                // requests from 0.1% to 0.4% of the output reserve
                for (uint256 j = 1; j <= 4; ++j) {
                    (bool ok,) = address(this).staticcall(
                        abi.encodeCall(this.exactOut, (bIn, bOut, (bOut / 1000) * j, TOKEN_LO, TOKEN_HI, _args(X, X, 100e27)))
                    );
                    assertTrue(ok, "a displaced pool prices ordinary requests at every scale");
                }
            }
        }
    }

    /// @notice Rate multipliers absorb the lost wei rather than amplifying it, so a
    ///         6-vs-18-decimal pair is immune even at a `1e30` normaliser.
    function test_repro_rateScalingIsNotAnAmplifier() public view {
        for (uint256 e = 6; e <= 18; ++e) {
            uint256 raw = 10 ** e; // raw 6-decimal balance
            uint256 X = raw * 1e12; // normaliser in the common scale, up to 1e30
            bytes memory args = abi.encodePacked(X, X, uint256(100e27), uint256(1e12), uint256(1));
            for (uint256 k = 0; k < 16; ++k) {
                (bool ok,) = address(this).staticcall(
                    abi.encodeCall(this.exactOut, (raw + k, raw, 1, TOKEN_LO, TOKEN_HI, args))
                );
                assertTrue(ok, "rateIn divides the lost wei away");
            }
        }
    }

    // ---------------------------------------------------------------------- helpers

    /// @dev Failures over a small band of `balanceIn` values just above the normaliser.
    function _failuresNear(uint256 X) internal view returns (uint256 fails) {
        for (uint256 k = 0; k < 32; ++k) {
            (bool ok,) = address(this).staticcall(
                abi.encodeCall(this.exactOut, (X + k, X, 1, TOKEN_LO, TOKEN_HI, _args(X, X, 0)))
            );
            if (!ok) ++fails;
        }
    }

    /// @dev Smallest power-of-ten `amountOut` that prices without reverting.
    function _smallestOkAmountOut(uint256 X, uint256 a) internal view returns (uint256) {
        bytes memory args = _args(X, X, a);
        for (uint256 f = 0; f <= 30; ++f) {
            uint256 amt = 10 ** f;
            if (amt > X) break;
            (bool ok,) =
                address(this).staticcall(abi.encodeCall(this.exactOut, (X + 1, X, amt, TOKEN_LO, TOKEN_HI, args)));
            if (ok) return amt;
        }
        return 0;
    }
}
