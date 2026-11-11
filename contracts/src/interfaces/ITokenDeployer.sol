// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Launch token deployer
/// @notice Deploys one `PledrinToken` per launch, minting its entire supply to the caller.
interface ITokenDeployer {
    /// @notice A launch token was deployed.
    event TokenDeployed(address indexed token, address indexed curve);

    /// @notice Deploys a launch token and mints the whole supply to the caller.
    /// @dev The recipient is `msg.sender` and nothing else, so a curve calling this
    /// receives the entire supply in the token's own constructor.
    /// @param name The token name.
    /// @param symbol The token symbol.
    /// @return token The deployed token.
    function deploy(string calldata name, string calldata symbol) external returns (IERC20 token);
}
