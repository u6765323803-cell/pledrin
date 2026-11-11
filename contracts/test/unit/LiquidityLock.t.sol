// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {LiquidityLock} from "src/LiquidityLock.sol";
import {ILiquidityLock} from "src/interfaces/ILiquidityLock.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {PledrinTestBase} from "../base/PledrinTestBase.sol";

/// @title `LiquidityLock`
/// @notice Covers `docs/SPEC.md` section 9 and Invariants 46, 52, 57 and 58.
/// @dev The lock's claim is that a position it holds can never leave and that the only
/// value that ever moves is a compounding's ratio residual, which stays here. Two of the
/// tests below are about `compound`'s refusals rather than its successes: it reverts when
/// the fees buy no liquidity, so fees are never credited out of a position without being
/// reinvested, and it has a backstop that refuses a call which would leave the position
/// with less liquidity than it started with.
contract LiquidityLockTest is PledrinTestBase {
    /// @notice The lock reads its PoolManager off its PositionManager, so the two can
    /// never be mismatched, and rejects a zero PositionManager.
    function test_theLockIsBoundToOneUniswapDeployment() public {
        assertEq(address(lock.positionManager()), address(positionManager), "positionManager");
        assertEq(address(lock.poolManager()), address(poolManager), "poolManager");

        vm.expectRevert(ILiquidityLock.InvalidPositionManager.selector);
        new LiquidityLock(IPositionManager(address(0)));
    }

    /// @notice **Invariant 46.** The lock exposes no function that could move a position:
    /// none of the ERC-721 or PositionManager escape hatches exists on it, and it has no
    /// fallback, so a call naming one of them reverts rather than being swallowed.
    function test_theLockHasNoFunctionThatCouldMoveAPosition() public {
        string[10] memory signatures = [
            "transferFrom(address,address,uint256)",
            "safeTransferFrom(address,address,uint256)",
            "approve(address,uint256)",
            "setApprovalForAll(address,bool)",
            "permit(address,uint256,uint256,uint256,bytes)",
            "burn(uint256)",
            "sweep(address,address)",
            "withdraw(uint256)",
            "rescue(address)",
            "owner()"
        ];
        address target = address(lock);
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = target.call(abi.encodeWithSignature(signatures[i]));
            assertFalse(ok, signatures[i]);
        }
    }

    /// @notice A graduation's positions arrive registered, with their kinds.
    function test_graduationRegistersBothPositions() public {
        (BondingCurve curve,) = createLaunchAtCap();
        uint256 coreId = positionManager.nextTokenId();
        vm.prank(GRADUATOR);
        curve.graduate();

        assertEq(lock.positionOf(coreId).launch, address(curve), "core launch");
        assertEq(uint8(lock.positionOf(coreId).kind), 0, "core kind");
        assertEq(lock.positionOf(coreId + 1).launch, address(curve), "floor launch");
        assertEq(uint8(lock.positionOf(coreId + 1).kind), 1, "floor kind");
        assertEq(lock.positionOf(coreId + 2).launch, address(0), "an unknown id is empty");
    }

    /// @notice A position id is registered once. The second attempt is refused whoever
    /// makes it.
    function test_aPositionIsRegisteredOnce() public {
        (BondingCurve curve,) = createLaunchAtCap();
        uint256 coreId = positionManager.nextTokenId();
        vm.prank(GRADUATOR);
        curve.graduate();

        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(ILiquidityLock.AlreadyLocked.selector, coreId));
        lock.registerPosition(coreId, ILiquidityLock.PositionKind.Floor);
    }

    /// @notice Registration is permissionless but useless to a stranger: all it can do is
    /// mark a position the lock already owns as compoundable.
    function test_anyoneMayRegisterAPositionTheLockAlreadyOwns() public {
        (BondingCurve curve,) = createDefaultLaunch();
        uint256 tokenId =
            positionManager.mintBare(address(lock), _poolKeyOf(curve), 170_400, 184_200, 1e18);

        vm.prank(OTHER);
        lock.registerPosition(tokenId, ILiquidityLock.PositionKind.Floor);
        assertEq(lock.positionOf(tokenId).launch, OTHER, "the registrant is recorded");
    }

    /// @notice `compound` reinvests a position's accrued fees into itself and reports the
    /// liquidity it added.
    function test_compoundReinvestsTheFeesIntoTheSamePosition() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        uint256 coreId = positionManager.nextTokenId();
        vm.prank(GRADUATOR);
        curve.graduate();

        uint128 before = positionManager.getPositionLiquidity(coreId);
        _accrueFees(coreId, token, 1 ether, 1e22);

        vm.prank(OTHER);
        uint128 added = lock.compound(coreId);

        assertGt(added, 0, "liquidity was added");
        assertEq(
            positionManager.getPositionLiquidity(coreId), before + added, "and it went in here"
        );
        assertEq(positionManager.ownerOf(coreId), address(lock), "the owner never changes");
    }

    /// @notice The ratio residual of a compounding is retained by the lock forever, which
    /// is what section 9 says and what makes the lock hold ETH with no way out.
    function test_theCompoundingResidualStaysInTheLock() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        uint256 coreId = positionManager.nextTokenId();
        vm.prank(GRADUATOR);
        curve.graduate();

        _accrueFees(coreId, token, 1 ether, 1e22);
        lock.compound(coreId);

        assertGt(
            address(lock).balance + token.balanceOf(address(lock)), 0, "a residual reached the lock"
        );

        uint256 ethResidual = address(lock).balance;
        uint256 tokenResidual = token.balanceOf(address(lock));
        _accrueFees(coreId, token, 1 ether, 1e22);
        lock.compound(coreId);

        assertGe(address(lock).balance, ethResidual, "the first residual never left");
        assertGe(token.balanceOf(address(lock)), tokenResidual, "in either currency");
    }

    /// @notice `compound` refuses a position whose fees buy no liquidity, rather than
    /// crediting the fees out of the position without reinvesting them.
    function test_compoundRevertsWhenThereIsNothingToCompound() public {
        (BondingCurve curve,) = createLaunchAtCap();
        uint256 coreId = positionManager.nextTokenId();
        vm.prank(GRADUATOR);
        curve.graduate();

        vm.expectRevert(abi.encodeWithSelector(ILiquidityLock.NothingToCompound.selector, coreId));
        lock.compound(coreId);

        // One-sided accrual is the realistic version of the same thing: a position that
        // spans the price needs both currencies, so fees in one alone buy nothing.
        _accrueFees(coreId, IERC20(address(curve.token())), 1 ether, 0);
        vm.expectRevert(abi.encodeWithSelector(ILiquidityLock.NothingToCompound.selector, coreId));
        lock.compound(coreId);
    }

    /// @notice The `LiquidityNotIncreased` backstop: a batch that would leave the position
    /// with less liquidity than it started with is refused. Uniswap v4 cannot produce that
    /// from the actions the lock encodes — the only liquidity-decreasing action id it
    /// contains carries a hard-coded zero — so the stand-in is told to shrink it.
    function test_compoundRefusesABatchThatWouldShrinkThePosition() public {
        (BondingCurve curve,) = createLaunchAtCap();
        uint256 coreId = positionManager.nextTokenId();
        vm.prank(GRADUATOR);
        curve.graduate();

        positionManager.setLiquidityDeltaOverride(-1);
        vm.expectRevert(
            abi.encodeWithSelector(ILiquidityLock.LiquidityNotIncreased.selector, coreId)
        );
        lock.compound(coreId);

        positionManager.setLiquidityDeltaOverride(0);
        vm.expectRevert(abi.encodeWithSelector(ILiquidityLock.NothingToCompound.selector, coreId));
        lock.compound(coreId);

        positionManager.setLiquidityDeltaOverride(5);
        assertEq(lock.compound(coreId), 5, "and accepts one that grows it");
    }

    /// @notice An unregistered position cannot be compounded, even if the lock owns it.
    function test_compoundRevertsForAnUnregisteredPosition() public {
        (BondingCurve curve,) = createDefaultLaunch();
        uint256 tokenId =
            positionManager.mintBare(address(lock), _poolKeyOf(curve), 170_400, 184_200, 1e18);

        vm.expectRevert(abi.encodeWithSelector(ILiquidityLock.NotLocked.selector, tokenId));
        lock.compound(tokenId);
    }

    /// @notice Invariant 55(a): `compound` holds a reentrancy guard.
    function test_compoundHoldsAReentrancyGuard() public {
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        uint256 coreId = positionManager.nextTokenId();
        vm.prank(GRADUATOR);
        curve.graduate();
        _accrueFees(coreId, token, 1 ether, 1e22);

        positionManager.setProbe(address(lock), abi.encodeCall(ILiquidityLock.compound, (coreId)));
        lock.compound(coreId);

        assertTrue(positionManager.probeCalled(), "the probe ran");
        assertFalse(positionManager.probeSucceeded(), "the re-entry was refused");
        positionManager.setProbe(address(0), "");
    }

    /// @notice **Invariant 57.** Only Uniswap v4's PositionManager may deliver an ERC-721
    /// to the lock.
    function test_onlyThePositionManagerMaySendTheLockAPosition() public {
        vm.prank(OTHER);
        vm.expectRevert(ILiquidityLock.NotPositionManager.selector);
        lock.onERC721Received(OTHER, OTHER, 1, "");

        vm.prank(address(positionManager));
        assertEq(
            lock.onERC721Received(OTHER, OTHER, 1, ""),
            IERC721Receiver.onERC721Received.selector,
            "the PositionManager is accepted"
        );
    }

    /// @notice The lock accepts ETH only from Uniswap, because it can never pay it out.
    function test_theLockAcceptsEthOnlyFromUniswap() public {
        vm.deal(OTHER, 1 ether);
        vm.prank(OTHER);
        (bool ok, bytes memory ret) = address(lock).call{value: 1 ether}("");
        assertFalse(ok, "a stranger's ETH is refused");
        assertEq(bytes4(ret), ILiquidityLock.DirectEthNotAccepted.selector, "with that error");

        vm.deal(address(poolManager), 1 ether);
        vm.prank(address(poolManager));
        (bool fromPool,) = address(lock).call{value: 1}("");
        assertTrue(fromPool, "the PoolManager pays residuals directly");

        vm.deal(address(positionManager), 1 ether);
        vm.prank(address(positionManager));
        (bool fromPosm,) = address(lock).call{value: 1}("");
        assertTrue(fromPosm, "and the PositionManager sweeps unspent value");
    }

    /// @notice ETH forced into the lock changes no price and no position, because the lock
    /// never reads its own balance.
    function test_ethForcedIntoTheLockChangesNothing() public {
        (BondingCurve curve,) = createLaunchAtCap();
        uint256 coreId = positionManager.nextTokenId();
        vm.prank(GRADUATOR);
        curve.graduate();

        uint128 liquidity = positionManager.getPositionLiquidity(coreId);
        (uint160 price,) = poolManager.slot0(curve.poolId());

        vm.deal(address(lock), 100 ether);

        assertEq(positionManager.getPositionLiquidity(coreId), liquidity, "liquidity");
        (uint160 priceAfter,) = poolManager.slot0(curve.poolId());
        assertEq(priceAfter, price, "price");
        vm.expectRevert(abi.encodeWithSelector(ILiquidityLock.NothingToCompound.selector, coreId));
        lock.compound(coreId);
    }

    // ------------------------------------------------------------------

    function _accrueFees(uint256 tokenId, IERC20 token, uint256 amount0, uint256 amount1) private {
        vm.deal(address(this), address(this).balance + amount0);
        if (amount1 != 0) {
            vm.deal(TRADER, TRADER.balance + 100 ether);
            vm.prank(TRADER);
            token.transfer(address(this), amount1);
            token.approve(address(positionManager), amount1);
        }
        positionManager.accrueFees{value: amount0}(tokenId, amount1);
    }

    function _poolKeyOf(BondingCurve curve) private view returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(curve.token())),
            fee: PledrinConstants.POOL_FEE,
            tickSpacing: PledrinConstants.POOL_TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }
}
