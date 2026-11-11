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
import {ReentrantClaimer, RevertingReceiver} from "../mocks/Actors.sol";

/// @title Fee accrual, the three buckets, `donate`, and the four claims
/// @notice Covers `docs/SPEC.md` sections 5.7, 6, 6.1 and 6.2, and Invariants 9, 14, 17,
/// 18, 20, 44, 52, 55 and 58.
/// @dev The two properties worth attacking here are that no wei is created or lost in a
/// split, and that the creator cannot reach a single wei of a launch before it delivers.
/// Both are asserted on every trade of a fuzzed sequence rather than once.
contract BondingCurveFeesTest is PledrinTestBase {
    /// @notice Section 6: a pledged launch gives the creator a larger share of the same
    /// total fee, and the trader pays the same either way.
    function test_pledgedAndUnpledgedSplitTheSameTotalDifferently() public {
        (BondingCurve unpledged,) = createDefaultLaunch();
        (BondingCurve pledgedCurve,) = createPledgedLaunch();

        (,, uint256 unpledgedFee,) = unpledged.quoteBuy(1 ether);
        (,, uint256 pledgedFee,) = pledgedCurve.quoteBuy(1 ether);
        assertEq(unpledgedFee, pledgedFee, "the trader pays the same fee either way");

        buy(unpledged, TRADER, 1 ether);
        buy(pledgedCurve, TRADER, 1 ether);

        assertGt(
            pledgedCurve.creatorFeeEth(),
            unpledged.creatorFeeEth(),
            "a bonded launch pays its creator more of the same fee"
        );
        assertLt(
            pledgedCurve.protectionEth(), unpledged.protectionEth(), "and holder protection less"
        );
    }

    /// @notice **Invariant 14 through the contract.** The three buckets sum to the fee the
    /// trade charged, on both sides of the book.
    function test_theThreeBucketsSumToTheFeeOnEveryTrade() public {
        (BondingCurve curve,) = createDefaultLaunch();

        (,, uint256 buyFee,) = curve.quoteBuy(1 ether);
        uint256 bought = buy(curve, TRADER, 1 ether);
        assertEq(_buckets(curve), buyFee, "Invariant 14 after the buy");

        (, uint256 sellFee,) = curve.quoteSell(bought / 2);
        sell(curve, TRADER, bought / 2);
        assertEq(_buckets(curve), buyFee + sellFee, "Invariant 14 after the sell");
    }

    /// @notice Invariant 17: the rounding remainder lands in holder protection, so the
    /// protection bucket is never smaller than its exact share.
    function test_theRemainderAlwaysLandsInTheProtectionBucket() public {
        (BondingCurve curve,) = createDefaultLaunch();

        // A value whose fee is indivisible by the share denominators.
        uint256 value = PledrinConstants.MIN_BUY_WEI + 7;
        (,, uint256 fee,) = curve.quoteBuy(value);
        (uint256 creatorCut, uint256 protocolCut, uint256 protectionCut) =
            CurveMath.splitFee(fee, UNPLEDGED_CREATOR_BPS, UNPLEDGED_PROTOCOL_BPS);

        buy(curve, TRADER, value);

        assertEq(curve.creatorFeeEth(), creatorCut, "creator");
        assertEq(curve.protocolFeeEth(), protocolCut, "protocol");
        assertEq(curve.protectionEth(), protectionCut, "protection");
        assertGe(
            protectionCut,
            (fee * UNPLEDGED_PROTECTION_BPS) / PledrinConstants.BPS_DENOMINATOR,
            "Invariant 17"
        );
    }

    /// @notice **Invariant 9.** `donate` adds exactly `msg.value` to the reserve and
    /// touches nothing else.
    function test_donateMovesOnlyTheReserve() public {
        (BondingCurve curve,) = createDefaultLaunch();
        buy(curve, TRADER, 1 ether);

        uint256 reserveBefore = curve.ethReserve();
        uint256 soldBefore = curve.tokensSold();
        uint256 creatorBefore = curve.creatorFeeEth();
        uint256 protocolBefore = curve.protocolFeeEth();
        uint256 protectionBefore = curve.protectionEth();
        uint256 deadlineBefore = curve.gradDeadline();

        vm.expectEmit(true, true, false, true, address(curve));
        emit IBondingCurve.Donated(address(curve), OTHER, 3 ether, reserveBefore + 3 ether);
        vm.prank(OTHER);
        curve.donate{value: 3 ether}();

        assertEq(curve.ethReserve(), reserveBefore + 3 ether, "exactly msg.value");
        assertEq(curve.tokensSold(), soldBefore, "tokensSold untouched");
        assertEq(curve.creatorFeeEth(), creatorBefore, "creator bucket untouched");
        assertEq(curve.protocolFeeEth(), protocolBefore, "protocol bucket untouched");
        assertEq(curve.protectionEth(), protectionBefore, "protection bucket untouched");
        assertEq(curve.gradDeadline(), deadlineBefore, "no lifecycle field moved");
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Live), "state untouched");
    }

    /// @notice Section 5.7: a donation raises every holder's exit price and lowers every
    /// future buyer's token count.
    function test_donateRaisesTheExitPriceForHolders() public {
        (BondingCurve curve,) = createDefaultLaunch();
        uint256 bought = buy(curve, TRADER, 1 ether);

        (,, uint256 before) = curve.quoteSell(bought);
        vm.prank(OTHER);
        curve.donate{value: 1 ether}();
        (,, uint256 afterDonation) = curve.quoteSell(bought);

        assertGt(afterDonation, before, "the holder's exit is worth more");
    }

    /// @notice A zero donation is rejected.
    function test_donateRevertsOnZeroValue() public {
        (BondingCurve curve,) = createDefaultLaunch();

        vm.prank(OTHER);
        vm.expectRevert(IBondingCurve.ZeroAmount.selector);
        curve.donate{value: 0}();
    }

    /// @notice Section 5.7: `donate` is open in every state but `Graduated`.
    function test_donateIsOpenEverywhereButAfterGraduation() public {
        (BondingCurve live,) = createDefaultLaunch();
        vm.prank(OTHER);
        live.donate{value: 1}();

        (BondingCurve graduating,) = createLaunchAtCap();
        vm.prank(OTHER);
        graduating.donate{value: 1}();

        (BondingCurve expired,) = createDefaultLaunch();
        buy(expired, TRADER, 1 ether);
        vm.warp(expired.gradDeadline());
        expired.expire();
        vm.prank(OTHER);
        expired.donate{value: 1}();

        (BondingCurve stalled,) = createLaunchAtCap();
        vm.warp(stalled.capReachedAt() + PledrinConstants.GRAD_GRACE);
        stalled.abortGraduation();
        vm.prank(OTHER);
        stalled.donate{value: 1}();

        vm.prank(GRADUATOR);
        graduating.graduate();
        vm.prank(OTHER);
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Graduated)
        );
        graduating.donate{value: 1}();
    }

    // ------------------------------------------------------------------
    // Claims
    // ------------------------------------------------------------------

    /// @notice **Invariant 20.** The creator cannot withdraw a single wei before the launch
    /// delivers: `claimCreatorFees` reverts in `Live` and in `Graduating`.
    function test_theCreatorCannotClaimBeforeTheLaunchDelivers() public {
        (BondingCurve curve,) = createPledgedLaunch();
        buy(curve, TRADER, 1 ether);
        assertGt(curve.creatorFeeEth(), 0, "fees have accrued");

        uint256 creatorBalance = CREATOR.balance;
        vm.prank(CREATOR);
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Live)
        );
        curve.claimCreatorFees();

        buyToCap(curve);
        vm.prank(CREATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBondingCurve.WrongState.selector, IBondingCurve.State.Graduating
            )
        );
        curve.claimCreatorFees();
        assertEq(CREATOR.balance, creatorBalance, "Invariant 20: nothing reached the creator");

        // And nothing else can pay them either: the bond is still held.
        vm.expectRevert(IBondingCurve.BondNotReturned.selector);
        curve.claimBond();
    }

    /// @notice After graduation the creator's bucket is claimable by anyone, and always to
    /// the creator.
    function test_creatorFeesAreClaimableAfterGraduationAndAlwaysPayTheCreator() public {
        (BondingCurve curve,) = createDefaultLaunch();
        buyToCap(curve);
        vm.prank(GRADUATOR);
        curve.graduate();

        uint256 accrued = curve.creatorFeeEth();
        uint256 before = CREATOR.balance;

        vm.expectEmit(true, true, false, true, address(curve));
        emit IBondingCurve.FeesClaimed(
            address(curve), CREATOR, IBondingCurve.FeeKind.Creator, accrued
        );
        vm.prank(OTHER);
        assertEq(curve.claimCreatorFees(), accrued, "the claim paid the bucket");

        assertEq(CREATOR.balance - before, accrued, "a stranger's claim still pays the creator");
        assertEq(curve.creatorFeeEth(), 0, "the bucket is empty");

        vm.expectRevert(IBondingCurve.NothingToClaim.selector);
        curve.claimCreatorFees();
    }

    /// @notice The creator's bucket is claimable in `Stalled` too, because the cap was
    /// delivered.
    function test_creatorFeesAreClaimableWhenStalled() public {
        (BondingCurve curve,) = createDefaultLaunch();
        buyToCap(curve);
        vm.warp(curve.capReachedAt() + PledrinConstants.GRAD_GRACE);
        curve.abortGraduation();

        assertGt(curve.claimCreatorFees(), 0, "claimable in Stalled");
    }

    /// @notice The protocol's bucket is claimable in any state, and only ever by the
    /// treasury the launch recorded.
    function test_protocolFeesAreClaimableInAnyStateAndOnlyPayTheRecordedTreasury() public {
        (BondingCurve curve,) = createDefaultLaunch();
        buy(curve, TRADER, 1 ether);

        uint256 accrued = curve.protocolFeeEth();
        assertGt(accrued, 0, "accrued");

        vm.prank(OTHER);
        assertEq(curve.claimProtocolFees(), accrued, "claimable while Live");
        assertEq(TREASURY.balance, accrued, "the treasury was paid");
        assertEq(curve.protocolFeeEth(), 0, "the bucket is empty");

        // A later change to factory configuration cannot redirect it.
        executeAfterDelay(
            address(factory),
            abi.encodeCall(ILaunchFactory.setProtocolTreasury, (OTHER)),
            bytes32("treasury")
        );
        buy(curve, TRADER, 1 ether);
        uint256 second = curve.protocolFeeEth();
        curve.claimProtocolFees();
        assertEq(TREASURY.balance, accrued + second, "still the launch's own treasury");
        assertEq(curve.protocolTreasury(), TREASURY, "Invariant 53");
    }

    /// @notice A bond that has already been claimed cannot be claimed again: `bondState`
    /// stays `Returned` forever, so the emptiness of the credit is what refuses the second
    /// claim, and it refuses it as `BondAlreadyClaimed`. This is the other half of
    /// Invariant 25, and the fourth row of Invariant 63's table: `Returned` with an empty
    /// credit can only mean a claim that already paid, which is why the refusal says so
    /// rather than telling the creator the bond has not been returned.
    function test_aReturnedBondCanOnlyBeClaimedOnce() public {
        (BondingCurve curve,) = createPledgedLaunch();
        buyToCap(curve);
        vm.prank(GRADUATOR);
        curve.graduate();

        assertEq(curve.claimBond(), 0.4 ether, "the bond was paid once");
        assertEq(curve.pendingBondWei(), 0, "and the credit is empty");
        assertEq(
            uint8(curve.bondState()),
            uint8(IBondingCurve.BondState.Returned),
            "the state stays Returned"
        );

        vm.expectRevert(IBondingCurve.BondAlreadyClaimed.selector);
        curve.claimBond();
        assertEq(CREATOR.balance, 20_000 ether - 0.409 ether + 0.4 ether, "paid exactly once");
    }

    /// @notice An empty bucket reverts rather than emitting a zero payment.
    /// @dev The bond is deliberately not one of these buckets. `claimBond` refuses by
    /// `bondState` and not by emptiness — a launch that never posted a bond has an empty
    /// credit but is not an empty bucket — so its four refusals are asserted together in
    /// `test_claimBondNamesTheBondStateThatRefusedIt` instead of here.
    function test_everyFeeClaimRevertsOnAnEmptyBucket() public {
        (BondingCurve curve,) = createDefaultLaunch();

        vm.expectRevert(IBondingCurve.NothingToClaim.selector);
        curve.claimProtocolFees();

        vm.expectRevert(IBondingCurve.NothingToClaim.selector);
        curve.claimBounty(OTHER);
    }

    /// @notice **Invariant 63.** `claimBond` gives exactly the refusal section 11.3's table
    /// assigns to the launch's `bondState`, and the four are asserted as one set so that a
    /// later collapse of any two of them back into a single error fails here.
    /// @dev Only one of the four is clearable, and the difference is what the caller acts
    /// on: `BondNotReturned` tells a creator to come back once the launch settles, while
    /// the other three tell them that no call they ever make will pay this bond. The
    /// clearable one is shown clearing on the same launch that gave it, so the test states
    /// which refusal is temporary rather than only which error each state returns.
    function test_claimBondNamesTheBondStateThatRefusedIt() public {
        // `None`: this launch posted no bond, and no path creates one afterwards.
        (BondingCurve unbonded,) = createDefaultLaunch();
        assertEq(
            uint8(unbonded.bondState()), uint8(IBondingCurve.BondState.None), "no bond was posted"
        );
        vm.expectRevert(IBondingCurve.NoBondPosted.selector);
        unbonded.claimBond();

        // `Bonded`: the bond is held against a launch that has not settled.
        (BondingCurve held,) = createPledgedLaunch();
        assertEq(uint8(held.bondState()), uint8(IBondingCurve.BondState.Bonded), "the bond is held");
        assertEq(held.bondHeldWei(), 0.4 ether, "and the ETH is on the bond account");
        vm.expectRevert(IBondingCurve.BondNotReturned.selector);
        held.claimBond();

        // The same launch, settled: the one clearable refusal becomes a payment.
        buyToCap(held);
        vm.prank(GRADUATOR);
        held.graduate();
        assertEq(held.claimBond(), 0.4 ether, "the clearable refusal cleared");

        // `Returned` with an empty credit: the bond has been paid, once.
        assertEq(uint8(held.bondState()), uint8(IBondingCurve.BondState.Returned), "still Returned");
        vm.expectRevert(IBondingCurve.BondAlreadyClaimed.selector);
        held.claimBond();

        // `Forfeited`: expiry moved the bond into the reserve. This launch is created last
        // because reaching the refusal needs the clock past its deadline, which would close
        // the buy window of every launch above it.
        (BondingCurve forfeited,) = createPledgedLaunch();
        vm.warp(forfeited.gradDeadline());
        forfeited.expire();
        assertEq(
            uint8(forfeited.bondState()),
            uint8(IBondingCurve.BondState.Forfeited),
            "the bond was forfeited"
        );
        vm.expectRevert(IBondingCurve.BondForfeitedToHolders.selector);
        forfeited.claimBond();
        assertEq(forfeited.pendingBondWei(), 0, "a forfeited bond is never credited");
    }

    /// @notice **Section 11.4 and Invariant 63's `Forfeited` row, end to end.** A launch
    /// that misses its deadline forfeits the bond to its holders: the creator's claim is
    /// refused permanently, the wei is in `ethReserve`, and the exit price every holder
    /// sells at is higher because of it.
    /// @dev The refusal alone would be a test of an error string. What makes the bond the
    /// thing this protocol is for is the other half: the forfeited ETH is in the reserve
    /// and a holder can take it out. The counterfactual quote is the reserve as it would
    /// have been had everything *except* the bond been forfeited, so the final comparison
    /// isolates the bond's own contribution to the exit price from the creator fees and the
    /// protection pool that expiry donates alongside it.
    function test_anExpiredLaunchPaysTheBondToHoldersAndRefusesTheClaimForever() public {
        (BondingCurve curve,) = createPledgedLaunch();
        uint256 holding = buy(curve, TRADER, 1 ether);

        uint256 bond = curve.bondHeldWei();
        uint256 reserveBefore = curve.ethReserve();
        uint256 creatorFees = curve.creatorFeeEth();
        uint256 protection = curve.protectionEth();
        uint256 creatorBalance = CREATOR.balance;
        assertEq(bond, 0.4 ether, "the launch posted a bond");
        assertGt(creatorFees, 0, "and the creator had accrued fees to lose as well");

        (,, uint256 exitBefore) = curve.quoteSell(holding);
        (,, uint256 exitWithoutTheBond) = CurveMath.sellQuote(
            uint256(curve.virtualEthReserve()) + reserveBefore + creatorFees + protection,
            PledrinConstants.VIRTUAL_TOKEN_RESERVE - curve.tokensSold(),
            curve.totalFeeBps(),
            holding
        );

        vm.warp(curve.gradDeadline());
        vm.prank(OTHER);
        curve.expire();

        // The creator's own claim is refused, and the refusal is permanent: the same
        // answer a decade later, with no state in between that can change it.
        vm.prank(CREATOR);
        vm.expectRevert(IBondingCurve.BondForfeitedToHolders.selector);
        curve.claimBond();
        vm.warp(vm.getBlockTimestamp() + 10 * 365 days);
        vm.expectRevert(IBondingCurve.BondForfeitedToHolders.selector);
        curve.claimBond();

        // Every wei of the bond is in the reserve, and none of it anywhere else.
        assertEq(
            curve.ethReserve(),
            reserveBefore + bond + creatorFees + protection,
            "the bond, the creator fees and the protection pool all reached the reserve"
        );
        assertEq(curve.bondHeldWei(), 0, "nothing is still held on the bond account");
        assertEq(curve.pendingBondWei(), 0, "and nothing was credited to the creator");
        assertEq(CREATOR.balance, creatorBalance, "who received not one wei");

        // And it reached the holders, which is the point: the exit price rose, by more than
        // the forfeited fees and protection pool alone would have raised it.
        (,, uint256 exitAfter) = curve.quoteSell(holding);
        assertGt(exitAfter, exitBefore, "expiry raised the exit price");
        assertGt(exitAfter, exitWithoutTheBond, "and the bond is part of what raised it");

        uint256 traderBefore = TRADER.balance;
        uint256 received = sell(curve, TRADER, holding);
        assertEq(received, exitAfter, "the holder exits at the raised price");
        assertEq(TRADER.balance - traderBefore, received, "and is paid it in full");
        assertGt(received, exitWithoutTheBond, "including the wei the creator forfeited");
    }

    /// @notice **Invariant 44.** The graduation bounty comes out of the protocol's own
    /// bucket and nowhere else.
    function test_theBountyIsDrawnOnlyFromTheProtocolBucket() public {
        (BondingCurve curve,) = createDefaultLaunch();
        buyToCap(curve);

        uint256 protocolBefore = curve.protocolFeeEth();
        uint256 creatorBefore = curve.creatorFeeEth();
        uint256 protectionBefore = curve.protectionEth();
        uint256 reserveBefore = curve.ethReserve();
        uint256 expectedBounty =
            (protocolBefore * PledrinConstants.GRAD_BOUNTY_BPS) / PledrinConstants.BPS_DENOMINATOR;

        vm.prank(GRADUATOR);
        curve.graduate();

        assertEq(curve.pendingBountyWei(GRADUATOR), expectedBounty, "the bounty is 10% of it");
        assertEq(curve.pendingBountyTotalWei(), expectedBounty, "and is tracked in total");
        assertEq(curve.protocolFeeEth(), protocolBefore - expectedBounty, "out of the protocol");
        assertEq(curve.creatorFeeEth(), creatorBefore, "not out of the creator bucket");
        assertLe(expectedBounty, protocolBefore, "Invariant 44's bound");
        // The protection bucket and the reserve were both spent on liquidity, not on the
        // bounty: what left them went into the two positions.
        assertEq(curve.protectionEth(), 0, "protection went into the floor position");
        assertEq(curve.ethReserve(), 0, "the reserve went into the core position");
        assertGt(reserveBefore, 0, "there was a reserve to spend");
        assertGt(protectionBefore, 0, "and a protection bucket");
    }

    /// @notice The bounty is credited, not pushed, and is claimable later by its earner.
    function test_theBountyIsCreditedAndClaimableByItsEarner() public {
        (BondingCurve curve,) = createDefaultLaunch();
        buyToCap(curve);

        uint256 before = GRADUATOR.balance;
        vm.prank(GRADUATOR);
        curve.graduate();
        assertEq(GRADUATOR.balance, before, "nothing was pushed during graduation");

        uint256 bounty = curve.pendingBountyWei(GRADUATOR);
        vm.prank(OTHER);
        assertEq(curve.claimBounty(GRADUATOR), bounty, "claimable by anyone, paid to the earner");
        assertEq(GRADUATOR.balance - before, bounty, "the earner was paid");
        assertEq(curve.pendingBountyWei(GRADUATOR), 0, "cleared");
        assertEq(curve.pendingBountyTotalWei(), 0, "and removed from the total");

        vm.expectRevert(IBondingCurve.NothingToClaim.selector);
        curve.claimBounty(GRADUATOR);
    }

    /// @notice The rounding remainder of the bounty division stays with the treasury.
    function test_theBountyRoundingRemainderStaysWithTheTreasury() public {
        (BondingCurve curve,) = createDefaultLaunch();
        buyToCap(curve);

        uint256 protocolBefore = curve.protocolFeeEth();
        vm.prank(GRADUATOR);
        curve.graduate();

        uint256 bounty = curve.pendingBountyWei(GRADUATOR);
        assertEq(
            curve.protocolFeeEth() + bounty,
            protocolBefore,
            "no wei of the protocol bucket was created or lost"
        );
        assertGe(
            curve.protocolFeeEth(),
            (protocolBefore * 9) / 10,
            "the remainder of the division stayed with the treasury"
        );
    }

    /// @notice **Invariant 58.** A recipient that reverts on receipt blocks only its own
    /// claim: every other claim, trade and transition still works.
    function test_aRevertingRecipientBlocksOnlyItsOwnClaim() public {
        RevertingReceiver hostileCreator = new RevertingReceiver();
        vm.deal(address(hostileCreator), 1 ether);

        (BondingCurve curve,) = createLaunchFrom(address(hostileCreator), defaultParams());
        buyToCap(curve);
        vm.prank(GRADUATOR);
        curve.graduate();

        uint256 accrued = curve.creatorFeeEth();
        vm.expectRevert(
            abi.encodeWithSelector(
                IBondingCurve.EthTransferFailed.selector, address(hostileCreator), accrued
            )
        );
        curve.claimCreatorFees();
        assertEq(curve.creatorFeeEth(), accrued, "the bucket is untouched by the failure");

        // Every other party is unaffected.
        assertGt(curve.claimProtocolFees(), 0, "the treasury still gets paid");
        assertGt(curve.claimBounty(GRADUATOR), 0, "the bounty earner still gets paid");
    }

    /// @notice Invariant 55(a): every claim holds a reentrancy guard, so a recipient
    /// cannot claim twice from its own payout callback. The recipient is the launch's
    /// creator here, which is the only claim destination a test can choose.
    function test_claimsCannotBeReentered() public {
        ReentrantClaimer claimer = new ReentrantClaimer();
        vm.deal(address(claimer), 1 ether);

        ILaunchFactory.LaunchParams memory params = defaultParams();
        params.bondWei = 0.4 ether;
        (BondingCurve curve,) = createLaunchFrom(address(claimer), params);
        buyToCap(curve);
        vm.prank(GRADUATOR);
        curve.graduate();

        uint256 accrued = curve.creatorFeeEth();
        claimer.prepare(IBondingCurve(address(curve)), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBondingCurve.EthTransferFailed.selector, address(claimer), accrued
            )
        );
        claimer.claim();
        assertEq(curve.creatorFeeEth(), accrued, "the creator bucket survived the attempt");

        uint256 bond = curve.pendingBondWei();
        claimer.prepare(IBondingCurve(address(curve)), 3);
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.EthTransferFailed.selector, address(claimer), bond)
        );
        claimer.claim();
        assertEq(curve.pendingBondWei(), bond, "the bond survived the attempt");
    }

    /// @notice **Invariant 18, by fuzz.** Across an arbitrary trade sequence, everything
    /// ever paid out of the three buckets plus what is still in them equals every fee the
    /// launch ever charged.
    function testFuzz_theBucketsConserveEveryFeeEverCharged(
        uint96 buyA,
        uint96 buyB,
        uint96 sellFraction
    ) public {
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();

        uint256 charged;
        uint256 valueA = bound(buyA, PledrinConstants.MIN_BUY_WEI, 1 ether);
        (,, uint256 feeA,) = curve.quoteBuy(valueA);
        buy(curve, TRADER, valueA);
        charged += feeA;

        uint256 valueB = bound(buyB, PledrinConstants.MIN_BUY_WEI, 1 ether);
        (,, uint256 feeB,) = curve.quoteBuy(valueB);
        buy(curve, OTHER, valueB);
        charged += feeB;

        uint256 held = token.balanceOf(TRADER);
        uint256 amount = bound(sellFraction, 1, held);
        (, uint256 feeC, uint256 out) = curve.quoteSell(amount);
        if (out > 0) {
            sell(curve, TRADER, amount);
            charged += feeC;
        }

        // Claim what is claimable before graduation: only the protocol's bucket.
        uint256 paidOut;
        if (curve.protocolFeeEth() > 0) paidOut += curve.claimProtocolFees();

        assertEq(_buckets(curve) + paidOut, charged, "Invariant 18");
    }

    /// @notice Invariant 52: no owner, timelock or treasury call can move a launch's
    /// value. The factory's whole power is three setters, none of which the curve reads
    /// after construction.
    function test_noGovernanceCallCanReachALaunchsValue() public {
        (BondingCurve curve,) = createPledgedLaunch();
        buy(curve, TRADER, 1 ether);

        uint256 reserve = curve.ethReserve();
        uint256 bond = curve.bondHeldWei();
        uint256 protection = curve.protectionEth();

        executeAfterDelay(
            address(factory),
            abi.encodeCall(ILaunchFactory.setProtocolTreasury, (OTHER)),
            bytes32("t")
        );
        executeAfterDelay(
            address(factory),
            abi.encodeCall(ILaunchFactory.setFeeConfig, (defaultFeeConfig())),
            bytes32("f")
        );
        setLaunchesPaused(true);

        assertEq(curve.ethReserve(), reserve, "reserve");
        assertEq(curve.bondHeldWei(), bond, "bond");
        assertEq(curve.protectionEth(), protection, "protection");
        assertEq(curve.protocolTreasury(), TREASURY, "treasury");
        assertEq(curve.totalFeeBps(), DEFAULT_FEE_BPS, "fee");
    }

    function _buckets(BondingCurve curve) private view returns (uint256) {
        return uint256(curve.creatorFeeEth()) + curve.protocolFeeEth() + curve.protectionEth();
    }
}
