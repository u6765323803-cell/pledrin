// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {BondingCurve} from "src/BondingCurve.sol";
import {ICreatorVesting} from "src/interfaces/ICreatorVesting.sol";

/// @notice One reading of a launch's whole storage, taken from inside a call the launch
/// makes out.
/// @dev This is how Invariant 55's parts (b) and (c) are tested directly rather than
/// inferred: (b) says a function that moves `state` to a terminal value writes it before
/// any external call, and (c) says every storage write is complete before the function's
/// final external call. Both are statements about what an external call *observes*, so the
/// test has to be the thing being called.
struct CurveSnapshot {
    uint8 state;
    uint8 bondState;
    uint256 ethReserve;
    uint256 tokensSold;
    uint256 creatorFeeEth;
    uint256 protocolFeeEth;
    uint256 protectionEth;
    uint256 bondHeldWei;
    uint256 pendingBondWei;
    uint256 pendingBountyTotalWei;
    uint64 graduatedAt;
    uint64 capReachedAt;
}

/// @notice Takes a snapshot of a curve on demand, appending to a list.
contract StateSnapshotter {
    CurveSnapshot[] private _snapshots;

    function snapshot(address curve) external {
        _snapshots.push(readCurve(curve));
    }

    function count() external view returns (uint256) {
        return _snapshots.length;
    }

    function snapshotAt(uint256 index) external view returns (CurveSnapshot memory) {
        return _snapshots[index];
    }

    function readCurve(address curve) internal view returns (CurveSnapshot memory) {
        BondingCurve c = BondingCurve(payable(curve));
        return CurveSnapshot({
            state: uint8(c.state()),
            bondState: uint8(c.bondState()),
            ethReserve: c.ethReserve(),
            tokensSold: c.tokensSold(),
            creatorFeeEth: c.creatorFeeEth(),
            protocolFeeEth: c.protocolFeeEth(),
            protectionEth: c.protectionEth(),
            bondHeldWei: c.bondHeldWei(),
            pendingBondWei: c.pendingBondWei(),
            pendingBountyTotalWei: c.pendingBountyTotalWei(),
            graduatedAt: c.graduatedAt(),
            capReachedAt: c.capReachedAt()
        });
    }
}

/// @notice A `CreatorVesting` stand-in that records what the calling launch looked like
/// when it called `start` or `void`.
/// @dev Used through `RogueCurveDeployer`, because the launches the factory creates all
/// share the one real vesting singleton.
contract ProbeVesting is StateSnapshotter {
    CurveSnapshot public lastStart;
    CurveSnapshot public lastVoid;
    uint256 public startCalls;
    uint256 public voidCalls;

    function createSchedule(address, address, uint128, uint32, uint32) external {}

    function start() external {
        lastStart = readCurve(msg.sender);
        startCalls++;
    }

    function void() external {
        lastVoid = readCurve(msg.sender);
        voidCalls++;
    }

    function startSnapshot() external view returns (CurveSnapshot memory) {
        return lastStart;
    }

    function voidSnapshot() external view returns (CurveSnapshot memory) {
        return lastVoid;
    }
}

/// @notice A `LaunchFactory` stand-in that records what the calling launch looked like
/// when it reported its outcome, and accepts the report from anyone.
contract ProbeFactory is StateSnapshotter {
    CurveSnapshot public lastRecord;
    uint256 public recordCalls;
    string public lastKind;

    function recordGraduation(address, uint128, bool) external {
        lastRecord = readCurve(msg.sender);
        lastKind = "graduation";
        recordCalls++;
    }

    function recordStall(address, bool) external {
        lastRecord = readCurve(msg.sender);
        lastKind = "stall";
        recordCalls++;
    }

    function recordExpiry(address, uint128) external {
        lastRecord = readCurve(msg.sender);
        lastKind = "expiry";
        recordCalls++;
    }

    function recordSnapshot() external view returns (CurveSnapshot memory) {
        return lastRecord;
    }
}
