// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test, stdError } from "forge-std/Test.sol";

import { SwapRegisters } from "../../src/libs/VM.sol";
import { MinRate } from "../../src/instructions/MinRate.sol";
import { MinRateHarness } from "./harnesses/MinRateHarness.sol";

/// @notice Kontrol specification for the MinRate instructions (opcodes 0xb0, 0xb1).
///
/// @dev Reference semantics, derived from src/instructions/MinRate.sol.
///
///      **Argument decoding** (`MinRateArgsBuilder.parse`, MinRate.sol:20-24):
///
///        rateLt = uint64(args[0:8])
///        rateGt = uint64(args[8:16])
///        (rateIn, rateOut) = tokenIn < tokenOut ? (rateLt, rateGt) : (rateGt, rateLt)
///
///      The pair `(rateIn, rateOut)` is a *floor price*: the taker must pay at least
///      `rateIn` units of input per `rateOut` units of output.
///
///      **0xb0 `_requireMinRate1D`** (MinRate.sol:37-49):
///
///        require(amountIn == 0 || amountOut == 0)          // MinRateExpectedBeforeSwapAmountsComputed
///        (swapAmountIn, swapAmountOut) = runLoop()
///        require(swapAmountIn * rateOut >= rateIn * swapAmountOut)   // MinRateFailed
///
///      **0xb1 `_adjustMinRate1D`** (MinRate.sol:53-72):
///
///        amountIn', amountOut' = amountIn, amountOut      // captured *before* runLoop
///        require(amountIn == 0 || amountOut == 0)          // MinRateExpectedBeforeSwapAmountsComputed
///        (swapAmountIn, swapAmountOut) = runLoop()
///        require(amountIn > 0 && amountOut > 0)            // MinRateRunLoopExpectToComputeSwapAmounts
///        if (swapAmountIn * rateOut < rateIn * swapAmountOut) {
///            isExactIn ? amountOut = floor(amountIn' * rateOut / rateIn)
///                      : amountIn  = ceil (amountOut' * rateIn  / rateOut)
///        }
///
///      Two things are worth stating up front, because the properties below are built
///      around them:
///
///      * The comparison is the cross-multiplied form of `swapAmountIn / swapAmountOut >=
///        rateIn / rateOut`, so the accept/reject boundary is *exact equality* of the two
///        products, not an approximation. `test_require_acceptsExactlyAtTheFloor` and
///        `test_require_rejectsOneWeiBelowTheFloor` pin it there.
///      * The clamp divides the registers as they were *before* `runLoop`, while the
///        comparison uses the amounts `runLoop` produced. When the rest of the program
///        leaves the taker-fixed leg alone the two coincide; when it does not, they do
///        not — see `test_adjust_exactIn_clampReadsThePreRunRegister`.
///
///      These run as ordinary fuzz tests under `forge test` and as proofs under
///      `kontrol prove`. Under Kontrol every `vm.assume` becomes a path constraint rather
///      than a sample filter, so the assumptions below define exactly the domain over
///      which each property is proven — read them as part of the specification.
///
///      MinRate is the first verified instruction that calls `ctx.runLoop()`. The harness
///      models the rest of the maker's program as a single stub instruction that writes a
///      caller-chosen `(swapAmountIn, swapAmountOut)` pair into the registers, so the run
///      loop's *result* is free while the loop itself is really executed. See
///      MinRateHarness for the encoding.
contract MinRateSpec is Test {
    MinRateHarness internal harness;

    /// @dev `TOKEN_LO < TOKEN_HI`, so `(TOKEN_LO, TOKEN_HI)` selects the `Lt` reading of
    ///      the args and `(TOKEN_HI, TOKEN_LO)` selects the `Gt` reading.
    address internal constant TOKEN_LO = address(0x1111);
    address internal constant TOKEN_HI = address(0x2222);

    function setUp() public {
        harness = new MinRateHarness();
    }

    /// @dev Args are two big-endian uint64s: the rate that applies when `tokenIn < tokenOut`
    ///      followed by the rate that applies otherwise.
    function _args(uint64 rateLt, uint64 rateGt) internal pure returns (bytes memory) {
        return abi.encodePacked(rateLt, rateGt);
    }

    /// @dev A one-instruction program for the harness stub: it makes `runLoop` return
    ///      exactly `(swapAmountIn, swapAmountOut)`.
    function _innerSwap(uint256 swapAmountIn, uint256 swapAmountOut) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0x00), uint8(64), swapAmountIn, swapAmountOut);
    }

    /// @dev `a * b` must not overflow, or the instruction panics before reaching the
    ///      comparison this specification is about.
    function _assumeMulSafe(uint256 a, uint256 b) internal pure {
        vm.assume(a == 0 || b <= type(uint256).max / a);
    }

    // -----------------------------------------------------------------------
    // Argument decoding
    // -----------------------------------------------------------------------

    /// @notice Bytes past the sixteenth are ignored.
    /// @dev Fixes the field widths: `rateLt` and `rateGt` are the first and second eight
    ///      bytes and nothing else in `args` is read, so a longer args block behaves
    ///      identically to the canonical one.
    function test_args_trailingBytesAreIgnored(
        uint64 rateLt,
        uint64 rateGt,
        uint256 trailing,
        uint256 preIn,
        uint256 swapIn,
        uint256 swapOut
    ) public {
        vm.assume(swapIn > 0 && swapOut > 0);
        _assumeMulSafe(swapIn, rateGt);
        _assumeMulSafe(rateLt, swapOut);
        _assumeMulSafe(preIn, rateGt);

        bytes memory program = _innerSwap(swapIn, swapOut);

        SwapRegisters memory exact =
            harness.adjustMinRate(true, preIn, 0, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), program);
        SwapRegisters memory padded = harness.adjustMinRate(
            true, preIn, 0, TOKEN_LO, TOKEN_HI, abi.encodePacked(rateLt, rateGt, trailing), program
        );

        assertEq(exact.amountIn, padded.amountIn, "only the first sixteen args bytes may be read");
        assertEq(exact.amountOut, padded.amountOut, "only the first sixteen args bytes may be read");
    }

    /// @notice `args.length` is not validated: an under-length args block is accepted.
    /// @dev `MinRateArgsBuilder.parse` (MinRate.sol:20-24) reads `bytes8(args)` and
    ///      `args.slice(8)` — the *unchecked* `Calldata.slice` overload, whose length is
    ///      computed as `args.length - 8` in assembly and so underflows on a short slice.
    ///      Neither read is bounds-checked, so the missing rate bytes come from whatever
    ///      calldata follows `args`. In this harness `args` is a separate ABI parameter and
    ///      a one-byte block decodes to `(rateIn, rateOut) = (0, 0)` — a vacuous floor that
    ///      accepts every rate. In the VM proper `args` is a slice of the maker's program,
    ///      so the bytes read are the *following instructions*, and `runLoop`'s
    ///      `pcs > length` check does not catch it because the declared args length is
    ///      what advances `pcs`. Pinned as an unguarded path, not as intended behaviour.
    function test_args_lengthIsNotValidated() public {
        SwapRegisters memory r = harness.requireMinRate(0, 0, TOKEN_LO, TOKEN_HI, hex"00", _innerSwap(1, 1));

        assertEq(r.amountIn, 1, "an under-length args block is decoded rather than rejected");
        assertEq(r.amountOut, 1, "an under-length args block is decoded rather than rejected");
    }

    // -----------------------------------------------------------------------
    // 0xb0 — the floor is exactly where the cross-multiplication says it is
    // -----------------------------------------------------------------------

    /// @notice Every rate at or above the floor is accepted, and the guard writes nothing.
    /// @dev The only assumptions are that neither side of the comparison overflows —
    ///      without them the instruction panics on the multiplication rather than
    ///      reaching the comparison, which is a different property (see
    ///      `test_require_revertsOnComparisonOverflow`).
    function test_require_acceptsAtOrAboveTheFloor(uint64 rateLt, uint64 rateGt, uint256 swapIn, uint256 swapOut)
        public
    {
        _assumeMulSafe(swapIn, rateGt);
        _assumeMulSafe(rateLt, swapOut);
        vm.assume(swapIn * rateGt >= uint256(rateLt) * swapOut);

        SwapRegisters memory r =
            harness.requireMinRate(0, 0, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), _innerSwap(swapIn, swapOut));

        assertEq(r.amountIn, swapIn, "the guard must not touch amountIn");
        assertEq(r.amountOut, swapOut, "the guard must not touch amountOut");
    }

    /// @notice Every rate strictly below the floor is rejected, with the exact error.
    function test_require_rejectsBelowTheFloor(uint64 rateLt, uint64 rateGt, uint256 swapIn, uint256 swapOut) public {
        _assumeMulSafe(swapIn, rateGt);
        _assumeMulSafe(rateLt, swapOut);
        vm.assume(swapIn * rateGt < uint256(rateLt) * swapOut);

        vm.expectRevert(
            abi.encodeWithSelector(MinRate.MinRateFailed.selector, swapIn, swapOut, uint256(rateLt), uint256(rateGt))
        );
        harness.requireMinRate(0, 0, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), _innerSwap(swapIn, swapOut));
    }

    /// @notice A rate sitting *exactly* on the floor is accepted.
    /// @dev `(swapIn, swapOut) = (rateIn * k, rateOut * k)` makes the two products equal
    ///      for every `k`, so this is the whole equality line, not one point on it.
    function test_require_acceptsExactlyAtTheFloor(uint64 rateLt, uint64 rateGt, uint256 k) public {
        vm.assume(rateLt > 0 && rateGt > 0);
        vm.assume(k <= type(uint256).max / uint256(rateLt) / uint256(rateGt));

        uint256 swapIn = uint256(rateLt) * k;
        uint256 swapOut = uint256(rateGt) * k;

        SwapRegisters memory r =
            harness.requireMinRate(0, 0, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), _innerSwap(swapIn, swapOut));

        assertEq(r.amountIn, swapIn, "a rate exactly at the floor must be accepted unchanged");
        assertEq(r.amountOut, swapOut, "a rate exactly at the floor must be accepted unchanged");
    }

    /// @notice One wei less input than the floor demands is rejected.
    /// @dev Paired with the test above this pins the boundary to the exact equality line:
    ///      the largest rejected point and the smallest accepted point are adjacent.
    function test_require_rejectsOneWeiBelowTheFloor(uint64 rateLt, uint64 rateGt, uint256 k) public {
        vm.assume(rateLt > 0 && rateGt > 0);
        vm.assume(k > 0);
        vm.assume(k <= type(uint256).max / uint256(rateLt) / uint256(rateGt));

        uint256 swapIn = uint256(rateLt) * k - 1;
        uint256 swapOut = uint256(rateGt) * k;

        vm.expectRevert(
            abi.encodeWithSelector(MinRate.MinRateFailed.selector, swapIn, swapOut, uint256(rateLt), uint256(rateGt))
        );
        harness.requireMinRate(0, 0, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), _innerSwap(swapIn, swapOut));
    }

    // -----------------------------------------------------------------------
    // Direction-dependent rate selection (args are Lt/Gt, not In/Out)
    // -----------------------------------------------------------------------

    /// @notice With `tokenIn > tokenOut` the roles of the two encoded rates are exchanged:
    ///         `rateGt` becomes the input rate and `rateLt` the output rate.
    /// @dev Stated as a rejection so the error payload witnesses which rate went where —
    ///      `MinRateFailed(..., rateIn, rateOut)` carries `(rateGt, rateLt)` here and
    ///      `(rateLt, rateGt)` in `test_require_rejectsBelowTheFloor`.
    function test_direction_gtOrderingExchangesTheRates(
        uint64 rateLt,
        uint64 rateGt,
        uint256 swapIn,
        uint256 swapOut
    ) public {
        _assumeMulSafe(swapIn, rateLt);
        _assumeMulSafe(rateGt, swapOut);
        vm.assume(swapIn * rateLt < uint256(rateGt) * swapOut);

        vm.expectRevert(
            abi.encodeWithSelector(MinRate.MinRateFailed.selector, swapIn, swapOut, uint256(rateGt), uint256(rateLt))
        );
        harness.requireMinRate(0, 0, TOKEN_HI, TOKEN_LO, _args(rateLt, rateGt), _innerSwap(swapIn, swapOut));
    }

    /// @notice The two token orderings enforce genuinely different floors.
    /// @dev The witness is the floor line of the `Lt` reading, `(swapIn, swapOut) =
    ///      (rateLt, rateGt)`. Under the `Gt` reading the same pair sits strictly below the
    ///      floor whenever `rateLt < rateGt`. So presenting the tokens the other way round
    ///      is not a relabelling — it selects a different constraint, which is exactly why
    ///      the maker signs the ordering into the args rather than into the token pair.
    function test_direction_separatesTheTwoFloors(uint64 rateLt, uint64 rateGt) public {
        vm.assume(rateLt > 0);
        vm.assume(rateLt < rateGt);

        bytes memory args = _args(rateLt, rateGt);
        bytes memory program = _innerSwap(rateLt, rateGt);

        // tokenIn < tokenOut: (rateIn, rateOut) = (rateLt, rateGt), the pair is on the floor.
        SwapRegisters memory r = harness.requireMinRate(0, 0, TOKEN_LO, TOKEN_HI, args, program);
        assertEq(r.amountIn, uint256(rateLt), "the Lt reading must accept its own floor");

        // tokenIn > tokenOut: (rateIn, rateOut) = (rateGt, rateLt), the same pair is below it.
        vm.expectRevert(
            abi.encodeWithSelector(
                MinRate.MinRateFailed.selector, uint256(rateLt), uint256(rateGt), uint256(rateGt), uint256(rateLt)
            )
        );
        harness.requireMinRate(0, 0, TOKEN_HI, TOKEN_LO, args, program);
    }

    /// @notice Reversing the token ordering is exactly equivalent to reversing the args.
    /// @dev The strongest statement of the direction-dependence: the two encoded rates are
    ///      swapped by `tokenIn < tokenOut` and nothing else about the instruction depends
    ///      on the tokens. Stated on the adjust variant because it returns observable
    ///      registers rather than merely succeeding.
    function test_direction_swappingTokensSwapsTheArgs(
        uint64 rateLt,
        uint64 rateGt,
        uint256 preIn,
        uint256 swapIn,
        uint256 swapOut
    ) public {
        vm.assume(rateLt > 0 && rateGt > 0);
        vm.assume(swapIn > 0 && swapOut > 0);
        _assumeMulSafe(swapIn, rateGt);
        _assumeMulSafe(rateLt, swapOut);
        _assumeMulSafe(preIn, rateGt);

        bytes memory program = _innerSwap(swapIn, swapOut);

        SwapRegisters memory lt =
            harness.adjustMinRate(true, preIn, 0, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), program);
        SwapRegisters memory gt =
            harness.adjustMinRate(true, preIn, 0, TOKEN_HI, TOKEN_LO, _args(rateGt, rateLt), program);

        assertEq(lt.amountIn, gt.amountIn, "token ordering must act only by swapping the two rates");
        assertEq(lt.amountOut, gt.amountOut, "token ordering must act only by swapping the two rates");
    }

    /// @notice `tokenIn == tokenOut` takes the `Gt` branch, since the test is a strict `<`.
    /// @dev A degenerate pair the VM should never present, recorded because the decoding is
    ///      total: there is no "equal" case, and the args are read as if `tokenIn > tokenOut`.
    function test_direction_equalTokensTakeTheGtBranch(uint64 rateLt, uint64 rateGt) public {
        vm.assume(rateGt > 0);
        vm.assume(rateGt < rateLt);

        bytes memory args = _args(rateLt, rateGt);
        // On the floor of the Gt reading `(rateIn, rateOut) = (rateGt, rateLt)`.
        bytes memory program = _innerSwap(rateGt, rateLt);

        SwapRegisters memory r = harness.requireMinRate(0, 0, TOKEN_LO, TOKEN_LO, args, program);
        assertEq(r.amountIn, uint256(rateGt), "equal tokens must read the args as the Gt case");

        // The same pair is below the floor under the Lt reading, so this is not vacuous.
        vm.expectRevert(
            abi.encodeWithSelector(
                MinRate.MinRateFailed.selector, uint256(rateGt), uint256(rateLt), uint256(rateLt), uint256(rateGt)
            )
        );
        harness.requireMinRate(0, 0, TOKEN_LO, TOKEN_HI, args, program);
    }

    // -----------------------------------------------------------------------
    // 0xb0 — guards and unguarded paths
    // -----------------------------------------------------------------------

    /// @notice The instruction must run before the swap amounts are computed.
    /// @dev Ordering guard: a program that placed 0xb0 after the swap would be checking a
    ///      rate the registers no longer describe.
    function test_require_revertsWhenBothAmountsPreSet(uint256 amountIn, uint256 amountOut, uint64 rateLt, uint64 rateGt)
        public
    {
        vm.assume(amountIn > 0 && amountOut > 0);

        vm.expectRevert(
            abi.encodeWithSelector(MinRate.MinRateExpectedBeforeSwapAmountsComputed.selector, amountIn, amountOut)
        );
        harness.requireMinRate(
            amountIn, amountOut, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), _innerSwap(amountIn, amountOut)
        );
    }

    /// @notice Exactly one pre-set register is allowed — that is the ordinary exact-in and
    ///         exact-out entry condition, so the guard above is not over-tight.
    function test_require_allowsOneAmountPreSet(uint256 amountIn) public {
        vm.assume(amountIn > 0);

        // rateIn == 0 makes the floor vacuous, isolating the ordering guard.
        SwapRegisters memory r =
            harness.requireMinRate(amountIn, 0, TOKEN_LO, TOKEN_HI, _args(0, 1), _innerSwap(1, 1));

        assertEq(r.amountIn, 1, "the ordering guard must accept a single pre-set register");
    }

    /// @notice A program that computes nothing satisfies the floor for *any* rate.
    /// @dev `0 * rateOut >= rateIn * 0` holds trivially. Unlike 0xb1, 0xb0 has no
    ///      `MinRateRunLoopExpectToComputeSwapAmounts` check, so a maker who places
    ///      RequireMinRate in a program whose swap leg can be skipped gets no protection
    ///      from it. Recorded as behaviour, not endorsed as intent.
    function test_require_acceptsANullSwapAtAnyRate(uint64 rateLt, uint64 rateGt) public {
        SwapRegisters memory r =
            harness.requireMinRate(0, 0, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), _innerSwap(0, 0));

        assertEq(r.amountIn, 0, "a null swap passes the floor check");
        assertEq(r.amountOut, 0, "a null swap passes the floor check");
    }

    /// @notice The cross-multiplication is unchecked arithmetic in the Solidity sense: it
    ///         panics rather than reverting with `MinRateFailed` when it overflows.
    /// @dev `rateOut` is only 64 bits, so this needs `swapAmountIn > 2^192`. It is
    ///         nonetheless a reachable path and the failure mode is a panic, not a
    ///         domain error.
    function test_require_revertsOnComparisonOverflow(uint64 rateGt, uint256 swapIn) public {
        vm.assume(rateGt > 0);
        vm.assume(swapIn > type(uint256).max / rateGt);

        // rateLt == 0 keeps the other product at zero, so the panic can only come from
        // `swapAmountIn * rateOut`.
        vm.expectRevert(stdError.arithmeticError);
        harness.requireMinRate(0, 0, TOKEN_LO, TOKEN_HI, _args(0, rateGt), _innerSwap(swapIn, 1));
    }

    /// @notice The guard never writes to the balance registers.
    function test_require_leavesEveryRegisterUntouched(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountNetPulled
    ) public {
        SwapRegisters memory r = harness.requireMinRateWithBalances(
            balanceIn, balanceOut, amountNetPulled, TOKEN_LO, TOKEN_HI, _args(0, 1), _innerSwap(3, 5)
        );

        assertEq(r.balanceIn, balanceIn, "balanceIn must be untouched");
        assertEq(r.balanceOut, balanceOut, "balanceOut must be untouched");
        assertEq(r.amountNetPulled, amountNetPulled, "amountNetPulled must be untouched");
        assertEq(r.amountIn, 3, "amountIn must be whatever the program computed");
        assertEq(r.amountOut, 5, "amountOut must be whatever the program computed");
    }

    // -----------------------------------------------------------------------
    // 0xb1 — no-op on a conforming rate
    // -----------------------------------------------------------------------

    /// @notice A rate at or above the floor is left alone on the exact-in leg.
    function test_adjust_exactIn_noOpAtOrAboveTheFloor(
        uint64 rateLt,
        uint64 rateGt,
        uint256 preIn,
        uint256 swapIn,
        uint256 swapOut
    ) public {
        vm.assume(swapIn > 0 && swapOut > 0);
        _assumeMulSafe(swapIn, rateGt);
        _assumeMulSafe(rateLt, swapOut);
        vm.assume(swapIn * rateGt >= uint256(rateLt) * swapOut);

        SwapRegisters memory r = harness.adjustMinRate(
            true, preIn, 0, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), _innerSwap(swapIn, swapOut)
        );

        assertEq(r.amountIn, swapIn, "a conforming rate must not be adjusted");
        assertEq(r.amountOut, swapOut, "a conforming rate must not be adjusted");
    }

    /// @notice A rate exactly on the floor is a no-op — the clamp is strictly below it.
    function test_adjust_exactIn_noOpExactlyAtTheFloor(uint64 rateLt, uint64 rateGt, uint256 preIn) public {
        vm.assume(rateLt > 0 && rateGt > 0);

        SwapRegisters memory r = harness.adjustMinRate(
            true, preIn, 0, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), _innerSwap(rateLt, rateGt)
        );

        assertEq(r.amountIn, uint256(rateLt), "the floor itself must not trigger the clamp");
        assertEq(r.amountOut, uint256(rateGt), "the floor itself must not trigger the clamp");
    }

    /// @notice A rate at or above the floor is left alone on the exact-out leg too.
    function test_adjust_exactOut_noOpAtOrAboveTheFloor(
        uint64 rateLt,
        uint64 rateGt,
        uint256 preOut,
        uint256 swapIn,
        uint256 swapOut
    ) public {
        vm.assume(swapIn > 0 && swapOut > 0);
        _assumeMulSafe(swapIn, rateGt);
        _assumeMulSafe(rateLt, swapOut);
        vm.assume(swapIn * rateGt >= uint256(rateLt) * swapOut);

        SwapRegisters memory r = harness.adjustMinRate(
            false, 0, preOut, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), _innerSwap(swapIn, swapOut)
        );

        assertEq(r.amountIn, swapIn, "a conforming rate must not be adjusted");
        assertEq(r.amountOut, swapOut, "a conforming rate must not be adjusted");
    }

    /// @notice `rateIn == 0` makes the floor vacuous, so the clamp never fires.
    /// @dev This is also why the exact-in leg cannot divide by zero: the only division is
    ///      by `rateIn`, and the branch guarding it is `_ * rateOut < 0`, which is
    ///      unsatisfiable. The exact-out leg has no such protection — see
    ///      `test_adjust_exactOut_panicsOnZeroRateOut`.
    function test_adjust_exactIn_zeroRateInNeverClamps(
        uint64 rateGt,
        uint256 preIn,
        uint256 swapIn,
        uint256 swapOut
    ) public {
        vm.assume(swapIn > 0 && swapOut > 0);
        _assumeMulSafe(swapIn, rateGt);

        SwapRegisters memory r =
            harness.adjustMinRate(true, preIn, 0, TOKEN_LO, TOKEN_HI, _args(0, rateGt), _innerSwap(swapIn, swapOut));

        assertEq(r.amountIn, swapIn, "a zero input rate must never clamp");
        assertEq(r.amountOut, swapOut, "a zero input rate must never clamp");
    }

    // -----------------------------------------------------------------------
    // 0xb1 — the clamp, and the direction it rounds
    // -----------------------------------------------------------------------

    /// @dev A program whose result sits strictly below the floor for every `rateIn >= 1`:
    ///      `1 * rateOut < rateIn * (rateOut + 1)`. The clamped value does not depend on
    ///      the program's amounts at all, only on the pre-run register and the two rates,
    ///      so fixing the trigger costs the clamp properties no generality.
    function _belowFloor(uint64 rateOut) internal pure returns (bytes memory) {
        return _innerSwap(1, uint256(rateOut) + 1);
    }

    /// @notice The exact-in clamp is `floor(amountIn * rateOut / rateIn)` — it rounds the
    ///         taker's output down, and by strictly less than one unit of the divisor.
    /// @dev Two-sided, so the rounding is pinned to exactly `floor`: the first assertion
    ///      alone would admit an implementation that rounds arbitrarily far down and
    ///      shortchanges the taker.
    function test_adjust_exactIn_clampFloorsTheOutput(uint64 rateLt, uint64 rateGt, uint256 preIn) public {
        vm.assume(rateLt > 0);
        _assumeMulSafe(preIn, rateGt);

        SwapRegisters memory r = harness.adjustMinRate(
            true, preIn, 0, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), _belowFloor(rateGt)
        );

        assertLe(r.amountOut * rateLt, preIn * rateGt, "the clamp must not round the output up");
        assertLt(
            preIn * rateGt - r.amountOut * rateLt, uint256(rateLt), "the clamp must not round down a whole divisor"
        );
        assertEq(r.amountIn, 1, "the exact-in clamp must not touch amountIn");
    }

    /// @notice The exact-out clamp is `ceil(amountOut * rateIn / rateOut)` — it rounds the
    ///         taker's input up, and by strictly less than one unit of the divisor.
    function test_adjust_exactOut_clampCeilsTheInput(uint64 rateLt, uint64 rateGt, uint256 preOut) public {
        vm.assume(rateLt > 0 && rateGt > 0);
        _assumeMulSafe(preOut, rateLt);
        // The ceiling can add up to `rateOut - 1`; keep the product it is compared against
        // representable.
        vm.assume(preOut * rateLt <= type(uint256).max - rateGt);

        SwapRegisters memory r = harness.adjustMinRate(
            false, 0, preOut, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), _belowFloor(rateGt)
        );

        assertGe(r.amountIn * rateGt, preOut * rateLt, "the clamp must not round the taker's input down");
        assertLt(
            r.amountIn * rateGt - preOut * rateLt, uint256(rateGt), "the clamp must not overshoot a whole divisor"
        );
        assertEq(r.amountOut, uint256(rateGt) + 1, "the exact-out clamp must not touch amountOut");
    }

    /// @notice After an exact-in clamp the registers satisfy 0xb0's floor condition.
    /// @dev The property that makes 0xb1 an *enforcement* of the floor rather than merely
    ///      an adjustment near it. It is stated on programs that leave the taker-fixed leg
    ///      alone (`swapAmountIn == amountIn`), which is the case the instruction is
    ///      written for. That is a genuine narrowing of the domain, not a convenience —
    ///      `test_adjust_exactIn_clampReadsThePreRunRegister` shows the conclusion is false
    ///      without it.
    function test_adjust_exactIn_clampEstablishesTheFloor(uint64 rateLt, uint64 rateGt, uint256 preIn) public {
        vm.assume(rateLt > 0);
        vm.assume(preIn > 0);
        _assumeMulSafe(preIn, rateGt);
        vm.assume(preIn * rateGt <= type(uint256).max - rateLt);

        // One unit of output above what the floor allows, so the clamp fires, and
        // `swapAmountIn == preIn` so the program has not moved the taker-fixed leg.
        uint256 swapOut = preIn * rateGt / rateLt + 1;

        SwapRegisters memory r = harness.adjustMinRate(
            true, preIn, 0, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), _innerSwap(preIn, swapOut)
        );

        assertGe(
            r.amountIn * rateGt, uint256(rateLt) * r.amountOut, "after the clamp the floor condition must hold"
        );
    }

    /// @notice The clamp divides the register as it was *before* `runLoop`, not the amount
    ///         `runLoop` returned — so when the program moves the taker-fixed leg, the
    ///         adjusted rate can still sit below the floor.
    /// @dev Concrete witness with a 1:1 floor. The program consumes 50 input and returns
    ///      100 output (rate 0.5, below the floor); the clamp recomputes the output from
    ///      the *pre-run* 100 and so leaves it at 100, producing final registers
    ///      `(50, 100)` — still 0.5, still below the floor. Any instruction sequenced
    ///      between AdjustMinRate and the swap that reduces `amountIn` (an input-side fee,
    ///      a partial fill) reaches this state. Asserted as observed behaviour so a change
    ///      to it is visible; see the accompanying report.
    function test_adjust_exactIn_clampReadsThePreRunRegister() public {
        SwapRegisters memory r =
            harness.adjustMinRate(true, 100, 0, TOKEN_LO, TOKEN_HI, _args(1, 1), _innerSwap(50, 100));

        assertEq(r.amountIn, 50, "amountIn is whatever the program left");
        assertEq(r.amountOut, 100, "the clamp is computed from the pre-runLoop amountIn");
        // The floor is 1:1 and the result is 0.5:1 — 0xb0 would reject these registers.
        assertLt(r.amountIn * 1, 1 * r.amountOut, "the floor is not enforced on this path");
    }

    /// @notice The clamp never touches the balance registers.
    function test_adjust_leavesBalanceRegistersUntouched(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountNetPulled,
        uint64 rateLt,
        uint64 rateGt,
        uint256 preIn
    ) public {
        vm.assume(rateLt > 0);
        _assumeMulSafe(preIn, rateGt);

        SwapRegisters memory r = harness.adjustMinRateWithBalances(
            true,
            balanceIn,
            balanceOut,
            preIn,
            amountNetPulled,
            TOKEN_LO,
            TOKEN_HI,
            _args(rateLt, rateGt),
            _belowFloor(rateGt)
        );

        assertEq(r.balanceIn, balanceIn, "balanceIn must be untouched");
        assertEq(r.balanceOut, balanceOut, "balanceOut must be untouched");
        assertEq(r.amountNetPulled, amountNetPulled, "amountNetPulled must be untouched");
    }

    // -----------------------------------------------------------------------
    // 0xb1 — guards and unguarded paths
    // -----------------------------------------------------------------------

    /// @notice 0xb1 carries the same ordering guard as 0xb0.
    function test_adjust_revertsWhenBothAmountsPreSet(
        bool isExactIn,
        uint256 amountIn,
        uint256 amountOut,
        uint64 rateLt,
        uint64 rateGt
    ) public {
        vm.assume(amountIn > 0 && amountOut > 0);

        vm.expectRevert(
            abi.encodeWithSelector(MinRate.MinRateExpectedBeforeSwapAmountsComputed.selector, amountIn, amountOut)
        );
        harness.adjustMinRate(
            isExactIn, amountIn, amountOut, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), _innerSwap(1, 1)
        );
    }

    /// @notice Unlike 0xb0, 0xb1 insists that the program actually computed both amounts.
    function test_adjust_revertsWhenRunLoopLeavesAmountInZero(uint256 swapOut, uint64 rateLt, uint64 rateGt) public {
        vm.assume(swapOut > 0);

        vm.expectRevert(
            abi.encodeWithSelector(MinRate.MinRateRunLoopExpectToComputeSwapAmounts.selector, uint256(0), swapOut)
        );
        harness.adjustMinRate(true, 0, 0, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), _innerSwap(0, swapOut));
    }

    function test_adjust_revertsWhenRunLoopLeavesAmountOutZero(uint256 swapIn, uint64 rateLt, uint64 rateGt) public {
        vm.assume(swapIn > 0);

        vm.expectRevert(
            abi.encodeWithSelector(MinRate.MinRateRunLoopExpectToComputeSwapAmounts.selector, swapIn, uint256(0))
        );
        harness.adjustMinRate(true, 0, 0, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), _innerSwap(swapIn, 0));
    }

    /// @notice A zero output rate on the exact-out leg is a division by zero, not a
    ///         domain error.
    /// @dev `rateOut == 0` makes every non-null rate "below the floor", so the branch is
    ///      taken and `ceilDiv(amountOut * rateIn, 0)` panics. `Math.ceilDiv` raises
    ///      `Panic(0x12)` on a zero divisor *before* looking at the numerator, so this
    ///      holds for every `preOut`, including zero — the property is stated over the
    ///      whole range for that reason. Nothing in the instruction rejects a zero rate,
    ///      and the exact-in leg has no equivalent hazard (see
    ///      `test_adjust_exactIn_zeroRateInNeverClamps`), so this is an asymmetry between
    ///      the two legs rather than a shared convention.
    function test_adjust_exactOut_panicsOnZeroRateOut(uint64 rateLt, uint256 preOut) public {
        vm.assume(rateLt > 0);
        _assumeMulSafe(preOut, rateLt);

        vm.expectRevert(stdError.divisionError);
        harness.adjustMinRate(false, 0, preOut, TOKEN_LO, TOKEN_HI, _args(rateLt, 0), _innerSwap(1, 1));
    }

    /// @notice Both rates zero is a no-op, not a panic.
    /// @dev The boundary of the panic above: the clamp branch needs `rateIn * swapOut > 0`,
    ///      so an all-zero args block leaves the registers alone on both legs. Worth
    ///      pinning because "zero rate" is otherwise the input a fuzzer would expect to be
    ///      uniformly hostile.
    function test_adjust_bothRatesZeroIsANoOp(bool isExactIn, uint256 pre, uint256 swapIn, uint256 swapOut) public {
        vm.assume(swapIn > 0 && swapOut > 0);

        SwapRegisters memory r = harness.adjustMinRate(
            isExactIn,
            isExactIn ? pre : 0,
            isExactIn ? 0 : pre,
            TOKEN_LO,
            TOKEN_HI,
            _args(0, 0),
            _innerSwap(swapIn, swapOut)
        );

        assertEq(r.amountIn, swapIn, "an all-zero rate must not clamp");
        assertEq(r.amountOut, swapOut, "an all-zero rate must not clamp");
    }
}
