// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {ILaunchFactory} from "src/interfaces/ILaunchFactory.sol";
import {ILiquidityLock} from "src/interfaces/ILiquidityLock.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";
import {TickAlign} from "src/libraries/TickAlign.sol";

import {PledrinTestBase} from "../base/PledrinTestBase.sol";

/// @title Graduation: the two positions, the bounty, and what is left behind
/// @notice Covers `docs/SPEC.md` sections 8.2, 8.5, 9 and 10.1, and Invariants 36, 39, 40,
/// 41, 42, 43, 44, 45, 46 and 47.
/// @dev Deterministic, against the Uniswap v4 stand-ins of `test/mocks`. The mint
/// arithmetic those stand-ins perform is the real `SqrtPriceMath` at the real rounding
/// direction, and the proof of that is in the numbers: the token shortfall they produce is
/// 28,428 base units at `virtualEthReserve = 1.25e16`, 1,088 at the default `5e17` and 240
/// at `1.25e20` — the three values measured against the live PositionManager and asserted
/// again in `test/fork/Graduation.fork.t.sol`. Those are the figures a silent drift would
/// move, so they are asserted as exact equalities here and there.
contract BondingCurveGraduationTest is PledrinTestBase {
    /// @notice The whole of section 8.2 on a healthy launch.
    function test_graduationDrainsTheReserveAndLocksTwoPositions() public {
        (BondingCurve curve, IERC20 token) = createPledgedLaunch();
        buyToCap(curve);

        uint256 coreId = positionManager.nextTokenId();
        uint256 reserveAtCap = curve.ethReserve();
        uint256 protectionAtCap = curve.protectionEth();

        vm.prank(GRADUATOR);
        curve.graduate();

        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "Graduated");
        assertEq(curve.graduatedAt(), vm.getBlockTimestamp(), "graduatedAt");
        assertEq(curve.ethReserve(), 0, "Invariant 43: the reserve is drained");
        assertEq(curve.protectionEth(), 0, "the protection pool was deposited");
        assertGt(reserveAtCap, 0, "there was a reserve");
        assertGt(protectionAtCap, 0, "and a protection pool");

        // Invariant 46: both positions are owned by the lock and registered to this launch.
        assertEq(positionManager.ownerOf(coreId), address(lock), "the core position is locked");
        assertEq(positionManager.ownerOf(coreId + 1), address(lock), "the floor position too");
        assertEq(lock.positionOf(coreId).launch, address(curve), "core registered");
        assertEq(
            uint8(lock.positionOf(coreId).kind),
            uint8(ILiquidityLock.PositionKind.Core),
            "core kind"
        );
        assertEq(lock.positionOf(coreId + 1).launch, address(curve), "floor registered");
        assertEq(
            uint8(lock.positionOf(coreId + 1).kind),
            uint8(ILiquidityLock.PositionKind.Floor),
            "floor kind"
        );

        // Invariant 43: what the curve keeps is dust and unclaimed buckets, nothing else.
        assertLe(token.balanceOf(address(curve)), PledrinConstants.LP_DUST_MAX, "token dust");
        assertEq(
            address(curve).balance,
            uint256(curve.protocolFeeEth()) + curve.creatorFeeEth() + curve.pendingBountyTotalWei()
                + curve.pendingBondWei(),
            "every wei left in the curve belongs to an unclaimed bucket"
        );
    }

    /// @notice **Invariant 39.** The core position takes at most `LP_SUPPLY` base units and
    /// at most `R_target` wei, leaves at most `LP_DUST_MAX` behind, and is the largest
    /// liquidity that fits: one more unit would need more than `LP_SUPPLY`.
    function test_theCorePositionIsTheLargestLiquidityThatFits() public {
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        buyToCap(curve);

        uint256 coreId = positionManager.nextTokenId();
        uint256 tokensBefore = token.balanceOf(address(curve));

        vm.prank(GRADUATOR);
        curve.graduate();

        uint128 liquidity = positionManager.getPositionLiquidity(coreId);
        uint256 consumed = tokensBefore - token.balanceOf(address(curve));
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(
            TickAlign.up(TickMath.MIN_TICK, PledrinConstants.POOL_TICK_SPACING)
        );
        uint160 terminal = curve.sqrtPriceTerminal();

        assertEq(
            liquidity,
            LiquidityAmounts.getLiquidityForAmount1(
                sqrtLower, terminal, PledrinConstants.LP_SUPPLY
            ),
            "the liquidity is sized from LP_SUPPLY"
        );
        assertLe(consumed, PledrinConstants.LP_SUPPLY, "at most LP_SUPPLY base units");
        assertLe(
            PledrinConstants.LP_SUPPLY - consumed,
            PledrinConstants.LP_DUST_MAX,
            "Invariant 39's dust bound"
        );
        assertGt(
            SqrtPriceMath.getAmount1Delta(sqrtLower, terminal, liquidity + 1, true),
            PledrinConstants.LP_SUPPLY,
            "one more unit of liquidity would need more than LP_SUPPLY"
        );
    }

    /// @notice The measured token shortfall at the default parameters: 1,088 base units.
    /// @dev Measured against the live Uniswap v4 PositionManager on Robinhood Chain and
    /// recorded in `docs/SPEC.md` section 8.2. Asserted as an equality on purpose: the
    /// failure mode this test exists to catch is the value drifting silently, which an
    /// inequality against `LP_DUST_MAX` would hide.
    function test_theCoreMintLeavesExactlyTheMeasuredDustAtTheDefaultReserve() public {
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        buyToCap(curve);
        vm.prank(GRADUATOR);
        curve.graduate();

        assertEq(token.balanceOf(address(curve)), 1088, "1,088 base units at vE0 = 5e17");
    }

    /// @notice The same measurement at both ends of the permitted reserve range: 28,428
    /// base units at the smallest raise and 240 at the largest.
    function test_theCoreMintDustAtBothEndsOfTheReserveRange() public {
        assertEq(
            _graduateAndMeasureDust(PledrinConstants.MIN_VIRTUAL_ETH_RESERVE),
            28_428,
            "28,428 base units at vE0 = 1.25e16"
        );
        assertEq(
            _graduateAndMeasureDust(PledrinConstants.MAX_VIRTUAL_ETH_RESERVE),
            240,
            "240 base units at vE0 = 1.25e20"
        );
    }

    /// @notice Invariant 39's dust bound holds across the whole permitted range, not only
    /// at the three measured points.
    function testFuzz_theCoreMintDustStaysInsideItsBound(uint128 vE0) public {
        uint256 dust = _graduateAndMeasureDust(
            uint128(
                bound(
                    vE0,
                    PledrinConstants.MIN_VIRTUAL_ETH_RESERVE,
                    PledrinConstants.MAX_VIRTUAL_ETH_RESERVE
                )
            )
        );

        assertLe(dust, PledrinConstants.LP_DUST_MAX, "Invariant 39");
    }

    /// @notice `amount0Max` is exactly `R_target`, and the core mint's ETH requirement sits
    /// just inside it. Section 8.2 says this bound must not be tightened; the headroom is
    /// not monotone in `virtualEthReserve`, so there is no safer closed form.
    function test_theCoreMintSpendsAtMostTheEthTarget() public {
        (BondingCurve curve,) = createDefaultLaunch();
        buyToCap(curve);

        uint256 target = curve.ethTarget();
        uint256 poolBefore = address(poolManager).balance;

        vm.prank(GRADUATOR);
        curve.graduate();

        uint256 toPool = address(poolManager).balance - poolBefore;
        assertGt(toPool, target, "the pool received the core ETH and the floor ETH");
        assertLe(
            SqrtPriceMath.getAmount0Delta(
                curve.sqrtPriceTerminal(),
                TickMath.getSqrtPriceAtTick(
                    TickAlign.down(TickMath.MAX_TICK, PledrinConstants.POOL_TICK_SPACING)
                ),
                positionManager.getPositionLiquidity(1),
                true
            ),
            target,
            "Invariant 39: the core position's ETH requirement is at most R_target"
        );
    }

    /// @notice **Invariant 42.** The floor position lies strictly above the current tick,
    /// spans the aligned floor band, consumes no token, and needs no token approval. At
    /// the default parameters that is the range `[170400, 184200]`, which is the range
    /// measured against the live PoolManager with a 1 ETH probe in
    /// `test/fork/V4Assumptions.t.sol`.
    function test_theFloorPositionIsAnEthBidStrictlyAboveTheCurrentTick() public {
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        buyToCap(curve);

        uint256 coreId = positionManager.nextTokenId();
        (, int24 tickBefore) = poolManager.slot0(curve.poolId());
        uint256 lockTokensBefore = token.balanceOf(address(lock));
        uint256 poolTokensBefore = token.balanceOf(address(poolManager));
        uint256 curveTokensBefore = token.balanceOf(address(curve));

        vm.prank(GRADUATOR);
        curve.graduate();

        (, PositionInfo floorInfo) = positionManager.getPoolAndPositionInfo(coreId + 1);
        assertEq(floorInfo.tickLower(), 170_400, "measured floor tickLower");
        assertEq(floorInfo.tickUpper(), 184_200, "measured floor tickUpper");
        assertEq(floorInfo.tickUpper() - floorInfo.tickLower(), 13_800, "the band's width");
        assertGt(floorInfo.tickLower(), tickBefore, "Invariant 42: strictly above the tick");
        assertEq(
            floorInfo.tickLower(),
            TickAlign.down(tickBefore, PledrinConstants.POOL_TICK_SPACING)
                + PledrinConstants.POOL_TICK_SPACING,
            "Invariant 42's formula"
        );
        assertLe(
            floorInfo.tickUpper(),
            TickAlign.down(TickMath.MAX_TICK, PledrinConstants.POOL_TICK_SPACING),
            "inside the aligned maximum tick"
        );
        assertGt(positionManager.getPositionLiquidity(coreId + 1), 0, "the floor has liquidity");

        // Funded in `currency0` alone: the whole token side of the graduation went into the
        // core position, and the floor mint moved no token anywhere.
        uint256 coreTokens = curveTokensBefore - token.balanceOf(address(curve));
        assertEq(
            token.balanceOf(address(poolManager)) - poolTokensBefore,
            coreTokens,
            "the floor mint consumed no token"
        );
        assertEq(token.balanceOf(address(lock)), lockTokensBefore, "the lock holds no token");
        assertEq(
            token.allowance(address(curve), address(permit2)),
            0,
            "the token approval is revoked before the floor mint"
        );
    }

    /// @notice Section 8.5: the floor position cannot move the pool's price or tick,
    /// because it holds no token at the moment it is minted.
    function test_theFloorMintLeavesThePriceAndTickWhereTheyWere() public {
        (BondingCurve curve,) = createDefaultLaunch();
        buyToCap(curve);

        (uint160 priceBefore, int24 tickBefore) = poolManager.slot0(curve.poolId());
        vm.prank(GRADUATOR);
        curve.graduate();
        (uint160 priceAfter, int24 tickAfter) = poolManager.slot0(curve.poolId());

        assertEq(priceAfter, priceBefore, "the price is unmoved");
        assertEq(tickAfter, tickBefore, "and so is the tick");
        assertEq(priceAfter, curve.sqrtPriceTerminal(), "Invariant 40");
    }

    /// @notice Section 8.2 step 5: the floor position is funded from the protection pool,
    /// the reserve's surplus over `R_target`, and whatever `R_target` the core mint did not
    /// spend. Nothing is stranded.
    function test_theFloorIsFundedFromProtectionSurplusAndUnspentTarget() public {
        (BondingCurve curve,) = createDefaultLaunch();
        buyToCap(curve);

        uint256 protection = curve.protectionEth();
        uint256 surplus = curve.ethReserve() - curve.ethTarget();
        uint256 coreId = positionManager.nextTokenId();

        vm.recordLogs();
        vm.prank(GRADUATOR);
        curve.graduate();

        // `ethToFloor` is the last ETH figure the `Graduated` event reports.
        uint256 floorEth = _floorEthFromEvent(address(curve));
        assertGe(floorEth, protection + surplus, "at least the protection pool and the surplus");
        assertGt(positionManager.getPositionLiquidity(coreId + 1), 0, "it was minted");
    }

    /// @notice **Invariant 41 and the `if` guard of section 8.2 step 2.** A pool already at
    /// `sqrtPriceTerminal` is not swapped at all: a limit equal to the current price would
    /// revert `PriceLimitAlreadyExceeded`, so the guard is load-bearing.
    function test_aHealthyGraduationPerformsNoSwapAtAll() public {
        (BondingCurve curve,) = createDefaultLaunch();
        buyToCap(curve);

        vm.prank(GRADUATOR);
        curve.graduate();

        assertEq(poolManager.swapCalls(), 0, "no swap was attempted");
    }

    /// @notice A pool price griefed **below** `sqrtPriceTerminal` is restored before the
    /// mints, at zero cost in both currencies, and the graduation proceeds. Invariants 40
    /// and 41. A lower price is a lower tick, which by the orientation of section 8.1 is a
    /// more expensive token.
    function test_aPoolPriceBelowTheTerminalPriceIsRestoredAtZeroCost() public {
        (BondingCurve curve,) = createDefaultLaunch();
        buyToCap(curve);

        uint160 terminal = curve.sqrtPriceTerminal();
        int24 griefedTick = 100_000;
        assertLt(TickMath.getSqrtPriceAtTick(griefedTick), terminal, "a lower tick, a lower price");
        poolManager.pokeSlot0(curve.poolId(), TickMath.getSqrtPriceAtTick(griefedTick), griefedTick);

        uint256 curveBalanceBefore = address(curve).balance;
        uint256 reserve = curve.ethReserve();
        uint256 protection = curve.protectionEth();

        vm.prank(GRADUATOR);
        curve.graduate();

        (uint160 priceAfter,) = poolManager.slot0(curve.poolId());
        assertEq(priceAfter, terminal, "the price was restored before the mints");
        assertEq(poolManager.swapCalls(), 1, "exactly one restoring swap");
        assertFalse(
            poolManager.lastSwapZeroForOne(), "a price below the terminal is restored one-for-zero"
        );
        assertEq(poolManager.lastSwapLimit(), terminal, "the limit is the terminal price");
        assertEq(
            poolManager.lastSwapAmountSpecified(),
            -1,
            "one unit of exact input, because PoolManager rejects a zero size"
        );
        assertEq(
            curveBalanceBefore - address(curve).balance,
            reserve + protection,
            "the only ETH that left the curve is what it deposited into the two positions"
        );
    }

    /// @notice A pool price griefed **above** `sqrtPriceTerminal` is restored from the
    /// other direction, which is the comparison section 8.2 step 2 makes.
    function test_aPoolPriceAboveTheTerminalPriceIsRestoredFromTheOtherSide() public {
        (BondingCurve curve,) = createDefaultLaunch();
        buyToCap(curve);

        uint160 terminal = curve.sqrtPriceTerminal();
        int24 griefedTick = 200_000;
        assertGt(
            TickMath.getSqrtPriceAtTick(griefedTick), terminal, "a higher tick, a higher price"
        );
        poolManager.pokeSlot0(curve.poolId(), TickMath.getSqrtPriceAtTick(griefedTick), griefedTick);

        vm.prank(GRADUATOR);
        curve.graduate();

        (uint160 priceAfter,) = poolManager.slot0(curve.poolId());
        assertEq(priceAfter, terminal, "restored");
        assertTrue(
            poolManager.lastSwapZeroForOne(), "a price above the terminal is restored zero-for-one"
        );
    }

    /// @notice Section 8.1: graduation reads `slot0.tick` and never derives it from
    /// `slot0.sqrtPriceX96`, because `Pool.swap` can leave the two disagreeing by one
    /// tick. A pool whose tick is one below the tick of its price places the floor range
    /// one spacing lower, which is what reading the tick means.
    function test_theFloorRangeFollowsTheReportedTickNotThePrice() public {
        (BondingCurve curve,) = createDefaultLaunch();
        buyToCap(curve);

        // The terminal tick is 170352, which is not a multiple of 200. Reporting 170400
        // instead — the tick of the same price band, one spacing up — moves the floor.
        poolManager.pokeTick(curve.poolId(), 170_400);
        uint256 coreId = positionManager.nextTokenId();

        vm.prank(GRADUATOR);
        curve.graduate();

        (, PositionInfo floorInfo) = positionManager.getPoolAndPositionInfo(coreId + 1);
        assertEq(floorInfo.tickLower(), 170_600, "the floor followed the reported tick");
        assertGt(floorInfo.tickLower(), 170_400, "and is still strictly above it");
    }

    /// @notice **Invariant 45.** Graduation sends ETH to the PoolManager and the
    /// PositionManager and to nobody else. The bond and the bounty are credited.
    function test_graduationSendsEthToNobodyButUniswap() public {
        (BondingCurve curve,) = createPledgedLaunch();
        buyToCap(curve);

        uint256 creatorBefore = CREATOR.balance;
        uint256 treasuryBefore = TREASURY.balance;
        uint256 graduatorBefore = GRADUATOR.balance;
        uint256 lockBefore = address(lock).balance;

        vm.prank(GRADUATOR);
        curve.graduate();

        assertEq(CREATOR.balance, creatorBefore, "the creator was paid nothing");
        assertEq(TREASURY.balance, treasuryBefore, "the treasury was paid nothing");
        assertEq(GRADUATOR.balance, graduatorBefore, "the caller was paid nothing");
        assertEq(address(lock).balance, lockBefore, "the lock received no ETH");
        assertGt(curve.pendingBondWei(), 0, "the bond was credited instead");
        assertGt(curve.pendingBountyWei(GRADUATOR), 0, "and so was the bounty");
    }

    /// @notice **Invariant 36.** `graduate` and `graduateAlt` together succeed at most once.
    function test_graduationHappensAtMostOnce() public {
        (BondingCurve curve,) = createLaunchAtCap();
        vm.prank(GRADUATOR);
        curve.graduate();

        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Graduated)
        );
        curve.graduate();

        // The alternate entry point is refused on both sides of its delay. Since the state
        // check runs before the delay check, neither call needs the warp to reach the
        // refusal; the warp is here to show that no passage of time opens a second
        // graduation, which is the part of Invariant 36 a single call cannot state.
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Graduated)
        );
        curve.graduateAlt(PledrinConstants.POOL_FEE, 100);

        vm.warp(curve.capReachedAt() + PledrinConstants.ALT_DELAY);
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Graduated)
        );
        curve.graduateAlt(PledrinConstants.POOL_FEE, 100);
    }

    /// @notice Graduation is only reachable from `Graduating`.
    function test_graduateRequiresGraduating() public {
        (BondingCurve curve,) = createDefaultLaunch();

        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Live)
        );
        curve.graduate();
    }

    /// @notice Graduation records itself against the creator, with the raise in wei.
    function test_graduationRecordsTheRaiseAndTheBondReturn() public {
        (BondingCurve curve,) = createPledgedLaunch();
        buyToCap(curve);
        vm.prank(GRADUATOR);
        curve.graduate();

        ILaunchFactory.Reputation memory record = factory.reputationOf(CREATOR);
        assertEq(record.graduations, 1, "graduations");
        assertEq(record.ethRaisedGraduated, curve.ethTarget(), "ethRaisedGraduated");
        assertEq(record.bondsReturned, 1, "bondsReturned");
        assertEq(record.expiries, 0, "not an expiry");
        assertEq(record.stalls, 0, "not a stall");
    }

    /// @notice Graduation starts the creator's vesting clock, and a launch with no
    /// allocation graduates just the same.
    function test_graduationStartsVestingAndToleratesNoAllocation() public {
        (BondingCurve withAllocation,) = createPledgedLaunch();
        buyToCap(withAllocation);
        vm.prank(GRADUATOR);
        withAllocation.graduate();
        assertEq(
            vesting.scheduleOf(address(withAllocation)).start,
            vm.getBlockTimestamp(),
            "the clock started"
        );

        (BondingCurve withNone,) = createLaunchAtCap();
        vm.prank(GRADUATOR);
        withNone.graduate();
        assertEq(vesting.scheduleOf(address(withNone)).allocation, 0, "no schedule");
        assertEq(uint8(withNone.state()), uint8(IBondingCurve.State.Graduated), "still graduated");
    }

    /// @notice **Invariant 47.** After graduation the protocol charges no fee on any trade,
    /// because the curve accepts no trade at all: the fee buckets can only shrink.
    function test_noFeeAccruesAfterGraduation() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        vm.prank(GRADUATOR);
        curve.graduate();

        uint256 creatorFees = curve.creatorFeeEth();
        uint256 protocolFees = curve.protocolFeeEth();

        vm.prank(TRADER);
        token.approve(address(curve), type(uint256).max);
        vm.prank(TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Graduated)
        );
        curve.sell(1e18, 0, vm.getBlockTimestamp());

        vm.prank(TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Graduated)
        );
        curve.buy{value: 1 ether}(0, vm.getBlockTimestamp());

        assertEq(curve.creatorFeeEth(), creatorFees, "no fee accrued");
        assertEq(curve.protocolFeeEth(), protocolFees, "no fee accrued");
        assertEq(curve.protectionEth(), 0, "and the protection bucket stays empty");
    }

    /// @notice The `Graduated` event reports both position ids, both ETH legs, the token
    /// leg and the bounty.
    function test_graduatedEventReportsEveryLeg() public {
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        buyToCap(curve);

        uint256 coreId = positionManager.nextTokenId();
        uint256 tokensBefore = token.balanceOf(address(curve));
        uint256 balanceBefore = address(curve).balance;

        vm.recordLogs();
        vm.prank(GRADUATOR);
        curve.graduate();

        GraduatedLog memory log = graduatedLog(address(curve));

        assertEq(log.positionIdCore, coreId, "core id");
        assertEq(log.positionIdFloor, coreId + 1, "floor id");
        assertEq(log.tokensToCore, tokensBefore - token.balanceOf(address(curve)), "token leg");
        assertEq(
            log.ethToCore + log.ethToFloor,
            balanceBefore - address(curve).balance,
            "both ETH legs account for every wei that left"
        );
        assertEq(log.bounty, curve.pendingBountyWei(GRADUATOR), "bounty");

        // **Invariant 69.** The whole pool key is reconstructible from this one log and
        // `token()`, because `currency0` and `hooks` are always the zero address.
        assertEq(log.fee, PledrinConstants.POOL_FEE, "the canonical fee");
        assertEq(log.tickSpacing, PledrinConstants.POOL_TICK_SPACING, "the canonical spacing");
        assertEq(
            log.poolId,
            PoolId.unwrap(poolKeyFor(address(token), log.fee, log.tickSpacing).toId()),
            "Invariant 69: the key the graduation used, rebuilt from the log"
        );
        assertEq(log.poolId, PoolId.unwrap(curve.poolId()), "and it is the canonical key");
        assertEq(log.caller, GRADUATOR, "the caller is indexed on the log");
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _graduateAndMeasureDust(uint128 vE0) private returns (uint256) {
        ILaunchFactory.LaunchParams memory params = defaultParams();
        params.virtualEthReserve = vE0;
        (BondingCurve curve, IERC20 token) = createLaunch(params);
        buyToCap(curve);
        vm.prank(GRADUATOR);
        curve.graduate();
        return token.balanceOf(address(curve));
    }

    function _floorEthFromEvent(address curve) private view returns (uint256 ethToFloor) {
        return graduatedLog(curve).ethToFloor;
    }
}
