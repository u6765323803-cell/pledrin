// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {ILaunchFactory} from "src/interfaces/ILaunchFactory.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";
import {TickAlign} from "src/libraries/TickAlign.sol";

import {PledrinTestBase} from "../base/PledrinTestBase.sol";

/// @title The core mint's ETH cost, pinned to the wei
/// @notice Covers `docs/SPEC.md` section 8.2 step 4, Invariant 39's ETH clause, Invariant
/// 60's ETH quantifier and finding 7 of
/// `docs/security/REVIEW-2026-11-11-phase1-contracts.md`.
/// @dev Since `5b86188`, `Graduated.ethToCore` is a value **computed** from
/// `SqrtPriceMath`, `TickMath` and `LiquidityAmounts` rather than a balance difference, and
/// it is in the log an indexer records. That makes a rounding change in any of those three
/// libraries an observable change in protocol output, and the rounding is not incidental:
/// the ETH headroom `R_target - ethToCore` is **171 wei** at the bottom of the permitted
/// reserve range, and if it ever went negative `SlippageCheck.validateMaxIn` would revert
/// the mint, graduation would be impossible for that launch, and `abortGraduation` into
/// `Stalled` with no pool would be the only exit. A library bump has to fail loudly here
/// rather than quietly there.
///
/// Every figure in this file was re-derived from the definitions in sections 8.1 and 8.2 —
/// `R_target = 8 * vE0`, `sqrtPriceTerminal = floor(sqrt(mulDiv(LP_SUPPLY, 2**192,
/// R_target)))`, the two aligned ticks, the liquidity that `LP_SUPPLY` of `currency1` buys,
/// and `getAmount0Delta(..., roundUp = true)` — and not copied from the review or from the
/// contract. `_coreEth` below is that derivation; the literals are what it produced.
contract CoreMintArithmeticTest is PledrinTestBase {
    /// @dev `R_target - ethToCore` at the default reserve. Equal to the token dust at the
    /// same parameters, which is a coincidence of `LP_SUPPLY = 1e26` against
    /// `R_target = 4e18` and is asserted as two separate numbers for that reason.
    uint256 internal constant DEFAULT_HEADROOM = 1088;

    // ------------------------------------------------------------------
    // The three reserves the specification quotes, to the wei
    // ------------------------------------------------------------------

    /// @notice The default reserve: **3,999,999,999,999,998,912 wei**, 1,088 wei inside
    /// `R_target`.
    function test_coreEthAtTheDefaultVirtualReserve() public pure {
        assertEq(_coreEth(DEFAULT_VE0, 200), 3_999_999_999_999_998_912, "spacing 200");
        assertEq(
            8 * uint256(DEFAULT_VE0) - _coreEth(DEFAULT_VE0, 200), DEFAULT_HEADROOM, "headroom"
        );

        // The alternate spacings move it, because `tickUpper` moves: 10 is the finest
        // `graduateAlt` accepts and it costs four wei more.
        assertEq(_coreEth(DEFAULT_VE0, 10), 3_999_999_999_999_998_916, "spacing 10");
        assertEq(8 * uint256(DEFAULT_VE0) - _coreEth(DEFAULT_VE0, 10), 1084, "headroom at 10");
    }

    /// @notice `MIN_VIRTUAL_ETH_RESERVE`, where the headroom is at its smallest in the whole
    /// permitted range: **172 wei** at the canonical spacing and **171** at spacing 10.
    /// @dev This is the pair finding 7 asks for. 171 wei of margin on a failure with no
    /// recovery path is the reason these are equalities and not bounds.
    function test_coreEthAtTheSmallestPermittedRaise() public pure {
        uint128 vE0 = PledrinConstants.MIN_VIRTUAL_ETH_RESERVE;
        assertEq(8 * uint256(vE0), 0.1 ether, "the smallest permitted raise");

        assertEq(_coreEth(vE0, 200), 99_999_999_999_999_828, "spacing 200");
        assertEq(8 * uint256(vE0) - _coreEth(vE0, 200), 172, "172 wei of headroom");

        assertEq(_coreEth(vE0, 10), 99_999_999_999_999_829, "spacing 10");
        assertEq(8 * uint256(vE0) - _coreEth(vE0, 10), 171, "171 wei of headroom");
    }

    /// @notice `MAX_VIRTUAL_ETH_RESERVE`, the other end: 17,205 wei of headroom.
    /// @dev Section 8.2 called the headroom non-monotone in `virtualEthReserve`. Over the
    /// permitted range it is not: it rises from 171 at the bottom to 17,205 at the top, as
    /// the review found. The conclusion the specification drew from the non-monotonicity —
    /// that `amount0Max` must stay at exactly `R_target` — survives for the stronger
    /// reason, which is the 171 wei this file pins above.
    function test_coreEthAtTheLargestPermittedRaise() public pure {
        uint128 vE0 = PledrinConstants.MAX_VIRTUAL_ETH_RESERVE;
        assertEq(8 * uint256(vE0), 1000 ether, "the largest permitted raise");

        assertEq(_coreEth(vE0, 200), 999_999_999_999_999_982_795, "spacing 200");
        assertEq(8 * uint256(vE0) - _coreEth(vE0, 200), 17_205, "17,205 wei of headroom");
        assertEq(8 * uint256(vE0) - _coreEth(vE0, 10), 17_144, "and 17,144 at spacing 10");
    }

    // ------------------------------------------------------------------
    // The property the literals are a witness for
    // ------------------------------------------------------------------

    /// @notice **The mint always fits.** Over the whole permitted reserve range and every
    /// permitted tick spacing, the core position's `currency0` requirement is at most
    /// `R_target`, so `validateMaxIn` passes and `ethTarget - coreEth` cannot underflow.
    function testFuzz_theCoreMintNeverCostsMoreThanTheTarget(
        uint256 reserveSeed,
        uint256 spacingSeed
    ) public pure {
        uint128 vE0 = uint128(
            bound(
                reserveSeed,
                PledrinConstants.MIN_VIRTUAL_ETH_RESERVE,
                PledrinConstants.MAX_VIRTUAL_ETH_RESERVE
            )
        );
        int24 spacing = int24(
            int256(
                bound(
                    spacingSeed,
                    uint256(int256(PledrinConstants.ALT_TICK_SPACING_MIN)),
                    uint256(int256(PledrinConstants.POOL_TICK_SPACING))
                )
            )
        );

        uint256 target = 8 * uint256(vE0);
        uint256 coreEth = _coreEth(vE0, spacing);
        assertLe(coreEth, target, "Invariant 39: at most 8 * vE0");
        assertGt(coreEth, target - 100_000, "and within a dust of it, so no ETH is stranded");
    }

    /// @notice The worst headroom in the range is at the very bottom of it, and it is 171.
    /// @dev A one-wei stride across the first 200 wei of the permitted range at every tenth
    /// spacing. The bottom is where a drift would first turn into an unrecoverable
    /// graduation, so it is walked rather than sampled.
    function test_theWorstHeadroomIsAtTheBottomOfTheRange() public pure {
        uint256 worst = type(uint256).max;
        uint128 worstReserve;
        int24 worstSpacing;

        for (uint256 i = 0; i < 200; i++) {
            uint128 vE0 = PledrinConstants.MIN_VIRTUAL_ETH_RESERVE + uint128(i);
            for (int24 spacing = 10; spacing <= 200; spacing += 10) {
                uint256 headroom = 8 * uint256(vE0) - _coreEth(vE0, spacing);
                if (headroom < worst) {
                    worst = headroom;
                    worstReserve = vE0;
                    worstSpacing = spacing;
                }
            }
        }

        assertEq(worst, 171, "the smallest headroom anywhere in the range");
        assertEq(worstReserve, PledrinConstants.MIN_VIRTUAL_ETH_RESERVE, "at the bottom");
        assertEq(worstSpacing, 10, "and at the finest permitted spacing");
    }

    // ------------------------------------------------------------------
    // The same numbers, out of the contract's own log
    // ------------------------------------------------------------------

    /// @notice The `ethToCore` a graduation emits is the derived number, at all three
    /// reserves and on both the canonical key and an alternate one.
    /// @dev This is the half of the pin that catches a change in the *contract* rather than
    /// in the libraries: the literals above would survive `_mintCore` reading a balance
    /// again, and these assertions would not. `test/fork/Graduation.fork.t.sol` and
    /// `test/fork/GraduationRange.fork.t.sol` assert the same literals against the real
    /// PositionManager, which is what makes them measurements of Uniswap rather than of
    /// this suite's stand-in.
    function test_theEmittedEthToCoreIsTheDerivedNumber() public {
        assertEq(
            _graduateAndReadEthToCore(DEFAULT_VE0, 0),
            3_999_999_999_999_998_912,
            "the default reserve, canonical spacing"
        );
        assertEq(
            _graduateAndReadEthToCore(PledrinConstants.MIN_VIRTUAL_ETH_RESERVE, 0),
            99_999_999_999_999_828,
            "the smallest permitted raise, canonical spacing"
        );
        assertEq(
            _graduateAndReadEthToCore(PledrinConstants.MAX_VIRTUAL_ETH_RESERVE, 0),
            999_999_999_999_999_982_795,
            "the largest permitted raise, canonical spacing"
        );
        assertEq(
            _graduateAndReadEthToCore(PledrinConstants.MIN_VIRTUAL_ETH_RESERVE, 10),
            99_999_999_999_999_829,
            "the smallest permitted raise on spacing 10, where 171 wei is the whole margin"
        );
    }

    /// @notice And the terminal price the whole derivation starts from is the one the
    /// constructor computed.
    function test_theTerminalPriceIsTheDerivedOne() public {
        (BondingCurve curve,) = createDefaultLaunch();
        assertEq(
            curve.sqrtPriceTerminal(),
            _sqrtPriceTerminal(DEFAULT_VE0),
            "sqrt(mulDiv(LP_SUPPLY, 2**192, R_target))"
        );
        assertEq(
            curve.sqrtPriceTerminal(),
            5000 * (uint160(1) << 96),
            "section 8.1: exactly 5000 * 2**96 at the default reserve"
        );
    }

    // ------------------------------------------------------------------
    // The derivation itself
    // ------------------------------------------------------------------

    /// @dev `docs/SPEC.md` section 8.1: the terminal price, floored, on a 512-bit
    /// intermediate.
    function _sqrtPriceTerminal(uint128 virtualEthReserve) private pure returns (uint160) {
        return uint160(
            FixedPointMathLib.sqrt(
                FullMath.mulDiv(
                    PledrinConstants.LP_SUPPLY, 1 << 192, 8 * uint256(virtualEthReserve)
                )
            )
        );
    }

    /// @dev `docs/SPEC.md` section 8.2 step 4: the `currency0` the full-range core position
    /// requires at the terminal price, rounded the way `Pool.modifyLiquidity` rounds an
    /// addition. Derived from the specification, not read from `contracts/src`.
    function _coreEth(uint128 virtualEthReserve, int24 tickSpacing) private pure returns (uint256) {
        uint160 terminal = _sqrtPriceTerminal(virtualEthReserve);
        int24 tickLower = TickAlign.up(TickMath.MIN_TICK, tickSpacing);
        int24 tickUpper = TickAlign.down(TickMath.MAX_TICK, tickSpacing);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), terminal, PledrinConstants.LP_SUPPLY
        );
        return SqrtPriceMath.getAmount0Delta(
            terminal, TickMath.getSqrtPriceAtTick(tickUpper), liquidity, true
        );
    }

    /// @dev Launches at a reserve, caps it, graduates it on the canonical key or on an
    /// alternate spacing, and returns the `ethToCore` the log carried.
    function _graduateAndReadEthToCore(uint128 virtualEthReserve, uint24 altSpacing)
        private
        returns (uint256 ethToCore)
    {
        ILaunchFactory.LaunchParams memory params = defaultParams();
        params.virtualEthReserve = virtualEthReserve;
        (BondingCurve curve, IERC20 token) = createLaunch(params);
        buyToCap(curve);

        vm.recordLogs();
        if (altSpacing == 0) {
            vm.prank(GRADUATOR);
            curve.graduate();
        } else {
            vm.warp(curve.capReachedAt() + PledrinConstants.ALT_DELAY);
            vm.prank(GRADUATOR);
            // The canonical fee on an alternate spacing, which is a different key from the
            // canonical one in exactly one field.
            curve.graduateAlt(PledrinConstants.POOL_FEE, altSpacing);
        }

        GraduatedLog memory log = graduatedLog(address(curve));
        ethToCore = log.ethToCore;
        uint256 tokensToCore = log.tokensToCore;
        assertLe(
            PledrinConstants.LP_SUPPLY - tokensToCore,
            PledrinConstants.LP_DUST_MAX,
            "Invariant 39 on the token leg"
        );
        assertEq(
            token.balanceOf(address(curve)),
            PledrinConstants.LP_SUPPLY - tokensToCore,
            "and the curve kept exactly that remainder"
        );
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "Graduated");
    }
}

