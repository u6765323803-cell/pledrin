// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

/// @notice Throwaway 18-decimal ERC-20, used only so the fork tests have something
/// to pair against native ETH on the real Uniswap v4 deployment.
/// @dev Test-only. `contracts/src/` must stay empty until the contracts engineer
/// starts, so nothing in this file is a candidate for production use. It is a
/// deliberately plain ERC-20: no hooks, no fee on transfer, no rebasing, because the
/// launch token the spec describes is a plain ERC-20 and anything else would make the
/// measurements unrepresentative.
contract TestERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance();
    error InsufficientAllowance();

    constructor(string memory name_, string memory symbol_, uint256 supply, address holder) {
        name = name_;
        symbol = symbol_;
        totalSupply = supply;
        balanceOf[holder] = supply;
        emit Transfer(address(0), holder, supply);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - value;
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) private {
        uint256 bal = balanceOf[from];
        if (bal < value) revert InsufficientBalance();
        balanceOf[from] = bal - value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}
