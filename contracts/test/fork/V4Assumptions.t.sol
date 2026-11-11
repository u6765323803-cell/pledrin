// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint128} from "v4-core/src/libraries/FixedPoint128.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SlippageCheck} from "v4-periphery/src/libraries/SlippageCheck.sol";

import {PoolSwapHelper} from "../helpers/PoolSwapHelper.sol";
import {PositionHolder} from "../helpers/PositionHolder.sol";
import {TestERC20} from "../helpers/TestERC20.sol";

/// @dev `permit2()` is a public immutable on the deployed `PositionManager` but is not
/// declared on `IPositionManager`, so the wiring probe reads it through this.
interface IPositionManagerPermit2 {
    function permit2() external view returns (address);
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title The six v4 behaviours `docs/SPEC.md` assumes, measured against the live
/// Uniswap v4 deployment on Robinhood Chain.
///
/// Each assumption is listed in the appendix of `docs/OPEN_DECISIONS.md`
/// ("Verification prerequisites for Phase 1"). Nothing here is encoded from memory:
/// every action sequence was built from `contracts/lib/v4-periphery/src` and
/// `contracts/lib/v4-periphery/lib/v4-core/src`, and every number is read back off
/// the forked chain.
///
/// Results: assumptions 1, 2, 5 and 6 held as stated. Three were refuted, and **all three
/// refutations have since been accepted into the specification**, so nothing in this file
/// is an open disagreement — each `_refuted_` test is the measurement the current
/// specification now states:
///
/// - **Assumption 3, refuted.** The floor position's tick direction was inverted. The
///   range the specification gave was below the current tick, which v4 funds in
///   `currency1`, so it would have minted a sell wall out of the token instead of a
///   standing ETH bid. The specification was corrected to the range this test measured —
///   `tickLower = alignDown(currentTick, tickSpacing) + tickSpacing`, strictly above the
///   current tick — and that range is now what spec 8.2 step 8, spec 10.1 and Invariant 42
///   say. Spec 10.1 quotes this test's numbers. This was the most consequential defect
///   found in the project, and it was found here.
/// - **Assumption 4, half refuted.** "At most `R_target`" held; "exactly `LP_SUPPLY`"
///   cannot, because `MINT_POSITION` is parameterised by liquidity and the `currency1` it
///   owes is a step function of that. The specification was corrected to "at most `S_LP`",
///   records the shortfall this test measured at the three reserve points, and bounds it
///   by `LP_DUST_MAX` in Invariant 39 instead of assuming exactness.
/// - **The "zero-input swap" of the restoring step, refuted as a phrase.** Literally zero
///   is not a swap v4 accepts. The specification was corrected: step 2 nominates one unit
///   of exact input and "zero cost" now describes what the swap settles rather than the
///   size it names, which is the property the appendix always meant.
///
/// Every test that measures something the specification got wrong keeps its `_refuted_`
/// name, because the name records what the test did. Where a comment below quotes the
/// wording that was refuted, it says which revision it is quoting and where the corrected
/// text now lives; a citation that was renumbered to the current step while still quoting
/// the old content would read as a correction and be a lie.
///
/// @dev The fork is not pinned to a block. The Robinhood Chain mainnet RPC prunes
/// historical state after a few thousand blocks (verified: `eth_call` at head-2000
/// succeeds, at head-500000 returns "historical state ... is not available"), so a
/// pinned block would stop resolving within a day and break CI. Every assertion here
/// is about v4's code, not about chain state, so running at head is sound.
contract V4AssumptionsForkTest is Test {
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------------
    // Addresses. Every one of these is from `docs/CHAIN_FACTS.md`.
    // ---------------------------------------------------------------------

    IPoolManager internal constant POOL_MANAGER =
        IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IPositionManager internal constant POSITION_MANAGER =
        IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
    IAllowanceTransfer internal constant PERMIT2 =
        IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    // ---------------------------------------------------------------------
    // Spec constants (section 15.1, and the default `virtualEthReserve` of 15.2).
    // ---------------------------------------------------------------------

    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;

    /// @dev Spec 15.1. The bound Invariant 39 asserts on the graduation mint's
    /// token remainder. Kept identical to the specification so the test fails if
    /// either side drifts; the largest measured shortfall is 28,428.
    uint256 internal constant LP_DUST_MAX = 10 ** 5;
    uint256 internal constant LP_SUPPLY = 100_000_000e18;
    uint256 internal constant VE0 = 5e17;
    uint256 internal constant R_TARGET = 8 * VE0; // ETH_TARGET_MULTIPLE * vE0 = 4 ether
    uint24 internal constant POOL_FEE = 10_000;
    int24 internal constant POOL_TICK_SPACING = 200;
    int24 internal constant FLOOR_RANGE_TICKS = 13_800;
    uint256 internal constant MIN_FLOOR_WEI = 1e12;

    /// @dev Spec 8.1 asserts this is the tick at the default parameters.
    int24 internal constant SPEC_TERMINAL_TICK = 170_352;

    TestERC20 internal token;
    PoolSwapHelper internal swapper;
    PositionHolder internal lock;

    PoolKey internal poolKey;
    PoolId internal poolId;
    uint160 internal sqrtPriceTerminal;

    // Set by `_seedLockedPositionAndAccrueFees`. Kept in storage rather than returned
    // because the assumption-2 tests otherwise exceed the stack without via-ir.
    uint256 internal seedTokenId;
    int24 internal seedTickLower;
    int24 internal seedTickUpper;
    bytes32 internal seedPositionKey;

    receive() external payable {}

    function setUp() public {
        vm.createSelectFork("robinhood");

        token = new TestERC20("Pledrin Fork Probe", "PFP", TOTAL_SUPPLY, address(this));
        swapper = new PoolSwapHelper(POOL_MANAGER);
        lock = new PositionHolder(POSITION_MANAGER);

        poolKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: POOL_FEE,
            tickSpacing: POOL_TICK_SPACING,
            hooks: IHooks(address(0))
        });
        poolId = poolKey.toId();
        sqrtPriceTerminal = _sqrtPriceTerminal(LP_SUPPLY, R_TARGET);

        vm.deal(address(this), 10_000 ether);
    }

    // =====================================================================
    // Wiring probe (folded in from the former test/ProbeV4Wiring.t.sol).
    // =====================================================================

    /// @notice Proves the remappings resolve and that the v4 interfaces this repo
    /// compiles against match the contracts actually deployed on Robinhood Chain.
    function test_wiring_deployedPeripheryMatchesDeployedCore() public view {
        assertEq(
            address(POSITION_MANAGER.poolManager()),
            address(POOL_MANAGER),
            "periphery interface does not match the deployed contracts"
        );
        assertEq(
            IPositionManagerPermit2(address(POSITION_MANAGER)).permit2(),
            address(PERMIT2),
            "PositionManager uses a different Permit2"
        );
        assertEq(block.chainid, 4663, "fork is not Robinhood Chain mainnet");
    }

    // =====================================================================
    // Assumption 6 — `PoolManager.initialize` with `hooks = address(0)`.
    // Resolves spec 8.1.
    // =====================================================================

    function test_assumption6_initializeWithZeroHooksLeavesZeroLiquidity() public {
        int24 tick = POOL_MANAGER.initialize(poolKey, sqrtPriceTerminal);

        (uint160 sqrtPriceX96, int24 slot0Tick, uint24 protocolFee, uint24 lpFee) =
            POOL_MANAGER.getSlot0(poolId);

        emit log_named_uint("sqrtPriceTerminal", sqrtPriceTerminal);
        emit log_named_int("tick returned by initialize", tick);

        assertEq(sqrtPriceX96, sqrtPriceTerminal, "pool did not open at sqrtPriceTerminal");
        assertEq(slot0Tick, tick, "slot0 tick disagrees with the returned tick");
        assertEq(POOL_MANAGER.getLiquidity(poolId), 0, "a freshly initialised pool has liquidity");
        assertEq(uint256(lpFee), uint256(POOL_FEE), "lpFee is not the pool key's fee");
        assertEq(
            uint256(protocolFee), 0, "a freshly initialised pool already carries a protocol fee"
        );

        // Spec 8.1's arithmetic claims, checked rather than trusted.
        assertEq(
            sqrtPriceTerminal,
            5000 * (uint160(1) << 96),
            "sqrtPriceTerminal is not exactly 5000 * 2**96"
        );
        assertEq(tick, SPEC_TERMINAL_TICK, "terminal tick is not the one spec 8.1 states");
        assertGt(
            sqrtPriceTerminal, TickMath.MIN_SQRT_PRICE, "sqrtPriceTerminal is below MIN_SQRT_PRICE"
        );

        // The pool key cannot be initialised twice, which is what makes initialising in
        // the launch transaction an anti-grief measure (spec 8.4).
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        POOL_MANAGER.initialize(poolKey, sqrtPriceTerminal);
    }

    /// @notice The whole permitted `virtualEthReserve` range initialises, and lands
    /// inside v4's tick bounds. Spec 8.1 claims ticks 115135 to 207243.
    function test_assumption6_initializeAcrossThePermittedVirtualReserveRange() public {
        uint256[2] memory bounds = [uint256(1.25e16), uint256(1.25e20)];
        int24[2] memory observed;

        for (uint256 i = 0; i < bounds.length; i++) {
            TestERC20 t = new TestERC20("x", "x", TOTAL_SUPPLY, address(this));
            PoolKey memory key = PoolKey({
                currency0: CurrencyLibrary.ADDRESS_ZERO,
                currency1: Currency.wrap(address(t)),
                fee: POOL_FEE,
                tickSpacing: POOL_TICK_SPACING,
                hooks: IHooks(address(0))
            });
            uint160 sqrtPrice = _sqrtPriceTerminal(LP_SUPPLY, 8 * bounds[i]);
            observed[i] = POOL_MANAGER.initialize(key, sqrtPrice);
            assertEq(POOL_MANAGER.getLiquidity(key.toId()), 0, "pool opened with liquidity");
            assertGt(sqrtPrice, TickMath.MIN_SQRT_PRICE, "sqrtPriceTerminal below MIN_SQRT_PRICE");
            assertLt(sqrtPrice, TickMath.MAX_SQRT_PRICE, "sqrtPriceTerminal above MAX_SQRT_PRICE");
        }

        emit log_named_int("tick at vE0 = 1.25e20 (R_target 1000 ETH)", observed[1]);
        emit log_named_int("tick at vE0 = 1.25e16 (R_target 0.1 ETH)", observed[0]);

        assertEq(observed[1], 115_135, "lower bound tick is not the one spec 8.1 states");
        assertEq(observed[0], 207_243, "upper bound tick is not the one spec 8.1 states");
    }

    // =====================================================================
    // Assumption 5 — the approval path. Resolves the two approval legs inside spec 8.2
    // step 4, which is the core mint; the approvals are part of that step rather than a
    // step of their own.
    // =====================================================================

    function test_assumption5_approvalPathIsTokenToPermit2ThenPermit2ToPositionManager() public {
        POOL_MANAGER.initialize(poolKey, sqrtPriceTerminal);

        (int24 tickLower, int24 tickUpper) = _coreRange();
        uint128 liquidity = _coreLiquidity(tickLower);
        bytes memory mintData = _mintCalldata(
            tickLower, tickUpper, liquidity, uint128(R_TARGET), uint128(LP_SUPPLY), address(lock)
        );

        bool ok;
        bytes memory ret;

        // (a) No approval of any kind: Permit2 rejects on expiration, which for an
        //     untouched allowance slot is 0.
        (ok, ret) = _tryModify(mintData, R_TARGET);
        assertFalse(ok, "mint succeeded with no approvals at all");
        emit log_named_bytes("revert: no approvals", ret);
        assertEq(
            bytes4(ret),
            IAllowanceTransfer.AllowanceExpired.selector,
            "unexpected revert with no approvals"
        );

        // (b) Approving PositionManager directly on the token is NOT the path.
        token.approve(address(POSITION_MANAGER), type(uint256).max);
        (ok, ret) = _tryModify(mintData, R_TARGET);
        assertFalse(ok, "a direct token approval to PositionManager was accepted");
        assertEq(
            bytes4(ret),
            IAllowanceTransfer.AllowanceExpired.selector,
            "unexpected revert with direct approval"
        );
        token.approve(address(POSITION_MANAGER), 0);

        // (c) token.approve(PERMIT2) on its own is not enough.
        token.approve(address(PERMIT2), LP_SUPPLY);
        (ok, ret) = _tryModify(mintData, R_TARGET);
        assertFalse(ok, "mint succeeded without PERMIT2.approve");
        assertEq(
            bytes4(ret),
            IAllowanceTransfer.AllowanceExpired.selector,
            "unexpected revert without PERMIT2.approve"
        );

        // (d) PERMIT2.approve on its own is not enough either: Permit2 clears its own
        //     allowance check and then fails pulling the token.
        token.approve(address(PERMIT2), 0);
        PERMIT2.approve(
            address(token), address(POSITION_MANAGER), uint160(LP_SUPPLY), type(uint48).max
        );
        (ok, ret) = _tryModify(mintData, R_TARGET);
        assertFalse(ok, "mint succeeded without token.approve(PERMIT2)");
        emit log_named_bytes("revert: PERMIT2.approve only", ret);
        assertEq(
            ret,
            abi.encodeWithSignature("Error(string)", "TRANSFER_FROM_FAILED"),
            "Permit2 did not fail inside the ERC-20 transfer"
        );

        // (e) Both legs, and nothing else: the exact approval sequence of spec 8.2 step 4.
        token.approve(address(PERMIT2), LP_SUPPLY);
        (ok, ret) = _tryModify(mintData, R_TARGET);
        assertTrue(ok, "the specified two-leg approval path did not work");

        // The two legs are exactly what was needed: PositionManager was never approved
        // on the token, and no signature-based permit was used.
        assertEq(
            token.allowance(address(this), address(POSITION_MANAGER)),
            0,
            "a direct approval was left behind"
        );
        assertEq(_ownerOf(POSITION_MANAGER.nextTokenId() - 1), address(lock), "position not minted");
    }

    // =====================================================================
    // Assumption 4 — core position: exactly LP_SUPPLY, at most R_target.
    // Resolves spec 8.2 step 4 and Invariant 39.
    // =====================================================================

    function test_assumption4_refuted_corePositionCannotConsumeExactlyLpSupply() public {
        POOL_MANAGER.initialize(poolKey, sqrtPriceTerminal);
        _approvePositionManager(LP_SUPPLY);

        (int24 tickLower, int24 tickUpper) = _coreRange();
        assertEq(tickLower, -887_200, "core tickLower is not alignUp(MIN_TICK, 200)");
        assertEq(tickUpper, 887_200, "core tickUpper is not alignDown(MAX_TICK, 200)");

        uint128 liquidity = _coreLiquidity(tickLower);
        uint256 predicted0 = SqrtPriceMath.getAmount0Delta(
            sqrtPriceTerminal, TickMath.getSqrtPriceAtTick(tickUpper), liquidity, true
        );
        uint256 predicted1 = SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceTerminal, liquidity, true
        );

        uint256 ethBefore = address(this).balance;
        uint256 tokenBefore = token.balanceOf(address(this));

        (bool ok,) = _tryModify(
            _mintCalldata(
                tickLower,
                tickUpper,
                liquidity,
                uint128(R_TARGET),
                uint128(LP_SUPPLY),
                address(lock)
            ),
            R_TARGET
        );
        assertTrue(ok, "core position mint failed");

        uint256 ethUsed = ethBefore - address(this).balance;
        uint256 tokenUsed = tokenBefore - token.balanceOf(address(this));

        emit log_named_uint("core liquidity", liquidity);
        emit log_named_uint("predicted currency0 (wei)", predicted0);
        emit log_named_uint("predicted currency1 (base units)", predicted1);
        emit log_named_uint("actual currency0 consumed (wei)", ethUsed);
        emit log_named_uint("actual currency1 consumed (base units)", tokenUsed);
        emit log_named_uint("R_target (wei)", R_TARGET);
        emit log_named_uint("LP_SUPPLY (base units)", LP_SUPPLY);
        emit log_named_uint("token residual left on the payer", LP_SUPPLY - tokenUsed);
        emit log_named_uint("eth residual returned to the payer", R_TARGET - ethUsed);

        assertEq(ethUsed, predicted0, "currency0 consumed does not match the local prediction");
        assertEq(tokenUsed, predicted1, "currency1 consumed does not match the local prediction");

        // The "at most R_target" half of the assumption holds.
        assertLe(ethUsed, R_TARGET, "core position consumed more than R_target of currency0");

        // The "exactly LP_SUPPLY" half does not. `MINT_POSITION` is parameterised by
        // liquidity, and the currency1 amount owed for a given liquidity is a step
        // function of it, so no liquidity value lands on LP_SUPPLY exactly.
        assertLt(tokenUsed, LP_SUPPLY, "currency1 consumed was exactly LP_SUPPLY after all");

        // One more unit of liquidity overshoots LP_SUPPLY, so `liquidity` is the largest
        // value that fits: the shortfall is irreducible, not a sizing mistake.
        assertGt(
            SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceTerminal, liquidity + 1, true
            ),
            LP_SUPPLY,
            "liquidity + 1 would also have fitted inside LP_SUPPLY"
        );

        // The residual is recoverable: the unspent currency1 never left the payer, and
        // the unspent currency0 came back via SWEEP. Both are still spendable.
        assertEq(
            token.balanceOf(address(this)),
            TOTAL_SUPPLY - tokenUsed,
            "token residual was not left with the payer"
        );
        token.transfer(address(lock), LP_SUPPLY - tokenUsed);
        assertEq(
            token.balanceOf(address(lock)),
            LP_SUPPLY - tokenUsed,
            "token residual was not transferable"
        );
        assertEq(address(POSITION_MANAGER).balance, 0, "PositionManager kept ETH after SWEEP");

        // Minting cannot move the price, which is what Invariant 40 depends on.
        (uint160 sqrtPriceAfter,,,) = POOL_MANAGER.getSlot0(poolId);
        assertEq(sqrtPriceAfter, sqrtPriceTerminal, "minting the core position moved the price");
    }

    /// @notice An `amount0Max` of exactly `R_target` is accepted, and one wei less is not.
    /// This fixes where the boundary of Invariant 39's "at most 8 * vE0" actually sits.
    function test_assumption4_rTargetIsTheExactCurrency0Bound() public {
        POOL_MANAGER.initialize(poolKey, sqrtPriceTerminal);
        _approvePositionManager(LP_SUPPLY);

        (int24 tickLower, int24 tickUpper) = _coreRange();
        uint128 liquidity = _coreLiquidity(tickLower);
        uint256 needed = SqrtPriceMath.getAmount0Delta(
            sqrtPriceTerminal, TickMath.getSqrtPriceAtTick(tickUpper), liquidity, true
        );

        emit log_named_uint("currency0 needed (wei)", needed);
        emit log_named_int(
            "R_target minus currency0 needed (wei)", int256(R_TARGET) - int256(needed)
        );

        (bool ok, bytes memory ret) = _tryModify(
            _mintCalldata(
                tickLower,
                tickUpper,
                liquidity,
                uint128(needed - 1),
                uint128(LP_SUPPLY),
                address(lock)
            ),
            R_TARGET
        );
        assertFalse(ok, "an amount0Max below the required amount was accepted");
        assertEq(
            bytes4(ret),
            SlippageCheck.MaximumAmountExceeded.selector,
            "unexpected revert on amount0Max"
        );

        (ok,) = _tryModify(
            _mintCalldata(
                tickLower,
                tickUpper,
                liquidity,
                uint128(R_TARGET),
                uint128(LP_SUPPLY),
                address(lock)
            ),
            R_TARGET
        );
        assertTrue(ok, "amount0Max = R_target was rejected");
    }

    /// @notice The size of the shortfall, across the whole permitted `virtualEthReserve`
    /// range. It is a few hundred base units — dust, but never zero, which is why
    /// spec 8.2 and Invariant 39 bound the remainder by `LP_DUST_MAX` instead of
    /// claiming the mint is token-exact.
    function test_assumption4_currency1ShortfallAcrossThePermittedRange() public {
        uint256[3] memory reserves = [uint256(1.25e16), uint256(5e17), uint256(1.25e20)];
        for (uint256 i = 0; i < reserves.length; i++) {
            (uint256 short0, uint256 short1) = _measureCoreShortfall(reserves[i]);
            emit log_named_uint("vE0 (wei)", reserves[i]);
            emit log_named_uint("  currency0 left unspent of R_target (wei)", short0);
            emit log_named_uint("  currency1 left unspent of LP_SUPPLY (base units)", short1);
            assertGt(short1, 0, "currency1 was consumed exactly");
            assertLe(short1, LP_DUST_MAX, "the currency1 shortfall exceeds LP_DUST_MAX");
            // The currency0 side has no spec constant: it is bounded by amount0Max,
            // which graduation sets to R_target. Asserted against the same dust bound
            // only to catch a gross regression, not because the spec requires it.
            assertLt(short0, LP_DUST_MAX, "the currency0 shortfall is larger than dust");
        }
    }

    // =====================================================================
    // Assumption 3 — single-sided native-ETH floor position.
    // Resolves spec 8.2 step 8, spec 10.1 and Invariant 42, all three of which now state
    // the range the second test below measured rather than the one the first refutes.
    // =====================================================================

    function test_assumption3_refuted_rangeBelowCurrentTickIsFundedInCurrency1NotCurrency0()
        public
    {
        POOL_MANAGER.initialize(poolKey, sqrtPriceTerminal);
        (, int24 currentTick,,) = POOL_MANAGER.getSlot0(poolId);

        // The range a superseded revision of section 8.2 specified, verbatim: at the time
        // this test was written the floor was given as a band *below* the current tick, and
        // the step was numbered 6. What follows refuted it, and the specification was
        // corrected to the range the next test measures, which is above the current tick
        // and now lives in step 8. The old range is kept here, attributed to the revision
        // that contained it, because this test's whole value is showing what it would have
        // minted.
        int24 tickUpper = _alignDown(currentTick, POOL_TICK_SPACING) - POOL_TICK_SPACING;
        int24 tickLower = tickUpper - _alignDown(FLOOR_RANGE_TICKS, POOL_TICK_SPACING);
        assertLt(
            tickUpper, currentTick, "the specified range is not strictly below the current tick"
        );

        uint256 floorEth = 1 ether;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), floorEth
        );
        (uint256 needs0, uint256 needs1) = _requiredAmounts(tickLower, tickUpper, liquidity);

        emit log_named_int("currentTick", currentTick);
        emit log_named_int("spec tickLower", tickLower);
        emit log_named_int("spec tickUpper", tickUpper);
        emit log_named_uint("currency0 the pool requires for this range", needs0);
        emit log_named_uint("currency1 the pool requires for this range", needs1);

        // v4 geometry: a range entirely below the current tick is composed of currency1.
        // The superseded section 10.1 claimed that `tickUpper < currentTick` "guarantees
        // the position is single-sided in currency0". It guarantees the opposite, which is
        // what the two assertions below measure. The current 10.1 states the direction in
        // both vocabularies — tick terms and price terms — and says explicitly that a range
        // below the current tick would mint a sell wall out of the token.
        assertEq(needs0, 0, "a range below the current tick wants currency0");
        assertGt(needs1, 0, "a range below the current tick does not want currency1");

        // Funded with ETH and nothing else, the mint is rejected on the currency1 leg.
        (bool ok, bytes memory ret) = _tryModify(
            _mintCalldata(tickLower, tickUpper, liquidity, uint128(floorEth), 0, address(lock)),
            floorEth
        );
        assertFalse(ok, "an ETH-only mint below the current tick succeeded");
        emit log_named_bytes("revert: ETH-only mint below current tick", ret);
        assertEq(
            bytes4(ret),
            SlippageCheck.MaximumAmountExceeded.selector,
            "unexpected revert below current tick"
        );

        // It is not a missing approval. With currency1 approved the mint succeeds and
        // spends token, not ETH: the position is a sell wall, not a floor bid.
        _approvePositionManager(needs1);
        uint256 ethBefore = address(this).balance;
        uint256 tokenBefore = token.balanceOf(address(this));
        (ok,) = _tryModify(
            _mintCalldata(
                tickLower, tickUpper, liquidity, uint128(floorEth), uint128(needs1), address(lock)
            ),
            floorEth
        );
        assertTrue(ok, "mint below the current tick failed even with currency1 approved");
        assertEq(
            ethBefore - address(this).balance, 0, "currency0 was consumed below the current tick"
        );
        assertEq(
            tokenBefore - token.balanceOf(address(this)),
            needs1,
            "currency1 consumed does not match prediction"
        );
    }

    /// @notice The behaviour the spec wanted, on the range that actually has it: a
    /// currency0-only position needs `tickLower` strictly ABOVE the current tick.
    /// @dev With `currency0 = ETH` and `currency1 = token`, the pool's price is
    /// token-per-ETH, so the token getting cheaper in ETH means the tick going UP. A
    /// standing ETH bid below the token's price therefore sits above the current tick,
    /// and a range above the current tick is the one v4 funds in currency0 alone.
    function test_assumption3_rangeAboveCurrentTickIsMintableWithEthAlone() public {
        POOL_MANAGER.initialize(poolKey, sqrtPriceTerminal);
        (, int24 currentTick,,) = POOL_MANAGER.getSlot0(poolId);

        int24 tickLower = _alignDown(currentTick, POOL_TICK_SPACING) + POOL_TICK_SPACING;
        int24 tickUpper = tickLower + _alignDown(FLOOR_RANGE_TICKS, POOL_TICK_SPACING);
        assertGt(tickLower, currentTick, "floor range is not strictly above the current tick");
        assertLe(
            tickUpper,
            _alignDown(TickMath.MAX_TICK, POOL_TICK_SPACING),
            "floor range leaves the tick bounds"
        );

        uint256 floorEth = 1 ether;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), floorEth
        );

        // No token approval of any kind is set up in this test.
        assertEq(
            token.allowance(address(this), address(PERMIT2)),
            0,
            "token approval leaked into this test"
        );

        uint256 ethBefore = address(this).balance;
        uint256 tokenBefore = token.balanceOf(address(this));

        (bool ok,) = _tryModify(
            _mintCalldata(tickLower, tickUpper, liquidity, uint128(floorEth), 0, address(lock)),
            floorEth
        );
        assertTrue(ok, "ETH-only mint above the current tick failed");

        uint256 ethUsed = ethBefore - address(this).balance;

        emit log_named_int("floor tickLower", tickLower);
        emit log_named_int("floor tickUpper", tickUpper);
        emit log_named_uint("floor liquidity", liquidity);
        emit log_named_uint("currency0 consumed (wei)", ethUsed);

        assertEq(
            token.balanceOf(address(this)), tokenBefore, "the floor position consumed currency1"
        );
        assertGt(ethUsed, 0, "the floor position consumed no currency0");
        assertLe(ethUsed, floorEth, "the floor position consumed more than floorEth");

        // It cannot move the opening price: that part of spec 8.5 point 3 holds.
        (uint160 sqrtPriceAfter, int24 tickAfter,,) = POOL_MANAGER.getSlot0(poolId);
        assertEq(sqrtPriceAfter, sqrtPriceTerminal, "the floor position moved the price");
        assertEq(tickAfter, currentTick, "the floor position moved the tick");
        assertEq(
            POOL_MANAGER.getLiquidity(poolId),
            0,
            "an out-of-range position joined the active liquidity"
        );

        // And it really is a bid: once the price rises into the range, the position has
        // spent ETH and holds token.
        assertEq(
            _ownerOf(POSITION_MANAGER.nextTokenId() - 1), address(lock), "floor position not locked"
        );
    }

    /// @notice The corrected range is economically the floor the spec describes, not just
    /// a currency0-funded position: once the price moves into it, the position has spent
    /// its ETH buying token from sellers, and holders selling into it received that ETH.
    /// @dev This is the check that settles the direction. With `currency0 = ETH` and
    /// `currency1 = token`, selling token pushes `sqrtPriceX96` UP, so the sellers a
    /// floor is meant to catch arrive from below in tick terms, at ticks above spot.
    function test_assumption3_floorRangeAboveCurrentTickIsAnEthBid() public {
        POOL_MANAGER.initialize(poolKey, sqrtPriceTerminal);
        (, int24 currentTick,,) = POOL_MANAGER.getSlot0(poolId);

        int24 tickLower = _alignDown(currentTick, POOL_TICK_SPACING) + POOL_TICK_SPACING;
        int24 tickUpper = tickLower + _alignDown(FLOOR_RANGE_TICKS, POOL_TICK_SPACING);
        uint256 floorEth = 1 ether;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), floorEth
        );

        (bool ok,) = _tryModify(
            _mintCalldata(tickLower, tickUpper, liquidity, uint128(floorEth), 0, address(lock)),
            floorEth
        );
        assertTrue(ok, "floor mint failed");

        // A holder sells into it, all the way through the range.
        token.transfer(address(swapper), 500_000_000e18);
        swapper.swap(
            poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -400_000_000e18,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickUpper)
            })
        );

        (, int24 tickAfter,,) = POOL_MANAGER.getSlot0(poolId);
        (uint256 holds0, uint256 holds1) = _requiredAmounts(tickLower, tickUpper, liquidity);

        emit log_named_int("tick after selling through the floor range", tickAfter);
        emit log_named_uint("ETH the seller received (wei)", address(swapper).balance);
        emit log_named_uint("currency0 the floor position still holds (wei)", holds0);
        emit log_named_uint("currency1 the floor position now holds (base units)", holds1);

        assertGt(tickAfter, tickLower, "the price never entered the floor range");
        assertGt(address(swapper).balance, 0, "the seller received no ETH from the floor position");
        assertEq(holds0, 0, "the floor position still holds ETH at the top of its range");
        assertGt(holds1, 0, "the floor position bought no token");
    }

    /// @notice Secondary finding, not one of the six. Spec 10.1 justifies
    /// `MIN_FLOOR_WEI = 1e12` by saying a smaller `floorEth` means "v4 would round the
    /// liquidity to zero". At the floor range that is not so: one wei already yields
    /// non-zero liquidity and mints. The constant is a harmless de-minimis threshold,
    /// but the reason given for it is not the real one.
    function test_floorPositionMintsFarBelowMinFloorWei() public {
        POOL_MANAGER.initialize(poolKey, sqrtPriceTerminal);
        (, int24 currentTick,,) = POOL_MANAGER.getSlot0(poolId);

        int24 tickLower = _alignDown(currentTick, POOL_TICK_SPACING) + POOL_TICK_SPACING;
        int24 tickUpper = tickLower + _alignDown(FLOOR_RANGE_TICKS, POOL_TICK_SPACING);

        uint128 atMin = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            MIN_FLOOR_WEI
        );
        uint128 atOneWei = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), 1
        );

        emit log_named_uint("liquidity for MIN_FLOOR_WEI (1e12 wei)", atMin);
        emit log_named_uint("liquidity for 1 wei", atOneWei);

        assertGt(atMin, 0, "MIN_FLOOR_WEI rounds the floor liquidity to zero");
        assertGt(atOneWei, 0, "1 wei of floor ETH rounds the liquidity to zero");

        uint256 ethBefore = address(this).balance;
        (bool ok,) =
            _tryModify(_mintCalldata(tickLower, tickUpper, atOneWei, 1, 0, address(lock)), 1);
        assertTrue(ok, "a one-wei floor position could not be minted");
        emit log_named_uint(
            "currency0 consumed by a one-wei floor position", ethBefore - address(this).balance
        );
        assertEq(
            ethBefore - address(this).balance, 1, "a one-wei floor position did not consume one wei"
        );
    }

    // =====================================================================
    // Assumption 1 — restoring a zero-liquidity pool's price for free.
    // Resolves spec 8.2 step 2 and Invariant 41.
    // =====================================================================

    function test_assumption1_priceOfAnEmptyPoolIsRestoredWithZeroNetDeltas() public {
        POOL_MANAGER.initialize(poolKey, sqrtPriceTerminal);
        assertEq(POOL_MANAGER.getLiquidity(poolId), 0, "pool is not empty");

        // A griefer pushes the price down to tick 100000, for free.
        uint160 griefed = TickMath.getSqrtPriceAtTick(100_000);
        BalanceDelta griefDelta = swapper.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: griefed})
        );
        (uint160 sqrtAfterGrief,,,) = POOL_MANAGER.getSlot0(poolId);

        emit log_named_int("grief delta amount0", griefDelta.amount0());
        emit log_named_int("grief delta amount1", griefDelta.amount1());
        assertEq(sqrtAfterGrief, griefed, "the grief swap did not move the price");
        assertEq(griefDelta.amount0(), 0, "the grief swap cost currency0");
        assertEq(griefDelta.amount1(), 0, "the grief swap cost currency1");

        // `graduate()` restores it. Direction follows from the comparison, and the
        // restoring swap is settled by the helper, so a non-zero delta would show up as
        // a balance change on the helper as well as in the returned delta.
        uint256 helperEthBefore = address(swapper).balance;
        uint256 helperTokenBefore = token.balanceOf(address(swapper));

        BalanceDelta restoreDelta = swapper.swap(
            poolKey,
            SwapParams({
                zeroForOne: false, amountSpecified: -1, sqrtPriceLimitX96: sqrtPriceTerminal
            })
        );
        (uint160 sqrtRestored, int24 tickRestored,,) = POOL_MANAGER.getSlot0(poolId);

        emit log_named_int("restore delta amount0", restoreDelta.amount0());
        emit log_named_int("restore delta amount1", restoreDelta.amount1());
        emit log_named_int("tick after restore", tickRestored);
        emit log_named_int(
            "getTickAtSqrtPrice(sqrtPriceTerminal)", TickMath.getTickAtSqrtPrice(sqrtPriceTerminal)
        );

        assertEq(restoreDelta.amount0(), 0, "the restoring swap had a non-zero currency0 delta");
        assertEq(restoreDelta.amount1(), 0, "the restoring swap had a non-zero currency1 delta");
        assertEq(sqrtRestored, sqrtPriceTerminal, "the price was not restored to sqrtPriceTerminal");
        assertEq(address(swapper).balance, helperEthBefore, "the restoring swap moved ETH");
        assertEq(
            token.balanceOf(address(swapper)), helperTokenBefore, "the restoring swap moved token"
        );

        // The restored tick is the exact tick of the restored price, so the floor
        // position's `currentTick` input is not skewed by the restore.
        assertEq(
            tickRestored, TickMath.getTickAtSqrtPrice(sqrtPriceTerminal), "restored tick is off"
        );
        assertEq(tickRestored, SPEC_TERMINAL_TICK, "restored tick is not the terminal tick");
    }

    /// @notice The same holds when the grief pushes the price up, and when the curve
    /// nominates a large `amountSpecified` rather than one wei: nothing is ever spent.
    function test_assumption1_restorationIsFreeInBothDirectionsAndAtAnySize() public {
        POOL_MANAGER.initialize(poolKey, sqrtPriceTerminal);

        uint160 griefed = TickMath.getSqrtPriceAtTick(300_000);
        swapper.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -1, sqrtPriceLimitX96: griefed})
        );
        (uint160 sqrtAfterGrief,,,) = POOL_MANAGER.getSlot0(poolId);
        assertEq(sqrtAfterGrief, griefed, "upward grief did not move the price");

        // A whole ETH nominated as the exact input, settled by the helper, which holds
        // nothing: if a single wei were owed this call would revert.
        assertEq(address(swapper).balance, 0, "the swap helper was pre-funded");
        BalanceDelta delta = swapper.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: sqrtPriceTerminal
            })
        );
        (uint160 sqrtRestored,,,) = POOL_MANAGER.getSlot0(poolId);

        emit log_named_int("restore delta amount0 (1e18 nominated)", delta.amount0());
        emit log_named_int("restore delta amount1 (1e18 nominated)", delta.amount1());

        assertEq(delta.amount0(), 0, "non-zero currency0 delta with a large amountSpecified");
        assertEq(delta.amount1(), 0, "non-zero currency1 delta with a large amountSpecified");
        assertEq(sqrtRestored, sqrtPriceTerminal, "price not restored");
        assertEq(address(swapper).balance, 0, "the restoring swap took ETH from the caller");
    }

    /// @notice A superseded revision of spec 8.2 step 2 called this a "zero-input swap".
    /// Literally zero is not a swap v4 will accept, so the restoring call must nominate a
    /// non-zero `amountSpecified` and rely on the empty pool consuming none of it.
    /// @dev The specification was corrected to match: step 2 now nominates one unit of
    /// exact input, and its prose states that "zero cost" describes what the swap settles
    /// rather than the size it names. `BondingCurve._restorePrice` nominates one unit.
    function test_assumption1_refuted_amountSpecifiedZeroIsRejectedByPoolManager() public {
        POOL_MANAGER.initialize(poolKey, sqrtPriceTerminal);

        (bool ok, bytes memory ret) = address(swapper)
            .call(
                abi.encodeCall(
                    PoolSwapHelper.swap,
                    (
                        poolKey,
                        SwapParams({
                            zeroForOne: true,
                            amountSpecified: 0,
                            sqrtPriceLimitX96: sqrtPriceTerminal - 1
                        })
                    )
                )
            );
        assertFalse(ok, "a swap with amountSpecified = 0 was accepted");
        emit log_named_bytes("revert: amountSpecified = 0", ret);
        assertEq(
            bytes4(ret),
            IPoolManager.SwapAmountCannotBeZero.selector,
            "unexpected revert for a zero-amount swap"
        );

        // And a swap whose limit is already the current price is rejected too, which is
        // why spec 8.2 step 2 must keep its `if price != sqrtPriceTerminal` guard.
        (ok, ret) = address(swapper)
            .call(
                abi.encodeCall(
                    PoolSwapHelper.swap,
                    (
                        poolKey,
                        SwapParams({
                            zeroForOne: true,
                            amountSpecified: -1,
                            sqrtPriceLimitX96: sqrtPriceTerminal
                        })
                    )
                )
            );
        assertFalse(ok, "a swap to the price it is already at was accepted");
        assertEq(
            bytes4(ret),
            Pool.PriceLimitAlreadyExceeded.selector,
            "unexpected revert for a no-op limit"
        );
    }

    /// @notice Once someone has added liquidity, restoring the price is no longer free,
    /// so `graduate()`'s zero-net-delta requirement makes it revert rather than spend
    /// curve ETH. This is the mitigation spec 8.4 claims for that vector.
    function test_assumption1_restorationIsNotFreeOnceSomeoneAddsLiquidity() public {
        POOL_MANAGER.initialize(poolKey, sqrtPriceTerminal);
        _approvePositionManager(LP_SUPPLY);

        (int24 tickLower, int24 tickUpper) = _coreRange();
        uint128 liquidity = _coreLiquidity(tickLower) / 1000;
        (bool ok,) = _tryModify(
            _mintCalldata(
                tickLower,
                tickUpper,
                liquidity,
                uint128(R_TARGET),
                uint128(LP_SUPPLY),
                address(this)
            ),
            R_TARGET
        );
        assertTrue(ok, "could not seed the pool with liquidity");
        assertGt(POOL_MANAGER.getLiquidity(poolId), 0, "pool is still empty");

        // Move the price with a real swap, then try to put it back.
        vm.deal(address(swapper), 1 ether);
        swapper.swap{value: 1 ether}(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.05e18,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(150_000)
            })
        );
        (uint160 sqrtMoved,,,) = POOL_MANAGER.getSlot0(poolId);
        assertLt(sqrtMoved, sqrtPriceTerminal, "the swap did not move the price");

        token.transfer(address(swapper), 1_000_000e18);
        BalanceDelta restoreDelta = swapper.swap(
            poolKey,
            SwapParams({
                zeroForOne: false, amountSpecified: -1e24, sqrtPriceLimitX96: sqrtPriceTerminal
            })
        );
        (uint160 sqrtRestored,,,) = POOL_MANAGER.getSlot0(poolId);

        emit log_named_int("restore delta amount0 with liquidity present", restoreDelta.amount0());
        emit log_named_int("restore delta amount1 with liquidity present", restoreDelta.amount1());

        assertEq(sqrtRestored, sqrtPriceTerminal, "price not restored");
        assertTrue(
            restoreDelta.amount0() != 0 || restoreDelta.amount1() != 0,
            "restoring the price was still free with liquidity in the pool"
        );
    }

    /// @notice Restoring the price costs nothing in either currency however far the grief
    /// pushed it — a griefer can move an empty pool all the way to `MIN_TICK + 1` for
    /// free, and the restore is still free. It is not free in *gas*, though: the swap
    /// walks the tick bitmap one word at a time, so the work scales with the tick
    /// distance divided by the tick spacing.
    /// @dev At the primary `POOL_TICK_SPACING = 200` the worst case is cheap. At
    /// `ALT_TICK_SPACING_MIN = 10` it is twenty times that, which on its own exceeds the
    /// two-million-gas graduation that spec 8.3 sizes the bounty against. It stays out of
    /// the graduation path only because spec 8.4 requires the alt pool to be
    /// *uninitialised*, so `graduateAlt` opens it at `sqrtPriceTerminal` itself and has
    /// nothing to restore. That requirement is load-bearing, not belt-and-braces.
    /// @dev The figures are EVM execution gas under the forked EVM. Per
    /// `docs/CHAIN_FACTS.md`, Nitro's `gasleft()` and L1 data costs differ, so treat
    /// them as the relative cost of the loop, not as a chain gas quote.
    function test_assumption1_extremeGriefRestorationIsFreeButNotGasFree() public {
        int24[2] memory spacings = [int24(200), int24(10)];
        uint256[2] memory gasAt;

        for (uint256 i = 0; i < spacings.length; i++) {
            PoolKey memory key = _freshPool(spacings[i]);
            BalanceDelta delta;
            (gasAt[i], delta) = _measureRestore(key, TickMath.MIN_TICK + 1);

            emit log_named_int("tickSpacing", spacings[i]);
            emit log_named_int("  restore delta amount0", delta.amount0());
            emit log_named_int("  restore delta amount1", delta.amount1());
            emit log_named_uint("  restore gas (EVM execution)", gasAt[i]);

            assertEq(delta.amount0(), 0, "extreme restore had a currency0 cost");
            assertEq(delta.amount1(), 0, "extreme restore had a currency1 cost");
            (uint160 sqrtRestored,,,) = POOL_MANAGER.getSlot0(key.toId());
            assertEq(
                sqrtRestored, sqrtPriceTerminal, "extreme restore did not reach sqrtPriceTerminal"
            );
        }

        assertLt(gasAt[0], 400_000, "the worst-case restore at tickSpacing 200 is no longer cheap");
        assertGt(gasAt[1], 2_000_000, "the tickSpacing 10 restore is no longer the expensive case");
    }

    // =====================================================================
    // Assumption 2 — collect and increase in one `modifyLiquidities` call.
    // Resolves decision 1 (LiquidityLock, permissionless compound-only).
    // =====================================================================

    function test_assumption2_collectAndIncreaseInOneCallWithNoIntermediateRecipient() public {
        _seedLockedPositionAndAccrueFees();

        (uint128 liquidityBefore,,) = POOL_MANAGER.getPositionInfo(poolId, seedPositionKey);
        (uint256 fees0, uint256 fees1) = _accruedFees(seedTickLower, seedTickUpper, seedPositionKey);

        emit log_named_uint("accrued currency0 fees (wei)", fees0);
        emit log_named_uint("accrued currency1 fees (base units)", fees1);
        assertGt(fees0, 0, "no currency0 fees accrued");
        assertGt(fees1, 0, "no currency1 fees accrued");

        // The lock holds nothing and has approved nothing. Anything it ends up with came
        // out of the position's fees, and anything it had to pay would make this revert.
        assertEq(address(lock).balance, 0, "lock was pre-funded with ETH");
        assertEq(token.balanceOf(address(lock)), 0, "lock was pre-funded with token");
        assertEq(token.allowance(address(lock), address(PERMIT2)), 0, "lock has a token approval");

        uint128 added = _compoundableLiquidity(fees0, fees1);
        assertGt(added, 0, "the accrued fees are not enough liquidity to compound");

        // One liquidity action. `_increase` with non-zero liquidity issues a single
        // `PoolManager.modifyLiquidity`, whose returned delta already nets the collected
        // fees against the cost of the new liquidity; the two CLOSE_CURRENCY actions then
        // route the ratio residual back to `msgSender()`, which is the position's own
        // owner. No recipient parameter names any other address at any point.
        (bool ok, bytes memory ret) = lock.tryModify(_compoundCalldata(added), block.timestamp);
        emit log_named_bytes("compound-only call result", ret);
        assertTrue(ok, "collect-and-increase in one call failed");

        (uint128 liquidityAfter,,) = POOL_MANAGER.getPositionInfo(poolId, seedPositionKey);
        emit log_named_uint("liquidity before", liquidityBefore);
        emit log_named_uint("liquidity after", liquidityAfter);
        emit log_named_uint("currency0 residual left in the lock (wei)", address(lock).balance);
        emit log_named_uint(
            "currency1 residual left in the lock (base units)", token.balanceOf(address(lock))
        );

        assertEq(
            liquidityAfter,
            liquidityBefore + added,
            "liquidity did not grow by the compounded amount"
        );
        assertEq(_ownerOf(seedTokenId), address(lock), "the position changed hands");

        // Every wei of fee either went into the position or sits in the lock: nothing was
        // taken from the lock, and nothing reached a third party.
        assertLe(address(lock).balance, fees0, "the lock received more currency0 than the fees");
        assertLe(
            token.balanceOf(address(lock)), fees1, "the lock received more currency1 than the fees"
        );
        assertEq(address(POSITION_MANAGER).balance, 0, "PositionManager retained ETH");
        assertEq(token.balanceOf(address(POSITION_MANAGER)), 0, "PositionManager retained token");
    }

    /// @notice The fees are fully collected by the same single call: after it, the
    /// position's accrued fees are zero.
    function test_assumption2_theSingleCallCollectsEveryWeiOfAccruedFees() public {
        _seedLockedPositionAndAccrueFees();

        (uint256 fees0, uint256 fees1) = _accruedFees(seedTickLower, seedTickUpper, seedPositionKey);
        (bool ok,) =
            lock.tryModify(_compoundCalldata(_compoundableLiquidity(fees0, fees1)), block.timestamp);
        assertTrue(ok, "compound call failed");

        (uint256 fees0After, uint256 fees1After) =
            _accruedFees(seedTickLower, seedTickUpper, seedPositionKey);
        emit log_named_uint("currency0 fees remaining after compounding", fees0After);
        emit log_named_uint("currency1 fees remaining after compounding", fees1After);
        assertEq(fees0After, 0, "currency0 fees were not collected");
        assertEq(fees1After, 0, "currency1 fees were not collected");
    }

    /// @notice The same thing without the caller having to know the fee amounts:
    /// `DECREASE_LIQUIDITY` of zero credits the fees and `INCREASE_LIQUIDITY_FROM_DELTAS`
    /// spends that credit, still inside one `modifyLiquidities`.
    function test_assumption2_collectAndIncreaseFromDeltasInOneCall() public {
        _seedLockedPositionAndAccrueFees();

        (uint128 liquidityBefore,,) = POOL_MANAGER.getPositionInfo(poolId, seedPositionKey);

        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.INCREASE_LIQUIDITY_FROM_DELTAS),
            uint8(Actions.CLOSE_CURRENCY),
            uint8(Actions.CLOSE_CURRENCY)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(seedTokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(seedTokenId, type(uint128).max, type(uint128).max, bytes(""));
        params[2] = abi.encode(poolKey.currency0);
        params[3] = abi.encode(poolKey.currency1);

        (bool ok, bytes memory ret) = lock.tryModify(abi.encode(actions, params), block.timestamp);
        emit log_named_bytes("from-deltas call result", ret);
        assertTrue(ok, "collect-then-increase-from-deltas in one call failed");

        (uint128 liquidityAfter,,) = POOL_MANAGER.getPositionInfo(poolId, seedPositionKey);
        emit log_named_uint("liquidity before", liquidityBefore);
        emit log_named_uint("liquidity after", liquidityAfter);
        emit log_named_uint("currency0 residual left in the lock (wei)", address(lock).balance);
        emit log_named_uint(
            "currency1 residual left in the lock (base units)", token.balanceOf(address(lock))
        );

        assertGt(liquidityAfter, liquidityBefore, "liquidity did not grow");
        assertEq(_ownerOf(seedTokenId), address(lock), "the position changed hands");
    }

    /// @notice Compounding is repeatable, and the ratio residual is *retained* by the
    /// lock rather than automatically reinvested: `INCREASE_LIQUIDITY_FROM_DELTAS` and
    /// `CLOSE_CURRENCY` both work off the PoolManager delta, not the lock's own balance.
    /// Folding an old residual back in would need the lock to forward ETH as `msg.value`
    /// and to hold a Permit2 approval for its own token, which is extra lock surface.
    function test_assumption2_compoundingIsRepeatableAndTheResidualIsRetained() public {
        _seedLockedPositionAndAccrueFees();

        (uint256 fees0, uint256 fees1) = _accruedFees(seedTickLower, seedTickUpper, seedPositionKey);
        (bool ok,) =
            lock.tryModify(_compoundCalldata(_compoundableLiquidity(fees0, fees1)), block.timestamp);
        assertTrue(ok, "first compound failed");

        uint256 residualEthRound1 = address(lock).balance;
        uint256 residualTokenRound1 = token.balanceOf(address(lock));
        (uint128 liquidityRound1,,) = POOL_MANAGER.getPositionInfo(poolId, seedPositionKey);

        _tradeBothWays();

        (fees0, fees1) = _accruedFees(seedTickLower, seedTickUpper, seedPositionKey);
        (ok,) = lock.tryModify(
            _compoundCalldata(_compoundableLiquidity(fees0, fees1)), block.timestamp
        );
        assertTrue(ok, "second compound failed");

        (uint128 liquidityRound2,,) = POOL_MANAGER.getPositionInfo(poolId, seedPositionKey);

        emit log_named_uint("liquidity after round 1", liquidityRound1);
        emit log_named_uint("liquidity after round 2", liquidityRound2);
        emit log_named_uint("currency0 residual after round 1 (wei)", residualEthRound1);
        emit log_named_uint("currency0 residual after round 2 (wei)", address(lock).balance);

        assertGt(liquidityRound2, liquidityRound1, "the second compound did not grow the position");
        assertGe(address(lock).balance, residualEthRound1, "the round-1 ETH residual left the lock");
        assertGe(
            token.balanceOf(address(lock)),
            residualTokenRound1,
            "the round-1 token residual left the lock"
        );
        assertEq(_ownerOf(seedTokenId), address(lock), "the position changed hands");
    }

    /// @notice A third party cannot collect or redirect the locked position's fees:
    /// `PositionManager` only accepts the owner, and the recipient CLOSE_CURRENCY uses is
    /// `msgSender()`, which is the lock itself.
    function test_assumption2_thirdPartyCannotCollectTheLockedPositionsFees() public {
        _seedLockedPositionAndAccrueFees();

        (uint256 fees0, uint256 fees1) = _accruedFees(seedTickLower, seedTickUpper, seedPositionKey);
        assertGt(fees0 + fees1, 0, "no fees accrued");

        bytes memory actions =
            abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(seedTokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));

        (bool ok, bytes memory ret) = _tryModify(abi.encode(actions, params), 0);
        assertFalse(ok, "a third party collected the locked position's fees");
        emit log_named_bytes("revert: third-party collect", ret);
        assertEq(
            bytes4(ret),
            IPositionManager.NotApproved.selector,
            "unexpected revert for a third-party collect"
        );
    }

    // =====================================================================
    // Fixtures
    // =====================================================================

    /// @dev Opens the pool, mints an in-range position owned by `lock`, then trades
    /// both ways through it so the position has fees in both currencies.
    function _seedLockedPositionAndAccrueFees() internal {
        POOL_MANAGER.initialize(poolKey, sqrtPriceTerminal);
        _approvePositionManager(LP_SUPPLY);

        (seedTickLower, seedTickUpper) = _coreRange();

        (bool ok,) = _tryModify(
            _mintCalldata(
                seedTickLower,
                seedTickUpper,
                _coreLiquidity(seedTickLower),
                uint128(R_TARGET),
                uint128(LP_SUPPLY),
                address(lock)
            ),
            R_TARGET
        );
        require(ok, "seed mint failed");
        seedTokenId = POSITION_MANAGER.nextTokenId() - 1;
        seedPositionKey = _positionKey(seedTickLower, seedTickUpper, seedTokenId);

        _tradeBothWays();
    }

    /// @dev A fresh ETH/token pool on `tickSpacing`, opened at `sqrtPriceTerminal`.
    function _freshPool(int24 tickSpacing) internal returns (PoolKey memory key) {
        TestERC20 t = new TestERC20("Pledrin Fork Probe", "PFP", TOTAL_SUPPLY, address(this));
        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(t)),
            fee: POOL_FEE,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
        POOL_MANAGER.initialize(key, sqrtPriceTerminal);
    }

    /// @dev Grief `key`'s price down to `griefTick`, then restore it, reporting the
    /// restoring swap's delta and the gas the restore spent.
    function _measureRestore(PoolKey memory key, int24 griefTick)
        internal
        returns (uint256 gasUsed, BalanceDelta delta)
    {
        swapper.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(griefTick)
            })
        );
        uint256 before = gasleft();
        delta = swapper.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -1, sqrtPriceLimitX96: sqrtPriceTerminal
            })
        );
        gasUsed = before - gasleft();
    }

    /// @dev Opens a pool at `vE0`'s terminal price, mints the core position the way spec
    /// 8.2 step 4 does, and reports what was left of `R_target` and of `LP_SUPPLY`.
    function _measureCoreShortfall(uint256 vE0) internal returns (uint256 short0, uint256 short1) {
        uint256 rTarget = 8 * vE0;
        sqrtPriceTerminal = _sqrtPriceTerminal(LP_SUPPLY, rTarget);
        poolKey = _freshPool(POOL_TICK_SPACING);
        poolId = poolKey.toId();
        token = TestERC20(Currency.unwrap(poolKey.currency1));
        _approvePositionManager(LP_SUPPLY);

        (int24 tickLower, int24 tickUpper) = _coreRange();
        uint256 ethBefore = address(this).balance;
        uint256 tokenBefore = token.balanceOf(address(this));

        (bool ok,) = _tryModify(
            _mintCalldata(
                tickLower,
                tickUpper,
                _coreLiquidity(tickLower),
                uint128(rTarget),
                uint128(LP_SUPPLY),
                address(lock)
            ),
            rTarget
        );
        require(ok, "core mint failed");

        short0 = rTarget - (ethBefore - address(this).balance);
        short1 = LP_SUPPLY - (tokenBefore - token.balanceOf(address(this)));
    }

    /// @dev Buy, then sell, so the seeded position accrues fees in both currencies.
    function _tradeBothWays() internal {
        vm.deal(address(swapper), 2 ether);
        token.transfer(address(swapper), 20_000_000e18);

        swapper.swap{value: 1 ether}(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.5e18,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK + 1)
            })
        );
        swapper.swap(
            poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -10_000_000e18,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK - 1)
            })
        );
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    /// @dev `sqrtPriceTerminal = sqrt(mulDiv(S_LP, 2**192, R_target))`, spec 8.1.
    function _sqrtPriceTerminal(uint256 sLp, uint256 rTarget) internal pure returns (uint160) {
        return uint160(FixedPointMathLib.sqrt(FullMath.mulDiv(sLp, uint256(1) << 192, rTarget)));
    }

    function _coreRange() internal pure returns (int24 tickLower, int24 tickUpper) {
        tickLower = _alignUp(TickMath.MIN_TICK, POOL_TICK_SPACING);
        tickUpper = _alignDown(TickMath.MAX_TICK, POOL_TICK_SPACING);
    }

    /// @dev The largest liquidity whose currency1 requirement still fits in LP_SUPPLY.
    function _coreLiquidity(int24 tickLower) internal view returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceTerminal, LP_SUPPLY
        );
    }

    function _mintCalldata(
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        address owner
    ) internal view returns (bytes memory) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, bytes("")
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        params[2] = abi.encode(poolKey.currency0, ActionConstants.MSG_SENDER);
        return abi.encode(actions, params);
    }

    /// @dev The amounts `PoolManager` will require for `liquidity` over this range at
    /// the pool's current price. Mirrors the branching in `Pool.modifyLiquidity`, which
    /// is what decides which currency a position is funded in.
    function _requiredAmounts(int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtPriceX96, int24 tick,,) = POOL_MANAGER.getSlot0(poolId);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        if (tick < tickLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true);
        } else if (tick < tickUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, true);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, true);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
        }
    }

    /// @dev The liquidity the accrued fees can buy at the pool's current price.
    function _compoundableLiquidity(uint256 fees0, uint256 fees1) internal view returns (uint128) {
        (uint160 sqrtPriceNow,,,) = POOL_MANAGER.getSlot0(poolId);
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceNow,
            TickMath.getSqrtPriceAtTick(seedTickLower),
            TickMath.getSqrtPriceAtTick(seedTickUpper),
            fees0,
            fees1
        );
    }

    /// @dev Collect and reinvest, as one `modifyLiquidities` batch, with the ratio
    /// residual closed back to the caller and no recipient parameter anywhere.
    function _compoundCalldata(uint128 added) internal view returns (bytes memory) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY),
            uint8(Actions.CLOSE_CURRENCY),
            uint8(Actions.CLOSE_CURRENCY)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            seedTokenId, uint256(added), type(uint128).max, type(uint128).max, bytes("")
        );
        params[1] = abi.encode(poolKey.currency0);
        params[2] = abi.encode(poolKey.currency1);
        return abi.encode(actions, params);
    }

    function _tryModify(bytes memory unlockData, uint256 value)
        internal
        returns (bool ok, bytes memory ret)
    {
        (ok, ret) = address(POSITION_MANAGER).call{value: value}(
            abi.encodeCall(IPositionManager.modifyLiquidities, (unlockData, block.timestamp))
        );
    }

    /// @dev The two approval legs of spec 8.2 step 4, and nothing else.
    function _approvePositionManager(uint256 amount) internal {
        token.approve(address(PERMIT2), amount);
        PERMIT2.approve(
            address(token), address(POSITION_MANAGER), uint160(amount), type(uint48).max
        );
    }

    function _ownerOf(uint256 tokenId) internal view returns (address) {
        return IPositionManagerPermit2(address(POSITION_MANAGER)).ownerOf(tokenId);
    }

    function _positionKey(int24 tickLower, int24 tickUpper, uint256 tokenId)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                0x58daec3116aae6D93017bAAea7749052E8a04fA7, tickLower, tickUpper, bytes32(tokenId)
            )
        );
    }

    function _accruedFees(int24 tickLower, int24 tickUpper, bytes32 positionKey)
        internal
        view
        returns (uint256 fees0, uint256 fees1)
    {
        (uint256 inside0, uint256 inside1) =
            POOL_MANAGER.getFeeGrowthInside(poolId, tickLower, tickUpper);
        (uint128 liquidity, uint256 last0, uint256 last1) =
            POOL_MANAGER.getPositionInfo(poolId, positionKey);
        unchecked {
            fees0 = FullMath.mulDiv(inside0 - last0, liquidity, FixedPoint128.Q128);
            fees1 = FullMath.mulDiv(inside1 - last1, liquidity, FixedPoint128.Q128);
        }
    }

    function _alignDown(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }

    function _alignUp(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick > 0 && tick % spacing != 0) compressed++;
        return compressed * spacing;
    }
}
