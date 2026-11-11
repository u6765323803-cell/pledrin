// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
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
import {AtomicRestorer} from "../helpers/AtomicRestorer.sol";
import {PoolSwapHelper} from "../helpers/PoolSwapHelper.sol";

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
        curve.graduateAlt(PledrinConstants.POOL_FEE, 100);

        vm.warp(capReachedAt + PledrinConstants.ALT_DELAY - 1);
        vm.expectRevert(IBondingCurve.AltDelayNotElapsed.selector);
        curve.graduateAlt(PledrinConstants.POOL_FEE, 100);

        vm.warp(capReachedAt + PledrinConstants.ALT_DELAY);
        curve.graduateAlt(PledrinConstants.POOL_FEE, 100);
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "Graduated");
    }

    /// @notice **Invariant 37's second half and section 16.2's check order.** The state
    /// check precedes the alternate-delay check, so a launch that has already graduated is
    /// told which state refused it rather than told to wait out a delay that is not what
    /// stands in its caller's way.
    /// @dev Both launches are inspected at the same instant, inside `ALT_DELAY`, and
    /// differ only in state. That is what makes this a test of the order of the two checks
    /// rather than of either check alone: with the delay checked first, the graduated
    /// launch would answer `AltDelayNotElapsed` and this would fail. The launch that is
    /// genuinely waiting is asserted alongside it, so the test also shows the delay check
    /// still fires where it is the real blocker, and the calldata verdict is shown
    /// preceding both in either state.
    function test_aGraduatedLaunchIsRefusedForItsStateAndNotForTheAltDelay() public {
        (BondingCurve graduated,) = createLaunchAtCap();
        (BondingCurve graduating,) = createLaunchAtCap();

        vm.prank(GRADUATOR);
        graduated.graduate();

        assertEq(graduated.capReachedAt(), graduating.capReachedAt(), "one clock for both");
        assertLt(
            vm.getBlockTimestamp(),
            uint256(graduated.capReachedAt()) + PledrinConstants.ALT_DELAY,
            "and the delay has elapsed for neither, which is where the checks disagree"
        );

        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Graduated)
        );
        graduated.graduateAlt(PledrinConstants.POOL_FEE, 100);

        vm.expectRevert(IBondingCurve.AltDelayNotElapsed.selector);
        graduating.graduateAlt(PledrinConstants.POOL_FEE, 100);

        // **Invariant 67.** All three calldata refusals precede the state check, in both
        // states.
        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.InvalidTickSpacing.selector, 201));
        graduated.graduateAlt(PledrinConstants.POOL_FEE, 201);
        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.InvalidTickSpacing.selector, 201));
        graduating.graduateAlt(PledrinConstants.POOL_FEE, 201);
        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.InvalidPoolFee.selector, 2999));
        graduated.graduateAlt(2999, 100);
        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.InvalidPoolFee.selector, 2999));
        graduating.graduateAlt(2999, 100);
        vm.expectRevert(IBondingCurve.CanonicalKeyNotAllowed.selector);
        graduated.graduateAlt(
            PledrinConstants.POOL_FEE, uint24(int24(PledrinConstants.POOL_TICK_SPACING))
        );
        vm.expectRevert(IBondingCurve.CanonicalKeyNotAllowed.selector);
        graduating.graduateAlt(
            PledrinConstants.POOL_FEE, uint24(int24(PledrinConstants.POOL_TICK_SPACING))
        );

        assertEq(uint8(graduated.state()), uint8(IBondingCurve.State.Graduated), "unmoved");
        assertEq(uint8(graduating.state()), uint8(IBondingCurve.State.Graduating), "and unmoved");
    }

    /// @notice **Invariant 67.** `graduateAlt` accepts `fee` in `[3000, 10000]` and
    /// `tickSpacing` in `[10, 200]`, narrowed through `SafeCast`, and refuses exactly one
    /// pair out of the 1,337,190: the canonical `(POOL_FEE, POOL_TICK_SPACING)`.
    /// @dev `ALT_TICK_SPACING_MAX` was 199 until decision 22, one below
    /// `POOL_TICK_SPACING`, and the gap in the range was what kept the alternate key away
    /// from the canonical one. It no longer is: the spacing range now *includes* 200, and
    /// what keeps `graduate` the only path to the canonical key is the refusal of that one
    /// pair. The distinction is the point of this test. A caller who wants the coarse
    /// canonical spacing — and they will, because a fine spacing imposes a tick-bitmap walk
    /// on the restoring swap — can have it at any other fee.
    function test_graduateAltAcceptsOnlyThePermittedFeesAndTickSpacings() public {
        (BondingCurve curve,) = createLaunchAtCap();
        vm.warp(curve.capReachedAt() + PledrinConstants.ALT_DELAY);

        // The spacing range, one outside on each side.
        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.InvalidTickSpacing.selector, 0));
        curve.graduateAlt(PledrinConstants.POOL_FEE, 0);
        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.InvalidTickSpacing.selector, 9));
        curve.graduateAlt(PledrinConstants.POOL_FEE, 9);
        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.InvalidTickSpacing.selector, 201));
        curve.graduateAlt(PledrinConstants.POOL_FEE, 201);

        // A spacing that does not fit in an `int24` is refused by the cast rather than by
        // the range check, which is the narrowing Invariant 67 names.
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeCast.SafeCastOverflowedIntDowncast.selector, 24, int256(8_388_608)
            )
        );
        curve.graduateAlt(PledrinConstants.POOL_FEE, 8_388_608);

        // The fee range, one outside on each side.
        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.InvalidPoolFee.selector, 2999));
        curve.graduateAlt(2999, 100);
        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.InvalidPoolFee.selector, 10_001));
        curve.graduateAlt(10_001, 100);

        // And the one refused pair, which is inside both ranges.
        vm.expectRevert(IBondingCurve.CanonicalKeyNotAllowed.selector);
        curve.graduateAlt(
            PledrinConstants.POOL_FEE, uint24(int24(PledrinConstants.POOL_TICK_SPACING))
        );
        // Either field moved by one makes it another key, and both of those are accepted.
        curve.graduateAlt(
            PledrinConstants.POOL_FEE - 1, uint24(int24(PledrinConstants.POOL_TICK_SPACING))
        );
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "9999 / 200");

        (BondingCurve other, IERC20 otherToken) = createLaunchAtCap();
        vm.warp(other.capReachedAt() + PledrinConstants.ALT_DELAY);
        other.graduateAlt(
            PledrinConstants.POOL_FEE, uint24(int24(PledrinConstants.POOL_TICK_SPACING)) - 1
        );
        assertEq(uint8(other.state()), uint8(IBondingCurve.State.Graduated), "10000 / 199");

        // That launch graduated onto its own key and left the canonical key, which its own
        // launch transaction opened, untouched at the terminal price.
        PoolKey memory altKey = _key(address(otherToken), PledrinConstants.POOL_TICK_SPACING - 1);
        (uint160 altPrice,) = poolManager.slot0(altKey.toId());
        assertEq(altPrice, other.sqrtPriceTerminal(), "the 199 key opened at the terminal price");
        assertNotEq(
            PoolId.unwrap(altKey.toId()),
            PoolId.unwrap(other.poolId()),
            "and it is not the canonical key"
        );
        (uint160 canonicalPrice,) = poolManager.slot0(other.poolId());
        assertEq(canonicalPrice, other.sqrtPriceTerminal(), "which is still at that price too");

        // Every corner of the two ranges graduates. One launch each, because a launch
        // graduates once.
        _assertAltKeyGraduates(PledrinConstants.ALT_POOL_FEE_MIN, 10);
        _assertAltKeyGraduates(PledrinConstants.ALT_POOL_FEE_MIN, 200);
        _assertAltKeyGraduates(PledrinConstants.ALT_POOL_FEE_MAX, 10);
        _assertAltKeyGraduates(PledrinConstants.ALT_POOL_FEE_MAX, 199);
    }

    /// @dev One fresh launch graduated on one alternate key, asserting the key it landed on
    /// is the key it was given — which is Invariant 69 read off the log.
    function _assertAltKeyGraduates(uint24 fee, uint24 tickSpacing) private {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        vm.warp(curve.capReachedAt() + PledrinConstants.ALT_DELAY);

        vm.recordLogs();
        curve.graduateAlt(fee, tickSpacing);

        GraduatedLog memory log = graduatedLog(address(curve));
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "graduated");
        assertEq(log.fee, fee, "Invariant 69: the fee the key used");
        assertEq(uint24(int24(log.tickSpacing)), tickSpacing, "Invariant 69: and the spacing");
        assertEq(
            log.poolId,
            PoolId.unwrap(poolKeyFor(address(token), fee, int24(uint24(tickSpacing))).toId()),
            "Invariant 69: the key is reconstructible from the log and token()"
        );
    }

    /// @notice **Invariant 38.** `graduateAlt` accepts an alternate key somebody else has
    /// already opened, at any price, and restores the price instead of refusing the key.
    /// @dev **This test asserted the opposite until decision 22**, and the assertion was
    /// the defect: `graduateAlt` required an uninitialised pool, and a bare `initialize`
    /// costs about 47,000 gas with no capital and nothing at risk, so all of the then-190
    /// alternate keys could be removed from the usable set for pennies. Finding 3 of
    /// `docs/security/REVIEW-2026-11-11-phase1-contracts.md`. What replaces the refusal is
    /// the machinery the canonical key already had: restore the price for free, assert it,
    /// then mint. The price a stranger opened the key at reaches nothing.
    function test_graduateAltAcceptsAnAlreadyOpenAlternateKey() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        vm.warp(curve.capReachedAt() + PledrinConstants.ALT_DELAY);

        // Somebody opens the alternate key first, at a price of their choosing.
        PoolKey memory altKey = _key(address(token), 100);
        poolManager.initialize(altKey, TickMath.getSqrtPriceAtTick(100_000));
        assertEq(poolManager.initializedPoolCount(), 2, "the canonical key and the seized one");

        curve.graduateAlt(PledrinConstants.POOL_FEE, 100);

        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "it graduated there");
        (uint160 price,) = poolManager.slot0(altKey.toId());
        assertEq(price, curve.sqrtPriceTerminal(), "at the terminal price, restored not opened");
        assertEq(poolManager.swapCalls(), 1, "by exactly one restoring swap");
        assertEq(poolManager.initializedPoolCount(), 2, "and nothing was initialised a second time");
    }

    /// @notice An alternate key already open **at the terminal price** needs no swap at all.
    /// @dev The cheapest case, and one a third party can arrange deliberately: moving a
    /// zero-liquidity pool costs nothing, so anybody can set a key up for a graduation that
    /// then performs no swap of its own.
    function test_graduateAltOnAnOpenKeyAlreadyAtTheTerminalPriceSwapsNothing() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        vm.warp(curve.capReachedAt() + PledrinConstants.ALT_DELAY);

        poolManager.initialize(_key(address(token), 100), curve.sqrtPriceTerminal());

        curve.graduateAlt(PledrinConstants.POOL_FEE, 100);

        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "graduated");
        assertEq(poolManager.swapCalls(), 0, "nothing to restore");
    }

    /// @notice Liquidity in the restoring swap's path still blocks **that key**, and the
    /// launch is not stuck: every other key in the set remains available.
    /// @dev This is what the refusal has become. A griefer can raise the cost of one
    /// particular key, by holding liquidity on it rather than by opening it, and the caller
    /// picks another of the 1,337,190.
    function test_liquidityInTheSwapPathBlocksOneAlternateKeyAndNotTheLaunch() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        vm.warp(curve.capReachedAt() + PledrinConstants.ALT_DELAY);

        poolManager.initialize(_key(address(token), 100), TickMath.getSqrtPriceAtTick(100_000));
        poolManager.setSwapDelta(-1, 0);

        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.SwapNotFree.selector, -1, 0));
        curve.graduateAlt(PledrinConstants.POOL_FEE, 100);
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduating), "state is frozen");

        // Another key, which nobody has touched, and the graduation completes.
        poolManager.setSwapDelta(0, 0);
        curve.graduateAlt(PledrinConstants.POOL_FEE, 60);
        (uint160 price,) = poolManager.slot0(_key(address(token), 60).toId());
        assertEq(price, curve.sqrtPriceTerminal(), "the alt pool opened at the terminal price");
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "graduated");
    }

    /// @notice A graduation on the alternate key mints the same two positions, on the
    /// alternate spacing's aligned ticks, and performs no restoring swap at all.
    function test_graduateAltMintsBothPositionsOnTheAlternateSpacing() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        vm.warp(curve.capReachedAt() + PledrinConstants.ALT_DELAY);

        uint256 coreId = positionManager.nextTokenId();
        curve.graduateAlt(PledrinConstants.POOL_FEE, 100);

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
        curve.graduateAlt(PledrinConstants.POOL_FEE, 100);
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "the alt path worked");
    }

    /// @notice **The recovery path finding 3 identified.** A third party restores a griefed
    /// price and graduates the launch in the same transaction, and the curve performs no
    /// swap of its own.
    /// @dev This is what saves a graduation the curve cannot complete by itself. The curve
    /// refuses to pay for a restoring swap — Invariant 41, and the test below is the one
    /// that asserts it — so when liquidity in the swap's path makes the restore cost
    /// something, the curve's own attempt reverts `SwapNotFree` forever. Anybody may move
    /// the price with their own funds instead, and then `graduate()` finds the price already
    /// correct and skips `_restorePrice` entirely. One transaction, so a griefer cannot
    /// re-grief in between: that is the whole value of the path.
    ///
    /// The stand-in's swap delta is a global knob rather than a per-caller cost, so the
    /// third party's swap is free here and the refusal is shown first with the knob set.
    /// `test/fork/V4Assumptions.t.sol`'s
    /// `test_assumption1_restorationIsNotFreeOnceSomeoneAddsLiquidity` is where a real
    /// third party pays a real restoring swap against the deployed PoolManager.
    function test_aThirdPartyCanRestoreThePriceAndGraduateInOneTransaction() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        uint160 terminal = curve.sqrtPriceTerminal();

        // Griefed below the terminal price, with liquidity in the way, so the curve's own
        // restore is refused and stays refused.
        poolManager.pokeSlot0(curve.poolId(), TickMath.getSqrtPriceAtTick(100_000), 100_000);
        poolManager.setSwapDelta(-1, 0);
        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.SwapNotFree.selector, -1, 0));
        curve.graduate();
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduating), "still frozen");

        // A third party pays for the restore out of their own funds, which is the part the
        // curve refuses to do, and graduates in the same call.
        poolManager.setSwapDelta(0, 0);
        AtomicRestorer restorer =
            new AtomicRestorer(new PoolSwapHelper(IPoolManager(address(poolManager))));
        uint256 swapsBefore = poolManager.swapCalls();
        restorer.restoreAndGraduate(
            IBondingCurve(address(curve)),
            _key(address(token), PledrinConstants.POOL_TICK_SPACING),
            false,
            terminal
        );

        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "it graduated");
        assertEq(poolManager.swapCalls(), swapsBefore + 1, "exactly one swap, and it was theirs");
        (uint160 price,) = poolManager.slot0(curve.poolId());
        assertEq(price, terminal, "the price the mint saw was the terminal price");
        assertEq(
            curve.pendingBountyWei(address(restorer)),
            curve.pendingBountyTotalWei(),
            "the bounty went to the caller that did the work"
        );
        assertEq(curve.ethReserve(), 0, "Invariant 43");
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
