// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {ILaunchFactory} from "src/interfaces/ILaunchFactory.sol";
import {ILiquidityLock} from "src/interfaces/ILiquidityLock.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";
import {TickAlign} from "src/libraries/TickAlign.sol";

import {PoolSwapHelper} from "../helpers/PoolSwapHelper.sol";
import {ForkBase} from "./ForkBase.sol";

/// @title Graduation end to end against the live Uniswap v4 deployment
/// @notice Covers `docs/SPEC.md` sections 8.1, 8.2, 8.4, 8.5, 9, 10.1 and 11.4 against the
/// real PoolManager, PositionManager and Permit2, and Invariants 5, 13, 24, 25, 26, 27,
/// 33, 36, 38, 39, 40, 41, 42, 43, 45 and 46.
/// @dev Every number asserted here is a *measured* value, not an expected one. The three
/// that matter most, and the reason they are equalities rather than bounds:
///
/// - the core mint leaves **1,088 base units** of `LP_SUPPLY` unconsumed at the default
///   `virtualEthReserve`. A bound against `LP_DUST_MAX` would hide a drift of four orders
///   of magnitude;
/// - the floor position occupies **`[170400, 184200]`**, strictly above the terminal tick
///   of **170352**, and consumes **zero** base units of the token. An inverted range would
///   mint a token-funded sell wall instead of an ETH floor bid, and an earlier revision of
///   the specification had exactly that;
/// - a graduated launch keeps **zero** ETH beyond its unclaimed buckets.
contract GraduationForkTest is ForkBase {
    using StateLibrary for IPoolManager;

    /// @notice The whole lifecycle on the real contracts: launch, bond, creator first buy,
    /// cap, graduation, both locked positions, and all four claims.
    function test_launchThroughGraduationOnTheRealDeployment() public {
        ILaunchFactory.LaunchParams memory params = defaultParams();
        params.bondWei = 0.4 ether;
        params.creatorFirstBuyWei = 0.009 ether;
        (BondingCurve curve, IERC20 token) = createLaunch(params);

        // The launch transaction opened the pool at the curve's terminal price.
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Live), "Live");
        assertEq(uint8(curve.bondState()), uint8(IBondingCurve.BondState.Bonded), "Bonded");
        assertEq(curve.ethTarget(), 4 ether, "R_target at the default reserve");
        assertEq(
            curve.sqrtPriceTerminal(),
            5000 * (uint160(1) << 96),
            "section 8.1: exactly 5000 * 2**96 at the default reserve"
        );
        (uint160 openingPrice, int24 openingTick,,) = POOL_MANAGER.getSlot0(curve.poolId());
        assertEq(openingPrice, curve.sqrtPriceTerminal(), "Invariant 40 at launch");
        assertEq(openingTick, DEFAULT_TERMINAL_TICK, "the measured terminal tick");
        assertEq(POOL_MANAGER.getLiquidity(curve.poolId()), 0, "and no liquidity");

        // The creator's first buy went to vesting, not to the creator.
        uint256 allocation = vesting.scheduleOf(address(curve)).allocation;
        assertGt(allocation, 0, "an allocation was delivered");
        assertLe(allocation, PledrinConstants.CREATOR_FIRST_BUY_MAX, "Invariant 24");
        assertEq(vesting.scheduleOf(address(curve)).start, 0, "with the clock unstarted");
        assertEq(token.balanceOf(CREATOR), 0, "the creator holds no token");
        assertEq(
            token.balanceOf(address(curve)),
            PledrinConstants.TOTAL_SUPPLY - curve.tokensSold(),
            "Invariant 5"
        );

        buyToCap(curve);
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduating), "Graduating");
        assertGe(curve.ethReserve(), curve.ethTarget(), "Invariant 13");

        uint256 coreId = POSITION_MANAGER.nextTokenId();
        uint256 creatorBalanceBefore = CREATOR.balance;
        uint256 treasuryBalanceBefore = TREASURY.balance;

        vm.prank(TRADER);
        curve.graduate();

        // Invariant 43: the reserve and the protection pool are gone, into the positions.
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "Graduated");
        assertEq(curve.ethReserve(), 0, "Invariant 43: the reserve is drained");
        assertEq(curve.protectionEth(), 0, "and the protection pool deposited");
        assertEq(
            unassignedEth(curve),
            0,
            "measured: a graduated launch keeps no ETH beyond its unclaimed buckets"
        );

        // Invariant 39: the measured token dust at the default reserve.
        assertEq(
            token.balanceOf(address(curve)),
            1088,
            "measured against the live PositionManager: 1,088 base units at vE0 = 5e17"
        );
        assertLe(token.balanceOf(address(curve)), PledrinConstants.LP_DUST_MAX, "Invariant 39");

        // Invariant 46: both positions are owned by the lock and registered to the launch.
        assertEq(ownerOfPosition(coreId), address(lock), "the core position is locked");
        assertEq(ownerOfPosition(coreId + 1), address(lock), "and so is the floor position");
        assertEq(
            uint8(lock.positionOf(coreId).kind),
            uint8(ILiquidityLock.PositionKind.Core),
            "core kind"
        );
        assertEq(
            uint8(lock.positionOf(coreId + 1).kind),
            uint8(ILiquidityLock.PositionKind.Floor),
            "floor kind"
        );

        // Invariant 40 and section 8.5: the mints left the price and the tick where the
        // launch transaction put them.
        (uint160 priceAfter, int24 tickAfter,,) = POOL_MANAGER.getSlot0(curve.poolId());
        assertEq(priceAfter, curve.sqrtPriceTerminal(), "the price is unmoved");
        assertEq(tickAfter, DEFAULT_TERMINAL_TICK, "and so is the tick");

        // Invariant 45: nothing was pushed to the creator, the treasury or the caller.
        assertEq(CREATOR.balance, creatorBalanceBefore, "the creator was paid nothing");
        assertEq(TREASURY.balance, treasuryBalanceBefore, "nor the treasury");
        assertEq(uint8(curve.bondState()), uint8(IBondingCurve.BondState.Returned), "Returned");
        assertEq(curve.pendingBondWei(), 0.4 ether, "the bond is credited, not pushed");
        assertGt(curve.pendingBountyWei(TRADER), 0, "and so is the bounty");
        assertEq(
            vesting.scheduleOf(address(curve)).start,
            vm.getBlockTimestamp(),
            "the vesting clock started"
        );

        // The four claims, each to its own destination.
        uint256 bounty = curve.pendingBountyWei(TRADER);
        curve.claimBounty(TRADER);
        uint256 creatorFees = curve.claimCreatorFees();
        curve.claimBond();
        curve.claimProtocolFees();

        assertEq(
            CREATOR.balance,
            creatorBalanceBefore + creatorFees + 0.4 ether,
            "the creator received exactly their fees and their bond"
        );
        assertGt(TREASURY.balance, treasuryBalanceBefore, "the treasury was paid");
        assertGt(bounty, 0, "the bounty was non-zero");
        assertEq(address(curve).balance, 0, "and the launch now holds nothing at all");
    }

    /// @notice **Invariant 42 and section 10.1.** The floor position is an ETH bid in the
    /// band `[170400, 184200]`, strictly above the current tick, and it consumes no token.
    /// @dev The range is the one measured against the deployed PoolManager with a 1 ETH
    /// probe in `test/fork/V4Assumptions.t.sol`, which also measured that the mirrored
    /// range `[156200, 170000]` requires `currency1` instead and that an ETH-only mint of
    /// it reverts `MaximumAmountExceeded`. This test is the same property as performed by
    /// `graduate` itself.
    function test_theFloorPositionIsAnEthBidAboveTheCurrentTick() public {
        (BondingCurve curve, IERC20 token) = createLaunch(defaultParams());
        buyToCap(curve);

        uint256 coreId = POSITION_MANAGER.nextTokenId();
        uint256 protection = curve.protectionEth();
        uint256 curveTokensBefore = token.balanceOf(address(curve));
        assertGt(protection, 0, "there is a protection pool to deposit");

        vm.prank(TRADER);
        curve.graduate();

        (, PositionInfo floorInfo) = POSITION_MANAGER.getPoolAndPositionInfo(coreId + 1);
        assertEq(floorInfo.tickLower(), 170_400, "measured floor tickLower");
        assertEq(floorInfo.tickUpper(), 184_200, "measured floor tickUpper");
        assertGt(
            floorInfo.tickLower(),
            DEFAULT_TERMINAL_TICK,
            "Invariant 42: strictly above the current tick"
        );
        assertEq(
            floorInfo.tickUpper() - floorInfo.tickLower(),
            PledrinConstants.FLOOR_RANGE_TICKS,
            "the band is FLOOR_RANGE_TICKS wide"
        );
        assertLe(
            floorInfo.tickUpper(),
            TickAlign.down(TickMath.MAX_TICK, PledrinConstants.POOL_TICK_SPACING),
            "inside the aligned maximum tick"
        );
        assertGt(POSITION_MANAGER.getPositionLiquidity(coreId + 1), 0, "the floor has liquidity");

        // Funded in `currency0` alone: every base unit that left the curve went into the
        // core position, and the token approval was revoked before the floor mint.
        (, PositionInfo coreInfo) = POSITION_MANAGER.getPoolAndPositionInfo(coreId);
        assertEq(coreInfo.tickLower(), -887_200, "core tickLower");
        assertEq(coreInfo.tickUpper(), 887_200, "core tickUpper");
        assertEq(
            curveTokensBefore - token.balanceOf(address(curve)),
            PledrinConstants.LP_SUPPLY - 1088,
            "measured: the core mint consumed LP_SUPPLY less 1,088 base units"
        );
        assertEq(token.balanceOf(address(lock)), 0, "the lock holds no token");
        assertEq(
            token.allowance(address(curve), address(PERMIT2)),
            0,
            "and the token approval is revoked"
        );
    }

    /// @notice **Invariant 39's last clause.** The core position's liquidity is the largest
    /// value whose `currency1` requirement fits in `LP_SUPPLY`: one more unit would need
    /// more.
    function test_theCorePositionIsTheLargestLiquidityThatFits() public {
        (BondingCurve curve,) = createLaunch(defaultParams());
        buyToCap(curve);

        uint256 coreId = POSITION_MANAGER.nextTokenId();
        vm.prank(TRADER);
        curve.graduate();

        uint128 liquidity = POSITION_MANAGER.getPositionLiquidity(coreId);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(-887_200);
        uint160 terminal = curve.sqrtPriceTerminal();

        assertEq(
            liquidity,
            LiquidityAmounts.getLiquidityForAmount1(
                sqrtLower, terminal, PledrinConstants.LP_SUPPLY
            ),
            "the liquidity is sized from LP_SUPPLY"
        );
        assertLe(
            SqrtPriceMath.getAmount1Delta(sqrtLower, terminal, liquidity, true),
            PledrinConstants.LP_SUPPLY,
            "and fits inside it"
        );
        assertGt(
            SqrtPriceMath.getAmount1Delta(sqrtLower, terminal, liquidity + 1, true),
            PledrinConstants.LP_SUPPLY,
            "one more unit of liquidity would not"
        );
    }

    /// @notice **Invariant 60 on the real PositionManager.** A launch-token donation of any
    /// size, made by an ordinary holder before `graduate()`, changes nothing about the
    /// graduation: the same position id, the same ETH and token consumed, the same floor
    /// funding, and the donation still sitting in the curve afterwards.
    /// @dev A differential test, run twice from the same forked state: once untouched, then
    /// rolled back and again with the donation in place. Asserting a single donated
    /// graduation would prove nothing, because the implementation this guards against — one
    /// absolute `token.balanceOf` after the mint in place of the delta across it — fails
    /// only by *comparison* with the undonated run. `D` here is 5,000 whole tokens, five
    /// hundred million times `LP_DUST_MAX`, so the post-mint balance the broken version
    /// would have measured is far outside the dust bound and would have reverted the
    /// graduation outright. `test/unit/BondingCurveDonationNeutrality.t.sol` fuzzes `D`
    /// across the whole donatable range; this is the same property against the real mint.
    function test_aTokenDonationChangesNothingAboutTheRealGraduationMint() public {
        (BondingCurve curve, IERC20 token) = createLaunch(defaultParams());
        buyToCap(curve);

        uint256 donation = 5000e18;
        uint256 coreId = POSITION_MANAGER.nextTokenId();
        uint256 snapshot = vm.snapshotState();

        vm.prank(TRADER);
        curve.graduate();
        uint128 baselineLiquidity = POSITION_MANAGER.getPositionLiquidity(coreId);
        uint128 baselineFloorLiquidity = POSITION_MANAGER.getPositionLiquidity(coreId + 1);
        uint256 baselineDust = token.balanceOf(address(curve));
        uint256 baselineEthToPool = address(POOL_MANAGER).balance;

        assertTrue(vm.revertToState(snapshot), "the pre-graduation state was restored");
        assertEq(
            token.balanceOf(address(curve)),
            PledrinConstants.LP_SUPPLY,
            "back at the cap holding exactly the LP allocation"
        );

        vm.prank(TRADER);
        token.transfer(address(curve), donation);
        vm.prank(TRADER);
        curve.graduate();

        assertEq(
            POSITION_MANAGER.getPositionLiquidity(coreId),
            baselineLiquidity,
            "Invariant 60: the core position is identical"
        );
        assertEq(
            POSITION_MANAGER.getPositionLiquidity(coreId + 1),
            baselineFloorLiquidity,
            "Invariant 60: and so is the floor position"
        );
        assertEq(
            address(POOL_MANAGER).balance,
            baselineEthToPool,
            "Invariant 60: the same ETH reached the pool"
        );
        assertEq(
            token.balanceOf(address(curve)),
            baselineDust + donation,
            "Invariant 60: the donation is still held by the curve"
        );
        assertEq(baselineDust, 1088, "the measured core-mint dust is unchanged by all of this");
        assertGt(
            token.balanceOf(address(curve)),
            PledrinConstants.LP_DUST_MAX,
            "an absolute post-mint balance read would have reverted this graduation"
        );
        assertEq(ownerOfPosition(coreId), address(lock), "both positions are still locked");
        assertEq(ownerOfPosition(coreId + 1), address(lock), "both positions are still locked");
    }

    /// @notice **Invariants 40 and 41.** A griefer moves the price of the empty pool; the
    /// graduation restores it with a swap that settles for nothing and then mints.
    /// @dev The grief is performed through the real PoolManager, so the restoration is the
    /// real `Pool.swap` walking the real tick bitmap.
    function test_aGriefedPoolPriceIsRestoredBeforeTheMints() public {
        (BondingCurve curve, IERC20 token) = createLaunch(defaultParams());
        buyToCap(curve);

        PoolKey memory key = poolKeyFor(address(token), PledrinConstants.POOL_TICK_SPACING);
        PoolSwapHelper swapper = new PoolSwapHelper(POOL_MANAGER);
        swapper.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(100_000)
            })
        );
        (uint160 griefed,,,) = POOL_MANAGER.getSlot0(curve.poolId());
        assertEq(griefed, TickMath.getSqrtPriceAtTick(100_000), "the grief took effect");

        uint256 curveBalanceBefore = address(curve).balance;
        uint256 reserve = curve.ethReserve();
        uint256 protection = curve.protectionEth();
        uint256 coreId = POSITION_MANAGER.nextTokenId();

        vm.prank(TRADER);
        curve.graduate();

        (uint160 restored, int24 tickAfter,,) = POOL_MANAGER.getSlot0(curve.poolId());
        assertEq(restored, curve.sqrtPriceTerminal(), "the price was restored");
        assertEq(tickAfter, DEFAULT_TERMINAL_TICK, "and so was the tick");
        assertEq(ownerOfPosition(coreId), address(lock), "the core position is locked");
        assertEq(ownerOfPosition(coreId + 1), address(lock), "and the floor position");
        assertEq(
            curveBalanceBefore - address(curve).balance,
            reserve + protection,
            "Invariant 41: the restoring swap cost the curve nothing"
        );
    }

    /// @notice **Invariant 38.** After `ALT_DELAY` a launch can graduate on an
    /// uninitialised alternate tick spacing, and only on one.
    function test_graduateAltOpensAnUninitialisedPoolOnAnotherSpacing() public {
        (BondingCurve curve, IERC20 token) = createLaunch(defaultParams());
        buyToCap(curve);

        vm.expectRevert(IBondingCurve.AltDelayNotElapsed.selector);
        curve.graduateAlt(100);

        vm.warp(curve.capReachedAt() + PledrinConstants.ALT_DELAY);

        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.InvalidTickSpacing.selector, 9));
        curve.graduateAlt(9);
        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.InvalidTickSpacing.selector, 201));
        curve.graduateAlt(201);
        // The primary spacing is outside the alternate window, which stops at 199, so the
        // range check rejects it before the pool-state check is reached. The alternate key
        // can therefore never be the canonical key the launch transaction initialised.
        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.InvalidTickSpacing.selector, 200));
        curve.graduateAlt(uint24(int24(PledrinConstants.POOL_TICK_SPACING)));

        uint256 coreId = POSITION_MANAGER.nextTokenId();
        curve.graduateAlt(100);

        PoolKey memory altKey = poolKeyFor(address(token), 100);
        (uint160 price, int24 tick,,) = POOL_MANAGER.getSlot0(altKey.toId());
        assertEq(price, curve.sqrtPriceTerminal(), "the alt pool opened at the terminal price");
        assertEq(tick, DEFAULT_TERMINAL_TICK, "at the same tick");
        assertEq(ownerOfPosition(coreId), address(lock), "the core position is locked");
        assertEq(ownerOfPosition(coreId + 1), address(lock), "and the floor position");
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "Graduated");
        assertEq(curve.ethReserve(), 0, "Invariant 43");
        assertLe(token.balanceOf(address(curve)), PledrinConstants.LP_DUST_MAX, "Invariant 39");

        // Invariant 36: the two together succeed at most once.
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Graduated)
        );
        curve.graduate();
    }

    /// @notice Section 9 and decision 1 of `docs/OPEN_DECISIONS.md`: the lock's one
    /// permissionless function collects a locked position's fees and reinvests them into
    /// the same position in a single `modifyLiquidities` call, with no intermediate
    /// recipient, and retains the ratio residual forever.
    function test_compoundGrowsTheLockedPositionAndRetainsTheResidual() public {
        (BondingCurve curve, IERC20 token) = createLaunch(defaultParams());
        buyToCap(curve);
        uint256 coreId = POSITION_MANAGER.nextTokenId();
        vm.prank(TRADER);
        curve.graduate();

        PoolKey memory key = poolKeyFor(address(token), PledrinConstants.POOL_TICK_SPACING);
        PoolSwapHelper swapper = new PoolSwapHelper(POOL_MANAGER);
        _tradeBothWays(swapper, key, token);

        uint128 before = POSITION_MANAGER.getPositionLiquidity(coreId);
        uint128 added = lock.compound(coreId);

        assertGt(added, 0, "the fees bought liquidity");
        assertEq(
            POSITION_MANAGER.getPositionLiquidity(coreId),
            before + added,
            "which went into the same position"
        );
        assertEq(ownerOfPosition(coreId), address(lock), "the owner never changes");

        // Immediately afterwards there is nothing left to compound, and the call refuses
        // rather than crediting fees out of the position without reinvesting them.
        vm.expectRevert(abi.encodeWithSelector(ILiquidityLock.NothingToCompound.selector, coreId));
        lock.compound(coreId);

        // A second round works and leaves the first round's residual untouched.
        uint256 residualEth = address(lock).balance;
        uint256 residualToken = token.balanceOf(address(lock));
        _tradeBothWays(swapper, key, token);
        assertGt(lock.compound(coreId), 0, "the second round compounded");
        assertGe(address(lock).balance, residualEth, "the ETH residual never left the lock");
        assertGe(token.balanceOf(address(lock)), residualToken, "nor the token residual");
    }

    /// @notice **Invariant 37's second half and section 8.4.** `abortGraduation` reverts
    /// before the grace window closes and succeeds exactly at it, returning the bond and
    /// donating the protection pool to holders.
    function test_abortGraduationAfterTheGraceWindow() public {
        ILaunchFactory.LaunchParams memory params = defaultParams();
        params.bondWei = 0.4 ether;
        (BondingCurve curve, IERC20 token) = createLaunch(params);
        buyToCap(curve);

        uint256 capReachedAt = curve.capReachedAt();
        assertGt(capReachedAt, 0, "capReachedAt is written when the cap is reached");

        vm.expectRevert(IBondingCurve.GraceNotElapsed.selector);
        curve.abortGraduation();
        vm.warp(capReachedAt + PledrinConstants.GRAD_GRACE - 1);
        vm.expectRevert(IBondingCurve.GraceNotElapsed.selector);
        curve.abortGraduation();

        uint256 reserve = curve.ethReserve();
        uint256 protection = curve.protectionEth();
        vm.warp(capReachedAt + PledrinConstants.GRAD_GRACE);
        curve.abortGraduation();

        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Stalled), "Stalled");
        assertEq(curve.ethReserve(), reserve + protection, "the protection pool was donated");
        assertEq(curve.protectionEth(), 0, "and its bucket emptied");
        assertEq(uint8(curve.bondState()), uint8(IBondingCurve.BondState.Returned), "Invariant 26");
        assertEq(curve.claimBond(), 0.4 ether, "the bond is returned, not forfeited");
        assertGt(curve.claimCreatorFees(), 0, "and the creator's fees become claimable");

        // Invariant 33: sells reopen permanently against the deepest reserve the curve
        // ever held.
        vm.prank(TRADER);
        token.approve(address(curve), type(uint256).max);
        vm.prank(TRADER);
        assertGt(curve.sell(1e24, 0, vm.getBlockTimestamp()), 0, "the exit is open");
    }

    /// @notice **Invariant 27 and section 11.4.** Expiry forfeits the bond, the creator's
    /// accrued fees and the protection pool into the reserve, voids the creator's
    /// allocation, and leaves sells open forever.
    function test_expiryForfeitsEverythingToHolders() public {
        ILaunchFactory.LaunchParams memory params = defaultParams();
        params.bondWei = 0.4 ether;
        params.creatorFirstBuyWei = 0.009 ether;
        (BondingCurve curve, IERC20 token) = createLaunch(params);

        vm.prank(TRADER);
        curve.buy{value: 1 ether}(0, vm.getBlockTimestamp());

        uint256 reserveBefore = curve.ethReserve();
        uint256 bond = curve.bondHeldWei();
        uint256 creatorFees = curve.creatorFeeEth();
        uint256 protection = curve.protectionEth();

        vm.warp(curve.gradDeadline());
        curve.expire();

        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Expired), "Expired");
        assertEq(uint8(curve.bondState()), uint8(IBondingCurve.BondState.Forfeited), "Invariant 26");
        assertEq(
            curve.ethReserve(),
            reserveBefore + bond + creatorFees + protection,
            "Invariant 27: all three reached the reserve"
        );
        assertEq(curve.bondHeldWei(), 0, "bondHeldWei");
        assertEq(curve.creatorFeeEth(), 0, "creatorFeeEth");
        assertEq(curve.protectionEth(), 0, "protectionEth");
        assertEq(curve.pendingBondWei(), 0, "nothing was credited to the creator");
        assertTrue(vesting.scheduleOf(address(curve)).voided, "the allocation is voided");
        assertEq(vesting.releasable(address(curve)), 0, "Invariant 21");

        vm.prank(CREATOR);
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Expired)
        );
        curve.claimCreatorFees();

        // And the bond itself: the refusal names the forfeiture, which is permanent, rather
        // than a return that has not happened yet (Invariant 63).
        vm.prank(CREATOR);
        vm.expectRevert(IBondingCurve.BondForfeitedToHolders.selector);
        curve.claimBond();

        vm.prank(TRADER);
        token.approve(address(curve), type(uint256).max);
        vm.prank(TRADER);
        assertGt(curve.sell(1e24, 0, vm.getBlockTimestamp()), 0, "Invariant 33: sells stay open");
    }

    /// @dev One buy and one sell through the pool, so a locked position accrues fees in
    /// both currencies and has something to compound.
    function _tradeBothWays(PoolSwapHelper swapper, PoolKey memory key, IERC20 token) private {
        vm.deal(address(swapper), 10 ether);
        swapper.swap{value: 2 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK + 1)
            })
        );
        swapper.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(token.balanceOf(address(swapper)) / 2),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK - 1)
            })
        );
    }
}
