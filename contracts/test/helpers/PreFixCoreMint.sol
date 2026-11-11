// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

import {PledrinConstants} from "src/libraries/PledrinConstants.sol";
import {TickAlign} from "src/libraries/TickAlign.sol";

/// @title The core graduation mint as it was written before the finding-1 fix
/// @notice Performs `BondingCurve._mintCore`'s batch and measures its ETH cost **the way
/// the contract measured it before commit `5b86188`**: the harness's own balance before
/// the call minus its balance after it.
/// @dev This exists so that both directions of finding 1 can be shown without editing
/// `contracts/src`, which this suite may not do. The fix removed one line, so the only way
/// to test that the line was wrong is to keep a copy of it somewhere a test can reach.
///
/// The copy is held honest by `measureBoth`, which returns the removed expression's value
/// and the landed expression's value from the same call. Every test that uses the harness
/// asserts those two agree when PositionManager holds nothing, which is what makes the
/// harness a reproduction of the old code rather than an unrelated contract that happens
/// to revert: if the batch, the ticks, the liquidity or the rounding here drifted from
/// `_mintCore`'s, the two numbers would stop matching and the equality would fail before
/// any claim about the defect was made.
///
/// The removed line, verbatim from `git show 5b86188^:contracts/src/BondingCurve.sol`:
///
/// ```solidity
/// uint256 ethBefore = address(this).balance;
/// positionManager.modifyLiquidities{value: target}(...);
/// ethUsed = ethBefore - address(this).balance;
/// ```
///
/// It is written against the real `IPositionManager` and `IAllowanceTransfer` interfaces
/// and reads no mock, so the fork suite runs the same harness against the deployed
/// PositionManager.
contract PreFixCoreMintHarness {
    /// @notice What the two expressions measured, from one mint.
    struct Measurement {
        /// @notice The position the mint created.
        uint256 positionId;
        /// @notice `ethBefore - address(this).balance`, the expression `5b86188` removed.
        uint256 ethUsedByBalanceDelta;
        /// @notice `getAmount0Delta(...)`, the expression `5b86188` added.
        uint256 ethUsedByComputation;
        /// @notice The token the mint consumed, which both versions measure as a delta.
        uint256 tokensUsed;
    }

    /// @notice The mint batch is funded from this contract, so it has to be able to take
    /// the swept `currency0` back. `BondingCurve.receive()` is the thing this stands for.
    receive() external payable {}

    /// @notice The ETH the core mint costs, by the expression `5b86188` added.
    /// @dev A pure function of the launch's terminal price and the key's tick spacing, so
    /// a caller can reproduce `Graduated.ethToCore` without reading any balance. This is
    /// the one copy of that formula in the suite outside `contracts/src`.
    /// @param sqrtPriceTerminal The launch's terminal price.
    /// @param tickSpacing The pool key's tick spacing.
    /// @return The `currency0` the core position requires, rounded as v4 rounds it.
    function computedCoreEth(uint160 sqrtPriceTerminal, int24 tickSpacing)
        public
        pure
        returns (uint256)
    {
        int24 tickLower = TickAlign.up(TickMath.MIN_TICK, tickSpacing);
        int24 tickUpper = TickAlign.down(TickMath.MAX_TICK, tickSpacing);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceTerminal, PledrinConstants.LP_SUPPLY
        );
        return SqrtPriceMath.getAmount0Delta(
            sqrtPriceTerminal, TickMath.getSqrtPriceAtTick(tickUpper), liquidity, true
        );
    }

    /// @notice Runs the core mint for a launch's parameters and reports both measurements.
    /// @dev The caller sends `target` as value and funds this contract with the token
    /// beforehand, exactly as the curve holds `LP_SUPPLY` when `_mintCore` runs.
    /// @param positionManager Uniswap v4 PositionManager, or the deterministic stand-in.
    /// @param permit2 Permit2, or the deterministic stand-in.
    /// @param token The launch token.
    /// @param owner The address the position NFT is minted to.
    /// @param key The pool key to mint into, whose price must be `sqrtPriceTerminal`.
    /// @param sqrtPriceTerminal The launch's terminal price.
    /// @param target The launch's `R_target`, which is also `amount0Max`.
    /// @return m Both measurements and what the mint consumed.
    function measureBoth(
        IPositionManager positionManager,
        IAllowanceTransfer permit2,
        IERC20 token,
        address owner,
        PoolKey memory key,
        uint160 sqrtPriceTerminal,
        uint128 target
    ) external payable returns (Measurement memory m) {
        m.ethUsedByComputation = computedCoreEth(sqrtPriceTerminal, key.tickSpacing);
        // Built in its own frame: `forge coverage` compiles with the optimizer and the IR
        // pipeline off, and the eight-element `MINT_POSITION` encoding does not fit on the
        // legacy codegen's stack alongside this function's locals. The same split is why
        // `MockPositionManager._mint` is three functions.
        bytes memory mintData = _coreMintData(key, sqrtPriceTerminal, target, owner);

        require(token.approve(address(permit2), PledrinConstants.LP_SUPPLY), "approve failed");
        permit2.approve(
            address(token),
            address(positionManager),
            uint160(PledrinConstants.LP_SUPPLY),
            type(uint48).max
        );

        m.positionId = positionManager.nextTokenId();
        uint256 tokensBefore = token.balanceOf(address(this));
        // --- the removed expression, first half ---
        uint256 ethBefore = address(this).balance;

        positionManager.modifyLiquidities{value: target}(mintData, block.timestamp);

        // --- the removed expression, second half. Reverts with panic 0x11 when the
        // balance rose across the call, which is what a swept stray does. ---
        m.ethUsedByBalanceDelta = ethBefore - address(this).balance;
        m.tokensUsed = tokensBefore - token.balanceOf(address(this));
    }

    /// @dev The core position's geometry and liquidity, as `_mintCore` computes them, and
    /// the batch built from them.
    function _coreMintData(
        PoolKey memory key,
        uint160 sqrtPriceTerminal,
        uint128 target,
        address owner
    ) private pure returns (bytes memory) {
        int24 tickLower = TickAlign.up(TickMath.MIN_TICK, key.tickSpacing);
        int24 tickUpper = TickAlign.down(TickMath.MAX_TICK, key.tickSpacing);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceTerminal, PledrinConstants.LP_SUPPLY
        );
        return _mintData(
            key, tickLower, tickUpper, liquidity, target, uint128(PledrinConstants.LP_SUPPLY), owner
        );
    }

    /// @dev `BondingCurve._mintData`, byte for byte, with the owner as a parameter.
    function _mintData(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        address owner
    ) private pure returns (bytes memory) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key, tickLower, tickUpper, uint256(liquidity), amount0Max, amount1Max, owner, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, ActionConstants.MSG_SENDER);
        return abi.encode(actions, params);
    }
}
