// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice One independent trader in the invariant suite.
/// @dev Each actor is a distinct address holding its own token and ETH balances, so the
/// invariant run exercises what several holders trading against one curve actually do: an
/// actor can only sell tokens it bought, and the curve's accounting has to survive any
/// interleaving of them. `execute` reports failure rather than bubbling it, because the
/// handler needs to know whether a call went through in order to keep its ghost variables
/// honest, and because an invariant run is expected to attempt calls that revert.
contract Actor {
    receive() external payable {}

    /// @notice Forwards one call, reporting success instead of reverting.
    function execute(address target, uint256 value, bytes memory data)
        external
        returns (bool ok, bytes memory ret)
    {
        (ok, ret) = target.call{value: value}(data);
    }

    /// @notice Approves a curve to pull this actor's tokens, as a seller must.
    function approve(IERC20 token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }
}
