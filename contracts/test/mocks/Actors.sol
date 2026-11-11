// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {ICreatorVesting} from "src/interfaces/ICreatorVesting.sol";

/// @notice An address that refuses ETH.
/// @dev Invariant 58: a recipient that reverts on receipt can block only its own claim.
/// Used as a creator and as a treasury.
contract RevertingReceiver {
    error Nope();

    receive() external payable {
        revert Nope();
    }

    /// @notice Lets the test drive a claim from this address.
    function claimCreatorFees(IBondingCurve curve) external returns (uint256) {
        return curve.claimCreatorFees();
    }
}

/// @notice An address that accepts ETH and can be made to stop accepting it.
contract ToggleableReceiver {
    bool public accepting = true;

    error NotAccepting();

    receive() external payable {
        if (!accepting) revert NotAccepting();
    }

    function setAccepting(bool value) external {
        accepting = value;
    }
}

/// @notice A buyer that re-enters `buy` from its refund callback.
/// @dev The clipped final buy is the only buy that pays ETH back to the buyer, so it is
/// the only place a buyer can re-enter from. Invariant 55.
contract ReentrantBuyer {
    IBondingCurve public curve;
    bool public attacked;

    function buy(IBondingCurve curve_, uint256 value) external payable {
        curve = curve_;
        curve_.buy{value: value}(0, block.timestamp);
    }

    receive() external payable {
        if (attacked) return;
        attacked = true;
        curve.buy{value: 1e12}(0, block.timestamp);
    }
}

/// @notice A seller that re-enters `sell` from its proceeds callback.
contract ReentrantSeller {
    IBondingCurve public curve;
    IERC20 public token;
    bool public attacked;

    function prepare(IBondingCurve curve_, IERC20 token_) external {
        curve = curve_;
        token = token_;
        token_.approve(address(curve_), type(uint256).max);
    }

    function buy(uint256 value) external payable {
        curve.buy{value: value}(0, block.timestamp);
    }

    function sell(uint256 amount) external {
        curve.sell(amount, 0, block.timestamp);
    }

    receive() external payable {
        if (attacked) return;
        attacked = true;
        curve.sell(1, 0, block.timestamp);
    }
}

/// @notice A claimant that re-enters its own claim from the payout callback.
contract ReentrantClaimer {
    IBondingCurve public curve;
    bool public attacked;
    uint8 public kind;

    function prepare(IBondingCurve curve_, uint8 kind_) external {
        curve = curve_;
        kind = kind_;
        attacked = false;
    }

    function claim() external returns (uint256) {
        return _claim();
    }

    receive() external payable {
        if (attacked) return;
        attacked = true;
        _claim();
    }

    function _claim() private returns (uint256) {
        if (kind == 0) return curve.claimCreatorFees();
        if (kind == 1) return curve.claimProtocolFees();
        if (kind == 2) return curve.claimBounty(address(this));
        return curve.claimBond();
    }
}

/// @notice A contract that graduates a launch and refuses the bounty when it is claimed.
contract HostileGraduator {
    error Nope();

    bool public accepting;

    receive() external payable {
        if (!accepting) revert Nope();
    }

    function setAccepting(bool value) external {
        accepting = value;
    }

    function graduate(IBondingCurve curve) external {
        curve.graduate();
    }

    function claim(IBondingCurve curve) external returns (uint256) {
        return curve.claimBounty(address(this));
    }
}

/// @notice A caller that tries to drive `CreatorVesting` as if it were a launch.
contract FakeLaunch {
    function createSchedule(
        ICreatorVesting vesting,
        address creator,
        address token,
        uint128 allocation,
        uint32 cliff,
        uint32 duration
    ) external {
        vesting.createSchedule(creator, token, allocation, cliff, duration);
    }

    function approve(IERC20 token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }

    function start(ICreatorVesting vesting) external {
        vesting.start();
    }

    function voidSchedule(ICreatorVesting vesting) external {
        vesting.void();
    }
}
