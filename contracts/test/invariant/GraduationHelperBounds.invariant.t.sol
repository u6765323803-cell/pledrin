// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {GraduationHelper} from "src/GraduationHelper.sol";

import {HostileCurve, HostilePoolManager, RecordingToken} from "../mocks/HostileGraduation.sol";
import {Actor} from "./handlers/Actor.sol";
import {GraduationHelperHandler} from "./handlers/GraduationHelperHandler.sol";

/// @title What a caller can lose to `GraduationHelper`, as an invariant
/// @notice **Invariant 68, over random interleavings, against an adversary.** Four actors
/// call `graduateVia` repeatedly, each bringing its own ETH and its own allowance, against
/// a curve that answers with a PoolManager that forges callback payloads, re-enters from
/// inside its settlements and demands every wei the helper holds — while value is pushed
/// into the helper from outside between calls.
///
/// The four invariants are the four claims section 8.6 makes that are statements about a
/// whole history rather than about one call:
///
/// 1. the helper holds nothing except stray value that no successful call has carried out
///    yet, which is the balance clause plus the correction to it;
/// 2. no actor's cumulative loss exceeds the cumulative `msg.value + maxTokensIn` it
///    brought, which is the bound the design rests on;
/// 3. no wei and no base unit is created or destroyed anywhere in the run, which is what
///    makes claim 2 a statement about where value went rather than about one balance;
/// 4. the helper never pulls more than the `maxTokensIn` it was given, however much
///    allowance it is holding, which is the single-upfront-pull claim over a history.
/// @dev The run is funded once, here, and the handler never mints and never deals, which
/// is what lets invariant 3 be an equality. Every address value can reach is in
/// `_totalEth`/`_totalTokens`: the four actors, the helper, the adversary's PoolManager,
/// the adversary's curve and the handler itself.
contract GraduationHelperBoundsInvariant is Test {
    uint160 internal constant TERMINAL = 396_140_812_571_321_687_967_719_751_680_000;

    uint256 internal constant ACTOR_COUNT = 4;
    uint256 internal constant ACTOR_ETH = 50 ether;
    uint256 internal constant ACTOR_TOKENS = 100_000e18;
    uint256 internal constant HANDLER_ETH = 10 ether;
    uint256 internal constant HANDLER_TOKENS = 10_000e18;
    uint256 internal constant CURVE_ETH = 20 ether;
    uint256 internal constant POOL_MANAGER_ETH = 30 ether;

    GraduationHelper internal helper;
    HostilePoolManager internal poolManager;
    HostileCurve internal curve;
    RecordingToken internal token;
    GraduationHelperHandler internal handler;

    Actor[] internal actors;

    uint256 internal initialEth;
    uint256 internal initialTokens;
    mapping(address actor => uint256) internal startingEth;
    mapping(address actor => uint256) internal startingTokens;

    function setUp() public {
        helper = new GraduationHelper();
        poolManager = new HostilePoolManager();
        token = new RecordingToken("Hostile launch", "HOST");
        curve =
            new HostileCurve(IERC20(address(token)), IPoolManager(address(poolManager)), TERMINAL);

        poolManager.setHelper(helper);
        poolManager.setLaunchToken(IERC20(address(token)));
        poolManager.setPrice(TERMINAL / 2);
        curve.setHelper(helper);

        Actor[] memory created = new Actor[](ACTOR_COUNT);
        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            created[i] = new Actor();
            actors.push(created[i]);
            vm.deal(address(created[i]), ACTOR_ETH);
            token.mint(address(created[i]), ACTOR_TOKENS);
            startingEth[address(created[i])] = ACTOR_ETH;
            startingTokens[address(created[i])] = ACTOR_TOKENS;
        }

        handler = new GraduationHelperHandler(helper, poolManager, curve, token, created);
        vm.deal(address(handler), HANDLER_ETH);
        token.mint(address(handler), HANDLER_TOKENS);
        vm.deal(address(curve), CURVE_ETH);
        vm.deal(address(poolManager), POOL_MANAGER_ETH);

        initialEth = _totalEth();
        initialTokens = _totalTokens();

        targetContract(address(handler));
    }

    /// @notice **The balance clause, with the correction.** The helper holds nothing except
    /// value that arrived outside a call of its own and that no successful `graduateVia`
    /// has carried out yet. Once one has, it holds nothing at all.
    function invariant_theHelperHoldsNothingItWasNotPushed() public view {
        assertLe(
            address(helper).balance,
            handler.strayEthOutstanding(),
            "Invariant 68: the helper is holding ETH that a call of its own left behind"
        );
        assertLe(
            token.balanceOf(address(helper)),
            handler.strayTokensOutstanding(),
            "Invariant 68: the helper is holding tokens that a call of its own left behind"
        );
    }

    /// @notice **The bound.** No actor has lost more than the sum of the `msg.value` and
    /// the `maxTokensIn` it brought, whatever the adversary did with either.
    function invariant_noActorLosesMoreThanItBrought() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = address(actors[i]);
            uint256 ethLost = _loss(startingEth[actor], actor.balance);
            uint256 tokensLost = _loss(startingTokens[actor], token.balanceOf(actor));
            assertLe(ethLost, handler.broughtEth(actor), "an actor lost more ETH than it brought");
            assertLe(
                tokensLost,
                handler.broughtTokens(actor),
                "an actor lost more tokens than it brought"
            );
        }
    }

    /// @notice No wei and no base unit is created or lost: every balance in the run adds up
    /// to what was funded at the start.
    function invariant_noWeiAndNoBaseUnitIsCreatedOrLost() public view {
        assertEq(_totalEth(), initialEth, "ETH was created or lost");
        assertEq(_totalTokens(), initialTokens, "base units were created or lost");
    }

    /// @notice The helper never pulls more than the `maxTokensIn` it was asked for, however
    /// much allowance it holds at the time.
    function invariant_theHelperPullsNoMoreThanItWasAskedFor() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = address(actors[i]);
            assertLe(
                token.pulledBy(address(helper), actor),
                handler.broughtTokens(actor),
                "the helper pulled more than the sum of the maxTokensIn it was given"
            );
        }
    }

    /// @notice Reports what the run actually did.
    /// @dev Logging only, for the reason the other invariant contracts give: a reverting
    /// `afterInvariant` is replayed against a clean state under Foundry 1.9.0, so counters
    /// asserted here would all read zero in the failure. The guarantee that the handler is
    /// not inert is `test_theHandlerPerformsRealWork` below.
    function afterInvariant() public view {
        console2.log("graduateVia calls", handler.calls());
        console2.log("  of which returned", handler.successes());
        console2.log("stray pushes into the helper", handler.strayPushes());
        console2.log("stray ETH outstanding", handler.strayEthOutstanding());
        console2.log("stray base units outstanding", handler.strayTokensOutstanding());
    }

    /// @notice The handler is capable of everything the four invariants depend on: a call
    /// that returns, a call that is refused, and value pushed in from outside. Without
    /// this, a green run could be a run in which every call reverted.
    function test_theHandlerPerformsRealWork() public {
        handler.movePrice(2);
        handler.pushStrayEth(1 ether);
        handler.pushStrayTokens(1000e18);
        assertEq(handler.strayPushes(), 2, "the pushes went in");
        assertGt(address(helper).balance, 0, "and the helper is holding them");

        // A call that returns: the adversary behaves, so the walk graduates.
        handler.graduateVia(0, 5 ether, 1000e18, 0, 0, 1, 1);
        assertEq(handler.successes(), 1, "a call that returned");
        assertEq(address(helper).balance, 0, "which swept the stray value out with it");
        assertEq(token.balanceOf(address(helper)), 0, "in both currencies");

        // A call that is refused: the adversary demands more than the caller brought.
        handler.movePrice(2);
        handler.graduateVia(1, 5 ether, 1000e18, 1, 0, 1, 2);
        assertEq(handler.calls(), 2, "two calls");
        assertEq(handler.successes(), 1, "one of which was refused");
    }

    function _totalEth() private view returns (uint256 total) {
        total = address(helper).balance + address(poolManager).balance + address(curve).balance
            + address(handler).balance;
        for (uint256 i = 0; i < actors.length; i++) {
            total += address(actors[i]).balance;
        }
    }

    function _totalTokens() private view returns (uint256 total) {
        total = token.balanceOf(address(helper)) + token.balanceOf(address(poolManager))
            + token.balanceOf(address(curve)) + token.balanceOf(address(handler));
        for (uint256 i = 0; i < actors.length; i++) {
            total += token.balanceOf(address(actors[i]));
        }
    }

    function _loss(uint256 before, uint256 current) private pure returns (uint256) {
        return before > current ? before - current : 0;
    }
}
