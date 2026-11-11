// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

/// @dev Proves the remappings resolve and that the v4 interfaces we compile
/// against match the contracts actually deployed on Robinhood Chain.
contract ProbeV4WiringTest is Test {
    IPoolManager constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IPositionManager constant POSITION_MANAGER =
        IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);

    function test_deployedPositionManagerPointsAtDeployedPoolManager() public {
        vm.createSelectFork("robinhood");
        assertEq(
            address(POSITION_MANAGER.poolManager()),
            address(POOL_MANAGER),
            "periphery interface does not match the deployed contracts"
        );
    }
}
