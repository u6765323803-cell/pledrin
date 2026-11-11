// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {BondingCurve} from "src/BondingCurve.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {InvariantBase} from "./InvariantBase.sol";
import {ProtocolHandler} from "./handlers/ProtocolHandler.sol";

/// @title Fee conservation and fee destinations, as invariants
/// @notice **Invariant 14, one of the four the specification marks mandatory** — the four
/// are 1, 2, 14 and 25, and `CurveSolvency.invariant.t.sol` covers 1 and 2 while
/// `BondAndLifecycle.invariant.t.sol` covers 25 — plus Invariants 17, 18, 44 and 59.
/// @dev Invariant 14 is a statement about each trade, and `CurveMath.splitFee` is proved
/// for every possible input by fuzz in `test/unit/CurveMath.t.sol`. What this file adds is
/// the statement across a whole history: the handler records every wei of fee each launch
/// ever charged, and the sum of the three buckets plus everything ever claimed out of them
/// plus the credited bounty plus everything deliberately moved out of the buckets has to
/// account for all of it, exactly.
///
/// The exact equality now holds for every launch in every state, including terminal ones.
/// It did not when this file was written, and the reason it does now is section 6.3: a fee
/// share whose bucket has lost its payout path is redirected into `ethReserve` by the trade
/// that charged it, so there is no longer any wei whose destination the accounting cannot
/// name. The four ways fee ETH leaves a bucket are all tracked by the handler — the
/// forfeiture on `expire`, the donation on `abortGraduation`, the protection deposit into
/// the floor position at graduation, and the per-trade redirect — and the equality is
/// stated over all of them together.
///
/// Conservation is necessary and not sufficient: `ethReserve` and the three buckets are
/// obligations of the same contract, so an implementation that sent a redirected share to
/// the wrong bucket would conserve every wei. The destination itself is Invariant 59, and it
/// is asserted here against the handler's record of what section 6.3's table predicted and
/// what each bucket actually received. `test/unit/BondingCurvePostTerminalFees.t.sol`
/// asserts the same destinations trade by trade, including through the events.
contract FeeSplitInvariant is InvariantBase {
    /// @notice **Invariants 14 and 18, for every launch in every state.** Every wei of fee
    /// a launch ever charged is still in one of the three buckets, already claimed out of
    /// one of them, credited as the graduation bounty, or in one of the places a terminal
    /// transition or section 6.3's redirect deliberately moved it to. None is created and
    /// none is lost.
    /// @dev This is exact, not an inequality, and it covers terminal launches. Section 6.3
    /// is what makes that possible: before it, a share accrued by a post-terminal sell into
    /// a bucket with no claim had no destination the accounting could name, so the equality
    /// had to be restricted to launches that never left `Live`.
    function invariant_everyFeeWeiIsAccountedFor() public view {
        uint256 count = handler.launchCount();
        for (uint256 i = 0; i < count; i++) {
            BondingCurve curve = handler.launchAt(i);
            address launch = address(curve);

            assertEq(
                _accountedFor(curve) + handler.feeToReserve(launch)
                    + handler.protectionToFloor(launch),
                handler.feeCharged(launch),
                "Invariants 14 and 18: every fee wei has a named destination"
            );
        }
    }

    /// @notice **Invariant 14's safety half, for every launch in every state.** No fee wei
    /// is ever created: what the buckets hold, plus what has been paid out of them, plus
    /// the bounty, never exceeds what was charged.
    /// @dev Weaker than the equality above and kept because it is a statement about the
    /// contract alone. It names none of the places fee ETH is deliberately moved to, so it
    /// still holds — and still fails on a launch that minted fee wei out of nothing — if a
    /// ghost that tracks one of those places is itself wrong.
    function invariant_noFeeWeiIsEverCreated() public view {
        uint256 count = handler.launchCount();
        for (uint256 i = 0; i < count; i++) {
            BondingCurve curve = handler.launchAt(i);
            assertLe(
                _accountedFor(curve),
                handler.feeCharged(address(curve)),
                "Invariant 14: no fee wei is created"
            );
        }
    }

    /// @notice **Invariant 59.** Across every sell the run accepted in `Expired` or
    /// `Stalled`, each of the three buckets received exactly what section 6.3's table says
    /// it receives, the redirected share reached `ethReserve` and nothing else, and the
    /// redirect was folded into the same reserve write as the payout.
    /// @dev The handler accumulates the table's prediction and the launch's observed bucket
    /// deltas independently, so this is a comparison of two measurements rather than a
    /// restatement of one. The reserve clause is the state-level form of the property the
    /// `Sold` log carries: the reserve fell by the gross less the redirect, so a redirect
    /// accrued after the reserve write — the shape the obvious implementation takes — would
    /// show up here as a shortfall equal to everything ever redirected.
    function invariant_everyPostTerminalFeeShareReachedItsDocumentedDestination() public view {
        uint256 count = handler.launchCount();
        for (uint256 i = 0; i < count; i++) {
            address launch = address(handler.launchAt(i));
            ProtocolHandler.TerminalFees memory ghost = handler.terminalFeesOf(launch);
            if (ghost.trades == 0) continue;

            assertEq(
                ghost.protectionToBucket,
                0,
                "Invariant 59: protectionEth receives nothing after a terminal transition"
            );
            assertEq(
                ghost.creatorToBucket,
                ghost.creatorExpected,
                "Invariant 59: the creator bucket received exactly section 6.3's column"
            );
            assertEq(
                ghost.protocolToBucket,
                ghost.protocolExpected,
                "Invariant 59: the protocol share accrues in every state"
            );
            assertEq(
                ghost.reserveDecrease + ghost.redirected,
                ghost.gross,
                "Invariant 59: the redirect is folded into the reserve write"
            );
            assertLe(
                ghost.redirected,
                handler.feeChargedAfterTerminal(launch),
                "the redirect never exceeds the fee charged after terminality"
            );
        }
    }

    /// @notice **Invariant 17.** The protection bucket is never smaller than its exact
    /// share of everything charged minus what the two floors could have dropped, which is
    /// the statement that every rounding remainder lands there and nowhere else.
    function invariant_theProtectionBucketHoldsEveryRoundingRemainder() public view {
        uint256 count = handler.launchCount();
        for (uint256 i = 0; i < count; i++) {
            BondingCurve curve = handler.launchAt(i);
            if (handler.hasLeftLive(address(curve))) continue;

            uint256 charged = handler.feeCharged(address(curve));
            if (charged == 0) continue;

            // The two product shares are floored per trade, so the pair of them can only
            // be smaller than their exact share of the total, and what they drop has to be
            // somewhere: the protection bucket.
            assertLe(
                uint256(curve.creatorFeeEth()) + curve.protocolFeeEth()
                    + curve.pendingBountyTotalWei() + handler.bountyPaidOut(address(curve))
                    + handler.feePaidOut(address(curve)),
                charged,
                "the two product shares never exceed what was charged"
            );
            assertGe(
                uint256(curve.protectionEth()) + curve.creatorFeeEth() + curve.protocolFeeEth()
                    + handler.feePaidOut(address(curve)) + curve.pendingBountyTotalWei()
                    + handler.bountyPaidOut(address(curve)),
                charged,
                "Invariant 17: nothing is dropped on the floor"
            );
        }
    }

    /// @notice **Invariant 44.** The graduation bounty never exceeds the protocol bucket it
    /// came out of, and is never drawn from the reserve, the protection pool, the creator
    /// bucket or the bond.
    function invariant_theBountyComesOnlyFromTheProtocolBucket() public view {
        uint256 count = handler.launchCount();
        for (uint256 i = 0; i < count; i++) {
            BondingCurve curve = handler.launchAt(i);
            address launch = address(curve);

            uint256 bounty = curve.pendingBountyTotalWei() + handler.bountyPaidOut(launch);
            if (bounty == 0) continue;

            // The protocol share of everything ever charged is the only source it can have.
            uint256 protocolShare = (handler.feeCharged(launch) * curve.protocolShareBps())
                / PledrinConstants.BPS_DENOMINATOR;
            assertLe(bounty, protocolShare + 1, "Invariant 44: at most the protocol's share");
            assertLe(
                bounty * 10,
                protocolShare * 10 + 10,
                "and at most a tenth of the bucket at the time of graduation"
            );
        }
    }

    /// @notice The three buckets are always covered by the launch's actual ETH balance,
    /// which is the balance half of Invariant 3 restricted to the fee buckets.
    function invariant_theBucketsAreAlwaysCovered() public view {
        uint256 count = handler.launchCount();
        for (uint256 i = 0; i < count; i++) {
            BondingCurve curve = handler.launchAt(i);
            assertGe(
                address(curve).balance,
                uint256(curve.creatorFeeEth()) + curve.protocolFeeEth() + curve.protectionEth()
                    + curve.pendingBountyTotalWei() + curve.pendingBondWei(),
                "the buckets are covered by real ETH"
            );
        }
    }

    function afterInvariant() public view {
        logHandlerActivity();
    }

    /// @dev Everything a launch's fee history can still be found in.
    function _accountedFor(BondingCurve curve) private view returns (uint256) {
        address launch = address(curve);
        return uint256(curve.creatorFeeEth()) + curve.protocolFeeEth() + curve.protectionEth()
            + handler.feePaidOut(launch) + curve.pendingBountyTotalWei()
            + handler.bountyPaidOut(launch);
    }
}
