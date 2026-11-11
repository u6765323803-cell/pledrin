// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {CreatorVesting} from "src/CreatorVesting.sol";
import {CurveDeployer} from "src/CurveDeployer.sol";
import {LaunchFactory} from "src/LaunchFactory.sol";
import {LiquidityLock} from "src/LiquidityLock.sol";
import {Timelock} from "src/Timelock.sol";
import {TokenDeployer} from "src/TokenDeployer.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {ILaunchFactory} from "src/interfaces/ILaunchFactory.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {MockPermit2} from "../mocks/MockPermit2.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockPositionManager} from "../mocks/MockPositionManager.sol";

/// @title Shared fixture for the deterministic suite
/// @notice Deploys the whole protocol against the deterministic Uniswap v4 stand-ins of
/// `test/mocks` and provides the launch, trade and graduation helpers every unit, fuzz and
/// invariant test in this suite builds on.
/// @dev No test deriving from this touches the network: CI runs the deterministic suite
/// and the fork suite as separate jobs, and the fork suite is the only place the real
/// Uniswap v4 deployment is read. Where a helper encodes a measured number, the
/// measurement and the fork test that pins it are named in a comment.
abstract contract PledrinTestBase is Test {
    uint16 internal constant DEFAULT_FEE_BPS = 100;
    uint16 internal constant UNPLEDGED_CREATOR_BPS = 3000;
    uint16 internal constant UNPLEDGED_PROTOCOL_BPS = 4000;
    uint16 internal constant UNPLEDGED_PROTECTION_BPS = 3000;
    uint16 internal constant PLEDGED_CREATOR_BPS = 5000;
    uint16 internal constant PLEDGED_PROTOCOL_BPS = 3000;
    uint16 internal constant PLEDGED_PROTECTION_BPS = 2000;

    /// @notice The default `virtualEthReserve` of `docs/SPEC.md` section 15.2.
    uint128 internal constant DEFAULT_VE0 = 5e17;
    /// @notice The default graduation window, 30 days.
    uint32 internal constant DEFAULT_GRAD_WINDOW = 2_592_000;
    /// @notice The default creator vesting cliff, 7 days.
    uint32 internal constant DEFAULT_CLIFF = 604_800;
    /// @notice The default creator vesting duration, 180 days.
    uint32 internal constant DEFAULT_VEST_DURATION = 15_552_000;

    address internal constant TREASURY = address(0xBEEF);
    address internal constant ADMIN = address(0xA11CE);
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant TRADER = address(0xD00D);
    address internal constant OTHER = address(0x5A1E);
    address internal constant GRADUATOR = address(0x6AAD);

    Timelock internal timelock;
    CreatorVesting internal vesting;
    LiquidityLock internal lock;
    CurveDeployer internal curveDeployer;
    TokenDeployer internal tokenDeployer;
    LaunchFactory internal factory;

    MockPoolManager internal poolManager;
    MockPositionManager internal positionManager;
    MockPermit2 internal permit2;

    function setUp() public virtual {
        // A non-zero starting time, so that a schedule's `start` and a timelock's
        // `readyAt` are never confused with "unset".
        vm.warp(1_760_000_000);

        poolManager = new MockPoolManager();
        permit2 = new MockPermit2();
        positionManager = new MockPositionManager(poolManager, permit2);

        timelock = new Timelock(ADMIN);
        vesting = new CreatorVesting();
        lock = new LiquidityLock(IPositionManager(address(positionManager)));
        curveDeployer = new CurveDeployer();
        tokenDeployer = new TokenDeployer();

        factory = new LaunchFactory(
            address(timelock),
            curveDeployer,
            tokenDeployer,
            vesting,
            lock,
            IPoolManager(address(poolManager)),
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(address(permit2)),
            TREASURY,
            defaultFeeConfig()
        );

        vm.deal(CREATOR, 20_000 ether);
        vm.deal(TRADER, 100_000 ether);
        vm.deal(OTHER, 100_000 ether);
        vm.deal(GRADUATOR, 1 ether);
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    function defaultFeeConfig() internal pure returns (ILaunchFactory.FeeConfig memory) {
        return ILaunchFactory.FeeConfig({
            totalFeeBps: DEFAULT_FEE_BPS,
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
        });
    }

    function defaultParams() internal pure returns (ILaunchFactory.LaunchParams memory) {
        return ILaunchFactory.LaunchParams({
            name: "Pledrin Launch",
            symbol: "PLDR",
            virtualEthReserve: DEFAULT_VE0,
            bondWei: 0,
            creatorFirstBuyWei: 0,
            gradWindow: DEFAULT_GRAD_WINDOW,
            creatorVestCliff: DEFAULT_CLIFF,
            creatorVestDuration: DEFAULT_VEST_DURATION,
            metadata: ""
        });
    }

    // ------------------------------------------------------------------
    // Launching
    // ------------------------------------------------------------------

    /// @notice Creates a launch with the default parameters and no bond or first buy.
    function createDefaultLaunch() internal returns (BondingCurve curve, IERC20 token) {
        return createLaunch(defaultParams());
    }

    /// @notice Creates a launch with a bond and a creator first buy, both at their
    /// documented defaults for a pledged launch.
    function createPledgedLaunch() internal returns (BondingCurve curve, IERC20 token) {
        ILaunchFactory.LaunchParams memory params = defaultParams();
        params.bondWei = 0.4 ether;
        params.creatorFirstBuyWei = 0.009 ether;
        return createLaunch(params);
    }

    /// @notice Creates a launch as `CREATOR`, sending exactly bond plus first buy.
    function createLaunch(ILaunchFactory.LaunchParams memory params)
        internal
        returns (BondingCurve curve, IERC20 token)
    {
        return createLaunchFrom(CREATOR, params);
    }

    /// @notice Creates a launch as an arbitrary creator.
    function createLaunchFrom(address who, ILaunchFactory.LaunchParams memory params)
        internal
        returns (BondingCurve curve, IERC20 token)
    {
        uint256 value = uint256(params.bondWei) + params.creatorFirstBuyWei;
        vm.prank(who);
        (address launch, address launchToken) = factory.createLaunch{value: value}(params);
        curve = BondingCurve(payable(launch));
        token = IERC20(launchToken);
    }

    // ------------------------------------------------------------------
    // Trading
    // ------------------------------------------------------------------

    function buy(BondingCurve curve, address who, uint256 value)
        internal
        returns (uint256 tokensOut)
    {
        vm.prank(who);
        return curve.buy{value: value}(0, vm.getBlockTimestamp());
    }

    function sell(BondingCurve curve, address who, uint256 tokensIn)
        internal
        returns (uint256 ethOut)
    {
        IERC20 token = curve.token();
        vm.prank(who);
        token.approve(address(curve), tokensIn);
        vm.prank(who);
        return curve.sell(tokensIn, 0, vm.getBlockTimestamp());
    }

    /// @notice Drives a launch to `tokensSold == CURVE_SUPPLY` with one clipped buy.
    /// @dev A buy larger than the whole remaining supply takes the clipped branch of
    /// `CurveMath.buyQuote`, which charges the exact ETH the remaining tokens cost and
    /// refunds the rest, so one call reaches the cap from any starting point.
    function buyToCap(BondingCurve curve) internal returns (uint256 tokensOut) {
        uint256 value = 4 * uint256(curve.ethTarget());
        vm.deal(TRADER, TRADER.balance + value);
        vm.prank(TRADER);
        tokensOut = curve.buy{value: value}(0, vm.getBlockTimestamp());
        require(curve.tokensSold() == PledrinConstants.CURVE_SUPPLY, "base: cap not reached");
    }

    /// @notice Creates a launch and drives it straight to `Graduating`.
    function createLaunchAtCap() internal returns (BondingCurve curve, IERC20 token) {
        (curve, token) = createDefaultLaunch();
        buyToCap(curve);
    }

    // ------------------------------------------------------------------
    // Accounting views the invariants and unit tests share
    // ------------------------------------------------------------------

    /// @notice Everything a launch's ETH balance is obliged to cover before graduation,
    /// which is Invariant 3.
    function obligations(BondingCurve curve) internal view returns (uint256) {
        return uint256(curve.ethReserve()) + curve.protectionEth() + curve.creatorFeeEth()
            + curve.protocolFeeEth() + curve.bondHeldWei() + curve.pendingBountyTotalWei()
            + curve.pendingBondWei();
    }

    /// @notice `(vE0 + ethReserve) * (vT0 - tokensSold)`, the product of Invariant 1.
    function curveProduct(BondingCurve curve) internal view returns (uint256) {
        (uint256 virtualEth, uint256 virtualTokens) = curve.liveReserves();
        return virtualEth * virtualTokens;
    }

    /// @notice `vE0 * vT0`, the constant Invariant 1 compares the product against.
    function curveK(BondingCurve curve) internal view returns (uint256) {
        return uint256(curve.virtualEthReserve()) * PledrinConstants.VIRTUAL_TOKEN_RESERVE;
    }

    /// @notice The timelock round trip, with every warp target read back out of the
    /// timelock rather than computed from a cached `vm.getBlockTimestamp()`.
    /// @dev Under `via_ir` the optimizer may rematerialise a `TIMESTAMP` read across a
    /// cheatcode call, so a cached timestamp is not reliable after a `vm.warp`. The
    /// comment next to `via_ir` in `foundry.toml` states this.
    function executeAfterDelay(address target, bytes memory data, bytes32 salt) internal {
        vm.prank(ADMIN);
        bytes32 id = timelock.propose(target, data, salt);
        vm.warp(timelock.readyAt(id));
        vm.prank(ADMIN);
        timelock.execute(target, data, salt);
    }

    /// @notice Pauses or unpauses new launches through the timelock.
    function setLaunchesPaused(bool paused) internal {
        executeAfterDelay(
            address(factory),
            abi.encodeCall(LaunchFactory.setLaunchesPaused, (paused)),
            keccak256(abi.encode("pause", paused, vm.getBlockTimestamp()))
        );
    }

    /// @notice Casts a launch's lifecycle state to its enum for an assertion message.
    function stateOf(BondingCurve curve) internal view returns (IBondingCurve.State) {
        return curve.state();
    }
}
