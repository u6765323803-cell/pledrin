// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {ICreatorVesting} from "src/interfaces/ICreatorVesting.sol";
import {ILaunchFactory} from "src/interfaces/ILaunchFactory.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {PledrinTestBase} from "../base/PledrinTestBase.sol";
import {FakeLaunch} from "../mocks/Actors.sol";

/// @title `CreatorVesting`
/// @notice Covers `docs/SPEC.md` sections 4.1 and 12, and Invariants 21, 22, 23 and 24.
/// @dev Every warp target here is derived from the schedule's own `start`, never from a
/// cached `block.timestamp`: under `via_ir` a cached timestamp is not reliable across a
/// `vm.warp`, and a vesting test that warped to the wrong moment would pass for the wrong
/// reason.
contract CreatorVestingTest is PledrinTestBase {
    /// @notice Section 4.1: the creator's allocation is a priced buy at the opening price,
    /// delivered to the vesting contract and not to the creator's wallet.
    function test_theCreatorAllocationIsAPricedBuyDeliveredToVesting() public {
        ILaunchFactory.LaunchParams memory params = defaultParams();
        params.creatorFirstBuyWei = 0.009 ether;
        (BondingCurve curve, IERC20 token) = createLaunch(params);

        ICreatorVesting.Schedule memory schedule = vesting.scheduleOf(address(curve));
        assertGt(schedule.allocation, 0, "an allocation was delivered");
        assertEq(schedule.creator, CREATOR, "the creator is recorded");
        assertEq(schedule.token, address(token), "the token is recorded");
        assertEq(schedule.cliff, DEFAULT_CLIFF, "cliff");
        assertEq(schedule.duration, DEFAULT_VEST_DURATION, "duration");
        assertEq(schedule.released, 0, "nothing released");
        assertEq(schedule.start, 0, "the clock has not started");
        assertFalse(schedule.voided, "not voided");

        assertEq(token.balanceOf(address(vesting)), schedule.allocation, "the vesting holds it");
        assertEq(token.balanceOf(CREATOR), 0, "the creator holds none of it");
        assertEq(curve.tokensSold(), schedule.allocation, "it was bought from the curve");
        assertEq(
            curve.ethReserve() + curve.protectionEth() + curve.creatorFeeEth()
                + curve.protocolFeeEth(),
            0.009 ether,
            "and paid for at the opening price"
        );
    }

    /// @notice **Invariant 24.** The first buy cannot exceed `CREATOR_FIRST_BUY_MAX`, and
    /// the curve rejects the launch rather than trimming it.
    function test_aFirstBuyAboveTheCeilingIsRejected() public {
        ILaunchFactory.LaunchParams memory params = defaultParams();
        params.creatorFirstBuyWei = 0.02 ether;

        vm.deal(CREATOR, 1 ether);
        vm.prank(CREATOR);
        vm.expectPartialRevert(IBondingCurve.FirstBuyTooLarge.selector);
        factory.createLaunch{value: 0.02 ether}(params);
    }

    /// @notice The largest first buy that fits is accepted, and what it delivers is at
    /// most the ceiling.
    function test_theLargestFirstBuyThatFitsIsAccepted() public {
        ILaunchFactory.LaunchParams memory params = defaultParams();
        params.creatorFirstBuyWei = 0.009 ether;
        (BondingCurve curve,) = createLaunch(params);

        assertLe(
            vesting.scheduleOf(address(curve)).allocation,
            PledrinConstants.CREATOR_FIRST_BUY_MAX,
            "Invariant 24"
        );
        assertGt(
            vesting.scheduleOf(address(curve)).allocation,
            PledrinConstants.CREATOR_FIRST_BUY_MAX / 2,
            "and it is close to the ceiling, so the bound is being tested"
        );
    }

    /// @notice A first buy below `MIN_BUY_WEI` is rejected by the factory, and a zero one
    /// simply creates no schedule.
    function test_aFirstBuyIsEitherZeroOrAtLeastTheMinimumBuy() public {
        ILaunchFactory.LaunchParams memory tooSmall = defaultParams();
        tooSmall.creatorFirstBuyWei = uint128(PledrinConstants.MIN_BUY_WEI - 1);
        vm.prank(CREATOR);
        vm.expectRevert(ILaunchFactory.InvalidFirstBuy.selector);
        factory.createLaunch{value: PledrinConstants.MIN_BUY_WEI - 1}(tooSmall);

        (BondingCurve none,) = createDefaultLaunch();
        assertEq(vesting.scheduleOf(address(none)).allocation, 0, "no schedule");
        assertEq(vesting.releasable(address(none)), 0, "and nothing releasable");
    }

    /// @notice `creatorFirstBuy` is reachable only by the launch's factory, and only while
    /// the curve has sold nothing.
    function test_theFirstBuyIsOnlyAvailableToTheFactoryInTheLaunchTransaction() public {
        (BondingCurve curve,) = createDefaultLaunch();

        vm.prank(OTHER);
        vm.expectRevert(IBondingCurve.NotFactory.selector);
        curve.creatorFirstBuy{value: 0.009 ether}(0, 2_592_000);

        buy(curve, TRADER, 1 ether);
        vm.deal(address(factory), 1 ether);
        vm.prank(address(factory));
        vm.expectRevert(IBondingCurve.FirstBuyUnavailable.selector);
        curve.creatorFirstBuy{value: 0.009 ether}(0, 2_592_000);
    }

    /// @notice **Invariant 21.** Nothing is releasable before the clock starts, nothing
    /// before the cliff, and nothing ever once voided.
    function test_nothingIsReleasableBeforeTheClockOrBeforeTheCliff() public {
        (BondingCurve curve,) = createPledgedLaunch();
        address launch = address(curve);

        assertEq(vesting.releasable(launch), 0, "before the clock starts");
        vm.warp(curve.gradDeadline() - 1);
        assertEq(vesting.releasable(launch), 0, "a month later, still nothing");
        vm.expectRevert(ICreatorVesting.NothingToRelease.selector);
        vesting.release(launch);

        buyToCap(curve);
        vm.prank(GRADUATOR);
        curve.graduate();

        uint64 start = vesting.scheduleOf(launch).start;
        assertEq(vesting.releasable(launch), 0, "at the start");
        vm.warp(uint256(start) + DEFAULT_CLIFF - 1);
        assertEq(vesting.releasable(launch), 0, "one second before the cliff");
        vm.warp(uint256(start) + DEFAULT_CLIFF);
        assertEq(vesting.releasable(launch), 0, "exactly at the cliff, nothing has accrued yet");
        vm.warp(uint256(start) + DEFAULT_CLIFF + 1);
        assertGt(vesting.releasable(launch), 0, "one second after the cliff, it has");
    }

    /// @notice **Invariant 22.** Cumulative releases never exceed the allocation and equal
    /// it exactly once the duration has elapsed.
    function test_releasesAreLinearAndSumToExactlyTheAllocation() public {
        (BondingCurve curve, IERC20 token) = createPledgedLaunch();
        address launch = address(curve);
        buyToCap(curve);
        vm.prank(GRADUATOR);
        curve.graduate();

        uint256 allocation = vesting.scheduleOf(launch).allocation;
        uint64 start = vesting.scheduleOf(launch).start;

        vm.warp(uint256(start) + DEFAULT_CLIFF + DEFAULT_VEST_DURATION / 4);
        assertApproxEqRel(vesting.releasable(launch), allocation / 4, 1e12, "a quarter of the way");
        uint256 first = vesting.release(launch);
        assertEq(token.balanceOf(CREATOR), first, "the creator was paid");

        vm.warp(uint256(start) + DEFAULT_CLIFF + DEFAULT_VEST_DURATION / 2);
        assertApproxEqRel(
            vesting.releasable(launch), allocation / 2 - first, 1e12, "half way, net of the first"
        );
        uint256 second = vesting.release(launch);

        vm.warp(uint256(start) + DEFAULT_CLIFF + DEFAULT_VEST_DURATION);
        assertEq(vesting.releasable(launch), allocation - first - second, "the tail");
        uint256 third = vesting.release(launch);

        assertEq(first + second + third, allocation, "Invariant 22: exactly the allocation");
        assertEq(token.balanceOf(CREATOR), allocation, "and the creator holds all of it");
        assertEq(vesting.releasable(launch), 0, "nothing left");
        vm.expectRevert(ICreatorVesting.NothingToRelease.selector);
        vesting.release(launch);

        // Long after the end it is still exactly the allocation and no more.
        vm.warp(uint256(start) + DEFAULT_CLIFF + DEFAULT_VEST_DURATION + 365 days);
        assertEq(vesting.releasable(launch), 0, "Invariant 22's ceiling holds forever");
        assertEq(vesting.scheduleOf(launch).released, allocation, "released");
    }

    /// @notice `release` is permissionless and always pays the recorded creator.
    function test_releaseIsPermissionlessAndAlwaysPaysTheCreator() public {
        (BondingCurve curve, IERC20 token) = createPledgedLaunch();
        buyToCap(curve);
        vm.prank(GRADUATOR);
        curve.graduate();
        uint64 start = vesting.scheduleOf(address(curve)).start;
        vm.warp(uint256(start) + DEFAULT_CLIFF + DEFAULT_VEST_DURATION);

        vm.prank(OTHER);
        uint256 amount = vesting.release(address(curve));

        assertGt(amount, 0, "a stranger released it");
        assertEq(token.balanceOf(CREATOR), amount, "to the creator");
        assertEq(token.balanceOf(OTHER), 0, "and not to the caller");
    }

    /// @notice **Invariant 21's second half.** A voided schedule releases nothing, ever,
    /// and the allocation is irrecoverable by anyone.
    /// @dev The refusal is `ScheduleVoided` and not `NothingToRelease`, which is Invariant
    /// 62 on the one path a real launch can reach it from: `expire()` voided this schedule,
    /// so the creator is told the allocation is gone rather than told to come back later.
    /// `test_releaseSeparatesAVoidedScheduleFromOneThatIsNotDueYet` asserts that against
    /// the three refusals a later call really can clear.
    function test_aVoidedScheduleIsIrrecoverable() public {
        (BondingCurve curve, IERC20 token) = createPledgedLaunch();
        address launch = address(curve);
        uint256 allocation = vesting.scheduleOf(launch).allocation;

        vm.warp(curve.gradDeadline());
        curve.expire();

        assertTrue(vesting.scheduleOf(launch).voided, "voided");
        assertEq(vesting.releasable(launch), 0, "nothing releasable");
        vm.warp(vm.getBlockTimestamp() + 10 * 365 days);
        assertEq(vesting.releasable(launch), 0, "a decade later, nothing");
        vm.expectRevert(ICreatorVesting.ScheduleVoided.selector);
        vesting.release(launch);

        assertEq(token.balanceOf(address(vesting)), allocation, "the tokens are stranded there");
        assertEq(token.totalSupply(), PledrinConstants.TOTAL_SUPPLY, "with no burn and no change");
    }

    /// @notice **Invariant 62.** `release` separates the one permanent refusal from the
    /// clearable ones: `ScheduleVoided` for a voided schedule, and `NothingToRelease` for
    /// each of the three conditions a later call can clear. The four are asserted together,
    /// because the distinction between them is the whole content of the invariant: a
    /// collapse of the voided case back into `NothingToRelease` fails here.
    /// @dev `NoSchedule`, the fourth row of section 12's table, is asserted in
    /// `test_releaseOnAnUnknownLaunchReverts`.
    ///
    /// The voided schedule here is started and fully vested, so `releasable` would be the
    /// entire allocation were it not voided. That is deliberate: the voided check runs
    /// before the amount is computed, and a schedule with nothing accrued could not tell
    /// the two orderings apart. No real launch reaches this combination — `expire()` is the
    /// only caller of `void()` and it can only fire while the launch is `Live`, which is
    /// before anything calls `start()` — so the stand-in launch of `test/mocks` is what
    /// constructs it. `test_aVoidedScheduleIsIrrecoverable` covers the real path.
    function test_releaseSeparatesAVoidedScheduleFromOneThatIsNotDueYet() public {
        // Clearable, one: the launch has not settled, so the clock has not started. A
        // graduation or a stall turns this same call into a payment.
        (BondingCurve curve,) = createPledgedLaunch();
        address launch = address(curve);
        assertEq(vesting.scheduleOf(launch).start, 0, "the clock has not started");
        vm.expectRevert(ICreatorVesting.NothingToRelease.selector);
        vesting.release(launch);

        // Clearable, two: started, one second inside the cliff.
        buyToCap(curve);
        vm.prank(GRADUATOR);
        curve.graduate();
        uint64 start = vesting.scheduleOf(launch).start;
        vm.warp(uint256(start) + DEFAULT_CLIFF - 1);
        vm.expectRevert(ICreatorVesting.NothingToRelease.selector);
        vesting.release(launch);

        // Clearable, three: past the cliff and paid, with nothing further accrued since.
        // The second call is in the same block as the release that emptied it.
        vm.warp(uint256(start) + DEFAULT_CLIFF + DEFAULT_VEST_DURATION / 4);
        assertGt(vesting.release(launch), 0, "the quarter point paid");
        assertLt(vesting.scheduleOf(launch).released, vesting.scheduleOf(launch).allocation, "part");
        vm.expectRevert(ICreatorVesting.NothingToRelease.selector);
        vesting.release(launch);

        // The same condition with the clock moving rather than standing still: at this
        // allocation and duration a second accrues less than one base unit, so a schedule
        // that has never paid anything still has nothing to pay.
        FakeLaunch slow = new FakeLaunch();
        (BondingCurve slowCurve, IERC20 slowToken) = createDefaultLaunch();
        _fundSchedule(slowCurve, slowToken, slow, 1000, 0, PledrinConstants.MAX_VEST_DURATION);
        slow.start(vesting);
        vm.warp(uint256(vesting.scheduleOf(address(slow)).start) + 1);
        assertEq(vesting.releasable(address(slow)), 0, "a second buys no base unit");
        assertEq(vesting.scheduleOf(address(slow)).released, 0, "and nothing has been paid");
        vm.expectRevert(ICreatorVesting.NothingToRelease.selector);
        vesting.release(address(slow));

        // Permanent: voided, with the whole allocation due by the clock.
        FakeLaunch voided = new FakeLaunch();
        (BondingCurve voidedCurve, IERC20 voidedToken) = createDefaultLaunch();
        _fundSchedule(voidedCurve, voidedToken, voided, 1e18, 0, PledrinConstants.MIN_VEST_DURATION);
        voided.start(vesting);
        vm.warp(
            uint256(vesting.scheduleOf(address(voided)).start) + PledrinConstants.MIN_VEST_DURATION
        );
        assertEq(vesting.releasable(address(voided)), 1e18, "the whole allocation is due");

        uint256 creatorBalance = voidedToken.balanceOf(CREATOR);
        voided.voidSchedule(vesting);
        assertEq(vesting.releasable(address(voided)), 0, "voiding took it back off the clock");
        vm.expectRevert(ICreatorVesting.ScheduleVoided.selector);
        vesting.release(address(voided));
        assertEq(voidedToken.balanceOf(CREATOR), creatorBalance, "and no release ever succeeds");
    }

    /// @notice A voided schedule can never be started, so expiry closes the door for good.
    function test_aVoidedScheduleCannotBeStarted() public {
        FakeLaunch launch = new FakeLaunch();
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        _fundSchedule(curve, token, launch, 1e18, 0, 2_592_000);

        launch.voidSchedule(vesting);
        vm.expectRevert(ICreatorVesting.ScheduleVoided.selector);
        launch.start(vesting);
    }

    /// @notice **Invariant 23.** `start` is writable exactly once, and only by the launch
    /// that owns the schedule.
    function test_startIsWritableExactlyOnceAndOnlyByTheLaunch() public {
        FakeLaunch launch = new FakeLaunch();
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        _fundSchedule(curve, token, launch, 1e18, 0, 2_592_000);

        // A stranger's `start` touches its own (absent) schedule, not this one.
        vm.prank(OTHER);
        vesting.start();
        assertEq(vesting.scheduleOf(address(launch)).start, 0, "still unset");

        launch.start(vesting);
        uint64 start = vesting.scheduleOf(address(launch)).start;
        assertEq(start, vm.getBlockTimestamp(), "started");

        vm.warp(uint256(start) + 1000);
        vm.expectRevert(ICreatorVesting.AlreadyStarted.selector);
        launch.start(vesting);
        assertEq(vesting.scheduleOf(address(launch)).start, start, "and never moved");
    }

    /// @notice A schedule is created once per launch, and the second attempt is refused.
    function test_aLaunchGetsExactlyOneSchedule() public {
        FakeLaunch launch = new FakeLaunch();
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        _fundSchedule(curve, token, launch, 1e18, 0, 2_592_000);

        vm.prank(TRADER);
        token.transfer(address(launch), 1e18);
        launch.approve(token, address(vesting), 1e18);
        vm.expectRevert(ICreatorVesting.ScheduleExists.selector);
        launch.createSchedule(vesting, CREATOR, address(token), 1e18, 0, 2_592_000);
    }

    /// @notice Every rejected schedule parameter.
    function test_everyInvalidScheduleParameterIsRejected() public {
        FakeLaunch launch = new FakeLaunch();
        (, IERC20 token) = createDefaultLaunch();

        vm.expectRevert(ICreatorVesting.InvalidSchedule.selector);
        launch.createSchedule(vesting, address(0), address(token), 1e18, 0, 2_592_000);

        vm.expectRevert(ICreatorVesting.InvalidSchedule.selector);
        launch.createSchedule(vesting, CREATOR, address(0), 1e18, 0, 2_592_000);

        vm.expectRevert(ICreatorVesting.InvalidSchedule.selector);
        launch.createSchedule(vesting, CREATOR, address(token), 0, 0, 2_592_000);

        vm.expectRevert(ICreatorVesting.InvalidSchedule.selector);
        launch.createSchedule(vesting, CREATOR, address(token), 1e18, 0, 0);
    }

    /// @notice A schedule has to be funded by the caller in the same call, which is what
    /// makes the contract safe to leave permissionless.
    function test_aScheduleMustBeFundedByItsCreatorInTheSameCall() public {
        FakeLaunch launch = new FakeLaunch();
        (, IERC20 token) = createDefaultLaunch();

        // No tokens, no allowance.
        vm.expectRevert();
        launch.createSchedule(vesting, CREATOR, address(token), 1e18, 0, 2_592_000);
        assertEq(vesting.scheduleOf(address(launch)).allocation, 0, "nothing was recorded");
    }

    /// @notice `release` on a launch with no schedule reverts rather than paying nothing.
    function test_releaseOnAnUnknownLaunchReverts() public {
        vm.expectRevert(ICreatorVesting.NoSchedule.selector);
        vesting.release(OTHER);
        assertEq(vesting.releasable(OTHER), 0, "and quotes zero");
    }

    /// @notice `start` and `void` are no-ops for a caller with no schedule, because a
    /// graduation must never be blocked by the absence of a creator allocation.
    function test_startAndVoidAreNoOpsWithoutASchedule() public {
        vm.prank(OTHER);
        vesting.start();
        vm.prank(OTHER);
        vesting.void();
        assertEq(vesting.scheduleOf(OTHER).allocation, 0, "nothing exists");
    }

    /// @notice A schedule cannot be voided twice.
    function test_aScheduleCannotBeVoidedTwice() public {
        FakeLaunch launch = new FakeLaunch();
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        _fundSchedule(curve, token, launch, 1e18, 0, 2_592_000);

        launch.voidSchedule(vesting);
        vm.expectRevert(ICreatorVesting.ScheduleVoided.selector);
        launch.voidSchedule(vesting);
    }

    /// @notice **Invariants 21 and 22 by fuzz** over the whole schedule shape and clock:
    /// releasable is zero before the cliff, monotone afterwards, never above the
    /// allocation, and exactly the allocation at the end.
    function testFuzz_theScheduleIsZeroBeforeTheCliffAndMonotoneAfterwards(
        uint32 cliff,
        uint32 duration,
        uint32 offset
    ) public {
        FakeLaunch launch = new FakeLaunch();
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        uint128 allocation = 1e24;

        cliff = uint32(bound(cliff, 0, PledrinConstants.MAX_VEST_CLIFF));
        duration = uint32(
            bound(duration, PledrinConstants.MIN_VEST_DURATION, PledrinConstants.MAX_VEST_DURATION)
        );

        _fundSchedule(curve, token, launch, allocation, cliff, duration);
        launch.start(vesting);

        uint256 start = vesting.scheduleOf(address(launch)).start;
        uint256 point = bound(offset, 0, uint256(cliff) + duration);

        vm.warp(start + point);
        uint256 releasable = vesting.releasable(address(launch));
        if (point < cliff) {
            assertEq(releasable, 0, "Invariant 21");
        } else {
            assertLe(releasable, allocation, "Invariant 22's ceiling");
        }

        vm.warp(start + uint256(cliff) + duration);
        assertEq(vesting.releasable(address(launch)), allocation, "exactly the allocation");
        assertEq(vesting.release(address(launch)), allocation, "and it all comes out");
    }

    // ------------------------------------------------------------------

    /// @dev Builds a schedule owned by a stand-in launch, funded the way a real launch
    /// funds one: the tokens are bought off a real curve and handed over, so the vesting
    /// contract pulls real supply from the caller that claims the allocation.
    function _fundSchedule(
        BondingCurve curve,
        IERC20 token,
        FakeLaunch launch,
        uint128 allocation,
        uint32 cliff,
        uint32 duration
    ) private {
        vm.deal(TRADER, TRADER.balance + 10 ether);
        vm.prank(TRADER);
        curve.buy{value: 1 ether}(0, vm.getBlockTimestamp());
        vm.prank(TRADER);
        token.transfer(address(launch), allocation);

        launch.approve(token, address(vesting), allocation);
        launch.createSchedule(vesting, CREATOR, address(token), allocation, cliff, duration);
    }
}
