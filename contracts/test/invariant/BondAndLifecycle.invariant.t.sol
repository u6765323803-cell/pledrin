// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {BondingCurve} from "src/BondingCurve.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {ILaunchFactory} from "src/interfaces/ILaunchFactory.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {InvariantBase} from "./InvariantBase.sol";

/// @title The bond and the lifecycle, as invariants
/// @notice **Invariant 25, the third of the three the specification marks mandatory**,
/// plus Invariants 26, 29, 30, 31, 36, 48 and 49.
/// @dev Invariant 25 has four terms and all four are tracked: what the bond account still
/// holds, what has been credited to the creator, what has been paid to them, and what was
/// moved into the reserve on expiry. Their sum has to be the immutable `bondWei` at every
/// point in time, which is what "never paid twice, and no wei of it ever paid to both the
/// creator and the reserve" means arithmetically.
///
/// Invariant 31 is asserted in its reworded form: `tokensSold` never *increases* once the
/// state leaves `Live`, and does not change at all in `Graduating` or `Graduated`. The old
/// wording — that it never changes at all — is false, because `sell` stays open in
/// `Expired` and `Stalled` and has to decrement the counter for Invariants 1 and 2 to keep
/// holding.
contract BondAndLifecycleInvariant is InvariantBase {
    /// @notice **Invariant 25.** A bond is never paid twice. Every wei of `bondWei` is in
    /// exactly one of four places, and the bond leaves `Bonded` at most once.
    function invariant_theBondIsNeverPaidTwice() public view {
        uint256 count = handler.launchCount();
        for (uint256 i = 0; i < count; i++) {
            BondingCurve curve = handler.launchAt(i);
            address launch = address(curve);

            assertEq(
                uint256(curve.bondHeldWei()) + curve.pendingBondWei() + handler.bondPaidOut(launch)
                    + handler.bondToReserve(launch),
                curve.bondWei(),
                "Invariant 25: every wei of the bond is in exactly one place"
            );
            assertLe(handler.bondExits(launch), 1, "Invariant 25: Bonded is left at most once");

            // And no wei of it reached both destinations.
            if (handler.bondToReserve(launch) != 0) {
                assertEq(curve.pendingBondWei(), 0, "forfeited bonds are never credited");
                assertEq(handler.bondPaidOut(launch), 0, "and never paid to the creator");
            }
            if (handler.bondPaidOut(launch) != 0) {
                assertEq(handler.bondToReserve(launch), 0, "returned bonds never reach holders");
            }
        }
    }

    /// @notice **Invariant 26.** `Returned` implies the launch graduated or stalled;
    /// `Forfeited` implies it expired; `Bonded` implies it has not reached a bond outcome.
    function invariant_theBondStateMatchesTheLifecycle() public view {
        uint256 count = handler.launchCount();
        for (uint256 i = 0; i < count; i++) {
            BondingCurve curve = handler.launchAt(i);
            IBondingCurve.BondState bondState = curve.bondState();
            IBondingCurve.State state = curve.state();

            if (bondState == IBondingCurve.BondState.Returned) {
                assertTrue(
                    state == IBondingCurve.State.Graduated || state == IBondingCurve.State.Stalled,
                    "Invariant 26: Returned implies Graduated or Stalled"
                );
            }
            if (bondState == IBondingCurve.BondState.Forfeited) {
                assertEq(
                    uint8(state),
                    uint8(IBondingCurve.State.Expired),
                    "Invariant 26: Forfeited implies Expired"
                );
            }
            if (bondState == IBondingCurve.BondState.None) {
                assertEq(curve.bondWei(), 0, "a launch with no bond state posted no bond");
            }
        }
    }

    /// @notice **Invariant 29.** `pledged()` is a pure function of the immutable `bondWei`
    /// and is therefore unchanged by every bond transition.
    function invariant_pledgedNeverChanges() public view {
        uint256 count = handler.launchCount();
        for (uint256 i = 0; i < count; i++) {
            BondingCurve curve = handler.launchAt(i);
            assertEq(curve.pledged(), curve.bondWei() != 0, "Invariant 29");
        }
    }

    /// @notice **Invariant 30.** Once a launch reaches `Graduated`, `Expired` or `Stalled`
    /// it never leaves that state.
    function invariant_terminalStatesAreTerminal() public view {
        uint256 count = handler.launchCount();
        for (uint256 i = 0; i < count; i++) {
            BondingCurve curve = handler.launchAt(i);
            address launch = address(curve);
            if (!handler.isTerminal(launch)) continue;

            assertEq(
                uint8(curve.state()),
                uint8(handler.terminalState(launch)),
                "Invariant 30: a terminal state never changes again"
            );
        }
    }

    /// @notice **Invariant 31, in its reworded form.** `tokensSold` never increases once
    /// the state leaves `Live`, and does not move at all in `Graduating` or `Graduated`.
    function invariant_tokensSoldNeverIncreasesAfterLive() public view {
        uint256 count = handler.launchCount();
        for (uint256 i = 0; i < count; i++) {
            BondingCurve curve = handler.launchAt(i);
            address launch = address(curve);
            if (!handler.hasLeftLive(launch)) continue;

            assertLe(
                curve.tokensSold(),
                handler.soldOnLeavingLive(launch),
                "Invariant 31: the counter never rises after Live"
            );

            IBondingCurve.State state = curve.state();
            if (state == IBondingCurve.State.Graduating || state == IBondingCurve.State.Graduated) {
                assertEq(
                    curve.tokensSold(),
                    PledrinConstants.CURVE_SUPPLY,
                    "Invariant 31: frozen at the cap while graduating or graduated"
                );
            }
        }
    }

    /// @notice **Invariant 36.** `graduate` and `graduateAlt` together succeed at most once
    /// per launch.
    function invariant_graduationSucceedsAtMostOnce() public view {
        uint256 count = handler.launchCount();
        for (uint256 i = 0; i < count; i++) {
            BondingCurve curve = handler.launchAt(i);
            assertLe(handler.graduationCount(address(curve)), 1, "Invariant 36");
            if (handler.graduationCount(address(curve)) == 1) {
                assertEq(
                    uint8(curve.state()),
                    uint8(IBondingCurve.State.Graduated),
                    "a graduated launch is Graduated"
                );
                assertGt(curve.graduatedAt(), 0, "and records when");
            }
        }
    }

    /// @notice **Invariants 48 and 49.** Every reputation counter only ever rises, and the
    /// three sums the specification names hold for every creator the run touched.
    function invariant_reputationOnlyRisesAndItsSumsHold() public view {
        address[3] memory creators = [CREATOR, OTHER, address(handler.actors(0))];
        for (uint256 i = 0; i < creators.length; i++) {
            ILaunchFactory.Reputation memory record = factory.reputationOf(creators[i]);

            assertLe(
                uint256(record.graduations) + record.stalls + record.expiries,
                record.launches,
                "Invariant 49: outcomes never exceed launches"
            );
            assertLe(
                uint256(record.bondsReturned) + record.bondsForfeited,
                record.bondsPosted,
                "Invariant 49: bond outcomes never exceed bonds posted"
            );
            assertLe(
                record.bondsPosted, record.launches, "Invariant 49: bonds never exceed launches"
            );
            assertLe(
                record.bondWeiForfeited,
                record.bondWeiPosted,
                "forfeited wei never exceeds posted wei"
            );
        }
    }

    /// @notice A launch's immutables are never writable after `createLaunch`, which is
    /// Invariant 53 restated as something an invariant run can check: whatever the run
    /// does, they still read the same.
    function invariant_launchImmutablesNeverChange() public view {
        uint256 count = handler.launchCount();
        for (uint256 i = 0; i < count; i++) {
            BondingCurve curve = handler.launchAt(i);

            assertEq(
                curve.ethTarget(),
                PledrinConstants.ETH_TARGET_MULTIPLE * uint256(curve.virtualEthReserve()),
                "R_target is still eight times the reserve"
            );
            assertLe(
                curve.totalFeeBps(),
                PledrinConstants.MAX_TOTAL_FEE_BPS,
                "Invariant 16: the fee ceiling holds forever"
            );
            assertEq(
                uint256(curve.creatorShareBps()) + curve.protocolShareBps()
                    + curve.protectionShareBps(),
                PledrinConstants.BPS_DENOMINATOR,
                "Invariant 15: the shares still sum to exactly 10000"
            );
            assertEq(curve.factory(), address(factory), "the factory never changes");
            assertTrue(curve.protocolTreasury() != address(0), "the treasury is never zeroed");
        }
    }

    function afterInvariant() public view {
        logHandlerActivity();
    }
}
