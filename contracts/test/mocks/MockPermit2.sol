// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Deterministic stand-in for Permit2's allowance registry
/// @notice Implements the two calls the protocol's approval path needs: the
/// `approve(token, spender, amount, expiration)` a launch makes before a graduation mint,
/// and the `transferFrom(from, to, amount, token)` PositionManager makes to collect the
/// token it owes.
/// @dev Test-only. Both legs of the approval are enforced, which is the point: Permit2
/// moves the token with its own ERC-20 allowance, so a launch that approved Permit2 but
/// did not register the PositionManager allowance — or the other way round — fails here
/// exactly as it would on chain. `test/fork/V4Assumptions.t.sol`'s assumption-5 test is
/// the measurement this mirrors.
contract MockPermit2 {
    struct Allowance {
        uint160 amount;
        uint48 expiration;
    }

    mapping(address owner => mapping(address token => mapping(address spender => Allowance)))
        private _allowance;

    /// @notice The registered allowance is too small for the transfer.
    error InsufficientAllowance(uint256 available, uint256 requested);
    /// @notice The registered allowance has expired.
    error AllowanceExpired(uint256 expiration);

    /// @notice Registers an allowance for a spender, as `Permit2.approve` does.
    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        _allowance[msg.sender][token][spender] = Allowance(amount, expiration);
    }

    /// @notice Moves a token on an owner's behalf, as `Permit2.transferFrom` does.
    /// @dev Spends the registered allowance and then relies on Permit2's own ERC-20
    /// allowance, so both legs have to be present.
    function transferFrom(address from, address to, uint160 amount, address token) external {
        Allowance storage allowed = _allowance[from][token][msg.sender];
        if (allowed.expiration != 0 && block.timestamp > allowed.expiration) {
            revert AllowanceExpired(allowed.expiration);
        }
        if (allowed.amount < amount) revert InsufficientAllowance(allowed.amount, amount);
        if (allowed.amount != type(uint160).max) allowed.amount -= amount;

        require(IERC20(token).transferFrom(from, to, amount), "MockPermit2: transfer failed");
    }

    /// @notice Reads a registered allowance.
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce)
    {
        Allowance memory allowed = _allowance[owner][token][spender];
        return (allowed.amount, allowed.expiration, 0);
    }
}
