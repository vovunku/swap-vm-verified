// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test, console } from "forge-std/Test.sol";

import { Context } from "../../../../src/libs/VM.sol";
import { PeggedSwap } from "../../../../src/instructions/PeggedSwap.sol";

/// @notice Executed witness that `PeggedSwap`'s rounding does NOT always favour the maker.
///
/// @dev     forge test --match-path test/kontrol/analysis/repro/PeggedSwapRoundingRepro.t.sol -vv
///
///      ## What this replaces
///
///      The claim in `BUGS.md` was **MODELLED**: a 120-digit re-implementation of the curve
///      reported `amountOut` landing 1 wei above `floor(exact)`. A model is not an execution,
///      and the model's sibling claim (the `:215` underflow) had already needed correcting
///      once. This file re-establishes the finding by executing the real instruction only,
///      with no reference model at all.
///
///      ## The formulation that needs no reference model
///
///      A taker who swaps `k` wei of X for Y and immediately swaps all of that Y back should
///      never end up with more X than they started with. `PeggedSwap` charges no fee, so the
///      break-even case is exact equality; any strict gain is rounding leaking to the taker.
///      The curve re-anchors from current reserves on every call
///      (`PeggedSwap.sol:148-154`), which is what makes the round trip meaningful: the second
///      call does not remember the first.
///
///      Witness, `x0 = y0 = 1e27`, `linearWidth = 0`, `rateLt = rateGt = 1`, pool at
///      `(1e27, 1e27)`:
///
///        | step                                     | in | out |
///        |------------------------------------------|----|-----|
///        | exactIn  X->Y, pool (1e27, 1e27)          | 3  | 2   |
///        | exactIn  Y->X, pool (1e27 - 2, 1e27 + 3)  | 2  | 5   |
///
///      3 wei in, 5 wei out. The taker is **+2 wei** and the pool is short 2 wei of X with
///      its Y reserve restored — a strict loss to the maker, from rounding alone.
///
///      ## Magnitude, which is the part that matters
///
///      The leak is one `u`-ulp, worth `x0_init / ONE` wei, not a fixed 1 wei. Measured
///      round-trip gain, balanced pool, `A = 100e27`:
///
///        | `x0_init`      | best gain (wei) |
///        |----------------|-----------------|
///        | `1e26` and below | 0             |
///        | `1e27`         | 4               |
///        | `1e28`         | 40              |
///        | `1e29`         | 400             |
///        | `1e30`         | 4000            |
///
///      So the gain is `~4 * x0_init / ONE` wei, i.e. a **relative** leak of `~4e-27` of the
///      pool per round trip, independent of trade size. Extracting 1% of a pool would take
///      ~2.5e24 round trips at ~1e5 gas each. It is a real defect in the rounding direction
///      and it is systematically in the taker's favour, but it is not economically
///      extractable: gas exceeds the prize by roughly twenty orders of magnitude.
///
///      Below `x0_init = 1e27` no round trip in the sampled region gains anything, which is
///      the same `x0_init > ONE` threshold that governs the `:215` underflow — both are the
///      same lost-ulp mechanism.
contract PeggedSwapRoundingRepro is Test, PeggedSwap {
    address internal constant TOKEN_LO = address(0x1111);
    address internal constant TOKEN_HI = address(0x2222);

    /// @dev tokenIn is the LOWER address: rateIn = rateLt, (x0_init, y0_init) = (args.x0, args.y0).
    function exactInLt(
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

    /// @dev tokenIn is the GREATER address: rateIn = rateGt and the normalisers swap, which is
    ///      exactly what the reverse leg of a round trip needs.
    function exactInGt(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        bytes calldata args
    ) external pure returns (uint256 amountOut) {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.query.tokenIn = TOKEN_HI;
        ctx.query.tokenOut = TOKEN_LO;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountIn = amountIn;
        _peggedSwapGrowPriceRange2D(ctx, args);
        amountOut = ctx.swap.amountOut;
    }

    function _args(uint256 x0, uint256 y0, uint256 a) internal pure returns (bytes memory) {
        return abi.encodePacked(x0, y0, a, uint256(1), uint256(1));
    }

    /// @notice The defect: a fee-less round trip returns the taker more than they put in.
    function test_repro_roundTripProfits() public view {
        uint256 X = 1e27;
        bytes memory args = _args(X, X, 0);

        uint256 got = this.exactInLt(X, X, 3, args);
        assertEq(got, 2, "3 wei of X buys 2 wei of Y");

        // Pool is now (X + 3, X - 2). Sell the 2 wei of Y straight back.
        uint256 back = this.exactInGt(X - got, X + 3, got, args);
        assertEq(back, 5, "2 wei of Y buys 5 wei of X back");

        assertGt(back, 3, "round trip is strictly profitable for the taker");
    }

    /// @notice The leak scales with the normaliser, one `u`-ulp at a time — it is not "1 wei".
    /// @dev This is the number that decides how serious the finding is, so it is pinned rather
    ///      than described.
    function test_repro_leakScalesWithNormaliser() public view {
        assertEq(_bestRoundTripGain(1e26), 0, "no leak below the ONE = 1e27 threshold");
        assertEq(_bestRoundTripGain(1e27), 4, "one ulp is 1 wei at x0_init = ONE");
        assertEq(_bestRoundTripGain(1e28), 40, "ten wei per ulp");
        assertEq(_bestRoundTripGain(1e30), 4000, "one thousand wei per ulp");
    }

    /// @notice At realistic pool sizes the round trip is exactly break-even or a loss.
    function test_repro_realisticPoolsDoNotLeak() public view {
        assertEq(_bestRoundTripGain(1e18), 0, "1e18 normaliser: no leak");
        assertEq(_bestRoundTripGain(1e21), 0, "1e21 normaliser (the repo's own fixture): no leak");
        assertEq(_bestRoundTripGain(1e24), 0, "1e24 normaliser: no leak");
    }

    /// @dev Largest taker gain over a small grid of round trips on a balanced pool.
    function _bestRoundTripGain(uint256 X) internal view returns (uint256 best) {
        bytes memory args = _args(X, X, 100e27);
        for (uint256 u = 0; u < 4; ++u) {
            uint256 bIn = X + (X / 10) * u;
            uint256 bOut = X - (X / 10) * u;
            for (uint256 k = 1; k <= 8; ++k) {
                (bool ok, bytes memory ret) =
                    address(this).staticcall(abi.encodeCall(this.exactInLt, (bIn, bOut, k, args)));
                if (!ok) continue;
                uint256 b = abi.decode(ret, (uint256));
                if (b == 0) continue;

                (ok, ret) = address(this).staticcall(abi.encodeCall(this.exactInGt, (bOut - b, bIn + k, b, args)));
                if (!ok) continue;
                uint256 c = abi.decode(ret, (uint256));

                if (c > k && c - k > best) best = c - k;
            }
        }
    }
}
