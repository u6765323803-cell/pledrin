// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ITokenDeployer} from "src/interfaces/ITokenDeployer.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

/// @notice An ERC-20 that can be told to report failure instead of reverting.
/// @dev Test-only. Every launch-token call the protocol makes is checked against the
/// boolean the ERC-20 standard says it returns — `token.approve`, `token.transfer` and
/// `token.transferFrom` are all wrapped in a check that reverts `TokenTransferFailed` — and
/// `PledrinToken` can never return false, so this is the only way to show those checks do
/// something. A token that returns `false` without reverting is the classic non-compliant
/// ERC-20 behaviour those wrappers exist for.
///
/// It satisfies the two things `BondingCurve`'s constructor demands of a launch token: a
/// total supply of exactly `TOTAL_SUPPLY`, all of it held by the curve.
contract ConfigurableToken is IERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply = PledrinConstants.TOTAL_SUPPLY;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    bool public failApprove;
    bool public failTransfer;
    bool public failTransferFrom;

    error InsufficientBalance();

    constructor(string memory name_, string memory symbol_, address holder) {
        name = name_;
        symbol = symbol_;
        balanceOf[holder] = PledrinConstants.TOTAL_SUPPLY;
        emit Transfer(address(0), holder, PledrinConstants.TOTAL_SUPPLY);
    }

    function setFailApprove(bool value) external {
        failApprove = value;
    }

    function setFailTransfer(bool value) external {
        failTransfer = value;
    }

    function setFailTransferFrom(bool value) external {
        failTransferFrom = value;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (failApprove) return false;
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (failTransfer) return false;
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (failTransferFrom) return false;
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        uint256 balance = balanceOf[from];
        if (balance < amount) revert InsufficientBalance();
        balanceOf[from] = balance - amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @notice Deploys a `ConfigurableToken` to its caller and remembers the last one.
contract ConfigurableTokenDeployer is ITokenDeployer {
    /// @notice The most recent token this deployer created, so a test can configure it.
    ConfigurableToken public last;

    /// @inheritdoc ITokenDeployer
    function deploy(string calldata name, string calldata symbol) external returns (IERC20) {
        last = new ConfigurableToken(name, symbol, msg.sender);
        emit TokenDeployed(address(last), msg.sender);
        return IERC20(address(last));
    }
}
