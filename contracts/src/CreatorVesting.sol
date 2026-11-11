// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ICreatorVesting} from "./interfaces/ICreatorVesting.sol";

/// @title Pledrin creator vesting
/// @notice Holds one schedule per launch, as specified in `docs/SPEC.md` section 12.
/// @dev There is no owner, no early-release path, no acceleration, no way to transfer a
/// schedule and no function that can change an `allocation`, `cliff` or `duration` after
/// it is created. A schedule is keyed by the launch that created it and funded by pulling
/// the allocation from that same launch in the same call, so the tokens one schedule can
/// release are always tokens that schedule itself delivered. That is what lets this
/// contract be permissionless: a caller can create a schedule only for itself, and doing
/// so costs it exactly the allocation it claims.
contract CreatorVesting is ICreatorVesting, ReentrancyGuardTransient {
    using SafeCast for uint256;

    mapping(address launch => Schedule) private _schedules;

    /// @inheritdoc ICreatorVesting
    function createSchedule(
        address creator,
        address token,
        uint128 allocation,
        uint32 cliff,
        uint32 duration
    ) external nonReentrant {
        Schedule storage schedule = _schedules[msg.sender];
        if (schedule.allocation != 0) revert ScheduleExists();
        if (creator == address(0) || token == address(0) || allocation == 0 || duration == 0) {
            revert InvalidSchedule();
        }

        schedule.creator = creator;
        schedule.token = token;
        schedule.allocation = allocation;
        schedule.cliff = cliff;
        schedule.duration = duration;

        emit VestingCreated(msg.sender, creator, allocation, cliff, duration);

        if (!IERC20(token).transferFrom(msg.sender, address(this), allocation)) {
            revert TokenTransferFailed();
        }
    }

    /// @inheritdoc ICreatorVesting
    /// @dev Called by the launch when it graduates or stalls. A launch with no schedule
    /// calls this too, and for it the call is a no-op rather than a revert, because a
    /// graduation must never be blocked by the absence of a creator allocation.
    function start() external {
        Schedule storage schedule = _schedules[msg.sender];
        if (schedule.allocation == 0) return;
        if (schedule.start != 0) revert AlreadyStarted();
        if (schedule.voided) revert ScheduleVoided();

        uint64 startedAt = block.timestamp.toUint64();
        schedule.start = startedAt;

        emit VestingStarted(
            msg.sender,
            schedule.creator,
            schedule.allocation,
            startedAt,
            schedule.cliff,
            schedule.duration
        );
    }

    /// @inheritdoc ICreatorVesting
    /// @dev Called by the launch when it expires. Once voided the allocation is
    /// irrecoverable by anyone, which removes it from circulation without a burn and
    /// without changing the token's total supply.
    function void() external {
        Schedule storage schedule = _schedules[msg.sender];
        if (schedule.allocation == 0) return;
        if (schedule.voided) revert ScheduleVoided();

        schedule.voided = true;

        emit VestingVoided(msg.sender, schedule.creator, schedule.allocation);
    }

    /// @inheritdoc ICreatorVesting
    function release(address launch) external nonReentrant returns (uint256 amount) {
        Schedule storage schedule = _schedules[launch];
        if (schedule.allocation == 0) revert NoSchedule();

        amount = _releasable(schedule);
        if (amount == 0) revert NothingToRelease();

        uint128 cumulative = schedule.released + amount.toUint128();
        schedule.released = cumulative;
        address creator = schedule.creator;
        address token = schedule.token;

        emit VestingReleased(launch, creator, amount, cumulative);

        if (!IERC20(token).transfer(creator, amount)) revert TokenTransferFailed();
    }

    /// @inheritdoc ICreatorVesting
    function releasable(address launch) external view returns (uint256 amount) {
        return _releasable(_schedules[launch]);
    }

    /// @inheritdoc ICreatorVesting
    function scheduleOf(address launch) external view returns (Schedule memory schedule) {
        return _schedules[launch];
    }

    /// @dev The schedule of `docs/SPEC.md` section 12: nothing before the launch settles,
    /// nothing before the cliff, nothing ever once voided, linear afterwards, and exactly
    /// the allocation once the duration has elapsed.
    function _releasable(Schedule storage schedule) private view returns (uint256) {
        uint64 startTime = schedule.start;
        if (startTime == 0 || schedule.voided) return 0;

        uint256 cliffEnd = uint256(startTime) + schedule.cliff;
        if (block.timestamp < cliffEnd) return 0;

        uint256 allocation = schedule.allocation;
        uint256 released = schedule.released;
        uint256 elapsed = block.timestamp - cliffEnd;
        if (elapsed >= schedule.duration) return allocation - released;

        return Math.mulDiv(allocation, elapsed, schedule.duration) - released;
    }
}
