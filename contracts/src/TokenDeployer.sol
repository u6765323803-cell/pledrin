// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PledrinToken} from "./PledrinToken.sol";
import {ITokenDeployer} from "./interfaces/ITokenDeployer.sol";

/// @title Pledrin token deployer
/// @notice Holds the creation code of `PledrinToken` and nothing else.
/// @dev Plumbing, not protocol. `BondingCurve`'s creation code already fills most of the
/// 24,576-byte contract size limit on its own, and carrying the token's creation code
/// inside it would push the contract that deploys curves past that limit. Keeping it here
/// lets the launch token still be minted, in one constructor, directly to the curve that
/// asked for it, which is what `docs/SPEC.md` section 3 requires.
///
/// Stateless, permissionless and owns nothing. The supply always goes to `msg.sender`, so
/// a caller other than a curve simply gets a token of its own with no relation to any
/// launch.
contract TokenDeployer is ITokenDeployer {
    /// @inheritdoc ITokenDeployer
    function deploy(string calldata name, string calldata symbol) external returns (IERC20 token) {
        token = new PledrinToken(name, symbol, msg.sender);

        emit TokenDeployed(address(token), msg.sender);
    }
}
