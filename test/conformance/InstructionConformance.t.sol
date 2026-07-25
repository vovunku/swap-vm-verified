// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CalldataPtrLib } from "@1inch/solidity-utils/contracts/libraries/CalldataPtr.sol";

import { Context, ContextLib } from "../../src/libs/VM.sol";
import { Controls } from "../../src/instructions/Controls.sol";
import { Balances } from "../../src/instructions/Balances.sol";
import { LimitSwap } from "../../src/instructions/LimitSwap.sol";

/// @notice Minimal ERC-20 exposing only `balanceOf`, which is all the gate instruction reads.
contract GateTokenMock {
    mapping(address => uint256) public balanceOf;

    function setBalance(address holder, uint256 amount) external {
        balanceOf[holder] = amount;
    }
}

/// @title Phase 1 conformance — the three instructions
///
/// @notice Runs the REAL `_onlyTakerTokenBalanceNonZero`, `_staticBalancesXD` and
///         `_limitSwap1D` through the REAL `runLoop`, and asserts the register outcomes that
///         `semantics/swapvm.md` produces for the same inputs.
///
/// @dev Unlike `RunLoopConformance.t.sol`, dispatch here is REAL: it routes each opcode to the
///      genuine instruction body inherited from `Controls`, `Balances` and `LimitSwap`. Only
///      the dispatch *table* is ours, which is what the production VM generates anyway. No
///      instruction logic is reimplemented, so this compares the K rules against production
///      code rather than against a transcription.
///
///      Expected values are stated as literals taken from `krun` output, not recomputed here,
///      so a divergence shows up as a failing assertion rather than being silently absorbed
///      by shared arithmetic.
contract InstructionConformanceTest is Test, Controls, Balances, LimitSwap {
    using ContextLib for Context;
    using CalldataPtrLib for bytes;

    GateTokenMock internal gateToken;

    /// @dev Bound to `ctx.vm.dispatch`. Real bodies, our table.
    function _dispatch(Context memory ctx, uint256 opcode, bytes calldata args) internal {
        if (opcode == 0x23) _onlyTakerTokenBalanceNonZero(ctx, args);
        else if (opcode == 0x90) _staticBalancesXD(ctx, args);
        else if (opcode == 0x53) _limitSwap1D(ctx, args);
        else revert("unmodelled opcode in conformance driver");
    }

    function setUp() public {
        gateToken = new GateTokenMock();
    }

    struct Outcome {
        uint256 balanceIn;
        uint256 balanceOut;
        uint256 amountIn;
        uint256 amountOut;
        uint256 pc;
    }

    function runProgram(
        bytes calldata program,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bool isExactIn
    ) external returns (Outcome memory o) {
        Context memory ctx;
        ctx.vm.programPtr = CalldataPtrLib.from(program);
        ctx.vm.dispatch = _dispatch;
        ctx.query.taker = taker;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.query.isExactIn = isExactIn;
        ctx.swap.amountIn = amountIn;
        ctx.swap.amountOut = amountOut;

        ctx.runLoop();

        return Outcome(ctx.swap.balanceIn, ctx.swap.balanceOut, ctx.swap.amountIn, ctx.swap.amountOut, ctx.vm.nextPC);
    }

    /// @dev The catalogue program, with the gate token address patched in at runtime so it
    ///      matches the deployed mock. Layout is identical to
    ///      `semantics/programs/permissioned-swap.md`.
    function _program(address gate) internal pure returns (bytes memory) {
        return bytes.concat(
            hex"2314", bytes20(gate),
            hex"9040",
            bytes32(uint256(1000e18)),
            bytes32(uint256(2000e18)),
            hex"530101"
        );
    }

    address internal constant TAKER = address(uint160(4660)); // 0x1234, as in the krun runs
    address internal constant TOKEN_LO = address(uint160(1));
    address internal constant TOKEN_HI = address(uint160(2));

    /// @notice Taker holds the gate token: full program prices at the 1:2 limit rate.
    /// @dev K: balanceIn 1000e18, balanceOut 2000e18, amountOut 2e18, status Running, pc 91.
    function test_conformance_holdingTakerGetsQuote() public {
        gateToken.setBalance(TAKER, 5);

        Outcome memory o =
            this.runProgram(_program(address(gateToken)), TAKER, TOKEN_LO, TOKEN_HI, 1e18, 0, true);

        assertEq(o.balanceIn, 1000e18, "balanceIn from StaticBalances");
        assertEq(o.balanceOut, 2000e18, "balanceOut from StaticBalances");
        assertEq(o.amountIn, 1e18, "amountIn unchanged on exact-in");
        assertEq(o.amountOut, 2e18, "amountOut = amountIn * balanceOut / balanceIn");
        assertEq(o.pc, 91, "program fully consumed");
    }

    /// @notice Taker holds nothing: the gate reverts and nothing after it runs.
    /// @dev K: status Reverted("TakerTokenBalanceIsZero"), pc 22, balances still 0.
    ///      This is the concrete instance of the Phase 1 theorem.
    function test_conformance_zeroBalanceTakerIsRejected() public {
        vm.expectRevert(
            abi.encodeWithSelector(Controls.TakerTokenBalanceIsZero.selector, TAKER, address(gateToken))
        );
        this.runProgram(_program(address(gateToken)), TAKER, TOKEN_LO, TOKEN_HI, 1e18, 0, true);
    }

    /// @notice Reversed token order: StaticBalances swaps the pair, then LimitSwap rejects.
    /// @dev K: balanceIn 2000e18, balanceOut 1000e18, then
    ///      Reverted("LimitSwapDirectionMismatch"). Guards the orientation branch — modelling
    ///      only one side would be wrong for half of all token pairs.
    function test_conformance_reversedTokenOrderSwapsThenMismatches() public {
        gateToken.setBalance(TAKER, 5);

        vm.expectRevert(LimitSwap.LimitSwapDirectionMismatch.selector);
        this.runProgram(_program(address(gateToken)), TAKER, TOKEN_HI, TOKEN_LO, 1e18, 0, false);
    }

    /// @notice Exact-out prices with a ceiling, in the maker's favour.
    /// @dev K: limitQuoteIn = ceilDiv(amountOut * balanceIn, balanceOut). With amountOut 3,
    ///      balances 1000e18/2000e18: ceilDiv(3000e18, 2000e18) = 2. Floor would give 1, so
    ///      this assertion distinguishes the rounding direction rather than merely exercising
    ///      the path.
    function test_conformance_exactOutRoundsUp() public {
        gateToken.setBalance(TAKER, 5);

        Outcome memory o =
            this.runProgram(_program(address(gateToken)), TAKER, TOKEN_LO, TOKEN_HI, 0, 3, false);

        assertEq(o.amountIn, 2, "ceilDiv(3 * 1000e18, 2000e18) == 2, not 1");
        assertEq(o.amountOut, 3, "amountOut unchanged on exact-out");
    }

    // -----------------------------------------------------------------------
    // Gaps found by mutation testing. Each of these was added because a
    // deliberate break in the K semantics survived the original suite.
    // -----------------------------------------------------------------------

    /// @dev Same layout, arbitrary balances and direction byte.
    function _programWith(address gate, uint256 balA, uint256 balB, bytes1 dirLt)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(
            hex"2314", bytes20(gate),
            hex"9040", bytes32(balA), bytes32(balB),
            hex"5301", dirLt
        );
    }

    /// @notice Exact-in FLOORS. The original suite could not tell floor from ceiling.
    /// @dev The catalogue program divides exactly — `1e18 * 2000e18 / 1000e18 = 2e18` — so
    ///      changing `limitQuoteOut` to a ceiling survived every test. `LimitSwap.sol:49`
    ///      calls floor "desired behavior": it is a maker-favouring rounding decision and was
    ///      completely unconstrained on both sides.
    ///
    ///      Balances 3/2 with `amountIn = 1`: floor(1*2/3) = 0, ceiling would give 1.
    function test_conformance_exactInFloorsNotCeils() public {
        gateToken.setBalance(TAKER, 5);

        Outcome memory o =
            this.runProgram(_programWith(address(gateToken), 3, 2, 0x01), TAKER, TOKEN_LO, TOKEN_HI, 1, 0, true);

        assertEq(o.amountOut, 0, "floor(1 * 2 / 3) == 0; a ceiling would give 1");
    }

    /// @notice Reversed order genuinely swaps the balance pair.
    /// @dev The existing reversed-order test only asserts a revert selector, so it passes even
    ///      with the orientation flipped. This one completes — direction byte `0x00` matches
    ///      `tokenIn > tokenOut` — and asserts the registers, which is the only way to pin
    ///      which balance went where.
    function test_conformance_reversedOrientationAssignsBalances() public {
        gateToken.setBalance(TAKER, 5);

        Outcome memory o = this.runProgram(
            _programWith(address(gateToken), 1000e18, 2000e18, 0x00), TAKER, TOKEN_HI, TOKEN_LO, 1e18, 0, true
        );

        assertEq(o.balanceIn, 2000e18, "tokenIn > tokenOut: args pair is SWAPPED");
        assertEq(o.balanceOut, 1000e18, "swapped");
        assertEq(o.amountOut, 0.5e18, "1e18 * 1000e18 / 2000e18");
    }

    /// @notice Setting balances twice reverts.
    /// @dev `Balances.sol:38` guards on both registers being zero. Untested until now — a
    ///      mutation deleting the guard entirely survived the suite.
    function test_conformance_doubleBalancesReverts() public {
        gateToken.setBalance(TAKER, 5);

        bytes memory prog = bytes.concat(
            hex"2314", bytes20(address(gateToken)),
            hex"9040", bytes32(uint256(1000e18)), bytes32(uint256(2000e18)),
            hex"9040", bytes32(uint256(5)), bytes32(uint256(6))
        );

        vm.expectRevert(
            abi.encodeWithSelector(Balances.SetBalancesExpectZeroBalances.selector, uint256(1000e18), uint256(2000e18))
        );
        this.runProgram(prog, TAKER, TOKEN_LO, TOKEN_HI, 1e18, 0, true);
    }

    /// @notice Pricing without balances reverts.
    /// @dev `LimitSwap.sol:41`. Untested until now; a mutation making the guard unreachable
    ///      survived.
    function test_conformance_limitSwapWithoutBalancesReverts() public {
        gateToken.setBalance(TAKER, 5);

        bytes memory prog = bytes.concat(hex"2314", bytes20(address(gateToken)), hex"530101");

        vm.expectRevert(abi.encodeWithSelector(LimitSwap.LimitSwapRequiresBothBalancesNonZero.selector, 0, 0));
        this.runProgram(prog, TAKER, TOKEN_LO, TOKEN_HI, 1e18, 0, true);
    }

    /// @notice Pricing twice reverts — the recompute guard.
    /// @dev `LimitSwap.sol:48`. No case ever pre-set the output register, so a mutation making
    ///      both recompute arms unreachable changed nothing at all.
    function test_conformance_recomputeDetectedOnExactIn() public {
        gateToken.setBalance(TAKER, 5);

        vm.expectRevert(LimitSwap.LimitSwapRecomputeDetected.selector);
        // amountOut already set on entry, so the exact-in leg must refuse to price again.
        this.runProgram(_program(address(gateToken)), TAKER, TOKEN_LO, TOKEN_HI, 1e18, 7, true);
    }

    /// @notice Mirror of the above on the exact-out leg. `LimitSwap.sol:51`.
    function test_conformance_recomputeDetectedOnExactOut() public {
        gateToken.setBalance(TAKER, 5);

        vm.expectRevert(LimitSwap.LimitSwapRecomputeDetected.selector);
        this.runProgram(_program(address(gateToken)), TAKER, TOKEN_LO, TOKEN_HI, 7, 3, false);
    }
}
