// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";

import {IERC721Ownership} from "./interfaces/IERC721Ownership.sol";
import {ILiquidityLock} from "./interfaces/ILiquidityLock.sol";

// Holding ETH with no way out is this contract's purpose: the ratio residual of a
// compounding is retained here forever, by design, and a withdrawal path is exactly what
// the lock must not have.
// forge-lint: disable-next-item(locked-ether)
/// @title Pledrin permanent liquidity lock
/// @notice Final owner of every graduated Uniswap v4 position, as specified in
/// `docs/SPEC.md` section 9.
/// @dev This contract is not upgradeable and holds its positions forever, so it is
/// written to be the most conservative code in the repository. It has no owner, no
/// rescue, no sweep, no timelock and no escape hatch, and it contains no call to
/// `transferFrom`, `safeTransferFrom`, `approve`, `setApprovalForAll` or `permit`, and no
/// `BURN_POSITION` action. The single liquidity-decreasing action id it does contain
/// carries a hard-coded zero liquidity, which is the Uniswap v4 idiom for crediting a
/// position's accrued fees without touching its principal; nothing can make that zero
/// non-zero because it is a literal in the encoding and not a parameter.
///
/// The only value that ever leaves a locked position is the ratio residual of a
/// compounding, which Uniswap v4 routes to the position's own owner — this contract — and
/// which stays here permanently. No address can receive value from this contract.
contract LiquidityLock is ILiquidityLock, IERC721Receiver, ReentrancyGuardTransient {
    // The cast names its function instead of attaching the whole library, because Uniswap
    // v4-core declares a second library called `SafeCast` and both reach this file through
    // the imports above. Naming it binds the cast below to OpenZeppelin's implementation at
    // the attachment site rather than leaving a reader to work out which one applies.
    using {SafeCast.toUint8} for uint256;

    /// @notice Uniswap v4 PositionManager, the only contract that may send this lock a
    /// position and the only contract this lock ever calls.
    IPositionManager public immutable positionManager;
    /// @notice Uniswap v4 PoolManager, which pays position residuals directly.
    IPoolManager public immutable poolManager;

    mapping(uint256 positionId => LockedPosition) private _positions;

    /// @notice Binds the lock to a Uniswap v4 deployment.
    /// @dev The PoolManager is read off the PositionManager rather than passed in, so the
    /// two can never be mismatched.
    /// @param positionManager_ Uniswap v4 PositionManager.
    constructor(IPositionManager positionManager_) {
        if (address(positionManager_) == address(0)) revert InvalidPositionManager();
        positionManager = positionManager_;
        poolManager = positionManager_.poolManager();
    }

    /// @notice Accepts the ratio residual of a compounding.
    /// @dev Uniswap v4 pays a position's residual `currency0` from PoolManager and sweeps
    /// unspent native value from PositionManager. Everything else is rejected so that no
    /// one can lose ETH by sending it to a contract that can never pay it out.
    receive() external payable {
        if (msg.sender != address(poolManager) && msg.sender != address(positionManager)) {
            revert DirectEthNotAccepted();
        }
    }

    /// @inheritdoc ILiquidityLock
    /// @dev Permissionless in effect: the caller can only register a position this lock
    /// already owns, and the only consequence of registering one is that its fees become
    /// compoundable. A launch calls this immediately after minting to this lock.
    function registerPosition(uint256 positionId, PositionKind kind) external {
        if (_positions[positionId].launch != address(0)) revert AlreadyLocked(positionId);
        if (IERC721Ownership(address(positionManager)).ownerOf(positionId) != address(this)) {
            revert NotOwned(positionId);
        }

        _positions[positionId] = LockedPosition({launch: msg.sender, kind: kind});

        emit PositionLocked(positionId, msg.sender, kind);
    }

    /// @inheritdoc ILiquidityLock
    /// @dev One `modifyLiquidities` batch, four actions, no caller-supplied number and no
    /// recipient parameter anywhere:
    ///
    /// - `DECREASE_LIQUIDITY` with a hard-coded zero liquidity credits the position's
    ///   accrued fees to this contract's Uniswap v4 delta and leaves the principal alone;
    /// - `INCREASE_LIQUIDITY_FROM_DELTAS` spends exactly that credit on new liquidity in
    ///   the same position;
    /// - the two `CLOSE_CURRENCY` actions settle both sides, paying any ratio residual to
    ///   `msgSender()`, which for a call this lock makes is this lock itself.
    ///
    /// The amount compounded is therefore the position's own fee delta and nothing else.
    /// This contract forwards no value and holds no Permit2 approval, so the batch cannot
    /// spend the residual it has accumulated, and the call reverts rather than letting
    /// fees be credited out of the position without being reinvested.
    function compound(uint256 positionId) external nonReentrant returns (uint128 liquidityAdded) {
        if (_positions[positionId].launch == address(0)) revert NotLocked(positionId);

        // Only the pool key is needed; the position's liquidity is read separately below.
        // forge-lint: disable-next-line(unused-return)
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(positionId);
        uint128 liquidityBefore = positionManager.getPositionLiquidity(positionId);

        positionManager.modifyLiquidities(_compoundData(positionId, key), block.timestamp);

        uint128 liquidityAfter = positionManager.getPositionLiquidity(positionId);
        if (liquidityAfter < liquidityBefore) revert LiquidityNotIncreased(positionId);
        if (liquidityAfter == liquidityBefore) revert NothingToCompound(positionId);
        liquidityAdded = liquidityAfter - liquidityBefore;

        emit PositionCompounded(positionId, msg.sender, liquidityAdded);
    }

    /// @notice Accepts a position NFT.
    /// @dev Only Uniswap v4's PositionManager may deliver one (Invariant 57). A position
    /// that arrives this way is held forever like any other; it becomes compoundable only
    /// if a launch registers it.
    /// @return The ERC-721 receiver magic value.
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != address(positionManager)) revert NotPositionManager();
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @inheritdoc ILiquidityLock
    function positionOf(uint256 positionId) external view returns (LockedPosition memory position) {
        return _positions[positionId];
    }

    /// @dev The compounding batch. Every number in it is a constant or the position id.
    function _compoundData(uint256 positionId, PoolKey memory key)
        private
        pure
        returns (bytes memory)
    {
        bytes memory actions = abi.encodePacked(
            Actions.DECREASE_LIQUIDITY.toUint8(),
            Actions.INCREASE_LIQUIDITY_FROM_DELTAS.toUint8(),
            Actions.CLOSE_CURRENCY.toUint8(),
            Actions.CLOSE_CURRENCY.toUint8()
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(positionId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(positionId, type(uint128).max, type(uint128).max, bytes(""));
        params[2] = abi.encode(key.currency0);
        params[3] = abi.encode(key.currency1);
        return abi.encode(actions, params);
    }
}
