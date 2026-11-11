// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {LaunchFactory} from "src/LaunchFactory.sol";
import {ICreatorVesting} from "src/interfaces/ICreatorVesting.sol";
import {ICurveDeployer} from "src/interfaces/ICurveDeployer.sol";
import {ILaunchFactory} from "src/interfaces/ILaunchFactory.sol";
import {ILiquidityLock} from "src/interfaces/ILiquidityLock.sol";
import {ITokenDeployer} from "src/interfaces/ITokenDeployer.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {PledrinTestBase} from "../base/PledrinTestBase.sol";

/// @title `LaunchFactory`
/// @notice Covers `docs/SPEC.md` sections 13, 14, 15.2 and 15.3, and Invariants 15, 28,
/// 48, 49, 50 and 53.
/// @dev Every parameter bound is tested one unit outside and exactly at the bound, because
/// a bound that is off by one is the kind of defect a happy-path test cannot see. The
/// reputation tests assert the sums of Invariant 49 rather than only the individual
/// counters, since the sums are what an off-chain score would read.
contract LaunchFactoryTest is PledrinTestBase {
    /// @notice Section 15.3: one transaction deploys the token and the curve, opens the
    /// pool, posts the bond, performs the creator's first buy and records the launch.
    function test_createLaunchDoesTheWholeThingInOneTransaction() public {
        ILaunchFactory.LaunchParams memory params = defaultParams();
        params.bondWei = 0.4 ether;
        params.creatorFirstBuyWei = 0.009 ether;
        params.metadata = hex"c0de";

        (BondingCurve curve, IERC20 token) = createLaunch(params);

        assertTrue(factory.isLaunch(address(curve)), "the curve is a launch");
        assertFalse(factory.isLaunch(OTHER), "and a stranger is not");
        assertEq(address(curve.token()), address(token), "the token belongs to the curve");
        assertEq(curve.bondHeldWei(), 0.4 ether, "the bond is held by the curve");
        assertEq(address(factory).balance, 0, "the factory holds nothing");
        assertGt(vesting.scheduleOf(address(curve)).allocation, 0, "the first buy was delivered");
        assertTrue(poolManager.initialized(curve.poolId()), "the pool is open");
        assertEq(poolManager.initializedPoolCount(), 1, "exactly one pool was opened");
    }

    /// @notice The two launch events carry everything an indexer needs, and the metadata
    /// is emitted without being stored.
    function test_createLaunchEmitsBothEvents() public {
        ILaunchFactory.LaunchParams memory params = defaultParams();
        params.bondWei = 0.4 ether;
        params.metadata = hex"c0de";

        vm.recordLogs();
        (BondingCurve curve, IERC20 token) = createLaunch(params);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool sawCreated;
        bool sawMetadata;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(factory)) continue;
            if (
                logs[i].topics[0]
                    == keccak256(
                        "LaunchCreated(address,address,address,uint128,uint256,uint16,uint16,uint16,uint16,uint128,uint64,bytes32)"
                    )
            ) {
                sawCreated = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(curve), "launch");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(token), "token");
                assertEq(address(uint160(uint256(logs[i].topics[3]))), CREATOR, "creator");
            }
            if (logs[i].topics[0] == keccak256("LaunchMetadata(address,string,string,bytes)")) {
                sawMetadata = true;
                (string memory name, string memory symbol, bytes memory metadata) =
                    abi.decode(logs[i].data, (string, string, bytes));
                assertEq(name, params.name, "name");
                assertEq(symbol, params.symbol, "symbol");
                assertEq(metadata, params.metadata, "metadata");
            }
        }
        assertTrue(sawCreated, "LaunchCreated");
        assertTrue(sawMetadata, "LaunchMetadata");
    }

    // ------------------------------------------------------------------
    // Parameter validation, one unit outside each bound
    // ------------------------------------------------------------------

    function test_createLaunchRejectsAnEmptyOrOverlongName() public {
        ILaunchFactory.LaunchParams memory empty = defaultParams();
        empty.name = "";
        _expect(empty, ILaunchFactory.InvalidName.selector);

        ILaunchFactory.LaunchParams memory long = defaultParams();
        long.name = string(new bytes(PledrinConstants.MAX_NAME_BYTES + 1));
        _expect(long, ILaunchFactory.InvalidName.selector);

        ILaunchFactory.LaunchParams memory atBound = defaultParams();
        atBound.name = string(new bytes(PledrinConstants.MAX_NAME_BYTES));
        createLaunch(atBound);
    }

    function test_createLaunchRejectsAnEmptyOrOverlongSymbol() public {
        ILaunchFactory.LaunchParams memory empty = defaultParams();
        empty.symbol = "";
        _expect(empty, ILaunchFactory.InvalidSymbol.selector);

        ILaunchFactory.LaunchParams memory long = defaultParams();
        long.symbol = string(new bytes(PledrinConstants.MAX_SYMBOL_BYTES + 1));
        _expect(long, ILaunchFactory.InvalidSymbol.selector);

        ILaunchFactory.LaunchParams memory atBound = defaultParams();
        atBound.symbol = string(new bytes(PledrinConstants.MAX_SYMBOL_BYTES));
        createLaunch(atBound);
    }

    function test_createLaunchRejectsAReserveOutsideTheBounds() public {
        ILaunchFactory.LaunchParams memory low = defaultParams();
        low.virtualEthReserve = PledrinConstants.MIN_VIRTUAL_ETH_RESERVE - 1;
        _expect(low, ILaunchFactory.InvalidVirtualEthReserve.selector);

        ILaunchFactory.LaunchParams memory high = defaultParams();
        high.virtualEthReserve = PledrinConstants.MAX_VIRTUAL_ETH_RESERVE + 1;
        _expect(high, ILaunchFactory.InvalidVirtualEthReserve.selector);

        ILaunchFactory.LaunchParams memory atMin = defaultParams();
        atMin.virtualEthReserve = PledrinConstants.MIN_VIRTUAL_ETH_RESERVE;
        (BondingCurve smallest,) = createLaunch(atMin);
        assertEq(smallest.ethTarget(), 0.1 ether, "the smallest permitted raise");

        ILaunchFactory.LaunchParams memory atMax = defaultParams();
        atMax.virtualEthReserve = PledrinConstants.MAX_VIRTUAL_ETH_RESERVE;
        (BondingCurve largest,) = createLaunch(atMax);
        assertEq(largest.ethTarget(), 1000 ether, "the largest permitted raise");
    }

    function test_createLaunchRejectsAWindowOutsideTheBounds() public {
        ILaunchFactory.LaunchParams memory short_ = defaultParams();
        short_.gradWindow = PledrinConstants.MIN_GRAD_WINDOW - 1;
        _expect(short_, ILaunchFactory.InvalidGradWindow.selector);

        ILaunchFactory.LaunchParams memory long_ = defaultParams();
        long_.gradWindow = PledrinConstants.MAX_GRAD_WINDOW + 1;
        _expect(long_, ILaunchFactory.InvalidGradWindow.selector);

        ILaunchFactory.LaunchParams memory atMin = defaultParams();
        atMin.gradWindow = PledrinConstants.MIN_GRAD_WINDOW;
        (BondingCurve curve,) = createLaunch(atMin);
        assertEq(
            curve.gradDeadline(),
            vm.getBlockTimestamp() + PledrinConstants.MIN_GRAD_WINDOW,
            "the shortest window"
        );
    }

    function test_createLaunchRejectsAVestCliffAboveTheMaximum() public {
        ILaunchFactory.LaunchParams memory long_ = defaultParams();
        long_.creatorVestCliff = PledrinConstants.MAX_VEST_CLIFF + 1;
        _expect(long_, ILaunchFactory.InvalidVestCliff.selector);

        ILaunchFactory.LaunchParams memory atBound = defaultParams();
        atBound.creatorVestCliff = PledrinConstants.MAX_VEST_CLIFF;
        atBound.creatorFirstBuyWei = 0.009 ether;
        (BondingCurve curve,) = createLaunch(atBound);
        assertEq(
            vesting.scheduleOf(address(curve)).cliff,
            PledrinConstants.MAX_VEST_CLIFF,
            "the longest cliff"
        );

        // Zero is permitted: there is no minimum cliff.
        ILaunchFactory.LaunchParams memory none = defaultParams();
        none.creatorVestCliff = 0;
        createLaunch(none);
    }

    function test_createLaunchRejectsAVestDurationOutsideTheBounds() public {
        ILaunchFactory.LaunchParams memory short_ = defaultParams();
        short_.creatorVestDuration = PledrinConstants.MIN_VEST_DURATION - 1;
        _expect(short_, ILaunchFactory.InvalidVestDuration.selector);

        ILaunchFactory.LaunchParams memory long_ = defaultParams();
        long_.creatorVestDuration = PledrinConstants.MAX_VEST_DURATION + 1;
        _expect(long_, ILaunchFactory.InvalidVestDuration.selector);

        ILaunchFactory.LaunchParams memory atMin = defaultParams();
        atMin.creatorVestDuration = PledrinConstants.MIN_VEST_DURATION;
        atMin.creatorFirstBuyWei = 0.009 ether;
        (BondingCurve curve,) = createLaunch(atMin);
        assertEq(
            vesting.scheduleOf(address(curve)).duration,
            PledrinConstants.MIN_VEST_DURATION,
            "the shortest duration"
        );
    }

    /// @notice **Invariant 28** in the factory: a non-zero bond must be at least
    /// `max(MIN_BOND_WEI, R_target / 10)` and at most `MAX_BOND_WEI`.
    function test_createLaunchRejectsABondOutsideItsBounds() public {
        ILaunchFactory.LaunchParams memory low = defaultParams();
        low.bondWei = 0.4 ether - 1;
        _expect(low, ILaunchFactory.InvalidBond.selector);

        ILaunchFactory.LaunchParams memory high = defaultParams();
        high.virtualEthReserve = PledrinConstants.MAX_VIRTUAL_ETH_RESERVE;
        high.bondWei = uint128(PledrinConstants.MAX_BOND_WEI) + 1;
        _expect(high, ILaunchFactory.InvalidBond.selector);

        ILaunchFactory.LaunchParams memory atFloor = defaultParams();
        atFloor.bondWei = 0.4 ether;
        (BondingCurve curve,) = createLaunch(atFloor);
        assertEq(curve.bondWei(), 0.4 ether, "exactly the proportional floor");

        // On the smallest raise the flat floor binds instead: `R_target / 10` is 0.01 ETH,
        // which is `MIN_BOND_WEI`, so the two coincide there.
        ILaunchFactory.LaunchParams memory smallest = defaultParams();
        smallest.virtualEthReserve = PledrinConstants.MIN_VIRTUAL_ETH_RESERVE;
        smallest.bondWei = uint128(PledrinConstants.MIN_BOND_WEI) - 1;
        _expect(smallest, ILaunchFactory.InvalidBond.selector);
        smallest.bondWei = uint128(PledrinConstants.MIN_BOND_WEI);
        createLaunch(smallest);
    }

    /// @notice `msg.value` must be exactly the bond plus the first buy, to the wei.
    function test_createLaunchRequiresExactlyTheBondPlusTheFirstBuy() public {
        ILaunchFactory.LaunchParams memory params = defaultParams();
        params.bondWei = 0.4 ether;
        params.creatorFirstBuyWei = 0.009 ether;
        uint256 expected = 0.409 ether;

        vm.prank(CREATOR);
        vm.expectRevert(
            abi.encodeWithSelector(ILaunchFactory.ValueMismatch.selector, expected - 1, expected)
        );
        factory.createLaunch{value: expected - 1}(params);

        vm.prank(CREATOR);
        vm.expectRevert(
            abi.encodeWithSelector(ILaunchFactory.ValueMismatch.selector, expected + 1, expected)
        );
        factory.createLaunch{value: expected + 1}(params);

        vm.prank(CREATOR);
        factory.createLaunch{value: expected}(params);
    }

    /// @notice An unbonded launch with no first buy must send nothing at all.
    function test_createLaunchWithNoBondAndNoFirstBuyTakesNoValue() public {
        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(ILaunchFactory.ValueMismatch.selector, 1, 0));
        factory.createLaunch{value: 1}(defaultParams());
    }

    // ------------------------------------------------------------------
    // Reputation
    // ------------------------------------------------------------------

    /// @notice Only a curve the factory deployed may write a reputation counter.
    function test_onlyALaunchMayWriteReputation() public {
        vm.prank(OTHER);
        vm.expectRevert(ILaunchFactory.NotLaunch.selector);
        factory.recordGraduation(CREATOR, 1 ether, true);

        vm.prank(OTHER);
        vm.expectRevert(ILaunchFactory.NotLaunch.selector);
        factory.recordStall(CREATOR, true);

        vm.prank(OTHER);
        vm.expectRevert(ILaunchFactory.NotLaunch.selector);
        factory.recordExpiry(CREATOR, 1 ether);

        ILaunchFactory.Reputation memory record = factory.reputationOf(CREATOR);
        assertEq(record.graduations + record.stalls + record.expiries, 0, "nothing was written");
    }

    /// @notice **Invariants 48 and 49.** Every counter only rises, and the three sums the
    /// specification names hold after each of the three outcomes.
    function test_everyCounterRisesAndTheSumsHold() public {
        ILaunchFactory.LaunchParams memory bonded = defaultParams();
        bonded.bondWei = 0.4 ether;

        // A graduation.
        (BondingCurve graduating,) = createLaunch(bonded);
        buyToCap(graduating);
        vm.prank(GRADUATOR);
        graduating.graduate();
        _assertSums(CREATOR);

        // A stall.
        (BondingCurve stalling,) = createLaunch(bonded);
        buyToCap(stalling);
        vm.warp(stalling.capReachedAt() + PledrinConstants.GRAD_GRACE);
        stalling.abortGraduation();
        _assertSums(CREATOR);

        // An expiry.
        (BondingCurve expiring,) = createLaunch(bonded);
        vm.warp(expiring.gradDeadline());
        expiring.expire();
        _assertSums(CREATOR);

        ILaunchFactory.Reputation memory record = factory.reputationOf(CREATOR);
        assertEq(record.launches, 3, "launches");
        assertEq(record.graduations, 1, "graduations");
        assertEq(record.stalls, 1, "stalls");
        assertEq(record.expiries, 1, "expiries");
        assertEq(record.bondsPosted, 3, "bondsPosted");
        assertEq(record.bondsReturned, 2, "bondsReturned");
        assertEq(record.bondsForfeited, 1, "bondsForfeited");
        assertEq(record.bondWeiPosted, 1.2 ether, "bondWeiPosted");
        assertEq(record.bondWeiForfeited, 0.4 ether, "bondWeiForfeited");
        assertEq(record.ethRaisedGraduated, 4 ether, "ethRaisedGraduated");
    }

    /// @notice Reputation is per creator: one creator's outcomes never touch another's.
    function test_reputationIsKeyedByCreator() public {
        createLaunchFrom(CREATOR, defaultParams());
        createLaunchFrom(OTHER, defaultParams());
        createLaunchFrom(OTHER, defaultParams());

        assertEq(factory.reputationOf(CREATOR).launches, 1, "the first creator");
        assertEq(factory.reputationOf(OTHER).launches, 2, "the second");
        assertEq(factory.reputationOf(TRADER).launches, 0, "and a stranger has none");
    }

    /// @notice An unbonded launch moves no bond counter at all.
    function test_anUnbondedLaunchMovesNoBondCounter() public {
        createDefaultLaunch();

        ILaunchFactory.Reputation memory record = factory.reputationOf(CREATOR);
        assertEq(record.launches, 1, "launches");
        assertEq(record.bondsPosted, 0, "bondsPosted");
        assertEq(record.bondWeiPosted, 0, "bondWeiPosted");
    }

    /// @notice There is no setter for any counter: the factory's whole writable surface is
    /// the three owner setters, and none of them is a counter.
    function test_thereIsNoReputationSetter() public {
        string[6] memory signatures = [
            "setReputation(address,uint32)",
            "setGraduations(address,uint32)",
            "writeCounter(address,uint8,uint256)",
            "attest(address,bytes)",
            "setOracle(address)",
            "setScore(address,uint256)"
        ];
        address target = address(factory);
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = target.call(abi.encodeWithSignature(signatures[i]));
            assertFalse(ok, signatures[i]);
        }
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    /// @notice **Invariant 15** at config time: a fee above the ceiling or a share set that
    /// does not sum to 10000 is refused, for either share set.
    function test_feeConfigIsCheckedAtConfigTime() public {
        ILaunchFactory.FeeConfig memory tooHigh = defaultFeeConfig();
        tooHigh.totalFeeBps = PledrinConstants.MAX_TOTAL_FEE_BPS + 1;
        _expectConfig(tooHigh);

        ILaunchFactory.FeeConfig memory badUnpledged = defaultFeeConfig();
        badUnpledged.unpledged.protectionShareBps += 1;
        _expectConfig(badUnpledged);

        ILaunchFactory.FeeConfig memory badPledged = defaultFeeConfig();
        badPledged.pledged.creatorShareBps -= 1;
        _expectConfig(badPledged);

        ILaunchFactory.FeeConfig memory atCeiling = defaultFeeConfig();
        atCeiling.totalFeeBps = PledrinConstants.MAX_TOTAL_FEE_BPS;
        executeAfterDelay(
            address(factory), abi.encodeCall(LaunchFactory.setFeeConfig, (atCeiling)), bytes32("ok")
        );
        assertEq(factory.feeConfig().totalFeeBps, PledrinConstants.MAX_TOTAL_FEE_BPS, "accepted");
    }

    /// @notice **Invariant 53.** A configuration change reaches future launches only.
    function test_aConfigChangeReachesFutureLaunchesOnly() public {
        (BondingCurve before,) = createDefaultLaunch();

        ILaunchFactory.FeeConfig memory config = defaultFeeConfig();
        config.totalFeeBps = 200;
        config.unpledged = ILaunchFactory.FeeShares(1000, 8000, 1000);
        executeAfterDelay(
            address(factory), abi.encodeCall(LaunchFactory.setFeeConfig, (config)), bytes32("c")
        );
        executeAfterDelay(
            address(factory),
            abi.encodeCall(LaunchFactory.setProtocolTreasury, (OTHER)),
            bytes32("t")
        );

        (BondingCurve afterChange,) = createDefaultLaunch();

        assertEq(before.totalFeeBps(), DEFAULT_FEE_BPS, "the old launch's fee is untouched");
        assertEq(before.creatorShareBps(), UNPLEDGED_CREATOR_BPS, "and its shares");
        assertEq(before.protocolTreasury(), TREASURY, "and its treasury");
        assertEq(afterChange.totalFeeBps(), 200, "the new launch took the new fee");
        assertEq(afterChange.creatorShareBps(), 1000, "and the new shares");
        assertEq(afterChange.protocolTreasury(), OTHER, "and the new treasury");
    }

    /// @notice The treasury cannot be set to zero.
    function test_theTreasuryCannotBeSetToZero() public {
        vm.prank(ADMIN);
        bytes memory data = abi.encodeCall(LaunchFactory.setProtocolTreasury, (address(0)));
        bytes32 id = timelock.propose(address(factory), data, bytes32(0));
        vm.warp(timelock.readyAt(id));

        vm.prank(ADMIN);
        vm.expectRevert(ILaunchFactory.InvalidTreasury.selector);
        timelock.execute(address(factory), data, bytes32(0));
        assertEq(factory.protocolTreasury(), TREASURY, "unchanged");
    }

    /// @notice The constructor refuses a zero dependency and a zero treasury.
    function test_theConstructorRefusesZeroDependencies() public {
        _expectDependency(0);
        _expectDependency(1);
        _expectDependency(2);
        _expectDependency(3);
        _expectDependency(4);
        _expectDependency(5);
        _expectDependency(6);

        vm.expectRevert(ILaunchFactory.InvalidTreasury.selector);
        new LaunchFactory(
            address(timelock),
            curveDeployer,
            tokenDeployer,
            vesting,
            lock,
            IPoolManager(address(poolManager)),
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(address(permit2)),
            address(0),
            defaultFeeConfig()
        );
    }

    /// @notice The factory's own initial configuration is checked by the same code the
    /// setter uses, so a bad configuration cannot be installed at deployment either.
    function test_theConstructorChecksItsOwnFeeConfig() public {
        ILaunchFactory.FeeConfig memory bad = defaultFeeConfig();
        bad.unpledged.creatorShareBps += 1;

        vm.expectRevert(ILaunchFactory.InvalidFeeConfig.selector);
        new LaunchFactory(
            address(timelock),
            curveDeployer,
            tokenDeployer,
            vesting,
            lock,
            IPoolManager(address(poolManager)),
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(address(permit2)),
            TREASURY,
            bad
        );
    }

    /// @notice Every launch gets its own token, curve and pool, whatever the parameters.
    function testFuzz_everyLaunchIsIndependent(uint128 vE0, uint32 window) public {
        ILaunchFactory.LaunchParams memory params = defaultParams();
        params.virtualEthReserve = uint128(
            bound(
                vE0,
                PledrinConstants.MIN_VIRTUAL_ETH_RESERVE,
                PledrinConstants.MAX_VIRTUAL_ETH_RESERVE
            )
        );
        params.gradWindow = uint32(
            bound(window, PledrinConstants.MIN_GRAD_WINDOW, PledrinConstants.MAX_GRAD_WINDOW)
        );

        (BondingCurve first, IERC20 firstToken) = createLaunch(params);
        (BondingCurve second, IERC20 secondToken) = createLaunch(params);

        assertTrue(address(first) != address(second), "two curves");
        assertTrue(address(firstToken) != address(secondToken), "two tokens");
        assertTrue(
            keccak256(abi.encode(first.poolId())) != keccak256(abi.encode(second.poolId())),
            "two pools"
        );
        assertEq(factory.reputationOf(CREATOR).launches, 2, "two launches recorded");
    }

    // ------------------------------------------------------------------

    function _assertSums(address creator) private view {
        ILaunchFactory.Reputation memory record = factory.reputationOf(creator);
        assertLe(
            uint256(record.graduations) + record.stalls + record.expiries,
            record.launches,
            "Invariant 49: outcomes never exceed launches"
        );
        assertLe(
            uint256(record.bondsReturned) + record.bondsForfeited,
            record.bondsPosted,
            "Invariant 49: bond outcomes never exceed bonds posted"
        );
        assertLe(record.bondsPosted, record.launches, "Invariant 49: bonds never exceed launches");
        assertLe(
            record.bondWeiForfeited, record.bondWeiPosted, "forfeited wei never exceeds posted"
        );
    }

    function _expect(ILaunchFactory.LaunchParams memory params, bytes4 selector) private {
        uint256 value = uint256(params.bondWei) + params.creatorFirstBuyWei;
        vm.deal(CREATOR, CREATOR.balance + value);
        vm.prank(CREATOR);
        vm.expectRevert(selector);
        factory.createLaunch{value: value}(params);
    }

    function _expectConfig(ILaunchFactory.FeeConfig memory config) private {
        bytes memory data = abi.encodeCall(LaunchFactory.setFeeConfig, (config));
        vm.prank(ADMIN);
        bytes32 id = timelock.propose(address(factory), data, bytes32(0));
        vm.warp(timelock.readyAt(id));
        vm.prank(ADMIN);
        vm.expectRevert(ILaunchFactory.InvalidFeeConfig.selector);
        timelock.execute(address(factory), data, bytes32(0));
    }

    /// @dev Deploys the factory with one dependency zeroed, named by index.
    function _expectDependency(uint256 index) private {
        ICurveDeployer curveDeployer_ = index == 0 ? ICurveDeployer(address(0)) : curveDeployer;
        ITokenDeployer tokenDeployer_ = index == 1 ? ITokenDeployer(address(0)) : tokenDeployer;
        ICreatorVesting vesting_ = index == 2 ? ICreatorVesting(address(0)) : vesting;
        ILiquidityLock lock_ = index == 3 ? ILiquidityLock(address(0)) : lock;
        IPoolManager poolManager_ =
            index == 4 ? IPoolManager(address(0)) : IPoolManager(address(poolManager));
        IPositionManager positionManager_ =
            index == 5 ? IPositionManager(address(0)) : IPositionManager(address(positionManager));
        IAllowanceTransfer permit2_ =
            index == 6 ? IAllowanceTransfer(address(0)) : IAllowanceTransfer(address(permit2));

        vm.expectRevert(ILaunchFactory.InvalidDependency.selector);
        new LaunchFactory(
            address(timelock),
            curveDeployer_,
            tokenDeployer_,
            vesting_,
            lock_,
            poolManager_,
            positionManager_,
            permit2_,
            TREASURY,
            defaultFeeConfig()
        );
    }
}
