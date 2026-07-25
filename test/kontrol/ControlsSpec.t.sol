// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { ControlsHarness } from "./harnesses/ControlsHarness.sol";
import { Controls } from "../../src/instructions/Controls.sol";

/// @notice Kontrol specification for the Controls instructions (opcodes 0x40–0x49).
///
/// @dev Reference semantics, from src/instructions/Controls.sol. The pure/control-flow
///      subset is specified here; the four `_onlyTakerToken...` opcodes make external
///      calls and are tier-3 (a different harness shape), so they are out of scope.
///
///        _salt              no-op; touches nothing
///        _jump              nextPC = uint16(args[0:2])
///        _stop              nextPC = type(uint256).max
///        _revert            revert InstructionRevert(args)
///        _jumpIfDirection   if (args[0] != 0) == (tokenIn < tokenOut): nextPC = uint16(args[1:3])
///        _jumpIfTokenIn     if args[0:20] == tokenIn:                   nextPC = uint16(args[20:22])
///        _jumpIfTokenOut    if args[0:20] == tokenOut:                  nextPC = uint16(args[20:22])
///        _deadline          require(block.timestamp <= uint40(args[0:5]))
///
///      These run as ordinary fuzz tests under `forge test` and as proofs under
///      `kontrol prove`. Under Kontrol every `vm.assume` becomes a path constraint
///      rather than a sample filter, so the assumptions define the domain.
///
///      WARNING — argument decoding. The source decodes arguments with `bytesN(args)`
///      conversions (`bytes2`, `bytes20`, `bytes5`, `bytes1`). In Solidity 0.8.30 these do
///      NOT revert when `args` is shorter than N; they zero-pad on the right. So a program
///      whose args length byte is too small for the opcode is not rejected — it silently
///      decodes a zero-padded (and therefore usually wrong) value. The properties below pin
///      this behaviour explicitly. The run loop does enforce `pcs <= length` after parsing,
///      which prevents the *adjacent*-calldata read the workplan worried about, but it does
///      not prevent the zero-padding within a too-short args field. This is worth flagging
///      to the contract authors as a footgun: a malformed program executes rather than
///      failing loudly.
contract ControlsSpec is Test, Controls {
    ControlsHarness internal harness;

    function setUp() public {
        harness = new ControlsHarness();
    }

    // -----------------------------------------------------------------------
    // _salt — declared no-op
    // -----------------------------------------------------------------------

    /// @notice `_salt` leaves every register untouched. The instruction exists only to
    ///         contribute to the order hash, so a future implementation that mutated
    ///         execution state would be a regression.
    function test_salt_isNoOp(uint256 initialPC, bytes memory args) public {
        assertEq(harness.salt(initialPC, args), initialPC, "_salt must not touch nextPC");
    }

    // -----------------------------------------------------------------------
    // _jump — unconditional jump
    // -----------------------------------------------------------------------

    /// @notice `_jump` writes the 2-byte argument into `nextPC`, overwriting any prior value.
    /// @dev The argument is the well-formed case: `args.length >= 2`. The initialPC is
    ///      passed in only to confirm it is ignored: whatever value the caller held is gone.
    function test_jump_setsNextPCFromArgument(uint256 initialPC, uint16 target) public {
        bytes memory args = abi.encodePacked(target);
        uint256 result = harness.jump(initialPC, args);

        assertEq(result, target, "_jump must set nextPC to the 2-byte argument");
    }

    /// @notice A 2-byte argument read inside a longer field takes only the first two bytes.
    /// @dev Pins that oversized args do not bleed into adjacent bytes — the decode is a
    ///      fixed-width prefix read, not a length-sensitive one.
    function test_jump_ignoresBytesBeyondSecond(uint16 target, bytes32 tail) public {
        bytes memory args = bytes.concat(bytes2(target), tail);
        uint256 result = harness.jump(type(uint256).max, args);

        assertEq(result, target, "_jump must read only the first 2 bytes");
    }

    /// @notice Truncated args do not revert — Solidity zero-pads `bytes2(shortArgs)`.
    /// @dev This is the footgun documented at the top of the file. `bytes2(args)` with
    ///      `args.length == 1` yields `args[0] << 8`, not a failure. Pinning it keeps a
    ///      future "fix" (a length check) visible as a breaking change to this spec.
    function test_jump_truncatedArgsZeroPads(bytes1 firstByte) public {
        bytes memory args = abi.encodePacked(firstByte);
        uint256 result = harness.jump(0, args);

        assertEq(result, uint16(uint8(firstByte)) << 8, "_jump zero-pads a 1-byte argument on the right");
    }

    /// @notice The empty-args extreme of the above: `bytes2("")` decodes to zero.
    function test_jump_emptyArgsDecodesToZero() public {
        assertEq(harness.jump(type(uint256).max, ""), 0, "_jump with empty args decodes to nextPC = 0");
    }

    // -----------------------------------------------------------------------
    // _stop — terminate the run loop
    // -----------------------------------------------------------------------

    /// @notice `_stop` sets `nextPC` to `type(uint256).max`, which is beyond any program
    ///         length, so the run loop's `while (pcs < length)` exits on the next iteration.
    function test_stop_setsNextPCToMax(uint256 initialPC, bytes memory args) public {
        uint256 result = harness.stop(initialPC, args);

        assertEq(result, type(uint256).max, "_stop must set nextPC to uint256 max");
    }

    // -----------------------------------------------------------------------
    // _revert — unconditional revert with payload
    // -----------------------------------------------------------------------

    /// @notice `_revert` always reverts, regardless of args (including empty).
    function test_revert_alwaysReverts(bytes memory args) public {
        vm.expectRevert();
        harness.revertInstruction(args);
    }

    /// @notice The revert payload is exactly `InstructionRevert(args)` — the argument bytes
    ///         are propagated verbatim, not hashed or truncated.
    /// @dev This is the only fuzzer-correct formulation: Foundry's `vm.expectRevert(bytes4)`
    ///      overload requires the revert data to be *exactly* 4 bytes, so it fails here
    ///      (the actual revert is a full ABI-encoded error). The full-payload match is
    ///      required.
    ///
    ///      Under Kontrol this proof is the slowest in the spec: for a *symbolic-length*
    ///      `bytes` argument the `expectRevert` registration must encode an unbounded
    ///      dynamic bytes (32-byte offset, length word, data, right-padding), and proving
    ///      two such encodings equal is byte-array reasoning Z3 does not discharge within
    ///      the default `smt-timeout`. The property is sound and fuzzer-green; closing it
    ///      under Kontrol likely needs either a higher `--smt-timeout` or a KEVM lemma for
    ///      `#abiEncode` identity of dynamic bytes — left as the one open item in this spec.
    function test_revert_propagatesArgsVerbatim(bytes memory args) public {
        vm.expectRevert(abi.encodeWithSelector(InstructionRevert.selector, args));
        harness.revertInstruction(args);
    }

    // -----------------------------------------------------------------------
    // _jumpIfDirection — conditional jump on swap direction
    // -----------------------------------------------------------------------

    /// @dev The maker's expected direction is encoded as `args[0] != 0`. Any non-zero byte
    ///      means "true"; only an exact zero byte means "false". This asymmetry is part of
    ///      the spec and is exercised by both directions below.

    /// @notice When the maker's expected direction matches the taker's presented direction,
    ///         the jump fires and `nextPC` is set to the 2-byte argument.
    function test_jumpIfDirection_jumpsWhenConditionMatches(
        uint256 initialPC,
        address tokenIn,
        address tokenOut,
        bytes1 directionByte,
        uint16 target
    ) public {
        vm.assume(tokenIn != tokenOut);
        bytes memory args = abi.encodePacked(directionByte, target);

        bool expected = directionByte != 0;
        bool actual = tokenIn < tokenOut;
        vm.assume(expected == actual);

        uint256 result = harness.jumpIfDirection(initialPC, tokenIn, tokenOut, args);

        assertEq(result, target, "_jumpIfDirection must jump when expected == actual direction");
    }

    /// @notice When the directions disagree, `nextPC` is left exactly as it was.
    function test_jumpIfDirection_noJumpWhenConditionMismatch(
        uint256 initialPC,
        address tokenIn,
        address tokenOut,
        bytes1 directionByte,
        uint16 target
    ) public {
        vm.assume(tokenIn != tokenOut);
        bytes memory args = abi.encodePacked(directionByte, target);

        bool expected = directionByte != 0;
        bool actual = tokenIn < tokenOut;
        vm.assume(expected != actual);

        uint256 result = harness.jumpIfDirection(initialPC, tokenIn, tokenOut, args);

        assertEq(result, initialPC, "_jumpIfDirection must leave nextPC untouched on mismatch");
    }

    // -----------------------------------------------------------------------
    // _jumpIfTokenIn — conditional jump on tokenIn match
    // -----------------------------------------------------------------------

    /// @notice A matching `tokenIn` fires the jump.
    function test_jumpIfTokenIn_jumpsWhenTokenMatches(uint256 initialPC, address token, uint16 target) public {
        bytes memory args = abi.encodePacked(token, target);

        uint256 result = harness.jumpIfTokenIn(initialPC, token, args);

        assertEq(result, target, "_jumpIfTokenIn must jump when token == tokenIn");
    }

    /// @notice A non-matching `tokenIn` leaves `nextPC` untouched.
    function test_jumpIfTokenIn_noJumpWhenTokenMismatch(
        uint256 initialPC,
        address tokenIn,
        address token,
        uint16 target
    ) public {
        vm.assume(token != tokenIn);
        bytes memory args = abi.encodePacked(token, target);

        uint256 result = harness.jumpIfTokenIn(initialPC, tokenIn, args);

        assertEq(result, initialPC, "_jumpIfTokenIn must leave nextPC untouched on mismatch");
    }

    // -----------------------------------------------------------------------
    // _jumpIfTokenOut — conditional jump on tokenOut match
    // -----------------------------------------------------------------------

    /// @notice A matching `tokenOut` fires the jump.
    function test_jumpIfTokenOut_jumpsWhenTokenMatches(uint256 initialPC, address token, uint16 target) public {
        bytes memory args = abi.encodePacked(token, target);

        uint256 result = harness.jumpIfTokenOut(initialPC, token, args);

        assertEq(result, target, "_jumpIfTokenOut must jump when token == tokenOut");
    }

    /// @notice A non-matching `tokenOut` leaves `nextPC` untouched.
    function test_jumpIfTokenOut_noJumpWhenTokenMismatch(
        uint256 initialPC,
        address tokenOut,
        address token,
        uint16 target
    ) public {
        vm.assume(token != tokenOut);
        bytes memory args = abi.encodePacked(token, target);

        uint256 result = harness.jumpIfTokenOut(initialPC, tokenOut, args);

        assertEq(result, initialPC, "_jumpIfTokenOut must leave nextPC untouched on mismatch");
    }

    // -----------------------------------------------------------------------
    // _deadline — temporal guard
    // -----------------------------------------------------------------------

    /// @notice At the boundary (`block.timestamp == deadline`) the instruction must NOT
    ///         revert. This is the equality case the workplan calls out: a guard that
    ///         used `<` instead of `<=` would fail here.
    function test_deadline_acceptsAtBoundary(uint40 deadline, address taker) public {
        bytes memory args = abi.encodePacked(deadline);
        vm.warp(uint256(deadline));

        harness.deadline(taker, args); // must not revert
    }

    /// @notice Strictly before the deadline is accepted.
    function test_deadline_acceptsBeforeBoundary(uint40 deadline, address taker) public {
        vm.assume(deadline > 0);
        bytes memory args = abi.encodePacked(deadline);
        vm.warp(uint256(deadline) - 1);

        harness.deadline(taker, args); // must not revert
    }

    /// @notice Strictly after the deadline reverts, with the taker and deadline in the
    ///         payload so the caller can attribute the failure.
    function test_deadline_revertsAfterBoundary(uint40 deadline, address taker) public {
        vm.assume(deadline < type(uint40).max);
        bytes memory args = abi.encodePacked(deadline);
        vm.warp(uint256(deadline) + 1);

        vm.expectRevert(abi.encodeWithSelector(DeadlineReached.selector, taker, uint256(deadline)));
        harness.deadline(taker, args);
    }
}
