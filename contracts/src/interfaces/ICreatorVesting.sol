// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

/// @title Creator vesting singleton
/// @notice One schedule per launch, as specified in `docs/SPEC.md` section 12.
interface ICreatorVesting {
    /// @notice One launch's creator allocation.
    /// @param creator The only address a release can ever pay.
    /// @param token The launch token held for this schedule.
    /// @param allocation Base units delivered by the creator's first buy at launch.
    /// @param released Cumulative base units released so far.
    /// @param start Unix time the clock starts, zero until the launch settles.
    /// @param cliff Seconds after `start` before anything is releasable.
    /// @param duration Seconds of linear release after the cliff.
    /// @param voided True once the launch expired, which strands the allocation forever.
    struct Schedule {
        address creator;
        address token;
        uint128 allocation;
        uint128 released;
        uint64 start;
        uint32 cliff;
        uint32 duration;
        bool voided;
    }

    /// @notice A launch funded its creator schedule at launch time, with `start` unset.
    event VestingCreated(
        address indexed launch,
        address indexed creator,
        uint256 allocation,
        uint32 cliff,
        uint32 duration
    );

    /// @notice A launch settled and the vesting clock started.
    event VestingStarted(
        address indexed launch,
        address indexed creator,
        uint256 allocation,
        uint64 start,
        uint32 cliff,
        uint32 duration
    );

    /// @notice Vested tokens were released to the creator.
    event VestingReleased(
        address indexed launch, address indexed creator, uint256 amount, uint256 cumulative
    );

    /// @notice A launch expired and its creator allocation became irrecoverable.
    event VestingVoided(address indexed launch, address indexed creator, uint256 allocation);

    /// @notice The caller already has a schedule.
    error ScheduleExists();
    /// @notice The caller has no schedule.
    error NoSchedule();
    /// @notice A schedule parameter is outside what this contract accepts.
    error InvalidSchedule();
    /// @notice The schedule's clock has already started.
    error AlreadyStarted();
    /// @notice The schedule has been voided by expiry, so no release will ever succeed.
    error ScheduleVoided();
    /// @notice The schedule has paid out its whole allocation, so nothing is left to release.
    error ScheduleFullyReleased();
    /// @notice Nothing is releasable at this block time on a schedule that can still release.
    error NothingToRelease();
    /// @notice The launch token did not deliver the allocation.
    error TokenTransferFailed();

    /// @notice Creates the caller's schedule and pulls the allocation from the caller.
    /// @param creator The address every release of this schedule pays.
    /// @param token The launch token being vested.
    /// @param allocation Base units to pull from the caller and vest.
    /// @param cliff Seconds after `start` before anything is releasable.
    /// @param duration Seconds of linear release after the cliff.
    function createSchedule(
        address creator,
        address token,
        uint128 allocation,
        uint32 cliff,
        uint32 duration
    ) external;

    /// @notice Starts the caller's schedule at the current block time.
    function start() external;

    /// @notice Voids the caller's schedule, stranding the allocation permanently.
    function void() external;

    /// @notice Releases everything vested so far to the launch's recorded creator.
    /// @dev Reverts `ScheduleVoided` on a voided schedule, `ScheduleFullyReleased` on one
    /// that has paid its allocation in full, and `NothingToRelease` when a schedule that
    /// can still release has nothing vested at this block time.
    /// @param launch The launch whose schedule to release.
    /// @return amount Base units transferred.
    function release(address launch) external returns (uint256 amount);

    /// @notice Base units releasable right now.
    /// @param launch The launch whose schedule to quote.
    /// @return amount Base units a `release` call would transfer at this block time.
    function releasable(address launch) external view returns (uint256 amount);

    /// @notice Reads one launch's schedule.
    /// @param launch The launch whose schedule to read.
    /// @return schedule The stored schedule, zero-valued if there is none.
    function scheduleOf(address launch) external view returns (Schedule memory schedule);
}
