// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {LaunchFactory} from "src/LaunchFactory.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {ILaunchFactory} from "src/interfaces/ILaunchFactory.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {ForkBase} from "./ForkBase.sol";

/// @title Graduation at both ends of the permitted reserve range, and governance, against
/// the live deployment
/// @notice Covers `docs/SPEC.md` sections 8.1, 8.2, 10.1, 12 and 14 against the real
/// Uniswap v4 contracts, and Invariants 22, 39, 42, 43, 50 and 51.
/// @dev The two dust figures asserted here are measured, not derived: **28,428** base
/// units at `virtualEthReserve = 1.25e16` and **240** at `1.25e20`. They bracket the 1,088
/// measured at the default reserve, they are the largest and smallest the permitted range
/// produces, and `docs/SPEC.md` section 8.2 quotes all three. They are asserted as
/// equalities because a drift in either is a change in Uniswap's mint arithmetic or in the
/// curve's terminal price, and both of those are things this suite exists to notice.
contract GraduationRangeForkTest is ForkBase {
    using StateLibrary for IPoolManager;

    /// @notice The smallest permitted raise, 0.1 ETH. The token shortfall is the largest
    /// the range produces and is still four orders of magnitude inside `LP_DUST_MAX`.
    function test_graduatesAtTheSmallestPermittedRaise() public {
        (BondingCurve curve, IERC20 token, uint256 coreId) =
            _graduateAt(PledrinConstants.MIN_VIRTUAL_ETH_RESERVE);

        assertEq(curve.ethTarget(), 0.1 ether, "R_target");
        assertEq(
            token.balanceOf(address(curve)), 28_428, "measured: 28,428 base units at vE0 = 1.25e16"
        );
        assertLe(token.balanceOf(address(curve)), PledrinConstants.LP_DUST_MAX, "Invariant 39");
        assertEq(unassignedEth(curve), 0, "no ETH is stranded");

        (, int24 tick,,) = POOL_MANAGER.getSlot0(curve.poolId());
        assertEq(tick, 207_243, "section 8.1: the terminal tick at the smallest raise");

        (, PositionInfo floorInfo) = POSITION_MANAGER.getPoolAndPositionInfo(coreId + 1);
        assertEq(floorInfo.tickLower(), 207_400, "the floor band starts above the tick");
        assertEq(floorInfo.tickUpper(), 221_200, "and is FLOOR_RANGE_TICKS wide");
        assertGt(floorInfo.tickLower(), tick, "Invariant 42");
    }

    /// @notice The largest permitted raise, 1000 ETH. The token shortfall is the smallest
    /// the range produces.
    function test_graduatesAtTheLargestPermittedRaise() public {
        (BondingCurve curve, IERC20 token, uint256 coreId) =
            _graduateAt(PledrinConstants.MAX_VIRTUAL_ETH_RESERVE);

        assertEq(curve.ethTarget(), 1000 ether, "R_target");
        assertEq(token.balanceOf(address(curve)), 240, "measured: 240 base units at vE0 = 1.25e20");
        assertLe(token.balanceOf(address(curve)), PledrinConstants.LP_DUST_MAX, "Invariant 39");
        assertEq(unassignedEth(curve), 0, "no ETH is stranded");

        (, int24 tick,,) = POOL_MANAGER.getSlot0(curve.poolId());
        assertEq(tick, 115_135, "section 8.1: the terminal tick at the largest raise");

        (, PositionInfo floorInfo) = POSITION_MANAGER.getPoolAndPositionInfo(coreId + 1);
        assertEq(floorInfo.tickLower(), 115_200, "the floor band starts above the tick");
        assertEq(floorInfo.tickUpper(), 129_000, "and is FLOOR_RANGE_TICKS wide");
        assertGt(floorInfo.tickLower(), tick, "Invariant 42");
    }

    /// @notice **Invariant 51 and 50 together, on the live chain.** A configuration change
    /// waits out the full timelock delay, and the pause it installs stops `createLaunch`
    /// and nothing else.
    /// @dev Every warp target is read back out of the timelock's own `readyAt` rather than
    /// computed from a cached `block.timestamp`. Under `via_ir` the optimizer may
    /// rematerialise a `TIMESTAMP` read across a cheatcode call, so
    /// `t0 = block.timestamp; vm.warp(t0 + a); vm.warp(t0 + b)` evaluates the second target
    /// against the post-warp time.
    function test_governanceIsTimelockedAndCannotTouchALaunch() public {
        bytes memory pauseCall = abi.encodeCall(LaunchFactory.setLaunchesPaused, (true));

        vm.prank(ADMIN);
        bytes32 id = timelock.propose(address(factory), pauseCall, bytes32(0));
        uint64 readyAt = timelock.readyAt(id);
        assertEq(
            readyAt,
            vm.getBlockTimestamp() + PledrinConstants.TIMELOCK_DELAY,
            "Invariant 51: 48 hours"
        );

        bytes memory expected = abi.encodeWithSelector(_delayNotElapsedSelector(), id, readyAt);
        vm.prank(ADMIN);
        vm.expectRevert(expected);
        timelock.execute(address(factory), pauseCall, bytes32(0));

        vm.warp(readyAt);
        vm.prank(ADMIN);
        timelock.execute(address(factory), pauseCall, bytes32(0));
        assertTrue(factory.launchesPaused(), "paused");

        vm.prank(CREATOR);
        vm.expectRevert(ILaunchFactory.LaunchesArePaused.selector);
        factory.createLaunch(defaultParams());

        // A launch created before the pause keeps working while paused.
        _executeAfterDelay(abi.encodeCall(LaunchFactory.setLaunchesPaused, (false)), bytes32("un"));
        (BondingCurve curve, IERC20 token) = createLaunch(defaultParams());
        _executeAfterDelay(pauseCall, bytes32("again"));
        assertTrue(factory.launchesPaused(), "paused again");

        vm.prank(TRADER);
        uint256 bought = curve.buy{value: 1 ether}(0, vm.getBlockTimestamp());
        assertGt(bought, 0, "buying still works while paused");

        vm.prank(TRADER);
        token.approve(address(curve), bought);
        vm.prank(TRADER);
        assertGt(curve.sell(bought / 2, 0, vm.getBlockTimestamp()), 0, "and selling");

        vm.prank(OTHER);
        curve.donate{value: 1 ether}();
        assertGt(curve.claimProtocolFees(), 0, "and claiming");

        buyToCap(curve);
        vm.prank(TRADER);
        curve.graduate();
        assertEq(
            uint8(curve.state()),
            uint8(IBondingCurve.State.Graduated),
            "and graduating, all while new launches are paused"
        );
    }

    /// @notice **Invariant 22 on the live chain.** The creator's allocation vests linearly
    /// from graduation and sums to exactly the allocation.
    function test_vestingReleasesLinearlyAfterGraduation() public {
        ILaunchFactory.LaunchParams memory params = defaultParams();
        params.creatorFirstBuyWei = 0.009 ether;
        (BondingCurve curve, IERC20 token) = createLaunch(params);

        uint256 allocation = vesting.scheduleOf(address(curve)).allocation;
        assertGt(allocation, 0, "an allocation was delivered");
        assertLe(allocation, PledrinConstants.CREATOR_FIRST_BUY_MAX, "Invariant 24");
        assertEq(vesting.releasable(address(curve)), 0, "nothing before graduation");

        buyToCap(curve);
        vm.prank(TRADER);
        curve.graduate();

        uint64 start = vesting.scheduleOf(address(curve)).start;
        assertEq(start, vm.getBlockTimestamp(), "the clock starts at graduation");

        vm.warp(uint256(start) + DEFAULT_CLIFF - 1);
        assertEq(vesting.releasable(address(curve)), 0, "one second before the cliff");

        vm.warp(uint256(start) + DEFAULT_CLIFF + DEFAULT_VEST_DURATION / 2);
        assertApproxEqRel(vesting.releasable(address(curve)), allocation / 2, 1e12, "half way");
        uint256 released = vesting.release(address(curve));
        assertEq(token.balanceOf(CREATOR), released, "the creator was paid");

        vm.warp(uint256(start) + DEFAULT_CLIFF + DEFAULT_VEST_DURATION);
        assertEq(vesting.releasable(address(curve)), allocation - released, "the tail");
        vesting.release(address(curve));
        assertEq(token.balanceOf(CREATOR), allocation, "Invariant 22: exactly the allocation");
        assertEq(vesting.releasable(address(curve)), 0, "and nothing more, ever");
    }

    // ------------------------------------------------------------------

    function _graduateAt(uint128 virtualEthReserve)
        private
        returns (BondingCurve curve, IERC20 token, uint256 coreId)
    {
        ILaunchFactory.LaunchParams memory params = defaultParams();
        params.name = "Edge";
        params.symbol = "EDGE";
        params.virtualEthReserve = virtualEthReserve;
        (curve, token) = createLaunch(params);

        buyToCap(curve);
        coreId = POSITION_MANAGER.nextTokenId();
        vm.prank(TRADER);
        curve.graduate();

        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "Graduated");
        assertEq(curve.ethReserve(), 0, "Invariant 43");
        assertEq(ownerOfPosition(coreId), address(lock), "the core position is locked");
        assertEq(ownerOfPosition(coreId + 1), address(lock), "and the floor position");
    }

    function _executeAfterDelay(bytes memory data, bytes32 salt) private {
        vm.prank(ADMIN);
        bytes32 id = timelock.propose(address(factory), data, salt);
        vm.warp(timelock.readyAt(id));
        vm.prank(ADMIN);
        timelock.execute(address(factory), data, salt);
    }

    function _delayNotElapsedSelector() private pure returns (bytes4) {
        return bytes4(keccak256("DelayNotElapsed(bytes32,uint64)"));
    }
}
