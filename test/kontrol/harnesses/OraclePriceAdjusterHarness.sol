// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Context, SwapRegisters } from "../../../src/libs/VM.sol";
import { OraclePriceAdjuster } from "../../../src/instructions/OraclePriceAdjuster.sol";
import { IPriceOracle } from "../../../src/instructions/interfaces/IPriceOracle.sol";

/// @notice A concrete stand-in for the Chainlink aggregator `OraclePriceAdjuster` calls.
///
/// @dev    **This is a trust boundary, and `HARNESS-FIDELITY.md` requires it to be named as
///         one.** `_oraclePriceAdjuster1D` makes an external call at
///         `OraclePriceAdjuster.sol:96` to an address it reads out of maker-signed program
///         bytes. Symbolically executing a call to an *unconstrained* address means executing
///         unconstrained code, which is not tractable — so the callee is fixed to this
///         contract while the values it returns stay symbolic.
///
///         What that buys, and what it costs:
///
///         * **Kept symbolic** — `answer` and `updatedAt`, the two returned values the
///           instruction actually reads, and `decimals()`. Every property about price
///           scaling, staleness and the adjustment arithmetic therefore quantifies over the
///           full oracle response, which is the part that matters.
///         * **Assumed away** — that the callee is well-behaved: it returns, it returns
///           exactly five ABI-encoded words, it does not reenter, it does not consume the
///           gas budget, and it costs the same on every call. A real `oracleAddress` is an
///           arbitrary address under maker control; nothing in `_oraclePriceAdjuster1D`
///           checks that it has code at all, so a call to an EOA returns empty data and the
///           ABI decode reverts. That path is NOT modelled here.
///         * **Also assumed away** — that `latestRoundData()` returns the same values within
///           a single call. The instruction calls `latestRoundData()` once and `decimals()`
///           at most once, so this is not load-bearing, but it is an assumption.
///
///         The mock holds its values in storage rather than taking constructor arguments,
///         because `run-constructor = false` under Kontrol and a spec must be able to drive
///         them from a test body. `roundId`, `startedAt` and `answeredInRound` are returned
///         as zero: `_oraclePriceAdjuster1D` discards all three (`:96` destructures only the
///         second and fourth), so nothing observes them.
contract MockPriceOracle is IPriceOracle {
    int256 internal _answer;
    uint256 internal _updatedAt;
    uint8 internal _decimals;

    /// @notice Drive the three values the instruction can observe.
    function set(int256 answer_, uint256 updatedAt_, uint8 decimals_) external {
        _answer = answer_;
        _updatedAt = updatedAt_;
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "";
    }

    function version() external pure returns (uint256) {
        return 0;
    }

    function getRoundData(uint80)
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (0, _answer, 0, _updatedAt, 0);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, _answer, 0, _updatedAt, 0);
    }
}

/// @notice External surface over OraclePriceAdjuster's internal instruction, for symbolic
///         execution.
///
/// @dev    `Context` embeds an internal function pointer (`VM.dispatch`), so it is not
///         ABI-encodable and cannot be passed across an external call. The harness therefore
///         accepts the individual registers and assembles the `Context` in memory. This is
///         the same plain shape as `BaseFeeAdjusterHarness`, for the same reasons, and it
///         contains no transcription of the instruction — Tier 1 under
///         `HARNESS-FIDELITY.md`.
///
///         `ctx.vm` is left zero-initialised. `_oraclePriceAdjuster1D` reads only
///         `ctx.query.isExactIn` and `ctx.swap`, and never dispatches, so the null function
///         pointer is never invoked. It *does* make an external call, but to
///         `oracleAddress` parsed from `args`, not through `ctx.vm`.
///
///         The entry points are `view` rather than `pure` for two reasons the instruction
///         forces: it `STATICCALL`s the oracle (`:96`) and it reads `block.timestamp`
///         (`:100`).
///
///         Every register goes in and the whole register file comes back, as a
///         `SwapRegisters` struct. `OraclePriceAdjuster` is a *post-swap adjuster* — it
///         requires both `amountIn` and `amountOut` to be non-zero (`:83`) — so a spec has
///         to be able to populate the registers a previous instruction would have written,
///         and returning all five is what lets a spec state register isolation.
contract OraclePriceAdjusterHarness is OraclePriceAdjuster {
    /// @notice Exact-input direction. The instruction is documented to raise `amountOut`.
    function exactIn(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountNetPulled,
        bytes calldata args
    ) external view returns (SwapRegisters memory) {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountIn = amountIn;
        ctx.swap.amountOut = amountOut;
        ctx.swap.amountNetPulled = amountNetPulled;

        _oraclePriceAdjuster1D(ctx, args);

        return ctx.swap;
    }

    /// @notice Exact-output direction. The instruction is documented to lower `amountIn`.
    function exactOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountNetPulled,
        bytes calldata args
    ) external view returns (SwapRegisters memory) {
        Context memory ctx;
        ctx.query.isExactIn = false;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountIn = amountIn;
        ctx.swap.amountOut = amountOut;
        ctx.swap.amountNetPulled = amountNetPulled;

        _oraclePriceAdjuster1D(ctx, args);

        return ctx.swap;
    }
}
