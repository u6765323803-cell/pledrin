// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {ICreatorVesting} from "src/interfaces/ICreatorVesting.sol";
import {ILaunchFactory} from "src/interfaces/ILaunchFactory.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {PledrinTestBase} from "../base/PledrinTestBase.sol";

/// @title The launch lifecycle
/// @notice Covers `docs/SPEC.md` sections 7, 8.4, 11.3 and 11.4, and Invariants 25, 26,
/// 27, 30, 34, 35, 36 and 37.
/// @dev Every warp target is derived from contract state — `gradDeadline`, `capReachedAt`
/// — and never from a cached `vm.getBlockTimestamp()`, because under `via_ir` the optimizer may
/// rematerialise a `TIMESTAMP` read across a cheatcode call. The `foundry.toml` comment
/// next to `via_ir` says so.
contract BondingCurveLifecycleTest is PledrinTestBase {
    // ------------------------------------------------------------------
    // expire
    // ------------------------------------------------------------------

    /// @notice **Invariant 27.** On expiry the bond, the creator's accrued fees and the
    /// protection pool are all donated into the reserve, those three fields become zero,
    /// and nothing is sent or credited to the creator.
    function test_expireDonatesTheBondTheCreatorFeesAndTheProtectionPool() public {
        (BondingCurve curve,) = createPledgedLaunch();
        buy(curve, TRADER, 1 ether);

        uint256 reserveBefore = curve.ethReserve();
        uint256 bond = curve.bondHeldWei();
        uint256 creatorFees = curve.creatorFeeEth();
        uint256 protection = curve.protectionEth();
        uint256 protocolFees = curve.protocolFeeEth();
        uint256 creatorBalance = CREATOR.balance;
        assertGt(bond, 0, "there is a bond");
        assertGt(creatorFees, 0, "and accrued creator fees");
        assertGt(protection, 0, "and a protection pool");

        vm.warp(curve.gradDeadline());
        vm.expectEmit(true, false, false, true, address(curve));
        emit IBondingCurve.Expired(
            address(curve),
            bond,
            creatorFees,
            protection,
            reserveBefore + bond + creatorFees + protection
        );
        vm.prank(OTHER);
        curve.expire();

        assertEq(
            curve.ethReserve(),
            reserveBefore + bond + creatorFees + protection,
            "everything forfeited reached the reserve"
        );
        assertEq(curve.bondHeldWei(), 0, "bondHeldWei");
        assertEq(curve.creatorFeeEth(), 0, "creatorFeeEth");
        assertEq(curve.protectionEth(), 0, "protectionEth");
        assertEq(curve.pendingBondWei(), 0, "nothing was credited to the creator");
        assertEq(CREATOR.balance, creatorBalance, "and nothing was sent to them");
        assertEq(curve.protocolFeeEth(), protocolFees, "the protocol bucket is untouched");
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Expired), "Expired");
        assertEq(uint8(curve.bondState()), uint8(IBondingCurve.BondState.Forfeited), "Invariant 26");
    }

    /// @notice Expiry voids the creator's vesting schedule in the same transaction.
    function test_expireVoidsTheCreatorAllocation() public {
        (BondingCurve curve,) = createPledgedLaunch();
        assertGt(vesting.scheduleOf(address(curve)).allocation, 0, "there is an allocation");

        vm.warp(curve.gradDeadline());
        curve.expire();

        assertTrue(vesting.scheduleOf(address(curve)).voided, "voided");
        assertEq(vesting.releasable(address(curve)), 0, "Invariant 21: nothing ever releasable");
    }

    /// @notice **Invariant 34.** Expiry needs the deadline reached and the cap missed: one
    /// second early reverts, and at the deadline it succeeds.
    function test_expireNeedsTheDeadlineAndRevertsOneSecondEarly() public {
        (BondingCurve curve,) = createDefaultLaunch();

        vm.warp(curve.gradDeadline() - 1);
        vm.expectRevert(IBondingCurve.DeadlineNotReached.selector);
        curve.expire();

        vm.warp(curve.gradDeadline());
        curve.expire();
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Expired), "Expired");
    }

    /// @notice **Invariant 34's other half.** A launch that reached the cap can never
    /// expire, whatever the clock says.
    function test_aLaunchThatReachedTheCapCannotExpire() public {
        (BondingCurve curve,) = createLaunchAtCap();

        vm.warp(curve.gradDeadline() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBondingCurve.WrongState.selector, IBondingCurve.State.Graduating
            )
        );
        curve.expire();
    }

    /// @notice The `CapAlreadyReached` guard is the one that fires if a launch somehow sat
    /// in `Live` at the cap, which the `Graduating` transition makes unreachable through
    /// `buy`. It is asserted through a launch frozen at the cap by other means.
    function test_expireRejectsALiveLaunchHoldingTheWholeSupplySold() public {
        (BondingCurve curve,) = createDefaultLaunch();
        buyToCap(curve);

        // `buy` already moved it to `Graduating`, and nothing in the protocol can put a
        // launch back into `Live`, so this branch is defensive rather than reachable. The
        // only way to exercise it is to write `state` directly. `state` shares its slot
        // with `protectionEth`, `capReachedAt` and `bondState`, so the write clears one
        // byte and the assertions below prove it touched nothing else.
        uint256 protectionBefore = curve.protectionEth();
        uint64 capReachedBefore = curve.capReachedAt();
        bytes32 slot = bytes32(uint256(2));
        bytes32 word = vm.load(address(curve), slot);
        vm.store(address(curve), slot, word & ~bytes32(uint256(0xff) << 192));

        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Live), "forced back to Live");
        assertEq(curve.protectionEth(), protectionBefore, "the write hit only the state byte");
        assertEq(curve.capReachedAt(), capReachedBefore, "capReachedAt survived the write");
        assertEq(curve.tokensSold(), PledrinConstants.CURVE_SUPPLY, "still at the cap");

        vm.warp(curve.gradDeadline());
        vm.expectRevert(IBondingCurve.CapAlreadyReached.selector);
        curve.expire();
    }

    /// @notice Expiry happens once. A second call finds the wrong state.
    function test_expireHappensOnce() public {
        (BondingCurve curve,) = createDefaultLaunch();
        vm.warp(curve.gradDeadline());
        curve.expire();

        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Expired)
        );
        curve.expire();
    }

    /// @notice An unbonded launch expires without touching the bond machinery.
    function test_anUnbondedLaunchExpiresWithNoBondTransition() public {
        (BondingCurve curve,) = createDefaultLaunch();
        buy(curve, TRADER, 1 ether);

        vm.warp(curve.gradDeadline());
        curve.expire();

        assertEq(uint8(curve.bondState()), uint8(IBondingCurve.BondState.None), "still None");
        ILaunchFactory.Reputation memory record = factory.reputationOf(CREATOR);
        assertEq(record.expiries, 1, "the expiry is recorded");
        assertEq(record.bondsForfeited, 0, "no bond was forfeited");
        assertEq(record.bondWeiForfeited, 0, "and no wei");
    }

    /// @notice A bonded expiry records the forfeiture in wei, which is the part of
    /// reputation that is expensive to fake.
    function test_aBondedExpiryRecordsTheForfeitedWei() public {
        (BondingCurve curve,) = createPledgedLaunch();
        vm.warp(curve.gradDeadline());
        curve.expire();

        ILaunchFactory.Reputation memory record = factory.reputationOf(CREATOR);
        assertEq(record.expiries, 1, "expiries");
        assertEq(record.bondsForfeited, 1, "bondsForfeited");
        assertEq(record.bondWeiForfeited, 0.4 ether, "bondWeiForfeited");
        assertEq(record.bondsReturned, 0, "nothing was returned");
    }

    // ------------------------------------------------------------------
    // abortGraduation
    // ------------------------------------------------------------------

    /// @notice **Invariant 37's second half, pinned directly.** `abortGraduation` reverts
    /// at every moment before `capReachedAt + GRAD_GRACE`, including one second before,
    /// and succeeds exactly at it.
    function test_abortGraduationRevertsBeforeTheGraceWindowCloses() public {
        (BondingCurve curve,) = createLaunchAtCap();
        uint256 capReachedAt = curve.capReachedAt();
        assertGt(capReachedAt, 0, "capReachedAt is written when the cap is reached");

        // Immediately.
        vm.expectRevert(IBondingCurve.GraceNotElapsed.selector);
        curve.abortGraduation();

        // Half way through the window.
        vm.warp(capReachedAt + PledrinConstants.GRAD_GRACE / 2);
        vm.expectRevert(IBondingCurve.GraceNotElapsed.selector);
        curve.abortGraduation();

        // One second before it closes.
        vm.warp(capReachedAt + PledrinConstants.GRAD_GRACE - 1);
        vm.expectRevert(IBondingCurve.GraceNotElapsed.selector);
        curve.abortGraduation();

        // Exactly at it.
        vm.warp(capReachedAt + PledrinConstants.GRAD_GRACE);
        curve.abortGraduation();
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Stalled), "Stalled");
    }

    /// @notice Section 8.4: a stall returns the bond, because the creator met the only
    /// condition the bond encodes, and donates the protection pool to holders.
    function test_abortGraduationReturnsTheBondAndDonatesTheProtectionPool() public {
        (BondingCurve curve,) = createPledgedLaunch();
        buyToCap(curve);

        uint256 reserve = curve.ethReserve();
        uint256 protection = curve.protectionEth();
        uint256 bond = curve.bondHeldWei();
        assertGt(protection, 0, "there is a protection pool");

        vm.warp(curve.capReachedAt() + PledrinConstants.GRAD_GRACE);
        vm.prank(OTHER);
        curve.abortGraduation();

        assertEq(curve.ethReserve(), reserve + protection, "the protection pool was donated");
        assertEq(curve.protectionEth(), 0, "and the bucket emptied");
        assertEq(uint8(curve.bondState()), uint8(IBondingCurve.BondState.Returned), "Returned");
        assertEq(curve.pendingBondWei(), bond, "the bond is credited, not pushed");
        assertEq(curve.bondHeldWei(), 0, "and no longer held");
        assertEq(curve.claimBond(), bond, "and claimable by the creator");
    }

    /// @notice A stall starts the creator's vesting clock, like a graduation.
    function test_abortGraduationStartsTheVestingClock() public {
        (BondingCurve curve,) = createPledgedLaunch();
        buyToCap(curve);
        assertEq(vesting.scheduleOf(address(curve)).start, 0, "unset before");

        vm.warp(curve.capReachedAt() + PledrinConstants.GRAD_GRACE);
        curve.abortGraduation();

        assertEq(vesting.scheduleOf(address(curve)).start, vm.getBlockTimestamp(), "started");
    }

    /// @notice A stall is recorded against the creator, with the bond return.
    function test_abortGraduationRecordsAStall() public {
        (BondingCurve curve,) = createPledgedLaunch();
        buyToCap(curve);
        vm.warp(curve.capReachedAt() + PledrinConstants.GRAD_GRACE);

        vm.expectEmit(true, true, false, true, address(curve));
        emit IBondingCurve.GraduationStalled(address(curve), OTHER);
        vm.prank(OTHER);
        curve.abortGraduation();

        ILaunchFactory.Reputation memory record = factory.reputationOf(CREATOR);
        assertEq(record.stalls, 1, "stalls");
        assertEq(record.bondsReturned, 1, "bondsReturned");
        assertEq(record.graduations, 0, "not a graduation");
    }

    /// @notice `abortGraduation` is only reachable from `Graduating`.
    function test_abortGraduationRequiresGraduating() public {
        (BondingCurve live,) = createDefaultLaunch();
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Live)
        );
        live.abortGraduation();

        (BondingCurve stalled,) = createLaunchAtCap();
        vm.warp(stalled.capReachedAt() + PledrinConstants.GRAD_GRACE);
        stalled.abortGraduation();
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Stalled)
        );
        stalled.abortGraduation();
    }

    /// @notice A stall on an unbonded launch moves no bond and still works.
    function test_abortGraduationOnAnUnbondedLaunch() public {
        (BondingCurve curve,) = createLaunchAtCap();
        vm.warp(curve.capReachedAt() + PledrinConstants.GRAD_GRACE);
        curve.abortGraduation();

        assertEq(uint8(curve.bondState()), uint8(IBondingCurve.BondState.None), "no bond");
        ILaunchFactory.Reputation memory record = factory.reputationOf(CREATOR);
        assertEq(record.stalls, 1, "stalls");
        assertEq(record.bondsReturned, 0, "bondsReturned");
    }

    /// @notice Section 8.4: a creator who griefs their own graduation to reach `Stalled`
    /// gains nothing. They receive exactly the bond and the fees `graduate` would have
    /// given them, and the holders keep a reserve that is larger by the protection pool.
    function test_stallingGainsTheCreatorNothingOverGraduating() public {
        (BondingCurve stalled,) = createPledgedLaunch();
        buyToCap(stalled);
        uint256 stalledFees = stalled.creatorFeeEth();
        uint256 stalledBond = stalled.bondHeldWei();
        vm.warp(stalled.capReachedAt() + PledrinConstants.GRAD_GRACE);
        stalled.abortGraduation();

        (BondingCurve graduated,) = createPledgedLaunch();
        buyToCap(graduated);
        uint256 graduatedFees = graduated.creatorFeeEth();
        uint256 graduatedBond = graduated.bondHeldWei();
        vm.prank(GRADUATOR);
        graduated.graduate();

        assertEq(stalledFees, graduatedFees, "the same creator fees either way");
        assertEq(stalledBond, graduatedBond, "and the same bond");
        assertEq(stalled.pendingBondWei(), graduated.pendingBondWei(), "both credited");
        assertEq(stalled.creatorFeeEth(), graduated.creatorFeeEth(), "both claimable");
    }

    // ------------------------------------------------------------------
    // Terminality and reachability
    // ------------------------------------------------------------------

    /// @notice **Invariant 30.** `Graduated`, `Expired` and `Stalled` are terminal: no
    /// external call moves a launch out of one.
    function test_theThreeTerminalStatesNeverChangeAgain() public {
        (BondingCurve graduated,) = createLaunchAtCap();
        vm.prank(GRADUATOR);
        graduated.graduate();
        _assertTerminal(graduated, IBondingCurve.State.Graduated);

        (BondingCurve expired,) = createDefaultLaunch();
        vm.warp(expired.gradDeadline());
        expired.expire();
        _assertTerminal(expired, IBondingCurve.State.Expired);

        (BondingCurve stalled,) = createLaunchAtCap();
        vm.warp(stalled.capReachedAt() + PledrinConstants.GRAD_GRACE);
        stalled.abortGraduation();
        _assertTerminal(stalled, IBondingCurve.State.Stalled);
    }

    /// @notice **Invariant 35.** Exactly one of the three terminal states is reachable
    /// from a `Live` launch, and every `Live` launch reaches one of them given time and a
    /// single external call.
    function test_everyLiveLaunchReachesExactlyOneTerminalState() public {
        // Below the cap: time plus one call gives `Expired` and nothing else.
        (BondingCurve expiring,) = createDefaultLaunch();
        buy(expiring, TRADER, 1 ether);
        vm.warp(expiring.gradDeadline());
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Live)
        );
        expiring.abortGraduation();
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Live)
        );
        expiring.graduate();
        expiring.expire();
        assertEq(uint8(expiring.state()), uint8(IBondingCurve.State.Expired), "Expired");

        // At the cap: `Graduated` immediately, or `Stalled` after the grace period, and
        // expiry is closed off for good.
        (BondingCurve atCap,) = createLaunchAtCap();
        vm.warp(atCap.gradDeadline() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBondingCurve.WrongState.selector, IBondingCurve.State.Graduating
            )
        );
        atCap.expire();
        vm.prank(GRADUATOR);
        atCap.graduate();
        assertEq(uint8(atCap.state()), uint8(IBondingCurve.State.Graduated), "Graduated");
    }

    /// @notice Section 7: a launch whose deadline passes is closed to buyers and incapable
    /// of graduating whether or not anyone calls `expire`.
    function test_aLaunchPastItsDeadlineIsClosedWithoutAnyoneCallingExpire() public {
        (BondingCurve curve,) = createDefaultLaunch();
        buy(curve, TRADER, 1 ether);
        vm.warp(curve.gradDeadline() + 365 days);

        vm.prank(TRADER);
        vm.expectRevert(IBondingCurve.BuyWindowClosed.selector);
        curve.buy{value: 1 ether}(0, vm.getBlockTimestamp());

        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Live)
        );
        curve.graduate();

        // Sells and donations keep working, with no `expire` call ever made.
        assertGt(sell(curve, TRADER, 1e18), 0, "the exit is open");
        vm.prank(OTHER);
        curve.donate{value: 1}();
    }

    /// @notice Section 7: `Graduating` freezes the curve, which is what makes the cap a
    /// one-way door. Neither direction of trade is available.
    function test_graduatingFreezesTheCurveInBothDirections() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        uint256 sold = curve.tokensSold();
        uint256 reserve = curve.ethReserve();

        vm.prank(TRADER);
        token.approve(address(curve), type(uint256).max);
        vm.prank(TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBondingCurve.WrongState.selector, IBondingCurve.State.Graduating
            )
        );
        curve.sell(1, 0, vm.getBlockTimestamp());

        vm.prank(TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBondingCurve.WrongState.selector, IBondingCurve.State.Graduating
            )
        );
        curve.buy{value: 1 ether}(0, vm.getBlockTimestamp());

        assertEq(curve.tokensSold(), sold, "tokensSold frozen");
        assertEq(curve.ethReserve(), reserve, "ethReserve frozen");
    }

    /// @notice A fuzz over the window: whatever the window and whenever the clock lands,
    /// a launch below the cap is buyable strictly before `gradDeadline` and expirable
    /// exactly from it.
    function testFuzz_theBuyWindowAndTheExpiryWindowMeetExactlyAtTheDeadline(
        uint32 window,
        uint32 offset
    ) public {
        ILaunchFactory.LaunchParams memory params = defaultParams();
        params.gradWindow = uint32(
            bound(window, PledrinConstants.MIN_GRAD_WINDOW, PledrinConstants.MAX_GRAD_WINDOW)
        );
        (BondingCurve curve,) = createLaunch(params);

        uint64 deadline = curve.gradDeadline();
        uint256 early = bound(offset, 1, params.gradWindow);
        vm.warp(deadline - early);

        vm.prank(TRADER);
        curve.buy{value: PledrinConstants.MIN_BUY_WEI}(0, vm.getBlockTimestamp());
        vm.expectRevert(IBondingCurve.DeadlineNotReached.selector);
        curve.expire();

        vm.warp(deadline);
        vm.prank(TRADER);
        vm.expectRevert(IBondingCurve.BuyWindowClosed.selector);
        curve.buy{value: PledrinConstants.MIN_BUY_WEI}(0, vm.getBlockTimestamp());
        curve.expire();
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Expired), "Expired");
    }

    function _assertTerminal(BondingCurve curve, IBondingCurve.State expected) private {
        bytes memory wrongState =
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, expected);

        vm.expectRevert(wrongState);
        curve.graduate();

        // No warp past `ALT_DELAY` is needed to reach this refusal: `graduateAlt` checks
        // the state before the delay, so a terminal launch answers `WrongState` wherever
        // the clock stands. Not warping is also what keeps this helper's own claim exact —
        // the state it asserts at the end is the state every call above it saw.
        vm.expectRevert(wrongState);
        curve.graduateAlt(PledrinConstants.POOL_FEE, 100);

        vm.expectRevert(wrongState);
        curve.abortGraduation();

        vm.expectRevert(wrongState);
        curve.expire();

        assertEq(uint8(curve.state()), uint8(expected), "Invariant 30: the state never moved");
    }
}
