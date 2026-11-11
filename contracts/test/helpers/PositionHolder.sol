// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

/// @notice Stand-in for `LiquidityLock`: an address that owns position NFTs and is the
/// only party able to act on them.
/// @dev Test-only, and deliberately *not* a model of the real lock. It exists so the
/// compound-only probe runs with `msgSender()` equal to the NFT's owner, which is what
/// `PositionManager._increase`'s `onlyIfApproved` check requires. It has no token
/// approvals of any kind and is funded with nothing, so any value it ends up holding
/// can only have come out of the position's accrued fees.
contract PositionHolder {
    IPositionManager public immutable positionManager;

    constructor(IPositionManager positionManager_) {
        positionManager = positionManager_;
    }

    receive() external payable {}

    /// @notice Forwards one batch of v4 actions, reporting failure instead of bubbling.
    function tryModify(bytes memory unlockData, uint256 deadline)
        external
        payable
        returns (bool ok, bytes memory ret)
    {
        (ok, ret) = address(positionManager).call{value: msg.value}(
            abi.encodeCall(IPositionManager.modifyLiquidities, (unlockData, deadline))
        );
    }
}
