// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {PledrinConstants} from "./libraries/PledrinConstants.sol";

/// @title Pledrin timelock
/// @notice Owner of `LaunchFactory`, as specified in `docs/SPEC.md` section 14. Every
/// configuration change it can make waits `TIMELOCK_DELAY` seconds between proposal and
/// execution, measured with `block.timestamp`.
/// @dev Holds nothing. It is not payable, has no receive function, and every operation it
/// executes is a zero-value call, so no path exists by which this contract can hold or
/// move value. Its authority is exactly the set of `onlyOwner` functions on the contract
/// it owns: pause new launches, change the defaults future launches copy, and change the
/// treasury future launches record. The admin's own rotation is itself an operation and
/// therefore also waits out the delay.
contract Timelock {
    using SafeCast for uint256;

    /// @notice Seconds between a proposal and the earliest moment it can execute.
    uint256 public constant DELAY = PledrinConstants.TIMELOCK_DELAY;

    /// @notice The only address that may propose, cancel or execute an operation.
    address public admin;

    /// @notice Block time at which a pending operation becomes executable, zero when the
    /// operation is not pending.
    mapping(bytes32 id => uint64 timestamp) public readyAt;

    /// @notice An operation was queued.
    event OperationProposed(
        bytes32 indexed id, address indexed target, bytes data, bytes32 salt, uint64 readyAt
    );
    /// @notice An operation was executed.
    event OperationExecuted(bytes32 indexed id, address indexed target, bytes data, bytes32 salt);
    /// @notice A pending operation was dropped.
    event OperationCancelled(bytes32 indexed id);
    /// @notice The admin changed.
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    /// @notice The caller is not the admin.
    error NotAdmin();
    /// @notice Only the timelock itself may call this, which means only through an
    /// operation that has waited out the delay.
    error NotTimelock();
    /// @notice The operation is already pending.
    error AlreadyProposed(bytes32 id);
    /// @notice The operation is not pending.
    error NotProposed(bytes32 id);
    /// @notice The operation's delay has not elapsed.
    error DelayNotElapsed(bytes32 id, uint64 readyAt);
    /// @notice The address supplied is the zero address.
    error InvalidAdmin();

    /// @dev Restricts a call to the admin.
    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// @notice Sets the first admin.
    /// @param initialAdmin The address that may propose, cancel and execute operations.
    constructor(address initialAdmin) {
        if (initialAdmin == address(0)) revert InvalidAdmin();

        admin = initialAdmin;

        emit AdminTransferred(address(0), initialAdmin);
    }

    /// @notice Queues an operation.
    /// @param target The contract the operation calls.
    /// @param data The calldata the operation sends.
    /// @param salt Distinguishes two otherwise identical operations.
    /// @return id The operation's identifier.
    function propose(address target, bytes calldata data, bytes32 salt)
        external
        onlyAdmin
        returns (bytes32 id)
    {
        id = operationId(target, data, salt);
        if (readyAt[id] != 0) revert AlreadyProposed(id);

        uint64 ready = (block.timestamp + DELAY).toUint64();
        readyAt[id] = ready;

        emit OperationProposed(id, target, data, salt, ready);
    }

    /// @notice Drops a pending operation.
    /// @param id The operation's identifier.
    function cancel(bytes32 id) external onlyAdmin {
        if (readyAt[id] == 0) revert NotProposed(id);

        delete readyAt[id];

        emit OperationCancelled(id);
    }

    /// @notice Executes an operation whose delay has elapsed.
    /// @dev The pending record is cleared before the call, so an operation executes at
    /// most once however the target behaves.
    /// @param target The contract the operation calls.
    /// @param data The calldata the operation sends.
    /// @param salt The salt the operation was proposed with.
    /// @return result The target's return data.
    function execute(address target, bytes calldata data, bytes32 salt)
        external
        onlyAdmin
        returns (bytes memory result)
    {
        bytes32 id = operationId(target, data, salt);
        uint64 ready = readyAt[id];
        if (ready == 0) revert NotProposed(id);
        if (block.timestamp < ready) revert DelayNotElapsed(id, ready);

        delete readyAt[id];

        emit OperationExecuted(id, target, data, salt);

        result = Address.functionCall(target, data);
    }

    /// @notice Rotates the admin. Reachable only through an executed operation.
    /// @param newAdmin The new admin.
    function setAdmin(address newAdmin) external {
        if (msg.sender != address(this)) revert NotTimelock();
        if (newAdmin == address(0)) revert InvalidAdmin();

        address previous = admin;
        admin = newAdmin;

        emit AdminTransferred(previous, newAdmin);
    }

    /// @notice The identifier of an operation.
    /// @param target The contract the operation calls.
    /// @param data The calldata the operation sends.
    /// @param salt Distinguishes two otherwise identical operations.
    /// @return The operation's identifier.
    function operationId(address target, bytes calldata data, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(target, keccak256(data), salt));
    }
}
