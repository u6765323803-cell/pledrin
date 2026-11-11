// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {PledrinToken} from "src/PledrinToken.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {ICreatorVesting} from "src/interfaces/ICreatorVesting.sol";
import {ICurveDeployer} from "src/interfaces/ICurveDeployer.sol";
import {ILaunchFactory} from "src/interfaces/ILaunchFactory.sol";
import {ILiquidityLock} from "src/interfaces/ILiquidityLock.sol";
import {ITokenDeployer} from "src/interfaces/ITokenDeployer.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {PledrinTestBase} from "../base/PledrinTestBase.sol";
import {RogueCurveDeployer} from "../helpers/RogueCurveDeployer.sol";

/// @title The launch token, the two deployers, and what a curve deployed outside the
/// factory can and cannot do
/// @notice Covers `docs/SPEC.md` sections 3 and 15.3, and Invariants 5, 19, 48 and 52.
/// @dev `CurveDeployer.deploy` is permissionless by design, so the tests that matter here
/// are the ones that bound a rogue curve: it is absent from `isLaunch`, it can write no
/// reputation counter, and it can create a vesting schedule only for itself and only by
/// actually delivering the tokens.
contract TokenAndDeployersTest is PledrinTestBase {
    /// @notice Section 3: the token is fixed-supply, 18 decimals, entirely in the curve.
    function test_launchTokenIsFixedSupplyAndEntirelyInTheCurve() public {
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();

        assertEq(token.totalSupply(), PledrinConstants.TOTAL_SUPPLY, "total supply");
        assertEq(token.balanceOf(address(curve)), PledrinConstants.TOTAL_SUPPLY, "Invariant 5");
        assertEq(IERC20Metadata(address(token)).decimals(), 18, "decimals");
        assertEq(IERC20Metadata(address(token)).name(), "Pledrin Launch", "name");
        assertEq(IERC20Metadata(address(token)).symbol(), "PLDR", "symbol");
    }

    /// @notice The token has no privileged entry point at all: the four selectors a
    /// mintable, burnable, ownable or pausable ERC-20 would expose are absent.
    function test_launchTokenHasNoPrivilegedEntryPoints() public {
        (, IERC20 token) = createDefaultLaunch();
        address tokenAddress = address(token);

        string[6] memory signatures = [
            "mint(address,uint256)",
            "burn(uint256)",
            "owner()",
            "pause()",
            "setBlacklist(address,bool)",
            "upgradeTo(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = tokenAddress.call(abi.encodeWithSignature(signatures[i]));
            assertFalse(ok, signatures[i]);
        }
    }

    /// @notice Invariant 19's token half: an ordinary ERC-20 transfer needs an allowance,
    /// so no protocol contract can move a holder's tokens without one.
    function test_launchTokenNeedsAnAllowanceLikeAnyErc20() public {
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        buy(curve, TRADER, 1 ether);

        vm.prank(address(curve));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(curve), 0, 1
            )
        );
        token.transferFrom(TRADER, address(curve), 1);
    }

    /// @notice `TokenDeployer` mints to its caller and to nobody else, so a caller that is
    /// not a curve simply gets a token with no relation to any launch.
    function test_tokenDeployerMintsToItsCaller() public {
        vm.prank(OTHER);
        IERC20 token = tokenDeployer.deploy("Rogue", "ROGUE");

        assertEq(token.balanceOf(OTHER), PledrinConstants.TOTAL_SUPPLY, "the caller holds it all");
        assertEq(token.totalSupply(), PledrinConstants.TOTAL_SUPPLY, "supply");
    }

    /// @notice The deployer announces what it deployed, which is how the indexer finds a
    /// launch token.
    function test_tokenDeployerEmitsTokenDeployed() public {
        vm.expectEmit(false, true, false, false, address(tokenDeployer));
        emit ITokenDeployer.TokenDeployed(address(0), OTHER);
        vm.prank(OTHER);
        IERC20 token = tokenDeployer.deploy("Rogue", "ROGUE");

        assertGt(address(token).code.length, 0, "the token has code");
    }

    /// @notice A token constructed directly mints to whatever curve address it is handed,
    /// which is what `TokenDeployer` relies on.
    function test_tokenConstructorMintsToTheAddressItIsGiven() public {
        PledrinToken token = new PledrinToken("Direct", "DIR", OTHER);

        assertEq(token.balanceOf(OTHER), PledrinConstants.TOTAL_SUPPLY, "minted to the argument");
    }

    // ------------------------------------------------------------------
    // Rogue curves
    // ------------------------------------------------------------------

    /// @notice A curve anyone deploys through `CurveDeployer` is not a launch: the factory
    /// does not know it, so none of its reputation counters can ever be written.
    function test_rogueCurveIsNotALaunchAndCannotWriteReputation() public {
        BondingCurve rogue = _deployRogueCurve(address(factory), 0);

        assertFalse(factory.isLaunch(address(rogue)), "a rogue curve is not a launch");

        // Drive it to the cap and try to graduate: the factory refuses to record it, so
        // the graduation reverts and no counter moves.
        vm.deal(OTHER, 100 ether);
        vm.prank(OTHER);
        rogue.buy{value: 8 ether}(0, vm.getBlockTimestamp());
        assertEq(uint8(rogue.state()), uint8(IBondingCurve.State.Graduating), "at the cap");

        vm.expectRevert(ILaunchFactory.NotLaunch.selector);
        rogue.graduate();

        ILaunchFactory.Reputation memory record = factory.reputationOf(CREATOR);
        assertEq(record.graduations, 0, "no graduation recorded");
        assertEq(record.launches, 0, "no launch recorded");
    }

    /// @notice The same for expiry: a rogue curve cannot record an expiry either.
    function test_rogueCurveCannotRecordAnExpiry() public {
        BondingCurve rogue = _deployRogueCurve(address(factory), 0);

        vm.warp(rogue.gradDeadline());
        vm.expectRevert(ILaunchFactory.NotLaunch.selector);
        rogue.expire();
    }

    /// @notice A rogue curve can only create a vesting schedule for itself, and only by
    /// delivering the allocation it claims. Its schedule is keyed by itself, so no real
    /// launch's schedule is reachable from it.
    function test_rogueCurveCanOnlyVestTokensItActuallyDelivers() public {
        // A caller with no tokens cannot create a schedule.
        (, IERC20 token) = createDefaultLaunch();
        vm.prank(OTHER);
        vm.expectRevert();
        vesting.createSchedule(OTHER, address(token), 1e18, 0, 2_592_000);

        // A caller that holds and approves the tokens creates a schedule for *itself*,
        // keyed by its own address, and funds it out of its own balance.
        vm.prank(OTHER);
        IERC20 rogueToken = tokenDeployer.deploy("Rogue", "ROGUE");
        vm.prank(OTHER);
        rogueToken.approve(address(vesting), 1e18);
        vm.prank(OTHER);
        vesting.createSchedule(OTHER, address(rogueToken), 1e18, 0, 2_592_000);

        ICreatorVesting.Schedule memory schedule = vesting.scheduleOf(OTHER);
        assertEq(schedule.allocation, 1e18, "the rogue schedule is keyed by the rogue");
        assertEq(rogueToken.balanceOf(address(vesting)), 1e18, "funded by the rogue itself");
        assertEq(token.balanceOf(address(vesting)), 0, "no real launch token reached the vesting");
    }

    /// @notice A rogue cannot register a position with the lock, because the lock checks
    /// that it already owns the token id. A position that exists but belongs to somebody
    /// else is rejected, and so is one that does not exist at all.
    function test_rogueCannotRegisterAPositionItDoesNotOwn() public {
        (, IERC20 token) = createDefaultLaunch();
        uint256 tokenId =
            positionManager.mintBare(OTHER, _poolKeyFor(address(token)), -887_200, 887_200, 1e18);

        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(ILiquidityLock.NotOwned.selector, tokenId));
        lock.registerPosition(tokenId, ILiquidityLock.PositionKind.Core);

        vm.expectRevert();
        lock.registerPosition(tokenId + 1, ILiquidityLock.PositionKind.Core);
    }

    function _poolKeyFor(address token) private pure returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: PledrinConstants.POOL_FEE,
            tickSpacing: PledrinConstants.POOL_TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    /// @notice `CurveDeployer` forwards the whole value to the curve it creates, and that
    /// curve's constructor requires the value to equal the bond it declares.
    function test_curveDeployerForwardsExactlyTheBondAndNothingElse() public {
        vm.deal(OTHER, OTHER.balance + 0.4 ether);
        vm.prank(OTHER);
        BondingCurve rogue = BondingCurve(
            payable(curveDeployer.deploy{value: 0.4 ether}(
                    _rogueConfig(address(factory), 0.4 ether)
                ))
        );
        assertEq(rogue.factory(), OTHER, "CurveDeployer records its own caller as the factory");

        assertEq(rogue.bondHeldWei(), 0.4 ether, "bond held");
        assertEq(address(rogue).balance, 0.4 ether, "the ETH is in the curve");
        assertEq(uint8(rogue.bondState()), uint8(IBondingCurve.BondState.Bonded), "bonded");
    }

    /// @notice A value that does not match the declared bond is rejected by the curve's
    /// own constructor, so the deployer needs no check of its own.
    function test_curveDeployerRejectsAValueThatIsNotTheBond() public {
        IBondingCurve.CurveConfig memory config = _rogueConfig(address(factory), 0.4 ether);

        vm.deal(OTHER, 1 ether);
        vm.prank(OTHER);
        vm.expectRevert(IBondingCurve.BondValueMismatch.selector);
        curveDeployer.deploy{value: 0.5 ether}(config);
    }

    /// @dev Deploys the strongest rogue curve available: one that names the real factory.
    /// `CurveDeployer` records its own caller as the factory, so reaching this state needs
    /// a deployer that takes the address as an argument.
    function _deployRogueCurve(address factory_, uint128 bondWei)
        private
        returns (BondingCurve rogue)
    {
        RogueCurveDeployer rogueDeployer = new RogueCurveDeployer();
        vm.deal(OTHER, OTHER.balance + bondWei);
        vm.prank(OTHER);
        rogue = BondingCurve(
            payable(rogueDeployer.deploy{value: bondWei}(factory_, _rogueConfig(factory_, bondWei)))
        );
        assertEq(rogue.factory(), factory_, "the rogue curve names the real factory");
    }

    function _rogueConfig(address, uint128 bondWei)
        private
        view
        returns (IBondingCurve.CurveConfig memory)
    {
        return IBondingCurve.CurveConfig({
            creator: CREATOR,
            protocolTreasury: TREASURY,
            tokenDeployer: ITokenDeployer(address(tokenDeployer)),
            vesting: ICreatorVesting(address(vesting)),
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
            name: "Rogue",
            symbol: "ROGUE"
        });
    }
}
