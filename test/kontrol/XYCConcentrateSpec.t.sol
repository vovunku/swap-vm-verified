// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test, stdError } from "forge-std/Test.sol";

import { SwapRegisters } from "../../src/libs/VM.sol";
import { XYCConcentrate, ONE } from "../../src/instructions/XYCConcentrate.sol";
import { XYCConcentrateHarness } from "./harnesses/XYCConcentrateHarness.sol";

/// @notice Kontrol specification for the XYCConcentrate instruction (opcode 0x51).
///
/// @dev Reference semantics, from `src/instructions/XYCConcentrate.sol`.
///
///      The instruction is a constant-product swap over *virtual* reserves. Real balances
///      are shifted by an offset derived from the reconstructed liquidity `L` and the price
///      bounds (`:125-141`), and then the ordinary XYC curve is applied (`:143-159`):
///
///        isTokenInLt := tokenIn < tokenOut
///        (bLt, bGt)  := isTokenInLt ? (balanceIn, balanceOut) : (balanceOut, balanceIn)
///        L           := _computeL(bLt, bGt, sqrtPriceMin, sqrtPriceMax)
///
///        isTokenInLt:  vIn = balanceIn  + ceil (L * ONE / sqrtPriceMax)
///                      vOut = balanceOut + floor(L * sqrtPriceMin / ONE)
///        otherwise:    vIn = balanceIn  + ceil (L * sqrtPriceMin / ONE)
///                      vOut = balanceOut + floor(L * ONE / sqrtPriceMax)
///
///        exactIn:   out = floor(amountIn * vOut / (vIn + amountIn))
///                   if out > balanceOut:                            <-- partial fill
///                       out = balanceOut
///                       amountIn = ceil(out * vIn / (vOut - out))
///                   amountOut = out
///
///        exactOut:  amountOut = min(amountOut, balanceOut)           <-- partial fill
///                   amountIn  = ceil(amountOut * vIn / (vOut - amountOut))
///
///      Two things follow that do **not** hold for `XYCSwap`, and both are load-bearing for
///      this file:
///
///      1. **`cannotDrainPool` is `<=`, not `<`.** The partial-fill clamp at `:146-149` and
///         `:153-154` makes `amountOut == balanceOut` reachable — the repo's own tests
///         assert balances hitting exactly zero (`test/XYCConcentrate.t.sol:220`, `:233`).
///         Porting `assertLt` across from `XYCSwapSpec.t.sol:60` would produce a failing
///         proof that looks like a tool problem and is not.
///         `test_exactIn_clampIsReachable_witness` pins a concrete counterexample to the
///         strict form, so the choice is checked rather than merely asserted.
///
///      2. **The clamped exact-in reconstruction *is* the exact-out formula.** Substituting
///         `out = balanceOut` into `:155-158` gives `:148` character for character. That is
///         not a coincidence to be admired, it is a test: a harness that has mistranscribed
///         either leg will fail `test_clampedExactIn_equalsExactOutAtFullBalance`.
///
///      ## What is provable today, and what is not
///
///      `_computeL` (`:97-108`) runs `Math.mulDiv` three times, and the virtual-offset
///      block two more. Every `Math.mulDiv` calls `mulmod` inside `Math.mul512`, and
///      without a lemma collapsing `mul512` when the true product fits in 256 bits, KEVM
///      cannot decide `high == 0` at `Math.sol:209` and forks into a 512-bit path
///      containing a Newton modular inverse. See `analysis/FINDINGS.md`, "XYCConcentrate —
///      blocked on mul512, not on sqrt". The single `Math.sqrt` at `:107` is *not* the
///      blocker, and there are no loops anywhere on the path.
///
///      The file is therefore split in two:
///
///        * **LEG-LEVEL** — properties of the pricing legs alone, stated against
///          `XYCConcentrateHarness.exactInLeg` / `exactOutLeg`, which take the two virtual
///          reserves as scalar parameters. `_computeL` is not on the execution path, and
///          what remains is one `MUL`, one `DIV` and one `Math.ceilDiv` per leg — exactly
///          the `XYCSwap` arithmetic that is already proven. These are expected to prove.
///
///        * **FULL-INSTRUCTION** — guards, orientation and the differential tests that ground LEG-LEVEL
///          against the real instruction. Every one of these routes through `_computeL` and
///          is expected to remain `PENDING` until the `mul512` lemma lands. They are
///          written now so that landing the lemma is a `kontrol prove` away rather than a
///          specification exercise.
///
///      These run as ordinary Foundry fuzz tests under `forge test` and as proofs under
///      `kontrol prove`. Under Kontrol every `vm.assume` becomes a path constraint rather
///      than a sample filter, so the assumptions below define exactly the domain over which
///      each property is proven — read them as part of the specification. Narrow parameter
///      *types* (`uint120`, `uint64`, `uint56`) are used in preference to `vm.assume` bounds
///      wherever a bound is needed: Kontrol constrains an ABI-decoded `uintN` directly, and
///      the fuzzer generates in range instead of rejecting, so the same domain costs
///      neither a rejected-sample budget nor an extra path constraint.
contract XYCConcentrateSpec is Test {
    XYCConcentrateHarness internal harness;

    /// @dev Distinct addresses with a known order, so `tokenIn < tokenOut` is decided
    ///      concretely and the prover does not branch on an address comparison. The guard
    ///      properties below deliberately use *symbolic* addresses instead, since the
    ///      guards must hold in both orientations.
    address internal constant TOKEN_LO = address(uint160(1));
    address internal constant TOKEN_HI = address(uint160(2));

    function setUp() public {
        harness = new XYCConcentrateHarness();
    }

    // =======================================================================
    // LEG-LEVEL — the pricing legs, with virtual reserves as scalars
    //
    // `_computeL` is off the execution path for every test in this section.
    // =======================================================================

    // -----------------------------------------------------------------------
    // Safety: the maker cannot be over-drained
    // -----------------------------------------------------------------------

    /// @notice An exact-in swap never returns more than the maker's output balance.
    ///
    /// @dev `<=`, not `<`. See the note at the top of this file, and
    ///      `test_exactIn_clampIsReachable_witness` immediately below for the concrete
    ///      input that refutes the strict form.
    ///
    ///      Stated over the whole input domain with no assumptions. The natural way to
    ///      reach the non-reverting path is to assume the products do not overflow, but
    ///      that puts a symbolic `DIV` into the path condition, which KEVM must model with
    ///      a divide-by-zero guard and which stalls the proof (see `README.md`, "Avoid
    ///      putting a symbolic division in the path condition"). `try`/`catch` expresses the
    ///      same intent with no division, and quantifies over strictly more inputs: every
    ///      `uint256` quadruple, with reverting inputs satisfying the property vacuously.
    function test_exactIn_cannotDrainPool(
        uint256 balanceOut,
        uint256 amountIn,
        uint256 virtualBalanceIn,
        uint256 virtualBalanceOut
    ) public view {
        try harness.exactInLeg(balanceOut, amountIn, 0, virtualBalanceIn, virtualBalanceOut) returns (
            SwapRegisters memory swap,
            bool
        ) {
            assertLe(swap.amountOut, balanceOut, "exactIn must never return more than the output balance");
        } catch {
            // Reverted: the arithmetic overflowed or a divisor was zero. No quote to bound.
        }
    }

    /// @notice An exact-out swap never returns more than the maker's output balance.
    /// @dev The clamp at `:153-154` is the whole content of this property: a taker asking
    ///      for more than the pool holds is served a partial fill rather than reverting.
    function test_exactOut_cannotDrainPool(
        uint256 balanceOut,
        uint256 amountOut,
        uint256 virtualBalanceIn,
        uint256 virtualBalanceOut
    ) public view {
        try harness.exactOutLeg(balanceOut, 0, amountOut, virtualBalanceIn, virtualBalanceOut) returns (
            SwapRegisters memory swap,
            bool
        ) {
            assertLe(swap.amountOut, balanceOut, "exactOut must never return more than the output balance");
            assertLe(swap.amountOut, amountOut, "the clamp must never increase the requested output");
        } catch {
            // Reverted; no quote to bound.
        }
    }

    /// @notice When the exact-in leg clamps, the output is *exactly* the output balance.
    /// @dev Together with `cannotDrainPool` this says `amountOut <= balanceOut` is tight:
    ///      the bound is attained, not merely respected.
    function test_exactIn_clampedOutputIsExactlyBalanceOut(
        uint256 balanceOut,
        uint256 amountIn,
        uint256 virtualBalanceIn,
        uint256 virtualBalanceOut
    ) public view {
        try harness.exactInLeg(balanceOut, amountIn, 0, virtualBalanceIn, virtualBalanceOut) returns (
            SwapRegisters memory swap,
            bool clamped
        ) {
            if (clamped) {
                assertEq(swap.amountOut, balanceOut, "a partial fill must deliver exactly the output balance");
            }
        } catch {
            // Reverted; nothing to observe.
        }
    }

    /// @notice Concrete witness that the partial-fill branch is reachable and that
    ///         `assertLt(amountOut, balanceOut)` is false for this instruction.
    ///
    /// @dev This is the guard rail on the single most likely mistake when porting
    ///      `XYCSwapSpec` across. It also makes `test_exactIn_clampedOutputIsExactlyBalanceOut`
    ///      and `test_clampedExactIn_equalsExactOutAtFullBalance` non-vacuous: both are
    ///      implications conditioned on `clamped`, and an implication whose hypothesis is
    ///      unreachable proves nothing.
    ///
    ///      Worked by hand:
    ///        unclamped out = floor(10000 * 200 / (1000 + 10000)) = floor(181.8..) = 181
    ///        181 > 100 = balanceOut, so the clamp fires
    ///        out       = 100
    ///        amountIn  = ceil(100 * 1000 / (200 - 100)) = 1000
    function test_exactIn_clampIsReachable_witness() public view {
        (SwapRegisters memory swap, bool clamped) = harness.exactInLeg(100, 10_000, 0, 1000, 200);

        assertTrue(clamped, "the partial-fill branch must be reachable");
        assertEq(swap.amountOut, 100, "output is clamped to the full output balance");
        assertEq(swap.amountIn, 1000, "input is recomputed to the exact-out price of a full fill");
    }

    // -----------------------------------------------------------------------
    // Rounding direction: the maker is never shortchanged
    // -----------------------------------------------------------------------

    /// @notice The quoted output never exceeds the exact (unrounded) curve value.
    ///
    /// @dev `amountOut * (vIn + amountIn) <= amountIn * vOut`, i.e. the multiplicative form
    ///      of `amountOut <= amountIn * vOut / (vIn + amountIn)`, stated without a second
    ///      division.
    ///
    ///      Holds on both branches: unclamped, `amountOut` is the floor of the quotient;
    ///      clamped, it is `balanceOut`, which the branch condition puts strictly *below*
    ///      the quotient. So the clamp only ever moves the result further in the maker's
    ///      favour.
    ///
    ///      No domain narrowing, and none is needed. Both products are safe to form on the
    ///      success path precisely because the instruction already formed them without
    ///      reverting: `amountIn * vOut` is evaluated at `:145`, and the left-hand side is
    ///      bounded above by it.
    function test_exactIn_roundsDownInFavourOfMaker(
        uint256 balanceOut,
        uint256 amountIn,
        uint256 virtualBalanceIn,
        uint256 virtualBalanceOut
    ) public view {
        try harness.exactInLeg(balanceOut, amountIn, 0, virtualBalanceIn, virtualBalanceOut) returns (
            SwapRegisters memory swap,
            bool
        ) {
            assertLe(
                swap.amountOut * (virtualBalanceIn + amountIn),
                amountIn * virtualBalanceOut,
                "flooring must not round the output up"
            );
        } catch {
            // Reverted; no quote to bound.
        }
    }

    /// @notice On the unclamped branch the output is exactly the floor — neither one wei
    ///         high nor one wei low.
    ///
    /// @dev The two-sided companion to `roundsDownInFavourOfMaker`. Pinning both sides
    ///      matters because a spec that only bounds the output from above is satisfied by
    ///      an implementation that always quotes zero.
    ///
    ///      DOMAIN NARROWING: reserves and input are `uint120`. The upper bound
    ///      `amountIn * vOut < (amountOut + 1) * (vIn + amountIn)` is not implied by the
    ///      instruction having succeeded — `(amountOut + 1) * (vIn + amountIn)` is a product
    ///      the instruction never forms and can overflow where the instruction did not.
    ///      `uint120` makes every product fit below `2^241`. The one-sided statement above
    ///      is unnarrowed, so nothing is lost from the safety-relevant direction.
    ///
    ///      `balanceOut` is `type(uint256).max` so the clamp cannot fire: the quotient is at
    ///      most `vOut < 2^120`. The clamped branch is covered by
    ///      `test_clampedExactIn_equalsExactOutAtFullBalance`.
    function test_exactIn_isExactlyTheFloor(uint120 virtualBalanceIn, uint120 virtualBalanceOut, uint120 amountIn)
        public
        view
    {
        vm.assume(uint256(virtualBalanceIn) + uint256(amountIn) > 0);

        (SwapRegisters memory swap, bool clamped) =
            harness.exactInLeg(type(uint256).max, amountIn, 0, virtualBalanceIn, virtualBalanceOut);

        assertFalse(clamped, "an unreachable output balance must not clamp");

        uint256 denominator = uint256(virtualBalanceIn) + uint256(amountIn);
        uint256 numerator = uint256(amountIn) * uint256(virtualBalanceOut);

        assertLe(swap.amountOut * denominator, numerator, "output must not exceed the exact curve value");
        assertLt(numerator, (swap.amountOut + 1) * denominator, "output must not fall a wei short of the floor");
    }

    /// @notice The exact-out leg charges exactly the ceiling of the curve value.
    ///
    /// @dev `amountIn = ceil(out * vIn / (vOut - out))`, stated as the two multiplicative
    ///      bounds that characterise a ceiling:
    ///
    ///        amountIn * d >= N   (never rounds the taker's payment down)
    ///        amountIn * d <  N + d   (and is the least such value, so the maker cannot
    ///                                 overcharge by a whole ulp either)
    ///
    ///      DOMAIN NARROWING, and how it is arranged: `virtualBalanceOut` is *derived* as
    ///      `balanceOut + headroom + 1` rather than taken freely. That makes
    ///      `vOut > balanceOut >= min(amountOut, balanceOut)` true by construction, so the
    ///      divisor is non-zero and the subtraction cannot underflow without a single
    ///      `vm.assume` — the whole quantified domain is reachable. The widths
    ///      (`uint128`/`uint120`) keep `amountIn * d <= N + d - 1 < 2^248 + 2^121` inside a
    ///      `uint256`, which the unbounded form does not guarantee. `amountOut` itself is a
    ///      free `uint256`, so the clamp is fully exercised.
    ///
    ///      Note that `vOut > balanceOut` is not an artificial restriction: in the real
    ///      instruction `vOut = balanceOut + offset` with `offset >= 0`, so the only excluded
    ///      case is `offset == 0`, i.e. a pool with no reconstructed liquidity at all. That
    ///      degenerate case is pinned separately by
    ///      `test_exactOut_panicsOnZeroLiquidityFullFill`.
    function test_exactOut_roundsUpInFavourOfMaker(
        uint128 virtualBalanceIn,
        uint120 balanceOut,
        uint120 headroom,
        uint256 amountOut
    ) public view {
        uint256 virtualBalanceOut = uint256(balanceOut) + uint256(headroom) + 1;

        (SwapRegisters memory swap,) = harness.exactOutLeg(balanceOut, 0, amountOut, virtualBalanceIn, virtualBalanceOut);

        uint256 divisor = virtualBalanceOut - swap.amountOut;
        uint256 numerator = swap.amountOut * uint256(virtualBalanceIn);

        assertGe(swap.amountIn * divisor, numerator, "ceiling must not round the taker's input down");
        assertLt(swap.amountIn * divisor, numerator + divisor, "the charge must be the least sufficient one");
    }

    // -----------------------------------------------------------------------
    // Degenerate inputs
    // -----------------------------------------------------------------------

    /// @notice Zero input yields zero output, and leaves the input register alone.
    /// @dev `virtualBalanceIn > 0` is required and not incidental: with both the reserve and
    ///      the input at zero, `:145` evaluates `0 / 0` and panics.
    function test_exactIn_zeroInputYieldsZeroOutput(
        uint256 balanceOut,
        uint256 virtualBalanceIn,
        uint256 virtualBalanceOut
    ) public view {
        vm.assume(virtualBalanceIn > 0);

        (SwapRegisters memory swap, bool clamped) =
            harness.exactInLeg(balanceOut, 0, 0, virtualBalanceIn, virtualBalanceOut);

        assertEq(swap.amountOut, 0, "zero input must yield zero output");
        assertEq(swap.amountIn, 0, "the input register must be left untouched");
        assertFalse(clamped, "a zero quote can never exceed the output balance");
    }

    /// @notice Zero requested output costs zero input.
    /// @dev `virtualBalanceOut > 0` is required: `Math.ceilDiv` checks its divisor before
    ///      short-circuiting on a zero numerator, so `ceilDiv(0, 0)` panics rather than
    ///      returning zero.
    function test_exactOut_zeroOutputYieldsZeroInput(
        uint256 balanceOut,
        uint256 virtualBalanceIn,
        uint256 virtualBalanceOut
    ) public view {
        vm.assume(virtualBalanceOut > 0);

        (SwapRegisters memory swap, bool clamped) =
            harness.exactOutLeg(balanceOut, 0, 0, virtualBalanceIn, virtualBalanceOut);

        assertEq(swap.amountIn, 0, "zero output must cost zero input");
        assertEq(swap.amountOut, 0, "the output register must stay at zero");
        assertFalse(clamped, "a zero request can never exceed the output balance");
    }

    /// @notice A full fill against a pool with no virtual output reserve panics.
    ///
    /// @dev Not a named error: `Math.ceilDiv` divides by `vOut - amountOut == 0` and raises
    ///      `Panic(0x12)`. Reachable only when the reconstructed liquidity offset is zero,
    ///      i.e. an empty pool, so this is a liveness wart rather than a safety hole — but
    ///      it is the exact boundary at which the exact-out leg stops being total, and a
    ///      reimplementation that returns `0` or `type(uint256).max` here would be a
    ///      behavioural change.
    function test_exactOut_panicsOnZeroLiquidityFullFill(uint256 virtualBalanceIn) public {
        vm.expectRevert(stdError.divisionError);
        harness.exactOutLeg(0, 0, 0, virtualBalanceIn, 0);
    }

    // -----------------------------------------------------------------------
    // The clamp / exact-out algebraic coincidence
    // -----------------------------------------------------------------------

    /// @notice A clamped exact-in swap prices identically to an exact-out swap for the
    ///         whole output balance.
    ///
    /// @dev Substituting `out := balanceOut` into the exact-out formula at `:155-158` gives
    ///      the clamp reconstruction at `:148` verbatim:
    ///
    ///        :148   ceilDiv(out * vIn, vOut - out)                with out = balanceOut
    ///        :155   ceilDiv(amountOut * vIn, vOut - amountOut)    with amountOut = balanceOut
    ///
    ///      Economically this is the statement that a partial fill is honestly priced: the
    ///      taker whose order was cut down pays exactly what a taker who had asked for the
    ///      reduced amount up front would have paid, with no penalty and no discount.
    ///
    ///      Mechanically it is a self-check on the harness. The two legs are transcribed
    ///      separately in `XYCConcentrateHarness._pricingLegs`; if either was mistranscribed
    ///      — a `/` where the source has `ceilDiv`, reserves swapped, the clamp applied
    ///      before rather than after the quotient — this equality breaks. That is why it is
    ///      worth stating even though it looks like a restatement of the source.
    ///
    ///      The exact-out call is deliberately *outside* the `try`: if the exact-in leg
    ///      clamped without reverting it has already evaluated
    ///      `ceilDiv(balanceOut * vIn, vOut - balanceOut)` successfully, so the exact-out
    ///      leg must succeed too. A revert there is a genuine failure, not a vacuous case.
    function test_clampedExactIn_equalsExactOutAtFullBalance(
        uint256 balanceOut,
        uint256 amountIn,
        uint256 virtualBalanceIn,
        uint256 virtualBalanceOut
    ) public view {
        try harness.exactInLeg(balanceOut, amountIn, 0, virtualBalanceIn, virtualBalanceOut) returns (
            SwapRegisters memory clampedFill,
            bool clamped
        ) {
            if (!clamped) {
                return;
            }

            (SwapRegisters memory fullFill, bool clampedAgain) =
                harness.exactOutLeg(balanceOut, 0, balanceOut, virtualBalanceIn, virtualBalanceOut);

            assertFalse(clampedAgain, "asking for exactly the balance must not itself clamp");
            assertEq(fullFill.amountOut, balanceOut, "exact-out for the whole balance delivers the whole balance");
            assertEq(clampedFill.amountOut, fullFill.amountOut, "both routes deliver the same output");
            assertEq(clampedFill.amountIn, fullFill.amountIn, "both routes charge the same input");
        } catch {
            // Reverted; there is no partial fill to compare against.
        }
    }

    /// @notice A partial fill never charges the taker more than they offered.
    ///
    /// @dev The other half of the clamp's economics, and the one that protects the *taker*:
    ///      `:148` overwrites `ctx.swap.amountIn`, so without this the instruction could in
    ///      principle cut the fill down and still bill for the full order.
    ///
    ///      It holds because `amountIn' = ceil(balanceOut * vIn / (vOut - balanceOut))` is
    ///      the least input that buys `balanceOut`, and the branch was only entered because
    ///      the taker's `amountIn` bought strictly more than that. Concretely, with
    ///      `d = vOut - balanceOut`, the branch condition gives
    ///      `amountIn * (d - 1) >= (balanceOut + 1) * vIn`, and
    ///      `(balanceOut + 1) / (d - 1) > balanceOut / d`, so `amountIn` strictly exceeds
    ///      the rational the ceiling is taken of — hence it is at least the ceiling.
    ///
    ///      Stated unconditionally: on the unclamped branch the register is untouched, so
    ///      equality holds trivially and the two branches share one inequality.
    function test_exactIn_partialFillNeverChargesMoreThanOffered(
        uint256 balanceOut,
        uint256 amountIn,
        uint256 virtualBalanceIn,
        uint256 virtualBalanceOut
    ) public view {
        try harness.exactInLeg(balanceOut, amountIn, 0, virtualBalanceIn, virtualBalanceOut) returns (
            SwapRegisters memory swap,
            bool
        ) {
            assertLe(swap.amountIn, amountIn, "a partial fill must never charge more than the taker offered");
        } catch {
            // Reverted; nothing was charged.
        }
    }

    /// @notice An exact-in swap that does not clamp leaves the input register untouched.
    /// @dev The complement of the property above, and the reason `amountIn` is an in/out
    ///      register rather than a pure input: `:148` is the only write to it on the
    ///      exact-in path.
    function test_exactIn_unclampedLeavesAmountInUntouched(
        uint256 balanceOut,
        uint256 amountIn,
        uint256 virtualBalanceIn,
        uint256 virtualBalanceOut
    ) public view {
        try harness.exactInLeg(balanceOut, amountIn, 0, virtualBalanceIn, virtualBalanceOut) returns (
            SwapRegisters memory swap,
            bool clamped
        ) {
            if (!clamped) {
                assertEq(swap.amountIn, amountIn, "a full fill must not rewrite the taker's input");
            }
        } catch {
            // Reverted; nothing to observe.
        }
    }

    // -----------------------------------------------------------------------
    // Recompute guards, on the pricing legs
    // -----------------------------------------------------------------------

    /// @notice The exact-in recompute guard rejects a pre-populated output register, with
    ///         the exact error and the exact arguments.
    ///
    /// @dev `:144`. Without it a program could run the curve twice and compound the price,
    ///      which is why instruction ordering is security-critical. The error carries both
    ///      registers, so the selector alone is not enough — the encoded arguments are part
    ///      of the interface and are checked here.
    ///
    ///      Stated on the pricing leg, where it is provable today. The same property
    ///      against the real instruction is `test_full_exactIn_revertsWhenAmountOutAlreadySet`.
    function test_exactIn_revertsWhenAmountOutAlreadySet(
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 virtualBalanceIn,
        uint256 virtualBalanceOut
    ) public {
        vm.assume(amountOut != 0);

        vm.expectRevert(
            abi.encodeWithSelector(XYCConcentrate.ConcentrateRecomputeDetected.selector, amountIn, amountOut)
        );
        harness.exactInLeg(balanceOut, amountIn, amountOut, virtualBalanceIn, virtualBalanceOut);
    }

    /// @notice The exact-out recompute guard rejects a pre-populated input register, with
    ///         the exact error and the exact arguments.
    /// @dev `:152`. Mirror image of the above; the two guards are separate `require`s on
    ///      separate branches and neither implies the other.
    function test_exactOut_revertsWhenAmountInAlreadySet(
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 virtualBalanceIn,
        uint256 virtualBalanceOut
    ) public {
        vm.assume(amountIn != 0);

        vm.expectRevert(
            abi.encodeWithSelector(XYCConcentrate.ConcentrateRecomputeDetected.selector, amountIn, amountOut)
        );
        harness.exactOutLeg(balanceOut, amountIn, amountOut, virtualBalanceIn, virtualBalanceOut);
    }

    // =======================================================================
    // FULL-INSTRUCTION — properties routed through `_computeL`
    //
    // Every test below reaches `Math.mulDiv`, and so `Math.mul512`/`mulmod`. Expected to
    // stay PENDING under Kontrol until the mul512-collapse lemma lands; they pass as fuzz
    // tests today and are what the lemma will be validated against.
    // =======================================================================

    /// @dev Price bounds that keep `_computeL` and the virtual-offset block total, so that
    ///      a `vm.expectRevert` in this section can name a specific error rather than
    ///      catching an incidental overflow.
    ///
    ///      `sqrtPriceMin ∈ [1, 2^56]` is strictly below `ONE`; `sqrtPriceMax ∈ [ONE, ONE + 2^64]`
    ///      is at or above it. So `0 < sqrtPriceMin < sqrtPriceMax` holds by construction —
    ///      no `vm.assume`, no rejected samples, no extra path constraint — and the spot
    ///      price sits inside the band, which is the regime the instruction is written for.
    ///
    ///      With balances held to `uint64` this bounds the whole chain well clear of
    ///      overflow: `beta <= 2e19`, `beta^2 <= 4e38`, `fourAC <= 2.6e40`, `L <= 2e21`, and
    ///      both virtual reserves `<= 2.1e21`, against a `uint256` ceiling of `1.16e77`.
    function _priceBounds(uint56 minRaw, uint64 spread)
        internal
        pure
        returns (uint256 sqrtPriceMin, uint256 sqrtPriceMax)
    {
        sqrtPriceMin = 1 + uint256(minRaw);
        sqrtPriceMax = ONE + uint256(spread);
    }

    /// @dev `parse2D` reads two raw words, so the args are just the two bounds packed.
    function _args(uint56 minRaw, uint64 spread) internal pure returns (bytes memory) {
        (uint256 sqrtPriceMin, uint256 sqrtPriceMax) = _priceBounds(minRaw, spread);
        return abi.encodePacked(sqrtPriceMin, sqrtPriceMax);
    }

    // -----------------------------------------------------------------------
    // Recompute guards, against the real instruction
    // -----------------------------------------------------------------------

    /// @notice `:144` against unmodified bytecode, in both token orientations.
    /// @dev `tokenIn` and `tokenOut` are symbolic and unconstrained, so the theorem covers
    ///      `isTokenInLt` both ways — including the equal-address case, which the
    ///      instruction treats as `tokenIn > tokenOut`. The guard sits after the liquidity
    ///      reconstruction, so the price bounds must keep that block total for the expected
    ///      error to be the one that fires; `_priceBounds` is what arranges that.
    function test_full_exactIn_revertsWhenAmountOutAlreadySet(
        address tokenIn,
        address tokenOut,
        uint64 balanceIn,
        uint64 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint56 minRaw,
        uint64 spread
    ) public {
        vm.assume(amountOut != 0);

        vm.expectRevert(
            abi.encodeWithSelector(XYCConcentrate.ConcentrateRecomputeDetected.selector, amountIn, amountOut)
        );
        harness.full(tokenIn, tokenOut, true, balanceIn, balanceOut, amountIn, amountOut, _args(minRaw, spread));
    }

    /// @notice `:152` against unmodified bytecode, in both token orientations.
    function test_full_exactOut_revertsWhenAmountInAlreadySet(
        address tokenIn,
        address tokenOut,
        uint64 balanceIn,
        uint64 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint56 minRaw,
        uint64 spread
    ) public {
        vm.assume(amountIn != 0);

        vm.expectRevert(
            abi.encodeWithSelector(XYCConcentrate.ConcentrateRecomputeDetected.selector, amountIn, amountOut)
        );
        harness.full(tokenIn, tokenOut, false, balanceIn, balanceOut, amountIn, amountOut, _args(minRaw, spread));
    }

    // -----------------------------------------------------------------------
    // No-drain, against the real instruction
    // -----------------------------------------------------------------------

    /// @notice The real instruction never returns more than the maker's output balance, in
    ///         either direction, for any price bounds whatsoever.
    /// @dev Fully unconstrained: both price bounds are free `uint256`s, so inverted or
    ///      degenerate bands are in scope and simply land in the `catch`. This is the FULL-INSTRUCTION
    ///      companion to `test_exactIn_cannotDrainPool` and the property that actually
    ///      matters for maker safety, since it is stated about bytecode rather than about a
    ///      transcription.
    function test_full_cannotDrainPool(
        address tokenIn,
        address tokenOut,
        bool isExactIn,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amount,
        uint256 sqrtPriceMin,
        uint256 sqrtPriceMax
    ) public view {
        bytes memory args = abi.encodePacked(sqrtPriceMin, sqrtPriceMax);

        try harness.full(
            tokenIn,
            tokenOut,
            isExactIn,
            balanceIn,
            balanceOut,
            isExactIn ? amount : 0,
            isExactIn ? 0 : amount,
            args
        ) returns (SwapRegisters memory swap) {
            assertLe(swap.amountOut, balanceOut, "no swap may return more than the output balance");
        } catch {
            // Reverted; no quote to bound.
        }
    }

    // -----------------------------------------------------------------------
    // Orientation
    // -----------------------------------------------------------------------

    /// @notice The virtual offsets follow the tokens' address ordering, not the trade
    ///         direction; the ceiling follows the input side.
    ///
    /// @dev This is the classic concentrated-liquidity vulnerability class. `:127-141`
    ///      decides two independent things from `isTokenInLt`:
    ///
    ///        (a) which real balance plays `bLt` and which plays `bGt` when reconstructing
    ///            `L` — and `_computeL` is *not* symmetric in its first two arguments
    ///            (`:104` weights `bLt` by `sqrtPriceMin` and `bGt` by `1/sqrtPriceMax`), so
    ///            getting this backwards silently reprices the pool;
    ///
    ///        (b) which of the two offsets — `L * ONE / sqrtPriceMax` for the lower-address
    ///            token, `L * sqrtPriceMin / ONE` for the higher-address one — is added to
    ///            which side, and which of them gets `Math.Rounding.Ceil`.
    ///
    ///      The property compares the same pool traded in opposite directions:
    ///
    ///        A: tokenIn = TOKEN_LO, so (balanceIn, balanceOut) = (bLt, bGt)
    ///        B: tokenIn = TOKEN_HI, so (balanceIn, balanceOut) = (bGt, bLt)
    ///
    ///      and asserts
    ///
    ///        (a) `L` is identical — it depends only on the (Lt, Gt) pair, not on direction;
    ///        (b) the offset attached to the lower-address token is the same quantity in
    ///            both runs, differing by at most one wei, and the *larger* of the two is
    ///            always the one on the input side. Same for the higher-address token.
    ///
    ///      A `<= 1` gap is exactly what `Ceil` versus floor of the same rational produces,
    ///      and nothing else does: if (b) were mistranscribed the two offsets would be
    ///      `L * ONE / sqrtPriceMax` and `L * sqrtPriceMin / ONE`, which under
    ///      `_priceBounds` differ by orders of magnitude rather than by a wei. If (a) were
    ///      mistranscribed the `L` equality fails outright. So neither conjunct is vacuous,
    ///      and the pair pins the orientation completely.
    function test_orientation_offsetsFollowTokenRoleNotSwapDirection(
        uint64 balanceLt,
        uint64 balanceGt,
        uint56 minRaw,
        uint64 spread
    ) public view {
        bytes memory args = _args(minRaw, spread);

        (uint256 liquidityA, uint256 virtualInA, uint256 virtualOutA) =
            harness.virtualReserves(TOKEN_LO, TOKEN_HI, balanceLt, balanceGt, args);
        (uint256 liquidityB, uint256 virtualInB, uint256 virtualOutB) =
            harness.virtualReserves(TOKEN_HI, TOKEN_LO, balanceGt, balanceLt, args);

        assertEq(liquidityA, liquidityB, "L must depend on the (Lt, Gt) pair only, not on trade direction");

        // The lower-address token is the input in A and the output in B.
        uint256 ltOffsetAsInput = virtualInA - balanceLt;
        uint256 ltOffsetAsOutput = virtualOutB - balanceLt;
        // The higher-address token is the output in A and the input in B.
        uint256 gtOffsetAsOutput = virtualOutA - balanceGt;
        uint256 gtOffsetAsInput = virtualInB - balanceGt;

        assertGe(ltOffsetAsInput, ltOffsetAsOutput, "the input side must round its offset up");
        assertLe(ltOffsetAsInput - ltOffsetAsOutput, 1, "the two sides must share one offset, up to rounding");

        assertGe(gtOffsetAsInput, gtOffsetAsOutput, "the input side must round its offset up");
        assertLe(gtOffsetAsInput - gtOffsetAsOutput, 1, "the two sides must share one offset, up to rounding");
    }

    // -----------------------------------------------------------------------
    // Differential: the LEG-LEVEL transcription against the real instruction
    // -----------------------------------------------------------------------

    /// @notice The exact-in pricing leg, fed the real instruction's virtual reserves,
    ///         reproduces the real instruction register for register.
    ///
    /// @dev This is the trust boundary for the whole LEG-LEVEL section.
    ///      `XYCConcentrateHarness.exactInLeg` is a *transcription* of `:143-159`, and every
    ///      LEG-LEVEL property is a property of that transcription. This test is what makes
    ///      them properties of `XYCConcentrate`.
    ///
    ///      The leg call sits inside the `try` on purpose: if `full` succeeded then the leg
    ///      is running the identical arithmetic on identical operands and must also succeed,
    ///      so a revert there is a real discrepancy rather than a case to skip.
    function test_diff_exactIn_fullMatchesLegs(
        uint64 balanceIn,
        uint64 balanceOut,
        uint64 amountIn,
        uint56 minRaw,
        uint64 spread
    ) public view {
        bytes memory args = _args(minRaw, spread);

        (, uint256 virtualBalanceIn, uint256 virtualBalanceOut) =
            harness.virtualReserves(TOKEN_LO, TOKEN_HI, balanceIn, balanceOut, args);

        try harness.full(TOKEN_LO, TOKEN_HI, true, balanceIn, balanceOut, amountIn, 0, args) returns (
            SwapRegisters memory expected
        ) {
            (SwapRegisters memory actual,) =
                harness.exactInLeg(balanceOut, amountIn, 0, virtualBalanceIn, virtualBalanceOut);

            assertEq(actual.amountIn, expected.amountIn, "transcribed exact-in leg must match the instruction");
            assertEq(actual.amountOut, expected.amountOut, "transcribed exact-in leg must match the instruction");
        } catch {
            // The instruction reverted; the transcription is only claimed to agree on the
            // success path, and the guard properties cover the revert path separately.
        }
    }

    /// @notice As above, for the exact-out leg and the mirrored token orientation.
    /// @dev Runs with `tokenIn > tokenOut` so that the differential covers the *other* arm
    ///      of the `isTokenInLt` branch as well; between the two `test_diff_*` tests both
    ///      orientations and both legs are exercised against real bytecode.
    function test_diff_exactOut_fullMatchesLegs(
        uint64 balanceIn,
        uint64 balanceOut,
        uint64 amountOut,
        uint56 minRaw,
        uint64 spread
    ) public view {
        bytes memory args = _args(minRaw, spread);

        (, uint256 virtualBalanceIn, uint256 virtualBalanceOut) =
            harness.virtualReserves(TOKEN_HI, TOKEN_LO, balanceIn, balanceOut, args);

        try harness.full(TOKEN_HI, TOKEN_LO, false, balanceIn, balanceOut, 0, amountOut, args) returns (
            SwapRegisters memory expected
        ) {
            (SwapRegisters memory actual,) =
                harness.exactOutLeg(balanceOut, 0, amountOut, virtualBalanceIn, virtualBalanceOut);

            assertEq(actual.amountIn, expected.amountIn, "transcribed exact-out leg must match the instruction");
            assertEq(actual.amountOut, expected.amountOut, "transcribed exact-out leg must match the instruction");
        } catch {
            // The instruction reverted; see above.
        }
    }
}
