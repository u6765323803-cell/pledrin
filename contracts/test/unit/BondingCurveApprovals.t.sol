// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {PledrinTestBase} from "../base/PledrinTestBase.sol";
import {AllowanceWatcher} from "../mocks/CallProbes.sol";

/// @title Invariant 61: every token approval a launch grants, and how long it lives
/// @notice Covers `docs/SPEC.md` section 8.2 step 4 and **Invariant 61**.
/// @dev A launch grants an ERC-20 allowance on its own token exactly twice in its life, and
/// both grants are consumed inside the transaction that makes them: `LP_SUPPLY` to Permit2
/// for the core graduation mint, revoked before the floor mint, and the creator's first-buy
/// allocation to `CreatorVesting`, pulled in full by `createSchedule`.
///
/// What makes this worth its own file is the asymmetry Invariant 61 describes. After
/// graduation the *Permit2 registration* naming PositionManager still exists and still
/// carries the core mint's unspent remainder — section 8.2 step 4 revokes
/// `token.approve(PERMIT2, 0)` and nothing else — so Permit2 would happily move that dust
/// if it could. It cannot, for one reason only: Permit2 spends the owner's ERC-20 allowance
/// too, and that allowance is zero with no code path left that could set it. The protection
/// is the zero allowance, not anything about the registration, and a test that asserted the
/// registration had expired or been cleared would be asserting something false about a
/// property that does not hold and does not need to.
///
/// The second clause — "no code path that sets that allowance other than the core mint" —
/// is a statement about reachability, so it is tested three ways rather than asserted once:
/// the grant is observed from *inside* the mint window and seen to be gone by the next call
/// out of the same function; every external entry point on the curve is called in every
/// state it can be called in, with the allowance asserted after each; and
/// `BondAndLifecycle.invariant.t.sol` asserts the same zero after every call of the
/// handler-driven campaign, which is the form that covers a path nobody thought to list.
/// Adding an `_approve` reachable from an external function, or widening
/// `_approvePositionManager` beyond `_mintCore`, fails those tests rather than quietly
/// falsifying `docs/SECURITY_NOTES.md` and `docs/THREAT_MODEL.md`.
contract BondingCurveApprovalsTest is PledrinTestBase {
    /// @notice **Invariant 61's first clause, on both graduation paths**, together with the
    /// registration that outlives it.
    /// @dev The registration's amount is the core mint's unspent remainder, which is the
    /// same number Invariant 39 bounds and the same number that stays in the curve as dust,
    /// so all three are asserted to be equal rather than asserted separately.
    function test_graduationLeavesNoTokenAllowanceOnEitherPath() public {
        (BondingCurve primary, IERC20 primaryToken) = createLaunchAtCap();
        vm.prank(GRADUATOR);
        primary.graduate();
        _assertGraduationLeftNoAllowance(primary, primaryToken, "graduate");

        (BondingCurve alternate, IERC20 alternateToken) = createLaunchAtCap();
        vm.warp(alternate.capReachedAt() + PledrinConstants.ALT_DELAY);
        vm.prank(GRADUATOR);
        alternate.graduateAlt(100);
        _assertGraduationLeftNoAllowance(alternate, alternateToken, "graduateAlt");
    }

    /// @notice **Invariant 61's second clause at the one site that grants the allowance.**
    /// The approval is live inside the core mint and already revoked by the floor mint, so
    /// the window it exists in is one internal call of one function.
    /// @dev Read from inside `modifyLiquidities` through `MockPositionManager.setProbe`,
    /// because the whole question is what an external callee sees mid-graduation. A
    /// graduation makes two mint calls, so the watcher sees two readings: `LP_SUPPLY` during
    /// the core mint, zero during the floor mint. The second reading is the assertion that
    /// section 8.2 step 4's "revoked before position B is minted" actually happened, which
    /// is what makes the floor position's funding in `currency0` alone structural.
    function test_theApprovalExistsOnlyInsideTheCoreMintWindow() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        assertEq(token.allowance(address(curve), address(permit2)), 0, "nothing before the mint");

        AllowanceWatcher watcher = new AllowanceWatcher();
        positionManager.setProbe(
            address(watcher),
            abi.encodeCall(AllowanceWatcher.record, (token, address(curve), address(permit2)))
        );

        vm.prank(GRADUATOR);
        curve.graduate();
        positionManager.setProbe(address(0), "");

        assertEq(watcher.count(), 2, "both mints were observed from the inside");
        assertEq(watcher.reading(0), PledrinConstants.LP_SUPPLY, "live during the core mint");
        assertEq(watcher.reading(1), 0, "already revoked before the floor mint");
        assertEq(
            token.allowance(address(curve), address(permit2)),
            0,
            "Invariant 61: and zero the moment graduate() returns"
        );

        // The window runs at most once per launch, because the function that opens it
        // cannot run twice (Invariant 36).
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Graduated)
        );
        vm.prank(GRADUATOR);
        curve.graduate();
        // And through the alternate entry point, which needs no warp to reach the state
        // check: `graduateAlt` checks the state before the alternate delay, so a graduated
        // launch answers `WrongState` at any point on the clock. The ordering itself is
        // pinned in `test/unit/BondingCurveGraduationGuards.t.sol`; what matters here is
        // only that the call is refused and grants nothing.
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Graduated)
        );
        curve.graduateAlt(100);
        assertEq(
            token.allowance(address(curve), address(permit2)), 0, "and the refusals grant nothing"
        );
    }

    /// @notice **Invariant 61's second clause as a statement about the external surface.**
    /// Every externally reachable function on a launch, called in every state it can be
    /// called in, leaves no allowance behind — whether the call succeeds or reverts.
    /// @dev The sweep is mechanical on purpose: it calls the whole surface by selector
    /// rather than the subset a reader would think to check, with and without value so a
    /// `payable` function is exercised for real and a non-`payable` one is not merely
    /// rejected on the value. A state-changing call inside a sweep is allowed to change the
    /// state — `graduate()` during the `Graduating` sweep succeeds — because the property is
    /// asserted after every call regardless of what the call did.
    function test_noExternalCallEverLeavesATokenAllowanceOutstanding() public {
        vm.deal(address(this), 100 ether);

        // Live, including the two successful trades and a donation.
        (BondingCurve live, IERC20 liveToken) = createPledgedLaunch();
        _assertNoAllowance(live, liveToken, "after createLaunch");
        uint256 bought = buy(live, TRADER, 1 ether);
        _assertNoAllowance(live, liveToken, "after a buy");
        sell(live, TRADER, bought / 2);
        _assertNoAllowance(live, liveToken, "after a sell");
        vm.prank(OTHER);
        live.donate{value: 1 ether}();
        _assertNoAllowance(live, liveToken, "after a donation");
        _sweepTheSurface(live, liveToken, "Live");

        // Graduating, then Graduated: the sweep's own `graduate()` performs the transition.
        (BondingCurve graduating, IERC20 graduatingToken) = createLaunchAtCap();
        _assertNoAllowance(graduating, graduatingToken, "at the cap");
        _sweepTheSurface(graduating, graduatingToken, "Graduating");
        assertEq(
            uint8(graduating.state()),
            uint8(IBondingCurve.State.Graduated),
            "the sweep graduated it, which is the state worth sweeping next"
        );
        _sweepTheSurface(graduating, graduatingToken, "Graduated");

        // Expired.
        (BondingCurve expired, IERC20 expiredToken) = createPledgedLaunch();
        buy(expired, TRADER, 1 ether);
        vm.warp(expired.gradDeadline());
        expired.expire();
        _assertNoAllowance(expired, expiredToken, "after expiry");
        _sweepTheSurface(expired, expiredToken, "Expired");

        // Stalled.
        (BondingCurve stalled, IERC20 stalledToken) = createLaunchAtCap();
        vm.warp(stalled.capReachedAt() + PledrinConstants.GRAD_GRACE);
        stalled.abortGraduation();
        _assertNoAllowance(stalled, stalledToken, "after abortGraduation");
        _sweepTheSurface(stalled, stalledToken, "Stalled");
    }

    /// @notice The other `_approve` call site: the creator's first-buy allocation is
    /// approved to `CreatorVesting` and pulled in full by `createSchedule`, so that
    /// allowance does not outlive `createLaunch` either.
    /// @dev Asserted because the enumeration Invariant 61's second clause rests on has two
    /// members, not one, and the one that is not the core mint should also be visibly
    /// consumed rather than left standing on a contract that could pull more later.
    function test_theCreatorVestingApprovalIsConsumedExactlyByTheSchedule() public {
        (BondingCurve curve, IERC20 token) = createPledgedLaunch();

        uint256 allocation = vesting.scheduleOf(address(curve)).allocation;
        assertGt(allocation, 0, "the pledged launch made a first buy");
        assertEq(token.balanceOf(address(vesting)), allocation, "the schedule holds it");
        assertEq(
            token.allowance(address(curve), address(vesting)),
            0,
            "createSchedule pulled exactly what was approved"
        );
        assertEq(token.allowance(address(curve), address(permit2)), 0, "and Permit2 has nothing");
    }

    // ------------------------------------------------------------------

    function _assertGraduationLeftNoAllowance(BondingCurve curve, IERC20 token, string memory path)
        private
        view
    {
        assertEq(
            uint8(curve.state()), uint8(IBondingCurve.State.Graduated), string.concat(path, ": ok")
        );
        assertEq(
            token.allowance(address(curve), address(permit2)),
            0,
            string.concat("Invariant 61 after ", path)
        );

        // The registration survives, carrying the unspent remainder, and is harmless only
        // because of the zero above. Its expiration is the maximum `uint48`: asserting that
        // it had passed would be asserting the wrong protection.
        (uint160 registered, uint48 expiration,) =
            permit2.allowance(address(curve), address(token), address(positionManager));
        uint256 dust = token.balanceOf(address(curve));
        assertEq(registered, dust, "the registration carries the core mint's remainder");
        assertEq(
            dust,
            PledrinConstants.LP_SUPPLY - _coreTokensFrom(curve, token),
            "which is LP_SUPPLY minus what the mint consumed"
        );
        assertLe(dust, PledrinConstants.LP_DUST_MAX, "Invariant 39 bounds it");
        assertGt(registered, 0, "and it is not zero, so the ERC-20 leg is what stops a pull");
        assertEq(expiration, type(uint48).max, "the registration never expires");
        assertGt(expiration, vm.getBlockTimestamp(), "so the expiry protects nothing");
    }

    /// @dev `LP_SUPPLY` minus the dust, read back from the token rather than from the event,
    /// so the two numbers in the assertion above come from different places.
    function _coreTokensFrom(BondingCurve curve, IERC20 token) private view returns (uint256) {
        return PledrinConstants.LP_SUPPLY - token.balanceOf(address(curve));
    }

    function _assertNoAllowance(BondingCurve curve, IERC20 token, string memory label)
        private
        view
    {
        assertEq(
            token.allowance(address(curve), address(permit2)),
            0,
            string.concat("Invariant 61: Permit2 allowance ", label)
        );
        assertEq(
            token.allowance(address(curve), address(vesting)),
            0,
            string.concat("no vesting allowance ", label)
        );
        assertEq(
            token.allowance(address(curve), address(positionManager)),
            0,
            string.concat("no direct PositionManager allowance ", label)
        );
    }

    /// @dev Calls every external function on the curve twice — once with no value, once with
    /// one ether — and asserts the property after each of the twenty-eight calls.
    function _sweepTheSurface(BondingCurve curve, IERC20 token, string memory state) private {
        bytes[] memory surface = new bytes[](14);
        surface[0] = abi.encodeCall(IBondingCurve.buy, (0, type(uint256).max));
        surface[1] = abi.encodeCall(IBondingCurve.creatorFirstBuy, (0, 2_592_000));
        surface[2] = abi.encodeCall(IBondingCurve.sell, (1e18, 0, type(uint256).max));
        surface[3] = abi.encodeCall(IBondingCurve.donate, ());
        surface[4] = abi.encodeCall(IBondingCurve.claimCreatorFees, ());
        surface[5] = abi.encodeCall(IBondingCurve.claimProtocolFees, ());
        surface[6] = abi.encodeCall(IBondingCurve.claimBond, ());
        surface[7] = abi.encodeCall(IBondingCurve.claimBounty, (GRADUATOR));
        surface[8] = abi.encodeCall(IBondingCurve.abortGraduation, ());
        surface[9] = abi.encodeCall(IBondingCurve.expire, ());
        surface[10] = abi.encodeCall(IBondingCurve.graduateAlt, (100));
        surface[11] = abi.encodeCall(IBondingCurve.graduate, ());
        surface[12] = abi.encodeWithSignature("unlockCallback(bytes)", bytes(""));
        // A plain ETH send, which is the only thing `receive()` can be reached by.
        surface[13] = "";

        uint256 accepted;
        for (uint256 pass = 0; pass < 2; pass++) {
            uint256 value = pass == 0 ? 0 : 1 ether;
            for (uint256 i = 0; i < surface.length; i++) {
                (bool ok,) = address(curve).call{value: value}(surface[i]);
                if (ok) accepted++;
                _assertNoAllowance(curve, token, string.concat(state, ": swept call"));
            }
        }

        // A sweep in which the launch refused everything would assert nothing about what a
        // successful call leaves behind, so the number accepted is asserted too.
        assertGt(accepted, 0, string.concat(state, ": every swept call was refused"));
    }
}
