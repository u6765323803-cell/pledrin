// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";

import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {PledrinConstants} from "src/libraries/PledrinConstants.sol";
import {TickAlign} from "src/libraries/TickAlign.sol";

/// @title `TickAlign` unit and fuzz tests
/// @notice Covers the alignment helpers the graduation tick ranges of `docs/SPEC.md`
/// section 8.2 are built from, and the aligned full-range bounds Invariant 39 and
/// Invariant 42 name.
/// @dev Solidity truncates integer division toward zero, so the sign of the tick decides
/// whether the quotient has to be nudged. The negative cases are the ones that matter:
/// the core position's `tickLower` is `alignUp(MIN_TICK, spacing)`, which is negative.
contract TickAlignTest is Test {
    /// @notice Section 8.2 step 4's full range at the primary tick spacing.
    function test_fullRangeBoundsAtThePrimaryTickSpacing() public pure {
        assertEq(
            TickAlign.up(TickMath.MIN_TICK, PledrinConstants.POOL_TICK_SPACING),
            -887_200,
            "aligned MIN_TICK"
        );
        assertEq(
            TickAlign.down(TickMath.MAX_TICK, PledrinConstants.POOL_TICK_SPACING),
            887_200,
            "aligned MAX_TICK"
        );
    }

    /// @notice The same range at the smallest tick spacing `graduateAlt` accepts.
    function test_fullRangeBoundsAtTheSmallestAlternateTickSpacing() public pure {
        assertEq(
            TickAlign.up(TickMath.MIN_TICK, PledrinConstants.ALT_TICK_SPACING_MIN),
            -887_270,
            "aligned MIN_TICK"
        );
        assertEq(
            TickAlign.down(TickMath.MAX_TICK, PledrinConstants.ALT_TICK_SPACING_MIN),
            887_270,
            "aligned MAX_TICK"
        );
    }

    /// @notice An exact multiple is its own alignment in both directions.
    function test_exactMultiplesAreUnchanged() public pure {
        assertEq(TickAlign.down(170_400, 200), 170_400, "down");
        assertEq(TickAlign.up(170_400, 200), 170_400, "up");
        assertEq(TickAlign.down(-170_400, 200), -170_400, "down, negative");
        assertEq(TickAlign.up(-170_400, 200), -170_400, "up, negative");
    }

    /// @notice Zero is a multiple of every spacing.
    function test_zeroAlignsToZero() public pure {
        assertEq(TickAlign.down(0, 200), 0, "down");
        assertEq(TickAlign.up(0, 200), 0, "up");
    }

    /// @notice The default parameters' terminal tick, 170352, is the value section 8.1
    /// states and the value the floor range is derived from.
    function test_defaultTerminalTickAlignsToTheFloorRange() public pure {
        int24 currentTick = 170_352;
        int24 tickLower = TickAlign.down(currentTick, 200) + 200;
        int24 tickUpper = tickLower + TickAlign.down(PledrinConstants.FLOOR_RANGE_TICKS, 200);

        assertEq(tickLower, 170_400, "floor tickLower");
        assertEq(tickUpper, 184_200, "floor tickUpper");
        assertGt(tickLower, currentTick, "Invariant 42: strictly above the current tick");
    }

    /// @notice A positive tick rounds the two directions apart by one spacing.
    function test_positiveTickRoundsBothWays() public pure {
        assertEq(TickAlign.down(170_352, 200), 170_200, "down");
        assertEq(TickAlign.up(170_352, 200), 170_400, "up");
    }

    /// @notice A negative tick rounds away from zero downward and toward zero upward.
    function test_negativeTickRoundsBothWays() public pure {
        assertEq(TickAlign.down(-170_352, 200), -170_400, "down");
        assertEq(TickAlign.up(-170_352, 200), -170_200, "up");
    }

    /// @notice `FLOOR_RANGE_TICKS` is not a multiple of every permitted spacing, so the
    /// band is narrowed rather than widened: `alignDown` keeps `tickUpper` inside the
    /// band the specification sizes.
    function test_floorWidthIsAlignedDownNotUp() public pure {
        assertEq(TickAlign.down(PledrinConstants.FLOOR_RANGE_TICKS, 200), 13_800, "spacing 200");
        assertEq(TickAlign.down(PledrinConstants.FLOOR_RANGE_TICKS, 10), 13_800, "spacing 10");
        assertEq(TickAlign.down(PledrinConstants.FLOOR_RANGE_TICKS, 80), 13_760, "spacing 80");
        assertLe(
            TickAlign.down(PledrinConstants.FLOOR_RANGE_TICKS, 80),
            PledrinConstants.FLOOR_RANGE_TICKS,
            "never wider than the band"
        );
    }

    /// @notice `down` lands on a multiple at or below the tick, within one spacing of it.
    function testFuzz_downIsTheGreatestMultipleAtMost(int24 tick, int24 spacing) public pure {
        spacing = int24(
            bound(
                spacing,
                PledrinConstants.ALT_TICK_SPACING_MIN,
                PledrinConstants.ALT_TICK_SPACING_MAX
            )
        );
        tick = int24(bound(tick, TickMath.MIN_TICK, TickMath.MAX_TICK));

        int24 aligned = TickAlign.down(tick, spacing);
        assertEq(aligned % spacing, 0, "a multiple of the spacing");
        assertLe(aligned, tick, "at most the tick");
        assertGt(aligned + spacing, tick, "within one spacing");
    }

    /// @notice `up` lands on a multiple at or above the tick, within one spacing of it.
    function testFuzz_upIsTheLeastMultipleAtLeast(int24 tick, int24 spacing) public pure {
        spacing = int24(
            bound(
                spacing,
                PledrinConstants.ALT_TICK_SPACING_MIN,
                PledrinConstants.ALT_TICK_SPACING_MAX
            )
        );
        tick = int24(bound(tick, TickMath.MIN_TICK, TickMath.MAX_TICK));

        int24 aligned = TickAlign.up(tick, spacing);
        assertEq(aligned % spacing, 0, "a multiple of the spacing");
        assertGe(aligned, tick, "at least the tick");
        assertLt(aligned - spacing, tick, "within one spacing");
    }

    /// @notice The two agree exactly on multiples and differ by one spacing elsewhere,
    /// which is the property the floor range's `+ tickSpacing` relies on.
    function testFuzz_theTwoDirectionsDifferByAtMostOneSpacing(int24 tick, int24 spacing)
        public
        pure
    {
        spacing = int24(
            bound(
                spacing,
                PledrinConstants.ALT_TICK_SPACING_MIN,
                PledrinConstants.ALT_TICK_SPACING_MAX
            )
        );
        tick = int24(bound(tick, TickMath.MIN_TICK, TickMath.MAX_TICK));

        int24 low = TickAlign.down(tick, spacing);
        int24 high = TickAlign.up(tick, spacing);
        if (tick % spacing == 0) {
            assertEq(low, high, "equal on a multiple");
        } else {
            assertEq(high - low, spacing, "one spacing apart otherwise");
        }
    }

    /// @notice Invariant 42's `tickLower > currentTick` holds for every tick and every
    /// permitted spacing, which is what makes the floor position an ETH bid rather than a
    /// token sell wall.
    function testFuzz_floorLowerTickIsStrictlyAboveTheCurrentTick(int24 tick, int24 spacing)
        public
        pure
    {
        spacing = int24(
            bound(
                spacing,
                PledrinConstants.ALT_TICK_SPACING_MIN,
                PledrinConstants.ALT_TICK_SPACING_MAX
            )
        );
        tick = int24(bound(tick, TickMath.MIN_TICK, TickMath.MAX_TICK - 1));

        int24 tickLower = TickAlign.down(tick, spacing) + spacing;
        assertGt(tickLower, tick, "Invariant 42");
    }
}
