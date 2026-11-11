// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {LaunchFactory} from "src/LaunchFactory.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {ILaunchFactory} from "src/interfaces/ILaunchFactory.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {Actor} from "./Actor.sol";

/// @title The actor that drives every invariant run
/// @notice Every externally reachable protocol function is behind one of this contract's
/// methods, so an invariant run is a random interleaving of real user behaviour: buys,
/// sells, donations, the three terminal transitions, all four claims, and the passage of
/// time.
/// @dev The ghost variables exist because some invariants are statements about history
/// rather than about the current state. `feeCharged` and `feePaidOut` are what
/// Invariant 18 compares; `bondPaidOut` and `bondToReserve` are two of the four terms of
/// Invariant 25; `hasLeftLive` and `soldOnLeavingLive` are what the reworded Invariant 31
/// needs. Each is written only when the call it describes actually succeeded, which is why
/// the actors report failure instead of bubbling it.
///
/// `foundry.toml` sets `fail_on_revert = false`, so a reverting call is a legitimate
/// outcome here. What is not legitimate is a call that succeeds and leaves one of the
/// invariants false, and the counters below make it visible how much of the run was real
/// work rather than refusals.
contract ProtocolHandler is CommonBase, StdCheats, StdUtils {
    LaunchFactory public immutable factory;

    BondingCurve[] public launches;
    Actor[] public actors;

    // --- Ghost variables ---

    /// @notice Every wei of fee a launch has ever charged.
    mapping(address launch => uint256) public feeCharged;
    /// @notice Every wei a launch has ever paid out of its three fee buckets.
    mapping(address launch => uint256) public feePaidOut;
    /// @notice Fee a launch charged by a sell made *after* it reached a terminal state.
    /// @dev Tracked separately because where that fee ends up is changing: two of the three
    /// shares accrued this way currently have no payout path, and they are being redirected
    /// into `ethReserve`. Keeping the figure separate lets the fee invariants assert what is
    /// true under either behaviour, and lets the stronger equality be extended to terminal
    /// launches once the redirection lands.
    mapping(address launch => uint256) public feeChargedAfterTerminal;
    /// @notice Bond wei a launch has paid to its creator.
    mapping(address launch => uint256) public bondPaidOut;
    /// @notice Bond wei a launch has moved into its own reserve on expiry.
    mapping(address launch => uint256) public bondToReserve;
    /// @notice Bounty wei a launch has paid out.
    mapping(address launch => uint256) public bountyPaidOut;
    /// @notice Number of times a launch's `bondState` left `Bonded`.
    mapping(address launch => uint256) public bondExits;
    /// @notice `tokensSold` at the moment a launch left `Live`, and whether it has.
    mapping(address launch => uint256) public soldOnLeavingLive;
    mapping(address launch => bool) public hasLeftLive;
    /// @notice The last state each launch was seen in, for terminal stickiness.
    mapping(address launch => IBondingCurve.State) public lastState;
    /// @notice Number of successful graduations per launch.
    mapping(address launch => uint256) public graduationCount;
    /// @notice The terminal state a launch reached, and whether it has reached one.
    mapping(address launch => IBondingCurve.State) public terminalState;
    mapping(address launch => bool) public isTerminal;
    /// @notice Fee wei a launch moved out of its buckets into its own `ethReserve`, which
    /// is what the forfeiture on `expire` and the donation on `abortGraduation` do.
    mapping(address launch => uint256) public feeToReserve;
    /// @notice Holder-protection wei a launch deposited into its floor position at
    /// graduation, which is the other way fee ETH leaves the buckets.
    mapping(address launch => uint256) public protectionToFloor;

    // --- Call counters, reported by the invariant tests ---

    uint256 public buys;
    uint256 public sells;
    uint256 public donations;
    uint256 public graduations;
    uint256 public stalls;
    uint256 public expiries;
    uint256 public claims;
    uint256 public newLaunches;
    uint256 public timeJumps;

    constructor(LaunchFactory factory_, BondingCurve[] memory launches_, uint256 actors_) {
        factory = factory_;
        for (uint256 i = 0; i < launches_.length; i++) {
            launches.push(launches_[i]);
            lastState[address(launches_[i])] = launches_[i].state();
            _recordLaunchTimeFee(launches_[i]);
        }
        for (uint256 i = 0; i < actors_; i++) {
            Actor actor = new Actor();
            vm.deal(address(actor), 20_000 ether);
            actors.push(actor);
        }
    }

    function launchCount() external view returns (uint256) {
        return launches.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function launchAt(uint256 index) external view returns (BondingCurve) {
        return launches[index];
    }

    // ------------------------------------------------------------------
    // Trading
    // ------------------------------------------------------------------

    function buy(uint256 launchSeed, uint256 actorSeed, uint256 value) external {
        BondingCurve curve = _liveLaunch(launchSeed);
        Actor actor = _actor(actorSeed);
        value = bound(value, PledrinConstants.MIN_BUY_WEI, 4 * uint256(curve.ethTarget()));
        if (address(actor).balance < value) return;

        (,, uint256 fee,) = curve.quoteBuy(value);
        _snapshotLiveness(curve);
        (bool ok,) = actor.execute(
            address(curve), value, abi.encodeCall(IBondingCurve.buy, (0, block.timestamp))
        );
        if (!ok) return;

        buys++;
        _recordFee(curve, fee);
        _observe(curve);
    }

    /// @notice A buy large enough to clip at the cap, which is how a run reaches
    /// `Graduating` often enough for the graduation invariants to mean anything.
    function buyToCap(uint256 launchSeed, uint256 actorSeed) external {
        BondingCurve curve = _liveLaunch(launchSeed);
        Actor actor = _actor(actorSeed);
        uint256 value = 4 * uint256(curve.ethTarget());
        if (address(actor).balance < value) return;

        (,, uint256 fee,) = curve.quoteBuy(value);
        _snapshotLiveness(curve);
        (bool ok,) = actor.execute(
            address(curve), value, abi.encodeCall(IBondingCurve.buy, (0, block.timestamp))
        );
        if (!ok) return;

        buys++;
        _recordFee(curve, fee);
        _observe(curve);
    }

    function sell(uint256 launchSeed, uint256 actorSeed, uint256 amount) external {
        Actor actor = _actor(actorSeed);
        BondingCurve curve = _sellableLaunch(launchSeed, actor);
        IERC20 token = curve.token();

        uint256 held = token.balanceOf(address(actor));
        if (held == 0) return;
        amount = bound(amount, 1, held);

        (, uint256 fee,) = curve.quoteSell(amount);
        actor.approve(token, address(curve), amount);
        _snapshotLiveness(curve);
        (bool ok,) = actor.execute(
            address(curve), 0, abi.encodeCall(IBondingCurve.sell, (amount, 0, block.timestamp))
        );
        if (!ok) return;

        sells++;
        _recordFee(curve, fee);
        _observe(curve);
    }

    function donate(uint256 launchSeed, uint256 actorSeed, uint256 value) external {
        BondingCurve curve = _launch(launchSeed);
        Actor actor = _actor(actorSeed);
        value = bound(value, 1, 10 ether);
        if (address(actor).balance < value) return;

        _snapshotLiveness(curve);
        (bool ok,) = actor.execute(address(curve), value, abi.encodeCall(IBondingCurve.donate, ()));
        if (!ok) return;

        donations++;
        _observe(curve);
    }

    // ------------------------------------------------------------------
    // Lifecycle
    // ------------------------------------------------------------------

    function graduate(uint256 launchSeed, uint256 actorSeed) external {
        BondingCurve curve = _launch(launchSeed);
        Actor actor = _actor(actorSeed);

        uint256 protection = curve.protectionEth();
        _snapshotLiveness(curve);
        (bool ok,) = actor.execute(address(curve), 0, abi.encodeCall(IBondingCurve.graduate, ()));
        if (!ok) return;

        protectionToFloor[address(curve)] += protection;
        graduations++;
        graduationCount[address(curve)]++;
        _recordBondExit(curve);
        _observe(curve);
    }

    function graduateAlt(uint256 launchSeed, uint256 actorSeed, uint24 spacing) external {
        BondingCurve curve = _launch(launchSeed);
        Actor actor = _actor(actorSeed);
        spacing = uint24(bound(spacing, 10, 200));

        uint256 protection = curve.protectionEth();
        _snapshotLiveness(curve);
        (bool ok,) =
            actor.execute(address(curve), 0, abi.encodeCall(IBondingCurve.graduateAlt, (spacing)));
        if (!ok) return;

        protectionToFloor[address(curve)] += protection;
        graduations++;
        graduationCount[address(curve)]++;
        _recordBondExit(curve);
        _observe(curve);
    }

    function abortGraduation(uint256 launchSeed, uint256 actorSeed) external {
        BondingCurve curve = _launch(launchSeed);
        Actor actor = _actor(actorSeed);

        uint256 donatedProtection = curve.protectionEth();
        _snapshotLiveness(curve);
        (bool ok,) =
            actor.execute(address(curve), 0, abi.encodeCall(IBondingCurve.abortGraduation, ()));
        if (!ok) return;

        stalls++;
        feeToReserve[address(curve)] += donatedProtection;
        _recordBondExit(curve);
        _observe(curve);
    }

    function expire(uint256 launchSeed, uint256 actorSeed) external {
        BondingCurve curve = _launch(launchSeed);
        Actor actor = _actor(actorSeed);

        uint256 bondBefore = curve.bondHeldWei();
        uint256 forfeitedFees = uint256(curve.creatorFeeEth()) + curve.protectionEth();
        _snapshotLiveness(curve);
        (bool ok,) = actor.execute(address(curve), 0, abi.encodeCall(IBondingCurve.expire, ()));
        if (!ok) return;

        expiries++;
        if (bondBefore != 0) {
            bondExits[address(curve)]++;
            bondToReserve[address(curve)] += bondBefore;
        }
        feeToReserve[address(curve)] += forfeitedFees;
        _observe(curve);
    }

    // ------------------------------------------------------------------
    // Claims
    // ------------------------------------------------------------------

    function claimCreatorFees(uint256 launchSeed, uint256 actorSeed) external {
        BondingCurve curve = _launch(launchSeed);
        uint256 amount = curve.creatorFeeEth();
        (bool ok,) = _actor(actorSeed)
            .execute(address(curve), 0, abi.encodeCall(IBondingCurve.claimCreatorFees, ()));
        if (!ok) return;

        claims++;
        feePaidOut[address(curve)] += amount;
        _observe(curve);
    }

    function claimProtocolFees(uint256 launchSeed, uint256 actorSeed) external {
        BondingCurve curve = _launch(launchSeed);
        uint256 amount = curve.protocolFeeEth();
        (bool ok,) = _actor(actorSeed)
            .execute(address(curve), 0, abi.encodeCall(IBondingCurve.claimProtocolFees, ()));
        if (!ok) return;

        claims++;
        feePaidOut[address(curve)] += amount;
        _observe(curve);
    }

    function claimBond(uint256 launchSeed, uint256 actorSeed) external {
        BondingCurve curve = _launch(launchSeed);
        uint256 amount = curve.pendingBondWei();
        (bool ok,) = _actor(actorSeed)
            .execute(address(curve), 0, abi.encodeCall(IBondingCurve.claimBond, ()));
        if (!ok) return;

        claims++;
        bondPaidOut[address(curve)] += amount;
        _observe(curve);
    }

    function claimBounty(uint256 launchSeed, uint256 actorSeed, uint256 earnerSeed) external {
        BondingCurve curve = _launch(launchSeed);
        address earner = address(_actor(earnerSeed));
        uint256 amount = curve.pendingBountyWei(earner);
        (bool ok,) = _actor(actorSeed)
            .execute(address(curve), 0, abi.encodeCall(IBondingCurve.claimBounty, (earner)));
        if (!ok) return;

        claims++;
        bountyPaidOut[address(curve)] += amount;
        _observe(curve);
    }

    // ------------------------------------------------------------------
    // The world
    // ------------------------------------------------------------------

    /// @notice Moves the clock forward by a short step, so a run spends its depth trading
    /// rather than sitting past every deadline.
    /// @dev Deliberately small. The three windows a launch has — the buy window, the
    /// alternate-key delay and the grace period — are opened by the three functions below
    /// instead, each of which warps to a target read out of the launch's own storage
    /// rather than to a cached timestamp plus a guess.
    function advanceTime(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 1, 6 hours));
        timeJumps++;

        // The actors are topped up here rather than at every trade. An actor that ran out
        // of ETH would stop buying, and a run in which nobody can buy tests nothing; the
        // protocol never reads an actor's balance, so this cannot mask a defect.
        for (uint256 i = 0; i < actors.length; i++) {
            if (address(actors[i]).balance < 2000 ether) {
                vm.deal(address(actors[i]), 20_000 ether);
            }
        }
    }

    /// @notice Warps to the earliest `gradDeadline` still ahead, which is what opens
    /// `expire` for exactly one launch.
    /// @dev The clock only ever advances to the *next* event. Warping to an arbitrary
    /// launch's deadline would take every shorter-lived launch past its own deadline in
    /// one step, and a run that put every launch out of its buy window in its first few
    /// calls would spend the rest of its depth being refused.
    function jumpToNextDeadline() external {
        uint256 target = type(uint256).max;
        for (uint256 i = 0; i < launches.length; i++) {
            BondingCurve candidate = launches[i];
            if (candidate.state() != IBondingCurve.State.Live) continue;
            uint256 deadline = candidate.gradDeadline();
            if (deadline > block.timestamp && deadline < target) target = deadline;
        }
        if (target == type(uint256).max) return;
        vm.warp(target);
        timeJumps++;
    }

    /// @notice Warps to the earliest `capReachedAt + ALT_DELAY` still ahead, which is what
    /// opens `graduateAlt`.
    function jumpToNextAltDelay() external {
        _jumpToNextCapWindow(PledrinConstants.ALT_DELAY);
    }

    /// @notice Warps to the earliest `capReachedAt + GRAD_GRACE` still ahead, which is
    /// what opens `abortGraduation`.
    function jumpToNextGrace() external {
        _jumpToNextCapWindow(PledrinConstants.GRAD_GRACE);
    }

    function _jumpToNextCapWindow(uint256 delay) private {
        uint256 target = type(uint256).max;
        for (uint256 i = 0; i < launches.length; i++) {
            BondingCurve candidate = launches[i];
            if (candidate.state() != IBondingCurve.State.Graduating) continue;
            uint256 ready = uint256(candidate.capReachedAt()) + delay;
            if (ready > block.timestamp && ready < target) target = ready;
        }
        if (target == type(uint256).max) return;
        vm.warp(target);
        timeJumps++;
    }

    /// @notice Adds a launch, so no invariant depends on the fixed set created at setup.
    function createLaunch(uint256 seed, uint256 bondSeed, uint256 firstBuySeed) external {
        if (launches.length >= 8) return;
        // forge-lint: disable-next-line(unused-return)
        _createLaunch(seed, bondSeed, firstBuySeed);
    }

    /// @dev Split from the parameter construction below because `forge coverage` compiles
    /// with the optimizer and the IR pipeline off, and the nine-field launch parameter
    /// struct does not fit on the legacy codegen's stack in the same frame as the call.
    function _createLaunch(uint256 seed, uint256 bondSeed, uint256 firstBuySeed)
        private
        returns (BondingCurve)
    {
        ILaunchFactory.LaunchParams memory params = _paramsFor(seed, bondSeed, firstBuySeed);
        (bool ok, bytes memory ret) = actors[0].execute(
            address(factory),
            uint256(params.bondWei) + params.creatorFirstBuyWei,
            abi.encodeCall(LaunchFactory.createLaunch, (params))
        );
        if (!ok) return BondingCurve(payable(address(0)));

        (address launch,) = abi.decode(ret, (address, address));
        BondingCurve curve = BondingCurve(payable(launch));
        launches.push(curve);
        lastState[launch] = curve.state();
        _recordLaunchTimeFee(curve);
        newLaunches++;
        return curve;
    }

    /// @dev A launch that is sometimes bonded, sometimes carries a creator first buy, and
    /// spans the permitted reserve range, so no invariant depends on one shape of launch.
    function _paramsFor(uint256 seed, uint256 bondSeed, uint256 firstBuySeed)
        private
        pure
        returns (ILaunchFactory.LaunchParams memory params)
    {
        params.name = "Invariant";
        params.symbol = "INV";
        params.virtualEthReserve = uint128(
            bound(
                seed,
                PledrinConstants.MIN_VIRTUAL_ETH_RESERVE,
                PledrinConstants.MAX_VIRTUAL_ETH_RESERVE
            )
        );
        params.gradWindow = uint32(bound(seed, 1 days, 60 days));
        params.creatorVestDuration = PledrinConstants.MIN_VEST_DURATION;

        if (bondSeed % 2 != 0) {
            params.bondWei = uint128(
                bound(
                    bondSeed,
                    PledrinConstants.minBondWei(
                        PledrinConstants.ETH_TARGET_MULTIPLE * uint256(params.virtualEthReserve)
                    ),
                    PledrinConstants.MAX_BOND_WEI
                )
            );
        }
        if (firstBuySeed % 3 != 0) {
            params.creatorFirstBuyWei =
                uint128(bound(firstBuySeed, PledrinConstants.MIN_BUY_WEI, 0.009 ether));
        }
    }

    // ------------------------------------------------------------------

    function _launch(uint256 seed) private view returns (BondingCurve) {
        return launches[seed % launches.length];
    }

    /// @dev The first launch at or after `seed` that is still buyable, and a fresh launch
    /// if none is. A run that let every launch pass its deadline would otherwise spend the
    /// rest of its depth being refused, and an invariant suite over a run of refusals
    /// proves nothing.
    function _liveLaunch(uint256 seed) private returns (BondingCurve) {
        uint256 n = launches.length;
        for (uint256 i = 0; i < n; i++) {
            BondingCurve candidate = launches[(seed % n + i) % n];
            if (
                candidate.state() == IBondingCurve.State.Live
                    && block.timestamp < candidate.gradDeadline()
            ) return candidate;
        }
        if (launches.length < 8) {
            BondingCurve created = _createLaunch(seed, seed >> 8, seed >> 16);
            if (address(created) != address(0)) return created;
        }
        return launches[seed % n];
    }

    /// @dev The first launch at or after `seed` whose token this actor holds and whose
    /// book is open on the sell side.
    function _sellableLaunch(uint256 seed, Actor actor) private view returns (BondingCurve) {
        uint256 n = launches.length;
        for (uint256 i = 0; i < n; i++) {
            BondingCurve candidate = launches[(seed % n + i) % n];
            IBondingCurve.State state = candidate.state();
            bool open = state == IBondingCurve.State.Live || state == IBondingCurve.State.Expired
                || state == IBondingCurve.State.Stalled;
            if (open && candidate.token().balanceOf(address(actor)) != 0) return candidate;
        }
        return launches[seed % n];
    }

    function _actor(uint256 seed) private view returns (Actor) {
        return actors[seed % actors.length];
    }

    /// @dev The creator's first buy is a trade like any other and charges a fee, but it
    /// happens inside `createLaunch` rather than through a handler method. Nothing else has
    /// touched the launch at this point, so its three buckets are exactly that fee.
    function _recordLaunchTimeFee(BondingCurve curve) private {
        feeCharged[address(curve)] += uint256(curve.creatorFeeEth()) + curve.protocolFeeEth()
        + curve.protectionEth();
    }

    function _recordFee(BondingCurve curve, uint256 fee) private {
        feeCharged[address(curve)] += fee;
        if (
            lastState[address(curve)] == IBondingCurve.State.Expired
                || lastState[address(curve)] == IBondingCurve.State.Stalled
        ) {
            feeChargedAfterTerminal[address(curve)] += fee;
        }
    }

    function _recordBondExit(BondingCurve curve) private {
        if (curve.bondState() == IBondingCurve.BondState.Returned && bondExits[address(curve)] == 0)
        {
            bondExits[address(curve)]++;
        }
    }

    /// @dev Reads the state a call is about to act on, which is what `_recordFee` needs to
    /// attribute a fee to the state it was charged in.
    function _snapshotLiveness(BondingCurve curve) private {
        lastState[address(curve)] = curve.state();
    }

    /// @dev Records what leaving `Live` looked like, for the reworded Invariant 31.
    function _observe(BondingCurve curve) private {
        address launch = address(curve);
        IBondingCurve.State current = curve.state();
        if (!hasLeftLive[launch] && current != IBondingCurve.State.Live) {
            hasLeftLive[launch] = true;
            soldOnLeavingLive[launch] = curve.tokensSold();
        }
        if (
            current == IBondingCurve.State.Graduated || current == IBondingCurve.State.Expired
                || current == IBondingCurve.State.Stalled
        ) {
            terminalState[launch] = current;
            isTerminal[launch] = true;
        }
        lastState[launch] = current;
    }
}
