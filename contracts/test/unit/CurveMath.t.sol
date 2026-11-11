// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";

import {FullMath} from "v4-core/src/libraries/FullMath.sol";

import {CurveMath} from "src/libraries/CurveMath.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {CurveMathHarness} from "../helpers/CurveMathHarness.sol";

/// @title `CurveMath` unit and fuzz tests
/// @notice Covers `docs/SPEC.md` sections 5.4, 5.5, 5.8 and 6.1, and the arithmetic half
/// of Invariants 1, 2, 7, 8, 11, 12, 14 and 17.
/// @dev Every rounding direction in this library was chosen to make
/// `(vE0 + ethReserve) * (vT0 - tokensSold)` non-decreasing, so the fuzz tests here are
/// written against the rounding rather than against the happy path: they assert the
/// product moves the right way for the quote the library returns, including at the
/// one-wei and one-base-unit boundaries where the rounding is the only thing that decides
/// the outcome.
contract CurveMathTest is Test {
    uint256 private constant VT0 = PledrinConstants.VIRTUAL_TOKEN_RESERVE;
    uint256 private constant C = PledrinConstants.CURVE_SUPPLY;
    uint256 private constant TAU = PledrinConstants.VIRTUAL_TOKEN_TAIL;
    uint256 private constant BPS = PledrinConstants.BPS_DENOMINATOR;

    CurveMathHarness private harness;

    function setUp() public {
        harness = new CurveMathHarness();
    }

    // ------------------------------------------------------------------
    // buyQuote, ordinary branch
    // ------------------------------------------------------------------

    /// @notice Section 5.4 steps 1 to 3 at the default parameters.
    function test_buyQuoteChargesTheFeeOnTheValueAndPricesTheRemainder() public pure {
        uint256 vE0 = 0.5 ether;
        (uint256 tokensOut, uint256 ethToCurve, uint256 fee, uint256 refund) =
            CurveMath.buyQuote(vE0, VT0, C, 100, 1 ether);

        uint256 expectedFee = FullMath.mulDivRoundingUp(1 ether, 100, BPS);
        uint256 expectedNet = 1 ether - expectedFee;
        assertEq(fee, expectedFee, "fee");
        assertEq(ethToCurve, expectedNet, "ethToCurve");
        assertEq(refund, 0, "refund");
        assertEq(tokensOut, FullMath.mulDiv(VT0, expectedNet, vE0 + expectedNet), "tokensOut");
    }

    /// @notice Invariant 14's premise: a zero fee is honoured exactly, with nothing
    /// skimmed.
    function test_buyQuoteWithZeroFeeSendsEverythingToTheCurve() public pure {
        (, uint256 ethToCurve, uint256 fee,) = CurveMath.buyQuote(0.5 ether, VT0, C, 0, 1 ether);

        assertEq(fee, 0, "fee");
        assertEq(ethToCurve, 1 ether, "ethToCurve");
    }

    /// @notice The buy fee rounds up, so a one-wei buy at a non-zero fee reaches the curve
    /// with nothing and buys nothing. `buy` rejects that with `ZeroAmount`.
    function test_buyQuoteRoundsTheFeeUpEvenWhenThatTakesTheWholeValue() public pure {
        (uint256 tokensOut, uint256 ethToCurve, uint256 fee,) =
            CurveMath.buyQuote(0.5 ether, VT0, C, 100, 1);

        assertEq(fee, 1, "the fee rounds up to the whole wei");
        assertEq(ethToCurve, 0, "nothing reaches the curve");
        assertEq(tokensOut, 0, "no tokens");
    }

    /// @notice `MIN_BUY_WEI` is the smallest buy `buy` accepts, and it yields tokens at
    /// every permitted `virtualEthReserve`.
    /// @dev Written out rather than looped: the `require-revert-in-loop` lint fires on
    /// `CurveMath`'s own revert when the library is called from inside a loop, and
    /// `foundry.toml` makes every lint finding fatal.
    function test_buyQuoteAtMinBuyWeiYieldsTokensAcrossTheReserveRange() public pure {
        uint256 feeBps = PledrinConstants.MAX_TOTAL_FEE_BPS;
        uint256 value = PledrinConstants.MIN_BUY_WEI;

        (uint256 atMin,,,) =
            CurveMath.buyQuote(PledrinConstants.MIN_VIRTUAL_ETH_RESERVE, VT0, C, feeBps, value);
        (uint256 atDefault,,,) = CurveMath.buyQuote(5e17, VT0, C, feeBps, value);
        (uint256 atMax,,,) =
            CurveMath.buyQuote(PledrinConstants.MAX_VIRTUAL_ETH_RESERVE, VT0, C, feeBps, value);

        assertGt(atMin, 0, "a minimum buy yields tokens at the smallest raise");
        assertGt(atDefault, 0, "and at the default");
        assertGt(atMax, 0, "and at the largest raise");
    }

    // ------------------------------------------------------------------
    // buyQuote, clipped final branch
    // ------------------------------------------------------------------

    /// @notice Section 5.4 step 4's second branch and Invariant 12: the clipped buy takes
    /// exactly the remaining supply, prices it with `mulDivUp`, recomputes the fee on the
    /// ETH actually consumed and refunds the rest.
    function test_buyQuoteClipsTheFinalBuyToTheRemainingSupply() public pure {
        uint256 vE0 = 0.5 ether;
        uint256 remaining = 1e18;
        uint256 sold = C - remaining;
        uint256 virtualEth = vE0 + 100 ether;
        uint256 virtualTokens = VT0 - sold;

        (uint256 tokensOut, uint256 ethToCurve, uint256 fee, uint256 refund) =
            CurveMath.buyQuote(virtualEth, virtualTokens, remaining, 100, 100 ether);

        assertEq(tokensOut, remaining, "the clipped buy takes exactly what is left");
        assertEq(
            ethToCurve,
            FullMath.mulDivRoundingUp(virtualEth, remaining, virtualTokens - remaining),
            "the clipped price rounds up"
        );
        assertEq(
            fee,
            FullMath.mulDivRoundingUp(ethToCurve, 100, BPS - 100),
            "the fee is recomputed on the ETH consumed, not on msg.value"
        );
        assertEq(refund, 100 ether - ethToCurve - fee, "refund");
        assertEq(ethToCurve + fee + refund, 100 ether, "no wei created or lost");
    }

    /// @notice The clipped buy's `require` of section 5.4 cannot fire, and this is the
    /// fuzz that shows it. `feeMax = ceil(value * feeBps / 10000)` gives
    /// `netMax <= value * (10000 - feeBps) / 10000`, so the clip's precondition
    /// `netMax >= ethToCurve` already implies
    /// `value >= ethToCurve + ceil(ethToCurve * feeBps / (10000 - feeBps))`, which is
    /// exactly `required`. The `require` is therefore a defensive assertion rather than a
    /// reachable branch, and `docs/SPEC.md` section 5.4's claim that it covers an
    /// "at-most-two-wei rounding overshoot" overstates what the arithmetic permits: the
    /// overshoot is zero.
    function testFuzz_clippedBuyNeverCostsMoreThanTheValue(
        uint256 virtualEth,
        uint256 virtualTokens,
        uint256 remaining,
        uint16 feeBps,
        uint256 value
    ) public view {
        virtualEth = bound(virtualEth, 1, 1e30);
        virtualTokens = bound(virtualTokens, 2, VT0);
        remaining = bound(remaining, 1, virtualTokens - 1);
        feeBps = uint16(bound(feeBps, 0, PledrinConstants.MAX_TOTAL_FEE_BPS));
        value = bound(value, 1, 1e30);

        (uint256 tokensOut, uint256 ethToCurve, uint256 fee, uint256 refund) =
            harness.buyQuote(virtualEth, virtualTokens, remaining, feeBps, value);

        if (tokensOut != remaining) return;
        assertEq(
            ethToCurve + fee + refund,
            value,
            "a clipped buy accounts for every wei of the value it was sent"
        );
    }

    /// @notice The boundary the previous test straddles: one wei more than the cost of the
    /// tokens plus their fee is accepted and refunds that wei.
    function test_buyQuoteAcceptsTheClippedBuyAtExactlyItsCost() public pure {
        uint256 virtualEth = 0.5 ether + 100 ether;
        uint256 remaining = 1e18;
        uint256 virtualTokens = VT0 - (C - remaining);
        uint256 ethCost =
            FullMath.mulDivRoundingUp(virtualEth, remaining, virtualTokens - remaining);
        uint256 feeCost = FullMath.mulDivRoundingUp(ethCost, 100, BPS - 100);

        (uint256 tokensOut,,, uint256 refund) =
            CurveMath.buyQuote(virtualEth, virtualTokens, remaining, 100, ethCost + feeCost);
        assertEq(tokensOut, remaining, "tokens");
        assertEq(refund, 0, "nothing to refund at exactly the cost");

        (,,, uint256 refundPlusOne) =
            CurveMath.buyQuote(virtualEth, virtualTokens, remaining, 100, ethCost + feeCost + 1);
        assertEq(refundPlusOne, 1, "one wei over the cost is refunded");
    }

    /// @notice The clipped branch also fires when the quote lands exactly one base unit
    /// above the remaining supply.
    function test_buyQuoteClipsWhenTheQuoteExceedsRemainingByOneBaseUnit() public pure {
        uint256 virtualEth = 1 ether;
        uint256 virtualTokens = VT0;
        // Pick `remaining` one below what the unclipped quote would yield.
        (uint256 unclipped,,,) = CurveMath.buyQuote(virtualEth, virtualTokens, C, 0, 1 ether);
        uint256 remaining = unclipped - 1;

        (uint256 tokensOut, uint256 ethToCurve, uint256 fee, uint256 refund) =
            CurveMath.buyQuote(virtualEth, virtualTokens, remaining, 0, 1 ether);
        assertEq(tokensOut, remaining, "clipped to remaining");
        // One base unit is worth a fraction of a wei here and `ethToCurve` rounds up, so
        // the clip costs the buyer the whole value and refunds nothing.
        assertEq(refund, 0, "refund");
        assertEq(ethToCurve + fee, 1 ether, "the clipped cost is the whole value");
    }

    /// @notice The unclipped branch is taken when the quote lands exactly on the remaining
    /// supply, so no refund arises at the boundary.
    function test_buyQuoteDoesNotClipWhenTheQuoteEqualsRemaining() public pure {
        (uint256 unclipped,,,) = CurveMath.buyQuote(1 ether, VT0, C, 0, 1 ether);

        (uint256 tokensOut, uint256 ethToCurve,, uint256 refund) =
            CurveMath.buyQuote(1 ether, VT0, unclipped, 0, 1 ether);
        assertEq(tokensOut, unclipped, "tokens");
        assertEq(ethToCurve, 1 ether, "the whole value reaches the curve");
        assertEq(refund, 0, "no refund on the exact boundary");
    }

    // ------------------------------------------------------------------
    // sellQuote
    // ------------------------------------------------------------------

    /// @notice Section 5.5 steps 2 to 5.
    function test_sellQuoteRoundsGrossDownAndTheFeeUp() public pure {
        uint256 virtualEth = 0.5 ether + 1 ether;
        uint256 virtualTokens = VT0 - 1e24;

        (uint256 gross, uint256 fee, uint256 out) =
            CurveMath.sellQuote(virtualEth, virtualTokens, 100, 1e24);

        assertEq(gross, FullMath.mulDiv(virtualEth, 1e24, virtualTokens + 1e24), "gross");
        assertEq(fee, FullMath.mulDivRoundingUp(gross, 100, BPS), "fee");
        assertEq(out, gross - fee, "out");
    }

    /// @notice A dust sell yields a gross of zero, which `sell` rejects with `ZeroAmount`
    /// rather than paying nothing for a real token.
    function test_sellQuoteOfOneBaseUnitCanYieldNothing() public pure {
        (uint256 gross,, uint256 out) = CurveMath.sellQuote(0.5 ether, VT0, 100, 1);

        assertEq(gross, 0, "one base unit is worth less than a wei at the opening price");
        assertEq(out, 0, "out");
    }

    /// @notice Section 5.6's bound at the cap: selling the entire sale supply back pays at
    /// most the reserve, with the equality case exact at the identity `C * tau == vT0 * S_LP`.
    function test_sellQuoteOfTheWholeSupplyAtTheCapPaysAtMostTheReserve() public pure {
        uint256 vE0 = 0.5 ether;
        uint256 reserve = PledrinConstants.ETH_TARGET_MULTIPLE * vE0;
        (uint256 gross,,) = CurveMath.sellQuote(vE0 + reserve, TAU, 0, C);

        assertLe(gross, reserve, "Invariant 2 at the cap");
        assertEq(gross, reserve, "the identity makes the bound exact at the cap");
    }

    // ------------------------------------------------------------------
    // splitFee: Invariants 14 and 17
    // ------------------------------------------------------------------

    /// @notice Invariant 14 at the documented default shares.
    function test_splitFeeSumsToTheFee() public pure {
        (uint256 creatorCut, uint256 protocolCut, uint256 protectionCut) =
            CurveMath.splitFee(10_000_001, 3000, 4000);

        assertEq(creatorCut, 3_000_000, "creator");
        assertEq(protocolCut, 4_000_000, "protocol");
        assertEq(protectionCut, 3_000_001, "the remainder lands in holder protection");
        assertEq(creatorCut + protocolCut + protectionCut, 10_000_001, "Invariant 14");
    }

    /// @notice Invariant 17: every rounding remainder goes to holder protection and
    /// nowhere else. One wei of fee is indivisible, so all of it does.
    function test_splitFeeSendsAWholeIndivisibleFeeToProtection() public pure {
        (uint256 creatorCut, uint256 protocolCut, uint256 protectionCut) =
            CurveMath.splitFee(1, 3000, 4000);

        assertEq(creatorCut, 0, "creator");
        assertEq(protocolCut, 0, "protocol");
        assertEq(protectionCut, 1, "the whole wei is the remainder");
    }

    /// @notice A zero fee splits into three zeroes rather than reverting.
    function test_splitFeeOfZeroIsThreeZeroes() public pure {
        (uint256 creatorCut, uint256 protocolCut, uint256 protectionCut) =
            CurveMath.splitFee(0, 3000, 4000);

        assertEq(creatorCut + protocolCut + protectionCut, 0, "zero");
    }

    /// @notice A share set that gives holder protection nothing still sums exactly.
    function test_splitFeeWithNoProtectionShareStillSumsToTheFee() public pure {
        (uint256 creatorCut, uint256 protocolCut, uint256 protectionCut) =
            CurveMath.splitFee(99_999, 5000, 5000);

        assertEq(creatorCut + protocolCut + protectionCut, 99_999, "Invariant 14");
        assertEq(protectionCut, 1, "only the rounding remainder");
    }

    /// @notice **Invariant 14, by fuzz.** The holder-protection share is taken as a
    /// residual and never as a product, so the three parts sum to the fee for every
    /// possible fee and every possible share set that sums to 10000.
    function testFuzz_splitFeeAlwaysSumsToTheFee(uint256 fee, uint16 creatorShareBps, uint16 split)
        public
        pure
    {
        creatorShareBps = uint16(bound(creatorShareBps, 0, BPS));
        uint16 protocolShareBps = uint16(bound(split, 0, BPS - creatorShareBps));
        fee = bound(fee, 0, type(uint128).max);

        (uint256 creatorCut, uint256 protocolCut, uint256 protectionCut) =
            CurveMath.splitFee(fee, creatorShareBps, protocolShareBps);

        assertEq(creatorCut + protocolCut + protectionCut, fee, "Invariant 14");
        assertLe(creatorCut, FullMath.mulDiv(fee, creatorShareBps, BPS), "creator is floored");
        assertLe(protocolCut, FullMath.mulDiv(fee, protocolShareBps, BPS), "protocol is floored");
    }

    /// @notice Invariant 17 by fuzz: the remainder is exactly what the two floors drop,
    /// and it is always in the protection cut.
    function testFuzz_splitFeeRemainderGoesToProtection(uint128 fee) public pure {
        (uint256 creatorCut, uint256 protocolCut, uint256 protectionCut) =
            CurveMath.splitFee(fee, 3000, 4000);

        uint256 exactProtection = FullMath.mulDiv(fee, 3000, BPS);
        assertGe(protectionCut, exactProtection, "protection never loses the remainder");
        assertLe(protectionCut - exactProtection, 2, "at most the two dropped remainders");
        assertEq(creatorCut + protocolCut + protectionCut, fee, "Invariant 14");
    }

    // ------------------------------------------------------------------
    // Rounding, against the solvency product
    // ------------------------------------------------------------------

    /// @notice **Invariant 1, by fuzz over a buy.** A buy adds `ethToCurve` to `vE` exactly
    /// and removes at most the exact token amount from `vT`, so the product never falls.
    function testFuzz_buyNeverLowersTheSolvencyProduct(
        uint128 vE0,
        uint128 reserve,
        uint128 sold,
        uint96 value,
        uint16 feeBps
    ) public pure {
        vE0 = uint128(
            bound(
                vE0,
                PledrinConstants.MIN_VIRTUAL_ETH_RESERVE,
                PledrinConstants.MAX_VIRTUAL_ETH_RESERVE
            )
        );
        sold = uint128(bound(sold, 0, C - 1));
        reserve = uint128(bound(reserve, 0, uint256(PledrinConstants.ETH_TARGET_MULTIPLE) * vE0));
        feeBps = uint16(bound(feeBps, 0, PledrinConstants.MAX_TOTAL_FEE_BPS));
        uint256 value_ = bound(value, PledrinConstants.MIN_BUY_WEI, 1e24);

        uint256 virtualEth = uint256(vE0) + reserve;
        uint256 virtualTokens = VT0 - sold;
        uint256 before = virtualEth * virtualTokens;

        (uint256 tokensOut, uint256 ethToCurve,,) =
            CurveMath.buyQuote(virtualEth, virtualTokens, C - sold, feeBps, value_);

        assertLe(tokensOut, C - sold, "Invariant 6: a buy never oversells the supply");
        uint256 afterProduct = (virtualEth + ethToCurve) * (virtualTokens - tokensOut);
        assertGe(afterProduct, before, "Invariant 1: the product never falls on a buy");
    }

    /// @notice **Invariant 1, by fuzz over a sell.** A sell adds `tokensIn` to `vT` exactly
    /// and removes at most the exact ETH from `vE`, so the product never falls.
    function testFuzz_sellNeverLowersTheSolvencyProduct(
        uint128 vE0,
        uint128 reserve,
        uint128 sold,
        uint128 tokensIn,
        uint16 feeBps
    ) public pure {
        vE0 = uint128(
            bound(
                vE0,
                PledrinConstants.MIN_VIRTUAL_ETH_RESERVE,
                PledrinConstants.MAX_VIRTUAL_ETH_RESERVE
            )
        );
        sold = uint128(bound(sold, 1, C));
        reserve = uint128(
            bound(reserve, 0, uint256(PledrinConstants.ETH_TARGET_MULTIPLE) * uint256(vE0))
        );
        tokensIn = uint128(bound(tokensIn, 1, sold));
        feeBps = uint16(bound(feeBps, 0, PledrinConstants.MAX_TOTAL_FEE_BPS));

        uint256 virtualEth = uint256(vE0) + reserve;
        uint256 virtualTokens = VT0 - sold;
        uint256 before = virtualEth * virtualTokens;

        (uint256 gross,,) = CurveMath.sellQuote(virtualEth, virtualTokens, feeBps, tokensIn);

        uint256 afterProduct = (virtualEth - gross) * (virtualTokens + tokensIn);
        assertGe(afterProduct, before, "Invariant 1: the product never falls on a sell");
    }

    /// @notice **Invariant 2, by fuzz.** For every reachable state and every `dT` in
    /// `[1, tokensSold]`, the gross the sell formula yields is at most `ethReserve`. The
    /// reachable set is characterised by the product bound of Invariant 1, which is what
    /// this test feeds it.
    function testFuzz_sellGrossNeverExceedsTheReserve(
        uint128 vE0,
        uint128 sold,
        uint128 tokensIn,
        uint256 slack
    ) public pure {
        vE0 = uint128(
            bound(
                vE0,
                PledrinConstants.MIN_VIRTUAL_ETH_RESERVE,
                PledrinConstants.MAX_VIRTUAL_ETH_RESERVE
            )
        );
        sold = uint128(bound(sold, 1, C));
        tokensIn = uint128(bound(tokensIn, 1, sold));

        // The smallest reserve the solvency invariant permits at this `sold`, plus any
        // amount of slack: `vE * vT >= K` rearranges to `r >= K / vT - vE0`.
        uint256 virtualTokens = VT0 - sold;
        uint256 k = uint256(vE0) * VT0;
        uint256 minReserve = FullMath.mulDivRoundingUp(k, 1, virtualTokens) - vE0;
        uint256 reserve = minReserve + bound(slack, 0, 1e24);

        (uint256 gross,,) = CurveMath.sellQuote(uint256(vE0) + reserve, virtualTokens, 0, tokensIn);

        assertLe(gross, reserve, "Invariant 2: the curve can always pay the sell");
    }

    /// @notice **Invariant 7, by fuzz.** An immediate round trip never profits, even at a
    /// zero fee, because the buy's token rounding and the sell's ETH rounding both favour
    /// the curve.
    function testFuzz_roundTripNeverProfits(
        uint128 vE0,
        uint128 reserve,
        uint128 sold,
        uint96 value
    ) public pure {
        vE0 = uint128(
            bound(
                vE0,
                PledrinConstants.MIN_VIRTUAL_ETH_RESERVE,
                PledrinConstants.MAX_VIRTUAL_ETH_RESERVE
            )
        );
        sold = uint128(bound(sold, 0, C - 1e18));
        reserve = uint128(bound(reserve, 0, uint256(PledrinConstants.ETH_TARGET_MULTIPLE) * vE0));
        uint256 value_ = bound(value, PledrinConstants.MIN_BUY_WEI, 1e24);

        uint256 virtualEth = uint256(vE0) + reserve;
        uint256 virtualTokens = VT0 - sold;

        (uint256 tokensOut, uint256 ethToCurve,, uint256 refund) =
            CurveMath.buyQuote(virtualEth, virtualTokens, C - sold, 0, value_);
        vm.assume(tokensOut > 0);

        (,, uint256 ethOut) =
            CurveMath.sellQuote(virtualEth + ethToCurve, virtualTokens - tokensOut, 0, tokensOut);

        assertLe(ethOut + refund, value_, "Invariant 7: a round trip is never profitable");
    }

    /// @notice **Invariant 8, by fuzz.** No trade executes better than spot for the user,
    /// evaluated at pre-trade reserves: `ethToCurve * vT >= tokensOut * vE` for a buy and
    /// `ethGross * vT <= tokensIn * vE` for a sell.
    function testFuzz_noTradeBeatsSpot(
        uint128 vE0,
        uint128 reserve,
        uint128 sold,
        uint96 value,
        uint128 tokensIn
    ) public pure {
        vE0 = uint128(
            bound(
                vE0,
                PledrinConstants.MIN_VIRTUAL_ETH_RESERVE,
                PledrinConstants.MAX_VIRTUAL_ETH_RESERVE
            )
        );
        sold = uint128(bound(sold, 1, C - 1e18));
        reserve = uint128(bound(reserve, 0, uint256(PledrinConstants.ETH_TARGET_MULTIPLE) * vE0));
        uint256 value_ = bound(value, PledrinConstants.MIN_BUY_WEI, 1e24);
        tokensIn = uint128(bound(tokensIn, 1, sold));

        uint256 virtualEth = uint256(vE0) + reserve;
        uint256 virtualTokens = VT0 - sold;

        (uint256 tokensOut, uint256 ethToCurve,,) =
            CurveMath.buyQuote(virtualEth, virtualTokens, C - sold, 100, value_);
        _assertProductLe(
            tokensOut, virtualEth, ethToCurve, virtualTokens, "Invariant 8: a buy never beats spot"
        );

        (uint256 gross,,) = CurveMath.sellQuote(virtualEth, virtualTokens, 100, tokensIn);
        _assertProductLe(
            gross, virtualTokens, tokensIn, virtualEth, "Invariant 8: a sell never beats spot"
        );
    }

    /// @dev Invariant 8's products can exceed 256 bits, so they are compared exactly on
    /// the full 512-bit product rather than on a scaled-down approximation that could
    /// flip the inequality.
    function _assertProductLe(uint256 a, uint256 b, uint256 c, uint256 d, string memory err)
        private
        pure
    {
        (uint256 leftHi, uint256 leftLo) = _mul512(a, b);
        (uint256 rightHi, uint256 rightLo) = _mul512(c, d);
        if (leftHi == rightHi) {
            assertLe(leftLo, rightLo, err);
        } else {
            assertLt(leftHi, rightHi, err);
        }
    }

    function _mul512(uint256 a, uint256 b) private pure returns (uint256 hi, uint256 lo) {
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            lo := mul(a, b)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
    }
}
