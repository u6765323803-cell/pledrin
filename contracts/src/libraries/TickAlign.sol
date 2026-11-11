// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

/// @title Tick alignment to a pool's tick spacing
/// @notice Rounding helpers for the tick ranges of `docs/SPEC.md` section 8.2.
/// @dev Solidity truncates integer division toward zero, so the sign of the tick has to
/// be handled explicitly for both directions.
library TickAlign {
    /// @notice Largest multiple of `spacing` that is at most `tick`.
    /// @param tick The tick to align.
    /// @param spacing The pool's tick spacing, strictly positive.
    /// @return The aligned tick.
    function down(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        // Dividing and multiplying back by `spacing` is the alignment itself, not a loss
        // of precision: the truncated remainder is exactly what the result must drop.
        // forge-lint: disable-next-line(divide-before-multiply)
        return compressed * spacing;
    }

    /// @notice Smallest multiple of `spacing` that is at least `tick`.
    /// @param tick The tick to align.
    /// @param spacing The pool's tick spacing, strictly positive.
    /// @return The aligned tick.
    function up(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick > 0 && tick % spacing != 0) compressed++;
        // forge-lint: disable-next-line(divide-before-multiply)
        return compressed * spacing;
    }
}
