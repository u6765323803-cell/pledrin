// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {stdError} from "forge-std/StdError.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {LaunchFactory} from "src/LaunchFactory.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {ILaunchFactory} from "src/interfaces/ILaunchFactory.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {PledrinTestBase} from "../base/PledrinTestBase.sol";
import {PreFixCoreMintHarness} from "../helpers/PreFixCoreMint.sol";
import {BalanceWatcher} from "../mocks/CallProbes.sol";

/// @title Invariant 60's second quantifier and Invariant 70: a stray balance in
/// PositionManager cannot touch a graduation
/// @notice Covers `docs/SPEC.md` section 8.2 steps 4 and 8, **Invariant 60** (the `S`
/// half), **Invariant 70**, Invariant 43's "ETH that reached the curve outside its own
/// paths", and finding 1 of `docs/security/REVIEW-2026-11-11-phase1-contracts.md`.
/// @dev PositionManager's native balance is a globally shared number anyone can raise: an
/// ordinary v4 user whose batch forwards more value than it settles leaves the remainder
/// there, and `SELFDESTRUCT` puts it there past the `receive()` sender check. The batch
/// `BondingCurve._mintData` builds ends in `SWEEP(currency0, MSG_SENDER)`, and
/// v4-periphery's sweep is not a refund of the mint's unspent value — it sends
/// PositionManager's **entire** balance of that currency (`PositionManager._sweep`,
/// `:499-502`). So with a stray `S` and a true mint cost `U`, the curve's balance across
/// the call moves by `S - U` rather than by `-U`, and the pre-`5b86188` contract, which
/// measured `ethBefore - address(this).balance`, computed `U - S`: wrong by `S` below
/// `S = U`, and an arithmetic panic at or above it, on `graduate()` and `graduateAlt(PledrinConstants.POOL_FEE, )`
/// alike, with `abortGraduation` into `Stalled` as the only remaining exit.
///
/// Every test here is differential, for the same reason the token half in
/// `BondingCurveDonationNeutrality.t.sol` is: the risk is not a defect that exists today
/// but a later edit that reintroduces a balance reading because it reads as equivalent. A
/// test that merely graduates with a stray in place and passes would also pass against a
/// *saturating* balance delta, which still mis-reports the event and still lets a stranger
/// inflate the floor position. So each test graduates twice from the same state — once with
/// `S = 0`, once with `S` parked — and compares the two outcomes field by field.
///
/// The ETH quantifier is stronger than the token one, and the assertions say so. A token
/// donation *cancels*: both readings rise by `D`. A stray does not cancel and does not need
/// to, because no quantity the graduation computes reads a balance `S` can reach.
/// `_assertOutcomesMatch` therefore also pins `ethToCore` to the value the launch's own
/// parameters give, which `test/unit/CoreMintArithmetic.t.sol` pins to a literal.
contract BondingCurveStrayBalanceTest is PledrinTestBase {
    /// @dev Everything Invariant 60 names for `S`, plus the floor liquidity Invariant 70
    /// adds, plus the three balances that must move by exactly `S`, by nothing, and to zero.
    struct Outcome {
        bool success;
        bytes returnData;
        uint256 corePositionId;
        uint256 floorPositionId;
        uint256 ethToCore;
        uint256 ethToFloor;
        uint256 tokensToCore;
        uint256 coreLiquidity;
        uint256 floorLiquidity;
        uint256 dust;
        uint256 curveBalance;
        uint256 poolBalance;
        uint256 positionManagerBalance;
    }

    /// @dev One instance, for the pure formula alone. The mints run through fresh ones.
    PreFixCoreMintHarness internal arithmetic;

    function setUp() public virtual override {
        super.setUp();
        arithmetic = new PreFixCoreMintHarness();
    }

    // ------------------------------------------------------------------
    // The differential, over every stray a third party can park
    // ------------------------------------------------------------------

    /// @notice **Invariant 60 for `S`, by fuzz.** For any native balance a third party can
    /// leave in PositionManager, the graduation is the one that would have happened with
    /// `S = 0`.
    /// @dev The range runs to 1,000 ETH — `MAX_VIRTUAL_ETH_RESERVE`'s whole raise, and 250
    /// times this launch's `R_target` — so most draws are far above the `U` that used to be
    /// the underflow threshold and the rest straddle it.
    function testFuzz_aStrayOfAnySizeChangesNothingAboutTheGraduation(uint256 straySeed) public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        uint256 stray = bound(straySeed, 1, 1000 ether);

        _assertStrayIsNeutral(curve, token, stray, false);
    }

    /// @notice The boundaries the fuzz will not land on, and the one that matters most is
    /// `U`: a wei below it the pre-fix contract under-reported `ethToCore` by `S`, at `U`
    /// the subtraction reached zero, and a wei above it the graduation reverted.
    function test_aStrayAtEveryBoundaryChangesNothing() public {
        (BondingCurve measured, IERC20 measuredToken) = createLaunchAtCap();
        uint256 coreEth = _coreEthOf(measured, measuredToken);

        uint256[7] memory strays = [
            uint256(1),
            PledrinConstants.MIN_FLOOR_WEI,
            coreEth - 1,
            coreEth,
            coreEth + 1,
            uint256(measured.ethTarget()),
            1000 ether
        ];

        for (uint256 i = 0; i < strays.length; i++) {
            (BondingCurve curve, IERC20 token) = createLaunchAtCap();
            _assertStrayIsNeutral(curve, token, strays[i], false);
        }
    }

    /// @notice The alternate key is the same procedure on a caller-chosen spacing, and a
    /// stray is just as inert there. `_mintCore` is on both paths, which is why the pre-fix
    /// defect closed both at once and left no third path.
    function test_aStrayChangesNothingAboutAnAlternateKeyGraduation() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        vm.warp(curve.capReachedAt() + PledrinConstants.ALT_DELAY);

        _assertStrayIsNeutral(curve, token, 10 ether, true);
    }

    /// @notice **Invariant 60's failure half for `S`.** A graduation that refuses refuses in
    /// exactly the same way with a stray parked, and for the same reason.
    /// @dev The griefed primary key of section 8.4: liquidity at the wrong price makes the
    /// restoring swap cost something and `graduate` refuses rather than spend curve ETH. If
    /// a stray could turn one revert into another — or into a success — a launch's fate
    /// would depend on a balance nobody involved controls.
    function test_aStrayChangesNeitherTheRevertNorItsReason() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        poolManager.pokeSlot0(curve.poolId(), 1 << 96, 100_000);
        poolManager.setSwapDelta(-1, 0);

        uint256 snapshot = vm.snapshotState();
        Outcome memory baseline = _graduate(curve, token, false);
        assertFalse(baseline.success, "the griefed key refuses this graduation");

        assertTrue(vm.revertToState(snapshot), "the baseline state was restored");
        vm.deal(address(positionManager), 100 ether);

        Outcome memory strayed = _graduate(curve, token, false);
        assertFalse(strayed.success, "and refuses it with the stray in place");
        assertEq(
            strayed.returnData, baseline.returnData, "Invariant 60: the same revert, byte for byte"
        );
        assertEq(
            strayed.returnData,
            abi.encodeWithSelector(IBondingCurve.SwapNotFree.selector, -1, 0),
            "and it is still the swap's own refusal"
        );
        assertEq(
            uint8(curve.state()),
            uint8(IBondingCurve.State.Graduating),
            "the launch is still retryable"
        );
        assertEq(address(positionManager).balance, 100 ether, "and the stray is where it was");
    }

    /// @notice A stray cannot conjure a floor position for a launch that has none.
    /// @dev The second-order half of finding 1, and the half the review did not list. With
    /// no trading fee there is no protection pool and the clipped buy lands `ethReserve` on
    /// `ethTarget` exactly, so `floorEth` is the mint's ETH remainder alone — 1,088 wei,
    /// below `MIN_FLOOR_WEI`, and the floor mint is skipped. The pre-fix `floorEth` was
    /// `ethTarget - (U - S) = 1,088 + S`, so a stray of `MIN_FLOOR_WEI` carried it over the
    /// threshold and minted a permanent position funded entirely by a stranger's ETH,
    /// flipping `positionIdFloor` from zero to a real id. The last block derives that from
    /// the harness instead of asserting it from the prose.
    function test_aStrayCannotConjureAFloorPositionWhereTheLaunchHasNone() public {
        _setZeroFees();

        uint256[3] memory strays =
            [PledrinConstants.MIN_FLOOR_WEI - 1088, PledrinConstants.MIN_FLOOR_WEI, 1 ether];

        for (uint256 i = 0; i < strays.length; i++) {
            (BondingCurve curve, IERC20 token) = createDefaultLaunch();
            buyToCap(curve);
            assertEq(curve.protectionEth(), 0, "no fee, so no protection pool");
            assertEq(curve.ethReserve(), curve.ethTarget(), "and no surplus over the target");

            Outcome memory baseline = _assertStrayIsNeutral(curve, token, strays[i], false);
            assertEq(baseline.floorPositionId, 0, "no floor position at all");
            assertEq(baseline.ethToFloor, 0, "and nothing deposited into one");
            assertEq(
                uint256(curve.ethTarget()) - baseline.ethToCore,
                1088,
                "floorEth is the mint's 1,088-wei ETH remainder, below MIN_FLOOR_WEI"
            );
        }

        // What the removed expression would have made of the largest of those, measured
        // rather than argued: `U - S` from the harness, and `ethTarget - that` is the
        // `floorEth` the pre-fix `_settle` would have computed from it.
        (BondingCurve fresh, IERC20 freshToken) = createDefaultLaunch();
        buyToCap(fresh);
        PreFixCoreMintHarness.Measurement memory m = _runHarness(fresh, freshToken, 1 ether);
        assertEq(m.ethUsedByBalanceDelta, m.ethUsedByComputation - 1 ether, "the pre-fix coreEth");
        uint256 preFixFloorEth = uint256(fresh.ethTarget()) - m.ethUsedByBalanceDelta;
        assertEq(preFixFloorEth, 1088 + 1 ether, "the pre-fix floorEth is 1,088 + S");
        assertGe(
            preFixFloorEth,
            PledrinConstants.MIN_FLOOR_WEI,
            "over the threshold, so the pre-fix code would have minted a floor position"
        );
    }

    // ------------------------------------------------------------------
    // Invariant 70: the ordering the floor mint's balance delta rests on
    // ------------------------------------------------------------------

    /// @notice **Invariant 70.** The floor mint still measures a balance delta, and the
    /// three clauses that keep it sound are observed from inside the two mint calls.
    /// @dev The clauses are an ordering property, so no single-function test sees them. The
    /// probe fires once per batch, before the batch's actions run and after its value has
    /// arrived, so the two readings are PositionManager's balance at the top of the core
    /// mint and at the top of the floor mint. The first is `S + R_target`: the stray is
    /// still there. The second is `floorEth` and nothing else, because the core mint's own
    /// `SWEEP` took the whole balance and the only calls between the two mints are the
    /// curve's own token approval, a Permit2 approval and a view.
    function test_theCoreMintSweepLeavesNothingForTheFloorMintToMismeasure() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();

        uint256 stray = 7 ether;
        uint256 protection = curve.protectionEth();
        uint256 surplus = curve.ethReserve() - curve.ethTarget();
        vm.deal(address(positionManager), stray);

        BalanceWatcher watcher = new BalanceWatcher();
        positionManager.setProbe(
            address(watcher), abi.encodeCall(BalanceWatcher.record, (address(positionManager)))
        );

        Outcome memory out = _graduate(curve, token, false);
        positionManager.setProbe(address(0), "");
        assertTrue(out.success, "the graduation succeeded with the stray in place");

        assertEq(watcher.count(), 2, "one reading per mint: the core mint, then the floor mint");
        assertEq(
            watcher.reading(0),
            stray + curve.ethTarget(),
            "clause 1: the core mint runs first, and the stray is still there when it does"
        );

        uint256 floorEth = protection + surplus + (uint256(curve.ethTarget()) - out.ethToCore);
        assertEq(
            watcher.reading(1),
            floorEth,
            "clauses 2 and 3: the sweep took the whole balance, so the floor mint holds its"
            " own funding and nothing else"
        );
        assertLe(out.ethToFloor, floorEth, "the floor mint cannot consume more than it was sent");
        assertEq(
            out.curveBalance,
            obligations(curve) + stray + (floorEth - out.ethToFloor),
            "Invariant 43: the curve keeps the swept stray and the floor mint's own remainder"
        );
        assertEq(address(positionManager).balance, 0, "and PositionManager holds nothing after");
    }

    /// @notice The swept stray is immobilised: it entered no bucket, and in `Graduated` the
    /// curve has no function that moves ETH it does not already owe somebody.
    function test_theSweptStrayStaysInTheCurveWithNoPathOut() public {
        (BondingCurve curve, IERC20 token) = createPledgedLaunch();
        buyToCap(curve);

        uint256 stray = 12.5 ether;
        uint256 protection = curve.protectionEth();
        uint256 surplus = curve.ethReserve() - curve.ethTarget();
        vm.deal(address(positionManager), stray);

        Outcome memory out = _graduate(curve, token, false);
        assertTrue(out.success, "graduated");

        uint256 floorEth = protection + surplus + (uint256(curve.ethTarget()) - out.ethToCore);
        uint256 floorRemainder = floorEth - out.ethToFloor;
        assertEq(
            address(curve).balance,
            obligations(curve) + stray + floorRemainder,
            "nothing credited the stray to anybody: every bucket is what the launch put there"
        );

        curve.claimBond();
        curve.claimCreatorFees();
        curve.claimProtocolFees();
        curve.claimBounty(GRADUATOR);

        assertEq(
            address(curve).balance,
            stray + floorRemainder,
            "Invariant 43: after every claim the stray and the floor remainder are all"
            " that is left"
        );

        // And there is no way to take either. Both trade functions are closed in
        // `Graduated`, the four claims are empty, and the curve has no other ETH-moving
        // surface at all.
        vm.prank(TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Graduated)
        );
        curve.donate{value: 1}();
        vm.prank(TRADER);
        token.approve(address(curve), 1e18);
        vm.prank(TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Graduated)
        );
        curve.sell(1e18, 0, vm.getBlockTimestamp());

        // The claims are the only ETH-moving functions left, and each refuses a second
        // call rather than paying out of what is left.
        vm.expectRevert(IBondingCurve.NothingToClaim.selector);
        curve.claimCreatorFees();
        vm.expectRevert(IBondingCurve.NothingToClaim.selector);
        curve.claimProtocolFees();
        vm.expectRevert(IBondingCurve.NothingToClaim.selector);
        curve.claimBounty(GRADUATOR);
        vm.expectRevert(IBondingCurve.BondAlreadyClaimed.selector);
        curve.claimBond();

        assertEq(address(curve).balance, stray + floorRemainder, "Invariant 43: and no path out");
    }

    // ------------------------------------------------------------------
    // Both directions of finding 1, against the two expressions themselves
    // ------------------------------------------------------------------

    /// @notice The removed expression and the landed one agree exactly when PositionManager
    /// holds nothing, which is what makes `PreFixCoreMintHarness` a reproduction of the
    /// pre-`5b86188` code rather than an unrelated contract that happens to revert.
    /// @dev Three-way equality: the balance delta, the computation, and the `ethToCore` the
    /// contract itself emits for the same launch in the same state. The fix is not an
    /// approximation of what the balance reading measured — at zero stray it is the same wei.
    function test_theTwoExpressionsAgreeExactlyWhenNothingIsParked() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();

        uint256 snapshot = vm.snapshotState();
        Outcome memory graduated = _graduate(curve, token, false);
        assertTrue(graduated.success, "baseline");
        assertTrue(vm.revertToState(snapshot), "the baseline state was restored");

        assertEq(address(positionManager).balance, 0, "nothing is parked");
        PreFixCoreMintHarness.Measurement memory m = _runHarness(curve, token, 0);

        assertEq(
            m.ethUsedByBalanceDelta,
            m.ethUsedByComputation,
            "the removed expression and the landed one are the same number at S = 0"
        );
        assertEq(
            m.ethUsedByComputation, graduated.ethToCore, "and both are the contract's ethToCore"
        );
        assertEq(m.tokensUsed, graduated.tokensToCore, "on the same mint, token leg included");
    }

    /// @notice **Both directions of finding 1.** With `S > U` parked, the removed expression
    /// reverts with an arithmetic panic and the landed one graduates.
    /// @dev The whole finding in one test. The panic is the pre-fix `graduate()` and
    /// `graduateAlt(PledrinConstants.POOL_FEE, )`: `_mintCore` is on both paths, so one parked balance above the
    /// largest live `R_target` denied every launch on the protocol at once, and after
    /// `GRAD_GRACE` the only exit was `abortGraduation` into `Stalled` with no pool. The
    /// stray need not be hostile — a 0.1 ETH remainder left behind by an unrelated v4 user
    /// is enough for a minimum-size launch.
    function test_theRemovedExpressionPanicsOnAStrayAndTheLandedOneDoesNot() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        uint256 coreEth = _coreEthOf(curve, token);
        uint256 stray = coreEth + 1;

        // Direction one: the removed expression, on exactly the stray that broke it. Every
        // argument is read into a local first, because `vm.expectRevert` attaches to the
        // next call of any kind and the argument reads are calls to the curve.
        uint256 snapshot = vm.snapshotState();
        PreFixCoreMintHarness harness = new PreFixCoreMintHarness();
        _fundHarness(curve, token, harness);
        vm.deal(address(positionManager), stray);
        PoolKey memory key = _canonicalKey(token);
        uint160 terminal = curve.sqrtPriceTerminal();
        uint128 target = curve.ethTarget();

        vm.expectRevert(stdError.arithmeticError);
        harness.measureBoth{value: target}(
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(address(permit2)),
            token,
            address(lock),
            key,
            terminal,
            target
        );
        assertTrue(vm.revertToState(snapshot), "the state was restored");

        // Direction two: the landed expression, same stray, same launch, same block.
        vm.deal(address(positionManager), stray);
        Outcome memory out = _graduate(curve, token, false);
        assertTrue(out.success, "the landed code graduates with the stray parked");
        assertEq(out.ethToCore, coreEth, "and reports the mint's real cost");
        assertEq(
            out.curveBalance,
            address(curve).balance,
            "the swept stray is in the curve, where Invariant 43 accounts for it"
        );
        assertGe(out.curveBalance, obligations(curve) + stray, "and it is surplus to every bucket");
    }

    /// @notice Below the underflow threshold the removed expression did not revert — it
    /// returned `U - S`, which is the review's formula, measured here across the range.
    /// @dev This is the mis-measurement a saturating variant of the fix would have kept: no
    /// revert, a wrong `ethToCore` in the log an indexer reads, and a `floorEth` inflated
    /// by a stranger's ETH.
    function testFuzz_theRemovedExpressionUnderReportedByExactlyTheStray(uint256 straySeed) public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        uint256 coreEth = _coreEthOf(curve, token);
        uint256 stray = bound(straySeed, 1, coreEth);

        PreFixCoreMintHarness.Measurement memory m = _runHarness(curve, token, stray);

        assertEq(m.ethUsedByComputation, coreEth, "the landed expression is the real cost");
        assertEq(
            m.ethUsedByBalanceDelta,
            coreEth - stray,
            "and the removed one measured U - S: wrong by exactly the stray"
        );
    }

    // ------------------------------------------------------------------
    // The differential harness
    // ------------------------------------------------------------------

    /// @dev Graduates from the current state twice: once untouched, then from the same state
    /// again with `stray` wei held by PositionManager. `vm.deal` rather than a transfer,
    /// because the real PositionManager's `receive()` refuses ETH from anyone but PoolManager
    /// and WETH9 — and `SELFDESTRUCT`, a block reward and an unswept batch remainder all
    /// bypass that check, so a forced balance is the faithful model of all three. Memory
    /// survives `revertToState`; only account state is rolled back.
    /// @return baseline The `S = 0` outcome, for callers that assert on its fields too.
    function _assertStrayIsNeutral(BondingCurve curve, IERC20 token, uint256 stray, bool alt)
        private
        returns (Outcome memory baseline)
    {
        uint256 snapshot = vm.snapshotState();

        baseline = _graduate(curve, token, alt);
        assertTrue(baseline.success, "the un-strayed graduation is the baseline");

        assertTrue(vm.revertToState(snapshot), "the baseline state was restored");
        assertEq(address(positionManager).balance, 0, "and PositionManager holds nothing again");

        vm.deal(address(positionManager), stray);
        assertEq(
            address(positionManager).balance,
            stray,
            "the stray is in place and the launch could not refuse it"
        );

        Outcome memory strayed = _graduate(curve, token, alt);
        _assertOutcomesMatch(curve, baseline, strayed, stray);
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
        out.floorLiquidity = out.floorPositionId == 0
            ? 0
            : positionManager.getPositionLiquidity(out.floorPositionId);
        out.dust = PledrinConstants.LP_SUPPLY - out.tokensToCore;
        out.curveBalance = address(curve).balance;
        out.poolBalance = address(poolManager).balance;
        out.positionManagerBalance = address(positionManager).balance;
        // Nobody donates a token in this file, so the curve keeps exactly the dust. Pinned
        // here so the two quantifiers of Invariant 60 cannot drift apart unnoticed.
        assertEq(token.balanceOf(address(curve)), out.dust, "the dust is all the curve keeps");
    }

    function _assertOutcomesMatch(
        BondingCurve curve,
        Outcome memory baseline,
        Outcome memory strayed,
        uint256 stray
    ) private view {
        assertEq(strayed.success, baseline.success, "Invariant 60: the same success");
        assertEq(strayed.corePositionId, baseline.corePositionId, "Invariant 60: positionIdCore");
        assertEq(strayed.floorPositionId, baseline.floorPositionId, "Invariant 60: positionIdFloor");
        assertEq(strayed.tokensToCore, baseline.tokensToCore, "Invariant 60: tokensToCore");
        assertEq(strayed.ethToCore, baseline.ethToCore, "Invariant 60: ethToCore");
        assertEq(strayed.ethToFloor, baseline.ethToFloor, "Invariant 70: ethToFloor");
        assertEq(strayed.coreLiquidity, baseline.coreLiquidity, "the core liquidity minted");
        assertEq(strayed.floorLiquidity, baseline.floorLiquidity, "Invariant 70: floor liquidity");
        assertEq(strayed.dust, baseline.dust, "the remainder the dust check compares");
        assertLe(strayed.dust, PledrinConstants.LP_DUST_MAX, "Invariant 39 under a stray");

        // The stronger statement. The token quantifier holds because `D` cancels between two
        // readings; `ethToCore` does not depend on `S` at all, so it is also exactly the
        // number the launch's own parameters give — which is what makes the emitted value
        // reproducible by an indexer that never saw a balance.
        assertEq(
            strayed.ethToCore,
            arithmetic.computedCoreEth(
                curve.sqrtPriceTerminal(), PledrinConstants.POOL_TICK_SPACING
            ),
            "Invariant 60: ethToCore is a pure function of the launch's parameters"
        );

        // Where the stray went, and where it did not.
        assertEq(
            strayed.curveBalance,
            baseline.curveBalance + stray,
            "Invariant 43: the curve's balance is higher by exactly the stray"
        );
        assertEq(
            strayed.poolBalance, baseline.poolBalance, "and the pool received not one wei of it"
        );
        assertEq(strayed.positionManagerBalance, 0, "the sweep took all of it");
        assertEq(baseline.positionManagerBalance, 0, "as it does when there is nothing to take");
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev `ethToCore` for the current state, taken from a graduation that is rolled back
    /// afterwards. Measured rather than computed, so the boundary cases are anchored to
    /// what the contract does and not to what this file thinks it does.
    function _coreEthOf(BondingCurve curve, IERC20 token) private returns (uint256 coreEth) {
        uint256 snapshot = vm.snapshotState();
        Outcome memory out = _graduate(curve, token, false);
        assertTrue(out.success, "the measuring graduation succeeded");
        coreEth = out.ethToCore;
        assertTrue(vm.revertToState(snapshot), "and was rolled back");
    }

    /// @dev Funds a fresh harness with `LP_SUPPLY` token and `R_target` ETH and runs the
    /// core mint through it, on the launch's own canonical key at its terminal price, which
    /// is the state `_mintCore` runs in.
    function _runHarness(BondingCurve curve, IERC20 token, uint256 stray)
        private
        returns (PreFixCoreMintHarness.Measurement memory)
    {
        PreFixCoreMintHarness harness = new PreFixCoreMintHarness();
        _fundHarness(curve, token, harness);
        if (stray != 0) vm.deal(address(positionManager), stray);
        return harness.measureBoth{value: curve.ethTarget()}(
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(address(permit2)),
            token,
            address(lock),
            _canonicalKey(token),
            curve.sqrtPriceTerminal(),
            curve.ethTarget()
        );
    }

    function _fundHarness(BondingCurve curve, IERC20 token, PreFixCoreMintHarness harness) private {
        vm.prank(TRADER);
        token.transfer(address(harness), PledrinConstants.LP_SUPPLY);
        vm.deal(address(this), uint256(curve.ethTarget()));
    }

    function _canonicalKey(IERC20 token) private pure returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: PledrinConstants.POOL_FEE,
            tickSpacing: PledrinConstants.POOL_TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    /// @dev Installs a zero trading fee through the timelock, which is the only way a launch
    /// reaches graduation with no protection pool at all.
    function _setZeroFees() private {
        ILaunchFactory.FeeConfig memory config = defaultFeeConfig();
        config.totalFeeBps = 0;
        executeAfterDelay(
            address(factory),
            abi.encodeCall(LaunchFactory.setFeeConfig, (config)),
            keccak256("zero fees")
        );
        assertEq(factory.feeConfig().totalFeeBps, 0, "the fee is zero for launches from here on");
    }
}

