// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {GraduationHelper} from "src/GraduationHelper.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {HostileCurve, HostilePoolManager, RecordingToken} from "../../mocks/HostileGraduation.sol";
import {Actor} from "./Actor.sol";

/// @title The actors that drive the `GraduationHelper` invariant run
/// @notice Several independent callers, each bringing its own ETH and its own token
/// allowance to a helper whose `curve` is hostile, whose PoolManager forges callbacks and
/// re-enters, and into which value is pushed from outside between calls.
/// @dev The whole run is funded once, in the invariant contract's `setUp`, and this handler
/// never mints and never deals. That is what makes conservation assertable: every wei and
/// every base unit in the run belongs to one of a closed set of addresses, so an invariant
/// can add them up and compare against the total. A handler that topped an actor up would
/// make the sum meaningless.
///
/// The ghosts are the four quantities the invariants are about: what each actor has
/// cumulatively brought in each currency, and how much stray value is currently
/// outstanding in the helper. The stray counters are reset by a **successful**
/// `graduateVia`, because that is exactly the specification's claim — stray value does not
/// persist: the next successful call either spends it settling that call's swap or
/// forwards it to that caller.
contract GraduationHelperHandler is CommonBase, StdCheats, StdUtils {
    GraduationHelper public immutable helper;
    HostilePoolManager public immutable poolManager;
    HostileCurve public immutable curve;
    RecordingToken public immutable token;

    Actor[] public actors;

    /// @notice Cumulative `msg.value` each actor has sent into `graduateVia`.
    mapping(address actor => uint256) public broughtEth;
    /// @notice Cumulative `maxTokensIn` each actor has named.
    mapping(address actor => uint256) public broughtTokens;
    /// @notice Stray ETH pushed into the helper and not yet carried out by a success.
    uint256 public strayEthOutstanding;
    /// @notice The same for stray base units of the launch token.
    uint256 public strayTokensOutstanding;

    uint256 public calls;
    uint256 public successes;
    uint256 public strayPushes;

    constructor(
        GraduationHelper helper_,
        HostilePoolManager poolManager_,
        HostileCurve curve_,
        RecordingToken token_,
        Actor[] memory actors_
    ) {
        helper = helper_;
        poolManager = poolManager_;
        curve = curve_;
        token = token_;
        for (uint256 i = 0; i < actors_.length; i++) {
            actors.push(actors_[i]);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 index) external view returns (Actor) {
        return actors[index];
    }

    /// @notice One call to `graduateVia` from one actor, against whichever adversary the
    /// seeds select.
    /// @param actorSeed Which actor calls.
    /// @param value The ETH it brings, bounded by what it holds.
    /// @param maxTokensIn The tokens it brings, bounded by what it holds.
    /// @param attackSeed Which of the PoolManager's attacks runs.
    /// @param curveSeed What the curve does when asked to graduate, and when asked to pay.
    /// @param candidateCount How long a candidate list to walk.
    /// @param approvalMultiple How much more than `maxTokensIn` the actor approves, which
    /// is the allowance a second pull would have to reach for.
    function graduateVia(
        uint256 actorSeed,
        uint256 value,
        uint256 maxTokensIn,
        uint8 attackSeed,
        uint8 curveSeed,
        uint8 candidateCount,
        uint8 approvalMultiple
    ) public {
        Actor actor = actors[actorSeed % actors.length];
        value = bound(value, 0, address(actor).balance);
        maxTokensIn = bound(maxTokensIn, 0, token.balanceOf(address(actor)));
        uint256 approval = maxTokensIn * uint256(bound(approvalMultiple, 1, 4));

        poolManager.setAttack(HostilePoolManager.Attack(attackSeed % 9));
        poolManager.setNesting(_key(), false, curve.sqrtPriceTerminal(), 4);
        poolManager.setReentryTarget(IBondingCurve(address(curve)), _candidates(2));
        curve.setOnGraduate(HostileCurve.OnGraduate(curveSeed % 5));
        curve.setOnClaim(
            HostileCurve.OnClaim((curveSeed / 5) % 5), bound(value, 0, address(curve).balance)
        );
        curve.setReentryCandidates(_candidates(1));

        actor.approve(IERC20(address(token)), address(helper), approval);

        calls++;
        broughtEth[address(actor)] += value;
        broughtTokens[address(actor)] += maxTokensIn;

        (bool ok,) = actor.execute(
            address(helper),
            value,
            abi.encodeCall(
                GraduationHelper.graduateVia,
                (
                    IBondingCurve(address(curve)),
                    _candidates(uint256(bound(candidateCount, 0, 4))),
                    maxTokensIn
                )
            )
        );
        if (ok) {
            successes++;
            // A successful call ends holding nothing, so whatever had been pushed in has
            // either been spent on its swap or forwarded to that caller.
            strayEthOutstanding = 0;
            strayTokensOutstanding = 0;
        }
    }

    /// @notice Pushes ETH into the helper from outside any call of its own, which step 9
    /// requires `receive()` to accept.
    /// @dev Out of this handler's own funded balance rather than an actor's, so that a
    /// push is not counted as somebody's loss.
    function pushStrayEth(uint256 amount) public {
        amount = bound(amount, 0, address(this).balance);
        if (amount == 0) return;

        strayPushes++;
        strayEthOutstanding += amount;
        (bool ok,) = address(helper).call{value: amount}("");
        require(ok, "handler: the helper refused ETH");
    }

    /// @notice The same with base units of the launch token.
    function pushStrayTokens(uint256 amount) public {
        amount = bound(amount, 0, token.balanceOf(address(this)));
        if (amount == 0) return;

        strayPushes++;
        strayTokensOutstanding += amount;
        // forge-lint: disable-next-line(unused-return)
        token.transfer(address(helper), amount);
    }

    /// @notice Moves the price the adversary reports, so some calls restore and some do
    /// not, and some find a key it claims is unopened.
    function movePrice(uint256 seed) public {
        uint160 terminal = curve.sqrtPriceTerminal();
        uint256 choice = seed % 4;
        if (choice == 0) {
            poolManager.setPrice(0);
        } else if (choice == 1) {
            poolManager.setPrice(terminal);
        } else if (choice == 2) {
            poolManager.setPrice(uint160(bound(seed, 1, uint256(terminal) - 1)));
        } else {
            poolManager.setPrice(uint160(bound(seed, uint256(terminal) + 1, type(uint160).max)));
        }
    }

    /// @notice Lets the adversary stop restoring the price, so `PriceNotRestored` is in the
    /// mix as well as the budget refusals.
    function setRestoring(bool restores) public {
        poolManager.setRestoreOnSwap(restores);
    }

    receive() external payable {}

    /// @dev The key the forged payloads name, which is the launch token's canonical key.
    function _key() private view returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: PledrinConstants.POOL_FEE,
            tickSpacing: PledrinConstants.POOL_TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    function _candidates(uint256 count)
        private
        pure
        returns (GraduationHelper.Candidate[] memory out)
    {
        out = new GraduationHelper.Candidate[](count);
        for (uint256 i = 0; i < count; i++) {
            // The first entry is the canonical pair, so it is taken through `graduate`;
            // the rest are permitted alternates, so they are taken through `graduateAlt`.
            out[i] = i == 0
                ? GraduationHelper.Candidate({
                    fee: PledrinConstants.POOL_FEE,
                    tickSpacing: uint24(int24(PledrinConstants.POOL_TICK_SPACING))
                })
                : GraduationHelper.Candidate({fee: 3000, tickSpacing: uint24(10 * i)});
        }
    }
}
