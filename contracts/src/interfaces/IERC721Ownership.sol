// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

/// @title ERC-721 ownership, and nothing else
/// @notice The only ERC-721 function `LiquidityLock` ever calls.
/// @dev Declared narrowly on purpose. The lock's claim is that it holds positions and
/// cannot move them, and that claim is easiest to check if the lock's source does not
/// reference a transfer or approval function anywhere, not even through an interface it
/// imports for one read.
interface IERC721Ownership {
    /// @notice The owner of a token.
    /// @param tokenId The token to read.
    /// @return owner The token's current owner.
    function ownerOf(uint256 tokenId) external view returns (address owner);
}
