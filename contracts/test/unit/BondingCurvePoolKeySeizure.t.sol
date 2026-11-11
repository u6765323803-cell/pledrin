// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Pool} from "v4-core/src/libraries/Pool.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {ILaunchFactory} from "src/interfaces/ILaunchFactory.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {PledrinTestBase} from "../base/PledrinTestBase.sol";

/// @title A seized canonical pool key changes nothing
/// @notice Covers `docs/SPEC.md` sections 8.1 and 8.2 step 3, **Invariants 38, 64, 65 and
/// 66**, and findings 2 and 3 of
/// `docs/security/REVIEW-2026-11-11-phase1-contracts.md`.
/// @dev A launch's canonical pool key **is** computable before its launch transaction. A
/// `CREATE` address is `keccak256(rlp([deployer, nonce]))[12:]`, `TokenDeployer` is a
/// singleton at a fixed address, and its nonce is one `eth_getTransactionCount` away — so
/// the token the next launch will deploy has a knowable address, and therefore a knowable
/// pool key, at any time. `vm.computeCreateAddress` is that computation, and every test
/// here uses it to act against a launch that does not exist yet.
///
/// While `initialize` was unconditional, seizing that key for roughly 47,000 gas reverted
/// `createLaunch`, and because the revert rolled `TokenDeployer`'s nonce back, every later
/// attempt targeted the same seized address: the protocol's only entry point was deniable
/// for the price of a rounding error. Decision 22 made the call conditional. What these
/// tests assert is that the condition changed nothing else — the seizure is now visible in
/// one log and in no number anywhere.
contract BondingCurvePoolKeySeizureTest is PledrinTestBase {
    /// @dev Everything about a launch an attacker must not be able to move.
    struct LaunchState {
        address token;
        bytes32 poolId;
        uint8 state;
        uint8 bondState;
        uint160 sqrtPriceTerminal;
        uint128 ethTarget;
        uint128 virtualEthReserve;
        uint128 ethReserve;
        uint256 tokensSold;
        uint128 creatorFeeEth;
        uint128 protocolFeeEth;
        uint128 protectionEth;
        uint128 bondHeldWei;
        uint128 bondWei;
        uint64 gradDeadline;
        uint16 totalFeeBps;
        bool pledged;
        uint256 curveTokenBalance;
        uint256 curveEthBalance;
    }

    // ------------------------------------------------------------------
    // Invariant 64: the launch is created whatever was done to the key
    // ------------------------------------------------------------------

    /// @notice **Invariant 64, by fuzz over the seized price.** For any price a third party
    /// opens the canonical key at, the launch is created and every number about it is the
    /// number it would have had on an untouched key.
    /// @dev Differential, and the `vm.revertToState` is what makes it one: rolling the
    /// state back restores `TokenDeployer`'s nonce, so the second launch deploys its token
    /// to the *same address* and lands on the *same pool key* as the first. Without that
    /// the two launches would have different keys and nothing could be compared.
    function testFuzz_aSeizedCanonicalKeyChangesNothingAboutTheLaunch(uint256 priceSeed) public {
        uint160 seized =
            uint160(bound(priceSeed, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));

        uint256 snapshot = vm.snapshotState();
        LaunchState memory baseline = _createAndRead();
        assertTrue(vm.revertToState(snapshot), "the baseline state was restored");

        PoolKey memory key = canonicalKey(_predictedToken());
        poolManager.initialize(key, seized);
        assertEq(poolManager.initializedPoolCount(), 1, "the attacker opened the key");

        LaunchState memory seizedRun = _createAndRead();

        assertEq(seizedRun.token, baseline.token, "the same token address, from the same nonce");
        assertEq(seizedRun.poolId, baseline.poolId, "and therefore the same canonical key");
        assertEq(abi.encode(seizedRun), abi.encode(baseline), "Invariant 64: field for field");

        // The curve left the foreign price exactly where it found it, and did not open the
        // key a second time.
        (uint160 price,) = poolManager.slot0(PoolId.wrap(seizedRun.poolId));
        assertEq(price, seized, "the seized price is untouched");
        assertEq(poolManager.initializedPoolCount(), 1, "nothing was initialised twice");
    }

    /// @notice The seizure is reported, once, in the launch transaction.
    /// @dev `PoolPreInitialized` is how the read side marks a launch whose canonical pool
    /// Pledrin did not open, and how often this happens becomes a number the protocol can
    /// count instead of guess.
    function test_aSeizedKeyEmitsPoolPreInitializedAndAnUntouchedKeyDoesNot() public {
        uint160 seized = TickMath.getSqrtPriceAtTick(100_000);
        address predicted = _predictedToken();
        poolManager.initialize(canonicalKey(predicted), seized);

        vm.recordLogs();
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        assertEq(address(token), predicted, "the seized key was this launch's key");
        assertEq(
            _poolPreInitializedCount(address(curve), address(token), seized),
            1,
            "Invariant 64: the one difference a seizure makes is this log"
        );

        // An untouched key emits nothing of the kind.
        vm.recordLogs();
        (BondingCurve clean, IERC20 cleanToken) = createDefaultLaunch();
        assertEq(
            _poolPreInitializedCount(address(clean), address(cleanToken), 0),
            0,
            "and it is absent in the ordinary case"
        );
        (uint160 price,) = poolManager.slot0(clean.poolId());
        assertEq(price, clean.sqrtPriceTerminal(), "which opened the key itself");
    }

    /// @notice A launch whose canonical key was seized still graduates on it: the price is
    /// restored for free first, and the assertion before the mint is what protects it.
    /// @dev This is the property that replaced "no attacker can reach the pool key first".
    /// No attacker can choose a Pledrin pool's price **at the moment liquidity enters it**,
    /// which is the claim the design can actually support.
    function test_aLaunchOnASeizedKeyStillGraduatesOnIt() public {
        poolManager.initialize(
            canonicalKey(_predictedToken()), TickMath.getSqrtPriceAtTick(-50_000)
        );

        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        buyToCap(curve);

        vm.recordLogs();
        vm.prank(GRADUATOR);
        curve.graduate();

        GraduatedLog memory log = graduatedLog(address(curve));
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "Graduated");
        assertEq(poolManager.swapCalls(), 1, "one free restoring swap, on the seized key");
        (uint160 price,) = poolManager.slot0(curve.poolId());
        assertEq(price, curve.sqrtPriceTerminal(), "Invariant 40 before the mint");
        assertEq(
            log.poolId,
            PoolId.unwrap(canonicalKey(address(token)).toId()),
            "and it graduated on the canonical key, seizure and all"
        );
    }

    // ------------------------------------------------------------------
    // Invariant 65: the condition is a test on slot0 and nothing else
    // ------------------------------------------------------------------

    /// @notice **Invariant 65.** The constructor calls `initialize` if and only if the
    /// canonical key's `sqrtPriceX96` is zero when it reads it.
    function test_theConstructorInitialisesExactlyWhenTheKeyIsUnopened() public {
        assertEq(poolManager.initializedPoolCount(), 0, "nothing is open yet");

        (BondingCurve first,) = createDefaultLaunch();
        assertEq(poolManager.initializedPoolCount(), 1, "an unopened key is opened");
        (uint160 price,) = poolManager.slot0(first.poolId());
        assertEq(price, first.sqrtPriceTerminal(), "at the terminal price");

        poolManager.initialize(canonicalKey(_predictedToken()), 1 << 96);
        assertEq(poolManager.initializedPoolCount(), 2, "the next key is opened by somebody else");

        createDefaultLaunch();
        assertEq(poolManager.initializedPoolCount(), 2, "and the launch does not open it again");
    }

    /// @notice **Invariant 65's second clause.** An unopened key whose `initialize` fails
    /// for any *other* reason still reverts the launch.
    /// @dev The condition in the constructor is a test on `slot0`, not a caught revert, and
    /// the distinction is normative. `initialize` also refuses an out-of-range tick
    /// spacing, an LP fee above `MAX_LP_FEE`, currencies out of order and a hook address v4
    /// rejects. None can fire at any permitted parameter set — every input is a protocol
    /// constant or the token address — which is exactly why none may be swallowed:
    /// suppressing them would hide a misconfiguration behind a branch that reads as a
    /// griefed pool. Reaching the clause needs the stand-in to produce a refusal the real
    /// contract has and the stand-in does not model, which is what
    /// `setInitializeRevertData` is for.
    function test_anInitializeThatFailsForAnyOtherReasonStillRevertsTheLaunch() public {
        bytes memory refusal = abi.encodeWithSignature("TickSpacingTooLarge(int24)", int24(200));
        poolManager.setInitializeRevertData(refusal);

        vm.prank(CREATOR);
        vm.expectRevert(refusal);
        factory.createLaunch(defaultParams());

        // And the same refusal is *not* reached when the key is already open, because the
        // call is not made at all. Same mock state, opposite outcome.
        poolManager.setInitializeRevertData("");
        poolManager.initialize(canonicalKey(_predictedToken()), 1 << 96);
        poolManager.setInitializeRevertData(refusal);

        (BondingCurve curve,) = createDefaultLaunch();
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Live), "the launch was created");
    }

    /// @notice The canonical key can only be opened once by anybody, which is the v4
    /// behaviour the condition exists to accommodate.
    function test_theRealInitializeRefusesASecondCallOnTheSameKey() public {
        (BondingCurve curve,) = createDefaultLaunch();
        // Built first: `vm.expectRevert` attaches to the next call of any kind, and
        // `curve.token()` is a call.
        PoolKey memory key = canonicalKey(address(curve.token()));

        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        poolManager.initialize(key, 1 << 96);
    }

    // ------------------------------------------------------------------
    // Invariants 66 and 38: liquidity is neither read nor needed
    // ------------------------------------------------------------------

    /// @notice **Invariant 66.** Third-party liquidity on the key a graduation uses changes
    /// nothing about that graduation, and is untouched afterwards.
    /// @dev Differential over `L`. A mint's amounts are a function of the price and of the
    /// position's own range, so liquidity somebody else holds cannot change what graduation
    /// deposits — and since the price is asserted equal to `sqrtPriceTerminal` immediately
    /// before the mint, it cannot change the price the mint sees either. The real version of
    /// this test is in the fork suite, where `L` is a position minted through the deployed
    /// PositionManager rather than a number this stand-in records; what it adds here is the
    /// differential, which a fork test cannot run twice from the same state.
    function testFuzz_graduationIsIndifferentToThirdPartyLiquidity(uint128 liquiditySeed) public {
        uint128 strangerLiquidity = uint128(bound(liquiditySeed, 1, type(uint128).max / 2));
        (BondingCurve curve, IERC20 token) = createLaunchAtCap();
        PoolId id = curve.poolId();

        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        vm.prank(GRADUATOR);
        curve.graduate();
        GraduatedLog memory baseline = graduatedLog(address(curve));
        uint256 baselineDust = token.balanceOf(address(curve));
        assertTrue(vm.revertToState(snapshot), "the baseline state was restored");

        poolManager.setLiquidity(id, strangerLiquidity);
        vm.recordLogs();
        vm.prank(GRADUATOR);
        curve.graduate();
        GraduatedLog memory withLiquidity = graduatedLog(address(curve));

        assertEq(
            abi.encode(withLiquidity), abi.encode(baseline), "Invariant 66: the same graduation"
        );
        assertEq(token.balanceOf(address(curve)), baselineDust, "and the same dust");
        assertEq(
            poolManager.liquidity(id),
            strangerLiquidity + positionManager.getPositionLiquidity(withLiquidity.positionIdCore),
            "Invariant 66: the stranger's liquidity is untouched, with the core position"
            " added on top of it"
        );
    }

    /// @notice **Invariant 38's second clause, directly.** No Pledrin contract reads a
    /// pool's liquidity — not in the constructor, not in either graduation path.
    /// @dev Asserted against the storage the call actually touched rather than by reading
    /// the source. `StateLibrary` puts a pool's active liquidity three words after its
    /// `slot0`, and the protocol reads `slot0` through `extsload`, so both slots are one
    /// `sload` away from each other and a check on liquidity would be a one-line change
    /// that no behavioural test would notice. `vm.accesses` sees every slot read on the
    /// PoolManager during the whole graduation, `slot0` among them, and the liquidity slot
    /// is not there.
    function test_noGraduationEverReadsThePoolsLiquidity() public {
        (BondingCurve curve,) = createLaunchAtCap();
        PoolId id = curve.poolId();
        bytes32 liquiditySlot = poolManager.liquiditySlot(id);
        bytes32 priceSlot = poolManager.slot0Slot(id);
        poolManager.setLiquidity(id, 5e18);

        vm.record();
        vm.prank(GRADUATOR);
        curve.graduate();
        (bytes32[] memory reads,) = vm.accesses(address(poolManager));

        bool sawPrice;
        for (uint256 i = 0; i < reads.length; i++) {
            assertNotEq(reads[i], liquiditySlot, "Invariant 38: the liquidity slot is never read");
            if (reads[i] == priceSlot) sawPrice = true;
        }
        assertTrue(sawPrice, "and the price slot is, so the recording is not empty");
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev The address the next launch's token will have. Public inputs only: the
    /// deployer's address and its nonce.
    function _predictedToken() private view returns (address) {
        return vm.computeCreateAddress(address(tokenDeployer), vm.getNonce(address(tokenDeployer)));
    }

    /// @dev Creates the default launch and reads everything about it that an attacker must
    /// not be able to move.
    function _createAndRead() private returns (LaunchState memory read) {
        ILaunchFactory.LaunchParams memory params = defaultParams();
        params.bondWei = 0.4 ether;
        params.creatorFirstBuyWei = 0.009 ether;
        (BondingCurve curve, IERC20 token) = createLaunch(params);

        read = LaunchState({
            token: address(token),
            poolId: PoolId.unwrap(curve.poolId()),
            state: uint8(curve.state()),
            bondState: uint8(curve.bondState()),
            sqrtPriceTerminal: curve.sqrtPriceTerminal(),
            ethTarget: curve.ethTarget(),
            virtualEthReserve: curve.virtualEthReserve(),
            ethReserve: curve.ethReserve(),
            tokensSold: curve.tokensSold(),
            creatorFeeEth: curve.creatorFeeEth(),
            protocolFeeEth: curve.protocolFeeEth(),
            protectionEth: curve.protectionEth(),
            bondHeldWei: curve.bondHeldWei(),
            bondWei: curve.bondWei(),
            gradDeadline: curve.gradDeadline(),
            totalFeeBps: curve.totalFeeBps(),
            pledged: curve.pledged(),
            curveTokenBalance: token.balanceOf(address(curve)),
            curveEthBalance: address(curve).balance
        });
    }

    /// @dev How many `PoolPreInitialized` logs this launch emitted, and with what. The
    /// price is only checked when a non-zero one is expected.
    function _poolPreInitializedCount(address curve, address token, uint160 expectedPrice)
        private
        view
        returns (uint256 count)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("PoolPreInitialized(address,address,uint160)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != topic || logs[i].emitter != curve) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), curve, "the launch");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), token, "the token");
            if (expectedPrice != 0) {
                assertEq(abi.decode(logs[i].data, (uint160)), expectedPrice, "the seized price");
            }
            count++;
        }
    }
}
