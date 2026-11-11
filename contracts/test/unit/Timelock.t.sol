// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {LaunchFactory} from "src/LaunchFactory.sol";
import {Timelock} from "src/Timelock.sol";
import {ILaunchFactory} from "src/interfaces/ILaunchFactory.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {PledrinTestBase} from "../base/PledrinTestBase.sol";

/// @title `Timelock`, and what a pause does and does not stop
/// @notice Covers `docs/SPEC.md` section 14 and Invariants 50, 51 and 52.
/// @dev Every warp target is read back out of the timelock's own `readyAt`, never computed
/// from a cached `block.timestamp`. That is not stylistic: with the IR pipeline the
/// optimizer may rematerialise a `TIMESTAMP` read across a cheatcode call, so
/// `t0 = block.timestamp; vm.warp(t0 + a); vm.warp(t0 + b);` evaluates the second target
/// against the post-warp time. `foundry.toml` records this next to `via_ir`.
contract TimelockTest is PledrinTestBase {
    bytes internal pauseCall = abi.encodeCall(LaunchFactory.setLaunchesPaused, (true));

    /// @notice The delay is the constant of section 15.1 and the admin is the constructor's
    /// argument.
    function test_theDelayAndTheAdminAreFixedAtDeployment() public view {
        assertEq(timelock.DELAY(), PledrinConstants.TIMELOCK_DELAY, "48 hours");
        assertEq(timelock.DELAY(), 172_800, "in seconds");
        assertEq(timelock.admin(), ADMIN, "admin");
    }

    /// @notice A zero admin is refused, because an operation could then never execute.
    function test_aZeroAdminIsRefused() public {
        vm.expectRevert(Timelock.InvalidAdmin.selector);
        new Timelock(address(0));
    }

    /// @notice **Invariant 51.** An operation cannot execute before `readyAt`, including
    /// one second before, and executes exactly at it.
    function test_anOperationWaitsOutTheFullDelay() public {
        vm.prank(ADMIN);
        bytes32 id = timelock.propose(address(factory), pauseCall, bytes32(0));
        uint64 readyAt = timelock.readyAt(id);

        assertEq(readyAt, vm.getBlockTimestamp() + PledrinConstants.TIMELOCK_DELAY, "readyAt");

        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(Timelock.DelayNotElapsed.selector, id, readyAt));
        timelock.execute(address(factory), pauseCall, bytes32(0));

        vm.warp(uint256(readyAt) - 1);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(Timelock.DelayNotElapsed.selector, id, readyAt));
        timelock.execute(address(factory), pauseCall, bytes32(0));

        vm.warp(readyAt);
        vm.prank(ADMIN);
        timelock.execute(address(factory), pauseCall, bytes32(0));

        assertTrue(factory.launchesPaused(), "the operation took effect");
        assertEq(timelock.readyAt(id), 0, "and is no longer pending");
    }

    /// @notice An operation executes at most once: the pending record is cleared before
    /// the call.
    function test_anOperationExecutesAtMostOnce() public {
        vm.prank(ADMIN);
        bytes32 id = timelock.propose(address(factory), pauseCall, bytes32(0));
        vm.warp(timelock.readyAt(id));
        vm.prank(ADMIN);
        timelock.execute(address(factory), pauseCall, bytes32(0));

        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(Timelock.NotProposed.selector, id));
        timelock.execute(address(factory), pauseCall, bytes32(0));
    }

    /// @notice Only the admin may propose, cancel or execute.
    function test_onlyTheAdminMayDriveTheTimelock() public {
        vm.prank(OTHER);
        vm.expectRevert(Timelock.NotAdmin.selector);
        timelock.propose(address(factory), pauseCall, bytes32(0));

        vm.prank(ADMIN);
        bytes32 id = timelock.propose(address(factory), pauseCall, bytes32(0));

        vm.prank(OTHER);
        vm.expectRevert(Timelock.NotAdmin.selector);
        timelock.cancel(id);

        vm.warp(timelock.readyAt(id));
        vm.prank(OTHER);
        vm.expectRevert(Timelock.NotAdmin.selector);
        timelock.execute(address(factory), pauseCall, bytes32(0));
    }

    /// @notice The same operation cannot be queued twice, and a salt is what distinguishes
    /// two otherwise identical ones.
    function test_aSaltDistinguishesTwoIdenticalOperations() public {
        vm.prank(ADMIN);
        bytes32 id = timelock.propose(address(factory), pauseCall, bytes32(0));

        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(Timelock.AlreadyProposed.selector, id));
        timelock.propose(address(factory), pauseCall, bytes32(0));

        vm.prank(ADMIN);
        bytes32 other = timelock.propose(address(factory), pauseCall, bytes32("second"));
        assertTrue(other != id, "a different salt is a different operation");
        assertEq(
            timelock.operationId(address(factory), pauseCall, bytes32("second")),
            other,
            "and the id is a pure function of the three"
        );
    }

    /// @notice A cancelled operation cannot execute, and only a pending one can be
    /// cancelled.
    function test_aCancelledOperationCannotExecute() public {
        vm.prank(ADMIN);
        bytes32 id = timelock.propose(address(factory), pauseCall, bytes32(0));
        uint64 readyAt = timelock.readyAt(id);

        vm.prank(ADMIN);
        timelock.cancel(id);
        assertEq(timelock.readyAt(id), 0, "no longer pending");

        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(Timelock.NotProposed.selector, id));
        timelock.cancel(id);

        vm.warp(readyAt);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(Timelock.NotProposed.selector, id));
        timelock.execute(address(factory), pauseCall, bytes32(0));
        assertFalse(factory.launchesPaused(), "and had no effect");
    }

    /// @notice An operation that was never proposed cannot execute, however long anyone
    /// waits.
    function test_anUnproposedOperationCannotExecute() public {
        bytes memory data = abi.encodeCall(LaunchFactory.setLaunchesPaused, (true));
        bytes32 id = timelock.operationId(address(factory), data, bytes32("unknown"));

        vm.warp(vm.getBlockTimestamp() + 10 * PledrinConstants.TIMELOCK_DELAY);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(Timelock.NotProposed.selector, id));
        timelock.execute(address(factory), data, bytes32("unknown"));
    }

    /// @notice A target that reverts bubbles its error up, and the operation is consumed
    /// either way, so a failed operation has to be proposed again.
    function test_aFailingTargetBubblesUpAndConsumesTheOperation() public {
        ILaunchFactory.FeeConfig memory bad = defaultFeeConfig();
        bad.totalFeeBps = PledrinConstants.MAX_TOTAL_FEE_BPS + 1;
        bytes memory data = abi.encodeCall(LaunchFactory.setFeeConfig, (bad));

        vm.prank(ADMIN);
        bytes32 id = timelock.propose(address(factory), data, bytes32(0));
        vm.warp(timelock.readyAt(id));

        vm.prank(ADMIN);
        vm.expectRevert(ILaunchFactory.InvalidFeeConfig.selector);
        timelock.execute(address(factory), data, bytes32(0));
    }

    /// @notice The admin rotation is itself an operation, so it waits out the delay too.
    function test_theAdminRotationIsItselfTimelocked() public {
        vm.expectRevert(Timelock.NotTimelock.selector);
        timelock.setAdmin(OTHER);

        vm.prank(ADMIN);
        vm.expectRevert(Timelock.NotTimelock.selector);
        timelock.setAdmin(OTHER);

        bytes memory data = abi.encodeCall(Timelock.setAdmin, (OTHER));
        vm.prank(ADMIN);
        bytes32 id = timelock.propose(address(timelock), data, bytes32(0));
        vm.warp(timelock.readyAt(id));
        vm.prank(ADMIN);
        timelock.execute(address(timelock), data, bytes32(0));

        assertEq(timelock.admin(), OTHER, "rotated");
        vm.prank(ADMIN);
        vm.expectRevert(Timelock.NotAdmin.selector);
        timelock.propose(address(factory), pauseCall, bytes32(0));
    }

    /// @notice The rotation cannot hand the timelock to nobody.
    function test_theAdminCannotBeRotatedToZero() public {
        bytes memory data = abi.encodeCall(Timelock.setAdmin, (address(0)));
        vm.prank(ADMIN);
        bytes32 id = timelock.propose(address(timelock), data, bytes32(0));
        vm.warp(timelock.readyAt(id));

        vm.prank(ADMIN);
        vm.expectRevert(Timelock.InvalidAdmin.selector);
        timelock.execute(address(timelock), data, bytes32(0));
        assertEq(timelock.admin(), ADMIN, "unchanged");
    }

    /// @notice The factory's three setters are reachable only through the timelock.
    function test_theFactorySettersAreOwnerOnly() public {
        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OTHER));
        factory.setLaunchesPaused(true);

        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OTHER));
        factory.setProtocolTreasury(OTHER);

        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OTHER));
        factory.setFeeConfig(defaultFeeConfig());

        // Even the timelock's admin cannot call them directly.
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ADMIN));
        factory.setLaunchesPaused(true);
    }

    /// @notice **Invariant 50.** A pause stops `createLaunch` and nothing else: buying,
    /// selling, donating, graduating, expiring, every claim and `release` all keep working
    /// while paused.
    function test_aPauseStopsOnlyTheCreationOfNewLaunches() public {
        ILaunchFactory.LaunchParams memory params = defaultParams();
        params.bondWei = 0.4 ether;
        params.creatorFirstBuyWei = 0.009 ether;
        (BondingCurve curve, IERC20 token) = createLaunch(params);
        (BondingCurve expiring,) = createDefaultLaunch();

        setLaunchesPaused(true);
        assertTrue(factory.launchesPaused(), "paused");

        vm.prank(CREATOR);
        vm.expectRevert(ILaunchFactory.LaunchesArePaused.selector);
        factory.createLaunch{value: 0}(defaultParams());

        // Buying.
        uint256 bought = buy(curve, TRADER, 1 ether);
        assertGt(bought, 0, "buy still works");
        // Selling.
        assertGt(sell(curve, TRADER, bought / 4), 0, "sell still works");
        // Donating.
        vm.prank(OTHER);
        curve.donate{value: 1 ether}();
        // Claiming the protocol bucket.
        assertGt(curve.claimProtocolFees(), 0, "claimProtocolFees still works");
        // Graduating.
        buyToCap(curve);
        vm.prank(GRADUATOR);
        curve.graduate();
        assertEq(uint8(curve.state()), 2, "graduate still works");
        // The remaining claims.
        assertGt(curve.claimCreatorFees(), 0, "claimCreatorFees still works");
        assertGt(curve.claimBond(), 0, "claimBond still works");
        assertGt(curve.claimBounty(GRADUATOR), 0, "claimBounty still works");
        // Releasing vested tokens.
        uint64 start = vesting.scheduleOf(address(curve)).start;
        vm.warp(uint256(start) + DEFAULT_CLIFF + DEFAULT_VEST_DURATION);
        assertGt(vesting.release(address(curve)), 0, "release still works");
        assertEq(token.balanceOf(CREATOR), vesting.scheduleOf(address(curve)).allocation, "paid");
        // Expiring the launch that never reached its cap. Its deadline is long past by now.
        expiring.expire();
        assertEq(uint8(expiring.state()), 3, "expire still works");

        // And unpausing lets launches resume.
        setLaunchesPaused(false);
        (BondingCurve resumed,) = createDefaultLaunch();
        assertTrue(factory.isLaunch(address(resumed)), "launches resume");
    }

    /// @notice An operation's `readyAt` is always exactly `DELAY` after its proposal,
    /// whatever the clock and whatever the operation.
    function testFuzz_everyProposalWaitsExactlyTheDelay(uint32 jump, bytes32 salt) public {
        vm.warp(vm.getBlockTimestamp() + bound(jump, 0, 365 days));

        vm.prank(ADMIN);
        bytes32 id = timelock.propose(address(factory), pauseCall, salt);
        assertEq(
            timelock.readyAt(id),
            vm.getBlockTimestamp() + PledrinConstants.TIMELOCK_DELAY,
            "Invariant 51"
        );

        // `readyAt` is read into a local first: `vm.prank` applies to the next call, and
        // an argument that is itself an external call would consume it.
        uint64 readyAt = timelock.readyAt(id);
        bytes memory expected =
            abi.encodeWithSelector(Timelock.DelayNotElapsed.selector, id, readyAt);
        vm.warp(uint256(readyAt) - 1);
        vm.prank(ADMIN);
        vm.expectRevert(expected);
        timelock.execute(address(factory), pauseCall, salt);
    }
}
