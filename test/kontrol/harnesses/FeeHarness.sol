// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { CalldataPtr, CalldataPtrLib } from "@1inch/solidity-utils/contracts/libraries/CalldataPtr.sol";

import { Context, ContextLib } from "../../../src/libs/VM.sol";
import { FeeArgsBuilder } from "../../../src/instructions/Fee.sol";
import { FeeExperimental } from "../../../src/instructions/FeeExperimental.sol";
import { IProtocolFeeProvider } from "../../../src/instructions/interfaces/IProtocolFeeProvider.sol";

/// @notice External surface over the `Fee` instruction family, for symbolic execution.
///
/// @dev Per `test/kontrol/analysis/HARNESS-FIDELITY.md`: this harness is Tier 1. It contains
///      **no transcription of any instruction**. Every entrypoint assembles a `Context` from
///      scalars, calls the real internal function on the real inheritance chain, and reads
///      the registers back.
///
///      It derives from `FeeExperimental`, not from `Fee`, because `FeeExperimental is Fee`
///      and the fee-*out* core (`_feeAmountOut`, `_flatFeeAmountOutXD`) lives there. Deriving
///      from the leaf reaches both halves of the fee family with one harness and one proof
///      store. Nothing in `FeeExperimental` shadows or overrides anything in `Fee`, so the
///      `Fee` entrypoints reached here are the same functions a `Fee`-only derivation would
///      reach; the `.sol` file each property is about is named on the property.
///
///      ## Three things about this harness that are load-bearing
///
///      ### 1. `msg.data[32:36]` is the instruction's `args`, and it is exact
///
///      The instruction entrypoints take `bytes calldata args` and parse `feeBps` out of it
///      with `uint32(bytes4(args))` (`Fee.sol:38`). `args` must therefore be *calldata*, and
///      a `bytes memory` built with `abi.encodePacked` cannot be passed.
///
///      The usual workaround — take `bytes calldata args` as a harness parameter — is the one
///      that stalled the `PeggedSwap` seam: a symbolic `args.length` propagates into every
///      memory offset downstream. So instead every entrypoint below takes `uint32 feeBps` as
///      its **first** parameter and hands the instruction `msg.data[32:36]`.
///
///      That slice is exactly the four bytes of `feeBps`. The ABI places the first parameter
///      in `msg.data[4:36]`, right-aligned, so a `uint32` occupies `msg.data[32:36]` and the
///      28 bytes above it are zero. `parseFlatFee` reads `uint32(bytes4(slice))`, which is
///      those four bytes big-endian. The offsets are concrete and the length is concrete, so
///      the prover sees no symbolic calldata geometry at all — only a 32-bit symbolic word.
///
///      **This is only correct while `feeBps` is the first parameter of the entrypoint.**
///      Reordering the parameters of any function below silently changes which bytes the
///      instruction parses. `test_harness_argsSliceIsTheFeeBpsParameter` in `FeeSpec` proves
///      the identification rather than asserting it in a comment.
///
///      ### 2. The empty tail program is a real program, not a stub
///
///      `_flatFeeAmountInXD`, `_feeAmountIn`, `_flatFeeAmountOutXD` and `_feeAmountOut` all
///      call `ctx.runLoop()`. `MinRateHarness` handles that with a stub dispatcher; most
///      entrypoints here do not need one, and the reason is stronger than convenience.
///
///      `runLoop` (`VM.sol:117-121`) reads `ctx.program()`, whose length comes from the low
///      128 bits of `ctx.vm.programPtr`. Leaving `ctx.vm` zero-initialised gives a
///      zero-length program, so the `while (pcs < length)` body never executes and
///      `ctx.vm.dispatch` — the null function pointer — is never invoked.
///
///      A zero-length tail is not an artefact. A fee instruction placed **last** in a maker's
///      program produces exactly this configuration on chain: `nextPC == programBytes.length`,
///      loop body skipped. So the empty-tail entrypoints characterise a genuinely reachable
///      program shape rather than a modelled one.
///
///      ### 3. Pre-seeding the register the inner program would have written
///
///      Three of the four fee bodies read a register *after* `runLoop` that the inner program
///      is expected to have written:
///
///        * `_feeAmountIn` exact-out  — reads `ctx.swap.amountIn`  after the loop;
///        * `_feeAmountOut` exact-in  — reads `ctx.swap.amountOut` after the loop.
///
///      With an empty tail those are zero and the properties are vacuous. The entrypoints
///      below therefore **pre-seed** the register with the value the swap instruction would
///      have produced, and still run the empty tail.
///
///      This is observationally identical to the real trajectory, and the argument is short
///      enough to check by eye. Between the guard and the division, each body reads exactly
///      one register, and nothing else; the guard
///      `require(amountIn == 0 || amountOut == 0)` passes in both configurations —
///      in production via the register the taker did not fix, here via the register the
///      harness left at zero. So the arithmetic executed is bit-identical.
///
///      It is also machine-checked rather than argued: `feeAmountInExactOutStubbed` installs a
///      genuine dispatcher over a one-opcode program, in the true production register shape
///      (`amountIn == 0`, `amountOut != 0` on entry), and
///      `test_diff_exactOut_stubbedMatchesPreseeded` in `FeeSpec` asserts the two agree on
///      both outputs. That property is the trust boundary for every pre-seeded entrypoint.
///
///      ## Residual gaps
///
///      `run-constructor = false`, so `_AQUA` reads as `address(0)`. No entrypoint below
///      reaches an `_AQUA.pull`, and the aqua variants are deliberately not exposed. The
///      `isStaticContext` flag is set on the protocol-fee entrypoint so no `safeTransferFrom`
///      is attempted either — the arithmetic, not the token movement, is what is specified.
contract FeeHarness is FeeExperimental {
    using ContextLib for Context;
    using CalldataPtrLib for CalldataPtr;

    constructor() FeeExperimental(address(0)) {}

    // -----------------------------------------------------------------------
    // Stub dispatcher — used by exactly one entrypoint, to validate the others
    // -----------------------------------------------------------------------

    /// @dev Fills whichever swap register was zero on entry from `amountNetPulled`, and
    ///      leaves the other untouched — the invariant a real pricing instruction maintains.
    ///      `_feeAmountIn` and `_feeAmountOut` never read or write `amountNetPulled`
    ///      (only the two `aqua*` wrappers do, and those are not exposed here), so the
    ///      register is free to carry the stub's payload without perturbing the code
    ///      under test. Memory only — no storage — for the reason given in `MinRateHarness`.
    function _dispatch(Context memory ctx, uint256, bytes calldata) internal {
        uint256 computed = ctx.swap.amountNetPulled;
        if (ctx.swap.amountIn == 0) {
            ctx.swap.amountIn = computed;
        } else {
            ctx.swap.amountOut = computed;
        }
    }

    // -----------------------------------------------------------------------
    // `Fee._feeAmountIn` — Fee.sol:226. The protocol-fee arithmetic core.
    // -----------------------------------------------------------------------

    /// @notice `_feeAmountIn` in the exact-in direction, with an empty tail program.
    /// @dev The production trajectory exactly: the taker fixes `amountIn`, the instruction
    ///      discounts it by the fee, runs the tail, and reconstructs. With an empty tail the
    ///      reconstruction sees the discounted amount, which is what a tail that prices
    ///      `amountOut` from `amountIn` also leaves behind.
    /// @return fee The value `_feeAmountIn` returns — note this is the *second* computation
    ///         (`Fee.sol:234`), because the exact-in branch overwrites the first.
    /// @return finalAmountIn `ctx.swap.amountIn` after the instruction.
    function feeAmountInExactIn(uint32 feeBps, uint256 amountIn)
        external
        returns (uint256 fee, uint256 finalAmountIn)
    {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.swap.amountIn = amountIn;

        fee = _feeAmountIn(ctx, feeBps);
        finalAmountIn = ctx.swap.amountIn;
    }

    /// @notice `_feeAmountIn` in the exact-out direction, register pre-seeded.
    /// @param swapAmountIn The `amountIn` the tail program is taken to have computed.
    function feeAmountInExactOut(uint32 feeBps, uint256 swapAmountIn)
        external
        returns (uint256 fee, uint256 finalAmountIn)
    {
        Context memory ctx;
        ctx.query.isExactIn = false;
        ctx.swap.amountIn = swapAmountIn;

        fee = _feeAmountIn(ctx, feeBps);
        finalAmountIn = ctx.swap.amountIn;
    }

    /// @notice `_feeAmountIn` exact-out driven by a real dispatcher over a one-opcode program,
    ///         in the production register shape.
    /// @dev The differential twin of `feeAmountInExactOut`. `amountOut` is non-zero and
    ///      `amountIn` is zero on entry, exactly as `SwapVM` populates them for an exact-out
    ///      fill; the tail then writes `amountIn`. Used only by
    ///      `test_diff_exactOut_stubbedMatchesPreseeded`, which is the trust boundary for the
    ///      pre-seeding shortcut used everywhere else.
    /// @param stubProgram The one-opcode program `hex"0000"`, passed through calldata so the
    ///        `CalldataPtr` references the live call frame.
    function feeAmountInExactOutStubbed(
        uint32 feeBps,
        uint256 swapAmountIn,
        uint256 takerAmountOut,
        bytes calldata stubProgram
    ) external returns (uint256 fee, uint256 finalAmountIn) {
        Context memory ctx;
        ctx.query.isExactIn = false;
        ctx.swap.amountIn = 0;
        ctx.swap.amountOut = takerAmountOut;
        ctx.swap.amountNetPulled = swapAmountIn;
        ctx.vm.nextPC = 0;
        ctx.vm.programPtr = CalldataPtrLib.from(stubProgram);
        ctx.vm.dispatch = _dispatch;

        fee = _feeAmountIn(ctx, feeBps);
        finalAmountIn = ctx.swap.amountIn;
    }

    /// @notice `_feeAmountIn` with both amount registers already populated, to exercise the
    ///         `FeeShouldBeAppliedBeforeSwapAmountsComputation` guard rather than the fee.
    function feeAmountInBothRegistersSet(uint32 feeBps, uint256 amountIn, uint256 amountOut)
        external
        returns (uint256 fee)
    {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.swap.amountIn = amountIn;
        ctx.swap.amountOut = amountOut;

        fee = _feeAmountIn(ctx, feeBps);
    }

    /// @notice `_feeAmountIn` exact-in, reporting every register, for the frame condition.
    /// @dev All five `SwapRegisters` fields are seeded and all but `amountIn` are returned,
    ///      so a property can state that the instruction wrote nothing else.
    function feeAmountInExactInFrame(
        uint32 feeBps,
        uint256 amountIn,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountNetPulled
    )
        external
        returns (
            uint256 outBalanceIn,
            uint256 outBalanceOut,
            uint256 outAmountOut,
            uint256 outAmountNetPulled
        )
    {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.swap.amountIn = amountIn;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountNetPulled = amountNetPulled;

        _feeAmountIn(ctx, feeBps);

        outBalanceIn = ctx.swap.balanceIn;
        outBalanceOut = ctx.swap.balanceOut;
        outAmountOut = ctx.swap.amountOut;
        outAmountNetPulled = ctx.swap.amountNetPulled;
    }

    // -----------------------------------------------------------------------
    // `Fee._flatFeeAmountInXD` — Fee.sol:67. Same shape, rounded up.
    // -----------------------------------------------------------------------

    /// @notice `_flatFeeAmountInXD` exact-in, through the real `parseFlatFee`.
    /// @dev `feeBps` MUST stay the first parameter — see note 1 in the contract docstring.
    function flatFeeExactIn(uint32 feeBps, uint256 amountIn) external returns (uint256 finalAmountIn) {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.swap.amountIn = amountIn;

        _flatFeeAmountInXD(ctx, msg.data[32:36]);

        finalAmountIn = ctx.swap.amountIn;
    }

    /// @notice `_flatFeeAmountInXD` exact-out, register pre-seeded, through the real parse.
    function flatFeeExactOut(uint32 feeBps, uint256 swapAmountIn) external returns (uint256 finalAmountIn) {
        Context memory ctx;
        ctx.query.isExactIn = false;
        ctx.swap.amountIn = swapAmountIn;

        _flatFeeAmountInXD(ctx, msg.data[32:36]);

        finalAmountIn = ctx.swap.amountIn;
    }

    /// @notice `_flatFeeAmountInXD` with both amount registers populated — the guard path.
    function flatFeeBothRegistersSet(uint32 feeBps, uint256 amountIn, uint256 amountOut) external {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.swap.amountIn = amountIn;
        ctx.swap.amountOut = amountOut;

        _flatFeeAmountInXD(ctx, msg.data[32:36]);
    }

    // -----------------------------------------------------------------------
    // `FeeExperimental._feeAmountOut` — FeeExperimental.sol:131, and its flat wrapper
    // -----------------------------------------------------------------------

    /// @notice `_feeAmountOut` exact-in, register pre-seeded.
    /// @param swapAmountOut The `amountOut` the tail program is taken to have priced.
    function feeAmountOutExactIn(uint32 feeBps, uint256 swapAmountOut)
        external
        returns (uint256 fee, uint256 finalAmountOut)
    {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.swap.amountOut = swapAmountOut;

        fee = _feeAmountOut(ctx, feeBps);
        finalAmountOut = ctx.swap.amountOut;
    }

    /// @notice `_feeAmountOut` exact-out: the taker fixes `amountOut`, the instruction grosses
    ///         it up for the tail and then restores it.
    function feeAmountOutExactOut(uint32 feeBps, uint256 amountOut)
        external
        returns (uint256 fee, uint256 finalAmountOut)
    {
        Context memory ctx;
        ctx.query.isExactIn = false;
        ctx.swap.amountOut = amountOut;

        fee = _feeAmountOut(ctx, feeBps);
        finalAmountOut = ctx.swap.amountOut;
    }

    /// @notice `_flatFeeAmountOutXD` exact-in, through the real `parseFlatFee`.
    function flatFeeOutExactIn(uint32 feeBps, uint256 swapAmountOut) external returns (uint256 finalAmountOut) {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.swap.amountOut = swapAmountOut;

        _flatFeeAmountOutXD(ctx, msg.data[32:36]);

        finalAmountOut = ctx.swap.amountOut;
    }

    // -----------------------------------------------------------------------
    // `Fee._protocolFeeAmountInXD` — Fee.sol:95. Static context, so no transfer.
    // -----------------------------------------------------------------------

    /// @notice `_protocolFeeAmountInXD` exact-in with `isStaticContext = true`.
    /// @dev The packed 24-byte argument layout (`feeBps || to`) is not expressible as two ABI
    ///      parameters, so this one entrypoint takes a `bytes24` and slices `msg.data[4:28]`.
    ///      A `bytes24` is left-aligned in its ABI slot, so those 24 bytes are exactly the
    ///      argument the maker would have assembled. `isStaticContext` suppresses the
    ///      `safeTransferFrom`, which would otherwise call into `address(0)`.
    function protocolFeeExactInStatic(bytes24 packedArgs, uint256 amountIn)
        external
        returns (uint256 finalAmountIn)
    {
        Context memory ctx;
        ctx.vm.isStaticContext = true;
        ctx.query.isExactIn = true;
        ctx.swap.amountIn = amountIn;

        _protocolFeeAmountInXD(ctx, msg.data[4:28]);

        finalAmountIn = ctx.swap.amountIn;
    }

    // -----------------------------------------------------------------------
    // Argument codec — `parse` runs on chain, `build` does not
    // -----------------------------------------------------------------------

    /// @notice The real `FeeArgsBuilder.parseFlatFee`, over the same slice the instructions use.
    /// @dev Also the identification lemma for note 1: if this returns its own argument, then
    ///      `msg.data[32:36]` is the `feeBps` parameter and every entrypoint above parses what
    ///      its caller passed.
    function parseFlatFee(uint32 feeBps) external view returns (uint32) {
        return FeeArgsBuilder.parseFlatFee(msg.data[32:36]);
    }

    /// @notice The real `FeeArgsBuilder.buildFlatFee` — the off-chain assembler.
    function buildFlatFee(uint32 feeBps) external pure returns (bytes memory) {
        return FeeArgsBuilder.buildFlatFee(feeBps);
    }

    /// @notice The real `FeeArgsBuilder.parseProtocolFee`, over a packed 24-byte slice.
    function parseProtocolFee(bytes24 packedArgs) external view returns (uint32 feeBps, address to) {
        return FeeArgsBuilder.parseProtocolFee(msg.data[4:28]);
    }

    /// @notice The real `FeeArgsBuilder.buildProtocolFee`.
    function buildProtocolFee(uint32 feeBps, address to) external pure returns (bytes memory) {
        return FeeArgsBuilder.buildProtocolFee(feeBps, to);
    }

    // -----------------------------------------------------------------------
    // `Fee._dynamicProtocolFeeAmountInXD` — Fee.sol:142. The harder tier.
    // -----------------------------------------------------------------------

    /// @notice `_dynamicProtocolFeeAmountInXD` against a concrete provider contract.
    /// @dev The provider address is 20 bytes of packed args, so this takes a `bytes20` and
    ///      slices `msg.data[4:24]`. The spec supplies the address of a `MockProtocolFeeProvider`
    ///      it deployed in `setUp`, so the `staticcall` lands on known code rather than on an
    ///      unconstrained symbolic address — symbolic execution through a call to an
    ///      unconstrained account is what makes this tier expensive.
    ///      `isStaticContext = true` suppresses the transfer, leaving the post-call validation
    ///      (`success && result.length == 64`, `feeBps <= BPS`, `to != address(0)`) and the
    ///      `_feeAmountIn` call as the only things executed.
    function dynamicProtocolFeeExactInStatic(bytes20 providerArg, uint256 amountIn)
        external
        returns (uint256 finalAmountIn)
    {
        Context memory ctx;
        ctx.vm.isStaticContext = true;
        ctx.query.isExactIn = true;
        ctx.swap.amountIn = amountIn;

        _dynamicProtocolFeeAmountInXD(ctx, msg.data[4:24]);

        finalAmountIn = ctx.swap.amountIn;
    }
}

/// @notice Concrete `IProtocolFeeProvider` for the dynamic-fee tier.
/// @dev Values live in storage rather than in `immutable`s so the spec can drive them per
///      property; `run-constructor = false` would make immutables read as zero, and a
///      constructor argument cannot be symbolic anyway because `setUp()` takes none.
contract MockProtocolFeeProvider is IProtocolFeeProvider {
    uint32 internal _feeBps;
    address internal _to;

    function set(uint32 feeBps, address to) external {
        _feeBps = feeBps;
        _to = to;
    }

    function getFeeBpsAndRecipient(bytes32, address, address, address, address, bool)
        external
        view
        returns (uint32, address)
    {
        return (_feeBps, _to);
    }
}
