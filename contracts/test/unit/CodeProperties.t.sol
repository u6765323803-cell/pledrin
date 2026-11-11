// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BondingCurve} from "src/BondingCurve.sol";

import {PledrinTestBase} from "../base/PledrinTestBase.sol";

/// @title What the compiled code does and does not contain
/// @notice **Invariant 54:** no contract in the system has a `selfdestruct`, a
/// `delegatecall`, a proxy or an initialiser callable more than once. **Invariant 57's
/// mutability clause:** `LiquidityLock.onERC721Received` is `view`.
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

    /// @notice **Invariant 57's mutability clause.** `LiquidityLock.onERC721Received` is
    /// declared `view`, and the compiled ABI says so.
    /// @dev Read out of the build artifact, not inferred from a call that happens not to
    /// revert, because `view` is the claim: a non-`view` function that writes nothing today
    /// would pass the weaker check and would not be what the argument needs. `view` is a
    /// compiler guarantee that the callback cannot move a token or a wei, whatever its body
    /// later becomes, and `docs/SECURITY_NOTES.md`'s `reentrancy-balance` verdict and
    /// `docs/THREAT_MODEL.md` sections 6.6 and 7 all rest on that guarantee. Dropping the
    /// keyword to make the callback do something useful would make those arguments silently
    /// false; this fails the build instead.
    ///
    /// One correction to how that argument is stated, which does not weaken the reason to
    /// pin the keyword. The callback does **not** run inside
    /// `positionManager.modifyLiquidities`: v4's PositionManager mints through
    /// `ERC721Permit_v4`, which is solmate's `ERC721`, whose `_mint` emits `Transfer` and
    /// calls no receiver hook — only `safeTransferFrom` does. `test/mocks` reproduces that
    /// absence deliberately and `test/unit/CallDiscipline.t.sol` asserts what the curve's
    /// one real in-window callee, its own `receive()`, is allowed to do. What does reach
    /// this function is a `safeTransferFrom` of any ERC-721 into the lock, from the
    /// PositionManager or from anywhere else, and `view` is what makes accepting such a
    /// token inert. Who may call it, and the magic value it answers with, are asserted in
    /// `test/unit/LiquidityLock.t.sol` and are not repeated here.
    function test_theLocksErc721CallbackIsView() public view {
        string memory artifact = vm.readFile("out/LiquidityLock.sol/LiquidityLock.json");
        string memory query = "$.abi[?(@.name == 'onERC721Received')]";

        assertEq(
            vm.parseJsonString(artifact, string.concat(query, ".stateMutability")),
            "view",
            "Invariant 57: LiquidityLock.onERC721Received must be view"
        );
        // Pinned against the entry for the IERC721Receiver callback itself rather than
        // against whichever function the query happened to find first.
        string[4] memory parameters = ["address", "address", "uint256", "bytes"];
        for (uint256 i = 0; i < parameters.length; i++) {
            assertEq(
                vm.parseJsonString(
                    artifact, string.concat(query, ".inputs[", vm.toString(i), "].type")
                ),
                parameters[i],
                "the callback's parameters"
            );
        }
        assertEq(
            vm.parseJsonString(artifact, string.concat(query, ".outputs[0].type")),
            "bytes4",
            "the callback's return type"
        );
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
