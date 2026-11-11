// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {ILaunchFactory} from "src/interfaces/ILaunchFactory.sol";
import {CurveMath} from "src/libraries/CurveMath.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {PledrinTestBase} from "../base/PledrinTestBase.sol";
import {ReentrantBuyer} from "../mocks/Actors.sol";

/// @title `BondingCurve.buy`
/// @notice Covers `docs/SPEC.md` section 5.4 and Invariants 1, 5, 6, 8, 10, 11, 12, 13,
/// 32 and 55.
/// @dev The cap boundary is the part of `buy` worth attacking, so the clipped final buy is
/// tested from both sides: one wei short of the cap, exactly at it, and far beyond it.
/// Nothing here asserts an ordering of `buy`'s steps. `buy` is strict
/// checks-effects-interactions — the reserve, the sold counter, the fee buckets and the
/// `Live -> Graduating` transition are all written before the token transfer and the
/// refund — and section 5.4's step order was corrected to match the code. The ordering
/// that is enforced is asserted directly, against the state an external call observes, in
/// `test/unit/CallDiscipline.t.sol`.
contract BondingCurveBuyTest is PledrinTestBase {
    /// @notice Section 5.4's effects on an ordinary buy.
    function test_buyMovesTheReserveTheSoldCounterAndTheBuyersBalance() public {
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        (uint256 quotedOut, uint256 quotedToCurve, uint256 quotedFee, uint256 quotedRefund) =
            curve.quoteBuy(1 ether);

        uint256 balanceBefore = TRADER.balance;
        vm.prank(TRADER);
        uint256 tokensOut = curve.buy{value: 1 ether}(0, vm.getBlockTimestamp());

        assertEq(tokensOut, quotedOut, "the quote is what the trade does");
        assertEq(quotedRefund, 0, "no refund on an ordinary buy");
        assertEq(curve.tokensSold(), tokensOut, "tokensSold");
        assertEq(curve.ethReserve(), quotedToCurve, "ethReserve");
        assertEq(token.balanceOf(TRADER), tokensOut, "the buyer holds the tokens");
        assertEq(
            token.balanceOf(address(curve)),
            PledrinConstants.TOTAL_SUPPLY - tokensOut,
            "Invariant 5"
        );
        assertEq(balanceBefore - TRADER.balance, 1 ether, "the buyer paid exactly msg.value");
        assertEq(quotedToCurve + quotedFee, 1 ether, "every wei is accounted for");
        assertEq(
            uint256(curve.creatorFeeEth()) + curve.protocolFeeEth() + curve.protectionEth(),
            quotedFee,
            "Invariant 14 on a buy"
        );
    }

    /// @notice The `Bought` and `FeeAccrued` events carry the numbers an indexer needs.
    function test_buyEmitsBoughtAndFeeAccrued() public {
        (BondingCurve curve,) = createDefaultLaunch();
        (uint256 tokensOut, uint256 ethToCurve, uint256 fee,) = curve.quoteBuy(1 ether);
        (uint256 creatorCut, uint256 protocolCut, uint256 protectionCut) =
            CurveMath.splitFee(fee, UNPLEDGED_CREATOR_BPS, UNPLEDGED_PROTOCOL_BPS);

        vm.expectEmit(true, true, false, true, address(curve));
        // A buy only runs in `Live`, where every bucket still has a payout path, so
        // `reserveCut` is zero and the three cuts carry the whole fee.
        emit IBondingCurve.FeeAccrued(address(curve), creatorCut, protocolCut, protectionCut, 0);
        vm.expectEmit(true, true, false, true, address(curve));
        emit IBondingCurve.Bought(
            address(curve), TRADER, 1 ether, ethToCurve, tokensOut, fee, 0, tokensOut, ethToCurve
        );
        vm.prank(TRADER);
        curve.buy{value: 1 ether}(0, vm.getBlockTimestamp());
    }

    /// @notice Invariant 11: a buy that would deliver less than the caller asked for
    /// reverts, which is the mitigation for the donation front-run of section 5.7.
    function test_buyRevertsWhenTheQuoteIsBelowMinTokensOut() public {
        (BondingCurve curve,) = createDefaultLaunch();
        (uint256 tokensOut,,,) = curve.quoteBuy(1 ether);

        vm.prank(TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBondingCurve.SlippageExceeded.selector, tokensOut, tokensOut + 1
            )
        );
        curve.buy{value: 1 ether}(tokensOut + 1, vm.getBlockTimestamp());

        // Exactly the quote is accepted.
        vm.prank(TRADER);
        assertEq(
            curve.buy{value: 1 ether}(tokensOut, vm.getBlockTimestamp()), tokensOut, "at the quote"
        );
    }

    /// @notice A donation between quote and execution is exactly what `minTokensOut`
    /// exists for: the same buy now yields fewer tokens and the guarded call reverts.
    function test_buyWithSlippageGuardSurvivesADonationFrontRun() public {
        (BondingCurve curve,) = createDefaultLaunch();
        (uint256 quoted,,,) = curve.quoteBuy(1 ether);

        vm.prank(OTHER);
        curve.donate{value: 10 ether}();

        (uint256 afterDonation,,,) = curve.quoteBuy(1 ether);
        assertLt(afterDonation, quoted, "the donation raised the price");

        vm.prank(TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.SlippageExceeded.selector, afterDonation, quoted)
        );
        curve.buy{value: 1 ether}(quoted, vm.getBlockTimestamp());
    }

    /// @notice The caller's own deadline, one second past.
    function test_buyRevertsAfterTheCallersDeadline() public {
        (BondingCurve curve,) = createDefaultLaunch();

        vm.prank(TRADER);
        vm.expectRevert(IBondingCurve.DeadlinePassed.selector);
        curve.buy{value: 1 ether}(0, vm.getBlockTimestamp() - 1);

        // The current block time is still inside the deadline.
        vm.prank(TRADER);
        curve.buy{value: 1 ether}(0, vm.getBlockTimestamp());
    }

    /// @notice Invariant 32: the buy window closes at `gradDeadline`, exactly.
    function test_buyRevertsAtTheGraduationDeadlineAndSucceedsOneSecondBefore() public {
        (BondingCurve curve,) = createDefaultLaunch();

        vm.warp(curve.gradDeadline() - 1);
        vm.prank(TRADER);
        curve.buy{value: 1 ether}(0, vm.getBlockTimestamp());

        vm.warp(curve.gradDeadline());
        vm.prank(TRADER);
        vm.expectRevert(IBondingCurve.BuyWindowClosed.selector);
        curve.buy{value: 1 ether}(0, vm.getBlockTimestamp());
    }

    /// @notice `MIN_BUY_WEI`, one wei below and exactly at.
    function test_buyRevertsBelowTheMinimumAndSucceedsAtIt() public {
        (BondingCurve curve,) = createDefaultLaunch();

        vm.prank(TRADER);
        vm.expectRevert(IBondingCurve.BuyTooSmall.selector);
        curve.buy{value: PledrinConstants.MIN_BUY_WEI - 1}(0, vm.getBlockTimestamp());

        vm.prank(TRADER);
        assertGt(
            curve.buy{value: PledrinConstants.MIN_BUY_WEI}(0, vm.getBlockTimestamp()),
            0,
            "the minimum buy yields tokens"
        );
    }

    /// @notice A zero-value buy is rejected by the same bound.
    function test_buyRevertsOnZeroValue() public {
        (BondingCurve curve,) = createDefaultLaunch();

        vm.prank(TRADER);
        vm.expectRevert(IBondingCurve.BuyTooSmall.selector);
        curve.buy{value: 0}(0, vm.getBlockTimestamp());
    }

    /// @notice **Invariant 12.** The buy that reaches the cap sets `tokensSold` to exactly
    /// `CURVE_SUPPLY`, refunds the difference, and moves the launch to `Graduating`.
    function test_theBuyThatReachesTheCapClipsRefundsAndFreezesTheCurve() public {
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        buy(curve, TRADER, 3 ether);

        uint256 value = 100 ether;
        (uint256 quotedOut, uint256 quotedToCurve, uint256 quotedFee, uint256 quotedRefund) =
            curve.quoteBuy(value);
        uint256 soldBefore = curve.tokensSold();

        vm.deal(TRADER, value);
        vm.prank(TRADER);
        uint256 tokensOut = curve.buy{value: value}(0, vm.getBlockTimestamp());

        assertEq(soldBefore + tokensOut, PledrinConstants.CURVE_SUPPLY, "exactly the cap");
        assertEq(tokensOut, quotedOut, "the quote matches");
        assertEq(TRADER.balance, quotedRefund, "the refund reached the buyer");
        assertEq(quotedToCurve + quotedFee + quotedRefund, value, "Invariant 12's accounting");
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduating), "Graduating");
        assertEq(curve.capReachedAt(), vm.getBlockTimestamp(), "capReachedAt");
        assertEq(
            token.balanceOf(address(curve)),
            PledrinConstants.TOTAL_SUPPLY - PledrinConstants.CURVE_SUPPLY,
            "only the LP supply is left in the curve"
        );
    }

    /// @notice **Invariant 13.** At the cap the reserve covers `R_target`, with the
    /// accumulated rounding sitting above it rather than below.
    function test_theReserveAtTheCapCoversTheTarget() public {
        (BondingCurve curve,) = createDefaultLaunch();
        buyToCap(curve);

        assertGe(curve.ethReserve(), curve.ethTarget(), "Invariant 13");
        assertGe(
            curve.ethReserve(),
            PledrinConstants.ETH_TARGET_MULTIPLE * uint256(curve.virtualEthReserve()),
            "Invariant 13 stated as 8 * vE0"
        );
    }

    /// @notice The `CapReached` event fires once, on the buy that reaches the cap.
    function test_capReachedIsEmittedOnce() public {
        (BondingCurve curve,) = createDefaultLaunch();

        vm.recordLogs();
        buyToCap(curve);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        bytes32 topic = keccak256("CapReached(address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) found++;
        }
        assertEq(found, 1, "CapReached fires exactly once");
    }

    /// @notice Invariant 32: no buy in any state but `Live`.
    function test_buyRevertsInEveryStateButLive() public {
        (BondingCurve graduating,) = createLaunchAtCap();
        vm.prank(TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBondingCurve.WrongState.selector, IBondingCurve.State.Graduating
            )
        );
        graduating.buy{value: 1 ether}(0, vm.getBlockTimestamp());

        vm.prank(GRADUATOR);
        graduating.graduate();
        vm.prank(TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Graduated)
        );
        graduating.buy{value: 1 ether}(0, vm.getBlockTimestamp());

        (BondingCurve expired,) = createDefaultLaunch();
        buy(expired, TRADER, 1 ether);
        vm.warp(expired.gradDeadline());
        expired.expire();
        vm.prank(TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Expired)
        );
        expired.buy{value: 1 ether}(0, vm.getBlockTimestamp());
    }

    /// @notice **Invariant 10.** Pricing reads storage only, so ETH and tokens forced into
    /// the curve change no quote. The curve's `receive` refuses direct ETH, so the force
    /// uses `vm.deal`, which is the strongest version of the attack: a balance that no
    /// code path created.
    function test_forceFedEthAndTokensChangeNoPrice() public {
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        buy(curve, TRADER, 1 ether);

        (uint256 quotedOut,,,) = curve.quoteBuy(1 ether);
        (uint256 quotedGross,,) = curve.quoteSell(1e18);
        uint256 reserveBefore = curve.ethReserve();
        uint256 soldBefore = curve.tokensSold();

        // Both amounts are read into locals first: a `vm.prank` applies to the next call,
        // and an argument that is itself an external call would consume it.
        uint256 forcedEth = address(curve).balance + 500 ether;
        uint256 forcedTokens = token.balanceOf(TRADER) / 2;
        vm.deal(address(curve), forcedEth);
        vm.prank(TRADER);
        token.transfer(address(curve), forcedTokens);

        (uint256 quotedOutAfter,,,) = curve.quoteBuy(1 ether);
        (uint256 quotedGrossAfter,,) = curve.quoteSell(1e18);
        assertEq(quotedOutAfter, quotedOut, "Invariant 10: the buy quote is unchanged");
        assertEq(quotedGrossAfter, quotedGross, "Invariant 10: the sell quote is unchanged");
        assertEq(curve.ethReserve(), reserveBefore, "ethReserve is storage, not a balance");
        assertEq(curve.tokensSold(), soldBefore, "tokensSold is storage, not a balance");

        vm.prank(TRADER);
        assertEq(
            curve.buy{value: 1 ether}(quotedOut, vm.getBlockTimestamp()),
            quotedOut,
            "the buy executes at the unchanged quote"
        );
    }

    /// @notice The curve's `receive` refuses ETH from anyone but the PositionManager, so a
    /// user cannot lose ETH by sending it where `donate` belongs.
    function test_directEthToTheCurveIsRejected() public {
        (BondingCurve curve,) = createDefaultLaunch();

        vm.prank(TRADER);
        (bool ok, bytes memory ret) = address(curve).call{value: 1 ether}("");
        assertFalse(ok, "direct ETH must not be accepted");
        assertEq(bytes4(ret), IBondingCurve.DirectEthNotAccepted.selector, "DirectEthNotAccepted");
    }

    /// @notice The PositionManager is the one sender the curve's `receive` accepts, because
    /// a graduation mint sweeps its unspent ETH back.
    function test_thePositionManagerMaySendTheCurveEth() public {
        (BondingCurve curve,) = createDefaultLaunch();

        vm.deal(address(positionManager), 1 ether);
        vm.prank(address(positionManager));
        (bool ok,) = address(curve).call{value: 1 ether}("");
        assertTrue(ok, "the PositionManager's sweep is accepted");
        assertEq(curve.ethReserve(), 0, "and it changes no price");
    }

    /// @notice Invariant 55: `buy` holds a reentrancy guard. The clipped buy's refund is
    /// the only ETH a buy sends, so it is the only place to re-enter from, and the guard
    /// turns the re-entry into a failed refund rather than a second trade.
    function test_buyCannotBeReenteredFromTheRefund() public {
        (BondingCurve curve,) = createDefaultLaunch();
        ReentrantBuyer attacker = new ReentrantBuyer();
        vm.deal(address(attacker), 100 ether);

        vm.expectRevert();
        attacker.buy{value: 0}(IBondingCurve(address(curve)), 100 ether);

        assertEq(curve.tokensSold(), 0, "no trade happened");
        assertEq(curve.ethReserve(), 0, "no ETH reached the reserve");
    }

    /// @notice A buy that would yield no tokens is rejected with `ZeroAmount` rather than
    /// taking the buyer's ETH for nothing.
    /// @dev The only way a quote yields zero is a curve with no supply left, and reaching
    /// the cap moves the launch to `Graduating`, where the state check fires first. The
    /// branch is therefore defensive, and the only way to exercise it is to put `state`
    /// back to `Live` by hand. `state` shares its slot with `protectionEth`,
    /// `capReachedAt` and `bondState`, so the write clears one byte and the assertions
    /// show it touched nothing else.
    function test_buyRevertsWhenTheQuoteYieldsNoTokens() public {
        (BondingCurve curve,) = createDefaultLaunch();
        buyToCap(curve);

        uint256 protectionBefore = curve.protectionEth();
        bytes32 slot = bytes32(uint256(2));
        bytes32 word = vm.load(address(curve), slot);
        vm.store(address(curve), slot, word & ~bytes32(uint256(0xff) << 192));

        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Live), "forced back to Live");
        assertEq(curve.protectionEth(), protectionBefore, "the write hit only the state byte");
        assertEq(curve.tokensSold(), PledrinConstants.CURVE_SUPPLY, "still at the cap");

        (uint256 quoted,,, uint256 refund) = curve.quoteBuy(1 ether);
        assertEq(quoted, 0, "there is nothing left to sell");
        assertEq(refund, 1 ether, "so the whole value would be refunded");

        vm.prank(TRADER);
        vm.expectRevert(IBondingCurve.ZeroAmount.selector);
        curve.buy{value: 1 ether}(0, vm.getBlockTimestamp());
    }

    /// @notice In the ordinary case the same guard is unreachable because the state check
    /// fires first: a launch at the cap is `Graduating`.
    function test_aBuyAtTheCapIsRefusedByTheStateCheck() public {
        (BondingCurve curve,) = createDefaultLaunch();
        buyToCap(curve);

        vm.prank(TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBondingCurve.WrongState.selector, IBondingCurve.State.Graduating
            )
        );
        curve.buy{value: PledrinConstants.MIN_BUY_WEI}(0, vm.getBlockTimestamp());
    }

    /// @notice Buys are monotone in value and never oversell the supply, at every
    /// permitted reserve. Invariants 1, 6 and 13 together, by fuzz over the whole trade.
    function testFuzz_buysStayInsideTheSupplyAndKeepTheProductNonDecreasing(
        uint128 vE0,
        uint96 first,
        uint96 second
    ) public {
        ILaunchFactory.LaunchParams memory params = defaultParams();
        params.virtualEthReserve = uint128(
            bound(
                vE0,
                PledrinConstants.MIN_VIRTUAL_ETH_RESERVE,
                PledrinConstants.MAX_VIRTUAL_ETH_RESERVE
            )
        );
        (BondingCurve curve,) = createLaunch(params);

        uint256 k = curveK(curve);
        assertEq(curveProduct(curve), k, "the product starts at K");

        uint256 firstValue = bound(first, PledrinConstants.MIN_BUY_WEI, 2000 ether);
        vm.deal(TRADER, firstValue);
        vm.prank(TRADER);
        curve.buy{value: firstValue}(0, vm.getBlockTimestamp());
        assertGe(curveProduct(curve), k, "Invariant 1 after the first buy");
        assertLe(curve.tokensSold(), PledrinConstants.CURVE_SUPPLY, "Invariant 6");

        if (curve.state() != IBondingCurve.State.Live) return;

        uint256 secondValue = bound(second, PledrinConstants.MIN_BUY_WEI, 2000 ether);
        vm.deal(TRADER, secondValue);
        vm.prank(TRADER);
        curve.buy{value: secondValue}(0, vm.getBlockTimestamp());
        assertGe(curveProduct(curve), k, "Invariant 1 after the second buy");
        assertLe(curve.tokensSold(), PledrinConstants.CURVE_SUPPLY, "Invariant 6");

        if (curve.tokensSold() == PledrinConstants.CURVE_SUPPLY) {
            assertGe(curve.ethReserve(), curve.ethTarget(), "Invariant 13");
        }
    }
}
