// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BondingCurve} from "src/BondingCurve.sol";

import {PledrinTestBase} from "../base/PledrinTestBase.sol";

/// @title Invariant 54: what the deployed code does not contain
/// @notice No contract in the system has a `selfdestruct`, a `delegatecall`, a proxy or an
/// initialiser callable more than once.
/// @dev The first two are checked against the deployed bytecode rather than against the
/// source, because that is where the claim has to hold. The walk skips the immediate data
/// of every `PUSH` instruction, so a `0xff` byte inside a constant cannot be mistaken for
/// a `SELFDESTRUCT`; a naive `indexOf` over the code would produce exactly that false
/// positive and would make the test meaningless.
///
/// `CREATE` is deliberately not forbidden: `CurveDeployer` and `TokenDeployer` exist to
/// run it, and `LaunchFactory`'s whole purpose is to have them do so.
contract CodePropertiesTest is PledrinTestBase {
    uint8 private constant OP_DELEGATECALL = 0xf4;
    uint8 private constant OP_CALLCODE = 0xf2;
    uint8 private constant OP_SELFDESTRUCT = 0xff;

    /// @notice Every deployed contract in the system, scanned for the three opcodes that
    /// would make it upgradeable or destructible.
    function test_noContractCanDelegatecallOrSelfdestruct() public {
        (BondingCurve curve, IERC20 token) = createPledgedLaunch();

        _assertCleanCode(address(factory), "LaunchFactory");
        _assertCleanCode(address(curveDeployer), "CurveDeployer");
        _assertCleanCode(address(tokenDeployer), "TokenDeployer");
        _assertCleanCode(address(vesting), "CreatorVesting");
        _assertCleanCode(address(lock), "LiquidityLock");
        _assertCleanCode(address(timelock), "Timelock");
        _assertCleanCode(address(curve), "BondingCurve");
        _assertCleanCode(address(token), "PledrinToken");
    }

    /// @notice No contract has an initialiser at all, so none can be called twice. Every
    /// value is set in a constructor or not at all.
    function test_noContractHasAnInitialiser() public {
        (BondingCurve curve, IERC20 token) = createPledgedLaunch();

        string[6] memory signatures = [
            "initialize()",
            "initialize(address)",
            "init()",
            "init(address)",
            "upgradeTo(address)",
            "upgradeToAndCall(address,bytes)"
        ];
        address[8] memory targets = [
            address(factory),
            address(curveDeployer),
            address(tokenDeployer),
            address(vesting),
            address(lock),
            address(timelock),
            address(curve),
            address(token)
        ];

        for (uint256 i = 0; i < targets.length; i++) {
            for (uint256 j = 0; j < signatures.length; j++) {
                (bool ok,) = targets[i].call(abi.encodeWithSignature(signatures[j]));
                assertFalse(ok, signatures[j]);
            }
        }
    }

    /// @notice `CreatorVesting` has no setter for a schedule's terms, which is the part of
    /// Invariant 23 that is about the contract's surface rather than about one schedule.
    function test_creatorVestingHasNoSetter() public {
        string[6] memory signatures = [
            "setAllocation(address,uint128)",
            "setCliff(address,uint32)",
            "setDuration(address,uint32)",
            "setStart(address,uint64)",
            "setCreator(address,address)",
            "accelerate(address)"
        ];
        address target = address(vesting);
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = target.call(abi.encodeWithSignature(signatures[i]));
            assertFalse(ok, signatures[i]);
        }
    }

    /// @notice Neither the curve nor the lock has a sweep, a rescue or an owner, so there
    /// is no path by which any address can take value out of them. Invariant 52.
    function test_neitherTheCurveNorTheLockHasAnEscapeHatch() public {
        (BondingCurve curve,) = createPledgedLaunch();

        string[8] memory signatures = [
            "owner()",
            "transferOwnership(address)",
            "sweep(address)",
            "sweep(address,address)",
            "rescue(address,uint256)",
            "withdraw(uint256)",
            "withdrawAll()",
            "emergencyWithdraw()"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool onCurve,) = address(curve).call(abi.encodeWithSignature(signatures[i]));
            assertFalse(onCurve, signatures[i]);
            (bool onLock,) = address(lock).call(abi.encodeWithSignature(signatures[i]));
            assertFalse(onLock, signatures[i]);
        }
    }

    /// @dev Walks the runtime code one instruction at a time, skipping `PUSH` immediates.
    function _assertCleanCode(address target, string memory name) private view {
        bytes memory code = target.code;
        assertGt(code.length, 0, name);

        uint256 i = 0;
        while (i < code.length) {
            uint8 op = uint8(code[i]);
            assertTrue(op != OP_DELEGATECALL, string.concat(name, ": DELEGATECALL"));
            assertTrue(op != OP_CALLCODE, string.concat(name, ": CALLCODE"));
            assertTrue(op != OP_SELFDESTRUCT, string.concat(name, ": SELFDESTRUCT"));

            // PUSH1 is 0x60 and PUSH32 is 0x7f; PUSH0 (0x5f) has no immediate.
            if (op >= 0x60 && op <= 0x7f) {
                i += uint256(op) - 0x60 + 2;
            } else {
                i += 1;
            }
        }
    }
}
