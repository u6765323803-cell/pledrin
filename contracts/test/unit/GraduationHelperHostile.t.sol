// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {GraduationHelper} from "src/GraduationHelper.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {HelperCaller} from "../mocks/GraduationCallers.sol";
import {HostileCurve, HostilePoolManager, RecordingToken} from "../mocks/HostileGraduation.sol";

/// @title A caller who names a hostile `curve` names the contract that calls back
/// @notice **The security property the whole of section 8.6 rests on.** `GraduationHelper`
/// reads its PoolManager off the curve its caller names, so a caller who names a hostile
/// curve chooses the contract that will call `unlockCallback`, chooses that callback's
/// payload, and gets control inside every settlement the helper performs. This file is
/// written to break that and reports what it could not reach.
///
/// The claim measured here: **a caller's total loss is bounded by
/// `msg.value + maxTokensIn` for any `curve` whatsoever.** The bound holds structurally
/// rather than by any check on the curve — `graduateVia` pulls `maxTokensIn` once at the
/// top of the call and every settlement afterwards spends a balance this contract is
/// already holding, so there is no allowance left for a forged callback to use and
/// nothing to spend but what the caller brought.
///
/// Three of the brief's attacks could not be constructed at all, and each is named at the
/// test that documents why:
///
/// - **`transferFrom` from inside the lock.** There is one `transferFrom` call site in the
///   contract, in `graduateVia` before the walk, and `nonReentrant` admits that function
///   once per transaction. No reachable path reaches a second one, so the attack reduces to
///   counting the pulls — `test_theSingleUpfrontPullIsTheOnlyAllowanceTheHelperEverUses`.
/// - **Settling a currency the caller never named** reduces to the same bound by a
///   different route: a forged payload can name any currency, and `_settleToken` pays out
///   of `balanceOf(address(this))`, so a currency the helper holds nothing of settles
///   nothing — `test_aForgedPayloadReachesOnlyACurrencyTheHelperAlreadyHolds`.
/// - **Re-entering `graduateVia`** cannot be constructed into a second concurrent walk at
///   all: the guard refuses it from inside a settlement, from inside `graduate` and from
///   inside `claimBounty`, which are the three moments a hostile contract has control.
/// @dev `HostilePoolManager` is not a model of Uniswap v4 and is not held to
/// `MockPoolManager`'s standard of fidelity. It is an adversary: it lies about prices,
/// forges payloads and answers `swap` with whatever delta the attack calls for.
contract GraduationHelperHostileTest is Test {
    /// @dev The price the hostile curve claims is its terminal price, and the price its
    /// PoolManager reports before the restore. They differ, so every attempt swaps.
    uint160 internal constant TERMINAL = 396_140_812_571_321_687_967_719_751_680_000;
    uint160 internal constant GRIEFED = 1 << 96;

    /// @dev The victim: an address that named a hostile curve and brought value to it.
    address internal constant VICTIM = address(0xC1C7);

    GraduationHelper internal helper;
    HostilePoolManager internal pm;
    HostileCurve internal curve;
    RecordingToken internal token;

    event GraduatedVia(
        address indexed launch,
        address indexed caller,
        uint256 candidateIndex,
        uint256 bounty,
        uint256 ethReturned,
        uint256 tokensReturned
    );

    function setUp() public {
        helper = new GraduationHelper();
        pm = new HostilePoolManager();
        token = new RecordingToken("Hostile launch", "HOST");
        curve = new HostileCurve(IERC20(address(token)), IPoolManager(address(pm)), TERMINAL);

        pm.setHelper(helper);
        pm.setLaunchToken(IERC20(address(token)));
        pm.setPrice(GRIEFED);
        curve.setHelper(helper);

        token.mint(VICTIM, 1_000_000e18);
        vm.deal(VICTIM, 100 ether);
        vm.deal(address(pm), 10 ether);
    }

    // ------------------------------------------------------------------
    // The bound, demanded as hard as the helper's own checks allow
    // ------------------------------------------------------------------

    /// @notice A PoolManager that demands one wei more than the helper holds is refused by
    /// the ETH budget, and the candidate's failure costs its caller nothing at all.
    function test_aDemandAboveTheEthBalanceIsRefusedAndCostsNothing() public {
        pm.setAttack(HostilePoolManager.Attack.OverspendEth);

        uint256 ethBefore = VICTIM.balance;
        vm.expectRevert(abi.encodeWithSelector(GraduationHelper.NoCandidateGraduated.selector, 1));
        vm.prank(VICTIM);
        helper.graduateVia{value: 1 ether}(IBondingCurve(address(curve)), _canonical(), 0);

        assertEq(VICTIM.balance, ethBefore, "the victim lost nothing");
        assertEq(pm.ethSettled(), 0, "and the adversary was paid nothing");
        _assertHelperHoldsNothing();
    }

    /// @notice The same one base unit above `maxTokensIn`, refused by the token budget.
    function test_aDemandAboveTheTokenBalanceIsRefusedAndCostsNothing() public {
        pm.setAttack(HostilePoolManager.Attack.OverspendTokens);
        _approve(1000e18);

        uint256 tokensBefore = token.balanceOf(VICTIM);
        vm.expectRevert(abi.encodeWithSelector(GraduationHelper.NoCandidateGraduated.selector, 1));
        vm.prank(VICTIM);
        helper.graduateVia(IBondingCurve(address(curve)), _canonical(), 1000e18);

        assertEq(token.balanceOf(VICTIM), tokensBefore, "the victim lost nothing");
        assertEq(token.balanceOf(address(pm)), 0, "and the adversary was paid nothing");
        _assertHelperHoldsNothing();
    }

    /// @notice **The worst case, exactly measured.** A PoolManager that demands every wei
    /// and every base unit the helper is holding is paid all of it — and that is the end of
    /// what it can reach. The caller's loss is `msg.value + maxTokensIn` and no more, the
    /// unspent part of the approval is untouched, and the helper ends empty.
    function test_theWorstAHostileCurveCanTakeIsMsgValuePlusMaxTokensIn() public {
        pm.setAttack(HostilePoolManager.Attack.DrainEverything);
        uint256 brought = 3 ether;
        uint256 maxTokensIn = 1000e18;
        // Ten times the pull, so a second pull would have something to take.
        _approve(10 * maxTokensIn);

        uint256 ethBefore = VICTIM.balance;
        uint256 tokensBefore = token.balanceOf(VICTIM);

        // One `transferFrom` in the whole call, counted across every frame including any
        // that reverted. This is the "no allowance left to use" claim, measured.
        vm.expectCall(address(token), abi.encodeWithSelector(IERC20.transferFrom.selector), 1);
        vm.prank(VICTIM);
        uint256 index = helper.graduateVia{value: brought}(
            IBondingCurve(address(curve)), _canonical(), maxTokensIn
        );

        assertEq(index, 0, "the hostile curve reported a graduation");
        assertEq(ethBefore - VICTIM.balance, brought, "the ETH loss is exactly msg.value");
        assertEq(
            tokensBefore - token.balanceOf(VICTIM), maxTokensIn, "and the token loss maxTokensIn"
        );
        assertEq(pm.ethSettled(), brought, "all of which reached the adversary");
        assertEq(token.balanceOf(address(pm)), maxTokensIn, "in both currencies");
        assertEq(
            token.allowance(VICTIM, address(helper)),
            9 * maxTokensIn,
            "the rest of the approval was never touched"
        );
        assertEq(token.pullCount(), 1, "one pull, at the top of the call");
        RecordingToken.Pull memory pull = token.pullAt(0);
        assertEq(pull.caller, address(helper), "pulled by the helper");
        assertEq(pull.from, VICTIM, "out of its caller");
        assertEq(pull.to, address(helper), "into itself");
        assertEq(pull.amount, maxTokensIn, "for exactly maxTokensIn");
        _assertHelperHoldsNothing();
    }

    /// @notice **Nested forged callbacks cannot exceed the same bound.** The helper's
    /// unlock flag is still set while a settlement is in flight, so the adversary gets
    /// control and calls `unlockCallback` again, with a payload of its own, as deep as it
    /// likes. Each nested swap demands the whole remaining balance, so the recursion is the
    /// greediest the design admits — and the total still cannot exceed what this one call
    /// brought.
    function test_nestedForgedCallbacksCannotTakeMoreThanTheOneCallBrought() public {
        pm.setAttack(HostilePoolManager.Attack.NestedCallbacks);
        pm.setNesting(_forgedKey(), false, TERMINAL, 8);
        uint256 brought = 2 ether;
        uint256 maxTokensIn = 500e18;
        _approve(10 * maxTokensIn);

        uint256 ethBefore = VICTIM.balance;
        uint256 tokensBefore = token.balanceOf(VICTIM);

        vm.expectCall(
            address(helper), abi.encodeWithSelector(GraduationHelper.unlockCallback.selector)
        );
        HelperCaller caller = new HelperCaller(helper);
        vm.deal(address(caller), brought);
        vm.prank(VICTIM);
        token.transfer(address(caller), maxTokensIn);
        caller.approveHelper(IERC20(address(token)), 10 * maxTokensIn);

        uint256 callerEthBefore = address(caller).balance;
        uint256 callerTokensBefore = token.balanceOf(address(caller));
        (bool ok,) =
            caller.tryGraduateVia(IBondingCurve(address(curve)), _canonical(), maxTokensIn, brought);

        uint256 ethLost = _loss(callerEthBefore, address(caller).balance);
        uint256 tokensLost = _loss(callerTokensBefore, token.balanceOf(address(caller)));
        emit log_named_string("the nested drain", ok ? "returned" : "reverted");
        emit log_named_uint("ETH the caller lost", ethLost);
        emit log_named_uint("tokens the caller lost", tokensLost);

        assertLe(ethLost, brought, "the bound: no more ETH than msg.value");
        assertLe(tokensLost, maxTokensIn, "the bound: no more tokens than maxTokensIn");
        if (ok) _assertHelperHoldsNothing();
        // The victim, who is not this call's caller, is untouched either way.
        assertEq(VICTIM.balance, ethBefore, "a third party's ETH is not reachable");
        assertEq(token.balanceOf(VICTIM) + maxTokensIn, tokensBefore, "nor a third party's tokens");
    }

    /// @notice The same nesting, arranged so that it **returns** rather than reverting, so
    /// the bound is measured on a successful drain and not only on a refused one.
    /// @dev With no token leg to settle there is nothing left for the outer frame to find
    /// missing, so the recursion runs, takes every wei the helper holds, and the call
    /// completes. The caller is down exactly `msg.value` — the most the bound permits —
    /// and the helper ends empty, which is the pair of facts that matters.
    function test_aNestedDrainThatReturnsStillTakesOnlyMsgValue() public {
        pm.setAttack(HostilePoolManager.Attack.NestedCallbacks);
        pm.setNesting(_forgedKey(), false, TERMINAL, 8);
        uint256 brought = 2 ether;

        uint256 ethBefore = VICTIM.balance;
        vm.prank(VICTIM);
        uint256 index =
            helper.graduateVia{value: brought}(IBondingCurve(address(curve)), _canonical(), 0);

        assertEq(index, 0, "the drain returned rather than reverting");
        assertGt(pm.reentryCount(), 0, "the nested callbacks ran");
        assertEq(ethBefore - VICTIM.balance, brought, "and took exactly msg.value, not a wei more");
        assertEq(pm.ethSettled(), brought, "all of which the adversary holds");
        _assertHelperHoldsNothing();
    }

    /// @notice **The headline measurement.** For any ETH brought, any token allowance, any
    /// stray balance already in the contract and any of the adversary's attacks, the
    /// caller's loss is bounded by `msg.value + maxTokensIn`, and a call that returns
    /// leaves the helper holding nothing.
    function testFuzz_aCallersTotalLossIsBoundedByMsgValuePlusMaxTokensIn(
        uint96 brought,
        uint96 maxTokensIn,
        uint8 attackSeed,
        uint96 strayEth,
        uint96 strayTokens
    ) public {
        brought = uint96(bound(brought, 0, 20 ether));
        maxTokensIn = uint96(bound(maxTokensIn, 0, 100_000e18));
        strayEth = uint96(bound(strayEth, 0, 5 ether));
        strayTokens = uint96(bound(strayTokens, 0, 1000e18));

        // Every attack in the script, including the three that end in a refusal.
        pm.setAttack(HostilePoolManager.Attack(attackSeed % 9));
        pm.setNesting(_forgedKey(), false, TERMINAL, 4);
        pm.setReentryTarget(IBondingCurve(address(curve)), _canonical());

        vm.deal(VICTIM, uint256(brought) + 1 ether);
        _approve(uint256(maxTokensIn) * 2);

        // Value with no owner, parked in the contract before the call.
        vm.deal(address(this), strayEth);
        (bool pushed,) = address(helper).call{value: strayEth}("");
        assertTrue(pushed, "step 9: receive accepts ETH from anybody");
        token.mint(address(helper), strayTokens);

        uint256 ethBefore = VICTIM.balance;
        uint256 tokensBefore = token.balanceOf(VICTIM);

        vm.prank(VICTIM);
        (bool ok,) = address(helper).call{value: brought}(
            abi.encodeCall(
                GraduationHelper.graduateVia,
                (IBondingCurve(address(curve)), _canonical(), uint256(maxTokensIn))
            )
        );

        // A credit the adversary pays out of its own balance can leave the caller ahead,
        // so the loss is a floor at zero rather than a subtraction.
        assertLe(_loss(ethBefore, VICTIM.balance), brought, "the ETH bound");
        assertLe(_loss(tokensBefore, token.balanceOf(VICTIM)), maxTokensIn, "the token bound");
        if (ok) {
            // The balance clause, in the form the specification carries.
            _assertHelperHoldsNothing();
        } else {
            assertEq(VICTIM.balance, ethBefore, "a refused call costs its caller nothing");
            assertEq(token.balanceOf(VICTIM), tokensBefore, "in either currency");
        }
    }

    // ------------------------------------------------------------------
    // What the adversary cannot reach
    // ------------------------------------------------------------------

    /// @notice **One pull, and no allowance afterwards.** The approval names the helper and
    /// is consumed exactly once, at the top of the call, before any address the curve chose
    /// has been given control. There is no second `transferFrom` call site to reach: the
    /// only one in the contract is in `graduateVia`, which `nonReentrant` admits once.
    function test_theSingleUpfrontPullIsTheOnlyAllowanceTheHelperEverUses() public {
        pm.setAttack(HostilePoolManager.Attack.DrainEverything);
        uint256 maxTokensIn = 777e18;
        _approve(maxTokensIn);

        vm.prank(VICTIM);
        helper.graduateVia{value: 1 ether}(IBondingCurve(address(curve)), _canonical(), maxTokensIn);

        assertEq(token.allowance(VICTIM, address(helper)), 0, "the pull consumed the approval");
        assertEq(token.pulledBy(address(helper), VICTIM), maxTokensIn, "and pulled no more");
        assertEq(token.pullCount(), 1, "in one call");
    }

    /// @notice A hostile curve cannot use the allowance its caller gave the **helper**: the
    /// approval names one spender and the curve is not it.
    function test_aHostileCurveCannotSpendTheAllowanceTheCallerGaveTheHelper() public {
        _approve(1000e18);

        vm.expectRevert(RecordingToken.InsufficientAllowance.selector);
        vm.prank(address(curve));
        token.transferFrom(VICTIM, address(curve), 1);

        vm.expectRevert(RecordingToken.InsufficientAllowance.selector);
        vm.prank(address(pm));
        token.transferFrom(VICTIM, address(pm), 1);
    }

    /// @notice **A forged payload reaches only a currency the helper already holds.** The
    /// adversary chooses the callback's payload, so it chooses the key, so it chooses the
    /// two currencies settled. A currency the helper holds nothing of settles nothing: the
    /// budget check is against `balanceOf(address(this))` and not against the key.
    function test_aForgedPayloadReachesOnlyACurrencyTheHelperAlreadyHolds() public {
        RecordingToken foreign = new RecordingToken("Someone else's token", "FOR");
        foreign.mint(VICTIM, 1000e18);
        // The victim approves the helper for the foreign token too, which is the most
        // careless thing a caller can do, and it still cannot be reached.
        vm.prank(VICTIM);
        foreign.approve(address(helper), type(uint256).max);

        PoolKey memory forged = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(foreign)),
            fee: PledrinConstants.POOL_FEE,
            tickSpacing: PledrinConstants.POOL_TICK_SPACING,
            hooks: IHooks(address(0))
        });
        pm.setForgedPayload(forged, false, TERMINAL);
        pm.setLaunchToken(IERC20(address(foreign)));
        pm.setAttack(HostilePoolManager.Attack.OverspendTokens);

        uint256 foreignBefore = foreign.balanceOf(VICTIM);
        vm.expectRevert(abi.encodeWithSelector(GraduationHelper.NoCandidateGraduated.selector, 1));
        vm.prank(VICTIM);
        helper.graduateVia{value: 1 ether}(IBondingCurve(address(curve)), _canonical(), 0);

        assertEq(foreign.balanceOf(VICTIM), foreignBefore, "the foreign token was not touched");
        assertEq(foreign.pullCount(), 0, "and its allowance was never used");
    }

    /// @notice **A stray balance in a token that is not this launch's is not swept, and the
    /// closing assertion does not measure it.** `_forward` forwards and then asserts
    /// against `curve.token()`, so a balance of some *other* launch's token survives a
    /// successful call. It is reachable by a `graduateVia` for that launch and by nothing
    /// else, it belongs to nobody, and it blocks nothing — but Invariant 68's wording says
    /// "every launch token", and this is the gap between the wording and the code.
    function test_aStrayBalanceOfAnotherLaunchsTokenSurvivesASuccessfulCall() public {
        RecordingToken other = new RecordingToken("Another launch", "OTH");
        other.mint(address(helper), 5e18);

        pm.setAttack(HostilePoolManager.Attack.None);
        vm.prank(VICTIM);
        helper.graduateVia(IBondingCurve(address(curve)), _canonical(), 0);

        assertEq(
            other.balanceOf(address(helper)),
            5e18,
            "the other launch's token stayed where it was parked"
        );
        _assertHelperHoldsNothing();
    }

    /// @notice `graduateVia` cannot be re-entered from inside a settlement, which is the
    /// one moment the adversary holds control while the helper's own funds are in motion.
    function test_graduateViaCannotBeReEnteredFromInsideASettlement() public {
        pm.setAttack(HostilePoolManager.Attack.ReenterGraduateVia);
        pm.setReentryTarget(IBondingCurve(address(curve)), _canonical());

        vm.prank(VICTIM);
        helper.graduateVia{value: 1 ether}(IBondingCurve(address(curve)), _canonical(), 0);

        assertEq(pm.reentryCount(), 1, "the adversary did try");
        HostilePoolManager.Reentry memory attempt = pm.reentryAt(0);
        assertFalse(attempt.succeeded, "and was refused");
        assertEq(
            bytes4(attempt.returnData),
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
            "by the guard"
        );
        _assertHelperHoldsNothing();
    }

    /// @notice `attemptCandidate` refuses the PoolManager from inside the lock, which is
    /// the strongest position any address can call it from.
    function test_attemptCandidateRefusesTheAdversaryFromInsideTheLock() public {
        pm.setAttack(HostilePoolManager.Attack.CallAttemptCandidate);
        pm.setReentryTarget(IBondingCurve(address(curve)), _canonical());

        vm.prank(VICTIM);
        helper.graduateVia{value: 1 ether}(IBondingCurve(address(curve)), _canonical(), 0);

        assertEq(pm.reentryCount(), 1, "the adversary did try");
        HostilePoolManager.Reentry memory attempt = pm.reentryAt(0);
        assertFalse(attempt.succeeded, "and was refused");
        assertEq(bytes4(attempt.returnData), GraduationHelper.NotSelf.selector, "with NotSelf");
        _assertHelperHoldsNothing();
    }

    /// @notice `unlockCallback` is refused outside an unlock, both to an adversary that was
    /// never asked to unlock anything and to one that is called back **after** the helper's
    /// own unlock has returned — which is where a hostile curve gets its turn.
    function test_unlockCallbackIsRefusedOutsideItsOwnUnlock() public {
        (bool ok, bytes memory ret) = pm.forgeCallbackOutsideUnlock(_forgedKey(), false, TERMINAL);
        assertFalse(ok, "a callback with no unlock in progress was accepted");
        assertEq(bytes4(ret), GraduationHelper.NotUnlocking.selector, "NotUnlocking");

        // And from inside a live `graduateVia`: the curve is called once the restore's
        // unlock has returned, so the flag is already back to zero.
        curve.setOnGraduate(HostileCurve.OnGraduate.ForgeCallback);
        curve.setForgedPayload(_forgedKey(), false, TERMINAL);
        vm.prank(VICTIM);
        helper.graduateVia{value: 1 ether}(IBondingCurve(address(curve)), _canonical(), 0);

        assertEq(curve.callbackCount(), 1, "the curve did try");
        HostileCurve.Callback memory attempt = curve.callbackAt(0);
        assertFalse(attempt.succeeded, "and was refused");
        assertEq(
            bytes4(attempt.returnData),
            GraduationHelper.NotUnlocking.selector,
            "the flag is cleared the moment `unlock` returns"
        );
        _assertHelperHoldsNothing();
    }

    /// @notice A curve that re-enters `graduateVia` from its own `graduate` is refused, and
    /// so is one that re-enters from `claimBounty`, which runs after the walk has finished.
    function test_aCurveCannotReEnterFromGraduateOrFromClaimBounty() public {
        curve.setOnGraduate(HostileCurve.OnGraduate.ReenterGraduateVia);
        curve.setReentryCandidates(_canonical());

        vm.prank(VICTIM);
        helper.graduateVia{value: 1 ether}(IBondingCurve(address(curve)), _canonical(), 0);
        assertEq(curve.callbackCount(), 1, "it tried from graduate");
        assertFalse(curve.callbackAt(0).succeeded, "and was refused");
        assertEq(
            bytes4(curve.callbackAt(0).returnData),
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
            "by the guard"
        );

        curve.setOnGraduate(HostileCurve.OnGraduate.Succeed);
        curve.setOnClaim(HostileCurve.OnClaim.ReenterGraduateVia, 0);
        vm.prank(VICTIM);
        helper.graduateVia{value: 1 ether}(IBondingCurve(address(curve)), _canonical(), 0);
        assertEq(curve.callbackCount(), 2, "and from claimBounty");
        assertFalse(curve.callbackAt(1).succeeded, "where it was refused too");
        assertEq(
            bytes4(curve.callbackAt(1).returnData),
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
            "by the same guard"
        );
        _assertHelperHoldsNothing();
    }

    // ------------------------------------------------------------------
    // What the curve can do to its own caller, and nothing further
    // ------------------------------------------------------------------

    /// @notice A `claimBounty` that refuses is tolerated: the graduation stands and the
    /// walk still returns its index. The same clause as the zero-bounty launch, reached
    /// here by a curve that refuses for its own reasons.
    function test_aClaimBountyThatRefusesIsToleratedAndTheCallStillSucceeds() public {
        curve.setOnClaim(HostileCurve.OnClaim.Refuse, 0);

        // Counted with `expectCall` rather than off the curve's own counter: the claim
        // reverts, so every record it kept of being called reverted with it.
        vm.expectCall(address(curve), abi.encodeWithSelector(IBondingCurve.claimBounty.selector), 1);
        vm.prank(VICTIM);
        uint256 index =
            helper.graduateVia{value: 1 ether}(IBondingCurve(address(curve)), _canonical(), 0);

        assertEq(index, 0, "the refusal did not undo the graduation");
        assertEq(curve.graduateCalls(), 1, "the graduation itself stands");
        _assertHelperHoldsNothing();
    }

    /// @notice A bounty that really is paid is forwarded to the caller with everything else.
    function test_aBountyThatIsPaidIsForwardedToTheCaller() public {
        vm.deal(address(curve), 5 ether);
        curve.setOnClaim(HostileCurve.OnClaim.PayReal, 4 ether);

        uint256 ethBefore = VICTIM.balance;
        vm.prank(VICTIM);
        helper.graduateVia{value: 1 ether}(IBondingCurve(address(curve)), _canonical(), 0);

        assertEq(VICTIM.balance, ethBefore + 4 ether, "the bounty and the unspent ETH came back");
        assertEq(curve.lastEarner(), address(helper), "the credit was claimed for the helper");
        _assertHelperHoldsNothing();
    }

    /// @notice A curve that lies about the bounty moves no value by lying: the amount in the
    /// log is the curve's word and the ETH that actually moves is a balance.
    /// @dev Worth stating for an indexer: `GraduatedVia.bounty` is what `claimBounty`
    /// returned, so for a curve that is not a `BondingCurve` it means nothing. The three
    /// amounts that follow it are balances this contract measured itself.
    function test_aCurveThatLiesAboutTheBountyMovesNoValueByLying() public {
        curve.setOnClaim(HostileCurve.OnClaim.LieAboutTheAmount, 0);
        uint256 brought = 1 ether;

        vm.recordLogs();
        uint256 ethBefore = VICTIM.balance;
        vm.prank(VICTIM);
        helper.graduateVia{value: brought}(IBondingCurve(address(curve)), _canonical(), 0);

        assertEq(VICTIM.balance, ethBefore, "the caller got back exactly what it brought");
        (uint256 bounty, uint256 ethReturned,) = _graduatedVia();
        assertEq(bounty, type(uint256).max, "the log repeats the curve's claim");
        assertEq(ethReturned, brought, "and reports the balance that actually moved");
        _assertHelperHoldsNothing();
    }

    /// @notice Value a curve pushes into the helper mid-call leaves with that same caller,
    /// which is the stray-value clause reached from inside a call rather than before one.
    function test_valueACurvePushesInMidCallLeavesWithThatCaller() public {
        vm.deal(address(curve), 1 ether);
        curve.setOnGraduate(HostileCurve.OnGraduate.PushEth);

        uint256 ethBefore = VICTIM.balance;
        vm.prank(VICTIM);
        helper.graduateVia(IBondingCurve(address(curve)), _canonical(), 0);

        assertEq(VICTIM.balance, ethBefore + 1, "the wei the curve pushed in came out again");
        _assertHelperHoldsNothing();
    }

    // ------------------------------------------------------------------
    // A launch token that misbehaves at each of the three call sites
    // ------------------------------------------------------------------

    /// @notice A token that refuses the upfront pull stops the call before the walk begins,
    /// and this refusal is the one the caller sees directly rather than through the walk.
    function test_aTokenThatRefusesTheUpfrontPullStopsTheCallBeforeTheWalk() public {
        _approve(1000e18);
        token.setFailTransferFrom(true);

        vm.expectRevert(GraduationHelper.TokenTransferFailed.selector);
        vm.prank(VICTIM);
        helper.graduateVia(IBondingCurve(address(curve)), _canonical(), 1000e18);

        assertEq(curve.graduateCalls(), 0, "no candidate was tried");
    }

    /// @notice A token that refuses the settlement transfer fails only that candidate.
    function test_aTokenThatRefusesTheSettlementTransferFailsOnlyThatCandidate() public {
        pm.setAttack(HostilePoolManager.Attack.DrainEverything);
        _approve(1000e18);
        token.setFailTransferTo(address(pm));

        uint256 tokensBefore = token.balanceOf(VICTIM);
        vm.expectRevert(abi.encodeWithSelector(GraduationHelper.NoCandidateGraduated.selector, 1));
        vm.prank(VICTIM);
        helper.graduateVia{value: 1 ether}(IBondingCurve(address(curve)), _canonical(), 1000e18);

        assertEq(token.balanceOf(VICTIM), tokensBefore, "and costs its caller nothing");
    }

    /// @notice A token that refuses the forwarding transfer reverts the whole call, because
    /// a call that cannot give the tokens back must not end.
    function test_aTokenThatRefusesTheForwardingTransferRevertsTheWholeCall() public {
        _approve(1000e18);
        token.setFailTransferTo(VICTIM);

        vm.expectRevert(GraduationHelper.TokenTransferFailed.selector);
        vm.prank(VICTIM);
        helper.graduateVia(IBondingCurve(address(curve)), _canonical(), 1000e18);
    }

    /// @notice A token that returns true from a transfer it did not perform is caught by the
    /// closing assertion, which is why that assertion runs after the transfers rather than
    /// instead of them.
    function test_aTokenThatLiesAboutTheForwardingTransferTripsTheClosingAssertion() public {
        _approve(1000e18);
        token.setLieTransferTo(VICTIM);

        vm.expectRevert(
            abi.encodeWithSelector(GraduationHelper.BalanceNotZero.selector, 0, 1000e18)
        );
        vm.prank(VICTIM);
        helper.graduateVia(IBondingCurve(address(curve)), _canonical(), 1000e18);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _assertHelperHoldsNothing() private view {
        assertEq(address(helper).balance, 0, "Invariant 68: the helper kept ETH");
        assertEq(token.balanceOf(address(helper)), 0, "Invariant 68: the helper kept tokens");
    }

    /// @dev What an address is down by, floored at zero: a call can leave its caller
    /// ahead, and "loss" is the quantity the bound is about.
    function _loss(uint256 before, uint256 current) private pure returns (uint256) {
        return before > current ? before - current : 0;
    }

    function _approve(uint256 amount) private {
        vm.prank(VICTIM);
        token.approve(address(helper), amount);
    }

    function _canonical() private pure returns (GraduationHelper.Candidate[] memory out) {
        out = new GraduationHelper.Candidate[](1);
        out[0] = GraduationHelper.Candidate({
            fee: PledrinConstants.POOL_FEE,
            tickSpacing: uint24(int24(PledrinConstants.POOL_TICK_SPACING))
        });
    }

    function _forgedKey() private view returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: PledrinConstants.POOL_FEE,
            tickSpacing: PledrinConstants.POOL_TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    /// @dev The three amounts of the one `GraduatedVia` log in the recording.
    function _graduatedVia()
        private
        view
        returns (uint256 bounty, uint256 ethReturned, uint256 tokensReturned)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("GraduatedVia(address,address,uint256,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != topic || logs[i].emitter != address(helper)) continue;
            (, bounty, ethReturned, tokensReturned) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            return (bounty, ethReturned, tokensReturned);
        }
        revert("no GraduatedVia event");
    }
}
