// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test, stdError } from "forge-std/Test.sol";

import { Fee, FeeArgsBuilder, BPS } from "../../src/instructions/Fee.sol";
import { FeeHarness, MockProtocolFeeProvider } from "./harnesses/FeeHarness.sol";

/// @notice Kontrol specification for the `Fee` instruction family
///         (opcodes FlatFeeAmountIn / ProtocolFeeAmountIn / DynamicProtocolFeeAmountIn, and
///         the fee-out core in `FeeExperimental`).
///
/// @dev ## Reference semantics
///
///      `BPS = 1e9` is "100%". Writing `f` for `feeBps`, `A` for the input amount and `Y` for
///      the output amount, and using `\` for flooring integer division:
///
///        Fee.sol:226  `_feeAmountIn`, exact-in     a := A - (A*f)\BPS
///                                                  fee := (a*f)\(BPS-f)
///                                                  amountIn := a + fee
///        Fee.sol:226  `_feeAmountIn`, exact-out     fee := (A*f)\(BPS-f)
///                                                  amountIn := A + fee
///        Fee.sol:67   `_flatFeeAmountInXD`          the same two lines with `ceilDiv`
///                                                  in place of `\`
///        FeeExp.:131  `_feeAmountOut`, exact-in     fee := (Y*f)\BPS ; amountOut := Y - fee
///        FeeExp.:131  `_feeAmountOut`, exact-out    fee := (Y*f)\(BPS-f) ; amountOut grossed
///                                                  up for the tail, then RESTORED to Y
///
///      Three structural facts drive most of what follows, and each is proven below rather
///      than asserted here:
///
///      1. **`BPS - f` is a divisor.** Every fee-reconstruction line divides by it. At
///         `f == BPS` that divisor is zero and at `f > BPS` the subtraction underflows, so
///         the range of `f` is not a stylistic constraint — it is a liveness one.
///      2. **`f` is never range-checked on chain.** `FeeArgsBuilder.parseFlatFee`
///         (`Fee.sol:37-39`) is `uint32(bytes4(args))` and nothing else. The `require`
///         lives in `buildFlatFee` (`Fee.sol:24`), an off-chain helper. `BUGS.md` records the
///         standing conclusion that no `build` is a guard: program bytes are maker-assembled
///         and only `parse` runs on chain.
///      3. **The two `FeeBpsOutOfRange` errors are different errors.**
///         `FeeArgsBuilder.FeeBpsOutOfRange(uint32)` (`Fee.sol:21`) is raised only by the two
///         `build` helpers. `Fee.FeeBpsOutOfRange(uint256)` (`Fee.sol:57`) is raised only on
///         the *dynamic provider* path (`Fee.sol:160`, `Fee.sol:209`). Neither is reachable
///         from a program-carried `feeBps`.
///
///      ## Why the upper bounds are not the specification
///
///      Same discipline as `XYCSwapSpec`, for the same reason. "The fee never exceeds the
///      principal" and "the fee is at most the exact product" are both satisfied by a fee of
///      zero. Every rounding property below is therefore stated **two-sided** — an upper bound
///      that says the rounding did not go up, and a lower bound that says it did not go down
///      past the correct value — so the pair pins the arithmetic exactly and a degenerate
///      implementation is refuted rather than tolerated. Concrete `_witness` properties anchor
///      non-vacuity at points where the rounding genuinely fires.
///
///      ## Domain
///
///      Under Kontrol every `vm.assume` is a path constraint, so the assumptions are part of
///      each theorem. Narrow parameter *types* are preferred to `vm.assume` bounds wherever a
///      bound is needed, per this repository's convention.
///
///      `uint32 feeBps` is not a narrowing at all: `parseFlatFee` reads exactly four bytes, so
///      `uint32` **is** the on-chain domain of the parameter, including every value above
///      `BPS` that the builder would have rejected. Amounts are bounded to `uint128` where a
///      product of an amount with `feeBps` is formed, which keeps that product below `2^160`
///      and removes `chop` from the assertion terms — the measured cause of the `XYCSwap`
///      full-width stalls. Where a property is stated at full `uint256` width it is because no
///      such product appears.
///
///      ## Harness
///
///      `FeeHarness` is Tier 1 — it calls the real internal functions with no transcription.
///      Two of its conventions are load-bearing and are proven, not assumed:
///      `test_harness_argsSliceIsTheFeeBpsParameter` establishes that the `msg.data[32:36]`
///      slice handed to each instruction is the caller's `feeBps`, and
///      `test_diff_exactOut_stubbedMatchesPreseeded` establishes that pre-seeding the register
///      the tail program would have written agrees with running a real dispatcher. Read
///      `FeeHarness`'s docstring before trusting anything here.
contract FeeSpec is Test {
    FeeHarness internal harness;
    MockProtocolFeeProvider internal provider;

    /// @dev The one-opcode program (`opcode = 0`, `argsLength = 0`) that drives the stub
    ///      dispatcher exactly once. Same convention as `MinRateSpec`.
    bytes internal constant STUB_PROGRAM = hex"0000";

    /// @dev Half of `BPS`, i.e. a 50% fee. The largest `feeBps` at which the exact-in
    ///      round trip is provably within one wei of the principal — see
    ///      `test_feeIn_exactIn_overshootIsAtMostOneWei_boundedToHalfBps`.
    uint32 internal constant HALF_BPS = 500_000_000;

    function setUp() public {
        harness = new FeeHarness();
        provider = new MockProtocolFeeProvider();
    }

    // =======================================================================
    // 0. Harness identification — the lemma the rest of the file rests on
    // =======================================================================

    /// @notice The four calldata bytes each instruction parses as `feeBps` are exactly the
    ///         `feeBps` the caller passed.
    ///
    /// @dev `FeeHarness` hands every instruction `msg.data[32:36]` rather than a
    ///      `bytes calldata` parameter, because a symbolic `args.length` propagates into every
    ///      downstream memory offset and is what stalled the `PeggedSwap` seam. The slice is
    ///      the low four bytes of the first ABI word, which is where a `uint32` first
    ///      parameter lives.
    ///
    ///      That is an argument about ABI layout, and arguments about layout are exactly the
    ///      kind that rot silently when a signature is edited. This property makes it
    ///      machine-checked: it runs the real `FeeArgsBuilder.parseFlatFee` over the real
    ///      slice and asserts the result is the parameter. Quantified over the whole `uint32`
    ///      domain, so it covers the out-of-range values the rest of the file relies on
    ///      reaching the instruction unmodified.
    function test_harness_argsSliceIsTheFeeBpsParameter(uint32 feeBps) public view {
        assertEq(harness.parseFlatFee(feeBps), feeBps, "msg.data[32:36] must be the feeBps parameter");
    }

    // =======================================================================
    // 1. The argument codec — `parse` is the only thing that runs on chain
    // =======================================================================

    /// @notice `parseFlatFee` accepts a `feeBps` above the documented 100% maximum, silently.
    ///
    /// @dev **FINDING, machine-checked.** `buildFlatFee` (`Fee.sol:23-26`) requires
    ///      `feeBps <= BPS` and reverts `FeeArgsBuilder.FeeBpsOutOfRange` otherwise. `parseFlatFee`
    ///      (`Fee.sol:37-39`) is `feeBps = uint32(bytes4(args))` — no `require`, no mask, no
    ///      clamp. Program bytes are assembled by the maker off chain and only `parse` executes
    ///      on chain, so the range check is not a guard on anything: `BUGS.md` §"no `build` is a
    ///      guard" states this for `DutchAuctionArgsBuilder` and it holds verbatim here.
    ///
    ///      The consequence is not merely theoretical, and it is not a revert-with-a-good-error:
    ///      see `test_feeIn_bpsAboveMaximumPanicsRatherThanNamingTheError` and
    ///      `test_feeIn_maxBpsAlwaysPanicsOnDivisionByZero` below. The whole range
    ///      `[BPS, 2^32)` — that is, 76% of the `uint32` domain — reaches the arithmetic and
    ///      reverts with an unlabelled `Panic`.
    function test_parse_acceptsBpsAboveTheDocumentedMaximum(uint32 feeBps) public view {
        vm.assume(feeBps > BPS);

        assertEq(harness.parseFlatFee(feeBps), feeBps, "parse must not validate, and does not");
    }

    /// @notice `buildFlatFee` — the off-chain helper — does reject it.
    /// @dev The other half of the finding above: the validation exists, it is just on the side
    ///      of the boundary that no attacker has to cross. The selector is named rather than
    ///      accepting any revert, so a future change that kept the `require` but reported a
    ///      different value is caught. Note this is `FeeArgsBuilder.FeeBpsOutOfRange(uint32)`,
    ///      a *different error with a different selector* from `Fee.FeeBpsOutOfRange(uint256)`.
    function test_build_rejectsBpsAboveTheDocumentedMaximum(uint32 feeBps) public {
        vm.assume(feeBps > BPS);

        vm.expectRevert(abi.encodeWithSelector(FeeArgsBuilder.FeeBpsOutOfRange.selector, feeBps));
        harness.buildFlatFee(feeBps);
    }

    /// @notice The packed protocol-fee argument layout decodes positionally: four bytes of
    ///         `feeBps` followed by twenty bytes of recipient.
    /// @dev `parseProtocolFee` (`Fee.sol:41-44`) slices with `Calldata.slice`, which the library
    ///      documents as performing **no bounds checking**. Over a well-formed 24-byte argument
    ///      the layout is what `buildProtocolFee` emits; this pins that agreement over the whole
    ///      24-byte domain, so a change to either side that broke the pairing is caught.
    function test_parse_protocolFeeLayoutIsFeeBpsThenRecipient(uint32 feeBps, address to) public view {
        bytes24 packed = bytes24(bytes.concat(bytes4(feeBps), bytes20(to)));

        (uint32 parsedBps, address parsedTo) = harness.parseProtocolFee(packed);

        assertEq(parsedBps, feeBps, "feeBps must decode from the leading four bytes");
        assertEq(parsedTo, to, "recipient must decode from the trailing twenty bytes");
    }

    // =======================================================================
    // 2. The `FeeShouldBeAppliedBeforeSwapAmountsComputation` guard, both directions
    // =======================================================================

    /// @notice The guard fires when — and this direction says *whenever* — both amount
    ///         registers are already non-zero.
    ///
    /// @dev `require(amountIn == 0 || amountOut == 0)` at `Fee.sol:227`. Its purpose is
    ///      ordering: a fee applied after the pricing instruction has run would discount an
    ///      amount that has already been converted, so the fee would be charged on the wrong
    ///      side of the curve. The selector is named so that an arithmetic panic further down
    ///      cannot be mistaken for the guard firing — the same convention, and the same
    ///      reasoning, as `XYCSwapSpec.test_exactIn_revertsOnZeroBalanceIn`.
    ///
    ///      Quantified over full-width amounts: no product of an amount is formed before the
    ///      `require`, so nothing here needs a bound.
    function test_feeIn_guardRevertsWhenBothRegistersNonZero(uint32 feeBps, uint256 amountIn, uint256 amountOut)
        public
    {
        vm.assume(amountIn != 0);
        vm.assume(amountOut != 0);

        vm.expectRevert(Fee.FeeShouldBeAppliedBeforeSwapAmountsComputation.selector);
        harness.feeAmountInBothRegistersSet(feeBps, amountIn, amountOut);
    }

    /// @notice The same guard on `_flatFeeAmountInXD` (`Fee.sol:69`).
    function test_flatFeeIn_guardRevertsWhenBothRegistersNonZero(
        uint32 feeBps,
        uint256 amountIn,
        uint256 amountOut
    ) public {
        vm.assume(amountIn != 0);
        vm.assume(amountOut != 0);

        vm.expectRevert(Fee.FeeShouldBeAppliedBeforeSwapAmountsComputation.selector);
        harness.flatFeeBothRegistersSet(feeBps, amountIn, amountOut);
    }

    /// @notice The converse: a zero `amountIn` passes the guard however large `amountOut` is.
    ///
    /// @dev The "only if" half. Without it the guard specification is one-sided and would be
    ///      satisfied by an instruction that reverted unconditionally. `amountOut` is
    ///      quantified over the whole `uint256` domain and is *not* assumed zero — that is the
    ///      point: the disjunction is genuinely a disjunction, and the register the taker did
    ///      not fix is what lets a legitimate fee through.
    ///
    ///      `feeBps < BPS` because at `feeBps == BPS` the instruction reverts on a
    ///      division by zero regardless of the registers — see
    ///      `test_feeIn_maxBpsAlwaysPanicsOnDivisionByZero`, which is a statement about the
    ///      arithmetic and not about this guard.
    function test_feeIn_guardDoesNotFireWhenAmountInIsZero(uint32 feeBps, uint256 amountOut) public {
        vm.assume(feeBps < BPS);

        uint256 fee = harness.feeAmountInBothRegistersSet(feeBps, 0, amountOut);

        assertEq(fee, 0, "a zero input amount owes no fee, and must not trip the ordering guard");
    }

    // =======================================================================
    // 3. `feeBps == 0` is exactly the identity
    // =======================================================================

    /// @notice A zero fee leaves `amountIn` untouched and charges nothing.
    /// @dev Stated over the full `uint256` domain — with `feeBps == 0` the products
    ///      `amountIn * feeBps` are zero, so no `chop` reasoning arises and no bound is needed.
    ///      This is the boundary case that a fee curve must get exactly right: an order
    ///      carrying a zero fee must be indistinguishable from one carrying no fee instruction
    ///      at all, or the instruction is not free to include.
    function test_feeIn_zeroBpsIsTheIdentity(uint256 amountIn) public {
        (uint256 fee, uint256 finalAmountIn) = harness.feeAmountInExactIn(0, amountIn);

        assertEq(fee, 0, "a zero fee must charge nothing");
        assertEq(finalAmountIn, amountIn, "a zero fee must leave amountIn exactly as it found it");
    }

    /// @notice The same for the rounding-up variant, where it is a stronger claim.
    /// @dev `_flatFeeAmountInXD` uses `Math.ceilDiv`, and a ceiling of zero is the one place a
    ///      rounding-up implementation could plausibly return one wei instead of none.
    ///      OpenZeppelin's `ceilDiv` guards it with `SafeCast.toUint(a > 0) *`; this proves the
    ///      guard is effective through the instruction.
    function test_flatFeeIn_zeroBpsIsTheIdentity(uint256 amountIn) public {
        uint256 finalAmountIn = harness.flatFeeExactIn(0, amountIn);

        assertEq(finalAmountIn, amountIn, "a zero flat fee must leave amountIn exactly as it found it");
    }

    // =======================================================================
    // 4. `feeBps == BPS` — the documented maximum is unusable
    // =======================================================================

    /// @notice At `feeBps == BPS` — exactly the maximum `buildFlatFee` permits — the
    ///         instruction reverts with `Panic(0x12)` for **every** input amount.
    ///
    /// @dev **FINDING, machine-checked.** `buildFlatFee` requires `feeBps <= BPS`, so `BPS`
    ///      itself is an accepted value, and the NatSpec on every entrypoint says
    ///      "`1e9 = 100%`". A maker following the documentation and the builder can assemble a
    ///      100% fee. It never executes.
    ///
    ///      The mechanism is the reconstruction divisor. On the exact-in path
    ///      (`Fee.sol:231-234`) the first line takes the whole amount as fee, leaving
    ///      `amountIn == 0`; the second line then evaluates `0 * BPS / (BPS - BPS)`, and
    ///      Solidity's checked division panics on a zero divisor even with a zero numerator.
    ///      The revert is `Panic(0x12)`, which carries no indication of which parameter was
    ///      wrong.
    ///
    ///      Quantified over `amountIn`, so this is not an edge case within the maximum — it is
    ///      the whole of it. `uint128` keeps `amountIn * BPS` below `2^158`, so the only
    ///      reachable revert is the division; at full width an overflow in that product would
    ///      also panic, but with `0x11`, and conflating the two would weaken the statement.
    function test_feeIn_maxBpsAlwaysPanicsOnDivisionByZero(uint128 amountIn) public {
        vm.expectRevert(stdError.divisionError);
        harness.feeAmountInExactIn(uint32(BPS), amountIn);
    }

    /// @notice The same at the flat-fee entrypoint, via `Math.ceilDiv`'s explicit panic.
    /// @dev OpenZeppelin's `ceilDiv` raises `Panic.DIVISION_BY_ZERO` deliberately, to
    ///      "guarantee the same behavior as in a regular Solidity division". So both fee-in
    ///      instructions agree, and both are unusable at their documented maximum.
    function test_flatFeeIn_maxBpsAlwaysPanicsOnDivisionByZero(uint128 amountIn) public {
        vm.expectRevert(stdError.divisionError);
        harness.flatFeeExactIn(uint32(BPS), amountIn);
    }

    // =======================================================================
    // 5. `feeBps > BPS` — reachable, and unlabelled
    // =======================================================================

    /// @notice Every `feeBps` above the maximum reverts with a bare arithmetic `Panic(0x11)`,
    ///         never with `FeeBpsOutOfRange`.
    ///
    /// @dev **FINDING, machine-checked.** The brief for this specification asked whether
    ///      `feeBps > BPS` reverts `FeeBpsOutOfRange`. It does not, anywhere on the
    ///      program-carried path:
    ///
    ///        * `FeeArgsBuilder.FeeBpsOutOfRange` (`Fee.sol:21`) is raised only inside
    ///          `buildFlatFee` / `buildProtocolFee`, which are off-chain helpers;
    ///        * `Fee.FeeBpsOutOfRange` (`Fee.sol:57`) is raised only at `Fee.sol:160` and
    ///          `Fee.sol:209`, both of which validate a fee returned by an *external provider*,
    ///          not one carried in the program.
    ///
    ///      What actually happens is an unchecked-subtraction underflow, and it is uniform over
    ///      the domain although it arrives by two different routes: for `amountIn > 0` the
    ///      discount `(amountIn*f)\BPS` exceeds `amountIn` and `Fee.sol:232` underflows; for
    ///      `amountIn == 0` the discount is zero and the underflow is instead `BPS - feeBps` at
    ///      `Fee.sol:234`. Both are `Panic(0x11)`.
    ///
    ///      Why it matters beyond hygiene: a `Panic` is indistinguishable from an
    ///      overflow anywhere else in the program, so an integrator cannot tell a
    ///      misconfigured fee from a too-large trade, and 76% of the parseable `feeBps` domain
    ///      lands here.
    function test_feeIn_bpsAboveMaximumPanicsRatherThanNamingTheError(uint32 feeBps, uint128 amountIn) public {
        vm.assume(feeBps > BPS);

        vm.expectRevert(stdError.arithmeticError);
        harness.feeAmountInExactIn(feeBps, amountIn);
    }

    /// @notice The same at the flat-fee entrypoint.
    function test_flatFeeIn_bpsAboveMaximumPanicsRatherThanNamingTheError(uint32 feeBps, uint128 amountIn)
        public
    {
        vm.assume(feeBps > BPS);

        vm.expectRevert(stdError.arithmeticError);
        harness.flatFeeExactIn(feeBps, amountIn);
    }

    // =======================================================================
    // 6. Fee-out: the fee never exceeds the principal, and is exactly the floor
    // =======================================================================

    /// @notice The fee taken out of `amountOut` never exceeds `amountOut`.
    ///
    /// @dev Property 1 of the brief, on the side where it holds. `(Y*f)\BPS <= Y` for every
    ///      `f <= BPS`, so the subtraction at `FeeExperimental.sol:138` cannot underflow and
    ///      the taker's net output is well defined. Failure here would be severe: the
    ///      instruction would revert on an ordinary fill, or — with an unchecked
    ///      subtraction — wrap.
    ///
    ///      This is an upper bound and therefore satisfied by a zero fee; it is pinned exactly
    ///      by `test_feeOut_exactIn_isExactlyTheFloor` immediately below, and anchored
    ///      non-vacuously by `test_feeOut_exactIn_isReachable_witness`.
    function test_feeOut_exactIn_feeNeverExceedsTheOutput(uint32 feeBps, uint128 swapAmountOut) public {
        vm.assume(feeBps <= BPS);

        (uint256 fee, uint256 net) = harness.feeAmountOutExactIn(feeBps, swapAmountOut);

        assertLe(fee, swapAmountOut, "the fee must never exceed the amount it is taken from");
        assertEq(net, uint256(swapAmountOut) - fee, "the net output must be the gross less the fee");
    }

    /// @notice The fee-out amount is exactly `floor(amountOut * feeBps / BPS)` — neither a wei
    ///         high nor a wei low.
    ///
    /// @dev Property 4 of the brief, stated two-sided so it is exact rather than merely
    ///      bounded. With `n = Y * f`:
    ///
    ///        fee * BPS <= n        the rounding did not go up
    ///        n - fee * BPS < BPS   the rounding did not go down past the floor
    ///
    ///      Together these force `fee = n \ BPS`. Neither is written as a division, so no
    ///      symbolic `DIV` enters the path condition — the same technique as
    ///      `XYCSwapSpec.test_exactIn_isExactlyTheFloor`.
    ///
    ///      **Which party the flooring favours, and it is not the obvious one.** The fee is
    ///      subtracted from the taker's output and handed to the fee recipient
    ///      (`FeeExperimental.sol:110`), so rounding the fee *down* rounds the taker's net
    ///      output *up*. Fee-out therefore rounds against the recipient and in favour of the
    ///      taker. That is the opposite of the convention in `XYCSwap`, where both legs round
    ///      in the maker's favour, and it is the opposite of `_flatFeeAmountInXD`, which
    ///      rounds its fee up — see `test_flatFeeIn_exactOut_isExactlyTheCeiling`. All three
    ///      are in the same VM and a program may contain all three.
    ///
    ///      `uint128` on the amount keeps `Y * f < 2^160`, so every term is representable and
    ///      the assertion is about the fee rather than about `chop`.
    function test_feeOut_exactIn_isExactlyTheFloor(uint32 feeBps, uint128 swapAmountOut) public {
        vm.assume(feeBps <= BPS);

        (uint256 fee, ) = harness.feeAmountOutExactIn(feeBps, swapAmountOut);

        uint256 n = uint256(swapAmountOut) * feeBps;

        assertLe(fee * BPS, n, "the fee must not round up");
        assertLt(n - fee * BPS, BPS, "the fee must not fall a wei short of the floor");
    }

    /// @notice Concrete witness that the fee-out leg charges a non-zero, strictly rounded fee.
    ///
    /// @dev The direct refutation of vacuity: an implementation returning `fee = 0`
    ///      unconditionally satisfies every upper bound in this file and fails this on its
    ///      first assertion.
    ///
    ///      Worked by hand, at a 0.5% fee — the rate `test/FeeOutAdditivityViolation.t.sol`
    ///      uses, so the point is the one the existing suite exercises:
    ///        n   = 1_000_000_007 * 5_000_000 = 5_000_000_035_000_000
    ///        fee = floor(n / 1e9)            = 5_000_000
    ///        net = 1_000_000_007 - 5_000_000 = 995_000_007
    ///      and `5_000_000 * 1e9 = 5_000_000_000_000_000 < n`, so the flooring is strict here
    ///      and this point distinguishes flooring from rounding to nearest or up.
    function test_feeOut_exactIn_isReachable_witness() public {
        (uint256 fee, uint256 net) = harness.feeAmountOutExactIn(5_000_000, 1_000_000_007);

        assertEq(fee, 5_000_000, "fee-out must take the floor of the exact product");
        assertEq(net, 995_000_007, "and hand the remainder to the taker");
        assertGt(fee, 0, "a non-zero fee on a non-zero amount: the upper bounds are not vacuous here");
        assertLt(fee * BPS, 5_000_000_035_000_000, "the flooring is strict at this point");
    }

    /// @notice A higher fee rate never yields a smaller fee.
    ///
    /// @dev Property 3 of the brief. Failure would mean a fee curve that inverts — a maker
    ///      could lower the rate and collect more, and a taker could be charged more by asking
    ///      for a discount. `floor(Y*f/BPS)` is monotone in `f` because the divisor is the
    ///      constant `BPS`; that this survives the surrounding instruction is what is proven.
    function test_feeOut_exactIn_feeIsMonotoneInBps(uint32 lowBps, uint32 highBps, uint128 swapAmountOut) public {
        vm.assume(lowBps <= highBps);
        vm.assume(highBps <= BPS);

        (uint256 lowFee, ) = harness.feeAmountOutExactIn(lowBps, swapAmountOut);
        (uint256 highFee, ) = harness.feeAmountOutExactIn(highBps, swapAmountOut);

        assertLe(lowFee, highFee, "a higher fee rate must never yield a smaller fee");
    }

    // =======================================================================
    // 7. Additivity, as a machine-checked property
    // =======================================================================

    /// @notice Splitting an exact-in fill in two never yields *less* net output, and never
    ///         yields more than one wei more.
    ///
    /// @dev Property 7 of the brief. `test/FeeOutAdditivityViolation.t.sol` already documents
    ///      by sampling that `feeOut` violates additivity and that splitting can be profitable.
    ///      This upgrades the arithmetic half of that result from sampled to proven, and — more
    ///      usefully — **bounds the magnitude**.
    ///
    ///      With `net(Y) = Y - (Y*f)\BPS`, the discrepancy is
    ///
    ///          net(a) + net(b) - net(a+b) = ((a+b)*f)\BPS - (a*f)\BPS - (b*f)\BPS
    ///
    ///      which is the superadditivity defect of flooring and lies in `{0, 1}`. So:
    ///
    ///        * additivity **is** violated — the lower bound below is not an equality, and
    ///          `test_feeOut_exactIn_additivityIsViolated_witness` exhibits a point where the
    ///          gap is exactly one;
    ///        * the violation is **always in the splitter's favour**, never the pool's;
    ///        * and at the instruction level it is worth **at most one wei per split**.
    ///
    ///      That last clause is the part worth having. The economic result in
    ///      `FeeOutAdditivityViolation` — where splitting is worth far more than a wei — is
    ///      therefore *not* attributable to this instruction's rounding. It comes from the
    ///      pool state moving between the two fills, which is a property of the curve and the
    ///      balance registers, not of the fee. Proving this bound is what separates the two.
    ///
    ///      Both parts are bounded to `uint128` so that `a + b` cannot overflow and both
    ///      products stay below `2^161`.
    function test_feeOut_exactIn_splittingGainsAtMostOneWei(uint32 feeBps, uint128 partA, uint128 partB) public {
        vm.assume(feeBps <= BPS);

        (, uint256 netA) = harness.feeAmountOutExactIn(feeBps, partA);
        (, uint256 netB) = harness.feeAmountOutExactIn(feeBps, partB);
        (, uint256 netWhole) = harness.feeAmountOutExactIn(feeBps, uint256(partA) + partB);

        assertGe(netA + netB, netWhole, "splitting must never yield less than filling whole");
        assertLe(netA + netB - netWhole, 1, "and never more than one wei more");
    }

    /// @notice Concrete witness that the additivity gap is genuinely reachable and genuinely
    ///         one wei.
    ///
    /// @dev The refutation half of the property above: without this, `netA + netB >= netWhole`
    ///      is satisfied by an additive implementation and the "violation" would be unproven.
    ///
    ///      Worked by hand at a 50% fee:
    ///        net(1) = 1 - floor(0.5) = 1 - 0 = 1, twice, so splitting yields 2
    ///        net(2) = 2 - floor(1.0) = 2 - 1 = 1
    ///      A taker splitting a two-wei fill into two one-wei fills pays no fee at all and
    ///      keeps both wei, where the unsplit fill pays one. The whole fee is avoided.
    ///
    ///      The scale of that is the point: the defect is one wei of *fee*, but as a fraction
    ///      of the fee it is 100%, and it is a dust-scale attack rather than a whole-order one.
    function test_feeOut_exactIn_additivityIsViolated_witness() public {
        (uint256 feeA, uint256 netA) = harness.feeAmountOutExactIn(HALF_BPS, 1);
        (uint256 feeB, uint256 netB) = harness.feeAmountOutExactIn(HALF_BPS, 1);
        (uint256 feeWhole, uint256 netWhole) = harness.feeAmountOutExactIn(HALF_BPS, 2);

        assertEq(feeA, 0, "a one-wei fill at 50% pays no fee");
        assertEq(feeB, 0, "and neither does the second");
        assertEq(feeWhole, 1, "but the unsplit two-wei fill pays one");

        assertEq(netA + netB, 2, "split: the taker keeps everything");
        assertEq(netWhole, 1, "whole: the taker keeps one");
        assertEq(netA + netB - netWhole, 1, "the additivity gap is exactly one wei here");
    }

    /// @notice The mirror on the fee-in exact-out leg: splitting reduces the total fee, by at
    ///         most one wei.
    /// @dev Same shape, opposite sign of interest — here the loss falls on the fee recipient
    ///      rather than the gain on the taker. `fee(A) = (A*f)\(BPS-f)` is superadditive by
    ///      flooring, so `fee(a) + fee(b) <= fee(a+b)`.
    function test_feeIn_exactOut_splittingCostsAtMostOneWeiOfFee(uint32 feeBps, uint128 partA, uint128 partB)
        public
    {
        vm.assume(feeBps < BPS);

        (uint256 feeA, ) = harness.feeAmountInExactOut(feeBps, partA);
        (uint256 feeB, ) = harness.feeAmountInExactOut(feeBps, partB);
        (uint256 feeWhole, ) = harness.feeAmountInExactOut(feeBps, uint256(partA) + partB);

        assertLe(feeA + feeB, feeWhole, "splitting must never increase the fee collected");
        assertLe(feeWhole - feeA - feeB, 1, "and must never decrease it by more than one wei");
    }

    // =======================================================================
    // 8. Fee-in exact-out: exactly the floor, and the fee is NOT bounded by the principal
    // =======================================================================

    /// @notice The exact-out fee-in reconstruction is exactly `floor(amountIn * f / (BPS - f))`.
    ///
    /// @dev Two-sided, with `d = BPS - f` and `n = A * f`:
    ///
    ///        fee * d <= n        the rounding did not go up
    ///        n - fee * d < d     the rounding did not go down past the floor
    ///
    ///      Flooring here rounds *against the fee recipient*: the maker forwards
    ///      `feeAmountIn` to the protocol (`Fee.sol:100`) and receives the same amount as extra
    ///      `amountIn` from the taker, so a fee rounded down is a fee under-collected by up to
    ///      one wei. Consistent with the fee-out leg, and inconsistent with
    ///      `_flatFeeAmountInXD` — the contrast is pinned in
    ///      `test_flatFeeIn_exactOut_isExactlyTheCeiling`.
    ///
    ///      `f < BPS` is a liveness condition, not a narrowing: at `f == BPS` the divisor is
    ///      zero and above it the subtraction underflows, both covered by their own properties
    ///      above.
    function test_feeIn_exactOut_isExactlyTheFloor(uint32 feeBps, uint128 swapAmountIn) public {
        vm.assume(feeBps < BPS);

        (uint256 fee, uint256 finalAmountIn) = harness.feeAmountInExactOut(feeBps, swapAmountIn);

        uint256 d = BPS - feeBps;
        uint256 n = uint256(swapAmountIn) * feeBps;

        assertLe(fee * d, n, "the fee must not round up");
        assertLt(n - fee * d, d, "the fee must not fall a wei short of the floor");
        assertEq(finalAmountIn, uint256(swapAmountIn) + fee, "amountIn must be grossed up by exactly the fee");
    }

    /// @notice On the exact-out leg the fee is **not** bounded by the principal, and the
    ///         factor is unbounded.
    ///
    /// @dev Property 1 of the brief, on the side where it fails — and it fails by construction
    ///      rather than by rounding. The exact-out leg grosses up: it must find an `amountIn`
    ///      whose post-fee remainder is the amount the tail priced, so it computes
    ///      `A * f / (BPS - f)`, which diverges as `f -> BPS`.
    ///
    ///      This is arguably what a fee of `f` *means* on that leg, so it is recorded as a
    ///      characterisation rather than as a defect. It is worth pinning because a reader of
    ///      `_feeAmountIn` sees a function that returns "the fee" and it is natural — and
    ///      wrong — to assume that value is bounded by the amount it is charged on. Any
    ///      downstream code that allocates, caps or accounts against `feeAmountIn` on that
    ///      assumption is wrong by a factor that a maker chooses.
    ///
    ///      Worked by hand at `f = BPS - 1`, one wei of bps below 100%:
    ///        d   = 1
    ///        fee = 1000 * 999_999_999 / 1 = 999_999_999_000
    ///      A gross input of 1000 becomes an `amountIn` of 999_999_999_000 + 1000 — a factor
    ///      of one billion, from a fee the builder accepts without complaint.
    function test_feeIn_exactOut_feeIsUnboundedInThePrincipal_witness() public {
        (uint256 fee, uint256 finalAmountIn) = harness.feeAmountInExactOut(999_999_999, 1000);

        assertEq(fee, 999_999_999_000, "the gross-up factor is 1/(1 - f/BPS), and it diverges");
        assertEq(finalAmountIn, 999_999_999_000 + 1000, "amountIn is the principal plus that fee");
        assertGt(fee, 1000, "the fee exceeds the principal it is charged on");
    }

    // =======================================================================
    // 9. Fee-in exact-in: the round trip, and where it overshoots
    // =======================================================================

    /// @notice The exact-in path is exactly two floored divisions — a discount and a
    ///         reconstruction — and both are pinned two-sided.
    ///
    /// @dev The complete specification of `_feeAmountIn`'s exact-in branch
    ///      (`Fee.sol:229-235`). The branch performs
    ///
    ///          a   := A - (A*f)\BPS          discount, before the tail runs
    ///          fee := (a*f)\(BPS-f)          reconstruction, after it
    ///          amountIn := a + fee
    ///
    ///      and `a` is recoverable from the harness outputs as `finalAmountIn - fee`, so both
    ///      divisions can be pinned without the harness exposing an internal local. Each is
    ///      stated two-sided, in the multiplicative form that keeps symbolic `DIV` out of the
    ///      path condition:
    ///
    ///          (A - a) * BPS <= A*f    and    A*f - (A - a)*BPS < BPS
    ///          fee * (BPS-f) <= a*f    and    a*f - fee*(BPS-f) < BPS-f
    ///
    ///      Together they say the branch is *this* pair of floors and nothing else, which is
    ///      what makes the overshoot below a consequence of the specification rather than an
    ///      observation about one implementation.
    ///
    ///      Every product is bounded: `A < 2^128` and `f < 2^32`, and `a <= A`, `fee*(BPS-f) <=
    ///      a*f`, so nothing exceeds `2^160`.
    function test_feeIn_exactIn_isExactlyTwoFlooredDivisions(uint32 feeBps, uint128 amountIn) public {
        vm.assume(feeBps < BPS);

        (uint256 fee, uint256 finalAmountIn) = harness.feeAmountInExactIn(feeBps, amountIn);

        uint256 discounted = finalAmountIn - fee; // `a`; cannot underflow, amountIn := a + fee
        uint256 n = uint256(amountIn) * feeBps;
        uint256 d = BPS - feeBps;

        // The discount: `A - a = (A*f) \ BPS`, exactly.
        assertLe((uint256(amountIn) - discounted) * BPS, n, "the discount must not round up");
        assertLt(n - (uint256(amountIn) - discounted) * BPS, BPS, "nor fall a wei short of the floor");

        // The reconstruction: `fee = (a*f) \ (BPS-f)`, exactly.
        assertLe(fee * d, discounted * feeBps, "the reconstruction must not round up");
        assertLt(discounted * feeBps - fee * d, d, "nor fall a wei short of the floor");
    }

    /// @notice The exact-in round trip does NOT return `amountIn` to at most its original
    ///         value. It can overshoot, and the overshoot is unbounded.
    ///
    /// @dev **REFUTED, deliberately.** This is stated as a property so the prover produces the
    ///      counterexample and its path condition, rather than leaving the claim to a hand
    ///      argument. It is expected to FAIL; the concrete witnesses beside it fix two points
    ///      on the failure, and the `_boundedToHalfBps` twin below records the strongest form
    ///      that does hold.
    ///
    ///      The mechanism is rounding amplification, and it is worth stating precisely because
    ///      it is not the usual off-by-one. The discount floors `a` down to an integer, and the
    ///      reconstruction then multiplies the error by `1/(1 - f/BPS)`. At `f` near `BPS` that
    ///      factor is enormous, so a sub-wei discounting error becomes a large absolute
    ///      overcharge — see `test_feeIn_exactIn_overshootIsUnbounded_witness`, where an
    ///      `amountIn` of 1000 is reconstructed as 1_000_000_000.
    /// @custom:kontrol-status REFUTED — the counterexample is the deliverable. The proven
    ///      restriction is `test_feeIn_exactIn_overshootIsAtMostOneWei_boundedToHalfBps`.
    function test_feeIn_exactIn_reconstructionNeverExceedsThePrincipal(uint32 feeBps, uint128 amountIn) public {
        vm.assume(feeBps < BPS);

        (, uint256 finalAmountIn) = harness.feeAmountInExactIn(feeBps, amountIn);

        assertLe(finalAmountIn, amountIn, "the round trip must not charge more than the taker offered");
    }

    /// @notice Concrete witness: an `amountIn` of 1000 is reconstructed as 1_000_000_000.
    ///
    /// @dev **FINDING, machine-checked.** Worked by hand at `f = BPS - 1`:
    ///        discount:       (1000 * 999_999_999) \ 1e9 = 999
    ///        a             = 1000 - 999            = 1
    ///        reconstruction: (1 * 999_999_999) \ 1  = 999_999_999
    ///        amountIn      = 1 + 999_999_999       = 1_000_000_000
    ///
    ///      The exact value the reconstruction is trying to recover is 1000: `a` should have
    ///      been `1e-6`, and flooring it to 1 is a relative error of a million, which the
    ///      `1/(1-f)` factor then carries straight into the result. The taker is charged
    ///      1_000_000x what they offered.
    ///
    ///      **Reachability, stated honestly.** `feeBps` is maker-signed program bytes and the
    ///      builder's range check does not run on chain, so the parameter is reachable; the
    ///      register is the taker's own `amount`. What limits the damage is
    ///      `TakerTraits.validate`, which caps `amountIn` against the taker's threshold — but
    ///      `BUGS.md` records that the threshold is opt-in and a taker who omits the slice has
    ///      no cap at all. So this is a real overcharge against an unprotected taker, and a
    ///      revert against a protected one. Either way the instruction's own arithmetic is what
    ///      produces it.
    function test_feeIn_exactIn_overshootIsUnbounded_witness() public {
        (uint256 fee, uint256 finalAmountIn) = harness.feeAmountInExactIn(999_999_999, 1000);

        assertEq(fee, 999_999_999, "the reconstruction charges the whole of the rounded-up remainder");
        assertEq(finalAmountIn, 1_000_000_000, "an offer of 1000 becomes a charge of one billion");
        assertEq(finalAmountIn / 1000, 1_000_000, "a factor of exactly one million");
    }

    /// @notice Concrete witness that the overshoot is not confined to extreme fee rates: at a
    ///         plain 50% fee, an `amountIn` of 1 is reconstructed as 2.
    ///
    /// @dev Worked by hand at `f = BPS/2`:
    ///        discount:       (1 * 5e8) \ 1e9 = 0
    ///        a             = 1
    ///        reconstruction: (1 * 5e8) \ 5e8 = 1
    ///        amountIn      = 2
    ///      The taker offered one wei and is charged two. This is the boundary point of the
    ///      `_boundedToHalfBps` property below — the overshoot is exactly one wei here — and it
    ///      is what makes that property tight rather than slack.
    function test_feeIn_exactIn_overshootAtHalfFee_witness() public {
        (uint256 fee, uint256 finalAmountIn) = harness.feeAmountInExactIn(HALF_BPS, 1);

        assertEq(fee, 1, "the reconstruction charges a whole wei on a one-wei principal");
        assertEq(finalAmountIn, 2, "and doubles the taker's offer");
    }

    /// @notice Restricted twin: at fee rates up to 50%, the exact-in round trip overshoots by
    ///         at most one wei.
    ///
    /// @dev The strongest form of `test_feeIn_exactIn_reconstructionNeverExceedsThePrincipal`
    ///      that survives. The full-width form is REFUTED and is NOT deleted — it stays above,
    ///      exactly as written, so the gap remains visible.
    ///
    ///      **What could be wrong above the bound and still pass this.** Everything the
    ///      refutation exhibits: at `f > BPS/2` the overshoot grows without limit, reaching
    ///      1_000_000x at `f = BPS - 1`. So this is not a "probably fine in practice"
    ///      narrowing of a property that holds generally — it is the exact boundary of a
    ///      property that fails hard on the other side, and `BPS/2` is where it fails. A
    ///      reviewer should read the pair, not this half.
    ///
    ///      Why the bound is exactly `BPS/2`: writing `d = BPS - f`, the reconstruction error
    ///      is at most `f/d` wei, and `f/d <= 1` precisely when `f <= BPS/2`.
    ///      `test_feeIn_exactIn_overshootAtHalfFee_witness` shows the one wei is attained, so
    ///      neither the bound nor the constant can be tightened.
    function test_feeIn_exactIn_overshootIsAtMostOneWei_boundedToHalfBps(uint32 feeBps, uint128 amountIn)
        public
    {
        vm.assume(feeBps <= HALF_BPS);

        (, uint256 finalAmountIn) = harness.feeAmountInExactIn(feeBps, amountIn);

        assertLe(finalAmountIn, uint256(amountIn) + 1, "at most a one-wei overcharge at fee rates up to 50%");
    }

    // =======================================================================
    // 10. `_flatFeeAmountInXD` rounds the other way
    // =======================================================================

    /// @notice The flat fee-in reconstruction is exactly `ceil(amountIn * f / (BPS - f))`.
    ///
    /// @dev The rounding-direction contrast, pinned. `_flatFeeAmountInXD` and `_feeAmountIn`
    ///      compute the same quantity — the source comment at `Fee.sol:71` says so in as many
    ///      words, "the same `_feeAmountIn` call, just with rounding up" — and they round in
    ///      **opposite** directions. On this leg the flat fee rounds the taker's `amountIn`
    ///      **up** (toward the maker, who keeps it) while `_feeAmountIn` rounds it **down**
    ///      (away from the protocol, which does not collect it). Both are defensible in
    ///      isolation; a program containing both charges its taker inconsistently by a wei
    ///      depending on which fee instruction it hit, and a reader who assumes the two agree
    ///      because the comment says they compute the same thing is wrong by that wei.
    ///
    ///      Stated two-sided with `d = BPS - f` and `n = A * f`:
    ///
    ///        n <= fee * d        the fee covers the exact value: it did not round down
    ///        fee * d < n + d     it is not a whole unit too large: it did not round past
    ///
    ///      Written this way rather than as `(fee - 1) * d < n` so no case split on `fee > 0`
    ///      is needed and no product the instruction never forms appears. `n + d` is safe:
    ///      `n < 2^160` and `d <= BPS`.
    function test_flatFeeIn_exactOut_isExactlyTheCeiling(uint32 feeBps, uint128 swapAmountIn) public {
        vm.assume(feeBps < BPS);

        uint256 finalAmountIn = harness.flatFeeExactOut(feeBps, swapAmountIn);

        uint256 fee = finalAmountIn - swapAmountIn;
        uint256 d = BPS - feeBps;
        uint256 n = uint256(swapAmountIn) * feeBps;

        assertLe(n, fee * d, "the flat fee must not round down");
        assertLt(fee * d, n + d, "nor round up by a whole unit");
    }

    /// @notice Concrete witness distinguishing the two rounding directions at one point.
    ///
    /// @dev At `f = 3` bps-of-1e9 and `A = 1000`: `n = 3000`, `d = 999_999_997`.
    ///        `_feeAmountIn`      floors:  3000 \ 999_999_997      = 0
    ///        `_flatFeeAmountInXD` ceils:  ceil(3000 / 999_999_997) = 1
    ///      One wei apart, on the same inputs, from two instructions the source describes as
    ///      computing the same thing. This is the smallest possible demonstration and it is
    ///      the one that a refactor unifying the two would break.
    function test_diff_exactOut_flatCeilsWhereProtocolFloors_witness() public {
        (uint256 flooredFee, ) = harness.feeAmountInExactOut(3, 1000);
        uint256 ceiledFinal = harness.flatFeeExactOut(3, 1000);

        assertEq(flooredFee, 0, "the protocol fee floors this to nothing");
        assertEq(ceiledFinal - 1000, 1, "the flat fee ceils the same value to one wei");
    }

    // =======================================================================
    // 11. Frame conditions
    // =======================================================================

    /// @notice `_feeAmountIn` exact-in writes `amountIn` and nothing else.
    ///
    /// @dev Property 8 of the brief. `SwapRegisters` has five fields; this instruction is
    ///      specified to touch one. `amountNetPulled` is the interesting one: the *aqua*
    ///      variant of the protocol fee does accumulate into it (`Fee.sol:118`), so a
    ///      refactor that moved that accumulation down into the shared `_feeAmountIn` would
    ///      double-count for the non-aqua path. This property catches that.
    ///
    ///      Balances and `amountNetPulled` are quantified at full `uint256` width — they are
    ///      never multiplied here — while `amountIn` is bounded so the fee arithmetic stays
    ///      inside `2^160`.
    function test_feeIn_exactIn_touchesOnlyAmountIn(
        uint32 feeBps,
        uint128 amountIn,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountNetPulled
    ) public {
        vm.assume(feeBps < BPS);

        (
            uint256 outBalanceIn,
            uint256 outBalanceOut,
            uint256 outAmountOut,
            uint256 outAmountNetPulled
        ) = harness.feeAmountInExactInFrame(feeBps, amountIn, balanceIn, balanceOut, amountNetPulled);

        assertEq(outBalanceIn, balanceIn, "balanceIn must not be touched");
        assertEq(outBalanceOut, balanceOut, "balanceOut must not be touched");
        assertEq(outAmountOut, 0, "amountOut must not be written by a fee on amountIn");
        assertEq(outAmountNetPulled, amountNetPulled, "amountNetPulled belongs to the aqua variants only");
    }

    /// @notice `_feeAmountOut` exact-out restores the taker's `amountOut` exactly.
    ///
    /// @dev The instruction grosses `amountOut` up before the tail runs and assigns the saved
    ///      value back afterwards (`FeeExperimental.sol:141-145`). The restore is what makes
    ///      the exact-out leg honour the taker's request, and it is the one line whose removal
    ///      would silently deliver the grossed-up amount. Quantified over the whole domain of
    ///      the amount for which the gross-up does not overflow.
    function test_feeOut_exactOut_restoresTheTakerAmount(uint32 feeBps, uint128 amountOut) public {
        vm.assume(feeBps < BPS);

        (uint256 fee, uint256 finalAmountOut) = harness.feeAmountOutExactOut(feeBps, amountOut);

        assertEq(finalAmountOut, amountOut, "the taker's requested output must be restored exactly");

        uint256 d = BPS - feeBps;
        uint256 n = uint256(amountOut) * feeBps;
        assertLe(fee * d, n, "the gross-up fee must not round up");
        assertLt(n - fee * d, d, "nor fall a wei short of the floor");
    }

    // =======================================================================
    // 12. The harness trust boundary
    // =======================================================================

    /// @notice Pre-seeding the register the tail program would have written agrees, output for
    ///         output, with running a real dispatcher over a real one-opcode program.
    ///
    /// @dev **This is the property that licenses every pre-seeded entrypoint in `FeeHarness`.**
    ///      `HARNESS-FIDELITY.md` asks that any gap between the harness and the deployed code
    ///      be closed by a machine-checked differential rather than by a comparison a human
    ///      did once, and this is that differential for the one shortcut this harness takes.
    ///
    ///      The two sides differ in exactly the way the shortcut does:
    ///
    ///        * `feeAmountInExactOut` enters with `amountIn` already set to the value the tail
    ///          would produce, `amountOut == 0`, and an empty tail;
    ///        * `feeAmountInExactOutStubbed` enters in the true production shape —
    ///          `amountIn == 0` and `amountOut` the taker's non-zero request — and a real
    ///          dispatcher writes `amountIn` during `runLoop`.
    ///
    ///      Note the two sides take *different branches of the ordering guard*: the pre-seeded
    ///      side passes it on `amountOut == 0` and the stubbed side on `amountIn == 0`. That
    ///      the outputs still agree is precisely what the shortcut claims, so this is not a
    ///      restatement of it.
    function test_diff_exactOut_stubbedMatchesPreseeded(
        uint32 feeBps,
        uint128 swapAmountIn,
        uint128 takerAmountOut
    ) public {
        vm.assume(feeBps < BPS);
        vm.assume(takerAmountOut != 0);

        (uint256 preFee, uint256 preFinal) = harness.feeAmountInExactOut(feeBps, swapAmountIn);
        (uint256 stubFee, uint256 stubFinal) =
            harness.feeAmountInExactOutStubbed(feeBps, swapAmountIn, takerAmountOut, STUB_PROGRAM);

        assertEq(stubFee, preFee, "the fee must not depend on how amountIn got there");
        assertEq(stubFinal, preFinal, "nor must the resulting amountIn");
    }

    // =======================================================================
    // 13. The dynamic-provider tier
    // =======================================================================
    //
    // `_dynamicProtocolFeeAmountInXD` makes a `staticcall` to a maker-named address and
    // validates what comes back. Symbolic execution through a call to an *unconstrained*
    // address is expensive — the callee's code is symbolic, so every branch of every possible
    // implementation is live. The properties below therefore do one of two things, and each
    // says which:
    //
    //   * the zero-provider property needs no call at all — it proves the guard at
    //     `Fee.sol:147` short-circuits the whole instruction;
    //   * the validation properties MOCK the provider with a concrete contract deployed in
    //     `setUp`, so the callee's bytecode is known and only the post-call validation is
    //     symbolic. What is proven is therefore the validation logic, conditional on a provider
    //     that returns a well-formed 64-byte payload. Providers that return short data, revert,
    //     or consume unbounded gas are NOT covered here; `Fee.sol:158`'s
    //     `success && result.length == 64` is the code that would handle them and it is not
    //     exercised by these properties.

    /// @notice A zero fee provider makes the whole instruction a no-op.
    /// @dev `Fee.sol:147` guards the call, and `Fee.sol:163` guards everything after it on
    ///      `feeBps != 0`, which is still zero. So no call is made, no fee is charged, and
    ///      `amountIn` is untouched. Full `uint256` width — no product is formed on this path.
    ///      Worth pinning because the same zero address is what a maker gets from an
    ///      uninitialised argument slot, and "silently free" is a much better failure than
    ///      "silently arbitrary".
    function test_dynamic_zeroProviderIsANoOp(uint256 amountIn) public {
        uint256 finalAmountIn = harness.dynamicProtocolFeeExactInStatic(bytes20(address(0)), amountIn);

        assertEq(finalAmountIn, amountIn, "a zero provider must leave amountIn untouched");
    }

    /// @notice A provider returning `feeBps > BPS` is rejected with `Fee.FeeBpsOutOfRange`.
    /// @dev `Fee.sol:160`. This is the one place in the contract where that error is reachable,
    ///      and the contrast with the program-carried path is the finding recorded on
    ///      `test_feeIn_bpsAboveMaximumPanicsRatherThanNamingTheError`: an *external* fee is
    ///      range-checked and reported by name; a *maker-signed* fee is neither.
    ///      The provider is a concrete mock, so only the validation is symbolic.
    function test_dynamic_providerBpsAboveMaximumIsRejected(uint32 feeBps, uint128 amountIn) public {
        vm.assume(feeBps > BPS);
        provider.set(feeBps, address(0xBEEF));

        vm.expectRevert(abi.encodeWithSelector(Fee.FeeBpsOutOfRange.selector, uint256(feeBps)));
        harness.dynamicProtocolFeeExactInStatic(bytes20(address(provider)), amountIn);
    }

    /// @notice A provider returning a non-zero fee to the zero address is rejected.
    /// @dev `Fee.sol:164`. Without it the fee would be transferred to `address(0)` and burned.
    ///      Note the ordering: the recipient check is inside `if (feeBps != 0)`, so a provider
    ///      that returns `(0, address(0))` is accepted — that case is the no-op and is correct.
    function test_dynamic_zeroRecipientIsRejectedWhenFeeIsNonZero(uint32 feeBps, uint128 amountIn) public {
        vm.assume(feeBps != 0);
        vm.assume(feeBps <= BPS);
        provider.set(feeBps, address(0));

        vm.expectRevert(Fee.FeeDynamicProtocolInvalidRecipient.selector);
        harness.dynamicProtocolFeeExactInStatic(bytes20(address(provider)), amountIn);
    }
}
