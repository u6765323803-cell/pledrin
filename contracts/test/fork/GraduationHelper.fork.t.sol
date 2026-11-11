// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {GraduationHelper} from "src/GraduationHelper.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";
import {TickAlign} from "src/libraries/TickAlign.sol";

import {PoolSwapHelper} from "../helpers/PoolSwapHelper.sol";
import {ForkBase} from "./ForkBase.sol";

/// @title `GraduationHelper` against the real Uniswap v4 deployment
/// @notice Section 8.6 end to end on Robinhood Chain: the free restore, both paid
/// restores, the budget refusal that tells a caller what to bring, and the candidate walk
/// escaping a canonical key that a third party has made expensive to restore.
/// @dev These are the tests the deterministic suite cannot be: a restore that costs
/// something costs what the **real** `Pool.swap` charges for crossing the liquidity in its
/// path, and the amount is read back off the chain rather than chosen by a stand-in. The
/// stand-in's own fidelity to `settle`, `sync` and `take` is asserted in
/// `test/mocks/MockPoolManager.sol` against the lines of `PoolManager.sol` it models; what
/// is measured here is the behaviour of the contract under test against those real lines.
///
/// `docs/CHAIN_FACTS.md` is the only source of the addresses, by way of `ForkBase`.
contract GraduationHelperForkTest is ForkBase {
    using StateLibrary for IPoolManager;

    /// @dev The caller that brings the value and keeps the bounty.
    address internal constant GRADUATOR = address(0x6AAD);

    GraduationHelper internal helper;
    PoolSwapHelper internal swapper;

    event GraduatedVia(
        address indexed launch,
        address indexed caller,
        uint256 candidateIndex,
        uint256 bounty,
        uint256 ethReturned,
        uint256 tokensReturned
    );

    receive() external payable {}

    function setUp() public override {
        super.setUp();
        helper = new GraduationHelper();
        swapper = new PoolSwapHelper(POOL_MANAGER);
        vm.deal(GRADUATOR, 1000 ether);
    }

    // ------------------------------------------------------------------
    // The free path
    // ------------------------------------------------------------------

    /// @notice **The whole of section 8.6 on an empty pool.** A canonical key griefed to a
    /// far-away price is restored for nothing, the launch graduates in the same
    /// transaction, both positions land in the lock, and the caller is up the bounty and
    /// down only the gas.
    function test_aGriefedEmptyPoolIsRestoredAndGraduatedThroughTheHelper() public {
        (BondingCurve curve, IERC20 token) = createLaunch(defaultParams());
        buyToCap(curve);
        PoolKey memory key = poolKeyFor(address(token), PledrinConstants.POOL_TICK_SPACING);

        // The grief: one swap on an empty pool, which moves the price for free.
        swapper.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(100_000)
            })
        );
        (uint160 griefed,,,) = POOL_MANAGER.getSlot0(key.toId());
        assertEq(griefed, TickMath.getSqrtPriceAtTick(100_000), "the grief took effect");

        uint256 bounty = _expectedBounty(curve);
        uint256 coreId = POSITION_MANAGER.nextTokenId();
        uint256 balanceBefore = GRADUATOR.balance;

        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(helper));
        emit GraduatedVia(address(curve), GRADUATOR, 0, bounty, bounty, 0);
        vm.prank(GRADUATOR);
        uint256 gasBefore = gasleft();
        uint256 index = helper.graduateVia(IBondingCurve(address(curve)), _candidates(), 0);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("graduateVia end to end, free restore, EVM execution gas", gasUsed);

        assertEq(index, 0, "the canonical candidate graduated");
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "Graduated");
        (uint160 price, int24 tick,,) = POOL_MANAGER.getSlot0(key.toId());
        assertEq(price, curve.sqrtPriceTerminal(), "the mint saw the terminal price");
        assertEq(tick, DEFAULT_TERMINAL_TICK, "and the terminal tick");
        assertEq(ownerOfPosition(coreId), address(lock), "the core position is locked");
        assertEq(ownerOfPosition(coreId + 1), address(lock), "and the floor position");
        assertEq(GRADUATOR.balance, balanceBefore + bounty, "the caller is up the bounty");
        assertGt(bounty, 0, "which was not zero");
        GraduatedLog memory log = graduatedLog(address(curve));
        assertEq(log.caller, address(helper), "the curve saw the helper as its caller");
        _assertHelperHoldsNothing(token);
    }

    // ------------------------------------------------------------------
    // The paid path, in both directions, against real liquidity
    // ------------------------------------------------------------------

    /// @notice **A restore that costs real ETH.** A third party holds liquidity above the
    /// terminal tick and the price has been pushed up through it, so bringing the price
    /// back down sells ETH into that liquidity: the curve's own free restore declines
    /// (`SwapNotFree`), the helper pays for it out of `msg.value`, and the launch
    /// graduates. The tokens the swap credits are forwarded to the caller with the rest.
    function test_aRestoreThatCostsRealEthIsPaidOutOfMsgValue() public {
        (BondingCurve curve, IERC20 token) = createLaunch(defaultParams());
        buyToCap(curve);
        PoolKey memory key = poolKeyFor(address(token), PledrinConstants.POOL_TICK_SPACING);

        _seedEthBandAbove(key, token);
        _griefUpwards(key, token);

        // The curve cannot fix this itself, which is the premise of section 8.6.
        vm.expectPartialRevert(IBondingCurve.SwapNotFree.selector);
        curve.graduate();
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduating), "still frozen");

        uint256 bounty = _expectedBounty(curve);
        uint256 brought = 50 ether;
        uint256 ethBefore = GRADUATOR.balance;
        uint256 tokensBefore = token.balanceOf(GRADUATOR);
        uint256 coreId = POSITION_MANAGER.nextTokenId();

        vm.prank(GRADUATOR);
        uint256 gasBefore = gasleft();
        uint256 index =
            helper.graduateVia{value: brought}(IBondingCurve(address(curve)), _candidates(), 0);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("graduateVia end to end, paid ETH restore, EVM execution gas", gasUsed);

        uint256 spent = ethBefore + bounty - GRADUATOR.balance;
        uint256 credited = token.balanceOf(GRADUATOR) - tokensBefore;
        emit log_named_uint("ETH the real restore cost", spent);
        emit log_named_uint("launch tokens the real restore credited", credited);

        assertEq(index, 0, "it graduated on the canonical key");
        assertGt(spent, 0, "the restore really did cost ETH");
        assertLt(spent, brought, "and less than the caller brought");
        assertGt(credited, 0, "the swap's token credit reached the caller");
        (uint160 price,,,) = POOL_MANAGER.getSlot0(key.toId());
        assertEq(price, curve.sqrtPriceTerminal(), "the price was restored exactly");
        assertEq(ownerOfPosition(coreId), address(lock), "the core position is locked");
        assertEq(ownerOfPosition(coreId + 1), address(lock), "and the floor position");
        _assertHelperHoldsNothing(token);
    }

    /// @notice **A restore that costs real launch tokens**, which is the other direction:
    /// liquidity below the terminal tick, a price pushed down into it, and a restore that
    /// buys the price back up with tokens out of the single pull and is credited ETH.
    /// @dev The amount brought is the amount the token budget refusal named, so this test
    /// also measures that the number is exact: what the attempt says it requires is what
    /// the restore then spends, to the base unit.
    function test_aRestoreThatCostsRealTokensIsPaidOutOfTheSinglePull() public {
        (BondingCurve curve, IERC20 token) = createLaunch(defaultParams());
        buyToCap(curve);
        PoolKey memory key = poolKeyFor(address(token), PledrinConstants.POOL_TICK_SPACING);

        _seedTokenBandBelow(key, token);
        _griefDownwards(key);

        vm.expectPartialRevert(IBondingCurve.SwapNotFree.selector);
        curve.graduate();

        // What the restore requires, read off an attempt made with nothing to pay it with.
        uint256 required = _requiredTokens(curve, token);
        emit log_named_uint("launch tokens the real restore requires", required);
        assertGt(required, 0, "the restore is not free");

        uint256 brought = required + 1e18;
        vm.prank(TRADER);
        token.transfer(GRADUATOR, brought);
        vm.prank(GRADUATOR);
        // forge-lint: disable-next-line(unused-return)
        token.approve(address(helper), brought);

        uint256 bounty = _expectedBounty(curve);
        uint256 ethBefore = GRADUATOR.balance;
        uint256 tokensBefore = token.balanceOf(GRADUATOR);

        vm.prank(GRADUATOR);
        uint256 gasBefore = gasleft();
        uint256 index = helper.graduateVia(IBondingCurve(address(curve)), _candidates(), brought);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint(
            "graduateVia end to end, paid token restore, EVM execution gas", gasUsed
        );

        uint256 spent = tokensBefore - token.balanceOf(GRADUATOR);
        uint256 credited = GRADUATOR.balance - ethBefore - bounty;
        emit log_named_uint("launch tokens the real restore cost", spent);
        emit log_named_uint("ETH the real restore credited", credited);

        assertEq(index, 0, "it graduated");
        assertEq(spent, required, "the refusal named exactly what the restore then cost");
        assertEq(token.allowance(GRADUATOR, address(helper)), 0, "the pull consumed the approval");
        (uint160 price,,,) = POOL_MANAGER.getSlot0(key.toId());
        assertEq(price, curve.sqrtPriceTerminal(), "the price was restored exactly");
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "Graduated");
        _assertHelperHoldsNothing(token);
    }

    /// @notice **The budget refusal gives the caller a number to bring.** With the real
    /// restore costing real ETH, an under-funded attempt names the required amount and the
    /// available amount, and spends nothing; bringing that number graduates the launch.
    /// @dev The number is read off `attemptCandidate` rather than off `graduateVia`,
    /// because the walk deliberately does not bind a candidate's revert reason: through
    /// `graduateVia` the caller sees `NoCandidateGraduated`. So a caller diagnosing a
    /// refusal simulates the attempt, which is what this test does, and that is the only
    /// way the number is observable.
    function test_theEthBudgetRefusalNamesTheNumberToBringOnTheRealPool() public {
        (BondingCurve curve, IERC20 token) = createLaunch(defaultParams());
        buyToCap(curve);
        PoolKey memory key = poolKeyFor(address(token), PledrinConstants.POOL_TICK_SPACING);

        _seedEthBandAbove(key, token);
        _griefUpwards(key, token);

        // Through the walk: an opaque refusal, and nothing spent.
        uint256 ethBefore = GRADUATOR.balance;
        vm.expectRevert(abi.encodeWithSelector(GraduationHelper.NoCandidateGraduated.selector, 1));
        vm.prank(GRADUATOR);
        helper.graduateVia{value: 1 wei}(IBondingCurve(address(curve)), _candidates(), 0);
        assertEq(GRADUATOR.balance, ethBefore, "the refused attempt spent nothing");
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduating), "still frozen");

        // Through the attempt: the number to bring.
        uint160 terminal = curve.sqrtPriceTerminal();
        vm.deal(address(helper), 1 wei);
        vm.prank(address(helper));
        (bool ok, bytes memory ret) = address(helper)
            .call(
                abi.encodeCall(
                    GraduationHelper.attemptCandidate,
                    (
                        IBondingCurve(address(curve)),
                        token,
                        POOL_MANAGER,
                        terminal,
                        GraduationHelper.Candidate({
                            fee: PledrinConstants.POOL_FEE,
                            tickSpacing: uint24(int24(PledrinConstants.POOL_TICK_SPACING))
                        })
                    )
                )
            );
        assertFalse(ok, "the under-funded attempt was accepted");
        assertEq(bytes4(ret), GraduationHelper.EthBudgetExceeded.selector, "EthBudgetExceeded");
        (uint256 required, uint256 available) = _decodeTwoWords(ret);
        emit log_named_uint("ETH the real restore requires", required);
        assertEq(available, 1, "the available amount is what the helper was holding");
        assertGt(required, available, "and the required amount is more than that");

        // Bringing that number graduates the launch, which is what makes the number useful.
        vm.prank(GRADUATOR);
        uint256 index =
            helper.graduateVia{value: required}(IBondingCurve(address(curve)), _candidates(), 0);
        assertEq(index, 0, "the number the refusal named was enough");
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Graduated), "Graduated");
        _assertHelperHoldsNothing(token);
    }

    // ------------------------------------------------------------------
    // The candidate walk, against a key somebody else has made expensive
    // ------------------------------------------------------------------

    /// @notice **Why the interface takes a list.** The canonical key has third-party
    /// liquidity in the restore's path and the caller brings no ETH, so that candidate
    /// fails; the alternate key in the same list is untouched, so the walk graduates there
    /// instead. An attacker can seize the key a transaction names and not the list.
    function test_theWalkEscapesAnExpensiveCanonicalKeyOntoAnAlternate() public {
        (BondingCurve curve, IERC20 token) = createLaunch(defaultParams());
        buyToCap(curve);
        PoolKey memory key = poolKeyFor(address(token), PledrinConstants.POOL_TICK_SPACING);

        _seedEthBandAbove(key, token);
        _griefUpwards(key, token);
        vm.warp(curve.capReachedAt() + PledrinConstants.ALT_DELAY);

        GraduationHelper.Candidate[] memory candidates = new GraduationHelper.Candidate[](2);
        candidates[0] = GraduationHelper.Candidate({
            fee: PledrinConstants.POOL_FEE,
            tickSpacing: uint24(int24(PledrinConstants.POOL_TICK_SPACING))
        });
        candidates[1] =
            GraduationHelper.Candidate({fee: PledrinConstants.POOL_FEE, tickSpacing: 100});

        uint256 coreId = POSITION_MANAGER.nextTokenId();
        vm.recordLogs();
        vm.prank(GRADUATOR);
        uint256 index = helper.graduateVia(IBondingCurve(address(curve)), candidates, 0);

        assertEq(index, 1, "the walk escaped onto the alternate key");
        GraduatedLog memory log = graduatedLog(address(curve));
        assertEq(log.tickSpacing, 100, "which is the key the graduation used");
        PoolKey memory altKey = poolKeyFor(address(token), PledrinConstants.POOL_FEE, 100);
        assertEq(log.poolId, PoolId.unwrap(altKey.toId()), "Invariant 69: the whole key");
        (uint160 altPrice, int24 altTick,,) = POOL_MANAGER.getSlot0(altKey.toId());
        assertEq(altPrice, curve.sqrtPriceTerminal(), "opened at the terminal price");
        assertEq(altTick, DEFAULT_TERMINAL_TICK, "and the terminal tick");
        assertEq(ownerOfPosition(coreId), address(lock), "the core position is locked");
        // The canonical key, and the stranger's liquidity on it, are left alone.
        (uint160 canonicalPrice,,,) = POOL_MANAGER.getSlot0(key.toId());
        assertGt(canonicalPrice, curve.sqrtPriceTerminal(), "the griefed key is still griefed");
        _assertHelperHoldsNothing(token);
    }

    // ------------------------------------------------------------------
    // Setup helpers: real liquidity, in each of the two paths
    // ------------------------------------------------------------------

    /// @dev Mints an ETH-only position in a band strictly above the terminal tick, which is
    /// the liquidity a downward restore has to cross. A range above the current tick is
    /// funded in `currency0` alone, which `test/fork/V4Assumptions.t.sol` measures.
    function _seedEthBandAbove(PoolKey memory key, IERC20 token) private {
        // Aligned to the spacing, as `PoolManager` requires: the terminal tick itself is
        // not a multiple of 200, so the band starts at the first multiple above it.
        int24 tickLower = TickAlign.up(DEFAULT_TERMINAL_TICK, PledrinConstants.POOL_TICK_SPACING);
        int24 tickUpper = tickLower + PledrinConstants.FLOOR_RANGE_TICKS;
        uint256 value = 40 ether;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), value
        );
        vm.deal(address(this), address(this).balance + value);
        uint256 id = POSITION_MANAGER.nextTokenId();
        _mint(key, tickLower, tickUpper, liquidity, uint128(value), 0, value);
        // Measured on the position and not on the pool: a range that does not contain the
        // current tick adds nothing to the pool's *active* liquidity, which is the
        // property that makes this a band the price has to be pushed into.
        assertGt(POSITION_MANAGER.getPositionLiquidity(id), 0, "the band above was not seeded");
        // Nothing of the token is needed for this one, which is the point of the band.
        assertEq(token.balanceOf(address(this)), 0, "an ETH-only mint took no token");
    }

    /// @dev Mints a token-only position in a band strictly below the terminal tick, which a
    /// restore coming back up has to cross. A range below the current tick is funded in
    /// `currency1` alone, and that leg goes through Permit2 exactly as the protocol's own
    /// mints do.
    function _seedTokenBandBelow(PoolKey memory key, IERC20 token) private {
        int24 tickUpper = TickAlign.down(DEFAULT_TERMINAL_TICK, PledrinConstants.POOL_TICK_SPACING);
        int24 tickLower = tickUpper - PledrinConstants.FLOOR_RANGE_TICKS;
        uint256 amount = 200_000_000e18;
        vm.prank(TRADER);
        token.transfer(address(this), amount);
        // forge-lint: disable-next-line(unused-return)
        token.approve(address(PERMIT2), amount);
        PERMIT2.approve(
            address(token), address(POSITION_MANAGER), uint160(amount), type(uint48).max
        );

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), amount
        );
        uint256 id = POSITION_MANAGER.nextTokenId();
        _mint(key, tickLower, tickUpper, liquidity, 0, uint128(amount), 0);
        assertGt(POSITION_MANAGER.getPositionLiquidity(id), 0, "the band below was not seeded");
    }

    /// @dev One `MINT_POSITION`, `SETTLE_PAIR`, `SWEEP` batch — the three actions the
    /// protocol itself uses — owned by this test contract.
    function _mint(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        uint256 value
    ) private {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            uint256(liquidity),
            amount0Max,
            amount1Max,
            address(this),
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, ActionConstants.MSG_SENDER);
        POSITION_MANAGER.modifyLiquidities{value: value}(
            abi.encode(actions, params), vm.getBlockTimestamp()
        );
    }

    /// @dev Pushes the price up through the seeded band with a real swap, paying tokens.
    function _griefUpwards(PoolKey memory key, IERC20 token) private {
        uint256 tokensIn = 100_000_000e18;
        vm.prank(TRADER);
        token.transfer(address(swapper), tokensIn);
        swapper.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(tokensIn),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(DEFAULT_TERMINAL_TICK + 8000)
            })
        );
        (uint160 price,,,) = POOL_MANAGER.getSlot0(key.toId());
        assertGt(price, TickMath.getSqrtPriceAtTick(DEFAULT_TERMINAL_TICK), "the grief went up");
    }

    /// @dev Pushes the price down through the seeded band with a real swap, paying ETH.
    function _griefDownwards(PoolKey memory key) private {
        uint256 ethIn = 30 ether;
        vm.deal(address(swapper), address(swapper).balance + ethIn);
        swapper.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(DEFAULT_TERMINAL_TICK - 8000)
            })
        );
        (uint160 price,,,) = POOL_MANAGER.getSlot0(key.toId());
        assertLt(price, TickMath.getSqrtPriceAtTick(DEFAULT_TERMINAL_TICK), "the grief went down");
    }

    // ------------------------------------------------------------------
    // Shared assertions
    // ------------------------------------------------------------------

    function _assertHelperHoldsNothing(IERC20 token) private view {
        assertEq(address(helper).balance, 0, "Invariant 68: the helper kept ETH");
        assertEq(token.balanceOf(address(helper)), 0, "Invariant 68: the helper kept tokens");
    }

    function _candidates() private pure returns (GraduationHelper.Candidate[] memory out) {
        out = new GraduationHelper.Candidate[](1);
        out[0] = GraduationHelper.Candidate({
            fee: PledrinConstants.POOL_FEE,
            tickSpacing: uint24(int24(PledrinConstants.POOL_TICK_SPACING))
        });
    }

    function _expectedBounty(BondingCurve curve) private view returns (uint256) {
        return curve.protocolFeeEth() * PledrinConstants.GRAD_BOUNTY_BPS
            / PledrinConstants.BPS_DENOMINATOR;
    }

    /// @dev The base units the restore requires, read off a deliberately under-funded
    /// attempt. `attemptCandidate` is callable only by the helper itself, so the probe is
    /// made from the helper's own address — which is also the only way a caller can see
    /// this number at all, since the walk does not bind a candidate's revert reason.
    function _requiredTokens(BondingCurve curve, IERC20 token) private returns (uint256 required) {
        uint160 terminal = curve.sqrtPriceTerminal();
        vm.prank(address(helper));
        (bool ok, bytes memory ret) = address(helper)
            .call(
                abi.encodeCall(
                    GraduationHelper.attemptCandidate,
                    (
                        IBondingCurve(address(curve)),
                        token,
                        POOL_MANAGER,
                        terminal,
                        GraduationHelper.Candidate({
                            fee: PledrinConstants.POOL_FEE,
                            tickSpacing: uint24(int24(PledrinConstants.POOL_TICK_SPACING))
                        })
                    )
                )
            );
        assertFalse(ok, "an attempt with no tokens at all was accepted");
        assertEq(bytes4(ret), GraduationHelper.TokenBudgetExceeded.selector, "TokenBudgetExceeded");
        uint256 available;
        (required, available) = _decodeTwoWords(ret);
        assertEq(available, 0, "the helper was holding nothing");
    }

    /// @dev The two words of a two-argument custom error's data.
    function _decodeTwoWords(bytes memory data) private pure returns (uint256 a, uint256 b) {
        assembly ("memory-safe") {
            a := mload(add(data, 0x24))
            b := mload(add(data, 0x44))
        }
    }
}
