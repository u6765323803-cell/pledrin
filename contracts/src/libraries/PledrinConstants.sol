// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

/// @title Pledrin global constants
/// @notice Every value in `docs/SPEC.md` section 15.1, plus the per-launch parameter
/// bounds of section 15.2 that are enforced in code.
/// @dev These are protocol-wide and identical for every launch. Nothing here is
/// configurable, and no external address appears here: addresses reach the contracts
/// as constructor arguments only.
library PledrinConstants {
    /// @notice The smallest non-zero dev bond a launch may post.
    /// @dev The floor is proportional to the raise the bond backs, with a flat minimum
    /// underneath it, so a bond is always meaningful relative to its launch rather than
    /// trivial on a large one. Shared by the factory's validation and the curve's
    /// constructor so the two can never disagree (Invariant 28).
    /// @param ethTarget The launch's `R_target`.
    /// @return The minimum acceptable bond in wei.
    function minBondWei(uint256 ethTarget) internal pure returns (uint256) {
        uint256 proportional = (ethTarget * BOND_MIN_BPS_OF_TARGET) / BPS_DENOMINATOR;
        return proportional > MIN_BOND_WEI ? proportional : MIN_BOND_WEI;
    }

    /// @notice Denominator for every basis-point share in the protocol.
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // --- Supply (section 4) ---

    /// @notice Total token supply of every launch, minted once to its curve.
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;
    /// @notice Tokens sellable on the curve before the cap is reached.
    uint256 internal constant CURVE_SUPPLY = 900_000_000e18;
    /// @notice Tokens deposited into the graduated pool's core position.
    uint256 internal constant LP_SUPPLY = 100_000_000e18;

    // --- Curve (section 5) ---

    /// @notice Virtual token reserve at `tokensSold == 0`.
    uint256 internal constant VIRTUAL_TOKEN_RESERVE = 1_012_500_000e18;
    /// @notice Virtual token reserve left at the cap, `VIRTUAL_TOKEN_RESERVE - CURVE_SUPPLY`.
    uint256 internal constant VIRTUAL_TOKEN_TAIL = 112_500_000e18;
    /// @notice `R_target == ETH_TARGET_MULTIPLE * virtualEthReserve`, exactly.
    uint256 internal constant ETH_TARGET_MULTIPLE = 8;
    /// @notice Smallest accepted `buy` value. Sells have no minimum.
    uint256 internal constant MIN_BUY_WEI = 10 ** 12;

    // --- Fees (section 6) ---

    /// @notice Ceiling on a launch's total trading fee, enforced in the curve itself.
    uint16 internal constant MAX_TOTAL_FEE_BPS = 200;
    /// @notice Share of the accrued protocol fee credited to whoever graduates a launch.
    uint256 internal constant GRAD_BOUNTY_BPS = 1000;

    // --- Graduation and the Uniswap v4 pool (sections 8 and 10) ---

    /// @notice LP fee of the canonical pool key, in pips.
    uint24 internal constant POOL_FEE = 10_000;
    /// @notice Tick spacing of the canonical pool key.
    int24 internal constant POOL_TICK_SPACING = 200;
    /// @notice Smallest LP fee `graduateAlt` accepts, in pips.
    uint24 internal constant ALT_POOL_FEE_MIN = 3000;
    /// @notice Largest LP fee `graduateAlt` accepts, in pips.
    /// @dev Equal to `POOL_FEE` rather than above it, so an alternate pool is never more
    /// expensive for a trader than the canonical pool would have been: an escape forced by
    /// a transient attack can only make the graduated pool cheaper to trade.
    uint24 internal constant ALT_POOL_FEE_MAX = POOL_FEE;
    /// @notice Smallest tick spacing `graduateAlt` accepts.
    int24 internal constant ALT_TICK_SPACING_MIN = 10;
    /// @notice Largest tick spacing `graduateAlt` accepts.
    /// @dev Equal to `POOL_TICK_SPACING`, so the alternate set contains keys at the
    /// canonical, coarse spacing and a caller never has to accept the tick-bitmap walk a
    /// fine spacing imposes on the restoring swap. What keeps `graduate` the only path to
    /// the canonical key is the refusal of the single pair `(POOL_FEE, POOL_TICK_SPACING)`,
    /// not a gap in either range.
    int24 internal constant ALT_TICK_SPACING_MAX = POOL_TICK_SPACING;
    /// @notice Width of the holder-protection band, counted upward in tick terms.
    int24 internal constant FLOOR_RANGE_TICKS = 13_800;
    /// @notice De-minimis threshold below which the floor position is not minted.
    uint256 internal constant MIN_FLOOR_WEI = 10 ** 12;
    /// @notice Bound on the base units of `LP_SUPPLY` the core mint cannot consume.
    uint256 internal constant LP_DUST_MAX = 10 ** 5;
    /// @notice Delay in `Graduating` before an alternate pool key may be used.
    uint256 internal constant ALT_DELAY = 3600;
    /// @notice Delay in `Graduating` before the launch may be stalled.
    uint256 internal constant GRAD_GRACE = 604_800;

    // --- Dev Bond (section 11) ---

    /// @notice Flat floor on a non-zero bond.
    uint256 internal constant MIN_BOND_WEI = 10 ** 16;
    /// @notice Ceiling on a bond.
    uint256 internal constant MAX_BOND_WEI = 1000e18;
    /// @notice Proportional floor on a non-zero bond, in bps of `R_target`.
    uint256 internal constant BOND_MIN_BPS_OF_TARGET = 1000;

    // --- Creator allocation (sections 4.1 and 12) ---

    /// @notice Ceiling on the base units the creator's vested first buy may yield.
    uint256 internal constant CREATOR_FIRST_BUY_MAX = 18_000_000e18;

    // --- Governance (section 14) ---

    /// @notice Seconds between a timelock proposal and its execution.
    uint256 internal constant TIMELOCK_DELAY = 172_800;

    // --- Per-launch parameter bounds (section 15.2) ---

    /// @notice Smallest `virtualEthReserve`, giving `R_target == 0.1 ether`.
    uint128 internal constant MIN_VIRTUAL_ETH_RESERVE = 1.25e16;
    /// @notice Largest `virtualEthReserve`, giving `R_target == 1000 ether`.
    uint128 internal constant MAX_VIRTUAL_ETH_RESERVE = 1.25e20;
    /// @notice Shortest graduation window.
    uint32 internal constant MIN_GRAD_WINDOW = 86_400;
    /// @notice Longest graduation window.
    uint32 internal constant MAX_GRAD_WINDOW = 31_536_000;
    /// @notice Longest creator vesting cliff.
    uint32 internal constant MAX_VEST_CLIFF = 7_776_000;
    /// @notice Shortest creator vesting duration.
    uint32 internal constant MIN_VEST_DURATION = 2_592_000;
    /// @notice Longest creator vesting duration.
    uint32 internal constant MAX_VEST_DURATION = 126_144_000;
    /// @notice Longest accepted token name, in bytes.
    uint256 internal constant MAX_NAME_BYTES = 64;
    /// @notice Longest accepted token symbol, in bytes.
    uint256 internal constant MAX_SYMBOL_BYTES = 16;
}
