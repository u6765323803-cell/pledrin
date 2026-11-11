// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

/// @title The curve constants and the identities that justify them
/// @notice Covers `docs/SPEC.md` sections 4, 5.2, 5.3, 8.1 and 15.1. These are the
/// numbers every other property in the protocol rests on, so each identity the
/// specification claims is asserted here exactly rather than approximately.
/// @dev The third identity — that the curve's terminal marginal price equals the price of
/// a full-range pool holding `R_target` against `LP_SUPPLY` — is the reason graduation
/// opens the pool at the price the last curve buyer paid. If it ever stopped holding, the
/// protocol would hand an arbitrageur a risk-free step at every graduation.
contract PledrinConstantsTest is Test {
    uint256 private constant VT0 = PledrinConstants.VIRTUAL_TOKEN_RESERVE;
    uint256 private constant C = PledrinConstants.CURVE_SUPPLY;
    uint256 private constant TAU = PledrinConstants.VIRTUAL_TOKEN_TAIL;
    uint256 private constant S_LP = PledrinConstants.LP_SUPPLY;

    /// @notice Section 4's allocation table, in base units.
    function test_supplySplitsNinetyTenWithNoCreatorCarveOut() public pure {
        assertEq(PledrinConstants.TOTAL_SUPPLY, 1e27, "total supply");
        assertEq(C, 9e26, "curve supply");
        assertEq(S_LP, 1e26, "LP supply");
        assertEq(C + S_LP, PledrinConstants.TOTAL_SUPPLY, "the two buckets are the whole supply");
        assertEq(C * 10, PledrinConstants.TOTAL_SUPPLY * 9, "90%");
        assertEq(S_LP * 10, PledrinConstants.TOTAL_SUPPLY, "10%");
    }

    /// @notice `VIRTUAL_TOKEN_TAIL` is `VIRTUAL_TOKEN_RESERVE - CURVE_SUPPLY`, which the
    /// curve relies on to never divide by zero at the cap.
    function test_virtualTokenTailIsTheReserveMinusTheSaleSupply() public pure {
        assertEq(TAU, VT0 - C, "tau");
        assertGt(TAU, 0, "the tail keeps the price finite at the cap");
    }

    /// @notice Section 5.3's premise: `C * tau == vT0 * S_LP` exactly in base units.
    function test_theConstantsSatisfyTheExactIdentity() public pure {
        assertEq(C * TAU, VT0 * S_LP, "C * tau == vT0 * S_LP");
        assertEq(C * TAU, 1.0125e53, "the value both sides take");
    }

    /// @notice Section 5.3's first identity: `R_target = vE0 * C / tau = 8 * vE0`, with no
    /// division remainder at any permitted `vE0`.
    function testFuzz_ethTargetIsEightTimesTheVirtualReserveExactly(uint128 vE0) public pure {
        vE0 = uint128(
            bound(
                vE0,
                PledrinConstants.MIN_VIRTUAL_ETH_RESERVE,
                PledrinConstants.MAX_VIRTUAL_ETH_RESERVE
            )
        );

        assertEq((uint256(vE0) * C) % TAU, 0, "the division is exact");
        assertEq(
            (uint256(vE0) * C) / TAU,
            PledrinConstants.ETH_TARGET_MULTIPLE * uint256(vE0),
            "R_target == 8 * vE0"
        );
    }

    /// @notice Section 5.3's second identity: terminal virtual ETH is `K / tau = 9 * vE0`,
    /// so `ethReserve >= 8 * vE0` at the cap. This is Invariant 13's arithmetic half.
    function testFuzz_terminalVirtualEthIsNineTimesTheVirtualReserve(uint128 vE0) public pure {
        vE0 = uint128(
            bound(
                vE0,
                PledrinConstants.MIN_VIRTUAL_ETH_RESERVE,
                PledrinConstants.MAX_VIRTUAL_ETH_RESERVE
            )
        );

        uint256 k = uint256(vE0) * VT0;
        assertEq(k % TAU, 0, "the division is exact");
        assertEq(k / TAU, 9 * uint256(vE0), "K / tau == 9 * vE0");
    }

    /// @notice Section 5.3's third identity, the one graduation depends on: the curve's
    /// terminal marginal price equals `R_target / S_LP`, so the pool opens at exactly the
    /// price the last curve buyer paid.
    function testFuzz_terminalMarginalPriceEqualsThePoolOpeningPrice(uint128 vE0) public pure {
        vE0 = uint128(
            bound(
                vE0,
                PledrinConstants.MIN_VIRTUAL_ETH_RESERVE,
                PledrinConstants.MAX_VIRTUAL_ETH_RESERVE
            )
        );

        uint256 target = PledrinConstants.ETH_TARGET_MULTIPLE * uint256(vE0);
        // P_term = vE0 * vT0 / tau^2 and R_target / S_LP, compared without dividing.
        assertEq(uint256(vE0) * VT0 * S_LP, target * TAU * TAU, "P_term == R_target / S_LP");
    }

    /// @notice Section 5.3: every launch spans exactly an 81-fold price range.
    function test_thePriceRangeIsAlwaysEightyOneFold() public pure {
        assertEq((VT0 * VT0) / (TAU * TAU), 81, "(vT0 / tau)^2 == 81");
        assertEq((VT0 * VT0) % (TAU * TAU), 0, "exactly, with no remainder");
    }

    /// @notice Section 15.2's reserve bounds give `R_target` from 0.1 to 1000 ETH.
    function test_theReserveBoundsGiveTheDocumentedTargetRange() public pure {
        assertEq(
            PledrinConstants.ETH_TARGET_MULTIPLE
                * uint256(PledrinConstants.MIN_VIRTUAL_ETH_RESERVE),
            0.1 ether,
            "smallest raise"
        );
        assertEq(
            PledrinConstants.ETH_TARGET_MULTIPLE
                * uint256(PledrinConstants.MAX_VIRTUAL_ETH_RESERVE),
            1000 ether,
            "largest raise"
        );
    }

    /// @notice Section 8.1: at the default reserve the terminal price is exactly
    /// `5000 * 2**96` with no remainder, and its tick is 170352.
    function test_terminalPriceAtTheDefaultReserveIsExact() public pure {
        uint256 target = PledrinConstants.ETH_TARGET_MULTIPLE * 5e17;
        uint256 ratio = FullMath.mulDiv(S_LP, 1 << 192, target);
        uint160 sqrtPrice = uint160(FixedPointMathLib.sqrt(ratio));

        assertEq(sqrtPrice, 5000 * (uint160(1) << 96), "sqrtPriceTerminal");
        assertEq(uint256(sqrtPrice) * sqrtPrice, ratio, "the square root is exact");
        assertEq(TickMath.getTickAtSqrtPrice(sqrtPrice), 170_352, "terminal tick");
    }

    /// @notice Section 8.1: across the permitted reserve range the terminal tick runs
    /// from 115135 to 207243, well inside v4's bounds, and the price never falls below
    /// `MIN_SQRT_PRICE`.
    function test_terminalTickRangeAcrossThePermittedReserveRange() public pure {
        assertEq(_terminalTick(PledrinConstants.MAX_VIRTUAL_ETH_RESERVE), 115_135, "largest raise");
        assertEq(_terminalTick(PledrinConstants.MIN_VIRTUAL_ETH_RESERVE), 207_243, "smallest raise");
    }

    /// @notice The same bound by fuzz, including the headroom the floor position needs
    /// above the terminal tick. This is the assertion in section 8.2 step 8 that
    /// `tickUpper <= alignDown(MAX_TICK, tickSpacing)` can never fire.
    function testFuzz_terminalTickLeavesRoomForTheFloorBand(uint128 vE0) public pure {
        vE0 = uint128(
            bound(
                vE0,
                PledrinConstants.MIN_VIRTUAL_ETH_RESERVE,
                PledrinConstants.MAX_VIRTUAL_ETH_RESERVE
            )
        );

        int24 tick = _terminalTick(vE0);
        assertGe(tick, 115_135, "lower end");
        assertLe(tick, 207_243, "upper end");
        assertLt(
            tick + PledrinConstants.FLOOR_RANGE_TICKS + PledrinConstants.POOL_TICK_SPACING,
            887_200,
            "the floor band fits below the aligned maximum tick"
        );
    }

    /// @notice Section 11.1: the bond floor is the greater of the flat minimum and a tenth
    /// of the raise, and the crossover is where `R_target / 10 == MIN_BOND_WEI`.
    function test_minimumBondIsTheGreaterOfFlatAndProportional() public pure {
        // A 0.1 ETH raise: a tenth of it is below the flat floor, so the flat floor binds.
        assertEq(PledrinConstants.minBondWei(0.1 ether), PledrinConstants.MIN_BOND_WEI, "flat");
        // A 1000 ETH raise: the proportional floor binds.
        assertEq(PledrinConstants.minBondWei(1000 ether), 100 ether, "proportional");
        // The crossover is exactly at `MIN_BOND_WEI * 10`: below it the flat floor binds,
        // above it the proportional one takes over wei by wei.
        assertEq(PledrinConstants.minBondWei(0.1 ether), 0.01 ether, "crossover");
        assertEq(PledrinConstants.minBondWei(0.1 ether - 10), 0.01 ether, "just below crossover");
        assertEq(
            PledrinConstants.minBondWei(0.1 ether + 10), 0.01 ether + 1, "just above crossover"
        );
    }

    /// @notice The floor is monotone in the raise and never below the flat minimum, which
    /// is what Invariant 28 relies on.
    function testFuzz_minimumBondIsMonotoneAndNeverBelowTheFlatFloor(uint128 target) public pure {
        uint256 bounded = bound(target, 0, 1000 ether);

        uint256 floorWei = PledrinConstants.minBondWei(bounded);
        assertGe(floorWei, PledrinConstants.MIN_BOND_WEI, "never below the flat floor");
        assertGe(PledrinConstants.minBondWei(bounded + 1), floorWei, "monotone");
    }

    /// @notice Section 15.1's `LP_DUST_MAX`. The same literal appears in
    /// `test/fork/V4Assumptions.t.sol`, deliberately, so the specification and the fork
    /// measurement cannot drift apart silently.
    function test_lpDustMaxIsTenToTheFifth() public pure {
        assertEq(PledrinConstants.LP_DUST_MAX, 10 ** 5, "LP_DUST_MAX");
    }

    /// @notice Every remaining section 15.1 constant, pinned so a stray edit shows up as a
    /// test failure rather than as changed behaviour.
    function test_theRemainingGlobalConstants() public pure {
        assertEq(PledrinConstants.BPS_DENOMINATOR, 10_000, "BPS_DENOMINATOR");
        assertEq(PledrinConstants.ETH_TARGET_MULTIPLE, 8, "ETH_TARGET_MULTIPLE");
        assertEq(PledrinConstants.CREATOR_FIRST_BUY_MAX, 18_000_000e18, "CREATOR_FIRST_BUY_MAX");
        assertEq(PledrinConstants.MIN_BUY_WEI, 10 ** 12, "MIN_BUY_WEI");
        assertEq(PledrinConstants.MAX_TOTAL_FEE_BPS, 200, "MAX_TOTAL_FEE_BPS");
        assertEq(PledrinConstants.GRAD_BOUNTY_BPS, 1000, "GRAD_BOUNTY_BPS");
        assertEq(PledrinConstants.POOL_FEE, 10_000, "POOL_FEE");
        assertEq(PledrinConstants.POOL_TICK_SPACING, 200, "POOL_TICK_SPACING");
        assertEq(PledrinConstants.ALT_TICK_SPACING_MIN, 10, "ALT_TICK_SPACING_MIN");
        assertEq(PledrinConstants.ALT_TICK_SPACING_MAX, 200, "ALT_TICK_SPACING_MAX");
        assertEq(PledrinConstants.ALT_POOL_FEE_MIN, 3000, "ALT_POOL_FEE_MIN");
        assertEq(PledrinConstants.ALT_POOL_FEE_MAX, 10_000, "ALT_POOL_FEE_MAX");
        assertEq(PledrinConstants.FLOOR_RANGE_TICKS, 13_800, "FLOOR_RANGE_TICKS");
        assertEq(PledrinConstants.MIN_FLOOR_WEI, 10 ** 12, "MIN_FLOOR_WEI");
        assertEq(PledrinConstants.MIN_BOND_WEI, 10 ** 16, "MIN_BOND_WEI");
        assertEq(PledrinConstants.MAX_BOND_WEI, 1000e18, "MAX_BOND_WEI");
        assertEq(PledrinConstants.BOND_MIN_BPS_OF_TARGET, 1000, "BOND_MIN_BPS_OF_TARGET");
        assertEq(PledrinConstants.ALT_DELAY, 3600, "ALT_DELAY");
        assertEq(PledrinConstants.GRAD_GRACE, 604_800, "GRAD_GRACE");
        assertEq(PledrinConstants.TIMELOCK_DELAY, 172_800, "TIMELOCK_DELAY");
        assertEq(PledrinConstants.MIN_GRAD_WINDOW, 86_400, "MIN_GRAD_WINDOW");
        assertEq(PledrinConstants.MAX_GRAD_WINDOW, 31_536_000, "MAX_GRAD_WINDOW");
        assertEq(PledrinConstants.MAX_VEST_CLIFF, 7_776_000, "MAX_VEST_CLIFF");
        assertEq(PledrinConstants.MIN_VEST_DURATION, 2_592_000, "MIN_VEST_DURATION");
        assertEq(PledrinConstants.MAX_VEST_DURATION, 126_144_000, "MAX_VEST_DURATION");
        assertEq(PledrinConstants.MAX_NAME_BYTES, 64, "MAX_NAME_BYTES");
        assertEq(PledrinConstants.MAX_SYMBOL_BYTES, 16, "MAX_SYMBOL_BYTES");
    }

    /// @notice **Invariant 67 at the constants.** The alternate key set is the product of
    /// the two ranges minus the single canonical pair, and that one exclusion is the whole
    /// mechanism that keeps `graduate` the only route to the canonical key.
    /// @dev **This test asserted the opposite relationship until decision 22.** It required
    /// `ALT_TICK_SPACING_MAX < POOL_TICK_SPACING`, so that the canonical key was outside the
    /// alternate set by a gap in the spacing range. That gap also put the coarse canonical
    /// spacing out of reach of every alternate key, which mattered because the restoring
    /// swap's tick-bitmap walk is expensive at a fine spacing, and finding 3 of
    /// `docs/security/REVIEW-2026-11-11-phase1-contracts.md` showed the gap bought nothing:
    /// the keys it protected could be removed from the usable set by a bare `initialize` for
    /// gas alone. The cap is now `POOL_TICK_SPACING` itself and the pair `(POOL_FEE,
    /// POOL_TICK_SPACING)` is refused in `graduateAlt`. What is pinned here is therefore the
    /// arithmetic of the set; the refusal itself is asserted against the contract in
    /// `test/unit/BondingCurveGraduationGuards.t.sol`.
    function test_theAlternateKeySetIsBothRangesMinusTheCanonicalPair() public pure {
        assertEq(
            PledrinConstants.ALT_TICK_SPACING_MAX,
            PledrinConstants.POOL_TICK_SPACING,
            "the spacing range reaches the canonical spacing and stops there"
        );
        assertEq(
            PledrinConstants.ALT_POOL_FEE_MAX,
            PledrinConstants.POOL_FEE,
            "and the fee range reaches the canonical fee, so no alternate pool is dearer"
        );
        assertLe(
            PledrinConstants.ALT_TICK_SPACING_MIN,
            PledrinConstants.ALT_TICK_SPACING_MAX,
            "the spacing window is non-empty"
        );
        assertGt(PledrinConstants.ALT_TICK_SPACING_MIN, 0, "and strictly positive");
        assertLe(
            PledrinConstants.ALT_POOL_FEE_MIN,
            PledrinConstants.ALT_POOL_FEE_MAX,
            "the fee window is non-empty"
        );
        assertLe(
            PledrinConstants.ALT_POOL_FEE_MAX,
            1_000_000,
            "and inside LPFeeLibrary.MAX_LP_FEE, which PoolManager.initialize enforces"
        );
        assertLe(
            PledrinConstants.ALT_TICK_SPACING_MAX,
            32_767,
            "and the spacing inside TickMath.MAX_TICK_SPACING, enforced in the same place"
        );

        // The size of the set, which is the number section 8.4 and Invariant 67 quote.
        uint256 fees = PledrinConstants.ALT_POOL_FEE_MAX - PledrinConstants.ALT_POOL_FEE_MIN + 1;
        uint256 spacings = uint256(
            int256(PledrinConstants.ALT_TICK_SPACING_MAX - PledrinConstants.ALT_TICK_SPACING_MIN)
        ) + 1;
        assertEq(fees * spacings - 1, 1_337_190, "Invariant 67: 1,337,190 usable keys");
    }

    /// @notice Section 4.1's creator first-buy ceiling, 18,000,000 whole tokens.
    /// @dev The ceiling is **1.8%** of `TOTAL_SUPPLY`, not the 2% that `docs/SPEC.md`
    /// sections 4.1 and 12 state: 18,000,000 of 1,000,000,000 is 1.8%. The constant is the
    /// number the specification gives in base units and the code agrees with it; only the
    /// percentage in the prose is wrong. This test asserts the ratio the constant actually
    /// has so the discrepancy cannot be resolved silently in the wrong direction.
    function test_creatorFirstBuyCeilingIsEighteenMillionWholeTokens() public pure {
        assertEq(PledrinConstants.CREATOR_FIRST_BUY_MAX, 18_000_000e18, "ceiling");
        assertEq(
            PledrinConstants.CREATOR_FIRST_BUY_MAX * 1000,
            PledrinConstants.TOTAL_SUPPLY * 18,
            "1.8% of total supply"
        );
        assertLt(
            PledrinConstants.CREATOR_FIRST_BUY_MAX * 50,
            PledrinConstants.TOTAL_SUPPLY,
            "below the 2% the prose claims"
        );
    }

    function _terminalTick(uint128 vE0) private pure returns (int24) {
        uint256 target = PledrinConstants.ETH_TARGET_MULTIPLE * uint256(vE0);
        uint160 sqrtPrice = uint160(FixedPointMathLib.sqrt(FullMath.mulDiv(S_LP, 1 << 192, target)));
        assertGt(sqrtPrice, TickMath.MIN_SQRT_PRICE, "above MIN_SQRT_PRICE");
        return TickMath.getTickAtSqrtPrice(sqrtPrice);
    }
}
