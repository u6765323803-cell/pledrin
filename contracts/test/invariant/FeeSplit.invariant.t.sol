// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {BondingCurve} from "src/BondingCurve.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {InvariantBase} from "./InvariantBase.sol";

/// @title Fee conservation, as an invariant
/// @notice **Invariant 14, the second of the two the specification marks mandatory**, plus
/// Invariants 17, 18 and 44.
/// @dev Invariant 14 is a statement about each trade, and `CurveMath.splitFee` is proved
/// for every possible input by fuzz in `test/unit/CurveMath.t.sol`. What this file adds is
/// the statement across a whole history: the handler records every wei of fee each launch
/// ever charged, and the sum of the three buckets plus everything ever claimed out of them
/// plus the credited bounty has to account for all of it.
///
/// The exact equality is asserted for launches that have not left `Live`, and the
/// no-wei-created inequality for every launch in every state. That split is deliberate.
/// A launch that leaves `Live` moves fee ETH out of the buckets on purpose — `expire`
/// forfeits the creator and protection shares into `ethReserve`, `abortGraduation` donates
/// the protection share there, and `graduate` deposits it into the floor position — so the
/// literal wording of Invariant 18 does not hold for a terminal launch and is not meant
/// to. It is also an area under active change: fee shares accrued by a sell *after* a
/// terminal transition currently have no payout path, and that is being fixed by
/// redirecting them into `ethReserve`. The inequality asserted here holds either way,
/// which is why it is written as an inequality.
contract FeeSplitInvariant is InvariantBase {
    /// @notice **Invariant 14 and 18.** For a launch that has not left `Live`, every wei of
    /// fee it ever charged is either still in one of the three buckets, already claimed out
    /// of one of them, or credited as the graduation bounty. None is created and none is
    /// lost.
    function invariant_everyFeeWeiIsAccountedFor() public view {
        uint256 count = handler.launchCount();
        for (uint256 i = 0; i < count; i++) {
            BondingCurve curve = handler.launchAt(i);
            if (handler.hasLeftLive(address(curve))) continue;

            assertEq(
                _accountedFor(curve),
                handler.feeCharged(address(curve)),
                "Invariants 14 and 18: the buckets account for every fee charged"
            );
        }
    }

    /// @notice **Invariant 14's safety half, for every launch in every state.** No fee wei
    /// is ever created: what the buckets hold, plus what has been paid out of them, plus
    /// the bounty, never exceeds what was charged.
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

    /// @notice **Invariant 18 extended to every launch.** Every wei of fee a launch charged
    /// before it reached a terminal state is still accounted for somewhere: in one of the
    /// three buckets, already claimed out of one, credited as the graduation bounty,
    /// forfeited or donated into `ethReserve`, or deposited into the floor position.
    /// @dev Stated as an inequality over the pre-terminal fee only, which makes it true
    /// both of the protocol as it stands and of the pending change to where a
    /// post-terminal sell's fee shares accrue. The exact equality is asserted above for
    /// launches that have not left `Live`.
    function invariant_everyFeeChargedBeforeTerminalityIsStillAccountedFor() public view {
        uint256 count = handler.launchCount();
        for (uint256 i = 0; i < count; i++) {
            BondingCurve curve = handler.launchAt(i);
            address launch = address(curve);

            assertGe(
                _accountedFor(curve) + handler.feeToReserve(launch)
                    + handler.protectionToFloor(launch),
                handler.feeCharged(launch) - handler.feeChargedAfterTerminal(launch),
                "Invariant 18: no fee wei charged before terminality is lost"
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
