// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {ILaunchFactory} from "src/interfaces/ILaunchFactory.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";
import {TickAlign} from "src/libraries/TickAlign.sol";

import {PledrinTestBase} from "../base/PledrinTestBase.sol";

/// @title Graduation's guards, the alternate pool key, and the de-minimis floor
/// @notice Covers `docs/SPEC.md` sections 8.2, 8.4 and 10.1, and Invariants 37, 38, 39,
/// 41, 43 and 56.
/// @dev Most of what is tested here cannot happen on a healthy pool, which is the reason
/// to test it: a graduation that reverted in one of these places and could not be retried
/// would strand every holder of that launch, and a graduation that did *not* revert where
/// it should would spend curve ETH on a griefer's price or immobilise a meaningful part of
/// `LP_SUPPLY`. Where reaching a guard needs the Uniswap stand-in to misbehave, the knob
/// is named in the test and documented as fault injection in `test/mocks`.
contract BondingCurveGraduationGuardsTest is PledrinTestBase {
    // ------------------------------------------------------------------
    // graduateAlt
    // ------------------------------------------------------------------

    /// @notice **Invariant 37's first half.** `graduateAlt` reverts before
    /// `capReachedAt + ALT_DELAY`, including one second before, and succeeds exactly at it.
    function test_graduateAltRevertsBeforeTheAltDelayElapses() public {
        (BondingCurve curve,) = createLaunchAtCap();
        uint256 capReachedAt = curve.capReachedAt();

        vm.expectRevert(IBondingCurve.AltDelayNotElapsed.selector);
        curve.graduateAlt(100);

        vm.warp(capReachedAt + PledrinConstants.ALT_DELAY - 1);
        vm.expectRevert(IBondingCurve.AltDelayNotElapsed.selector);
        curve.graduateAlt(100);

        vm.warp(capReachedAt + PledrinConstants.ALT_DELAY);
        curve.graduateAlt(100);
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "Graduated");
    }

    /// @notice **Invariant 38's first half.** Only a tick spacing inside
    /// `[ALT_TICK_SPACING_MIN, ALT_TICK_SPACING_MAX]` is accepted: one outside on each side
    /// is rejected, and both bounds themselves graduate.
    /// @dev `ALT_TICK_SPACING_MAX` is 199, one below `POOL_TICK_SPACING`, so the top of the
    /// window is an ordinary alternate key: uninitialised, and graduation there is a
    /// complete graduation rather than a revert. 200 is therefore *outside* the window and
    /// the range check rejects it before the pool-state check is ever reached, which is why
    /// the error here is `InvalidTickSpacing(200)` and not `AltPoolInitialized`. The
    /// distinction is load-bearing: the range check is what guarantees the alternate key
    /// can never be the canonical key, so a caller cannot reach `graduate`'s pool through
    /// `graduateAlt` even on a launch whose canonical pool was never initialised.
    /// `test_graduateAltRequiresAnUninitialisedPool` covers `AltPoolInitialized` itself.
    function test_graduateAltAcceptsOnlyThePermittedTickSpacings() public {
        (BondingCurve curve,) = createLaunchAtCap();
        vm.warp(curve.capReachedAt() + PledrinConstants.ALT_DELAY);

        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.InvalidTickSpacing.selector, 0));
        curve.graduateAlt(0);
        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.InvalidTickSpacing.selector, 9));
        curve.graduateAlt(9);
        // One above the window, and the canonical spacing itself, which is the first value
        // above it. Both fail on the range check.
        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.InvalidTickSpacing.selector, 200));
        curve.graduateAlt(uint24(int24(PledrinConstants.POOL_TICK_SPACING)));
        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.InvalidTickSpacing.selector, 201));
        curve.graduateAlt(201);

        curve.graduateAlt(uint24(int24(PledrinConstants.ALT_TICK_SPACING_MIN)));
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "the lower bound");

        (BondingCurve other, IERC20 otherToken) = createLaunchAtCap();
        vm.warp(other.capReachedAt() + PledrinConstants.ALT_DELAY);
        other.graduateAlt(uint24(int24(PledrinConstants.ALT_TICK_SPACING_MAX)));
        assertEq(uint8(other.state()), uint8(IBondingCurve.State.Graduated), "the upper bound");

        // The upper bound graduated onto its own key, and left the canonical key, which the
        // launch transaction initialised, untouched at the terminal price.
        PoolKey memory altKey = _key(address(otherToken), PledrinConstants.ALT_TICK_SPACING_MAX);
        (uint160 altPrice,) = poolManager.slot0(altKey.toId());
        assertEq(altPrice, other.sqrtPriceTerminal(), "the 199 key opened at the terminal price");
        assertNotEq(
            PoolId.unwrap(altKey.toId()),
            PoolId.unwrap(other.poolId()),
            "and it is not the canonical key"
        );
    }

    /// @notice **Invariant 38's second half.** `graduateAlt` requires the alternate pool to
    /// be uninitialised, so it opens it itself at `sqrtPriceTerminal` with nothing to
    /// restore. Section 8.4 explains why this must not be relaxed.
    function test_graduateAltRequiresAnUninitialisedPool() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        vm.warp(curve.capReachedAt() + PledrinConstants.ALT_DELAY);

        // Somebody opens the alternate key first, at a price of their choosing.
        PoolKey memory altKey = _key(address(token), 100);
        poolManager.initialize(altKey, TickMath.getSqrtPriceAtTick(100_000));

        vm.expectRevert(IBondingCurve.AltPoolInitialized.selector);
        curve.graduateAlt(100);

        // Another spacing is still available, and the launch graduates there.
        curve.graduateAlt(60);
        (uint160 price,) = poolManager.slot0(_key(address(token), 60).toId());
        assertEq(price, curve.sqrtPriceTerminal(), "the alt pool opened at the terminal price");
    }

    /// @notice A graduation on the alternate key mints the same two positions, on the
    /// alternate spacing's aligned ticks, and performs no restoring swap at all.
    function test_graduateAltMintsBothPositionsOnTheAlternateSpacing() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        vm.warp(curve.capReachedAt() + PledrinConstants.ALT_DELAY);

        uint256 coreId = positionManager.nextTokenId();
        curve.graduateAlt(100);

        (PoolKey memory coreKey, PositionInfo coreInfo) =
            positionManager.getPoolAndPositionInfo(coreId);
        assertEq(coreKey.tickSpacing, 100, "the core position is on the alternate spacing");
        assertEq(coreInfo.tickLower(), TickAlign.up(TickMath.MIN_TICK, 100), "aligned MIN_TICK");
        assertEq(coreInfo.tickUpper(), TickAlign.down(TickMath.MAX_TICK, 100), "aligned MAX_TICK");

        (, PositionInfo floorInfo) = positionManager.getPoolAndPositionInfo(coreId + 1);
        assertEq(floorInfo.tickLower(), 170_400, "floor tickLower at spacing 100");
        assertEq(floorInfo.tickUpper(), 184_200, "floor tickUpper at spacing 100");
        assertEq(positionManager.ownerOf(coreId), address(lock), "core locked");
        assertEq(positionManager.ownerOf(coreId + 1), address(lock), "floor locked");
        assertEq(poolManager.swapCalls(), 0, "nothing to restore on a pool it opened itself");
        assertLe(token.balanceOf(address(curve)), PledrinConstants.LP_DUST_MAX, "Invariant 39");
        assertEq(curve.ethReserve(), 0, "Invariant 43");
    }

    /// @notice The primary key stays unusable once it is blocked, which is why the alt path
    /// exists: `graduate` keeps failing and `graduateAlt` is the way out.
    function test_aPermanentlyBlockedPrimaryKeyIsEscapedByTheAltPath() public {
        (BondingCurve curve,) = createLaunchAtCap();

        // A griefer adds liquidity, so the restoring swap would no longer be free.
        poolManager.pokeSlot0(curve.poolId(), TickMath.getSqrtPriceAtTick(100_000), 100_000);
        poolManager.setSwapDelta(-1, 0);

        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.SwapNotFree.selector, -1, 0));
        curve.graduate();
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduating), "state is frozen");

        vm.warp(curve.capReachedAt() + PledrinConstants.ALT_DELAY);
        curve.graduateAlt(100);
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "the alt path worked");
    }

    // ------------------------------------------------------------------
    // The restoring swap's guards
    // ------------------------------------------------------------------

    /// @notice **Invariant 41.** A restoring swap that would cost the curve anything in
    /// either currency reverts the whole graduation rather than spending curve ETH. State
    /// stays frozen and `graduate` is retryable forever.
    function test_aRestoringSwapThatCostsAnythingRevertsTheGraduation() public {
        (BondingCurve curve,) = createLaunchAtCap();
        uint256 reserve = curve.ethReserve();
        poolManager.pokeSlot0(curve.poolId(), TickMath.getSqrtPriceAtTick(100_000), 100_000);

        // A non-zero `currency0` delta.
        poolManager.setSwapDelta(-5, 0);
        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.SwapNotFree.selector, -5, 0));
        curve.graduate();

        // A non-zero `currency1` delta.
        poolManager.setSwapDelta(0, 7);
        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.SwapNotFree.selector, 0, 7));
        curve.graduate();

        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduating), "still Graduating");
        assertEq(curve.ethReserve(), reserve, "no ETH was spent");

        // With the grief removed, the same call succeeds: the failure cost nothing and the
        // graduation is retryable.
        poolManager.setSwapDelta(0, 0);
        curve.graduate();
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "retried");
    }

    /// @notice A swap that settles for nothing but fails to restore the price reverts
    /// before either mint, so the pool can never be seeded at a griefed price.
    function test_aPriceThatCannotBeRestoredRevertsBeforeTheMints() public {
        (BondingCurve curve,) = createLaunchAtCap();
        uint160 griefed = TickMath.getSqrtPriceAtTick(100_000);
        poolManager.pokeSlot0(curve.poolId(), griefed, 100_000);
        poolManager.setSwapRestoresPrice(false);

        uint256 nextId = positionManager.nextTokenId();
        vm.expectRevert(
            abi.encodeWithSelector(
                IBondingCurve.PriceNotRestored.selector, griefed, curve.sqrtPriceTerminal()
            )
        );
        curve.graduate();

        assertEq(positionManager.nextTokenId(), nextId, "no position was minted");
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduating), "still Graduating");
    }

    /// @notice **Invariant 56.** `unlockCallback` reverts unless PoolManager is calling and
    /// the curve is inside its own `unlock`.
    function test_unlockCallbackRejectsEveryOtherCaller() public {
        (BondingCurve curve,) = createLaunchAtCap();
        bytes memory data = abi.encode(_key(address(curve.token()), 200), true);

        vm.prank(OTHER);
        vm.expectRevert(IBondingCurve.NotPoolManager.selector);
        curve.unlockCallback(data);

        // Even the PoolManager cannot drive it outside the curve's own `unlock`.
        vm.prank(address(poolManager));
        vm.expectRevert(IBondingCurve.NotUnlocking.selector);
        curve.unlockCallback(data);
    }

    // ------------------------------------------------------------------
    // The core mint's dust assertion
    // ------------------------------------------------------------------

    /// @notice **Invariant 39's assertion, shown firing.** A core mint that leaves more
    /// than `LP_DUST_MAX` base units unconsumed reverts the graduation. No arithmetic the
    /// real contracts perform can do that — the measured shortfall is at most 28,428 base
    /// units — so the stand-in is told to under-collect by `LP_DUST_MAX + 1`.
    function test_aCoreMintThatLeavesMoreThanDustBehindRevertsTheGraduation() public {
        (BondingCurve curve,) = createLaunchAtCap();
        positionManager.setMintTokenShortfall(PledrinConstants.LP_DUST_MAX + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IBondingCurve.LpDustTooHigh.selector, PledrinConstants.LP_DUST_MAX + 1 + 1088
            )
        );
        curve.graduate();
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduating), "still Graduating");

        // Exactly at the bound it is accepted: the assertion is `>`, not `>=`.
        positionManager.setMintTokenShortfall(PledrinConstants.LP_DUST_MAX - 1088);
        curve.graduate();
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "at the bound");
    }

    // ------------------------------------------------------------------
    // The floor range's assertion
    // ------------------------------------------------------------------

    /// @notice The floor band must fit below the aligned maximum tick. Section 8.2 step 8
    /// says this cannot fire at any permitted parameter set, which
    /// `test/unit/PledrinConstants.t.sol` proves across the whole reserve range; here the
    /// pool reports a tick no `sqrtPriceTerminal` can produce, and the assertion fires.
    function test_aFloorBandThatWouldLeaveTheTickBoundsRevertsTheGraduation() public {
        (BondingCurve curve,) = createLaunchAtCap();

        // 880000 leaves less than FLOOR_RANGE_TICKS of headroom below 887200.
        poolManager.pokeTick(curve.poolId(), 880_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                IBondingCurve.FloorRangeInvalid.selector, 880_200, 894_000, 880_000
            )
        );
        curve.graduate();
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduating), "still Graduating");
    }

    // ------------------------------------------------------------------
    // The de-minimis floor
    // ------------------------------------------------------------------

    /// @notice Section 10.1's `MIN_FLOOR_WEI`, both sides of the boundary. Below it the
    /// floor position is not minted and the ETH stays in a contract with no withdrawal
    /// path; at it, exactly, the position is minted.
    /// @dev `floorEth` is tuned to the wei by donating into the reserve while the launch is
    /// in `Graduating`, where `donate` is still open and nothing else can move. With a
    /// zero fee the base `floorEth` is the 1,088 wei of `R_target` the core mint does not
    /// spend, which is the same rounding that leaves 1,088 base units of token dust.
    function test_theFloorPositionIsSkippedJustBelowMinFloorWeiAndMintedAtIt() public {
        _setZeroFee();

        (BondingCurve below,) = createDefaultLaunch();
        buyToCap(below);
        assertEq(below.protectionEth(), 0, "a zero fee accrues nothing");
        vm.prank(OTHER);
        below.donate{value: PledrinConstants.MIN_FLOOR_WEI - 1 - 1088}();

        uint256 nextId = positionManager.nextTokenId();
        vm.prank(GRADUATOR);
        below.graduate();

        assertEq(positionManager.nextTokenId(), nextId + 1, "only the core position was minted");
        assertEq(
            address(below).balance,
            PledrinConstants.MIN_FLOOR_WEI - 1,
            "the skipped ETH stayed in the curve"
        );
        assertLe(
            address(below).balance,
            PledrinConstants.MIN_FLOOR_WEI,
            "Invariant 43's bound on what is left behind"
        );
        assertEq(below.ethReserve(), 0, "the reserve is still drained");

        (BondingCurve atBound,) = createDefaultLaunch();
        buyToCap(atBound);
        vm.prank(OTHER);
        atBound.donate{value: PledrinConstants.MIN_FLOOR_WEI - 1088}();

        uint256 atNextId = positionManager.nextTokenId();
        vm.prank(GRADUATOR);
        atBound.graduate();

        assertEq(positionManager.nextTokenId(), atNextId + 2, "both positions were minted");
        assertEq(address(atBound).balance, 0, "every wei went into the positions");
        assertGt(
            positionManager.getPositionLiquidity(atNextId + 1),
            0,
            "one millionth of an ETH still buys liquidity over a band this wide"
        );
    }

    /// @notice The floor mint's liquidity is the largest whose `currency0` requirement fits
    /// in `floorEth`, and that requirement never exceeds it.
    /// @dev This is the property behind `_floorLiquidity`'s one-wei fallback. The fallback
    /// itself is unreachable: `getLiquidityForAmount0` floors, so the liquidity it returns
    /// needs strictly less than `floorEth` unless `floorEth * floor(lower * upper / 2**96)`
    /// divides `upper - lower` exactly, and the two round-ups in `getAmount0Delta` then
    /// have to add a whole wei to a number of size `floorEth * (upper - lower) / upper`.
    /// Over the floor band the second condition has probability on the order of
    /// `1 / sqrtPriceLower`. The fuzz below is the evidence that the primary branch is the
    /// one that runs; the fallback is reported as an uncovered defensive line rather than
    /// reached by making the arithmetic lie.
    function testFuzz_theFloorLiquidityRequirementNeverExceedsFloorEth(uint256 floorEth)
        public
        pure
    {
        floorEth = bound(floorEth, PledrinConstants.MIN_FLOOR_WEI, 2000 ether);
        uint160 lower = TickMath.getSqrtPriceAtTick(170_400);
        uint160 upper = TickMath.getSqrtPriceAtTick(184_200);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(lower, upper, floorEth);
        uint256 required = SqrtPriceMath.getAmount0Delta(lower, upper, liquidity, true);
        assertLe(required, floorEth, "the primary liquidity already fits");

        uint128 fallbackLiquidity =
            LiquidityAmounts.getLiquidityForAmount0(lower, upper, floorEth - 1);
        assertLe(
            SqrtPriceMath.getAmount0Delta(lower, upper, fallbackLiquidity, true),
            floorEth,
            "and the fallback would fit too"
        );
    }

    // ------------------------------------------------------------------

    function _setZeroFee() private {
        executeAfterDelay(
            address(factory),
            abi.encodeCall(
                ILaunchFactory.setFeeConfig,
                (ILaunchFactory.FeeConfig({
                        totalFeeBps: 0,
                        unpledged: ILaunchFactory.FeeShares({
                            creatorShareBps: UNPLEDGED_CREATOR_BPS,
                            protocolShareBps: UNPLEDGED_PROTOCOL_BPS,
                            protectionShareBps: UNPLEDGED_PROTECTION_BPS
                        }),
                        pledged: ILaunchFactory.FeeShares({
                            creatorShareBps: PLEDGED_CREATOR_BPS,
                            protocolShareBps: PLEDGED_PROTOCOL_BPS,
                            protectionShareBps: PLEDGED_PROTECTION_BPS
                        })
                    }))
            ),
            bytes32("zero fee")
        );
    }

    function _key(address token, int24 spacing) private pure returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: PledrinConstants.POOL_FEE,
            tickSpacing: spacing,
            hooks: IHooks(address(0))
        });
    }
}
