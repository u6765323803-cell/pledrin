// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

/// @notice Pushes ERC-20 tokens it already holds into an arbitrary address on demand.
/// @dev Fault injection, used as a `MockPositionManager` probe target to make a launch's
/// token balance *rise* in the middle of the graduation mint — between the reading
/// `BondingCurve._mintCore` takes before `modifyLiquidities` and the one it takes after.
/// Nothing in the real system can do that, which is the point: the delta the mint is
/// measured by then underflows, and the test using this asserts that the graduation fails
/// closed rather than mismeasuring what the mint consumed.
contract TokenPusher {
    function push(IERC20 token, address to, uint256 amount) external {
        require(token.transfer(to, amount), "TokenPusher: transfer failed");
    }
}

/// @notice Records an address's native balance every time it is asked to, keeping the
/// whole series.
/// @dev Used as a `MockPositionManager` probe target to read PositionManager's own ETH
/// balance from *inside* `modifyLiquidities`, once per batch. A graduation makes two such
/// calls, and the pair of readings is what witnesses the three ordering clauses of
/// Invariant 70 directly: the first carries whatever a third party parked there plus the
/// core mint's `R_target`, and the second carries `floorEth` and nothing else, because the
/// core mint's closing `SWEEP` took the whole balance away and no call between the two
/// mints can give it another. `probeReturn` holds only the last call's data, so a watcher
/// that accumulates is needed to see both.
contract BalanceWatcher {
    uint256[] private _readings;

    function record(address subject) external {
        _readings.push(subject.balance);
    }

    function count() external view returns (uint256) {
        return _readings.length;
    }

    function reading(uint256 index) external view returns (uint256) {
        return _readings[index];
    }
}

/// @notice Records an ERC-20 allowance every time it is asked to, keeping the whole series.
/// @dev Used as a `MockPositionManager` probe target to read `token.allowance(curve, PERMIT2)`
/// from *inside* `modifyLiquidities`. A graduation makes two such calls — the core mint and
/// the floor mint — and the series is what shows the approval exists during the first and is
/// already revoked by the second, which is the ordering `docs/SPEC.md` section 8.2 step 4
/// requires and Invariant 61 rests on. `MockPositionManager.probeReturn` holds only the last
/// call's return data, so a watcher that accumulates is needed to see both.
contract AllowanceWatcher {
    uint256[] private _readings;

    function record(IERC20 token, address owner, address spender) external {
        _readings.push(token.allowance(owner, spender));
    }

    function count() external view returns (uint256) {
        return _readings.length;
    }

    function reading(uint256 index) external view returns (uint256) {
        return _readings[index];
    }
}
