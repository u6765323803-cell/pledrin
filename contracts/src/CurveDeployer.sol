// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {BondingCurve} from "./BondingCurve.sol";
import {IBondingCurve} from "./interfaces/IBondingCurve.sol";
import {ICurveDeployer} from "./interfaces/ICurveDeployer.sol";

/// @title Pledrin curve deployer
/// @notice Holds the creation code of `BondingCurve` and nothing else.
/// @dev This contract exists for one reason: `BondingCurve`'s creation code plus
/// `LaunchFactory`'s own code exceeds the 24,576-byte contract size limit, so the factory
/// cannot carry it. Keeping the creation code here leaves every launch a full, ordinary
/// deployment with real immutables set in a real constructor, which is what
/// `docs/OPEN_DECISIONS.md` decision 5 chose for Phase 1, instead of a clone whose
/// parameters are read by hand-maintained offsets.
///
/// It is stateless, permissionless and owns nothing. The curve it deploys records the
/// caller as its factory, so a curve deployed by anyone else is simply a contract with no
/// standing in any factory: it is not in `isLaunch`, it can write no reputation counter,
/// and it holds only whatever its own deployer funded it with.
contract CurveDeployer is ICurveDeployer {
    /// @inheritdoc ICurveDeployer
    function deploy(IBondingCurve.CurveConfig calldata config)
        external
        payable
        returns (address curve)
    {
        // The ETH goes to the curve this call creates and nowhere else, and that curve's
        // constructor requires it to equal the bond its configuration declares.
        // forge-lint: disable-next-item(arbitrary-send-eth)
        curve = address(new BondingCurve{value: msg.value}(msg.sender, config));

        emit CurveDeployed(curve, msg.sender, config.creator);
    }
}
