// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test, stdError } from "forge-std/Test.sol";

import { Context } from "../../../../src/libs/VM.sol";
import { FeeArgsBuilder, BPS } from "../../../../src/instructions/Fee.sol";
import { FeeExperimental } from "../../../../src/instructions/FeeExperimental.sol";

/// @notice Executed witnesses for four defects in the `Fee` instruction family.
///
/// @dev     forge test --match-path test/kontrol/analysis/repro/FeeRepro.t.sol -vv
///
///      Each of these is also stated as a Kontrol property in `test/kontrol/FeeSpec.t.sol`;
///      three of them are PROVEN there over a symbolic domain and one is REFUTED there (which
///      is how the third witness below was found). This file is the executing-EVM half: it
///      runs the real instruction on concrete inputs and reports what came out.
///
///      ## The shared root: `feeBps` is never checked on chain
///
///      `FeeArgsBuilder.buildFlatFee` (`Fee.sol:23-26`) requires `feeBps <= BPS`. That function
///      is an off-chain assembler. The on-chain half is `parseFlatFee` (`Fee.sol:37-39`), which
///      is `feeBps = uint32(bytes4(args))` and nothing else — no bound, no clamp. Program bytes
///      are maker-assembled and only `parse` executes during a fill, so the whole `uint32`
///      range reaches the arithmetic. `BUGS.md` §"no `build` is a guard" already states this
///      for `DutchAuctionArgsBuilder`; it holds verbatim for `Fee`.
///
///      ## 1. The documented maximum fee is unusable — `Panic(0x12)`
///
///      Every fee-in reconstruction divides by `BPS - feeBps` (`Fee.sol:76`, `:80`, `:234`,
///      `:239`). At `feeBps == BPS` that divisor is zero. `buildFlatFee` accepts `BPS`
///      (`<=`, not `<`) and every entrypoint's NatSpec says "`1e9 = 100%`", so a maker who
///      follows the documentation and the builder assembles an order that reverts on every
///      fill with a bare `Panic(0x12)`.
///
///      * **Reachability.** Ordinary: it is the value the builder's own bound names.
///      * **Impact.** Denial of service on the whole order. No funds move.
///      * **Who bears it.** The **maker** — self-inflicted, plus the taker's wasted gas.
///      * **Guard elsewhere.** None. Nothing between `parse` and the division inspects `feeBps`.
///
///      ## 2. `feeBps > BPS` reverts with an unlabelled `Panic(0x11)`
///
///      Above the maximum the failure is an underflow rather than a named error, and it arrives
///      by two routes: for `amountIn > 0` the discount exceeds the principal and `Fee.sol:232`
///      underflows; for `amountIn == 0` the discount is zero and `BPS - feeBps` at `Fee.sol:234`
///      underflows instead. Both are `Panic(0x11)`.
///
///      The contract *has* an error for this — `Fee.FeeBpsOutOfRange` (`Fee.sol:57`) — but it is
///      raised only at `Fee.sol:160` and `Fee.sol:209`, which validate a fee returned by an
///      external *provider*. A maker-signed fee is never checked by name.
///
///      * **Reachability.** 76% of the parseable `uint32` domain.
///      * **Impact.** Robustness only. An integrator cannot distinguish a misconfigured fee
///        from an ordinary overflow.
///      * **Who bears it.** The maker (self-inflicted) and whoever debugs it.
///      * **Guard elsewhere.** None on chain.
///
///      ## 3. The exact-in fee round trip overshoots, and the VM then rejects the fill
///
///      This is the one worth reading carefully, because the defect and its consequence live in
///      different files.
///
///      `_feeAmountIn` exact-in (`Fee.sol:229-235`) discounts `amountIn` by the fee before the
///      rest of the program runs, then reconstructs it afterwards:
///
///          a   := amountIn - (amountIn*f) \ BPS      // Fee.sol:231-232, floored
///          fee := (a*f) \ (BPS - f)                  // Fee.sol:234,     floored
///          amountIn := a + fee                       // Fee.sol:235
///
///      Both divisions floor. Flooring the first one *raises* `a` above the exact value
///      `amountIn*(1 - f/BPS)`, and the second line then scales that error by `1/(1 - f/BPS)`.
///      The result can exceed the `amountIn` the taker offered.
///
///      `SwapVM` does not tolerate that. In the exact-in direction `TakerTraits.validate`
///      (`TakerTraits.sol:181`) runs
///
///          require(takerAmount >= amountIn, TakerTraitsTakerAmountInMismatch(...))
///
///      on the value `runLoop` returned, where `takerAmount` is the taker's own `amount`
///      (`SwapVM.sol:161`, `:207`). **That check is unconditional** — unlike the
///      `thresholdAmount` checks beside it, it is not gated on `hasThreshold`. So the overshoot
///      does not overcharge anyone; it makes the fill revert.
///
///      The Kontrol counterexample (`FeeSpec.test_feeIn_exactIn_reconstructionNeverExceedsThePrincipal`,
///      PROOF FAILED at node 198) is the interesting part: it is **not** an extreme fee.
///
///          feeBps  = 3          i.e. 0.0000003%
///          amountIn = 1_333_333_333
///
///      Path condition: `amountIn =/= 0` and `amountIn < a + fee`. The tests below show this is
///      not a knife edge — a fixed dust-scale fee rate breaks a dense set of trade sizes.
///
///      * **Reachability.** Ordinary. `feeBps` is a normal small protocol fee; `amountIn` is
///        the taker's own trade size, unconstrained by anything before `runLoop`
///        (`SwapVM.sol:161`).
///      * **Impact.** Denial of service on an otherwise-valid fill. **No funds move
///        incorrectly** — the guard catches it. This is deliberately stated as DoS and not as
///        an overcharge; an earlier reading of it as "the taker is charged 1e6x" was wrong,
///        because the exact-in `takerAmount` check is not opt-in.
///      * **Who bears it.** The **taker** loses gas and the fill fails; the **maker**'s order
///        does not fill. Neither party chose the failure, which is what separates this from
///        (1) and (2).
///      * **Guard elsewhere.** `TakerTraits.validate` is the guard, and it converts wrong
///        arithmetic into a revert. That is the right outcome and it is why this is MEDIUM
///        rather than HIGH. It also means the defect is invisible in any test that only checks
///        that successful fills are priced correctly.
///
///      ## 4. …and the *other* fee-in instruction does not have the problem
///
///      `_flatFeeAmountInXD` (`Fee.sol:67-82`) is described by its own source comment at
///      `Fee.sol:71` as "the same `_feeAmountIn` call, just with rounding up". It uses
///      `Math.ceilDiv` on both lines. Ceiling the discount *lowers* `a`, which is the opposite
///      of what breaks `_feeAmountIn`, and over the whole window swept below the flat variant
///      never overshoots.
///
///      So the two instructions that the source says compute the same thing differ in whether
///      they can brick a fill. The one that cannot is the flat fee, which pays the maker; the
///      one that can is the shared core used by `_protocolFeeAmountInXD`,
///      `_aquaProtocolFeeAmountInXD`, `_dynamicProtocolFeeAmountInXD` and
///      `_aquaDynamicProtocolFeeAmountInXD` — every protocol-fee opcode.
///
///      ## 5. Fee-out additivity — ALREADY KNOWN, included only to pin the magnitude
///
///      That `feeOut` violates additivity, and that splitting a swap can be profitable, is an
///      existing result: `test/FeeOutAdditivityViolation.t.sol` demonstrates it and the
///      Nethermind review covers it. **Nothing here is new about the finding itself.**
///
///      What the Kontrol property adds is a bound. `FeeSpec.test_feeOut_exactIn_splittingGainsAtMostOneWei`
///      proves that at the instruction level the gap is *exactly* zero or one wei per split:
///
///          net(a) + net(b) - net(a+b) = ((a+b)*f)\BPS - (a*f)\BPS - (b*f)\BPS  in {0, 1}
///
///      So the instruction's own rounding cannot account for the economically significant
///      splitting profit measured in `FeeOutAdditivityViolation` — that profit comes from the
///      pool state moving between fills, which is a property of the curve and the balance
///      registers, not of the fee. The witness below fixes a point where the one wei is
///      attained and the whole fee is avoided.
contract FeeRepro is Test, FeeExperimental {
    constructor() FeeExperimental(address(0)) {}

    // -----------------------------------------------------------------------
    // Thin drivers. No transcription — the real internal functions are called.
    // `ctx.vm` is left zero, so `runLoop` sees a zero-length program and does
    // nothing; that is the on-chain shape of a fee instruction placed last.
    // -----------------------------------------------------------------------

    /// @dev `_feeAmountIn`, exact-in. Returns (fee, resulting amountIn).
    function feeInExactIn(uint256 amountIn, uint256 feeBps) public returns (uint256, uint256) {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.swap.amountIn = amountIn;
        uint256 fee = _feeAmountIn(ctx, feeBps);
        return (fee, ctx.swap.amountIn);
    }

    /// @dev `_flatFeeAmountInXD`, exact-in, through the real `parseFlatFee`.
    ///      `feeBps` MUST be the first parameter: `msg.data[32:36]` is its four ABI bytes.
    function flatFeeInExactIn(uint32 feeBps, uint256 amountIn) external returns (uint256) {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.swap.amountIn = amountIn;
        _flatFeeAmountInXD(ctx, msg.data[32:36]);
        return ctx.swap.amountIn;
    }

    /// @dev `_feeAmountOut`, exact-in, with `amountOut` pre-seeded to the value the tail
    ///      program would have priced. Returns (fee, net amountOut).
    function feeOutExactIn(uint256 amountOut, uint256 feeBps) public returns (uint256, uint256) {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.swap.amountOut = amountOut;
        uint256 fee = _feeAmountOut(ctx, feeBps);
        return (fee, ctx.swap.amountOut);
    }

    // -----------------------------------------------------------------------
    // 1. The documented maximum reverts on a division by zero
    // -----------------------------------------------------------------------

    function test_repro_maxBpsIsAcceptedByTheBuilderAndRevertsOnChain() public {
        // The off-chain assembler blesses it: `require(feeBps <= BPS)` at Fee.sol:24.
        bytes memory args = FeeArgsBuilder.buildFlatFee(uint32(BPS));
        assertEq(args.length, 4, "buildFlatFee accepts a 100% fee and emits it");

        // The instruction does not. `0 * BPS / (BPS - BPS)` at Fee.sol:234.
        vm.expectRevert(stdError.divisionError);
        this.feeInExactIn(1000e18, BPS);
    }

    function test_repro_maxBpsRevertsForEveryAmountIncludingZero() public {
        vm.expectRevert(stdError.divisionError);
        this.feeInExactIn(0, BPS);

        vm.expectRevert(stdError.divisionError);
        this.feeInExactIn(1, BPS);

        // `Math.ceilDiv` raises the same panic deliberately, so the flat variant agrees.
        vm.expectRevert(stdError.divisionError);
        this.flatFeeInExactIn(uint32(BPS), 1000e18);
    }

    // -----------------------------------------------------------------------
    // 2. Above the maximum: an unlabelled arithmetic panic, not `FeeBpsOutOfRange`
    // -----------------------------------------------------------------------

    function test_repro_bpsAboveMaxParsesFineThenPanics() public {
        uint32 tooBig = uint32(BPS) + 1;

        // `parse` does not validate — this is the whole of Fee.sol:37-39.
        assertEq(this.parseFlatFeeRaw(tooBig), tooBig, "parse accepts an out-of-range feeBps");

        // `build` does, but `build` never runs on chain.
        vm.expectRevert(abi.encodeWithSelector(FeeArgsBuilder.FeeBpsOutOfRange.selector, tooBig));
        this.buildFlatFeeRaw(tooBig);

        // And the instruction reverts with Panic(0x11), NOT with either FeeBpsOutOfRange.
        vm.expectRevert(stdError.arithmeticError);
        this.feeInExactIn(1000e18, tooBig);

        // Same panic by the other route, when there is nothing to discount.
        vm.expectRevert(stdError.arithmeticError);
        this.feeInExactIn(0, tooBig);
    }

    function parseFlatFeeRaw(uint32 feeBps) external view returns (uint32) {
        return FeeArgsBuilder.parseFlatFee(msg.data[32:36]);
    }

    function buildFlatFeeRaw(uint32 feeBps) external pure returns (bytes memory) {
        return FeeArgsBuilder.buildFlatFee(feeBps);
    }

    // -----------------------------------------------------------------------
    // 3. The exact-in overshoot, and the guard it trips
    // -----------------------------------------------------------------------

    /// @notice Kontrol's own counterexample, executed on the EVM.
    /// @dev A fee of three parts per billion, on an ordinary trade size, produces an
    ///      `amountIn` one wei above what the taker offered — which `TakerTraits.validate`
    ///      rejects.
    function test_repro_exactInOvershootAtDustFeeRate() public {
        uint256 takerAmount = 1_333_333_333;
        uint32 feeBps = 3;

        (uint256 fee, uint256 finalAmountIn) = feeInExactIn(takerAmount, feeBps);

        // Worked by hand:
        //   discount       = (1_333_333_333 * 3) \ 1e9        = 3
        //   a              = 1_333_333_333 - 3                = 1_333_333_330
        //   reconstruction = (1_333_333_330 * 3) \ (1e9 - 3)  = 4
        //   amountIn       = 1_333_333_330 + 4                = 1_333_333_334
        assertEq(fee, 4, "the reconstruction charges one wei more than the discount removed");
        assertEq(finalAmountIn, takerAmount + 1, "and amountIn ends up above the taker's offer");

        // This is exactly the condition TakerTraits.sol:181 rejects, unconditionally, in the
        // exact-in direction: `require(takerAmount >= amountIn)`.
        assertFalse(takerAmount >= finalAmountIn, "TakerTraits.validate would revert this fill");
    }

    /// @notice The extreme end of the same defect: `amountIn` is reconstructed a millionfold
    ///         too large.
    /// @dev `feeBps = BPS - 1` is one bps-of-1e9 below 100% and is accepted by `buildFlatFee`.
    ///      The discount leaves `a = 1`, and dividing by `BPS - feeBps = 1` returns the whole
    ///      thing. Still a revert rather than an overcharge, for the same reason.
    function test_repro_exactInOvershootIsUnboundedAtHighFeeRates() public {
        (uint256 fee, uint256 finalAmountIn) = feeInExactIn(1000, uint32(BPS) - 1);

        assertEq(fee, 999_999_999, "the whole rounded-up remainder is charged as fee");
        assertEq(finalAmountIn, 1_000_000_000, "an offer of 1000 reconstructs as one billion");
        assertEq(finalAmountIn / 1000, 1_000_000, "a factor of exactly one million");
    }

    /// @notice The overshoot is not a knife edge: at a fixed dust-scale fee rate a dense set of
    ///         ordinary trade sizes is unfillable.
    /// @dev Sweeps 4001 consecutive amounts around the counterexample and counts how many
    ///      reconstruct above the taker's offer. Reported with `-vv`. The point of the count is
    ///      that a maker cannot avoid this by "not using weird numbers" — the failures are
    ///      interleaved with the successes at one-wei spacing.
    function test_repro_exactInOvershootDensitySweep() public {
        uint32 feeBps = 3;
        uint256 base = 1_333_333_000;
        uint256 overshoots;

        for (uint256 i = 0; i < 4001; ++i) {
            (, uint256 finalAmountIn) = feeInExactIn(base + i, feeBps);
            if (finalAmountIn > base + i) ++overshoots;
        }

        emit log_named_uint("amounts swept", 4001);
        emit log_named_uint("amounts whose fill TakerTraits.validate would reject", overshoots);

        assertGt(overshoots, 0, "the overshoot must be reachable at an ordinary fee rate");
    }

    // -----------------------------------------------------------------------
    // 4. The flat fee-in instruction does not overshoot on the same sweep
    // -----------------------------------------------------------------------

    /// @notice Differential: over the identical window, `_flatFeeAmountInXD` never reconstructs
    ///         above the taker's offer, while `_feeAmountIn` does.
    /// @dev The two are described by `Fee.sol:71` as computing the same quantity with different
    ///      rounding. They do not have the same failure mode. Ceiling the discount lowers the
    ///      amount handed to the tail, which is the opposite of what makes the floored version
    ///      overshoot.
    function test_repro_flatFeeInDoesNotOvershootWhereProtocolFeeInDoes() public {
        uint32 feeBps = 3;
        uint256 base = 1_333_333_000;
        uint256 flatOvershoots;
        uint256 protocolOvershoots;

        for (uint256 i = 0; i < 2001; ++i) {
            uint256 amountIn = base + i;

            if (this.flatFeeInExactIn(feeBps, amountIn) > amountIn) ++flatOvershoots;

            (, uint256 finalAmountIn) = feeInExactIn(amountIn, feeBps);
            if (finalAmountIn > amountIn) ++protocolOvershoots;
        }

        emit log_named_uint("_flatFeeAmountInXD overshoots", flatOvershoots);
        emit log_named_uint("_feeAmountIn overshoots", protocolOvershoots);

        assertEq(flatOvershoots, 0, "the ceiling variant never reconstructs above the offer");
        assertGt(protocolOvershoots, 0, "the flooring variant does");
    }

    // -----------------------------------------------------------------------
    // 5. Fee-out additivity — KNOWN. The magnitude is what is pinned here.
    // -----------------------------------------------------------------------

    /// @notice The additivity gap at the instruction level is exactly one wei at this point,
    ///         and the split pays no fee at all.
    /// @dev Not a new finding. `test/FeeOutAdditivityViolation.t.sol` and the Nethermind review
    ///      already establish that `feeOut` is non-additive and that splitting can be
    ///      profitable. This exists to record the magnitude that
    ///      `FeeSpec.test_feeOut_exactIn_splittingGainsAtMostOneWei` proves in general: 0 or 1
    ///      wei per split, always in the splitter's favour.
    function test_repro_feeOutAdditivityGapIsOneWei() public {
        uint256 halfBps = BPS / 2; // a 50% fee, so the arithmetic is readable

        (uint256 feeA, uint256 netA) = feeOutExactIn(1, halfBps);
        (uint256 feeB, uint256 netB) = feeOutExactIn(1, halfBps);
        (uint256 feeWhole, uint256 netWhole) = feeOutExactIn(2, halfBps);

        assertEq(feeA, 0, "a one-wei fill at 50% pays no fee");
        assertEq(feeB, 0, "and neither does the second");
        assertEq(feeWhole, 1, "the unsplit two-wei fill pays one");

        assertEq(netA + netB, 2, "split: the taker keeps everything");
        assertEq(netWhole, 1, "whole: the taker keeps one");
        assertEq(netA + netB - netWhole, 1, "the gap is exactly one wei, in the splitter's favour");
    }
}
