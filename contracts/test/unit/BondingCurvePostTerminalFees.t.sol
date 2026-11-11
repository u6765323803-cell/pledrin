// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {CurveMath} from "src/libraries/CurveMath.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {PledrinTestBase} from "../base/PledrinTestBase.sol";

/// @title Where a fee charged after a terminal transition actually goes
/// @notice Covers `docs/SPEC.md` section 6.3 and **Invariant 59**, with Invariants 1, 4,
/// 14 and 17 asserted alongside on every trade here.
/// @dev `sell` stays open in `Expired` and `Stalled` and keeps charging the full fee, but
/// two of the three buckets have lost their payout path by then: `claimCreatorFees`
/// reverts in `Expired`, and the protection bucket has no claim function at all and is
/// distributed only by a transition that has already happened. Section 6.3's table sends
/// those shares to `ethReserve` instead.
///
/// The destination is what this file asserts, directly, bucket by bucket. The rest of the
/// suite asserts conservation — that no wei is created or lost — and conservation alone
/// cannot tell the correct destination from a wrong one, because `ethReserve` and the three
/// buckets are all obligations of the same contract: an implementation that paid a
/// redirected share into, say, the protocol bucket would conserve every wei and strand none
/// of it, and would still be wrong.
///
/// Two of the assertions here would fail against the obvious implementation of the
/// redirect rather than against an obviously broken one, which is why they are spelled out:
///
/// - `Sold.ethReserve` is the reserve **after** the redirect. Accruing the fee and then
///   writing `ethReserve - ethGross` would leave the log short by the redirected amount on
///   every post-terminal sell, and an indexer following the reserve through events would
///   drift further from the chain on each one while every on-chain balance stayed correct.
/// - `FeeAccrued`'s four amounts sum to the trade's fee in every state. Reporting the
///   redirected share as though it had reached its bucket would reconcile arithmetically
///   and name the wrong destination.
contract BondingCurvePostTerminalFeesTest is PledrinTestBase {
    /// @dev The four balances a fee can move between, read in one go so a trade's effect is
    /// a difference of two snapshots.
    struct Balances {
        uint256 creator;
        uint256 protocol;
        uint256 protection;
        uint256 reserve;
    }

    // ------------------------------------------------------------------
    // Expired: the creator share and the protection share both go to the reserve
    // ------------------------------------------------------------------

    /// @notice **Invariant 59 in `Expired`.** A sell adds `creatorCut + protectionCut` to
    /// `ethReserve` and leaves `creatorFeeEth` and `protectionEth` untouched.
    /// @dev Both buckets are zero in `Expired` — `expire` forfeits them into the reserve —
    /// so "unchanged" here is the strongest form of the statement: neither bucket ever
    /// becomes non-zero again, which is exactly the stranded wei the redirect prevents.
    /// The test also sells twice, because a redirect that only worked on the first
    /// post-terminal trade would pass a single-trade check.
    function test_aSellInExpiredAddsTheCreatorAndProtectionSharesToTheReserve() public {
        (BondingCurve curve, IERC20 token) = _expiredLaunch();

        assertEq(curve.creatorFeeEth(), 0, "expire forfeited the creator bucket");
        assertEq(curve.protectionEth(), 0, "and the protection bucket");

        for (uint256 i = 0; i < 2; i++) {
            uint256 amount = token.balanceOf(TRADER) / 4;
            (uint256 ethGross, uint256 fee,) = curve.quoteSell(amount);
            (uint256 creatorCut, uint256 protocolCut, uint256 protectionCut) = _cuts(curve, fee);
            assertGt(creatorCut, 0, "a creator share worth redirecting");
            assertGt(protectionCut, 0, "and a protection share");

            Balances memory before = _balances(curve);
            sell(curve, TRADER, amount);
            Balances memory now_ = _balances(curve);

            assertEq(now_.creator, 0, "Invariant 59: creatorFeeEth is unchanged in Expired");
            assertEq(now_.protection, 0, "Invariant 59: protectionEth is unchanged in Expired");
            assertEq(
                now_.protocol - before.protocol, protocolCut, "the protocol share still accrues"
            );
            assertEq(
                now_.reserve,
                before.reserve - ethGross + creatorCut + protectionCut,
                "Invariant 59: both closed shares land in ethReserve"
            );
            // Section 6.3's consequence for Invariant 4: the reserve falls by less than the
            // gross exactly because the redirect is folded into the same write.
            assertEq(
                before.reserve - now_.reserve,
                ethGross - creatorCut - protectionCut,
                "the reserve fell by the gross less the redirect"
            );
            assertGe(curveProduct(curve), curveK(curve), "Invariant 1 survives the redirect");
        }

        // The buckets the redirect emptied have no reachable claim in `Expired`, which is
        // the whole reason the shares were moved.
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Expired)
        );
        curve.claimCreatorFees();
    }

    // ------------------------------------------------------------------
    // Stalled: only the protection share moves
    // ------------------------------------------------------------------

    /// @notice **Invariant 59 in `Stalled`.** Only the protection share is redirected. The
    /// creator's bucket keeps growing, because `claimCreatorFees` is open in `Stalled`.
    function test_aSellInStalledRedirectsOnlyTheProtectionShare() public {
        (BondingCurve curve, IERC20 token) = _stalledLaunch();

        uint256 creatorAtTransition = curve.creatorFeeEth();
        assertGt(creatorAtTransition, 0, "the creator bucket survived abortGraduation");
        assertEq(curve.protectionEth(), 0, "which donated the protection bucket to the reserve");

        uint256 creatorAccrued;
        for (uint256 i = 0; i < 2; i++) {
            uint256 amount = token.balanceOf(TRADER) / 4;
            (uint256 ethGross, uint256 fee,) = curve.quoteSell(amount);
            (uint256 creatorCut, uint256 protocolCut, uint256 protectionCut) = _cuts(curve, fee);
            assertGt(protectionCut, 0, "a protection share worth redirecting");

            Balances memory before = _balances(curve);
            sell(curve, TRADER, amount);
            Balances memory now_ = _balances(curve);

            assertEq(
                now_.creator - before.creator,
                creatorCut,
                "Invariant 59: the creator share still accrues in Stalled"
            );
            assertEq(now_.protection, 0, "Invariant 59: protectionEth is unchanged in Stalled");
            assertEq(
                now_.protocol - before.protocol, protocolCut, "the protocol share still accrues"
            );
            assertEq(
                now_.reserve,
                before.reserve - ethGross + protectionCut,
                "Invariant 59: only the protection share lands in ethReserve"
            );
            assertGe(curveProduct(curve), curveK(curve), "Invariant 1 survives the redirect");
            creatorAccrued += creatorCut;
        }

        assertEq(
            curve.creatorFeeEth(),
            creatorAtTransition + creatorAccrued,
            "the creator bucket grew by every creator share charged in Stalled"
        );

        // And it is reachable, which is why it was not redirected.
        uint256 claimable = curve.creatorFeeEth();
        uint256 creatorBalanceBefore = CREATOR.balance;
        assertEq(curve.claimCreatorFees(), claimable, "claimable in Stalled");
        assertEq(CREATOR.balance - creatorBalanceBefore, claimable, "and paid to the creator");
    }

    // ------------------------------------------------------------------
    // The protocol share, which never moves
    // ------------------------------------------------------------------

    /// @notice Section 6.3's unchanged column: `claimProtocolFees` has no state gate, so the
    /// protocol share accrues to `protocolFeeEth` in both terminal states and is still
    /// claimable there.
    function test_theProtocolBucketGrowsNormallyInBothTerminalStates() public {
        (BondingCurve expired, IERC20 expiredToken) = _expiredLaunch();
        (BondingCurve stalled, IERC20 stalledToken) = _stalledLaunch();

        uint256 expiredBucket = expired.protocolFeeEth();
        uint256 stalledBucket = stalled.protocolFeeEth();

        (, uint256 expiredFee,) = expired.quoteSell(expiredToken.balanceOf(TRADER) / 4);
        (, uint256 expiredProtocolCut,) = _cuts(expired, expiredFee);
        sell(expired, TRADER, expiredToken.balanceOf(TRADER) / 4);

        (, uint256 stalledFee,) = stalled.quoteSell(stalledToken.balanceOf(TRADER) / 4);
        (, uint256 stalledProtocolCut,) = _cuts(stalled, stalledFee);
        sell(stalled, TRADER, stalledToken.balanceOf(TRADER) / 4);

        assertGt(expiredProtocolCut, 0, "a protocol share worth asserting");
        assertEq(
            expired.protocolFeeEth() - expiredBucket,
            expiredProtocolCut,
            "Invariant 59: the protocol share accrues in Expired"
        );
        assertEq(
            stalled.protocolFeeEth() - stalledBucket,
            stalledProtocolCut,
            "Invariant 59: the protocol share accrues in Stalled"
        );

        uint256 treasuryBefore = TREASURY.balance;
        uint256 paid = expired.claimProtocolFees() + stalled.claimProtocolFees();
        assertEq(TREASURY.balance - treasuryBefore, paid, "and is claimable in both");
        assertGt(paid, 0, "by a non-zero amount");
    }

    // ------------------------------------------------------------------
    // The event an indexer reads
    // ------------------------------------------------------------------

    /// @notice **`FeeAccrued`'s four amounts sum to the trade's fee in every state.** In
    /// `Live` the fourth is zero; in `Expired` and `Stalled` it is exactly the redirect, and
    /// each of the first three is exactly what its bucket received.
    /// @dev Asserted against the `fee` field of the same trade's `Bought` or `Sold`, which
    /// is the number section 6.3 tells a reader to reconcile against, rather than against a
    /// quote taken beforehand.
    function test_theFourFeeAmountsSumToTheTradeFeeInLiveExpiredAndStalled() public {
        // Live, on both sides of the book.
        (BondingCurve live, IERC20 liveToken) = createDefaultLaunch();
        vm.recordLogs();
        buy(live, TRADER, 1 ether);
        (uint256[4] memory cuts, uint256 fee, uint256 reserve) = _tradeLogs(address(live), false);
        assertEq(cuts[3], 0, "no redirect on a Live buy");
        assertEq(cuts[0] + cuts[1] + cuts[2] + cuts[3], fee, "Invariant 14 through the log");
        assertEq(reserve, live.ethReserve(), "Bought.ethReserve is the reserve after the buy");

        vm.recordLogs();
        sell(live, TRADER, liveToken.balanceOf(TRADER) / 4);
        (cuts, fee, reserve) = _tradeLogs(address(live), true);
        assertEq(cuts[3], 0, "no redirect on a Live sell");
        assertEq(cuts[0] + cuts[1] + cuts[2] + cuts[3], fee, "Invariant 14 through the log");
        assertEq(reserve, live.ethReserve(), "Sold.ethReserve is the reserve after the sell");

        // Expired: the first and third amounts are zero and the fourth carries both.
        (BondingCurve expired, IERC20 expiredToken) = _expiredLaunch();
        vm.recordLogs();
        sell(expired, TRADER, expiredToken.balanceOf(TRADER) / 4);
        (cuts, fee, reserve) = _tradeLogs(address(expired), true);
        (uint256 creatorCut, uint256 protocolCut, uint256 protectionCut) = _cuts(expired, fee);
        assertEq(cuts[0], 0, "FeeAccrued reports the creator bucket as receiving nothing");
        assertEq(cuts[1], protocolCut, "and the protocol bucket as receiving its share");
        assertEq(cuts[2], 0, "and the protection bucket as receiving nothing");
        assertEq(cuts[3], creatorCut + protectionCut, "reserveCut is both redirected shares");
        assertEq(cuts[0] + cuts[1] + cuts[2] + cuts[3], fee, "the four amounts sum to the fee");
        assertEq(reserve, expired.ethReserve(), "Sold.ethReserve is the post-redirect reserve");

        // Stalled: only the third amount is zero.
        (BondingCurve stalled, IERC20 stalledToken) = _stalledLaunch();
        vm.recordLogs();
        sell(stalled, TRADER, stalledToken.balanceOf(TRADER) / 4);
        (cuts, fee, reserve) = _tradeLogs(address(stalled), true);
        (creatorCut, protocolCut, protectionCut) = _cuts(stalled, fee);
        assertEq(cuts[0], creatorCut, "the creator bucket still receives its share in Stalled");
        assertEq(cuts[1], protocolCut, "and the protocol bucket its own");
        assertEq(cuts[2], 0, "the protection bucket receives nothing");
        assertEq(cuts[3], protectionCut, "reserveCut is the protection share alone");
        assertEq(cuts[0] + cuts[1] + cuts[2] + cuts[3], fee, "the four amounts sum to the fee");
        assertEq(reserve, stalled.ethReserve(), "Sold.ethReserve is the post-redirect reserve");
    }

    /// @notice **`Sold.ethReserve` is the post-redirect reserve.** The redirect is folded in
    /// before the single reserve write, so the log equals the chain and an indexer following
    /// `ethReserve` through events never drifts.
    /// @dev The assertion that matters is the last one in each block: the logged reserve is
    /// *not* the pre-redirect figure. Without it this test would also pass against an
    /// implementation that accrued the redirect after logging the reserve, which is the
    /// shape the obvious implementation takes and which would understate the reserve by the
    /// redirected amount on every post-terminal sell, cumulatively.
    function test_soldCarriesThePostRedirectReserve() public {
        (BondingCurve expired, IERC20 expiredToken) = _expiredLaunch();
        uint256 amount = expiredToken.balanceOf(TRADER) / 4;
        (uint256 ethGross, uint256 fee,) = expired.quoteSell(amount);
        (uint256 creatorCut,, uint256 protectionCut) = _cuts(expired, fee);
        uint256 reserveBefore = expired.ethReserve();

        vm.recordLogs();
        sell(expired, TRADER, amount);
        (, uint256 loggedFee, uint256 loggedReserve) = _tradeLogs(address(expired), true);

        assertEq(loggedFee, fee, "the quoted fee is the fee the trade charged");
        assertEq(loggedReserve, expired.ethReserve(), "Sold.ethReserve equals the live reserve");
        assertEq(
            loggedReserve,
            reserveBefore - ethGross + creatorCut + protectionCut,
            "and it is the post-redirect value"
        );
        assertNotEq(
            loggedReserve, reserveBefore - ethGross, "not the value before the redirect was folded"
        );

        (BondingCurve stalled, IERC20 stalledToken) = _stalledLaunch();
        amount = stalledToken.balanceOf(TRADER) / 4;
        (ethGross, fee,) = stalled.quoteSell(amount);
        (,, protectionCut) = _cuts(stalled, fee);
        reserveBefore = stalled.ethReserve();

        vm.recordLogs();
        sell(stalled, TRADER, amount);
        (, loggedFee, loggedReserve) = _tradeLogs(address(stalled), true);

        assertEq(loggedFee, fee, "the quoted fee is the fee the trade charged");
        assertEq(loggedReserve, stalled.ethReserve(), "Sold.ethReserve equals the live reserve");
        assertEq(
            loggedReserve,
            reserveBefore - ethGross + protectionCut,
            "and it is the post-redirect value"
        );
        assertNotEq(
            loggedReserve, reserveBefore - ethGross, "not the value before the redirect was folded"
        );
    }

    // ------------------------------------------------------------------
    // By fuzz, over every accepted sell size in both terminal states
    // ------------------------------------------------------------------

    /// @notice **Invariant 59 by fuzz.** For any accepted sell in either terminal state, the
    /// three buckets move by exactly what section 6.3's table says they move by, the reserve
    /// absorbs the rest of the fee, and nothing is created or lost.
    /// @dev Written over the whole accepted range rather than a chosen size because the
    /// redirect is a sum of two floored products and the residual: at a small enough trade
    /// the fee is a handful of wei and one or two of the three shares round to zero, which
    /// is where an off-by-one in the fold would hide. A trade the curve refuses is asserted
    /// to be refused rather than skipped, so no fuzz input is wasted.
    function testFuzz_everyTerminalSellSendsTheClosedSharesToTheReserve(
        uint256 amountSeed,
        bool stall
    ) public {
        (BondingCurve curve, IERC20 token) = stall ? _stalledLaunch() : _expiredLaunch();
        bool expired = !stall;

        uint256 amount = bound(amountSeed, 1, token.balanceOf(TRADER));
        (uint256 ethGross, uint256 fee, uint256 ethOut) = curve.quoteSell(amount);
        if (ethGross == 0 || ethOut == 0) {
            vm.prank(TRADER);
            token.approve(address(curve), amount);
            vm.prank(TRADER);
            vm.expectRevert(IBondingCurve.ZeroAmount.selector);
            curve.sell(amount, 0, vm.getBlockTimestamp());
            return;
        }

        (uint256 creatorCut, uint256 protocolCut, uint256 protectionCut) = _cuts(curve, fee);
        uint256 expectedRedirect = expired ? creatorCut + protectionCut : protectionCut;

        Balances memory before = _balances(curve);
        sell(curve, TRADER, amount);
        Balances memory now_ = _balances(curve);

        assertEq(
            now_.creator - before.creator, expired ? 0 : creatorCut, "the creator bucket's delta"
        );
        assertEq(now_.protocol - before.protocol, protocolCut, "the protocol bucket's delta");
        assertEq(now_.protection, before.protection, "the protection bucket never moves");
        assertEq(now_.reserve, before.reserve - ethGross + expectedRedirect, "the reserve's delta");

        // Conservation across all four destinations: every wei of the fee is in exactly one
        // of them (Invariants 14 and 17), and the redirect created none of it.
        assertEq(
            (now_.creator - before.creator) + (now_.protocol - before.protocol)
                + (now_.protection - before.protection) + expectedRedirect,
            fee,
            "Invariant 14: the four destinations sum to the fee"
        );
        assertEq(ethOut + fee, ethGross, "the seller was paid the gross less the fee");
        assertGe(curveProduct(curve), curveK(curve), "Invariant 1 survives the redirect");
        assertGe(
            address(curve).balance, obligations(curve), "Invariant 3: the obligations are covered"
        );
    }

    // ------------------------------------------------------------------
    // Fixtures and log readers
    // ------------------------------------------------------------------

    /// @dev A launch in `Expired` whose `TRADER` holds tokens to sell back.
    function _expiredLaunch() private returns (BondingCurve curve, IERC20 token) {
        (curve, token) = createDefaultLaunch();
        buy(curve, TRADER, 1 ether);
        vm.warp(curve.gradDeadline());
        curve.expire();
    }

    /// @dev A launch in `Stalled`, reached the only way it can be: to the cap, then past
    /// `GRAD_GRACE` without a graduation.
    function _stalledLaunch() private returns (BondingCurve curve, IERC20 token) {
        (curve, token) = createLaunchAtCap();
        vm.warp(curve.capReachedAt() + PledrinConstants.GRAD_GRACE);
        curve.abortGraduation();
    }

    function _balances(BondingCurve curve) private view returns (Balances memory) {
        return Balances({
            creator: curve.creatorFeeEth(),
            protocol: curve.protocolFeeEth(),
            protection: curve.protectionEth(),
            reserve: curve.ethReserve()
        });
    }

    /// @dev The split of `fee` this launch's own share parameters produce, so the expected
    /// numbers come from the configuration under test rather than from a copied literal.
    function _cuts(BondingCurve curve, uint256 fee)
        private
        view
        returns (uint256 creatorCut, uint256 protocolCut, uint256 protectionCut)
    {
        return CurveMath.splitFee(fee, curve.creatorShareBps(), curve.protocolShareBps());
    }

    /// @dev One trade's `FeeAccrued` amounts, in event order, together with the `fee` and
    /// `ethReserve` fields of the `Bought` or `Sold` log of the same trade. Both come out of
    /// one `getRecordedLogs` call because that cheatcode drains the buffer.
    function _tradeLogs(address launch, bool isSell)
        private
        view
        returns (uint256[4] memory cuts, uint256 fee, uint256 reserve)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 feeTopic = keccak256("FeeAccrued(address,uint256,uint256,uint256,uint256)");
        bytes32 tradeTopic = isSell
            ? keccak256("Sold(address,address,uint256,uint256,uint256,uint256,uint256,uint256)")
            : keccak256(
                "Bought(address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
            );

        bool sawFee;
        bool sawTrade;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != launch) continue;
            if (logs[i].topics[0] == feeTopic) {
                (cuts[0], cuts[1], cuts[2], cuts[3]) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                sawFee = true;
            } else if (logs[i].topics[0] == tradeTopic && isSell) {
                (,,, fee,, reserve) = abi.decode(
                    logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256)
                );
                sawTrade = true;
            } else if (logs[i].topics[0] == tradeTopic) {
                (,,, fee,,, reserve) = abi.decode(
                    logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256)
                );
                sawTrade = true;
            }
        }
        require(sawFee, "no FeeAccrued event");
        require(sawTrade, "no Bought or Sold event");
    }
}
