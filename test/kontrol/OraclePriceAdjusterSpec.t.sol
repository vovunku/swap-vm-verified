// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test, stdError } from "forge-std/Test.sol";

import { SwapRegisters } from "../../src/libs/VM.sol";
import { OraclePriceAdjuster } from "../../src/instructions/OraclePriceAdjuster.sol";
import { OraclePriceAdjusterHarness, MockPriceOracle } from "./harnesses/OraclePriceAdjusterHarness.sol";

/// @notice Kontrol specification for the OraclePriceAdjuster instruction.
///
/// @dev Reference semantics, derived from `src/instructions/OraclePriceAdjuster.sol:82-139`.
///
///      Args are a 31-byte packed record (`:23-48`):
///
///        maxPriceDecay (uint64) | maxStaleness (uint16) | oracleDecimals (uint8) | oracleAddress (address)
///
///      **The instruction's own argument docstring at `:78-81` lists these in the opposite
///      order**, and `:22` describes `oracleAddress` as "stored in the lower bits" when the
///      packed encoding puts it in the trailing 20 bytes. `parse` (`:44-47`) is
///      authoritative and is what this spec follows.
///
///      Write `D = maxPriceDecay`, `S = maxStaleness`, `n = oracleDecimals`, `a = answer`,
///      `t = updatedAt`, and `WAD = 1e18`. Then:
///
///        require(amountIn > 0 && amountOut > 0)                              (:83)
///        (, a, , t, ) = IPriceOracle(oracleAddress).latestRoundData()        (:96)
///        require(S == 0 || block.timestamp <= t + S)                         (:100)
///        if (n == 0) n = oracle.decimals()                                   (:103-105)
///        P = toUint256(a) * 10**(18-n)   if n < 18                           (:110)
///          = toUint256(a) / 10**(n-18)   if n > 18                           (:112)
///          = toUint256(a)                if n == 18
///        C = (amountOut * WAD) / amountIn                        // floor    (:117)
///
///        if (P > C):                                                         (:120)
///          exactIn:   R = (P * WAD) / C                          // floor    (:126)
///                     amountOut' = amountOut * min(R, 2*WAD - D) / WAD       (:128-129)
///          exactOut:  R = (C * WAD) / P                          // floor    (:133)
///                     amountIn'  = ceil(amountIn * max(R, D) / WAD)          (:134-135)
///        else: no register changes at all
///
///      ## The claim under test
///
///      The contract docstring at `:57` states that the instruction "ensures the adjustment
///      is always favorable for the taker". That is the property this spec is built around,
///      stated in both directions, and it is **false** — see
///      `test_unguarded_*` below and the two refutations recorded in `BUGS.md`.
///
///      `:29` does `require(maxPriceDecay < 1e18)` — but only in `build`, an off-chain
///      helper. `BUGS.md` establishes for `DutchAuction` and `BaseFeeAdjuster` that **no
///      `build` is a guard**: program bytes are maker-assembled and `parse` is the only
///      thing that runs on chain. `parse` (`:38-48`) is four raw byte casts and validates
///      nothing, so `D` spans the full `uint64` range on chain. This spec therefore builds
///      its arguments with `abi.encodePacked` rather than through
///      `OraclePriceAdjusterArgsBuilder.build`, because `build` cannot express the values
///      that are reachable — which is itself the finding.
///
///      ## DOMAIN NOTES — read these as part of every theorem below
///
///      **`oracleDecimals` is fixed to a concrete value in every property.** `10**(18-n)`
///      and `10**(n-18)` are exponentiations with a *runtime* exponent; symbolic, that is a
///      loop with a symbolic trip count and no proof terminates. Every property therefore
///      pins `n`, and the properties that are about the scaling pin it at the value being
///      probed. `REF_DECIMALS = 18` is used elsewhere because at 18 both branches at `:109`
///      and `:111` are skipped and no exponentiation is emitted at all. The unrestricted
///      form is marked `@custom:kontrol-status OPEN` where it exists.
///
///      **The oracle is a concrete mock.** See `OraclePriceAdjusterHarness.sol` — it is a
///      declared trust boundary. `answer`, `updatedAt` and `decimals()` stay symbolic; the
///      callee's *behaviour* (returns, returns five words, does not reenter) is assumed.
///
///      **`maxStaleness` is 0 in every property that is not about staleness**, which
///      short-circuits `:100` at the first disjunct and removes `block.timestamp` and
///      `updatedAt` from the path condition. That this is even possible is itself pinned,
///      in `test_zeroMaxStaleness_disablesTheCheckEntirely`.
///
///      These run as ordinary fuzz tests under `forge test` and as proofs under
///      `kontrol prove`. Under Kontrol every `vm.assume` becomes a path constraint rather
///      than a sample filter, so the assumptions define exactly the domain over which each
///      property is proven — read them as part of the specification.
contract OraclePriceAdjusterSpec is Test {
    OraclePriceAdjusterHarness internal harness;
    MockPriceOracle internal oracle;

    uint256 internal constant WAD = 1e18;

    /// @dev 18 decimals makes the scaling at `:109-113` the identity, so no runtime
    ///      exponentiation is emitted. Chainlink feeds are typically 8, which is covered
    ///      separately by the docstring-configuration properties.
    uint8 internal constant REF_DECIMALS = 18;

    /// @dev 0 short-circuits the staleness check at `:100`.
    uint16 internal constant NO_STALENESS = 0;

    /// @dev The reference swap: one token1 in, one token0 out, so `C == WAD` exactly and
    ///      every multiplier below reads directly as a price factor.
    uint256 internal constant REF_AMOUNT = WAD;

    /// @dev An oracle at twice the swap's implied price, so `:120` is taken and both
    ///      `priceRatio` expressions are nameable constants: `R = 2*WAD` on the exact-in
    ///      leg and `R = WAD/2` on the exact-out leg.
    int256 internal constant REF_ANSWER = int256(2 * WAD);

    function setUp() public {
        harness = new OraclePriceAdjusterHarness();
        oracle = new MockPriceOracle();
    }

    /// @dev The on-chain encoding, byte for byte as `parse` reads it back.
    ///
    ///      Deliberately NOT `OraclePriceAdjusterArgsBuilder.build`: that helper carries a
    ///      `require(maxPriceDecay < 1e18)` at `:29` which would make the entire
    ///      out-of-range region — where the bugs are — inexpressible. `build` never runs on
    ///      chain, so a spec that went through it would be proving things about a domain
    ///      strictly smaller than the reachable one.
    function _args(uint64 maxPriceDecay, uint16 maxStaleness, uint8 oracleDecimals)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodePacked(maxPriceDecay, maxStaleness, oracleDecimals, address(oracle));
    }

    /// @dev The reference argument record: symbolic decay, everything else pinned.
    function _refArgs(uint64 maxPriceDecay) internal view returns (bytes memory) {
        return _args(maxPriceDecay, NO_STALENESS, REF_DECIMALS);
    }

    function _setOracle(int256 answer, uint256 updatedAt, uint8 decimals_) internal {
        oracle.set(answer, updatedAt, decimals_);
    }

    // -----------------------------------------------------------------------
    // Guards — cheapest properties first, which is also what validates the harness
    // -----------------------------------------------------------------------

    /// @notice A zero input register is rejected in both directions.
    /// @dev Checked at `:83`, before any argument parsing and before the oracle is called,
    ///      so it holds for empty `args` and for an `oracleAddress` with no code.
    function test_revertsWhenAmountInIsZero(uint256 amountOut) public {
        vm.expectRevert(OraclePriceAdjuster.OraclePriceAdjusterShouldBeAppliedAfterSwap.selector);
        harness.exactIn(0, 0, 0, amountOut, 0, "");

        vm.expectRevert(OraclePriceAdjuster.OraclePriceAdjusterShouldBeAppliedAfterSwap.selector);
        harness.exactOut(0, 0, 0, amountOut, 0, "");
    }

    /// @notice A zero output register is rejected in both directions.
    /// @dev The guard is `amountIn > 0 && amountOut > 0` regardless of `isExactIn`, so an
    ///      exact-out quote whose output leg is set but whose input leg is not is rejected
    ///      just the same. This is the ordering constraint the instruction's name refers to.
    function test_revertsWhenAmountOutIsZero(uint256 amountIn) public {
        vm.assume(amountIn > 0);

        vm.expectRevert(OraclePriceAdjuster.OraclePriceAdjusterShouldBeAppliedAfterSwap.selector);
        harness.exactIn(0, 0, amountIn, 0, 0, "");

        vm.expectRevert(OraclePriceAdjuster.OraclePriceAdjusterShouldBeAppliedAfterSwap.selector);
        harness.exactOut(0, 0, amountIn, 0, 0, "");
    }

    // -----------------------------------------------------------------------
    // PROPERTY 1 — the docstring's own claim, stated two-sided
    //
    // `:57`: "Ensures the adjustment is always favorable for the taker."
    //
    // Stated as a pair, in each direction, so that neither half can be satisfied by a
    // degenerate implementation:
    //
    //   * the FAVOURABILITY half says the taker is never worse off than the swap
    //     instruction left them. On its own, the identity function satisfies it.
    //   * the EXACTNESS half pins the adjustment to the value the source computes, which
    //     the identity function does not satisfy.
    //
    // Both halves are stated over `D` at its true on-chain width (`uint64`).
    // -----------------------------------------------------------------------

    /// @notice THE CLAIM, exact-out direction: the adjustment never raises what the taker
    ///         pays.
    /// @dev Expected to be REFUTED. `:134` clamps with `Math.max(priceRatio, maxPriceDecay)`
    ///      and `:135` multiplies by the result, so above one wad the "floor" is a
    ///      multiplier and the discount the instruction exists to grant becomes a surcharge.
    ///      Restricting `D <= 2*WAD` is not needed here — the exact-out leg has no mirror
    ///      subtraction — so this quantifies over the whole encodable range.
    /// @custom:kontrol-status NOT-CLOSED. Stalled at 148 nodes with one pending leaf (node
    ///      161) across two runs totalling ~55 min, with and without
    ///      `--fallback-on Aborted`. The blocking term, dumped from `kcfg/nodes/161.json`,
    ///      is `chop(WAD * xorSelect(D)) - 1) / WAD` — OZ's `Math.ceilDiv` compiled as
    ///      `(a - 1) / b + 1`, so `a - 1` is `chop(a + maxUInt256)`, over a product whose
    ///      multiplicand is itself an XOR-select on `maxPriceDecay`. This is the same shape
    ///      `kontrol.toml` quarantines in `[prove.xycswap-open]` — a symbolic division of a
    ///      symbolic product under `chop`. The **exact-in** twin of this claim
    ///      (`test_claim_exactIn_neverDecreasesTheTakersPayout`) uses a plain `/ WAD` rather
    ///      than `ceilDiv` and DID refute, in 3m16s, so the finding itself is machine-checked
    ///      in one direction; this direction rests on the executed witnesses in
    ///      `repro/OraclePriceAdjusterRepro.t.sol`.
    function test_claim_exactOut_neverIncreasesTheTakersCost(uint64 maxPriceDecay) public {
        _setOracle(REF_ANSWER, 0, REF_DECIMALS);

        SwapRegisters memory r =
            harness.exactOut(0, 0, REF_AMOUNT, REF_AMOUNT, 0, _refArgs(maxPriceDecay));

        assertLe(r.amountIn, REF_AMOUNT, "the adjustment must never raise what the taker pays");
    }

    /// @notice THE CLAIM, exact-in direction: the adjustment never lowers what the taker
    ///         receives.
    /// @dev Expected to be REFUTED. `:127` computes `maxIncrease = 2e18 - D` and `:128`
    ///      caps with it; for `WAD < D <= 2*WAD` that cap is strictly *below* one wad, so
    ///      `:129` scales `amountOut` **down**. `D > 2*WAD` is excluded here only because it
    ///      reverts rather than mis-computing, which is a different defect with a different
    ///      criticality — it is pinned separately in
    ///      `test_unguarded_exactIn_revertsWhenDecayCapExceedsTwoWad`.
    function test_claim_exactIn_neverDecreasesTheTakersPayout(uint64 maxPriceDecay) public {
        vm.assume(maxPriceDecay <= 2 * WAD);
        _setOracle(REF_ANSWER, 0, REF_DECIMALS);

        SwapRegisters memory r =
            harness.exactIn(0, 0, REF_AMOUNT, REF_AMOUNT, 0, _refArgs(maxPriceDecay));

        assertGe(r.amountOut, REF_AMOUNT, "the adjustment must never lower what the taker receives");
    }

    /// @notice The exactness half, exact-in: within the range `build` permits, the result is
    ///         exactly `min(R, 2*WAD - D)` applied to `amountOut`, and it strictly improves.
    /// @dev This is what stops the favourability half above from being satisfiable by the
    ///      identity. With `C == WAD` and `P == 2*WAD` the uncapped ratio is `R == 2*WAD`,
    ///      so for every `D < WAD` the cap `2*WAD - D` binds and the answer is that cap.
    /// @custom:kontrol-status FAILED-ON-PROVER-INCOMPLETENESS, not on the code — do not read
    ///      this as a refutation. Kontrol reports node 225 asserting
    ///      `0 xorInt (2e18 - D) != (2e18 - D)`, with path condition
    ///      `chop(0 xorInt (2e18 - D) + D - 2e18) =/= 0`. Both reduce to the identity
    ///      `0 xorInt X == X`, so the goal is unreachable and the report is a missing
    ///      simplification. Three independent confirmations: the identity itself; the
    ///      `Model` block names `maxPriceDecay = 0`, at which the constraint is false, so
    ///      the model does not satisfy its own path condition; and the property passes
    ///      256/256 as a fuzz test. The `0 xorInt` arises because solc compiles `Math.min`
    ///      branchlessly as an XOR-select. **A lemma `rule 0 xorInt X => X [simplification]`
    ///      is what closes this**, and it transfers to every instruction using
    ///      `Math.min`/`Math.max` — i.e. most of the adjusters. `BUGS.md` records the
    ///      converse trap for `PeggedSwap`: a failing proof is not evidence against a
    ///      property until you have read why it failed.
    function test_exactIn_exactArithmeticInTheRangeBuildPermits(uint64 maxPriceDecay) public {
        vm.assume(maxPriceDecay < WAD); // exactly what `build` requires at `:29`
        _setOracle(REF_ANSWER, 0, REF_DECIMALS);

        uint256 cap = 2 * WAD - maxPriceDecay; // in (WAD, 2*WAD]
        SwapRegisters memory r =
            harness.exactIn(0, 0, REF_AMOUNT, REF_AMOUNT, 0, _refArgs(maxPriceDecay));

        assertEq(r.amountOut, cap, "exact-in applies the mirrored cap");
        assertGt(r.amountOut, REF_AMOUNT, "and it is a strict improvement, so the claim is not vacuous");
    }

    /// @notice The exactness half, exact-out: within the range `build` permits, the result is
    ///         exactly `ceil(amountIn * max(R, D) / WAD)`, and it strictly improves.
    /// @dev `R == WAD/2` here, so the floor `D` binds for `D > WAD/2` and the ratio binds
    ///      below it. Both sides of the `max` are exercised by the same statement.
    ///      Expected to PASS.
    function test_exactOut_exactArithmeticInTheRangeBuildPermits(uint64 maxPriceDecay) public {
        vm.assume(maxPriceDecay < WAD);
        _setOracle(REF_ANSWER, 0, REF_DECIMALS);

        uint256 ratio = WAD / 2; // (C * WAD) / P with C == WAD, P == 2*WAD
        uint256 adjustment = ratio > maxPriceDecay ? ratio : maxPriceDecay;

        SwapRegisters memory r =
            harness.exactOut(0, 0, REF_AMOUNT, REF_AMOUNT, 0, _refArgs(maxPriceDecay));

        assertEq(r.amountIn, adjustment, "exact-out applies max(ratio, floor)");
        assertLt(r.amountIn, REF_AMOUNT, "and it is a strict discount, so the claim is not vacuous");
    }

    // -----------------------------------------------------------------------
    // PROPERTY 2 — the mirror subtraction at `:127`
    // -----------------------------------------------------------------------

    /// @notice UNGUARDED PATH. `D > 2*WAD` makes the exact-in leg revert with a bare
    ///         `Panic(0x11)` on `2e18 - maxPriceDecay`.
    /// @dev `D` is a `uint64`, so values up to `~1.8e19` are encodable while the mirror
    ///      expression underflows above `2e18`. Nothing validates the field at parse time
    ///      and the failure carries no name: such an order is simply unexecutable in the
    ///      exact-in direction and says nothing about why. Direct mirror of the CONFIRMED
    ///      `BaseFeeAdjuster.sol:93` entry in `BUGS.md`. Expected to PASS.
    function test_unguarded_exactIn_revertsWhenDecayCapExceedsTwoWad(uint64 maxPriceDecay) public {
        vm.assume(maxPriceDecay > 2 * WAD);
        _setOracle(REF_ANSWER, 0, REF_DECIMALS);

        vm.expectRevert(stdError.arithmeticError);
        harness.exactIn(0, 0, REF_AMOUNT, REF_AMOUNT, 0, _refArgs(maxPriceDecay));
    }

    // -----------------------------------------------------------------------
    // PROPERTY 3 — what the out-of-range region actually does
    //
    // The two properties above say the claim is false. These say what is true instead,
    // which is what makes the finding reportable rather than merely alarming.
    // -----------------------------------------------------------------------

    /// @notice UNGUARDED PATH. With `D > WAD` the exact-out floor sits above one wad and the
    ///         taker is charged `D / WAD` times what the swap quoted.
    /// @dev A smooth dial, not a knife edge: at `D = 1.5e18` the taker pays 1.5x and at
    ///      `2e18` exactly double. `R == WAD/2 < D` throughout, so the `max` always selects
    ///      the maker's floor and the result is `D` itself.
    function test_unguarded_exactOut_floorAboveOneWadIsASurcharge(uint64 maxPriceDecay) public {
        vm.assume(maxPriceDecay > WAD);
        _setOracle(REF_ANSWER, 0, REF_DECIMALS);

        SwapRegisters memory r =
            harness.exactOut(0, 0, REF_AMOUNT, REF_AMOUNT, 0, _refArgs(maxPriceDecay));

        assertEq(r.amountIn, uint256(maxPriceDecay), "the floor is applied even when it is a surcharge");
        assertGt(r.amountIn, REF_AMOUNT, "an above-wad floor makes the taker pay more, not less");
    }

    /// @notice UNGUARDED PATH. With `WAD < D <= 2*WAD` the exact-in cap falls below one wad,
    ///         so the "improvement" is a haircut, reaching a **total** loss at `D == 2*WAD`.
    /// @dev At `D = 2e18` the cap is exactly zero and `amountOut` is set to zero while
    ///      `amountIn` is left standing — the taker pays in full and receives nothing. This
    ///      is strictly worse than the corresponding `BaseFeeAdjuster` case, because there
    ///      the branch needs `block.basefee > baseGasPrice` whereas here it needs only
    ///      `oraclePrice > currentPrice`, which is near-permanently true (see
    ///      `test_finding_theAdjustmentIgnoresTheOraclePrice`).
    function test_unguarded_exactIn_capBelowOneWadIsAHaircut(uint64 maxPriceDecay) public {
        vm.assume(maxPriceDecay > WAD && maxPriceDecay <= 2 * WAD);
        _setOracle(REF_ANSWER, 0, REF_DECIMALS);

        uint256 cap = 2 * WAD - maxPriceDecay; // strictly below WAD
        SwapRegisters memory r =
            harness.exactIn(0, 0, REF_AMOUNT, REF_AMOUNT, 0, _refArgs(maxPriceDecay));

        assertEq(r.amountOut, cap, "the cap is applied even when it is a haircut");
        assertLe(r.amountOut, REF_AMOUNT, "an above-wad decay cap turns the uplift into a haircut");
        assertEq(r.amountIn, REF_AMOUNT, "and the taker's payment is left untouched");
    }

    // -----------------------------------------------------------------------
    // PROPERTY 4 — the adjustment does not depend on the oracle price
    //
    // `:117` computes `C = amountOut * WAD / amountIn`, a ratio of raw token units, and
    // `:120` compares it against `P`, the oracle answer rescaled to 18 decimals. Those two
    // are commensurable only if the feed quotes token0-per-token1 *in raw units* — i.e.
    // already corrected for the two tokens' decimals. The instruction has no parameter for
    // token decimals, only for the oracle's, so it cannot perform that correction.
    //
    // The docstring's own example (`:63-67`) is a Chainlink ETH/USD feed, which does not
    // satisfy it. What happens instead is that `R` overshoots the cap by twenty-odd orders
    // of magnitude, so the clamp always binds and the answer stops depending on the oracle
    // at all.
    // -----------------------------------------------------------------------

    /// @notice The docstring's configuration, with a symbolic oracle answer: over four
    ///         orders of magnitude of price, the result is the same constant.
    /// @dev Configuration is `:63-67` verbatim — Chainlink ETH/USD at 8 decimals,
    ///      `D = 0.95e18`, base price 1 ETH for 3000 USDC, exact-in. `C = 3.33e14` in wad
    ///      terms while `P` is around `3.1e21`, so `R ~= 9e24` against a cap of `1.05e18`.
    ///      The bound `answer >= 1e12` is `$10000` at 8 decimals, `answer <= type(uint64).max`
    ///      is about `$1.8e11`; the whole of that range collapses to the cap. The
    ///      instruction is documented to "adjust the swap price towards the oracle price"
    ///      (`:56`) and does not.
    /// @custom:kontrol-status narrowed — `oracleDecimals` is pinned at 8 because the
    ///      scaling is a runtime exponentiation; see the domain note.
    function test_finding_theAdjustmentIgnoresTheOraclePrice(uint64 answer) public {
        vm.assume(answer >= 1e12); // >= $10000.00000000 at 8 decimals

        _setOracle(int256(uint256(answer)), 0, 8);

        SwapRegisters memory r = harness.exactIn(
            0, 0, 3000e18, 1e18, 0, _args(uint64(0.95e18), NO_STALENESS, 8)
        );

        assertEq(r.amountOut, 1.05e18, "the taker receives the full capped uplift whatever the oracle says");
    }

    // -----------------------------------------------------------------------
    // PROPERTY 5 — decimal scaling
    // -----------------------------------------------------------------------

    /// @notice UNGUARDED PATH. `oracleDecimals >= 96` makes `10**(n-18)` overflow, so the
    ///         instruction reverts with a bare `Panic(0x11)` for every oracle answer.
    /// @dev `n` is an unvalidated `uint8` out of maker-signed bytes, so `0..255` is
    ///      encodable. `10**77` is the largest power of ten a `uint256` holds
    ///      (`~1.16e77`), so the divisor at `:112` overflows from `n - 18 = 78` upward:
    ///      **the whole top 62.5% of the field's range is a brick**. The divisor is
    ///      independent of the answer, so nothing about the price can avoid it.
    ///      `n` is concrete at 96 here because the exponent is a runtime loop; the
    ///      unrestricted statement over `n >= 96` is
    ///      `@custom:kontrol-status OPEN` and is witnessed by execution in the reproducer.
    function test_unguarded_oracleDecimals96Bricks(uint64 answer, uint64 maxPriceDecay) public {
        _setOracle(int256(uint256(answer)), 0, 96);

        vm.expectRevert(stdError.arithmeticError);
        harness.exactIn(0, 0, REF_AMOUNT, REF_AMOUNT, 0, _args(maxPriceDecay, NO_STALENESS, 96));
    }

    /// @notice `oracleDecimals = 77` truncates the answer to zero, which silently disables
    ///         the adjustment rather than reverting.
    /// @dev The largest non-reverting value of `n`. `10**59` divides any `uint64` answer to
    ///      zero, so `P == 0`, `:120` is false and the instruction is the identity. A
    ///      mis-encoded decimals byte therefore has two distinct failure modes on either
    ///      side of 96 — silent no-op below, unattributable panic above — and neither is
    ///      reported.
    function test_unguarded_oracleDecimals77SilentlyDisablesTheAdjustment(uint64 answer, uint64 maxPriceDecay)
        public
    {
        _setOracle(int256(uint256(answer)), 0, 77);

        SwapRegisters memory r =
            harness.exactIn(0, 0, REF_AMOUNT, REF_AMOUNT, 0, _args(maxPriceDecay, NO_STALENESS, 77));

        assertEq(r.amountOut, REF_AMOUNT, "a truncated-to-zero oracle price is a silent no-op");
        assertEq(r.amountIn, REF_AMOUNT, "and nothing else moves either");
    }

    /// @notice A negative oracle answer is rejected by SafeCast, with a named error.
    /// @dev `:108` is `answer.toUint256()`. Chainlink feeds are `int256` precisely because
    ///      some of them can go negative, so this is a reachable denial of service — but it
    ///      is the one arithmetic failure in this instruction that is *attributable*, which
    ///      is worth pinning as the contrast to the two bare panics above.
    function test_negativeOracleAnswerIsRejectedWithANamedError(uint64 magnitude, uint64 maxPriceDecay) public {
        vm.assume(magnitude > 0);
        _setOracle(-int256(uint256(magnitude)), 0, REF_DECIMALS);

        vm.expectRevert(
            abi.encodeWithSignature("SafeCastOverflowedIntToUint(int256)", -int256(uint256(magnitude)))
        );
        harness.exactIn(0, 0, REF_AMOUNT, REF_AMOUNT, 0, _refArgs(maxPriceDecay));
    }

    // -----------------------------------------------------------------------
    // PROPERTY 6 — staleness
    // -----------------------------------------------------------------------

    /// @notice `maxStaleness == 0` disables the freshness check for every `updatedAt` and
    ///         every `block.timestamp`, including an oracle that has never updated.
    /// @dev Documented at `:20` ("0 = no staleness check") and at `:99`, so this is
    ///      intended behaviour and the property is a pin rather than a finding. It is worth
    ///      pinning anyway because zero is what a maker gets by leaving the field out: the
    ///      encoding has no way to distinguish "no staleness bound wanted" from "these two
    ///      bytes were never written". Expected to PASS.
    function test_zeroMaxStaleness_disablesTheCheckEntirely(uint256 updatedAt, uint64 timestamp) public {
        vm.warp(timestamp);
        _setOracle(REF_ANSWER, updatedAt, REF_DECIMALS);

        SwapRegisters memory r =
            harness.exactOut(0, 0, REF_AMOUNT, REF_AMOUNT, 0, _args(uint64(0.95e18), 0, REF_DECIMALS));

        assertEq(r.amountIn, 0.95e18, "a zero staleness bound admits any oracle timestamp at all");
    }

    /// @notice With a non-zero bound, an answer older than it is rejected with a named error.
    /// @dev The named-error half of the staleness pair, so the property is two-sided:
    ///      `S == 0` admits everything, `S > 0` rejects what it should. `updatedAt` is
    ///      bounded to `uint64` so that `updatedAt + S` cannot itself overflow — the
    ///      unrestricted statement is `@custom:kontrol-status OPEN`, and above
    ///      `type(uint256).max - S` the check panics rather than reverting with the
    ///      instruction's own error.
    function test_staleOracleIsRejectedWithANamedError(uint64 updatedAt, uint16 maxStaleness) public {
        vm.assume(maxStaleness > 0);
        vm.assume(uint256(updatedAt) + maxStaleness < type(uint64).max);

        uint256 nowTs = uint256(updatedAt) + maxStaleness + 1;
        vm.warp(nowTs);
        _setOracle(REF_ANSWER, updatedAt, REF_DECIMALS);

        vm.expectRevert(
            abi.encodeWithSelector(
                OraclePriceAdjuster.OraclePriceAdjusterOraclePriceStale.selector,
                nowTs,
                uint256(updatedAt),
                maxStaleness
            )
        );
        harness.exactOut(0, 0, REF_AMOUNT, REF_AMOUNT, 0, _args(uint64(0.95e18), maxStaleness, REF_DECIMALS));
    }

    // -----------------------------------------------------------------------
    // PROPERTY 7 — frame conditions
    //
    // Which registers the instruction is entitled to touch. `OraclePriceAdjuster` is a
    // post-swap adjuster composed after a curve, so writing a balance register would
    // silently invalidate whatever a later instruction reads out of it.
    // -----------------------------------------------------------------------

    /// @notice The exact-in leg writes `amountOut` and nothing else.
    /// @dev Balances and `amountNetPulled` are fully symbolic `uint256`s and must come back
    ///      untouched. `D` is bounded below one wad only so that the call does not revert;
    ///      the frame condition itself is direction-independent.
    function test_exactIn_touchesOnlyAmountOut(
        uint64 maxPriceDecay,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountNetPulled
    ) public {
        vm.assume(maxPriceDecay < WAD);
        _setOracle(REF_ANSWER, 0, REF_DECIMALS);

        SwapRegisters memory r = harness.exactIn(
            balanceIn, balanceOut, REF_AMOUNT, REF_AMOUNT, amountNetPulled, _refArgs(maxPriceDecay)
        );

        assertEq(r.balanceIn, balanceIn, "balanceIn must be untouched");
        assertEq(r.balanceOut, balanceOut, "balanceOut must be untouched");
        assertEq(r.amountIn, REF_AMOUNT, "exact-in must not write amountIn");
        assertEq(r.amountNetPulled, amountNetPulled, "amountNetPulled must be untouched");
    }

    /// @notice The exact-out leg writes `amountIn` and nothing else.
    function test_exactOut_touchesOnlyAmountIn(
        uint64 maxPriceDecay,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountNetPulled
    ) public {
        vm.assume(maxPriceDecay < WAD);
        _setOracle(REF_ANSWER, 0, REF_DECIMALS);

        SwapRegisters memory r = harness.exactOut(
            balanceIn, balanceOut, REF_AMOUNT, REF_AMOUNT, amountNetPulled, _refArgs(maxPriceDecay)
        );

        assertEq(r.balanceIn, balanceIn, "balanceIn must be untouched");
        assertEq(r.balanceOut, balanceOut, "balanceOut must be untouched");
        assertEq(r.amountOut, REF_AMOUNT, "exact-out must not write amountOut");
        assertEq(r.amountNetPulled, amountNetPulled, "amountNetPulled must be untouched");
    }

    // -----------------------------------------------------------------------
    // PROPERTY 8 — the no-adjustment branch
    // -----------------------------------------------------------------------

    /// @notice When the oracle price does not exceed the swap's implied price, the
    ///         instruction is the identity on every register.
    /// @dev The `else` at `:138`, and the only branch on which the docstring's claim is
    ///      trivially true. `P == C` is included, so the strictness of `>` at `:120` is part
    ///      of the specification rather than an accident. Expected to PASS.
    function test_oraclePriceNotBetter_isIdentity(
        uint64 answer,
        uint64 maxPriceDecay,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountNetPulled
    ) public {
        vm.assume(answer <= REF_AMOUNT); // P <= C, with C == WAD
        _setOracle(int256(uint256(answer)), 0, REF_DECIMALS);

        bytes memory args = _refArgs(maxPriceDecay);

        SwapRegisters memory r =
            harness.exactIn(balanceIn, balanceOut, REF_AMOUNT, REF_AMOUNT, amountNetPulled, args);
        assertEq(r.amountIn, REF_AMOUNT, "exact-in: no register moves");
        assertEq(r.amountOut, REF_AMOUNT, "exact-in: no register moves");

        r = harness.exactOut(balanceIn, balanceOut, REF_AMOUNT, REF_AMOUNT, amountNetPulled, args);
        assertEq(r.amountIn, REF_AMOUNT, "exact-out: no register moves");
        assertEq(r.amountOut, REF_AMOUNT, "exact-out: no register moves");
    }

    // -----------------------------------------------------------------------
    // PROPERTY 9 — totality of `:117`
    // -----------------------------------------------------------------------

    /// @notice UNGUARDED PATH. `amountOut * 1e18` at `:117` overflows for a large output
    ///         register, with a bare `Panic(0x11)`.
    /// @dev `:83` requires only that both amount registers are non-zero; nothing bounds
    ///      them. The frontier is `amountOut > (2**256 - 1) / 1e18 ~= 1.16e59`, which no
    ///      real token supply reaches, so this is a quoting-robustness defect rather than a
    ///      risk — recorded so the enumeration of revert causes is complete. `SwapVM` does
    ///      not check the taker's `amount` against their balance before `runLoop`, so a
    ///      `quote()` probe reaches it.
    function test_unguarded_currentPriceOverflowsOnHugeAmountOut(uint256 amountOut, uint64 maxPriceDecay) public {
        vm.assume(amountOut > type(uint256).max / WAD);
        _setOracle(REF_ANSWER, 0, REF_DECIMALS);

        vm.expectRevert(stdError.arithmeticError);
        harness.exactIn(0, 0, REF_AMOUNT, amountOut, 0, _refArgs(maxPriceDecay));
    }
}
