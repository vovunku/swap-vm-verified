// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test, console2 } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { InstructionConformanceTest } from "../conformance/InstructionConformance.t.sol";

/// @notice The demo's EXECUTED tier: runs a composed program through the REAL
///         `ContextLib.runLoop` with the REAL instruction bodies.
///
/// @dev Inputs arrive by environment variable so the contract bytecode never changes and
///      Foundry does not recompile between runs — the difference between ~48 s and ~1 ms.
///      The gate token's `balanceOf` is mocked so any composed gate address can be exercised
///      without deploying a token at it.
contract DemoRun is Test {
    InstructionConformanceTest internal harness;

    function setUp() public { harness = new InstructionConformanceTest(); harness.setUp(); }

    function test_demo_execute() public {
        bytes memory program = vm.envBytes("DEMO_PROGRAM");
        address taker      = vm.envOr("DEMO_TAKER", address(0xBEEF));
        address tokenIn    = vm.envOr("DEMO_TOKEN_IN", address(1));
        address tokenOut   = vm.envOr("DEMO_TOKEN_OUT", address(2));
        uint256 amountIn   = vm.envOr("DEMO_AMOUNT_IN", uint256(1e18));
        uint256 amountOut  = vm.envOr("DEMO_AMOUNT_OUT", uint256(0));
        bool isExactIn     = vm.envOr("DEMO_EXACT_IN", true);
        uint256 gateBal    = vm.envOr("DEMO_GATE_BALANCE", uint256(0));

        // Whatever address the gate names, answer balanceOf(taker) with the chosen balance.
        if (program.length >= 22 && uint8(program[0]) == 0x23) {
            address gate;
            assembly { gate := shr(96, mload(add(program, 34))) }
            vm.mockCall(gate, abi.encodeWithSelector(IERC20.balanceOf.selector, taker), abi.encode(gateBal));
            console2.log("GATE", gate);
        }

        try harness.runProgram(program, taker, tokenIn, tokenOut, amountIn, amountOut, isExactIn)
            returns (InstructionConformanceTest.Outcome memory o) {
            console2.log("OK");
            console2.log("balanceIn", o.balanceIn);
            console2.log("balanceOut", o.balanceOut);
            console2.log("amountIn", o.amountIn);
            console2.log("amountOut", o.amountOut);
            console2.log("nextPC", o.pc);
        } catch (bytes memory err) {
            console2.log("REVERT");
            console2.logBytes(err);
        }
    }
}
