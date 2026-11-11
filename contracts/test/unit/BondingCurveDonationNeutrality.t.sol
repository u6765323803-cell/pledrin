// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {stdError} from "forge-std/StdError.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {ILiquidityLock} from "src/interfaces/ILiquidityLock.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {PledrinTestBase} from "../base/PledrinTestBase.sol";
import {TokenPusher} from "../mocks/CallProbes.sol";
import {MockPermit2} from "../mocks/MockPermit2.sol";

/// @title Invariant 60: a token donation cannot touch the graduation mint
/// @notice Covers `docs/SPEC.md` section 8.2 step 4, **Invariant 60**, and
/// `docs/THREAT_MODEL.md` section 6.6.
/// @dev Any address may transfer launch tokens to the curve at any time and ERC-20 gives
/// the curve no way to refuse. `_mintCore` is written so that this cannot matter: the token
/// and the ETH the mint consumed are each a difference between a reading taken before
/// `modifyLiquidities` and a reading taken after it, and the dust comparison is `LP_SUPPLY`
/// minus that token delta. A donation raises both readings by the same amount and cancels.
///
/// **Why this is a differential test and not an assertion about one graduation.** The risk
/// is not a bug that exists today. It is that the two balance readings look like needless
/// indirection next to one `token.balanceOf(address(this))` after the call, and that the
/// tidier version reads as the same assertion. It is not: the curve's post-mint balance is
/// the dust *plus every token anybody ever sent it*, so the tidied check would let any
/// holder push the remainder past `LP_DUST_MAX` with a transfer, revert `graduate()` on
/// demand for the price of tokens they already hold, keep doing it until `GRAD_GRACE`
/// expired, and leave `abortGraduation` to strand a launch that had already reached its cap
/// in `Stalled` with no Uniswap pool at all. A test that merely graduates with a donation
/// in place and passes would also pass against that version, so it would guard nothing.
/// Every test here graduates twice from the same state — once with `D = 0`, then back to
/// that state and again with `D` donated — and compares the two outcomes field by field.
/// The assertion that does the guarding is the last one in `_assertOutcomesMatch`: with
/// `D > LP_DUST_MAX` the curve's post-mint balance exceeds `LP_DUST_MAX`, which is the
/// number the tidied check would have compared and reverted on.
contract BondingCurveDonationNeutralityTest is PledrinTestBase {
    /// @dev Everything Invariant 60 names, plus the two things that would move with it.
    struct Outcome {
        bool success;
        bytes returnData;
        uint256 corePositionId;
        uint256 floorPositionId;
        uint256 ethToCore;
        uint256 ethToFloor;
        uint256 tokensToCore;
        uint256 coreLiquidity;
        uint256 dust;
        uint256 curveTokenBalance;
    }

    // ------------------------------------------------------------------
    // The differential, over the whole donatable range
    // ------------------------------------------------------------------

    /// @notice **Invariant 60 by fuzz.** For any `D` an ordinary holder can send, the
    /// graduation is bit-for-bit the graduation that would have happened with `D = 0`.
    /// @dev `D` is drawn from the whole balance the capped launch's buyer holds, which is
    /// `CURVE_SUPPLY`: nine hundred million whole tokens, so almost every draw is many
    /// orders of magnitude above `LP_DUST_MAX = 10**5`. The donor is `TRADER`, an ordinary
    /// holder with no relationship to the launch beyond having bought from it, and the
    /// transfer is a plain `IERC20.transfer` — no cooperation from the protocol.
    function testFuzz_aDonationOfAnySizeChangesNothingAboutTheGraduation(uint256 donationSeed)
        public
    {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        uint256 donation = bound(donationSeed, 1, token.balanceOf(TRADER));

        _assertDonationIsNeutral(curve, token, donation, false);
    }

    /// @notice The boundary values the fuzz will not reach on its own: one base unit, the
    /// dust ceiling itself, one base unit over it, and the donor's whole balance.
    function test_aDonationAtEveryBoundaryChangesNothing() public {
        uint256[5] memory donations = [
            uint256(1),
            PledrinConstants.LP_DUST_MAX,
            PledrinConstants.LP_DUST_MAX + 1,
            1e18,
            PledrinConstants.CURVE_SUPPLY
        ];

        for (uint256 i = 0; i < donations.length; i++) {
            (BondingCurve curve, IERC20 token) = createLaunchAtCap();
            _assertDonationIsNeutral(curve, token, donations[i], false);
        }
    }

    /// @notice The alternate key is the same procedure on a caller-chosen spacing, and a
    /// donation is just as inert there.
    /// @dev The clock is moved past `ALT_DELAY` before the snapshot is taken, so both
    /// graduations run at the same timestamp and the only difference between them is `D`.
    function test_aDonationChangesNothingAboutAnAlternateKeyGraduation() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        vm.warp(curve.capReachedAt() + PledrinConstants.ALT_DELAY);

        _assertDonationIsNeutral(curve, token, 50_000_000e18, true);
    }

    /// @notice **Invariant 60's failure half.** A graduation that reverts reverts in exactly
    /// the same way with a donation in place, and still reverts for the same reason.
    /// @dev The griefed primary key of section 8.4: a pool with liquidity at the wrong
    /// price makes the restoring swap cost something, and `graduate` refuses rather than
    /// spending curve ETH. If a donation could change a revert into a different revert — or
    /// into a success — the launch's fate would depend on a third party's transfer, which is
    /// the whole thing Invariant 60 denies.
    function test_aDonationChangesNeitherTheRevertNorItsReason() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        poolManager.pokeSlot0(curve.poolId(), 1 << 96, 100_000);
        poolManager.setSwapDelta(-1, 0);

        uint256 snapshot = vm.snapshotState();
        Outcome memory baseline = _graduate(curve, token, false);
        assertFalse(baseline.success, "the griefed key refuses this graduation");

        assertTrue(vm.revertToState(snapshot), "the baseline state was restored");
        vm.prank(TRADER);
        token.transfer(address(curve), 10 * PledrinConstants.LP_DUST_MAX);

        Outcome memory donated = _graduate(curve, token, false);
        assertFalse(donated.success, "and refuses it with the donation in place");
        assertEq(
            donated.returnData, baseline.returnData, "Invariant 60: the same revert, byte for byte"
        );
        assertEq(
            donated.returnData,
            abi.encodeWithSelector(IBondingCurve.SwapNotFree.selector, -1, 0),
            "and it is still the swap's own refusal"
        );
        assertEq(
            uint8(curve.state()),
            uint8(IBondingCurve.State.Graduating),
            "the launch is still retryable"
        );
    }

    // ------------------------------------------------------------------
    // The donated tokens, afterwards
    // ------------------------------------------------------------------

    /// @notice **Invariant 60's second clause.** The donation stays in the curve, and after
    /// graduation nothing can move it: the curve has no token-moving surface left, and the
    /// one approval it ever granted was revoked inside the mint.
    function test_theDonatedTokensStayInTheCurveWithNoPathOut() public {
        (BondingCurve curve, IERC20 token) = createPledgedLaunch();
        buyToCap(curve);

        uint256 donation = 123_456_789e18;
        vm.prank(TRADER);
        token.transfer(address(curve), donation);

        vm.prank(GRADUATOR);
        curve.graduate();

        uint256 stranded = token.balanceOf(address(curve));
        assertEq(stranded, donation + 1088, "the donation plus the measured core-mint dust");

        // The approval path of section 8.2 step 4 is closed where the spec closes it: the
        // ERC-20 leg, which both legs are needed for. The Permit2 registration still
        // carries the part of `LP_SUPPLY` the mint did not spend — the spec revokes
        // `token.approve(PERMIT2, 0)` and nothing else — and that registration is inert,
        // because Permit2 moves the token with the curve's ERC-20 allowance and the curve
        // has no code path that could ever grant one again.
        assertEq(token.allowance(address(curve), address(permit2)), 0, "the ERC-20 leg");
        (uint160 registered,,) =
            permit2.allowance(address(curve), address(token), address(positionManager));
        assertEq(registered, 1088, "the Permit2 leg keeps the unspent remainder");
        vm.prank(address(positionManager));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(permit2), 0, 1
            )
        );
        permit2.transferFrom(address(curve), TRADER, 1, address(token));

        // Nothing the curve still answers in `Graduated` moves a token, and the two trade
        // functions are closed outright.
        vm.prank(TRADER);
        token.approve(address(curve), stranded);
        vm.prank(TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Graduated)
        );
        curve.sell(1e18, 0, vm.getBlockTimestamp());
        vm.prank(TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Graduated)
        );
        curve.donate{value: 1}();

        curve.claimCreatorFees();
        curve.claimProtocolFees();
        curve.claimBond();
        curve.claimBounty(GRADUATOR);

        // The lock's one permissionless function reaches the locked position, never the
        // curve: with no fees earned yet it has nothing to reinvest and says so.
        vm.expectRevert(abi.encodeWithSelector(ILiquidityLock.NothingToCompound.selector, 1));
        lock.compound(1);

        assertEq(token.balanceOf(address(curve)), stranded, "Invariant 60: no path out");
    }

    // ------------------------------------------------------------------
    // The two underflow directions, and which of them is reachable
    // ------------------------------------------------------------------

    /// @notice A token balance that *rises* across the mint call would underflow
    /// `tokensBefore - balanceOf(...)`, and the graduation fails closed when it does.
    /// @dev Fault injection, and it has to be: the balance cannot rise inside that window in
    /// the real system. The pool is hookless; the only Pledrin code entered during the mint
    /// is the curve's own `receive()`, which accepts ETH from the PositionManager alone and
    /// moves nothing; and `LiquidityLock.onERC721Received` is `view`
    /// (`test/unit/CodeProperties.t.sol`) and is not called by a mint at all, because v4's
    /// PositionManager mints through solmate's hookless `_mint`. So this uses
    /// `MockPositionManager.setProbe` to have a `TokenPusher` transfer tokens to the curve
    /// from inside `modifyLiquidities`, which is a state the real system cannot produce, and
    /// asserts the outcome is a revert rather than a mismeasured mint. An underflow here
    /// cannot be silent — it is checked arithmetic — and this is the test that says so.
    function test_aTokenBalanceThatRisesInsideTheMintWindowRevertsTheGraduation() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();

        // More than the mint will pull, so the curve's balance is higher after the call
        // than before it.
        TokenPusher pusher = new TokenPusher();
        vm.prank(TRADER);
        token.transfer(address(pusher), 2 * PledrinConstants.LP_SUPPLY);
        positionManager.setProbe(
            address(pusher),
            abi.encodeCall(
                TokenPusher.push, (token, address(curve), 2 * PledrinConstants.LP_SUPPLY)
            )
        );

        vm.prank(GRADUATOR);
        vm.expectRevert(stdError.arithmeticError);
        curve.graduate();

        positionManager.setProbe(address(0), "");
    }

    /// @notice The other direction — `tokensUsed > LP_SUPPLY`, which would underflow
    /// `LP_SUPPLY - tokensUsed` — is unreachable, and the reason is the approval rather than
    /// a check: the curve grants exactly `LP_SUPPLY` on both legs of the Permit2 path and
    /// nothing else can take its token, so the balance cannot fall by more than `LP_SUPPLY`
    /// across the window.
    /// @dev Demonstrated rather than assumed. The probe spends the whole allowance from
    /// inside the mint call, which is the only way anything could take token beyond what
    /// the mint itself takes; the mint's own collection then has no allowance left and the
    /// graduation reverts on the second leg. Fail closed in both orders, so no sequence of
    /// pulls can reach the subtraction with `tokensUsed` above `LP_SUPPLY`.
    function test_theMintCannotTakeMoreTokenThanTheCurveApproved() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();

        positionManager.setProbe(
            address(permit2),
            abi.encodeCall(
                MockPermit2.transferFrom,
                (address(curve), OTHER, uint160(PledrinConstants.LP_SUPPLY), address(token))
            )
        );

        vm.prank(GRADUATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockPermit2.InsufficientAllowance.selector, 0, PledrinConstants.LP_SUPPLY - 1088
            )
        );
        curve.graduate();
        assertEq(
            uint8(curve.state()),
            uint8(IBondingCurve.State.Graduating),
            "the state change was rolled back with the rest"
        );
        positionManager.setProbe(address(0), "");

        // And with no interference the consumption is at most `LP_SUPPLY`, which is the
        // bound that makes the subtraction safe. `LP_SUPPLY` itself is the approval.
        vm.prank(GRADUATOR);
        vm.recordLogs();
        curve.graduate();
        uint256 tokensToCore = graduatedLog(address(curve)).tokensToCore;
        assertLe(tokensToCore, PledrinConstants.LP_SUPPLY, "tokensUsed <= LP_SUPPLY");
        assertGe(
            tokensToCore,
            PledrinConstants.LP_SUPPLY - PledrinConstants.LP_DUST_MAX,
            "and within LP_DUST_MAX of it"
        );
    }

    // ------------------------------------------------------------------
    // The differential harness
    // ------------------------------------------------------------------

    /// @dev Graduates from the current state twice: once untouched, then from the same
    /// state again with `donation` transferred in by an ordinary holder. Memory survives
    /// `revertToState` — only account state is rolled back — so the first outcome is still
    /// readable when the second one is taken.
    function _assertDonationIsNeutral(BondingCurve curve, IERC20 token, uint256 donation, bool alt)
        private
    {
        uint256 snapshot = vm.snapshotState();

        Outcome memory baseline = _graduate(curve, token, alt);
        assertTrue(baseline.success, "the undonated graduation is the baseline");

        assertTrue(vm.revertToState(snapshot), "the baseline state was restored");
        assertEq(
            token.balanceOf(address(curve)),
            PledrinConstants.LP_SUPPLY,
            "back at the cap, holding exactly the LP allocation"
        );

        vm.prank(TRADER);
        token.transfer(address(curve), donation);
        assertEq(
            token.balanceOf(address(curve)),
            PledrinConstants.LP_SUPPLY + donation,
            "the donation landed and the curve could not refuse it"
        );

        Outcome memory donated = _graduate(curve, token, alt);
        _assertOutcomesMatch(baseline, donated, donation);
    }

    function _graduate(BondingCurve curve, IERC20 token, bool alt)
        private
        returns (Outcome memory out)
    {
        vm.recordLogs();
        vm.prank(GRADUATOR);
        (out.success, out.returnData) = address(curve)
            .call(
                alt
                    ? abi.encodeCall(IBondingCurve.graduateAlt, (PledrinConstants.POOL_FEE, 100))
                    : abi.encodeCall(IBondingCurve.graduate, ())
            );
        if (!out.success) {
            // Nothing to decode. The next `vm.recordLogs()` is what resets the buffer:
            // `vm.getRecordedLogs()` is a `view` in forge-std 1.9.0 and clears nothing.
            return out;
        }

        GraduatedLog memory log = graduatedLog(address(curve));
        (out.corePositionId, out.floorPositionId, out.ethToCore, out.ethToFloor, out.tokensToCore) =
            (
                log.positionIdCore,
                log.positionIdFloor,
                log.ethToCore,
                log.ethToFloor,
                log.tokensToCore
            );
        out.coreLiquidity = positionManager.getPositionLiquidity(out.corePositionId);
        out.dust = PledrinConstants.LP_SUPPLY - out.tokensToCore;
        out.curveTokenBalance = token.balanceOf(address(curve));
    }

    function _assertOutcomesMatch(Outcome memory baseline, Outcome memory donated, uint256 donation)
        private
        pure
    {
        assertEq(donated.success, baseline.success, "Invariant 60: the same success");
        assertEq(donated.corePositionId, baseline.corePositionId, "Invariant 60: positionIdCore");
        assertEq(donated.tokensToCore, baseline.tokensToCore, "Invariant 60: tokensToCore");
        assertEq(donated.ethToCore, baseline.ethToCore, "Invariant 60: ethToCore");
        assertEq(donated.ethToFloor, baseline.ethToFloor, "Invariant 60: ethToFloor");
        assertEq(donated.floorPositionId, baseline.floorPositionId, "positionIdFloor");
        assertEq(donated.coreLiquidity, baseline.coreLiquidity, "the liquidity minted");
        assertEq(donated.dust, baseline.dust, "the remainder the dust check compares");
        assertLe(donated.dust, PledrinConstants.LP_DUST_MAX, "Invariant 39 under a donation");
        assertEq(
            donated.curveTokenBalance,
            baseline.curveTokenBalance + donation,
            "Invariant 60: the donation is still held by the curve"
        );

        // The guard. This is the figure a single post-call `balanceOf` would have treated as
        // the remainder, and `_mintCore` never reads it.
        if (donation > PledrinConstants.LP_DUST_MAX) {
            assertGt(
                donated.curveTokenBalance,
                PledrinConstants.LP_DUST_MAX,
                "an absolute post-call balance read would have reverted this graduation"
            );
        }
    }
}

