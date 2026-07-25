// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { PiecewiseLinearScaleArgsBuilder } from "../../../../src/instructions/PiecewiseLinearScale.sol";

/// @notice Executed witness for the silent truncation in `unscaleValue`, plus the reachability
///         check that decides it is a documentation defect and not a vulnerability.
///
/// @dev     forge test --match-path test/kontrol/analysis/repro/PiecewiseLinearScaleUnscaleTruncationRepro.t.sol -vv
///
///      ## The defect
///
///      `PiecewiseLinearScale.sol:64` computes `((value << 24) + scale) / (scale + 1)`.
///      Solidity's `<<` is **not** overflow-checked — unlike `*`, which would revert here — so
///      for `value > type(uint232).max` the top 24 bits are discarded and the function returns a
///      wrong answer with no revert at all. At `value = 2**232` it returns `0`.
///
///      The function's own docstring promises `scaleValue(unscaleValue(v, s), s) == v`. That
///      round trip is silently false above the frontier, and the repository's fuzz test avoids
///      the region by bounding its input (`test/PiecewiseLinearScale.t.sol:68`) rather than by
///      documenting a precondition.
///
///      ## Reachability — the part that matters
///
///      `unscaleValue` is **not on any on-chain execution path**. An exhaustive grep finds it
///      referenced in exactly three places: its own definition, the instruction's integration
///      docstring at `:87`, and `test/PiecewiseLinearScale.t.sol`. `_runOpcode` never reaches it;
///      `_calcScaleNow` uses `parsePointScale`/`parseIntervalDuration`, not this.
///
///      It is a maker-side helper for computing "what balance do I need so that the final
///      scaling lands on the amount I want to sell". So the exposure is: a maker (or a builder
///      library) computing an order parameter off chain gets a wrong number back and signs an
///      order that does not do what they meant.
///
///      And the frontier is `2**232 ~= 6.9e69` wei. No ERC20 in existence has a supply within
///      thirty-five orders of magnitude of that. Reaching it requires deliberately passing a
///      nonsense value.
///
///      Conclusion: real, silent, and — as a defect in deployed behaviour — unreachable. It
///      belongs in the ledger as an undocumented precondition on a helper, not as a bug in the
///      VM. The honest fix is a `require`, or a `*` in place of the `<<`, either of which turns
///      a silent wrong answer into a revert.
contract PiecewiseLinearScaleUnscaleTruncationRepro is Test {
    /// @notice The defect: a wrong answer, no revert.
    function test_repro_silentTruncationAtUint232() public pure {
        uint24 scale = type(uint24).max; // scale + 1 == 2**24, i.e. the identity scaling

        // Just below the frontier the round trip holds.
        uint256 belowFrontier = type(uint232).max;
        assertEq(
            PiecewiseLinearScaleArgsBuilder.unscaleValue(belowFrontier, scale),
            belowFrontier,
            "identity scaling round-trips below 2**232"
        );

        // One step above it, the answer is zero and nothing reverts.
        assertEq(PiecewiseLinearScaleArgsBuilder.unscaleValue(2 ** 232, scale), 0, "silently returns zero");
    }

    /// @notice The advertised round-trip identity is false above the frontier.
    /// @dev `:62` states `scaleValue(unscaled, scale) == value`.
    function test_repro_roundTripIdentityBreaks() public pure {
        uint24 scale = type(uint24).max;
        uint256 value = 2 ** 232 + 12_345;

        uint256 unscaled = PiecewiseLinearScaleArgsBuilder.unscaleValue(value, scale);
        uint256 scaled = PiecewiseLinearScaleArgsBuilder.scaleValue(unscaled, scale);

        assertTrue(scaled != value, "the documented identity does not hold");
        assertEq(scaled, 12_345, "the top 24 bits are simply gone");
    }

    /// @notice A multiplication would have reverted; the shift does not. This is the whole bug
    ///         in one comparison.
    function test_repro_multiplyWouldHaveReverted() public {
        uint256 value = 2 ** 232;
        assertEq(value << 24, 0, "shift wraps");

        (bool ok,) = address(this).staticcall(abi.encodeCall(this.mulBy2Pow24, (value)));
        assertFalse(ok, "the equivalent multiplication reverts");
    }

    function mulBy2Pow24(uint256 value) external pure returns (uint256) {
        return value * (2 ** 24);
    }

    /// @notice Everything at a plausible token scale is exact, which is why this has never bitten.
    function testFuzz_repro_realisticValuesAreExact(uint256 value, uint24 scale) public pure {
        value = bound(value, 0, 1e40); // far above any real supply, far below 2**232
        uint256 unscaled = PiecewiseLinearScaleArgsBuilder.unscaleValue(value, scale);
        assertEq(PiecewiseLinearScaleArgsBuilder.scaleValue(unscaled, scale), value, "round trip holds");
    }
}
