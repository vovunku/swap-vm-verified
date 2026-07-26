// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Context } from "../../../../src/libs/VM.sol";
import { OraclePriceAdjuster } from "../../../../src/instructions/OraclePriceAdjuster.sol";
import { MockPriceOracle } from "../../harnesses/OraclePriceAdjusterHarness.sol";

/// @notice Executed witnesses for the unguarded paths in `OraclePriceAdjuster`.
///
/// @dev     forge test --match-path test/kontrol/analysis/repro/OraclePriceAdjusterRepro.t.sol -vv
///
///      The contract docstring at `:57` claims the instruction "ensures the adjustment is
///      always favorable for the taker", and `:56` claims it "adjusts the swap price towards
///      the oracle price". **Both are false**, for two unrelated reasons, and the second one
///      is the more interesting.
///
///      ## 1. The same `maxPriceDecay` family as `BaseFeeAdjuster`
///
///      `:29` has `require(maxPriceDecay < 1e18)` — in `build` only. `BUGS.md` establishes
///      that no `build` is a guard: program bytes are maker-assembled and `parse` (`:38-48`)
///      is four raw byte casts that validate nothing. So `D` spans the whole `uint64` range
///      on chain, and three things go wrong above one wad:
///
///      * **exact-out becomes a surcharge.** `:134` floors the multiplier at `D` and `:135`
///        multiplies `amountIn` by it. At `D = 2e18` the taker is charged exactly double.
///      * **exact-in becomes a haircut, and at `D = 2e18` a total loss.** `:127` computes
///        `2e18 - D`, so the cap falls below one wad and `:129` scales `amountOut` *down*.
///        At exactly `2e18` the cap is zero: `amountOut` is set to **zero** while `amountIn`
///        stands, so the taker pays in full and receives nothing.
///      * **above `2e18` exact-in bricks.** `2e18 - D` is a checked subtraction. Bare
///        `Panic(0x11)`.
///
///      Direct mirrors of `BaseFeeAdjuster.sol:93`/`:99`, already CONFIRMED in `BUGS.md` —
///      but with a **much weaker trigger**, which is finding 2.
///
///      ## 2. The adjustment does not depend on the oracle price at all
///
///      `:117` computes `currentPrice = amountOut * 1e18 / amountIn`, a ratio of **raw token
///      units**. `:120` compares that against `oraclePrice`, the feed's answer rescaled to
///      18 decimals. Those two are commensurable only if the feed quotes token0-per-token1
///      already corrected for the two tokens' decimals. The instruction takes a parameter
///      for the *oracle's* decimals and none for the *tokens'*, so it cannot make that
///      correction, and the docstring's own worked example (`:63-67`, Chainlink ETH/USD)
///      does not satisfy it.
///
///      What happens instead is that `priceRatio` overshoots the cap by twenty-odd orders of
///      magnitude, so the clamp always binds and the result stops depending on the oracle:
///      the instruction hands the taker the **full capped improvement on every fill**,
///      including fills where the oracle says the price moved against them. It is not an
///      oracle-tracking instruction; it is an unconditional discount with an oracle call
///      attached.
contract OraclePriceAdjusterRepro is Test, OraclePriceAdjuster {
    MockPriceOracle internal oracle;

    /// @dev The docstring's example (`:63-67`): base price 1 ETH for 3000 USDC, Chainlink
    ///      ETH/USD at 8 decimals, `maxPriceDecay = 0.95e18` (a 5% bound).
    uint64 internal constant DECAY_5PCT = 0.95e18;
    uint8 internal constant CHAINLINK_DECIMALS = 8;

    function setUp() public {
        oracle = new MockPriceOracle();
    }

    function adjust(
        bool isExactIn,
        uint256 amountIn,
        uint256 amountOut,
        bytes calldata args
    ) external view returns (uint256, uint256) {
        Context memory ctx;
        ctx.query.isExactIn = isExactIn;
        ctx.swap.amountIn = amountIn;
        ctx.swap.amountOut = amountOut;
        _oraclePriceAdjuster1D(ctx, args);
        return (ctx.swap.amountIn, ctx.swap.amountOut);
    }

    /// @dev The on-chain encoding as `parse` reads it back. Deliberately not
    ///      `OraclePriceAdjusterArgsBuilder.build`, whose `require` would make every value
    ///      exercised here inexpressible — which is exactly the point: `build` does not run
    ///      on chain.
    function _args(uint64 maxPriceDecay, uint16 maxStaleness, uint8 oracleDecimals)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodePacked(maxPriceDecay, maxStaleness, oracleDecimals, address(oracle));
    }

    function _panicCode(bytes memory err) internal pure returns (uint256 code) {
        if (bytes4(err) != bytes4(0x4e487b71)) return type(uint256).max;
        assembly {
            code := mload(add(err, 0x24))
        }
    }

    // =======================================================================
    // 1. The `maxPriceDecay` family
    //
    // Reference swap for this section: one token1 in, one token0 out, oracle at 18
    // decimals answering `2e18`. Then `currentPrice == 1e18` and `oraclePrice == 2e18`,
    // so `:120` is taken and every multiplier below reads directly as a price factor.
    // =======================================================================

    function _refOracle() internal {
        oracle.set(int256(2e18), 0, 18);
    }

    /// @notice The economically serious one: the discount becomes a surcharge.
    function test_repro_maxPriceDecayAboveOneChargesTheTakerDouble() public {
        _refOracle();

        (uint256 amountIn,) = this.adjust(false, 1e18, 1e18, _args(2e18, 0, 18));

        assertEq(amountIn, 2e18, "taker is charged exactly double instead of discounted");
    }

    /// @notice And it is a smooth dial the maker turns, not a knife edge.
    function test_repro_surchargeScalesWithTheParameter() public {
        _refOracle();

        (uint256 at0p95,) = this.adjust(false, 1e18, 1e18, _args(0.95e18, 0, 18));
        (uint256 at1x,) = this.adjust(false, 1e18, 1e18, _args(1e18, 0, 18));
        (uint256 at1p5x,) = this.adjust(false, 1e18, 1e18, _args(1.5e18, 0, 18));
        (uint256 at2x,) = this.adjust(false, 1e18, 1e18, _args(2e18, 0, 18));

        assertEq(at0p95, 0.95e18, "the intended 5% discount, for contrast");
        assertEq(at1x, 1e18, "1e18 is the no-op point");
        assertEq(at1p5x, 1.5e18, "1.5x");
        assertEq(at2x, 2e18, "2x");
    }

    /// @notice Exact-in at `D == 2e18`: the taker pays in full and receives **nothing**.
    /// @dev This has no counterpart in `BaseFeeAdjuster`'s confirmed entries at this
    ///      severity, because there the branch needs a gas spike. Here it needs only
    ///      `oraclePrice > currentPrice`, which finding 2 shows is near-permanently true.
    function test_repro_maxPriceDecayAtTwoWadZeroesTheTakersPayout() public {
        _refOracle();

        (uint256 amountIn, uint256 amountOut) = this.adjust(true, 1e18, 1e18, _args(2e18, 0, 18));

        assertEq(amountOut, 0, "the taker receives nothing");
        assertEq(amountIn, 1e18, "while still paying in full");
    }

    /// @notice Between one and two wad, exact-in is a proportional haircut.
    function test_repro_exactInHaircutScalesWithTheParameter() public {
        _refOracle();

        (, uint256 at1p5x) = this.adjust(true, 1e18, 1e18, _args(1.5e18, 0, 18));
        (, uint256 at1p9x) = this.adjust(true, 1e18, 1e18, _args(1.9e18, 0, 18));

        assertEq(at1p5x, 0.5e18, "half the payout");
        assertEq(at1p9x, 0.1e18, "a tenth of the payout");
    }

    /// @notice Above two wad the exact-in leg reverts with a bare `Panic(0x11)` from
    ///         `2e18 - maxPriceDecay` at `:127`.
    function test_repro_maxPriceDecayAboveTwoBricksExactIn() public {
        _refOracle();

        (bool ok, bytes memory err) =
            address(this).staticcall(abi.encodeCall(this.adjust, (true, 1e18, 1e18, _args(3e18, 0, 18))));

        assertFalse(ok, "expected a revert");
        assertEq(_panicCode(err), 0x11, "expected Panic(0x11) from 2e18 - maxPriceDecay");
    }

    /// @notice The same order is completely healthy while the oracle is below the swap's
    ///         implied price — which is what makes an out-of-range `D` a latent trap rather
    ///         than an immediate failure.
    function test_repro_sameOrderIsHealthyWhileTheOracleIsNotBetter() public {
        oracle.set(int256(1e18), 0, 18); // oraclePrice == currentPrice, so `:120` is false

        (uint256 aIn, uint256 aOut) = this.adjust(true, 1e18, 1e18, _args(3e18, 0, 18));
        assertEq(aIn, 1e18, "unchanged");
        assertEq(aOut, 1e18, "unchanged");

        (aIn, aOut) = this.adjust(false, 1e18, 1e18, _args(3e18, 0, 18));
        assertEq(aIn, 1e18, "unchanged");
        assertEq(aOut, 1e18, "unchanged");
    }

    // =======================================================================
    // 2. The adjustment ignores the oracle price
    //
    // Everything below uses a perfectly ordinary, `build`-legal `maxPriceDecay = 0.95e18`
    // and the docstring's own worked example. There is no misconfiguration here at all.
    // =======================================================================

    /// @notice The docstring's example, at the docstring's own oracle price.
    /// @dev `:66` promises "Taker gets more ETH (up to 5% improvement)". They get exactly
    ///      5%, not the 3.33% the quoted 3100-vs-3000 price difference calls for. The clamp
    ///      binds, so the number the oracle returned never reaches the result.
    function test_repro_docstringExampleSaturatesTheCap() public {
        oracle.set(int256(3100e8), 0, CHAINLINK_DECIMALS); // 1 ETH = $3100

        (, uint256 amountOut) = this.adjust(true, 3000e18, 1e18, _args(DECAY_5PCT, 0, CHAINLINK_DECIMALS));

        assertEq(amountOut, 1.05e18, "the full 5% cap");
        // A correct implementation would have given 3100/3000 = 1.0333x, under the cap.
        assertGt(amountOut, 1.0333e18, "more than the oracle actually justifies");
    }

    /// @notice **The finding.** Sweep the oracle across nine orders of magnitude — from one
    ///         tenth of a cent to a hundred billion dollars an ETH — and the answer never
    ///         moves.
    /// @dev Including `$100`, a 97% crash relative to the order's own 3000 limit price, on
    ///      which the instruction is documented to make *no* adjustment ("If oracle price <=
    ///      current price, no adjustment (already favorable for taker)", `:138`) and instead
    ///      hands over the maximum improvement it is capable of.
    function test_repro_theAdjustmentIsIndependentOfTheOraclePrice() public {
        uint256[7] memory answers = [
            uint256(1e5), // $0.001
            uint256(1e8), // $1
            uint256(100e8), // $100 — a 97% crash against the order's own price
            uint256(3000e8), // $3000 — exactly the order's price, so no adjustment is due
            uint256(3100e8), // $3100 — the docstring's number
            uint256(1e12), // $10 000
            uint256(1e16) // $100 000 000
        ];

        for (uint256 i = 0; i < answers.length; ++i) {
            oracle.set(int256(answers[i]), 0, CHAINLINK_DECIMALS);
            (, uint256 amountOut) = this.adjust(true, 3000e18, 1e18, _args(DECAY_5PCT, 0, CHAINLINK_DECIMALS));
            assertEq(amountOut, 1.05e18, "the result does not depend on the oracle answer");
        }
    }

    /// @notice At `$3000` the oracle agrees exactly with the order, so the instruction's own
    ///         `else` branch (`:138`) is what should run. It does not.
    function test_repro_agreeingOracleStillPaysTheFullCap() public {
        oracle.set(int256(3000e8), 0, CHAINLINK_DECIMALS);

        (, uint256 amountOut) = this.adjust(true, 3000e18, 1e18, _args(DECAY_5PCT, 0, CHAINLINK_DECIMALS));

        assertEq(amountOut, 1.05e18, "a 5% giveaway on an order the oracle says is correctly priced");
    }

    /// @notice The exact-out direction saturates the same way, at the full 5% discount.
    function test_repro_exactOutAlsoSaturates() public {
        oracle.set(int256(100e8), 0, CHAINLINK_DECIMALS); // the crashed price again

        (uint256 amountIn,) = this.adjust(false, 3000e18, 1e18, _args(DECAY_5PCT, 0, CHAINLINK_DECIMALS));

        assertEq(amountIn, 2850e18, "the taker pays the full 5% less regardless of the oracle");
    }

    /// @notice Switching to real USDC decimals does not fix it — it flips the instruction
    ///         into the *other* degenerate regime, a permanent no-op.
    /// @dev This is the sharpest statement of the dimensional error. `currentPrice` is a
    ///      ratio of raw units, so it moves by `10**(dec0 - dec1)` when the token decimals
    ///      change, while `oraclePrice` does not move at all. With 18-decimal token1 the
    ///      comparison at `:120` is permanently *true* and the clamp permanently binds;
    ///      with 6-decimal token1 (real USDC) `currentPrice = 3.33e26` against an
    ///      `oraclePrice` of `3.1e21` and the comparison is permanently **false**.
    ///
    ///      So the instruction lands in one of two degenerate regimes — always the full
    ///      capped giveaway, or never any adjustment at all — selected by the token pair's
    ///      decimals, a quantity it has no parameter for. The intended behaviour, tracking
    ///      the oracle, is what it does in neither.
    function test_repro_realDecimalsFlipItToAPermanentNoOp() public {
        oracle.set(int256(3100e8), 0, CHAINLINK_DECIMALS);

        // 3000 USDC (6 decimals) in, 1 ETH (18 decimals) out — the same trade as above.
        (uint256 amountIn, uint256 amountOut) =
            this.adjust(true, 3000e6, 1e18, _args(DECAY_5PCT, 0, CHAINLINK_DECIMALS));

        assertEq(amountOut, 1e18, "no adjustment is ever made for this token pair");
        assertEq(amountIn, 3000e6, "nothing moves");

        // ...and it stays a no-op at any price a feed could plausibly report. `currentPrice`
        // is `3.33e26` here, so the branch needs `answer > 3.33e16` — $333 million an ETH.
        oracle.set(int256(1e16), 0, CHAINLINK_DECIMALS); // $100 000 000
        (, amountOut) = this.adjust(true, 3000e6, 1e18, _args(DECAY_5PCT, 0, CHAINLINK_DECIMALS));
        assertEq(amountOut, 1e18, "still nothing");
    }

    /// @notice The window in which the oracle actually influences the result, measured. It
    ///         is `$0.00001666` wide, and it sits nine orders of magnitude below any price a
    ///         real ETH/USD feed reports.
    /// @dev `currentPrice = 1e18 * 1e18 / 3000e18 = 333333333333333` and `oraclePrice =
    ///      answer * 1e10`, so `:120` fires from `answer = 33334` and the `min` at `:128`
    ///      saturates from `answer = 35000`. Between those two the instruction behaves as
    ///      documented — and that is the entire domain on which it does.
    ///
    ///      This is the measurement that turns "the comparison looks dimensionally wrong"
    ///      into "the branch is unconditional in practice": every real feed answer is above
    ///      35000 by a factor of at least a million.
    function test_repro_theOracleOnlyMattersOnAVanishingWindow() public {
        oracle.set(int256(33333), 0, CHAINLINK_DECIMALS);
        (, uint256 below) = this.adjust(true, 3000e18, 1e18, _args(DECAY_5PCT, 0, CHAINLINK_DECIMALS));
        assertEq(below, 1e18, "below the threshold: no adjustment at all");

        oracle.set(int256(34999), 0, CHAINLINK_DECIMALS);
        (, uint256 inWindow) = this.adjust(true, 3000e18, 1e18, _args(DECAY_5PCT, 0, CHAINLINK_DECIMALS));
        assertGt(inWindow, 1e18, "inside the window the oracle raises the payout...");
        assertLt(inWindow, 1.05e18, "...and does not yet reach the cap");

        oracle.set(int256(35000), 0, CHAINLINK_DECIMALS);
        (, uint256 saturated) = this.adjust(true, 3000e18, 1e18, _args(DECAY_5PCT, 0, CHAINLINK_DECIMALS));
        assertEq(saturated, 1.05e18, "from here up, the answer is the cap and nothing else");

        // The window is 1666 feed units wide, i.e. $0.00001666, out of a `uint64` range
        // that reaches $184 billion.
        assertEq(uint256(35000 - 33334), 1666, "window width");
    }

    /// @notice The two findings compose: an out-of-range `D` on a docstring-configured order
    ///         zeroes the taker's payout on every fill, not merely on unusual ones.
    function test_repro_theTwoFindingsCompose() public {
        oracle.set(int256(3100e8), 0, CHAINLINK_DECIMALS);

        (uint256 amountIn, uint256 amountOut) = this.adjust(true, 3000e18, 1e18, _args(2e18, 0, CHAINLINK_DECIMALS));

        assertEq(amountOut, 0, "nothing out");
        assertEq(amountIn, 3000e18, "3000 USDC in");
    }

    // =======================================================================
    // 3. `oracleDecimals` — an unvalidated `uint8` with two failure modes
    // =======================================================================

    /// @notice `oracleDecimals >= 96` makes `10**(n-18)` at `:112` overflow. Bare
    ///         `Panic(0x11)`, for every oracle answer.
    /// @dev `10**77 ~= 1e77` is the largest power of ten a `uint256` holds, so the divisor
    ///      overflows from `n - 18 = 78` upward: the top 160 values of the field's 256 are
    ///      an unconditional brick.
    function test_repro_oracleDecimalsAtLeast96Bricks() public {
        oracle.set(int256(3100e8), 0, 96);

        for (uint8 n = 96; n < 100; ++n) {
            (bool ok, bytes memory err) =
                address(this).staticcall(abi.encodeCall(this.adjust, (true, 1e18, 1e18, _args(DECAY_5PCT, 0, n))));
            assertFalse(ok, "expected a revert");
            assertEq(_panicCode(err), 0x11, "expected Panic(0x11) from 10**(n-18)");
        }

        // 95 is the last value that survives.
        (bool ok95,) =
            address(this).staticcall(abi.encodeCall(this.adjust, (true, 1e18, 1e18, _args(DECAY_5PCT, 0, 95))));
        assertTrue(ok95, "95 is the frontier");
    }

    /// @notice Below the brick, a too-large `oracleDecimals` truncates the price to zero and
    ///         silently disables the adjustment instead of reverting.
    /// @dev So a mis-encoded decimals byte has two distinct failure modes either side of 96,
    ///      and neither is reported: a silent no-op below, an unattributable panic above.
    function test_repro_oracleDecimalsBelow96SilentlyDisablesTheAdjustment() public {
        oracle.set(int256(3100e8), 0, 77);

        (uint256 amountIn, uint256 amountOut) = this.adjust(true, 1e18, 1e18, _args(DECAY_5PCT, 0, 77));

        assertEq(amountOut, 1e18, "silently unadjusted");
        assertEq(amountIn, 1e18, "silently unadjusted");
    }

    /// @notice `oracleDecimals == 0` is a sentinel, not a value: it re-reads the feed. If the
    ///         feed also answers zero the price is scaled by `1e18`.
    /// @dev `:103-105`. There is no second check after the fallback, so a feed returning
    ///      `decimals() == 0` multiplies the answer by `10**18` rather than treating it as
    ///      already-scaled. A maker cannot express "this feed genuinely has 0 decimals".
    function test_repro_zeroOracleDecimalsIsASentinelWithNoRecheck() public {
        oracle.set(int256(3100e8), 0, 0); // feed reports 0 decimals too

        (, uint256 amountOut) = this.adjust(true, 1e18, 1e18, _args(DECAY_5PCT, 0, 0));

        // 3100e8 * 1e18 is astronomically above currentPrice, so the cap binds.
        assertEq(amountOut, 1.05e18, "scaled by 1e18 and clamped");
    }

    // =======================================================================
    // 4. Staleness
    // =======================================================================

    /// @notice `maxStaleness == 0` disables the freshness check entirely — including for a
    ///         feed that has never updated, at an arbitrarily distant block timestamp.
    /// @dev Documented at `:20`, so this is intended. It is pinned because zero is also what
    ///      a maker gets by leaving the two bytes unwritten: the encoding cannot distinguish
    ///      "no staleness bound wanted" from "this field was never set".
    function test_repro_zeroMaxStalenessAcceptsAnAncientAnswer() public {
        oracle.set(int256(2e18), 0, 18); // updatedAt == 0: never updated
        vm.warp(10_000_000_000); // year 2286

        (uint256 amountIn,) = this.adjust(false, 1e18, 1e18, _args(DECAY_5PCT, 0, 18));

        assertEq(amountIn, 0.95e18, "a never-updated feed is accepted and acted on");
    }

    /// @notice With a non-zero bound the check works and reports a named error, which is the
    ///         contrast that makes the bare panics above a defect rather than a house style.
    function test_repro_nonZeroMaxStalenessIsEnforcedWithANamedError() public {
        oracle.set(int256(2e18), 1000, 18);
        vm.warp(1000 + 60 + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                OraclePriceAdjuster.OraclePriceAdjusterOraclePriceStale.selector, uint256(1061), uint256(1000), uint16(60)
            )
        );
        this.adjust(false, 1e18, 1e18, _args(DECAY_5PCT, 60, 18));
    }
}
