// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CalldataPtrLib } from "@1inch/solidity-utils/contracts/libraries/CalldataPtr.sol";

import { Context, ContextLib } from "../../src/libs/VM.sol";
import { Controls } from "../../src/instructions/Controls.sol";
import { Balances } from "../../src/instructions/Balances.sol";
import { LimitSwap } from "../../src/instructions/LimitSwap.sol";
import { Whitelist } from "../../src/instructions/Whitelist.sol";

/// @notice Minimal ERC-20 exposing `balanceOf` (gate/gte/txorigin reads) and `totalSupply`
///         (SupplyShare reads). All the conformance opcodes that consult token state read one
///         or both of these; no other ERC-20 surface is exercised.
contract GateTokenMock {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function setBalance(address holder, uint256 amount) external {
        balanceOf[holder] = amount;
    }

    function setTotalSupply(uint256 amount) external {
        totalSupply = amount;
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
contract InstructionConformanceTest is Test, Controls, Balances, LimitSwap, Whitelist {
    using ContextLib for Context;
    using CalldataPtrLib for bytes;

    GateTokenMock internal gateToken;

    /// @dev Bound to `ctx.vm.dispatch`. Real bodies, our table.
    ///      Routes each opcode to the genuine instruction body inherited from `Controls`,
    ///      `Balances`, `LimitSwap`, and `Whitelist`. Only the dispatch *table* is ours, which is
    ///      what the production VM generates anyway. No instruction logic is reimplemented, so
    ///      this compares the K rules against production code rather than against a transcription.
    ///
    ///      Coverage: Phase 1 trio (0x23/0x90/0x53) + the direct-form Conditions & access guards
    ///      opcodes (0x01/0x02/0x03/0x30/0x31/0x32/0x2b) + the refactored concrete-evaluable
    ///      opcodes whose rules formerly used uninterpreted predicates but now branch on direct
    ///      comparisons / recursive loop functions (0x20/0x24/0x25/0x26/0x2c/0x2d). The latter set
    ///      became conformance-testable when their K rules were rewritten from predicate form to
    ///      direct/recursive form (see semantics/opcodes/*.md "Direct form, concrete conformance").
    function _dispatch(Context memory ctx, uint256 opcode, bytes calldata args) internal virtual {
        if (opcode == 0x23) _onlyTakerTokenBalanceNonZero(ctx, args);
        else if (opcode == 0x90) _staticBalancesXD(ctx, args);
        else if (opcode == 0x53) _limitSwap1D(ctx, args);
        // -- Conditions & access guards: direct-form opcodes --
        else if (opcode == 0x01) _revert(ctx, args);
        else if (opcode == 0x02) _salt(ctx, args);
        else if (opcode == 0x03) _jump(ctx, args);
        else if (opcode == 0x30) _jumpIfDirection(ctx, args);
        else if (opcode == 0x31) _jumpIfTokenIn(ctx, args);
        else if (opcode == 0x32) _jumpIfTokenOut(ctx, args);
        else if (opcode == 0x2b) _privateOrder(ctx, args);
        // -- Refactored to direct/recursive form for concrete conformance --
        else if (opcode == 0x20) _deadline(ctx, args);
        else if (opcode == 0x24) _onlyTakerTokenBalanceGte(ctx, args);
        else if (opcode == 0x25) _onlyTakerTokenSupplyShareGte(ctx, args);
        else if (opcode == 0x26) _onlyTxOriginTokenBalanceNonZero(ctx, args);
        else if (opcode == 0x2c) _whitelistCoequal(ctx, args);
        else if (opcode == 0x2d) _whitelistSequential(ctx, args);
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

    /// @notice Recompute guard on the REVERSED branch, exact-in.
    /// @dev This is the case that would have caught the bad D-1 fix. Both recompute tests
    ///      above use forward token order; the model's `==Bool` precedence bug made both
    ///      recompute arms unreachable *only* on the reversed branch, so no test touched it
    ///      and a "verified on a clean rebuild" table of four cases missed it entirely.
    function test_conformance_recomputeDetectedReversedExactIn() public {
        gateToken.setBalance(TAKER, 5);

        vm.expectRevert(LimitSwap.LimitSwapRecomputeDetected.selector);
        this.runProgram(_programWith(address(gateToken), 1000e18, 2000e18, 0x00), TAKER, TOKEN_HI, TOKEN_LO, 1e18, 7, true);
    }

    /// @notice Recompute guard on the REVERSED branch, exact-out.
    function test_conformance_recomputeDetectedReversedExactOut() public {
        gateToken.setBalance(TAKER, 5);

        vm.expectRevert(LimitSwap.LimitSwapRecomputeDetected.selector);
        this.runProgram(_programWith(address(gateToken), 1000e18, 2000e18, 0x00), TAKER, TOKEN_HI, TOKEN_LO, 7, 3, false);
    }

    /// @notice Mirror of the above on the exact-out leg. `LimitSwap.sol:51`.
    function test_conformance_recomputeDetectedOnExactOut() public {
        gateToken.setBalance(TAKER, 5);

        vm.expectRevert(LimitSwap.LimitSwapRecomputeDetected.selector);
        this.runProgram(_program(address(gateToken)), TAKER, TOKEN_LO, TOKEN_HI, 7, 3, false);
    }

    // -----------------------------------------------------------------------
    // Conditions & access guards -- concrete conformance.
    //
    // Each test runs the SAME bytes as a claim in `semantics/proofs/conformance-concrete.k`
    // through the REAL instruction body via `_dispatch`, and asserts the SAME expected outcome
    // the K claim asserts. Agreement between the two sides is the conformance evidence.
    //
    // pc expectations are taken from the K claims (which were hand-derived from the Solidity
    // source, then confirmed by kprove). A divergence surfaces as a failing assertion here AND
    // a still-proving K claim -- the signature of "the rule matches itself, not Solidity".
    // -----------------------------------------------------------------------

    /// @dev K claim c1: `b"\x02\x00"` => pc 2, Running. Salt is a pure no-op; decode advances
    ///      pc by 2+0 and the loop falls through at length 2.
    function test_conformance_salt_is_noop() public {
        InstructionConformanceTest.Outcome memory o =
            this.runProgram(hex"0200", TAKER, TOKEN_LO, TOKEN_HI, 1e18, 0, true);
        assertEq(o.pc, 2, "salt: decode advances pc by 2+0");
    }

    /// @dev K claim c2: `b"\x01\x00"` => Reverted(InstructionRevert). Unconditional revert;
    ///      the args bytes are the maker's reason payload.
    function test_conformance_revert_unwinds() public {
        vm.expectRevert(abi.encodeWithSelector(Controls.InstructionRevert.selector, hex""));
        this.runProgram(hex"0100", TAKER, TOKEN_LO, TOKEN_HI, 1e18, 0, true);
    }

    /// @dev K claim c3: `b"\x03\x02\x00\x05"` => pc 5. Jump overwrites nextPC with uint16 5;
    ///      program is 4 bytes so loop exits at pc 5.
    function test_conformance_jump_overwrites_pc() public {
        InstructionConformanceTest.Outcome memory o =
            this.runProgram(hex"03020005", TAKER, TOKEN_LO, TOKEN_HI, 1e18, 0, true);
        assertEq(o.pc, 5, "jump: nextPC = uint16(0x0005) = 5");
    }

    /// @dev K claim c4: `b"\x30\x03\x01\x00\x09"` with tokenIn<tokenOut => pc 9 (branch taken).
    ///      expectedDir(0x01 != 0 = true) == swapDir(TOKEN_LO < TOKEN_HI = true).
    function test_conformance_jumpIfDirection_taken() public {
        InstructionConformanceTest.Outcome memory o =
            this.runProgram(hex"3003010009", TAKER, TOKEN_LO, TOKEN_HI, 1e18, 0, true);
        assertEq(o.pc, 9, "jumpIfDirection: branch taken, nextPC = uint16(0x0009)");
    }

    /// @dev K claim c5: same program, tokenIn>tokenOut => pc 5 (fall through).
    ///      expectedDir(true) != swapDir(TOKEN_HI < TOKEN_LO = false).
    function test_conformance_jumpIfDirection_fallThrough() public {
        InstructionConformanceTest.Outcome memory o =
            this.runProgram(hex"3003010009", TAKER, TOKEN_HI, TOKEN_LO, 1e18, 0, true);
        assertEq(o.pc, 5, "jumpIfDirection: branch NOT taken, pc = 2+3");
    }

    /// @dev K claim c6: JumpIfTokenIn with arg token=1 == tokenIn=1 => jump to 30. Jump target
    ///      30 != fall-through pc 24, so a mutant deleting the jump arm fails this test.
    ///      Program: 0x31 0x16 + bytes20(1) + bytes2(30) = 24 bytes. Note the token is exactly
    ///      20 bytes (bytes20), NOT bytes32 -- argsLen declares 0x16=22 = 20 token + 2 pc, and a
    ///      wider literal would leave trailing bytes that decode as a second instruction.
    function test_conformance_jumpIfTokenIn_taken() public {
        bytes memory prog = bytes.concat(
            hex"3116",
            bytes20(uint160(1)),
            bytes2(uint16(30))
        );
        InstructionConformanceTest.Outcome memory o =
            this.runProgram(prog, TAKER, address(uint160(1)), TOKEN_HI, 1e18, 0, true);
        assertEq(o.pc, 30, "jumpIfTokenIn: token match, nextPC = 30");
    }

    /// @dev K claim c7: JumpIfTokenIn with arg token=5 != tokenIn=1 => fall through, pc 24.
    function test_conformance_jumpIfTokenIn_fallThrough() public {
        bytes memory prog = bytes.concat(
            hex"3116",
            bytes20(uint160(5)),
            bytes2(uint16(30))
        );
        InstructionConformanceTest.Outcome memory o =
            this.runProgram(prog, TAKER, address(uint160(1)), TOKEN_HI, 1e18, 0, true);
        assertEq(o.pc, 24, "jumpIfTokenIn: no match, pc = 2+22");
    }

    /// @dev K claim c8: JumpIfTokenOut with arg token=7 == tokenOut=7 => jump to 30.
    function test_conformance_jumpIfTokenOut_taken() public {
        bytes memory prog = bytes.concat(
            hex"3216",
            bytes20(uint160(7)),
            bytes2(uint16(30))
        );
        InstructionConformanceTest.Outcome memory o =
            this.runProgram(prog, TAKER, TOKEN_LO, address(uint160(7)), 1e18, 0, true);
        assertEq(o.pc, 30, "jumpIfTokenOut: token match, nextPC = 30");
    }

    /// @dev K claim: JumpIfTokenOut with arg token=9 != tokenOut=7 => fall through, pc 24.
    ///      Paired with the taken case so BOTH arms are exercised (previously only taken
    ///      existed). A mutant that always jumps fails this; one that never jumps fails taken.
    function test_conformance_jumpIfTokenOut_fallThrough() public {
        bytes memory prog = bytes.concat(
            hex"3216",
            bytes20(uint160(9)),
            bytes2(uint16(30))
        );
        InstructionConformanceTest.Outcome memory o =
            this.runProgram(prog, TAKER, TOKEN_LO, address(uint160(7)), 1e18, 0, true);
        assertEq(o.pc, 24, "jumpIfTokenOut: no match, pc = 2+22");
    }

    /// @dev K claim c9: PrivateOrder, taker matches packed arg. taker=0x1234=4660; arg =
    ///      Int2Bytes(10, 4660) = low 80 bits = 0x1234. uint80(uint160(4660)) == arg => pass.
    ///      pc = 2+10 = 12.
    function test_conformance_privateOrder_takerMatches() public {
        bytes memory prog = bytes.concat(hex"2b0a", bytes10(uint80(uint160(uint256(4660)))));
        InstructionConformanceTest.Outcome memory o =
            this.runProgram(prog, address(uint160(4660)), TOKEN_LO, TOKEN_HI, 1e18, 0, true);
        assertEq(o.pc, 12, "privateOrder: taker matches, gate passes, pc = 2+10");
    }

    /// @dev K claim c10: PrivateOrder, taker does NOT match. taker=0x1234, arg=0x5678=22136.
    ///      uint80(uint160(0x1234)) != 0x5678 => revert WhitelistInvalidTaker.
    function test_conformance_privateOrder_takerRejected() public {
        bytes memory prog = bytes.concat(hex"2b0a", bytes10(uint80(uint160(uint256(22136)))));
        vm.expectRevert(Whitelist.WhitelistInvalidTaker.selector);
        this.runProgram(prog, address(uint160(4660)), TOKEN_LO, TOKEN_HI, 1e18, 0, true);
    }

    // -----------------------------------------------------------------------
    // Refactored concrete-evaluable opcodes -- concrete conformance.
    //
    // Each test below mirrors a concrete claim in `semantics/proofs/<opcode>-concrete.k`
    // (Deadline/Gte/SupplyShare/TxOrigin/WhitelistCoequal/WhitelistSequential). These opcodes'
    // K rules were originally written with uninterpreted Bool predicates (the arm-selection
    // workaround), which made their symbolic claims tautological and blocked concrete
    // evaluation -- so NO conformance was possible. The rules have since been rewritten to
    // direct-comparison form (Deadline/Gte/SupplyShare/TxOrigin) or recursive-loop function
    // form (the two Whitelists), making them concrete-evaluable. These tests are the
    // payoff: the SAME bytes run through both engines, agreement = real verification.
    // -----------------------------------------------------------------------

    /// @dev K claim deadline-concrete.k A: block.timestamp 100 > deadline 50 => revert.
    ///      Program: 0x20 0x05 + bytes5(uint40(50)) = 7 bytes.
    function test_conformance_deadline_expired_reverts() public {
        bytes memory prog = bytes.concat(hex"2005", bytes5(uint40(50)));
        vm.warp(100);
        vm.expectRevert(abi.encodeWithSelector(Controls.DeadlineReached.selector, TAKER, uint256(50)));
        this.runProgram(prog, TAKER, TOKEN_LO, TOKEN_HI, 1e18, 0, true);
    }

    /// @dev K claim deadline-concrete.k B: block.timestamp 50 <= deadline 100 => pass, pc=7.
    function test_conformance_deadline_notExpired_passes() public {
        bytes memory prog = bytes.concat(hex"2005", bytes5(uint40(100)));
        vm.warp(50);
        InstructionConformanceTest.Outcome memory o =
            this.runProgram(prog, TAKER, TOKEN_LO, TOKEN_HI, 1e18, 0, true);
        assertEq(o.pc, 7, "deadline: passes, pc = 2+5");
    }

    /// @dev K claim gte-concrete.k A: balance 5 < minAmount 10 => revert.
    ///      Program: 0x24 0x34 + bytes20(gateToken) + bytes32(10) = 54 bytes.
    function test_conformance_gte_belowMin_reverts() public {
        gateToken.setBalance(TAKER, 5);
        bytes memory prog = bytes.concat(hex"2434", bytes20(address(gateToken)), bytes32(uint256(10)));
        vm.expectRevert(
            abi.encodeWithSelector(
                Controls.TakerTokenBalanceIsLessThanRequired.selector,
                TAKER,
                address(gateToken),
                uint256(5),
                uint256(10)
            )
        );
        this.runProgram(prog, TAKER, TOKEN_LO, TOKEN_HI, 1e18, 0, true);
    }

    /// @dev K claim gte-concrete.k B: balance 10 >= minAmount 10 (boundary) => pass, pc=54.
    function test_conformance_gte_atMin_passes() public {
        gateToken.setBalance(TAKER, 10);
        bytes memory prog = bytes.concat(hex"2434", bytes20(address(gateToken)), bytes32(uint256(10)));
        InstructionConformanceTest.Outcome memory o =
            this.runProgram(prog, TAKER, TOKEN_LO, TOKEN_HI, 1e18, 0, true);
        assertEq(o.pc, 54, "gte: balance == min, pc = 2+52");
    }

    /// @dev K claim supplyshare-concrete.k A: totalSupply 0 => revert (first conjunct fails).
    ///      Program: 0x25 0x1c + bytes20(gateToken) + bytes8(uint64(0)) = 30 bytes.
    function test_conformance_supplyShare_zeroSupply_reverts() public {
        gateToken.setTotalSupply(0);
        bytes memory prog = bytes.concat(hex"251c", bytes20(address(gateToken)), bytes8(uint64(0)));
        // balance=0 (no setBalance), totalSupply=0, minShareE18=0 -> args to the error.
        vm.expectRevert(
            abi.encodeWithSelector(
                Controls.TakerTokenBalanceSupplyShareIsLessThanRequired.selector,
                TAKER,
                address(gateToken),
                uint256(0),
                uint256(0),
                uint256(0)
            )
        );
        this.runProgram(prog, TAKER, TOKEN_LO, TOKEN_HI, 1e18, 0, true);
    }

    /// @dev K claim supplyshare-concrete.k B: totalSupply 1000, balance 1000, minShareE18 1e18.
    ///      1000 * 1e18 >= 1e18 * 1000 (boundary) => pass, pc=30.
    function test_conformance_supplyShare_boundary_passes() public {
        gateToken.setBalance(TAKER, 1000);
        gateToken.setTotalSupply(1000);
        bytes memory prog =
            bytes.concat(hex"251c", bytes20(address(gateToken)), bytes8(uint64(1e18)));
        InstructionConformanceTest.Outcome memory o =
            this.runProgram(prog, TAKER, TOKEN_LO, TOKEN_HI, 1e18, 0, true);
        assertEq(o.pc, 30, "supplyShare: boundary pass, pc = 2+28");
    }

    /// @dev K claim txorigin-concrete.k A: tx.origin holds 0 of gateToken =>
    ///      revert TxOriginTokenBalanceIsZero. Program: 0x26 0x14 + bytes20(gateToken) = 22 bytes.
    ///      tx.origin in forge is the test-runner EOA (not address(this)); we don't set its
    ///      balance, so balanceOf(tx.origin) defaults to 0.
    function test_conformance_txOrigin_zeroBalance_reverts() public {
        bytes memory prog = bytes.concat(hex"2614", bytes20(address(gateToken)));
        vm.expectRevert(
            abi.encodeWithSelector(Controls.TxOriginTokenBalanceIsZero.selector, tx.origin, address(gateToken))
        );
        this.runProgram(prog, TAKER, TOKEN_LO, TOKEN_HI, 1e18, 0, true);
    }

    /// @dev K claim txorigin-concrete.k B: tx.origin holds 5 of gateToken => pass, pc=22.
    function test_conformance_txOrigin_holdsBalance_passes() public {
        gateToken.setBalance(tx.origin, 5);
        bytes memory prog = bytes.concat(hex"2614", bytes20(address(gateToken)));
        InstructionConformanceTest.Outcome memory o =
            this.runProgram(prog, TAKER, TOKEN_LO, TOKEN_HI, 1e18, 0, true);
        assertEq(o.pc, 22, "txOrigin: holds balance, pc = 2+20");
    }

    /// @dev K claim whitelistcoequal-concrete.k A: packed taker 4660 matches the single list
    ///      entry => jump to 20. Program: 0x2c 0x0c + bytes2(20) + bytes10(uint80(4660)) = 14 bytes.
    ///      Jump target 20 != fall-through pc 14, so a mutant deleting the jump arm fails this.
    ///      Solidity packs uint80(uint160(taker)); for taker 4660 (< 2^80) that equals 4660.
    function test_conformance_whitelistCoequal_match_jumps() public {
        bytes memory prog =
            bytes.concat(hex"2c0c", bytes2(uint16(20)), bytes10(uint80(uint160(uint256(4660)))));
        InstructionConformanceTest.Outcome memory o =
            this.runProgram(prog, address(uint160(4660)), TOKEN_LO, TOKEN_HI, 1e18, 0, true);
        assertEq(o.pc, 20, "whitelistCoequal: match, nextPC = 20");
    }

    /// @dev K claim whitelistcoequal-concrete.k B: packed entry 9999 != taker 4660 => fall
    ///      through, pc = 2+12 = 14.
    function test_conformance_whitelistCoequal_noMatch_fallsThrough() public {
        bytes memory prog =
            bytes.concat(hex"2c0c", bytes2(uint16(20)), bytes10(uint80(uint160(uint256(9999)))));
        InstructionConformanceTest.Outcome memory o =
            this.runProgram(prog, address(uint160(4660)), TOKEN_LO, TOKEN_HI, 1e18, 0, true);
        assertEq(o.pc, 14, "whitelistCoequal: no match, pc = 2+12");
    }

    /// @dev K claim whitelistsequential-concrete.k A: ts 10, start 0, duration 1000, addr 4660
    ///      matches taker => JUMP (address check fires before timeLeft<duration check).
    ///      Program: 0x2d 0x13 + bytes2(30) + bytes5(0) + bytes2(1000) + bytes10(4660) = 21 bytes.
    ///      Jump target 30 != fall-through pc 21.
    function test_conformance_whitelistSequential_match_jumps() public {
        bytes memory prog = bytes.concat(
            hex"2d13",
            bytes2(uint16(30)),
            bytes5(uint40(0)),
            bytes2(uint16(1000)),
            bytes10(uint80(uint160(uint256(4660))))
        );
        vm.warp(10);
        InstructionConformanceTest.Outcome memory o =
            this.runProgram(prog, address(uint160(4660)), TOKEN_LO, TOKEN_HI, 1e18, 0, true);
        assertEq(o.pc, 30, "whitelistSequential: match in window, nextPC = 30");
    }

    /// @dev K claim whitelistsequential-concrete.k B: ts 10, start 0, duration 1000, addr 9999
    ///      != taker 4660, and timeLeft(10) < duration(1000) => revert WhitelistAllowedTimeViolation.
    function test_conformance_whitelistSequential_noMatch_inWindow_reverts() public {
        bytes memory prog = bytes.concat(
            hex"2d13",
            bytes2(uint16(30)),
            bytes5(uint40(0)),
            bytes2(uint16(1000)),
            bytes10(uint80(uint160(uint256(9999))))
        );
        vm.warp(10);
        vm.expectRevert(Whitelist.WhitelistAllowedTimeViolation.selector);
        this.runProgram(prog, address(uint160(4660)), TOKEN_LO, TOKEN_HI, 1e18, 0, true);
    }
}
