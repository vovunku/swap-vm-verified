// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { SwapRegisters } from "../../src/libs/VM.sol";
import { PiecewiseLinearScale } from "../../src/instructions/PiecewiseLinearScale.sol";
import { PiecewiseLinearScaleHarness } from "./harnesses/PiecewiseLinearScaleHarness.sol";

/// @notice Kontrol specification for the PiecewiseLinearScale instructions
///         (opcodes 0x98 `PiecewiseLinearScaleBalanceIn`, 0x99 `PiecewiseLinearScaleBalanceOut`).
///
/// @dev Reference semantics, derived from `src/instructions/PiecewiseLinearScale.sol`.
///
///      **Argument layout** (`PiecewiseLinearScaleArgsBuilder.build`, :19-29):
///
///        args = [ 5 bytes start | 3 bytes scales[0] | 2 bytes durations[0]
///                              | 3 bytes scales[1] | 2 bytes durations[1] | ... ]
///
///        so with `k` points and `k - 1` durations, `args.length == 5 * k + 3`.
///
///      The three parsers (:32-52) are raw `calldataload`s at fixed strides and perform no
///      bounds checking:
///
///        start             = uint40(args[0  : 5])
///        scales[n]         = uint24(args[5 + 5n : 5 + 5n + 3])     // via args.slice(5)
///        durations[n]      = uint16(args[8 + 5n : 8 + 5n + 2])     // via args.slice(8)
///
///      **`_calcScaleNow`** (:118-151), entirely inside one `unchecked` block:
///
///        max = args.length / 5 - 1                                  // == durations.length
///        timeLeft = block.timestamp
///        if (timeLeft <= start) return scales[0] + 1                // clamp before start
///        timeLeft -= start
///        num = 0
///        while (durations[num] < timeLeft) {
///            timeLeft -= durations[num]
///            if (++num == max) return scales[max] + 1               // clamp after end
///        }
///        duration = durations[num]
///        return (timeLeft * scales[num+1] + (duration - timeLeft) * scales[num]) / duration + 1
///
///      **The instructions themselves** (:99-111) are three lines each:
///
///        require(amountIn == 0 || amountOut == 0, PiecewiseLinearScaleAmountsAlreadyComputed)
///        balanceIn  = balanceIn  * _calcScaleNow(args) >> 24        // 0x98
///        balanceOut = balanceOut * _calcScaleNow(args) >> 24        // 0x99
///
///      Four consequences drive the properties below.
///
///      * Every raw scale field is three bytes, so `S = scales[.] + 1` lies in
///        `[1, 2**24]`, and the interpolated value is a weighted average of two such fields
///        plus one, hence in the same range. `S <= 2**24` is exactly what makes
///        `balance * S >> 24 <= balance`: the instruction can only ever *shrink* a balance.
///        Contraction is the safety property; the range is the reason it holds.
///      * `S` is recovered exactly by scaling `balanceIn = 2**24`, since
///        `(2**24 * S) >> 24 == S` for every `S <= 2**24`. Every scale property below is
///        therefore stated against the real instruction bytecode with zero rounding loss,
///        via `harness.scaleOf`.
///      * The division at :149 is by `duration`, and the loop is only left through the
///        bottom when `durations[num] >= timeLeft`, with `timeLeft > 0` guaranteed by the
///        early return at :134. So `duration > 0` on every path that divides — the
///        instruction has no reachable division by zero, and none of the properties below
///        needs an assumption to avoid one.
///      * At an interpolation the operands are bounded by `timeLeft <= duration < 2**16`
///        and `scales[.] < 2**24`, so both products are below `2**40` and the sum below
///        `2**41`. The `unchecked` block at :149 cannot overflow. The *only* arithmetic in
///        the instruction that can overflow is the `balance * S` multiply at :102 / :110,
///        which is checked and panics.
///
///      **Two known bugs are pinned rather than assumed away**, both recorded in
///      `test/kontrol/analysis/FINDINGS.md`:
///
///        - `max = args.length / 5 - 1` at :128 is inside `unchecked`, so a short args block
///          makes the `++num == max` exit unreachable and the loop never terminates. See
///          the `test_argsLength_*` group.
///        - `unscaleValue` at :64 shifts left by 24 without an overflow check, so it
///          silently truncates above `type(uint232).max`. See `test_value_*`.
///
///      These run as ordinary fuzz tests under `forge test` and as proofs under
///      `kontrol prove`. Under Kontrol every `vm.assume` becomes a path constraint rather
///      than a sample filter, so the assumptions below define exactly the domain over which
///      each property is proven — read them as part of the specification.
///
///      **One test in this file must be excluded from `kontrol prove`:**
///      `test_argsLength_underThirteenBytesNeverTerminates`. It witnesses a non-terminating
///      loop by capping the gas of a low-level call and observing the failure. Gas is
///      disabled by default under Kontrol, so there the loop is genuinely infinite and the
///      proof would not converge. Prove with
///      `--mt 'PiecewiseLinearScaleSpec\.test_(?!argsLength_underThirteen)'` or select the
///      other properties explicitly. The companion `test_argsLength_tenBytesTerminates`
///      is safe to prove and brackets the bug from the other side.
contract PiecewiseLinearScaleSpec is Test {
    PiecewiseLinearScaleHarness internal harness;

    /// @dev The scale basis. `_calcScaleNow` returns a value in `[1, SCALE_ONE]`.
    uint256 internal constant SCALE_ONE = 1 << 24;

    /// @dev Shortest well-formed args block: two points, one duration. `5 + 3 + 2 + 3 = 13`,
    ///      so `max = 13 / 5 - 1 == 1 == durations.length`.
    uint256 internal constant MIN_ARGS_LENGTH = 13;

    /// @dev `runLoop` reads the args length from a single byte (`VM.sol:131`,
    ///      `and(shr(240, word), 0xff)`), so no instruction can ever be handed more than
    ///      255 args bytes. That is what bounds the segment count at `255 / 5 - 1 == 50`.
    uint256 internal constant MAX_ARGS_LENGTH = 255;

    function setUp() public {
        harness = new PiecewiseLinearScaleHarness();
    }

    // -----------------------------------------------------------------------
    // Args construction
    // -----------------------------------------------------------------------

    /// @dev Two points, one segment. 13 bytes, `max == 1`.
    function _args2(uint40 start, uint24 s0, uint16 d0, uint24 s1) internal pure returns (bytes memory) {
        return abi.encodePacked(start, s0, d0, s1);
    }

    /// @dev Three points, two segments. 18 bytes, `max == 2`.
    function _args3(uint40 start, uint24 s0, uint16 d0, uint24 s1, uint16 d1, uint24 s2)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(start, s0, d0, s1, d1, s2);
    }

    function _min(uint24 a, uint24 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _max(uint24 a, uint24 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    // =======================================================================
    // scaleValue / unscaleValue — pure, loop-free, no calldata parsing
    // =======================================================================

    /// @notice `scaleValue` never expands: `value * (scale + 1) >> 24 <= value`.
    /// @dev The one-value form of the contraction property, and the reason the instruction
    ///      is safe to place in front of a swap. It holds because `scale` is three bytes,
    ///      so the multiplier `scale + 1` never exceeds the `2**24` the shift divides by.
    ///
    ///      Stated with `try`/`catch` rather than an overflow assumption: the multiply is
    ///      checked and panics for `value > type(uint256).max / (scale + 1)`, and bounding
    ///      that away would put a symbolic division in the path condition. This form
    ///      quantifies over *every* `(uint256, uint24)` pair — see the note in
    ///      `test/kontrol/README.md`.
    function test_value_scaleNeverExpands(uint256 value, uint24 scale) public view {
        try harness.scaleValue(value, scale) returns (uint256 scaled) {
            assertLe(scaled, value, "scaling must never grow a value");
        } catch { /* the checked multiply overflowed: nothing to bound */ }
    }

    /// @notice `scaleValue(0, ·) == 0` and `scaleValue(·, 2**24 - 1)` is the identity.
    /// @dev The two extremes of the scale range, pinning that `2**24 - 1` really is "1.0"
    ///      and not `1.0 - 1ulp`. Together with the range property this fixes the encoding
    ///      convention: the field holds `S - 1`, not `S`.
    ///
    ///      `value` is taken as a `uint232` rather than filtered down from a `uint256`: the
    ///      checked multiply `value * 2**24` panics above that, and a `vm.assume` would give
    ///      the same domain with almost no fuzz coverage inside it.
    function test_value_maximalScaleIsTheIdentity(uint232 value) public view {
        assertEq(harness.scaleValue(value, type(uint24).max), value, "the largest scale must be exactly 1.0");
        assertEq(harness.scaleValue(0, type(uint24).max), 0, "zero scales to zero");
    }

    /// @notice `scaleValue(unscaleValue(v, s), s) == v` — the round trip documented at :62.
    /// @dev DOMAIN NARROWING, and a deliberate one: `value <= type(uint232).max`.
    ///      `unscaleValue` computes `value << 24` (:64) and Solidity's `<<` is not
    ///      overflow-checked, so above `type(uint232).max` the top bits are discarded
    ///      silently and the identity is false with no revert to signal it. This is
    ///      FINDINGS.md bug 4; the repo's own fuzz test applies the same bound
    ///      (`test/PiecewiseLinearScale.t.sol:68`). The violation is pinned separately in
    ///      `test_value_unscaleSilentlyTruncatesAboveUint232`, so the narrowing hides
    ///      nothing.
    ///
    ///      Inside the domain the identity is exact and needs no further assumption. With
    ///      `m = scale + 1 <= 2**24` and `u = ceil(v * 2**24 / m)`, `u * m` lies in
    ///      `[v * 2**24, v * 2**24 + m - 1]`, an interval of width `< 2**24`, so it floors
    ///      back to `v`; and `u * m <= v * 2**24 + m - 1 < 2**256`, so the checked multiply
    ///      inside `scaleValue` cannot overflow either.
    ///
    ///      The narrowing is expressed as a `uint232` parameter rather than a `vm.assume`
    ///      over a `uint256`: identical domain, but a filter would leave the fuzzer sampling
    ///      almost nothing inside it.
    function test_value_unscaleThenScaleIsIdentity(uint232 value, uint24 scale) public view {
        uint256 unscaled = harness.unscaleValue(value, scale);

        assertEq(harness.scaleValue(unscaled, scale), value, "unscale must be a right inverse of scale");
    }

    /// @notice `unscaleValue` returns the *smallest* preimage: one less already scales below.
    /// @dev Without this, `unscaleValue` could return any preimage — including a wastefully
    ///      large one, which for the documented use (:86-87, sizing an order so the final
    ///      scaling lands on the intended amount) would over-commit the maker's balance.
    ///      Same `uint232` domain as the round trip above, and for the same reason.
    function test_value_unscaleIsMinimal(uint232 value, uint24 scale) public view {
        uint256 unscaled = harness.unscaleValue(value, scale);
        vm.assume(unscaled > 0);

        assertLt(harness.scaleValue(unscaled - 1, scale), value, "no smaller preimage may exist");
    }

    /// @notice BUG (FINDINGS.md 4): `unscaleValue` truncates silently above `type(uint232).max`.
    /// @dev `value << 24` is not overflow-checked. At `value == 2**232` the shift produces
    ///      exactly `2**256`, which wraps to zero, so the function returns `0` — and the
    ///      round trip yields `0` instead of `2**232` with no revert anywhere. Concrete
    ///      witness rather than a fuzzed one, because it is a single point of the domain and
    ///      the whole content is that the function is silently wrong there.
    ///      `value <= type(uint232).max` is an undocumented precondition.
    function test_value_unscaleSilentlyTruncatesAboveUint232() public view {
        uint256 value = uint256(type(uint232).max) + 1; // 2**232

        assertEq(harness.unscaleValue(value, 0), 0, "value << 24 wraps to zero and is not caught");
        assertTrue(harness.scaleValue(harness.unscaleValue(value, 0), 0) != value, "the round trip is broken here");
    }

    // =======================================================================
    // Scale range — 1 <= S <= 2**24
    // =======================================================================

    /// @notice For every well-formed two-point schedule and every instant, `1 <= S <= 2**24`.
    /// @dev The bound that makes the instruction contractive. `S` is recovered exactly (see
    ///      `scaleOf`), so this is a statement about the instruction's own output, not about
    ///      a model of it. Every field of the schedule and the current instant are symbolic;
    ///      only the *shape* (two points) is fixed, which fixes the loop trip count at zero
    ///      or one and keeps the goal loop-free.
    function test_scale_rangeTwoPointSchedule(uint40 start, uint24 s0, uint16 d0, uint24 s1, uint256 nowTs) public {
        vm.warp(nowTs);

        uint256 scale = harness.scaleOf(_args2(start, s0, d0, s1));

        assertGe(scale, 1, "the scale is at least 1");
        assertLe(scale, SCALE_ONE, "the scale never exceeds 1.0");
    }

    /// @notice Same bound on a three-point schedule, which really executes the loop.
    function test_scale_rangeThreePointSchedule(
        uint40 start,
        uint24 s0,
        uint16 d0,
        uint24 s1,
        uint16 d1,
        uint24 s2,
        uint256 nowTs
    ) public {
        vm.warp(nowTs);

        uint256 scale = harness.scaleOf(_args3(start, s0, d0, s1, d1, s2));

        assertGe(scale, 1, "the scale is at least 1");
        assertLe(scale, SCALE_ONE, "the scale never exceeds 1.0");
    }

    /// @notice The same bound for an *arbitrary* args block of any length the VM can deliver.
    /// @dev The general form. `args.length <= 255` is not a convenience: `runLoop` reads the
    ///      args length from a single byte (`VM.sol:131`), so no longer block can reach the
    ///      instruction, and `max = args.length / 5 - 1 <= 50`. `args.length >= 13` excludes
    ///      exactly the non-terminating region pinned below. Between them the loop runs at
    ///      most 50 iterations and every continuation branch terminates it, so
    ///      `--bmc-depth 51` closes the goal *unconditionally* rather than up to a bound.
    ///
    ///      Note this quantifies over malformed-but-long args too — lengths that are not
    ///      `5k + 3`, and blocks whose trailing scale field runs a byte or two past the end.
    ///      Those reads are not bounds-checked and simply yield zero-extended fields, which
    ///      is still a valid `uint24`, so the range property survives them.
    function test_scale_rangeAnyLengthArgs(bytes calldata args, uint256 nowTs) public {
        vm.assume(args.length >= MIN_ARGS_LENGTH);
        vm.assume(args.length <= MAX_ARGS_LENGTH);
        vm.warp(nowTs);

        uint256 scale = harness.scaleOf(args);

        assertGe(scale, 1, "the scale is at least 1");
        assertLe(scale, SCALE_ONE, "the scale never exceeds 1.0");
    }

    // =======================================================================
    // Non-expansion — balance' <= balance
    // =======================================================================

    /// @notice 0x98 never grows `balanceIn`.
    /// @dev The safety property the whole instruction rests on: it is documented as a
    ///      *shrink* (:97, :105) and a maker relies on that when placing it in front of a
    ///      swap. `try`/`catch` rather than an overflow assumption, so the theorem covers
    ///      every `uint256` balance; the reverting inputs are exactly the checked-multiply
    ///      panic at :102 and carry no claim.
    function test_scaleIn_neverExpandsBalanceIn(
        uint256 balanceIn,
        uint40 start,
        uint24 s0,
        uint16 d0,
        uint24 s1,
        uint256 nowTs
    ) public {
        vm.warp(nowTs);

        try harness.scaleBalanceIn(balanceIn, 0, 0, 0, 0, _args2(start, s0, d0, s1)) returns (
            SwapRegisters memory r
        ) {
            assertLe(r.balanceIn, balanceIn, "0x98 must never grow balanceIn");
        } catch { /* the checked multiply overflowed: nothing to bound */ }
    }

    /// @notice 0x99 never grows `balanceOut`.
    function test_scaleOut_neverExpandsBalanceOut(
        uint256 balanceOut,
        uint40 start,
        uint24 s0,
        uint16 d0,
        uint24 s1,
        uint256 nowTs
    ) public {
        vm.warp(nowTs);

        try harness.scaleBalanceOut(0, balanceOut, 0, 0, 0, _args2(start, s0, d0, s1)) returns (
            SwapRegisters memory r
        ) {
            assertLe(r.balanceOut, balanceOut, "0x99 must never grow balanceOut");
        } catch { /* the checked multiply overflowed: nothing to bound */ }
    }

    /// @notice Non-expansion for an arbitrary args block of any length the VM can deliver.
    function test_scaleIn_neverExpandsForAnyLengthArgs(uint256 balanceIn, bytes calldata args, uint256 nowTs)
        public
    {
        vm.assume(args.length >= MIN_ARGS_LENGTH);
        vm.assume(args.length <= MAX_ARGS_LENGTH);
        vm.warp(nowTs);

        try harness.scaleBalanceIn(balanceIn, 0, 0, 0, 0, args) returns (SwapRegisters memory r) {
            assertLe(r.balanceIn, balanceIn, "0x98 must never grow balanceIn");
        } catch { /* the checked multiply overflowed: nothing to bound */ }
    }

    /// @notice A zero balance stays zero, so the contraction bound is attained at the bottom.
    /// @dev Rules out an implementation that is contractive only because it is trivial, and
    ///      confirms the instruction is total at the degenerate input.
    function test_scaleIn_zeroBalanceStaysZero(uint40 start, uint24 s0, uint16 d0, uint24 s1, uint256 nowTs) public {
        vm.warp(nowTs);

        SwapRegisters memory r = harness.scaleBalanceIn(0, 0, 0, 0, 0, _args2(start, s0, d0, s1));

        assertEq(r.balanceIn, 0, "zero must scale to zero");
    }

    // =======================================================================
    // Clamping outside the schedule
    // =======================================================================

    /// @notice At or before `start` the scale is the first point's, for every schedule shape.
    /// @dev The early return at :134. Stated with `<=`, not `<`: the instant `start` itself
    ///      belongs to the clamp, not to the first segment. That is not a free choice — the
    ///      first segment's interpolation at `timeLeft == 0` would give
    ///      `(0 * s1 + d0 * s0) / d0 + 1 == s0 + 1` as well, so the two agree and the
    ///      schedule is continuous at its left endpoint. This test pins which branch runs;
    ///      `test_knot_startOfScheduleAgreesWithInterpolation` pins that they agree.
    ///
    ///      `nowTs` is a `uint40` rather than a `uint256`: `start` is a five-byte field, so
    ///      `nowTs <= start` already forces `nowTs < 2**40`. The narrower type is the same
    ///      domain, sampled uniformly instead of by rejection.
    function test_clamp_beforeStartReturnsFirstScale(
        uint40 start,
        uint24 s0,
        uint16 d0,
        uint24 s1,
        uint16 d1,
        uint24 s2,
        uint40 nowTs
    ) public {
        vm.assume(nowTs <= start);
        vm.warp(nowTs);

        assertEq(
            harness.scaleOf(_args2(start, s0, d0, s1)), uint256(s0) + 1, "before start the first scale applies"
        );
        assertEq(
            harness.scaleOf(_args3(start, s0, d0, s1, d1, s2)),
            uint256(s0) + 1,
            "before start the first scale applies, whatever follows"
        );
    }

    /// @notice Past the end of a two-point schedule the scale is the last point's.
    /// @dev The `++num == max` return at :142. `elapsed > d0` is the strict inequality that
    ///      takes the loop's continuation branch; `elapsed == d0` is the knot and is covered
    ///      by `test_knot_endOfScheduleIsExact`, which gives the same answer through the
    ///      interpolation instead.
    function test_clamp_afterEndReturnsLastScaleTwoPoint(
        uint40 start,
        uint24 s0,
        uint16 d0,
        uint24 s1,
        uint256 elapsed
    ) public {
        vm.assume(elapsed > d0);
        vm.assume(elapsed <= type(uint256).max - start); // keep the warp target representable
        vm.warp(uint256(start) + elapsed);

        assertEq(harness.scaleOf(_args2(start, s0, d0, s1)), uint256(s1) + 1, "after the end the last scale applies");
    }

    /// @notice Past the end of a three-point schedule the scale is the last point's.
    /// @dev Two loop iterations, so this is the first property that really exercises the
    ///      `++num == max` counter rather than the single-step case.
    function test_clamp_afterEndReturnsLastScaleThreePoint(
        uint40 start,
        uint24 s0,
        uint16 d0,
        uint24 s1,
        uint16 d1,
        uint24 s2,
        uint256 elapsed
    ) public {
        vm.assume(elapsed > uint256(d0) + uint256(d1));
        vm.assume(elapsed <= type(uint256).max - start);
        vm.warp(uint256(start) + elapsed);

        assertEq(
            harness.scaleOf(_args3(start, s0, d0, s1, d1, s2)),
            uint256(s2) + 1,
            "after the end the last scale applies"
        );
    }

    /// @notice A zero-length segment is skipped rather than dividing by zero.
    /// @dev `d0 == 0` makes `durations[0] < timeLeft` true for every `timeLeft > 0`, so the
    ///      loop always steps over it and the division at :149 is never reached with a zero
    ///      divisor. Worth pinning explicitly: a zero duration is the input a reader expects
    ///      to be hostile, and `PiecewiseLinearScaleArgsBuilder.build` does not reject it.
    function test_clamp_zeroDurationSegmentIsSkipped(uint40 start, uint24 s0, uint24 s1, uint256 elapsed) public {
        vm.assume(elapsed > 0);
        vm.assume(elapsed <= type(uint256).max - start);
        vm.warp(uint256(start) + elapsed);

        assertEq(
            harness.scaleOf(_args2(start, s0, 0, s1)), uint256(s1) + 1, "a zero-width segment must not divide by zero"
        );
    }

    // =======================================================================
    // Knot exactness — the interpolation divides exactly at a segment boundary
    // =======================================================================

    /// @notice At the right endpoint of the only segment the scale is exactly `s1 + 1`.
    /// @dev `timeLeft == duration == d0`, so :149 evaluates
    ///      `(d0 * s1 + 0 * s0) / d0 + 1`. The numerator is an exact multiple of the
    ///      divisor, so the floor contributes nothing and the schedule passes exactly
    ///      through its declared point — no off-by-one-ulp drift at the knot. This is the
    ///      property that makes the piecewise curve well defined: the interpolated value and
    ///      the clamped value coincide there, which is why
    ///      `test_clamp_afterEndReturnsLastScaleTwoPoint` can use a strict inequality
    ///      without leaving a gap.
    function test_knot_endOfScheduleIsExact(uint40 start, uint24 s0, uint16 d0, uint24 s1) public {
        vm.assume(d0 > 0);
        vm.warp(uint256(start) + uint256(d0));

        assertEq(harness.scaleOf(_args2(start, s0, d0, s1)), uint256(s1) + 1, "the knot must be hit exactly");
    }

    /// @notice At an *interior* knot the scale is exactly that point's, with no rounding.
    /// @dev Three points, `elapsed == d0`: the loop condition `d0 < d0` is false, so the
    ///      instruction interpolates on segment 0 at its right endpoint and must land on
    ///      `s1 + 1` exactly. Distinct from the test above because here the schedule
    ///      *continues* past the knot — the value comes from the interpolation branch while
    ///      a further segment still exists, which is the case a rounding error would show
    ///      up in as a discontinuity between the two segments.
    function test_knot_interiorKnotIsExact(uint40 start, uint24 s0, uint16 d0, uint24 s1, uint16 d1, uint24 s2)
        public
    {
        vm.assume(d0 > 0);
        vm.warp(uint256(start) + uint256(d0));

        assertEq(
            harness.scaleOf(_args3(start, s0, d0, s1, d1, s2)),
            uint256(s1) + 1,
            "an interior knot must be hit exactly"
        );
    }

    /// @notice The schedule is continuous at its left endpoint: clamp and interpolation agree.
    /// @dev At `elapsed == 1` on a one-tick segment (`d0 == 1`) the interpolation gives
    ///      `s1 + 1`; at `elapsed == 0` the clamp gives `s0 + 1`, which is also what the
    ///      interpolation formula would give at `timeLeft == 0`. Stated as the second knot
    ///      of the same segment so both endpoints of a segment are pinned exactly.
    function test_knot_startOfScheduleAgreesWithInterpolation(uint40 start, uint24 s0, uint24 s1) public {
        vm.warp(uint256(start));
        assertEq(harness.scaleOf(_args2(start, s0, 1, s1)), uint256(s0) + 1, "the left knot is the first scale");

        vm.warp(uint256(start) + 1);
        assertEq(harness.scaleOf(_args2(start, s0, 1, s1)), uint256(s1) + 1, "the right knot is the second scale");
    }

    // =======================================================================
    // Interpolation inside a segment
    // =======================================================================

    /// @notice Inside a segment the scale lies between the two endpoint scales.
    /// @dev The averaging property the source claims at :148 without proof. It holds in both
    ///      directions of travel — a rising and a falling schedule are the same code — so it
    ///      is stated with `min`/`max` rather than assuming `s0 >= s1`. Together with
    ///      knot exactness this says the segment really is a monotone interpolation between
    ///      its endpoints and never overshoots either of them, which is what a maker signing
    ///      a decay schedule is relying on.
    ///
    ///      `elapsed` is a `uint16` bounded by `d0`, so this is the interpolation branch by
    ///      construction; the branches outside the segment are covered by the clamp tests.
    function test_interp_liesBetweenEndpointScales(uint40 start, uint24 s0, uint16 d0, uint24 s1, uint16 elapsed)
        public
    {
        vm.assume(d0 > 0);
        vm.assume(elapsed > 0 && elapsed <= d0);
        vm.warp(uint256(start) + uint256(elapsed));

        uint256 scale = harness.scaleOf(_args2(start, s0, d0, s1));

        assertGe(scale, _min(s0, s1) + 1, "the interpolation must not undershoot both endpoints");
        assertLe(scale, _max(s0, s1) + 1, "the interpolation must not overshoot both endpoints");
    }

    /// @notice A constant schedule is exactly constant, at every instant.
    /// @dev `s0 == s1` collapses :149 to `(timeLeft * s + (d0 - timeLeft) * s) / d0 + 1 ==
    ///      s + 1` — an exact division for every `timeLeft`, so there is no accumulated
    ///      rounding drift anywhere inside the segment, and the clamp branches give the same
    ///      answer. Quantified over *all* `nowTs`, so it covers every branch of
    ///      `_calcScaleNow` at once and is the cheapest end-to-end check that the arg
    ///      decoding puts each field where the formula expects it.
    function test_interp_constantScheduleIsExactEverywhere(uint40 start, uint24 s, uint16 d0, uint256 nowTs) public {
        vm.warp(nowTs);

        assertEq(
            harness.scaleOf(_args2(start, s, d0, s)), uint256(s) + 1, "a flat schedule must not drift"
        );
    }

    /// @notice The interpolation is the exact floor of the linear blend — no slack either way.
    /// @dev Two-sided, so the rounding is pinned to exactly one floor: the first assertion
    ///      alone would admit an implementation that rounds arbitrarily far down. Written
    ///      against the cross-multiplied form so the spec contains no division of its own.
    ///      The products are below `2**41` (`elapsed <= d0 < 2**16`, `s· < 2**24`), so
    ///      nothing here can overflow.
    function test_interp_isTheExactFloorOfTheBlend(uint40 start, uint24 s0, uint16 d0, uint24 s1, uint16 elapsed)
        public
    {
        vm.assume(d0 > 0);
        vm.assume(elapsed > 0 && elapsed <= d0);
        vm.warp(uint256(start) + uint256(elapsed));

        uint256 scale = harness.scaleOf(_args2(start, s0, d0, s1));
        uint256 blend = uint256(elapsed) * s1 + (uint256(d0) - elapsed) * s0;

        assertLe((scale - 1) * d0, blend, "the interpolation must not round up");
        assertLt(blend - (scale - 1) * d0, d0, "the interpolation must not round down a whole divisor");
    }

    // =======================================================================
    // The ordering guard — both directions
    // =======================================================================

    /// @notice 0x98 reverts, with the exact selector and payload, when both amounts are set.
    /// @dev Ordering guard (:100): the instruction rewrites a *balance*, so running it after
    ///      the swap amounts exist would price against reserves the amounts no longer
    ///      describe. The payload carries both registers, so this also pins that the error
    ///      reports the observed state rather than a placeholder.
    function test_guard_scaleInRevertsWhenBothAmountsSet(
        uint256 balanceIn,
        uint256 amountIn,
        uint256 amountOut,
        uint40 start,
        uint24 s0,
        uint16 d0,
        uint24 s1
    ) public {
        vm.assume(amountIn != 0 && amountOut != 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                PiecewiseLinearScale.PiecewiseLinearScaleAmountsAlreadyComputed.selector, amountIn, amountOut
            )
        );
        harness.scaleBalanceIn(balanceIn, 0, amountIn, amountOut, 0, _args2(start, s0, d0, s1));
    }

    /// @notice 0x99 carries the same guard, with the same selector and payload.
    function test_guard_scaleOutRevertsWhenBothAmountsSet(
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint40 start,
        uint24 s0,
        uint16 d0,
        uint24 s1
    ) public {
        vm.assume(amountIn != 0 && amountOut != 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                PiecewiseLinearScale.PiecewiseLinearScaleAmountsAlreadyComputed.selector, amountIn, amountOut
            )
        );
        harness.scaleBalanceOut(0, balanceOut, amountIn, amountOut, 0, _args2(start, s0, d0, s1));
    }

    /// @notice The converse: whenever either amount is zero the guard passes and the
    ///         instruction completes.
    /// @dev The direction that makes the guard a specification rather than a one-sided
    ///      bound — without it, an instruction that reverted unconditionally would satisfy
    ///      the two tests above. Covers all three admissible states: `(0, x)`, `(x, 0)` and
    ///      `(0, 0)`.
    ///
    ///      `balanceIn` is fixed at `2**24` so that `balanceIn * S <= 2**48` and the checked
    ///      multiply at :102 cannot panic — the claim here is about the guard, and a panic
    ///      from unrelated arithmetic would make "does not revert" unprovable for reasons
    ///      that have nothing to do with it. The overflow path is covered separately by the
    ///      `try`/`catch` in the non-expansion properties.
    ///
    ///      The admissible set is parameterised (`zeroOut` picks which register is cleared,
    ///      and `amount` may itself be zero, giving the `(0, 0)` case) rather than carved
    ///      out of two free `uint256`s with `vm.assume(amountIn == 0 || amountOut == 0)`.
    ///      The domain is identical; the filter form is a measure-zero slice the fuzzer
    ///      would essentially never sample.
    function test_guard_acceptsWheneverEitherAmountIsZero(
        bool zeroOut,
        uint256 amount,
        uint40 start,
        uint24 s0,
        uint16 d0,
        uint24 s1,
        uint256 nowTs
    ) public {
        (uint256 amountIn, uint256 amountOut) = zeroOut ? (amount, uint256(0)) : (uint256(0), amount);
        vm.warp(nowTs);

        SwapRegisters memory rIn =
            harness.scaleBalanceIn(SCALE_ONE, 0, amountIn, amountOut, 0, _args2(start, s0, d0, s1));
        SwapRegisters memory rOut =
            harness.scaleBalanceOut(0, SCALE_ONE, amountIn, amountOut, 0, _args2(start, s0, d0, s1));

        assertGe(rIn.balanceIn, 1, "0x98 must complete when the guard passes");
        assertLe(rIn.balanceIn, SCALE_ONE, "0x98 must complete when the guard passes");
        assertGe(rOut.balanceOut, 1, "0x99 must complete when the guard passes");
        assertLe(rOut.balanceOut, SCALE_ONE, "0x99 must complete when the guard passes");
    }

    /// @notice The guard runs before the args are parsed at all.
    /// @dev `require` is the first statement of both instructions (:100, :108), so a
    ///      program that both mis-orders the instruction *and* supplies a short args block
    ///      gets the domain error rather than the non-terminating loop pinned below. Worth
    ///      recording as the precedence between the two failure modes: the guard is the one
    ///      a maker actually observes.
    function test_guard_precedesArgumentParsing(uint256 amountIn, uint256 amountOut) public {
        vm.assume(amountIn != 0 && amountOut != 0);
        vm.warp(1_000_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                PiecewiseLinearScale.PiecewiseLinearScaleAmountsAlreadyComputed.selector, amountIn, amountOut
            )
        );
        // Four bytes: the args block that makes `_calcScaleNow` loop forever.
        harness.scaleBalanceIn(SCALE_ONE, 0, amountIn, amountOut, 0, hex"00000000");
    }

    // =======================================================================
    // Register isolation
    // =======================================================================

    /// @notice 0x98 writes `balanceIn` and nothing else.
    /// @dev The instruction is documented (:98) as unsafe to combine with
    ///      `_invalidateTokenIn1D` precisely because it mutates `balanceIn`; that warning is
    ///      only meaningful if `balanceIn` is the *only* register it mutates. `balanceIn` is
    ///      fixed at `2**24` so the call cannot panic on the multiply and the isolation
    ///      claim is not vacuously satisfied by a revert.
    function test_isolation_scaleInTouchesOnlyBalanceIn(
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountNetPulled,
        uint40 start,
        uint24 s0,
        uint16 d0,
        uint24 s1,
        uint256 nowTs
    ) public {
        vm.warp(nowTs);

        SwapRegisters memory r = harness.scaleBalanceIn(
            SCALE_ONE, balanceOut, amountIn, 0, amountNetPulled, _args2(start, s0, d0, s1)
        );

        assertEq(r.balanceOut, balanceOut, "0x98 must not touch balanceOut");
        assertEq(r.amountIn, amountIn, "0x98 must not touch amountIn");
        assertEq(r.amountOut, 0, "0x98 must not touch amountOut");
        assertEq(r.amountNetPulled, amountNetPulled, "0x98 must not touch amountNetPulled");
    }

    /// @notice 0x99 writes `balanceOut` and nothing else.
    function test_isolation_scaleOutTouchesOnlyBalanceOut(
        uint256 balanceIn,
        uint256 amountOut,
        uint256 amountNetPulled,
        uint40 start,
        uint24 s0,
        uint16 d0,
        uint24 s1,
        uint256 nowTs
    ) public {
        vm.warp(nowTs);

        SwapRegisters memory r = harness.scaleBalanceOut(
            balanceIn, SCALE_ONE, 0, amountOut, amountNetPulled, _args2(start, s0, d0, s1)
        );

        assertEq(r.balanceIn, balanceIn, "0x99 must not touch balanceIn");
        assertEq(r.amountIn, 0, "0x99 must not touch amountIn");
        assertEq(r.amountOut, amountOut, "0x99 must not touch amountOut");
        assertEq(r.amountNetPulled, amountNetPulled, "0x99 must not touch amountNetPulled");
    }

    /// @notice The two opcodes differ only in which register they write.
    /// @dev Same schedule, same instant, same input balance: the scale each computes must be
    ///      identical. Rules out a divergence between the two copies of the three-line body
    ///      — they call the same `_calcScaleNow`, and this is the statement that they do.
    function test_isolation_bothOpcodesComputeTheSameScale(
        uint40 start,
        uint24 s0,
        uint16 d0,
        uint24 s1,
        uint16 d1,
        uint24 s2,
        uint256 nowTs
    ) public {
        vm.warp(nowTs);
        bytes memory args = _args3(start, s0, d0, s1, d1, s2);

        SwapRegisters memory rIn = harness.scaleBalanceIn(SCALE_ONE, SCALE_ONE, 0, 0, 0, args);
        SwapRegisters memory rOut = harness.scaleBalanceOut(SCALE_ONE, SCALE_ONE, 0, 0, 0, args);

        assertEq(rIn.balanceIn, rOut.balanceOut, "both opcodes must apply the same scale");
        assertEq(rIn.balanceOut, SCALE_ONE, "0x98 must leave balanceOut alone");
        assertEq(rOut.balanceIn, SCALE_ONE, "0x99 must leave balanceIn alone");
    }

    // =======================================================================
    // Args length — the non-terminating loop (FINDINGS.md bug 2)
    // =======================================================================

    /// @notice Ten args bytes already terminate: the bug is a short-args bug, not a
    ///         well-formedness bug.
    /// @dev `10 / 5 - 1 == 1`, so `max == 1` and the `++num == max` exit at :142 is
    ///      reachable on the first iteration. The block is still malformed — `scales[1]`
    ///      is read from `args[10:13]`, three bytes past the end, and comes back zero — but
    ///      it terminates, which is what separates it from the cases below. Ten is the
    ///      smallest length that does.
    function test_argsLength_tenBytesTerminates(uint256 elapsed) public {
        vm.assume(elapsed > 0 && elapsed < 1e18);
        vm.warp(elapsed);

        // start == 0, scales[0] == 0, durations[0] == 0, scales[1] read out of bounds as 0.
        assertEq(harness.scaleOf(hex"00000000000000000000"), 1, "ten bytes must terminate");
    }

    /// @notice BUG (FINDINGS.md bug 2): fewer than ten args bytes make the loop
    ///         non-terminating — out of gas, not a revert.
    /// @dev `max = args.length / 5 - 1` at :128 is inside `unchecked`. There are two
    ///      distinct failure regions, and FINDINGS.md records only the first:
    ///
    ///        - `args.length <= 4`: `args.length / 5 == 0` and the subtraction underflows,
    ///          so `max == type(uint256).max` and `++num == max` is unreachable in practice.
    ///        - `5 <= args.length <= 9`: `args.length / 5 == 1` and `max == 0`. No underflow
    ///          — but `num` starts at `0` and is *pre-incremented* before the comparison, so
    ///          `++num == 0` is equally unreachable. Same non-termination, different cause.
    ///          This second region is a refinement of the finding, not a restatement of it.
    ///
    ///      In both cases the duration words are read past the end of `args`, where
    ///      `calldataload` returns zero, so `timeLeft -= 0` is a no-op and the loop makes no
    ///      progress. The `Calldata.slice` overload used at :123/:125 does no bounds
    ///      checking by design, so nothing intervenes. `runLoop` cannot catch it either:
    ///      its `pcs > length` check (`VM.sol:143`) validates the *declared* args length,
    ///      which is what advanced `pcs` in the first place.
    ///
    ///      DO NOT PROVE THIS ONE. It is witnessed by capping the gas of a low-level call
    ///      and observing that it fails. Gas is disabled by default under Kontrol, so there
    ///      the loop is genuinely infinite and the proof would never converge. Exclude it
    ///      from `kontrol prove`; see the contract doc comment.
    function test_argsLength_underThirteenBytesNeverTerminates() public {
        vm.warp(1_000_000);

        // args.length == 4: `4 / 5 - 1` underflows to type(uint256).max.
        (bool okUnderflow,) =
            address(harness).staticcall{ gas: 1_000_000 }(abi.encodeCall(harness.scaleOf, (hex"00000000")));
        assertFalse(okUnderflow, "a four-byte args block must be rejected, not looped on forever");

        // args.length == 9: no underflow, but `max == 0` and `++num == 0` is unreachable.
        (bool okMaxZero,) =
            address(harness).staticcall{ gas: 1_000_000 }(abi.encodeCall(harness.scaleOf, (hex"000000000000000000")));
        assertFalse(okMaxZero, "a nine-byte args block must be rejected, not looped on forever");

        // Contrast: ten bytes terminates and returns a scale.
        (bool okTen,) = address(harness).staticcall{ gas: 1_000_000 }(
            abi.encodeCall(harness.scaleOf, (hex"00000000000000000000"))
        );
        assertTrue(okTen, "ten bytes must terminate");
    }
}
