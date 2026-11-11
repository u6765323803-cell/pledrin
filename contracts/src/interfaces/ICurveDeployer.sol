// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IBondingCurve} from "./IBondingCurve.sol";

/// @title Bonding curve deployer
/// @notice Deploys one `BondingCurve` per launch on behalf of a factory.
interface ICurveDeployer {
    /// @notice A curve was deployed.
    event CurveDeployed(address indexed curve, address indexed factory, address indexed creator);

    /// @notice Deploys a launch's curve and forwards the ETH it sent as that launch's bond.
    /// @dev The deployed curve records the caller as its factory, so a curve deployed by
    /// anyone other than a real factory has no standing with one. The curve's own
    /// constructor requires the value forwarded to equal the bond its configuration
    /// declares, so nothing is re-checked here.
    /// @param config Everything the launch fixes for its lifetime.
    /// @return curve The deployed curve.
    function deploy(IBondingCurve.CurveConfig calldata config)
        external
        payable
        returns (address curve);
}
