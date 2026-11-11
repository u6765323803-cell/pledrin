// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {ILaunchFactory} from "src/interfaces/ILaunchFactory.sol";
import {ILiquidityLock} from "src/interfaces/ILiquidityLock.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";
import {TickAlign} from "src/libraries/TickAlign.sol";

import {PoolSwapHelper} from "../helpers/PoolSwapHelper.sol";
import {PositionHolder} from "../helpers/PositionHolder.sol";
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
        // Read before the mint, because the mint is what moves it. Zero unless somebody
        // has left a native balance in the live PositionManager; the two assertions below
        // that would otherwise be false by exactly this much carry it explicitly.
        uint256 stray = strayInPositionManager();

        vm.prank(TRADER);
        curve.graduate();

        // Invariant 43: the reserve and the protection pool are gone, into the positions.
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "Graduated");
        assertEq(curve.ethReserve(), 0, "Invariant 43: the reserve is drained");
        assertEq(curve.protectionEth(), 0, "and the protection pool deposited");
        assertEq(
            unassignedEth(curve),
            stray,
            "measured: a graduated launch keeps no ETH beyond its unclaimed buckets, except"
            " whatever the mint's sweep carried in from PositionManager"
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
        assertEq(
            address(curve).balance,
            stray,
            "and the launch now holds nothing at all beyond the swept stray, which is"
            " immobilised there under Invariant 43"
        );
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
        uint256 stray = strayInPositionManager();

        vm.prank(TRADER);
        curve.graduate();

        (uint160 restored, int24 tickAfter,,) = POOL_MANAGER.getSlot0(curve.poolId());
        assertEq(restored, curve.sqrtPriceTerminal(), "the price was restored");
        assertEq(tickAfter, DEFAULT_TERMINAL_TICK, "and so was the tick");
        assertEq(ownerOfPosition(coreId), address(lock), "the core position is locked");
        assertEq(ownerOfPosition(coreId + 1), address(lock), "and the floor position");
        assertEq(
            curveBalanceBefore + stray - address(curve).balance,
            reserve + protection,
            "Invariant 41: the restoring swap cost the curve nothing. The stray is on the"
            " left because the mint's sweep adds it to the curve's balance, so the fall is"
            " smaller by that much without anything extra having left"
        );
    }

    /// @notice **Invariants 38, 67 and 69 on the real deployment.** After `ALT_DELAY` a
    /// launch graduates on a caller-chosen alternate key, and the only pair refused is the
    /// canonical one.
    /// @dev The alternate spacing range reaches `POOL_TICK_SPACING` since decision 22, so
    /// 200 is inside it and the canonical *pair* is what `graduateAlt` refuses. That matters
    /// on the real chain more than in the stand-in: the restoring swap walks the real tick
    /// bitmap, and a caller forced onto a fine spacing pays for it, so being able to pick
    /// the coarse canonical spacing at another fee is the point of the change.
    function test_graduateAltOpensAnAlternateKeyOnTheRealDeployment() public {
        (BondingCurve curve, IERC20 token) = createLaunch(defaultParams());
        buyToCap(curve);

        vm.expectRevert(IBondingCurve.AltDelayNotElapsed.selector);
        curve.graduateAlt(PledrinConstants.POOL_FEE, 100);

        vm.warp(curve.capReachedAt() + PledrinConstants.ALT_DELAY);

        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.InvalidTickSpacing.selector, 9));
        curve.graduateAlt(PledrinConstants.POOL_FEE, 9);
        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.InvalidTickSpacing.selector, 201));
        curve.graduateAlt(PledrinConstants.POOL_FEE, 201);
        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.InvalidPoolFee.selector, 2999));
        curve.graduateAlt(2999, 100);
        // The canonical pair, which is the one pair outside the usable set. Both of its
        // fields are individually permitted, which is why the refusal is its own error.
        vm.expectRevert(IBondingCurve.CanonicalKeyNotAllowed.selector);
        curve.graduateAlt(
            PledrinConstants.POOL_FEE, uint24(int24(PledrinConstants.POOL_TICK_SPACING))
        );

        uint256 coreId = POSITION_MANAGER.nextTokenId();
        vm.recordLogs();
        curve.graduateAlt(PledrinConstants.POOL_FEE, 100);

        // **Invariant 69.** The key the graduation used, rebuilt from the one log.
        GraduatedLog memory log = graduatedLog(address(curve));
        assertEq(log.fee, PledrinConstants.POOL_FEE, "the fee the log reports");
        assertEq(log.tickSpacing, 100, "and the spacing");
        PoolKey memory altKey = poolKeyFor(address(token), log.fee, log.tickSpacing);
        assertEq(log.poolId, PoolId.unwrap(altKey.toId()), "Invariant 69: the whole key");
        assertNotEq(log.poolId, PoolId.unwrap(curve.poolId()), "which is not the canonical key");

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

    // ------------------------------------------------------------------
    // Finding 1, against the contract that actually sweeps
    // ------------------------------------------------------------------

    /// @notice **Invariant 60's `S` quantifier and Invariant 70, on the real
    /// PositionManager.** A native balance parked in PositionManager before `graduate()` is
    /// swept into the curve and changes nothing else about the graduation.
    /// @dev This is the half of finding 1 that only the real contract can settle. The
    /// deterministic suite asserts the same property against a stand-in whose `SWEEP` was
    /// *modelled*, and the model was wrong for a release: it refunded `msg.value - amount0`
    /// where `PositionManager._sweep` sends `currency.balanceOfSelf()`, the entire balance.
    /// Here the sweep is the deployed code. Differential, run twice from the same forked
    /// state, because a single successful graduation with a stray in place would also pass
    /// against a saturating balance delta that still mis-reports the event.
    ///
    /// `vm.deal` is the faithful way to park it: the real `receive()` refuses ETH from
    /// anyone but PoolManager and WETH9, and the three routes that work in production —
    /// `SELFDESTRUCT`, a block reward, and a batch that forwards more value than it settles
    /// — all arrive without running any of PositionManager's code, which is what `vm.deal`
    /// does.
    function test_aStrayBalanceInTheRealPositionManagerIsSweptAndChangesNothing() public {
        (BondingCurve curve,) = createLaunch(defaultParams());
        buyToCap(curve);

        uint256 coreId = POSITION_MANAGER.nextTokenId();
        uint256 snapshot = vm.snapshotState();

        vm.recordLogs();
        vm.prank(TRADER);
        curve.graduate();
        GraduatedLog memory baseline = graduatedLog(address(curve));
        uint128 baselineCoreLiquidity = POSITION_MANAGER.getPositionLiquidity(coreId);
        uint128 baselineFloorLiquidity = POSITION_MANAGER.getPositionLiquidity(coreId + 1);
        uint256 baselineCurveBalance = address(curve).balance;
        uint256 baselinePoolBalance = address(POOL_MANAGER).balance;

        assertTrue(vm.revertToState(snapshot), "the pre-graduation state was restored");

        // More than the whole raise, and more than the `ethToCore` the pre-fix balance
        // delta would have subtracted it from — which is what made that subtraction
        // underflow and revert both graduation paths.
        uint256 stray = uint256(curve.ethTarget()) + 1 ether;
        vm.deal(address(POSITION_MANAGER), strayInPositionManager() + stray);

        vm.recordLogs();
        vm.prank(TRADER);
        curve.graduate();
        GraduatedLog memory strayed = graduatedLog(address(curve));

        assertEq(abi.encode(strayed), abi.encode(baseline), "Invariant 60: the same graduation");
        assertEq(
            POSITION_MANAGER.getPositionLiquidity(coreId),
            baselineCoreLiquidity,
            "the same core liquidity"
        );
        assertEq(
            POSITION_MANAGER.getPositionLiquidity(coreId + 1),
            baselineFloorLiquidity,
            "Invariant 70: and the same floor liquidity"
        );
        assertEq(
            address(POOL_MANAGER).balance,
            baselinePoolBalance,
            "the pool received not one wei of the stray"
        );
        assertEq(
            address(curve).balance,
            baselineCurveBalance + stray,
            "Invariant 43: the curve's balance is higher by exactly the stray"
        );
        assertEq(
            strayInPositionManager(), 0, "and the real sweep took the whole balance, as it does"
        );
    }

    /// @notice **The golden `ethToCore`, measured against the real deployment.**
    /// @dev Since `5b86188`, `Graduated.ethToCore` is computed from `SqrtPriceMath`,
    /// `TickMath` and `LiquidityAmounts` rather than read off a balance, and it is in the
    /// log an indexer records — so a library bump that changes a rounding direction changes
    /// protocol output. What makes the literal a measurement rather than a tautology is the
    /// second half of this test: the real PoolManager's balance rises by exactly
    /// `ethToCore + ethToFloor`, so the number the curve computed is the number Uniswap
    /// charged. `test/unit/CoreMintArithmetic.t.sol` re-derives it from the specification
    /// and pins the two ends of the reserve range.
    function test_ethToCoreIsTheComputedNumberAndIsWhatUniswapCharges() public {
        (BondingCurve curve,) = createLaunch(defaultParams());
        buyToCap(curve);

        uint256 poolBefore = address(POOL_MANAGER).balance;
        uint256 curveBefore = address(curve).balance;
        uint256 stray = strayInPositionManager();

        vm.recordLogs();
        vm.prank(TRADER);
        curve.graduate();
        GraduatedLog memory log = graduatedLog(address(curve));

        assertEq(
            log.ethToCore,
            3_999_999_999_999_998_912,
            "measured: the core mint's ETH cost at the default reserve"
        );
        assertEq(
            uint256(curve.ethTarget()) - log.ethToCore,
            1088,
            "1,088 wei of headroom under amount0Max, which is exactly R_target"
        );
        assertEq(
            address(POOL_MANAGER).balance - poolBefore,
            log.ethToCore + log.ethToFloor,
            "and both legs are what the real PoolManager was actually paid"
        );
        assertEq(
            curveBefore + stray - address(curve).balance,
            log.ethToCore + log.ethToFloor,
            "which is also what left the curve"
        );
    }

    /// @notice **Invariants 64 and 66 on the real deployment.** A launch whose canonical key
    /// was opened by somebody else, at a foreign price, with a real third-party position on
    /// it, is created and graduates on that key, and the stranger's position is untouched.
    /// @dev Both halves of decision 22 against the deployed PoolManager. The key is seized
    /// before the launch exists, using nothing but the deployer's address and nonce. The
    /// liquidity has to come afterwards, because a position on a token that has not been
    /// deployed cannot be funded — which is itself worth recording: the pre-launch seizure
    /// can set a price and nothing else.
    function test_aSeizedCanonicalKeyWithRealLiquidityChangesNothing() public {
        address predicted =
            vm.computeCreateAddress(address(tokenDeployer), vm.getNonce(address(tokenDeployer)));
        PoolKey memory canonical = poolKeyFor(predicted, PledrinConstants.POOL_TICK_SPACING);
        uint160 foreign = TickMath.getSqrtPriceAtTick(100_000);

        // The seizure, for the price of one `initialize`.
        POOL_MANAGER.initialize(canonical, foreign);
        (uint160 opened,,,) = POOL_MANAGER.getSlot0(canonical.toId());
        assertEq(opened, foreign, "a stranger chose the opening price");

        vm.recordLogs();
        (BondingCurve curve, IERC20 token) = createLaunch(defaultParams());
        assertEq(address(token), predicted, "the seized key was this launch's key");
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Live), "Invariant 64: created");
        (uint160 afterLaunch,,,) = POOL_MANAGER.getSlot0(curve.poolId());
        assertEq(afterLaunch, foreign, "and the launch left the foreign price alone");

        buyToCap(curve);

        // A stranger now mints a real position on that key, in ETH alone, in a band above
        // the terminal tick so the price does not move.
        PositionHolder stranger = new PositionHolder(POSITION_MANAGER);
        uint256 strangerId = POSITION_MANAGER.nextTokenId();
        _mintEthOnlyPosition(stranger, canonical, 180_000, 200_000, 3 ether);
        uint128 strangerLiquidity = POSITION_MANAGER.getPositionLiquidity(strangerId);
        assertGt(strangerLiquidity, 0, "the stranger holds liquidity on the launch's own key");
        assertEq(ownerOfPosition(strangerId), address(stranger), "which is theirs");

        uint256 coreId = POSITION_MANAGER.nextTokenId();
        vm.recordLogs();
        vm.prank(TRADER);
        curve.graduate();
        GraduatedLog memory log = graduatedLog(address(curve));

        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "Graduated");
        assertEq(log.poolId, PoolId.unwrap(canonical.toId()), "on the seized key");
        assertEq(
            log.ethToCore,
            3_999_999_999_999_998_912,
            "Invariant 66: the same ethToCore as an untouched key"
        );
        assertEq(
            log.tokensToCore,
            PledrinConstants.LP_SUPPLY - 1088,
            "Invariant 66: and the same token leg"
        );
        assertEq(log.positionIdCore, coreId, "the core position is the next id");
        assertEq(ownerOfPosition(coreId), address(lock), "and it is locked");
        assertEq(
            POSITION_MANAGER.getPositionLiquidity(strangerId),
            strangerLiquidity,
            "Invariant 66: the stranger's liquidity is untouched"
        );
        assertEq(ownerOfPosition(strangerId), address(stranger), "and still theirs");
        (uint160 priceAfter,,,) = POOL_MANAGER.getSlot0(curve.poolId());
        assertEq(priceAfter, curve.sqrtPriceTerminal(), "Invariant 40 held through the mint");
    }

    /// @dev Mints a position funded in `currency0` alone, owned by `holder`, in a band
    /// strictly above the current tick. One `MINT_POSITION`, `SETTLE_PAIR`, `SWEEP` batch —
    /// the same three actions the protocol uses — with `amount1Max` at zero, so no token
    /// and no Permit2 approval is involved.
    function _mintEthOnlyPosition(
        PositionHolder holder,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint256 value
    ) private {
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), value
        );
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            uint256(liquidity),
            uint128(value),
            uint128(0),
            address(holder),
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, ActionConstants.MSG_SENDER);

        vm.deal(address(holder), value);
        (bool ok, bytes memory ret) =
            holder.tryModify{value: value}(abi.encode(actions, params), vm.getBlockTimestamp());
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
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
