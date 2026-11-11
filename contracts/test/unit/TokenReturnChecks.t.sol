// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
import {FakeLaunch} from "../mocks/Actors.sol";
import {ProbeFactory} from "../mocks/CallProbes.sol";
import {ConfigurableToken, ConfigurableTokenDeployer} from "../mocks/ConfigurableToken.sol";

/// @title Every launch-token call is checked against the boolean it returns
/// @notice Covers the `TokenTransferFailed` paths of `BondingCurve` and `CreatorVesting`,
/// which exist because the ERC-20 standard permits a token to report failure by returning
/// `false` rather than by reverting.
/// @dev `PledrinToken` can never return `false`, so a launch the factory created cannot
/// reach these lines; the test deploys a curve directly against a token that can. That is
/// not a hypothetical: the wrappers are there precisely so that a launch token which
/// silently fails cannot be mistaken for one that succeeded, and an unchecked return would
/// let a buy credit a buyer with tokens they never received.
contract TokenReturnChecksTest is PledrinTestBase {
    RogueCurveDeployer internal deployer;
    ConfigurableTokenDeployer internal badDeployer;
    ProbeFactory internal probeFactory;

    function setUp() public override {
        super.setUp();
        deployer = new RogueCurveDeployer();
        badDeployer = new ConfigurableTokenDeployer();
        probeFactory = new ProbeFactory();
    }

    /// @notice A `transfer` that reports failure makes the whole buy revert, so no buyer is
    /// ever credited with tokens that did not move.
    function test_aBuyRevertsWhenTheTokenTransferReportsFailure() public {
        (BondingCurve curve, ConfigurableToken token) = _launchWithConfigurableToken();

        token.setFailTransfer(true);
        vm.deal(OTHER, 10 ether);
        vm.prank(OTHER);
        vm.expectRevert(IBondingCurve.TokenTransferFailed.selector);
        curve.buy{value: 1 ether}(0, vm.getBlockTimestamp());

        assertEq(curve.tokensSold(), 0, "no state survived the failure");
        assertEq(curve.ethReserve(), 0, "and no ETH reached the reserve");

        token.setFailTransfer(false);
        vm.prank(OTHER);
        assertGt(curve.buy{value: 1 ether}(0, vm.getBlockTimestamp()), 0, "and it works again");
    }

    /// @notice A `transferFrom` that reports failure makes the whole sell revert, so the
    /// curve never pays for tokens it did not receive.
    function test_aSellRevertsWhenTheTokenPullReportsFailure() public {
        (BondingCurve curve, ConfigurableToken token) = _launchWithConfigurableToken();

        vm.deal(OTHER, 10 ether);
        vm.prank(OTHER);
        uint256 bought = curve.buy{value: 1 ether}(0, vm.getBlockTimestamp());

        vm.prank(OTHER);
        token.approve(address(curve), bought);
        token.setFailTransferFrom(true);

        uint256 reserveBefore = curve.ethReserve();
        vm.prank(OTHER);
        vm.expectRevert(IBondingCurve.TokenTransferFailed.selector);
        curve.sell(bought, 0, vm.getBlockTimestamp());

        assertEq(curve.ethReserve(), reserveBefore, "the reserve is untouched");
        assertEq(curve.tokensSold(), bought, "and so is the sold counter");
    }

    /// @notice An `approve` that reports failure stops the graduation before any position
    /// is minted, so the launch stays in `Graduating` and can be retried.
    function test_graduationRevertsWhenTheTokenApprovalReportsFailure() public {
        (BondingCurve curve, ConfigurableToken token) = _launchWithConfigurableToken();

        vm.deal(OTHER, 100 ether);
        vm.prank(OTHER);
        curve.buy{value: 16 ether}(0, vm.getBlockTimestamp());
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduating), "at the cap");

        token.setFailApprove(true);
        uint256 nextId = positionManager.nextTokenId();
        vm.expectRevert(IBondingCurve.TokenTransferFailed.selector);
        curve.graduate();

        assertEq(positionManager.nextTokenId(), nextId, "no position was minted");
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduating), "still Graduating");

        token.setFailApprove(false);
        curve.graduate();
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "and retried");
    }

    /// @notice `CreatorVesting` checks the pull that funds a schedule, so a schedule can
    /// never exist without the tokens behind it.
    function test_createScheduleRevertsWhenTheTokenPullReportsFailure() public {
        FakeLaunch launch = new FakeLaunch();
        ConfigurableToken token = new ConfigurableToken("Bad", "BAD", address(launch));

        launch.approve(IERC20(address(token)), address(vesting), 1e18);
        token.setFailTransferFrom(true);

        vm.expectRevert(ICreatorVesting.TokenTransferFailed.selector);
        launch.createSchedule(vesting, CREATOR, address(token), 1e18, 0, 2_592_000);
        assertEq(vesting.scheduleOf(address(launch)).allocation, 0, "no schedule was recorded");
    }

    /// @notice `CreatorVesting` checks the transfer that releases vested tokens, so a
    /// release that moved nothing is never recorded as paid.
    function test_releaseRevertsWhenTheTokenTransferReportsFailure() public {
        FakeLaunch launch = new FakeLaunch();
        ConfigurableToken token = new ConfigurableToken("Bad", "BAD", address(launch));

        launch.approve(IERC20(address(token)), address(vesting), 1e18);
        launch.createSchedule(vesting, CREATOR, address(token), 1e18, 0, 2_592_000);
        launch.start(vesting);

        uint64 start = vesting.scheduleOf(address(launch)).start;
        vm.warp(uint256(start) + 2_592_000);
        token.setFailTransfer(true);

        vm.expectRevert(ICreatorVesting.TokenTransferFailed.selector);
        vesting.release(address(launch));
        assertEq(vesting.scheduleOf(address(launch)).released, 0, "nothing was recorded as paid");

        token.setFailTransfer(false);
        assertEq(vesting.release(address(launch)), 1e18, "and the release works afterwards");
    }

    /// @dev A curve deployed directly against a token that can report failure. It names a
    /// probe factory, because the real factory only recognises curves it deployed itself.
    function _launchWithConfigurableToken()
        private
        returns (BondingCurve curve, ConfigurableToken token)
    {
        vm.prank(OTHER);
        curve = BondingCurve(
            payable(deployer.deploy(
                    address(probeFactory),
                    IBondingCurve.CurveConfig({
                        creator: CREATOR,
                        protocolTreasury: TREASURY,
                        tokenDeployer: ITokenDeployer(address(badDeployer)),
                        vesting: ICreatorVesting(address(vesting)),
                        liquidityLock: ILiquidityLock(address(lock)),
                        poolManager: IPoolManager(address(poolManager)),
                        positionManager: IPositionManager(address(positionManager)),
                        permit2: IAllowanceTransfer(address(permit2)),
                        virtualEthReserve: DEFAULT_VE0,
                        bondWei: 0,
                        gradWindow: DEFAULT_GRAD_WINDOW,
                        totalFeeBps: DEFAULT_FEE_BPS,
                        creatorShareBps: UNPLEDGED_CREATOR_BPS,
                        protocolShareBps: UNPLEDGED_PROTOCOL_BPS,
                        protectionShareBps: UNPLEDGED_PROTECTION_BPS,
                        name: "Configurable",
                        symbol: "CFG"
                    })
                ))
        );
        token = badDeployer.last();
        assertEq(address(curve.token()), address(token), "the curve took the configurable token");
    }
}
