// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test, stdError } from "forge-std/Test.sol";

import { SwapRegisters } from "../../src/libs/VM.sol";
import { BaseFeeAdjuster, BaseFeeAdjusterArgsBuilder } from "../../src/instructions/BaseFeeAdjuster.sol";
import { BaseFeeAdjusterHarness } from "./harnesses/BaseFeeAdjusterHarness.sol";

/// @notice Kontrol specification for the BaseFeeAdjuster instruction (opcode 0xb4).
///
/// @dev Reference semantics, derived from src/instructions/BaseFeeAdjuster.sol:72-103.
///
///      Args are a 31-byte packed record (BaseFeeAdjuster.sol:19-43):
///
///        baseGasPrice (uint64) | ethToToken1Price (uint96) | gasAmount (uint24) | maxPriceDecay (uint64)
///
///      Write `b = block.basefee`, `g = baseGasPrice`, `p = ethToToken1Price`,
///      `G = gasAmount`, `D = maxPriceDecay`, and `WAD = 1e18`. Then, given registers
///      already populated by a preceding swap instruction:
///
///        require(amountIn > 0 && amountOut > 0)                          (line 73)
///
///        if (b <= g):  no register changes at all                        (line 83)
///        else:
///          C = ((b - g) * G * p) / WAD                       // floor    (lines 85-86)
///          q = (C * WAD) / amountIn                          // floor    (lines 92, 98)
///
///          exactIn:   amountOut' = amountOut * min(WAD + q, 2*WAD - D) / WAD   // floor
///          exactOut:  amountIn'  = ceil(amountIn * max(WAD - q, D) / WAD)      // ceil
///
///      `q` is the gas compensation expressed as a fraction of the taker's *input* leg
///      (token1). The exactIn branch applies that same fraction to `amountOut` rather than
///      converting it into token0 — algebraically the same thing as scaling by the swap
///      price, and it avoids a second division (lines 90-91).
///
///      Both roundings — floor on the exactIn uplift, ceil on the exactOut discount — move
///      the result *against* the taker and in the maker's favour, the same convention
///      XYCSwap and LimitSwap use.
///
///      `2*WAD - D` is described in the source as the "mirror" of the decay: with
///      `D = 0.99e18` (1% max discount) the exactIn cap is `1.01e18` (1% max uplift). The
///      mirroring is only meaningful for `D <= WAD`, and the encoding admits `D` up to
///      `2^64 - 1`. The properties below pin what actually happens outside that range
///      rather than assuming it away — see the `unguarded` properties at the end.
///
///      DOMAIN NOTE — the gas price. `block.basefee` is driven by `vm.fee`, which rejects
///      values at or above `2^64`; that is also the width every client uses for the header
///      field, and the width the instruction's own `baseGasPrice` field uses. Every
///      property below therefore quantifies over `b < 2^64`. This is a real restriction of
///      the theorem and it does real work: within it the three upstream multiplications are
///      *total* (see `test_gasCostArithmeticIsTotal`), so none of the properties below need
///      an overflow side condition on the gas-cost computation, and the only reachable
///      arithmetic reverts are the two underflows recorded further down. Above `2^64` the
///      product `(b - g) * G * p` can overflow and the instruction panics; that path is
///      unreachable on any real chain and is not expressible through `vm.fee`.
///
///      These run as ordinary fuzz tests under `forge test` and as proofs under
///      `kontrol prove`. Under Kontrol every `vm.assume` becomes a path constraint rather
///      than a sample filter, so the assumptions below define exactly the domain over which
///      each property is proven — read them as part of the specification.
contract BaseFeeAdjusterSpec is Test {
    BaseFeeAdjusterHarness internal harness;

    uint256 internal constant WAD = 1e18;

    /// @dev Args used by the clamp-boundary constructions: with `baseGasPrice == 0`,
    ///      `ethToToken1Price == WAD` and `gasAmount == 1`, the compensation collapses to
    ///      `C == basefee`, and with `amountIn == WAD` to `q == basefee`. That makes the
    ///      point where each clamp binds land on an exact, nameable basefee.
    uint96 internal constant UNIT_PRICE = uint96(WAD);
    uint24 internal constant UNIT_GAS = 1;

    function setUp() public {
        harness = new BaseFeeAdjusterHarness();
    }

    function _args(uint64 baseGasPrice, uint96 ethToToken1Price, uint24 gasAmount, uint64 maxPriceDecay)
        internal
        pure
        returns (bytes memory)
    {
        return BaseFeeAdjusterArgsBuilder.build(baseGasPrice, ethToToken1Price, gasAmount, maxPriceDecay);
    }

    /// @dev The extra gas cost in token1, `C`, on the branch where the adjustment happens.
    ///      No overflow assumption is needed: see `test_gasCostArithmeticIsTotal`.
    function _extraCost(uint64 basefee, uint64 baseGasPrice, uint96 ethToToken1Price, uint24 gasAmount)
        internal
        pure
        returns (uint256)
    {
        vm.assume(basefee > baseGasPrice);
        return ((uint256(basefee - baseGasPrice) * gasAmount) * ethToToken1Price) / WAD;
    }

    /// @dev The compensation ratio `q`, as a fraction of the taker's input leg.
    function _ratio(uint256 extraCostInToken1, uint256 amountIn) internal pure returns (uint256) {
        vm.assume(amountIn > 0);
        return (extraCostInToken1 * WAD) / amountIn;
    }

    // -----------------------------------------------------------------------
    // Totality of the gas-cost arithmetic
    // -----------------------------------------------------------------------

    /// @notice Over the encodable parameter range, none of the three multiplications that
    ///         produce `C` — and none of `C * WAD` — can overflow.
    /// @dev `(b - g) < 2^64`, `G < 2^24` and `p < 2^96` give `(b - g) * G * p < 2^184`, and
    ///      `C = that / WAD < 2^124`, so `C * WAD < 2^184` as well. This is what licenses
    ///      the absence of overflow assumptions in every other property here: the field
    ///      widths chosen by the args encoding are load-bearing, not decorative. Widen
    ///      `gasAmount` or `ethToToken1Price` and this property is the one that breaks first.
    function test_gasCostArithmeticIsTotal(
        uint64 basefee,
        uint64 baseGasPrice,
        uint96 ethToToken1Price,
        uint24 gasAmount
    ) public {
        vm.assume(basefee > baseGasPrice);

        uint256 extraGasCost = uint256(basefee - baseGasPrice) * gasAmount;
        assertLe(extraGasCost, 2 ** 88, "(b - g) * G must stay under 2^88");

        uint256 scaled = extraGasCost * ethToToken1Price;
        assertLe(scaled, 2 ** 184, "(b - g) * G * p must stay under 2^184");

        uint256 c = scaled / WAD;
        assertLe(c * WAD, 2 ** 184, "C * WAD must stay under 2^184");
    }

    // -----------------------------------------------------------------------
    // The gas-price threshold, including the boundary itself
    // -----------------------------------------------------------------------

    /// @notice At or below the base gas price the instruction is the identity on every register.
    function test_belowBaseGasPrice_isIdentity(
        uint64 basefee,
        uint64 baseGasPrice,
        uint96 ethToToken1Price,
        uint24 gasAmount,
        uint64 maxPriceDecay,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountNetPulled
    ) public {
        vm.assume(basefee <= baseGasPrice);
        vm.assume(amountIn > 0 && amountOut > 0);
        vm.fee(basefee);

        bytes memory args = _args(baseGasPrice, ethToToken1Price, gasAmount, maxPriceDecay);

        SwapRegisters memory r = harness.exactIn(balanceIn, balanceOut, amountIn, amountOut, amountNetPulled, args);
        assertEq(r.amountOut, amountOut, "exactIn must not adjust at or below the base gas price");
        assertEq(r.amountIn, amountIn, "exactIn must not touch amountIn");

        r = harness.exactOut(balanceIn, balanceOut, amountIn, amountOut, amountNetPulled, args);
        assertEq(r.amountIn, amountIn, "exactOut must not adjust at or below the base gas price");
        assertEq(r.amountOut, amountOut, "exactOut must not touch amountOut");
    }

    /// @notice Exactly at the base gas price, nothing happens — the threshold is strict.
    /// @dev This is the interesting half of the previous property: one wei of basefee more
    ///      and the adjustment branch is taken. Pinning `b == g` makes the strictness of the
    ///      comparison part of the specification rather than an accident, and a fuzzer would
    ///      essentially never sample the equality on its own.
    function test_atBaseGasPrice_isIdentity(
        uint64 baseGasPrice,
        uint96 ethToToken1Price,
        uint24 gasAmount,
        uint64 maxPriceDecay,
        uint256 amountIn,
        uint256 amountOut
    ) public {
        vm.assume(amountIn > 0 && amountOut > 0);
        vm.fee(baseGasPrice);

        bytes memory args = _args(baseGasPrice, ethToToken1Price, gasAmount, maxPriceDecay);

        SwapRegisters memory r = harness.exactIn(0, 0, amountIn, amountOut, 0, args);
        assertEq(r.amountOut, amountOut, "exactIn: basefee == baseGasPrice must be a no-op");

        r = harness.exactOut(0, 0, amountIn, amountOut, 0, args);
        assertEq(r.amountIn, amountIn, "exactOut: basefee == baseGasPrice must be a no-op");
    }

    /// @notice A zero gas budget is a no-op however high the gas price goes.
    /// @dev `G == 0` collapses `C`, and hence `q`, to zero, leaving `min(WAD, 2*WAD - D) == WAD`
    ///      for any `D <= WAD`. The compensation really is proportional to `gasAmount`.
    function test_zeroGasAmount_isNoOp(
        uint64 basefee,
        uint64 baseGasPrice,
        uint96 ethToToken1Price,
        uint64 maxPriceDecay,
        uint256 amountIn,
        uint256 amountOut
    ) public {
        vm.assume(basefee > baseGasPrice);
        vm.assume(amountIn > 0 && amountOut > 0);
        vm.assume(maxPriceDecay <= WAD);
        // The multiplier is exactly one wad here, but the multiplication still happens.
        vm.assume(amountIn <= type(uint256).max / WAD);
        vm.assume(amountOut <= type(uint256).max / WAD);
        vm.fee(basefee);

        bytes memory args = _args(baseGasPrice, ethToToken1Price, 0, maxPriceDecay);

        SwapRegisters memory r = harness.exactIn(0, 0, amountIn, amountOut, 0, args);
        assertEq(r.amountOut, amountOut, "exactIn: zero gasAmount must not move amountOut");

        r = harness.exactOut(0, 0, amountIn, amountOut, 0, args);
        assertEq(r.amountIn, amountIn, "exactOut: zero gasAmount must not move amountIn");
    }

    // -----------------------------------------------------------------------
    // Exact arithmetic
    // -----------------------------------------------------------------------

    /// @notice The exact-in leg computes `amountOut * min(WAD + q, 2*WAD - D) / WAD`, floored.
    /// @dev Every constant and every rounding step is pinned. `min` is spelled out as a
    ///      conditional rather than reusing `Math.min`, so the property is stated
    ///      independently of the library the implementation happens to call.
    function test_exactIn_exactArithmetic(
        uint64 basefee,
        uint64 baseGasPrice,
        uint96 ethToToken1Price,
        uint24 gasAmount,
        uint64 maxPriceDecay,
        uint256 amountIn,
        uint256 amountOut
    ) public {
        uint256 q = _ratio(_extraCost(basefee, baseGasPrice, ethToToken1Price, gasAmount), amountIn);
        // `2*WAD - D` must not underflow; its negation is a revert property below
        vm.assume(maxPriceDecay <= 2 * WAD);

        uint256 cap = 2 * WAD - maxPriceDecay;
        uint256 increase = WAD + q < cap ? WAD + q : cap;

        vm.assume(amountOut > 0);
        // `amountOut * increase` must not overflow
        vm.assume(increase == 0 || amountOut <= type(uint256).max / increase);

        vm.fee(basefee);
        SwapRegisters memory r = harness.exactIn(
            0, 0, amountIn, amountOut, 0, _args(baseGasPrice, ethToToken1Price, gasAmount, maxPriceDecay)
        );

        assertEq(r.amountOut, (amountOut * increase) / WAD, "exactIn arithmetic");
    }

    /// @notice The exact-out leg computes `ceil(amountIn * max(WAD - q, D) / WAD)`.
    /// @dev The ceiling is stated as `floor + (remainder != 0)` rather than by multiplying
    ///      the result back up, which keeps the property free of any overflow side condition.
    function test_exactOut_exactArithmetic(
        uint64 basefee,
        uint64 baseGasPrice,
        uint96 ethToToken1Price,
        uint24 gasAmount,
        uint64 maxPriceDecay,
        uint256 amountIn,
        uint256 amountOut
    ) public {
        uint256 q = _ratio(_extraCost(basefee, baseGasPrice, ethToToken1Price, gasAmount), amountIn);
        // `WAD - q` must not underflow; its negation is a revert property below
        vm.assume(q <= WAD);

        uint256 decay = WAD - q > maxPriceDecay ? WAD - q : maxPriceDecay;

        vm.assume(amountOut > 0);
        // `amountIn * decay` must not overflow
        vm.assume(decay == 0 || amountIn <= type(uint256).max / decay);

        uint256 product = amountIn * decay;
        uint256 expected = product / WAD + (product % WAD == 0 ? 0 : 1);

        vm.fee(basefee);
        SwapRegisters memory r = harness.exactOut(
            0, 0, amountIn, amountOut, 0, _args(baseGasPrice, ethToToken1Price, gasAmount, maxPriceDecay)
        );

        assertEq(r.amountIn, expected, "exactOut arithmetic");
    }

    // -----------------------------------------------------------------------
    // Rounding direction
    // -----------------------------------------------------------------------

    /// @notice The exact-in uplift is rounded down: the taker never receives more than the
    ///         exact (real-valued) adjusted amount, and never more than one wad less.
    /// @dev Together the two bounds pin the rounding to exactly floor. The upper bound is
    ///      the maker's protection — flooring can only move the payout down — and the lower
    ///      bound is the taker's, ruling out an implementation that rounds arbitrarily far
    ///      down and still satisfies "never rounds up".
    function test_exactIn_roundsInFavourOfMaker(
        uint64 basefee,
        uint64 baseGasPrice,
        uint96 ethToToken1Price,
        uint24 gasAmount,
        uint64 maxPriceDecay,
        uint256 amountIn,
        uint256 amountOut
    ) public {
        uint256 q = _ratio(_extraCost(basefee, baseGasPrice, ethToToken1Price, gasAmount), amountIn);
        vm.assume(maxPriceDecay <= 2 * WAD);

        uint256 cap = 2 * WAD - maxPriceDecay;
        uint256 increase = WAD + q < cap ? WAD + q : cap;

        vm.assume(amountOut > 0);
        vm.assume(increase == 0 || amountOut <= type(uint256).max / increase);

        vm.fee(basefee);
        SwapRegisters memory r = harness.exactIn(
            0, 0, amountIn, amountOut, 0, _args(baseGasPrice, ethToToken1Price, gasAmount, maxPriceDecay)
        );

        uint256 exact = amountOut * increase;
        assertLe(r.amountOut * WAD, exact, "the uplift must not be rounded up");
        assertLt(exact - r.amountOut * WAD, WAD, "the uplift must not be rounded down by a whole wad");
    }

    /// @notice The exact-out discount is rounded up: the taker never pays less than the
    ///         exact (real-valued) discounted amount, and never more than one wad more.
    /// @dev So *both* legs round against the taker — the gas compensation is never generous
    ///      by even one wei. The extra `- WAD` in the overflow assumption is needed by the
    ///      statement (it multiplies the ceiling back up), not by the code under test.
    function test_exactOut_roundsInFavourOfMaker(
        uint64 basefee,
        uint64 baseGasPrice,
        uint96 ethToToken1Price,
        uint24 gasAmount,
        uint64 maxPriceDecay,
        uint256 amountIn,
        uint256 amountOut
    ) public {
        uint256 q = _ratio(_extraCost(basefee, baseGasPrice, ethToToken1Price, gasAmount), amountIn);
        vm.assume(q <= WAD);

        uint256 decay = WAD - q > maxPriceDecay ? WAD - q : maxPriceDecay;

        vm.assume(amountOut > 0);
        vm.assume(decay == 0 || amountIn <= (type(uint256).max - WAD) / decay);

        vm.fee(basefee);
        SwapRegisters memory r = harness.exactOut(
            0, 0, amountIn, amountOut, 0, _args(baseGasPrice, ethToToken1Price, gasAmount, maxPriceDecay)
        );

        uint256 exact = amountIn * decay;
        assertGe(r.amountIn * WAD, exact, "the discount must not be rounded down");
        assertLt(r.amountIn * WAD, exact + WAD, "the discount must not be rounded up by a whole wad");
    }

    // -----------------------------------------------------------------------
    // Direction and magnitude of the adjustment
    // -----------------------------------------------------------------------

    /// @notice For a sanely encoded cap (`D <= WAD`) the exact-in leg never reduces the
    ///         taker's payout, and never raises it beyond the mirrored cap.
    function test_exactIn_movesOnlyInTheTakersFavourAndIsCapped(
        uint64 basefee,
        uint64 baseGasPrice,
        uint96 ethToToken1Price,
        uint24 gasAmount,
        uint64 maxPriceDecay,
        uint256 amountIn,
        uint256 amountOut
    ) public {
        _ratio(_extraCost(basefee, baseGasPrice, ethToToken1Price, gasAmount), amountIn);
        vm.assume(maxPriceDecay <= WAD);

        uint256 cap = 2 * WAD - maxPriceDecay;

        vm.assume(amountOut > 0);
        // `cap >= min(WAD + q, cap)`, so bounding against the cap also discharges the
        // instruction's own `amountOut * increase`. The stronger bound is needed by the
        // *statement* of the cap assertion below, not by the code under test.
        vm.assume(amountOut <= type(uint256).max / cap);

        vm.fee(basefee);
        SwapRegisters memory r = harness.exactIn(
            0, 0, amountIn, amountOut, 0, _args(baseGasPrice, ethToToken1Price, gasAmount, maxPriceDecay)
        );

        assertGe(r.amountOut, amountOut, "the taker must never receive less than before the adjustment");
        assertLe(r.amountOut, (amountOut * cap) / WAD, "the uplift must never exceed the mirrored cap");
    }

    /// @notice For a sanely encoded cap (`D <= WAD`) the exact-out leg never increases the
    ///         taker's cost, and never discounts below the floor the maker signed.
    function test_exactOut_movesOnlyInTheTakersFavourAndIsCapped(
        uint64 basefee,
        uint64 baseGasPrice,
        uint96 ethToToken1Price,
        uint24 gasAmount,
        uint64 maxPriceDecay,
        uint256 amountIn,
        uint256 amountOut
    ) public {
        uint256 q = _ratio(_extraCost(basefee, baseGasPrice, ethToToken1Price, gasAmount), amountIn);
        vm.assume(q <= WAD);
        vm.assume(maxPriceDecay <= WAD);

        uint256 decay = WAD - q > maxPriceDecay ? WAD - q : maxPriceDecay;

        vm.assume(amountOut > 0);
        // `decay >= D`, so this also keeps `amountIn * D` below the overflow boundary.
        vm.assume(decay == 0 || amountIn <= type(uint256).max / decay);

        uint256 floorProduct = amountIn * maxPriceDecay;

        vm.fee(basefee);
        SwapRegisters memory r = harness.exactOut(
            0, 0, amountIn, amountOut, 0, _args(baseGasPrice, ethToToken1Price, gasAmount, maxPriceDecay)
        );

        assertLe(r.amountIn, amountIn, "the taker must never pay more than before the adjustment");
        assertGe(
            r.amountIn,
            floorProduct / WAD + (floorProduct % WAD == 0 ? 0 : 1),
            "the discount must never go below the maker's floor"
        );
    }

    // -----------------------------------------------------------------------
    // The clamps, at the boundary
    //
    // Each clamp is exercised at exactly the point where the two branches of the
    // min/max meet, and one wei of basefee either side of it. With
    //
    //   baseGasPrice = 0, ethToToken1Price = WAD, gasAmount = 1, amountIn = WAD
    //     =>  C = basefee  and  q = basefee
    //
    // the clamp binds exactly when `basefee == WAD - D`, so the boundary is hit
    // identically rather than approximately.
    // -----------------------------------------------------------------------

    /// @notice At the exact point where `WAD + q == 2*WAD - D`, the two branches of the
    ///         `min` agree, and the result is that common value.
    /// @dev Proving the branches coincide *at* the boundary is what rules out an off-by-one
    ///      in the comparison: `<` mistakenly written as `<=`, or the operands swapped,
    ///      still passes any test that only probes either side.
    function test_exactIn_atMinClampBoundary(uint64 maxPriceDecay, uint256 amountOut) public {
        vm.assume(maxPriceDecay < WAD);
        uint256 basefee = WAD - maxPriceDecay; // makes q == WAD - D exactly
        uint256 cap = 2 * WAD - maxPriceDecay;
        vm.assume(amountOut > 0 && amountOut <= type(uint256).max / cap);

        vm.fee(basefee);
        SwapRegisters memory r =
            harness.exactIn(0, 0, WAD, amountOut, 0, _args(0, UNIT_PRICE, UNIT_GAS, maxPriceDecay));

        // The uncapped branch and the capped branch are the same number here.
        assertEq(WAD + basefee, cap, "boundary construction");
        assertEq(r.amountOut, (amountOut * cap) / WAD, "at the boundary the clamp equals the uncapped value");
    }

    /// @notice One wei of basefee past the boundary the clamp binds, and the result stops moving.
    function test_exactIn_justAboveMinClampBoundary(uint64 maxPriceDecay, uint256 amountOut) public {
        vm.assume(maxPriceDecay < WAD);
        uint256 cap = 2 * WAD - maxPriceDecay;
        vm.assume(amountOut > 0 && amountOut <= type(uint256).max / cap);

        vm.fee(WAD - maxPriceDecay + 1);
        SwapRegisters memory r =
            harness.exactIn(0, 0, WAD, amountOut, 0, _args(0, UNIT_PRICE, UNIT_GAS, maxPriceDecay));

        assertEq(r.amountOut, (amountOut * cap) / WAD, "past the boundary the result is the cap");
    }

    /// @notice One wei of basefee below the boundary the uncapped branch is taken, and the
    ///         result is the smaller formula.
    function test_exactIn_justBelowMinClampBoundary(uint64 maxPriceDecay, uint256 amountOut) public {
        vm.assume(uint256(maxPriceDecay) + 1 < WAD); // keep basefee >= 1, i.e. above baseGasPrice == 0
        uint256 basefee = WAD - maxPriceDecay - 1;
        uint256 cap = 2 * WAD - maxPriceDecay;
        vm.assume(amountOut > 0 && amountOut <= type(uint256).max / cap);

        vm.fee(basefee);
        SwapRegisters memory r =
            harness.exactIn(0, 0, WAD, amountOut, 0, _args(0, UNIT_PRICE, UNIT_GAS, maxPriceDecay));

        assertEq(r.amountOut, (amountOut * (WAD + basefee)) / WAD, "below the boundary the cap must not bind");
        assertLe(r.amountOut, (amountOut * cap) / WAD, "and the result stays under the cap");
    }

    /// @notice At the exact point where `WAD - q == D`, the two branches of the `max` agree.
    /// @dev With `amountIn == WAD` the answer is `D` itself, so the boundary value is
    ///      checkable without restating the ceiling division.
    function test_exactOut_atMaxClampBoundary(uint64 maxPriceDecay, uint256 amountOut) public {
        vm.assume(maxPriceDecay < WAD);
        vm.assume(amountOut > 0);
        uint256 basefee = WAD - maxPriceDecay; // makes q == WAD - D exactly

        vm.fee(basefee);
        SwapRegisters memory r =
            harness.exactOut(0, 0, WAD, amountOut, 0, _args(0, UNIT_PRICE, UNIT_GAS, maxPriceDecay));

        assertEq(WAD - basefee, uint256(maxPriceDecay), "boundary construction");
        assertEq(r.amountIn, uint256(maxPriceDecay), "at the boundary the clamp equals the uncapped value");
    }

    /// @notice One wei of basefee past the boundary the floor binds: the discount stops deepening.
    function test_exactOut_justAboveMaxClampBoundary(uint64 maxPriceDecay, uint256 amountOut) public {
        vm.assume(maxPriceDecay >= 1 && maxPriceDecay < WAD);
        vm.assume(amountOut > 0);

        vm.fee(WAD - maxPriceDecay + 1);
        SwapRegisters memory r =
            harness.exactOut(0, 0, WAD, amountOut, 0, _args(0, UNIT_PRICE, UNIT_GAS, maxPriceDecay));

        assertEq(r.amountIn, uint256(maxPriceDecay), "past the boundary the result is the floor");
    }

    /// @notice One wei of basefee below the boundary the floor does not bind, and the taker
    ///         pays exactly one wei more than the floor.
    function test_exactOut_justBelowMaxClampBoundary(uint64 maxPriceDecay, uint256 amountOut) public {
        vm.assume(uint256(maxPriceDecay) + 1 < WAD);
        vm.assume(amountOut > 0);

        vm.fee(WAD - maxPriceDecay - 1);
        SwapRegisters memory r =
            harness.exactOut(0, 0, WAD, amountOut, 0, _args(0, UNIT_PRICE, UNIT_GAS, maxPriceDecay));

        assertEq(r.amountIn, uint256(maxPriceDecay) + 1, "below the boundary the floor must not bind");
    }

    // -----------------------------------------------------------------------
    // Register isolation
    // -----------------------------------------------------------------------

    /// @notice The exact-in leg writes `amountOut` and nothing else.
    /// @dev Balances and `amountNetPulled` are symbolic and must come back untouched. This
    ///      is what makes the instruction safe to compose after a swap instruction: it
    ///      cannot invalidate the balance registers a later instruction reads.
    function test_exactIn_touchesOnlyAmountOut(
        uint64 basefee,
        uint64 baseGasPrice,
        uint96 ethToToken1Price,
        uint24 gasAmount,
        uint64 maxPriceDecay,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountNetPulled
    ) public {
        uint256 q = _ratio(_extraCost(basefee, baseGasPrice, ethToToken1Price, gasAmount), amountIn);
        vm.assume(maxPriceDecay <= 2 * WAD);

        uint256 cap = 2 * WAD - maxPriceDecay;
        uint256 increase = WAD + q < cap ? WAD + q : cap;
        vm.assume(amountOut > 0);
        vm.assume(increase == 0 || amountOut <= type(uint256).max / increase);

        vm.fee(basefee);
        SwapRegisters memory r = harness.exactIn(
            balanceIn,
            balanceOut,
            amountIn,
            amountOut,
            amountNetPulled,
            _args(baseGasPrice, ethToToken1Price, gasAmount, maxPriceDecay)
        );

        assertEq(r.balanceIn, balanceIn, "balanceIn must be untouched");
        assertEq(r.balanceOut, balanceOut, "balanceOut must be untouched");
        assertEq(r.amountIn, amountIn, "exactIn must not write amountIn");
        assertEq(r.amountNetPulled, amountNetPulled, "amountNetPulled must be untouched");
    }

    /// @notice The exact-out leg writes `amountIn` and nothing else.
    function test_exactOut_touchesOnlyAmountIn(
        uint64 basefee,
        uint64 baseGasPrice,
        uint96 ethToToken1Price,
        uint24 gasAmount,
        uint64 maxPriceDecay,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountNetPulled
    ) public {
        uint256 q = _ratio(_extraCost(basefee, baseGasPrice, ethToToken1Price, gasAmount), amountIn);
        vm.assume(q <= WAD);

        uint256 decay = WAD - q > maxPriceDecay ? WAD - q : maxPriceDecay;
        vm.assume(amountOut > 0);
        vm.assume(decay == 0 || amountIn <= type(uint256).max / decay);

        vm.fee(basefee);
        SwapRegisters memory r = harness.exactOut(
            balanceIn,
            balanceOut,
            amountIn,
            amountOut,
            amountNetPulled,
            _args(baseGasPrice, ethToToken1Price, gasAmount, maxPriceDecay)
        );

        assertEq(r.balanceIn, balanceIn, "balanceIn must be untouched");
        assertEq(r.balanceOut, balanceOut, "balanceOut must be untouched");
        assertEq(r.amountOut, amountOut, "exactOut must not write amountOut");
        assertEq(r.amountNetPulled, amountNetPulled, "amountNetPulled must be untouched");
    }

    // -----------------------------------------------------------------------
    // Reverts
    // -----------------------------------------------------------------------

    /// @notice A zero input register is rejected: the instruction is only meaningful once a
    ///         swap instruction has populated both amount registers.
    /// @dev Checked before any argument parsing, so it holds for empty `args` too.
    function test_revertsWhenAmountInIsZero(uint64 basefee, uint256 amountOut) public {
        vm.fee(basefee);

        vm.expectRevert(BaseFeeAdjuster.BaseFeeAdjusterShouldBeAppliedAfterSwap.selector);
        harness.exactIn(0, 0, 0, amountOut, 0, "");

        vm.expectRevert(BaseFeeAdjuster.BaseFeeAdjusterShouldBeAppliedAfterSwap.selector);
        harness.exactOut(0, 0, 0, amountOut, 0, "");
    }

    /// @notice A zero output register is rejected, in *both* directions.
    /// @dev The guard is `amountIn > 0 && amountOut > 0` regardless of `isExactIn`, so an
    ///      exact-out quote whose input leg is set but whose output leg is not is rejected
    ///      just the same. This is the ordering constraint the instruction's name refers to.
    function test_revertsWhenAmountOutIsZero(uint64 basefee, uint256 amountIn) public {
        vm.fee(basefee);
        vm.assume(amountIn > 0);

        vm.expectRevert(BaseFeeAdjuster.BaseFeeAdjusterShouldBeAppliedAfterSwap.selector);
        harness.exactIn(0, 0, amountIn, 0, 0, "");

        vm.expectRevert(BaseFeeAdjuster.BaseFeeAdjusterShouldBeAppliedAfterSwap.selector);
        harness.exactOut(0, 0, amountIn, 0, 0, "");
    }

    /// @notice UNGUARDED PATH. A maker may encode `maxPriceDecay > 2*WAD`, and the exact-in
    ///         leg then reverts with an arithmetic panic on `2*WAD - maxPriceDecay`.
    /// @dev `maxPriceDecay` is a `uint64`, so anything up to `2^64 - 1 ≈ 1.8e19` is
    ///      encodable, while the mirror expression underflows above `2e18`. Nothing
    ///      validates the field at parse time and the failure is a bare `Panic(0x11)`
    ///      rather than a named error: such an order is simply unexecutable in the exact-in
    ///      direction and says nothing about why. It also only bites once gas rises above
    ///      the base, so the order looks healthy for as long as gas stays cheap.
    function test_exactIn_revertsWhenDecayCapExceedsTwoWad(uint64 maxPriceDecay, uint256 amountIn, uint256 amountOut)
        public
    {
        vm.assume(maxPriceDecay > 2 * WAD);
        vm.assume(amountIn > 0 && amountOut > 0);

        vm.fee(1); // strictly above baseGasPrice == 0, so the adjustment branch is taken
        // `gasAmount == 0` keeps the extra cost at zero, so the panic is the mirror
        // expression itself and not an overflow upstream of it.
        vm.expectRevert(stdError.arithmeticError);
        harness.exactIn(0, 0, amountIn, amountOut, 0, _args(0, 0, 0, maxPriceDecay));
    }

    /// @notice UNGUARDED PATH. When the gas compensation exceeds the taker's whole input
    ///         leg, the exact-out branch underflows on `WAD - q` instead of clamping.
    /// @dev `Math.max(priceDecay, maxPriceDecay)` is applied *after* the subtraction, so it
    ///      cannot rescue it. The exact-in branch has no equivalent problem — it adds rather
    ///      than subtracts — which makes this an asymmetry between the two directions: a
    ///      small exact-out fill reverts under high gas, while the same order in the
    ///      exact-in direction merely saturates at the cap.
    function test_exactOut_revertsWhenCompensationExceedsAmountIn(
        uint64 basefee,
        uint64 maxPriceDecay,
        uint256 amountOut
    ) public {
        // With `p == WAD` and `G == 1`, `C == basefee`; with `amountIn == WAD`, `q == basefee`.
        vm.assume(basefee > WAD);
        vm.assume(amountOut > 0);

        vm.fee(basefee);
        vm.expectRevert(stdError.arithmeticError);
        harness.exactOut(0, 0, WAD, amountOut, 0, _args(0, UNIT_PRICE, UNIT_GAS, maxPriceDecay));
    }

    /// @notice UNGUARDED PATH. The final scaling can overflow for an absurdly large amount
    ///         register, in either direction.
    /// @dev `amountOut * priceIncrease` and `amountIn * priceDecay` are the only remaining
    ///      unchecked-by-the-contract products once the gas price is bounded to `2^64`.
    ///      They need a register above `~5.8e58`, which no real token supply reaches, but
    ///      the path exists and is recorded here so the enumeration of revert causes is
    ///      complete.
    function test_revertsOnAmountScalingOverflow(uint256 amountIn, uint256 amountOut) public {
        // `q == 0` and `D == 0`, so both multipliers are exactly one wad.
        vm.assume(amountIn > type(uint256).max / WAD);
        vm.assume(amountOut > type(uint256).max / WAD);
        bytes memory args = _args(0, 0, 0, 0);

        vm.fee(1);

        vm.expectRevert(stdError.arithmeticError);
        harness.exactIn(0, 0, amountIn, amountOut, 0, args);

        vm.expectRevert(stdError.arithmeticError);
        harness.exactOut(0, 0, amountIn, amountOut, 0, args);
    }

    // -----------------------------------------------------------------------
    // Behaviour outside the documented parameter range
    //
    // The source describes `maxPriceDecay` as a decay coefficient below one wad
    // ("0.99e18 = 1% max discount"). Nothing enforces that. These two properties
    // pin what the instruction actually does when the field is encoded above one
    // wad: in both directions the sign of the "adjustment" flips against the
    // taker, which is the opposite of the instruction's stated purpose.
    // -----------------------------------------------------------------------

    /// @notice UNGUARDED PATH. With `WAD < D <= 2*WAD` the exact-in cap falls *below* one wad,
    ///         so a rising gas price makes the taker receive strictly less, not more.
    function test_unguarded_exactIn_capBelowOneWadCutsTheTakersPayout(uint64 maxPriceDecay, uint256 amountOut)
        public
    {
        vm.assume(maxPriceDecay > WAD && maxPriceDecay <= 2 * WAD);
        uint256 cap = 2 * WAD - maxPriceDecay; // strictly below WAD
        vm.assume(amountOut > 0 && amountOut <= type(uint256).max / WAD);

        vm.fee(1); // any basefee above the base takes the branch; `q == 0` here
        SwapRegisters memory r = harness.exactIn(0, 0, WAD, amountOut, 0, _args(0, 0, 0, maxPriceDecay));

        assertEq(r.amountOut, (amountOut * cap) / WAD, "the cap is applied even when it is a haircut");
        assertLe(r.amountOut, amountOut, "an above-wad decay cap turns the uplift into a haircut");
    }

    /// @notice UNGUARDED PATH. With `D > WAD` the exact-out floor sits above one wad, so the
    ///         "discount" becomes a surcharge: the taker pays more than the swap quoted.
    function test_unguarded_exactOut_floorAboveOneWadRaisesTheTakersCost(uint64 maxPriceDecay, uint256 amountOut)
        public
    {
        vm.assume(maxPriceDecay > WAD);
        vm.assume(amountOut > 0);

        vm.fee(1); // `q == 0`, so priceDecay starts at exactly WAD and the floor overrides it
        SwapRegisters memory r = harness.exactOut(0, 0, WAD, amountOut, 0, _args(0, 0, 0, maxPriceDecay));

        assertEq(r.amountIn, uint256(maxPriceDecay), "the floor is applied even when it is a surcharge");
        assertGt(r.amountIn, WAD, "an above-wad floor makes the taker pay more, not less");
    }
}
