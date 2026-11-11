// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

/// @title Permanent liquidity lock
/// @notice Holder of the graduated Uniswap v4 positions, as specified in
/// `docs/SPEC.md` section 9.
interface ILiquidityLock {
    /// @notice Which of a launch's two graduation positions a token id is.
    enum PositionKind {
        Core,
        Floor
    }

    /// @notice A position the lock holds on behalf of a launch.
    /// @param launch The curve that minted it.
    /// @param kind Core or floor.
    struct LockedPosition {
        address launch;
        PositionKind kind;
    }

    /// @notice A graduation position was recorded as permanently locked.
    event PositionLocked(uint256 indexed positionId, address indexed launch, PositionKind kind);

    /// @notice A locked position's accrued fees were reinvested into itself.
    event PositionCompounded(
        uint256 indexed positionId, address indexed caller, uint128 liquidityAdded
    );

    /// @notice The lock does not own the position being registered.
    error NotOwned(uint256 positionId);
    /// @notice The position id is already registered.
    error AlreadyLocked(uint256 positionId);
    /// @notice The position id was never registered by a launch.
    error NotLocked(uint256 positionId);
    /// @notice Only the Uniswap v4 PositionManager may send this lock an ERC-721.
    error NotPositionManager();
    /// @notice The position's accrued fees buy no liquidity, so nothing was compounded.
    error NothingToCompound(uint256 positionId);
    /// @notice The position's liquidity did not grow, so the call is rejected.
    error LiquidityNotIncreased(uint256 positionId);
    /// @notice The PositionManager handed to the constructor is the zero address.
    error InvalidPositionManager();
    /// @notice Only Uniswap v4 may send this lock ETH, and only as a position residual.
    error DirectEthNotAccepted();

    /// @notice Records a position the caller has just minted to this lock.
    /// @param positionId The Uniswap v4 position NFT id.
    /// @param kind Core or floor.
    function registerPosition(uint256 positionId, PositionKind kind) external;

    /// @notice Collects a locked position's accrued fees and reinvests them into it.
    /// @param positionId The Uniswap v4 position NFT id.
    /// @return liquidityAdded Liquidity the position gained.
    function compound(uint256 positionId) external returns (uint128 liquidityAdded);

    /// @notice Reads one locked position's record.
    /// @param positionId The Uniswap v4 position NFT id.
    /// @return position The stored record, zero-valued if the id was never registered.
    function positionOf(uint256 positionId) external view returns (LockedPosition memory position);
}
