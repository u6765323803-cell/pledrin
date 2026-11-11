// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {BondingCurve} from "src/BondingCurve.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";

/// @notice Deploys a `BondingCurve` that names an arbitrary address as its factory.
/// @dev Test-only, and the whole point of it is the one thing `CurveDeployer` cannot do:
/// `CurveDeployer` always records its own caller as the new curve's factory, so a curve
/// deployed through it can never claim to belong to the real `LaunchFactory`. This helper
/// lets a test build the strongest rogue curve there is — one that names the real factory
/// — and show that the factory still refuses it, because `isLaunch` is written only by
/// `createLaunch`.
///
/// It carries `BondingCurve`'s creation code, so it is close to the EIP-170 limit for the
/// same reason `CurveDeployer` is; `forge build --sizes` is the check that holds it.
contract RogueCurveDeployer {
    /// @notice Deploys a curve with a caller-chosen factory address.
    /// @param factory_ The address the new curve will report as its factory.
    /// @param config Everything the curve fixes for its lifetime.
    /// @return curve The deployed curve.
    function deploy(address factory_, IBondingCurve.CurveConfig calldata config)
        external
        payable
        returns (address curve)
    {
        // forge-lint: disable-next-item(arbitrary-send-eth)
        curve = address(new BondingCurve{value: msg.value}(factory_, config));
    }
}
