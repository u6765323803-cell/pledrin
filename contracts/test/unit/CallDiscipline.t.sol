// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {ICreatorVesting} from "src/interfaces/ICreatorVesting.sol";
import {ILiquidityLock} from "src/interfaces/ILiquidityLock.sol";
import {ITokenDeployer} from "src/interfaces/ITokenDeployer.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {PledrinTestBase} from "../base/PledrinTestBase.sol";
import {RogueCurveDeployer} from "../helpers/RogueCurveDeployer.sol";
import {CurveSnapshot, ProbeFactory, ProbeVesting, StateSnapshotter} from "../mocks/CallProbes.sol";

/// @title Invariant 55: reentrancy guards and call discipline
/// @notice Covers all three parts of the reworded Invariant 55 of `docs/SPEC.md`
/// section 17, and Invariant 30's enforcement mechanism.
/// @dev Parts (b) and (c) are statements about what an external call made by the launch
/// can observe, so each is tested by *being* that call: the launch's dependencies are
/// replaced with probes that read the launch's whole storage at the moment they are
/// invoked. Part (a) is tested by having one of those probes attempt to re-enter.
///
/// The strong form of (c) — no storage write after any external call — is not achievable
/// in `graduate`, `graduateAlt` or `createLaunch`, and the specification no longer claims
/// it is: graduation has to read how much ETH the core mint consumed before it can compute
/// `floorEth`. What is enforced, and what is asserted here, is that `state` is terminal
/// before the first call out and that every other write is complete before the last one.
contract CallDisciplineTest is PledrinTestBase {
    RogueCurveDeployer internal deployer;
    ProbeVesting internal probeVesting;
    ProbeFactory internal probeFactory;

    function setUp() public override {
        super.setUp();
        deployer = new RogueCurveDeployer();
        probeVesting = new ProbeVesting();
        probeFactory = new ProbeFactory();
    }

    // ------------------------------------------------------------------
    // (b) `state` is terminal before the first external call
    // ------------------------------------------------------------------

    /// @notice Invariant 55(b) for `graduate`: `state` is already `Graduated` when the
    /// first external call of the graduation — the core mint — runs.
    function test_graduationIsAlreadyGraduatedWhenItFirstCallsOut() public {
        (BondingCurve curve,) = createLaunchAtCap();
        StateSnapshotter snapshotter = new StateSnapshotter();
        positionManager.setProbe(
            address(snapshotter), abi.encodeCall(StateSnapshotter.snapshot, (address(curve)))
        );

        vm.prank(GRADUATOR);
        curve.graduate();

        assertEq(snapshotter.count(), 2, "one snapshot per mint");
        CurveSnapshot memory duringCoreMint = snapshotter.snapshotAt(0);
        assertEq(
            duringCoreMint.state,
            uint8(IBondingCurve.State.Graduated),
            "Invariant 55(b): terminal before the first call out"
        );
        assertEq(duringCoreMint.graduatedAt, vm.getBlockTimestamp(), "graduatedAt is written too");
    }

    /// @notice Invariant 55(c) for `graduate`: by the floor mint — the last call that
    /// precedes only state-free calls and the event — every storage write is complete.
    function test_everyGraduationWriteIsCompleteBeforeTheFloorMint() public {
        (BondingCurve curve,) = createPledgedLaunch();
        buyToCap(curve);

        StateSnapshotter snapshotter = new StateSnapshotter();
        positionManager.setProbe(
            address(snapshotter), abi.encodeCall(StateSnapshotter.snapshot, (address(curve)))
        );

        vm.prank(GRADUATOR);
        curve.graduate();

        CurveSnapshot memory duringFloorMint = snapshotter.snapshotAt(1);
        assertEq(duringFloorMint.state, uint8(IBondingCurve.State.Graduated), "state");
        assertEq(duringFloorMint.ethReserve, 0, "ethReserve was already zeroed");
        assertEq(duringFloorMint.protectionEth, 0, "protectionEth was already zeroed");
        assertEq(duringFloorMint.bondHeldWei, 0, "the bond had already left the bond account");
        assertEq(
            duringFloorMint.bondState,
            uint8(IBondingCurve.BondState.Returned),
            "bondState was already final"
        );
        assertEq(duringFloorMint.pendingBondWei, curve.pendingBondWei(), "pendingBondWei was final");
        assertEq(
            duringFloorMint.pendingBountyTotalWei,
            curve.pendingBountyTotalWei(),
            "the bounty credit was final"
        );
        assertEq(
            duringFloorMint.protocolFeeEth, curve.protocolFeeEth(), "the protocol bucket was final"
        );
        assertEq(duringFloorMint.tokensSold, curve.tokensSold(), "tokensSold was final");
    }

    /// @notice Invariant 55(b) and (c) for `expire`, observed from the vesting contract the
    /// launch calls as it finishes.
    function test_expireIsFinishedWritingBeforeItCallsOut() public {
        BondingCurve curve = _probeLaunch(0.4 ether);
        vm.deal(TRADER, 10 ether);
        vm.prank(TRADER);
        curve.buy{value: 1 ether}(0, vm.getBlockTimestamp());

        uint256 expectedReserve = uint256(curve.ethReserve()) + curve.bondHeldWei()
            + curve.creatorFeeEth() + curve.protectionEth();

        vm.warp(curve.gradDeadline());
        curve.expire();

        CurveSnapshot memory atVoid = probeVesting.voidSnapshot();
        assertEq(probeVesting.voidCalls(), 1, "the vesting was told once");
        assertEq(atVoid.state, uint8(IBondingCurve.State.Expired), "Invariant 55(b)");
        assertEq(atVoid.ethReserve, expectedReserve, "the forfeiture was already credited");
        assertEq(atVoid.creatorFeeEth, 0, "the creator bucket was already zeroed");
        assertEq(atVoid.protectionEth, 0, "the protection bucket was already zeroed");
        assertEq(atVoid.bondHeldWei, 0, "the bond account was already emptied");
        assertEq(atVoid.bondState, uint8(IBondingCurve.BondState.Forfeited), "bondState was final");

        CurveSnapshot memory atRecord = probeFactory.recordSnapshot();
        assertEq(probeFactory.recordCalls(), 1, "the factory was told once");
        assertEq(atRecord.state, uint8(IBondingCurve.State.Expired), "state at the last call");
        assertEq(atRecord.ethReserve, expectedReserve, "and the reserve at the last call");
    }

    /// @notice Invariant 55(b) and (c) for `abortGraduation`.
    function test_abortGraduationIsFinishedWritingBeforeItCallsOut() public {
        BondingCurve curve = _probeLaunch(0.4 ether);
        vm.deal(TRADER, 100 ether);
        vm.prank(TRADER);
        curve.buy{value: 16 ether}(0, vm.getBlockTimestamp());
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduating), "at the cap");

        uint256 expectedReserve = uint256(curve.ethReserve()) + curve.protectionEth();
        uint256 bond = curve.bondHeldWei();

        vm.warp(curve.capReachedAt() + PledrinConstants.GRAD_GRACE);
        curve.abortGraduation();

        CurveSnapshot memory atStart = probeVesting.startSnapshot();
        assertEq(probeVesting.startCalls(), 1, "the vesting clock was started once");
        assertEq(atStart.state, uint8(IBondingCurve.State.Stalled), "Invariant 55(b)");
        assertEq(atStart.ethReserve, expectedReserve, "the protection pool was already donated");
        assertEq(atStart.protectionEth, 0, "and its bucket zeroed");
        assertEq(atStart.bondHeldWei, 0, "the bond had already left the bond account");
        assertEq(atStart.pendingBondWei, bond, "and was already credited to the creator");
        assertEq(atStart.bondState, uint8(IBondingCurve.BondState.Returned), "bondState");
    }

    // ------------------------------------------------------------------
    // (a) reentrancy guards
    // ------------------------------------------------------------------

    /// @notice Invariant 55(a) for `graduate`: a call that re-enters the launch from inside
    /// the graduation's own mint is refused by the guard, whichever entry point it picks.
    function test_graduationCannotBeReenteredThroughAnyEntryPoint() public {
        _assertReentryIsRefused(abi.encodeCall(IBondingCurve.graduate, ()));
        _assertReentryIsRefused(abi.encodeCall(IBondingCurve.donate, ()));
        _assertReentryIsRefused(abi.encodeCall(IBondingCurve.claimProtocolFees, ()));
        _assertReentryIsRefused(
            abi.encodeCall(IBondingCurve.graduateAlt, (PledrinConstants.POOL_FEE, 100))
        );
        _assertReentryIsRefused(abi.encodeCall(IBondingCurve.abortGraduation, ()));
        _assertReentryIsRefused(abi.encodeCall(IBondingCurve.expire, ()));
    }

    /// @notice The same for `sell`, which is the other function that hands control to an
    /// address the caller chooses while holding the guard.
    function test_sellCannotBeReenteredThroughAnyEntryPoint() public {
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        GuardProbe probe = new GuardProbe();
        vm.deal(address(probe), 10 ether);
        probe.buy(IBondingCurve(address(curve)), token, 1 ether);

        probe.setReentry(abi.encodeCall(IBondingCurve.donate, ()));
        vm.expectRevert();
        probe.sell(1e18);

        assertEq(curve.tokensSold(), probe.bought(), "nothing was sold");
    }

    // ------------------------------------------------------------------

    function _assertReentryIsRefused(bytes memory call) private {
        (BondingCurve curve,) = createLaunchAtCap();
        positionManager.setProbe(address(curve), call);

        vm.prank(GRADUATOR);
        curve.graduate();

        assertTrue(positionManager.probeCalled(), "the probe ran");
        assertFalse(positionManager.probeSucceeded(), "Invariant 55(a): the re-entry failed");
        assertEq(
            bytes4(positionManager.probeReturn()),
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
            "and failed on the guard rather than on anything else"
        );
        positionManager.setProbe(address(0), "");
    }

    /// @dev A launch whose vesting and factory are probes. It cannot be created through
    /// the real factory, which hands every launch the one real vesting singleton, so it is
    /// deployed directly with the factory address it will report to.
    function _probeLaunch(uint128 bondWei) private returns (BondingCurve curve) {
        vm.deal(OTHER, OTHER.balance + bondWei);
        vm.prank(OTHER);
        curve = BondingCurve(
            payable(deployer.deploy{value: bondWei}(
                    address(probeFactory),
                    IBondingCurve.CurveConfig({
                        creator: CREATOR,
                        protocolTreasury: TREASURY,
                        tokenDeployer: ITokenDeployer(address(tokenDeployer)),
                        vesting: ICreatorVesting(address(probeVesting)),
                        liquidityLock: ILiquidityLock(address(lock)),
                        poolManager: IPoolManager(address(poolManager)),
                        positionManager: IPositionManager(address(positionManager)),
                        permit2: IAllowanceTransfer(address(permit2)),
                        virtualEthReserve: DEFAULT_VE0,
                        bondWei: bondWei,
                        gradWindow: DEFAULT_GRAD_WINDOW,
                        totalFeeBps: DEFAULT_FEE_BPS,
                        creatorShareBps: UNPLEDGED_CREATOR_BPS,
                        protocolShareBps: UNPLEDGED_PROTOCOL_BPS,
                        protectionShareBps: UNPLEDGED_PROTECTION_BPS,
                        name: "Probe",
                        symbol: "PRB"
                    })
                ))
        );
    }
}

/// @notice A trader that re-enters the launch from its ETH callback with a call the test
/// chooses.
contract GuardProbe {
    IBondingCurve private _curve;
    IERC20 private _token;
    bytes private _reentry;
    uint256 public bought;

    receive() external payable {
        if (_reentry.length == 0) return;
        bytes memory call = _reentry;
        _reentry = "";
        (bool ok, bytes memory ret) = address(_curve).call(call);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function buy(IBondingCurve curve, IERC20 token, uint256 value) external {
        _curve = curve;
        _token = token;
        bought = curve.buy{value: value}(0, block.timestamp);
        token.approve(address(curve), type(uint256).max);
    }

    function setReentry(bytes calldata call) external {
        _reentry = call;
    }

    function sell(uint256 amount) external {
        _curve.sell(amount, 0, block.timestamp);
    }
}
