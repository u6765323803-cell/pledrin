// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {GraduationHelper} from "src/GraduationHelper.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {ILaunchFactory} from "src/interfaces/ILaunchFactory.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {PledrinTestBase} from "../base/PledrinTestBase.sol";
import {HelperCaller} from "../mocks/GraduationCallers.sol";

/// @title `GraduationHelper` against real launches
/// @notice `docs/SPEC.md` section 8.6 and Invariant 68, on the deterministic Uniswap v4
/// stand-ins: the candidate walk, the free restore, the paid restore, both budget
/// refusals, the bounty, the stray-value sweep and the two call-discipline guards.
/// @dev The adversarial half of section 8.6 — a caller who names a hostile `curve` and
/// therefore names the contract that calls `unlockCallback` — is
/// `test/unit/GraduationHelperHostile.t.sol`, and the end-to-end run against the real
/// Uniswap v4 deployment is `test/fork/GraduationHelper.fork.t.sol`. Everything here uses
/// a real `BondingCurve`, so a graduation that this file reports really is a graduation.
///
/// **The balance clause is asserted in the form the specification carries, not the form
/// an earlier revision carried.** `receive()` is an external call and step 9 requires it
/// to accept ETH from any sender, so "zero at the end of every external call" cannot be
/// the testable statement. What is asserted below is: at the end of every call to
/// `graduateVia` the helper holds zero ETH and zero base units of any launch token, and
/// value that arrives by any other path does not persist — the next successful
/// `graduateVia` either spends it settling that call's swap or forwards it to that caller.
/// Both outcomes have a test of their own, named for which one it is.
contract GraduationHelperTest is PledrinTestBase {
    using CurrencyLibrary for Currency;

    /// @dev The nominal exact input `GraduationHelper` gives every restoring swap. It is
    /// far above anything a restore can need, which is how "sized to reach the limit" is
    /// expressed to v4: the limit decides the size, not this number.
    int256 private constant EXACT_INPUT_TO_LIMIT = -int256(uint256(type(uint128).max));

    /// @dev A griefed price below the terminal price, restored on launch tokens in.
    int24 private constant GRIEF_TICK_BELOW = 100_000;
    /// @dev A griefed price above it, restored on ETH in.
    int24 private constant GRIEF_TICK_ABOVE = 200_000;

    GraduationHelper internal helper;

    event GraduatedVia(
        address indexed launch,
        address indexed caller,
        uint256 candidateIndex,
        uint256 bounty,
        uint256 ethReturned,
        uint256 tokensReturned
    );

    function setUp() public override {
        super.setUp();
        helper = new GraduationHelper();
    }

    // ------------------------------------------------------------------
    // The ordinary paths
    // ------------------------------------------------------------------

    /// @notice **Section 8.6 steps 2 to 5.** A pool griefed off the terminal price is
    /// restored and the launch graduates in the same transaction, on the canonical key.
    function test_aGriefedCanonicalKeyIsRestoredAndGraduatedInOneCall() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        uint160 terminal = curve.sqrtPriceTerminal();
        _grief(curve.poolId(), GRIEF_TICK_BELOW);

        uint256 bounty = _expectedBounty(curve);
        uint256 swapsBefore = poolManager.swapCalls();
        uint256 balanceBefore = GRADUATOR.balance;

        vm.expectEmit(true, true, true, true, address(helper));
        emit GraduatedVia(address(curve), GRADUATOR, 0, bounty, bounty, 0);
        vm.prank(GRADUATOR);
        uint256 index = helper.graduateVia(IBondingCurve(address(curve)), _candidates(), 0);

        assertEq(index, 0, "the canonical candidate graduated");
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "it graduated");
        (uint160 price,) = poolManager.slot0(curve.poolId());
        assertEq(price, terminal, "the mint saw the terminal price");
        assertEq(poolManager.swapCalls(), swapsBefore + 1, "one swap, and it was the helper's");
        assertEq(poolManager.lastSwapLimit(), terminal, "the limit was the terminal price");
        assertEq(
            poolManager.lastSwapAmountSpecified(),
            EXACT_INPUT_TO_LIMIT,
            "the swap was sized to reach the limit"
        );
        assertFalse(poolManager.lastSwapZeroForOne(), "a price below terminal comes up on token in");
        assertEq(GRADUATOR.balance, balanceBefore + bounty, "the bounty reached the caller");
        assertEq(
            curve.pendingBountyWei(address(helper)), 0, "step 5: the helper's credit was claimed"
        );
        _assertHelperHoldsNothing(token);
    }

    /// @notice **The free path.** In an empty pool the restoring swap settles nothing in
    /// either currency, so the helper touches neither `settle` nor `take`, and the price
    /// lands exactly on the limit — the same behaviour the curve's own restore relies on.
    function test_theFreeRestorePaysNothingAndSettlesNothing() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        _grief(curve.poolId(), GRIEF_TICK_ABOVE);

        uint256 settlesBefore = poolManager.settleCalls();
        uint256 takesBefore = poolManager.takeCalls();

        vm.prank(GRADUATOR);
        helper.graduateVia(IBondingCurve(address(curve)), _candidates(), 0);

        assertEq(poolManager.settleCalls(), settlesBefore, "the free restore settled nothing");
        assertEq(poolManager.takeCalls(), takesBefore, "and took nothing");
        assertTrue(poolManager.lastSwapZeroForOne(), "a price above terminal comes down on ETH in");
        (uint160 price,) = poolManager.slot0(curve.poolId());
        assertEq(price, curve.sqrtPriceTerminal(), "the price is on the limit");
        assertEq(
            poolManager.currencyDelta(address(helper), CurrencyLibrary.ADDRESS_ZERO),
            0,
            "no delta was left open"
        );
        _assertHelperHoldsNothing(token);
    }

    /// @notice A key already at the terminal price needs no swap at all, which is the
    /// `current == sqrtPriceTerminal` arm of step 3.
    function test_aKeyAlreadyAtTheTerminalPriceIsGraduatedWithoutASwap() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        uint256 swapsBefore = poolManager.swapCalls();

        vm.prank(GRADUATOR);
        uint256 index = helper.graduateVia(IBondingCurve(address(curve)), _candidates(), 0);

        assertEq(index, 0, "it graduated on the first candidate");
        assertEq(poolManager.swapCalls(), swapsBefore, "and nobody swapped");
        _assertHelperHoldsNothing(token);
    }

    /// @notice An unopened alternate key is opened by the graduation itself, which is the
    /// `current == 0` arm of the same step.
    function test_anUnopenedAlternateKeyIsOpenedByTheGraduationItself() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        vm.warp(curve.capReachedAt() + PledrinConstants.ALT_DELAY);

        uint256 swapsBefore = poolManager.swapCalls();
        vm.recordLogs();
        vm.prank(GRADUATOR);
        uint256 index = helper.graduateVia(IBondingCurve(address(curve)), _candidates(3000, 100), 0);

        assertEq(index, 0, "the alternate candidate graduated");
        assertEq(poolManager.swapCalls(), swapsBefore, "an unopened key needs no restore");
        GraduatedLog memory log = graduatedLog(address(curve));
        assertEq(log.fee, 3000, "the key the graduation used");
        assertEq(log.tickSpacing, 100, "and its spacing");
        _assertHelperHoldsNothing(token);
    }

    /// @notice **The canonical pair is always taken through `graduate()`.** The helper
    /// routes `(POOL_FEE, POOL_TICK_SPACING)` to `graduate` and everything else to
    /// `graduateAlt`, so `CanonicalKeyNotAllowed` is not reachable through this contract:
    /// the pair that would provoke it is the pair that never reaches `graduateAlt`.
    function test_theCanonicalPairIsTakenThroughGraduateAndNeverThroughGraduateAlt() public {
        (BondingCurve curve,) = createLaunchAtCap();
        // Before `ALT_DELAY`, so a canonical pair sent to `graduateAlt` would fail twice
        // over and the success below can only be `graduate`.
        vm.recordLogs();
        vm.prank(GRADUATOR);
        uint256 index = helper.graduateVia(IBondingCurve(address(curve)), _candidates(), 0);

        assertEq(index, 0, "the canonical candidate graduated");
        GraduatedLog memory log = graduatedLog(address(curve));
        assertEq(log.fee, PledrinConstants.POOL_FEE, "on the canonical fee");
        assertEq(log.tickSpacing, PledrinConstants.POOL_TICK_SPACING, "and the canonical spacing");
    }

    // ------------------------------------------------------------------
    // The walk
    // ------------------------------------------------------------------

    /// @notice **Step 2 and step 6.** The first candidate that graduates ends the walk, and
    /// the candidates after it are never tried.
    function test_theFirstSuccessEndsTheWalkAndTheRestAreNeverTried() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        vm.warp(curve.capReachedAt() + PledrinConstants.ALT_DELAY);

        GraduationHelper.Candidate[] memory candidates = new GraduationHelper.Candidate[](4);
        candidates[0] = GraduationHelper.Candidate({fee: 2999, tickSpacing: 100}); // fee too low
        candidates[1] = GraduationHelper.Candidate({fee: 3000, tickSpacing: 9}); // spacing too low
        candidates[2] = GraduationHelper.Candidate({fee: 3000, tickSpacing: 100}); // graduates
        candidates[3] = GraduationHelper.Candidate({fee: 4000, tickSpacing: 60}); // never reached

        vm.prank(GRADUATOR);
        uint256 index = helper.graduateVia(IBondingCurve(address(curve)), candidates, 0);

        assertEq(index, 2, "the third candidate is the one that graduated");
        PoolKey memory untried = poolKeyFor(address(token), 4000, 60);
        assertFalse(
            poolManager.initialized(untried.toId()), "the candidate after the success was tried"
        );
        _assertHelperHoldsNothing(token);
    }

    /// @notice A list whose only success is its last element still graduates on it.
    function test_aListWhoseOnlySuccessIsTheLastElement() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        vm.warp(curve.capReachedAt() + PledrinConstants.ALT_DELAY);

        GraduationHelper.Candidate[] memory candidates = new GraduationHelper.Candidate[](5);
        candidates[0] = GraduationHelper.Candidate({fee: 1, tickSpacing: 100});
        candidates[1] = GraduationHelper.Candidate({fee: 10_001, tickSpacing: 100});
        candidates[2] = GraduationHelper.Candidate({fee: 3000, tickSpacing: 201});
        candidates[3] = GraduationHelper.Candidate({fee: 3000, tickSpacing: 1 << 23});
        candidates[4] = GraduationHelper.Candidate({fee: 10_000, tickSpacing: 200});

        vm.prank(GRADUATOR);
        uint256 index = helper.graduateVia(IBondingCurve(address(curve)), candidates, 0);

        assertEq(index, 4, "the last candidate graduated");
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "it graduated");
        _assertHelperHoldsNothing(token);
    }

    /// @notice **A failed candidate unwinds completely.** One that reaches a swap and then
    /// cannot graduate leaves the pool it swapped on exactly where it found it, and the
    /// walk goes on to graduate on the next key. The caller's balances end where they
    /// would have without the failure.
    /// @dev The attempt is a self-call, so its revert unwinds its own swap — and unwinds
    /// every record of it too, including the stand-in's own swap counter, which is why the
    /// swap is shown two ways instead of counted. `expectCall` sees the call the revert
    /// erased, and the second half runs the identical candidate from the identical state
    /// with the delay elapsed: the restore then sticks, so the only difference between the
    /// two halves is the refusal that arrives after the swap.
    function test_aFailedCandidateUnwindsItsSwapAndTheWalkGoesOn() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        PoolKey memory altKey = poolKeyFor(address(token), PledrinConstants.POOL_FEE, 100);
        uint160 griefed = TickMath.getSqrtPriceAtTick(GRIEF_TICK_BELOW);
        poolManager.pokeSlot0(altKey.toId(), griefed, GRIEF_TICK_BELOW);

        GraduationHelper.Candidate[] memory candidates = new GraduationHelper.Candidate[](2);
        // Restorable, but `ALT_DELAY` has not elapsed, so the attempt swaps and then fails.
        candidates[0] =
            GraduationHelper.Candidate({fee: PledrinConstants.POOL_FEE, tickSpacing: 100});
        candidates[1] = GraduationHelper.Candidate({fee: 10_000, tickSpacing: 200});

        uint256 balanceBefore = GRADUATOR.balance;
        uint256 bounty = _expectedBounty(curve);
        uint256 snapshot = vm.snapshotState();

        // Two over the whole test, one per half: the swap the first half's revert erased
        // and the swap the second half's success keeps. `expectCall` is checked at the end
        // of the test and counts a call that a later revert undid, which is the only way
        // left to observe the first one.
        vm.expectCall(address(poolManager), abi.encodeWithSelector(IPoolManager.swap.selector), 2);
        vm.prank(GRADUATOR);
        uint256 index = helper.graduateVia(IBondingCurve(address(curve)), candidates, 0);

        assertEq(index, 1, "the second candidate is the one that graduated");
        (uint160 altPrice,) = poolManager.slot0(altKey.toId());
        assertEq(altPrice, griefed, "the failed candidate's swap unwound with it");
        assertEq(GRADUATOR.balance, balanceBefore + bounty, "the caller is only up the bounty");
        _assertHelperHoldsNothing(token);

        assertTrue(vm.revertToState(snapshot), "the pre-walk state was restored");
        vm.warp(curve.capReachedAt() + PledrinConstants.ALT_DELAY);
        vm.prank(GRADUATOR);
        index = helper.graduateVia(IBondingCurve(address(curve)), candidates, 0);

        assertEq(index, 0, "the same first candidate graduates once the delay has elapsed");
        (altPrice,) = poolManager.slot0(altKey.toId());
        assertEq(altPrice, curve.sqrtPriceTerminal(), "and this time its restore stuck");
        _assertHelperHoldsNothing(token);
    }

    /// @notice **Step 6.** When no candidate graduates the whole call reverts with the
    /// number tried and the caller keeps everything.
    function test_noCandidateGraduatesSoTheCallerKeepsEverything() public {
        // `Live`, not `Graduating`: every candidate is refused for the state.
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        buy(curve, TRADER, 1 ether);

        uint256 tokens = token.balanceOf(TRADER);
        vm.prank(TRADER);
        token.approve(address(helper), tokens);

        GraduationHelper.Candidate[] memory candidates = new GraduationHelper.Candidate[](2);
        candidates[0] = GraduationHelper.Candidate({fee: 10_000, tickSpacing: 200});
        candidates[1] = GraduationHelper.Candidate({fee: 3000, tickSpacing: 100});

        uint256 ethBefore = TRADER.balance;

        vm.expectRevert(abi.encodeWithSelector(GraduationHelper.NoCandidateGraduated.selector, 2));
        vm.prank(TRADER);
        helper.graduateVia{value: 1 ether}(IBondingCurve(address(curve)), candidates, tokens);

        assertEq(TRADER.balance, ethBefore, "not a wei left the caller");
        assertEq(token.balanceOf(TRADER), tokens, "nor a base unit");
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Live), "and nothing graduated");
        _assertHelperHoldsNothing(token);
    }

    /// @notice The boundary case of step 6: an empty list tries nothing and says so.
    function test_anEmptyCandidateListTriesNothingAndRevertsWithZero() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        uint256 swapsBefore = poolManager.swapCalls();

        GraduationHelper.Candidate[] memory none = new GraduationHelper.Candidate[](0);
        vm.expectRevert(abi.encodeWithSelector(GraduationHelper.NoCandidateGraduated.selector, 0));
        vm.prank(GRADUATOR);
        helper.graduateVia{value: 1 ether}(IBondingCurve(address(curve)), none, 0);

        assertEq(poolManager.swapCalls(), swapsBefore, "an empty list reads no pool");
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduating), "and graduates none");
        _assertHelperHoldsNothing(token);
    }

    /// @notice Every reason a candidate can be refused, one list each, and each costing the
    /// caller nothing. The walk reports `NoCandidateGraduated(1)` for all of them, because
    /// the revert reason of an attempt is deliberately not bound.
    function test_everyRefusalAWalkCanMeetCostsTheCallerNothing() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();

        // Before `ALT_DELAY`: a permitted alternate pair that has to wait.
        _expectWholeWalkToFail(curve, token, 3000, 100, "alt delay not elapsed");

        vm.warp(curve.capReachedAt() + PledrinConstants.ALT_DELAY);
        _expectWholeWalkToFail(curve, token, 2999, 100, "fee below ALT_POOL_FEE_MIN");
        _expectWholeWalkToFail(curve, token, 10_001, 100, "fee above ALT_POOL_FEE_MAX");
        _expectWholeWalkToFail(curve, token, 3000, 9, "spacing below ALT_TICK_SPACING_MIN");
        _expectWholeWalkToFail(curve, token, 3000, 201, "spacing above ALT_TICK_SPACING_MAX");
        // Above `int24`, so the helper's own `SafeCast` narrowing is what refuses it.
        _expectWholeWalkToFail(curve, token, 3000, 1 << 23, "spacing wider than int24");

        // And the state refusal, on a launch that has already graduated.
        vm.prank(GRADUATOR);
        helper.graduateVia(IBondingCurve(address(curve)), _candidates(), 0);
        _expectWholeWalkToFail(curve, token, 10_000, 200, "already graduated");
    }

    // ------------------------------------------------------------------
    // The paid path and the two budgets
    // ------------------------------------------------------------------

    /// @notice **The paid path, ETH leg.** A restore that costs real ETH is settled out of
    /// `msg.value` and the remainder comes back with the bounty.
    function test_aPaidEthRestoreSpendsMsgValueAndReturnsTheRest() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        _grief(curve.poolId(), GRIEF_TICK_ABOVE);
        uint256 cost = 0.03 ether;
        poolManager.setSwapDelta(-int128(int256(cost)), 0);

        uint256 brought = 0.1 ether;
        uint256 bounty = _expectedBounty(curve);
        uint256 balanceBefore = GRADUATOR.balance;
        vm.deal(GRADUATOR, balanceBefore + brought);

        vm.recordLogs();
        vm.prank(GRADUATOR);
        uint256 index =
            helper.graduateVia{value: brought}(IBondingCurve(address(curve)), _candidates(), 0);

        assertEq(index, 0, "it graduated");
        assertEq(poolManager.settledTotal(CurrencyLibrary.ADDRESS_ZERO), cost, "the ETH settled");
        assertEq(poolManager.settleCalls(), 1, "in one settlement");
        assertEq(
            GRADUATOR.balance,
            balanceBefore + brought - cost + bounty,
            "the caller paid the restore and kept the rest, plus the bounty"
        );
        assertEq(
            poolManager.currencyDelta(address(helper), CurrencyLibrary.ADDRESS_ZERO),
            0,
            "the lock closed with no open delta"
        );
        _assertHelperHoldsNothing(token);
    }

    /// @notice **The paid path, token leg.** A restore paid in launch tokens spends out of
    /// the single upfront pull and returns the remainder, and the pull is the only
    /// allowance the helper ever uses.
    function test_aPaidTokenRestoreSpendsThePullAndReturnsTheRest() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        _grief(curve.poolId(), GRIEF_TICK_BELOW);
        uint256 cost = 5e18;
        poolManager.setSwapDelta(0, -int128(int256(cost)));

        uint256 brought = 9e18;
        uint256 tokensBefore = token.balanceOf(TRADER);
        vm.prank(TRADER);
        token.approve(address(helper), brought);

        vm.prank(TRADER);
        uint256 index = helper.graduateVia(IBondingCurve(address(curve)), _candidates(), brought);

        assertEq(index, 0, "it graduated");
        assertEq(
            poolManager.settledTotal(Currency.wrap(address(token))),
            cost,
            "the pool was paid the restore. Measured through the settlement rather than"
            " through the PoolManager's balance, which by the end of this call also holds"
            " the core position's whole token leg"
        );
        assertEq(
            token.balanceOf(TRADER), tokensBefore - cost, "and the caller paid exactly that much"
        );
        assertEq(token.allowance(TRADER, address(helper)), 0, "the pull consumed the allowance");
        assertEq(poolManager.syncCalls(), 1, "sync, transfer, settle: the protocol's order");
        assertEq(poolManager.settleCalls(), 1, "one settlement");
        _assertHelperHoldsNothing(token);
    }

    /// @notice A restore that credits the helper instead of charging it is taken and
    /// forwarded to the caller with everything else.
    function test_aRestoreThatCreditsTheHelperForwardsTheCreditToTheCaller() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        _grief(curve.poolId(), GRIEF_TICK_ABOVE);
        uint256 credit = 0.02 ether;
        poolManager.setSwapDelta(int128(int256(credit)), 0);
        vm.deal(address(poolManager), address(poolManager).balance + credit);

        uint256 bounty = _expectedBounty(curve);
        uint256 balanceBefore = GRADUATOR.balance;

        vm.prank(GRADUATOR);
        helper.graduateVia(IBondingCurve(address(curve)), _candidates(), 0);

        assertEq(poolManager.takeCalls(), 1, "the credit was taken");
        assertEq(poolManager.takenTotal(CurrencyLibrary.ADDRESS_ZERO), credit, "all of it, once");
        assertEq(GRADUATOR.balance, balanceBefore + bounty + credit, "and it reached the caller");
        _assertHelperHoldsNothing(token);
    }

    /// @notice **`EthBudgetExceeded` names the number to bring.** The walk itself does not
    /// surface it — a candidate's revert reason is deliberately not bound, so a caller sees
    /// `NoCandidateGraduated` — which is why the number is read here off the attempt the
    /// walk makes, called the way the walk calls it.
    function test_theEthBudgetRefusalNamesWhatToBringAndSpendsNothing() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        _grief(curve.poolId(), GRIEF_TICK_ABOVE);
        uint256 cost = 1 ether;
        poolManager.setSwapDelta(-int128(int256(cost)), 0);

        uint256 brought = 0.25 ether;
        vm.deal(address(helper), brought);
        // Read before the cheatcode: `expectRevert` binds to the next call, and an
        // argument that is itself a call would be that call.
        uint160 terminal = curve.sqrtPriceTerminal();
        vm.expectRevert(
            abi.encodeWithSelector(GraduationHelper.EthBudgetExceeded.selector, cost, brought)
        );
        vm.prank(address(helper));
        helper.attemptCandidate(
            IBondingCurve(address(curve)),
            token,
            IPoolManager(address(poolManager)),
            terminal,
            GraduationHelper.Candidate({fee: 10_000, tickSpacing: 200})
        );

        // The same shortfall through the walk: an opaque refusal, and nothing spent.
        uint256 balanceBefore = GRADUATOR.balance;
        vm.deal(GRADUATOR, balanceBefore + brought);
        vm.expectRevert(abi.encodeWithSelector(GraduationHelper.NoCandidateGraduated.selector, 1));
        vm.prank(GRADUATOR);
        helper.graduateVia{value: brought}(IBondingCurve(address(curve)), _candidates(), 0);

        assertEq(GRADUATOR.balance, balanceBefore + brought, "the attempt spent nothing");
        assertEq(poolManager.settledTotal(CurrencyLibrary.ADDRESS_ZERO), 0, "nothing was settled");
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduating), "still frozen");
    }

    /// @notice **`TokenBudgetExceeded` names the number to bring**, read the same way and
    /// for the same reason.
    function test_theTokenBudgetRefusalNamesWhatToBringAndSpendsNothing() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        _grief(curve.poolId(), GRIEF_TICK_BELOW);
        uint256 cost = 10e18;
        poolManager.setSwapDelta(0, -int128(int256(cost)));

        uint256 brought = 4e18;
        vm.prank(TRADER);
        token.transfer(address(helper), brought);

        uint160 terminal = curve.sqrtPriceTerminal();
        vm.expectRevert(
            abi.encodeWithSelector(GraduationHelper.TokenBudgetExceeded.selector, cost, brought)
        );
        vm.prank(address(helper));
        helper.attemptCandidate(
            IBondingCurve(address(curve)),
            token,
            IPoolManager(address(poolManager)),
            terminal,
            GraduationHelper.Candidate({fee: 10_000, tickSpacing: 200})
        );

        assertEq(token.balanceOf(address(poolManager)), 0, "the pool was paid nothing");
        assertEq(token.balanceOf(address(helper)), brought, "and the attempt spent nothing");
    }

    /// @notice A swap that settles but cannot reach the limit is refused before the
    /// graduation, so no launch can be minted at a griefed price.
    function test_aSwapThatCannotReachTheLimitIsRefused() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        uint160 griefed = TickMath.getSqrtPriceAtTick(GRIEF_TICK_ABOVE);
        _grief(curve.poolId(), GRIEF_TICK_ABOVE);
        poolManager.setSwapRestoresPrice(false);

        uint160 terminal = curve.sqrtPriceTerminal();
        vm.expectRevert(
            abi.encodeWithSelector(GraduationHelper.PriceNotRestored.selector, griefed, terminal)
        );
        vm.prank(address(helper));
        helper.attemptCandidate(
            IBondingCurve(address(curve)),
            token,
            IPoolManager(address(poolManager)),
            terminal,
            GraduationHelper.Candidate({fee: 10_000, tickSpacing: 200})
        );

        vm.expectRevert(abi.encodeWithSelector(GraduationHelper.NoCandidateGraduated.selector, 1));
        vm.prank(GRADUATOR);
        helper.graduateVia(IBondingCurve(address(curve)), _candidates(), 0);
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduating), "nothing graduated");
        _assertHelperHoldsNothing(token);
    }

    // ------------------------------------------------------------------
    // The bounty
    // ------------------------------------------------------------------

    /// @notice **Step 5, and the failure it tolerates.** A launch whose accrued protocol
    /// fee is under ten wei credits a bounty of zero, `claimBounty` refuses an empty
    /// credit, and the graduation stands anyway: the walk returns its index and the
    /// zero-balance assertion still holds.
    function test_aBountyOfZeroMakesTheClaimFailAndTheGraduationStands() public {
        _setZeroFee();
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        assertEq(curve.protocolFeeEth(), 0, "a zero-fee launch accrues no protocol fee");

        uint256 balanceBefore = GRADUATOR.balance;
        vm.expectEmit(true, true, true, true, address(helper));
        emit GraduatedVia(address(curve), GRADUATOR, 0, 0, 0, 0);
        vm.prank(GRADUATOR);
        uint256 index = helper.graduateVia(IBondingCurve(address(curve)), _candidates(), 0);

        assertEq(index, 0, "the walk returned the index that graduated");
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "it graduated");
        assertEq(GRADUATOR.balance, balanceBefore, "and there was nothing to pay out");
        _assertHelperHoldsNothing(token);
    }

    /// @notice The bounty is credited to the helper by the graduation and claimed out of it
    /// in the same transaction, which is what makes the balance clause reachable at all.
    function test_theBountyIsClaimedInTheSameTransactionAndForwarded() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        uint256 bounty = _expectedBounty(curve);
        assertGt(bounty, 0, "this launch has a bounty to claim");

        uint256 balanceBefore = GRADUATOR.balance;
        vm.prank(GRADUATOR);
        helper.graduateVia(IBondingCurve(address(curve)), _candidates(), 0);

        assertEq(GRADUATOR.balance, balanceBefore + bounty, "the caller was paid the bounty");
        assertEq(curve.pendingBountyWei(address(helper)), 0, "the helper holds no credit");
        assertEq(curve.pendingBountyTotalWei(), 0, "and the launch owes none");
        _assertHelperHoldsNothing(token);
    }

    // ------------------------------------------------------------------
    // Stray value: swept, not asserted against
    // ------------------------------------------------------------------

    /// @notice **A stray base unit does not brick the helper for that launch.** It is swept
    /// out by the next successful call instead of failing the closing assertion forever,
    /// which is the difference between Invariant 68 and a griefing lever.
    function test_aStrayTokenUnitDoesNotBrickTheHelperAndLeavesWithTheNextCaller() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();

        vm.prank(TRADER);
        token.transfer(address(helper), 1);
        assertEq(token.balanceOf(address(helper)), 1, "the griefer's base unit is parked");

        uint256 tokensBefore = token.balanceOf(GRADUATOR);
        vm.prank(GRADUATOR);
        uint256 index = helper.graduateVia(IBondingCurve(address(curve)), _candidates(), 0);

        assertEq(index, 0, "the launch graduated with the stray unit in the contract");
        assertEq(token.balanceOf(GRADUATOR), tokensBefore + 1, "and it left with the caller");
        _assertHelperHoldsNothing(token);
    }

    /// @notice The same for ETH that arrives through `receive()`, which step 9 requires to
    /// accept anything from anybody.
    function test_strayEthDoesNotBrickTheHelperAndLeavesWithTheNextCaller() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();

        vm.prank(OTHER);
        (bool sent,) = address(helper).call{value: 7 wei}("");
        assertTrue(sent, "step 9: `receive` accepts ETH from any sender");

        uint256 bounty = _expectedBounty(curve);
        uint256 balanceBefore = GRADUATOR.balance;
        vm.prank(GRADUATOR);
        helper.graduateVia(IBondingCurve(address(curve)), _candidates(), 0);

        assertEq(GRADUATOR.balance, balanceBefore + bounty + 7, "the stray left with the caller");
        _assertHelperHoldsNothing(token);
    }

    /// @notice **Stray ETH can subsidise a restore the caller did not pay for.** The ETH
    /// leg is bounded by the balance the helper holds, not by `msg.value`, so value that
    /// arrived by another path can be spent settling this call's swap. Nobody is harmed —
    /// stray value has no owner and this caller loses nothing they sent — but it is a real
    /// behaviour and this is the test that says so.
    function test_strayEthCanPayForARestoreThatTheCallerDidNotFund() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        _grief(curve.poolId(), GRIEF_TICK_ABOVE);
        uint256 cost = 0.05 ether;
        poolManager.setSwapDelta(-int128(int256(cost)), 0);

        vm.prank(OTHER);
        (bool sent,) = address(helper).call{value: cost}("");
        assertTrue(sent, "the stray arrived");

        uint256 bounty = _expectedBounty(curve);
        uint256 balanceBefore = GRADUATOR.balance;
        vm.prank(GRADUATOR);
        uint256 index = helper.graduateVia(IBondingCurve(address(curve)), _candidates(), 0);

        assertEq(index, 0, "the restore was paid out of the stray balance");
        assertEq(poolManager.settledTotal(CurrencyLibrary.ADDRESS_ZERO), cost, "all of it");
        assertEq(
            GRADUATOR.balance,
            balanceBefore + bounty,
            "and the caller, who sent no ETH at all, lost nothing"
        );
        _assertHelperHoldsNothing(token);
    }

    /// @notice **The token leg behaves the same way, and that symmetry is the answer to the
    /// obvious question.** `_settleToken` is bounded by `balanceOf(address(this))` exactly
    /// as `_settleEth` is bounded by `address(this).balance`, so a stray token balance can
    /// pay for a restore the caller did not fund. Neither leg is bounded by the pull alone.
    function test_strayTokensCanPayForARestoreThatTheCallerDidNotFund() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        _grief(curve.poolId(), GRIEF_TICK_BELOW);
        uint256 cost = 3e18;
        poolManager.setSwapDelta(0, -int128(int256(cost)));

        vm.prank(TRADER);
        token.transfer(address(helper), cost);

        uint256 tokensBefore = token.balanceOf(GRADUATOR);
        vm.prank(GRADUATOR);
        uint256 index = helper.graduateVia(IBondingCurve(address(curve)), _candidates(), 0);

        assertEq(index, 0, "the token restore was paid out of the stray balance");
        assertEq(poolManager.settledTotal(Currency.wrap(address(token))), cost, "all of it");
        assertEq(
            token.balanceOf(GRADUATOR),
            tokensBefore,
            "and the caller, who brought no tokens and approved nothing, lost none"
        );
        _assertHelperHoldsNothing(token);
    }

    /// @notice **Invariant 68's value-movement clause, in the form the specification
    /// carries:** the helper moves value to no address other than its own caller, except a
    /// swap's settlement to the PoolManager inside that swap's own lock. Asserted as
    /// narrowly as that sentence reads — every movement out of the contract is either to
    /// `msg.sender` or to the PoolManager, and every PoolManager-bound one falls strictly
    /// inside a lock window.
    /// @dev Read off the log stream rather than off balances, because the clause is about
    /// *when* as well as *where*. The stand-in emits `LockTaken` and `LockReleased` for no
    /// other purpose: a token transfer to the PoolManager is a call on the token, so
    /// nothing in the PoolManager could refuse one that arrived outside its lock, and only
    /// the log order can show that none did. The ETH leg needs no such window check —
    /// `settle` is `onlyWhenUnlocked` on the real contract and on the stand-in — but it is
    /// checked the same way anyway, since the same scan covers it.
    function test_valueLeavesOnlyForTheCallerOrForASettlementInsideTheLock() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        _grief(curve.poolId(), GRIEF_TICK_BELOW);
        uint256 cost = 2e18;
        poolManager.setSwapDelta(0, -int128(int256(cost)));

        uint256 brought = 6e18;
        vm.prank(TRADER);
        token.approve(address(helper), brought);

        vm.recordLogs();
        vm.prank(TRADER);
        helper.graduateVia(IBondingCurve(address(curve)), _candidates(), brought);

        (uint256 toCaller, uint256 toManagerInsideLock) = _auditValueMovements(token, TRADER);
        assertEq(toCaller, 1, "one movement to the caller: the unspent remainder");
        assertEq(toManagerInsideLock, 1, "and one settlement, inside the swap's own lock");
    }

    // ------------------------------------------------------------------
    // Call discipline and the shape of the contract
    // ------------------------------------------------------------------

    /// @notice `attemptCandidate` refuses every address but the contract itself.
    function test_attemptCandidateRefusesEveryAddressButTheContractItself() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        GraduationHelper.Candidate memory candidate =
            GraduationHelper.Candidate({fee: 10_000, tickSpacing: 200});
        uint160 terminal = curve.sqrtPriceTerminal();
        IPoolManager manager = IPoolManager(address(poolManager));

        vm.expectRevert(GraduationHelper.NotSelf.selector);
        helper.attemptCandidate(IBondingCurve(address(curve)), token, manager, terminal, candidate);

        vm.expectRevert(GraduationHelper.NotSelf.selector);
        vm.prank(address(poolManager));
        helper.attemptCandidate(IBondingCurve(address(curve)), token, manager, terminal, candidate);
    }

    /// @notice `unlockCallback` refuses anybody when no unlock is in progress, including
    /// the PoolManager the curve names — the flag is cleared the moment `unlock` returns.
    function test_unlockCallbackRefusesOutsideAnUnlock() public {
        (, IERC20 token) = createLaunchAtCap();
        bytes memory payload =
            abi.encode(poolKeyFor(address(token), 10_000, 200), true, uint160(1 << 96));

        vm.expectRevert(GraduationHelper.NotUnlocking.selector);
        helper.unlockCallback(payload);

        vm.expectRevert(GraduationHelper.NotUnlocking.selector);
        vm.prank(address(poolManager));
        helper.unlockCallback(payload);
    }

    /// @notice **Invariant 68's shape clauses.** No owner, no admin function, no pause, no
    /// rescue, and no storage that outlives a transaction: every slot a call could have
    /// written reads zero afterwards, because the only state the contract has is transient.
    function test_theHelperHasNoOwnerNoAdminAndNoPersistentStorage() public {
        (BondingCurve curve,) = createLaunchAtCap();

        string[8] memory signatures = [
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "unpause()",
            "sweep(address)",
            "rescue(address,uint256)",
            "setPoolManager(address)",
            "initialize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = address(helper).call(abi.encodeWithSignature(signatures[i]));
            assertFalse(ok, signatures[i]);
        }

        vm.prank(GRADUATOR);
        helper.graduateVia(IBondingCurve(address(curve)), _candidates(), 0);

        for (uint256 slot = 0; slot < 8; slot++) {
            assertEq(
                vm.load(address(helper), bytes32(slot)),
                bytes32(0),
                "a call wrote storage that outlived it"
            );
        }
    }

    /// @notice A caller that refuses the refund fails its own call and nothing else: the
    /// launch is still `Graduating` afterwards and the next caller graduates it.
    function test_aCallerThatRefusesTheRefundFailsOnlyItsOwnCall() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        HelperCaller caller = new HelperCaller(helper);
        caller.setOnRefund(HelperCaller.OnRefund.Refuse);
        vm.deal(address(caller), 1 ether);

        uint256 bounty = _expectedBounty(curve);
        vm.expectRevert(
            abi.encodeWithSelector(
                GraduationHelper.EthTransferFailed.selector, address(caller), bounty
            )
        );
        caller.graduateVia(IBondingCurve(address(curve)), _candidates(), 0, 0);

        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduating), "nothing graduated");

        vm.prank(GRADUATOR);
        helper.graduateVia(IBondingCurve(address(curve)), _candidates(), 0);
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "the next caller did");
        _assertHelperHoldsNothing(token);
    }

    /// @notice A caller that pushes value back in from its own receive hook fails its own
    /// call, which is the only call it can affect. This is the closing assertion firing.
    function test_aCallerThatPushesValueBackInFailsOnlyItsOwnCall() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        HelperCaller caller = new HelperCaller(helper);
        caller.setOnRefund(HelperCaller.OnRefund.PushBack);
        vm.deal(address(caller), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(GraduationHelper.BalanceNotZero.selector, 1, 0));
        caller.graduateVia(IBondingCurve(address(curve)), _candidates(), 0, 0);

        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduating), "nothing graduated");
        _assertHelperHoldsNothing(token);
    }

    /// @notice A caller that re-enters `graduateVia` from its refund hook is refused by the
    /// guard, and its own call still completes: the reentrant call is the one that fails.
    function test_aCallerThatReEntersFromItsRefundIsRefusedByTheGuard() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        HelperCaller caller = new HelperCaller(helper);
        caller.setOnRefund(HelperCaller.OnRefund.Reenter);
        caller.setReentry(IBondingCurve(address(curve)), _candidates());
        vm.deal(address(caller), 1 ether);

        uint256 index = caller.graduateVia(IBondingCurve(address(curve)), _candidates(), 0, 0);

        assertEq(index, 0, "the outer call completed");
        assertEq(caller.refunds(), 1, "the refund arrived");
        assertFalse(caller.reentrySucceeded(), "and the reentrant call did not");
        assertEq(
            bytes4(caller.reentryError()),
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
            "the guard is what refused it"
        );
        _assertHelperHoldsNothing(token);
    }

    /// @notice **Invariant 68's last clause.** Deleting this contract, replacing it or
    /// deploying a second instance changes no curve's behaviour: three identical launches
    /// graduated through two different helper instances and through no helper at all come
    /// out with the same amounts in every field of `Graduated`.
    /// @dev This is the clause that makes the helper not a trust dependency. It is checked
    /// by comparing the graduations rather than by inspecting the contracts, because the
    /// claim is about outcomes — a curve cannot tell whether its caller was a helper, which
    /// instance it was, or whether one exists.
    function test_aSecondInstanceAndNoInstanceAtAllChangeNothing() public {
        GraduationHelper second = new GraduationHelper();

        (BondingCurve first,) = createLaunchAtCap();
        (BondingCurve middle,) = createLaunchAtCap();
        (BondingCurve last,) = createLaunchAtCap();

        vm.recordLogs();
        vm.prank(GRADUATOR);
        helper.graduateVia(IBondingCurve(address(first)), _candidates(), 0);
        GraduatedLog memory viaFirst = graduatedLog(address(first));

        vm.recordLogs();
        vm.prank(GRADUATOR);
        second.graduateVia(IBondingCurve(address(middle)), _candidates(), 0);
        GraduatedLog memory viaSecond = graduatedLog(address(middle));

        vm.recordLogs();
        vm.prank(GRADUATOR);
        last.graduate();
        GraduatedLog memory direct = graduatedLog(address(last));

        assertEq(viaFirst.ethToCore, direct.ethToCore, "ethToCore");
        assertEq(viaSecond.ethToCore, direct.ethToCore, "ethToCore, second instance");
        assertEq(viaFirst.tokensToCore, direct.tokensToCore, "tokensToCore");
        assertEq(viaSecond.tokensToCore, direct.tokensToCore, "tokensToCore, second instance");
        assertEq(viaFirst.ethToFloor, direct.ethToFloor, "ethToFloor");
        assertEq(viaSecond.ethToFloor, direct.ethToFloor, "ethToFloor, second instance");
        assertEq(viaFirst.bounty, direct.bounty, "bounty");
        assertEq(viaSecond.bounty, direct.bounty, "bounty, second instance");
        assertEq(viaFirst.fee, direct.fee, "the key's fee");
        assertEq(viaFirst.tickSpacing, direct.tickSpacing, "and its spacing");
        // The one field that differs is the one that has to: who called.
        assertEq(viaFirst.caller, address(helper), "the first instance was the caller");
        assertEq(viaSecond.caller, address(second), "the second instance was the caller");
        assertEq(direct.caller, GRADUATOR, "and nobody was, in the third");
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    /// @notice For any ETH brought and any restore cost inside it, the caller ends up with
    /// exactly what they brought, less the restore, plus the bounty — and the helper ends
    /// up with nothing.
    function testFuzz_whatComesBackIsWhatWasBroughtLessTheRestorePlusTheBounty(
        uint256 brought,
        uint256 cost
    ) public {
        brought = bound(brought, 0, 50 ether);
        cost = bound(cost, 0, brought);

        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        _grief(curve.poolId(), GRIEF_TICK_ABOVE);
        poolManager.setSwapDelta(-int128(int256(cost)), 0);

        uint256 bounty = _expectedBounty(curve);
        vm.deal(GRADUATOR, brought);

        vm.prank(GRADUATOR);
        uint256 index =
            helper.graduateVia{value: brought}(IBondingCurve(address(curve)), _candidates(), 0);

        assertEq(index, 0, "it graduated");
        assertEq(GRADUATOR.balance, brought - cost + bounty, "the caller's arithmetic");
        assertEq(poolManager.settledTotal(CurrencyLibrary.ADDRESS_ZERO), cost, "the pool's");
        _assertHelperHoldsNothing(token);
    }

    /// @notice For any list in which exactly one candidate can graduate, the walk returns
    /// that candidate's index whatever its position.
    function testFuzz_theWalkReturnsTheIndexOfTheOnlyCandidateThatCanGraduate(
        uint256 length,
        uint256 position
    ) public {
        length = bound(length, 1, 12);
        position = bound(position, 0, length - 1);

        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        GraduationHelper.Candidate[] memory candidates = new GraduationHelper.Candidate[](length);
        for (uint256 i = 0; i < length; i++) {
            // Every other entry is refused for its fee, which is a verdict about calldata
            // and so is true whatever the pool's state.
            candidates[i] = GraduationHelper.Candidate({fee: 2999, tickSpacing: 100});
        }
        candidates[position] = GraduationHelper.Candidate({fee: 10_000, tickSpacing: 200});

        vm.prank(GRADUATOR);
        uint256 index = helper.graduateVia(IBondingCurve(address(curve)), candidates, 0);

        assertEq(index, position, "the index the walk returned");
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "it graduated");
        _assertHelperHoldsNothing(token);
    }

    // ------------------------------------------------------------------
    // Gas, and what happens to a walk that is not given enough of it
    // ------------------------------------------------------------------

    /// @notice What a failed candidate costs and what the ordinary success costs, measured
    /// rather than estimated: four numbers, each from the same pre-graduation state.
    /// @dev The assertions are deliberately loose bands, not point values, for two
    /// reasons. `forge coverage` runs this same test with the optimizer and the IR pipeline
    /// off, where every number below is larger; and the restoring swap here is the
    /// stand-in's, which costs a fraction of the real one because it walks no tick bitmap.
    /// The figures that matter are the ones logged here, the `--gas-report` rows at the
    /// default profile, and — for a swap that crosses real liquidity — the end-to-end
    /// measurement in `test/fork/GraduationHelper.fork.t.sol`.
    function test_gasForAFailedCandidateAndForTheOrdinarySuccess() public {
        (BondingCurve curve,) = createLaunchAtCap();
        uint256 snapshot = vm.snapshotState();

        GraduationHelper.Candidate[] memory one = _candidates();
        uint256 plain = _measure(curve, one, 0);
        assertTrue(vm.revertToState(snapshot), "restored");

        // The same success, with a restoring swap in front of it.
        _grief(curve.poolId(), GRIEF_TICK_BELOW);
        uint256 withRestore = _measure(curve, one, 0);
        assertTrue(vm.revertToState(snapshot), "restored");

        // Ten candidates refused on their fee — a verdict about calldata, so no pool is
        // read at all — and then the candidate that graduates.
        GraduationHelper.Candidate[] memory cheapFailures = new GraduationHelper.Candidate[](11);
        for (uint256 i = 0; i < 10; i++) {
            cheapFailures[i] = GraduationHelper.Candidate({fee: 2999, tickSpacing: 100});
        }
        cheapFailures[10] = one[0];
        uint256 perCalldataFailure = (_measure(curve, cheapFailures, 0) - plain) / 10;
        assertTrue(vm.revertToState(snapshot), "restored");

        // Ten candidates that are permitted pairs on unopened keys, so each one reads
        // `slot0`, skips the swap and is refused by the curve for `ALT_DELAY`. This is the
        // failed candidate that does not reach a swap.
        GraduationHelper.Candidate[] memory poolReadFailures = new GraduationHelper.Candidate[](11);
        for (uint256 i = 0; i < 10; i++) {
            poolReadFailures[i] =
                GraduationHelper.Candidate({fee: 3000, tickSpacing: uint24(10 + i * 10)});
        }
        poolReadFailures[10] = one[0];
        uint256 perPoolReadFailure = (_measure(curve, poolReadFailures, 0) - plain) / 10;

        emit log_named_uint("graduateVia, success, no restore needed", plain);
        emit log_named_uint("graduateVia, success, free restoring swap", withRestore);
        emit log_named_uint("one candidate refused on calldata", perCalldataFailure);
        emit log_named_uint("one candidate refused after a slot0 read", perPoolReadFailure);

        assertGt(withRestore, plain, "the restoring swap is not free in gas");
        assertGt(perPoolReadFailure, perCalldataFailure, "a pool read costs more than a cast");
        assertLt(perPoolReadFailure, 200_000, "a failed candidate has become implausible");
    }

    /// @notice **An under-funded walk reverts; it never returns a wrong answer.** A
    /// candidate that runs out of gas inside `attemptCandidate` leaves the walk the 1/64
    /// the self-call could not take, which is enough to revert and not enough to lie.
    /// @dev Swept across stipends rather than fuzzed, so the boundary between "not enough
    /// gas to finish" and "enough" is crossed in both directions in one run, and each
    /// stipend starts from the same pre-graduation state.
    function test_anUnderFundedWalkRevertsRatherThanSkippingACandidate() public {
        (BondingCurve curve,) = createLaunchAtCap();
        HelperCaller caller = new HelperCaller(helper);
        vm.deal(address(caller), 1 ether);

        uint256 successes;
        for (uint256 stipend = 30_000; stipend <= 3_000_000; stipend += 150_000) {
            uint256 snapshot = vm.snapshotState();
            (bool ok, bytes memory ret) = caller.graduateViaWithGas(
                IBondingCurve(address(curve)), _candidates(), 0, 0, stipend
            );

            if (ok) {
                successes++;
                assertEq(
                    uint8(curve.state()),
                    uint8(IBondingCurve.State.Graduated),
                    "a call that returned an index did not graduate the launch"
                );
                assertEq(abi.decode(ret, (uint256)), 0, "and the index it returned");
            } else {
                assertEq(
                    uint8(curve.state()),
                    uint8(IBondingCurve.State.Graduating),
                    "a call that reverted still changed the launch"
                );
            }
            assertTrue(vm.revertToState(snapshot), "the pre-graduation state was restored");
        }
        assertGt(successes, 0, "no stipend in the sweep was enough to graduate at all");
    }

    // ------------------------------------------------------------------
    // Shared helpers
    // ------------------------------------------------------------------

    /// @dev Walks the recorded logs and classifies every value movement out of the helper.
    /// Anything that is neither to the caller nor a settlement inside a lock window fails
    /// here rather than being counted.
    /// @param token The launch token to audit transfers of.
    /// @param caller The address the helper was allowed to pay.
    /// @return toCaller Movements to the caller.
    /// @return toManagerInsideLock Settlements to the PoolManager inside its own lock.
    function _auditValueMovements(IERC20 token, address caller)
        private
        view
        returns (uint256 toCaller, uint256 toManagerInsideLock)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        bytes32 settleTopic = keccak256("Settle(address,address,uint256)");
        bytes32 lockTakenTopic = keccak256("LockTaken(address)");
        bytes32 lockReleasedTopic = keccak256("LockReleased(address,uint256)");

        bool locked;
        for (uint256 i = 0; i < logs.length; i++) {
            bytes32 topic = logs[i].topics[0];
            if (logs[i].emitter == address(poolManager)) {
                if (topic == lockTakenTopic) locked = true;
                if (topic == lockReleasedTopic) locked = false;
                if (topic == settleTopic && _addressAt(logs[i], 1) == address(helper)) {
                    assertTrue(locked, "a settlement happened outside the swap's lock");
                    toManagerInsideLock++;
                }
                continue;
            }
            if (logs[i].emitter != address(token) || topic != transferTopic) continue;
            if (_addressAt(logs[i], 1) != address(helper)) continue;

            address to = _addressAt(logs[i], 2);
            if (to == caller) {
                toCaller++;
                continue;
            }
            assertEq(to, address(poolManager), "the helper moved value to a third address");
            assertTrue(locked, "a settlement happened outside the swap's lock");
        }
    }

    /// @dev One indexed address topic of a log.
    function _addressAt(Vm.Log memory entry, uint256 index) private pure returns (address) {
        return address(uint160(uint256(entry.topics[index])));
    }

    /// @dev One `graduateVia` from `GRADUATOR`, and the gas it took.
    function _measure(
        BondingCurve curve,
        GraduationHelper.Candidate[] memory candidates,
        uint256 value
    ) private returns (uint256 used) {
        vm.deal(GRADUATOR, GRADUATOR.balance + value);
        vm.prank(GRADUATOR);
        uint256 before = gasleft();
        helper.graduateVia{value: value}(IBondingCurve(address(curve)), candidates, 0);
        used = before - gasleft();
    }

    /// @dev Invariant 68's balance clause, in the form the specification carries: zero at
    /// the end of a `graduateVia`, in ETH and in that launch's token.
    function _assertHelperHoldsNothing(IERC20 token) private view {
        assertEq(address(helper).balance, 0, "Invariant 68: the helper kept ETH");
        assertEq(token.balanceOf(address(helper)), 0, "Invariant 68: the helper kept tokens");
    }

    /// @dev One candidate naming the canonical key.
    function _candidates() private pure returns (GraduationHelper.Candidate[] memory out) {
        return
            _candidates(
                PledrinConstants.POOL_FEE, uint24(int24(PledrinConstants.POOL_TICK_SPACING))
            );
    }

    function _candidates(uint24 fee, uint24 tickSpacing)
        private
        pure
        returns (GraduationHelper.Candidate[] memory out)
    {
        out = new GraduationHelper.Candidate[](1);
        out[0] = GraduationHelper.Candidate({fee: fee, tickSpacing: tickSpacing});
    }

    /// @dev Moves a pool off the terminal price, as a griefer would.
    function _grief(PoolId id, int24 tick) private {
        poolManager.pokeSlot0(id, TickMath.getSqrtPriceAtTick(tick), tick);
    }

    /// @dev The bounty this launch will credit, by section 8.3's formula.
    function _expectedBounty(BondingCurve curve) private view returns (uint256) {
        return curve.protocolFeeEth() * PledrinConstants.GRAD_BOUNTY_BPS
            / PledrinConstants.BPS_DENOMINATOR;
    }

    /// @dev One single-candidate walk that must fail, with nothing moved and nothing spent.
    function _expectWholeWalkToFail(
        BondingCurve curve,
        IERC20 token,
        uint24 fee,
        uint24 tickSpacing,
        string memory reason
    ) private {
        uint256 ethBefore = GRADUATOR.balance;
        vm.expectRevert(abi.encodeWithSelector(GraduationHelper.NoCandidateGraduated.selector, 1));
        vm.prank(GRADUATOR);
        helper.graduateVia(IBondingCurve(address(curve)), _candidates(fee, tickSpacing), 0);

        assertEq(GRADUATOR.balance, ethBefore, reason);
        _assertHelperHoldsNothing(token);
    }

    /// @dev A launch whose trading fee is zero, so its protocol fee — and therefore its
    /// bounty — is zero too.
    function _setZeroFee() private {
        executeAfterDelay(
            address(factory),
            abi.encodeCall(
                ILaunchFactory.setFeeConfig,
                (ILaunchFactory.FeeConfig({
                        totalFeeBps: 0,
                        unpledged: ILaunchFactory.FeeShares({
                            creatorShareBps: UNPLEDGED_CREATOR_BPS,
                            protocolShareBps: UNPLEDGED_PROTOCOL_BPS,
                            protectionShareBps: UNPLEDGED_PROTECTION_BPS
                        }),
                        pledged: ILaunchFactory.FeeShares({
                            creatorShareBps: PLEDGED_CREATOR_BPS,
                            protocolShareBps: PLEDGED_PROTOCOL_BPS,
                            protectionShareBps: PLEDGED_PROTECTION_BPS
                        })
                    }))
            ),
            bytes32("zero fee")
        );
    }
}
