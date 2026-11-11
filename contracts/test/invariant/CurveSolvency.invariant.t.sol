// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {InvariantBase} from "./InvariantBase.sol";

/// @title Curve solvency, as an invariant
/// @notice **Invariants 1 and 2, the first two of the four the specification marks
/// mandatory** — the four are 1, 2, 14 and 25, and `FeeSplit.invariant.t.sol` covers 14
/// while `BondAndLifecycle.invariant.t.sol` covers 25 — plus Invariants 3, 5, 6 and 13,
/// asserted after every call of a random interleaving of buys, sells, donations,
/// graduations, stalls, expiries, claims and the passage of time.
/// @dev Invariant 2 is asserted in its strongest form: the gross for `dT == tokensSold` —
/// one seller selling every token the curve ever sold — must be payable out of
/// `ethReserve`, and so must the gross for the interior sizes a real seller would pick.
///
/// Both are asserted for every state except `Graduated`, and that exclusion is a finding
/// rather than a convenience. `docs/SPEC.md` states Invariant 1 "for every launch in every
/// state", but `graduate` deposits the whole reserve into the two locked positions and
/// sets `ethReserve` to zero (section 8.2 step 6, Invariant 43), which leaves the product
/// at `vE0 * (vT0 - CURVE_SUPPLY) == vE0 * vT0 / 9`. The invariant cannot hold there and
/// does not need to: graduation closes both sides of the book in the same transaction, so
/// there is no sell left to be solvent against. The reports note the wording.
contract CurveSolvencyInvariant is InvariantBase {
    /// @notice **Invariant 1.** `(vE0 + ethReserve) * (vT0 - tokensSold)` is at least
    /// `vE0 * vT0` for every launch that still prices trades.
    function invariant_theSolvencyProductNeverFallsBelowK() public view {
        uint256 count = handler.launchCount();
        for (uint256 i = 0; i < count; i++) {
            BondingCurve curve = handler.launchAt(i);
            if (!stillTrades(curve)) continue;
            assertGe(productOf(curve), kOf(curve), "Invariant 1");
        }
    }

    /// @notice **Invariant 2.** The curve can pay for any sell it would accept, including
    /// the largest one anybody could present.
    function invariant_theCurveCanPayForEverySellItWouldAccept() public view {
        uint256 count = handler.launchCount();
        for (uint256 i = 0; i < count; i++) {
            BondingCurve curve = handler.launchAt(i);
            if (!stillTrades(curve)) continue;

            uint256 sold = curve.tokensSold();
            uint256 reserve = curve.ethReserve();
            if (sold == 0) continue;

            (uint256 whole,,) = curve.quoteSell(sold);
            assertLe(whole, reserve, "Invariant 2: everything ever sold, at once");

            (uint256 half,,) = curve.quoteSell(sold / 2);
            assertLe(half, reserve, "Invariant 2: half of it");

            (uint256 one,,) = curve.quoteSell(1);
            assertLe(one, reserve, "Invariant 2: one base unit");
        }
    }

    /// @notice **Invariant 3.** A launch's ETH balance covers every obligation it has:
    /// the reserve, the three fee buckets, the bond still held, and the credited bond and
    /// bounty awaiting a claim.
    function invariant_theBalanceCoversEveryObligation() public view {
        uint256 count = handler.launchCount();
        for (uint256 i = 0; i < count; i++) {
            BondingCurve curve = handler.launchAt(i);
            assertGe(address(curve).balance, obligations(curve), "Invariant 3");
        }
    }

    /// @notice **Invariant 5.** The curve holds exactly the supply it has not sold, for
    /// every launch that has not graduated. After graduation it holds the dust the core
    /// mint could not consume.
    function invariant_theCurveHoldsExactlyTheUnsoldSupply() public view {
        uint256 count = handler.launchCount();
        for (uint256 i = 0; i < count; i++) {
            BondingCurve curve = handler.launchAt(i);
            IERC20 token = curve.token();
            if (curve.state() == IBondingCurve.State.Graduated) {
                assertLe(
                    token.balanceOf(address(curve)),
                    PledrinConstants.LP_DUST_MAX,
                    "Invariant 43: only dust is left after graduation"
                );
                continue;
            }
            assertEq(
                token.balanceOf(address(curve)),
                PledrinConstants.TOTAL_SUPPLY - curve.tokensSold(),
                "Invariant 5"
            );
        }
    }

    /// @notice **Invariant 6.** `tokensSold` never exceeds the sale supply.
    function invariant_tokensSoldNeverExceedsTheCurveSupply() public view {
        uint256 count = handler.launchCount();
        for (uint256 i = 0; i < count; i++) {
            assertLe(handler.launchAt(i).tokensSold(), PledrinConstants.CURVE_SUPPLY, "Invariant 6");
        }
    }

    /// @notice **Invariant 13.** A launch sitting at the cap holds at least `R_target`,
    /// which is what makes graduation fundable. Implied by Invariant 1 and asserted
    /// separately because graduation depends on it.
    function invariant_aLaunchAtTheCapHoldsTheTarget() public view {
        uint256 count = handler.launchCount();
        for (uint256 i = 0; i < count; i++) {
            BondingCurve curve = handler.launchAt(i);
            if (!stillTrades(curve)) continue;
            if (curve.tokensSold() != PledrinConstants.CURVE_SUPPLY) continue;
            assertGe(curve.ethReserve(), curve.ethTarget(), "Invariant 13");
            assertGe(
                curve.ethReserve(),
                PledrinConstants.ETH_TARGET_MULTIPLE * uint256(curve.virtualEthReserve()),
                "Invariant 13 as 8 * vE0"
            );
        }
    }

    /// @notice **Invariant 43.** A graduated launch holds no reserve, and what ETH it does
    /// hold belongs to an unclaimed bucket or is the sub-`MIN_FLOOR_WEI` remainder the
    /// floor mint declined.
    function invariant_aGraduatedLaunchHoldsNoReserve() public view {
        uint256 count = handler.launchCount();
        for (uint256 i = 0; i < count; i++) {
            BondingCurve curve = handler.launchAt(i);
            if (curve.state() != IBondingCurve.State.Graduated) continue;

            assertEq(curve.ethReserve(), 0, "Invariant 43: the reserve is drained");
            assertEq(curve.protectionEth(), 0, "and so is the protection pool");
            assertLe(
                address(curve).balance,
                uint256(curve.creatorFeeEth()) + curve.protocolFeeEth()
                    + curve.pendingBountyTotalWei() + curve.pendingBondWei()
                    + PledrinConstants.MIN_FLOOR_WEI,
                "Invariant 43's bound on what is left behind"
            );
        }
    }

    /// @notice Reports what the run actually did.
    /// @dev Logging only. A run's activity cannot be asserted here: under Foundry 1.9.0 a
    /// reverting `afterInvariant` is replayed against a clean state, so the counters it
    /// would report in the failure are all zero and the message would be a lie. The
    /// guarantee that the handler is not inert is `test_theHandlerPerformsRealWork` below,
    /// which drives the same handler deterministically.
    function afterInvariant() public view {
        logHandlerActivity();
    }

    /// @notice The handler is capable of every action the invariant run depends on. Without
    /// this, a green invariant suite could be a suite in which nothing ever succeeded.
    function test_theHandlerPerformsRealWork() public {
        handler.buy(1, 0, 1 ether);
        assertEq(handler.buys(), 1, "a buy went through");

        handler.sell(1, 0, 1e24);
        assertEq(handler.sells(), 1, "a sell went through");

        handler.donate(1, 1, 1 ether);
        assertEq(handler.donations(), 1, "a donation went through");

        handler.buyToCap(1, 2);
        assertEq(handler.buys(), 2, "a clipped buy reached the cap");
        assertEq(
            uint8(handler.launchAt(1).state()),
            uint8(IBondingCurve.State.Graduating),
            "and froze the curve"
        );

        handler.graduate(1, 2);
        assertEq(handler.graduations(), 1, "a graduation went through");

        handler.claimProtocolFees(1, 0);
        assertGt(handler.claims(), 0, "a claim went through");

        handler.buyToCap(2, 3);
        handler.jumpToNextGrace();
        handler.abortGraduation(2, 3);
        assertEq(handler.stalls(), 1, "a stall went through");

        handler.jumpToNextDeadline();
        handler.expire(0, 0);
        assertEq(handler.expiries(), 1, "an expiry went through");

        handler.createLaunch(uint256(keccak256("seed")), 1, 1);
        assertEq(handler.newLaunches(), 1, "a launch was created mid-run");

        handler.advanceTime(1 hours);
        assertGt(handler.timeJumps(), 0, "the clock moved");
    }
}
